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
  ./scripts/manage_inbound.sh --state-dir ./state/<host> print-config NAME
  ./scripts/manage_inbound.sh --state-dir ./state/<host> print-uri NAME      # deprecated alias

This script renders mihomo (not Xray) configs. The server runs mihomo with a
Hysteria2 inbound; the printed client config is a mihomo-compatible YAML
(JSON-content) suitable for Clash Verge Rev, Hiddify, ClashMi, and similar
clients.

Flags:
  --ssh-identity PATH   SSH private key to use for deploy
  --dry-run             Render the new config locally and show a diff vs the
                        currently deployed rendered-config.yaml. No state file
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

for file in "${STATE_DIR}/node.json" "${STATE_DIR}/clients.json" "${CONFIG_DIR}/ips.txt" "${CONFIG_DIR}/mihomo_config.template.yaml" "${CONFIG_DIR}/mihomo_client.template.yaml" "${SCRIPT_DIR}/remote_apply_node.sh" "${SCRIPT_DIR}/render_mihomo.py" "${SCRIPT_DIR}/render_mihomo_client.py"; do
  if [[ ! -f "${file}" ]]; then
    echo "Required file not found: ${file}" >&2
    exit 1
  fi
done

REAL_STATE_DIR="${STATE_DIR}"
sandbox_dir=""
cert_tmp=""
key_tmp=""
remote_stage=""
remote_stage_ssh=()
cleanup_temp() {
  [[ -n "${sandbox_dir}" ]] && rm -rf "${sandbox_dir}"
  [[ -n "${cert_tmp}" ]] && rm -f "${cert_tmp}"
  [[ -n "${key_tmp}" ]] && rm -f "${key_tmp}"
  # Remote stage holds the hy2 key + ovpn-bearing rendered config. Always
  # purge it, including on set -e mid-deploy failures.
  if [[ -n "${remote_stage}" && ${#remote_stage_ssh[@]} -gt 0 ]]; then
    ssh "${remote_stage_ssh[@]}" "rm -rf $(printf '%q' "${remote_stage}")" 2>/dev/null || true
  fi
}
trap cleanup_temp EXIT

if [[ "${DRY_RUN}" == "1" ]]; then
  sandbox_dir="$(mktemp -d)"
  cp "${STATE_DIR}/node.json" "${sandbox_dir}/node.json"
  cp "${STATE_DIR}/clients.json" "${sandbox_dir}/clients.json"
  STATE_DIR="${sandbox_dir}"
fi

command="$1"
shift

render_config() {
  local corp_domains="${CONFIG_DIR}/corporate_domains.txt"
  [[ ! -f "${corp_domains}" ]] && corp_domains=""
  python3 "${SCRIPT_DIR}/render_mihomo.py" \
    --template "${CONFIG_DIR}/mihomo_config.template.yaml" \
    --node     "${STATE_DIR}/node.json" \
    --clients  "${STATE_DIR}/clients.json" \
    --routes   "${CONFIG_DIR}/ips.txt" \
    --corp-domains "${corp_domains}" \
    --output   "${STATE_DIR}/rendered-config.yaml"
  chmod 600 "${STATE_DIR}/rendered-config.yaml"
}

deploy_remote() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    local current="${REAL_STATE_DIR}/rendered-config.yaml"
    local proposed="${STATE_DIR}/rendered-config.yaml"
    echo "[dry-run] Proposed rendered-config.yaml written to: ${proposed}"
    if [[ -f "${current}" ]]; then
      echo "[dry-run] Diff vs current (${current}):"
      if diff -u "${current}" "${proposed}" >/dev/null 2>&1; then
        echo "  (no changes)"
      else
        diff -u "${current}" "${proposed}" || true
      fi
    else
      echo "[dry-run] No existing rendered-config.yaml at ${current}; this would be the first deploy."
    fi
    echo "[dry-run] No state was written to ${REAL_STATE_DIR} and nothing was uploaded."
    return 0
  fi

  local host user ssh_port install_dir
  host="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host"])' "${STATE_DIR}/node.json")"
  user="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_user"])' "${STATE_DIR}/node.json")"
  ssh_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh_port"])' "${STATE_DIR}/node.json")"
  install_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["install_dir"])' "${STATE_DIR}/node.json")"

  local ssh_opts=(-p "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  local scp_opts=(-P "${ssh_port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  if [[ -n "${SSH_IDENTITY}" ]]; then
    ssh_opts+=(-i "${SSH_IDENTITY}")
    scp_opts+=(-i "${SSH_IDENTITY}")
  fi

  # Extract cert + key from node.json into temp files with strict perms.
  # cert_tmp / key_tmp are script-scoped (declared near the top-level EXIT
  # trap), so they're cleaned up on any exit path — including set -e on
  # an ssh/scp failure inside this function.
  cert_tmp="$(mktemp)" || exit 1
  key_tmp="$(mktemp)"  || exit 1
  chmod 600 "${cert_tmp}" "${key_tmp}"
  python3 - "${STATE_DIR}/node.json" "${cert_tmp}" "${key_tmp}" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(node["hysteria2"]["cert_pem"])
open(sys.argv[3], "w").write(node["hysteria2"]["key_pem"])
PY

  local cert_base key_base
  cert_base="$(basename "${cert_tmp}")"
  key_base="$(basename "${key_tmp}")"

  # mktemp -d returns a 0700 dir; remote_stage + remote_stage_ssh are
  # script-scoped so the EXIT trap purges /tmp/tristate-manage-* even when
  # deploy-config fails. Replaces the earlier $RANDOM-based name which was
  # both predictable (collision risk) and leak-prone on error.
  remote_stage_ssh=("${ssh_opts[@]}" "${user}@${host}")
  remote_stage="$(ssh "${ssh_opts[@]}" "${user}@${host}" "mktemp -d /tmp/tristate-manage-XXXXXXXX")"
  scp "${scp_opts[@]}" \
    "${SCRIPT_DIR}/remote_apply_node.sh" \
    "${STATE_DIR}/rendered-config.yaml" \
    "${cert_tmp}" \
    "${key_tmp}" \
    "${user}@${host}:${remote_stage}/"
  # SCP may not preserve source perms; harden the private key on the remote.
  ssh "${ssh_opts[@]}" "${user}@${host}" \
    "chmod 600 $(quote_sh "${remote_stage}/${key_base}") && chmod 644 $(quote_sh "${remote_stage}/${cert_base}")"
  ssh "${ssh_opts[@]}" "${user}@${host}" \
    "chmod +x $(quote_sh "${remote_stage}/remote_apply_node.sh") && sudo $(quote_sh "${remote_stage}/remote_apply_node.sh") deploy-config \
      --install-dir $(quote_sh "${install_dir}") \
      --config $(quote_sh "${remote_stage}/rendered-config.yaml") \
      --cert   $(quote_sh "${remote_stage}/${cert_base}") \
      --key    $(quote_sh "${remote_stage}/${key_base}")"
}

print_client_config() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  chmod 600 "${tmp}"
  python3 "${SCRIPT_DIR}/render_mihomo_client.py" \
    --template "${CONFIG_DIR}/mihomo_client.template.yaml" \
    --node     "${STATE_DIR}/node.json" \
    --clients  "${STATE_DIR}/clients.json" \
    --name     "${name}" \
    --output   "${tmp}"
  cat "${tmp}"
  rm -f "${tmp}"
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
    password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    python3 - "${STATE_DIR}/clients.json" "${name}" "${password}" <<'PY'
import json, sys
path, name, pw = sys.argv[1:]
clients = json.load(open(path))
if any(c["email"] == name for c in clients):
    raise SystemExit(f"client exists: {name}")
clients.append({"email": name, "password": pw})
with open(path, "w") as handle:
    json.dump(clients, handle, indent=2)
    handle.write("\n")
PY
    chmod 600 "${STATE_DIR}/clients.json"
    render_config
    deploy_remote
    print_client_config "${name}"
    ;;
  remove-client)
    if [[ $# -ne 1 ]]; then
      echo "remove-client requires NAME" >&2
      exit 1
    fi
    name="$1"
    python3 - "${STATE_DIR}/clients.json" "${name}" <<'PY'
import json, sys
path, name = sys.argv[1:]
clients = json.load(open(path))
remaining = [c for c in clients if c["email"] != name]
if len(remaining) == len(clients):
    raise SystemExit(f"client not found: {name}")
with open(path, "w") as handle:
    json.dump(remaining, handle, indent=2)
    handle.write("\n")
PY
    chmod 600 "${STATE_DIR}/clients.json"
    render_config
    deploy_remote
    ;;
  rotate-client)
    if [[ $# -ne 1 ]]; then
      echo "rotate-client requires NAME" >&2
      exit 1
    fi
    name="$1"
    password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    python3 - "${STATE_DIR}/clients.json" "${name}" "${password}" <<'PY'
import json, sys
path, name, pw = sys.argv[1:]
clients = json.load(open(path))
for c in clients:
    if c["email"] == name:
        c["password"] = pw
        break
else:
    raise SystemExit(f"client not found: {name}")
with open(path, "w") as handle:
    json.dump(clients, handle, indent=2)
    handle.write("\n")
PY
    chmod 600 "${STATE_DIR}/clients.json"
    render_config
    deploy_remote
    print_client_config "${name}"
    ;;
  set-port)
    if [[ $# -ne 1 ]]; then
      echo "set-port requires PORT" >&2
      exit 1
    fi
    port="$1"
    python3 - "${STATE_DIR}/node.json" "${port}" <<'PY'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
node = json.load(open(path))
node["listen_port"] = port
with open(path, "w") as handle:
    json.dump(node, handle, indent=2)
    handle.write("\n")
PY
    chmod 600 "${STATE_DIR}/node.json"
    render_config
    deploy_remote
    ;;
  print-uri|print-config)
    if [[ $# -ne 1 ]]; then
      echo "${command} requires NAME" >&2
      exit 1
    fi
    if [[ "${command}" == "print-uri" ]]; then
      echo "warning: 'print-uri' is deprecated; use 'print-config'. The server now runs mihomo+hysteria2, so old URI-style credentials no longer apply." >&2
    fi
    print_client_config "$1"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
