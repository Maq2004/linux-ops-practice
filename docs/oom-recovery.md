# OOM 故障复盘：1.6 GiB ECS 上的容器重启风暴

> 本文是个人实验环境的脱敏复盘，不包含真实 IP、域名、密码或客户信息。

## 环境

| 项 | 值 |
|---|---|
| 云主机 | 阿里云 ECS，1.6 GiB 内存 |
| 系统 | Ubuntu 22.04 |
| 容器 | MySQL 8.4、Redis 7.2、Uptime Kuma |
| 编排 | Docker Compose |
| 现象 | SSH 无法 fork、负载升高、`docker ps` 卡住 |

## 现象

- SSH 登录后执行命令报 `fork failed: Cannot allocate memory`。
- `uptime` / `top` 的 load 很高，`wa`（I/O wait）明显升高。
- `docker ps -a` 长时间无响应；`docker compose` 进程处于 `D` 状态。
- 业务容器反复重启，刚起来又被杀掉。

## 先收集证据，不要急着重启

```bash
free -h
df -h
df -i
uptime
ps -eo pid,stat,pcpu,pmem,comm --sort=-pmem | head -20
dmesg -T | grep -i -E 'oom|killed process|out of memory'
journalctl -k --since "2 hours ago" | tail -100
docker ps -a
docker stats --no-stream
```

关键判断：

- `free -h` 的 `available` 很低，swap 可能还没被使用。
- `df -h` / `df -i` 排除磁盘满和 inode 满。
- `dmesg` 出现 `Out of memory: Killed process ...`，说明不是普通的应用报错，而是内核 OOM killer 介入。
- `docker ps` 卡住、容器进程处于 `D` 状态，说明 OOM 之后 Docker/overlay 清理也被拖住了。

## 根因链

1. 1.6 GiB 内存同时跑 MySQL、Redis、Uptime Kuma，内存余量太小。
2. MySQL 的 `innodb_buffer_pool_size` 偏大，mysqld 常驻内存接近 900 MiB。
3. 三个容器都设置了 `restart: always`：OOM 杀掉一个容器后，Docker 立刻拉起，形成“杀掉-重启-再杀”的风暴。
4. 重启风暴期间 SSH 无法 fork，Docker 的 overlay/网络清理也被拖住，`docker ps` 卡死。
5. `systemd-journald` 也被 OOM 影响，日志出现损坏/重启；备份脚本缺少执行位，cron 静默失败 5 天，直到排查时才被发现。

> 结论：Java/MySQL 等进程本身不一定有代码 bug；在内存不足时，它们只是 OOM 的受害者。真正要改的是资源预算、重启策略和监控。

## 恢复步骤

### 1. 先阻断重启风暴

```bash
sudo systemctl stop docker.socket
# 如 docker 服务本身还能响应，再停 docker；不要反复 restart
sudo systemctl stop docker
```

先让容器停止自动拉起，避免一边恢复一边继续 OOM。共享主机或公司测试机，重启/停机前必须先和负责人确认。

### 2. 增加 swap（缓冲，不是根治）

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### 3. 收紧 MySQL 内存

```ini
# /etc/mysql/mysql.conf.d/mysqld.cnf
[mysqld]
innodb_buffer_pool_size = 96M
performance_schema = OFF
```

修改后重启 MySQL。`performance_schema` 关闭会损失部分性能诊断能力，这是 1.6 GiB 实验机上的取舍，生产环境要单独评估。

### 4. 逐容器启动并复测

```bash
docker compose up -d mysql
docker stats --no-stream
docker compose up -d redis
docker compose up -d uptime-kuma
free -h
docker ps
```

验收目标：

- `available` 回到几百 MiB；
- swap 使用量为 0 或很低；
- 容器不再反复重启；
- `docker ps` 能正常返回。

本次恢复后：可用内存约 **856 MiB**，swap 使用 **0**。

### 5. 补日志与 cron 的坑

```bash
sudo systemctl status systemd-journald
sudo journalctl --verify
crontab -l
ls -l /path/to/backup.sh
chmod +x /path/to/backup.sh
```

备份脚本没有执行位时，cron 会“看起来执行了”，但实际没有产出；要用日志和备份文件时间双重验证。

## 如果重来一次

- 1.6 GiB 机器不要同时跑 MySQL + Redis + Kuma；至少 2 GiB 起步，或把数据库拆走。
- 给每个容器设置 `mem_limit`，给 MySQL 单独设 buffer pool，不要依赖默认值。
- `restart: always` 要配资源限制和监控；否则 OOM 会变成重启风暴。
- 监控 `available`、swap、容器重启次数，而不是只看 CPU。
- cron 任务要有“最后成功时间”与失败告警，不能只看进程退出码。

## 验证清单

- [ ] `free -h` 的 available 足够，swap 不持续增长
- [ ] `docker ps` 正常，容器重启次数不再增加
- [ ] `dmesg -T | grep -i oom` 没有新的 OOM
- [ ] journald 正常，`journalctl --verify` 通过
- [ ] 备份文件存在且 `gzip -t` 通过
- [ ] cron 日志能看到成功记录
