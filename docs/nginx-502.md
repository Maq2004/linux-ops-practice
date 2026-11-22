# Nginx 502 排障：从 502 到 upstream 端口

> 本文是个人实验环境的脱敏记录；`<SERVER_IP>` 为占位符，不包含真实公网地址。

## 拓扑

```text
Browser
  │  http://<SERVER_IP>:81
  ▼
Nginx :81
  │  proxy_pass http://127.0.0.1:3001
  ▼
Uptime Kuma :3001
```

Nginx 只监听演示端口 81，Kuma 只监听 `127.0.0.1:3001`，不直接把 3001 暴露到公网。

## 复现 502

先确认 Nginx 正常，再停掉后端：

```bash
curl -I http://127.0.0.1:81
# HTTP/1.1 200 OK / 302 Found

docker stop uptime-kuma

curl -I http://127.0.0.1:81
# HTTP/1.1 502 Bad Gateway
```

查看 Nginx 错误日志：

```bash
sudo tail -n 50 /var/log/nginx/uptime-kuma.error.log
```

典型行：

```text
connect() failed (111: Connection refused) while connecting to upstream
```

`111` 是 `ECONNREFUSED`：Nginx 能连到 127.0.0.1，但 3001 没有进程监听，或者后端容器没起来。

## 三层定位

按“Nginx → 本机端口 → 后端进程”顺序收敛：

```bash
# 1. Nginx 自身
sudo systemctl status nginx
sudo nginx -t

# 2. 本机端口
sudo ss -lntp | grep -E ':(81|3001)\b'

# 3. 直接访问后端
curl -v http://127.0.0.1:3001/

# 4. 容器状态与日志
docker ps -a
docker logs --tail 100 uptime-kuma
```

判断：

- 81 没监听：Nginx 没启动/配置没加载/端口冲突。
- 81 监听但 3001 没监听：Kuma 容器没起来。
- 3001 监听但 `curl` 失败：Kuma 进程内部报错，看容器日志。
- 两者都正常但公网 502：检查安全组、云防火墙、主机 iptables 和 Nginx 的 upstream 地址。

## 修复

```bash
docker start uptime-kuma
curl -I http://127.0.0.1:3001/
sudo nginx -t
sudo systemctl reload nginx
curl -I http://127.0.0.1:81
```

`reload` 是平滑重载，不会断开已有连接；改配置后先用 `nginx -t`，不要直接 restart。

## 302 不是错误

Uptime Kuma 根路径会跳转到 `/dashboard`：

```text
HTTP/1.1 302 Found
Location: /dashboard
```

这是应用自己的重定向，不是 Nginx 报错。跟随重定向：

```bash
curl -IL http://127.0.0.1:81
# 最终 HTTP/1.1 200 OK
```

## HTTPS：实验环境自签

生产环境应使用 Let's Encrypt/ACME 或云证书；本仓库只记录实验环境的自签证书，不伪造真域名证书。

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/demo.key \
  -out /etc/nginx/ssl/demo.crt \
  -subj "/CN=demo.test" \
  -addext "subjectAltName=DNS:demo.test,IP:<SERVER_IP>"
```

Nginx 增加 443 server，并把 80 的测试域名跳转到 HTTPS：

```nginx
server {
    listen 443 ssl;
    server_name demo.test;

    ssl_certificate     /etc/nginx/ssl/demo.crt;
    ssl_certificate_key /etc/nginx/ssl/demo.key;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host $host;
    }
}

server {
    listen 80;
    server_name demo.test;
    return 301 https://$host$request_uri;
}
```

本机验证（不依赖 DNS）：

```bash
curl --resolve demo.test:443:127.0.0.1 -k https://demo.test/
openssl s_client -connect 127.0.0.1:443 -servername demo.test </dev/null 2>/dev/null | openssl x509 -noout -dates
```

## 五层收敛

公网访问失败时，不要只盯 Nginx，按下面顺序逐层排除：

| 层 | 典型现象 | 检查 |
|---|---|---|
| 云安全组/云防火墙 | 超时、连接被拒绝 | 入方向是否放行 TCP 81 |
| 主机 iptables/firewalld | 本机通、外部不通 | `iptables -S`、`firewall-cmd --list-all` |
| Nginx | 502/404/301 | `nginx -t`、error.log、`ss -lntp` |
| upstream | 502/connection refused | `curl -v 127.0.0.1:3001`、容器日志 |
| 应用/数据 | 500、超时 | 应用日志、数据库连接、磁盘/inode |

## 错误码速查

| 现象 | 更可能的原因 |
|---|---|
| `Connection refused` / 502 | 后端没监听、端口写错、容器没起来 |
| `404` | location/root/alias 路径不匹配 |
| `301/302` | 应用重定向或 Nginx 跳转，不一定是错误 |
| 超时 | 安全组、iptables、上游阻塞、`proxy_read_timeout` 太短 |
| `502` 但本机 3001 正常 | Nginx upstream 地址、容器网络、代理协议不匹配 |
