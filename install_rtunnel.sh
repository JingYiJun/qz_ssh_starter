#!/usr/bin/env bash
# 安装 rtunnel 到本地用户目录
#
# 用法：
#   ./install_rtunnel.sh
#
# 环境变量：
#   RTUNNEL_VERSION    rtunnel 版本，默认自动获取最新稳定版本（vx.y.z）

set -euo pipefail

#####################################
# 目录结构
#####################################

INSTALL_DIR="${HOME}/.local/bin"
DATA_DIR="${HOME}/.local/share/rtunnel_installer"

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
# 操作系统和架构检测
#####################################

OS_TYPE=""
WST_ARCH=""

detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  
  case "$uname_s" in
    Linux)
      OS_TYPE="linux"
      ;;
    Darwin)
      OS_TYPE="darwin"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      OS_TYPE="windows"
      ;;
    *)
      log_error "不支持的操作系统: $uname_s"
      exit 1
      ;;
  esac
  
  log_info "检测到操作系统：$uname_s -> $OS_TYPE"
}

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
      log_warn "未知架构: $uname_m，默认使用 amd64（可能下载失败，需要手动修脚本）"
      WST_ARCH="amd64"
      ;;
  esac

  log_info "检测到体系结构：$uname_m -> ${OS_TYPE}_${WST_ARCH}"
}

#####################################
# GitHub 镜像测速 + 选择
#####################################

readonly GITHUB_PROXIES=(
    ""  # Direct connection
    # "https://github.akams.cn/"
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

  mkdir -p "$DATA_DIR"
  local selection_file="${DATA_DIR}/github_proxy_selection"

  # 先看有没有持久化选择
  if [[ -f "$selection_file" ]]; then
    local selection
    selection="$(<"$selection_file")"
    if [[ -n "$selection" && "$selection" =~ ^[0-9]+$ ]]; then
      if [[ $selection -ge 0 && $selection -lt ${#GITHUB_PROXIES[@]} ]]; then
        FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$selection]}"
        log_ok "使用保存的 GitHub 镜像: ${FASTEST_GITHUB_PROXY:-直连}" >&2
        return
      fi
    fi
    log_warn "保存的 GitHub 镜像选择无效，删除: $selection_file" >&2
    rm -f "$selection_file"
  fi

  log_info "开始测试 GitHub 镜像延迟..." >&2

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
      log_warn "镜像 '$proxy_name' 不可用" >&2
      times[$i]="N/A"
      continue
    fi

    log_info "镜像 '$proxy_name' 耗时: ${curl_time}s" >&2
    times[$i]="$curl_time"
    available_indices+=("$i")

    if [[ "$(compare_floats "$curl_time" "$min_time")" == "<" ]]; then
      min_time="$curl_time"
      min_index="$i"
    fi
  done

  # 输出测试结果摘要
  echo
  if [[ ${#available_indices[@]} -eq 0 ]]; then
    log_error "所有 GitHub 镜像都不可用（测试了 ${#GITHUB_PROXIES[@]} 个镜像）" >&2
    log_error "请检查网络连接或稍后重试"
    exit 1
  fi

  log_info "找到 ${#available_indices[@]} 个可用镜像（共测试 ${#GITHUB_PROXIES[@]} 个）" >&2

  echo
  log_info "请选择要使用的 GitHub 镜像：" >&2
  for idx in "${available_indices[@]}"; do
    local proxy="${GITHUB_PROXIES[$idx]}"
    local proxy_name="${proxy:-Direct}"
    local extra=""
    if [[ "$idx" -eq "$min_index" ]]; then
      extra=" (fastest)"
    fi
    log_info "  $idx) $proxy_name  (${times[$idx]} s)${extra}" >&2
  done
  log_info "输入说明：" >&2
  log_info "  <数字>   = 本次会话使用该镜像" >&2
  log_info "  <数字>!  = 使用该镜像并记住选择（写入 ${selection_file})" >&2
  log_info "  <回车>   = 使用测速最快的镜像" >&2
  log_info "  !        = 使用最快镜像并记住选择" >&2

  read -p "[QUESTION] 你的选择: " -r user_choice

  local persistent=0
  if [[ "$user_choice" == *"!"* ]]; then
    persistent=1
    user_choice="${user_choice%!}"
  fi

  if [[ -z "$user_choice" ]]; then
    FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
    log_ok "选择最快镜像: ${FASTEST_GITHUB_PROXY:-Direct}" >&2
    if [[ $persistent -eq 1 ]]; then
      mkdir -p "$DATA_DIR"
      echo "$min_index" >"$selection_file"
      log_info "已保存该选择，后续会自动使用。要重置删除文件即可：$selection_file" >&2
    fi
  elif [[ "$user_choice" =~ ^[0-9]+$ ]]; then
    if [[ $user_choice -ge 0 && $user_choice -lt ${#GITHUB_PROXIES[@]} ]]; then
      FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$user_choice]}"
      log_ok "手动选择镜像: ${FASTEST_GITHUB_PROXY:-Direct}" >&2
      if [[ $persistent -eq 1 ]]; then
        mkdir -p "$DATA_DIR"
        echo "$user_choice" >"$selection_file"
        log_info "已保存该选择，后续会自动使用。" >&2
      fi
    else
      log_warn "输入无效，使用最快镜像。" >&2
      FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
    fi
  else
    log_warn "输入无效，使用最快镜像。" >&2
    FASTEST_GITHUB_PROXY="${GITHUB_PROXIES[$min_index]}"
  fi
}

#####################################
# 下载并安装 rtunnel
#####################################

download_and_install_rtunnel() {
  github_proxy_select

  local version
  if [[ -n "${RTUNNEL_VERSION:-}" ]]; then
    version="$RTUNNEL_VERSION"
    if [[ "$version" != v* ]]; then
      version="v${version}"
    fi
  else
    version="latest"
  fi

  log_info "使用 rtunnel 版本：$version" >&2

  # 根据操作系统和架构构建下载文件名
  local file_ext="tar.gz"
  local binary_name="rtunnel"
  
  if [[ "$OS_TYPE" == "windows" ]]; then
    file_ext="zip"
    binary_name="rtunnel.exe"
  fi
  
  local base_url="https://github.com/JingYiJun/rtunnel/releases/download/${version}/rtunnel-${OS_TYPE}-${WST_ARCH}.${file_ext}"
  local final_url
  if [[ -z "$FASTEST_GITHUB_PROXY" ]]; then
    final_url="$base_url"
  else
    local proxy="${FASTEST_GITHUB_PROXY%/}/"
    final_url="${proxy}${base_url}"
  fi

  log_info "准备从以下地址下载 rtunnel：" >&2
  log_info "  $final_url" >&2

  mkdir -p "$INSTALL_DIR"
  local tmp_file
  tmp_file="$(mktemp /tmp/rtunnel_XXXXXX.${file_ext})"

  if ! curl -fL "$final_url" -o "$tmp_file"; then
    log_error "下载 rtunnel 失败，请检查网络或镜像设置。" >&2
    rm -f "$tmp_file"
    exit 1
  fi

  log_info "正在解压 rtunnel..." >&2
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/rtunnel_extract_XXXXXX)"
  
  # 根据文件类型选择解压命令
  if [[ "$file_ext" == "zip" ]]; then
    if ! command -v unzip >/dev/null 2>&1; then
      log_error "需要 unzip 命令来解压 zip 文件，请先安装 unzip。" >&2
      rm -f "$tmp_file"
      rm -rf "$tmp_dir"
      exit 1
    fi
    if ! unzip -q "$tmp_file" -d "$tmp_dir"; then
      log_error "解压 rtunnel 失败。" >&2
      rm -f "$tmp_file"
      rm -rf "$tmp_dir"
      exit 1
    fi
  else
    if ! tar -xzf "$tmp_file" -C "$tmp_dir"; then
      log_error "解压 rtunnel 失败。" >&2
      rm -f "$tmp_file"
      rm -rf "$tmp_dir"
      exit 1
    fi
  fi

  # 查找解压后的 rtunnel 二进制文件
  local rtunnel_bin
  rtunnel_bin=$(find "$tmp_dir" -name "$binary_name" -type f | head -1)
  
  if [[ -z "$rtunnel_bin" || ! -f "$rtunnel_bin" ]]; then
    log_error "解压后的文件中未找到 rtunnel 二进制文件（查找: $binary_name）。" >&2
    rm -f "$tmp_file"
    rm -rf "$tmp_dir"
    exit 1
  fi

  local install_path="${INSTALL_DIR}/${binary_name}"
  mv "$rtunnel_bin" "$install_path"
  chmod +x "$install_path"

  # 清理临时文件
  rm -f "$tmp_file"
  rm -rf "$tmp_dir"

  log_ok "rtunnel 已安装到：$install_path" >&2
  echo "$install_path"
}

#####################################
# 检测 shell 并写入 PATH 配置到 rc_file
#####################################

detect_shell_and_configure_path() {
  local shell_path shell_name
  shell_path="${SHELL:-}"
  shell_name="${shell_path##*/}"

  local rc_file
  case "$shell_name" in
    bash)
      # macOS 上 login shell 常读 ~/.bash_profile；Linux 多为 ~/.bashrc
      if [[ -f "${HOME}/.bashrc" ]]; then
        rc_file="${HOME}/.bashrc"
      elif [[ -f "${HOME}/.bash_profile" ]]; then
        rc_file="${HOME}/.bash_profile"
      else
        rc_file="${HOME}/.bashrc"
      fi
      ;;
    zsh)
      if [[ -n "${ZDOTDIR:-}" ]]; then
        rc_file="${ZDOTDIR%/}/.zshrc"
      else
        rc_file="${HOME}/.zshrc"
      fi
      ;;
    fish)
      rc_file="${HOME}/.config/fish/config.fish"
      ;;
    *)
      rc_file="${HOME}/.profile"
      if [[ -n "$shell_name" ]]; then
        log_warn "未识别的 shell: $shell_name，使用 $rc_file"
      else
        log_warn "未检测到 SHELL 环境变量，使用 $rc_file"
      fi
      ;;
  esac

  log_info "检测到 shell: ${shell_name:-unknown}"

  # 确保 rc_file 存在
  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"

  local marker_begin marker_end
  marker_begin="# >>> rtunnel >>>"
  marker_end="# <<< rtunnel <<<"

  # 若已写入过（存在标记），则跳过
  if command -v grep >/dev/null 2>&1; then
    if grep -Fq "$marker_begin" "$rc_file" || grep -Fq "$marker_end" "$rc_file"; then
      log_ok "已检测到 $rc_file 中存在 rtunnel PATH 配置，跳过写入。"
      echo
      log_info "如需立即生效，请执行："
      echo "  source \"$rc_file\""
      echo
      return
    fi
  else
    # fallback：不用 grep（极少数环境）
    local rc_content
    rc_content="$(<"$rc_file")"
    if [[ "$rc_content" == *"$marker_begin"* || "$rc_content" == *"$marker_end"* ]]; then
      log_ok "已检测到 $rc_file 中存在 rtunnel PATH 配置，跳过写入。"
      echo
      log_info "如需立即生效，请执行："
      echo "  source \"$rc_file\""
      echo
      return
    fi
  fi

  echo >>"$rc_file"
  {
    echo "$marker_begin"
    echo "# rtunnel"
    if [[ "$shell_name" == "fish" ]]; then
      echo "fish_add_path \$HOME/.local/bin"
    else
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    echo "$marker_end"
  } >>"$rc_file"

  log_ok "已将 rtunnel PATH 配置写入：$rc_file"
  echo
  log_info "请执行以下命令使配置立即生效（或重开一个终端）："
  echo "  source \"$rc_file\""
  echo
}

#####################################
# 打印测试命令
#####################################

print_test_commands() {
  local install_path="$1"
  local binary_name="rtunnel"
  if [[ "$OS_TYPE" == "windows" ]]; then
    binary_name="rtunnel.exe"
  fi
  
  echo
  log_info "==== 测试运行命令 ===="
  if [[ "$OS_TYPE" == "windows" ]]; then
    echo "  # 检查 rtunnel 是否在 PATH 中"
    echo "  where $binary_name"
  else
    echo "  # 检查 rtunnel 是否在 PATH 中"
    echo "  which $binary_name"
  fi
  echo
  echo "  # 测试 rtunnel 是否可执行"
  echo "  $binary_name --help"
  echo
  echo "  # 如果 PATH 未配置，可以直接使用完整路径"
  echo "  $install_path --help"
  echo
}

#####################################
# 主流程
#####################################

main() {
  log_info "开始安装 rtunnel..."
  log_info "安装目录: $INSTALL_DIR"
  
  detect_os
  detect_arch
  local install_path
  install_path=$(download_and_install_rtunnel)
  
  echo
  log_ok "安装完成！"
  
  # Windows 下可能不需要 shell 配置，但 Git Bash 等环境仍可使用
  if [[ "$OS_TYPE" != "windows" ]]; then
    detect_shell_and_configure_path
  else
    log_info "Windows 系统：请确保 $INSTALL_DIR 已添加到 PATH 环境变量中"
    echo
  fi
  
  print_test_commands "$install_path"
}

main "$@"

