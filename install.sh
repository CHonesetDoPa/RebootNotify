#!/usr/bin/env bash

set -euo pipefail

PROGRAM_NAME="RebootNotify"
SERVICE_NAME="rebootnotify"
SUPERVISOR_CONF="/etc/supervisor/conf.d/${SERVICE_NAME}.conf"
INSTALL_DIR="${INSTALL_DIR:-/opt/RebootNotify}"
BIN_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
CONFIG_PATH="${INSTALL_DIR}/config.yaml"
REMOTE_CONFIG_TEMPLATE_URL="${REMOTE_CONFIG_TEMPLATE_URL:-https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/config.example.yaml}"

GITHUB_REPO="${GITHUB_REPO:-CHonesetDoPa/RebootNotify}"
VERSION="${VERSION:-latest}"
TOKEN="${TOKEN:-YOUR_BOT_TOKEN}"
CHAT_ID="${CHAT_ID:-YOUR_CHAT_ID}"
PROXY_ENABLED="${PROXY_ENABLED:-false}"
PROXY_SERVER="${PROXY_SERVER:-http://127.0.0.1:7890}"
REBOOT_FILE="${REBOOT_FILE:-/var/run/reboot-required}"
REBOOT_INTERVAL="${REBOOT_INTERVAL:-3600}"
INITIAL_DELAY="${INITIAL_DELAY:-0}"
UPGRADE_ENABLED="${UPGRADE_ENABLED:-true}"
UPGRADE_INTERVAL="${UPGRADE_INTERVAL:-86400}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NONE='\033[0m'

log_info() {
  echo -e "${COLOR_GREEN}[INFO]${COLOR_NONE} $*"
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_NONE} $*"
}

log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_NONE} $*" >&2
}

usage() {
  cat <<EOF
Usage:
  bash install.sh install [options]
  bash install.sh uninstall [options]

Commands:
  install      Install supervisor, deploy binary and enable service (default)
  uninstall    Remove deployed files, supervisor config and uninstall supervisor

Options:
  --repo <owner/repo>     GitHub repo, e.g. CHonesetDoPa/RebootNotify
  --version <tag|latest>  Release tag (default: latest)
  --install-dir <path>    Install directory (default: /opt/RebootNotify)
  --token <token>         Telegram bot token for generated config.yaml
  --chat-id <id>          Telegram chat id for generated config.yaml
  -h, --help              Show this help

Environment variables (optional):
  GITHUB_REPO, VERSION, INSTALL_DIR, TOKEN, CHAT_ID,
  PROXY_ENABLED, PROXY_SERVER, REBOOT_FILE, REBOOT_INTERVAL,
  INITIAL_DELAY, UPGRADE_ENABLED, UPGRADE_INTERVAL,
  REMOTE_CONFIG_TEMPLATE_URL

Config template source:
  REMOTE_CONFIG_TEMPLATE_URL only (default points to GitHub raw config.example.yaml)

Note:
  Prompts read from /dev/tty, so curl|bash installation is still interactive.

Examples:
  bash install.sh install --repo CHonesetDoPa/RebootNotify
  bash install.sh uninstall
  curl -fsSL https://example.com/install.sh | bash -s -- install --repo CHonesetDoPa/RebootNotify
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Please run as root (or with sudo)."
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y supervisor curl ca-certificates

  if has_cmd systemctl; then
    systemctl enable --now supervisor
  else
    service supervisor start
  fi
}

detect_arch() {
  local machine
  machine="$(uname -m)"

  case "${machine}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      log_error "Unsupported architecture: ${machine}. Supported: amd64, arm64"
      exit 1
      ;;
  esac
}

build_download_url() {
  local repo="$1"
  local version="$2"
  local asset="$3"

  if [[ "${version}" == "latest" ]]; then
    echo "https://github.com/${repo}/releases/latest/download/${asset}"
  else
    echo "https://github.com/${repo}/releases/download/${version}/${asset}"
  fi
}

trim_quotes() {
  local v="$1"
  if [[ "${v}" =~ ^\"(.*)\"$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${v}" =~ ^\'(.*)\'$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo "${v}"
}

normalize_bool() {
  local v="${1,,}"
  case "${v}" in
    true|false)
      echo "${v}"
      return 0
      ;;
    y|yes|1)
      echo "true"
      return 0
      ;;
    n|no|0)
      echo "false"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

get_env_for_path() {
  local path="$1"
  local generic
  generic="$(echo "${path}" | tr '[:lower:].' '[:upper:]_')"

  if [[ -n "${!generic-}" ]]; then
    echo "${!generic}"
    return
  fi

  case "${path}" in
    telegram.token)
      echo "${TOKEN}"
      ;;
    telegram.chat_id)
      echo "${CHAT_ID}"
      ;;
    proxy.enabled)
      echo "${PROXY_ENABLED}"
      ;;
    proxy.server)
      echo "${PROXY_SERVER}"
      ;;
    reboot_file)
      echo "${REBOOT_FILE}"
      ;;
    reboot_interval)
      echo "${REBOOT_INTERVAL}"
      ;;
    initial_delay)
      echo "${INITIAL_DELAY}"
      ;;
    upgrade_check.enabled)
      echo "${UPGRADE_ENABLED}"
      ;;
    upgrade_check.interval)
      echo "${UPGRADE_INTERVAL}"
      ;;
    *)
      echo ""
      ;;
  esac
}

detect_value_type() {
  local raw="$1"
  if [[ "${raw}" =~ ^(true|false)$ ]]; then
    echo "bool"
  elif [[ "${raw}" =~ ^-?[0-9]+$ ]]; then
    echo "int"
  else
    echo "string"
  fi
}

ask_config_value() {
  local path="$1"
  local raw_default="$2"
  local detected_type
  local default_value
  local env_value
  local final_value
  local input

  default_value="$(trim_quotes "${raw_default}")"
  detected_type="$(detect_value_type "${default_value}")"
  env_value="$(get_env_for_path "${path}")"

  if [[ -n "${env_value}" ]]; then
    default_value="${env_value}"
  fi

  if [[ -r /dev/tty ]]; then
    while true; do
      read -r -p "Config ${path} [${default_value}]: " input </dev/tty
      if [[ -z "${input}" ]]; then
        input="${default_value}"
      fi

      case "${detected_type}" in
        bool)
          if final_value="$(normalize_bool "${input}")"; then
            echo "${final_value}"
            return 0
          fi
          echo "Please input true/false (or yes/no)." >&2
          ;;
        int)
          if [[ "${input}" =~ ^-?[0-9]+$ ]]; then
            echo "${input}"
            return 0
          fi
          echo "Please input an integer." >&2
          ;;
        *)
          echo "${input}"
          return 0
          ;;
      esac
    done
  fi

  case "${detected_type}" in
    bool)
      if final_value="$(normalize_bool "${default_value}")"; then
        echo "${final_value}"
        return 0
      fi
      echo "false"
      ;;
    int)
      if [[ "${default_value}" =~ ^-?[0-9]+$ ]]; then
        echo "${default_value}"
      else
        echo "0"
      fi
      ;;
    *)
      echo "${default_value}"
      ;;
  esac
}

resolve_template_config() {
  local remote_template

  remote_template="$(mktemp)"
  if curl -fsSL --retry 3 --connect-timeout 10 "${REMOTE_CONFIG_TEMPLATE_URL}" -o "${remote_template}"; then
    echo "${remote_template}"
    return 0
  fi
  rm -f "${remote_template}"
  return 1
}

write_config_from_example() {
  local template_file
  local work_template
  local output_file
  local line
  local indent
  local key
  local value
  local level
  local path
  local prompted
  local value_type
  local escaped

  mkdir -p "${INSTALL_DIR}"
  output_file="${CONFIG_PATH}"

  if template_file="$(resolve_template_config)"; then
    work_template="${template_file}"
    log_info "Using remote template: ${REMOTE_CONFIG_TEMPLATE_URL}"
  else
    log_error "Failed to download config template from: ${REMOTE_CONFIG_TEMPLATE_URL}"
    exit 1
  fi

  local -a path_stack=()

  : >"${output_file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^([[:space:]]*)([a-zA-Z0-9_]+):[[:space:]]*(.*)$ ]]; then
      indent="${BASH_REMATCH[1]}"
      key="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
      level=$(( ${#indent} / 2 ))

      if [[ -z "${value}" || "${value}" =~ ^# ]]; then
        path_stack[level]="${key}"
        unset 'path_stack[@]:$((level + 1))'
        echo "${line}" >>"${output_file}"
        continue
      fi

      path=""
      if (( level > 0 )); then
        local i
        for ((i = 0; i < level; i++)); do
          if [[ -n "${path_stack[i]:-}" ]]; then
            if [[ -n "${path}" ]]; then
              path+="."
            fi
            path+="${path_stack[i]}"
          fi
        done
        if [[ -n "${path}" ]]; then
          path+="."
        fi
      fi
      path+="${key}"

      prompted="$(ask_config_value "${path}" "${value}")"
      value_type="$(detect_value_type "$(trim_quotes "${value}")")"

      if [[ "${value_type}" == "string" ]]; then
        escaped="${prompted//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        echo "${indent}${key}: \"${escaped}\"" >>"${output_file}"
      else
        echo "${indent}${key}: ${prompted}" >>"${output_file}"
      fi
    else
      echo "${line}" >>"${output_file}"
    fi
  done <"${work_template}"

  if [[ "${work_template}" == /tmp/* ]]; then
    rm -f "${work_template}"
  fi
}

write_supervisor_conf() {
  cat >"${SUPERVISOR_CONF}" <<EOF
[program:${SERVICE_NAME}]
command=${BIN_PATH}
directory=${INSTALL_DIR}
user=root
autostart=true
autorestart=true
startsecs=3
startretries=3
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/${SERVICE_NAME}.out.log
stderr_logfile=/var/log/${SERVICE_NAME}.err.log
environment=HOME="/root",PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
}

reload_and_start_supervisor() {
  supervisorctl reread
  supervisorctl update
  supervisorctl restart "${SERVICE_NAME}" || supervisorctl start "${SERVICE_NAME}"
  supervisorctl status "${SERVICE_NAME}" || true
}

download_binary() {
  local repo="$1"
  local version="$2"
  local arch="$3"
  local asset="${PROGRAM_NAME}-linux-${arch}"
  local url

  url="$(build_download_url "${repo}" "${version}" "${asset}")"
  log_info "Downloading ${asset} from ${url}"

  mkdir -p "${INSTALL_DIR}"
  curl -fsSL --retry 3 --connect-timeout 10 "${url}" -o "${BIN_PATH}"
  chmod +x "${BIN_PATH}"
}

do_install() {
  local arch

  require_root
  ensure_dependencies

  arch="$(detect_arch)"
  download_binary "${GITHUB_REPO}" "${VERSION}" "${arch}"
  write_config_from_example
  write_supervisor_conf
  reload_and_start_supervisor

  log_info "Install completed."
  log_info "Binary: ${BIN_PATH}"
  log_info "Config: ${CONFIG_PATH}"
  log_warn "Please edit ${CONFIG_PATH} with your real Telegram token/chat_id if still placeholders."
}

do_uninstall() {
  require_root

  if has_cmd supervisorctl; then
    supervisorctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    supervisorctl remove "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  rm -f "${SUPERVISOR_CONF}"
  rm -rf "${INSTALL_DIR}"

  if has_cmd supervisorctl; then
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y --purge supervisor || true
  apt-get autoremove -y || true

  log_info "Uninstall completed."
}

MODE="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall)
      MODE="$1"
      shift
      ;;
    --repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      BIN_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
      CONFIG_PATH="${INSTALL_DIR}/config.yaml"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --chat-id)
      CHAT_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "${MODE}" == "install" ]]; then
  do_install
else
  do_uninstall
fi
