#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/manage_inbound.sh --state-dir ./state/<host> list
  ./scripts/manage_inbound.sh --state-dir ./state/<host> add-client NAME
  ./scripts/manage_inbound.sh --state-dir ./state/<host> remove-client NAME
  ./scripts/manage_inbound.sh --state-dir ./state/<host> rotate-client NAME
  ./scripts/manage_inbound.sh --state-dir ./state/<host> set-port PORT
  ./scripts/manage_inbound.sh --state-dir ./state/<host> print-uri NAME

Flags:
  --ssh-identity PATH   SSH private key to use for deploy
  --dry-run             Render the new config locally and show a diff vs the
                        currently deployed rendered-config.json. No state file
                        is written and nothing is uploaded.
EOF
}

quote_sh() {
  printf '%q' "$1"
}

STATE_DIR=""
SSH_IDENTITY=""
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --ssh-identity) SSH_IDENTITY="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

if [[ -z "${STATE_DIR}" || $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

for file in "${STATE_DIR}/node.json" "${STATE_DIR}/clients.json" "${CONFIG_DIR}/ips.txt" "${CONFIG_DIR}/xray_config.template.json" "${SCRIPT_DIR}/remote_apply_node.sh"; do
  if [[ ! -f "${file}" ]]; then
    echo "Required file not found: ${file}" >&2
    exit 1
  fi
done

REAL_STATE_DIR="${STATE_DIR}"
if [[ "${DRY_RUN}" == "1" ]]; then
  sandbox_dir="$(mktemp -d)"
  trap 'rm -rf "${sandbox_dir}"' EXIT
  cp "${STATE_DIR}/node.json" "${sandbox_dir}/node.json"
  cp "${STATE_DIR}/clients.json" "${sandbox_dir}/clients.json"
  STATE_DIR="${sandbox_dir}"
fi

command="$1"
shift

python_uuid='import uuid; print(uuid.uuid4())'

render_config() {
  local corp_domains="${CONFIG_DIR}/corporate_domains.txt"
  [[ ! -f "${corp_domains}" ]] && corp_domains=""
  python3 - "${CONFIG_DIR}/xray_config.template.json" "${STATE_DIR}/node.json" "${CONFIG_DIR}/ips.txt" "${STATE_DIR}/clients.json" "${STATE_DIR}/rendered-config.json" "${corp_domains}" <<'PY'
import ipaddress
import json
import sys
from string import Template

template_path, node_path, routes_path, clients_path, output_path, corp_domains_path = sys.argv[1:]
template = Template(open(template_path).read())
node = json.load(open(node_path))
clients = json.load(open(clients_path))

ips = []
for line in open(routes_path):
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or not stripped.startswith("route "):
        continue
    _, address, mask = stripped.split()
    network = ipaddress.IPv4Network(f"{address}/{mask}", strict=False)
    ips.append(str(network))

domains = []
if corp_domains_path:
    for line in open(corp_domains_path):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        domains.append(stripped)
if not domains:
    domains = ["regexp:^$"]

config = template.substitute(
    LISTEN_PORT=node["listen_port"],
    SERVER_NAME=json.dumps(node["server_name"]),
    REALITY_DEST=json.dumps(node["reality_dest"]),
    REALITY_PRIVATE_KEY=json.dumps(node["reality_private_key"]),
    SHORT_ID=json.dumps(node["short_id"]),
    CLIENTS=json.dumps(clients, indent=6),
    OUTLINE_ADDRESS=json.dumps(node["outline"]["address"]),
    OUTLINE_PORT=node["outline"]["port"],
    OUTLINE_METHOD=json.dumps(node["outline"]["method"]),
    OUTLINE_PASSWORD=json.dumps(node["outline"]["password"]),
    CORPORATE_IPS=json.dumps(ips, indent=8),
    CORPORATE_DOMAINS=json.dumps(domains, indent=8),
)

parsed = json.loads(config)
with open(output_path, "w") as handle:
    json.dump(parsed, handle, indent=2)
    handle.write("\n")
PY
}

deploy_remote() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    local current="${REAL_STATE_DIR}/rendered-config.json"
    local proposed="${STATE_DIR}/rendered-config.json"
    echo "[dry-run] Proposed rendered-config.json written to: ${proposed}"
    if [[ -f "${current}" ]]; then
      echo "[dry-run] Diff vs current (${current}):"
      if diff -u "${current}" "${proposed}" >/dev/null 2>&1; then
        echo "  (no changes)"
      else
        diff -u "${current}" "${proposed}" || true
      fi
    else
      echo "[dry-run] No existing rendered-config.json at ${current}; this would be the first deploy."
    fi
    echo "[dry-run] No state was written to ${REAL_STATE_DIR} and nothing was uploaded."
    return 0
  fi
  local host user ssh_port install_dir
  host="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"])' "${STATE_DIR}/node.json")"
  user="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_user"])' "${STATE_DIR}/node.json")"
  ssh_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_port"])' "${STATE_DIR}/node.json")"
  install_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["install_dir"])' "${STATE_DIR}/node.json")"

  local ssh_opts=(-p "${ssh_port}" -o BatchMode=no -o StrictHostKeyChecking=accept-new)
  local scp_opts=(-P "${ssh_port}" -o StrictHostKeyChecking=accept-new)
  if [[ -n "${SSH_IDENTITY}" ]]; then
    ssh_opts+=(-i "${SSH_IDENTITY}")
    scp_opts+=(-i "${SSH_IDENTITY}")
  fi

  local remote_stage="/tmp/tristate-manage-$RANDOM"
  ssh "${ssh_opts[@]}" "${user}@${host}" "mkdir -p $(quote_sh "${remote_stage}")"
  scp "${scp_opts[@]}" "${SCRIPT_DIR}/remote_apply_node.sh" "${STATE_DIR}/rendered-config.json" "${user}@${host}:${remote_stage}/"
  ssh "${ssh_opts[@]}" "${user}@${host}" \
    "chmod +x $(quote_sh "${remote_stage}/remote_apply_node.sh") && sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") deploy-config \
      --install-dir $(quote_sh "${install_dir}") \
      --config $(quote_sh "${remote_stage}/rendered-config.json") && rm -rf $(quote_sh "${remote_stage}")"
}

print_uri() {
  local name="$1"
  python3 - "${STATE_DIR}/node.json" "${STATE_DIR}/clients.json" "${name}" <<'PY'
import json
import sys
from urllib.parse import urlencode, quote

node = json.load(open(sys.argv[1]))
clients = json.load(open(sys.argv[2]))
target = sys.argv[3]

for client in clients:
    if client["email"] == target:
        params = urlencode(
            {
                "encryption": "none",
                "flow": client["flow"],
                "security": "reality",
                "sni": node["server_name"],
                "fp": "chrome",
                "pbk": node["reality_public_key"],
                "sid": node["short_id"],
                "type": "tcp",
                "headerType": "none",
            }
        )
        print(f"vless://{client['id']}@{node['host']}:{node['listen_port']}?{params}#{quote(client['email'])}")
        break
else:
    raise SystemExit(f"Client not found: {target}")
PY
}

case "${command}" in
  list)
    python3 -m json.tool "${STATE_DIR}/clients.json"
    ;;
  add-client)
    if [[ $# -ne 1 ]]; then
      echo "add-client requires NAME" >&2
      exit 1
    fi
    name="$1"
    uuid_value="$(python3 -c "${python_uuid}")"
    python3 - "${STATE_DIR}/clients.json" "${name}" "${uuid_value}" <<'PY'
import json
import sys

path, name, uuid_value = sys.argv[1:]
clients = json.load(open(path))
if any(client["email"] == name for client in clients):
    raise SystemExit(f"Client already exists: {name}")
clients.append({"email": name, "id": uuid_value, "flow": "xtls-rprx-vision"})
with open(path, "w") as handle:
    json.dump(clients, handle, indent=2)
    handle.write("\n")
PY
    render_config
    deploy_remote
    print_uri "${name}"
    ;;
  remove-client)
    if [[ $# -ne 1 ]]; then
      echo "remove-client requires NAME" >&2
      exit 1
    fi
    python3 - "${STATE_DIR}/clients.json" "$1" <<'PY'
import json
import sys

path, name = sys.argv[1:]
clients = json.load(open(path))
remaining = [client for client in clients if client["email"] != name]
if len(remaining) == len(clients):
    raise SystemExit(f"Client not found: {name}")
with open(path, "w") as handle:
    json.dump(remaining, handle, indent=2)
    handle.write("\n")
PY
    render_config
    deploy_remote
    ;;
  rotate-client)
    if [[ $# -ne 1 ]]; then
      echo "rotate-client requires NAME" >&2
      exit 1
    fi
    uuid_value="$(python3 -c "${python_uuid}")"
    python3 - "${STATE_DIR}/clients.json" "$1" "${uuid_value}" <<'PY'
import json
import sys

path, name, uuid_value = sys.argv[1:]
clients = json.load(open(path))
for client in clients:
    if client["email"] == name:
        client["id"] = uuid_value
        break
else:
    raise SystemExit(f"Client not found: {name}")
with open(path, "w") as handle:
    json.dump(clients, handle, indent=2)
    handle.write("\n")
PY
    render_config
    deploy_remote
    print_uri "$1"
    ;;
  set-port)
    if [[ $# -ne 1 ]]; then
      echo "set-port requires PORT" >&2
      exit 1
    fi
    python3 - "${STATE_DIR}/node.json" "$1" <<'PY'
import json
import sys

path, port = sys.argv[1:]
node = json.load(open(path))
node["listen_port"] = int(port)
with open(path, "w") as handle:
    json.dump(node, handle, indent=2)
    handle.write("\n")
PY
    render_config
    deploy_remote
    ;;
  print-uri)
    if [[ $# -ne 1 ]]; then
      echo "print-uri requires NAME" >&2
      exit 1
    fi
    print_uri "$1"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
