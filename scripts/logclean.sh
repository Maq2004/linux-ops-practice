#!/bin/bash
# 日志清理：找 N 天前的 *.log → 打包 → 校验 → 删除源文件 → 只保留 K 份归档
# 用法：SRC=/path/applog DEST=/path/backup/logs DAYS=2 KEEP=7 ./logclean.sh
# 默认值按练习机路径设置，可按环境覆盖

set -u

LOG="${LOG:-$HOME/script/logclean.log}"
SRC="${SRC:-$HOME/applog}"          # 日志存在的路径
DAYS="${DAYS:-2}"                  # 一次性压缩几天的
DEST="${DEST:-$HOME/backup/logs}"  # 压缩日志存到哪里
KEEP="${KEEP:-7}"                  # 归档保留几份

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$DEST" "$(dirname "$LOG")"
echo "开始时间:$(date '+%F %T')" >> "$LOG"

cd "$SRC" || {
	echo "cd 目录错误 $SRC" >&2
	exit 1
}

find . -type f -name '*.log' -mtime +"$DAYS" > "$TMP_DIR/list.txt"

if [ ! -s "$TMP_DIR/list.txt" ]; then
	echo "没有需要清理的日志，都是 $DAYS 天以内的"
	exit 0
fi

get_number=$(wc -l < "$TMP_DIR/list.txt")
echo "找到了:${get_number}个文件,$(date '+%F %T')" >> "$LOG"

ARCHIVE="$DEST/logs_$(date +%F).tar.gz"

tar -czf "$ARCHIVE" -C "$SRC" -T "$TMP_DIR/list.txt" || {
	echo "[ERROR] 打包错误，删除半成品包" >&2
	rm -f "$ARCHIVE"
	exit 2
}

xargs rm -f < "$TMP_DIR/list.txt"

# shellcheck disable=SC2012  # 包名由本脚本生成(logs_YYYY-MM-DD.tar.gz)，字符集可控
ls -t "$DEST"/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "结束时间:$(date '+%F %T')" >> "$LOG"
echo "====================================================" >> "$LOG"
