# Optimized Xray-core for remnanode

Upstream Xray-core **v26.11.9** (the version `remnawave/node` 3.4.6 ships) with **one patch** and a tuned build.

## What's changed and why

**The patch fixes mihomo clients.** Since Xray v26.9.9 ([XTLS/REALITY@8cdf7bf](https://github.com/XTLS/REALITY/commit/8cdf7bf9c7f0)), the REALITY server
treats any Client Hello without an `X25519MLKEM768` key share as a prober and forwards it to the target site.
mihomo strips that key share unless `support-x25519mlkem768: true` is set, so default mihomo configs fail with
`REALITY authentication failed`. [`patches/reality-accept-x25519-only.patch`](patches/reality-accept-x25519-only.patch) restores the pre-v26.9.9
behaviour (3 lines removed). Clients without your key are still forwarded to the target.

Tested with mihomo v1.19.34 using `test/mihomo-compat.sh`:

| mihomo proxy | stock xray (remnawave/node:3.4.6) | this build |
|---|---|---|
| VLESS + REALITY + Vision, default | FAIL (auth failed) | PASS |
| VLESS + REALITY + Vision, `support-x25519mlkem768: true` | PASS | PASS |
| VLESS + REALITY + XHTTP, default | FAIL (auth failed) | PASS |
| Plain TLS probe without key | n/a | forwarded to real site (PASS) |

**The build** uses upstream's release flags (`-trimpath -s -w -gcflags=all=-l=4`) and Go 1.27. You can also turn on:
- **PGO**: put `default.pgo` next to the Dockerfile. Go typically reports 2–14% less CPU. See "CPU" below.
- **`GOAMD64=v3`** (AVX2): only if `grep -c avx2 /proc/cpuinfo` prints more than 0 on the node. Otherwise the binary won't start.

**Left unchanged on purpose:**
- The wire protocol. Changing it would break mihomo, sing-box and v2rayN clients.
- The feature set. Panel config profiles can use any feature, and remnanode needs the API, stats and routing services.

## Build

```bash
docker buildx build --platform linux/amd64 -o out .
```

Output is `out/xray`. For an ARM node use `--platform linux/arm64`. For AVX2 add `--build-arg GOAMD64=v3`.
`out/xray` in this folder is already built for amd64, without PGO, with `GOAMD64=v1`.

## Use it in remnanode

1. Copy `out/xray` to the node, next to its `docker-compose.yml`.
2. Add the two marked parts from [`docker-compose.yml`](docker-compose.yml):

   ```yaml
       environment:
         - GOMEMLIMIT=700MiB
       volumes:
         - ./xray:/usr/local/bin/xray:ro
   ```

3. Restart:

   ```bash
   docker compose up -d --force-recreate
   ```

4. Check that the node uses the new core. The line should end in `optimized (go1.27.x linux/amd64)`:

   ```bash
   docker compose logs remnanode | grep "Xray version"
   ```

Alternative: set `CUSTOM_CORE_URL=https://…/xray`. remnanode's `init-env.sh` supports it, though the docs.rw node install page doesn't mention it.
It downloads the core on every container start, so you have to host the file somewhere. Don't combine it with the volume mount.

**When remnawave/node moves to a new Xray version:** change `XRAY_VERSION` in the Dockerfile, rebuild, and run the test.
If `patch` fails, the upstream code changed and the patch needs redoing.

## Memory (set in the panel config profile)

remnanode keeps your `policy.levels.0` fields and only overwrites the stats flags:

```json
"policy": { "levels": { "0": { "bufferSize": 64, "connIdle": 180, "handshake": 4, "uplinkOnly": 1, "downlinkOnly": 1 } } }
```

- `bufferSize` is in KB, per connection and per direction. The amd64 default is **512 KB**, so 1000 slow clients can hold up to about 1 GB. 64 KB is enough for proxying.
- `GOMEMLIMIT` (compose env) makes the Go GC work harder as the heap nears the limit, instead of letting it grow. Set it to about 70% of the RAM you give xray. It's a soft limit.

## CPU

- Use **VLESS + Vision on RAW (TCP)** where possible. On Linux, xray hands direct traffic to the kernel (`splice`), which is the cheapest path.
  XHTTP costs more CPU, so keep it for networks where plain TCP gets throttled.
- **PGO from your real traffic:**
  1. Add `"metrics": { "tag": "metrics", "listen": "127.0.0.1:11111" }` to the config profile.
  2. At peak hours, on the node, run:

     ```bash
     curl -o default.pgo "http://127.0.0.1:11111/debug/pprof/profile?seconds=120"
     ```

  3. Put `default.pgo` next to the Dockerfile and rebuild. The build log shows `PGO: on`.
  4. Remove `metrics` from the profile again.

## TSPU: what the core can and can't do

These are all config choices, and all of them work with mihomo:

1. **REALITY target**: pick a site hosted on the same provider/ASN as your VPS that supports TLS 1.3 and HTTP/2 and isn't blocked in Russia.
   Avoid mega-popular domains: an SNI like `microsoft.com` on a Hetzner IP is an easy flag. Check a candidate with:

   ```bash
   docker exec remnanode rw-core tls ping example.com
   ```

2. **Port 443 only.** xray itself warns that other ports raise the block risk.
3. **Ask clients to send the post-quantum key share** (mihomo: `support-x25519mlkem768: true`). Real Chrome always sends it, so a "chrome" fingerprint without it looks odd.
   The patch only stops locking out clients that don't send it. It doesn't make them stealthier.
4. **Don't set `minClientVer`.** mihomo reports itself as version 1.8.2 and would be refused.
5. **XHTTP** (`network: xhttp`, mihomo supports it) for networks that freeze long TCP flows to foreign hosting IPs (reported cut-offs around 16–20 KB).
   It splits traffic into ordinary HTTP requests. Keep `xPaddingBytes` at the default unless your subscription template sends the same value to clients.
6. **`finalmask`** (xray's new obfuscation layer) is xray-only. mihomo's VLESS doesn't support it, so keep it off inbounds that mihomo clients use.

No server core can beat **IP whitelists** (mobile networks during shutdowns) or blocks by IP reputation. Those need a relay on an allowed IP.

## Re-test

```bash
test/mihomo-compat.sh out/xray
```

The binary must match your Docker's CPU architecture: build `linux/arm64` on an Apple Silicon Mac.
The test needs internet, because it borrows `www.cloudflare.com`'s handshake.
