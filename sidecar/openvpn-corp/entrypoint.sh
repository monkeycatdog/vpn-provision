#!/usr/bin/env bash
#
# Start the corporate OpenVPN client, wait for its tun device, then run a
# SOCKS5 proxy (dante) that egresses through the tunnel.
#
# Mounted inputs (read-only) under /etc/openvpn:
#   corporate.conf  - the corp .ovpn, with <ca>/<cert>/<key> inlined
#   corporate.auth  - two lines: username, password
#
# The proxy listens on 0.0.0.0:1080 *inside the container*; the compose file
# publishes it to 127.0.0.1:1080 on the host so only local mihomo can reach it.

set -euo pipefail

OVPN_CONF="${OVPN_CONF:-/etc/openvpn/corporate.conf}"
OVPN_AUTH="${OVPN_AUTH:-/etc/openvpn/corporate.auth}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
TUN_DEV="${TUN_DEV:-tun0}"
TUN_WAIT_SECS="${TUN_WAIT_SECS:-45}"

log() { echo "[openvpn-corp] $*" >&2; }

[[ -f "${OVPN_CONF}" ]] || { log "FATAL: ${OVPN_CONF} not mounted"; exit 1; }
[[ -f "${OVPN_AUTH}" ]] || { log "FATAL: ${OVPN_AUTH} not mounted"; exit 1; }

# /dev/net/tun must exist (compose grants the device + NET_ADMIN). Create the
# node if the kernel module is present but the device file is missing.
if [[ ! -c /dev/net/tun ]]; then
  log "creating /dev/net/tun"
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || { log "FATAL: cannot create /dev/net/tun (need --device /dev/net/tun + NET_ADMIN)"; exit 1; }
fi

# OpenSSL 3 ships Blowfish (BF-CBC) only via the legacy provider. Loading both
# providers lets the client negotiate AES-GCM via NCP when the server supports
# it, and still fall back to BF-CBC for a legacy-only gateway.
OVPN_ARGS=(
  --config "${OVPN_CONF}"
  --auth-user-pass "${OVPN_AUTH}"
  --auth-nocache
  --providers legacy default
  --data-ciphers "AES-256-GCM:AES-128-GCM:BF-CBC"
  --data-ciphers-fallback "BF-CBC"
  --dev "${TUN_DEV}"
  --verb 3
  --suppress-timestamps
  --writepid /run/openvpn.pid
  # Pull DNS from the server into the container resolver so corp-internal
  # hostnames (DOMAIN-SUFFIX rules from mihomo) resolve through the tunnel.
  --up /usr/local/bin/up-dns.sh --up-restart
  --script-security 2
)

# up-dns.sh: rewrite /etc/resolv.conf from pushed `dhcp-option DNS` values.
cat >/usr/local/bin/up-dns.sh <<'UP'
#!/usr/bin/env bash
set -euo pipefail
dns=()
for v in "${!foreign_option_@}"; do
  opt="${!v}"
  if [[ "${opt}" == "dhcp-option DNS "* ]]; then
    dns+=("${opt#dhcp-option DNS }")
  fi
done
if [[ ${#dns[@]} -gt 0 ]]; then
  { for ip in "${dns[@]}"; do echo "nameserver ${ip}"; done; } >/etc/resolv.conf
  echo "[openvpn-corp] resolv.conf set to: ${dns[*]}" >&2
fi
UP
chmod +x /usr/local/bin/up-dns.sh

log "starting openvpn -> $(grep -m1 '^remote ' "${OVPN_CONF}" || echo '?')"
openvpn "${OVPN_ARGS[@]}" &
OVPN_PID=$!

cleanup() { kill "${OVPN_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Wait for the tun device to come up (handshake complete).
waited=0
until ip link show "${TUN_DEV}" >/dev/null 2>&1; do
  if ! kill -0 "${OVPN_PID}" 2>/dev/null; then
    log "FATAL: openvpn exited before ${TUN_DEV} appeared"
    wait "${OVPN_PID}"; exit 1
  fi
  if (( waited >= TUN_WAIT_SECS )); then
    log "FATAL: ${TUN_DEV} not up after ${TUN_WAIT_SECS}s"
    exit 1
  fi
  sleep 1; waited=$((waited + 1))
done
log "${TUN_DEV} is up after ${waited}s"

# dante: SOCKS5, internal listener on all interfaces (published to loopback by
# compose), external egress bound to the tun device. No auth — reachability is
# constrained to the host loopback by the compose port publish.
cat >/etc/sockd.conf <<EOF
logoutput: stderr
internal: 0.0.0.0 port = ${SOCKS_PORT}
external: ${TUN_DEV}
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
  log: error
}
EOF

log "starting dante SOCKS5 on :${SOCKS_PORT} egress ${TUN_DEV}"
sockd -f /etc/sockd.conf &
SOCKD_PID=$!
cleanup() { kill "${SOCKD_PID}" "${OVPN_PID}" 2>/dev/null || true; }

# Exit if either process dies, so Docker's restart policy recovers the tunnel.
wait -n "${OVPN_PID}" "${SOCKD_PID}"
log "a child process exited; shutting down for restart"
exit 1
