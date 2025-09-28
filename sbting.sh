#!/bin/sh
# Alpine Sing-box 一键部署脚本
# 支持自签/域名模式，端口/UUID/HY2密码保存，循环菜单
# Author: ChatGPT (优化 by HHoog)

set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/certs"
META_FILE="$CONFIG_DIR/.singbox_meta"

mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# ---------- 系统依赖安装 ----------
apk update
for pkg in curl socat wget openssl bind-tools bash systemd; do
    if ! command -v $pkg >/dev/null 2>&1; then
        echo "[INFO] 安装依赖 $pkg..."
        apk add $pkg
    fi
done

# ---------- 公网 IP ----------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[ -z "$SERVER_IP" ] && { echo "[✖] 获取公网 IP 失败"; exit 1; }
echo "[✔] 检测到公网 IP: $SERVER_IP"

# ---------- 随机端口函数 ----------
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# ---------- 读取历史配置 ----------
if [ -f "$META_FILE" ]; then
    . "$META_FILE"
fi

# ---------- 安装 sing-box ----------
if ! command -v sing-box >/dev/null 2>&1; then
    echo "[INFO] 下载并安装 sing-box..."
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
    SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz"
    wget -O /tmp/sing-box.tar.gz "$SB_URL"
    tar xzf /tmp/sing-box.tar.gz -C /usr/local/bin
    chmod +x /usr/local/bin/sing-box
fi

# ---------- 菜单循环 ----------
while :; do
    echo
    echo "=================== Sing-box Alpine Menu ==================="
    echo "1) 切换模式（自签 / 域名）"
    echo "2) 修改端口"
    echo "3) 重新申请证书（仅域名模式）"
    echo "4) 重启 / 刷新服务"
    echo "5) 删除 Sing-box"
    echo "6) 显示当前节点信息"
    echo "0) 退出脚本"
    echo "============================================================"
    read -p "请选择操作: " OPT

    case $OPT in
        1)
            echo "选择部署模式：1) 域名 + Let's Encrypt 2) 自签固定 www.epple.com"
            read -p "请输入选项(1/2): " MODE
            [ "$MODE" = "1" ] && DOMAIN_MODE=1 || DOMAIN_MODE=2
            if [ "$DOMAIN_MODE" = "1" ]; then
                read -p "请输入你的域名: " DOMAIN
                DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
                [ "$DOMAIN_IP" != "$SERVER_IP" ] && echo "[✖] 域名解析不匹配 VPS IP" && continue
                echo "[✔] 域名解析正常"
            else
                DOMAIN="www.epple.com"
            fi
            ;;
        2)
            read -p "请输入 VLESS TCP 端口 (当前:${VLESS_PORT:-443}): " TMP
            VLESS_PORT=${TMP:-$VLESS_PORT}
            read -p "请输入 Hysteria2 UDP 端口 (当前:${HY2_PORT:-8443}): " TMP
            HY2_PORT=${TMP:-$HY2_PORT}
            ;;
        3)
            if [ "$DOMAIN_MODE" = "1" ]; then
                /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
                /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --force
                echo "[✔] 证书已更新"
            else
                echo "[!] 自签模式无需此操作"
            fi
            ;;
        4)
            systemctl enable sing-box
            systemctl restart sing-box
            echo "[✔] sing-box 服务已重启"
            ;;
        5)
            echo "[!] 删除 sing-box..."
            pkill sing-box || true
            rm -rf "$CONFIG_DIR" /usr/local/bin/sing-box
            echo "[✔] 删除完成"
            exit 0
            ;;
        6)
            echo "-------- 当前节点信息 --------"
            echo "模式: $( [ "$DOMAIN_MODE" = "1" ] && echo "域名" || echo "自签" )"
            echo "域名/CN: $DOMAIN"
            echo "VLESS TCP: ${VLESS_PORT:-443}"
            echo "HY2 UDP: ${HY2_PORT:-8443}"
            echo "UUID: ${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
            echo "HY2 密码: ${HY2_PASS:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')}"
            ;;
        0)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "输入错误，请重新选择"
            ;;
    esac

    # ---------- 自动生成 UUID / HY2 密码 ----------
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [ -z "$HY2_PASS" ] && HY2_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')

    # ---------- 生成证书 ----------
    if [ "$DOMAIN_MODE" = "1" ]; then
        [ ! -f "$CERT_DIR/fullchain.pem" ] && mkdir -p "$CERT_DIR" && /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
        [ ! -f "$CERT_DIR/fullchain.pem" ] && /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --force
    else
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" -subj "/CN=$DOMAIN" -addext "subjectAltName = DNS:$DOMAIN,IP:$SERVER_IP"
    fi

    # ---------- 生成 sing-box 配置 ----------
    cat > "$CONFIG_FILE" <<EOF
{
  "log":{"level":"info"},
  "inbounds":[
    {
      "type":"vless",
      "listen":"0.0.0.0",
      "listen_port":$VLESS_PORT,
      "users":[{"uuid":"$UUID"}],
      "tls":{"enabled":true,"server_name":"$DOMAIN","certificate_path":"$CERT_DIR/fullchain.pem","key_path":"$CERT_DIR/privkey.pem"}
    },
    {
      "type":"hysteria2",
      "listen":"0.0.0.0",
      "listen_port":$HY2_PORT,
      "users":[{"password":"$HY2_PASS"}],
      "tls":{"enabled":true,"server_name":"$DOMAIN","certificate_path":"$CERT_DIR/fullchain.pem","key_path":"$CERT_DIR/privkey.pem"}
    }
  ],
  "outbounds":[{"type":"direct"}]
}
EOF

    # ---------- 保存元信息 ----------
    cat > "$META_FILE" <<EOF
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
UUID=$UUID
HY2_PASS=$HY2_PASS
DOMAIN=$DOMAIN
DOMAIN_MODE=$DOMAIN_MODE
EOF

    # ---------- 启动服务 ----------
    systemctl enable sing-box
    systemctl restart sing-box
    echo "[✔] sing-box 已应用配置并启动"
done
