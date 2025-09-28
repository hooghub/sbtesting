#!/bin/sh
# Alpine OpenRC Sing-box 一键安装脚本（最终版，只使用 dcron）
# Author: ChatGPT

set -e

# --------- 检查 root ---------
[ "$(id -u)" != "0" ] && echo "[✖] 请用 root 权限运行" && exit 1
echo "[✔] Root 权限 OK"

# --------- 检查系统 ---------
if [ -f /etc/alpine-release ]; then
    echo "[✔] 检测到系统: Alpine Linux"
else
    echo "[✖] 仅支持 Alpine Linux" && exit 1
fi

# --------- 安装依赖 ---------
echo "[*] 安装依赖..."
apk update
apk add --no-cache bash curl wget socat openssl iproute2 dcron

# 启动并加入 OpenRC
rc-update add dcron
rc-service dcron start

# --------- 获取公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && echo "[✖] 获取公网 IP 失败" && exit 1
echo "[✔] 检测到公网 IP: $SERVER_IP"

# --------- 创建目录 ---------
mkdir -p /etc/singbox
PORT_FILE="/etc/singbox/port.conf"
CONF_FILE="/etc/singbox/config.json"
CERT_DIR="/etc/singbox/cert"
mkdir -p "$CERT_DIR"

# --------- 生成随机端口/UUID/HY2密码（首次运行） ---------
if [ ! -f "$PORT_FILE" ]; then
    VLESS_PORT=$((RANDOM%50000+10000))
    HY2_PORT=$((RANDOM%50000+10000))
    UUID=$(cat /proc/sys/kernel/random/uuid)
    HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
    echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
    echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
    echo "UUID=$UUID" >> "$PORT_FILE"
    echo "HY2_PASS=$HY2_PASS" >> "$PORT_FILE"
else
    . "$PORT_FILE"
fi

# --------- 生成自签证书函数 ---------
generate_self_cert() {
    DOMAIN="www.epple.com"
    echo "[!] 自签模式，生成固定域名 $DOMAIN 的自签证书"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
}

# --------- 生成 sing-box 配置 ---------
generate_config() {
    cat > "$CONF_FILE" <<EOF
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
start_service() {
    if [ -f /etc/init.d/sing-box ]; then
        rc-service sing-box restart
    else
        # 创建 OpenRC 服务
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="-c /etc/singbox/config.json"
pidfile="/var/run/sing-box.pid"
name="sing-box"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box
        rc-service sing-box start
    fi
}

# --------- VLESS/HY2 URI ---------
show_uri() {
    if [ "$MODE" = "1" ]; then
        NODE_HOST="$DOMAIN"
        INSECURE="0"
    else
        NODE_HOST="$SERVER_IP"
        INSECURE="1"
    fi
    VLESS_URI="vless://$UUID@$NODE_HOST:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$NODE_HOST"
    HY2_URI="hysteria2://$HY2_PASS@$NODE_HOST:$HY2_PORT?insecure=$INSECURE&sni=$DOMAIN#HY2-$NODE_HOST"

    echo -e "\n=================== 节点信息 ==================="
    echo "VLESS URI: $VLESS_URI"
    echo "HY2 URI  : $HY2_URI"
    echo "=============================================="
}

# --------- 循环菜单 ---------
while true; do
    echo -e "\n=================== Sing-box 菜单 ==================="
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
            if [ "$m" = "1" ]; then
                MODE=1
                read -p "请输入域名: " DOMAIN
                # 安装 acme.sh
                [ ! -f ~/.acme.sh/acme.sh ] && curl https://get.acme.sh | sh
                source ~/.bashrc || true
                ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
                ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
                    --key-file "$CERT_DIR/privkey.pem" \
                    --fullchain-file "$CERT_DIR/fullchain.pem" --force
            else
                MODE=2
                generate_self_cert
            fi
            generate_config
            start_service
            show_uri
            ;;
        2)
            read -p "输入新的 VLESS 端口 (Enter保持不变): " nv
            read -p "输入新的 HY2 端口 (Enter保持不变): " nh
            [ -n "$nv" ] && VLESS_PORT=$nv
            [ -n "$nh" ] && HY2_PORT=$nh
            echo "VLESS_PORT=$VLESS_PORT" > "$PORT_FILE"
            echo "HY2_PORT=$HY2_PORT" >> "$PORT_FILE"
            echo "UUID=$UUID" >> "$PORT_FILE"
            echo "HY2_PASS=$HY2_PASS" >> "$PORT_FILE"
            generate_config
            start_service
            show_uri
            ;;
        3)
            if [ "$MODE" = "1" ]; then
                ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256 --force
                ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
                    --key-file "$CERT_DIR/privkey.pem" \
                    --fullchain-file "$CERT_DIR/fullchain.pem" --force
                generate_config
                start_service
                show_uri
            else
                echo "[✖] 自签模式无需申请证书"
            fi
            ;;
        4)
            start_service
            show_uri
            ;;
        5)
            show_uri
            ;;
        6)
            rc-service sing-box stop || true
            rc-update del sing-box || true
            rm -rf /etc/singbox
            echo "[✔] Sing-box 已删除"
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选项"
            ;;
    esac
done
