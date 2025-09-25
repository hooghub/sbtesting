#!/bin/bash
# 自动排查 VLESS + HY2 节点可连通性
# Author: ChatGPT

set -e

echo "=================== Sing-box 节点自动排查 ==================="

read -rp "请输入域名: " DOMAIN
read -rp "请输入 VLESS 端口 (TCP, 默认 443): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}
read -rp "请输入 HY2 端口 (UDP, 默认 8443): " HY2_PORT
HY2_PORT=${HY2_PORT:-8443}

echo
echo ">>> 1. 检查域名解析"
IP=$(dig +short $DOMAIN | tail -n1)
if [[ -z "$IP" ]]; then
    echo "[✖] 域名未解析或解析失败！"
else
    echo "[✔] 域名解析成功: $IP"
fi

echo
echo ">>> 2. 检查 VLESS TCP 端口监听"
TCP_LISTEN=$(ss -tulnp | grep $VLESS_PORT || true)
if [[ -z "$TCP_LISTEN" ]]; then
    echo "[✖] VLESS 端口 $VLESS_PORT 未监听！"
else
    echo "[✔] VLESS 端口 $VLESS_PORT 正在监听"
fi

echo
echo ">>> 3. 检查 HY2 UDP 端口监听"
UDP_LISTEN=$(ss -ulnp | grep $HY2_PORT || true)
if [[ -z "$UDP_LISTEN" ]]; then
    echo "[✖] HY2 端口 $HY2_PORT 未监听！"
else
    echo "[✔] HY2 端口 $HY2_PORT 正在监听"
fi

echo
echo ">>> 4. 检查 TLS 证书有效性"
CERT_PATH="/etc/ssl/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/ssl/$DOMAIN/privkey.pem"
if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    echo "[✖] TLS 证书或私钥不存在！路径: $CERT_PATH $KEY_PATH"
else
    echo "[✔] TLS 证书存在，尝试连接测试..."
    openssl s_client -connect $DOMAIN:$VLESS_PORT -servername $DOMAIN </dev/null &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo "[✔] VLESS TLS 握手成功"
    else
        echo "[✖] VLESS TLS 握手失败"
    fi
fi

echo
echo ">>> 5. 检查 sing-box 服务状态"
systemctl status sing-box --no-pager | grep Active
if [[ $? -eq 0 ]]; then
    echo "[✔] sing-box 服务正在运行"
else
    echo "[✖] sing-box 服务未运行"
fi

echo
echo ">>> 6. 建议节点信息测试"
echo "VLESS 节点: vless://你的UUID@$DOMAIN:$VLESS_PORT?encryption=none&security=tls&sni=$DOMAIN&type=tcp&flow=xtls-rprx-vision"
echo "HY2 节点: hysteria2://hy2user:你的密码@$DOMAIN:$HY2_PORT?insecure=0&sni=$DOMAIN"

echo
echo "=================== 排查完成 ==================="
