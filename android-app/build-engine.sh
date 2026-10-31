#!/bin/bash
# Builds the Go engine (userspace Tailscale + SSH client, ../android-proto/engine) as libtsengine.so for the app.
# Needs Go on PATH and the Android NDK (r28 under ~/Library/Android/sdk/ndk). arm64 only for now (all current phones + the M-series emulator).
set -e; cd "$(dirname "$0")/../android-proto"
NDK=$(ls -d ~/Library/Android/sdk/ndk/28* | tail -1)
CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang
OUT=../android-app/android/app/src/main/jniLibs/arm64-v8a; mkdir -p "$OUT"
CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC=$CC GOFLAGS=-trimpath go build -buildmode=c-shared -ldflags "-s -w" -o "$OUT/libtsengine.so" ./engine
rm -f "$OUT/libtsengine.h"; echo "built $OUT/libtsengine.so"
