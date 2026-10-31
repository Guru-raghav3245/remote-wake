#!/bin/bash
# Builds universal (Intel + Apple Silicon) tailscale and tailscaled from source into app/vendor/tailscale/ (BSD-3, redistributable).
# Needs Go (downloaded to a temp dir and checked against go.dev's sha256 if not installed). Rerun to update: change TS below.
set -e; cd "$(dirname "$0")"
TS=1.104.4
OUT="$PWD/vendor/tailscale"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if ! command -v go >/dev/null; then
  V=$(curl -s "https://go.dev/VERSION?m=text" | head -1)
  curl -sfL "https://go.dev/dl/$V.darwin-$(uname -m | sed s/x86_64/amd64/).tar.gz" -o "$W/go.tgz"
  SUM=$(curl -s "https://go.dev/dl/?mode=json" | python3 -c "import sys,json;print([f['sha256'] for r in json.load(sys.stdin)[:3] for f in r['files'] if f['filename']=='$V.darwin-$(uname -m | sed s/x86_64/amd64/).tar.gz'][0])")
  [ "$(shasum -a 256 "$W/go.tgz" | cut -d' ' -f1)" = "$SUM" ] || { echo "Go checksum mismatch"; exit 1; }
  tar xzf "$W/go.tgz" -C "$W"; export PATH="$W/go/bin:$PATH"
fi
export GOPATH="$W/gopath" GOFLAGS=-trimpath CGO_ENABLED=0
LD="-s -w -X tailscale.com/version.longStamp=$TS -X tailscale.com/version.shortStamp=$TS"
for a in arm64 amd64; do GOOS=darwin GOARCH=$a go install -ldflags "$LD" tailscale.com/cmd/tailscale@v$TS tailscale.com/cmd/tailscaled@v$TS; done
mkdir -p "$OUT"
H=$(go env GOHOSTARCH); X=$([ "$H" = arm64 ] && echo amd64 || echo arm64)   # host arch lands in bin/, the other in bin/darwin_<arch>/
for b in tailscale tailscaled; do
  lipo -create "$W/gopath/bin/$b" "$W/gopath/bin/darwin_$X/$b" -output "$OUT/$b"
done
cp "$W/gopath/pkg/mod/tailscale.com@v$TS/LICENSE" "$OUT/LICENSE"; chmod -R u+w "$W" 2>/dev/null || true
echo "built Tailscale $TS in $OUT"
