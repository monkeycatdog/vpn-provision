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
  - predicted exit (corporate / RU / freedom) from config/ips.txt + .ru TLD heuristic
  - (unless --no-remote) lines from the live mihomo /rules dump that mention
    the domain or its resolved IP

mihomo's GLOBAL fallback group decides which Outline (or direct-out) handles
non-corporate, non-RU destinations at runtime; check /proxies/GLOBAL for the
currently selected outbound (use ./scripts/diagnose_relay.sh).
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

def classify(ip, host):
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return "unknown"
    for net in networks:
        if addr in net:
            return "corporate"
    lowered = host.lower().rstrip(".")
    if lowered.endswith(".ru") or lowered.endswith(".xn--p1ai") or lowered.endswith(".рф"):
        return "direct-ru"
    return "freedom"

for d in domains:
    try:
        infos = socket.getaddrinfo(d, None, socket.AF_INET, socket.SOCK_STREAM)
        ips = sorted({i[4][0] for i in infos})
    except socket.gaierror as exc:
        print(f"{d}\t-\tdns-fail ({exc})")
        continue
    verdicts = {classify(ip, d) for ip in ips}
    if "corporate" in verdicts:
        verdict = "corporate"
    elif "direct-ru" in verdicts:
        verdict = "direct-ru"
    else:
        verdict = "freedom"
    print(f"{d}\t{','.join(ips)}\t{verdict}")
PY
}

echo "== Local prediction =="
printf "%-60s %-44s %s\n" "DOMAIN" "IPs" "PREDICTED"
local_pred="$(predict "${DOMAINS[@]}")"
while IFS=$'\t' read -r d ips verdict; do
  printf "%-60s %-44s %s\n" "$d" "$ips" "$verdict"
done <<< "${local_pred}"

if [[ "${REMOTE}" != "1" ]]; then
  exit 0
fi

echo ""
echo "== Remote rule match on ${user}@${host} (via mihomo /rules) =="

rules_tmp="$(mktemp -t mihomo-rules.XXXXXX.json)"
trap 'rm -f "${rules_tmp}"' EXIT

if ! ssh "${ssh_opts[@]}" "${user}@${host}" 'curl -s --max-time 5 http://127.0.0.1:9090/rules' \
     > "${rules_tmp}" 2>/dev/null || [[ ! -s "${rules_tmp}" ]]; then
  echo "(could not reach mihomo REST API on 127.0.0.1:9090 via ${user}@${host})"
  echo "Note: GEOIP/GEOSITE rules require dat files; this dump only resolves literal DOMAIN-* and IP-CIDR rules."
  exit 0
fi

# Build a domain -> resolved-IP map from the local prediction (reuse DNS we already did).
declare -A IP_OF
while IFS=$'\t' read -r d ips _verdict; do
  IP_OF["$d"]="${ips%%,*}"
done <<< "${local_pred}"

for d in "${DOMAINS[@]}"; do
  echo "--- ${d} ---"
  ip="${IP_OF[$d]:-}"
  [[ "${ip}" == "-" ]] && ip=""
  echo "  DNS: ${ip:-FAIL}"
  patterns=("${d}")
  [[ -n "${ip}" ]] && patterns+=("${ip}")
  hit=0
  for p in "${patterns[@]}"; do
    if matches="$(grep -F -- "${p}" "${rules_tmp}" 2>/dev/null)"; then
      if [[ -n "${matches}" ]]; then
        printf '%s\n' "${matches}" | sed 's/^/    /'
        hit=1
      fi
    fi
  done
  if [[ "${hit}" -eq 0 ]]; then
    echo "    (no literal DOMAIN-*/IP-CIDR rule mentions this; mihomo will defer to GEOIP/GEOSITE dat lookup)"
  fi
done
