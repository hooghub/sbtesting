#!/bin/sh
# Alpine 专用 Sing-box 一键部署脚本
# 支持: 域名/自签、自定义端口、UUID/HY2密码保留、循环菜单
# Author: Chis + ChatGPT 优化

set -e

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
UUID_FILE="/etc/sing-box/.uuid"
HY2_PASS_FILE="/etc/sing-box/.hy2pass"
VLESS_PORT_FILE="/etc/sing-box/.vlessport"
HY2_PORT_FILE="/etc/sing-box/.hy2port"
DOMAIN_FILE="/etc/sing-box/.domain"
MODE_FILE="/etc/sing-box/.mode"

mkdir -p "$CERT_DIR"

echo "[✔] 检测系统类型..."
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    echo "[✔] 系统: Alpine"
else
    echo "[✖] 仅支持 Alpine 系统"
    exit 1
fi

install_deps() {
    echo "[*] 安装依赖..."
    apk update -U
    apk add curl socat wget openssl bind-tools bash systemd >/dev/null
    # Alpine 默认 dcron 已安装，无需 cronie
}

install_deps

get_public_ip() {
    SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
    if [ -n "$SERVER_IP" ]; then
        echo "[✔] 公网 IP: $SERVER_IP"
    else
        echo "[✖] 无法获取公网 IP"
        exit 1
    fi
}

get_public_ip

# 随机端口生成
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        if ! ss -tuln | grep -q ":$PORT"; then
            break
        fi
    done
    echo $PORT
}

# UUID / HY2 密码初始化
init_uuid_hy2() {
    [ ! -f "$UUID_FILE" ] && cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
    [ ! -f "$HY2_PASS_FILE" ] && openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' > "$HY2_PASS_FILE"
    UUID=$(cat "$UUID_FILE")
    HY2_PASS=$(cat "$HY2_PASS_FILE")
}

# 端口初始化
init_ports() {
    [ ! -f "$VLESS_PORT_FILE" ] && get_random_port > "$VLESS_PORT_FILE"
    [ ! -f "$HY2_PORT_FILE" ] && get_random_port > "$HY2_PORT_FILE"
    VLESS_PORT=$(cat "$VLESS_PORT_FILE")
    HY2_PORT=$(cat "$HY2_PORT_FILE")
}

# 模式/域名初始化
init_mode_domain() {
    [ ! -f "$MODE_FILE" ] && echo "2" > "$MODE_FILE"
    MODE=$(cat "$MODE_FILE")
    if [ "$MODE" = "1" ]; then
        [ ! -f "$DOMAIN_FILE" ] && read -rp "请输入域名: " DOMAIN && echo "$DOMAIN" > "$DOMAIN_FILE"
        DOMAIN=$(cat "$DOMAIN_FILE")
    else
        DOMAIN="www.epple.com"
    fi
}

init_uuid_hy2
init_ports
init_mode_domain

# 安装 Sing-box
install_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "[*] 安装 Sing-box..."
        SING_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | head -1 | cut -d '"' -f4)
        wget -qO /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SING_VER/sing-box-$SING_VER-linux-amd64.tar.gz"
        tar xzf /tmp/sing-box.tar.gz -C /usr/local/bin sing-box
        chmod +x /usr/local/bin/sing-box
    fi
}

install_singbox

# 生成/导入证书
generate_cert() {
    if [ "$MODE" = "1" ]; then
        # 域名模式
        if ! command -v acme.sh >/dev/null 2>&1; then
            echo "[*] 安装 acme.sh ..."
            curl https://get.acme.sh | sh
            source ~/.bashrc || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        LE_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
        LE_KEY="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
        if [ ! -f "$LE_CERT" ] || [ ! -f "$LE_KEY" ]; then
            /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
            /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
                --key-file "$CERT_DIR/privkey.pem" \
                --fullchain-file "$CERT_DIR/fullchain.pem" --force
        else
            cp "$LE_CERT" "$CERT_DIR/fullchain.pem"
            cp "$LE_KEY" "$CERT_DIR/privkey.pem"
        fi
    else
        # 自签模式
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
}

generate_cert

# 生成 Sing-box 配置
generate_config() {
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
}

generate_config

# 创建 systemd 服务
create_service() {
cat > /etc/systemd/system/sing-box.service <<EOF
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
}

create_service

# 循环菜单
while :; do
echo "===================== Sing-box 菜单 ====================="
echo "1) 切换模式 (自签 / 域名)"
echo "2) 修改端口"
echo "3) 重新申请证书"
echo "4) 重启/刷新服务"
echo "5) 删除 Sing-box"
echo "6) 显示当前节点信息"
echo "0) 退出"
read -rp "请选择操作: " CHOICE

case $CHOICE in
1)
    read -rp "请输入模式 (1=域名, 2=自签): " NEW_MODE
    echo "$NEW_MODE" > "$MODE_FILE"
    init_mode_domain
    generate_cert
    generate_config
    systemctl restart sing-box
    ;;
2)
    read -rp "请输入 VLESS TCP 端口: " VLESS_PORT
    read -rp "请输入 Hysteria2 UDP 端口: " HY2_PORT
    echo "$VLESS_PORT" > "$VLESS_PORT_FILE"
    echo "$HY2_PORT" > "$HY2_PORT_FILE"
    generate_config
    systemctl restart sing-box
    ;;
3)
    generate_cert
    systemctl restart sing-box
    ;;
4)
    systemctl restart sing-box
    ;;
5)
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf /usr/local/bin/sing-box "$CONFIG_FILE" "$CERT_DIR" "$UUID_FILE" "$HY2_PASS_FILE" "$VLESS_PORT_FILE" "$HY2_PORT_FILE" "$DOMAIN_FILE" "$MODE_FILE" /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo "[✔] Sing-box 已删除"
    exit 0
    ;;
6)
    echo "VLESS: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$SERVER_IP"
    echo "Hysteria2: hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$DOMAIN#HY2-$SERVER_IP"
    ;;
0)
    exit 0
    ;;
*)
    echo "输入错误"
    ;;
esac
done
