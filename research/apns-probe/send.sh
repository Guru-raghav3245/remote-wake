#!/bin/bash
# usage: ./send.sh background   or   ./send.sh alert
# Run on the sender (VM). Needs in this folder: AuthKey_*.p8 and token.txt (the Mac's device token).
set -e
cd "$(dirname "$0")"
TEAM_ID=65Q59PGHMZ
KEY_ID=L72JVD5GGR
KEY_FILE=AuthKey_$KEY_ID.p8
TOPIC=com.guru.wakeprobe
HOST=api.sandbox.push.apple.com   # development-signed app; api.push.apple.com for production
TOKEN=${TOKEN:-$(tr -d '[:space:]' < token.txt)}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ES256 JWT, cached 30 min (Apple rejects tokens older than 1h and throttles minting more than once per 20 min).
if [ -z "$(find .jwt -mmin -30 2>/dev/null)" ]; then
  H=$(printf '{"alg":"ES256","kid":"%s"}' "$KEY_ID" | b64url)
  C=$(printf '{"iss":"%s","iat":%s}' "$TEAM_ID" "$(date +%s)" | b64url)
  # openssl signs as DER; JWT wants raw r||s (32+32 bytes)
  S=$(printf '%s.%s' "$H" "$C" | openssl dgst -sha256 -sign "$KEY_FILE" | python3 -c '
import sys
d = sys.stdin.buffer.read()
i = 2 if d[1] < 0x80 else 3
out = b""
for _ in range(2):
    n = d[i + 1]
    out += d[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
    i += 2 + n
sys.stdout.buffer.write(out)' | b64url)
  echo "$H.$C.$S" > .jwt
fi
JWT=$(cat .jwt)

NOW=$(date +%s)
EXP=$((NOW + 3600))

if [ "$1" = "alert" ]; then
  TYPE=alert; PRIO=10
  BODY=$(printf '{"aps":{"alert":{"title":"probe","body":"wake test"},"mutable-content":1},"sentAt":%s}' "$NOW")
else
  TYPE=background; PRIO=5
  BODY=$(printf '{"aps":{"content-available":1},"sentAt":%s}' "$NOW")
fi

echo "SENT $NOW $1" >> send-log.txt

CODE=$(curl -s -o resp.txt -w "%{http_code}" --http2 \
  -H "authorization: bearer $JWT" \
  -H "apns-topic: $TOPIC" \
  -H "apns-push-type: $TYPE" \
  -H "apns-priority: $PRIO" \
  -H "apns-expiration: $EXP" \
  -d "$BODY" \
  "https://$HOST/3/device/$TOKEN")
echo "$CODE"
[ "$CODE" = 200 ] || cat resp.txt   # 200 = APNs accepted it, nothing more
