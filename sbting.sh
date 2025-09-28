#!/bin/sh
# Alpine 专用 Sing-box 一键脚本（无 qrencode）
# Author: Chis (优化 by ChatGPT)
set -e

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
UUID_FILE="/etc/sing-box/uuid"
HY2_FILE="/etc/sing-box/hy2_pass"
PORT_FILE="/etc/sing-box/ports"
MODE_FILE="/etc/sing-box/mode"

mkdir -p "$CERT_DIR"

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1

# --------- 检测系统 ---------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
echo "[✔] 检测到系统: $OS"

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
if [ "$OS" = "alpine" ]; then
    apk update
    apk add -y bash curl openssl socat bind-tools
else
    echo "[✖] 本脚本仅支持 Alpine"
    exit 1
fi

# --------- 获取公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && { echo "[✖] 获取公网 IP 失败"; exit 1; }
echo "[✔] 公网 IP: $SERVER_IP"

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 保存或读取 UUID/HY2/端口 ---------
if [ -f "$UUID_FILE" ]; then
    UUID=$(cat "$UUID_FILE")
else
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "$UUID" > "$UUID_FILE"
fi

if [ -f "$HY2_FILE" ]; then
    HY2_PASS=$(cat "$HY2_FILE")
else
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    echo "$HY2_PASS" > "$HY2_FILE"
fi

if [ -f "$PORT_FILE" ]; then
    . "$PORT_FILE"
else
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
fi

# --------- 模式选择 ---------
if [ -f "$MODE_FILE" ]; then
    MODE=$(cat "$MODE_FILE")
else
    echo "请选择部署模式："
    echo "1) 域名 + Let's Encrypt"
    echo "2) 公网 IP + 自签证书 (www.epple.com)"
    read -p "输入选项 (1 或 2): " MODE
    [ "$MODE" != "1" ] && MODE=2
    echo "$MODE" > "$MODE_FILE"
fi

# --------- 域名模式 ---------
if [ "$MODE" = "1" ]; then
    read -p "请输入你的域名: " DOMAIN
    [ -z "$DOMAIN" ] && { echo "[✖] 域名不能为空"; exit 1; }

    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
    [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[⚠] 域名解析不匹配 VPS IP"

    # 安装 acme.sh
    if ! command -v acme.sh >/dev/null 2>&1; then
        curl https://get.acme.sh | sh
        source ~/.profile || true
    fi

    LE_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    LE_KEY="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"

    if [ ! -f "$LE_CERT" ] || [ ! -f "$LE_KEY" ]; then
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    fi

    cp "$LE_CERT" "$CERT_DIR/fullchain.pem"
    cp "$LE_KEY" "$CERT_DIR/privkey.pem"
else
    DOMAIN="www.epple.com"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
fi

# --------- 安装 sing-box ---------
if ! command -v sing-box >/dev/null 2>&1; then
    echo "[*] 安装 sing-box..."
    curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz -o /tmp/sing-box.tar.gz
    tar -xf /tmp/sing-box.tar.gz -C /tmp
    mv /tmp/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
fi

# --------- 生成配置 ---------
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

# --------- 创建 systemd 服务 ---------
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# --------- 检查端口 ---------
ss -tuln | grep $VLESS_PORT && echo "[✔] VLESS TCP $VLESS_PORT 已监听"
ss -uln | grep $HY2_PORT && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听"

# --------- 输出节点信息 ---------
echo "=================== 节点信息 ==================="
echo "VLESS: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp"
echo "HY2  : hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$DOMAIN"
echo "==============================================="
