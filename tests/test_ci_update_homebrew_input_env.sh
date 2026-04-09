#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/386.
# Ensures workflow_dispatch input values in update-homebrew.yml are routed
# through env vars instead of direct GitHub expression interpolation inside the
# shell script.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/update-homebrew.yml"

for forbidden in \
  'if [ -n "${{ github.event.inputs.version }}" ]; then' \
  'VERSION="${{ github.event.inputs.version }}"' \
  'if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then'
do
  if grep -Fq "$forbidden" "$WORKFLOW_FILE"; then
    echo "FAIL: update-homebrew.yml still uses unsafe direct interpolation"
    echo "Forbidden:"
    echo "  $forbidden"
    exit 1
  fi
done

for expected in \
  'VERSION_INPUT: ${{ github.event.inputs.version }}' \
  'VERSION="${VERSION_INPUT}"' \
  'EVENT_NAME: ${{ github.event_name }}' \
  'if [ "${EVENT_NAME}" = "workflow_dispatch" ]; then'
do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: missing expected safe input handling line in update-homebrew.yml"
    echo "Expected:"
    echo "  $expected"
    exit 1
  fi
done

echo "PASS: update-homebrew.yml uses env vars for workflow_dispatch inputs"
