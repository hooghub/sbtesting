#!/bin/bash
# Sing-box 全自动静默部署脚本
# 支持: VLESS TCP+TLS, HY2 UDP+QUIC+TLS, 自签 IP SAN, 随机端口, systemd
# Author: ChatGPT

set -euo pipefail

CONFIG_DIR="/etc/sing-box/config"
mkdir -p "$CONFIG_DIR"

# -------- 随机端口函数 --------
rand_port() {
    shuf -i 20000-65000 -n 1
}

# -------- 获取服务器公网 IP --------
IP=$(curl -s https://api.ip.sb/ip)
[[ -z "$IP" ]] && IP="127.0.0.1"

# -------- 生成自签证书 (IP SAN) --------
CERT="$CONFIG_DIR/server.crt"
KEY="$CONFIG_DIR/server.key"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$IP" \
        -addext "subjectAltName = IP:$IP" \
        -quiet >/dev/null 2>&1
fi

# -------- 随机端口 --------
TCP_PORT=$(rand_port)
UDP_PORT=$(rand_port)
QUIC_PORT=$(rand_port)

UUID=$(cat /proc/sys/kernel/random/uuid)

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
      "sniff": true,
      "tls": {
        "enabled": true,
        "certificate": "$CERT",
        "key": "$KEY"
      },
      "users": [
        {
          "name": "$UUID"
        }
      ]
    },
    {
      "type": "hy2",
      "tag": "hy2-udp",
      "listen": "0.0.0.0",
      "port": $UDP_PORT,
      "quic": {
        "enabled": true,
        "port": $QUIC_PORT,
        "tls": {
          "certificate": "$CERT",
          "key": "$KEY"
        }
      },
      "users": [
        {
          "name": "$UUID"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# -------- 创建 systemd 服务 --------
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

# -------- 生成 VLESS URI --------
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

# -------- 安装 qrencode 并生成 QR --------
if ! command -v qrencode &>/dev/null; then
    apt update -y && apt install -y qrencode
fi

qrencode -t ansiutf8 "$VLESS_URI"
qrencode -t ansiutf8 "$HY2_URI"

echo "部署完成！"
echo "VLESS TCP URI: $VLESS_URI"
echo "HY2 UDP+QUIC URI: $HY2_URI"
echo "订阅文件: $SUB_JSON"
echo "配置目录: $CONFIG_DIR"
