#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/trace_routing.sh --state-dir ./state/<host> [--ssh-identity PATH] [--no-remote] domain [domain ...]

For each domain prints:
  - resolved IP(s)
  - predicted exit (corporate / RU / freedom) based on config/ips.txt and .ru TLD heuristic
  - (unless --no-remote) actual kernel route on the VPS via 'ip route get'
  - the Xray access-log lines that mention the domain

Default path for non-matching destinations is the Freedom Outline outbound,
so anything not corporate and not obviously RU is predicted as "freedom".
EOF
}

STATE_DIR=""
SSH_IDENTITY=""
REMOTE="1"
DOMAINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --ssh-identity) SSH_IDENTITY="$2"; shift 2 ;;
    --no-remote) REMOTE="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *) DOMAINS+=("$1"); shift ;;
  esac
done

if [[ -z "${STATE_DIR}" || ${#DOMAINS[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${STATE_DIR}/node.json" ]]; then
  echo "Missing ${STATE_DIR}/node.json" >&2
  exit 1
fi

host="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"])' "${STATE_DIR}/node.json")"
user="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_user"])' "${STATE_DIR}/node.json")"
ssh_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_port"])' "${STATE_DIR}/node.json")"

ssh_opts=(-p "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "${SSH_IDENTITY}" ]] && ssh_opts+=(-i "${SSH_IDENTITY}")

predict() {
  python3 - "${CONFIG_DIR}/ips.txt" "$@" <<'PY'
import ipaddress
import socket
import sys

routes_file = sys.argv[1]
domains = sys.argv[2:]

networks = []
for line in open(routes_file):
    stripped = line.strip()
    if not stripped.startswith("route "):
        continue
    parts = stripped.split()
    if len(parts) < 3:
        continue
    try:
        networks.append(ipaddress.IPv4Network(f"{parts[1]}/{parts[2]}", strict=False))
    except ValueError:
        continue

def classify(ip: str, host: str) -> str:
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return "unknown"
    for net in networks:
        if addr in net:
            return "corporate"
    lowered = host.lower().rstrip(".")
    if lowered.endswith(".ru") or lowered.endswith(".xn--p1ai") or lowered.endswith(".\u0440\u0444"):
        return "direct-ru"
    return "freedom"

out = []
for d in domains:
    try:
        infos = socket.getaddrinfo(d, None, socket.AF_INET, socket.SOCK_STREAM)
        ips = sorted({i[4][0] for i in infos})
    except socket.gaierror as exc:
        out.append((d, [], "dns-fail", str(exc)))
        continue
    verdicts = {classify(ip, d) for ip in ips}
    if "corporate" in verdicts:
        verdict = "corporate"
    elif "direct-ru" in verdicts:
        verdict = "direct-ru"
    else:
        verdict = "freedom"
    out.append((d, ips, verdict, ""))

for d, ips, verdict, err in out:
    ip_str = ",".join(ips) if ips else "-"
    note = f" ({err})" if err else ""
    print(f"{d}\t{ip_str}\t{verdict}{note}")
PY
}

echo "== Local prediction =="
printf "%-60s %-44s %s\n" "DOMAIN" "IPs" "PREDICTED"
while IFS=$'\t' read -r d ips verdict; do
  printf "%-60s %-44s %s\n" "$d" "$ips" "$verdict"
done < <(predict "${DOMAINS[@]}")

if [[ "${REMOTE}" != "1" ]]; then
  exit 0
fi

echo ""
echo "== Remote verification on ${user}@${host} =="

remote_script='set -e
while IFS= read -r d; do
  [ -z "$d" ] && continue
  echo "--- $d ---"
  ip=$(getent ahostsv4 "$d" | awk "NR==1 {print \$1}")
  if [ -z "$ip" ]; then
    echo "  DNS: FAIL"
    continue
  fi
  echo "  DNS: $ip"
  route_line=$(ip route get "$ip" 2>&1 | head -1)
  echo "  ROUTE: $route_line"
  dev=$(echo "$route_line" | awk "{for(i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1)}")
  if [ "$dev" = "tun0" ]; then
    echo "  EXIT-KERNEL: corporate (tun0)"
  elif [ -z "$dev" ]; then
    echo "  EXIT-KERNEL: unresolved"
  else
    echo "  EXIT-KERNEL: via $dev (direct if RU / Freedom if default; see Xray access log below)"
  fi
  if [ -r /opt/tristate-relay/xray/logs/access.log ]; then
    echo "  XRAY-LOG:"
    sudo grep -F "$d" /opt/tristate-relay/xray/logs/access.log 2>/dev/null | tail -3 | sed "s/^/    /" || true
  fi
done'

printf '%s\n' "${DOMAINS[@]}" | ssh "${ssh_opts[@]}" "${user}@${host}" "${remote_script}"
