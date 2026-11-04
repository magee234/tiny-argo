#!/bin/busybox sh
# tiny-argo (direct) entrypoint: sing-box VLESS-WS, no tunnel
# Runs on busybox-static only (no bash / no coreutils) to keep the image tiny.
set -u

BB=/bin/busybox
SB=/usr/local/bin/sing-box
APP=/app
CFG=$APP/config.json

$BB mkdir -p /tmp

UUID=${UUID:-}
PORT=${PORT:-3000}
PUBLIC_PORT=${PUBLIC_PORT:-$PORT}
NAME=${NAME:-tiny}
HOST=${HOST:-}
LOG_LEVEL=${LOG_LEVEL:-warn}
TLS_DOMAIN=${TLS_DOMAIN:-}
# 64MiB/GOGC=100: 20MiB+GOGC=50 实测会让 GC 连续触发，大流量下吞吐明显下降。
# 64MiB 对单个 sing-box 进程足够（实测峰值 RSS ~40MB），且留了非堆内存余量。
SB_MEM=${GOMEMLIMIT:-64MiB}
export GOGC=${GOGC:-100}

ts()  { $BB date +%H:%M:%S; }
log() { $BB echo "[$(ts)] $*"; }

# ---------- UUID ----------
[ -z "$UUID" ] && UUID=$($SB generate uuid)

# ---------- sing-box config ----------
$BB cat > "$CFG" <<EOF
{
  "log": { "level": "${LOG_LEVEL}", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [ { "uuid": "${UUID}" } ],
      "transport": {
        "type": "ws",
        "path": "/${UUID}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

$SB check -c "$CFG" 2>/dev/null || { log "FATAL: generated config rejected by sing-box"; exit 1; }
log "sing-box config OK (port ${PORT})"

# ---------- node link ----------
if [ -z "$HOST" ]; then
  HOST=$($BB wget -q -O - -T 6 "http://ip-api.com/line?fields=query" 2>/dev/null | $BB tr -d '\r\n')
fi
if [ -z "$HOST" ]; then
  log "WARN: public IP not detected; set HOST=<your-ip> to get a usable link"
  HOST="YOUR_SERVER_IP"
fi
# path 故意不带 ?ed=2048：实测部分客户端（v2rayN 等）带上 early data 会让
# sing-box 返回 400 Bad Request（Sec-WebSocket-Protocol 解析失败）。
# 不带 ed 服务端同样接受，只损失约一个 RTT 的首包优化。
LINK="vless://${UUID}@${HOST}:${PUBLIC_PORT}?encryption=none&security=none&type=ws&host=${HOST}&path=%2F${UUID}#${NAME}"

# 平台另外提供 HTTPS 域名时（Railway HTTP 入口等），顺带输出一条 TLS 链接。
# TLS 由平台边缘终止，容器内仍是明文 WS，伪装性更好且通常比 TCP 代理更快。
TLS_LINK=""
if [ -n "$TLS_DOMAIN" ]; then
  TLS_LINK="vless://${UUID}@${TLS_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${TLS_DOMAIN}&sni=${TLS_DOMAIN}&path=%2F${UUID}&alpn=http%2F1.1#${NAME}-tls"
fi

log "----------------------------------------------"
log "NODE: $LINK"
if [ -n "$TLS_LINK" ]; then log "NODE-TLS: $TLS_LINK"; fi
log "----------------------------------------------"

# ---------- run sing-box in foreground (PID 1) ----------
export GOMEMLIMIT=$SB_MEM
log "sing-box starting (GOMEMLIMIT=${SB_MEM})"
exec $SB run -c "$CFG"
