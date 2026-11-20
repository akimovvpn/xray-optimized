#!/bin/sh
# Checks a linux xray binary (same CPU arch as your docker) against a real mihomo client.
# Usage: test/mihomo-compat.sh ./out/xray        Needs docker + internet (REALITY borrows www.cloudflare.com's handshake).
set -eu
BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
MIHOMO_IMAGE=${MIHOMO_IMAGE:-metacubex/mihomo:v1.19.34}
DIR=$(mktemp -d)
NET=xcompat-$$
UUID=6f1c2a4e-8b7d-4c3a-9e2f-1a2b3c4d5e6f
SID=a1b2c3d4
SNI=www.cloudflare.com

cleanup() { docker rm -f "xs-$$" "mc-$$" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$DIR"; }
trap cleanup EXIT

KEYS=$(docker run --rm -v "$BIN:/xray:ro" alpine:3.21 /xray x25519)
PRIV=$(echo "$KEYS" | awk -F': ' '/^PrivateKey/ {print $2}')
PUB=$(echo "$KEYS" | awk -F': ' '/^Password/ {print $2}')

cat > "$DIR/server.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "vision", "port": 443, "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }], "decryption": "none" },
      "streamSettings": { "network": "raw", "security": "reality",
        "realitySettings": { "target": "$SNI:443", "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"] } } },
    { "tag": "xhttp", "port": 8443, "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "reality",
        "xhttpSettings": { "path": "/assets", "mode": "auto", "xPaddingBytes": "100-1000" },
        "realitySettings": { "target": "$SNI:443", "serverNames": ["$SNI"], "privateKey": "$PRIV", "shortIds": ["$SID"] } } }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

cat > "$DIR/mihomo.yaml" <<EOF
log-level: warning
ipv6: false
listeners:
  - { name: l1, type: mixed, listen: 0.0.0.0, port: 7001, proxy: vision-default }
  - { name: l2, type: mixed, listen: 0.0.0.0, port: 7002, proxy: vision-mlkem }
  - { name: l3, type: mixed, listen: 0.0.0.0, port: 7003, proxy: xhttp-default }
proxies:
  - { name: vision-default, type: vless, server: xs-$$, port: 443, uuid: $UUID, network: tcp, tls: true, udp: true,
      flow: xtls-rprx-vision, servername: $SNI, client-fingerprint: chrome,
      reality-opts: { public-key: $PUB, short-id: $SID } }
  - { name: vision-mlkem, type: vless, server: xs-$$, port: 443, uuid: $UUID, network: tcp, tls: true, udp: true,
      flow: xtls-rprx-vision, servername: $SNI, client-fingerprint: chrome,
      reality-opts: { public-key: $PUB, short-id: $SID, support-x25519mlkem768: true } }
  - { name: xhttp-default, type: vless, server: xs-$$, port: 8443, uuid: $UUID, network: xhttp, tls: true, udp: true,
      encryption: "", servername: $SNI, client-fingerprint: chrome,
      reality-opts: { public-key: $PUB, short-id: $SID },
      xhttp-opts: { path: /assets, x-padding-bytes: "100-1000" } }
rules:
  - MATCH,DIRECT
EOF

docker network create "$NET" >/dev/null
docker run -d --name "xs-$$" --network "$NET" -v "$BIN:/xray:ro" -v "$DIR/server.json:/s.json:ro" alpine:3.21 /xray run -c /s.json >/dev/null
docker run -d --name "mc-$$" --network "$NET" -v "$DIR/mihomo.yaml:/root/.config/mihomo/config.yaml:ro" "$MIHOMO_IMAGE" >/dev/null
sleep 4
docker run --rm -v "$BIN:/xray:ro" alpine:3.21 /xray version | head -1

fail=0
for p in 7001:vision-default 7002:vision-mlkem 7003:xhttp-default; do
  code=$(docker run --rm --network "$NET" curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' \
    --max-time 15 -x "socks5h://mc-$$:${p%%:*}" https://cp.cloudflare.com/ || true)
  if [ "$code" = 204 ]; then echo "PASS ${p#*:}"; else echo "FAIL ${p#*:} (http $code)"; fail=1; fi
done
# Security check: a plain TLS probe (no REALITY key) must be forwarded to the real site and see its real certificate.
code=$(docker run --rm --network "$NET" curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' \
  --max-time 15 --connect-to "$SNI:443:xs-$$:443" "https://$SNI/" || true)
if [ "$code" != 000 ]; then echo "PASS probe falls back to $SNI (http $code)"; else echo "FAIL probe fallback"; fail=1; fi
[ "$fail" = 0 ] || { echo "--- xray log"; docker logs "xs-$$" 2>&1 | tail -5; echo "--- mihomo log"; docker logs "mc-$$" 2>&1 | tail -5; }
exit "$fail"
