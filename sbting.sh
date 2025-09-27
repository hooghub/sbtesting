#!/bin/bash
# sing-box 自签证书部署 (VLESS TLS + HY2 TLS UDP+QUIC)
# Author: ChatGPT
set -euo pipefail

echo "=== Sing-box 自签证书部署 (VLESS TLS + HY2 TLS UDP+QUIC) ==="

# 1️⃣ 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 2️⃣ 获取公网 IP
PUBLIC_IP=$(curl -s --max-time 8 https://ipv4.icanhazip.com || curl -s --max-time 8 https://ifconfig.me)
if [[ -z "$PUBLIC_IP" ]]; then
  read -rp "无法自动检测公网 IP，请手动输入: " PUBLIC_IP
fi
PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '[:space:]')
echo "公网 IP: $PUBLIC_IP"

# 3️⃣ 安装依赖
apt update -y
apt install -y curl openssl qrencode socat dnsutils jq

# 4️⃣ 安装 sing-box
if ! command -v sing-box &>/dev/null; then
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
fi

# 5️⃣ 随机端口函数
get_random_port() {
  while :; do
    PORT=$((RANDOM%50000+10000))
    ss -nulp | awk '{print $5}' | grep -q ":$PORT$" && continue || { echo "$PORT"; break; }
  done
}

# 6️⃣ 输入端口
read -rp "请输入 VLESS TCP 端口 (默认 443, 0随机): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}
[[ "$VLESS_PORT" == "0" || -z "$VLESS_PORT" ]] && VLESS_PORT=$(get_random_port)

read -rp "请输入 HY2 UDP/QUIC 端口 (默认 8443, 0随机): " HY2_PORT
HY2_PORT=${HY2_PORT:-8443}
[[ "$HY2_PORT" == "0" || -z "$HY2_PORT" ]] && HY2_PORT=$(get_random_port)

# 7️⃣ 生成 UUID 和 HY2 密码
UUID=$(cat /proc/sys/kernel/random/uuid)
HY2_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)

echo "UUID: $UUID"
echo "HY2 PASS: $HY2_PASS"
echo "VLESS port: $VLESS_PORT"
echo "HY2 port: $HY2_PORT"

# 8️⃣ 证书目录
CERT_DIR="/etc/ssl/singbox_self"
mkdir -p "$CERT_DIR"

# 9️⃣ 生成自签证书 (IP SAN)
echo ">>> 生成自签证书..."
openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP"

chmod 600 "$CERT_DIR"/*.pem

# 10️⃣ 创建配置目录
CONFIG_DIR="/etc/sing-box/config"
mkdir -p "$CONFIG_DIR"

# 11️⃣ 生成配置文件
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "decryption": "none",
      "tls": {
        "enabled": true,
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
        "certificate_path": "$CERT_DIR/fullchain.pem",
        "key_path": "$CERT_DIR/privkey.pem"
      },
      "udp": { "enabled": true },
      "quic": { "enabled": true, "max_streams": 1024 }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

# 12️⃣ systemd 指向目录
if grep -q "ExecStart=/usr/bin/sing-box" /lib/systemd/system/sing-box.service; then
    sed -i "s#ExecStart=.*#ExecStart=/usr/bin/sing-box run -C $CONFIG_DIR#g" /lib/systemd/system/sing-box.service
fi

# 13️⃣ 重载 systemd 并启动
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
sleep 2

# 14️⃣ 检查端口监听
[[ -n "$(ss -tulnp | grep $VLESS_PORT)" ]] && echo "[✔] VLESS TCP $VLESS_PORT 正在监听" || echo "[✖] VLESS TCP $VLESS_PORT 未监听"
[[ -n "$(ss -u -l -n | grep $HY2_PORT)" ]] && echo "[✔] HY2 UDP/QUIC $HY2_PORT 正在监听" || echo "[✖] HY2 UDP/QUIC $HY2_PORT 未监听"

# 15️⃣ 输出节点 URI
VLESS_URI="vless://$UUID@$PUBLIC_IP:$VLESS_PORT?encryption=none&security=tls&sni=$PUBLIC_IP&type=tcp#VLESS-$PUBLIC_IP"
HY2_URI="hysteria2://$HY2_PASS@$PUBLIC_IP:$HY2_PORT?insecure=1&quic=1#HY2-$PUBLIC_IP"

echo -e "\n=================== 节点信息 ==================="
echo "VLESS URI:"
echo "$VLESS_URI"
echo "$VLESS_URI" | qrencode -t ansiutf8 || true
echo
echo "HY2 URI:"
echo "$HY2_URI"
echo "$HY2_URI" | qrencode -t ansiutf8 || true

# 16️⃣ 生成订阅 JSON
SUB_FILE="/root/singbox_nodes_self_signed_quic.json"
cat > "$SUB_FILE" <<EOF
{
  "ip": "$PUBLIC_IP",
  "vless": "$VLESS_URI",
  "hysteria2": "$HY2_URI",
  "singbox_config_dir": "$CONFIG_DIR",
  "certificate": "$CERT_DIR/fullchain.pem"
}
EOF

echo "订阅文件已保存到: $SUB_FILE"
echo "部署完成，客户端请允许自签证书或导入 fullchain.pem，HY2 已开启 QUIC + UDP"
