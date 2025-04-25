#!/bin/sh
# Nezha Agent 自动化安装脚本
# 支持通过命令行参数配置面板信息和Agent版本
# 自动添加版本号前缀 v0.
# 使用 curl -Ls 进行下载
# 兼容 dash shell (通过exec切换到bash)
# 集成了用户提供的 service install 逻辑 (包括失败时卸载重试)
# 在服务安装成功后自动启动 Agent 服务

# --- 用户可修改的默认参数 ---
# 默认 Agent 版本，如果命令行未提供，则使用此值 (请填写纯数字，如 20.5)
DEFAULT_AGENT_VERSION="20.5"
# 默认面板域名或IP，如果命令行未提供，则使用此值
DEFAULT_GRPC_HOST="nz.luck.nyc.mn"
# 默认面板 RPC 端口，如果命令行未提供，则使用此值
DEFAULT_GRPC_PORT="443"
# 默认 Agent 密钥，如果命令行未提供，则使用此值
DEFAULT_CLIENT_SECRET="xGprpNknTducLdzZrh"
# 默认是否启用 TLS，如果命令行未提供第五个参数，则视为禁用 TLS
# 命令行传入任意非空字符串 (如 "yes", "true", "1", "--tls" 等) 即可启用 TLS
DEFAULT_TLS_ENABLED="" # 默认不启用

# --- 从命令行参数获取值，如果未提供则使用默认值 ---
AGENT_VERSION=${1:-${DEFAULT_AGENT_VERSION}}
GRPC_HOST=${2:-${DEFAULT_GRPC_HOST}}
GRPC_PORT=${3:-${DEFAULT_GRPC_PORT}}
CLIENT_SECRET=${4:-${DEFAULT_CLIENT_SECRET}}
TLS_ENABLED=${5:-${DEFAULT_TLS_ENABLED}} # 第五个参数决定是否启用 TLS

# --- 定义颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 定义 Agent 安装路径 ---
BASE_PATH="/root"
AGENT_INSTALL_PATH="${BASE_PATH}/agent"
AGENT_EXEC_NAME="agent" # Agent 程序重命名后的名称
AGENT_EXEC_PATH="${AGENT_INSTALL_PATH}/${AGENT_EXEC_NAME}" # Agent 可执行文件完整路径

# --- Helper Functions ---

# 打印信息
info() {
  printf "${YELLOW}%s${PLAIN}\n" "$*"
}

success() {
  printf "${GREEN}%s${PLAIN}\n" "$*"
}

error() {
  printf "${RED}%s${PLAIN}\n" "$*" >&2
  exit 1
}

# 检查 root 权限
check_root() {
  if [ "$EUID" -ne 0 ]; then
    error "错误：请使用 root 用户运行此脚本！"
  fi
}

# 检测系统类型和版本
check_os() {
  release=""
  os_version=""

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    release=${ID}
    os_version=${VERSION_ID}
  elif [ -f /etc/redhat-release ]; then
    release="centos"
    os_version=$(grep -oE '[0-9.]+' /etc/redhat-release | cut -d. -f1)
  elif cat /etc/issue 2>/dev/null | grep -Eqi "debian"; then
    release="debian"
    os_version=$(cat /etc/issue 2>/dev/null | grep -Eo '[0-9.]+' | cut -d. -f1)
  elif cat /etc/issue 2>/dev/null | grep -Eqi "ubuntu"; then
    release="ubuntu"
    os_version=$(cat /etc/issue 2>/dev/null | grep -Eo '[0-9.]+' | cut -d. -f1)
  elif cat /etc/issue 2>/dev/null | grep -Eqi "alpine"; then
    release="alpine"
    # Alpine version can be tricky, often relies on release file
    os_version=$(grep -Eo '[0-9.]+' /etc/alpine-release 2>/dev/null | cut -d. -f1)
  fi

  # Ensure release is lowercase
  release=$(echo "${release}" | tr '[:upper:]' '[:lower:]')

  info "检测到系统：${release} ${os_version}"

  # 版本检查
  case "${release}" in
    centos|rhel|rocky|almalinux)
      if [ -z "${os_version}" ] || [ "${os_version}" -lt 7 ]; then
        error "错误：请使用 CentOS/RHEL/Rocky/AlmaLinux 7 或更高版本的系统！"
      fi
      ;;
    ubuntu)
      if [ -z "${os_version}" ] || [ "${os_version}" -lt 16 ]; then
        error "错误：请使用 Ubuntu 16 或更高版本的系统！"
      fi
      ;;
    debian)
      if [ -z "${os_version}" ] || [ "${os_version}" -lt 8 ]; then
        error "错误：请使用 Debian 8 或更高版本的系统！"
      fi
      ;;
    alpine)
      # Alpine might work on recent versions, minimal checks here
      if [ -z "${os_version}" ]; then
           info "警告：无法确定 Alpine Linux 版本，继续尝试安装。"
      fi
      ;;
    *)
      error "错误：无法检测到或不支持您的系统类型 (${release})。当前支持 CentOS, Ubuntu, Debian, Alpine 等基于发行版。"
      ;;
  esac
}

# 检查系统架构并获取Agent支持的架构名
get_arch() {
  ARCH=$(uname -m)
  case ${ARCH} in
    x86_64 | x64 | amd64) echo "amd64" ;;
    aarch64 | arm64 | armv8b | armv8l) echo "arm64" ;;
    s390x) echo "s390x" ;;
    # Note: 386, arm, riscv64 might exist but are less common for servers
    i386 | i686) error "错误：不支持 32 位系统 (x86)。请使用 64 位系统 (x86_64)。" ;;
    arm*) error "错误：不支持旧版 ARM 架构。请使用 ARM64 (aarch64)。" ;; # Generic arm fallback as most arm* might fail
    riscv64) error "错误：不支持 RISC-V 架构。" ;; # Explicitly note unsupported
    *) error "错误：不支持的系统架构: ${ARCH}" ;;
  esac
}

# 添加 "v0." 前缀到版本号（如果尚未以 v 开头）
add_version_prefix() {
  version=$1
  # Check if it already starts with 'v' or 'V'
  if ! echo "$version" | grep -Eqi "^v"; then
    version="v0.${version}"
  fi
  echo "$version"
}

# 安装依赖 (wget, unzip, curl)
install_dependencies() {
  info "安装依赖 (wget, unzip, curl)..."
  if [ "${release}" = "centos" ] || [ "${release}" = "rhel" ] || [ "${release}" = "rocky" ] || [ "${release}" = "almalinux" ]; then
    # yum install epel-release -y >/dev/null 2>&1 # epel might not be needed for these
    yum install wget unzip curl -y >/dev/null 2>&1
  elif [ "${release}" = "alpine" ]; then
    apk update >/dev/null 2>&1
    apk add wget unzip curl >/dev/null 2>&1
  else # debian, ubuntu and other apt-based
    apt update >/dev/null 2>&1
    apt install wget unzip curl -y >/dev/null 2>&1
  fi

  # Verify curl is installed
  if ! command -v curl > /dev/null; then
    error "错误：依赖安装失败，或者 curl 命令不可用。请手动安装 curl。"
  fi
  success "依赖安装完成。"
}

# 下载 Agent 压缩包
download_agent() {
  AGENT_ARCH=$(get_arch)
  # AGENT_VERSION is already prefixed by now in main()
  AGENT_URL="https://github.com/nezhahq/agent/releases/download/${AGENT_VERSION}/nezha-agent_linux_${AGENT_ARCH}.zip"
  AGENT_ZIP="nezha-agent_linux_${AGENT_ARCH}.zip" # Using a more specific temp filename

  info "正在下载 Agent 版本 ${AGENT_VERSION} (${AGENT_ARCH})..."
  info "下载 URL: ${AGENT_URL}"

  # Use curl -Ls for silent download and follow redirects, fail on error (-f)
  if ! curl -Ls -f "$AGENT_URL" -o "$AGENT_ZIP"; then
      error "错误：下载 Agent 失败，请检查网络连接、版本号 ${AGENT_VERSION} 是否正确存在或 URL (${AGENT_URL}) 是否有效。"
  fi

  success "Agent 压缩包下载完成：${AGENT_ZIP}"
}

# 安装 Agent 可执行文件
install_agent_files() {
  AGENT_ARCH=$(get_arch)
  AGENT_ZIP="nezha-agent_linux_${AGENT_ARCH}.zip"

  info "正在安装 Agent 文件到 ${AGENT_INSTALL_PATH}..."

  # 移除旧的安装目录
  if [ -d "$AGENT_INSTALL_PATH" ]; then
      info "检测到 Agent 安装目录 ${AGENT_INSTALL_PATH} 已存在，正在移除..."
      rm -rf "$AGENT_INSTALL_PATH" || error "错误：移除旧 Agent 目录失败。"
  fi

  # 创建安装目录
  mkdir -p "$AGENT_INSTALL_PATH" || error "错误：创建 Agent 安装目录失败。"

  # 解压文件
  if ! unzip -q "$AGENT_ZIP" -d "$AGENT_INSTALL_PATH"; then
      # Clean up potentially incomplete directory on failure
      rm -rf "$AGENT_INSTALL_PATH" 2>/dev/null
      error "错误：解压 Agent 压缩包失败。请检查文件是否完整或磁盘空间。"
  fi

  # 清理下载的压缩包
  rm -f "$AGENT_ZIP"

  # 重命名并设置可执行权限
  # Agent压缩包里通常是 nezha-agent
  if [ -f "$AGENT_INSTALL_PATH/nezha-agent" ]; then
      mv "$AGENT_INSTALL_PATH/nezha-agent" "$AGENT_EXEC_PATH" || error "错误：重命名 Agent 可执行文件失败。"
  elif [ -f "$AGENT_EXEC_PATH" ]; then
      info "Agent 可执行文件已存在并命名为 ${AGENT_EXEC_NAME}，跳过重命名。"
  else
      error "错误：在解压目录中未找到 'nezha-agent' 或 '${AGENT_EXEC_NAME}' 可执行文件。"
  fi

  chmod +x "$AGENT_EXEC_PATH" || error "错误：设置 Agent 可执行文件权限失败。"

  success "Agent 文件安装完成。"
}

# 配置和安装 Agent 服务 (集成用户提供的逻辑) 并尝试启动
install_and_start_service() {
  info "正在配置和安装 Agent 服务..."

  # 根据 TLS_ENABLED 变量设置 --tls 参数
  SERVICE_INSTALL_ARGS="" # 初始化为空
  if [ -n "$TLS_ENABLED" ]; then
    SERVICE_INSTALL_ARGS="--tls"
    info "已根据参数启用 TLS 加密连接。"
  else
    info "未启用 TLS 加密连接。"
  fi

  # 构建服务安装命令字符串 (用户提供的逻辑)
  # 将 >/dev/null 2>&1 保留在命令字符串内，以保证 eval 执行时静默
  _cmd="sudo ${AGENT_INSTALL_PATH}/nezha-agent service install -s $GRPC_HOST:$GRPC_PORT -p $CLIENT_SECRET $SERVICE_INSTALL_ARGS >/dev/null 2>&1"

  info "第一次尝试安装 Agent 服务..."
  # 执行第一次安装尝试
  if eval "$_cmd"; then
      success "Agent 服务第一次安装尝试成功。"
  else
      error_code=$? # 捕获第一次安装失败的退出码

      info "Agent 服务第一次安装尝试失败 (退出码: ${error_code})。"
      info "这通常意味着服务配置已存在，尝试卸载后重新安装..."

      # 如果第一次安装失败，尝试静默卸载旧服务配置
      # || true 确保即使卸载失败（例如服务根本不存在）脚本也不会停止
      info "尝试卸载现有的 Agent 服务配置..."
      if sudo "${AGENT_INSTALL_PATH}"/nezha-agent service uninstall >/dev/null 2>&1; then
           success "旧 Agent 服务配置已卸载。"
      else
           info "卸载旧 Agent 服务配置失败或不存在（正常现象如果之前未安装）。"
      fi

      info "尝试第二次安装 Agent 服务..."
      # 尝试第二次安装
      # 直接执行命令，不需要 eval
      if sudo "${AGENT_INSTALL_PATH}"/nezha-agent service install -s "$GRPC_HOST:$GRPC_PORT" -p "$CLIENT_SECRET" "$SERVICE_INSTALL_ARGS" >/dev/null 2>&1; then
          success "Agent 服务卸载后重新安装成功。"
      else
          error "错误：Agent 服务卸载后重新安装仍然失败。请检查提供的参数或手动排查。"
          exit 1 # 安装最终失败，退出脚本
      fi
  fi

  info "Agent 服务配置完成。"

  # --- 添加启动服务的代码 ---
  # 确保 Agent 可执行文件存在且有执行权限
  if [ ! -x "$AGENT_EXEC_PATH" ]; then
      error "错误：Agent 可执行文件未在 ${AGENT_EXEC_PATH} 找到或没有执行权限。服务启动失败。"
      # 安装配置可能成功，但文件不对，不一定退出，但报告错误
      # exit 1 # 如果认为这是严重错误就取消注释
  else
      info "正在尝试启动 Agent 服务..."
      # 调用 Agent 可执行文件的 service start 命令
      # 这个命令会尝试通过系统服务管理器（systemd/SysVinit）启动服务
      if sudo "$AGENT_EXEC_PATH" service start; then
          success "Agent 服务已成功启动！"

          # 尝试设置服务开机自启 (Best effort)
          info "尝试设置 Agent 服务开机自启..."
          # systemd
          if command -v systemctl >/dev/null; then
              sudo systemctl enable nezha-agent 2>/dev/null || info "警告：使用 systemctl enable 失败（服务单元可能不是 nezha-agent），请手动设置开机自启。"
          fi
          # SysVinit chkconfig (CentOS/RHEL/类似的)
          if command -v chkconfig >/dev/null && [ -f /etc/init.d/nezha-agent ]; then
               sudo chkconfig nezha-agent on 2>/dev/null || info "警告：使用 chkconfig on 失败，请手动设置开机自启。"
          fi
          # SysVinit update-rc.d (Debian/Ubuntu/类似的)
          if command -v update-rc.d >/dev/null && [ -f /etc/init.d/nezha-agent ]; then
               sudo update-rc.d nezha-agent defaults 2>/dev/null || info "警告：使用 update-rc.d defaults 失败，请手动设置开机自启。"
          fi
          info "已尝试设置开机自启，具体是否成功取决于您的系统和服务配置。"

      else
          # 如果 Agent 自己的 start 命令失败，提示用户手动排查
          error "错误：Agent 服务启动失败。请手动执行 'sudo ${AGENT_EXEC_PATH} service start' 或检查系统服务状态 ('systemctl status nezha-agent' 或 'service nezha-agent status') 进行排查。"
          # 不立即退出，让用户看到安装成功的消息，但明确指出启动失败
          # exit 1 # 如果认为启动失败是致命错误就取消注释
      fi
  fi
  # --- 启动服务的代码结束 ---
}


# --- 主流程 ---
main() {
  # 告诉用户使用的参数
  info "======================================"
  info " Nezha Agent 安装脚本"
  info "--------------------------------------"
  info " 使用参数："
  info "   Agent 版本: ${AGENT_VERSION} (将自动处理v0.前缀)"
  info "   面板地址:   ${GRPC_HOST}:${GRPC_PORT}"
  info "   Agent 密钥: ${CLIENT_SECRET}"
  info "   启用 TLS:   ${TLS_ENABLED:+'是':'否'}" # 如果 TLS_ENABLED 非空则显示 '是'，否则显示 '否'
  info "======================================"

  check_root
  check_os
  # get_arch is called later during download

  # Add v0. prefix to the AGENT_VERSION variable before using it for download
  AGENT_VERSION=$(add_version_prefix "$AGENT_VERSION")
  info "确认下载版本号（已添加v0.前缀）：${AGENT_VERSION}"


  install_dependencies
  download_agent # Uses AGENT_VERSION and get_arch
  install_agent_files # Uses get_arch

  # Install and start the service using the parameters
  install_and_start_service # Uses GRPC_HOST, GRPC_PORT, CLIENT_SECRET, TLS_ENABLED, AGENT_INSTALL_PATH, AGENT_EXEC_PATH

  # Final success message
  success "======================================"
  success "Nezha Agent 安装脚本执行完毕！"
  success "服务安装和配置完成，并尝试启动 Agent 服务。"
  success "请根据上面的输出确认服务是否成功启动。"
  success "如果启动失败，请手动使用命令排查问题。"
  success "检查服务状态: systemctl status nezha-agent (systemd) 或 service nezha-agent status (SysVinit)"
  success "======================================"
}

# --- 确保使用 Bash 执行脚本 ---
# 这有助于避免某些shell（如dash）的兼容性问题
if [ -z "$BASH_VERSION" ]; then
    info "当前 shell 不是 bash，尝试切换到 /bin/bash 执行..."
    # 使用 exec 替换当前的 shell 进程为 bash
    exec /bin/bash "$0" "$@"
    # 如果 exec 失败，脚本将在这里继续在原始 shell 中执行
    # 但由于我们前面做了很多兼容性处理，大部分情况下应该能工作
    # 如果 exec 返回非零状态码，表示切换失败
    if [ $? -ne 0 ]; then
        error "警告：切换到 /bin/bash 失败，脚本可能无法完全按照预期执行。"
    fi
fi

# --- 运行主流程 ---
main "$@"

exit 0
