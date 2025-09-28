#!/bin/bash
# Sing-box 一键部署脚本 (Alpine 专用最终增强版)
# 支持：域名模式 / 自签固定域名 www.epple.com
# Author: Chis (优化 by ChatGPT)

set -e

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/ssl/sing-box"
mkdir -p "$CERT_DIR"

echo "=================== Sing-box 部署前环境检查 ==================="

# --------- 检查 root ---------
[[ $EUID -ne 0 ]] && echo "[✖] 请用 root 权限运行" && exit 1 || echo "[✔] Root 权限 OK"

# --------- 检测系统 ---------
if grep -qi alpine /etc/os-release; then
    OS_TYPE="alpine"
else
    echo "[✖] 本脚本仅支持 Alpine Linux" && exit 1
fi

# --------- 检测公网 IP ---------
SERVER_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
[[ -n "$SERVER_IP" ]] && echo "[✔] 检测到公网 IP: $SERVER_IP" || { echo "[✖] 获取公网 IP 失败"; exit 1; }

# --------- 安装依赖 ---------
REQUIRED_CMDS=(curl openssl wget socat bash qrencode dig)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &>/dev/null; then
        echo "[!] 安装缺失命令: $cmd"
        if [[ "$cmd" == "dig" ]]; then
            apk add --no-cache bind-tools
        elif [[ "$cmd" == "qrencode" ]]; then
            apk add --no-cache qrencode
        else
            apk add --no-cache $cmd
        fi
    fi
 done

# --------- 安装 cron ---------
if ! command -v crond &>/dev/null; then
    echo "[!] 安装 dcron"
    apk add --no-cache dcron
fi

# --------- 安装 sing-box ---------
if ! command -v sing-box &>/dev/null; then
    echo ">>> 下载并安装 sing-box ..."
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
    wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SB_VER/sing-box-$SB_VER-linux-amd64.tar.gz"
    tar zxvf /tmp/sing-box.tar.gz -C /usr/local/bin/ --strip-components=1
    chmod +x /usr/local/bin/sing-box
fi

# --------- 读取或初始化配置 ---------
if [[ -f "$CONFIG_FILE" ]]; then
    source <(jq -r '. | to_entries|map("\(.key)=\(.value|tostring)")|.[]' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

# --------- 菜单 ---------
while true; do
    echo -e "\n========= Sing-box Alpine 一键管理 ========="
    echo "1) 部署/更新 Sing-box"
    echo "2) 修改端口"
    echo "3) 切换域名模式/自签模式"
    echo "4) 显示当前节点链接"
    echo "5) 重启服务"
    echo "6) 一键删除 Sing-box"
    echo "0) 退出"
    read -rp "请输入选项: " OPTION

    case $OPTION in
    1)
        # --------- 模式选择 ---------
        echo -e "\n请选择部署模式：\n1) 使用域名 + Let's Encrypt\n2) 使用公网 IP + 自签固定域名 www.epple.com"
        read -rp "请输入选项 (1 或 2): " MODE
        [[ "$MODE" =~ ^[12]$ ]] || { echo "[✖] 输入错误"; continue; }

        if [[ "$MODE" == "1" ]]; then
            read -rp "请输入你的域名: " DOMAIN
            DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)
            [[ "$DOMAIN_IP" != "$SERVER_IP" ]] && { echo "[✖] 域名解析与 VPS IP 不符"; continue; }
            # 安装 acme.sh 并申请证书
            if ! command -v acme.sh &>/dev/null; then
                curl https://get.acme.sh | sh
                source ~/.bashrc || true
            fi
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

        # --------- 输入端口或使用上次 ---------
        read -rp "请输入 VLESS TCP 端口 (默认 ${VLESS_PORT:-443}): " IN_VLESS
        VLESS_PORT=${IN_VLESS:-${VLESS_PORT:-443}}
        read -rp "请输入 Hysteria2 UDP 端口 (默认 ${HY2_PORT:-8443}): " IN_HY2
        HY2_PORT=${IN_HY2:-${HY2_PORT:-8443}}

        # --------- 保留 UUID/HY2密码 ---------
        UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
        HY2_PASS=${HY2_PASS:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')}

        # --------- 生成配置 ---------
        cat > "$CONFIG_FILE" <<EOF
{
  "VLESS_PORT": $VLESS_PORT,
  "HY2_PORT": $HY2_PORT,
  "UUID": "$UUID",
  "HY2_PASS": "$HY2_PASS",
  "DOMAIN": "$DOMAIN",
  "MODE": $MODE
}
EOF

        cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {"type": "vless","listen": "0.0.0.0","listen_port": $VLESS_PORT,"users": [{ "uuid": "$UUID" }],"tls": {"enabled": true,"server_name": "$DOMAIN","certificate_path": "$CERT_DIR/fullchain.pem","key_path": "$CERT_DIR/privkey.pem"}},
    {"type": "hysteria2","listen": "0.0.0.0","listen_port": $HY2_PORT,"users": [{ "password": "$HY2_PASS" }],"tls": {"enabled": true,"server_name": "$DOMAIN","certificate_path": "$CERT_DIR/fullchain.pem","key_path": "$CERT_DIR/privkey.pem"}}
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

        # --------- 启动服务 ---------
        systemctl enable sing-box || true
        systemctl restart sing-box
        sleep 2

        # --------- 显示二维码 ---------
        VLESS_URI="vless://$UUID@$SERVER_IP:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp#VLESS-$DOMAIN"
        HY2_URI="hysteria2://$HY2_PASS@$SERVER_IP:$HY2_PORT?insecure=$( [[ $MODE==2 ]] && echo 1 || echo 0 )&sni=$DOMAIN#HY2-$DOMAIN"
        echo -e "\nVLESS URI:\n$VLESS_URI" | qrencode -t ansiutf8
        echo -e "\nHY2 URI:\n$HY2_URI" | qrencode -t ansiutf8
        ;;

    2)
        # 修改端口
        read -rp "请输入新的 VLESS TCP 端口: " VLESS_PORT
        read -rp "请输入新的 Hysteria2 UDP 端口: " HY2_PORT
        systemctl restart sing-box
        echo "[✔] 服务已更新端口并重启";;

    3)
        # 切换模式
        MODE=$((3 - MODE))
        echo "[✔] 已切换模式为 $([[ $MODE == 1 ]] && echo '域名模式' || echo '自签模式')"
        bash "$0";;

    4)
        echo -e "\n当前节点信息："
        echo -e "VLESS: $VLESS_URI"
        echo -e "HY2: $HY2_URI";;

    5)
        systemctl restart sing-box
        echo "[✔] 服务已重启";;

    6)
        systemctl stop sing-box || true
        rm -rf /usr/local/bin/sing-box $CONFIG_FILE $CERT_DIR
        echo "[✔] Sing-box 已删除";;

    0)
        exit 0;;
    *) echo "无效选项";;
    esac
 done
