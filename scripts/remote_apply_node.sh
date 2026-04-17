#!/usr/bin/env bash

set -euo pipefail

IMAGE="ghcr.io/xtls/xray-core:latest@sha256:592ec4d11f656db95598d01e76dbcc6e002d67360b96a5436500a938230f52c7"

usage() {
  cat <<'EOF'
Usage:
  remote_apply_node.sh bootstrap --install-dir DIR --ssh-port 22 --listen-port 443 --server-name NAME --reality-dest HOST:443 --ovpn FILE --routes FILE [--auth-file FILE]
  remote_apply_node.sh deploy-config --install-dir DIR --config FILE
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
  fi
}

bootstrap() {
  local install_dir="" ssh_port="" listen_port="" server_name="" reality_dest="" ovpn="" routes="" auth_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      --ssh-port) ssh_port="$2"; shift 2 ;;
      --listen-port) listen_port="$2"; shift 2 ;;
      --server-name) server_name="$2"; shift 2 ;;
      --reality-dest) reality_dest="$2"; shift 2 ;;
      --ovpn) ovpn="$2"; shift 2 ;;
      --routes) routes="$2"; shift 2 ;;
      --auth-file) auth_file="$2"; shift 2 ;;
      *) echo "Unknown bootstrap arg: $1" >&2; exit 1 ;;
    esac
  done

  for required in "${install_dir}" "${ssh_port}" "${listen_port}" "${server_name}" "${reality_dest}" "${ovpn}" "${routes}"; do
    if [[ -z "${required}" ]]; then
      usage >&2
      exit 1
    fi
  done

  export DEBIAN_FRONTEND=noninteractive

  apt-get update >&2
  apt-get install -y software-properties-common >&2
  add-apt-repository -y universe >&2 || true
  apt-get update >&2
  apt-get install -y ca-certificates curl docker-compose-plugin docker.io jq openvpn python3 ufw >&2 || {
    echo "apt install docker-compose-plugin failed; installing docker.io and Compose v2 plugin from GitHub" >&2
    apt-get install -y ca-certificates curl docker.io jq openvpn python3 ufw >&2
    arch="$(uname -m)"
    case "${arch}" in
      x86_64) dc_arch="x86_64" ;;
      aarch64) dc_arch="aarch64" ;;
      *) echo "Unsupported architecture for compose fallback: ${arch}" >&2; exit 1 ;;
    esac
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-${dc_arch}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  }
  systemctl enable --now docker >&2

  cat >/etc/sysctl.d/99-tristate-relay.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null

  sed -i -E 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming >&2
  ufw default allow outgoing >&2
  ufw allow "${ssh_port}/tcp" >&2
  ufw allow "${listen_port}/tcp" >&2
  ufw --force enable >&2

  cat >/etc/sysctl.d/99-tristate-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
  sysctl --system >/dev/null

  install -d -m 0755 "${install_dir}/xray" "${install_dir}/state" /etc/openvpn/client
  install -d -m 0777 "${install_dir}/xray/logs"

  local tmp_config
  tmp_config="$(mktemp)"

  python3 - "${ovpn}" "${routes}" "${auth_file}" /etc/openvpn/client >"${tmp_config}" <<'PY'
from pathlib import Path
import shutil
import shlex
import sys

raw_path = Path(sys.argv[1])
route_path = Path(sys.argv[2])
auth_path = sys.argv[3]
client_dir = Path(sys.argv[4])
source_dir = raw_path.parent
raw_lines = raw_path.read_text().splitlines()

guard_lines = [
    'pull-filter ignore "redirect-gateway"',
    'pull-filter ignore "dhcp-option DNS"',
    'pull-filter ignore "block-outside-dns"',
    "route-nopull",
]

injected_pull_filters = {
    'pull-filter ignore "redirect-gateway"',
    'pull-filter ignore "dhcp-option DNS"',
    'pull-filter ignore "block-outside-dns"',
}

strip_exact = {"route-nopull", "block-outside-dns"}
strip_prefixes = ("redirect-gateway",)

cleaned = []
auth_parts = None
for line in raw_lines:
    stripped = line.strip()
    if stripped in strip_exact or stripped in injected_pull_filters:
        continue
    if any(stripped.startswith(prefix) for prefix in strip_prefixes):
        continue
    try:
        parts = shlex.split(stripped)
    except ValueError:
        parts = stripped.split()
    if parts and parts[0] == "auth-user-pass":
        auth_parts = parts
        continue
    if parts and parts[0] in {"ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"} and len(parts) >= 2:
        candidate = Path(parts[1])
        if not candidate.is_absolute():
            candidate = (source_dir / candidate).resolve()
        if candidate.exists():
            target = client_dir / candidate.name
            shutil.copy2(candidate, target)
            rewritten = [parts[0], str(target)]
            if len(parts) > 2:
                rewritten.extend(parts[2:])
            cleaned.append(" ".join(rewritten))
            continue
    cleaned.append(line)

needs_auth = auth_parts is not None
result = cleaned + [""] + guard_lines + [""]
if needs_auth:
    selected_auth = None
    if auth_path:
        selected_auth = str(client_dir / "corporate.auth")
    elif len(auth_parts) >= 2:
        candidate = Path(auth_parts[1])
        if not candidate.is_absolute():
            candidate = (source_dir / candidate).resolve()
        if candidate.exists():
            target = client_dir / candidate.name
            shutil.copy2(candidate, target)
            selected_auth = str(target)
    if not selected_auth:
        raise SystemExit("OpenVPN config requires auth-user-pass but no auth file was provided")
    result.append(f"auth-user-pass {selected_auth}")
    result.append("")

result.append("# Explicit split-tunnel routes appended by provisioning")
for line in route_path.read_text().splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if not stripped.startswith("route "):
        continue
    result.append(stripped)

sys.stdout.write("\n".join(result) + "\n")
PY

  install -m 0600 "${tmp_config}" /etc/openvpn/client/corporate.conf
  rm -f "${tmp_config}"

  if [[ -n "${auth_file}" ]]; then
    install -m 0600 "${auth_file}" /etc/openvpn/client/corporate.auth
  fi

  systemctl enable openvpn-client@corporate >&2
  systemctl restart openvpn-client@corporate >&2

  local tun_ready=0
  for _ in $(seq 1 30); do
    if ip -o link show tun0 >/dev/null 2>&1 && ip -o -4 addr show dev tun0 | grep -q inet; then
      tun_ready=1
      break
    fi
    sleep 1
  done
  if [[ "${tun_ready}" -ne 1 ]]; then
    echo "OpenVPN did not bring up tun0 within 30s. Check 'journalctl -u openvpn-client@corporate'." >&2
    systemctl --no-pager --full status openvpn-client@corporate >&2 || true
    exit 1
  fi

  if ! python3 - "${routes}" <<'PY' >&2
import ipaddress
import subprocess
import sys

route_path = sys.argv[1]
routes_table = subprocess.check_output(["ip", "-4", "route", "show", "dev", "tun0"], text=True)
installed = []
for line in routes_table.splitlines():
    parts = line.split()
    if not parts:
        continue
    try:
        installed.append(ipaddress.IPv4Network(parts[0], strict=False))
    except ValueError:
        continue

expected = []
with open(route_path) as handle:
    for line in handle:
        stripped = line.strip()
        if not stripped.startswith("route "):
            continue
        _, addr, mask = stripped.split()
        try:
            expected.append(ipaddress.IPv4Network(f"{addr}/{mask}", strict=False))
        except ValueError:
            continue

matched = [
    net for net in expected
    if any(net.subnet_of(installed_net) or installed_net.subnet_of(net) or net == installed_net for installed_net in installed)
]

if not matched:
    print("ERROR: none of the corporate routes from ips.txt are installed via tun0.", file=sys.stderr)
    print("Installed tun0 routes:", file=sys.stderr)
    print(routes_table, file=sys.stderr)
    sys.exit(1)

print(f"Corporate routes via tun0: {len(matched)}/{len(expected)} matched.", file=sys.stderr)
PY
  then
    exit 1
  fi

  if [[ ! -f "${install_dir}/state/reality.env" ]]; then
    docker pull "${IMAGE}" >/dev/null
    local keys
    keys="$(docker run --rm --entrypoint xray "${IMAGE}" x25519)"
    local private_key public_key
    private_key="$(printf '%s\n' "${keys}" | awk '/^PrivateKey:/ {print $2; exit} /^Private key:/ {print $3; exit}')"
    public_key="$(printf '%s\n' "${keys}" | awk '/Password \(PublicKey\):/ {print $NF; exit} /^Public key:/ {print $3; exit}')"
    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
      echo "Failed to generate REALITY keypair" >&2
      exit 1
    fi
    cat >"${install_dir}/state/reality.env" <<EOF
REALITY_PRIVATE_KEY=${private_key}
REALITY_PUBLIC_KEY=${public_key}
SERVER_NAME=${server_name}
REALITY_DEST=${reality_dest}
LISTEN_PORT=${listen_port}
EOF
  fi

  # shellcheck disable=SC1090
  . "${install_dir}/state/reality.env"
  local payload
  payload="$(jq -cn \
    --arg private_key "${REALITY_PRIVATE_KEY}" \
    --arg public_key "${REALITY_PUBLIC_KEY}" \
    '{reality_private_key: $private_key, reality_public_key: $public_key}')"
  printf '__TRISTATE_BOOTSTRAP_JSON__ %s\n' "${payload}"
}

deploy_config() {
  local install_dir="" config_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      --config) config_path="$2"; shift 2 ;;
      *) echo "Unknown deploy-config arg: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "${install_dir}" || -z "${config_path}" ]]; then
    usage >&2
    exit 1
  fi

  install -d -m 0755 "${install_dir}/xray"
  install -d -m 0777 "${install_dir}/xray/logs"

  local previous_port=""
  if [[ -f "${install_dir}/xray/config.json" ]]; then
    previous_port="$(python3 - "${install_dir}/xray/config.json" <<'PY' || true
import json
import sys

try:
    config = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for inbound in config.get("inbounds", []):
    if inbound.get("tag") == "vless-reality-in":
        print(inbound["port"])
        break
PY
)"
  fi

  install -m 0644 "${config_path}" "${install_dir}/xray/config.json"

  local listen_port
  listen_port="$(python3 - "${install_dir}/xray/config.json" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
for inbound in config.get("inbounds", []):
    if inbound.get("tag") == "vless-reality-in":
        print(inbound["port"])
        break
else:
    raise SystemExit("vless-reality-in inbound not found in config")
PY
)"
  ufw allow "${listen_port}/tcp" >&2
  if [[ -n "${previous_port}" && "${previous_port}" != "${listen_port}" ]]; then
    ufw delete allow "${previous_port}/tcp" >&2 || true
  fi

  cat >"${install_dir}/docker-compose.yml" <<EOF
services:
  xray:
    image: ${IMAGE}
    container_name: tristate-xray
    restart: unless-stopped
    network_mode: host
    user: "0:0"
    command: ["run", "-config", "/etc/xray/config.json"]
    volumes:
      - ${install_dir}/xray/config.json:/etc/xray/config.json:ro
      - ${install_dir}/xray/logs:/var/log/xray
    healthcheck:
      test: ["CMD", "xray", "run", "-test", "-config", "/etc/xray/config.json"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

  docker run --rm --entrypoint xray \
    -v "${install_dir}/xray/config.json:/etc/xray/config.json:ro" \
    "${IMAGE}" run -test -config /etc/xray/config.json >/dev/null

  docker compose -f "${install_dir}/docker-compose.yml" pull >&2
  docker compose -f "${install_dir}/docker-compose.yml" up -d >&2
  # Xray reads config only at startup; the config.json bind-mount content may
  # have changed even when docker compose sees no image/compose change, so
  # force a restart so the new routing rules take effect.
  docker compose -f "${install_dir}/docker-compose.yml" restart xray >&2

  docker ps --filter name=tristate-xray --format '{{.Names}} {{.Status}}'
}

require_root

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

mode="$1"
shift

case "${mode}" in
  bootstrap) bootstrap "$@" ;;
  deploy-config) deploy_config "$@" ;;
  *) usage >&2; exit 1 ;;
esac
