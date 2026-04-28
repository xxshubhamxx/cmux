#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/chromium-patches/aws-m1-ultra-verified-owl-host.json"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
MODE="applied"

usage() {
  cat >&2 <<EOF
usage: $0 [--chromium-src <path>] [--manifest <path>] [--mode applied|clean-apply]

Modes:
  applied      Verify the checkout is the recorded base plus the recorded patch.
  clean-apply  Verify the recorded patch applies to the recorded base in a temp clone.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --chromium-src)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      CHROMIUM_SRC="$1"
      ;;
    --manifest)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MANIFEST="$1"
      ;;
    --mode)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MODE="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ ! -d "$CHROMIUM_SRC/.git" ]; then
  echo "missing Chromium checkout: $CHROMIUM_SRC" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "missing manifest: $MANIFEST" >&2
  exit 1
fi

read_manifest() {
  /usr/bin/python3 - "$MANIFEST" "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
patch = root / manifest["patchFile"]
print(manifest["chromiumBaseCommit"])
print(patch)
print(manifest["patchSHA256"])
print(manifest["patchLineCount"])
print("\n".join(manifest.get("requiredBuildOutputs", [])))
PY
}

manifest_values_file="$(mktemp "${TMPDIR:-/tmp}/owl-chromium-manifest.XXXXXX")"
read_manifest > "$manifest_values_file"
EXPECTED_BASE="$(sed -n '1p' "$manifest_values_file")"
PATCH_FILE="$(sed -n '2p' "$manifest_values_file")"
EXPECTED_PATCH_SHA="$(sed -n '3p' "$manifest_values_file")"
EXPECTED_PATCH_LINES="$(sed -n '4p' "$manifest_values_file")"
REQUIRED_OUTPUTS=()
while IFS= read -r output; do
  REQUIRED_OUTPUTS+=("$output")
done < <(sed -n '5,$p' "$manifest_values_file")
rm -f "$manifest_values_file"

actual_patch_sha="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
actual_patch_lines="$(wc -l < "$PATCH_FILE" | tr -d ' ')"

if [ "$actual_patch_sha" != "$EXPECTED_PATCH_SHA" ]; then
  echo "patch sha mismatch: expected $EXPECTED_PATCH_SHA got $actual_patch_sha" >&2
  exit 1
fi

if [ "$actual_patch_lines" != "$EXPECTED_PATCH_LINES" ]; then
  echo "patch line-count mismatch: expected $EXPECTED_PATCH_LINES got $actual_patch_lines" >&2
  exit 1
fi

actual_head="$(git -C "$CHROMIUM_SRC" rev-parse HEAD)"
if [ "$actual_head" != "$EXPECTED_BASE" ]; then
  echo "Chromium HEAD mismatch: expected $EXPECTED_BASE got $actual_head" >&2
  exit 1
fi

case "$MODE" in
  applied)
    actual_diff_sha="$(git -C "$CHROMIUM_SRC" diff --binary | shasum -a 256 | awk '{print $1}')"
    actual_diff_lines="$(git -C "$CHROMIUM_SRC" diff --binary | wc -l | tr -d ' ')"
    if [ "$actual_diff_sha" != "$EXPECTED_PATCH_SHA" ]; then
      echo "Chromium diff sha mismatch: expected $EXPECTED_PATCH_SHA got $actual_diff_sha" >&2
      exit 1
    fi
    if [ "$actual_diff_lines" != "$EXPECTED_PATCH_LINES" ]; then
      echo "Chromium diff line-count mismatch: expected $EXPECTED_PATCH_LINES got $actual_diff_lines" >&2
      exit 1
    fi
    for output in "${REQUIRED_OUTPUTS[@]}"; do
      if [ ! -e "$CHROMIUM_SRC/$output" ]; then
        echo "missing required build output: $CHROMIUM_SRC/$output" >&2
        exit 1
      fi
    done
    ;;
  clean-apply)
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/owl-chromium-patch-check.XXXXXX")"
    cleanup() {
      rm -rf "$temp_dir"
    }
    trap cleanup EXIT
    git clone --shared --no-checkout "$CHROMIUM_SRC" "$temp_dir/chromium-src" >/dev/null 2>&1
    git -C "$temp_dir/chromium-src" checkout --detach "$EXPECTED_BASE" >/dev/null 2>&1
    git -C "$temp_dir/chromium-src" apply --check "$PATCH_FILE"
    ;;
  *)
    usage
    exit 2
    ;;
esac

echo "Chromium OWL patch check passed"
echo "mode: $MODE"
echo "chromium: $CHROMIUM_SRC"
echo "base: $EXPECTED_BASE"
echo "patch-sha256: $EXPECTED_PATCH_SHA"
