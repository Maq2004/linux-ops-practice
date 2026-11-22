#!/usr/bin/env bash
# 用法：./check_nginx.sh [端口，默认 81]
set -euo pipefail

PORT="${1:-81}"
URL="http://127.0.0.1:${PORT}/"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

command -v nginx >/dev/null 2>&1 || fail "nginx not found"
command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v ss >/dev/null 2>&1 || fail "ss not found"

systemctl is-active --quiet nginx || fail "nginx is not active"
nginx -t >/dev/null 2>&1 || fail "nginx -t failed"
ss -lntp 2>/dev/null | grep -Eq "[:.]${PORT}[[:space:]]" || fail "port ${PORT} is not listening"

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$URL" || true)"
case "$code" in
  200|301|302|401|403)
    printf '[OK] nginx active; %s -> HTTP %s\n' "$URL" "$code"
    ;;
  *)
    fail "unexpected HTTP code from ${URL}: ${code:-none}"
    ;;
esac
