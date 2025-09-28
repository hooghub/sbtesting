#!/bin/sh
# Alpine Sing-box 一键部署脚本 (OpenRC 版本)
# Author: Chis (优化 by ChatGPT)
# 适用 Alpine 3.18+，无 systemd，无 qrencode

set -e

SINGBOX_DIR="/etc/singbox"
PORT_FILE="$SINGBOX_DIR/port.conf"
CONFIG_FILE="$SINGBOX_DIR/config.json"

mkdir -p "$SINGBOX_DIR"

# ------------------ 检查 root ------------------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# ------------------ 检测系统 ------------------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
[ "$OS" != "alpine" ] && echo "[✖] 仅支持 Alpine" && exit 1
echo "[✔] 检测到系统: Alpine Linux"

# ------------------ 安装依赖 ------------------
echo "[*] 安装依赖..."
apk update
apk add bash curl socat openssl wget dcron iproute2 >/dev/null 2>&1

# ------------------ 检测公网 IP ------------------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && echo "[✖] 获取公网 IP 失败" && exit 1
echo "[✔] 检测到公网 IP: $SERVER_IP"

# ------------------ 初始化端口/UUID/HY2密码 ------------------
if [ ! -f "$PORT_FILE" ]; then
    VLESS_PORT=$(shuf -i10000-60000 -n1)
    HY2_PORT=$(shuf -i10000-60000 -n1)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE=2
    DOMAIN="www.epple.com"
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
fi

# ------------------ 读取配置 ------------------
read VLESS_PORT HY2_PORT UUID HY2_PASS MODE DOMAIN < "$PORT_FILE"

# ------------------ 检查端口占用 ------------------
check_port() {
    PORT=$1
    if ss -tuln | grep -q ":$PORT"; then
        echo "[✖] 端口 $PORT 已被占用"
    else
        echo "[✔] 端口 $PORT 空闲"
    fi
}

# ------------------ 安装 Sing-box ------------------
if [ ! -x "/usr/local/bin/sing-box" ]; then
    echo "[*] 安装 Sing-box..."
    curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.gz | gunzip -c > /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
fi

# ------------------ 生成证书 ------------------
generate_cert() {
    mkdir -p "$SINGBOX_DIR"
    if [ "$MODE" -eq 1 ]; then
        # 域名模式
        read -rp "请输入你的域名: " DOMAIN
        [ -z "$DOMAIN" ] && echo "[✖] 域名不能为空" && exit 1
        # 安装 acme.sh 并申请证书
        if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
            curl https://get.acme.sh | sh
            export PATH="$HOME/.acme.sh:$PATH"
        fi
        "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
        "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
            --key-file "$SINGBOX_DIR/privkey.pem" \
            --fullchain-file "$SINGBOX_DIR/fullchain.pem" --force
    else
        # 自签模式
        DOMAIN="www.epple.com"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SINGBOX_DIR/privkey.pem" \
            -out "$SINGBOX_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName=DNS:$DOMAIN,IP:$SERVER_IP"
    fi
    chmod 644 "$SINGBOX_DIR"/*.pem
}

generate_cert

# ------------------ 生成 sing-box 配置 ------------------
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
        "certificate_path": "$SINGBOX_DIR/fullchain.pem",
        "key_path": "$SINGBOX_DIR/privkey.pem"
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
        "certificate_path": "$SINGBOX_DIR/fullchain.pem",
        "key_path": "$SINGBOX_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
}

generate_config

# ------------------ OpenRC 服务 ------------------
if [ ! -f "/etc/init.d/sing-box" ]; then
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command=/usr/local/bin/sing-box
command_args="-c /etc/singbox/config.json"
pidfile=/var/run/sing-box.pid
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
fi

# ------------------ 启动服务 ------------------
start_service() {
    rc-service sing-box restart || rc-service sing-box start
}

start_service

# ------------------ 生成 URI ------------------
generate_uri() {
    if [ "$MODE" -eq 1 ]; then
        NODE_HOST="$DOMAIN"
        INSECURE=0
    else
        NODE_HOST="$SERVER_IP"
        INSECURE=1
    fi
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
}

generate_uri

# ------------------ 菜单循环 ------------------
while :; do
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
            [ "$MODE" -eq 1 ] && MODE=2 || MODE=1
            generate_cert
            generate_config
            start_service
            echo "[✔] 模式已切换"
            ;;
        2)
            read -rp "请输入 VLESS TCP 端口: " VLESS_PORT
            read -rp "请输入 HY2 UDP 端口: " HY2_PORT
            echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
            generate_config
            start_service
            generate_uri
            echo "[✔] 端口已修改并刷新服务"
            ;;
        3)
            [ "$MODE" -eq 1 ] || { echo "[✖] 自签模式不支持"; continue; }
            generate_cert
            generate_config
            start_service
            echo "[✔] 证书已重新申请"
            ;;
        4)
            start_service
            echo "[✔] 服务已刷新"
            ;;
        5)
            generate_uri
            echo -e "\nVLESS URI: $VLESS_URI"
            echo -e "HY2 URI: $HY2_URI"
            ;;
        6)
            rc-service sing-box stop || true
            rm -f /usr/local/bin/sing-box "$CONFIG_FILE" "$PORT_FILE"
            rm -f /etc/init.d/sing-box
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
