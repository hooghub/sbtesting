#!/bin/sh
# Alpine Sing-box OpenRC 一键部署脚本
# Author: Chis + ChatGPT
# Features: 自签/域名模式、端口/UUID/HY2密码保留、循环菜单、OpenRC

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/certs"
STATE_FILE="$CONFIG_DIR/state.conf"

# -------- 检查 root --------
if [ "$(id -u)" != "0" ]; then
    echo "[✖] 请使用 root 权限运行"
    exit 1
fi
echo "[✔] Root 权限 OK"

# -------- 检测系统 --------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
echo "[✔] 检测到系统: $OS"
if [ "$OS" != "alpine" ]; then
    echo "[✖] 本脚本仅支持 Alpine Linux"
    exit 1
fi

# -------- 检测公网 IP --------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo "[✖] 获取公网 IP 失败"
    exit 1
fi
echo "[✔] 检测到公网 IP: $SERVER_IP"

# -------- 安装依赖 --------
echo "[*] 安装依赖..."
apk update
apk add bash curl wget socat openssl dcron || true

# -------- 启动 dcron --------
rc-update add dcron default
/etc/init.d/dcron start || true

# -------- 创建目录 --------
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# -------- 读取状态 --------
if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
fi

# -------- 随机端口函数 --------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q "$PORT" || break
    done
    echo "$PORT"
}

# -------- 生成 UUID / HY2 密码 --------
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$HY2_PASS" ] && HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
[ -z "$VLESS_PORT" ] && VLESS_PORT=$(get_random_port)
[ -z "$HY2_PORT" ] && HY2_PORT=$(get_random_port)

# -------- 菜单函数 --------
menu() {
while true; do
cat <<EOF
=================== Sing-box 菜单 ===================
1) 切换模式 (自签/域名)
2) 修改端口
3) 重新申请证书 (仅域名模式)
4) 重启/刷新服务
5) 显示当前节点信息
6) 删除 Sing-box
0) 退出
请输入选项: 
EOF
read -r opt
case $opt in
1)
    echo "请选择模式：1) 域名模式 2) 自签模式"
    read -r m
    if [ "$m" = "1" ]; then
        MODE="domain"
        echo "请输入域名:"
        read -r DOMAIN
        echo "[*] 申请或更新域名证书..."
        if ! command -v acme.sh >/dev/null 2>&1; then
            curl https://get.acme.sh | sh
            . ~/.bashrc || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        MODE="selfsign"
        DOMAIN="www.epple.com"
        echo "[!] 自签模式，生成固定域名 $DOMAIN 的自签证书"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
    ;;
2)
    echo "请输入 VLESS TCP 端口 (当前: $VLESS_PORT): "
    read -r vp
    [ -n "$vp" ] && VLESS_PORT="$vp"
    echo "请输入 Hysteria2 UDP 端口 (当前: $HY2_PORT): "
    read -r hp
    [ -n "$hp" ] && HY2_PORT="$hp"
    ;;
3)
    if [ "$MODE" = "domain" ]; then
        echo "[*] 重新申请证书..."
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        echo "[✖] 自签模式无需申请证书"
    fi
    ;;
4)
    echo "[*] 重启 Sing-box 服务..."
    rc-service sing-box restart || true
    ;;
5)
    echo "当前节点信息:"
    echo "模式: $MODE"
    echo "域名/CN: $DOMAIN"
    echo "VLESS TCP 端口: $VLESS_PORT"
    echo "Hysteria2 UDP 端口: $HY2_PORT"
    echo "UUID: $UUID"
    echo "HY2 密码: $HY2_PASS"
    ;;
6)
    echo "[*] 删除 Sing-box..."
    rc-service sing-box stop || true
    rm -rf "$CONFIG_DIR"
    echo "[✔] 删除完成"
    exit 0
    ;;
0)
    exit 0
    ;;
*)
    echo "[✖] 输入错误"
    ;;
esac
save_state
deploy_singbox
done
}

# -------- 保存状态 --------
save_state() {
cat > "$STATE_FILE" <<EOF
MODE="$MODE"
DOMAIN="$DOMAIN"
VLESS_PORT="$VLESS_PORT"
HY2_PORT="$HY2_PORT"
UUID="$UUID"
HY2_PASS="$HY2_PASS"
EOF
}

# -------- 生成 sing-box 配置 --------
deploy_singbox() {
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{"uuid": "$UUID"}],
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
      "users": [{"password": "$HY2_PASS"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# -------- OpenRC 服务 --------
cat > /etc/init.d/sing-box <<'EOL'
#!/sbin/openrc-run
command=/usr/local/bin/sing-box
command_args="-c /etc/sing-box/config.json"
pidfile=/var/run/sing-box.pid
name=sing-box
description="Sing-box service"
EOL
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
rc-service sing-box restart || true
}

# -------- 初次部署 --------
[ -z "$MODE" ] && MODE="selfsign"
[ -z "$DOMAIN" ] && DOMAIN="www.epple.com"
deploy_singbox
save_state
menu
