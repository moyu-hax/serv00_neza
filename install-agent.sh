#!/bin/bash
# 安装监控 Agent 的简化脚本 (自动添加 v0 前缀, 使用 curl -Ls, 兼容 dash)

set -e # 脚本出错时立即退出

# 默认参数，如果命令行没有提供，则使用这些值
AGENT_VERSION=${1:-"20.5"}       # Agent 版本，默认为 20.5
GRPC_HOST=${2:-"nz.luck.nyc.mn"}    # 面板域名，默认为 nz.luck.nyc.mn
GRPC_PORT=${3:-"443"}               # 面板 RPC 端口，默认为 443
CLIENT_SECRET=${4:-"xGprpNknTducLdzZrh"} # Agent 密钥，默认为 xGprpNknTducLdzZrh
TLS=${5:-""}                      # 是否启用 TLS，默认为空

# 添加 "v0." 前缀到版本号
add_version_prefix() {
  version=$1
  if ! echo "$version" | grep -q "^v"; then
    version="v0.${version}"
  fi
  echo "$version"
}

# 定义一些颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义 Agent 安装路径 (现在在 root 目录)
BASE_PATH="/root"
AGENT_PATH="${BASE_PATH}/agent"

# 检查是否需要 sudo
need_sudo() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "sudo"
  fi
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
  DEPS="curl wget unzip"
  if command -v apt-get >/dev/null 2>&1; then
    ${need_sudo} apt-get update
    ${need_sudo} apt-get install -y $DEPS
  elif command -v yum >/dev/null 2>&1; then
    ${need_sudo} yum install -y $DEPS
  elif command -v pacman >/dev/null 2>&1; then
    ${need_sudo} pacman -Sy --noconfirm $DEPS
  elif command -v apk >/dev/null 2>&1; then
    ${need_sudo} apk update
    ${need_sudo} apk add $DEPS
  else
    error "无法找到包管理器，请手动安装 curl, wget, 和 unzip。"
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
  AGENT_VERSION=$(add_version_prefix "$AGENT_VERSION")
  AGENT_URL="https://github.com/nezhahq/agent/releases/download/${AGENT_VERSION}/nezha-agent_linux_${ARCH}.zip"
  AGENT_ZIP="agent_linux_${ARCH}.zip" # 去掉 nezhahq 前缀

  info "下载 Agent..."
  ${need_sudo} curl -Ls "$AGENT_URL" -o "$AGENT_ZIP" || error "下载失败，请检查网络或版本号。"

  echo "url is ${AGENT_URL}"
  return "$AGENT_URL"
  return "$AGENT_ZIP"
}

# 安装 Agent
install_agent() {
  AGENT_URL=$(download_agent)
  AGENT_ZIP=$(basename "$AGENT_URL")

  info "安装 Agent..."
  ${need_sudo} mkdir -p "$AGENT_PATH"
  ${need_sudo} unzip -q "$AGENT_ZIP" -d "$AGENT_PATH" || error "解压失败。"
  ${need_sudo} rm -f "$AGENT_ZIP"
  ${need_sudo} mv "$AGENT_PATH"/nezha-agent "$AGENT_PATH/agent" # 确保可执行，并去掉 nezhahq 前缀
  ${need_sudo} chmod +x "$AGENT_PATH/agent"
}

# 配置 Agent
configure_agent() {
  info "配置 Agent..."
  if [ -n "$TLS" ]; then
    TLS_ARG="--tls"
  fi

  ${need_sudo} "$AGENT_PATH/agent" service install \
    -s "$GRPC_HOST:$GRPC_PORT" \
    -p "$CLIENT_SECRET" \
    ${TLS_ARG} || error "Agent 配置失败。"
}

# 主流程
main() {
  # 检查参数是否为空，设置默认值
  if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
    info "使用默认参数安装，或参数不足"
  else
    info "开始安装，IP: $GRPC_HOST， RPC端口: $GRPC_PORT， 密钥: $CLIENT_SECRET ，版本: ${AGENT_VERSION} (自动转换为 v0.${AGENT_VERSION})，加密: $TLS"
  fi

  install_dependencies
  install_agent
  configure_agent

  success "Agent 安装完成！"
}

# 告诉系统使用 bash
if [ -n "$BASH_VERSION" ]; then
  # 如果已经运行在 Bash 中，则不执行任何操作
  :
else
  # 否则，使用 exec 重新启动脚本，确保使用 Bash
  exec /bin/bash "$0" "$@"
fi

# 运行主流程
main "$@"

exit 0
