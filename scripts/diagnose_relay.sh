#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/diagnose_relay.sh --state-dir ./state/<host> [--ssh-identity PATH]

Runs read-only checks on the VPS: can the host reach the Outline Shadowsocks
port, is the Xray container up, recent Xray errors. Use when the client
connects but sites do not load (default path is Freedom Shadowsocks).
EOF
}

STATE_DIR=""
SSH_IDENTITY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --ssh-identity) SSH_IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${STATE_DIR}" || ! -f "${STATE_DIR}/node.json" ]]; then
  usage >&2
  exit 1
fi

host="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"])' "${STATE_DIR}/node.json")"
user="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_user"])' "${STATE_DIR}/node.json")"
ssh_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_port"])' "${STATE_DIR}/node.json")"
oa="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outline"]["address"])' "${STATE_DIR}/node.json")"
op="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outline"]["port"])' "${STATE_DIR}/node.json")"

ssh_opts=(-p "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[[ -n "${SSH_IDENTITY}" ]] && ssh_opts+=(-i "${SSH_IDENTITY}")

echo "=== 1) TCP reachability from VPS to Outline (${oa}:${op}) ==="
ssh "${ssh_opts[@]}" "${user}@${host}" "timeout 5 bash -c 'echo >/dev/tcp/${oa}/${op}' 2>/dev/null && echo OK || echo FAIL"

echo ""
echo "=== 2) Docker / Xray container ==="
ssh "${ssh_opts[@]}" "${user}@${host}" "docker ps --filter name=tristate-xray --format '{{.Names}} {{.Status}}' 2>/dev/null || echo 'docker not running'"

echo ""
echo "=== 3) Last 40 lines of Xray error log (inside container) ==="
ssh "${ssh_opts[@]}" "${user}@${host}" "docker logs --tail 40 tristate-xray 2>&1 || true"

echo ""
echo "If (1) shows FAIL: firewall or provider blocks outbound from VPS to Outline, or wrong IP/port in node.json."
echo "If (3) shows shadowsocks errors: wrong Outline password/method or server unreachable."
echo "After changing config/xray_config.template.json or Outline URI: re-render and deploy (just manage-list then just manage-set-port same port, or just provision)."
