#!/bin/sh
# Alpine OpenRC Sing-box 一键部署脚本（最终修正版）
# Author: ChatGPT + Chis

set -e

SINGBOX_DIR="/etc/singbox"
PORT_FILE="$SINGBOX_DIR/port.conf"
CONFIG_FILE="$SINGBOX_DIR/config.json"
mkdir -p "$SINGBOX_DIR"

# ---------------- 环境检查 ----------------
[ "$(id -u)" -ne 0 ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# 系统检测
OS=$(awk -F= '/^ID=/ {print $2}' /etc/os-release)
echo "[✔] 检测到系统: $OS"

# 安装依赖
echo "[*] 安装依赖..."
apk update
apk add bash curl socat openssl wget dcron iproute2 >/dev/null 2>&1
export PATH=$PATH:/usr/sbin:/sbin

# 检测公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && { echo "[✖] 获取公网 IP 失败"; exit 1; }
echo "[✔] 检测到公网 IP: $SERVER_IP"

# ---------------- 初始化端口/UUID/HY2 ----------------
if [ ! -f "$PORT_FILE" ]; then
    VLESS_PORT=$(shuf -i10000-60000 -n1)
    HY2_PORT=$(shuf -i10000-60000 -n1)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE=2
    DOMAIN="www.epple.com"
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
fi

# 读取配置
read VLESS_PORT HY2_PORT UUID HY2_PASS MODE DOMAIN < "$PORT_FILE"

# ---------------- 函数 ----------------
check_port() {
    PORT=$1
    if netstat -tuln | grep -q ":$PORT "; then
        echo "[✖] 端口 $PORT 已被占用"
    else
        echo "[✔] 端口 $PORT 空闲"
    fi
}

generate_cert() {
    if [ "$MODE" -eq 1 ]; then
        # 域名模式
        echo "[*] 域名模式，申请/更新 Let’s Encrypt 证书"
        [ -z "$DOMAIN" ] && { echo "[✖] 域名为空"; return 1; }
        if ! command -v acme.sh >/dev/null 2>&1; then
            curl https://get.acme.sh | sh
            . ~/.bashrc || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        mkdir -p "$SINGBOX_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$SINGBOX_DIR/privkey.pem" \
            --fullchain-file "$SINGBOX_DIR/fullchain.pem" --force
    else
        # 自签模式
        echo "[*] 自签模式，生成固定域名 $DOMAIN 自签证书"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SINGBOX_DIR/privkey.pem" \
            -out "$SINGBOX_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
        chmod 644 "$SINGBOX_DIR"/*.pem
    fi
}

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

start_service() {
    if ! pgrep -f sing-box >/dev/null 2>&1; then
        nohup sing-box -c "$CONFIG_FILE" >/dev/null 2>&1 &
    else
        pkill -f sing-box
        nohup sing-box -c "$CONFIG_FILE" >/dev/null 2>&1 &
    fi
    sleep 2
}

show_nodes() {
    if [ "$MODE" -eq 1 ]; then
        NODE_HOST="$DOMAIN"
        INSECURE="0"
    else
        NODE_HOST="$SERVER_IP"
        INSECURE="1"
    fi
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
    echo -e "\nVLESS URI: $VLESS_URI"
    echo -e "HY2 URI: $HY2_URI"
}

update_port_file() {
    echo "$VLESS_PORT $HY2_PORT $UUID $HY2_PASS $MODE $DOMAIN" > "$PORT_FILE"
}

# ---------------- 循环菜单 ----------------
while true; do
    echo -e "\n=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    printf "请输入选项: "
    read -r choice
    case $choice in
        1)
            printf "请选择模式：1) 域名模式 2) 自签模式\n输入 (1/2): "
            read -r new_mode
            [ "$new_mode" = "1" ] && MODE=1 || MODE=2
            [ "$MODE" -eq 1 ] && read -rp "请输入域名: " DOMAIN
            generate_cert
            generate_config
            start_service
            update_port_file
            ;;
        2)
            read -rp "请输入 VLESS TCP 端口 (当前 $VLESS_PORT): " tmp_port
            [ -n "$tmp_port" ] && VLESS_PORT=$tmp_port
            read -rp "请输入 Hysteria2 UDP 端口 (当前 $HY2_PORT): " tmp_port
            [ -n "$tmp_port" ] && HY2_PORT=$tmp_port
            generate_config
            start_service
            update_port_file
            ;;
        3)
            [ "$MODE" -eq 1 ] && generate_cert && generate_config && start_service && update_port_file || echo "[✖] 自签模式无需申请证书"
            ;;
        4)
            generate_config
            start_service
            ;;
        5)
            show_nodes
            ;;
        6)
            pkill -f sing-box || true
            rm -rf "$SINGBOX_DIR"
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
