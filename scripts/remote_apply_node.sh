#!/usr/bin/env bash

set -euo pipefail

MIHOMO_IMAGE="metacubex/mihomo:v1.19.25"
SIDECAR_IMAGE="tristate-openvpn-corp:local"
CORP_SOCKS_PORT="1080"
LOYALSOLDIER_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
LOYALSOLDIER_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

# write_compose <install_dir> — emit the docker-compose.yml shared by both the
# mihomo relay and the openvpn-corp egress sidecar. Both deploy-config and
# deploy-sidecar call this so the file always defines both services; each only
# (re)creates its own service by name, leaving the other running.
write_compose() {
  local install_dir="$1"
  cat >"${install_dir}/docker-compose.yml" <<EOF
services:
  mihomo:
    image: ${MIHOMO_IMAGE}
    container_name: tristate-mihomo
    restart: unless-stopped
    network_mode: host
    cap_add: [NET_ADMIN]
    volumes:
      - ${install_dir}/mihomo:/root/.config/mihomo
  openvpn-corp:
    image: ${SIDECAR_IMAGE}
    container_name: tristate-openvpn-corp
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun
    ports:
      - "127.0.0.1:${CORP_SOCKS_PORT}:${CORP_SOCKS_PORT}"
    volumes:
      - ${install_dir}/openvpn-corp/etc:/etc/openvpn:ro
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
  fi
}

download_loyalsoldier_geo_assets() {
  local dest="$1"
  install -d -m 0755 "${dest}"
  curl -fsSL "${LOYALSOLDIER_GEOSITE_URL}" -o "${dest}/geosite.dat"
  curl -fsSL "${LOYALSOLDIER_GEOIP_URL}" -o "${dest}/geoip.dat"
}

install_geo_update_job() {
  local install_dir="$1"
  local script_path="${install_dir}/mihomo/update-geo-assets.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "INSTALL_DIR='${install_dir}'"
    echo "LOYALSOLDIER_GEOSITE_URL='${LOYALSOLDIER_GEOSITE_URL}'"
    echo "LOYALSOLDIER_GEOIP_URL='${LOYALSOLDIER_GEOIP_URL}'"
    cat <<'INNER'
ASSETS="${INSTALL_DIR}/mihomo"
install -d -m 0755 "${ASSETS}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL "${LOYALSOLDIER_GEOSITE_URL}" -o "${tmp}/geosite.dat.new"
curl -fsSL "${LOYALSOLDIER_GEOIP_URL}" -o "${tmp}/geoip.dat.new"
changed=0
if [[ ! -f "${ASSETS}/geosite.dat" ]] || ! cmp -s "${tmp}/geosite.dat.new" "${ASSETS}/geosite.dat"; then
  mv "${tmp}/geosite.dat.new" "${ASSETS}/geosite.dat"
  changed=1
else
  rm -f "${tmp}/geosite.dat.new"
fi
if [[ ! -f "${ASSETS}/geoip.dat" ]] || ! cmp -s "${tmp}/geoip.dat.new" "${ASSETS}/geoip.dat"; then
  mv "${tmp}/geoip.dat.new" "${ASSETS}/geoip.dat"
  changed=1
else
  rm -f "${tmp}/geoip.dat.new"
fi
if [[ "${changed}" -eq 1 ]]; then
  docker restart tristate-mihomo >&2 || echo "tristate-mihomo-geo-update: geo files updated but docker restart failed" >&2
fi
INNER
  } >"${script_path}"
  chmod 0755 "${script_path}"

  cat >/etc/systemd/system/tristate-mihomo-geo-update.service <<EOF
[Unit]
Description=Update Loyalsoldier geo data for tristate mihomo
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path}
EOF

  cat >/etc/systemd/system/tristate-mihomo-geo-update.timer <<'EOF'
[Unit]
Description=Daily refresh of Loyalsoldier geoip/geosite for tristate mihomo

[Timer]
OnCalendar=daily
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >&2
  systemctl enable --now tristate-mihomo-geo-update.timer >&2
}

usage() {
  cat <<'EOF'
Usage:
  remote_apply_node.sh bootstrap --install-dir DIR --ssh-port 22 --listen-port 443
  remote_apply_node.sh deploy-sidecar --install-dir DIR --build-context DIR --ovpn FILE --auth FILE
  remote_apply_node.sh deploy-config --install-dir DIR --config FILE --cert FILE --key FILE
EOF
}

# deploy_sidecar: install corp credentials, build the openvpn-corp image, and
# bring up the egress sidecar. Runs only on a full provision (not on client
# add/remove), so the corp tunnel is established once and then left alone.
deploy_sidecar() {
  local install_dir="" build_context="" ovpn_path="" auth_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      --build-context) build_context="$2"; shift 2 ;;
      --ovpn) ovpn_path="$2"; shift 2 ;;
      --auth) auth_path="$2"; shift 2 ;;
      *) echo "Unknown deploy-sidecar arg: $1" >&2; exit 1 ;;
    esac
  done

  for required in "${install_dir}" "${build_context}" "${ovpn_path}" "${auth_path}"; do
    if [[ -z "${required}" ]]; then
      usage >&2
      exit 1
    fi
  done

  install -d -m 0700 "${install_dir}/openvpn-corp/etc"
  install -m 0600 "${ovpn_path}" "${install_dir}/openvpn-corp/etc/corporate.conf"
  install -m 0600 "${auth_path}" "${install_dir}/openvpn-corp/etc/corporate.auth"

  echo "[deploy-sidecar] building ${SIDECAR_IMAGE}" >&2
  docker build -t "${SIDECAR_IMAGE}" "${build_context}" >&2

  echo "[deploy-sidecar] writing docker-compose.yml" >&2
  write_compose "${install_dir}"

  echo "[deploy-sidecar] docker compose up -d --force-recreate openvpn-corp" >&2
  docker compose -f "${install_dir}/docker-compose.yml" up -d --force-recreate openvpn-corp >&2

  echo "[deploy-sidecar] waiting for corporate tunnel (tun0)" >&2
  local up=0 i
  for i in $(seq 1 60); do
    if docker logs tristate-openvpn-corp 2>&1 | grep -q "tun0 is up"; then
      up=1; break
    fi
    if docker logs tristate-openvpn-corp 2>&1 | grep -qE "FATAL|AUTH_FAILED"; then
      break
    fi
    sleep 1
  done
  if [[ "${up}" -ne 1 ]]; then
    echo "[deploy-sidecar] ERROR: corporate tunnel did not come up. Recent sidecar logs:" >&2
    docker logs --tail 60 tristate-openvpn-corp >&2 2>&1 || true
    exit 1
  fi
  echo "[deploy-sidecar] corporate tunnel established" >&2

  echo "[deploy-sidecar] probing SOCKS5 egress on 127.0.0.1:${CORP_SOCKS_PORT}" >&2
  if curl -s --max-time 12 --socks5-hostname "127.0.0.1:${CORP_SOCKS_PORT}" \
       https://ifconfig.me >/dev/null 2>&1; then
    echo "[deploy-sidecar] SOCKS5 egress reachable" >&2
  else
    echo "[deploy-sidecar] WARNING: SOCKS5 egress probe failed (corp may block ifconfig.me; tunnel is up)" >&2
  fi

  docker ps --filter name=tristate-openvpn-corp --format '{{.Names}} {{.Status}}'
}

bootstrap() {
  local install_dir="" ssh_port="" listen_port=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      --ssh-port) ssh_port="$2"; shift 2 ;;
      --listen-port) listen_port="$2"; shift 2 ;;
      *) echo "Unknown bootstrap arg: $1" >&2; exit 1 ;;
    esac
  done

  for required in "${install_dir}" "${ssh_port}" "${listen_port}"; do
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
  apt-get install -y ca-certificates curl docker.io jq python3 ufw >&2
  use_compose_github=0
  if ! apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    use_compose_github=1
  elif ! apt-get install -y docker-compose-plugin >&2; then
    use_compose_github=1
  fi
  if [[ "${use_compose_github}" -eq 1 ]]; then
    echo "docker-compose-plugin not available from apt (or install failed); installing Docker Compose v2 CLI plugin from GitHub" >&2
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
  fi
  systemctl enable --now docker >&2

  install -d -m 0755 "${install_dir}/mihomo"
  install -d -m 0700 "${install_dir}/mihomo/cert"
  install -d -m 0755 "${install_dir}/mihomo/logs"
  # Corp egress sidecar holds the corporate creds; 0700 so only root reads them.
  install -d -m 0700 "${install_dir}/openvpn-corp"
  install -d -m 0700 "${install_dir}/openvpn-corp/etc"

  # The openvpn-corp sidecar needs the tun device. Load the module and ensure
  # the device node exists so `--device /dev/net/tun` works in the container.
  modprobe tun 2>/dev/null || true
  if [[ ! -e /dev/net/tun ]]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || echo "WARNING: could not create /dev/net/tun" >&2
  fi

  sed -i -E 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming >&2
  ufw default allow outgoing >&2
  ufw allow "${ssh_port}/tcp" >&2
  ufw allow "${listen_port}/udp" >&2
  ufw --force enable >&2
}

deploy_config() {
  local install_dir="" config_path="" cert_path="" key_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      --config) config_path="$2"; shift 2 ;;
      --cert) cert_path="$2"; shift 2 ;;
      --key) key_path="$2"; shift 2 ;;
      *) echo "Unknown deploy-config arg: $1" >&2; exit 1 ;;
    esac
  done

  for required in "${install_dir}" "${config_path}" "${cert_path}" "${key_path}"; do
    if [[ -z "${required}" ]]; then
      usage >&2
      exit 1
    fi
  done

  install -d -m 0755 "${install_dir}/mihomo"
  install -d -m 0700 "${install_dir}/mihomo/cert"

  # Capture the currently deployed listen_port BEFORE overwrite so we can
  # revoke its UFW rule once the new port is in place. Empty string if no
  # prior config exists (first deploy).
  local prev_listen_port=""
  if [[ -f "${install_dir}/mihomo/config.yaml" ]]; then
    prev_listen_port="$(python3 - "${install_dir}/mihomo/config.yaml" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
    listeners = cfg.get("listeners") or []
    if listeners:
        print(listeners[0].get("port", ""))
except Exception:
    pass
PY
)"
  fi

  install -m 0644 "${config_path}" "${install_dir}/mihomo/config.yaml"
  install -m 0644 "${cert_path}" "${install_dir}/mihomo/cert/server.crt"
  install -m 0600 "${key_path}" "${install_dir}/mihomo/cert/server.key"

  echo "[deploy-config] downloading Loyalsoldier geoip.dat / geosite.dat" >&2
  download_loyalsoldier_geo_assets "${install_dir}/mihomo"

  echo "[deploy-config] validating mihomo config" >&2
  local validate_rc=0
  docker run --rm \
    -v "${install_dir}/mihomo:/root/.config/mihomo" \
    "${MIHOMO_IMAGE}" -t || validate_rc=$?
  if [[ "${validate_rc}" -ne 0 ]]; then
    echo "[deploy-config] ERROR: mihomo config validation failed (exit ${validate_rc})" >&2
    exit 1
  fi

  local listen_port
  listen_port="$(python3 - "${install_dir}/mihomo/config.yaml" <<'PY'
import json
import sys

# The rendered mihomo config is emitted as JSON-compatible YAML; json.load works.
with open(sys.argv[1]) as fh:
    config = json.load(fh)
listeners = config.get("listeners", [])
if not listeners:
    raise SystemExit("no listeners[] entry found in mihomo config")
print(listeners[0]["port"])
PY
)"
  echo "[deploy-config] ufw allow ${listen_port}/udp" >&2
  ufw allow "${listen_port}/udp" >&2
  if [[ -n "${prev_listen_port}" && "${prev_listen_port}" != "${listen_port}" ]]; then
    echo "[deploy-config] revoking previous ufw allow ${prev_listen_port}/udp" >&2
    ufw delete allow "${prev_listen_port}/udp" >&2 || true
  fi

  echo "[deploy-config] writing docker-compose.yml" >&2
  write_compose "${install_dir}"

  # Recreate only mihomo by name; the openvpn-corp sidecar (if running) is left
  # untouched so client add/remove never drops the corporate tunnel.
  echo "[deploy-config] docker compose up -d --force-recreate mihomo" >&2
  docker compose -f "${install_dir}/docker-compose.yml" up -d --force-recreate mihomo >&2

  echo "[deploy-config] install systemd geo refresh timer" >&2
  install_geo_update_job "${install_dir}"

  echo "[deploy-config] done" >&2
  docker ps --filter name=tristate-mihomo --format '{{.Names}} {{.Status}}'
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
  deploy-sidecar) deploy_sidecar "$@" ;;
  deploy-config) deploy_config "$@" ;;
  *) usage >&2; exit 1 ;;
esac
