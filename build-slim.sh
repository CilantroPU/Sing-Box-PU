#!/bin/bash
set -x
BASE=$HOME/workspace/slimbuild
cd "$BASE" || exit 1
if [ ! -x "$BASE/go/bin/go" ]; then
  VER=$(curl -s -m 20 "https://go.dev/dl/?mode=json" | jq -r '.[0].version')
  echo "Go version: $VER"
  curl -sL -m 600 "https://go.dev/dl/${VER}.linux-amd64.tar.gz" | tar xz || exit 1
fi
export PATH="$BASE/go/bin:$PATH" GOPATH="$BASE/gopath" GOCACHE="$BASE/gocache" GOPROXY="https://goproxy.cn,direct" GOTMPDIR="$BASE/gotmp" CGO_ENABLED=0
go version
if [ ! -d src ]; then
  git clone --quiet --depth 1 --branch v1.14.4 https://github.com/SagerNet/sing-box.git src || exit 1
fi
cd src || exit 1
TAGS="with_quic,with_utls,with_acme"
echo "=== build amd64 tags=$TAGS ==="
time go build -trimpath -tags "$TAGS" -ldflags "-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=1.14.4" -o "$BASE/sing-box-slim" ./cmd/sing-box || exit 1
echo "=== build arm64 ==="
GOARCH=arm64 go build -trimpath -tags "$TAGS" -ldflags "-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=1.14.4" -o "$BASE/sing-box-slim-arm64" ./cmd/sing-box || exit 1
ls -la "$BASE"/sing-box-slim*
"$BASE/sing-box-slim" version
echo "BUILD_DONE"
