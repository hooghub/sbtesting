#!/bin/sh
# Sing-box 一键部署 (Alpine OpenRC 完整版)
# 无 qrencode，无 systemd
# 支持自签/域名模式，端口/UUID/HY2密码保留，循环菜单
# Author: ChatGPT + Chis

CONF_DIR="/etc/singbox"
PORT_FILE="$CONF_DIR/port.conf"
CONFIG_FILE="$CONF_DIR/config.json"
CERT_DIR="$CONF_DIR/cert"

mkdir -p "$CONF_DIR" "$CERT_DIR"

echo "=================== Sing-box 部署前环境检查 ==================="

# 1️⃣ 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "[✖] 请用 root 权限运行"
  exit 1
else
  echo "[✔] Root 权限 OK"
fi

# 2️⃣ 检测系统
if [ -f /etc/alpine-release ]; then
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 当前系统非 Alpine，退出"
    exit 1
fi

# 3️⃣ 检测公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
if [ -n "$SERVER_IP" ]; then
    echo "[✔] 检测到公网 IP: $SERVER_IP"
else
    echo "[✖] 获取公网 IP 失败"
    exit 1
fi

# 4️⃣ 安装依赖 (openssl、iproute2、curl、socat、wget、dig、bash、dcron)
echo "[*] 安装依赖..."
apk update
apk add openssl iproute2 curl socat wget bind-tools bash dcron

# 启动 dcron
rc-update add dcron
rc-service dcron start

# 5️⃣ 判断端口/UUID/HY2密码是否已存在
if [ -f "$PORT_FILE" ]; then
    VLESS_PORT=$(awk '{print $1}' "$PORT_FILE")
    HY2_PORT=$(awk '{print $2}' "$PORT_FILE")
    UUID=$(awk '{print $3}' "$PORT_FILE")
    HY2_PASS=$(awk '{print $4}' "$PORT_FILE")
    MODE=$(awk '{print $5}' "$PORT_FILE")
    DOMAIN=$(awk '{print $6}' "$PORT_FILE")
else
    # 随机端口
    get_random_port() {
        while :; do
            PORT=$((RANDOM%50000+10000))
            ss -tuln | grep -q ":$PORT" || break
        done
        echo $PORT
    }
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE=2
    DOMAIN="www.epple.com"
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
fi

# 6️⃣ 安装 sing-box (tar.gz 方式)
if ! command -v sing-box >/dev/null 2>&1; then
    echo "[*] 安装 sing-box..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_TAG="amd64" ;;
        aarch64) ARCH_TAG="arm64" ;;
        *) echo "[✖] Unsupported architecture $ARCH"; exit 1 ;;
    esac
    URL="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${ARCH_TAG}.tar.gz"
    wget -qO- "$URL" | tar xz -C /usr/local/bin/ --strip-components=1 sing-box
    chmod +x /usr/local/bin/sing-box
fi

# 7️⃣ 证书生成
generate_cert() {
    if [ "$MODE" = "1" ]; then
        # 域名模式
        if ! command -v acme.sh >/dev/null 2>&1; then
            echo "[*] 安装 acme.sh..."
            curl https://get.acme.sh | sh
            export PATH="$HOME/.acme.sh:$PATH"
        fi
        read -rp "请输入域名: " DOMAIN
        DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
        if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
            echo "[✖] 域名解析不匹配 VPS 公网 IP"
            exit 1
        fi
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        # 自签模式
        DOMAIN="www.epple.com"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
}

generate_cert

# 8️⃣ 生成 sing-box 配置
cat > "$CONFIG_FILE" <<EOF
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

# 9️⃣ OpenRC 服务文件
SERVICE_FILE="/etc/init.d/sing-box"
cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/singbox/config.json"
pidfile="/var/run/sing-box.pid"
name="sing-box"
EOF
chmod +x "$SERVICE_FILE"
rc-update add sing-box default
rc-service sing-box restart

# 10️⃣ 菜单循环
while :; do
    echo "=================== Sing-box 菜单 ==================="
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
            MODE=$([ "$MODE" = 1 ] && echo 2 || echo 1)
            echo "切换模式为 $([ "$MODE" = 1 ] && echo "域名模式" || echo "自签模式")"
            generate_cert
            ;;
        2)
            read -rp "请输入 VLESS 端口: " VLESS_PORT
            read -rp "请输入 HY2 端口: " HY2_PORT
            ;;
        3)
            [ "$MODE" = 1 ] && generate_cert || echo "[!] 自签模式无需证书"
            ;;
        4)
            rc-service sing-box restart
            ;;
        5)
            NODE_HOST=$([ "$MODE" = 1 ] && echo "$DOMAIN" || echo "$SERVER_IP")
            INSECURE=$([ "$MODE" = 1 ] && echo 0 || echo 1)
            echo "VLESS URI: vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
            echo "HY2 URI: hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
            ;;
        6)
            rc-service sing-box stop
            rc-update del sing-box
            rm -rf "$CONF_DIR" "$SERVICE_FILE"
            echo "[✔] Sing-box 已删除"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[!] 无效输入"
            ;;
    esac
    # 保存端口/UUID/HY2密码/模式/域名
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
    # 重新生成配置
    cat > "$CONFIG_FILE" <<EOF
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
    rc-service sing-box restart
done
