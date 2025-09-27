#!/bin/bash
# ================= Sing-box 自动部署脚本 =================
# 功能: 自动部署 VLESS+TCP+TLS 和 HY2+UDP+TLS, 支持自签证书, systemd 启动, QR/订阅
# 作者: ChatGPT
# ========================================================

set -e

# ----------------- 检查 root -----------------
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# ----------------- 配置变量 -----------------
DEFAULT_VLESS_PORT=$((RANDOM % 55535 + 10000))
DEFAULT_HY2_PORT=$((RANDOM % 55535 + 10000))
CONFIG_DIR="/etc/sing-box/config"
CERT_DIR="/etc/sing-box/cert"
DOMAIN_OR_IP=""

# ----------------- 安装依赖 -----------------
echo "[INFO] 安装依赖..."
apt update -y
apt install -y curl wget unzip socat openssl qrencode jq

# ----------------- 获取公网 IP -----------------
PUBLIC_IP=$(curl -s4 icanhazip.com)
echo "[INFO] 检测到 VPS 公网 IP: $PUBLIC_IP"

# ----------------- 用户输入 -----------------
read -rp "请输入自定义 VLESS TCP 端口(默认 $DEFAULT_VLESS_PORT): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-$DEFAULT_VLESS_PORT}

read -rp "请输入自定义 HY2 UDP 端口(默认 $DEFAULT_HY2_PORT): " HY2_PORT
HY2_PORT=${HY2_PORT:-$DEFAULT_HY2_PORT}

read -rp "请输入域名或 IP (留空使用检测到的公网 IP $PUBLIC_IP): " DOMAIN_OR_IP
DOMAIN_OR_IP=${DOMAIN_OR_IP:-$PUBLIC_IP}

# ----------------- 安装 Sing-box -----------------
echo "[INFO] 安装 Sing-box..."
ARCH=$(uname -m)
if [[ $ARCH == x86_64 ]]; then
    ARCH_TAG="amd64"
elif [[ $ARCH == aarch64 ]]; then
    ARCH_TAG="arm64"
else
    echo "不支持的架构: $ARCH" && exit 1
fi

# 固定最新版下载链接（官方 tar.gz）
SINGBOX_VER="v1.12.8"
wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_VER/sing-box-$SINGBOX_VER-linux-$ARCH_TAG.tar.gz"
tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# ----------------- 创建目录 -----------------
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# ----------------- 生成自签证书 -----------------
echo "[INFO] 生成自签证书..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=$DOMAIN_OR_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP,DNS:$DOMAIN_OR_IP"

# ----------------- 生成 Sing-box 配置 -----------------
UUID=$(cat /proc/sys/kernel/random/uuid)

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $VLESS_PORT,
      "sniff": true,
      "tls": {
        "enabled": true,
        "certificate": "$CERT_DIR/server.crt",
        "key": "$CERT_DIR/server.key"
      },
      "users": [
        {
          "name": "$UUID"
        }
      ]
    },
    {
      "type": "hysteria",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": $HY2_PORT,
      "up_mbps": 100,
      "down_mbps": 100,
      "obfs": "tls",
      "tls": {
        "enabled": true,
        "certificate": "$CERT_DIR/server.crt",
        "key": "$CERT_DIR/server.key"
      },
      "password": "$UUID"
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# ----------------- 创建 systemd 服务 -----------------
echo "[INFO] 创建 systemd 服务..."
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# ----------------- 生成节点 URI & QR -----------------
VLESS_URI="vless://$UUID@$DOMAIN_OR_IP:$VLESS_PORT?security=tls&type=tcp#Sing-box-VLESS"
HY2_JSON=$(jq -n --arg host "$DOMAIN_OR_IP" --arg pw "$UUID" --arg port "$HY2_PORT" '{type:"hysteria",server:$host,port:$port,password:$pw,obfs:"tls"}')

echo
echo "================= 部署完成 ================="
echo "VLESS URI: $VLESS_URI"
echo "HY2 JSON: $HY2_JSON"
echo "VLESS QR:"
echo $VLESS_URI | qrencode -o - -t UTF8
echo "============================================"
