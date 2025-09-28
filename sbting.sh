#!/bin/sh
# Alpine 专用 Sing-box 一键部署脚本
# 作者: Chis (优化)

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/cert"
DATA_FILE="$CONFIG_DIR/data.conf"

# 创建必要目录
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1

# --------- 检测系统 ---------
OS_NAME=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
if [ "$OS_NAME" = "alpine" ]; then
    PKG_MGR="apk"
else
    echo "[✖] 仅支持 Alpine Linux" && exit 1
fi

# --------- 安装依赖 ---------
REQUIRED_CMDS="curl openssl socat bash bind-tools"
for cmd in $REQUIRED_CMDS; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[!] 安装缺失依赖: $cmd"
        apk add --no-cache $cmd
    fi
done

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && echo "[✖] 获取公网 IP 失败" && exit 1
echo "[✔] 检测到公网 IP: $SERVER_IP"

# --------- 生成随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# --------- 读取或生成 UUID/HY2密码/端口 ---------
if [ -f "$DATA_FILE" ]; then
    . "$DATA_FILE"
else
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    MODE="2"
    echo "VLESS_PORT=$VLESS_PORT" > "$DATA_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$DATA_FILE"
    echo "UUID=$UUID" >> "$DATA_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$DATA_FILE"
    echo "MODE=$MODE" >> "$DATA_FILE"
fi

# --------- 安装 sing-box ---------
if ! command -v sing-box >/dev/null 2>&1; then
    echo ">>> 下载并安装 Sing-box ..."
    curl -L -o /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz
    tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin
    chmod +x /usr/local/bin/sing-box
fi

# --------- 生成自签证书函数 ---------
generate_self_cert() {
    DOMAIN="www.epple.com"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    chmod 644 "$CERT_DIR/"*.pem
}

# --------- 生成域名证书函数 ---------
generate_letsencrypt_cert() {
    [ -z "$DOMAIN" ] && read -rp "请输入域名: " DOMAIN
    mkdir -p "$CERT_DIR/$DOMAIN"
    if ! command -v acme.sh >/dev/null 2>&1; then
        echo ">>> 安装 acme.sh ..."
        curl https://get.acme.sh | sh
        . ~/.bashrc || true
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
}

# --------- 生成配置文件 ---------
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

# --------- systemd 服务 ---------
setup_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
}

# --------- 检查端口监听 ---------
check_ports() {
    ss -tuln | grep -q "$VLESS_PORT" && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    ss -tuln | grep -q "$HY2_PORT" && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"
}

# --------- 菜单循环 ---------
while :; do
echo -e "\n========= Alpine Sing-box 管理 ========="
echo "1) 切换模式 (自签/域名)"
echo "2) 修改端口"
echo "3) 重新申请证书"
echo "4) 重启/刷新服务"
echo "5) 删除 Sing-box"
echo "6) 显示当前节点信息"
echo "0) 退出"
read -rp "请选择操作: " CHOICE

case $CHOICE in
1)
    if [ "$MODE" = "1" ]; then
        MODE="2"
        generate_self_cert
        DOMAIN="www.epple.com"
        echo "MODE=$MODE" > "$DATA_FILE"
        echo "DOMAIN=$DOMAIN" >> "$DATA_FILE"
        echo "[✔] 切换到自签模式"
    else
        MODE="1"
        read -rp "请输入域名: " DOMAIN
        generate_letsencrypt_cert
        echo "MODE=$MODE" > "$DATA_FILE"
        echo "DOMAIN=$DOMAIN" >> "$DATA_FILE"
        echo "[✔] 切换到域名模式"
    fi
    generate_config
    systemctl restart sing-box
    check_ports
    ;;
2)
    read -rp "请输入 VLESS TCP 端口: " VLESS_PORT
    read -rp "请输入 Hysteria2 UDP 端口: " HY2_PORT
    echo "VLESS_PORT=$VLESS_PORT" > "$DATA_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$DATA_FILE"
    echo "UUID=$UUID" >> "$DATA_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$DATA_FILE"
    echo "MODE=$MODE" >> "$DATA_FILE"
    generate_config
    systemctl restart sing-box
    check_ports
    ;;
3)
    if [ "$MODE" = "1" ]; then
        generate_letsencrypt_cert
    else
        generate_self_cert
    fi
    generate_config
    systemctl restart sing-box
    check_ports
    ;;
4)
    systemctl restart sing-box
    check_ports
    ;;
5)
    systemctl stop sing-box || true
    systemctl disable sing-box || true
    rm -rf "$CONFIG_DIR"
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo "[✔] Sing-box 已删除"
    exit 0
    ;;
6)
    echo "模式: $( [ "$MODE" = "1" ] && echo "域名模式 ($DOMAIN)" || echo "自签模式 ($DOMAIN)")"
    echo "VLESS TCP端口: $VLESS_PORT"
    echo "Hysteria2 UDP端口: $HY2_PORT"
    echo "UUID: $UUID"
    echo "HY2密码: $HY2_PASS"
    echo "VLESS URI: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp"
    echo "HY2 URI: hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=$( [ "$MODE" = "2" ] && echo "1" || echo "0")&sni=$DOMAIN"
    ;;
0) exit 0 ;;
*) echo "[✖] 无效选项" ;;
esac
done
