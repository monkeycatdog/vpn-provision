#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/diagnose_relay.sh --state-dir ./state/<host> [--ssh-identity PATH]

Runs read-only checks on the VPS:
  1. TCP reachability from VPS to each configured Outline endpoint
  2. mihomo container status
  3. Last 40 lines of mihomo logs
  4. Live mihomo proxy-group state (which outbound is currently selected)
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

ssh_opts=(-p "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[[ -n "${SSH_IDENTITY}" ]] && ssh_opts+=(-i "${SSH_IDENTITY}")

echo "=== 1) TCP reachability from VPS to each Outline endpoint ==="
endpoints="$(python3 -c '
import json, sys
node = json.load(open(sys.argv[1]))
for ep in node["outline"]:
    print(f"{ep[\"name\"]} {ep[\"address\"]} {ep[\"port\"]}")
' "${STATE_DIR}/node.json")"

while read -r name addr port; do
  [[ -z "${name}" ]] && continue
  result="$(ssh "${ssh_opts[@]}" "${user}@${host}" \
    "timeout 5 bash -c 'echo >/dev/tcp/${addr}/${port}' 2>/dev/null && echo OK || echo FAIL")"
  printf "  %-20s %s:%s  %s\n" "${name}" "${addr}" "${port}" "${result}"
done <<< "${endpoints}"

echo ""
echo "=== 2) Mihomo container status ==="
ssh "${ssh_opts[@]}" "${user}@${host}" bash <<'REMOTE'
set +e
docker_cmd() {
  if docker ps >/dev/null 2>&1; then
    docker "$@"
  elif sudo -n docker ps >/dev/null 2>&1; then
    sudo -n docker "$@"
  else
    sudo docker "$@"
  fi
}
docker_cmd ps --filter name=tristate-mihomo --format '{{.Names}} {{.Status}}' \
  || echo "(docker ps failed; need docker group or passwordless sudo for docker)"
echo ""
echo "=== 3) Last 40 lines of mihomo logs ==="
docker_cmd logs --tail 40 tristate-mihomo 2>&1 || true
echo ""
echo "=== 4) Mihomo live proxy-group state (selected outbound + delay) ==="
curl -s --max-time 5 http://127.0.0.1:9090/proxies/GLOBAL \
  | python3 -m json.tool 2>/dev/null \
  || echo "(could not reach mihomo REST API on 127.0.0.1:9090 - container down or external-controller misconfigured)"
echo ""
echo "=== 5) openvpn-corp sidecar status + tunnel ==="
docker_cmd ps --filter name=tristate-openvpn-corp --format '{{.Names}} {{.Status}}' \
  || echo "(docker ps failed)"
docker_cmd logs --tail 15 tristate-openvpn-corp 2>&1 | grep -iE "tun0 is up|FATAL|AUTH_FAILED|SOCKS5" \
  || echo "(no tunnel status lines yet)"
echo "-- corp SOCKS5 egress probe (bypasses mihomo) --"
curl -s --max-time 10 --socks5-hostname 127.0.0.1:1080 https://ifconfig.me \
  && echo " <- corp egress IP" \
  || echo "(corp SOCKS5 probe failed; tunnel down or corp blocks ifconfig.me)"
REMOTE

echo ""
echo "If (1) shows FAIL: provider blocks outbound or wrong IP/port in node.json.outline[]"
echo "If (4) shows now=direct-out: ALL Outline endpoints failed health check; add a third or wait for upstream."
echo "If (4) shows now=ss-*: that endpoint is healthy and active."
echo "Refresh client config + redeploy: just manage-set-port \$(grep listen_port state/<host>/node.json | head -1 | grep -oE '[0-9]+') (no-op port update triggers re-render + deploy)."
