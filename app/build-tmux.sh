#!/bin/bash
# Builds tmux (ISC licence) from source into app/vendor/tmux/ (Apple silicon only, like the app). libevent is linked statically,
# ncurses comes from macOS. Sources are checked against their sha256. Rerun to update: change TMUX/LIBEVENT and the sums below.
set -e; cd "$(dirname "$0")"
TMUX=3.8;  TMUX_SUM=e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e
LIBEVENT=2.1.13; LE_SUM=f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c
OUT="$PWD/vendor/tmux"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
get() { curl -sfL "$1" -o "$W/$2"; [ "$(shasum -a 256 "$W/$2" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $2"; exit 1; }; tar xzf "$W/$2" -C "$W"; }
get "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT-stable/libevent-$LIBEVENT-stable.tar.gz" le.tgz $LE_SUM
get "https://github.com/tmux/tmux/releases/download/$TMUX/tmux-$TMUX.tar.gz" tmux.tgz $TMUX_SUM
export MACOSX_DEPLOYMENT_TARGET=13.0 PATH=/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin   # no Homebrew: its pkg-config would link /opt/homebrew libraries
(cd "$W/libevent-$LIBEVENT-stable" && ac_cv_func_pipe2=no ./configure --prefix="$W/le" --disable-shared --disable-openssl --disable-samples --disable-libevent-regress >/dev/null && make -j8 >/dev/null && make install >/dev/null)
(cd "$W/tmux-$TMUX" && LIBEVENT_CFLAGS="-I$W/le/include" LIBEVENT_LIBS="-L$W/le/lib -levent_core" ./configure --disable-utf8proc --disable-jemalloc >/dev/null && make -j8 >/dev/null)
mkdir -p "$OUT"; cp "$W/tmux-$TMUX/tmux" "$OUT/tmux"; strip "$OUT/tmux"
cp "$W/tmux-$TMUX/COPYING" "$OUT/LICENSE"; cat "$W/libevent-$LIBEVENT-stable/LICENSE" >> "$OUT/LICENSE"
otool -L "$OUT/tmux" | grep -q /opt/homebrew && { echo "tmux links Homebrew libraries"; exit 1; }
nm -u "$OUT/tmux" | grep -q pipe2 && { echo "tmux needs pipe2 (macOS 27+)"; exit 1; }
echo "built tmux $TMUX in $OUT"
