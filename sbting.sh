#!/bin/bash
# ======================================================
# Sing-box VPS 一键安装脚本（优化版）
# 自动安装依赖/下载 sing-box，可直接运行
# 支持自签 TLS + VLESS TCP + HY2 UDP+QUIC
# 自动生成节点 URI、QR 和订阅 JSON
# ======================================================

set -euo pipefail

CONFIG_DIR="/etc/sing-box/config"
mkdir -p "$CONFIG_DIR"

# ---------------- 安装必要依赖 ----------------
install_dep() {
    local dep=$1
    if ! command -v "$dep" &>/dev/null; then
        echo "[INFO] 安装依赖: $dep"
        apt update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt install -y "$dep" >/dev/null 2>&1
    fi
}

for dep in curl unzip openssl qrencode jq; do
    install_dep $dep
done

# ---------------- 下载 Sing-box ----------------
if ! command -v sing-box &>/dev/null; then
    echo "[INFO] 下载 sing-box 可执行文件"
    TMP_ZIP="/tmp/sing-box.zip"
    curl -Ls https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.zip -o "$TMP_ZIP"
    unzip -q "$TMP_ZIP" -d /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
fi

# ---------------- 获取 VPS 公网 IP ----------------
IP=$(curl -s https://api.ip.sb/ip || echo "127.0.0.1")
echo "[INFO] 检测到 VPS 公网 IP: $IP"

# ---------------- 随机端口生成 ----------------
rand_port() { shuf -i 20000-65000 -n 1; }
TCP_PORT=$(rand_port)
UDP_PORT=$(rand_port)
QUIC_PORT=$(rand_port)
UUID=$(cat /proc/sys/kernel/random/uuid)

# ---------------- 自签 TLS 证书 ----------------
CERT="$CONFIG_DIR/server.crt"
KEY="$CONFIG_DIR/server.key"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "[INFO] 生成自签 TLS 证书"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$IP" \
        -addext "subjectAltName = IP:$IP" \
        -quiet >/dev/null 2>&1
fi

# ---------------- 生成 sing-box 配置 ----------------
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

# ---------------- systemd 服务 ----------------
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

# ---------------- 节点 URI ----------------
VLESS_URI="vless://$UUID@$IP:$TCP_PORT?encryption=none&security=tls&type=tcp#SingBox-TCP"
HY2_URI="hy2://$UUID@$IP:$UDP_PORT?security=tls&type=quic&quicPort=$QUIC_PORT#SingBox-HY2"

# ---------------- 生成订阅 JSON ----------------
SUB_JSON="$CONFIG_DIR/subscribe.json"
cat > "$SUB_JSON" <<EOF
[
  {"name":"SingBox-TCP","type":"vless","server":"$IP","port":$TCP_PORT,"uuid":"$UUID","tls":true},
  {"name":"SingBox-HY2","type":"hy2","server":"$IP","port":$UDP_PORT,"uuid":"$UUID","tls":true,"quicPort":$QUIC_PORT}
]
EOF

# ---------------- 生成 QR ----------------
qrencode -t ansiutf8 "$VLESS_URI"
qrencode -t ansiutf8 "$HY2_URI"

echo "======================================"
echo "部署完成！"
echo "VLESS TCP URI: $VLESS_URI"
echo "HY2 UDP+QUIC URI: $HY2_URI"
echo "订阅 JSON: $SUB_JSON"
echo "配置目录: $CONFIG_DIR"
echo "systemd 服务: sing-box"
echo "======================================"
