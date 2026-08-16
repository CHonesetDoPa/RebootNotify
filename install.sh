#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PROGRAM_NAME="RebootNotify"
SERVICE_NAME="rebootnotify"
SUPERVISOR_CONF="/etc/supervisor/conf.d/${SERVICE_NAME}.conf"
INSTALL_DIR="/opt/RebootNotify"
BIN_PATH="${INSTALL_DIR}/${PROGRAM_NAME}"
CONFIG_PATH="${INSTALL_DIR}/config.yaml"
REMOTE_CONFIG_TEMPLATE_URL="https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/config.example.yaml"

GITHUB_REPO="CHonesetDoPa/RebootNotify"
VERSION="latest"
TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
PROXY_ENABLED="false"
PROXY_SERVER="http://127.0.0.1:7890"
REBOOT_FILE="/var/run/reboot-required"
REBOOT_INTERVAL="3600"
INITIAL_DELAY="0"
UPGRADE_ENABLED="true"
UPGRADE_INTERVAL="86400"

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
  bash install.sh uninstall [选项]

命令:
  install      安装 supervisor、部署二进制文件并启动服务（默认）
  uninstall    卸载已部署文件、supervisor 配置并移除依赖

选项:
  --repo <owner/repo>          GitHub 仓库，例如 CHonesetDoPa/RebootNotify
  --version <tag|latest>       发布版本或 latest（默认: latest）
  --install-dir <path>         安装目录（默认: /opt/RebootNotify）
  --token <token>              Telegram Bot Token，用于生成 config.yaml
  --chat-id <id>               Telegram Chat ID，用于生成 config.yaml
  --proxy-enabled <true|false> 是否启用代理（默认: false）
  --proxy-server <url>         代理地址（默认: http://127.0.0.1:7890）
  --reboot-file <path>         系统重启检测文件（默认: /var/run/reboot-required）
  --reboot-interval <sec>      重启检测间隔（默认: 3600）
  --initial-delay <sec>        启动延迟（默认: 0）
  --upgrade-enabled <true|false>
                              是否启用升级检查（默认: true）
  --upgrade-interval <sec>     升级检测间隔（默认: 86400）
  -h, --help                   显示帮助信息

说明:
  仅支持通过命令行参数传入配置。
  当必需参数 --token 和 --chat-id 已填写时，会跳过交互式确认和配置输入。

示例:
  bash install.sh install --repo CHonesetDoPa/RebootNotify --version latest --token "123456:ABCDEF" --chat-id "123456789"
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

ensure_dependencies() {
  log_info "开始检查并安装运行所需依赖：supervisor、curl、ca-certificates"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y supervisor curl ca-certificates

  if has_cmd systemctl; then
    systemctl enable --now supervisor
    log_info "supervisor 已启用并已启动。"
  else
    service supervisor start
    log_warn "当前环境未检测到 systemctl，已尝试通过 service 启动 supervisor。"
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

describe_config_prompt() {
  local path="$1"

  case "${path}" in
    telegram.token)
      echo "Telegram Bot Token：用于访问 Telegram Bot API，通常形如 123456:ABCDEF..." ;;
    telegram.chat_id)
      echo "Telegram Chat ID：接收通知的目标用户或群组 ID，例如 123456789" ;;
    proxy.enabled)
      echo "是否启用代理：true/false。开启后会使用代理访问 Telegram API" ;;
    proxy.server)
      echo "代理地址：例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080" ;;
    reboot_file)
      echo "系统重启检测文件：通常为 /var/run/reboot-required，用于判断系统是否需要重启" ;;
    reboot_interval)
      echo "重启检测间隔（秒）：例如 3600 表示每小时检查一次" ;;
    initial_delay)
      echo "启动延迟（秒）：程序启动前等待的秒数，0 表示立即启动" ;;
    upgrade_check.enabled)
      echo "是否开启升级检查：true/false。开启后会定期检测程序更新" ;;
    upgrade_check.interval)
      echo "升级检查间隔（秒）：例如 86400 表示每天检查一次" ;;
    *)
      echo "配置项 ${path}" ;;
  esac
}

get_cli_value_for_path() {
  local path="$1"

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

has_required_cli_params() {
  [[ -n "${TOKEN}" && "${TOKEN}" != "YOUR_BOT_TOKEN" && -n "${CHAT_ID}" && "${CHAT_ID}" != "YOUR_CHAT_ID" ]]
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
  local cli_value
  local final_value
  local input
  local description

  default_value="$(trim_quotes "${raw_default}")"
  detected_type="$(detect_value_type "${default_value}")"
  cli_value="$(get_cli_value_for_path "${path}")"

  if [[ -n "${cli_value}" ]]; then
    default_value="${cli_value}"
  fi

  if has_required_cli_params; then
    case "${detected_type}" in
      bool)
        if final_value="$(normalize_bool "${default_value}")"; then
          echo "${final_value}"
          return 0
        fi
        echo "false"
        return 0
        ;;
      int)
        if [[ "${default_value}" =~ ^-?[0-9]+$ ]]; then
          echo "${default_value}"
          return 0
        fi
        echo "0"
        return 0
        ;;
      *)
        echo "${default_value}"
        return 0
        ;;
    esac
  fi

  description="$(describe_config_prompt "${path}")"

  if [[ -r /dev/tty ]]; then
    while true; do
      read -r -p "配置 ${path}：${description} [当前值: ${default_value}] 请输入：" input </dev/tty
      if [[ -z "${input}" ]]; then
        input="${default_value}"
      fi

      case "${detected_type}" in
        bool)
          if final_value="$(normalize_bool "${input}")"; then
            echo "${final_value}"
            return 0
          fi
          echo "请输入 true/false（或 yes/no）。" >&2
          ;;
        int)
          if [[ "${input}" =~ ^-?[0-9]+$ ]]; then
            echo "${input}"
            return 0
          fi
          echo "请输入一个整数值。" >&2
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

confirm_installation() {
  local reply

  if has_required_cli_params; then
    log_info "已检测到必要参数，跳过安装确认交互。"
    return 0
  fi

  echo
  log_info "即将执行安装。请确认以下配置："
  log_info "安装目录：${INSTALL_DIR}"
  log_info "程序路径：${BIN_PATH}"
  log_info "配置文件：${CONFIG_PATH}"
  log_info "GitHub 仓库：${GITHUB_REPO}"
  log_info "版本：${VERSION}"
  echo

  while true; do
    read -r -p "是否继续安装？请输入 y(继续) / n(取消)：" reply </dev/tty || reply="n"
    case "${reply,,}" in
      y|yes)
        log_info "已确认，开始安装。"
        return 0
        ;;
      n|no)
        log_info "安装已取消。"
        exit 0
        ;;
      *)
        log_warn "无效输入，请输入 y 或 n。"
        ;;
    esac
  done
}

resolve_template_config() {
  local remote_template

  remote_template="$(mktemp)"
  log_info "正在下载配置模板：${REMOTE_CONFIG_TEMPLATE_URL}"
  if curl -fsSL --retry 3 --connect-timeout 10 "${REMOTE_CONFIG_TEMPLATE_URL}" -o "${remote_template}"; then
    log_info "配置模板下载成功。"
    echo "${remote_template}"
    return 0
  fi
  log_error "下载配置模板失败：${REMOTE_CONFIG_TEMPLATE_URL}"
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
    log_info "正在使用远程模板：${REMOTE_CONFIG_TEMPLATE_URL}"
  else
    log_error "无法下载配置模板：${REMOTE_CONFIG_TEMPLATE_URL}"
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
  log_info "正在重新加载 supervisor 配置并启动服务..."
  supervisorctl reread
  supervisorctl update
  supervisorctl restart "${SERVICE_NAME}" || supervisorctl start "${SERVICE_NAME}"
  supervisorctl status "${SERVICE_NAME}" || true
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
  local local_bin

  if local_bin="$(find_local_binary "${arch}")"; then
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
  curl -fL --retry 3 --connect-timeout 10 --progress-bar --show-error "${url}" -o "${BIN_PATH}"
  chmod +x "${BIN_PATH}"
  log_info "二进制文件下载完成：${BIN_PATH}"
}

do_install() {
  local arch

  log_info "开始安装 ${PROGRAM_NAME}..."
  require_root
  confirm_installation
  ensure_dependencies

  arch="$(detect_arch)"
  log_info "检测到系统架构：${arch}"
  download_binary "${GITHUB_REPO}" "${VERSION}" "${arch}"
  write_config_from_example
  write_supervisor_conf
  reload_and_start_supervisor

  log_info "安装已完成。"
  log_info "程序文件：${BIN_PATH}"
  log_info "配置文件：${CONFIG_PATH}"
}

do_uninstall() {
  log_info "开始卸载 ${PROGRAM_NAME}..."
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

  log_info "卸载完成。"
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
    --proxy-enabled)
      PROXY_ENABLED="$2"
      shift 2
      ;;
    --proxy-server)
      PROXY_SERVER="$2"
      shift 2
      ;;
    --reboot-file)
      REBOOT_FILE="$2"
      shift 2
      ;;
    --reboot-interval)
      REBOOT_INTERVAL="$2"
      shift 2
      ;;
    --initial-delay)
      INITIAL_DELAY="$2"
      shift 2
      ;;
    --upgrade-enabled)
      UPGRADE_ENABLED="$2"
      shift 2
      ;;
    --upgrade-interval)
      UPGRADE_INTERVAL="$2"
      shift 2
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
else
  do_uninstall
fi
