#!/bin/bash
# Sing-box 完整部署脚本 (自签证书 + VLESS TLS + HY2 UDP+QUIC)
# Author: ChatGPT

set -e

echo "=================== Sing-box 自签证书部署 ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 安装依赖
apt update -y
apt install -y curl socat openssl qrencode dnsutils

# 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 获取公网 IP
PUBLIC_IP=$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me)
echo "[✔] 公网 IP: $PUBLIC_IP"

# 随机端口函数
get_random_port() {
    while :; do
        PORT=$((RANDOM%50000+10000))
        ss -tuln | grep -q $PORT || break
    done
    echo $PORT
}

# 输入端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 0随机): " VLESS_PORT
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP/QUIC 端口 (默认 8443, 0随机): " HY2_PORT
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# UUID / HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12)

# 配置目录
CONFIG_DIR="/etc/sing-box/config"
CERT_DIR="/etc/ssl/singbox_self"
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# 生成自签证书（IP SAN）
openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP" \
    -batch -quiet

chmod 600 "$CERT_DIR"/*.pem

# sing-box 配置
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{"uuid": "$UUID"}],
      "decryption": "none",
      "tls": {
        "enabled": true,
        "server_name": "$PUBLIC_IP",
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
        "server_name": "$PUBLIC_IP",
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      },
      "up_mbps": 1000,
      "down_mbps": 1000,
      "quic": {
        "enabled": true
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# 权限
chown -R sing-box:sing-box "$CONFIG_DIR" "$CERT_DIR"

# 重载 systemd 并启动
systemctl daemon-reload
systemctl enable --now sing-box
sleep 3

# 检查端口
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 已监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -ulnp | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP/QUIC $HY2_PORT 已监听" || echo "[✖] HY2 UDP/QUIC $HY2_PORT 未监听"

# 输出节点 URI
VLESS_URI="vless://$UUID@$PUBLIC_IP:$VLESS_PORT?encryption=none&security=tls&sni=$PUBLIC_IP&type=tcp#VLESS-$PUBLIC_IP"
HY2_URI="hysteria2://$HY2_PASS@$PUBLIC_IP:$HY2_PORT?insecure=0&sni=$PUBLIC_IP#HY2-$PUBLIC_IP"

echo -e "\n=================== VLESS 节点 ==================="
echo "$VLESS_URI"
echo "二维码："
echo "$VLESS_URI" | qrencode -t ansiutf8

echo -e "\n=================== HY2 节点 ==================="
echo "$HY2_URI"
echo "二维码："
echo "$HY2_URI" | qrencode -t ansiutf8

# 生成订阅文件
SUB_FILE="/root/singbox_nodes_self_signed_quic.json"
cat > $SUB_FILE <<EOF
{
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI"
}
EOF
echo -e "\n订阅文件已生成: $SUB_FILE"

echo -e "\n=================== 部署完成 ==================="
