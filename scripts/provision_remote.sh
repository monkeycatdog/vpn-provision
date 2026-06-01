#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
SIDECAR_BUILD_DIR="${REPO_ROOT}/sidecar/openvpn-corp"
MIHOMO_IMAGE="metacubex/mihomo:v1.19.25"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/provision_remote.sh \
    --host relay.example.com \
    --user root \
    --corp-ovpn /path/to/corporate.ovpn \
    --outline-uri 'ss://...' [--outline-uri 'ss://...' ...] \
    [--outline-uris-csv 'ss://a,ss://b'] \
    [--auth-file /path/to/auth.txt] \
    [--ssh-port 22] \
    [--listen-port 443] \
    [--client-name laptop] \
    [--dry-run]

What it does:
  - connects from your laptop to the VPS over SSH
  - installs Docker, UFW, and the mihomo relay stack
  - generates a self-signed EC P-256 cert/key pair locally for hysteria2 TLS
    (pinned by SHA-256 fingerprint, so no SNI/CA infrastructure needed)
  - builds an openvpn-corp sidecar container (real OpenVPN client) that holds
    the corporate tunnel and exposes a loopback SOCKS5 proxy; mihomo routes
    corp-destined traffic to it (mihomo itself never speaks OpenVPN, which lets
    this work with legacy gateways: BF-CBC, no tls-crypt)
  - encodes one or more Outline (ss://) endpoints as upstream proxies
  - hardens routing using config/ips.txt and config/corporate_domains.txt
  - writes local state under ./state/<host> for future client management

  With --dry-run: validates env, files, every Outline URI, OpenVPN parsing,
  SSH reachability, passwordless sudo, remote port availability, and renders
  the mihomo template locally with a placeholder cert. If docker is present
  locally, runs `mihomo -t` against the rendered config as a smoke check.
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

# parse_ovpn <ovpn_path> <auth_file_or_empty> <output_json_path>
# Parses an OpenVPN config into a JSON document suitable for node["openvpn_corp"].
parse_ovpn() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

ovpn_path = Path(sys.argv[1])
auth_path = sys.argv[2]
output_path = sys.argv[3]

text = ovpn_path.read_text()
source_dir = ovpn_path.parent

server = None
port = None
proto = "udp"
cipher = None
auth_digest = None

# Extract simple directives line-by-line, ignoring lines inside inline blocks.
inline_block = None
inline_buffers = {}
for raw_line in text.splitlines():
    line = raw_line.rstrip()
    stripped = line.strip()
    if inline_block is not None:
        if stripped == f"</{inline_block}>":
            inline_block = None
            continue
        inline_buffers.setdefault(inline_block, []).append(raw_line)
        continue
    if not stripped or stripped.startswith("#") or stripped.startswith(";"):
        continue
    m = re.match(r"<([a-zA-Z0-9_-]+)>$", stripped)
    if m:
        inline_block = m.group(1)
        inline_buffers.setdefault(inline_block, [])
        continue
    try:
        parts = shlex.split(stripped)
    except ValueError:
        continue
    if not parts:
        continue
    key = parts[0]
    if key == "remote" and len(parts) >= 2:
        if server is None:
            server = parts[1]
            if len(parts) >= 3 and parts[2].isdigit():
                port = int(parts[2])
            if len(parts) >= 4 and parts[3] in ("udp", "tcp"):
                proto = parts[3]
    elif key == "port" and len(parts) >= 2 and parts[1].isdigit():
        if port is None:
            port = int(parts[1])
    elif key == "proto" and len(parts) >= 2:
        proto = parts[1]
        if proto.startswith("tcp"):
            proto = "tcp"
        elif proto.startswith("udp"):
            proto = "udp"
    elif key in ("cipher", "data-ciphers"):
        if len(parts) >= 2 and cipher is None:
            cipher = parts[1].split(":")[0]
    elif key == "auth" and len(parts) >= 2:
        auth_digest = parts[1]

if inline_block is not None:
    raise SystemExit(
        f"ovpn parse: unterminated <{inline_block}> block (no closing "
        f"</{inline_block}> tag). Silent truncation would have stored a "
        f"partial PEM in node.json."
    )

if server is None:
    raise SystemExit("ovpn parse: no 'remote' directive found")
if port is None:
    port = 1194

def read_inline_or_file(name):
    if name in inline_buffers:
        return "\n".join(inline_buffers[name]).strip() + "\n"
    # Try external file referenced via directive like `ca my-ca.crt`.
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue
        try:
            parts = shlex.split(stripped)
        except ValueError:
            continue
        if len(parts) >= 2 and parts[0] == name:
            candidate = Path(parts[1])
            if not candidate.is_absolute():
                candidate = source_dir / candidate
            if candidate.exists():
                return candidate.read_text()
    return None

ca_pem        = read_inline_or_file("ca")
tls_crypt_pem = read_inline_or_file("tls-crypt")
tls_auth_pem  = read_inline_or_file("tls-auth")
cert_pem      = read_inline_or_file("cert")
key_pem       = read_inline_or_file("key")

if ca_pem is None:
    raise SystemExit("ovpn parse: no <ca> block or 'ca' file directive found")

block = {
    "server": server,
    "port":   port,
    "proto":  proto,
    "ca_pem": ca_pem,
}
if tls_crypt_pem:
    block["tls_crypt_pem"] = tls_crypt_pem
elif tls_auth_pem:
    # mihomo's openvpn proxy accepts tls-crypt-style static keys via the same
    # field; downstream renderer will surface this verbatim.
    block["tls_crypt_pem"] = tls_auth_pem
if cert_pem and key_pem:
    block["cert_pem"] = cert_pem
    block["key_pem"]  = key_pem
if cipher:
    block["cipher"] = cipher
if auth_digest:
    block["auth"] = auth_digest

if auth_path:
    lines = Path(auth_path).read_text().splitlines()
    if len(lines) < 2:
        raise SystemExit("auth file must have at least 2 lines: username, password")
    block["username"] = lines[0].strip()
    block["password"] = lines[1].strip()

with open(output_path, "w") as fh:
    json.dump(block, fh, indent=2)
    fh.write("\n")
PY
}

# prepare_sidecar_conf <ovpn_path> <ips_txt> <output_conf> — produce a
# self-contained OpenVPN config for the openvpn-corp sidecar:
#   - inline any external ca/cert/key/tls-auth/tls-crypt files
#   - strip `auth-user-pass` (the sidecar supplies credentials via
#     --auth-user-pass <file>; a bare directive would be a fatal duplicate)
#   - append the corporate routes from config/ips.txt as `route` directives so
#     the declared corp subnets egress via the tunnel even if the server does
#     not push them. The sidecar is network-isolated, so (unlike the old
#     host-level client) it safely pulls server routes/DNS too — corp DNS from
#     the push is what resolves DOMAIN-SUFFIX corp rules inside the container.
prepare_sidecar_conf() {
  python3 - "$1" "$2" "$3" <<'PY'
import ipaddress, shlex, sys
from pathlib import Path

src = Path(sys.argv[1])
ips_txt = Path(sys.argv[2])
out = Path(sys.argv[3])
source_dir = src.parent
inline_directives = {"ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"}

lines_out = []
inline_block = None
for raw in src.read_text().splitlines():
    stripped = raw.strip()
    # Pass through (and track) existing inline <...> blocks verbatim.
    if inline_block is not None:
        lines_out.append(raw)
        if stripped == f"</{inline_block}>":
            inline_block = None
        continue
    if stripped.startswith("<") and stripped.endswith(">") and not stripped.startswith("</"):
        inline_block = stripped[1:-1]
        lines_out.append(raw)
        continue
    try:
        parts = shlex.split(stripped) if stripped else []
    except ValueError:
        parts = []
    key = parts[0] if parts else ""
    # Drop auth-user-pass; credentials come from the command line.
    if key == "auth-user-pass":
        continue
    # Inline an external file referenced by a directive with a path argument.
    if key in inline_directives and len(parts) >= 2:
        candidate = Path(parts[1])
        if not candidate.is_absolute():
            candidate = source_dir / candidate
        if candidate.exists():
            content = candidate.read_text().rstrip("\n")
            lines_out.append(f"<{key}>")
            lines_out.append(content)
            lines_out.append(f"</{key}>")
            continue
    lines_out.append(raw)

# Append corporate routes from ips.txt as explicit `route net mask` directives.
if ips_txt.exists():
    routes = []
    for lineno, raw in enumerate(ips_txt.read_text().splitlines(), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("route "):
            p = s.split()
            if len(p) == 3:
                net = ipaddress.ip_network(f"{p[1]}/{p[2]}", strict=False)
            elif len(p) == 2:
                net = ipaddress.ip_network(p[1], strict=False)
            else:
                raise SystemExit(f"{ips_txt}:{lineno}: unrecognized route form: {s!r}")
        elif "/" in s:
            net = ipaddress.ip_network(s, strict=False)
        else:
            raise SystemExit(f"{ips_txt}:{lineno}: expected 'route ...' or a CIDR, got {s!r}")
        routes.append(net)
    if routes:
        lines_out.append("")
        lines_out.append("# corporate routes (appended from config/ips.txt)")
        for net in routes:
            lines_out.append(f"route {net.network_address} {net.netmask}")

out.write_text("\n".join(lines_out) + "\n")
PY
}

# parse_outline_uri <uri> — prints JSON {"name","address","port","method","password"} for one URI.
parse_outline_uri() {
  python3 - "$1" "$2" <<'PY'
import base64
import json
import sys
from urllib.parse import urlparse, unquote

uri = sys.argv[1]
default_name = sys.argv[2]
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
method, password = decoded.split(":", 1)
port = parsed.port if parsed.port is not None else 8388
name = unquote(parsed.fragment) if parsed.fragment else default_name
print(json.dumps({
    "name":     name,
    "address":  parsed.hostname,
    "port":     port,
    "method":   method,
    "password": password,
}))
PY
}

HOST=""
SSH_USER="root"
SSH_PORT="22"
CORP_OVPN=""
AUTH_FILE=""
OUTLINE_URIS=()
LISTEN_PORT="443"
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
    --outline-uri) OUTLINE_URIS+=("$2"); shift 2 ;;
    --outline-uris|--outline-uris-csv)
      IFS=',' read -r -a _csv <<< "$2"
      for _u in "${_csv[@]}"; do
        _u="${_u## }"; _u="${_u%% }"
        [[ -n "${_u}" ]] && OUTLINE_URIS+=("${_u}")
      done
      shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --state-root) STATE_ROOT="$2"; shift 2 ;;
    --ssh-identity) SSH_IDENTITY="$2"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${HOST}" || -z "${CORP_OVPN}" || ${#OUTLINE_URIS[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

for cmd in ssh scp python3; do
  require_cmd "${cmd}"
done
if [[ "${DRY_RUN}" != "1" ]]; then
  require_cmd openssl
fi

for file in "${CORP_OVPN}" "${CONFIG_DIR}/ips.txt" "${SCRIPT_DIR}/remote_apply_node.sh" "${CONFIG_DIR}/mihomo_config.template.yaml" "${SCRIPT_DIR}/render_mihomo.py" "${SCRIPT_DIR}/render_mihomo_client.py" "${SIDECAR_BUILD_DIR}/Dockerfile" "${SIDECAR_BUILD_DIR}/entrypoint.sh"; do
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

ssh_opts=(-p "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
scp_opts=(-P "${SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_IDENTITY}" ]]; then
  ssh_opts+=(-i "${SSH_IDENTITY}")
  scp_opts+=(-i "${SSH_IDENTITY}")
fi

# remote_stage is allocated after preflight (see below) via ssh-side
# `mktemp -d` so the name is unpredictable (no $RANDOM collision risk on
# concurrent runs) and the dir is 0700 by default.
remote_stage=""

echo "[0/5] Preflight: verifying SSH and passwordless sudo on ${SSH_USER}@${HOST}:${SSH_PORT}"
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

# --- Dry-run path ------------------------------------------------------------
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "[dry-run] Validating ${#OUTLINE_URIS[@]} Outline URI(s)"
  outline_json_array="["
  first=1
  idx=0
  for uri in "${OUTLINE_URIS[@]}"; do
    idx=$((idx + 1))
    entry="$(parse_outline_uri "${uri}" "endpoint-${idx}")"
    echo "  ${entry}"
    if [[ "${first}" == "1" ]]; then
      outline_json_array+="${entry}"
      first=0
    else
      outline_json_array+=",${entry}"
    fi
  done
  outline_json_array+="]"

  echo "[dry-run] Parsing OpenVPN config ${CORP_OVPN}"
  parse_ovpn "${CORP_OVPN}" "${AUTH_FILE}" "${tmp_dir}/openvpn_corp.json"
  python3 - "${tmp_dir}/openvpn_corp.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
fields = [f"server={d['server']}", f"port={d['port']}", f"proto={d['proto']}"]
if "username" in d: fields.append(f"username={d['username']}")
if "cipher" in d:   fields.append(f"cipher={d['cipher']}")
if "auth" in d:     fields.append(f"auth={d['auth']}")
fields.append(f"ca_pem={'present' if d.get('ca_pem') else 'missing'}")
fields.append(f"tls_crypt={'present' if d.get('tls_crypt_pem') else 'missing'}")
fields.append(f"client_cert={'present' if d.get('cert_pem') else 'missing'}")
print("  " + ", ".join(fields))
PY

  echo "[dry-run] Enumerating OpenVPN external file dependencies"
  dep_count=0
  while IFS= read -r dep_file; do
    [[ -z "${dep_file}" ]] && continue
    echo "  dep: ${dep_file}"
    dep_count=$((dep_count + 1))
  done < <(list_ovpn_dependencies "${CORP_OVPN}")
  echo "  ${dep_count} external file(s) will be inlined into node.json locally"

  echo "[dry-run] Checking remote listen port ${LISTEN_PORT}/udp is free"
  port_in_use="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
    "ss -H -lun 'sport = :${LISTEN_PORT}' 2>/dev/null | wc -l" 2>/dev/null || echo 0)"
  if [[ "${port_in_use}" -gt 0 ]]; then
    echo "  WARNING: port ${LISTEN_PORT}/udp already has a listener on the VPS" >&2
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

  echo "[dry-run] Rendering mihomo config locally with placeholder hy2 cert"
  # Placeholder cert/key/fingerprint in dry-run: noted as fake.
  echo "[dry-run] (using placeholder hy2 cert/key/fingerprint; live run generates real ones via openssl)"
  fake_cert="-----BEGIN CERTIFICATE-----\nDRYRUN\n-----END CERTIFICATE-----\n"
  fake_key="-----BEGIN PRIVATE KEY-----\nDRYRUN\n-----END PRIVATE KEY-----\n"
  fake_fp="00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

  python3 - \
    "${HOST}" "${SSH_USER}" "${SSH_PORT}" "${INSTALL_DIR}" "${LISTEN_PORT}" \
    "${fake_cert}" "${fake_key}" "${fake_fp}" \
    "${outline_json_array}" "${tmp_dir}/openvpn_corp.json" "${tmp_dir}/fake-node.json" <<'PY'
import json, sys
(host, ssh_user, ssh_port, install_dir, listen_port,
 cert_pem, key_pem, fp,
 outline_json, ovpn_path, output) = sys.argv[1:]
outline = json.loads(outline_json)
ovpn    = json.load(open(ovpn_path))
node = {
    "host": host,
    "ssh_user": ssh_user,
    "ssh_port": int(ssh_port),
    "install_dir": install_dir,
    "listen_port": int(listen_port),
    "hysteria2": {
        "cert_pem": cert_pem,
        "key_pem":  key_pem,
        "cert_fingerprint_sha256": fp,
    },
    "outline": outline,
    "openvpn_corp": ovpn,
}
with open(output, "w") as fh:
    json.dump(node, fh, indent=2)
    fh.write("\n")
PY

  # Fake clients.json for dry-run.
  cat >"${tmp_dir}/fake-clients.json" <<EOF
[{"email": "${CLIENT_NAME}", "password": "dry-run-placeholder-password"}]
EOF

  corp_domains_arg="${CONFIG_DIR}/corporate_domains.txt"
  [[ ! -f "${corp_domains_arg}" ]] && corp_domains_arg=""

  python3 "${SCRIPT_DIR}/render_mihomo.py" \
    --template "${CONFIG_DIR}/mihomo_config.template.yaml" \
    --node "${tmp_dir}/fake-node.json" \
    --clients "${tmp_dir}/fake-clients.json" \
    --routes "${CONFIG_DIR}/ips.txt" \
    --corp-domains "${corp_domains_arg}" \
    --output "${tmp_dir}/rendered.yaml"

  # Validate output is parseable JSON (mihomo accepts JSON-in-YAML).
  python3 - "${tmp_dir}/rendered.yaml" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1]))
proxies = obj.get("proxies", [])
rules   = obj.get("rules", [])
listeners = obj.get("listeners", []) or obj.get("hysteria2", [])
print(f"  rendered JSON is valid ({len(proxies)} proxies, {len(rules)} rules)")
PY

  if command -v docker >/dev/null 2>&1; then
    echo "[dry-run] Running 'mihomo -t' locally via docker"
    mkdir -p "${tmp_dir}/mihomo-home"
    cp "${tmp_dir}/rendered.yaml" "${tmp_dir}/mihomo-home/config.yaml"
    # Mount read-write: GEOSITE/GEOIP rules make mihomo download the .dat files
    # into its working dir during -t (same as production deploy-config). A
    # read-only mount would fail rule validation on the geo download.
    if docker run --rm \
      -v "${tmp_dir}/mihomo-home:/root/.config/mihomo" \
      "${MIHOMO_IMAGE}" -t -d /root/.config/mihomo &>"${tmp_dir}/mihomo.out"; then
      echo "  mihomo -t: PASS"
    else
      echo "  mihomo -t: FAIL" >&2
      cat "${tmp_dir}/mihomo.out" >&2
      exit 1
    fi
  else
    echo "[dry-run] docker not found locally; skipping 'mihomo -t' (structural JSON check only)"
  fi

  existing_state="no"
  if [[ -f "${STATE_ROOT}/${HOST}/node.json" ]]; then
    existing_state="yes (hy2 cert + client passwords would be reused if present)"
  fi
  cat <<EOF

Dry run OK. Summary:
  host:            ${SSH_USER}@${HOST}:${SSH_PORT}
  listen port:     ${LISTEN_PORT}/udp (hysteria2)
  install dir:     ${INSTALL_DIR}
  state dir:       ${STATE_ROOT}/${HOST}
  existing state:  ${existing_state}
  ovpn:            ${CORP_OVPN}
  auth file:       ${AUTH_FILE:-<none>}
  outline endpoints: ${#OUTLINE_URIS[@]} (validated)
  bootstrap client: ${CLIENT_NAME}

No changes were made. Re-run without --dry-run to apply.
EOF
  exit 0
fi

# --- Live path ---------------------------------------------------------------
cleanup_remote() {
  [[ -z "${remote_stage}" ]] && return 0
  ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "rm -rf $(quote_sh "${remote_stage}")" >/dev/null 2>&1 || true
}
trap 'rc=$?; rm -rf "${tmp_dir}"; cleanup_remote; exit $rc' EXIT

# Allocate remote stage now (post-preflight, so SSH is known good). mktemp -d
# returns a 0700 dir with an unpredictable name — avoids $RANDOM collisions
# when two provision runs target the same VPS concurrently.
remote_stage="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "mktemp -d /tmp/tristate-relay-XXXXXXXX")"

echo "[1/5] Uploading bootstrap helper + openvpn-corp sidecar to ${SSH_USER}@${HOST}:${remote_stage}"
# The bootstrap helper, the sidecar build context, and the corporate OpenVPN
# bundle land on the VPS. mihomo routes corp traffic to the openvpn-corp
# sidecar's SOCKS5 proxy; the sidecar (a real openvpn client) holds the
# corporate tunnel. The hy2 cert, Outline endpoints, and routing rules are
# still rendered locally into the mihomo config.
scp "${scp_opts[@]}" "${SCRIPT_DIR}/remote_apply_node.sh" "${SSH_USER}@${HOST}:${remote_stage}/"
scp "${scp_opts[@]}" -r "${SIDECAR_BUILD_DIR}" "${SSH_USER}@${HOST}:${remote_stage}/openvpn-corp-build"

# Build the self-contained sidecar OpenVPN config (inline deps, no
# auth-user-pass) and stage it with the auth file.
prepare_sidecar_conf "${CORP_OVPN}" "${CONFIG_DIR}/ips.txt" "${tmp_dir}/corporate.conf"
if grep -q '^auth-user-pass' "${CORP_OVPN}" && [[ -z "${AUTH_FILE}" ]]; then
  echo "ERROR: ${CORP_OVPN} requires auth-user-pass but no --auth-file was given." >&2
  echo "The openvpn-corp sidecar needs a two-line user/pass file. Aborting." >&2
  exit 1
fi
if [[ -n "${AUTH_FILE}" ]]; then
  cp "${AUTH_FILE}" "${tmp_dir}/corporate.auth"
else
  : > "${tmp_dir}/corporate.auth"
fi
scp "${scp_opts[@]}" "${tmp_dir}/corporate.conf" "${tmp_dir}/corporate.auth" \
  "${SSH_USER}@${HOST}:${remote_stage}/"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "chmod 600 $(quote_sh "${remote_stage}/corporate.conf") $(quote_sh "${remote_stage}/corporate.auth")"

echo "[1/5] Generating hy2 self-signed EC P-256 cert/key locally"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 3650 -nodes -subj "/CN=tristate.local" \
  -keyout "${tmp_dir}/hy2.key" -out "${tmp_dir}/hy2.crt" >/dev/null 2>&1
hy2_fp="$(openssl x509 -in "${tmp_dir}/hy2.crt" -noout -fingerprint -sha256 \
  | sed 's/^.*=//; s/://g; s/\(..\)/\1:/g; s/:$//')"
echo "  fingerprint: ${hy2_fp}"

echo "[2/5] Bootstrapping the VPS"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "chmod +x $(quote_sh "${remote_stage}/remote_apply_node.sh") && sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") bootstrap \
    --install-dir $(quote_sh "${INSTALL_DIR}") \
    --ssh-port $(quote_sh "${SSH_PORT}") \
    --listen-port $(quote_sh "${LISTEN_PORT}")"

echo "[2/5] Building + starting the openvpn-corp sidecar (corporate tunnel)"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") deploy-sidecar \
    --install-dir $(quote_sh "${INSTALL_DIR}") \
    --build-context $(quote_sh "${remote_stage}/openvpn-corp-build") \
    --ovpn $(quote_sh "${remote_stage}/corporate.conf") \
    --auth $(quote_sh "${remote_stage}/corporate.auth")"

state_dir="${STATE_ROOT}/${HOST}"
mkdir -p "${state_dir}"

# Parse ovpn for the live node.json.
parse_ovpn "${CORP_OVPN}" "${AUTH_FILE}" "${tmp_dir}/openvpn_corp.json"

# Build outline JSON array.
outline_json_array="["
first=1
idx=0
for uri in "${OUTLINE_URIS[@]}"; do
  idx=$((idx + 1))
  entry="$(parse_outline_uri "${uri}" "endpoint-${idx}")"
  if [[ "${first}" == "1" ]]; then
    outline_json_array+="${entry}"
    first=0
  else
    outline_json_array+=",${entry}"
  fi
done
outline_json_array+="]"

echo "[3/5] Writing local state to ${state_dir}"
# Read the freshly-generated cert/key as text so they embed in node.json.
hy2_cert_pem="$(cat "${tmp_dir}/hy2.crt")"
hy2_key_pem="$(cat "${tmp_dir}/hy2.key")"
python3 - \
  "${HOST}" "${SSH_USER}" "${SSH_PORT}" "${INSTALL_DIR}" "${LISTEN_PORT}" \
  "${hy2_fp}" \
  "${outline_json_array}" "${tmp_dir}/openvpn_corp.json" \
  "${tmp_dir}/hy2.crt" "${tmp_dir}/hy2.key" \
  "${state_dir}/node.json" <<'PY'
import json, sys
(host, ssh_user, ssh_port, install_dir, listen_port,
 fp, outline_json, ovpn_path, cert_path, key_path, output) = sys.argv[1:]
outline = json.loads(outline_json)
ovpn    = json.load(open(ovpn_path))
cert_pem = open(cert_path).read()
key_pem  = open(key_path).read()
node = {
    "host": host,
    "ssh_user": ssh_user,
    "ssh_port": int(ssh_port),
    "install_dir": install_dir,
    "listen_port": int(listen_port),
    "hysteria2": {
        "cert_pem": cert_pem,
        "key_pem":  key_pem,
        "cert_fingerprint_sha256": fp,
    },
    "outline": outline,
    "openvpn_corp": ovpn,
}
with open(output, "w") as fh:
    json.dump(node, fh, indent=2)
    fh.write("\n")
PY
chmod 700 "${state_dir}"
chmod 600 "${state_dir}/node.json"

# Bootstrap client password (token_urlsafe(24)).
if [[ ! -f "${state_dir}/clients.json" ]]; then
  client_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  python3 - "${CLIENT_NAME}" "${client_password}" "${state_dir}/clients.json" <<'PY'
import json, sys
name, password, output = sys.argv[1:]
with open(output, "w") as fh:
    json.dump([{"email": name, "password": password}], fh, indent=2)
    fh.write("\n")
PY
fi
chmod 600 "${state_dir}/clients.json"

echo "[4/5] Rendering the mihomo config and deploying to the VPS"
corp_domains_arg="${CONFIG_DIR}/corporate_domains.txt"
[[ ! -f "${corp_domains_arg}" ]] && corp_domains_arg=""
python3 "${SCRIPT_DIR}/render_mihomo.py" \
  --template "${CONFIG_DIR}/mihomo_config.template.yaml" \
  --node "${state_dir}/node.json" \
  --clients "${state_dir}/clients.json" \
  --routes "${CONFIG_DIR}/ips.txt" \
  --corp-domains "${corp_domains_arg}" \
  --output "${tmp_dir}/config.yaml"

# Upload rendered config + cert + key.
scp "${scp_opts[@]}" \
  "${tmp_dir}/config.yaml" \
  "${tmp_dir}/hy2.crt" \
  "${tmp_dir}/hy2.key" \
  "${SSH_USER}@${HOST}:${remote_stage}/"
ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" "chmod 600 $(quote_sh "${remote_stage}/hy2.key")"

ssh "${ssh_opts[@]}" "${SSH_USER}@${HOST}" \
  "sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") deploy-config \
    --install-dir $(quote_sh "${INSTALL_DIR}") \
    --config $(quote_sh "${remote_stage}/config.yaml") \
    --cert $(quote_sh "${remote_stage}/hy2.crt") \
    --key $(quote_sh "${remote_stage}/hy2.key")"

echo "[5/5] Rendering the client mihomo config"
python3 "${SCRIPT_DIR}/render_mihomo_client.py" \
  --template "${CONFIG_DIR}/mihomo_client.template.yaml" \
  --node "${state_dir}/node.json" \
  --clients "${state_dir}/clients.json" \
  --name "${CLIENT_NAME}" \
  --output "${state_dir}/connection.yaml"
chmod 600 "${state_dir}/connection.yaml"

cat <<EOF

Provisioning finished.
- Local state:        ${state_dir}
- Client config:      ${state_dir}/connection.yaml
- hy2 fingerprint:    ${hy2_fp}

Hand the client config to the laptop user (it embeds the pinned cert
fingerprint, host, port, and client password — no separate URI).

Future changes:
- add/remove clients with ./scripts/manage_inbound.sh
- current clients live in ${state_dir}/clients.json
EOF
