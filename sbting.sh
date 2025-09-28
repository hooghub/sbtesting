#!/bin/sh
# Alpine OpenRC Sing-box 一键脚本
# Author: ChatGPT + Hooghub

set -e

CONF_DIR="/etc/singbox"
PORT_FILE="$CONF_DIR/port.conf"
CONFIG_FILE="$CONF_DIR/config.json"
CERT_DIR="$CONF_DIR/cert"

mkdir -p "$CONF_DIR" "$CERT_DIR"

echo "=================== Sing-box 部署前环境检查 ==================="

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
if ! grep -q "Alpine" /etc/os-release 2>/dev/null; then
    echo "[✖] 当前系统非 Alpine Linux，退出"
    exit 1
else
    echo "[✔] 检测到系统: Alpine Linux"
fi

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add bash curl wget socat openssl iproute2 dcron

# --------- 随机端口 / UUID / HY2密码 ---------
if [ ! -f "$PORT_FILE" ]; then
    VLESS_PORT=$((RANDOM%50000+10000))
    HY2_PORT=$((RANDOM%50000+10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS" > "$PORT_FILE"
else
    read VLESS_PORT HY2_PORT UUID HY2_PASS < "$PORT_FILE"
fi

# --------- 证书生成 ---------
generate_cert(){
    MODE=$1
    DOMAIN=$2
    if [ "$MODE" = "1" ]; then
        # 域名模式
        if ! command -v acme.sh >/dev/null 2>&1; then
            echo ">>> 安装 acme.sh ..."
            curl https://get.acme.sh | sh
            export PATH="$HOME/.acme.sh:$PATH"
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
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

# --------- 生成配置文件 ---------
generate_config(){
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

# --------- OpenRC 服务 ---------
setup_openrc(){
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
command=/usr/local/bin/sing-box
command_args="run -c /etc/singbox/config.json"
pidfile=/var/run/sing-box.pid
name=sing-box
description="Sing-box service"
depend() {
    need net
}
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
}

start_service(){
    rc-service sing-box restart || rc-service sing-box start
}

# --------- 初始模式 ---------
MODE_FILE="$CONF_DIR/mode.conf"
if [ -f "$MODE_FILE" ]; then
    read MODE DOMAIN < "$MODE_FILE"
else
    echo -e "\n请选择部署模式：\n1) 使用域名 + Let's Encrypt\n2) 使用公网 IP + 自签 www.epple.com"
    read -rp "输入 (1/2): " MODE
    if [ "$MODE" = "1" ]; then
        read -rp "请输入域名: " DOMAIN
    fi
    echo "$MODE $DOMAIN" > "$MODE_FILE"
fi

generate_cert "$MODE" "$DOMAIN"
generate_config
setup_openrc
start_service

# --------- URI 输出 ---------
NODE_HOST="$SERVER_IP"
[ "$MODE" = "1" ] && NODE_HOST="$DOMAIN"
VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$([ "$MODE" = "2" ] && echo 1 || echo 0)&sni=$DOMAIN#HY2-$NODE_HOST"

echo -e "\n=================== 节点信息 ==================="
echo "VLESS URI: $VLESS_URI"
echo "HY2 URI  : $HY2_URI"

# --------- 循环菜单 ---------
while true; do
    echo -e "\n=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 删除 Sing-box"
    echo "0) 退出"
    read -rp "请输入选项: " CHOICE
    case "$CHOICE" in
        1)
            [ "$MODE" = "1" ] && MODE="2" || MODE="1"
            if [ "$MODE" = "1" ]; then
                read -rp "请输入域名: " DOMAIN
            fi
            echo "$MODE $DOMAIN" > "$MODE_FILE"
            generate_cert "$MODE" "$DOMAIN"
            generate_config
            start_service
            echo "[✔] 模式切换完成"
            ;;
        2)
            read -rp "请输入 VLESS TCP 端口 (当前: $VLESS_PORT, 0随机): " TP
            [ "$TP" = "0" ] && TP=$((RANDOM%50000+10000))
            read -rp "请输入 Hysteria2 UDP 端口 (当前: $HY2_PORT, 0随机): " UP
            [ "$UP" = "0" ] && UP=$((RANDOM%50000+10000))
            VLESS_PORT=$TP
            HY2_PORT=$UP
            echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS" > "$PORT_FILE"
            generate_config
            start_service
            echo "[✔] 端口修改完成"
            ;;
        3)
            if [ "$MODE" = "1" ]; then
                generate_cert "$MODE" "$DOMAIN"
                generate_config
                start_service
                echo "[✔] 证书已更新"
            else
                echo "[✖] 自签模式无需更新证书"
            fi
            ;;
        4)
            start_service
            echo "[✔] 服务已重启"
            ;;
        5)
            rc-service sing-box stop || true
            rc-update del sing-box || true
            rm -rf "$CONF_DIR" /etc/init.d/sing-box
            echo "[✔] Sing-box 已删除"
            exit 0
            ;;
        0) exit 0 ;;
        *) echo "[✖] 无效选项" ;;
    esac

    echo -e "\n当前节点信息:"
    echo "VLESS URI: $VLESS_URI"
    echo "HY2 URI  : $HY2_URI"
done
