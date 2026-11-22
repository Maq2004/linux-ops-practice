#!/bin/bash
# MysqlRedisBackup.sh
# 用途：备份 MySQL 库（mysqldump 逻辑备份）与 Redis 数据目录（AOF + RDB 物理备份），
#      压缩归档、按天保留、失败即非零退出。
#
# 用法：
#   export REDISCLI_AUTH='<redis-password>'
#   sudo -E bash scripts/MysqlRedisBackup.sh
#
# 依赖：mysqldump / gzip / zcat / redis-cli / tar / find
# MySQL 凭据：默认 /home/opsM/.my.cnf（权限 600），通过 --defaults-extra-file 传入
# Redis 凭据：从环境变量 REDISCLI_AUTH 读取，不写在脚本和命令行里
#
# 定时（root）：
#   0 3 * * * /home/opsM/script/MysqlRedisBackup.sh >> /home/opsM/script/backup.cron.log 2>&1
#
# 恢复演练（备份 ≠ 可恢复）：
#   MySQL：先导到替身库再比对，禁止直接灌回生产。
#   Redis：解包到临时目录 → 临时容器挂载 /data → 端口错开 → 验证
#          DB loaded from append only file + DBSIZE 与备份时刻一致。
#
# 退出码：0=全部成功；1=mysqldump/打包失败；2=MySQL 产物校验失败或 BGSAVE 30s 未完成；
#         3=Redis 持久化状态异常；4=Redis 打包失败；5=Redis 包无法解开。

set -uo pipefail

: "${REDISCLI_AUTH:?请先 export REDISCLI_AUTH='<redis-password>'}"
export REDISCLI_AUTH

TIME=$(date +%F_%H%M)

MYSQL_CNF="${MYSQL_CNF:-/home/opsM/.my.cnf}"
MYSQL_DB="${MYSQL_DB:-lab}"
MYSQL_BACKUP_DIR="${MYSQL_BACKUP_DIR:-/home/opsM/mysqlBackup}"
REDIS_BACKUP_DIR="${REDIS_BACKUP_DIR:-/home/opsM/redisBackup}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/data/redis/data}"
RETENTION_DAYS="${RETENTION_DAYS:-6}" # -mtime +6，约保留 7 天

mkdir -p "$MYSQL_BACKUP_DIR" "$REDIS_BACKUP_DIR"

mysqldump --defaults-extra-file="$MYSQL_CNF" --databases "$MYSQL_DB" |
	gzip > "$MYSQL_BACKUP_DIR/mysql-${TIME}.sql.gz" || {
	echo "[ERROR] mysqldump backup error" >&2
	exit 1
}

zcat "$MYSQL_BACKUP_DIR/mysql-${TIME}.sql.gz" | tail -n 1 | grep -q "Dump completed on" || {
	echo "[ERROR] mysqldump file check error" >&2
	rm -f "$MYSQL_BACKUP_DIR/mysql-${TIME}.sql.gz"
	exit 2
}

redis-cli --no-auth-warning BGSAVE

v=""
for _ in {1..30}; do
	v=$(redis-cli --no-auth-warning INFO persistence | grep -E 'rdb_bgsave_in_progress' | awk -F ':' '{print $2+0}')
	[ "${v:-}" = "0" ] && break
	sleep 1
done

[ "${v:-}" = "0" ] || {
	echo "[ERROR] redis bgsave is not ready at 30 sec" >&2
	exit 2
}

STATUS_lastRdb_lastAof=$(redis-cli --no-auth-warning INFO persistence |
	grep -E 'rdb_last_bgsave_status|aof_last_write_status' |
	awk -F ':' 'BEGIN{n=0} $2 ~/ok/ {n++} END{print n}')
STATUS_lastRdb_lastAof="${STATUS_lastRdb_lastAof:-0}"

if [ "$STATUS_lastRdb_lastAof" -ne 2 ]; then
	echo "[ERROR] redis status error" >&2
	exit 3
fi

tar -czf "$REDIS_BACKUP_DIR/redis-${TIME}.tar.gz" -C "$REDIS_DATA_DIR" . || {
	# tar 备份即使失败了也会留下 tar 包，失败了要删除以免误导
	echo "[ERROR] redis backup error" >&2
	rm -f "$REDIS_BACKUP_DIR/redis-${TIME}.tar.gz"
	exit 4
}

# 备份好后再查一遍，确认能解包
tar -tzf "$REDIS_BACKUP_DIR/redis-${TIME}.tar.gz" >/dev/null 2>&1 || {
	echo "[ERROR] redis backup couldn't unzip" >&2
	rm -f "$REDIS_BACKUP_DIR/redis-${TIME}.tar.gz"
	exit 5
}

find "$MYSQL_BACKUP_DIR" -maxdepth 1 -type f -name "mysql-*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
find "$REDIS_BACKUP_DIR" -maxdepth 1 -type f -name "redis-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete
