#!/usr/bin/env bash
# 自动安装 & 启动 openssh-server + wstunnel，并生成 SSH 连接命令
#
# 用法：
#   ./qz_ssh_starter.sh [--base-url "https://host/base/path"] [--user ssh_user] [--port port] [--public-key "ssh-ed25519 ..."]
#
# 示例（基于环境变量，推荐）：
#   export VC_PREFIX="/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE"
#   ./qz_ssh_starter.sh --public-key "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABAQ..."
#
# 示例（显式指定 Base URL）：
#   ./qz_ssh_starter.sh \
#     --base-url "https://nat-notebook-inspire.sii.edu.cn/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE" \
#     --user root \
#     --port 10080 \
#     --public-key "ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABAQ..."
#
# 环境变量：
#   VC_BASE_URL        完整 base URL（优先级：--base-url > VC_BASE_URL > VC_BASE_HOST + VC_PREFIX）
#   VC_PREFIX          仅 path（例如 /ws-XXX/...），脚本会与 VC_BASE_HOST 拼接
#   VC_BASE_HOST       与 VC_PREFIX 组合时使用，默认 https://nat-notebook-inspire.sii.edu.cn
#   WSTUNNEL_VERSION   wstunnel 版本，默认 10.5.1
#   WSTUNNEL_MIRRORS   自定义镜像前缀，逗号分隔（会走测速+选择流程）
#   DRY_RUN=1          只打印 wstunnel 命令，不真正启动 wstunnel server

set -euo pipefail

#####################################
# 目录结构：基于脚本路径
#####################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/ws_tunnel_data"
BIN_DIR="${DATA_DIR}/bin"
LOG_DIR="${DATA_DIR}/logs"

#####################################
# 彩色输出 & 日志函数
#####################################

COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"

log_info() {
  echo -e "[${COLOR_BLUE}INFO${COLOR_RESET}] $*"
}

log_warn() {
  echo -e "[${COLOR_YELLOW}WARN${COLOR_RESET}] $*" >&2
}

log_error() {
  echo -e "[${COLOR_RED}ERROR${COLOR_RESET}] $*" >&2
}

log_ok() {
  echo -e "[${COLOR_GREEN}OK${COLOR_RESET}] $*"
}

#####################################
# 帮助信息
#####################################

print_usage() {
  cat <<EOF
用法：
  $0 [ssh_user] [port] [--public-key "ssh-ed25519 ..."] [--base-url https://host/base/path]

说明：
  - 默认会从环境变量获取 Base URL，优先级：--base-url > VC_BASE_URL > (VC_BASE_HOST + VC_PREFIX)
  - ssh_user：可选，默认 root
  - port：    可选，wstunnel 对外 ws 端口，默认 10080
  - stop：    子命令，停止当前 wstunnel
EOF
}

#####################################
# 参数解析
#####################################

BASE_URL=""
SSH_USER="root"
WSTUNNEL_PORT="10080"
PUBLIC_KEY=""

parse_args() {
  FORCE_START="0"

  if [[ $# -gt 0 && "$1" == "stop" ]]; then
    stop_wstunnel
  fi

  # 兼容旧版：若第一个位置参数不是选项，则视作 base url
  if [[ $# -ge 1 && "$1" != -* ]]; then
    BASE_URL_RAW="$1"
    shift
  fi

  # 兼容位置参数 user / port
  if [[ $# -ge 1 && "$1" != -* ]]; then
    SSH_USER="$1"
    shift
  fi
  if [[ $# -ge 1 && "$1" != -* ]]; then
    WSTUNNEL_PORT="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user)
        SSH_USER="$2"
        shift 2
        ;;
      -p|--port)
        WSTUNNEL_PORT="$2"
        shift 2
        ;;
      --public-key)
        PUBLIC_KEY="$2"
        shift 2
        ;;
      --base-url)
        BASE_URL_RAW="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --force)
        FORCE_START="1"
        shift
        ;;
      *)
        log_warn "忽略未知参数: $1"
        shift
        ;;
    esac
  done

  resolve_base_url
  BASE_URL="${BASE_URL_RAW%/}"
}

#####################################
# Base URL 解析（环境变量）
#####################################

resolve_base_url() {
  if [[ -n "${BASE_URL_RAW:-}" ]]; then
    log_info "使用传入的 Base URL：$BASE_URL_RAW"
    return
  fi

  if [[ -n "${VC_BASE_URL:-}" ]]; then
    BASE_URL_RAW="$VC_BASE_URL"
    log_info "使用环境变量 VC_BASE_URL：$BASE_URL_RAW"
    return
  fi

  if [[ -n "${VC_PREFIX:-}" ]]; then
    local host="${VC_BASE_HOST:-https://nat-notebook-inspire.sii.edu.cn}"
    host="${host%/}"
    local prefix="$VC_PREFIX"
    if [[ "$prefix" != /* ]]; then
      prefix="/$prefix"
    fi
    BASE_URL_RAW="${host}${prefix}"
    log_info "根据 VC_BASE_HOST + VC_PREFIX 计算 Base URL：$BASE_URL_RAW"
    return
  fi

  log_error "未提供 Base URL，请使用 --base-url 或设置 VC_BASE_URL / VC_PREFIX。"
  exit 1
}

#####################################
# URL 解析
#####################################

WSS_HOST=""
BASE_PATH=""

parse_url() {
  local proto_host
  proto_host="$(echo "$BASE_URL" | sed -E 's#(https?://[^/]+).*#\1#')"

  WSS_HOST="$(echo "$proto_host" | sed -E 's#https?://##')"
  BASE_PATH="$(echo "$BASE_URL" | sed -E 's#https?://[^/]+##')"

  if [[ -z "$WSS_HOST" || -z "$BASE_PATH" ]]; then
    log_error "无法从 URL 中解析 host 或 path: $BASE_URL"
    exit 1
  fi

  log_info "解析 URL 成功："
  log_info "  Host:      $WSS_HOST"
  log_info "  Base path: $BASE_PATH"
}

#####################################
# 基础目录初始化
#####################################

init_dirs() {
  mkdir -p "$BIN_DIR" "$LOG_DIR"
  log_info "数据目录：$DATA_DIR"
  log_info "bin 目录：$BIN_DIR"
  log_info "log 目录：$LOG_DIR"
}

#####################################
# 架构检测
#####################################

WST_ARCH=""
detect_arch() {
  local uname_m
  uname_m="$(uname -m)"

  case "$uname_m" in
    x86_64|amd64)
      WST_ARCH="amd64"
      ;;
    aarch64|arm64)
      WST_ARCH="arm64"
      ;;
    *)
      log_warn "未知架构: $uname_m，默认使用 linux_amd64（可能下载失败，需要手动修脚本）"
      WST_ARCH="amd64"
      ;;
  esac

  log_info "检测到体系结构：$uname_m -> linux_${WST_ARCH}"
}

#####################################
# GitHub 镜像测速 + 选择
#####################################

readonly GITHUB_PROXIES=(
    ""  # Direct connection
    "https://github.akams.cn/"
    "https://gh-proxy.net/"
    "https://tvv.tw/"
)
FASTEST_GITHUB_PROXY="UNSET"
readonly GITHUB_SPEEDTEST_URL="https://raw.githubusercontent.com/microsoft/vscode/main/LICENSE.txt"

compare_floats() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    if (a < b) print "<";
    else if (a > b) print ">";
    else print "=";
  }'
}

github_proxy_select() {
  if [[ "$FASTEST_GITHUB_PROXY" != "UNSET" ]]; then
    return
  fi

  local selection_file="${DATA_DIR}/github_proxy_selection"

  # 先看有没有持久化选择
  if [[ -f "$selection_file" ]]; then
    local selection
    selection="$(<"$selection_file")"
    if [[ -n "$selection" && "$selection" =~ ^[0-9]+$ ]]; then
      if [[ $selection -ge 0 && $selection -lt ${#GITHUB_PROXIES[@]} ]]; then
        FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$selection]}"
        log_ok "使用保存的 GitHub 镜像: ${FASTEST_GITHUB_PROXY:-直连}"
        return
      fi
    fi
    log_warn "保存的 GitHub 镜像选择无效，删除: $selection_file"
    rm -f "$selection_file"
  fi

  log_info "开始测试 GitHub 镜像延迟..."

  local min_time="10.0"
  local min_index=0
  local times=()
  local available_indices=()

  for i in "${!GITHUB_PROXIES[@]}"; do
    local proxy="${GITHUB_PROXIES[$i]}"
    local proxy_name="${proxy:-Direct}"
    local test_url

    if [[ -z "$proxy" ]]; then
      test_url="$GITHUB_SPEEDTEST_URL"
    else
      proxy="${proxy%/}/"
      test_url="${proxy}${GITHUB_SPEEDTEST_URL}"
    fi

    local curl_time
    if ! curl_time=$(curl --silent --fail --location --output /dev/null \
                         --max-time 3 --write-out "%{time_total}" \
                         "$test_url"); then
      log_warn "镜像 '$proxy_name' 不可用"
      times[$i]="N/A"
      continue
    fi

    log_info "镜像 '$proxy_name' 耗时: ${curl_time}s"
    times[$i]="$curl_time"
    available_indices+=("$i")

    if [[ "$(compare_floats "$curl_time" "$min_time")" == "<" ]]; then
      min_time="$curl_time"
      min_index="$i"
    fi
  done

  if [[ ${#available_indices[@]} -eq 0 ]]; then
    log_error "没有可用的 GitHub 镜像"
    exit 1
  fi

  echo
  log_info "请选择要使用的 GitHub 镜像："
  for idx in "${available_indices[@]}"; do
    local proxy="${GITHUB_PROXIES[$idx]}"
    local proxy_name="${proxy:-Direct}"
    local extra=""
    if [[ "$idx" -eq "$min_index" ]]; then
      extra=" (fastest)"
    fi
    log_info "  $idx) $proxy_name  (${times[$idx]} s)${extra}"
  done
  log_info "输入说明："
  log_info "  <数字>   = 本次会话使用该镜像"
  log_info "  <数字>!  = 使用该镜像并记住选择（写入 ${selection_file})"
  log_info "  <回车>   = 使用测速最快的镜像"
  log_info "  !        = 使用最快镜像并记住选择"

  read -p "[QUESTION] 你的选择: " -r user_choice

  local persistent=0
  if [[ "$user_choice" == *"!"* ]]; then
    persistent=1
    user_choice="${user_choice%!}"
  fi

  if [[ -z "$user_choice" ]]; then
    FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
    log_ok "选择最快镜像: ${FASTEST_GITHUB_PROXY:-Direct}"
    if [[ $persistent -eq 1 ]]; then
      mkdir -p "$DATA_DIR"
      echo "$min_index" >"$selection_file"
      log_info "已保存该选择，后续会自动使用。要重置删除文件即可：$selection_file"
    fi
  elif [[ "$user_choice" =~ ^[0-9]+$ ]]; then
    if [[ $user_choice -ge 0 && $user_choice -lt ${#GITHUB_PROXIES[@]} ]]; then
      FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$user_choice]}"
      log_ok "手动选择镜像: ${FASTEST_GITHUB_PROXY:-Direct}"
      if [[ $persistent -eq 1 ]]; then
        mkdir -p "$DATA_DIR"
        echo "$user_choice" >"$selection_file"
        log_info "已保存该选择，后续会自动使用。"
      fi
    else
      log_warn "输入无效，使用最快镜像。"
      FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
    fi
  else
    log_warn "输入无效，使用最快镜像。"
    FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
  fi
}

#####################################
# wstunnel 下载 & 安装
#####################################

WSTUNNEL_BIN=""
download_and_install_wstunnel() {
  github_proxy_select

  local version
  version="${WSTUNNEL_VERSION:-10.5.1}"
  local base_tar_url="https://github.com/erebe/wstunnel/releases/download/v${version}/wstunnel_${version}_linux_${WST_ARCH}.tar.gz"

  local final_url
  if [[ -z "$FASTEST_GITHUB_PROXY" ]]; then
    final_url="$base_tar_url"
  else
    local proxy="${FASTEST_GITHUB_PROXY%/}/"
    final_url="${proxy}${base_tar_url}"
  fi

  log_info "准备从以下地址下载 wstunnel："
  log_info "  $final_url"

  local tmp_tar
  tmp_tar="$(mktemp /tmp/wstunnel_XXXXXX.tar.gz)"

  if ! curl -fL "$final_url" -o "$tmp_tar"; then
    log_error "下载 wstunnel 失败，请检查网络或镜像设置。"
    rm -f "$tmp_tar"
    exit 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/wstunnel_XXXXXX)"
  tar -xf "$tmp_tar" -C "$tmp_dir"

  if [[ ! -f "$tmp_dir/wstunnel" ]]; then
    log_error "在 tar 包中未找到 wstunnel 可执行文件。"
    rm -rf "$tmp_dir" "$tmp_tar"
    exit 1
  fi

  mv "$tmp_dir/wstunnel" "$BIN_DIR/wstunnel"
  chmod +x "$BIN_DIR/wstunnel"
  rm -rf "$tmp_dir" "$tmp_tar"

  log_ok "wstunnel 已安装到：$BIN_DIR/wstunnel"
}

ensure_wstunnel() {
  WSTUNNEL_BIN="${BIN_DIR}/wstunnel"
  if [[ -x "$WSTUNNEL_BIN" ]]; then
    log_ok "检测到已有 wstunnel：$WSTUNNEL_BIN"
    return
  fi

  log_info "未检测到 wstunnel，开始下载..."
  download_and_install_wstunnel
}

#####################################
# SSH server 相关
#####################################

configure_sshd_security() {
  log_info "配置 sshd：禁止密码登录，仅允许公钥"

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    cat >/etc/ssh/sshd_config.d/99-wstunnel.conf <<EOF
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM yes
PermitRootLogin prohibit-password
EOF
    log_ok "已写入 /etc/ssh/sshd_config.d/99-wstunnel.conf"
  else
    local cfg="/etc/ssh/sshd_config"
    if [[ ! -f "$cfg" ]]; then
      log_error "未找到 $cfg，无法配置 sshd。"
      exit 1
    fi

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg" || true
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$cfg" || true
    if ! grep -q '^PubkeyAuthentication' "$cfg"; then
      echo 'PubkeyAuthentication yes' >>"$cfg"
    else
      sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg" || true
    fi
    if ! grep -q '^PermitRootLogin' "$cfg"; then
      echo 'PermitRootLogin prohibit-password' >>"$cfg"
    else
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg" || true
    fi

    log_ok "已更新 $cfg"
  fi
}

configure_authorized_keys() {
  if [[ -z "${PUBLIC_KEY:-}" ]]; then
    log_warn "未提供 --public-key，保留已有 authorized_keys。"
    return
  fi

  local user_home
  user_home="$(getent passwd "$SSH_USER" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -z "$user_home" ]]; then
    user_home="$(eval echo "~${SSH_USER}")"
  fi

  if [[ ! -d "$user_home" ]]; then
    log_error "无法确定用户 $SSH_USER 的 home 目录：$user_home"
    exit 1
  fi

  local ssh_dir="${user_home}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_keys"
  chmod 600 "$auth_keys"

  if grep -qxF "$PUBLIC_KEY" "$auth_keys"; then
    log_info "authorized_keys 中已存在该 key。"
  else
    echo "$PUBLIC_KEY" >>"$auth_keys"
    log_ok "已将 public key 写入 $auth_keys"
  fi

  chown -R "${SSH_USER}:${SSH_USER}" "$ssh_dir" || true
}

start_sshd_service() {
  log_info "尝试启动 / 重启 sshd..."

  if command -v service >/dev/null 2>&1 && [[ -f /etc/init.d/ssh ]]; then
    if service ssh restart; then
      log_ok "已通过 service ssh restart 启动 sshd"
      return
    else
      log_warn "service ssh restart 失败，尝试其他方式..."
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart ssh 2>/dev/null; then
      log_ok "已通过 systemctl restart ssh 启动 sshd"
      return
    fi
  fi

  local sshd_bin
  sshd_bin="$(command -v sshd || echo "/usr/sbin/sshd")"
  if [[ ! -x "$sshd_bin" ]]; then
    log_error "未找到 sshd 可执行文件。"
    exit 1
  fi

  if pgrep -x sshd >/dev/null 2>&1; then
    log_ok "检测到已有 sshd 进程，无需再次启动。"
    return
  fi

  nohup "$sshd_bin" -D >/var/log/sshd-wstunnel.log 2>&1 &
  log_ok "已直接启动 sshd，日志: /var/log/sshd-wstunnel.log"
}

check_ssh_port_22() {
  log_info "检查 22 端口是否监听..."

  local ok=0

  if command -v nc >/dev/null 2>&1; then
    for _ in {1..20}; do
      if nc -z 127.0.0.1 22 2>/dev/null; then
        ok=1
        break
      fi
      sleep 0.5
    done
  elif command -v ss >/dev/null 2>&1; then
    for _ in {1..20}; do
      if ss -tnlp 2>/dev/null | grep -q ':22 '; then
        ok=1
        break
      fi
      sleep 0.5
    done
  else
    log_warn "无 nc/ss，退化为检测 sshd 进程。"
    if pgrep -x sshd >/dev/null 2>&1; then
      ok=1
    fi
  fi

  if [[ "$ok" -eq 1 ]]; then
    log_ok "22 端口看起来已经可用。"
  else
    log_error "22 端口检测失败，请检查 sshd 配置/日志。"
    exit 1
  fi
}

ensure_ssh_server() {
  log_info "检查 openssh-server / sshd..."

  if ! command -v sshd >/dev/null 2>&1; then
    log_warn "未检测到 sshd，将尝试安装 openssh-server..."

    if ! command -v apt-get >/dev/null 2>&1; then
      log_error "未找到 apt-get，无法自动安装 openssh-server，请手动安装。"
      exit 1
    fi

    apt-get update
    if ! apt-get install -y openssh-server; then
      log_error "apt 安装 openssh-server 失败，请检查网络或源配置。"
      exit 1
    fi
    log_ok "openssh-server 安装完成。"
  else
    log_ok "检测到 sshd：$(command -v sshd)"
  fi

  configure_sshd_security
  configure_authorized_keys
  start_sshd_service
  check_ssh_port_22
}

#####################################
# 启动 wstunnel server
#####################################

start_wstunnel_server() {
  local port="$WSTUNNEL_PORT"
  local host_short
  host_short="$(hostname -s 2>/dev/null || hostname || echo "unknown")"
  local log_file="${LOG_DIR}/${host_short}.log"

  # 检查现有进程
  local existing_pid
  existing_pid=$(get_running_wstunnel_pid)

  if [[ -n "$existing_pid" && "$FORCE_START" == "0" ]]; then
    log_warn "检测到已有 wstunnel 正在运行 (port=${port})，PID: $existing_pid"
    log_info "如需重新启动，请运行："
    echo "  ./start_ws_tunnel.sh stop"
    echo "  ./start_ws_tunnel.sh <args> --force"
    return
  fi

  # 如果强制重启则 kill
  if [[ -n "$existing_pid" && "$FORCE_START" == "1" ]]; then
    log_warn "--force 已启用，正在终止现有 wstunnel (PID: $existing_pid)..."
    kill -9 "$existing_pid"
    sleep 0.5
  fi

  log_info "准备启动 wstunnel server:"
  log_info "  命令: $WSTUNNEL_BIN server --restrict-to 127.0.0.1:22 ws://0.0.0.0:${port}"
  log_info "  日志: $log_file"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_warn "DRY_RUN=1，只显示命令，不执行。"
    return
  fi

  nohup "$WSTUNNEL_BIN" server \
    --restrict-to 127.0.0.1:22 \
    "ws://0.0.0.0:${port}" \
    >>"$log_file" 2>&1 &

  sleep 1

  local newpid
  newpid=$(get_running_wstunnel_pid)

  if [[ -n "$newpid" ]]; then
    log_ok "wstunnel 已成功启动 (port=${port})，PID: $newpid"
  else
    log_error "wstunnel 启动失败，请检查日志：$log_file"
    exit 1
  fi
}

#####################################
# 打印 SSH 一次性命令 & config 示例
#####################################

print_ssh_instructions() {
  local port="$WSTUNNEL_PORT"
  local pf_url="https://${WSS_HOST}${BASE_PATH}/proxy/${port}/"
  local http_upgrade_path="${BASE_PATH}/proxy/${port}/v1"

  echo
  log_info "==== Port Forward URL（浏览器访问调试用） ===="
  echo "  $pf_url"
  echo

  log_info "==== 本地 SSH 一次性命令（在你的本地终端执行） ===="
  echo "ssh \\"
  echo "  -o StrictHostKeyChecking=no \\"
  echo "  -o UserKnownHostsFile=/dev/null \\"
  echo "  -o ProxyCommand=\"wstunnel client --log-lvl=off -L stdio://%h:%p --http-upgrade-path-prefix ${http_upgrade_path} wss://${WSS_HOST}\" \\"
  echo "  ${SSH_USER}@127.0.0.1"
  echo

  log_info "==== ~/.ssh/config 示例（可选，写入本地配置后直接 ssh qz-notebook-ssh） ===="
  cat <<EOF
Host qz-notebook-ssh
  HostName 127.0.0.1
  User ${SSH_USER}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand wstunnel client --log-lvl=off -L stdio://%h:%p --http-upgrade-path-prefix ${http_upgrade_path} wss://${WSS_HOST}
EOF
  echo
}

#####################################
# 进程检测与控制
#####################################

get_running_wstunnel_pid() {
  # 匹配当前脚本目录中 bin/wstunnel 启动，且绑定了指定端口的 server 模式
  pgrep -f "${BIN_DIR}/wstunnel server --restrict-to 127.0.0.1:22 ws://0.0.0.0:${WSTUNNEL_PORT}" || true
}

stop_wstunnel() {
  local pids
  pids=$(pgrep -f "${BIN_DIR}/wstunnel server" || true)

  if [[ -z "$pids" ]]; then
    log_info "没有正在运行的 wstunnel 进程。"
    exit 0
  fi

  log_warn "检测到以下 wstunnel 进程，将终止："
  echo "$pids"

  echo "$pids" | xargs kill -9
  log_ok "已停止所有 wstunnel 服务。"
  exit 0
}

#####################################
# 主流程
#####################################

main() {
  parse_args "$@"
  init_dirs
  parse_url
  detect_arch
  ensure_ssh_server
  ensure_wstunnel
  start_wstunnel_server
  print_ssh_instructions
}

main "$@"