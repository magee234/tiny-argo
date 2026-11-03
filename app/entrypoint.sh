#!/bin/busybox sh
# tiny-argo entrypoint: sing-box VLESS-WS + optional cloudflared tunnel
# Runs on busybox-static only (no bash / no coreutils) to keep the image tiny.
set -u

BB=/bin/busybox
SB=/usr/local/bin/sing-box
CF=/usr/local/bin/cloudflared
APP=/app
CFG=$APP/config.json
LOG=$APP/argo.log

$BB mkdir -p /tmp

UUID=${UUID:-}
PORT=${PORT:-3000}
ARGO_DOMAIN=${ARGO_DOMAIN:-}
ARGO_AUTH=${ARGO_AUTH:-}
DISABLE_ARGO=${DISABLE_ARGO:-false}
NAME=${NAME:-tiny}
HOST=${HOST:-}
CFIP=${CFIP:-}
CFPORT=${CFPORT:-443}
LOG_LEVEL=${LOG_LEVEL:-info}
SB_MEM=${GOMEMLIMIT:-20MiB}
CF_MEM=${CF_GOMEMLIMIT:-32MiB}
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

# ---------- cloudflared (argo tag only, disable with DISABLE_ARGO=true) ----------
DOMAIN=""
if [ "$DISABLE_ARGO" != "true" ] && [ -x "$CF" ]; then
  if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
    log "argo: fixed tunnel -> ${ARGO_DOMAIN}"
    GOMEMLIMIT=$CF_MEM $CF tunnel --no-autoupdate run --token "$ARGO_AUTH" > "$LOG" 2>&1 &
    DOMAIN=$ARGO_DOMAIN
  else
    log "argo: starting quick tunnel (trycloudflare)..."
    GOMEMLIMIT=$CF_MEM $CF tunnel \
      --url "http://localhost:${PORT}" \
      --no-autoupdate --protocol http2 --edge-ip-version auto \
      > "$LOG" 2>&1 &
    i=0
    while [ $i -lt 45 ]; do
      $BB sleep 1
      DOMAIN=$($BB grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" 2>/dev/null \
               | $BB head -n 1 | $BB sed 's|https://||')
      [ -n "$DOMAIN" ] && break
      i=$((i+1))
    done
    if [ -z "$DOMAIN" ]; then
      log "argo: quick tunnel failed (see below), falling back to direct link"
      $BB tail -n 5 "$LOG" 2>/dev/null
    fi
  fi
fi

# ---------- node link ----------
if [ -n "$DOMAIN" ]; then
  ADDR=${CFIP:-$DOMAIN}
  APORT=${CFPORT:-443}
  LINK="vless://${UUID}@${ADDR}:${APORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=http&alpn=http/1.1&type=ws&host=${DOMAIN}&path=%2F${UUID}%3Fed%3D2048#${NAME}"
else
  if [ -z "$HOST" ]; then
    HOST=$($BB wget -q -O - -T 6 "http://ip-api.com/line?fields=query" 2>/dev/null | $BB tr -d '\r\n')
  fi
  if [ -z "$HOST" ]; then
    log "WARN: public IP not detected; set HOST=<your-ip> to get a usable link"
    HOST="YOUR_SERVER_IP"
  fi
  LINK="vless://${UUID}@${HOST}:${PORT}?encryption=none&security=none&type=ws&host=${HOST}&path=%2F${UUID}%3Fed%3D2048#${NAME}"
fi

log "----------------------------------------------"
log "NODE: $LINK"
log "----------------------------------------------"

# ---------- run sing-box in foreground (PID 1) ----------
export GOMEMLIMIT=$SB_MEM
log "sing-box starting (GOMEMLIMIT=${SB_MEM})"
exec $SB run -c "$CFG"
