# syntax=docker/dockerfile:1.7
# Builds a patched, optimized Xray-core binary for remnanode.
#   docker buildx build --platform linux/amd64 -o out .      -> ./out/xray
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build

# Same version remnawave/node 3.4.6 ships. The patch is pinned to it: on a bump, `patch` fails loudly instead of silently skipping.
ARG XRAY_VERSION=v26.11.9
ARG TARGETARCH
# v1 = runs on every x86-64 (same as official). v3 (AVX2) is a few % faster: use it only if `grep -c avx2 /proc/cpuinfo` on the server is > 0.
ARG GOAMD64=v1
# v8.0 = every arm64. v8.2 is fine on Graviton2+/Ampere/Neoverse.
ARG GOARM64=v8.0

RUN apk add --no-cache git patch
WORKDIR /src
RUN git clone --depth 1 --branch "${XRAY_VERSION}" https://github.com/XTLS/Xray-core.git .

COPY patches/ /patches/
RUN go mod download github.com/xtls/reality \
    && cp -r "$(go list -m -f '{{.Dir}}' github.com/xtls/reality)" /reality \
    && chmod -R u+w /reality \
    && patch -d /reality -p1 --forward < /patches/reality-accept-x25519-only.patch \
    && go mod edit -replace github.com/xtls/reality=/reality

# Optional PGO: drop a CPU profile named default.pgo next to this Dockerfile (see README). Without it the build is just non-PGO.
RUN --mount=type=bind,target=/ctx \
    if [ -f /ctx/default.pgo ]; then cp /ctx/default.pgo main/default.pgo && echo "PGO: on"; else echo "PGO: off"; fi

# Flags copied from upstream .github/workflows/release.yml; -pgo=auto picks up main/default.pgo when present.
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" GOAMD64="${GOAMD64}" GOARM64="${GOARM64}" \
    go build -o /out/xray -trimpath -buildvcs=false -pgo=auto -gcflags="all=-l=4" \
      -ldflags="-X github.com/xtls/xray-core/core.build=optimized -s -w -buildid=" ./main

FROM scratch
COPY --from=build /out/xray /xray
