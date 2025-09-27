#!/bin/bash
# ================= Sing-box 无域名自动部署 =================
# 功能: 自动部署 VLESS+TCP+TLS & HY2+UDP+TLS, 自签证书(IP SAN), systemd 启动, QR/订阅
# =========================================================

set -e

# ----------------- 检查 root -----------------
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# ----------------- 配置变量 -----------------
CONFIG_DIR="/etc/sing-box/config"
CERT_DIR="/etc/sing-box/cert"
SUB_FILE="/etc/sing-box/subscription.json"
DEFAULT_VLESS_PORT=$((RANDOM % 55535 + 10000))
DEFAULT_HY2_PORT=$((RANDOM % 55535 + 10000))

# ----------------- 安装依赖 -----------------
echo "[INFO] 安装依赖..."
apt update -y
apt install -y curl wget unzip socat openssl qrencode jq

# ----------------- 获取公网 IP -----------------
PUBLIC_IP=$(curl -s4 icanhazip.com)
echo "[INFO] 使用 VPS 公网 IP: $PUBLIC_IP"

# ----------------- 用户输入端口 -----------------
read -rp "请输入自定义 VLESS TCP 端口(默认 $DEFAULT_VLESS_PORT): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-$DEFAULT_VLESS_PORT}

read -rp "请输入自定义 HY2 UDP 端口(默认 $DEFAULT_HY2_PORT): " HY2_PORT
HY2_PORT=${HY2_PORT:-$DEFAULT_HY2_PORT}

# ----------------- 下载并安装 Sing-box -----------------
echo "[INFO] 下载并安装 Sing-box..."
ARCH=$(uname -m)
if [[ $ARCH == x86_64 ]]; then
    ARCH_TAG="amd64"
elif [[ $ARCH == aarch64 ]]; then
    ARCH_TAG="arm64"
else
    echo "不支持的架构: $ARCH" && exit 1
fi

# 使用第三方可用镜像
wget -O /tmp/sing-box.tar.gz "https://github.com/enpioodada/sing-box-core/releases/download/sing-box/sing-box-puernya-linux-$ARCH_TAG.tar.gz"
tar -xzf /tmp/sing-box.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# ----------------- 创建目录 -----------------
mkdir -p "$CONFIG_DIR" "$CERT_DIR"

# ----------------- 生成自签证书 -----------------
echo "[INFO] 生成自签证书..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP"

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

# ----------------- 生成节点 URI & QR & 订阅 -----------------
VLESS_URI="vless://$UUID@$PUBLIC_IP:$VLESS_PORT?security=tls&type=tcp#Sing-box-VLESS"
HY2_JSON=$(jq -n --arg host "$PUBLIC_IP" --arg pw "$UUID" --arg port "$HY2_PORT" '{type:"hysteria",server:$host,port:$port,password:$pw,obfs:"tls"}')

jq -n --arg vless "$VLESS_URI" --argjson hy2 "$HY2_JSON" '[{vless:$vless, hysteria:$hy2}]' > $SUB_FILE

# ----------------- 输出信息 -----------------
echo
echo "================= 部署完成 ================="
echo "VLESS URI: $VLESS_URI"
echo "HY2 JSON: $HY2_JSON"
echo "订阅文件: $SUB_FILE"
echo "VLESS QR:"
echo $VLESS_URI | qrencode -o - -t UTF8
echo "============================================"
