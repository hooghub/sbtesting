#!/bin/sh
# Alpine 3.18+ OpenRC Sing-box 一键部署脚本
# 无 systemd、无 qrencode、支持自签/域名、端口/UUID/HY2密码永久保存
# 修改端口/模式可直接刷新服务，无需重新运行脚本

set -e

PORT_FILE="/etc/singbox/port.conf"
CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
DATA_DIR="/etc/singbox"

mkdir -p "$CERT_DIR" "$DATA_DIR"

# --------- 检查 root ---------
[ "$(id -u)" -ne 0 ] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
if [ -f /etc/alpine-release ]; then
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 当前系统非 Alpine，退出"; exit 1
fi

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add curl bash socat openssl wget dcron iproute2 bind-tools

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q "$PORT" || break
    done
    echo $PORT
}

# --------- 读取或生成端口、UUID、HY2密码 ---------
if [ -f "$PORT_FILE" ]; then
    read VLESS_PORT HY2_PORT UUID HY2_PASS MODE DOMAIN < "$PORT_FILE"
else
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE=2
    DOMAIN="www.epple.com"
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
fi

# --------- OpenRC 服务 ---------
if [ ! -f /etc/init.d/sing-box ]; then
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="Sing-box service"
command=/usr/local/bin/sing-box
command_args="run -c /etc/sing-box/config.json"
pidfile="/var/run/sing-box.pid"
depend() {
    need net
}
EOF
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
fi

# --------- 生成证书函数 ---------
generate_cert() {
    if [ "$MODE" = "1" ]; then
        [ -z "$DOMAIN" ] && { echo "[✖] 域名不能为空"; return 1; }
        DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
        [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符" && return 1
        echo "[✔] 域名解析正常"
        [ ! -x /root/.acme.sh/acme.sh ] && curl https://get.acme.sh | sh
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        DOMAIN="www.epple.com"
        echo "[!] 自签模式，生成固定域名 $DOMAIN 的自签证书"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
}

# --------- 生成配置函数 ---------
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

# --------- 生成 URI 函数 ---------
generate_uri() {
    [ "$MODE" = "1" ] && NODE_HOST="$DOMAIN" && INSECURE="0" || NODE_HOST="$SERVER_IP" && INSECURE="1"
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
}

# --------- 初始化 ---------
generate_cert
generate_config
generate_uri
rc-service sing-box restart

# --------- 循环菜单 ---------
while true; do
echo "=================== Sing-box 菜单 ==================="
echo "1) 切换模式 (自签/域名)"
echo "2) 修改端口"
echo "3) 重新申请证书 (仅域名模式)"
echo "4) 重启/刷新服务"
echo "5) 显示当前节点信息"
echo "6) 删除 Sing-box"
echo "0) 退出"
read -rp "请输入选项: " CHOICE
case $CHOICE in
1)
    echo "切换模式：1) 域名模式 2) 自签模式"
    read -rp "输入 (1/2): " NEW_MODE
    [ "$NEW_MODE" != "1" ] && [ "$NEW_MODE" != "2" ] && echo "输入错误" && continue
    MODE=$NEW_MODE
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
    generate_cert
    generate_config
    rc-service sing-box restart
    generate_uri
    ;;
2)
    read -rp "请输入 VLESS TCP 端口: " NEW_VLESS
    read -rp "请输入 Hysteria2 UDP 端口: " NEW_HY2
    VLESS_PORT=${NEW_VLESS:-$VLESS_PORT}
    HY2_PORT=${NEW_HY2:-$HY2_PORT}
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
    generate_config
    rc-service sing-box restart
    generate_uri
    ;;
3)
    [ "$MODE" != "1" ] && echo "仅域名模式可申请证书" && continue
    generate_cert
    generate_config
    rc-service sing-box restart
    generate_uri
    ;;
4)
    rc-service sing-box restart
    ;;
5)
    echo "VLESS URI: $VLESS_URI"
    echo "HY2 URI: $HY2_URI"
    ;;
6)
    rc-service sing-box stop || true
    rm -rf /etc/sing-box /etc/ssl/sing-box /etc/init.d/sing-box /var/run/sing-box.pid /etc/singbox
    echo "Sing-box 已删除"
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
