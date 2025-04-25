#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 定义颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 全局变量 ---
export VERSION=${VERSION:-'17.5'} # Default Nezha Agent version if not set externally
NZ_AGENT_PATH="/opt/nezha/agent"  # Installation path for the agent binary

# --- 函数定义 ---

# Function to detect OS release
detect_os() {
    # Default to unknown
    release="unknown"
    # Check for /etc/os-release
    if [ -f /etc/os-release ]; then
        # Source the file to get variables like ID, VERSION_ID
        . /etc/os-release
        # Use the ID field for distribution identification
        case "$ID" in
            debian|ubuntu|devuan|deepin)
                release="debian"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                release="centos" # Group RHEL-based distros
                ;;
            alpine)
                release="alpine"
                ;;
            *)
                echo -e "${YELLOW}警告：未知的 Linux 发行版 ($ID)，将尝试使用 apt 作为包管理器。${PLAIN}"
                release="debian" # Fallback assumption
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        release="centos" # Older RHEL/CentOS detection
    elif [ -f /etc/debian_version ]; then
        release="debian" # Older Debian/Ubuntu detection
    elif command -v apk &> /dev/null; then
         release="alpine" # Check if apk command exists for Alpine
    fi
     echo -e "${GREEN}检测到的操作系统: ${release}${PLAIN}"
}

# Function to install base dependencies
install_base() {
    echo "> 安装基础依赖 (wget, unzip)..."
    if [[ "${release}" == "centos" ]]; then
        yum install -y epel-release || true # Try to install EPEL, continue if it fails (might already be there or not needed)
        yum install -y wget unzip
    elif [[ "${release}" == "alpine" ]]; then
        apk update
        apk add wget unzip
    elif [[ "${release}" == "debian" ]]; then
        apt update
        apt install -y wget unzip
    else
        echo -e "${RED}错误：无法确定包管理器，请手动安装 wget 和 unzip。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}基础依赖安装完成。${PLAIN}"
}

# Function to install the Nezha agent binary
install_agent() {
    # Detect OS first
    detect_os
    # Install dependencies
    install_base

    echo "> 安装监控 Agent (版本 v0.${VERSION})..."

    # Create target directory if it doesn't exist
    echo "> 创建安装目录 ${NZ_AGENT_PATH}..."
    mkdir -p ${NZ_AGENT_PATH}

    echo "> 下载 Agent 二进制文件..."
    # Determine download URL based on architecture
    local download_url=""
    if [[ "${arch}" == "amd64" ]]; then
        download_url="https://github.com/nezhahq/agent/releases/download/v0.${VERSION}/nezha-agent_linux_amd64.zip"
    elif [[ "${arch}" == "arm64" ]]; then
        download_url="https://github.com/nezhahq/agent/releases/download/v0.${VERSION}/nezha-agent_linux_arm64.zip"
    elif [[ "${arch}" == "s390x" ]]; then
        download_url="https://github.com/nezhahq/agent/releases/download/v0.${VERSION}/nezha-agent_linux_s390x.zip"
    else
        echo -e "${RED}错误：此脚本不支持架构 ${arch} 的 Agent 下载。${PLAIN}"
        exit 1
    fi

    # Download, unzip, and move the agent
    local temp_zip="nezha-agent_temp.zip"
    wget -O "${temp_zip}" "${download_url}"
    unzip -o "${temp_zip}" -d "${NZ_AGENT_PATH}" # Extract directly to target path, overwrite if exists
    # The zip usually contains a single executable named 'nezha-agent'
    # Ensure the final binary is named correctly within the directory
    if [ -f "${NZ_AGENT_PATH}/nezha-agent" ]; then
       chmod +x "${NZ_AGENT_PATH}/nezha-agent" # Make executable
       echo -e "${GREEN}Agent 二进制文件已下载并移动到 ${NZ_AGENT_PATH}/nezha-agent${PLAIN}"
    else
       echo -e "${RED}错误：解压后未找到 nezha-agent 文件。请检查下载或解压过程。${PLAIN}"
       # Attempt to find the extracted file if named differently (less common)
       local extracted_file=$(unzip -l "${temp_zip}" | grep -oP 'nezha-agent_linux_\w+' | head -n 1)
       if [[ -n "$extracted_file" && -f "${NZ_AGENT_PATH}/${extracted_file}" ]]; then
           mv "${NZ_AGENT_PATH}/${extracted_file}" "${NZ_AGENT_PATH}/nezha-agent"
           chmod +x "${NZ_AGENT_PATH}/nezha-agent"
           echo -e "${YELLOW}警告：解压的文件名与预期不符，已尝试重命名为 nezha-agent。${PLAIN}"
           echo -e "${GREEN}Agent 二进制文件已下载并移动到 ${NZ_AGENT_PATH}/nezha-agent${PLAIN}"
       else
            rm -f "${temp_zip}" # Clean up zip even on error
            exit 1
       fi
    fi

    # Clean up the downloaded zip file
    rm -f "${temp_zip}"
    echo -e "${GREEN}临时文件清理完成。${PLAIN}"
}

# Function to configure and install the agent service
modify_agent_config() {
    echo "> 配置 Agent 服务..."

    # Ensure the agent binary exists and is executable
    if [ ! -x "${NZ_AGENT_PATH}/nezha-agent" ]; then
        echo -e "${RED}错误: Agent 执行文件 ${NZ_AGENT_PATH}/nezha-agent 未找到或不可执行。${PLAIN}"
        exit 1
    fi

    echo "请提供 Nezha 面板的连接信息:"
    printf "请输入面板服务器域名或IP (不可套CDN): "
    read -r nz_grpc_host
    printf "请输入面板 RPC 端口 (默认值 5555): "
    read -r nz_grpc_port
    # Set default port if input is empty
    [[ -z "${nz_grpc_port}" ]] && nz_grpc_port=5555
    printf "请输入 Agent 密钥 (在面板添加 Agent 后获得): "
    read -r nz_client_secret
    printf "是否启用 gRPC TLS 加密 (--tls)? (y/N，默认 N): "
    read -r nz_use_tls

    local args=""
    if [[ "${nz_use_tls}" =~ ^[Yy]$ ]]; then
        args="--tls"
        echo "> TLS 已启用。"
    else
        echo "> TLS 未启用。"
    fi

    # Check if required inputs are provided
    if [ -z "$nz_grpc_host" ] || [ -z "$nz_client_secret" ]; then
        echo -e "${RED}错误: 域名/IP 和 Agent 密钥不能为空。${PLAIN}"
        exit 1
    fi

    echo "> 正在安装 Agent 系统服务..."
    # Construct the command
    local install_cmd="sudo ${NZ_AGENT_PATH}/nezha-agent service install -s ${nz_grpc_host}:${nz_grpc_port} -p ${nz_client_secret} ${args}"

    echo "将执行命令: ${install_cmd}"

    # Attempt to install the service
    # Redirect output only if successful, show errors otherwise
    if ! ${install_cmd}; then
        echo -e "${YELLOW}警告：首次尝试安装服务失败。正在尝试卸载可能存在的旧服务并重新安装...${PLAIN}"
        # Attempt uninstall (ignore errors) and then install again
        sudo "${NZ_AGENT_PATH}"/nezha-agent service uninstall >/dev/null 2>&1 || true
        if ! ${install_cmd}; then
            echo -e "${RED}错误：Agent 服务安装失败。请检查上面的错误信息和您的输入。${PLAIN}"
            exit 1
        fi
    fi

    echo -e "${GREEN}Agent 服务配置并安装成功！${PLAIN}"
    echo -e "${GREEN}请稍等片刻，Agent 应该会在 Nezha 面板上线。${PLAIN}"
    echo -e "${GREEN}您可以使用 'sudo systemctl status nezha-agent' (或 'sudo service nezha-agent status') 查看服务状态。${PLAIN}"
}

# --- 主逻辑 ---

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 请使用 root 用户运行此脚本！\n" && exit 1

# 检测系统架构
arch=$(arch)
echo "> 检测到系统架构: ${arch}"

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then # Combined arm and aarch64
    arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    echo -e "${YELLOW}警告：未知的系统架构 (${arch})，将尝试使用 amd64。${PLAIN}"
    arch="amd64"
fi
echo "> 标准化架构为: ${arch}"

# 检查是否为 64 位系统
if [ "$(uname -m)" != 'x86_64' ] && [ "$(uname -m)" != 'aarch64' ] && [ "$(uname -m)" != 's390x' ]; then
     if [ "$(getconf WORD_BIT)" = '32' ] || [ "$(getconf LONG_BIT)" = '32' ]; then
        echo -e "${RED}错误：本软件不支持 32 位系统 (${arch})，请使用 64 位系统。${PLAIN}"
        exit 1
    fi
     # If uname -m is something else but getconf says it's 64 bit, let it proceed with caution
     echo -e "${YELLOW}警告：系统架构检测可能不完全准确 ($(uname -m))，但系统报告为 64 位。继续尝试...${PLAIN}"
fi

# 执行安装和配置
install_agent
modify_agent_config

echo -e "${GREEN}Nezha Agent 安装脚本执行完毕。${PLAIN}"

exit 0
