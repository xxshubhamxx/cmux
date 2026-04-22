#!/usr/bin/env bun
import { createHash, randomBytes } from "node:crypto";
import WebSocket from "ws";
import { Sandbox } from "e2b";
import { Freestyle } from "freestyle";

type Provider = "e2b" | "freestyle";
type FreestyleVmRef = {
  exec(args: { command: string; timeoutMs?: number }): Promise<{ stdout?: string | null }>;
};

const provider = argValue("--provider") as Provider | undefined;
if (provider !== "e2b" && provider !== "freestyle") {
  throw new Error("--provider must be e2b or freestyle");
}

const image = argValue("--image") ?? argValue("--template") ?? argValue("--snapshot");
if (!image) {
  throw new Error("--image is required");
}

const keep = hasFlag("--keep");
const leasePath = "/tmp/cmux/attach-lease.json";

const result = provider === "e2b"
  ? await testE2B(image, keep)
  : await testFreestyle(image, keep);
console.log(JSON.stringify(result, null, 2));

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

async function testE2B(template: string, keep: boolean): Promise<Record<string, unknown>> {
  if (!process.env.E2B_API_KEY) {
    throw new Error("E2B_API_KEY is required");
  }
  const sandbox = await Sandbox.create(template, {
    timeoutMs: 10 * 60 * 1000,
    network: { allowPublicTraffic: false },
  });
  const host = sandbox.getHost(7777);
  const httpURL = `https://${host}`;
  const wsURL = `wss://${host}/terminal`;
  const headers = { "e2b-traffic-access-token": sandbox.trafficAccessToken ?? "" };

  try {
    const noTrafficAuth = await fetch(`${httpURL}/healthz`);
    const trafficAuth = await fetch(`${httpURL}/healthz`, { headers });
    if (noTrafficAuth.status !== 403) {
      throw new Error(`expected E2B traffic gate to return 403 without token, got ${noTrafficAuth.status}`);
    }
    if (trafficAuth.status !== 200) {
      throw new Error(`expected healthz with E2B token to return 200, got ${trafficAuth.status}`);
    }

    await installLeaseE2B(sandbox, "wrong-e2b", "sess-e2b");
    const wrongCmuxToken = await websocketAuthShouldFail(wsURL, headers, "wrong-token", "sess-e2b");
    const leaseStillThere = await e2bFileExists(sandbox, leasePath);
    if (!leaseStillThere) throw new Error("wrong cmux token consumed E2B lease");

    const token = await installLeaseE2B(sandbox, "right-e2b", "sess-e2b");
    const terminalOutput = await websocketShellRoundTrip(wsURL, headers, token, "sess-e2b");
    const replay = await websocketAuthShouldFail(wsURL, headers, token, "sess-e2b");

    return {
      provider: "e2b",
      sandboxId: sandbox.sandboxId,
      host,
      trafficGate: { withoutToken: noTrafficAuth.status, withToken: trafficAuth.status },
      unauthenticatedTransport: "covered by healthz 403 without e2b-traffic-access-token",
      wrongCmuxToken,
      terminalOutput,
      replay,
      kept: keep,
    };
  } finally {
    if (!keep) {
      await Sandbox.kill(sandbox.sandboxId).catch(() => false);
    }
  }
}

async function testFreestyle(snapshotId: string, keep: boolean): Promise<Record<string, unknown>> {
  if (!process.env.FREESTYLE_API_KEY) {
    throw new Error("FREESTYLE_API_KEY is required");
  }
  const fs = new Freestyle();
  const created = await fs.vms.create({
    snapshotId,
    ports: [{ port: 443, targetPort: 7777 }],
    readySignalTimeoutSeconds: 600,
  });
  const vmId = created.vmId;
  const vm = fs.vms.ref({ vmId });

  try {
    const domain = (created as { domains?: string[] }).domains?.[0] ?? `${vmId}.vm.freestyle.sh`;
    const httpURL = `https://${domain}`;
    const wsURL = `wss://${domain}/terminal`;

    const health = await fetch(`${httpURL}/healthz`);
    if (health.status !== 200) {
      throw new Error(`expected Freestyle healthz 200, got ${health.status}`);
    }

    await installLeaseFreestyle(vm, "wrong-freestyle", "sess-fs");
    const wrongCmuxToken = await websocketAuthShouldFail(wsURL, {}, "wrong-token", "sess-fs");
    const leaseStillThere = await freestyleFileExists(vm, leasePath);
    if (!leaseStillThere) throw new Error("wrong cmux token consumed Freestyle lease");

    const token = await installLeaseFreestyle(vm, "right-freestyle", "sess-fs");
    const terminalOutput = await websocketShellRoundTrip(wsURL, {}, token, "sess-fs");
    const replay = await websocketAuthShouldFail(wsURL, {}, token, "sess-fs");

    return {
      provider: "freestyle",
      vmId,
      domain,
      health: health.status,
      wrongCmuxToken,
      terminalOutput,
      replay,
      kept: keep,
    };
  } finally {
    if (!keep) {
      await fs.vms.delete({ vmId }).catch(() => undefined);
    }
  }
}

async function installLeaseE2B(sandbox: Sandbox, label: string, sessionId: string): Promise<string> {
  const { token, lease } = makeLease(label, sessionId);
  const encoded = Buffer.from(JSON.stringify(lease)).toString("base64");
  await sandbox.commands.run(
    `install -d -m 0700 /tmp/cmux && printf '%s' '${encoded}' | base64 -d > ${shellQuote(leasePath)} && chmod 600 ${shellQuote(leasePath)}`,
    { timeoutMs: 30_000 },
  );
  return token;
}

async function installLeaseFreestyle(vm: FreestyleVmRef, label: string, sessionId: string): Promise<string> {
  const { token, lease } = makeLease(label, sessionId);
  const encoded = Buffer.from(JSON.stringify(lease)).toString("base64");
  await vm.exec({
    command: `install -d -m 0700 /tmp/cmux && printf '%s' '${encoded}' | base64 -d > ${shellQuote(leasePath)} && chmod 600 ${shellQuote(leasePath)}`,
    timeoutMs: 30_000,
  });
  return token;
}

function makeLease(label: string, sessionId: string): { token: string; lease: unknown } {
  const token = `cmux-${label}-${randomBytes(24).toString("hex")}`;
  const hash = createHash("sha256").update(token).digest("hex");
  return {
    token,
    lease: {
      version: 1,
      token_sha256: hash,
      expires_at_unix: Math.floor(Date.now() / 1000) + 120,
      session_id: sessionId,
      single_use: true,
    },
  };
}

async function e2bFileExists(sandbox: Sandbox, path: string): Promise<boolean> {
  const result = await sandbox.commands.run(`test -f ${shellQuote(path)} && echo yes || echo no`, { timeoutMs: 30_000 });
  return result.stdout.trim() === "yes";
}

async function freestyleFileExists(vm: FreestyleVmRef, path: string): Promise<boolean> {
  const result = await vm.exec({
    command: `test -f ${shellQuote(path)} && echo yes || echo no`,
    timeoutMs: 30_000,
  });
  return (result.stdout ?? "").trim() === "yes";
}

async function websocketAuthShouldFail(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
): Promise<{ closeCode: number; closeReason: string }> {
  const ws = await openWebSocket(url, headers);
  ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId, cols: 80, rows: 24 }));
  return await waitForClose(ws);
}

async function websocketShellRoundTrip(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
): Promise<string> {
  const ws = await openWebSocket(url, headers);
  ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId, cols: 80, rows: 24 }));
  const ready = await waitForMessage(ws, (data, isBinary) => !isBinary && data.toString().includes('"ready"'));
  if (!ready.toString().includes('"ready"')) {
    throw new Error(`expected ready frame, got ${ready.toString()}`);
  }
  ws.send(Buffer.from("printf '%b\\n' '\\103\\115\\125\\130\\137\\103\\114\\117\\125\\104\\137\\127\\123\\137\\117\\113'; exit\r"));
  const output = await waitForMessage(ws, (data, isBinary) => isBinary && data.toString().includes("CMUX_CLOUD_WS_OK"));
  ws.close();
  return output.toString();
}

function openWebSocket(url: string, headers: Record<string, string>): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers });
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error(`timeout opening ${url}`));
    }, 15_000);
    ws.once("open", () => {
      clearTimeout(timer);
      resolve(ws);
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function waitForClose(ws: WebSocket): Promise<{ closeCode: number; closeReason: string }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for close")), 15_000);
    ws.once("close", (code, reason) => {
      clearTimeout(timer);
      resolve({ closeCode: code, closeReason: reason.toString() });
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function waitForMessage(
  ws: WebSocket,
  predicate: (data: Buffer, isBinary: boolean) => boolean,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting for message")), 30_000);
    ws.on("message", onMessage);
    ws.once("close", onClose);
    ws.once("error", onError);
    function cleanup() {
      clearTimeout(timer);
      ws.off("message", onMessage);
      ws.off("close", onClose);
      ws.off("error", onError);
    }
    function onMessage(data: WebSocket.RawData, isBinary: boolean) {
      const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
      if (!predicate(buffer, isBinary)) return;
      cleanup();
      resolve(buffer);
    }
    function onClose(code: number, reason: Buffer) {
      cleanup();
      reject(new Error(`closed before expected message: ${code} ${reason.toString()}`));
    }
    function onError(err: Error) {
      cleanup();
      reject(err);
    }
  });
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}
