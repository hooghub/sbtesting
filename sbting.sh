#!/bin/sh
# Alpine OpenRC Sing-box 一键部署脚本 (最终修复版)
# 支持：自签/域名模式、端口/UUID/HY2密码保存、循环菜单、OpenRC
# 作者：Chis (优化 by ChatGPT)

set -e

PORT_FILE="/etc/singbox/port.conf"
CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

echo "=================== Sing-box 部署前环境检查 ==================="

# Root 检查
[ "$(id -u)" -ne 0 ] && echo "[✖] 请使用 root 运行" && exit 1
echo "[✔] Root 权限 OK"

# 系统检查
if [ -f /etc/alpine-release ]; then
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 当前系统非 Alpine Linux"
    exit 1
fi

# 安装依赖
echo "[*] 安装依赖..."
apk update
apk add bash curl socat openssl wget dcron || true

# 检测公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# 生成端口/UUID/HY2密码（第一次运行）
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q ":$PORT" || break
    done
    echo "$PORT"
}

if [ ! -s "$PORT_FILE" ]; then
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE=2
    DOMAIN="www.epple.com"
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
fi

# 读取端口/UUID/HY2密码/模式/域名
read VLESS_PORT HY2_PORT UUID HY2_PASS MODE DOMAIN < "$PORT_FILE"
VLESS_PORT=${VLESS_PORT:-$(get_random_port)}
HY2_PORT=${HY2_PORT:-$(get_random_port)}

# 安装 sing-box (tar.gz 方式)
if ! command -v sing-box >/dev/null 2>&1; then
    echo ">>> 安装 sing-box ..."
    TMP_DIR=$(mktemp -d)
    curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz | tar -xz -C "$TMP_DIR"
    mv "$TMP_DIR/sing-box" /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf "$TMP_DIR"
fi

# 生成证书
generate_cert() {
    if [ "$MODE" -eq 1 ]; then
        # 域名模式
        read -p "请输入域名: " DOMAIN
        [ -z "$DOMAIN" ] && echo "[✖] 域名不能为空" && exit 1
        if ! command -v acme.sh >/dev/null 2>&1; then
            echo ">>> 安装 acme.sh ..."
            curl https://get.acme.sh | sh
            source ~/.bashrc || true
        fi
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        # 自签模式
        echo "[!] 自签模式，生成固定域名 www.epple.com 的自签证书"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=www.epple.com" \
            -addext "subjectAltName = DNS:www.epple.com,IP:$SERVER_IP"
    fi
    chmod 644 "$CERT_DIR"/*.pem
}

generate_cert

# 生成 sing-box 配置
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

# OpenRC 服务
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
command=/usr/local/bin/sing-box
command_args="-c /etc/sing-box/config.json"
pidfile=/var/run/sing-box.pid
name="sing-box"
description="Sing-box service"
EOF
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
rc-service sing-box restart || rc-service sing-box start

# 生成 URI
NODE_HOST=$SERVER_IP
INSECURE=$([ "$MODE" -eq 2 ] && echo 1 || echo 0)
VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"

# 循环菜单
while true; do
echo "=================== Sing-box 菜单 ==================="
echo "1) 切换模式 (自签/域名)"
echo "2) 修改端口"
echo "3) 重新申请证书 (仅域名模式)"
echo "4) 重启/刷新服务"
echo "5) 显示当前节点信息"
echo "6) 删除 Sing-box"
echo "0) 退出"
read -p "请输入选项: " CHOICE
case "$CHOICE" in
1)
    MODE=$([ "$MODE" -eq 1 ] && echo 2 || echo 1)
    generate_cert
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
    rc-service sing-box restart
    echo "[✔] 模式切换完成"
    ;;
2)
    read -p "请输入新的 VLESS 端口: " VLESS_PORT
    read -p "请输入新的 Hysteria2 端口: " HY2_PORT
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
    rc-service sing-box restart
    echo "[✔] 端口修改完成"
    ;;
3)
    [ "$MODE" -eq 1 ] && generate_cert || echo "[✖] 自签模式无需证书"
    rc-service sing-box restart
    ;;
4)
    rc-service sing-box restart
    echo "[✔] 服务已刷新"
    ;;
5)
    echo "VLESS URI: $VLESS_URI"
    echo "HY2 URI: $HY2_URI"
    ;;
6)
    rc-service sing-box stop
    rm -rf /etc/sing-box /usr/local/bin/sing-box "$PORT_FILE" "$CERT_DIR" /etc/init.d/sing-box
    echo "[✔] Sing-box 已删除"
    exit 0
    ;;
0)
    exit 0
    ;;
*)
    echo "[✖] 输入错误"
    ;;
esac
done
