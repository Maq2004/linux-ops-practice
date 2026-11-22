#!/usr/bin/env bash
# 清理轮转日志；默认只打印，不删除。
# 用法：DRY_RUN=0 ./log_clean.sh /var/log 14
set -euo pipefail

LOG_DIR="${1:-/var/log}"
DAYS="${2:-14}"
DRY_RUN="${DRY_RUN:-1}"

[[ -d "$LOG_DIR" ]] || { printf 'not a directory: %s\n' "$LOG_DIR" >&2; exit 1; }
[[ "$DAYS" =~ ^[0-9]+$ ]] || { printf 'DAYS must be a non-negative integer\n' >&2; exit 1; }

case "$DRY_RUN" in
  0|1) ;;
  *) printf 'DRY_RUN must be 0 or 1\n' >&2; exit 1 ;;
esac

printf 'scan=%s days=%s dry_run=%s\n' "$LOG_DIR" "$DAYS" "$DRY_RUN"

find "$LOG_DIR" -type f \
  \( -name '*.log.[0-9]*' -o -name '*.gz' -o -name '*.old' \) \
  -mtime +"$DAYS" -print0 |
while IFS= read -r -d '' file; do
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$file"
  else
    rm -f -- "$file"
    printf '[deleted] %s\n' "$file"
  fi
done
