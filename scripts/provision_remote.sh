#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/provision_remote.sh \
    --host relay.example.com \
    --user root \
    --corp-ovpn /path/to/corporate.ovpn \
    --outline-uri 'ss://...' \
    [--auth-file /path/to/auth.txt] \
    [--ssh-port 22] \
    [--listen-port 443] \
    [--server-name yandex.ru] \
    [--reality-dest yandex.ru:443] \
    [--client-name laptop] \
    [--dry-run]

What it does:
  - connects from your laptop to the VPS over SSH
  - installs Docker, OpenVPN, UFW, and the Xray relay stack
  - hardens OpenVPN into split-tunnel mode using config/ips.txt
  - generates a VLESS+REALITY inbound
  - writes local state under ./state/<host> for future client/inbound management

  With --dry-run: validates env, files, Outline URI, OpenVPN deps, SSH
  reachability, passwordless sudo, remote port availability, and renders
  the Xray template locally with fake keys (xray run -test if docker is local).
  Makes zero changes on the VPS or in ./state/.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

quote_sh() {
  printf '%q' "$1"
}

list_ovpn_dependencies() {
  python3 - "$1" <<'PY'
from pathlib import Path
import shlex
import sys

ovpn_path = Path(sys.argv[1]).resolve()
source_dir = ovpn_path.parent
directives = {"ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "auth-user-pass"}

seen_paths = set()
seen_basenames = {}
for raw_line in ovpn_path.read_text().splitlines():
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith(";"):
        continue
    try:
        parts = shlex.split(stripped)
    except ValueError:
        continue
    if len(parts) < 2 or parts[0] not in directives:
        continue
    candidate = Path(parts[1])
    if candidate.is_absolute():
        continue
    resolved = (source_dir / candidate).resolve()
    if not resolved.exists() or resolved in seen_paths:
        continue
    prior = seen_basenames.get(resolved.name)
    if prior is not None and prior != resolved:
        raise SystemExit(
            f"OpenVPN dependency basename collision: {prior} vs {resolved}. "
            "Rename one of the files so basenames are unique."
        )
    seen_paths.add(resolved)
    seen_basenames[resolved.name] = resolved
    print(resolved)
PY
}

HOST=""
SSH_USER="root"
SSH_PORT="22"
CORP_OVPN=""
AUTH_FILE=""
OUTLINE_URI=""
LISTEN_PORT="443"
SERVER_NAME="yandex.ru"
REALITY_DEST="yandex.ru:443"
CLIENT_NAME="laptop"
INSTALL_DIR="/opt/tristate-relay"
STATE_ROOT="${REPO_ROOT}/state"
SSH_IDENTITY=""
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --corp-ovpn) CORP_OVPN="$2"; shift 2 ;;
    --auth-file) AUTH_FILE="$2"; shift 2 ;;
    --outline-uri) OUTLINE_URI="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --reality-dest) REALITY_DEST="$2"; shift 2 ;;
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --state-root) STATE_ROOT="$2"; shift 2 ;;
    --ssh-identity) SSH_IDENTITY="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${HOST}" || -z "${CORP_OVPN}" || -z "${OUTLINE_URI}" ]]; then
  usage >&2
  exit 1
fi

for cmd in ssh scp python3; do
  require_cmd "${cmd}"
done

for file in "${CORP_OVPN}" "${CONFIG_DIR}/ips.txt" "${SCRIPT_DIR}/remote_apply_node.sh" "${CONFIG_DIR}/xray_config.template.json"; do
  if [[ ! -f "${file}" ]]; then
    echo "Required file not found: ${file}" >&2
    exit 1
  fi
done

if [[ -n "${AUTH_FILE}" && ! -f "${AUTH_FILE}" ]]; then
  echo "OpenVPN auth file not found: ${AUTH_FILE}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT


ssh_opts=(-p "${SSH_PORT}" -o BatchMode=no -o StrictHostKeyChecking=accept-new)
scp_opts=(-P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_IDENTITY}" ]]; then
  ssh_opts+=(-i "${SSH_IDENTITY}")
  scp_opts+=(-i "${SSH_IDENTITY}")
fi

remote_stage="/tmp/tristate-relay-$RANDOM"

echo "[0/6] Preflight: verifying SSH and passwordless sudo on ${SSH_USER}@${HOST}:${SSH_PORT}"
if ! ssh "${ssh_opts[@]}" -o ConnectTimeout=10 "${SSH_USER}@${HOST}" "true" >/dev/null 2>&1; then
  echo "Cannot SSH to ${SSH_USER}@${HOST}:${SSH_PORT}. Check --host/--ssh-port/--ssh-identity." >&2
  exit 1
fi
if ! ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "sudo -n true" >/dev/null 2>&1; then
  echo "Remote user '${SSH_USER}' needs passwordless sudo (or run as root). Aborting." >&2
  exit 1
fi
actual_ssh_port="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" 'echo "${SSH_CONNECTION##* }"' 2>/dev/null || true)"
if [[ -n "${actual_ssh_port}" && "${actual_ssh_port}" != "${SSH_PORT}" ]]; then
  echo "Warning: active SSH connection is on port ${actual_ssh_port} but --ssh-port is ${SSH_PORT}." >&2
  echo "UFW will allow ${SSH_PORT}/tcp only; you risk locking yourself out. Aborting." >&2
  exit 1
fi

echo "[0/6] Preflight: verifying REALITY dest ${REALITY_DEST} supports TLS 1.3 + X25519 from the VPS"
reality_host="${REALITY_DEST%:*}"
reality_port="${REALITY_DEST##*:}"
reality_probe="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "if ! command -v openssl >/dev/null 2>&1; then echo __NO_OPENSSL__; else openssl s_client -connect $(quote_sh "${reality_host}:${reality_port}") -servername $(quote_sh "${SERVER_NAME}") -tls1_3 -groups X25519 </dev/null 2>&1; fi" \
  2>/dev/null || true)"
if printf '%s' "${reality_probe}" | grep -q '__NO_OPENSSL__'; then
  echo "  openssl not present on VPS; skipping REALITY-dest TLS probe." >&2
elif ! printf '%s' "${reality_probe}" | grep -qE 'Protocol *: *TLSv1\.3|New, TLSv1\.3,'; then
  echo "  ERROR: ${reality_host}:${reality_port} did not negotiate TLS 1.3 from the VPS. Pick a different --reality-dest." >&2
  printf '%s\n' "${reality_probe}" | tail -20 >&2
  exit 1
elif ! printf '%s' "${reality_probe}" | grep -qiE '(Server|Peer) Temp Key: *X25519|Negotiated .*: *x25519'; then
  echo "  ERROR: ${reality_host}:${reality_port} did not negotiate X25519. REALITY requires X25519 key exchange." >&2
  printf '%s\n' "${reality_probe}" | grep -iE 'Temp Key|Protocol|Cipher' >&2 || true
  exit 1
else
  echo "  ok: ${reality_host}:${reality_port} negotiated TLS 1.3 with X25519"
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "[dry-run] Validating Outline URI"
  python3 - "${OUTLINE_URI}" <<'PY'
import base64
import sys
from urllib.parse import urlparse

uri = sys.argv[1]
parsed = urlparse(uri)
if parsed.scheme != "ss":
    raise SystemExit(f"Outline URI must start with ss:// (got scheme={parsed.scheme!r})")
if not parsed.hostname:
    raise SystemExit("Outline URI must contain a host")
creds = parsed.netloc.rsplit("@", 1)[0]
try:
    decoded = base64.urlsafe_b64decode(creds + "=" * (-len(creds) % 4)).decode()
except Exception as exc:
    raise SystemExit(f"Outline URI userinfo is not valid base64: {exc}")
if ":" not in decoded:
    raise SystemExit("Decoded Outline creds must be METHOD:PASSWORD")
method, _ = decoded.split(":", 1)
op = parsed.port if parsed.port is not None else 8388
print(f"  scheme=ss host={parsed.hostname} port={op} method={method}")
PY

  echo "[dry-run] Enumerating OpenVPN dependencies"
  dep_count=0
  while IFS= read -r dep_file; do
    [[ -z "${dep_file}" ]] && continue
    echo "  dep: ${dep_file}"
    dep_count=$((dep_count + 1))
  done < <(list_ovpn_dependencies "${CORP_OVPN}")
  echo "  ${dep_count} external file(s) would be uploaded"

  echo "[dry-run] Checking remote listen port ${LISTEN_PORT}/tcp is free"
  port_in_use="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
    "ss -H -ltn 'sport = :${LISTEN_PORT}' 2>/dev/null | wc -l" 2>/dev/null || echo 0)"
  if [[ "${port_in_use}" -gt 0 ]]; then
    echo "  WARNING: port ${LISTEN_PORT}/tcp already has a listener on the VPS" >&2
  else
    echo "  ok"
  fi

  echo "[dry-run] Checking remote disk space on /"
  remote_free="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "df -Pk / | awk 'NR==2 {print \$4}'" 2>/dev/null || echo 0)"
  if [[ "${remote_free}" -lt 1048576 ]]; then
    echo "  WARNING: less than 1 GiB free on / (${remote_free} KiB)" >&2
  else
    echo "  ${remote_free} KiB free on /"
  fi

  echo "[dry-run] Rendering Xray config locally with ephemeral REALITY keys (docker x25519)"
  mkdir -p "${tmp_dir}"
  dry_private=""
  dry_public=""
  if command -v docker >/dev/null 2>&1; then
    dry_keys="$(docker run --rm --entrypoint xray ghcr.io/xtls/xray-core:latest@sha256:592ec4d11f656db95598d01e76dbcc6e002d67360b96a5436500a938230f52c7 x25519 2>/dev/null || true)"
    dry_private="$(printf '%s\n' "${dry_keys}" | awk '/^PrivateKey:/ {print $2; exit} /^Private key:/ {print $3; exit}')"
    dry_public="$(printf '%s\n' "${dry_keys}" | awk '/Password \(PublicKey\):/ {print $NF; exit} /^Public key:/ {print $3; exit}')"
  fi
  if [[ -z "${dry_private}" || -z "${dry_public}" ]]; then
    echo "[dry-run] WARNING: could not generate x25519 keys via docker; REALITY section will use invalid placeholders and xray run -test will be skipped." >&2
    dry_private="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    dry_public="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  fi
  cat >"${tmp_dir}/fake-node.json" <<EOF
{
  "host": "${HOST}",
  "ssh_user": "${SSH_USER}",
  "ssh_port": ${SSH_PORT},
  "install_dir": "${INSTALL_DIR}",
  "listen_port": ${LISTEN_PORT},
  "server_name": "${SERVER_NAME}",
  "reality_dest": "${REALITY_DEST}",
  "short_id": "0123456789abcdef",
  "reality_private_key": "${dry_private}",
  "reality_public_key":  "${dry_public}",
  "outline": $(python3 - "${OUTLINE_URI}" <<'PY'
import base64
import json
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
creds = parsed.netloc.rsplit("@", 1)[0]
decoded = base64.urlsafe_b64decode(creds + "=" * (-len(creds) % 4)).decode()
method, password = decoded.split(":", 1)
op = parsed.port if parsed.port is not None else 8388
print(json.dumps({"address": parsed.hostname, "port": op, "method": method, "password": password}))
PY
)
}
EOF
  cat >"${tmp_dir}/fake-clients.json" <<EOF
[{"email": "${CLIENT_NAME}", "id": "00000000-0000-4000-8000-000000000000", "flow": "xtls-rprx-vision"}]
EOF

  corp_domains_arg="${CONFIG_DIR}/corporate_domains.txt"
  [[ ! -f "${corp_domains_arg}" ]] && corp_domains_arg=""
  python3 - "${CONFIG_DIR}/xray_config.template.json" "${tmp_dir}/fake-node.json" "${CONFIG_DIR}/ips.txt" "${tmp_dir}/fake-clients.json" "${tmp_dir}/rendered.json" "${corp_domains_arg}" <<'PY'
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
    ips.append(str(ipaddress.IPv4Network(f"{address}/{mask}", strict=False)))

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
print(f"  rendered JSON is valid ({len(parsed.get('inbounds', []))} inbounds, {len(parsed.get('outbounds', []))} outbounds, {len(parsed.get('routing', {}).get('rules', []))} routing rules)")
PY

  if command -v docker >/dev/null 2>&1; then
    if [[ "${dry_private}" == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]]; then
      echo "[dry-run] Skipping 'xray run -test' (no valid x25519 keys from docker)."
    else
      echo "[dry-run] Running 'xray run -test' locally via docker"
      if docker run --rm --entrypoint xray \
        -v "${tmp_dir}/rendered.json:/etc/xray/config.json:ro" \
        ghcr.io/xtls/xray-core:latest@sha256:592ec4d11f656db95598d01e76dbcc6e002d67360b96a5436500a938230f52c7 \
        run -test -config /etc/xray/config.json &>"${tmp_dir}/xray.out"; then
        echo "  xray run -test: PASS"
      else
        echo "  xray run -test: FAIL" >&2
        cat "${tmp_dir}/xray.out" >&2
        exit 1
      fi
    fi
  else
    echo "[dry-run] docker not found locally; skipping 'xray run -test' (structural JSON check only)"
  fi

  existing_state="no"
  if [[ -f "${STATE_ROOT}/${HOST}/node.json" ]]; then
    existing_state="yes (REALITY keys + short_id would be reused; OpenVPN/Xray would be redeployed)"
  fi
  cat <<EOF

Dry run OK. Summary:
  host:            ${SSH_USER}@${HOST}:${SSH_PORT}
  listen port:     ${LISTEN_PORT}/tcp
  REALITY SNI:     ${SERVER_NAME}
  REALITY dest:    ${REALITY_DEST}
  install dir:     ${INSTALL_DIR}
  state dir:       ${STATE_ROOT}/${HOST}
  existing state:  ${existing_state}
  ovpn:            ${CORP_OVPN}
  auth file:       ${AUTH_FILE:-<none>}
  outline:         (validated)
  bootstrap client: ${CLIENT_NAME}

No changes were made. Re-run without --dry-run to apply.
EOF
  exit 0
fi

cleanup_remote() {
  ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "rm -rf $(quote_sh "${remote_stage}")" >/dev/null 2>&1 || true
}
trap 'rc=$?; rm -rf "${tmp_dir}"; cleanup_remote; exit $rc' EXIT

echo "[1/6] Uploading bootstrap assets to ${SSH_USER}@${HOST}:${remote_stage}"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "mkdir -p $(quote_sh "${remote_stage}")"
upload_files=(
  "${SCRIPT_DIR}/remote_apply_node.sh"
  "${CONFIG_DIR}/ips.txt"
  "${CORP_OVPN}"
)
while IFS= read -r dep_file; do
  [[ -n "${dep_file}" ]] && upload_files+=("${dep_file}")
done < <(list_ovpn_dependencies "${CORP_OVPN}")
scp "${scp_opts[@]}" "${upload_files[@]}" "${SSH_USER}@${HOST}:${remote_stage}/"
if [[ -n "${AUTH_FILE}" ]]; then
  scp "${scp_opts[@]}" "${AUTH_FILE}" "${SSH_USER}@${HOST}:${remote_stage}/corporate.auth"
fi

echo "[2/6] Bootstrapping the VPS"
bootstrap_output="$(
  ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
    "chmod +x $(quote_sh "${remote_stage}/remote_apply_node.sh") && sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") bootstrap \
      --install-dir $(quote_sh "${INSTALL_DIR}") \
      --ssh-port $(quote_sh "${SSH_PORT}") \
      --listen-port $(quote_sh "${LISTEN_PORT}") \
      --server-name $(quote_sh "${SERVER_NAME}") \
      --reality-dest $(quote_sh "${REALITY_DEST}") \
      --ovpn $(quote_sh "${remote_stage}/$(basename "${CORP_OVPN}")") \
      --routes $(quote_sh "${remote_stage}/ips.txt") \
      ${AUTH_FILE:+--auth-file $(quote_sh "${remote_stage}/corporate.auth")}"
)"

bootstrap_json="$(printf '%s\n' "${bootstrap_output}" | awk '/^__TRISTATE_BOOTSTRAP_JSON__ /{sub(/^__TRISTATE_BOOTSTRAP_JSON__ /,""); print; exit}')"
if [[ -z "${bootstrap_json}" ]]; then
  echo "Bootstrap did not return a JSON payload. Remote output:" >&2
  printf '%s\n' "${bootstrap_output}" >&2
  exit 1
fi
printf '%s\n' "${bootstrap_json}" >"${tmp_dir}/bootstrap.json"

state_dir="${STATE_ROOT}/${HOST}"
mkdir -p "${state_dir}"

if [[ -f "${state_dir}/node.json" ]]; then
  python3 - "${state_dir}/node.json" "${tmp_dir}/bootstrap.json" <<'PY' || true
import json
import sys

old = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
old_pub = old.get("reality_public_key")
new_pub = new.get("reality_public_key")
if old_pub and new_pub and old_pub != new_pub:
    print(
        "WARNING: REALITY public key on the VPS changed since the last provision.\n"
        f"  old: {old_pub}\n  new: {new_pub}\n"
        "All existing client URIs are invalidated and must be reissued.",
        file=sys.stderr,
    )
PY
fi

if [[ -f "${state_dir}/node.json" ]]; then
  short_id="$(python3 - "${state_dir}/node.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["short_id"])
PY
)"
else
  short_id="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
)"
fi

echo "[3/6] Writing local state to ${state_dir}"
python3 - "$HOST" "$SSH_USER" "$SSH_PORT" "$INSTALL_DIR" "$LISTEN_PORT" "$SERVER_NAME" "$REALITY_DEST" "$OUTLINE_URI" "$short_id" "${tmp_dir}/bootstrap.json" "${state_dir}/node.json" <<'PY'
import base64
import json
import sys
from urllib.parse import urlparse

host, ssh_user, ssh_port, install_dir, listen_port, server_name, reality_dest, outline_uri, short_id, bootstrap_path, output_path = sys.argv[1:]
bootstrap = json.load(open(bootstrap_path))

parsed = urlparse(outline_uri)
if parsed.scheme != "ss":
    raise SystemExit("Outline URI must start with ss://")

creds = parsed.netloc.rsplit("@", 1)[0]
server = parsed.hostname
port = parsed.port if parsed.port is not None else 8388
decoded = base64.urlsafe_b64decode(creds + "=" * (-len(creds) % 4)).decode()
method, password = decoded.split(":", 1)

node = {
    "host": host,
    "ssh_user": ssh_user,
    "ssh_port": int(ssh_port),
    "install_dir": install_dir,
    "listen_port": int(listen_port),
    "server_name": server_name,
    "reality_dest": reality_dest,
    "short_id": short_id,
    "reality_private_key": bootstrap["reality_private_key"],
    "reality_public_key": bootstrap["reality_public_key"],
    "outline": {
        "address": server,
        "port": port,
        "method": method,
        "password": password,
    },
}

with open(output_path, "w") as handle:
    json.dump(node, handle, indent=2)
    handle.write("\n")
PY

if [[ ! -f "${state_dir}/clients.json" ]]; then
  client_uuid="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
  cat >"${state_dir}/clients.json" <<EOF
[
  {
    "email": "${CLIENT_NAME}",
    "id": "${client_uuid}",
    "flow": "xtls-rprx-vision"
  }
]
EOF
fi

echo "[4/6] Rendering the Xray config"
corp_domains_arg="${CONFIG_DIR}/corporate_domains.txt"
[[ ! -f "${corp_domains_arg}" ]] && corp_domains_arg=""
python3 - "${CONFIG_DIR}/xray_config.template.json" "${state_dir}/node.json" "${CONFIG_DIR}/ips.txt" "${state_dir}/clients.json" "${tmp_dir}/config.json" "${corp_domains_arg}" <<'PY'
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

echo "[5/6] Uploading the rendered config and starting Xray"
scp "${scp_opts[@]}" "${tmp_dir}/config.json" "${SSH_USER}@${HOST}:${remote_stage}/config.json"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") deploy-config \
    --install-dir $(quote_sh "${INSTALL_DIR}") \
    --config $(quote_sh "${remote_stage}/config.json")"

echo "[6/6] Fetching the client URI"
python3 - "${state_dir}/node.json" "${state_dir}/clients.json" "${state_dir}/connection.txt" <<'PY'
import json
import sys
from urllib.parse import urlencode, quote

node = json.load(open(sys.argv[1]))
clients = json.load(open(sys.argv[2]))
client = clients[0]

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

uri = f"vless://{client['id']}@{node['host']}:{node['listen_port']}?{params}#{quote(client['email'])}"
with open(sys.argv[3], "w") as handle:
    handle.write(uri + "\n")
print(uri)
PY

cat <<EOF

Provisioning finished.
- Local state: ${state_dir}
- Client URI: $(cat "${state_dir}/connection.txt")

Future changes:
- add/remove clients with ./scripts/manage_inbound.sh
- current clients live in ${state_dir}/clients.json
EOF
