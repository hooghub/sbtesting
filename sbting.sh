#!/bin/sh
# Sing-box Alpine OpenRC 一键部署脚本 (最终版)
# Author: Chis (优化 by ChatGPT)
# Features:
# - OpenRC / dcron
# - 自动下载 sing-box
# - 自签 / 域名模式
# - 端口/UUID/HY2密码保留
# - 循环菜单操作
# - Alpine 3.18+ 直接运行

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/cert"
PORT_FILE="$CONFIG_DIR/port.info"
UUID_FILE="$CONFIG_DIR/uuid.info"
HY2_FILE="$CONFIG_DIR/hy2.info"
MODE_FILE="$CONFIG_DIR/mode.info"
DOMAIN_FILE="$CONFIG_DIR/domain.info"
SINGBOX_BIN="/usr/local/bin/sing-box"

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# --------- 环境检查 ---------
echo "=================== Sing-box 部署前环境检查 ==================="
[ "$(id -u)" != "0" ] && echo "[✖] 请使用 root 运行" && exit 1
echo "[✔] Root 权限 OK"

OS="$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')"
echo "[✔] 检测到系统: $OS"
[ "$OS" != "alpine" ] && echo "[✖] 本脚本仅支持 Alpine" && exit 1

# 检测公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && echo "[✖] 无法获取公网 IP" && exit 1
echo "[✔] 检测到公网 IP: $SERVER_IP"

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add --no-cache bash curl wget socat openssl iproute2 dcron

# 启动 dcron
rc-update add dcron default
/etc/init.d/dcron start || true

# --------- 安装 Sing-box ---------
if [ ! -f "$SINGBOX_BIN" ]; then
    echo "[*] 下载 sing-box..."
    wget -O "$SINGBOX_BIN" https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64
    chmod +x "$SINGBOX_BIN"
fi

# --------- 生成/读取 UUID、HY2 密码 ---------
[ -f "$UUID_FILE" ] || cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
[ -f "$HY2_FILE" ] || openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' > "$HY2_FILE"

UUID=$(cat "$UUID_FILE")
HY2_PASS=$(cat "$HY2_FILE")

# --------- 读取端口与模式 ---------
[ -f "$PORT_FILE" ] || echo "0 0" > "$PORT_FILE" # VLESS HY2
read VLESS_PORT HY2_PORT < "$PORT_FILE"
[ -f "$MODE_FILE" ] || echo "2" > "$MODE_FILE" # 默认自签
MODE=$(cat "$MODE_FILE")
[ -f "$DOMAIN_FILE" ] || echo "" > "$DOMAIN_FILE"
DOMAIN=$(cat "$DOMAIN_FILE")

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q "$PORT" || break
    done
    echo "$PORT"
}

# --------- OpenRC 启动脚本 ---------
if [ ! -f /etc/init.d/sing-box ]; then
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box service"
command=$SINGBOX_BIN
command_args="run -c $CONFIG_FILE"
pidfile="/var/run/sing-box.pid"
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
fi

# --------- 菜单循环 ---------
while :; do
    echo ""
    echo "=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    printf "请输入选项: "
    read CHOICE

    case "$CHOICE" in
        1)
            echo "请选择模式：1) 域名 2) 自签"
            read M
            [ "$M" = "1" ] && MODE=1 || MODE=2
            echo "$MODE" > "$MODE_FILE"

            if [ "$MODE" = "1" ]; then
                printf "请输入域名: "
                read DOMAIN
                echo "$DOMAIN" > "$DOMAIN_FILE"
                [ ! -f "$HOME/.acme.sh/acme.sh" ] && curl https://get.acme.sh | sh
                source ~/.bashrc || true
                /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
                /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
                    --key-file "$CERT_DIR/privkey.pem" \
                    --fullchain-file "$CERT_DIR/fullchain.pem" --force
            else
                DOMAIN="www.epple.com"
                openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                    -keyout "$CERT_DIR/privkey.pem" \
                    -out "$CERT_DIR/fullchain.pem" \
                    -subj "/CN=$DOMAIN" \
                    -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
            fi
            echo "[✔] 模式已切换为 $([ "$MODE" = "1" ] && echo "域名" || echo "自签")"
            ;;

        2)
            printf "请输入 VLESS TCP 端口 (当前:$VLESS_PORT, 0 随机): "
            read VP
            printf "请输入 Hysteria2 UDP 端口 (当前:$HY2_PORT, 0 随机): "
            read HP
            [ -z "$VP" ] || [ "$VP" = "0" ] && VP=$(get_random_port)
            [ -z "$HP" ] || [ "$HP" = "0" ] && HP=$(get_random_port)
            VLESS_PORT=$VP
            HY2_PORT=$HP
            echo "$VLESS_PORT $HY2_PORT" > "$PORT_FILE"
            echo "[✔] 端口已更新"
            ;;

        3)
            if [ "$MODE" = "1" ]; then
                /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --force
                echo "[✔] 证书已重新申请/更新"
            else
                echo "[✖] 自签模式无需申请证书"
            fi
            ;;

        4)
            /etc/init.d/sing-box restart || /etc/init.d/sing-box start
            echo "[✔] 服务已刷新"
            ;;

        5)
            # 检查端口是否监听
            if ! ss -tuln | grep -q ":$VLESS_PORT"; then
                echo "[⚠] VLESS TCP 端口 $VLESS_PORT 未监听"
            fi
            if ! ss -tuln | grep -q ":$HY2_PORT"; then
                echo "[⚠] Hysteria2 UDP 端口 $HY2_PORT 未监听"
            fi
            NODE_HOST="$([ "$MODE" = "1" ] && echo "$DOMAIN" || echo "$SERVER_IP")"
            INSECURE="$([ "$MODE" = "1" ] && echo 0 || echo 1)"
            echo "VLESS URI: vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
            echo "HY2 URI: hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
            ;;

        6)
            echo "[!] 删除 Sing-box..."
            rc-update del sing-box || true
            /etc/init.d/sing-box stop || true
            rm -rf "$CONFIG_DIR"
            rm -f /etc/init.d/sing-box
            echo "[✔] 已删除"
            exit 0
            ;;

        0)
            exit 0
            ;;

        *)
            echo "[✖] 输入错误"
            ;;
    esac

    # --------- 生成配置文件 ---------
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

done
