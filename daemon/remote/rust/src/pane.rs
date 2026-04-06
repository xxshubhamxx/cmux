use std::io::{Read, Write};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};

use crate::capture::{TerminalCapture, capture_terminal};
use crate::ghostty::GhosttyTerminal;
use crate::metadata::OscTracker;

const MAX_RAW_BUFFER_BYTES: usize = 1 << 20;
const IDLE_SETTLE_DURATION: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, serde::Serialize)]
pub struct PaneCapture {
    pub pane_id: String,
    pub session_id: String,
    pub capture: TerminalCapture,
    pub closed: bool,
    pub offset: u64,
    pub base_offset: u64,
}

#[derive(Debug)]
pub struct PaneReadResult {
    pub data: Vec<u8>,
    pub offset: u64,
    pub base_offset: u64,
    pub truncated: bool,
    pub eof: bool,
}

#[derive(Debug)]
pub struct PaneBufferState {
    pub base_offset: u64,
    pub next_offset: u64,
    pub buffer: Vec<u8>,
    pub closed: bool,
    pub busy: bool,
    pub busy_generation: u64,
    pub title: String,
    pub pwd: String,
    pub last_output_at: Instant,
}

#[derive(Debug)]
pub struct PaneShared {
    pub state: Mutex<PaneBufferState>,
    pub cv: Condvar,
}

#[derive(Debug)]
pub struct PaneHandle {
    pub pane_id: String,
    pub session_id: String,
    pub shared: Arc<PaneShared>,
    command_tx: Sender<PaneCommand>,
}

pub enum PaneRuntimeEvent {
    Output {
        session_id: String,
        pane_id: String,
        len: usize,
    },
    Busy {
        session_id: String,
        pane_id: String,
    },
    Idle {
        session_id: String,
        pane_id: String,
    },
    Exit {
        session_id: String,
        pane_id: String,
    },
}

pub type EventCallback = Arc<dyn Fn(PaneRuntimeEvent) + Send + Sync>;

enum ReaderEvent {
    Data(Vec<u8>),
    Eof,
}

enum PaneCommand {
    Write(Vec<u8>, mpsc::Sender<Result<usize, String>>),
    Resize(u16, u16, mpsc::Sender<Result<(), String>>),
    Capture(bool, mpsc::Sender<Result<TerminalCapture, String>>),
    Close(mpsc::Sender<()>),
}

impl PaneHandle {
    pub fn spawn(
        session_id: &str,
        pane_id: &str,
        command: &str,
        cols: u16,
        rows: u16,
        events: EventCallback,
    ) -> Result<Arc<Self>, String> {
        let shared = Arc::new(PaneShared {
            state: Mutex::new(PaneBufferState {
                base_offset: 0,
                next_offset: 0,
                buffer: Vec::new(),
                closed: false,
                busy: false,
                busy_generation: 0,
                title: String::new(),
                pwd: String::new(),
                last_output_at: Instant::now(),
            }),
            cv: Condvar::new(),
        });
        let (command_tx, command_rx) = crossbeam_channel::unbounded();
        let handle = Arc::new(Self {
            pane_id: pane_id.to_string(),
            session_id: session_id.to_string(),
            shared: Arc::clone(&shared),
            command_tx,
        });

        let session_id_owned = session_id.to_string();
        let pane_id_owned = pane_id.to_string();
        let command_owned = command.to_string();
        thread::spawn(move || {
            run_pane_actor(
                session_id_owned,
                pane_id_owned,
                command_owned,
                cols,
                rows,
                shared,
                command_rx,
                events,
            );
        });

        Ok(handle)
    }

    pub fn write(&self, data: Vec<u8>) -> Result<usize, String> {
        let (tx, rx) = mpsc::channel();
        self.command_tx
            .send(PaneCommand::Write(data, tx))
            .map_err(|_| "pane runtime is unavailable".to_string())?;
        rx.recv().map_err(|_| "pane runtime closed".to_string())?
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), String> {
        let (tx, rx) = mpsc::channel();
        self.command_tx
            .send(PaneCommand::Resize(cols, rows, tx))
            .map_err(|_| "pane runtime is unavailable".to_string())?;
        rx.recv().map_err(|_| "pane runtime closed".to_string())?
    }

    pub fn capture(&self, include_history: bool) -> Result<PaneCapture, String> {
        let (tx, rx) = mpsc::channel();
        self.command_tx
            .send(PaneCommand::Capture(include_history, tx))
            .map_err(|_| "pane runtime is unavailable".to_string())?;
        let capture = rx.recv().map_err(|_| "pane runtime closed".to_string())??;
        let state = self.shared.state.lock().unwrap();
        Ok(PaneCapture {
            pane_id: self.pane_id.clone(),
            session_id: self.session_id.clone(),
            capture,
            closed: state.closed,
            offset: state.next_offset,
            base_offset: state.base_offset,
        })
    }

    pub fn close(&self) {
        let (tx, rx) = mpsc::channel();
        if self.command_tx.send(PaneCommand::Close(tx)).is_ok() {
            let _ = rx.recv_timeout(Duration::from_secs(1));
        }
    }

    pub fn read(
        &self,
        offset: u64,
        max_bytes: usize,
        timeout_ms: i32,
    ) -> Result<PaneReadResult, String> {
        let timeout = if timeout_ms <= 0 {
            None
        } else {
            Some(Duration::from_millis(timeout_ms as u64))
        };
        let deadline = timeout.map(|value| Instant::now() + value);
        let mut guard = self.shared.state.lock().unwrap();

        loop {
            let mut effective_offset = offset;
            let truncated = effective_offset < guard.base_offset;
            if effective_offset < guard.base_offset {
                effective_offset = guard.base_offset;
            }
            if effective_offset < guard.next_offset {
                let start = (effective_offset - guard.base_offset) as usize;
                let mut end = guard.buffer.len();
                if max_bytes > 0 && end.saturating_sub(start) > max_bytes {
                    end = start + max_bytes;
                }
                let data = guard.buffer[start..end].to_vec();
                let offset = effective_offset + (end - start) as u64;
                let eof = guard.closed && end == guard.buffer.len();
                return Ok(PaneReadResult {
                    data,
                    offset,
                    base_offset: guard.base_offset,
                    truncated,
                    eof,
                });
            }
            if guard.closed {
                return Ok(PaneReadResult {
                    data: Vec::new(),
                    offset: guard.next_offset,
                    base_offset: guard.base_offset,
                    truncated,
                    eof: true,
                });
            }

            match deadline {
                Some(target) => {
                    let now = Instant::now();
                    if now >= target {
                        return Err("timeout".to_string());
                    }
                    let (next_guard, wait_result) =
                        self.shared.cv.wait_timeout(guard, target - now).unwrap();
                    guard = next_guard;
                    if wait_result.timed_out() {
                        return Err("timeout".to_string());
                    }
                }
                None => {
                    guard = self.shared.cv.wait(guard).unwrap();
                }
            }
        }
    }
}

fn run_pane_actor(
    session_id: String,
    pane_id: String,
    command: String,
    cols: u16,
    rows: u16,
    shared: Arc<PaneShared>,
    command_rx: Receiver<PaneCommand>,
    events: EventCallback,
) {
    let pty_system = native_pty_system();
    let pair = match pty_system.openpty(PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }) {
        Ok(value) => value,
        Err(_) => return,
    };

    let mut cmd = CommandBuilder::new("/bin/sh");
    cmd.arg("-lc");
    cmd.arg(command.as_str());
    let mut child = match pair.slave.spawn_command(cmd) {
        Ok(value) => value,
        Err(_) => return,
    };
    drop(pair.slave);

    let master = pair.master;
    let reader = match master.try_clone_reader() {
        Ok(value) => value,
        Err(_) => return,
    };
    let mut writer = match master.take_writer() {
        Ok(value) => value,
        Err(_) => return,
    };
    let mut terminal = match GhosttyTerminal::new(cols, rows, 100_000) {
        Ok(value) => value,
        Err(_) => return,
    };
    let mut metadata = OscTracker::default();

    let (reader_tx, reader_rx) = crossbeam_channel::unbounded();
    thread::spawn(move || reader_loop(reader, reader_tx));

    let mut runtime_closed = false;
    let mut reader_rx = reader_rx;
    while !runtime_closed {
        crossbeam_channel::select! {
            recv(reader_rx) -> message => {
                match message {
                    Ok(ReaderEvent::Data(data)) => {
                        let mut emit_busy = false;
                        let _ = terminal.feed(&data);
                        metadata.feed(&data);
                        {
                            let mut state = shared.state.lock().unwrap();
                            if !state.busy {
                                state.busy = true;
                                state.busy_generation += 1;
                                emit_busy = true;
                            }
                            state.title = metadata.title().to_string();
                            state.pwd = metadata.pwd().to_string();
                            state.buffer.extend_from_slice(&data);
                            state.next_offset += data.len() as u64;
                            state.last_output_at = Instant::now();
                            if state.buffer.len() > MAX_RAW_BUFFER_BYTES {
                                let overflow = state.buffer.len() - MAX_RAW_BUFFER_BYTES;
                                state.buffer.drain(..overflow);
                                state.base_offset += overflow as u64;
                            }
                        }
                        shared.cv.notify_all();
                        if emit_busy {
                            events(PaneRuntimeEvent::Busy {
                                session_id: session_id.clone(),
                                pane_id: pane_id.clone(),
                            });
                        }
                        events(PaneRuntimeEvent::Output {
                            session_id: session_id.clone(),
                            pane_id: pane_id.clone(),
                            len: data.len(),
                        });
                    }
                    Ok(ReaderEvent::Eof) | Err(_) => {
                        reader_rx = crossbeam_channel::never();
                        {
                            let mut state = shared.state.lock().unwrap();
                            state.closed = true;
                            state.busy = false;
                        }
                        shared.cv.notify_all();
                        events(PaneRuntimeEvent::Exit {
                            session_id: session_id.clone(),
                            pane_id: pane_id.clone(),
                        });
                    }
                }
            }
            recv(command_rx) -> message => {
                match message {
                    Ok(PaneCommand::Write(data, reply)) => {
                        let result = writer
                            .write_all(&data)
                            .and_then(|_| writer.flush())
                            .map(|_| data.len())
                            .map_err(|err| err.to_string());
                        let _ = reply.send(result);
                    }
                    Ok(PaneCommand::Resize(cols, rows, reply)) => {
                        let result = master
                            .resize(PtySize {
                                rows: rows.max(1),
                                cols: cols.max(2),
                                pixel_width: 0,
                                pixel_height: 0,
                            })
                            .map_err(|err| err.to_string())
                            .and_then(|_| terminal.resize(cols.max(2), rows.max(1)));
                        let _ = reply.send(result);
                    }
                    Ok(PaneCommand::Capture(include_history, reply)) => {
                        let result = terminal.capture(include_history).map(|raw| {
                            capture_terminal(raw, metadata.title().to_string(), metadata.pwd().to_string())
                        });
                        let _ = reply.send(result);
                    }
                    Ok(PaneCommand::Close(reply)) => {
                        let _ = child.kill();
                        let _ = reply.send(());
                        runtime_closed = true;
                    }
                    Err(_) => runtime_closed = true,
                }
            }
            default(Duration::from_millis(50)) => {
                let emit_idle = {
                    let mut state = shared.state.lock().unwrap();
                    if state.closed || !state.busy || state.last_output_at.elapsed() < IDLE_SETTLE_DURATION {
                        false
                    } else {
                        state.busy = false;
                        true
                    }
                };
                if emit_idle {
                    shared.cv.notify_all();
                    events(PaneRuntimeEvent::Idle {
                        session_id: session_id.clone(),
                        pane_id: pane_id.clone(),
                    });
                }
            }
        }
    }

    let _ = child.kill();
    let _ = child.wait();
}

fn reader_loop(mut reader: Box<dyn Read + Send>, tx: Sender<ReaderEvent>) {
    let mut buf = vec![0_u8; 32 * 1024];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => {
                let _ = tx.send(ReaderEvent::Eof);
                return;
            }
            Ok(len) => {
                let _ = tx.send(ReaderEvent::Data(buf[..len].to_vec()));
            }
            Err(_) => {
                let _ = tx.send(ReaderEvent::Eof);
                return;
            }
        }
    }
}
