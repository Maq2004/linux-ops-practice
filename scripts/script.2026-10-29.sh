#!/bin/bash
# 服务巡检：Nginx / Redis 端口 / 磁盘 / 内存 / 容器
# 用法：./script.2026-10-29.sh [磁盘阈值百分比] [内存阈值MB]
# 环境变量：CONTAINERS="redis-lab mysql-lab uptime-kuma"
# 退出码：0=全部正常，1=有告警，2=参数非法

set -u

echo "========================$(date)================================"
FAILED=0

check_nginx=$(systemctl is-active nginx)
if [ "$check_nginx" = "active" ]; then
	echo "nginx_running"
else
	echo "nginx_down"
	FAILED=$((FAILED + 1))
fi

if ss -lntu | grep -qE '[:.]6379[[:space:]]'; then
	echo "port_6379_listening"
else
	echo "port_6379_down"
	FAILED=$((FAILED + 1))
fi

check_disk=$(df -P / | awk 'NR==2{print $5}')
check_memory=$(free -m | awk 'NR==2{print $3}')
check_disk=${check_disk%\%}

default_disk=${1:-80}
default_memory=${2:-1500}

case "$default_memory" in
	'' | *[!0-9]*)
		echo "参数中携带非法符号" >&2
		exit 2
		;;
esac

case "$default_disk" in
	'' | *[!0-9]*)
		echo "参数中携带非法符号" >&2
		exit 2
		;;
esac

if [ "$check_disk" -gt "$default_disk" ]; then
	echo "disk_warning"
	FAILED=$((FAILED + 1))
else
	echo "disk_ok"
fi

# 数值比较用 -gt，避免字符串比较把 90 和 1500 比错
if [ "$check_memory" -gt "$default_memory" ]; then
	echo "memory_warning"
	FAILED=$((FAILED + 1))
else
	echo "memory_ok"
fi

# 默认只检查实际存在的三个容器；不要放不存在的容器，否则巡检永远告警
CONTAINERS="${CONTAINERS:-redis-lab mysql-lab uptime-kuma}"

for c in $CONTAINERS; do
	if docker ps --filter "name=^$c$" --format '{{.Names}}' | grep -q .; then
		echo "container_${c}_running"
	else
		echo "container_${c}_down"
		FAILED=$((FAILED + 1))
	fi
done

echo "==========summary============"

if [ "$FAILED" -eq 0 ]; then
	echo "everything_ok"
	echo "========================$(date)================================"
	exit 0
else
	echo "warning:$FAILED"
	echo "========================$(date)================================"
	exit 1
fi
