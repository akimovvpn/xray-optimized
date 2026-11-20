# Optimized Xray-core for remnanode

Upstream Xray-core **v26.11.9** (the version `remnawave/node` 3.4.6 ships) with **two patches** and a tuned build.
Neither patch changes a byte on the wire.

## What's changed and why

**Patch 1 fixes mihomo clients.** Since Xray v26.9.9 ([XTLS/REALITY@8cdf7bf](https://github.com/XTLS/REALITY/commit/8cdf7bf9c7f0)), the REALITY server
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

**Patch 2 cuts CPU and memory** ([`patches/xray-core-performance.patch`](patches/xray-core-performance.patch)). Details in "Performance" below.

**The build** uses upstream's release flags (`-trimpath -s -w -gcflags=all=-l=4`) and Go 1.27. You can also turn on:
- **PGO**: put `default.pgo` next to the Dockerfile. Go typically reports 2–14% less CPU. See "CPU" below.
- **`GOAMD64=v3`** (AVX2): only if `grep -c avx2 /proc/cpuinfo` prints more than 0 on the node. Otherwise the binary won't start.

**Left unchanged on purpose:**
- The wire protocol. Changing it would break mihomo, sing-box and v2rayN clients.
- The feature set. Panel config profiles can use any feature, and remnanode needs the API, stats and routing services.

## Performance

Measured with `bench/run.sh`: a remnanode-like server with 1000 users, per-user stats, the API, online-IP tracking,
sniffing and geoip/geosite rules, pinned to 2 CPUs. The client and traffic generator run on other CPUs.
The traffic is inner TLS, like real HTTPS. The machine is an arm64 Docker VM, so look at the relative numbers.
Stock is the same source and build flags without patch 2.

| scenario | stock | this build |
|---|---|---|
| Vision download: CPU per GB (3 runs each) | 2.6–3.5 s | **1.5–1.8 s**, 0.6 s when direct mode starts early |
| Vision download: throughput on 2 CPUs | 530–705 MB/s | **950–1,130 MB/s** |
| Vision download: heap allocated per 12 GB / GC runs | 9.8–13 GB / 1,350–1,790 | **0.02–0.4 GB / 2–74** |
| 6000 short connections: CPU per connection | 1.10 ms | **0.98–1.01 ms** |
| 6000 short connections: heap allocated | 1,120 MB | **720 MB** |
| 3000 idle connections: RSS | 247–254 MB | **214 MB** |
| XHTTP download (code path not touched) | 2.48 s/GB | 2.37 s/GB (noise) |

What the profiles showed and what the patch does:

1. **Vision padding mode was the #1 CPU and allocation sink.** Vision only switches to its fast direct copy when a read
   ends exactly on an inner-TLS record boundary (that's needed for stealth). On fast downloads that can take a long time,
   and every write until then went through three slow helpers:
   - `IsCompleteRecord` copied the whole buffer into a new slice: 92% of all heap allocations on a download. It now walks the buffers in place (0 allocations, 5 ns instead of 6–10 µs).
   - `ReshapeMultiBuffer` searched for record headers with Rabin-Karp (`bytes.LastIndex`): 29% of server CPU. It now scans 8 bytes at a time (7× faster), and it builds its debug-log string only when debug logging is on.
   - `XtlsPadding` used `crypto/rand.Int`, which allocates a `big.Int` and makes a getrandom call per padding. It now uses Go's ChaCha8 global source (OS-seeded, unpredictable, allocation-free) with the same uniform range. Debug-log arguments are no longer boxed when debug is off.

   The whole padding write path is **5.9× faster** (33.5 µs → 5.7 µs per 32 KB) and allocates 96% less.
   The results are identical to upstream: fuzz tests compare the new code with the upstream implementations,
   and upstream's VLESS / Vision / REALITY end-to-end scenario tests pass.
2. **Idle connections pinned an 8 KB buffer each.** The reader on the raw client socket took a buffer from the pool
   and then blocked. On a bare TCP/Unix socket it now waits for readability first and takes the buffer only when data
   is there. Errors, EOF and deadlines behave as before (tested). Other platforms and wrapped connections keep the old code.

Measured but **not** changed, because the cost is inherent or the fix isn't worth the risk:
- In padding mode the remaining CPU is write syscalls (one per TLS record) and AES-GCM. Batching them would change record sizes and packet timing on the wire.
- Each connection runs 3 goroutines (~10 KB of stack each on average). That's xray's architecture.
- REALITY allocates two 17 KB buffers per handshake, and VLESS allocates an unpooled 8 KB first-packet buffer (about 35% of short-connection allocations). Pooling them is only safe if nothing reads them after release, and I haven't proven that.
- `GOGC`: 200 saves 4% CPU under churn for +33% peak memory, and 400 saves 6% for 2× memory. The default is the right balance. Use `GOMEMLIMIT` as the cap.
- The access log (on by default, one line per connection) costs about 1% CPU. Turn it off with `"log": {"access": "none"}` if you don't need it.

Re-run it yourself:

```bash
bench/run.sh out/xray-opt opt
```

One-time setup on an Apple Silicon Mac (use `--platform linux/amd64` on x86). It takes the stock core and geo files from remnanode and builds the load generator:

```bash
mkdir -p out/geo && docker create --platform linux/arm64 --name rwx remnawave/node:3.4.6 && docker cp -L rwx:/usr/local/bin/xray out/xray-stock && docker cp rwx:/usr/local/share/xray/geoip.dat out/geo/ && docker cp rwx:/usr/local/share/xray/geosite.dat out/geo/ && docker rm rwx
```

```bash
docker run --rm -v "$PWD:/w" -w /w/bench/loadgen -e CGO_ENABLED=0 golang:1.27-alpine go build -o /w/out/loadgen .
```

```bash
docker buildx build --platform linux/arm64 -o out/opt . && mv out/opt/xray out/xray-opt
```

Results (summary, CPU/heap/alloc profiles, goroutine dump) go to `bench/results/<label>/`.

## Build

```bash
docker buildx build --platform linux/amd64 -o out .
```

Output is `out/xray`. For an ARM node use `--platform linux/arm64`. For AVX2 add `--build-arg GOAMD64=v3`.
`out/xray` in this folder is already built for amd64 (both patches, no PGO, `GOAMD64=v1`).
The build runs the patch's equivalence tests, so a broken patch fails the build.

## Use it in remnanode

Ready-made binaries are on the [releases page](https://github.com/akimovvpn/xray-optimized/releases) (`xray-linux-amd64`, `xray-linux-arm64`, `SHA256SUMS`).
Pick one of the two ways below. Don't combine them.

**A. Download on start (simplest).** Add to `environment:` in the node's `docker-compose.yml`:

```yaml
      - CUSTOM_CORE_URL=https://github.com/akimovvpn/xray-optimized/releases/download/v26.11.9-opt.1/xray-linux-amd64
      - GOMEMLIMIT=700MiB
```

remnanode's `init-env.sh` downloads the core on every container start (the docs.rw install page doesn't mention this).
Use the pinned tag as above. A `/releases/latest/download/…` URL would also work, but then every restart could silently switch versions.

**B. Mount a local file** (no download at start). Get the binary next to `docker-compose.yml`:

```bash
curl -fLo xray https://github.com/akimovvpn/xray-optimized/releases/download/v26.11.9-opt.1/xray-linux-amd64 && chmod +x xray
```

Then add the two marked parts from [`docker-compose.yml`](docker-compose.yml):

```yaml
    environment:
      - GOMEMLIMIT=700MiB
    volumes:
      - ./xray:/usr/local/bin/xray:ro
```

Either way, restart:

```bash
docker compose up -d --force-recreate
```

Then check that the node uses the new core. The line should end in `optimized (go1.27.4 linux/amd64)`:

```bash
docker compose logs remnanode | grep "Xray version"
```

**When remnawave/node moves to a new Xray version:** change `XRAY_VERSION` in the Dockerfile, rebuild, and run the test.
If `git apply`, `patch` or the build's tests fail, the upstream code changed and the patches need redoing.

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
