#!/usr/bin/env bash
# Regression guard for workflow_dispatch input handling in test-e2e.yml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/test-e2e.yml"

if grep -Fq 'REF_DISPLAY="${{ inputs.ref || github.ref_name }}"' "$WORKFLOW_FILE"; then
  echo "FAIL: test-e2e.yml still interpolates inputs.ref directly inside run"
  exit 1
fi

for expected in \
  'REF_DISPLAY: ${{ inputs.ref || github.ref_name }}' \
  '**Ref:** \`$REF_DISPLAY\`'
do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: missing expected safe ref handling line in test-e2e.yml"
    echo "Expected:"
    echo "  $expected"
    exit 1
  fi
done

echo "PASS: test-e2e.yml routes ref input through env"
