#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="vpsmanager"
BIN_NAME="vpsmanager"
BINARY_URL="https://raw.githubusercontent.com/idbaremetal/VPS-Manager/refs/heads/main/vpsmanager"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_DIR="/etc/vpsmanager"
APP_SETTINGS_PATH="${CONFIG_DIR}/app-settings.json"
PRIVATE_IP_PATH="${CONFIG_DIR}/private-ip-allocations.json"
NAT_RULES_PATH="${CONFIG_DIR}/nat-rules.json"
VM_TEMPLATE_STATE_PATH="${CONFIG_DIR}/vm-template-state.json"
WORK_DIR="/var/lib/vpsmanager"

TTY_DEVICE=""
if [[ -r /dev/tty ]]; then
  TTY_DEVICE="/dev/tty"
fi

DEFAULT_SERVER_HOST="0.0.0.0"
DEFAULT_SERVER_PORT="8005"
DEFAULT_NAT_PORT_START="10000"
DEFAULT_NAT_PORT_END="30000"
DEFAULT_BRIDGE_NAME="vmbr1"
DEFAULT_PRIVATE_GATEWAY="10.0.0.1"
DEFAULT_SUBNET_PREFIX="22"
DEFAULT_IP_START="10.0.1.1"
DEFAULT_IP_END="10.0.3.254"
DEFAULT_STORAGE_NAME="local"
DEFAULT_STORAGE_TYPE="file_system"
DEFAULT_LXC_TEMPLATE_STORAGE="local"
DEFAULT_VM_TEMPLATE_DIRECTORY="/var/lib/vz/template/iso"
NETWORK_INTERFACES_PATH="/etc/network/interfaces"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Jalankan script ini sebagai root. Contoh: sudo bash Install.sh"
  fi
}

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

random_token() {
  if command_exists openssl; then
    openssl rand -hex 24
    return
  fi

  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

detect_node_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'pve'
}

detect_public_ip() {
  local detected=""

  if command_exists ip; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  fi

  if [[ -z "${detected}" ]] && command_exists hostname; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s' "${detected}"
}

backup_if_exists() {
  local file_path="$1"

  if [[ -f "${file_path}" ]]; then
    local backup_path="${file_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "${file_path}" "${backup_path}"
    log "Backup dibuat: ${backup_path}"
  fi
}

install_dependencies() {
  if command_exists apt-get; then
    log "Menginstall dependency sistem yang dibutuhkan..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates aria2 ifupdown2
  else
    warn "apt-get tidak ditemukan. Pastikan curl, systemd, aria2, ifupdown2, iptables, dan Proxmox CLI sudah tersedia."
  fi
}

download_binary() {
  command_exists curl || fail "curl tidak ditemukan."

  log "Mendownload binary ${BIN_NAME}..."
  local tmp_file
  tmp_file="$(mktemp)"

  curl -fsSL "${BINARY_URL}" -o "${tmp_file}"
  install -m 0755 "${tmp_file}" "${BIN_PATH}"
  rm -f "${tmp_file}"

  log "Binary terpasang di ${BIN_PATH}"
}

write_file_if_missing() {
  local file_path="$1"
  local content="$2"

  if [[ ! -f "${file_path}" ]]; then
    printf '%s' "${content}" >"${file_path}"
    log "Membuat ${file_path}"
  fi
}

ensure_network_interfaces_file() {
  if [[ ! -f "${NETWORK_INTERFACES_PATH}" ]]; then
    cat >"${NETWORK_INTERFACES_PATH}" <<'EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF
    log "Membuat ${NETWORK_INTERFACES_PATH}"
  fi
}

ensure_bridge() {
  ensure_network_interfaces_file

  if grep -Eq "^[[:space:]]*iface[[:space:]]+${DEFAULT_BRIDGE_NAME}[[:space:]]+inet[[:space:]]+manual([[:space:]]|$)" "${NETWORK_INTERFACES_PATH}"; then
    log "Bridge ${DEFAULT_BRIDGE_NAME} sudah ada di ${NETWORK_INTERFACES_PATH}"
  else
    backup_if_exists "${NETWORK_INTERFACES_PATH}"
    cat >>"${NETWORK_INTERFACES_PATH}" <<EOF

auto ${DEFAULT_BRIDGE_NAME}
iface ${DEFAULT_BRIDGE_NAME} inet manual
        bridge_ports none
        bridge_stp off
        bridge_fd 0
EOF
    log "Bridge ${DEFAULT_BRIDGE_NAME} ditambahkan ke ${NETWORK_INTERFACES_PATH}"
  fi

  if command_exists ifreload; then
    ifreload -a
    log "Konfigurasi network di-apply dengan ifreload -a"
  else
    warn "ifreload tidak ditemukan. Pastikan ifupdown2 terinstall lalu jalankan ifreload -a secara manual."
  fi
}

onboard_config() {
  mkdir -p "${CONFIG_DIR}" "${WORK_DIR}"
  chmod 0755 "${CONFIG_DIR}" "${WORK_DIR}"

  log "Menulis konfigurasi default ${APP_SETTINGS_PATH}..."

  local default_token
  local default_node_name
  local default_public_ip
  default_token="$(random_token)"
  default_node_name="$(detect_node_name)"
  default_public_ip="$(detect_public_ip)"

  backup_if_exists "${APP_SETTINGS_PATH}"

  cat >"${APP_SETTINGS_PATH}" <<EOF
{
  "management_api": {
    "token": "$(json_escape "${default_token}")",
    "node_name": "$(json_escape "${default_node_name}")"
  },
  "server": {
    "host": "$(json_escape "${DEFAULT_SERVER_HOST}")",
    "port": ${DEFAULT_SERVER_PORT}
  },
  "nat_public_network": {
    "public_ip": "$(json_escape "${default_public_ip}")",
    "port_start": ${DEFAULT_NAT_PORT_START},
    "port_end": ${DEFAULT_NAT_PORT_END}
  },
  "private_network_pool": {
    "bridge_name": "$(json_escape "${DEFAULT_BRIDGE_NAME}")",
    "private_gateway": "$(json_escape "${DEFAULT_PRIVATE_GATEWAY}")",
    "subnet_prefix": ${DEFAULT_SUBNET_PREFIX},
    "ip_start": "$(json_escape "${DEFAULT_IP_START}")",
    "ip_end": "$(json_escape "${DEFAULT_IP_END}")"
  },
  "default_storage": {
    "storage_name": "$(json_escape "${DEFAULT_STORAGE_NAME}")",
    "storage_type": "$(json_escape "${DEFAULT_STORAGE_TYPE}")",
    "lxc_template_storage": "$(json_escape "${DEFAULT_LXC_TEMPLATE_STORAGE}")",
    "vm_template_directory_path": "$(json_escape "${DEFAULT_VM_TEMPLATE_DIRECTORY}")"
  }
}
EOF

  chmod 0600 "${APP_SETTINGS_PATH}"
  log "Konfigurasi utama dibuat di ${APP_SETTINGS_PATH}"

  write_file_if_missing "${PRIVATE_IP_PATH}" $'{\n  "allocations": []\n}\n'
  write_file_if_missing "${NAT_RULES_PATH}" $'{\n  "rules": []\n}\n'
  write_file_if_missing "${VM_TEMPLATE_STATE_PATH}" $'{\n  "items": {}\n}\n'

  chmod 0644 "${PRIVATE_IP_PATH}" "${NAT_RULES_PATH}" "${VM_TEMPLATE_STATE_PATH}"
}

install_systemd_service() {
  log "Membuat systemd unit ${SERVICE_NAME}.service..."

  cat >"${SERVICE_PATH}" <<EOF
[Unit]
Description=VPS Manager API Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${SERVICE_PATH}"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
}

health_check() {
  local port="8080"

  if [[ -f "${APP_SETTINGS_PATH}" ]]; then
    local parsed_port
    parsed_port="$(sed -n 's/.*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${APP_SETTINGS_PATH}" | head -n 1)"
    if [[ -n "${parsed_port}" ]]; then
      port="${parsed_port}"
    fi
  fi

  if command_exists curl; then
    if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      log "Health check sukses di http://127.0.0.1:${port}/healthz"
      return
    fi
  fi

  warn "Health check belum sukses. Cek dengan: systemctl status ${SERVICE_NAME} dan journalctl -u ${SERVICE_NAME} -n 100"
}

print_summary() {
  local port="8080"
  local token=""
  local public_ip=""

  if [[ -f "${APP_SETTINGS_PATH}" ]]; then
    local parsed_port
    parsed_port="$(sed -n 's/.*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${APP_SETTINGS_PATH}" | head -n 1)"
    if [[ -n "${parsed_port}" ]]; then
      port="${parsed_port}"
    fi

    token="$(sed -n 's/.*"token":[[:space:]]*"\([^"]*\)".*/\1/p' "${APP_SETTINGS_PATH}" | head -n 1)"
    public_ip="$(sed -n 's/.*"public_ip":[[:space:]]*"\([^"]*\)".*/\1/p' "${APP_SETTINGS_PATH}" | head -n 1)"
  fi

  if [[ -z "${public_ip}" ]]; then
    public_ip="$(detect_public_ip)"
  fi

  if [[ -z "${public_ip}" ]]; then
    public_ip="127.0.0.1"
  fi

  printf '\n'
  printf 'Install selesai.\n'
  printf 'Binary  : %s\n' "${BIN_PATH}"
  printf 'Service : %s\n' "${SERVICE_NAME}.service"
  printf 'Config  : %s\n' "${APP_SETTINGS_PATH}"
  printf 'Docs    : http://%s:%s/docs\n' "${public_ip}" "${port}"
  printf 'Health  : http://%s:%s/healthz\n' "${public_ip}" "${port}"
  if [[ -n "${token}" ]]; then
    printf 'Token   : %s\n' "${token}"
  fi
  printf '\n'
  printf 'Perintah penting:\n'
  printf '  systemctl status %s\n' "${SERVICE_NAME}"
  printf '  journalctl -u %s -f\n' "${SERVICE_NAME}"
  printf '  systemctl restart %s\n' "${SERVICE_NAME}"
}

main() {
  require_root
  install_dependencies
  ensure_bridge
  download_binary
  onboard_config
  install_systemd_service
  health_check
  print_summary
}

main "$@"
