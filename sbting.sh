#!/bin/bash
# ==============================================
# Sing-box 改进版静默安装脚本
# 自动部署 VLESS TCP + TLS, HY2 UDP + QUIC + TLS
# 支持自签 TLS (IP SAN)
# 自动生成 QR / 节点 URI / 订阅 JSON
# ==============================================

set -euo pipefail

CONFIG_DIR="/etc/sing-box/config"
mkdir -p "$CONFIG_DIR"

# -------- 安装必要依赖 --------
if ! command -v sing-box &>/dev/null; then
    echo "安装 sing-box..."
    curl -Ls https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.zip -o /tmp/sing-box.zip
    unzip -q /tmp/sing-box.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
fi

for dep in curl qrencode jq openssl; do
    if ! command -v $dep &>/dev/null; then
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install -y $dep
    fi
done

# -------- 获取 VPS 公网 IP --------
IP=$(curl -s https://api.ip.sb/ip || echo "127.0.0.1")

# -------- 随机端口 --------
rand_port() { shuf -i 20000-65000 -n 1; }
TCP_PORT=$(rand_port)
UDP_PORT=$(rand_port)
QUIC_PORT=$(rand_port)

# -------- 生成 UUID --------
UUID=$(cat /proc/sys/kernel/random/uuid)

# -------- 自签 TLS 证书 --------
CERT="$CONFIG_DIR/server.crt"
KEY="$CONFIG_DIR/server.key"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$IP" \
        -addext "subjectAltName = IP:$IP" \
        -quiet >/dev/null 2>&1
fi

# -------- 生成 sing-box 配置 --------
CONFIG_JSON="$CONFIG_DIR/config.json"
cat > "$CONFIG_JSON" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-tcp",
      "listen": "0.0.0.0",
      "port": $TCP_PORT,
      "tls": {
        "enabled": true,
        "certificate": "$CERT",
        "key": "$KEY"
      },
      "users": [{"name": "$UUID"}]
    },
    {
      "type": "hy2",
      "tag": "hy2-udp",
      "listen": "0.0.0.0",
      "port": $UDP_PORT,
      "quic": {
        "enabled": true,
        "port": $QUIC_PORT,
        "tls": {"certificate": "$CERT","key": "$KEY"}
      },
      "users": [{"name": "$UUID"}]
    }
  ],
  "outbounds":[{"type":"direct"}]
}
EOF

# -------- systemd 服务 --------
SERVICE_FILE="/etc/systemd/system/sing-box.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_JSON
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

# -------- 节点 URI --------
VLESS_URI="vless://$UUID@$IP:$TCP_PORT?encryption=none&security=tls&type=tcp#SingBox-TCP"
HY2_URI="hy2://$UUID@$IP:$UDP_PORT?security=tls&type=quic&quicPort=$QUIC_PORT#SingBox-HY2"

# -------- 生成订阅 JSON --------
SUB_JSON="$CONFIG_DIR/subscribe.json"
cat > "$SUB_JSON" <<EOF
[
  {"name":"SingBox-TCP","type":"vless","server":"$IP","port":$TCP_PORT,"uuid":"$UUID","tls":true},
  {"name":"SingBox-HY2","type":"hy2","server":"$IP","port":$UDP_PORT,"uuid":"$UUID","tls":true,"quicPort":$QUIC_PORT}
]
EOF

# -------- 生成 QR --------
qrencode -t ansiutf8 "$VLESS_URI"
qrencode -t ansiutf8 "$HY2_URI"

echo "=============================="
echo "部署完成！"
echo "VLESS TCP URI: $VLESS_URI"
echo "HY2 UDP+QUIC URI: $HY2_URI"
echo "订阅 JSON: $SUB_JSON"
echo "配置目录: $CONFIG_DIR"
echo "systemd 服务: sing-box"
echo "=============================="
