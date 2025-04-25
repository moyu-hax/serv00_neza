#!/bin/bash
export UUID=${UUID:-'333cdcf3-4520-4b74-839b-fd4ccd472b14'} # 哪吒v1，在不同的平台需要改UUID，否则会覆盖 (Nezha v1, need to change UUID on different platforms, otherwise it will overwrite)
export NEZHA_SERVER=${NEZHA_SERVER:-'nz.luck.nyc.mn'}       # v1哪吒填写形式：nezha.abc.com:8008,v0哪吒填写形式：nezha.abc.com (v1 Nezha format: nezha.abc.com:8008, v0 Nezha format: nezha.abc.com)
export NEZHA_PORT=${NEZHA_PORT:-'443'}           # v1哪吒不要填写这个,v0哪吒agent端口为{443,8443,2053,2083,2087,2096}其中之一时自动开启tls (v1 Nezha don't fill this, v0 Nezha agent port enables TLS automatically if it's one of {443,8443,2053,2083,2087,2096})
export NEZHA_KEY=${NEZHA_KEY:-'UwjaSb5jzsjXkRaVjw'}             # v1的NZ_CLIENT_SECRET或v0的agent密钥 (v1's NZ_CLIENT_SECRET or v0's agent key)
export ARGO_DOMAIN=${ARGO_DOMAIN:-'kvmi7.xcx.pp.ua'}         # 固定隧道域名,留空即启用临时隧道 (Fixed tunnel domain, leave empty to enable temporary tunnel)
export ARGO_AUTH=${ARGO_AUTH:-'{"AccountTag":"2288aa590e1341e5682c3b3e58731b84","TunnelSecret":"XczzA0u8PDFYXyXA/6g4j2OZQIz1jBbUt4RmSH63tPU=","TunnelID":"3628e4bc-56c3-4741-8b6a-1e7275d1f79d","Endpoint":""}'}             # 固定隧道token或json,留空即启用临时隧道 (Fixed tunnel token or json, leave empty to enable temporary tunnel)
export CFIP=${CFIP:-'cloudflare.182682.xyz'}        # argo节点优选域名或优选ip (Argo node preferred domain or IP)
export CFPORT=${CFPORT:-'443'}                # argo节点端口 (Argo node port)
export NAME=${NAME:-'Vls'}                    # 节点名称 (Node name)
export FILE_PATH=${FILE_PATH:-'./.cache'}     # sub 路径 (Subscription path)
export ARGO_PORT=${ARGO_PORT:-'8001'}         # argo端口 使用固定隧道token,cloudflare后台设置的端口需和这里对应 (Argo port, if using fixed tunnel token, the port set in Cloudflare dashboard needs to match this)
export TUIC_PORT=${TUIC_PORT:-'40000'}        # Tuic 端口，支持多端口玩具可填写，否则不动 (Tuic port, fill if multi-port is supported, otherwise leave unchanged)
export HY2_PORT=${HY2_PORT:-'50000'}          # Hy2 端口，支持多端口玩具可填写，否则不动 (Hy2 port, fill if multi-port is supported, otherwise leave unchanged)
export REALITY_PORT=${REALITY_PORT:-'60000'}  # reality 端口,支持多端口玩具可填写，否则不动 (Reality port, fill if multi-port is supported, otherwise leave unchanged)
export CHAT_ID=${CHAT_ID:-''}                 # TG chat_id，可在https://t.me/laowang_serv00_bot 获取 (TG chat_id, can be obtained from https://t.me/laowang_serv00_bot)
export BOT_TOKEN=${BOT_TOKEN:-''}             # TG bot_token, 使用自己的bot需要填写,使用上方的bot不用填写,不会给别人发送 (TG bot_token, need to fill if using your own bot, no need to fill if using the bot above, won't send to others)
export UPLOAD_URL=${UPLOAD_URL:-''}  # 订阅自动上传地址,没有可不填,需要填部署Merge-sub项目后的首页地址,例如：https://merge.serv00.net (Subscription auto-upload address, optional, need to fill with the homepage address after deploying Merge-sub project, e.g., https://merge.serv00.net)

# Function to delete old nodes from the subscription merge service
delete_old_nodes() {
  # Return if UPLOAD_URL is empty or the old subscription file doesn't exist
  [[ -z $UPLOAD_URL || ! -f "${FILE_PATH}/sub.txt" ]] && return
  # Decode the old subscription file and grep for node URIs
  old_nodes=$(base64 -d "${FILE_PATH}/sub.txt" | grep -E '(vless|vmess|trojan|hysteria2|tuic)://')
  # Return if no old nodes found
  [[ -z $old_nodes ]] && return

  # Construct JSON payload for deletion
  json_data='{"nodes": ['
  for node in $old_nodes; do
      json_data+="\"$node\","
  done
  json_data=${json_data%,} # Remove trailing comma
  json_data+=']}'

  # Send DELETE request to the upload URL API
  curl -X DELETE "$UPLOAD_URL/api/delete-nodes" \
          -H "Content-Type: application/json" \
          -d "$json_data" > /dev/null 2>&1
}
# Call the function to delete old nodes before starting
delete_old_nodes

# Create cache directory if it doesn't exist and clean up old files
[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}" && rm -rf boot.log config.json tunnel.json tunnel.yml "${FILE_PATH}/sub.txt" >/dev/null 2>&1

# Function to configure Cloudflare Argo Tunnel
argo_configure() {
  # If ARGO_AUTH or ARGO_DOMAIN is empty, use quick tunnels (temporary)
  if [[ -z $ARGO_AUTH || -z $ARGO_DOMAIN ]]; then
    echo -e "\e[1;32mARGO_DOMAIN or ARGO_AUTH variable is empty, use quick tunnels\e[0m"
    return
  fi

  # If ARGO_AUTH looks like JSON credentials (contains TunnelSecret)
  if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
    # Write the JSON to tunnel.json
    echo $ARGO_AUTH > tunnel.json
    # Create tunnel.yml configuration file
    cat > tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$ARGO_AUTH")
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  else
    # If ARGO_AUTH doesn't look like JSON, assume it's a token (though not explicitly used here for config generation)
    echo -e "\e[1;32mARGO_AUTH mismatch TunnelSecret, use token connect to tunnel\e[0m"
  fi
}
# Call the Argo configuration function
argo_configure
wait # This command waits for background jobs, likely no effect here without prior background jobs

# Function to download necessary binaries and run them
download_and_run() {
ARCH=$(uname -m) && DOWNLOAD_DIR="." && mkdir -p "$DOWNLOAD_DIR" && FILE_INFO=()
# Determine base URL based on architecture
if [ "$ARCH" == "arm" ] || [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
    BASE_URL="https://arm64.sss.nyc.mn"
elif [ "$ARCH" == "amd64" ] || [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "x86" ]; then
    BASE_URL="https://amd64.sss.nyc.mn"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi
# Define core files to download (sing-box and cloudflared likely)
FILE_INFO=("$BASE_URL/sb web" "$BASE_URL/bot bot")

# Add Nezha agent based on configuration (v0 or v1)
if [ -n "$NEZHA_PORT" ]; then
    # Nezha v0 (uses NEZHA_PORT)
    FILE_INFO+=("$BASE_URL/agent npm")
else
    # Nezha v1 (no NEZHA_PORT, uses config file)
    FILE_INFO+=("$BASE_URL/v1 php")
    # Create Nezha v1 config file
    cat > "${FILE_PATH}/config.yml" << EOF
client_secret: ${NEZHA_KEY}
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 1
server: ${NEZHA_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: false
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${UUID}
EOF
fi
# Declare an associative array to map file types to downloaded filenames
declare -A FILE_MAP
# Function to generate a random 6-char name
generate_random_name() {
   local chars=abcdefghijklmnopqrstuvwxyz1234567890
   local name=""
   for i in {1..6}; do
       name="$name${chars:RANDOM%${#chars}:1}"
   done
   echo "$name"
}
# Function to download a file using curl or wget
download_file() {
   local URL=$1
   local NEW_FILENAME=$2

   if command -v curl >/dev/null 2>&1; then
       curl -L -sS -o "$NEW_FILENAME" "$URL"
       echo -e "\e[1;32mDownloaded $NEW_FILENAME by curl\e[0m"
   elif command -v wget >/dev/null 2>&1; then
       wget -q -O "$NEW_FILENAME" "$URL"
       echo -e "\e[1;32mDownloaded $NEW_FILENAME by wget\e[0m"
   else
       echo -e "\e[1;33mNeither curl nor wget is available for downloading\e[0m"
       exit 1
   fi
}
# Loop through the files to download
for entry in "${FILE_INFO[@]}"; do
    URL=$(echo "$entry" | cut -d ' ' -f 1)
    RANDOM_NAME=$(generate_random_name)
    NEW_FILENAME="$DOWNLOAD_DIR/$RANDOM_NAME"

    # Download the file
    download_file "$URL" "$NEW_FILENAME"

    # Make it executable
    chmod +x "$NEW_FILENAME"
    # Store the mapping (e.g., 'web' -> './abc123')
    FILE_MAP[$(echo "$entry" | cut -d ' ' -f 2)]="$NEW_FILENAME"
done
wait # Wait for potential background downloads (though download_file is synchronous)

# Generate Reality keypair using the 'web' (sing-box) binary
output=$(./"$(basename ${FILE_MAP[web]})" generate reality-keypair)
private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

# Generate self-signed TLS certificate using openssl
openssl ecparam -genkey -name prime256v1 -out "private.key"
openssl req -new -x509 -days 3650 -key "private.key" -out "cert.pem" -subj "/CN=bing.com"

# Create the main configuration file (config.json) for sing-box ('web' binary)
  cat > config.json << EOF
{
    "log": {
        "disabled": true,
        "level": "info",
        "timestamp": true
    },
    "dns": {
        "servers": [
        {
            "tag": "google",
            "address": "tls://8.8.8.8"
        }
      ]
    },
    "inbounds": [
    { // Vmess over WebSocket for Argo Tunnel
      "tag": "vmess-ws-in",
      "type": "vmess",
      "listen": "::",
      "listen_port": ${ARGO_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    { // TUIC v5 inbound
      "tag": "tuic-in",
      "type": "tuic",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "password": "admin" // Hardcoded password
        }
      ],
      "congestion_control": "bbr", // BBR congestion control
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "cert.pem", // Generated certificate
        "key_path": "private.key" // Generated private key
      }
    },
    { // Hysteria2 inbound
      "tag": "hysteria2-in",
      "type": "hysteria2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
         {
             "password": "${UUID}" // Uses UUID as password
         }
      ],
      "masquerade": "https://bing.com", // Masquerade as bing.com
      "tls": {
            "enabled": true,
            "alpn": [
                "h3"
            ],
            "certificate_path": "cert.pem", // Generated certificate
            "key_path": "private.key" // Generated private key
        }
      },
      { // VLESS Reality inbound
        "tag": "vless-reality-vesion",
        "type": "vless",
        "listen": "::",
        "listen_port": $REALITY_PORT,
          "users": [
              {
                  "uuid": "$UUID",
                  "flow": "xtls-rprx-vision" // Vision flow control
              }
          ],
          "tls": {
              "enabled": true,
              "server_name": "www.nazhumi.com", // SNI for outer TLS handshake
              "reality": {
                  "enabled": true,
                  "handshake": {
                      "server": "www.nazhumi.com", // Real server to handshake with
                      "server_port": 443
                  },
                  "private_key": "$private_key", // Generated Reality private key
                  "short_id": [ // Optional short IDs
                      ""
                  ]
              }
          }
      }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    { // Hardcoded WARP WireGuard outbound
      "type": "wireguard",
      "tag": "wireguard-out",
      "server": "162.159.192.200", // WARP IP
      "server_port": 4500, // WARP Port (example, might vary)
      "local_address": [
        "172.16.0.2/32",
        "2606:4700:110:8f77:1ca9:f086:846c:5f9e/128" // WARP IPv6 example
      ],
      "private_key": "wIxsZdR2nMdA7a2Ul3XQcniSfSZqdqjPb6w6opvf5AU=", // Hardcoded WARP private key
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", // Hardcoded WARP public key
      "reserved": [126, 246, 173] // Hardcoded WARP reserved bytes
    }
  ],
  "route": {
    "rule_set": [
      { // Rule for Netflix
        "tag": "netflix",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/netflix.srs",
        "download_detour": "direct" // Download rules via direct connection
      },
      { // Rule for OpenAI
        "tag": "openai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs",
        "download_detour": "direct" // Download rules via direct connection
      }
    ],
    "rules": [
      { // Route Netflix and OpenAI traffic through WARP
        "rule_set": ["netflix", "openai"],
        "outbound": "wireguard-out"
      }
    ],
    "final": "direct" // Default traffic goes direct
  }
}
EOF

# Run the 'web' (sing-box) binary in the background
if [ -e "$(basename ${FILE_MAP[web]})" ]; then
    nohup ./"$(basename ${FILE_MAP[web]})" run -c config.json >/dev/null 2>&1 &
    sleep 2 # Wait for sing-box to start
    echo -e "\e[1;32m$(basename ${FILE_MAP[web]}) is running\e[0m"
fi

# Run the 'bot' (cloudflared) binary in the background
if [ -e "$(basename ${FILE_MAP[bot]})" ]; then
    # Determine cloudflared arguments based on ARGO_AUTH
    if [[ $ARGO_AUTH =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
      # Looks like a token
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
    elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
      # Looks like JSON credentials
      args="tunnel --edge-ip-version auto --config tunnel.yml run"
    else
      # Assume quick/temporary tunnel
      args="tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --logfile boot.log --loglevel info --url http://localhost:${ARGO_PORT}"
    fi
    # Run cloudflared with determined arguments
    nohup ./"$(basename ${FILE_MAP[bot]})" $args >/dev/null 2>&1 &
    sleep 2 # Wait for cloudflared to start
    echo -e "\e[1;32m$(basename ${FILE_MAP[bot]}) is running\e[0m"
fi

# Run the Nezha agent ('npm' or 'php') in the background if configured
if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_PORT" ] && [ -n "$NEZHA_KEY" ]; then
    # Nezha v0 configuration
    if [ -e "$(basename ${FILE_MAP[npm]})" ]; then
      # Check if port requires TLS for v0
      tlsPorts=("443" "8443" "2096" "2087" "2083" "2053")
      [[ " ${tlsPorts[*]} " =~ " ${NEZHA_PORT} " ]] && NEZHA_TLS="--tls" || NEZHA_TLS=""
      # Set TMPDIR (needed by some nezha-agent versions)
      export TMPDIR=$(pwd)
      # Run Nezha v0 agent
      nohup ./"$(basename ${FILE_MAP[npm]})" -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} >/dev/null 2>&1 &
      sleep 2
      echo -e "\e[1;32m$(basename ${FILE_MAP[npm]}) is running\e[0m"
    fi
elif [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
    # Nezha v1 configuration
    if [ -e "$(basename ${FILE_MAP[php]})" ]; then
      # Run Nezha v1 agent with its config file
      nohup ./"$(basename ${FILE_MAP[php]})" -c "${FILE_PATH}/config.yml" >/dev/null 2>&1 &
      echo -e "\e[1;32m$(basename ${FILE_MAP[php]}) is running\e[0m"
    fi
else
    # Nezha not configured
    echo -e "\e[1;35mNEZHA variable is empty, skipping running\e[0m"
fi
# Remove downloaded binaries after launching them
for key in "${!FILE_MAP[@]}"; do
    if [ -e "$(basename ${FILE_MAP[$key]})" ]; then
        rm -rf "$(basename ${FILE_MAP[$key]})" >/dev/null 2>&1
    fi
done
}
# Call the main download and run function
download_and_run

# Function to get the Argo Tunnel domain name
get_argodomain() {
  # If ARGO_AUTH is set (persistent tunnel), use the defined ARGO_DOMAIN
  if [[ -n $ARGO_AUTH ]]; then
    echo "$ARGO_DOMAIN"
  else
    # Otherwise, extract the temporary domain from cloudflared logs
    local retry=0
    local max_retries=6
    local argodomain=""
    while [[ $retry -lt $max_retries ]]; do
      ((retry++))
      # Extract *.trycloudflare.com from boot.log
      argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' boot.log)
      if [[ -n $argodomain ]]; then
        break
      fi
      sleep 1
    done
    echo "$argodomain"
  fi
}

# Function to send the generated subscription to Telegram
send_telegram() {
  # Return if subscription file doesn't exist
  [ ! -f "${FILE_PATH}/sub.txt" ] || return
  # Read subscription content (base64 encoded)
  MESSAGE=$(cat "${FILE_PATH}/sub.txt")
  # Format the message for Telegram (Markdown)
  LOCAL_MESSAGE="***${NAME} 节点部署完成***%0A\`\`\`${MESSAGE}\`\`\`" # Node deployment complete
  # Use user's bot if BOT_TOKEN and CHAT_ID are set
  if [ -n "${BOT_TOKEN}" ] && [ -n "${CHAT_ID}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}&text=${LOCAL_MESSAGE}&parse_mode=Markdown" > /dev/null
  # Use public relay bot if only CHAT_ID is set
  elif [ -n "${CHAT_ID}" ]; then
    curl -s -X POST "http://api.tg.gvrander.eu.org/api/notify" \
      -H "Authorization: Bearer eJWRgxC4LcznKLiUiDoUsw@nMgDBCCSuk6Iw0S9Pbs" \ # Hardcoded Bearer token
      -H "Content-Type: application/json" \
      -d "$(printf '{"chat_id": "%s", "message": "%s"}' "${CHAT_ID}" "${LOCAL_MESSAGE}")" > /dev/null
  else
    # No Telegram info provided
    echo -e "\n\e[1;35mTG variable is empty, skipping send\e[0m"
    return
  fi

  # Check if sending was successful (curl exit code 0)
  if [ $? -eq 0 ]; then
    echo -e "\n\e[1;32mNodes sent to TG successfully\e[0m"
  else
    echo -e "\n\e[1;31mFailed to send nodes to TG\e[0m"
  fi
}

# Function to upload generated nodes to the subscription merge service
upload_nodes() {
    # Return if UPLOAD_URL is empty or the node list file doesn't exist
    [[ -z $UPLOAD_URL || ! -f "${FILE_PATH}/list.txt" ]] && return
    # Read the raw node list
    content=$(cat ${FILE_PATH}/list.txt)
    # Extract node URIs
    nodes=$(echo "$content" | grep -E '(vless|vmess|trojan|hysteria2|tuic)://')
    # Return if no nodes found
    [[ -z $nodes ]] && return
    # Convert space-separated nodes to array (needed for loop)
    nodes=($nodes)
    # Construct JSON payload for adding nodes
    json_data='{"nodes": ['
    for node in "${nodes[@]}"; do
        json_data+="\"$node\","
    done
    json_data=${json_data%,} # Remove trailing comma
    json_data+=']}'

    # Send POST request to the upload URL API
    curl -s -X POST "$UPLOAD_URL/api/add-nodes" \
         -H "Content-Type: application/json" \
         -d "$json_data" > /dev/null 2>&1

    # Check if upload was successful
    if [[ $? -eq 0 ]]; then
        echo -e "\033[1;32mNodes uploaded successfully\033[0m"
    else
        echo -e "\033[1;31mFailed to upload nodes\033[0m"
    fi
}

# --- Main Script Execution ---

# Get the Argo domain (either fixed or temporary)
argodomain=$(get_argodomain)
echo -e "\e[1;32mArgoDomain:\e[1;35m${argodomain}\e[0m\n"
sleep 1
# Get Public IP (IPv4 preferred, fallback IPv6, fallback XXX)
IP=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 1 api.ipify.org || { ipv6=$(curl -s --max-time 1 ipv6.ip.sb); echo "[$ipv6]"; } || echo "XXX")
# Get ISP info from Cloudflare speed test metadata
ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F\" '{print $26" "$18}' | sed -e 's/ /_/g' || echo "0.0")

# Construct Vmess JSON payload (for WS through Argo)
VMESS="{ \"v\": \"2\", \"ps\": \"${NAME}-${ISP}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2048\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"\"}"

# Create the raw node list file and add the Vmess node (base64 encoded)
cat > ${FILE_PATH}/list.txt <<EOF
vmess://$(echo "$VMESS" | base64 -w0)
EOF

# Add TUIC node if port is non-default
if [ "$TUIC_PORT" != "40000" ]; then
  echo -e "\ntuic://${UUID}:admin@${IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr#${NAME}-${ISP}" >> ${FILE_PATH}/list.txt
fi

# Add Hysteria2 node if port is non-default
if [ "$HY2_PORT" != "50000" ]; then
  echo -e "\nhysteria2://${UUID}@${IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#${NAME}-${ISP}" >> ${FILE_PATH}/list.txt
fi

# Add VLESS Reality node if port is non-default
if [ "$REALITY_PORT" != "60000" ]; then
  echo -e "\nvless://${UUID}@${IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&type=tcp&headerType=none#${NAME}-${ISP}" >> ${FILE_PATH}/list.txt
fi

# Base64 encode the entire list to create the final subscription file
base64 -w0 ${FILE_PATH}/list.txt > ${FILE_PATH}/sub.txt
# Print the base64 subscription content to stdout
cat ${FILE_PATH}/sub.txt
echo -e "\n\n\e[1;32m${FILE_PATH}/sub.txt saved successfully\e[0m"
# Upload nodes if configured
upload_nodes
# Send subscription to Telegram if configured
send_telegram
echo -e "\n\e[1;32mRunning done!\e[0m\n"
sleep 10 # Keep running for 10 seconds

# Clean up temporary files
rm -rf boot.log config.json sb.log core fake_useragent_0.2.0.json ${FILE_PATH}/list.txt >/dev/null 2>&1
