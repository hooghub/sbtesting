#!/bin/sh
# Alpine Sing-box 一键部署脚本（兼容无 qrencode）
# Author: Chis (优化 by ChatGPT)
# shellcheck disable=SC3043

set -e

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
DATA_FILE="/etc/sing-box/sb_data.env"

mkdir -p "$CERT_DIR"
mkdir -p /etc/sing-box

# ---------------- 检查 root ----------------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1

# ---------------- 检测系统 ----------------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release)
echo "[✔] 检测系统: $OS"

# ---------------- 安装依赖 ----------------
apk update
apk add --no-cache curl openssl socat bash coreutils bind-tools iproute2

# dcron 默认即可
if ! command -v crond >/dev/null 2>&1; then
    apk add --no-cache dcron
fi

# ---------------- 检测公网 IP ----------------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# ---------------- 读取已有端口/UUID/HY2密码 ----------------
if [ -f "$DATA_FILE" ]; then
    . "$DATA_FILE"
fi

# ---------------- 安装 sing-box ----------------
if ! command -v sing-box >/dev/null 2>&1; then
    echo "[*] 安装 sing-box ..."
    cd /tmp
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SB_VER/sing-box-$SB_VER-linux-amd64.tar.gz"
    tar xf sing-box.tar.gz -C /usr/local/bin --strip-components=1
    chmod +x /usr/local/bin/sing-box
fi

# ---------------- 菜单 ----------------
while :; do
echo -e "\nAlpine Sing-box 一键部署 - 快捷菜单"
echo "1) 切换模式（自签/域名）"
echo "2) 修改端口"
echo "3) 重新申请证书（域名模式）"
echo "4) 重启/刷新服务"
echo "5) 显示当前节点链接"
echo "6) 删除 Sing-box"
echo "0) 退出"
read -rp "请选择操作: " CHOICE

case $CHOICE in
1)
    echo "选择模式：1) 域名模式 2) 自签模式"
    read -rp "请输入选项: " MODE
    if [ "$MODE" = "1" ]; then
        read -rp "请输入域名: " DOMAIN
        DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
        [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名解析与 VPS IP 不符" && continue
        echo "[✔] 域名解析正常"

        # 安装 acme.sh
        if ! command -v acme.sh >/dev/null 2>&1; then
            curl https://get.acme.sh | sh
            source ~/.bashrc || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

        # 申请证书
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
    echo "[✔] 模式切换完成"
    ;;

2)
    read -rp "请输入 VLESS TCP 端口 (当前: ${VLESS_PORT:-443}): " TMP
    [ -n "$TMP" ] && VLESS_PORT=$TMP
    read -rp "请输入 Hysteria2 UDP 端口 (当前: ${HY2_PORT:-8443}): " TMP
    [ -n "$TMP" ] && HY2_PORT=$TMP
    echo "[✔] 端口更新完成"
    ;;

3)
    if [ "$DOMAIN" ] && [ "$MODE" = "1" ]; then
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
        echo "[✔] 证书已更新"
    else
        echo "[✖] 当前非域名模式，无法申请证书"
    fi
    ;;

4)
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
    sleep 2
    echo "[✔] 服务已刷新"
    ;;

5)
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    HY2_PASS=${HY2_PASS:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')}
    NODE_HOST=${DOMAIN:-$SERVER_IP}
    INSECURE=1
    [ "$MODE" = "1" ] && INSECURE=0
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"
    echo -e "\nVLESS: $VLESS_URI"
    echo -e "HY2:   $HY2_URI"
    if command -v qrencode >/dev/null 2>&1; then
        echo "$VLESS_URI" | qrencode -t ansiutf8
        echo "$HY2_URI" | qrencode -t ansiutf8
    else
        echo "[!] 系统无 qrencode，二维码生成已跳过"
    fi
    ;;

6)
    systemctl stop sing-box || true
    rm -f /usr/local/bin/sing-box "$CONFIG_FILE" "$DATA_FILE"
    rm -rf "$CERT_DIR"
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

# ---------------- 保存端口/UUID/HY2 ----------------
[ -n "$VLESS_PORT" ] && echo "VLESS_PORT=$VLESS_PORT" > "$DATA_FILE"
[ -n "$HY2_PORT" ] && echo "HY2_PORT=$HY2_PORT" >> "$DATA_FILE"
[ -n "$UUID" ] && echo "UUID=$UUID" >> "$DATA_FILE"
[ -n "$HY2_PASS" ] && echo "HY2_PASS=$HY2_PASS" >> "$DATA_FILE"

done
