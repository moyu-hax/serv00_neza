#!/bin/sh
# 安装监控 Agent 的简化脚本 (自动添加 v0 前缀, 使用 curl -Ls, 兼容 dash)

# 默认参数，如果命令行没有提供，则使用这些值
AGENT_VERSION=${1:-"20.5"}       # Agent 版本，默认为 20.5
GRPC_HOST=${2:-"nz.luck.nyc.mn"}    # 面板域名，默认为 nz.luck.nyc.mn
GRPC_PORT=${3:-"443"}               # 面板 RPC 端口，默认为 443
CLIENT_SECRET=${4:-"xGprpNknTducLdzZrh"} # Agent 密钥，默认为 xGprpNknTducLdzZrh
TLS=${5:-""}                      # 是否启用 TLS，默认为空

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
  if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本！"
  fi
}

# 检测系统类型
check_os() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
  elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
  elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
  elif cat /etc/issue | grep -Eqi "Fedora|almalinux|rocky"; then
    release="red hat"
  elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
  elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version | grep -Eqi "alpine"; then
    release="alpine"
  elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
  fi

  # 检查系统版本
  os_version=""
  if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
  elif [[ -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
  fi

  # 版本检查
  if [[ x"${release}" == x"centos" && ${os_version} -le 6 ]]; then
    error "请使用 CentOS 7 或更高版本的系统！"
  elif [[ x"${release}" == x"ubuntu" && ${os_version} -lt 16 ]]; then
    error "请使用 Ubuntu 16 或更高版本的系统！"
  elif [[ x"${release}" == x"debian" && ${os_version} -lt 8 ]]; then
    error "请使用 Debian 8 或更高版本的系统！"
  fi
}

# 检查系统架构
check_arch() {
  arch=$(arch)
  if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
  elif [[ $arch == "aarch64" || $arch == "arm" || $arch == "arm64" ]]; then
    arch="arm64"
  elif [[ $arch == "s390x" ]]; then
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
  if ! echo "$version" | grep -q "^v"; then
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
  if [[ "${release}" == "centos" ]]; then
    yum install epel-release -y
    yum install wget unzip -y
  elif [[ "${release}" == "alpine" ]]; then
    apk update
    apk add wget unzip
  else
    apt update
    apt install wget unzip -y
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
  AGENT_ZIP="agent_linux_${ARCH}.zip"

  info "下载 Agent..."
  curl -Ls "$AGENT_URL" -o "$AGENT_ZIP" || error "下载失败，请检查网络或版本号。"

  echo "url is ${AGENT_URL}"
}

# 安装 Agent
install_agent() {
  download_agent
  AGENT_ZIP="agent_linux_$(get_arch).zip"

  info "安装 Agent..."
  mkdir -p "$AGENT_PATH"
  unzip -q "$AGENT_ZIP" -d "$AGENT_PATH" || error "解压失败。"
  rm -f "$AGENT_ZIP"
  mv "$AGENT_PATH"/nezha-agent "$AGENT_PATH/agent"
  chmod +x "$AGENT_PATH/agent"
}

# 配置 Agent
configure_agent() {
  info "配置 Agent..."
  if [ -n "$TLS" ]; then
    TLS_ARG="--tls"
  fi

  "$AGENT_PATH/agent" service install \
    -s "$GRPC_HOST:$GRPC_PORT" \
    -p "$CLIENT_SECRET" \
    ${TLS_ARG} || error "Agent 配置失败。"
}

# 主流程
main() {
  check_root
  check_os
  check_arch

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
if [ -z "$BASH_VERSION" ]; then
    exec /bin/bash "$0" "$@"
fi

# 运行主流程
main "$@"

exit 0
