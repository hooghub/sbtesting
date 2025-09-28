#!/bin/sh
# Sing-box 一键部署脚本 (Alpine 兼容版)
# Author: Chis (优化 by ChatGPT)
# 无 qrencode，兼容老版 Alpine
# 使用 systemd 管理服务

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/certs"
DATA_FILE="$CONFIG_DIR/data.env"

echo "=================== Sing-box Alpine 一键部署 ==================="

# --------- 检查 root ---------
[ "$(id -u)" -ne 0 ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
OS="$(awk -F= '/^ID=/ {print $2}' /etc/os-release | tr -d '"')"
echo "[✔] 检测到系统: $OS"

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update -U
apk add curl socat wget openssl bind-tools bash systemd || true

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && echo "[✖] 获取公网 IP 失败" && exit 1
echo "[✔] 检测到公网 IP: $SERVER_IP"

# --------- 创建目录 ---------
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# --------- 读取历史数据 ---------
if [ -f "$DATA_FILE" ]; then
    . "$DATA_FILE"
fi

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 保存数据函数 ---------
save_data() {
    cat > "$DATA_FILE" <<EOF
MODE=$MODE
DOMAIN=$DOMAIN
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
UUID=$UUID
HY2_PASS=$HY2_PASS
EOF
}

# --------- UUID/HY2 密码初始化 ---------
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$HY2_PASS" ] && HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

# --------- 菜单循环 ---------
while true; do
echo -e "\n=================== Sing-box 菜单 ==================="
echo "1) 切换模式 (自签/域名)"
echo "2) 修改端口"
echo "3) 重新申请证书 (仅域名模式)"
echo "4) 重启/刷新服务"
echo "5) 显示当前节点信息"
echo "6) 删除 Sing-box"
echo "0) 退出"
read -rp "请输入选项: " choice

case $choice in
1)
    echo "请选择模式：1) 域名模式 2) 自签模式"
    read -rp "输入 (1/2): " MODE
    [ "$MODE" != "1" ] && MODE="2"
    if [ "$MODE" = "1" ]; then
        read -rp "请输入域名: " DOMAIN
        DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
        if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
            echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符"
            continue
        fi
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
        echo "[!] 自签模式，生成固定域名 $DOMAIN 的自签证书"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
    save_data
    ;;

2)
    read -rp "请输入 VLESS TCP 端口 (当前: ${VLESS_PORT:-443}): " port
    VLESS_PORT=${port:-$VLESS_PORT}
    read -rp "请输入 Hysteria2 UDP 端口 (当前: ${HY2_PORT:-8443}): " port
    HY2_PORT=${port:-$HY2_PORT}
    save_data
    ;;

3)
    [ "$MODE" = "1" ] && /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --force || echo "[✖] 自签模式无需证书"
    ;;

4)
    echo "[*] 生成配置并重启 sing-box..."
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

    # 安装 sing-box (官方 tar.gz)
    if ! command -v sing-box >/dev/null 2>&1; then
        curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz -o /tmp/singbox.tar.gz
        tar xzf /tmp/singbox.tar.gz -C /usr/local/bin sing-box
        chmod +x /usr/local/bin/sing-box
    fi

    # systemd 服务
    SERVICE_FILE="/etc/systemd/system/sing-box.service"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    sleep 3

    # 检查监听
    ss -tulnp | grep "$VLESS_PORT" && echo "[✔] VLESS TCP $VLESS_PORT 已监听"
    ss -ulnp | grep "$HY2_PORT" && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听"
    ;;

5)
    echo "VLESS: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$DOMAIN"
    echo "Hysteria2: hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=$([ "$MODE" = "2" ] && echo 1 || echo 0)&sni=$DOMAIN#HY2-$DOMAIN"
    ;;

6)
    systemctl stop sing-box || true
    systemctl disable sing-box || true
    rm -rf "$CONFIG_DIR" /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
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
