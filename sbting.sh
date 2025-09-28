#!/bin/bash
# Alpine Sing-box 一键部署脚本（最终增强版）
# 支持：域名模式 / 自签固定域名 www.epple.com
# Author: Chis (优化 by ChatGPT)

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/certs"
DATA_FILE="$CONFIG_DIR/.singbox_data"
SINGBOX_BIN="/usr/local/bin/sing-box"

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# --------- 系统检测 ---------
OS_TYPE="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        alpine) OS_TYPE="alpine" ;;
        debian|ubuntu) OS_TYPE="debian" ;;
    esac
fi

# --------- 安装依赖 ---------
install_deps() {
    if [ "$OS_TYPE" = "alpine" ]; then
        apk update
        apk add --no-cache curl wget bash openssl qrencode socat dcron bind-tools
    elif [ "$OS_TYPE" = "debian" ]; then
        apt update -y
        apt install -y curl wget bash openssl qrencode socat cron dnsutils
    else
        echo "[✖] 未知系统，请手动安装依赖"; exit 1
    fi
}
install_deps

# --------- 下载并安装 sing-box ---------
install_singbox() {
    if [ ! -f "$SINGBOX_BIN" ]; then
        echo ">>> 下载并安装 sing-box ..."
        SINGBOX_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep browser_download_url | grep linux-amd64 | cut -d '"' -f 4)
        curl -L "$SINGBOX_URL" -o /tmp/sing-box.tar.gz
        tar -xzf /tmp/sing-box.tar.gz -C /tmp
        mv /tmp/sing-box "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
    fi
}
install_singbox

# --------- 加载已有数据 ---------
if [ -f "$DATA_FILE" ]; then
    source "$DATA_FILE"
else
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    VLESS_PORT=0
    HY2_PORT=0
    MODE=2
fi

# --------- 菜单 ---------
while true; do
    echo -e "\n=== Alpine Sing-box 管理菜单 ==="
    echo "1) 设置/修改端口 (保留 UUID/HY2密码)"
    echo "2) 切换模式 (域名 / 自签)"
    echo "3) 显示当前节点 URI 和二维码"
    echo "4) 快速更新/重启服务"
    echo "5) 一键卸载 Sing-box"
    echo "0) 退出"
    read -rp "请选择操作: " CHOICE

    case "$CHOICE" in
        1)
            read -rp "请输入 VLESS TCP 端口 (当前 $VLESS_PORT, 0随机): " TMP_VLESS
            [[ "$TMP_VLESS" == "0" || -z "$TMP_VLESS" ]] && TMP_VLESS=$((RANDOM%50000+10000))
            VLESS_PORT=$TMP_VLESS
            read -rp "请输入 Hysteria2 UDP 端口 (当前 $HY2_PORT, 0随机): " TMP_HY2
            [[ "$TMP_HY2" == "0" || -z "$TMP_HY2" ]] && TMP_HY2=$((RANDOM%50000+10000))
            HY2_PORT=$TMP_HY2
            echo "[✔] 端口已更新"
            ;;
        2)
            echo -e "\n请选择模式:\n1) 域名模式\n2) 自签模式"
            read -rp "输入 1 或 2 (当前 $MODE): " TMP_MODE
            [[ "$TMP_MODE" =~ ^[12]$ ]] && MODE=$TMP_MODE
            echo "[✔] 模式已切换"
            ;;
        3)
            NODE_HOST=$([ "$MODE" = 1 ] && echo "$DOMAIN" || echo "$SERVER_IP")
            VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
            HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$([ "$MODE" = 2 ] && echo 1 || echo 0)&sni=$DOMAIN#HY2-$NODE_HOST"
            echo -e "\nVLESS URI: $VLESS_URI"
            echo -e "HY2 URI: $HY2_URI"
            command -v qrencode &>/dev/null && echo "$VLESS_URI" | qrencode -t ansiutf8 && echo "$HY2_URI" | qrencode -t ansiutf8
            ;;
        4)
            echo "[✔] 更新配置并重启服务..."
            mkdir -p "$CONFIG_DIR"
            cat > "$CONFIG_FILE" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "vless", "listen": "0.0.0.0", "listen_port": $VLESS_PORT, "users": [{"uuid": "$UUID"}], "tls": {"enabled": true, "server_name": "$DOMAIN", "certificate_path": "$CERT_DIR/fullchain.pem", "key_path": "$CERT_DIR/privkey.pem"}},
    {"type": "hysteria2", "listen": "0.0.0.0", "listen_port": $HY2_PORT, "users": [{"password": "$HY2_PASS"}], "tls": {"enabled": true, "server_name": "$DOMAIN", "certificate_path": "$CERT_DIR/fullchain.pem", "key_path": "$CERT_DIR/privkey.pem"}}
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
            systemctl enable sing-box
            systemctl restart sing-box
            sleep 3
            echo "[✔] 配置已更新并重启服务"
            ;;
        5)
            echo "[✔] 卸载 Sing-box 并清理配置..."
            systemctl stop sing-box || true
            systemctl disable sing-box || true
            rm -rf "$CONFIG_DIR" "$SINGBOX_BIN"
            echo "[✔] 已彻底删除 Sing-box"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *) echo "[✖] 无效选项";;
    esac

    # --------- 保存数据 ---------
    echo "UUID=$UUID" > "$DATA_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$DATA_FILE"
    echo "VLESS_PORT=$VLESS_PORT" >> "$DATA_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$DATA_FILE"
    echo "MODE=$MODE" >> "$DATA_FILE"

    echo -e "\n[✔] 当前配置已保存"

done
