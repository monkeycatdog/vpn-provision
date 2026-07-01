set dotenv-load

default:
  @just --list

provision:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  : "${TRISTATE_HOST:?set TRISTATE_HOST in .env}"
  : "${TRISTATE_CORP_OVPN:?set TRISTATE_CORP_OVPN in .env}"
  : "${TRISTATE_OUTLINE_URIS:?set TRISTATE_OUTLINE_URIS (comma-separated) in .env}"
  cmd=(
    ./scripts/provision_remote.sh
    --host "$TRISTATE_HOST"
    --user "${TRISTATE_SSH_USER:-root}"
    --corp-ovpn "$TRISTATE_CORP_OVPN"
    --ssh-port "${TRISTATE_SSH_PORT:-22}"
    --listen-port "${TRISTATE_LISTEN_PORT:-443}"
    --server-name "${TRISTATE_SERVER_NAME:-yandex.ru}"
    --reality-dest "${TRISTATE_REALITY_DEST:-yandex.ru:443}"
    --client-name "${TRISTATE_CLIENT_NAME:-laptop}"
    --install-dir "${TRISTATE_INSTALL_DIR:-/opt/tristate-relay}"
    --state-root "${TRISTATE_STATE_ROOT:-./state}"
  )
  IFS=',' read -ra _uris <<< "$TRISTATE_OUTLINE_URIS"
  for u in "${_uris[@]}"; do cmd+=(--outline-uri "$u"); done
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ -n "${TRISTATE_AUTH_FILE:-}" ]] && cmd+=(--auth-file "$TRISTATE_AUTH_FILE")
  "${cmd[@]}"

provision-check:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  : "${TRISTATE_HOST:?set TRISTATE_HOST in .env}"
  : "${TRISTATE_CORP_OVPN:?set TRISTATE_CORP_OVPN in .env}"
  : "${TRISTATE_OUTLINE_URIS:?set TRISTATE_OUTLINE_URIS (comma-separated) in .env}"
  cmd=(
    ./scripts/provision_remote.sh
    --host "$TRISTATE_HOST"
    --user "${TRISTATE_SSH_USER:-root}"
    --corp-ovpn "$TRISTATE_CORP_OVPN"
    --ssh-port "${TRISTATE_SSH_PORT:-22}"
    --listen-port "${TRISTATE_LISTEN_PORT:-443}"
    --server-name "${TRISTATE_SERVER_NAME:-yandex.ru}"
    --reality-dest "${TRISTATE_REALITY_DEST:-yandex.ru:443}"
    --client-name "${TRISTATE_CLIENT_NAME:-laptop}"
    --install-dir "${TRISTATE_INSTALL_DIR:-/opt/tristate-relay}"
    --state-root "${TRISTATE_STATE_ROOT:-./state}"
    --dry-run
  )
  IFS=',' read -ra _uris <<< "$TRISTATE_OUTLINE_URIS"
  for u in "${_uris[@]}"; do cmd+=(--outline-uri "$u"); done
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ -n "${TRISTATE_AUTH_FILE:-}" ]] && cmd+=(--auth-file "$TRISTATE_AUTH_FILE")
  "${cmd[@]}"

manage-list:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)
  "${cmd[@]}" list

manage-add name:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)
  "${cmd[@]}" add-client "{{name}}"

manage-remove name:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)
  "${cmd[@]}" remove-client "{{name}}"

manage-rotate name:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)
  "${cmd[@]}" rotate-client "{{name}}"

manage-uri name:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  "${cmd[@]}" print-uri "{{name}}"

manage-set-port port:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/manage_inbound.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)
  "${cmd[@]}" set-port "{{port}}"

connection:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cat "$sd/connection.txt"

diagnose:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/diagnose_relay.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  "${cmd[@]}"

trace +domains:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/trace_routing.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  [[ "${TRISTATE_NO_REMOTE:-0}" == "1" ]] && cmd+=(--no-remote)
  "${cmd[@]}" {{domains}}

trace-sample:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  sd="$(./scripts/tristate_state_dir.sh)"
  cmd=(./scripts/trace_routing.sh --state-dir "$sd")
  [[ -n "${TRISTATE_SSH_IDENTITY:-}" ]] && cmd+=(--ssh-identity "$TRISTATE_SSH_IDENTITY")
  "${cmd[@]}" \
    gitlab.ops.px-dev.com \
    yandex.ru \
    mail.ru \
    ifconfig.me \
    google.com \
    github.com

validate:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{justfile_directory()}}"
  bash -n scripts/provision_remote.sh
  bash -n scripts/remote_apply_node.sh
  bash -n scripts/manage_inbound.sh
  bash -n scripts/tristate_state_dir.sh
  bash -n scripts/diagnose_relay.sh
  bash -n scripts/trace_routing.sh
  echo OK
