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
NAME=${NAME:-tiny}
HOST=${HOST:-}
LOG_LEVEL=${LOG_LEVEL:-info}
SB_MEM=${GOMEMLIMIT:-20MiB}
export GOGC=${GOGC:-50}

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
LINK="vless://${UUID}@${HOST}:${PORT}?encryption=none&security=none&type=ws&host=${HOST}&path=%2F${UUID}%3Fed%3D2048#${NAME}"

log "----------------------------------------------"
log "NODE: $LINK"
log "----------------------------------------------"

# ---------- run sing-box in foreground (PID 1) ----------
export GOMEMLIMIT=$SB_MEM
log "sing-box starting (GOMEMLIMIT=${SB_MEM})"
exec $SB run -c "$CFG"
