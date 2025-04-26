#!/bin/bash

NZ_AGENT_PATH="/opt/agent"
arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm" || $arch == "arm64" ]]; then
    arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="amd64"
    echo -e "${red}未知的系统架构: ${arch}${plain}"
fi
install_base() {
    (command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 && command -v getenforce >/dev/null 2>&1) ||
        (install_soft curl wget unzip)
}
err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}
install_agent() {
    # 调用 install_base 函数 (该函数未在此处定义，猜测是安装一些基础依赖)
    install_base


    echo "> 安装监控Agent"



    # 直接设置版本号为 v0.17.5
    _version="v0.17.5"

    # Nezha Monitoring Folder
    # 创建 Nezha Agent 的安装目录
    sudo mkdir -p $NZ_AGENT_PATH

    echo "正在下载监控端"

    NZ_AGENT_URL="https://github.com/nezhahq/agent/releases/download/${_version}/nezha-agent_linux_${arch}.zip"


    # 使用 wget 下载 Agent 的 zip 文件
    #   -t 2: 尝试下载 2 次
    #   -T 60: 超时时间为 60 秒
    #   -O nezha-agent_linux_${arch}.zip: 将下载的文件保存为指定名称
    #   >/dev/null 2>&1: 将标准输出和标准错误输出重定向到 /dev/null，即不显示下载过程
    _cmd="wget -t 2 -T 60 -O nezha-agent_linux_${arch}.zip $NZ_AGENT_URL >/dev/null 2>&1"
    if ! eval "$_cmd"; then
        # 如果下载失败，则报错并退出
        err "Release 下载失败，请检查本机能否连接 ${GITHUB_URL}"
        return 1
    fi

    # 解压下载的 zip 文件
    #  -qo: 静默解压，如果文件已存在则覆盖
    #  mv: 将解压后的 nezha-agent 移动到 $NZ_AGENT_PATH
    #  rm -rf: 删除 zip 文件和 README.md
    sudo unzip -qo nezha-agent_linux_${arch}.zip &&
    sudo mv nezha-agent $NZ_AGENT_PATH &&
    sudo rm -rf nezha-agent_linux_${arch}.zip README.md

    # 调用 modify_agent_config 函数修改 Agent 的配置文件
    #  如果参数数量大于等于 3，则将所有参数传递给 modify_agent_config
    #  否则，传递参数 0
    if [ $# -ge 3 ]; then
        modify_agent_config "$@"
    else
        modify_agent_config 0
    fi
}
modify_agent_config() {
    echo "> 修改 Agent 配置"

    if [ $# -lt 3 ]; then
        echo "请先在管理面板上添加Agent，记录下密钥"
            printf "请输入一个解析到面板所在IP的域名（不可套CDN）: "
            read -r nz_grpc_host
            printf "请输入面板RPC端口 (默认值 5555): "
            read -r nz_grpc_port
            printf "请输入Agent 密钥: "
            read -r nz_client_secret
            printf "是否启用针对 gRPC 端口的 SSL/TLS加密 (--tls)，需要请按 [y]，默认是不需要，不理解用户可回车跳过: "
            read -r nz_grpc_proxy
        echo "${nz_grpc_proxy}" | grep -qiw 'Y' && args='--tls'
        if [ -z "$nz_grpc_host" ] || [ -z "$nz_client_secret" ]; then
            err "所有选项都不能为空"
            before_show_menu
            return 1
        fi
        if [ -z "$nz_grpc_port" ]; then
            nz_grpc_port=5555
        fi
    else
        nz_grpc_host=$1
        nz_grpc_port=$2
        nz_client_secret=$3
        shift 3
        if [ $# -gt 0 ]; then
            args="$*"
        fi
    fi

    _cmd="sudo ${NZ_AGENT_PATH}/nezha-agent service install -s $nz_grpc_host:$nz_grpc_port -p $nz_client_secret $args >/dev/null 2>&1"

    if ! eval "$_cmd"; then
        sudo "${NZ_AGENT_PATH}"/nezha-agent service uninstall >/dev/null 2>&1
        sudo "${NZ_AGENT_PATH}"/nezha-agent service install -s "$nz_grpc_host:$nz_grpc_port" -p "$nz_client_secret" "$args" >/dev/null 2>&1
    fi
    
    success "Agent 配置 修改成功，请稍等 Agent 重启生效"

    #if [[ $# == 0 ]]; then
    #    before_show_menu
    #fi
}

install_base
install_agent
