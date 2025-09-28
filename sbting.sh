#!/bin/sh
# Alpine OpenRC Sing-box 一键部署脚本
# 支持：自签/域名模式，端口/UUID/HY2密码保留，循环菜单
# Author: ChatGPT

set -e

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
INIT_FILE="/etc/init.d/sing-box"

# ------------------ 基础检查 ------------------
echo "=================== Sing-box 部署前环境检查 ==================="

# root
[ "$(id -u)" -ne 0 ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# 检测系统
OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
echo "[✔] 检测到系统: $OS"
if [ "$OS" != "Alpine Linux" ]; then
    echo "[✖] 仅支持 Alpine 系统"; exit 1
fi

# 检测公网 IP
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -n "$SERVER_IP" ] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# ------------------ 安装依赖 ------------------
echo "[*] 安装依赖..."
apk update
apk add bash curl wget socat dcron openssl

# ------------------ 生成随机端口/UUID/HY2密码 ------------------
if [ -f "$CONFIG_FILE" ]; then
    # 读取历史配置
    VLESS_PORT=$(jq -r '.inbounds[0].listen_port' "$CONFIG_FILE")
    HY2_PORT=$(jq -r '.inbounds[1].listen_port' "$CONFIG_FILE")
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONFIG_FILE")
    HY2_PASS=$(jq -r '.inbounds[1].users[0].password' "$CONFIG_FILE")
else
    VLESS_PORT=$((RANDOM%50000+10000))
    HY2_PORT=$((RANDOM%50000+10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
fi

# ------------------ 生成自签证书 ------------------
gen_self_cert() {
    mkdir -p "$CERT_DIR"
    DOMAIN="www.epple.com"
    echo "[!] 自签模式，生成固定域名 $DOMAIN"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    chmod 644 "$CERT_DIR"/*.pem
    echo "[✔] 自签证书生成完成"
}

# ------------------ 生成域名证书 ------------------
gen_domain_cert() {
    read -rp "请输入你的域名: " DOMAIN
    [ -z "$DOMAIN" ] && echo "[✖] 域名不能为空" && return 1
    # 检查解析
    DOMAIN_IP=$(nslookup "$DOMAIN" | awk '/^Address: / { print $2 }' | tail -n1)
    [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名解析 $DOMAIN_IP 与 VPS IP $SERVER_IP 不符" && return 1
    mkdir -p "$CERT_DIR"
    # acme.sh 自动申请
    if ! command -v acme.sh >/dev/null 2>&1; then
        curl https://get.acme.sh | sh
        source ~/.bashrc || true
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" --force
    echo "[✔] 域名证书生成完成"
}

# ------------------ 下载 Sing-box ------------------
install_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        mkdir -p /opt/sing-box && cd /opt/sing-box
        curl -L -O https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz
        tar -xzf sing-box-linux-amd64.tar.gz
        mv sing-box /usr/local/bin/
        chmod +x /usr/local/bin/sing-box
    fi
}

# ------------------ OpenRC 服务 ------------------
setup_openrc() {
    cat > "$INIT_FILE" <<'EOF'
#!/sbin/openrc-run
command=/usr/local/bin/sing-box
command_args=-c /etc/sing-box/config.json
pidfile=/var/run/sing-box.pid
name=sing-box
description="Sing-box Service"
depend() {
    need net
}
EOF
    chmod +x "$INIT_FILE"
    rc-update add sing-box default
}

# ------------------ 配置文件生成 ------------------
gen_config() {
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
}

# ------------------ 启动/重启服务 ------------------
start_service() {
    /etc/init.d/sing-box restart || /etc/init.d/sing-box start
}

# ------------------ 菜单循环 ------------------
while true; do
    echo "=================== Sing-box 菜单 ==================="
    echo "1) 切换模式 (自签/域名)"
    echo "2) 修改端口"
    echo "3) 重新申请证书 (仅域名模式)"
    echo "4) 重启/刷新服务"
    echo "5) 显示当前节点信息"
    echo "6) 删除 Sing-box"
    echo "0) 退出"
    read -rp "请输入选项: " CHOICE
    case $CHOICE in
        1)
            echo "请选择模式：1) 域名模式 2) 自签模式"
            read -rp "输入 (1/2): " MODE
            if [ "$MODE" = "1" ]; then
                gen_domain_cert || continue
            else
                gen_self_cert
            fi
            gen_config
            start_service
            ;;
        2)
            read -rp "请输入 VLESS TCP 端口: " VLESS_PORT
            read -rp "请输入 Hysteria2 UDP 端口: " HY2_PORT
            gen_config
            start_service
            ;;
        3)
            gen_domain_cert
            gen_config
            start_service
            ;;
        4)
            start_service
            ;;
        5)
            echo "VLESS: vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN"
            echo "HY2: hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=0&sni=$DOMAIN"
            ;;
        6)
            /etc/init.d/sing-box stop || true
            rc-update del sing-box
            rm -f /usr/local/bin/sing-box
            rm -rf /opt/sing-box /etc/sing-box /etc/ssl/sing-box /etc/init.d/sing-box
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

# ------------------ 脚本结束 ------------------
