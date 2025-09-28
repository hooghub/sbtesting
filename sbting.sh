#!/bin/sh
# Alpine 专用 Sing-box 一键部署脚本 (最终增强版)
# Author: Chis (优化 by ChatGPT)

set -e

CONFIG_FILE="/etc/sing-box/config.json"
DATA_FILE="/etc/sing-box/data.env"
CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
echo "[✔] 检测到系统: $OS"

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 安装依赖 ---------
apk update
apk add curl wget socat openssl bash python3 py3-pip dcron
pip3 install --upgrade pip
pip3 install qrcode[pil]

# 启动 crond
rc-update add crond
rc-service crond start

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 生成 UUID 和 HY2 密码 ---------
generate_credentials() {
    [ -f "$DATA_FILE" ] && . "$DATA_FILE"
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [ -z "$HY2_PASS" ] && HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    [ -z "$VLESS_PORT" ] && VLESS_PORT=$(get_random_port)
    [ -z "$HY2_PORT" ] && HY2_PORT=$(get_random_port)
    echo "UUID=$UUID" > "$DATA_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$DATA_FILE"
    echo "VLESS_PORT=$VLESS_PORT" >> "$DATA_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$DATA_FILE"
}

generate_credentials

# --------- 菜单 ---------
while :; do
    echo "=================== Alpine Sing-box 一键部署 ==================="
    echo "1) 部署/更新 Sing-box"
    echo "2) 修改端口"
    echo "3) 切换域名模式 / 自签模式"
    echo "4) 修改域名或重新申请证书"
    echo "5) 显示当前节点 URI"
    echo "6) 刷新/重启服务"
    echo "7) 删除 Sing-box"
    echo "0) 退出"
    read -rp "请选择操作: " CHOICE

    case "$CHOICE" in
    1)
        # --------- 模式选择 ---------
        echo -e "\n请选择模式：\n1) 域名模式 (Let's Encrypt)\n2) 自签固定域名 www.epple.com"
        read -rp "请输入选项 (1/2): " MODE
        [ "$MODE" != "1" ] && [ "$MODE" != "2" ] && echo "[✖] 输入错误" && continue

        # --------- 安装 sing-box ---------
        if ! command -v sing-box >/dev/null 2>&1; then
            echo ">>> 下载并安装 Sing-box ..."
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) ARCH="amd64" ;;
                aarch64) ARCH="arm64" ;;
                *) echo "[✖] 不支持架构 $ARCH"; exit 1 ;;
            esac
            VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
            wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$VERSION/sing-box-$VERSION-linux-$ARCH.tar.gz"
            tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin sing-box
            chmod +x /usr/local/bin/sing-box
        fi

        # --------- 证书 ---------
        if [ "$MODE" = "1" ]; then
            read -rp "请输入你的域名: " DOMAIN
            DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
            [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名未解析到 VPS IP" && continue
            if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
                # 安装 acme.sh
                curl https://get.acme.sh | sh
                source ~/.bashrc || true
                /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
                /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
                    --key-file "$CERT_DIR/privkey.pem" \
                    --fullchain-file "$CERT_DIR/fullchain.pem" --force
            fi
        else
            DOMAIN="www.epple.com"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$CERT_DIR/privkey.pem" \
                -out "$CERT_DIR/fullchain.pem" \
                -subj "/CN=$DOMAIN" \
                -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
        fi

        # --------- 生成配置 ---------
        mkdir -p /etc/sing-box
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

        # --------- systemd 服务 ---------
        SERVICE_FILE="/etc/systemd/system/sing-box.service"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box

        # --------- 检查端口 ---------
        ss -tulnp | grep $VLESS_PORT && echo "[✔] VLESS TCP $VLESS_PORT 已监听"
        ss -ulnp | grep $HY2_PORT && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听"

        # --------- 生成二维码 ---------
        NODE_HOST="$SERVER_IP"
        [ "$MODE" = "1" ] && NODE_HOST="$DOMAIN"
        INSECURE=$([ "$MODE" = "2" ] && echo "1" || echo "0")
        VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
        HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"

        echo "$VLESS_URI" | python3 -m qrcode
