# Nginx 502 排障：从 502 到 upstream 端口

> 本文是个人实验环境的脱敏记录；`<SERVER_IP>` 为占位符，不包含真实公网地址。

## 拓扑

```text
Browser
  │  https://<SERVER_IP>
  ▼
Nginx :443 SSL
  │  proxy_pass http://127.0.0.1:3001
  ▼
Uptime Kuma :3001
```

Nginx 只监听 443 SSL，Kuma 只监听 `127.0.0.1:3001`，不直接把 3001 暴露到公网。

## 复现 502

先确认 Nginx 正常，再停掉后端：

```bash
curl -k -I https://127.0.0.1/
# HTTP/1.1 200 OK / 302 Found

docker stop uptime-kuma

curl -k -I https://127.0.0.1/
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
sudo ss -lntp | grep -E ':(443|3001)\b'

# 3. 直接访问后端
curl -v http://127.0.0.1:3001/

# 4. 容器状态与日志
docker ps -a
docker logs --tail 100 uptime-kuma
```

判断：

- 443 没监听：Nginx 没启动/配置没加载/端口冲突。
- 443 监听但 3001 没监听：Kuma 容器没起来。
- 3001 监听但 `curl` 失败：Kuma 进程内部报错，看容器日志。
- 两者都正常但公网 502：检查安全组、云防火墙、主机 iptables 和 Nginx 的 upstream 地址。

## 修复

```bash
docker start uptime-kuma
curl -I http://127.0.0.1:3001/
sudo nginx -t
sudo systemctl reload nginx
curl -k -I https://127.0.0.1/
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
curl -k -IL https://127.0.0.1/
# 最终 HTTP/1.1 200 OK
```

## 页面一直转圈：curl 200，但浏览器用不了

`curl -I` 返回 200，只能说明 HTTP 响应头正常；如果页面依赖 WebSocket，缺少升级头时浏览器会一直转圈，DevTools 的 Network → WS 里看不到 `101 Switching Protocols`。

Uptime Kuma 的页面依赖 WebSocket。反代 `location /` 至少要补齐：

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host $host;
proxy_read_timeout 3600s;
```

改完先 `nginx -t`，再 `systemctl reload nginx`。验证时不要只看 curl，打开浏览器 DevTools，确认 WS 连接为 `101`，页面能正常加载。

> 面试里这是个好话题：`curl` 通 ≠ 浏览器可用；HTTP 200 只覆盖了普通请求，WebSocket 还需要协议升级。

## systemd 托管后端与自动拉起

`deploy/ops-demo.service` 是一个最小示例，托管 Python `http.server` 后端：

```bash
sudo cp deploy/ops-demo.service /etc/systemd/system/ops-demo.service
# 编辑 User=<user> 和 WorkingDirectory
sudo systemctl daemon-reload
sudo systemctl enable --now ops-demo
systemctl status ops-demo
journalctl -u ops-demo -n 30

# 验证 on-failure：kill 后 MainPID 变化
sudo systemctl kill -s KILL ops-demo
sleep 2
systemctl status ops-demo
systemctl show -p MainPID --value ops-demo
```

`Restart=on-failure` 不会在 `systemctl stop` 后拉起；被信号杀死或非 0 退出才会。生产环境用专用低权限用户，不要用 root。

## 证书准备（实验环境自签）

生产环境应使用 Let's Encrypt/ACME 或云证书；本仓库只记录实验环境的自签证书，不伪造真域名证书。

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/demo.key \
  -out /etc/nginx/ssl/demo.crt \
  -subj "/CN=demo.test" \
  -addext "subjectAltName=DNS:demo.test,IP:<SERVER_IP>"
```

Nginx 使用 443 SSL server；本环境 80 被 Apache 占用，不做 80→443 跳转，证书路径按实际替换：

```nginx
server {
    listen 443 ssl;
    server_name demo.test;

    ssl_certificate     /etc/nginx/ssl/demo.crt;
    ssl_certificate_key /etc/nginx/ssl/demo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
    }
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
| 云安全组/云防火墙 | 超时、连接被拒绝 | 入方向是否放行 TCP 443 |
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
