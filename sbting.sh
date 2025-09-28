#!/bin/bash
# Sing-box 一键部署 (Alpine OpenRC 专用版)
# 支持：自签/域名模式、端口/UUID/HY2密码保留、循环菜单
# Author: Chis (优化 by ChatGPT)

set -e

CONFIG_DIR="/etc/singbox"
PORT_FILE="$CONFIG_DIR/port.conf"
CERT_DIR="$CONFIG_DIR/certs"
CONF_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERT_DIR"

# --------- 检查 root ---------
[[ $EUID -ne 0 ]] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
if grep -qi alpine /etc/os-release; then
    SYSTEM="alpine"
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 仅支持 Alpine Linux" && exit 1
fi

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add curl socat wget openssl iproute2 bash dcron bind-tools --no-cache
rc-update add dcron
rc-service dcron start

# --------- 获取公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[[ -n "$SERVER_IP" ]] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 读取或生成端口/UUID/HY2密码 ---------
if [[ -f "$PORT_FILE" ]]; then
    source "$PORT_FILE"
else
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
    echo "UUID=$UUID" >> "$PORT_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$PORT_FILE"
fi

# --------- 模式选择 ---------
MODE_FILE="$CONFIG_DIR/mode.conf"
if [[ -f "$MODE_FILE" ]]; then
    source "$MODE_FILE"
else
    MODE=2 # 默认自签
    echo "MODE=$MODE" > "$MODE_FILE"
fi

# --------- 域名 / 自签证书 ---------
generate_cert() {
    if [[ "$MODE" == 1 ]]; then
        read -rp "请输入你的域名 (例如: example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && { echo "[✖] 域名不能为空"; return 1; }
        DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
        [[ -z "$DOMAIN_IP" ]] && { echo "[✖] 域名未解析"; return 1; }
        [[ "$DOMAIN_IP" != "$SERVER_IP" ]] && { echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符"; return 1; }
        echo "[✔] 域名解析正常"

        # 安装 acme.sh
        if ! command -v acme.sh &>/dev/null; then
            curl https://get.acme.sh | sh
            source ~/.bashrc || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        DOMAIN="www.epple.com"
        echo "[!] 自签模式，生成固定域名 $DOMAIN"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
}

# --------- 生成配置 ---------
generate_conf() {
cat > "$CONF_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    },
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

# --------- 安装 sing-box ---------
install_singbox() {
    if ! command -v sing-box &>/dev/null; then
        echo ">>> 安装 sing-box ..."
        curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz -o /tmp/sing-box.tar.gz
        tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin sing-box
        chmod +x /usr/local/bin/sing-box
    fi
}

# --------- OpenRC 服务 ---------
setup_openrc() {
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/singbox/config.json"
pidfile="/var/run/sing-box.pid"
name="sing-box"
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box
}

# --------- 启动服务 ---------
start_service() {
    rc-service sing-box restart || rc-service sing-box start
}

# --------- 显示 URI ---------
show_uri() {
    if [[ "$MODE" == 1 ]]; then
        NODE_HOST="$DOMAIN"
        INSECURE="0"
    else
        NODE_HOST="$SERVER_IP"
        INSECURE="1"
    fi
    echo -e "\nVLESS URI:\nvless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    echo -e "\nHY2 URI:\nhysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
}

# --------- 主菜单循环 ---------
while true; do
    echo -e "\n=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    read -rp "请输入选项: " CHOICE

    case "$CHOICE" in
        1)
            echo "请选择模式：1) 域名模式 2) 自签模式"
            read -rp "输入 (1/2): " NEW_MODE
            [[ "$NEW_MODE" =~ ^[12]$ ]] || { echo "输入错误"; continue; }
            MODE=$NEW_MODE
            echo "MODE=$MODE" > "$MODE_FILE"
            generate_cert
            generate_conf
            start_service
            show_uri
            ;;
        2)
            read -rp "输入 VLESS TCP 端口 (回车保留 $VLESS_PORT): " TMP
            [[ -n "$TMP" ]] && VLESS_PORT="$TMP"
            read -rp "输入 HY2 UDP 端口 (回车保留 $HY2_PORT): " TMP
            [[ -n "$TMP" ]] && HY2_PORT="$TMP"
            echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
            echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
            echo "UUID=$UUID" >> "$PORT_FILE"
            echo "HY2_PASS=$HY2_PASS" >> "$PORT_FILE"
            generate_conf
            start_service
            show_uri
            ;;
        3)
            [[ "$MODE" == 1 ]] || { echo "[!] 仅域名模式可重新申请证书"; continue; }
            generate_cert
            generate_conf
            start_service
            show_uri
            ;;
        4)
            generate_conf
            start_service
            show_uri
            ;;
        5)
            show_uri
            ;;
        6)
            rc-service sing-box stop || true
            rc-update del sing-box || true
            rm -rf "$CONFIG_DIR"
            echo "[✔] 已删除 Sing-box"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "输入错误"
            ;;
    esac
done

# --------- 第一次运行 ---------
install_singbox
generate_cert
generate_conf
setup_openrc
start_service
show_uri
