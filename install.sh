#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PROGRAM_NAME="RebootNotify"
SERVICE_NAME="rebootnotify"
INSTALL_DIR="/opt/RebootNotify"
BIN_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
CONFIG_PATH="${INSTALL_DIR}/config.yaml"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_REPO="CHonesetDoPa/RebootNotify"
VERSION="latest"
CONTROLLER_URL=""
CONTROLLER_TOKEN=""
CONTROLLER_INTERVAL="60"
PROXY_ENABLED="false"
PROXY_SERVER="http://127.0.0.1:7890"
REBOOT_FILE="/var/run/reboot-required"
REBOOT_INTERVAL="3600"
INITIAL_DELAY="0"
UPGRADE_ENABLED="true"
UPGRADE_INTERVAL="86400"
AGENT_ID=""

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_NONE='\033[0m'

log_info() {
  echo -e "${COLOR_GREEN}[INFO]${COLOR_NONE} $*" >&2
}

log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_NONE} $*" >&2
}

log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_NONE} $*" >&2
}

usage() {
  cat <<EOF
用法:
  bash install.sh install [选项]
  bash install.sh upgrade [选项]
  bash install.sh status
  bash install.sh uninstall

命令:
  install      首次安装或重新配置 Agent（默认）
  upgrade      下载新版本并保留现有配置、Agent ID
  status       查看 Agent 服务状态和配置摘要
  uninstall    停止并卸载 Agent（默认保留配置备份）

选项:
  --repo <owner/repo>          GitHub 仓库，例如 CHonesetDoPa/RebootNotify
  --version <tag|latest>       发布版本或 latest（默认: latest）
  --install-dir <path>         安装目录（默认: /opt/RebootNotify）
  --controller-url <url>       主控面板地址（首次安装必填，升级时沿用现有配置）
  --controller-token <token>   主控访问令牌（首次安装必填，升级时沿用现有配置）
  --controller-interval <sec>  上报与命令检查间隔（默认: 60）
  --reboot-file <path>         系统重启检测文件（默认: /var/run/reboot-required）
  --reboot-interval <sec>      重启检测间隔（默认: 3600）
  --initial-delay <sec>        启动延迟（默认: 0）
  --upgrade-enabled <true|false>
                              是否启用升级检查（默认: true）
  --upgrade-interval <sec>     升级检测间隔（默认: 86400）
  --proxy-enabled <true|false> 是否为下载启用代理（默认: false）
  --proxy-server <url>         下载代理地址（默认: http://127.0.0.1:7890）
  --force-download             忽略本地二进制，强制从 Release 下载
  --no-start                   写入文件但不启动/重启 systemd 服务
  -h, --help                   显示帮助信息

说明:
  重复执行 install 会升级二进制并保留 agent_id；传入的配置参数会覆盖旧配置。
  upgrade 等同于保留配置的升级操作；脚本不会输出 Token 等敏感信息。

示例:
  bash install.sh install --controller-url "https://panel.example.com" --controller-token "your-token"
  bash install.sh upgrade --version latest
  bash install.sh status
  bash install.sh uninstall
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "请使用 root 用户或 sudo 运行此脚本。"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    log_error "参数 $1 需要一个非空值。"
    exit 1
  fi
}

validate_positive_integer() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "${name} 必须是大于 0 的整数，当前值：${value}"
    exit 1
  fi
}

validate_boolean() {
  local name="$1" value="$2"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    log_error "${name} 必须是 true 或 false，当前值：${value}"
    exit 1
  fi
}

load_existing_config() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return 0
  fi
  local value
  value="$(sed -n 's/^agent_id:[[:space:]]*"\(.*\)"$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && -z "${AGENT_ID}" ]] && AGENT_ID="${value}"
  value="$(sed -n 's/^  url:[[:space:]]*"\(.*\)"$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && -z "${CONTROLLER_URL}" ]] && CONTROLLER_URL="${value}"
  value="$(sed -n 's/^  token:[[:space:]]*"\(.*\)"$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && -z "${CONTROLLER_TOKEN}" ]] && CONTROLLER_TOKEN="${value}"
  value="$(sed -n 's/^  interval:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && "${CONTROLLER_INTERVAL}" == "60" ]] && CONTROLLER_INTERVAL="${value}"
  value="$(sed -n 's/^reboot_file:[[:space:]]*"\(.*\)"$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && "${REBOOT_FILE}" == "/var/run/reboot-required" ]] && REBOOT_FILE="${value}"
  value="$(sed -n 's/^reboot_interval:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && "${REBOOT_INTERVAL}" == "3600" ]] && REBOOT_INTERVAL="${value}"
  value="$(sed -n 's/^initial_delay:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "${CONFIG_PATH}" | head -n 1)"
  [[ -n "${value}" && "${INITIAL_DELAY}" == "0" ]] && INITIAL_DELAY="${value}"
  value="$(sed -n 's/^  enabled:[[:space:]]*\(true\|false\)$/\1/p' "${CONFIG_PATH}" | tail -n 1)"
  [[ -n "${value}" && "${UPGRADE_ENABLED}" == "true" ]] && UPGRADE_ENABLED="${value}"
  value="$(sed -n 's/^  interval:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "${CONFIG_PATH}" | tail -n 1)"
  [[ -n "${value}" && "${UPGRADE_INTERVAL}" == "86400" ]] && UPGRADE_INTERVAL="${value}"
  log_info "检测到现有配置，将保留 Agent ID：${AGENT_ID:-未设置}"
}

validate_config() {
  validate_positive_integer "--controller-interval" "${CONTROLLER_INTERVAL}"
  validate_positive_integer "--reboot-interval" "${REBOOT_INTERVAL}"
  validate_positive_integer "--upgrade-interval" "${UPGRADE_INTERVAL}"
  validate_positive_integer "--initial-delay" "${INITIAL_DELAY}"
  validate_boolean "--upgrade-enabled" "${UPGRADE_ENABLED}"
  if [[ ! "${GITHUB_REPO}" =~ ^[^/]+/[^/]+$ ]]; then
    log_error "--repo 必须为 owner/repository 格式。"
    exit 1
  fi
  if [[ ! "${CONTROLLER_URL}" =~ ^https?://[^[:space:]]+$ ]]; then
    log_error "--controller-url 必须是 http:// 或 https:// 地址。"
    exit 1
  fi
}

ensure_dependencies() {
  local -a missing_dependencies=()

  if ! has_cmd curl; then
    missing_dependencies+=(curl)
  fi
  if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
    missing_dependencies+=(ca-certificates)
  fi

  if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
    log_info "检测到缺少依赖：${missing_dependencies[*]}，开始安装"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing_dependencies[@]}"
  else
    log_info "所需依赖已存在，跳过 apt 安装：curl、ca-certificates"
  fi

  if ! has_cmd systemctl; then
    log_error "当前系统未检测到 systemd/systemctl，无法安装服务。"
    exit 1
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
      log_error "不支持的架构：${machine}。支持的架构为：amd64、arm64"
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

write_config() {
  mkdir -p "${INSTALL_DIR}"
  local temp_config="${CONFIG_PATH}.tmp"
  cat >"${temp_config}" <<EOF
controller:
  enabled: true
  url: "${CONTROLLER_URL}"
  token: "${CONTROLLER_TOKEN}"
  interval: ${CONTROLLER_INTERVAL}
reboot_file: "${REBOOT_FILE}"
reboot_interval: ${REBOOT_INTERVAL}
initial_delay: ${INITIAL_DELAY}
upgrade_check:
  enabled: ${UPGRADE_ENABLED}
  interval: ${UPGRADE_INTERVAL}
agent_id: "${AGENT_ID}"
EOF
  chmod 600 "${temp_config}"
  mv -f "${temp_config}" "${CONFIG_PATH}"
  log_info "配置文件已写入：${CONFIG_PATH}"
}

write_systemd_unit() {
  cat >"${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=RebootNotify Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=5
User=root
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
EOF
}

reload_and_start_systemd() {
  log_info "正在重新加载 systemd 配置并启动服务..."
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  log_info "服务状态已更新。"
}

configure_download_proxy() {
  local proxy_url=""

  if [[ "${PROXY_ENABLED}" == "true" && -n "${PROXY_SERVER}" ]]; then
    proxy_url="${PROXY_SERVER}"
  fi

  if [[ -n "${proxy_url}" ]]; then
    export HTTP_PROXY="${proxy_url}"
    export HTTPS_PROXY="${proxy_url}"
    export ALL_PROXY="${proxy_url}"
    export http_proxy="${proxy_url}"
    export https_proxy="${proxy_url}"
    export all_proxy="${proxy_url}"
    log_info "正在使用代理下载：${proxy_url}"
  fi
}

find_local_binary() {
  local arch="$1"
  local dir
  local candidate
  local local_bin
  local -a candidates=()

  case "${arch}" in
    amd64)
      candidates=("${PROGRAM_NAME}-linux-amd64" "${PROGRAM_NAME}-linux-x86_64")
      ;;
    arm64)
      candidates=("${PROGRAM_NAME}-linux-arm64" "${PROGRAM_NAME}-linux-aarch64")
      ;;
    *)
      candidates=("${PROGRAM_NAME}-linux-${arch}")
      ;;
  esac

  for dir in "${PWD}" "${SCRIPT_DIR}"; do
    for candidate in "${candidates[@]}"; do
      local_bin="${dir}/${candidate}"
      if [[ -f "${local_bin}" && -x "${local_bin}" ]]; then
        echo "${local_bin}"
        return 0
      fi
    done
  done

  return 1
}

download_binary() {
  local repo="$1"
  local version="$2"
  local arch="$3"
  local asset="${PROGRAM_NAME}-linux-${arch}"
  local url
  local local_bin temp_bin

  if [[ "${FORCE_DOWNLOAD}" != "true" ]] && local_bin="$(find_local_binary "${arch}")"; then
    log_info "检测到本地已存在对应架构二进制：${local_bin}"
    mkdir -p "${INSTALL_DIR}"
    if [[ "${local_bin}" != "${BIN_PATH}" ]]; then
      cp "${local_bin}" "${BIN_PATH}"
    fi
    chmod +x "${BIN_PATH}"
    log_info "已复用本地二进制，跳过远程下载：${BIN_PATH}"
    return 0
  fi

  configure_download_proxy

  url="$(build_download_url "${repo}" "${version}" "${asset}")"
  log_info "开始下载二进制文件：${asset}"
  log_info "下载地址：${url}"
  log_info "请稍候，正在下载程序文件..."

  mkdir -p "${INSTALL_DIR}"
  temp_bin="${BIN_PATH}.tmp"
  curl -fL --retry 3 --connect-timeout 10 --progress-bar --show-error "${url}" -o "${temp_bin}"
  mv -f "${temp_bin}" "${BIN_PATH}"
  chmod +x "${BIN_PATH}"
  log_info "二进制文件下载完成：${BIN_PATH}"
}

do_install() {
  local arch

  log_info "开始安装 ${PROGRAM_NAME}..."
  require_root
  ensure_dependencies
  load_existing_config
  require_controller_config
  validate_config
  if [[ -z "${AGENT_ID}" ]]; then
    AGENT_ID="$(cat /proc/sys/kernel/random/uuid)"
  fi

  arch="$(detect_arch)"
  log_info "检测到系统架构：${arch}"
  download_binary "${GITHUB_REPO}" "${VERSION}" "${arch}"
  write_config
  write_systemd_unit
  if [[ "${NO_START}" != "true" ]]; then
    reload_and_start_systemd
  else
    log_warn "已跳过服务启动（--no-start）。"
  fi

  log_info "安装已完成。"
  log_info "程序文件：${BIN_PATH}"
  log_info "配置文件：${CONFIG_PATH}"
}

do_uninstall() {
  log_info "开始卸载 ${PROGRAM_NAME}..."
  require_root

  systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "${SYSTEMD_UNIT}"
  if [[ -d "${INSTALL_DIR}" ]]; then
    local backup_path="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    mv "${INSTALL_DIR}" "${backup_path}"
    log_info "已备份安装目录：${backup_path}"
  fi

  log_info "卸载完成。"
}

do_status() {
  require_root
  if ! has_cmd systemctl; then
    log_error "当前系统未检测到 systemctl。"
    exit 1
  fi
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    log_warn "未发现安装配置：${CONFIG_PATH}"
  else
    local agent_id
    agent_id="$(sed -n 's/^agent_id:[[:space:]]*"\(.*\)"$/\1/p' "${CONFIG_PATH}" | head -n 1)"
    log_info "安装目录：${INSTALL_DIR}"
    log_info "Agent ID：${agent_id:-未设置}"
    log_info "配置文件：${CONFIG_PATH}"
  fi
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
}

require_controller_config() {
  if [[ -z "${CONTROLLER_URL}" ]]; then
    log_error "安装必须提供 --controller-url 参数。"
    exit 1
  fi
  if [[ -z "${CONTROLLER_TOKEN}" ]]; then
    log_error "安装必须提供 --controller-token 参数。"
    exit 1
  fi
}

MODE="install"
FORCE_DOWNLOAD="false"
NO_START="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall)
      MODE="$1"
      shift
      ;;
    upgrade|status)
      MODE="$1"
      shift
      ;;
    --repo)
      require_value "$@"
      GITHUB_REPO="$2"
      shift 2
      ;;
    --version)
      require_value "$@"
      VERSION="$2"
      shift 2
      ;;
    --install-dir)
      require_value "$@"
      INSTALL_DIR="$2"
      BIN_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
      CONFIG_PATH="${INSTALL_DIR}/config.yaml"
      shift 2
      ;;
    --controller-url)
      require_value "$@"
      CONTROLLER_URL="$2"
      shift 2
      ;;
    --controller-token)
      require_value "$@"
      CONTROLLER_TOKEN="$2"
      shift 2
      ;;
    --controller-interval)
      require_value "$@"
      CONTROLLER_INTERVAL="$2"
      shift 2
      ;;
    --proxy-enabled)
      require_value "$@"
      PROXY_ENABLED="$2"
      shift 2
      ;;
    --proxy-server)
      require_value "$@"
      PROXY_SERVER="$2"
      shift 2
      ;;
    --reboot-file)
      require_value "$@"
      REBOOT_FILE="$2"
      shift 2
      ;;
    --reboot-interval)
      require_value "$@"
      REBOOT_INTERVAL="$2"
      shift 2
      ;;
    --initial-delay)
      require_value "$@"
      INITIAL_DELAY="$2"
      shift 2
      ;;
    --upgrade-enabled)
      require_value "$@"
      UPGRADE_ENABLED="$2"
      shift 2
      ;;
    --upgrade-interval)
      require_value "$@"
      UPGRADE_INTERVAL="$2"
      shift 2
      ;;
    --force-download)
      FORCE_DOWNLOAD="true"
      shift
      ;;
    --no-start)
      NO_START="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "未知参数：$1"
      usage
      exit 1
      ;;
  esac
done

if [[ "${MODE}" == "install" ]]; then
  do_install
elif [[ "${MODE}" == "upgrade" ]]; then
  do_install
elif [[ "${MODE}" == "status" ]]; then
  do_status
else
  do_uninstall
fi
