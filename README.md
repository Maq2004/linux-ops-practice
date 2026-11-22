# linux-ops-practice

个人 Linux / 云服务器运维练习仓库：一次真实的 OOM 故障、Nginx 反向代理与 502 排障、Docker Compose + Uptime Kuma 部署整理成可复现的记录。

Uptime Kuma 使用内置 **SQLite**（容器内 `/app/data/kuma.db`）保存监控配置与心跳历史；MySQL / Redis 是同一 Docker 自定义网络中的独立练习服务，Kuma 仅通过 **TCP Port** 监控其端口可用性，不把它们作为存储后端。

> 仓库内所有公网 IP、域名、密码、私钥均已替换为占位符，不含真实生产凭证。

## 背景

- 1.6 GiB 内存的阿里云 ECS，运行 MySQL 8.0、Redis 7.2、Uptime Kuma 三个容器。
- 一次内存耗尽导致 SSH 无法 fork、Docker 清理卡住；恢复后补上 Nginx 反向代理与可用性监控。
- 目标不是把服务跑起来，是能说明：怎么发现、怎么定位、怎么验证、怎么避免再次发生。

## 架构

```text
Browser
  │  HTTPS :443
  ▼
Nginx :443 SSL（宿主机）
  │  proxy_pass 127.0.0.1:3001
  ▼
Uptime Kuma :3001 ── 内置 SQLite（/app/data/kuma.db）

Docker 自定义网络 <network-name>
  ├─ uptime-kuma :3001
  ├─ mysql-lab :3306   ← TCP Port 监控，不是 Kuma 的存储后端
  └─ redis-lab :6379   ← TCP Port 监控，不是 Kuma 的存储后端
```

> Kuma 的存储是容器内的 SQLite 文件，不是 MySQL / Redis；TCP Port 监控只能证明端口能连上，不代表数据库查询或认证正常。数据库 compose 见 `compose/mysql-redis.yaml`，与 OOM 复盘中的 96M buffer pool、内存限额对应。

> 实际部署可把三个容器加入同一个自定义网络，3306 / 6379 不需要发布到宿主机或公网；仓库里的 compose 为便于本机复现，默认保留 `127.0.0.1:3306/6379` 映射，实际服务器可去掉这些 host 端口，改为共享 Docker 网络，Kuma 用容器名访问。

## 目录

```text
.
├── README.md
├── .env.example
├── .gitattributes
├── .gitignore
├── compose/
│   ├── mysql-redis.yaml
│   └── uptime-kuma.yaml
├── deploy/
│   ├── nginx-uptime-kuma.conf
│   └── ops-demo.service
├── scripts/
│   ├── service-check.sh
│   ├── logclean.sh
│   └── MysqlRedisBackup.sh
└── docs/
    └── incidents/
        ├── oom-recovery.md
        └── nginx-502.md
```

## 快速开始

### 1. 启动 MySQL / Redis（独立练习服务）

```bash
cp .env.example .env
docker compose --env-file .env -f compose/mysql-redis.yaml up -d
docker compose --env-file .env -f compose/mysql-redis.yaml ps
```

MySQL 8.0 + Redis 7.2，均只绑定 `127.0.0.1`；MySQL 使用 96M buffer pool 且关闭 `performance_schema`，与 OOM 复盘中的修复一致。1.6 GiB 实验机的内存预算见 `mem_limit`，重启策略用 `on-failure:3` 避免 OOM 后反复拉起；这些值不要直接照搬到生产。

### 2. 启动 Uptime Kuma

```bash
docker compose -f compose/uptime-kuma.yaml up -d
docker compose -f compose/uptime-kuma.yaml ps
```

Kuma 只绑定 `127.0.0.1:3001`，不直接暴露到公网。数据保存在 `compose/data/`。

### 3. 配置 Nginx 反向代理

```bash
sudo cp deploy/nginx-uptime-kuma.conf /etc/nginx/sites-available/uptime-kuma
sudo ln -sf /etc/nginx/sites-available/uptime-kuma /etc/nginx/sites-enabled/uptime-kuma
sudo nginx -t
sudo systemctl reload nginx
```

配置默认监听 `443 ssl`，证书路径是 `/etc/nginx/ssl/kuma.crt` 和 `/etc/nginx/ssl/kuma.key`；实验环境自签证书的生成命令见 `docs/incidents/nginx-502.md` 的“证书准备”，真实证书替换路径即可。

如果 443 已被占用，改 `deploy/nginx-uptime-kuma.conf` 里的 `listen`，并同步修改安全组；

### 4. systemd 托管后端（可选）

示例 unit 在 `deploy/ops-demo.service`，演示 systemd 托管一个 Python `http.server` 后端：

```bash
sudo cp deploy/ops-demo.service /etc/systemd/system/ops-demo.service
# 编辑 User=<user> 和 WorkingDirectory
sudo systemctl daemon-reload
sudo systemctl enable --now ops-demo
systemctl status ops-demo
journalctl -u ops-demo -n 30

# 验证 on-failure 自动拉起：MainPID 会变化
sudo systemctl kill -s KILL ops-demo
sleep 2
systemctl status ops-demo
systemctl show -p MainPID --value ops-demo
```

`Restart=on-failure` 只在非 0 退出或被信号杀死时拉起；`systemctl stop` 不会拉起。生产环境把 `User` 改为专用低权限用户，不要用 root。

### 5. 本机验证

```bash
curl -k -I https://127.0.0.1/
# HTTP/1.1 302 Found，Location: /dashboard 是正常跳转，不是错误

curl -k -IL https://127.0.0.1/
# 最终 HTTP/1.1 200 OK

ss -lntp | grep ':443'
```

> 自签证书需要 `-k` 跳过证书校验；换成受信任证书后可去掉 `-k`。

### 6. 公网访问

- 云安全组只放行 TCP `443` 给演示来源。
- 浏览器打开 `https://<SERVER_IP>`；自签证书会提示“不安全”，实验环境继续访问即可。
- 若公网仍不通，依次查：安全组 → 云防火墙 → 主机 iptables → Nginx 监听 → 后端端口。

## 脚本

### 1. 服务巡检 `scripts/service-check.sh`

检查 Nginx、Redis 6379 端口、根分区使用率、内存占用和容器状态。默认阈值：磁盘 80%、内存 1500 MB；容器默认 `redis-lab mysql-lab uptime-kuma`。

```bash
bash scripts/service-check.sh
CONTAINERS="mysql-lab uptime-kuma" bash scripts/service-check.sh 85 1200
```

有异常时打印 `warning:N` 并退出 1，适合挂 cron 做“有没有问题”的第一层巡检。

### 2. 日志清理 `scripts/logclean.sh`

把 N 天前的 `*.log` 打包到归档目录，校验 tar 包后删除源日志，并只保留最近 K 份归档。

```bash
# 先改路径再执行；会删除源日志
SRC=/path/applog DEST=/path/backup/logs DAYS=2 KEEP=7 bash scripts/logclean.sh
```

默认路径是 `$HOME/applog`、`$HOME/backup/logs`；`LOG` 可指定日志文件。cron 里请写实际用户路径，例如 `/home/<user>/applog`。

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
