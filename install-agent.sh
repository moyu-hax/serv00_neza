#!/bin/sh
# 安装监控 Agent 的简化脚本 (自动添加 v0 前缀, 使用 curl -Ls, 兼容 dash)
# 解决服务配置已存在的问题，并在安装后启动服务

# 默认参数，如果命令行没有提供，则使用这些值
AGENT_VERSION=${1:-"20.5"}       # Agent 版本，默认为 20.5
GRPC_HOST=${2:-"nz.luck.nyc.mn"}    # 面板域名，默认为 nz.luck.nyc.mn
GRPC_PORT=${3:-"443"}               # 面板 RPC 端口，默认为 443
CLIENT_SECRET=${4:-"xGprpNknTducLdzZrh"} # Agent 密钥，默认为 xGprpNknTducLdzZrh
TLS=${5:-""}                      # 是否启用 TLS，默认为空 (传入任意非空字符串启用)

# 定义一些颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义 Agent 安装路径
BASE_PATH="/root"
AGENT_PATH="${BASE_PATH}/agent"

# 检查 root 权限
check_root() {
  # Using [ ... ] for better dash compatibility before exec /bin/bash
  if [ "$EUID" -ne 0 ]; then
    error "请使用 root 用户运行此脚本！"
  fi
}

# 检测系统类型
check_os() {
  release=""
  if [ -f /etc/redhat-release ]; then
    release="centos"
  elif cat /etc/issue 2>/dev/null | grep -Eqi "debian"; then
    release="debian"
  elif cat /etc/issue 2>/dev/null | grep -Eqi "ubuntu"; then
    release="ubuntu"
  elif cat /etc/issue 2>/dev/null | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
  elif cat /etc/issue 2>/dev/null | grep -Eqi "Fedora|almalinux|rocky"; then
    release="red hat"
  elif cat /proc/version 2>/dev/null | grep -Eqi "debian"; then
    release="debian"
  elif cat /proc/version 2>/dev/null | grep -Eqi "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version 2>/dev/null | grep -Eqi "alpine"; then
    release="alpine"
  elif cat /proc/version 2>/dev/null | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
  fi

  # 检查系统版本
  os_version=""
  if [ -f /etc/os-release ]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release 2>/dev/null)
  elif [ -f /etc/lsb-release ]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release 2>/dev/null)
  fi

  # 版本检查 (Using [ ... ] for better dash compatibility)
  if [ x"${release}" = x"centos" ] && [ "${os_version}" -le 6 ]; then
    error "请使用 CentOS 7 或更高版本的系统！"
  elif [ x"${release}" = x"ubuntu" ] && [ "${os_version}" -lt 16 ]; then
    error "请使用 Ubuntu 16 或更高版本的系统！"
  elif [ x"${release}" = x"debian" ] && [ "${os_version}" -lt 8 ]; then
    error "请使用 Debian 8 或更高版本的系统！"
  elif [ -z "${release}" ]; then
    error "无法检测到系统版本，可能不支持您的系统。"
  fi
}

# 检查系统架构
check_arch() {
  arch=$(arch)
  if [ "$arch" = "x86_64" ] || [ "$arch" = "x64" ] || [ "$arch" = "amd64" ]; then
    arch="amd64"
  elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm" ] || [ "$arch" = "arm64" ]; then
    arch="arm64"
  elif [ "$arch" = "s390x" ]; then
    arch="s390x"
  else
    arch="amd64"
    info "未知的系统架构: ${arch}，将使用 amd64"
  fi

  # 检查是否为 32 位系统
  if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ]; then
    error "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)"
  fi
}

# 添加 "v0." 前缀到版本号
add_version_prefix() {
  version=$1
  # Check if it already starts with v or V
  if ! echo "$version" | grep -Eqi "^v"; then
    version="v0.${version}"
  fi
  echo "$version"
}

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

# 安装依赖
install_dependencies() {
  info "安装依赖..."
  if [ "${release}" = "centos" ] || [ "${release}" = "red hat" ]; then
    # yum install epel-release -y # epel not always needed for wget/unzip
    yum install wget unzip curl -y
  elif [ "${release}" = "alpine" ]; then
    apk update
    apk add wget unzip curl
  else
    apt update
    apt install wget unzip curl -y
  fi

  # Check if curl is available
  if ! command -v curl > /dev/null; then
    error "未安装 curl，请手动安装或检查依赖安装步骤。"
  fi
}

# 获取系统架构
get_arch() {
  ARCH=$(uname -m)
  case $ARCH in
    x86_64) echo "amd64" ;;
    i386 | i686) echo "386" ;;
    aarch64 | armv8b | armv8l) echo "arm64" ;;
    arm*) echo "arm" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) error "不支持的架构: $ARCH" ;;
  esac
}

# 下载 Agent
download_agent() {
  ARCH=$(get_arch)
  # Add prefix only once, the variable $AGENT_VERSION is already prefixed in main
  AGENT_URL="https://github.com/nezhahq/agent/releases/download/${AGENT_VERSION}/nezha-agent_linux_${ARCH}.zip"
  AGENT_ZIP="agent_linux_${ARCH}.zip"

  info "下载 Agent ${AGENT_VERSION}..."
  # Use curl -Ls for silent download and follow redirects
  if ! curl -Ls "$AGENT_URL" -o "$AGENT_ZIP"; then
      error "下载失败，请检查网络或版本号 ${AGENT_VERSION} 是否正确存在。"
  fi

  echo "下载 URL: ${AGENT_URL}"
}

# 安装 Agent 文件
install_agent_files() {
  AGENT_ZIP="agent_linux_$(get_arch).zip"

  info "安装 Agent 文件到 ${AGENT_PATH}..."
  # Remove existing agent path before creating and extracting
  if [ -d "$AGENT_PATH" ]; then
      info "检测到 Agent 安装目录 ${AGENT_PATH} 已存在，正在移除..."
      rm -rf "$AGENT_PATH" || error "移除旧 Agent 目录失败。"
  fi

  mkdir -p "$AGENT_PATH" || error "创建 Agent 目录失败。"

  if ! unzip -q "$AGENT_ZIP" -d "$AGENT_PATH"; then
      error "解压 Agent 文件失败。"
  fi

  # Clean up zip file
  rm -f "$AGENT_ZIP"

  # Rename and set execute permissions
  if [ -f "$AGENT_PATH/nezha-agent" ]; then
      mv "$AGENT_PATH/nezha-agent" "$AGENT_PATH/agent" || error "重命名 Agent 文件失败。"
  elif [ -f "$AGENT_PATH/agent" ]; then
      info "Agent 文件已命名为 'agent'，跳过重命名。"
  else
      error "Agent 文件 'nezha-agent' 或 'agent' 未在解压目录中找到。"
  fi
  chmod +x "$AGENT_PATH/agent" || error "设置 Agent 可执行权限失败。"
}


# 配置和安装服务
configure_and_install_service() {
  info "配置 Agent 服务..."

  # --- 新增步骤：尝试卸载旧服务配置 ---
  info "尝试卸载现有的 Agent 服务配置 (如果存在)..."
  # Execute uninstall command, ignore errors using || true
  # This prevents the script from failing if the service wasn't previously installed
  "$AGENT_PATH/agent" service uninstall || true
  # --- 结束新增步骤 ---


  TLS_ARG="" # Initialize TLS_ARG as empty
  if [ -n "$TLS" ]; then
    TLS_ARG="--tls"
    info "已启用 TLS 加密连接。"
  else
    info "未启用 TLS 加密连接。"
  fi

  info "使用以下参数安装服务: 面板地址: $GRPC_HOST:$GRPC_PORT, 密钥: $CLIENT_SECRET, TLS: ${TLS_ARG}"

  # Install the new service configuration
  "$AGENT_PATH/agent" service install \
    -s "$GRPC_HOST:$GRPC_PORT" \
    -p "$CLIENT_SECRET" \
    ${TLS_ARG} || error "Agent 服务配置和安装失败，请检查参数和日志。"

  info "Agent 服务配置完成，正在尝试启动..."

  # --- 新增步骤：启动服务 ---
  # Try starting the service using the agent's command first
  if "$AGENT_PATH/agent" service start; then
      success "Agent 服务已成功启动。"
      # Attempt to enable the service to start on boot (best effort)
      info "尝试设置 Agent 服务开机自启..."
      if command -v systemctl > /dev/null; then
          systemctl enable nezha-agent 2>/dev/null || true # Ignore enable errors if service unit file isn't standard
          info "已尝试使用 systemctl enable."
      elif command -v chkconfig > /dev/null && [ -f /etc/init.d/nezha-agent ]; then
           chkconfig nezha-agent on 2>/dev/null || true
           info "已尝试使用 chkconfig on."
      elif command -v update-rc.d > /dev/null && [ -f /etc/init.d/nezha-agent ]; then
           update-rc.d nezha-agent defaults 2>/dev/null || true
           info "已尝试使用 update-rc.d defaults."
      else
           info "无法确定如何设置开机自启，请手动配置。"
      fi
  else
      # Fallback if agent service start command fails
      info "Agent service start command failed, attempting systemctl or service..."
      if command -v systemctl > /dev/null; then
          systemctl start nezha-agent || error "通过 systemctl 启动 Agent 失败，请手动检查服务状态。"
          systemctl enable nezha-agent 2>/dev/null || true # Enable even if start needed fallback
          success "Agent 服务已通过 systemctl 成功启动。"
      elif command -v service > /dev/null && [ -f /etc/init.d/nezha-agent ]; then
          service nezha-agent start || error "通过 service 启动 Agent 失败，请手动检查服务状态。"
          success "Agent 服务已通过 service 成功启动。"
          # SysVinit enable handled in the successful agent start block
      else
          error "Agent 服务启动失败，且无法确定如何启动服务 (systemctl或service命令不可用)。请手动启动。"
      fi
  fi
  # --- 结束新增步骤 ---
}

# 主流程
main() {
  check_root
  check_os
  check_arch
  install_dependencies

  # Add v0. prefix to the AGENT_VERSION variable before using it
  AGENT_VERSION=$(add_version_prefix "$AGENT_VERSION")

  # Display parameters being used
  info "使用参数: 版本: ${AGENT_VERSION}, 面板地址: $GRPC_HOST:$GRPC_PORT, 密钥: $CLIENT_SECRET, TLS: ${TLS:-'否'}"

  download_agent
  install_agent_files
  configure_and_install_service

  success "Nezha Agent 安装和配置完成！服务应该已经启动并设置为开机自启 (如果系统支持)。"
  success "请检查面板确认 Agent 已上线。"
}

# 告诉系统使用 bash，如果当前不是
if [ -z "$BASH_VERSION" ]; then
    info "当前 shell 不是 bash，尝试切换到 /bin/bash..."
    exec /bin/bash "$0" "$@"
    # If exec fails, the script will continue in the original shell.
    # Using [ ... ] for checks above helps compatibility if exec fails.
    # However, [[ ... ]] and command substitution might still cause issues before exec.
    # The standard practice is to put #!/bin/bash at the top, but the user explicitly requested sh compatible initially.
    # The safest is to ensure /bin/bash exists and is runnable.
    if [ $? -ne 0 ]; then
        error "切换到 /bin/bash 失败，脚本可能无法正常运行。"
    fi
fi

# 运行主流程
main "$@"

exit 0
