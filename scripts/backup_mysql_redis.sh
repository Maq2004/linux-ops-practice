#!/usr/bin/env bash
# 备份 MySQL 与 Redis，并按天数清理旧备份。
# MySQL 凭据放在 ~/.my.cnf（chmod 600）；Redis 如启用密码，使用 REDISCLI_AUTH。
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/ops}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
STAMP="$(date +%F_%H%M%S)"
MYSQL_CNF="${MYSQL_CNF:-$HOME/.my.cnf}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || { printf 'RETENTION_DAYS must be a non-negative integer\n' >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
umask 077

if command -v mysqldump >/dev/null 2>&1 && [[ -f "$MYSQL_CNF" ]]; then
  out="$BACKUP_DIR/mysql_${STAMP}.sql.gz"
  mysqldump --defaults-extra-file="$MYSQL_CNF" \
    --single-transaction --quick --routines --triggers --events \
    --no-tablespaces --all-databases | gzip > "$out"
  gzip -t "$out"
  printf '[OK] mysql -> %s\n' "$out"
else
  printf '[SKIP] mysqldump or %s not found\n' "$MYSQL_CNF" >&2
fi

if command -v redis-cli >/dev/null 2>&1; then
  out="$BACKUP_DIR/redis_${STAMP}.rdb"
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --rdb "$out"
  printf '[OK] redis -> %s\n' "$out"
else
  printf '[SKIP] redis-cli not found\n' >&2
fi

find "$BACKUP_DIR" -type f \
  \( -name 'mysql_*.sql.gz' -o -name 'redis_*.rdb' \) \
  -mtime +"$RETENTION_DAYS" -print -delete
