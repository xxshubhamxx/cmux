#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-dev-env.sh"

next_pid=""
started_db=0
cleanup_watcher_pid=""

stop_local_db() {
  bash "$ROOT_DIR/scripts/db-local.sh" down >/dev/null 2>&1 || true
  echo "cmux web dev: stopped local Postgres for CMUX_PORT=$CMUX_PORT"
}

start_cleanup_watcher() {
  if [[ "${CMUX_DEV_STOP_DB_ON_EXIT:-1}" == "0" ]]; then
    return
  fi

  local parent_pid=$$
  (
    trap '' INT HUP
    while kill -0 "$parent_pid" >/dev/null 2>&1; do
      sleep 1
    done
    bash "$ROOT_DIR/scripts/db-local.sh" down >/dev/null 2>&1 || true
  ) &
  cleanup_watcher_pid=$!
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "$next_pid" ]] && kill -0 "$next_pid" >/dev/null 2>&1; then
    pkill -TERM -P "$next_pid" >/dev/null 2>&1 || true
    kill "$next_pid" >/dev/null 2>&1 || true
    wait "$next_pid" >/dev/null 2>&1 || true
  fi

  if [[ "$started_db" == "1" && "${CMUX_DEV_STOP_DB_ON_EXIT:-1}" != "0" ]]; then
    if [[ -n "$cleanup_watcher_pid" ]] && kill -0 "$cleanup_watcher_pid" >/dev/null 2>&1; then
      kill "$cleanup_watcher_pid" >/dev/null 2>&1 || true
      wait "$cleanup_watcher_pid" >/dev/null 2>&1 || true
    fi
    stop_local_db
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${CMUX_DEV_START_DB:-1}" != "0" ]]; then
  started_db=1
  start_cleanup_watcher
  bash "$ROOT_DIR/scripts/db-local.sh" up >/dev/null
  bunx drizzle-kit migrate --config "$ROOT_DIR/drizzle.config.ts"
fi

redacted_database_url="postgres://${CMUX_DB_USER}:<redacted>@localhost:${CMUX_DB_PORT}/${CMUX_DB_NAME}"
cat <<EOF
cmux web dev
  CMUX_PORT=$CMUX_PORT
  CMUX_VM_API_BASE_URL=$CMUX_VM_API_BASE_URL
  DATABASE_URL=$redacted_database_url
  CMUX_WEB_SECRET_ENV_FILE=$CMUX_WEB_SECRET_ENV_FILE
EOF

next dev --port "$CMUX_PORT" &
next_pid=$!

set +e
wait "$next_pid"
status=$?
set -e
next_pid=""
exit "$status"
