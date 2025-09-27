#!/bin/bash

set -e

# ======================== 配色 ========================
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Sing-box 一键部署脚本启动...${NC}"

# ======================== 检查 root ========================
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本!"
    exit 1
fi

# ======================== 安装依赖 ========================
echo -e "${GREEN}检查并安装依赖...${NC}"
apt update
apt install -y curl wget unzip qrencode socat openssl

# ======================== 目录设置 ========================
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CERT_DIR="$CONFIG_DIR/cert"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERT_DIR"

# ======================== 下载最新版 Sing-box ========================
echo -e "${GREEN}获取最新版 Sing-box...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
URL="https://github.com/SagerNet/sing-box/releases/download/${VER}/sing-box-${VER#v}-linux-${ARCH}.zip"

cd /tmp
wget -O sing-box.zip "$URL"
unzip -o sing-box.zip
install -m 755 sing-box/sing-box "$INSTALL_DIR/sing-box"
rm -rf sing-box sing-box.zip

# ======================== 端口设置 ========================
read -p "请输入 VLESS TCP+TLS 端口（回车随机）： " VLESS_PORT
read -p "请输入 HY2 UDP+TLS 端口（回车随机）： " HY2_PORT

VLESS_PORT=${VLESS_PORT:-$((RANDOM%55535+10000))}
HY2_PORT=${HY2_PORT:-$((RANDOM%55535+10000))}

# ======================== 生成 UUID ========================
UUID=$(cat /proc/sys/kernel/random/uuid)

# ======================== 获取公网 IP ========================
IP=$(curl -6s https://api64.ipify.org || curl -4s https://api.ipify.org)

# ======================== 生成自签证书 ========================
echo -e "${GREEN}生成自签证书（3年有效，支持 IP SAN）...${NC}"
openssl req -new -newkey rsa:2048 -days 1095 -nodes -x509 \
    -subj "/CN=$IP" \
    -addext "subjectAltName = IP:$IP" \
    -keyout "$CERT_DIR/key.pem" \
    -out "$CERT_DIR/cert.pem"

# ======================== 生成配置文件 ========================
cat > $CONFIG_DIR/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IP",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    },
    {
      "type": "hy2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$IP",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# ======================== 写入 systemd 服务 ========================
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/sing-box run -c $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

sleep 2

# ======================== 生成节点 URI 和二维码 ========================
VLESS_URI="vless://$UUID@$IP:$VLESS_PORT?encryption=none&security=tls&type=tcp&sni=$IP#singbox-vless"
HY2_URI="hy2://$UUID@$IP:$HY2_PORT?security=tls&sni=$IP#singbox-hy2"

echo -e "${GREEN}VLESS 节点信息:${NC}"
echo "$VLESS_URI"
qrencode -o - "$VLESS_URI" 2>/dev/null | cat

echo -e "${GREEN}HY2 节点信息:${NC}"
echo "$HY2_URI"
qrencode -o - "$HY2_URI" 2>/dev/null | cat

# ======================== 生成订阅 JSON ========================
cat > $CONFIG_DIR/subscribe.json <<EOF
[
  {
    "name": "singbox-vless",
    "type": "vless",
    "server": "$IP",
    "port": $VLESS_PORT,
    "uuid": "$UUID",
    "tls": true
  },
  {
    "name": "singbox-hy2",
    "type": "hy2",
    "server": "$IP",
    "port": $HY2_PORT,
    "uuid": "$UUID",
    "tls": true
  }
]
EOF

echo -e "${GREEN}订阅 JSON 路径: $CONFIG_DIR/subscribe.json${NC}"
echo -e "${GREEN}Sing-box 已部署完成，systemd 服务已启动。${NC}"

systemctl status sing-box --no-pager
