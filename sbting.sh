#!/bin/sh
# Sing-box 一键部署 (Alpine + OpenRC)
# Author: Chis / ChatGPT 优化
set -e

CONFIG_FILE="/etc/singbox/config.json"
CERT_DIR="/etc/ssl/sing-box"
DATA_FILE="/etc/singbox/data.conf"
SERVICE_FILE="/etc/init.d/sing-box"

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
OS=$(awk -F= '/^ID=/ {print $2}' /etc/os-release)
[ "$OS" != "alpine" ] && echo "[✖] 当前系统非 Alpine" && exit 1
echo "[✔] 检测到系统: alpine"

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add curl wget socat bash openssl dcron

mkdir -p "$CERT_DIR"
mkdir -p "$(dirname $DATA_FILE)"

# --------- 获取公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && { echo "[✖] 获取公网 IP 失败"; exit 1; }
echo "[✔] 检测到公网 IP: $SERVER_IP"

# --------- 读取历史数据 ---------
if [ -f "$DATA_FILE" ]; then
    . "$DATA_FILE"
fi

# --------- 生成随机端口/UUID/HY2 密码 ---------
gen_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

[ -z "$VLESS_PORT" ] && VLESS_PORT=$(gen_port)
[ -z "$HY2_PORT" ] && HY2_PORT=$(gen_port)
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$HY2_PASS" ] && HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

# --------- OpenRC 服务文件 ---------
cat > $SERVICE_FILE <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/singbox/config.json"
pidfile="/var/run/sing-box.pid"
name="sing-box"
EOF
chmod +x $SERVICE_FILE
rc-update add sing-box default

# --------- 菜单功能函数 ---------
gen_cert() {
    MODE="$1"
    if [ "$MODE" = "1" ]; then
        read -p "请输入域名 (example.com): " DOMAIN
        [ -z "$DOMAIN" ] && { echo "[✖] 域名不能为空"; return; }
        DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n1)
        [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符"
        echo "[✔] 域名解析正常"

        # 安装 acme.sh 并申请证书
        [ ! -f "$HOME/.acme.sh/acme.sh" ] && curl https://get.acme.sh | sh
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        DOMAIN="www.epple.com"
        echo "[!] 自签模式，生成固定域名 $DOMAIN"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi
    chmod 644 "$CERT_DIR"/*.pem
}

gen_config() {
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

save_data() {
    cat > "$DATA_FILE" <<EOF
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
UUID=$UUID
HY2_PASS=$HY2_PASS
DOMAIN=$DOMAIN
MODE=$MODE
EOF
}

check_ports() {
    ss -tulnp | grep -q $VLESS_PORT && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
    ss -tulnp | grep -q $HY2_PORT && echo "[✔] Hysteria2 UDP $HY2_PORT 已监听" || echo "[✖] Hysteria2 UDP $HY2_PORT 未监听"
}

menu() {
while :; do
    echo "\n=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    printf "请输入选项: "
    read opt
    case $opt in
        1)
            echo "请选择模式：1) 域名模式 2) 自签模式"
            read m
            [ "$m" = "1" ] && MODE=1 || MODE=2
            gen_cert "$MODE"
            gen_config
            save_data
            /etc/init.d/sing-box restart
            check_ports
            ;;
        2)
            read -p "请输入 VLESS TCP 端口 (当前 $VLESS_PORT): " vp
            read -p "请输入 Hysteria2 UDP 端口 (当前 $HY2_PORT): " hp
            [ -n "$vp" ] && VLESS_PORT="$vp"
            [ -n "$hp" ] && HY2_PORT="$hp"
            gen_config
            save_data
            /etc/init.d/sing-box restart
            check_ports
            ;;
        3)
            [ "$MODE" != "1" ] && echo "[✖] 当前非域名模式" && continue
            gen_cert "$MODE"
            gen_config
            save_data
            /etc/init.d/sing-box restart
            ;;
        4)
            /etc/init.d/sing-box restart
            check_ports
            ;;
        5)
            echo "[*] 当前节点信息:"
            echo "VLESS: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN"
            echo "Hysteria2: hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=1&sni=$DOMAIN"
            ;;
        6)
            /etc/init.d/sing-box stop || true
            rm -rf /usr/local/bin/sing-box "$CONFIG_FILE" "$CERT_DIR" "$DATA_FILE" "$SERVICE_FILE"
            rc-update del sing-box
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
}

# --------- 安装 Sing-box ---------
[ ! -f /usr/local/bin/sing-box ] && curl -L https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.gz | gunzip -c > /usr/local/bin/sing-box && chmod +x /usr/local/bin/sing-box

# --------- 初始化 ---------
[ -z "$MODE" ] && MODE=2
gen_cert "$MODE"
gen_config
save_data

# --------- 启动服务 ---------
/etc/init.d/sing-box start
check_ports

# --------- 循环菜单 ---------
menu
