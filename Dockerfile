# syntax=docker/dockerfile:1

# ---- stage 1: fetch & verify (thrown away) -------------------------------
FROM alpine:3.20 AS fetch
ARG SING_BOX_VERSION=1.9.5
ARG TARGETARCH

RUN apk add --no-cache ca-certificates busybox-static curl tar

WORKDIR /out
# sing-box 1.9.5: pure-Go static build (verified: no PT_INTERP / no PT_DYNAMIC),
# runs directly on scratch. Newer releases (>=1.12) switched to CGO builds and
# balloon to 31 MB compressed -- intentionally pinned to 1.9.5 for size.
RUN set -eux; \
    curl -fsSL -o /tmp/sb.tgz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/sb.tgz -C /tmp; \
    mv "/tmp/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}/sing-box" /out/sing-box; \
    chmod 0755 /out/sing-box; \
    echo '{"inbounds":[{"type":"vless","tag":"t","listen":"127.0.0.1","listen_port":18001,"users":[{"uuid":"bf000d23-0752-40b4-affe-68f7707a9661"}],"transport":{"type":"ws","path":"/x"}}],"outbounds":[{"type":"direct","tag":"direct"}]}' > /tmp/t.json; \
    if [ "$TARGETARCH" = "amd64" ]; then \
      /out/sing-box version | head -n 1; \
      /out/sing-box check -c /tmp/t.json && echo "config OK"; \
    fi; \
    ls -l /out

# ---- stage 2: direct (sing-box only, ~12 MB) ------------------------------
FROM scratch AS direct
LABEL org.opencontainers.image.title="tiny-argo" \
      org.opencontainers.image.description="Minimal sing-box VLESS-WS node (direct connection)" \
      org.opencontainers.image.licenses="MIT"

COPY --from=fetch /out/sing-box /usr/local/bin/sing-box
COPY --from=fetch /bin/busybox.static /bin/busybox
COPY --from=fetch /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY app/entrypoint.sh /app/entrypoint.sh

ENV PATH=/usr/local/bin:/bin \
    GOMEMLIMIT=64MiB \
    GOGC=100 \
    LOG_LEVEL=warn
EXPOSE 3000
ENTRYPOINT ["/bin/busybox", "sh", "/app/entrypoint.sh"]
