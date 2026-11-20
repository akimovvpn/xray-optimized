"""Writes a remnanode-like xray server config and a matching client config.

usage: python3 -I bench/gen_configs.py <outdir> <privateKey> <publicKey> [access_log]
"""
import json
import sys
import uuid

out, priv, pub = sys.argv[1], sys.argv[2], sys.argv[3]
access = sys.argv[4] if len(sys.argv) > 4 else ""  # "" = xray default (console), "none" = off
SNI, SID, USERS = "bench.local", "a1b2c3d4", 1000
ids = [str(uuid.UUID(int=i + 1)) for i in range(USERS)]  # deterministic; user 0 carries the traffic

reality = {"target": "target:443", "serverNames": [SNI], "privateKey": priv, "shortIds": ["", SID]}
sniff = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}
log = {"loglevel": "warning"}
if access:
    log["access"] = access

server = {
    "log": log,
    "api": {"services": ["HandlerService", "StatsService", "RoutingService"], "tag": "REMNAWAVE_API"},
    "stats": {},
    "metrics": {"tag": "metrics", "listen": "0.0.0.0:11111"},
    "policy": {
        "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True, "statsUserOnline": True}},
        "system": {k: True for k in ("statsInboundDownlink", "statsInboundUplink", "statsOutboundDownlink", "statsOutboundUplink")},
    },
    "inbounds": [
        {"tag": "REMNAWAVE_API_INBOUND", "listen": "@xtls-api-bench", "protocol": "tunnel"},
        {"tag": "VISION", "port": 443, "protocol": "vless", "sniffing": sniff,
         "settings": {"clients": [{"id": i, "email": f"user{n}", "flow": "xtls-rprx-vision"} for n, i in enumerate(ids)], "decryption": "none"},
         "streamSettings": {"network": "raw", "security": "reality", "realitySettings": reality}},
        {"tag": "XHTTP", "port": 8443, "protocol": "vless", "sniffing": sniff,
         "settings": {"clients": [{"id": i, "email": f"x-user{n}"} for n, i in enumerate(ids)], "decryption": "none"},
         "streamSettings": {"network": "xhttp", "security": "reality", "xhttpSettings": {"path": "/b", "mode": "auto"}, "realitySettings": reality}},
    ],
    "outbounds": [{"tag": "DIRECT", "protocol": "freedom",  # bench sink lives on a private docker IP
                   "settings": {"finalRules": [{"action": "allow", "ip": ["172.16.0.0/12"]}]}}, {"tag": "BLOCK", "protocol": "blackhole"}],
    "routing": {"rules": [
        {"inboundTag": ["REMNAWAVE_API_INBOUND"], "outboundTag": "REMNAWAVE_API"},
        {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
        {"domain": ["geosite:category-ads-all"], "outboundTag": "BLOCK"},
        {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
    ]},
}

client_reality = {"serverName": SNI, "fingerprint": "chrome", "password": pub, "shortId": SID}
client = {
    "log": {"loglevel": "warning", "access": "none"},
    "inbounds": [
        {"tag": "s-vision", "listen": "0.0.0.0", "port": 1080, "protocol": "socks", "settings": {"udp": False}},
        {"tag": "s-xhttp", "listen": "0.0.0.0", "port": 1081, "protocol": "socks", "settings": {"udp": False}},
    ],
    "outbounds": [
        {"tag": "vision", "protocol": "vless",
         "settings": {"vnext": [{"address": "xs", "port": 443, "users": [{"id": ids[0], "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
         "streamSettings": {"network": "raw", "security": "reality", "realitySettings": client_reality}},
        {"tag": "xhttp", "protocol": "vless",
         "settings": {"vnext": [{"address": "xs", "port": 8443, "users": [{"id": ids[0], "encryption": "none"}]}]},
         "streamSettings": {"network": "xhttp", "security": "reality", "xhttpSettings": {"path": "/b", "mode": "auto"}, "realitySettings": client_reality}},
    ],
    "routing": {"rules": [
        {"inboundTag": ["s-vision"], "outboundTag": "vision"},
        {"inboundTag": ["s-xhttp"], "outboundTag": "xhttp"},
    ]},
}

for name, cfg in (("server.json", server), ("client.json", client)):
    with open(f"{out}/{name}", "w") as f:
        json.dump(cfg, f, indent=1)
