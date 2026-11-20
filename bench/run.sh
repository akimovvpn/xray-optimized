#!/bin/sh
# Benchmarks a linux xray binary as a remnanode-like server on 2 pinned CPUs.
# usage: bench/run.sh <server-xray> <label> [scenario...]     scenarios: down xdown churn idle (default: all)
# needs: out/xray-stock (client side, never changes), out/loadgen, out/geo/{geoip,geosite}.dat
# env:   ACCESS=none to turn the access log off, GOENV="GOGC=200 ..." extra server env
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
LABEL=$2
shift 2
SCEN=${*:-down xdown churn idle}
RES="$ROOT/bench/results/$LABEL"
NET=xbench
mkdir -p "$RES"
IMG=alpine:3.21
CURL="docker run --rm --network $NET curlimages/curl:8.11.1 -s"

cleanup() { docker rm -f xs xc sink target >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

KEYS=$(docker run --rm -v "$ROOT/out/xray-stock:/xray:ro" $IMG /xray x25519)
python3 -I "$ROOT/bench/gen_configs.py" "$RES" \
  "$(echo "$KEYS" | awk -F': ' '/^PrivateKey/ {print $2}')" "$(echo "$KEYS" | awk -F': ' '/^Password/ {print $2}')" "${ACCESS:-}"

docker network create $NET >/dev/null
LG="-v $ROOT/out/loadgen:/loadgen:ro"
docker run -d --name target --network $NET --cpuset-cpus 5 $LG $IMG /loadgen target -listen :443 >/dev/null
docker run -d --name sink --network $NET --cpuset-cpus 5 $LG $IMG /loadgen sink -listen :9000 >/dev/null
ENVS=""
for e in ${GOENV:-}; do ENVS="$ENVS -e $e"; done
# shellcheck disable=SC2086
docker run -d --name xs --network $NET --cpuset-cpus 0-1 --ulimit nofile=1048576:1048576 $ENVS \
  -e XRAY_LOCATION_ASSET=/geo -v "$ROOT/out/geo:/geo:ro" -v "$BIN:/xray:ro" -v "$RES/server.json:/c.json:ro" \
  $IMG /xray run -c /c.json >/dev/null
docker run -d --name xc --network $NET --cpuset-cpus 2-4 --ulimit nofile=1048576:1048576 \
  -v "$ROOT/out/xray-stock:/xray:ro" -v "$RES/client.json:/c.json:ro" $IMG /xray run -c /c.json >/dev/null
sleep 3
docker run --rm -v "$BIN:/xray:ro" $IMG /xray version | head -1 | tee "$RES/version.txt"

ticks() { docker exec xs awk '{print $14+$15}' /proc/1/stat; }
rss() { docker exec xs awk '/^(VmRSS|VmHWM)/ {printf "%s=%dMB ", $1, $2/1024}' /proc/1/status; }
gcvars() {
  $CURL http://xs:11111/debug/vars | python3 -I -c '
import json,sys; m=json.load(sys.stdin)["memstats"]
print(m["NumGC"], m["PauseTotalNs"], m["HeapInuse"], m["HeapSys"], m["StackInuse"], m["Sys"], m["TotalAlloc"], m["Mallocs"])'
}
goroutines() { $CURL "http://xs:11111/debug/pprof/goroutine?debug=1" | head -1 | awk '{print $NF}'; }

loadgen() { docker run --rm --network $NET --cpuset-cpus 6-7 --ulimit nofile=1048576:1048576 $LG $IMG /loadgen run "$@"; }

measure() { # name, profile-seconds, loadgen args...
  name=$1 psec=$2
  shift 2
  t0=$(ticks); g0=$(gcvars)
  if [ "$psec" -gt 0 ]; then
    (sleep 1; $CURL -o /dev/stdout "http://xs:11111/debug/pprof/profile?seconds=$psec" > "$RES/$name.cpu.pprof") &
  fi
  out=$(loadgen "$@") || { echo "$out"; for c in xs xc; do echo "--- $c"; docker logs $c 2>&1 | tail -6; done; exit 1; }
  wait
  t1=$(ticks); g1=$(gcvars)
  echo "$g0" "$g1" "$t0" "$t1" "$out" | python3 -I -c '
import sys,re
v=sys.stdin.read().split(); g0=list(map(int,v[0:8])); g1=list(map(int,v[8:16])); t0,t1=int(v[16]),int(v[17]); out=" ".join(v[18:])
kv=dict(x.split("=",1) for x in out.split() if "=" in x); cpu=(t1-t0)/100; gb=int(kv["bytes"])/1e9; ok=int(kv["ok"])
m=kv["mode"]; print(f"{m:6} {out}")
print(f"       server_cpu_s={cpu:.2f} cpu_s_per_GB={cpu/gb if gb else 0:.3f} cpu_ms_per_conn={cpu*1000/ok if ok else 0:.2f} "
      f"gc_runs={g1[0]-g0[0]} gc_pause_ms={(g1[1]-g0[1])/1e6:.1f} alloc_MB={(g1[6]-g0[6])/1e6:.0f} mallocs_k={(g1[7]-g0[7])/1e3:.0f}")' | tee -a "$RES/summary.txt"
}

: > "$RES/summary.txt"
echo "idle-start $(rss)" | tee -a "$RES/summary.txt"
for s in $SCEN; do
  case $s in
    down)  measure down 8 -socks xc:1080 -dst sink:9000 -mode down -conns 8 -bytes 1500000000 ;;
    xdown) measure xdown 8 -socks xc:1081 -dst sink:9000 -mode down -conns 8 -bytes 400000000 ;;
    churn) measure churn 8 -socks xc:1080 -dst sink:9000 -mode churn -conns 32 -total 6000 -bytes 65536 ;;
    idle)
      (sleep 35; { echo "idle-hold $(rss) goroutines=$(goroutines) memstats(NumGC PauseNs HeapInuse HeapSys StackInuse Sys TotalAlloc Mallocs)=$(gcvars)"; } >> "$RES/summary.txt"
       $CURL -o /dev/stdout http://xs:11111/debug/pprof/heap > "$RES/idle.heap.pprof"
       $CURL -o /dev/stdout "http://xs:11111/debug/pprof/goroutine?debug=1" > "$RES/idle.goroutines.txt") &
      measure idle 0 -socks xc:1080 -dst sink:9000 -mode idle -conns 3000 -dur 50s -interval 5s
      wait ;;
  esac
  $CURL -o /dev/stdout http://xs:11111/debug/pprof/allocs > "$RES/$s.allocs.pprof"
  echo "after-$s $(rss) goroutines=$(goroutines) heap_inuse_MB=$(gcvars | awk '{printf "%d", $3/1048576}') stack_inuse_MB=$(gcvars | awk '{printf "%d", $5/1048576}')" | tee -a "$RES/summary.txt"
done
grep idle-hold "$RES/summary.txt" || true
