#!/bin/sh
set -e

SINGBOX_DIR="/etc/singbox"
PORT_FILE="$SINGBOX_DIR/port.conf"
UUID_FILE="$SINGBOX_DIR/uuid.conf"
HY2_FILE="$SINGBOX_DIR/hy2.conf"
MODE_FILE="$SINGBOX_DIR/mode.conf"
CERT_DIR="$SINGBOX_DIR/cert"

mkdir -p "$SINGBOX_DIR" "$CERT_DIR"

# Root check
[ "$(id -u)" != "0" ] && echo "请用 root 运行" && exit 1
echo "[✔] Root 权限 OK"

# Detect OS
grep -qi "alpine" /etc/os-release || { echo "[✖] 本脚本仅支持 Alpine"; exit 1; }
echo "[✔] 检测到系统: Alpine Linux"

# Detect Public IP
PUBLIC_IP=$(curl -s https://api.ip.sb/ip || curl -s https://ifconfig.me)
echo "[✔] 检测到公网 IP: $PUBLIC_IP"

# Install dependencies
echo "[*] 安装依赖..."
apk update
apk add --no-cache dcron curl wget bash openssl iproute2
apk del cronie 2>/dev/null || true

# Generate or load port/UUID/HY2
[ -f "$PORT_FILE" ] || echo $((RANDOM%55535+10000)) > "$PORT_FILE"
PORT=$(cat "$PORT_FILE")

[ -f "$UUID_FILE" ] || cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
UUID=$(cat "$UUID_FILE")

[ -f "$HY2_FILE" ] || head -c 16 /dev/urandom | base64 > "$HY2_FILE"
HY2_PASS=$(cat "$HY2_FILE")

[ -f "$MODE_FILE" ] || echo "self" > "$MODE_FILE"
MODE=$(cat "$MODE_FILE")

# Certificate
generate_cert(){
    if [ "$MODE" = "self" ]; then
        echo "[*] 自签模式，生成自签证书"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
            -subj "/CN=www.epple.com"
    else
        echo "[*] 域名模式，请输入域名:"
        read -r DOMAIN
        echo "$DOMAIN" > "$CERT_DIR/domain.conf"
        apk add --no-cache socat
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN"
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file "$CERT_DIR/key.pem" \
            --fullchain-file "$CERT_DIR/cert.pem"
    fi
}

# Config
generate_config(){
    cat > "$SINGBOX_DIR/config.json" <<EOF
{
    "log": {"level":"info"},
    "inbounds":[
        {"type":"tcp","listen":"0.0.0.0","listen_port":$PORT,"tls":{"enabled":true,"server_name":"www.epple.com","cert_file":"$CERT_DIR/cert.pem","key_file":"$CERT_DIR/key.pem"},"users":[{"uuid":"$UUID","flow":"xtls-rprx-vision","level":0}]},
        {"type":"udp","listen":"0.0.0.0","listen_port":$PORT,"transport":{"type":"udp","obfs":"udp","password":"$HY2_PASS"}}
    ],
    "outbounds":[{"type":"direct"}]
}
EOF
}

# OpenRC service
setup_service(){
    cat > /etc/init.d/singbox <<'EOF'
#!/sbin/openrc-run
name="singbox"
description="Sing-box service"
command=/usr/local/bin/sing-box
command_args="run -c /etc/singbox/config.json"
pidfile="/var/run/singbox.pid"
EOF
    chmod +x /etc/init.d/singbox
    rc-update add singbox default
    rc-service singbox start || rc-service singbox restart
}

# Show URI
show_uri(){
    echo "===================== Sing-box 节点 ====================="
    echo "VLESS URI: vless://$UUID@$PUBLIC_IP:$PORT?encryption=none&security=tls&sni=www.epple.com&type=tcp#VLESS-$PUBLIC_IP"
    echo "HY2 URI: hysteria2://$HY2_PASS@$PUBLIC_IP:$PORT?insecure=1&sni=www.epple.com#HY2-$PUBLIC_IP"
    echo "========================================================"
}

# First run
generate_cert
generate_config
setup_service
show_uri

# Menu
while true; do
    echo "=================== Sing-box 管理菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    read -rp "请输入选项: " option
    case "$option" in
        1)
            [ "$MODE" = "self" ] && MODE="domain" || MODE="self"
            echo "$MODE" > "$MODE_FILE"
            generate_cert
            generate_config
            rc-service singbox restart
            show_uri
            ;;
        2)
            read -rp "请输入新的端口: " NEW_PORT
            PORT="$NEW_PORT"
            echo "$PORT" > "$PORT_FILE"
            generate_config
            rc-service singbox restart
            show_uri
            ;;
        3)
            [ "$MODE" = "domain" ] && generate_cert && generate_config && rc-service singbox restart && show_uri || echo "[✖] 自签模式无法申请域名证书"
            ;;
        4)
            rc-service singbox restart
            show_uri
            ;;
        5)
            show_uri
            ;;
        6)
            rc-service singbox stop
            rm -rf "$SINGBOX_DIR"
            rm -f /etc/init.d/singbox
            echo "[✔] Sing-box 已删除"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[✖] 无效选项"
            ;;
    esac
done
