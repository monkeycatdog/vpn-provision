#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${TRISTATE_STATE_DIR:-}" ]]; then
  printf '%s' "$TRISTATE_STATE_DIR"
else
  : "${TRISTATE_HOST:?Set TRISTATE_HOST or TRISTATE_STATE_DIR in .env}"
  printf '%s' "${TRISTATE_STATE_ROOT:-./state}/$TRISTATE_HOST"
fi
