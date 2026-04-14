import * as monaco from "monaco-editor";

import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";

import {
  postToSwift,
  type InboundMessage,
  type OutboundCommand,
} from "./bridge";
import { applyCmuxPalette, registerCmuxThemes } from "./theme";

// Route Monaco worker requests to the bundled workers.
self.MonacoEnvironment = {
  getWorker(_moduleId: unknown, label: string) {
    switch (label) {
      case "json":
        return new jsonWorker();
      case "css":
      case "scss":
      case "less":
        return new cssWorker();
      case "html":
      case "handlebars":
      case "razor":
        return new htmlWorker();
      case "typescript":
      case "javascript":
        return new tsWorker();
      default:
        return new editorWorker();
    }
  },
};

registerCmuxThemes(monaco);

const container = document.getElementById("root");
if (!container) {
  throw new Error("cmux monaco: missing #root");
}

const editor = monaco.editor.create(container, {
  value: "",
  language: "plaintext",
  theme: "cmux-dark",
  automaticLayout: true,
  fontFamily:
    "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace",
  fontSize: 13,
  lineNumbers: "on",
  minimap: { enabled: false },
  scrollBeyondLastLine: true,
  smoothScrolling: true,
  renderLineHighlight: "line",
  wordWrap: "off",
  tabSize: 2,
  insertSpaces: true,
  renderWhitespace: "selection",
  bracketPairColorization: { enabled: true },
});

// --- Outbound events ---------------------------------------------------------

let ignoreNextChange = false;

editor.onDidChangeModelContent((event) => {
  if (ignoreNextChange) {
    ignoreNextChange = false;
    return;
  }
  const model = editor.getModel();
  if (!model) return;
  const sel = editor.getSelection();
  const offset = sel ? model.getOffsetAt(sel.getStartPosition()) : 0;
  const end = sel ? model.getOffsetAt(sel.getEndPosition()) : offset;
  postToSwift({
    type: "changed",
    value: model.getValue(),
    cursor: { offset, length: Math.max(0, end - offset) },
    versionId: event.versionId,
  });
});

// Debounced snapshot of cursor + scroll + Monaco view state.
let snapshotHandle: number | null = null;
function scheduleViewStateSnapshot(): void {
  if (snapshotHandle !== null) return;
  snapshotHandle = window.setTimeout(() => {
    snapshotHandle = null;
    publishViewState();
  }, 250);
}

function scrollTopFraction(): number {
  const scrollTop = editor.getScrollTop();
  const scrollHeight = editor.getScrollHeight();
  const containerHeight = editor.getLayoutInfo().height;
  const denom = Math.max(1, scrollHeight - containerHeight);
  return Math.min(1, Math.max(0, scrollTop / denom));
}

function publishViewState(): void {
  const model = editor.getModel();
  if (!model) return;
  const sel = editor.getSelection();
  const start = sel ? model.getOffsetAt(sel.getStartPosition()) : 0;
  const end = sel ? model.getOffsetAt(sel.getEndPosition()) : start;
  const monacoViewState = editor.saveViewState();
  postToSwift({
    type: "viewState",
    cursor: { offset: start, length: Math.max(0, end - start) },
    scrollTopFraction: scrollTopFraction(),
    monacoViewState: monacoViewState ? JSON.stringify(monacoViewState) : "",
  });
}

editor.onDidChangeCursorPosition(scheduleViewStateSnapshot);
editor.onDidChangeCursorSelection(scheduleViewStateSnapshot);
editor.onDidScrollChange(scheduleViewStateSnapshot);

// Cmd+S → forward to Swift (host decides whether to actually save).
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
  postToSwift({ type: "saveRequested" });
});

// --- Inbound command router --------------------------------------------------

function setModelText(value: string, languageId: string, preserveViewState: boolean): void {
  const model = editor.getModel();
  const state = preserveViewState ? editor.saveViewState() : null;
  const desiredLang = languageId || "plaintext";
  if (model && model.getLanguageId() === desiredLang) {
    if (model.getValue() !== value) {
      ignoreNextChange = true;
      model.setValue(value);
    }
  } else {
    const uri = monaco.Uri.parse(`inmemory://cmux/${Date.now()}`);
    const next = monaco.editor.createModel(value, desiredLang, uri);
    editor.setModel(next);
    if (model) model.dispose();
  }
  if (state) editor.restoreViewState(state);
}

function setCursorFromOffset(offset: number, length: number): void {
  const model = editor.getModel();
  if (!model) return;
  const total = model.getValueLength();
  const start = Math.max(0, Math.min(offset, total));
  const end = Math.max(start, Math.min(start + Math.max(0, length), total));
  const startPos = model.getPositionAt(start);
  const endPos = model.getPositionAt(end);
  editor.setSelection(monaco.Range.fromPositions(startPos, endPos));
  editor.revealPositionInCenterIfOutsideViewport(startPos);
}

function apply(cmd: OutboundCommand): void {
  switch (cmd.kind) {
    case "setText":
      setModelText(cmd.value, cmd.languageId, cmd.preserveViewState);
      return;
    case "setCursor":
      setCursorFromOffset(cmd.offset, cmd.length);
      return;
    case "restoreViewState": {
      let restored = false;
      if (cmd.monacoViewState) {
        try {
          const parsed = JSON.parse(cmd.monacoViewState);
          restored = editor.restoreViewState(parsed) !== undefined;
        } catch {
          restored = false;
        }
      }
      if (!restored && cmd.cursorOffset !== null) {
        setCursorFromOffset(cmd.cursorOffset, cmd.cursorLength ?? 0);
      }
      if (!restored && cmd.scrollTopFraction !== null) {
        const denom = Math.max(
          1,
          editor.getScrollHeight() - editor.getLayoutInfo().height,
        );
        editor.setScrollTop(cmd.scrollTopFraction * denom);
      }
      return;
    }
    case "setTheme":
      applyCmuxPalette(monaco, {
        isDark: cmd.isDark,
        backgroundHex: cmd.backgroundHex,
        foregroundHex: cmd.foregroundHex,
      });
      return;
    case "setLanguage": {
      const model = editor.getModel();
      if (model) monaco.editor.setModelLanguage(model, cmd.languageId || "plaintext");
      return;
    }
    case "focus":
      editor.focus();
      return;
  }
}

window.cmuxMonaco = { apply };

// Signal readiness: Swift will respond with setText / restoreViewState / setTheme.
const readyMessage: InboundMessage = { type: "ready" };
postToSwift(readyMessage);
