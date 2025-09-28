#!/bin/sh
# Alpine 专用 Sing-box 一键部署脚本
# 支持：自签固定域名 www.epple.com / 域名模式（Let's Encrypt）
# 完全不依赖 Python，兼容老版本 Alpine
# Author: Chis (优化 by ChatGPT)

set -e

PORT_FILE="/etc/singbox/port_info"
CONF_DIR="/etc/sing-box"
CERT_DIR="$CONF_DIR/cert"
SVC_FILE="/etc/systemd/system/sing-box.service"

mkdir -p "$CONF_DIR" "$CERT_DIR"

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统类型 ---------
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
echo "[✔] 检测到系统: $OS"

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 安装依赖 ---------
install_pkgs() {
    echo "[!] 安装依赖..."
    if [ "$OS" = "alpine" ]; then
        apk update
        apk add -U curl wget socat openssl bash qrencode coreutils bind-tools
        # 只安装一个 cron
        if ! command -v crond >/dev/null 2>&1; then
            apk add -U dcron
        fi
    else
        echo "[✖] 仅支持 Alpine"
        exit 1
    fi
}

install_pkgs

# --------- 安装 sing-box ---------
install_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo ">>> 下载并安装 sing-box ..."
        SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
        wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SB_VER/sing-box-$SB_VER-linux-amd64.tar.gz"
        tar -xzf /tmp/sing-box.tar.gz -C /tmp
        mv /tmp/sing-box "$CONF_DIR/sing-box"
        chmod +x "$CONF_DIR/sing-box"
        # 创建 systemd 服务
        cat > "$SVC_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$CONF_DIR/sing-box run -c $CONF_DIR/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box
    fi
}

install_singbox

# --------- 随机端口函数 ---------
get_random_port() {
    while :; do
        PORT=$((RANDOM % 50000 + 10000))
        ss -tuln | grep -q ":$PORT" || break
    done
    echo $PORT
}

# --------- 读取或生成配置 ---------
if [ -f "$PORT_FILE" ]; then
    . "$PORT_FILE"
else
    # 默认首次安装
    MODE=2 # 默认自签
    VLESS_PORT=$(get_random_port)
    HY2_PORT=$(get_random_port)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    DOMAIN="www.epple.com"
    echo "MODE=$MODE
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
UUID=$UUID
HY2_PASS=$HY2_PASS
DOMAIN=$DOMAIN" > "$PORT_FILE"
fi

# --------- 证书生成函数 ---------
gen_cert() {
    if [ "$MODE" -eq 1 ]; then
        # 域名模式
        echo ">>> 域名模式，请输入域名："
        read -rp "域名: " DOMAIN
        [ -z "$DOMAIN" ] && { echo "[✖] 域名不能为空"; exit 1; }
        # 安装 acme.sh
        if ! command -v acme.sh >/dev/null 2>&1; then
            curl https://get.acme.sh | sh
            source ~/.bashrc || true
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

# --------- 配置生成函数 ---------
gen_config() {
cat > "$CONF_DIR/config.json" <<EOF
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

# --------- 启动服务函数 ---------
start_svc() {
    systemctl restart sing-box
    sleep 3
    ss -tulnp | grep "$VLESS_PORT" >/dev/null && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    ss -ulnp | grep "$HY2_PORT" >/dev/null && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"
}

# --------- 生成二维码函数 ---------
show_qr() {
    VLESS_URI="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$SERVER_IP"
    HY2_URI="hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$DOMAIN#HY2-$SERVER_IP"
    echo -e "\nVLESS 节点: $VLESS_URI"
    qrencode -t ansiutf8 <<< "$VLESS_URI"
    echo -e "\nHY2 节点: $HY2_URI"
    qrencode -t ansiutf8 <<< "$HY2_URI"
}

# --------- 菜单循环 ---------
while :; do
echo -e "\n========= Sing-box Alpine 菜单 ========="
echo "1) 切换模式（自签/域名）"
echo "2) 修改端口"
echo "3) 重新申请证书（仅域名模式）"
echo "4) 重启/刷新服务"
echo "5) 显示节点二维码"
echo "6) 删除 Sing-box"
echo "0) 退出"
read -rp "请选择操作: " OP

case $OP in
1)
    MODE=$((MODE==1?2:1))
    gen_cert
    gen_config
    start_svc
    echo "[✔] 模式切换完成"
    ;;
2)
    read -rp "请输入 VLESS TCP 端口: " VLESS_PORT
    read -rp "请输入 HY2 UDP 端口: " HY2_PORT
    gen_config
    start_svc
    echo "[✔] 端口修改完成"
    ;;
3)
    if [ "$MODE" -eq 1 ]; then
        gen_cert
        gen_config
        start_svc
        echo "[✔] 证书更新完成"
    else
        echo "[✖] 自签模式无需证书"
    fi
    ;;
4)
    start_svc
    echo "[✔] 服务已重启/刷新"
    ;;
5)
    show_qr
    ;;
6)
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf "$CONF_DIR" "$SVC_FILE" "$PORT_FILE"
    systemctl daemon-reload
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

# 保存配置
echo "MODE=$MODE
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
UUID=$UUID
HY2_PASS=$HY2_PASS
DOMAIN=$DOMAIN" > "$PORT_FILE"

done
