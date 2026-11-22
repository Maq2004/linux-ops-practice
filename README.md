# linux-ops-practice

个人 Linux / 云服务器运维练习仓库：把一次真实的 OOM 故障、Nginx 反向代理与 502 排障、Docker Compose + Uptime Kuma 部署整理成可复现的记录。

> 仓库内所有公网 IP、域名、密码、私钥均已替换为占位符，不含真实生产凭证。

## 背景

- 1.6 GiB 内存的阿里云 ECS，运行 MySQL 8.4、Redis 7.2、Uptime Kuma 三个容器。
- 一次内存耗尽导致 SSH 无法 fork、Docker 清理卡住；恢复后补上 Nginx 反向代理与可用性监控。
- 目标不是“把服务跑起来”，而是能说明：怎么发现、怎么定位、怎么验证、怎么避免再次发生。

## 架构

```text
Browser
  │  HTTP :81
  ▼
Nginx :81  ──proxy_pass──▶  Uptime Kuma 127.0.0.1:3001
                                  │
                                  ├─ MySQL 8.4 (Docker)
                                  └─ Redis 7.2 (Docker)
```

> MySQL / Redis 是同一台 ECS 上的练习服务；Uptime Kuma 只负责站点可用性监控，不直接监控数据库指标。数据库的 compose 未放进仓库（避免环境差异和凭据泄露），OOM 复盘里保留了关键参数，可按需自行复现。

## 目录

```text
.
├── README.md
├── .gitignore
├── compose/
│   └── uptime-kuma.yaml
├── deploy/
│   └── nginx-uptime-kuma.conf
├── scripts/
│   ├── script.2026-10-29.sh
│   ├── logclean.sh
│   └── MysqlRedisBackup.sh
└── docs/
    └── incidents/
        ├── oom-recovery.md
        └── nginx-502.md
```

## 快速开始

### 1. 启动 Uptime Kuma

```bash
docker compose -f compose/uptime-kuma.yaml up -d
docker compose -f compose/uptime-kuma.yaml ps
```

Kuma 只绑定 `127.0.0.1:3001`，不直接暴露到公网。数据保存在 `compose/data/`。

### 2. 配置 Nginx 反向代理

```bash
sudo cp deploy/nginx-uptime-kuma.conf /etc/nginx/sites-available/uptime-kuma
sudo ln -sf /etc/nginx/sites-available/uptime-kuma /etc/nginx/sites-enabled/uptime-kuma
sudo nginx -t
sudo systemctl reload nginx
```

如果 81 端口已被占用，改 `deploy/nginx-uptime-kuma.conf` 里的 `listen`，并同步修改安全组。

### 3. 本机验证

```bash
curl -I http://127.0.0.1:81
# HTTP/1.1 302 Found，Location: /dashboard 是正常跳转，不是错误

curl -IL http://127.0.0.1:81
# 最终 HTTP/1.1 200 OK

ss -lntp | grep ':81'
```

### 4. 公网访问

- 云安全组只放行 TCP `81` 给演示来源，**不要放行 3001**。
- 浏览器打开 `http://<SERVER_IP>:81`。
- 若公网仍不通，依次查：安全组 → 云防火墙 → 主机 iptables → Nginx 监听 → 后端端口。

## 脚本

三个脚本来自 `Linux学习笔记/学习脚本` 里的实际练习，保留原来的检查项、退出码和保留策略，只做了脱敏与路径参数化；不是另写一套。

### 1. 服务巡检 `scripts/script.2026-10-29.sh`

检查 Nginx、Redis 6379 端口、根分区使用率、内存占用和容器状态。默认阈值：磁盘 80%、内存 1500 MB；容器默认 `redis-lab mysql-lab uptime-kuma`。

```bash
bash scripts/script.2026-10-29.sh
CONTAINERS="mysql-lab uptime-kuma" bash scripts/script.2026-10-29.sh 85 1200
```

有异常时打印 `warning:N` 并退出 1，适合挂 cron 做“有没有问题”的第一层巡检。

### 2. 日志清理 `scripts/logclean.sh`

把 N 天前的 `*.log` 打包到归档目录，校验 tar 包后删除源日志，并只保留最近 K 份归档。

```bash
# 先改路径再执行；会删除源日志
SRC=/path/applog DEST=/path/backup/logs DAYS=2 KEEP=7 bash scripts/logclean.sh
```

默认路径是 `/home/opsM/applog`、`/home/opsM/backup/logs`；`LOG` 可指定日志文件。

### 3. MySQL / Redis 备份 `scripts/MysqlRedisBackup.sh`

`mysqldump` 备份指定库，`zcat + grep "Dump completed on"` 校验；Redis 先 `BGSAVE`，检查 RDB/AOF 状态，再打包数据目录，最后做 `tar -tzf` 解包校验。

```bash
export REDISCLI_AUTH='<redis-password>'
sudo -E bash scripts/MysqlRedisBackup.sh
```

可用环境变量：`MYSQL_CNF`、`MYSQL_DB`、`MYSQL_BACKUP_DIR`、`REDIS_BACKUP_DIR`、`REDIS_DATA_DIR`、`RETENTION_DAYS`。退出码与恢复演练见脚本头部注释。

> 这三个脚本会改文件/删日志/覆盖备份，先在测试目录跑一遍；生产环境把密码放环境变量或密钥管理，不要写进脚本。

## 故障复盘

- [OOM：1.6 GiB ECS 上的容器重启风暴](docs/incidents/oom-recovery.md)
- [Nginx 502：从 502 到 upstream 端口](docs/incidents/nginx-502.md)
