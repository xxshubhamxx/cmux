import type * as monaco from "monaco-editor";

export const CMUX_THEME_DARK = "cmux-dark";
export const CMUX_THEME_LIGHT = "cmux-light";

export function registerCmuxThemes(monacoNs: typeof monaco): void {
  monacoNs.editor.defineTheme(CMUX_THEME_DARK, {
    base: "vs-dark",
    inherit: true,
    rules: [],
    colors: {},
  });
  monacoNs.editor.defineTheme(CMUX_THEME_LIGHT, {
    base: "vs",
    inherit: true,
    rules: [],
    colors: {},
  });
}

export interface CmuxPalette {
  isDark: boolean;
  backgroundHex: string;
  foregroundHex: string;
}

export function applyCmuxPalette(
  monacoNs: typeof monaco,
  palette: CmuxPalette,
): void {
  const base = palette.isDark ? "vs-dark" : "vs";
  const name = palette.isDark ? CMUX_THEME_DARK : CMUX_THEME_LIGHT;

  // Re-define with Ghostty-derived colors overlaid. Token rules inherit from the
  // base theme; we only override editor-chrome colors so syntax highlighting
  // still looks right for whichever language is loaded.
  monacoNs.editor.defineTheme(name, {
    base,
    inherit: true,
    rules: [],
    colors: {
      "editor.background": palette.backgroundHex,
      "editor.foreground": palette.foregroundHex,
      "editorCursor.foreground": palette.foregroundHex,
      "editor.lineHighlightBackground": palette.isDark
        ? "#ffffff0a"
        : "#0000000a",
      "editorGutter.background": palette.backgroundHex,
      "editorLineNumber.foreground": palette.isDark ? "#6e7681" : "#b1b1b3",
      "editorLineNumber.activeForeground": palette.foregroundHex,
      "editorWidget.background": palette.backgroundHex,
      "editorSuggestWidget.background": palette.backgroundHex,
      "editor.selectionBackground": palette.isDark ? "#264f7844" : "#add6ff66",
      "editor.inactiveSelectionBackground": palette.isDark
        ? "#3a3d41"
        : "#e5ebf1",
    },
  });

  monacoNs.editor.setTheme(name);

  // Mirror into CSS for the host element so white-on-white flashes never happen.
  document.documentElement.style.setProperty(
    "--cmux-editor-bg",
    palette.backgroundHex,
  );
  document.documentElement.style.setProperty(
    "--cmux-editor-fg",
    palette.foregroundHex,
  );
  document.body.style.background = palette.backgroundHex;
  document.body.style.color = palette.foregroundHex;
  document.documentElement.style.colorScheme = palette.isDark ? "dark" : "light";
}
