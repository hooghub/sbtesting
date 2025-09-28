#!/bin/sh
# Alpine OpenRC Sing-box 一键管理脚本
# Author: ChatGPT + HHoog
set -e

CONFIG_DIR="/etc/singbox"
CONFIG_FILE="$CONFIG_DIR/config.json"
PORT_FILE="$CONFIG_DIR/port.conf"
CERT_DIR="$CONFIG_DIR/cert"
UUID_FILE="$CONFIG_DIR/uuid"
HY2_PASS_FILE="$CONFIG_DIR/hy2_pass"
SVC_FILE="/etc/init.d/sing-box"

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# -------------------- 检查 root --------------------
if [ "$(id -u)" != "0" ]; then
    echo "[✖] 请使用 root 运行"
    exit 1
fi
echo "[✔] Root 权限 OK"

# -------------------- 检测系统 --------------------
if [ -f /etc/alpine-release ]; then
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 仅支持 Alpine Linux"
    exit 1
fi

# -------------------- 安装依赖 --------------------
echo "[*] 安装依赖..."
apk update
apk add curl socat wget openssl iproute2 dcron bash bind-tools --no-cache

# -------------------- 获取公网 IP --------------------
SERVER_IP=$(curl -s icanhazip.com || curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo "[✖] 无法获取公网 IP"
    exit 1
fi
echo "[✔] 检测到公网 IP: $SERVER_IP"

# -------------------- 生成/读取端口、UUID、HY2密码 --------------------
if [ -f "$PORT_FILE" ]; then
    . "$PORT_FILE"
else
    VLESS_PORT=$((RANDOM%50000+10000))
    HY2_PORT=$((RANDOM%50000+10000))
    echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
fi

if [ -f "$UUID_FILE" ]; then
    UUID=$(cat "$UUID_FILE")
else
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "$UUID" > "$UUID_FILE"
fi

if [ -f "$HY2_PASS_FILE" ]; then
    HY2_PASS=$(cat "$HY2_PASS_FILE")
else
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    echo "$HY2_PASS" > "$HY2_PASS_FILE"
fi

# -------------------- OpenRC 服务 --------------------
if [ ! -f "$SVC_FILE" ]; then
    cat > "$SVC_FILE" <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="-c /etc/singbox/config.json"
pidfile="/run/sing-box.pid"
name="sing-box"
description="Sing-box Service"
depend() {
    need net
}
EOF
    chmod +x "$SVC_FILE"
    rc-update add sing-box default
fi

# -------------------- 函数：生成证书 --------------------
gen_cert() {
    MODE="$1"
    DOMAIN="$2"
    if [ "$MODE" = "1" ]; then
        # 域名模式
        if ! command -v acme.sh >/dev/null 2>&1; then
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
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=www.epple.com" \
            -addext "subjectAltName = DNS:www.epple.com,IP:$SERVER_IP"
    fi
}

# -------------------- 函数：生成配置 --------------------
gen_config() {
    MODE="$1"
    DOMAIN="$2"
    NODE_HOST=$([ "$MODE" = "1" ] && echo "$DOMAIN" || echo "$SERVER_IP")
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

# -------------------- 函数：显示节点 --------------------
show_node() {
    MODE="$1"
    DOMAIN="$2"
    NODE_HOST=$([ "$MODE" = "1" ] && echo "$DOMAIN" || echo "$SERVER_IP")
    INSECURE=$([ "$MODE" = "1" ] && echo 0 || echo 1)
    echo "=================== VLESS 节点 ==================="
    echo "vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    echo "=================== Hysteria2 节点 ==================="
    echo "hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
}

# -------------------- 初始化默认模式 --------------------
if [ ! -f "$CONFIG_DIR/mode.conf" ]; then
    MODE=2  # 默认自签
    DOMAIN="www.epple.com"
    echo "$MODE" > "$CONFIG_DIR/mode.conf"
else
    MODE=$(cat "$CONFIG_DIR/mode.conf")
    DOMAIN=$([ "$MODE" = "1" ] && echo "$DOMAIN" || echo "www.epple.com")
fi

# -------------------- 循环菜单 --------------------
while true; do
    echo
    echo "=================== Sing-box 管理菜单 ==================="
    echo "1) 切换模式（自签/域名）"
    echo "2) 修改端口"
    echo "3) 重新申请证书（仅域名模式）"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    read -r -p "请输入选项: " CHOICE

    case "$CHOICE" in
        1)
            echo "选择模式：1) 域名模式 2) 自签模式"
            read -r MODE_SEL
            if [ "$MODE_SEL" = "1" ]; then
                MODE=1
                read -r -p "请输入你的域名: " DOMAIN
                [ -z "$DOMAIN" ] && echo "[✖] 域名不能为空" && continue
            else
                MODE=2
                DOMAIN="www.epple.com"
            fi
            echo "$MODE" > "$CONFIG_DIR/mode.conf"
            gen_cert "$MODE" "$DOMAIN"
            gen_config "$MODE" "$DOMAIN"
            rc-service sing-box restart
            echo "[✔] 模式已切换并重启服务"
            ;;
        2)
            read -r -p "请输入新的 VLESS 端口: " VLESS_PORT
            read -r -p "请输入新的 HY2 端口: " HY2_PORT
            echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
            echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
            gen_config "$MODE" "$DOMAIN"
            rc-service sing-box restart
            echo "[✔] 端口已更新并重启服务"
            ;;
        3)
            if [ "$MODE" = "1" ]; then
                gen_cert "$MODE" "$DOMAIN"
                gen_config "$MODE" "$DOMAIN"
                rc-service sing-box restart
                echo "[✔] 证书已重新申请并重启服务"
            else
                echo "[!] 自签模式无需重新申请证书"
            fi
            ;;
        4)
            rc-service sing-box restart
            echo "[✔] 服务已重启/刷新"
            ;;
        5)
            show_node "$MODE" "$DOMAIN"
            ;;
        6)
            rc-service sing-box stop
            rm -rf "$CONFIG_DIR"
            rc-update del sing-box default
            rm -f "$SVC_FILE"
            echo "[✔] Sing-box 已删除"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[!] 请输入有效选项"
            ;;
    esac
done
