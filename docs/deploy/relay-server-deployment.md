# Session Sharing Relay — Server Deployment Record

实际部署一台公网中转 relay 的过程与最终配置。本文档用占位符替换了具体的公网 IP /
域名 / token，重新部署到新机器时把占位符替换掉即可。

| 占位符 | 含义 |
| --- | --- |
| `<RELAY_HOST>` | 公网入口 IP 或主机名（仅运维参考） |
| `<RELAY_DOMAIN>` | 已生效证书的域名，会被客户端用于 wss 连接 |
| `<RELAY_PORT>` | 对外暴露的 TLS 端口（本次部署用的是一个非 443 的高位端口） |
| `<USER_TOKEN>` | 相当于「客户端入场券」，由部署者生成的 32 字节随机十六进制串 |
| `<BASIC_USER>` / `<BASIC_PASSWORD>` | 静态站点门口的 HTTP Basic 凭证 |

## 1. 目标环境调研

| 项 | 实测值 |
| --- | --- |
| OS | CentOS 7（已 EOL），kernel 3.10 |
| 系统 Python | 3.6.8（不可用，relay 至少要 3.9+） |
| nginx | 1.20.1（已在用，挂在 master PID 1 下，**不**由 systemd 管理） |
| 已有 nginx 站点 | `/etc/nginx/conf.d/um-react.conf` 等，监听 20080/20443/24533/25005/25600 |
| firewalld | 未启用（依赖云厂商安全组） |
| SELinux | Disabled |
| 已有证书 | `/etc/letsencrypt/live/<RELAY_DOMAIN>/`（certbot 自动续期） |
| 在跑的其它服务 | nginx、frps（9010/9020）、zerotier、rpcbind |

## 2. 关键决策

1. **TLS 端口选 `<RELAY_PORT>`**。20443 等已有端口被现有站点占着，不动；选一个云
   安全组已经放开的高位端口，不要 443，避免抢标准端口。
2. **复用现有 Let's Encrypt 证书**，不另签。证书已绑 `<RELAY_DOMAIN>`，relay 不参
   与 certbot 续期流程。
3. **relay 监听 `127.0.0.1:18080` 不暴露公网**。所有外部流量必须经 nginx → 反代
   到 127.0.0.1:18080。admin（healthz / readyz / metrics）放在 18081，仅本机可见。
4. **Python 3.11 源码编译装到 `/opt/python-3.11/`**。CentOS 7 上：
   - EPEL 提供 `openssl11`（1.1.1k），先装它
   - 在 `/opt/openssl11-prefix/` 用 symlink 拼一个标准 prefix 布局给 Python 的
     `--with-openssl` 用
   - 不污染系统 Python 3.6
5. **跑一个新建系统用户 `ghostty-relay`**，无 shell、无 home、systemd 启停。
6. **新增 `/etc/nginx/conf.d/ghostty-relay.conf`**，绝不动现有任何 conf 文件。
7. 阿里云安全组开放 `<RELAY_PORT>/tcp` 入方向（控制台手动改，部署脚本无权限）。

## 3. 部署流程

### 3.1 编译依赖

```bash
yum install -y \
  gcc gcc-c++ make \
  openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel \
  ncurses-devel readline-devel sqlite-devel gdbm-devel libuuid-devel \
  wget tar
yum install -y openssl11-devel openssl11
```

### 3.2 拼 OpenSSL 1.1.1 prefix（让 Python configure 能找到）

```bash
mkdir -p /opt/openssl11-prefix/{include,lib,lib/pkgconfig}
ln -sfn /usr/include/openssl11/openssl /opt/openssl11-prefix/include/openssl
ln -sfn /usr/lib64/libssl.so.1.1   /opt/openssl11-prefix/lib/libssl.so
ln -sfn /usr/lib64/libssl.so.1.1   /opt/openssl11-prefix/lib/libssl.so.1.1
ln -sfn /usr/lib64/libcrypto.so.1.1 /opt/openssl11-prefix/lib/libcrypto.so
ln -sfn /usr/lib64/libcrypto.so.1.1 /opt/openssl11-prefix/lib/libcrypto.so.1.1
sed 's|/usr|/opt/openssl11-prefix|g; s|^Cflags:.*|Cflags: -I/opt/openssl11-prefix/include|; s|openssl11|openssl|g' \
  /usr/lib64/pkgconfig/openssl11.pc > /opt/openssl11-prefix/lib/pkgconfig/openssl.pc
```

### 3.3 编译安装 Python 3.11

```bash
cd /tmp
curl -fsSL --retry 3 -o Python-3.11.10.tgz \
  https://www.python.org/ftp/python/3.11.10/Python-3.11.10.tgz
tar -xzf Python-3.11.10.tgz
cd Python-3.11.10
./configure \
  --prefix=/opt/python-3.11 \
  --with-openssl=/opt/openssl11-prefix \
  --with-openssl-rpath=/usr/lib64 \
  --with-ensurepip=install \
  --enable-shared \
  LDFLAGS='-Wl,-rpath,/opt/python-3.11/lib'
make -j"$(nproc)"
make altinstall
/opt/python-3.11/bin/python3.11 -c 'import ssl; print(ssl.OPENSSL_VERSION)'
# 预期：OpenSSL 1.1.1k FIPS 25 Mar 2021
```

### 3.4 系统用户与目录

```bash
useradd --system --no-create-home --shell /sbin/nologin ghostty-relay
mkdir -p /opt/ghostty-session-sharing /var/lib/ghostty-relay
chown ghostty-relay:ghostty-relay /var/lib/ghostty-relay
chmod 700 /var/lib/ghostty-relay
```

### 3.5 推送代码

从开发机：

```bash
tar --exclude='__pycache__' --exclude='*.pyc' \
  -czf /tmp/relay.tar.gz -C contrib/session-sharing/relay .
scp /tmp/relay.tar.gz root@<RELAY_HOST>:/tmp/

# 同样方式推送 web 客户端 dist/
tar -czf /tmp/web-client.tar.gz \
  -C contrib/session-sharing/ghostty-web-client/dist .
scp /tmp/web-client.tar.gz root@<RELAY_HOST>:/tmp/
```

服务器侧：

```bash
mkdir -p /opt/ghostty-session-sharing/contrib/session-sharing/relay
tar -xzf /tmp/relay.tar.gz \
  -C /opt/ghostty-session-sharing/contrib/session-sharing/relay

mkdir -p /opt/ghostty-session-sharing/ghostty-web-client/dist
tar -xzf /tmp/web-client.tar.gz \
  -C /opt/ghostty-session-sharing/ghostty-web-client/dist

chown -R root:ghostty-relay /opt/ghostty-session-sharing/ghostty-web-client
find /opt/ghostty-session-sharing/ghostty-web-client -type f -exec chmod 0640 {} \;
find /opt/ghostty-session-sharing/ghostty-web-client -type d -exec chmod 0750 {} \;

/opt/python-3.11/bin/python3.11 -m py_compile \
  /opt/ghostty-session-sharing/contrib/session-sharing/relay/server.py
```

### 3.6 生成 user token

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
# 输出一条 64 位十六进制串作为 <USER_TOKEN>
```

### 3.7 写 `/etc/ghostty-relay.env`

```ini
GHOSTTY_RELAY_HOST=127.0.0.1
GHOSTTY_RELAY_PORT=18080
GHOSTTY_RELAY_OFFLINE_TTL=300
GHOSTTY_RELAY_TOKEN_TTL=300
GHOSTTY_RELAY_ALLOW_PUBLIC_BIND=0
GHOSTTY_RELAY_USER_TOKENS=<USER_TOKEN>
GHOSTTY_RELAY_ALLOW_USER_TOKEN_CLIENT_ACCESS=0
GHOSTTY_RELAY_STATIC_ROOT=/opt/ghostty-session-sharing/ghostty-web-client/dist
GHOSTTY_RELAY_MAX_BODY_BYTES=65536
GHOSTTY_RELAY_MAX_SESSIONS=4096
GHOSTTY_RELAY_MAX_CLIENTS_PER_SESSION=8
GHOSTTY_RELAY_MAX_FRAME_BYTES=262144
GHOSTTY_RELAY_RATE_LIMIT_REQUESTS=120
GHOSTTY_RELAY_RATE_LIMIT_WINDOW_SECONDS=60
GHOSTTY_RELAY_TRUSTED_PROXIES=127.0.0.1
GHOSTTY_RELAY_ADMIN_HOST=127.0.0.1
GHOSTTY_RELAY_ADMIN_PORT=18081
GHOSTTY_RELAY_TOKEN_EXPIRY_CHECK_SECONDS=30
GHOSTTY_RELAY_PING_INTERVAL_SECONDS=30
GHOSTTY_RELAY_PING_TIMEOUT_SECONDS=60
GHOSTTY_RELAY_CLIENT_SEND_BUFFER_BYTES=1048576
```

权限：

```bash
chown root:ghostty-relay /etc/ghostty-relay.env
chmod 640 /etc/ghostty-relay.env
```

### 3.8 systemd unit

`/etc/systemd/system/ghostty-relay.service`：

```ini
[Unit]
Description=Ghostty Session Sharing Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ghostty-relay
Group=ghostty-relay
WorkingDirectory=/opt/ghostty-session-sharing
EnvironmentFile=/etc/ghostty-relay.env
ExecStart=/opt/python-3.11/bin/python3.11 /opt/ghostty-session-sharing/contrib/session-sharing/relay/server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ghostty-relay

[Install]
WantedBy=multi-user.target
```

启用：

```bash
systemctl daemon-reload
systemctl enable --now ghostty-relay
systemctl status ghostty-relay --no-pager | head
journalctl -u ghostty-relay -n 20 --no-pager
```

### 3.9 nginx 反代

`/etc/nginx/conf.d/ghostty-relay.conf`：

```nginx
# Ghostty session sharing relay reverse proxy.

map $http_upgrade $ghostty_relay_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen <RELAY_PORT> ssl http2;
    listen [::]:<RELAY_PORT> ssl http2;
    server_name <RELAY_DOMAIN>;

    ssl_certificate     /etc/letsencrypt/live/<RELAY_DOMAIN>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/<RELAY_DOMAIN>/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:GhosttyRelaySSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    client_max_body_size 64k;

    proxy_read_timeout    1h;
    proxy_send_timeout    1h;
    proxy_connect_timeout 30s;

    # Proxy headers shared by every location below.
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $ghostty_relay_connection_upgrade;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # The agent and browser endpoints carry their own token-based auth, so they
    # MUST stay reachable without HTTP Basic. Anything else (the SPA shell,
    # /assets, etc.) sits behind a Basic gate so the page itself is private.
    location /api/ {
        proxy_pass http://127.0.0.1:18080;
    }
    location /ws/ {
        proxy_pass http://127.0.0.1:18080;
    }
    location / {
        auth_basic           "Ghostty Session Sharing";
        auth_basic_user_file /etc/nginx/ghostty-relay.htpasswd;
        proxy_pass http://127.0.0.1:18080;
    }
}
```

reload。本机 nginx **不在 systemd 控制下**，使用 `nginx -s reload`：

```bash
nginx -t
nginx -s reload
ss -tlnp | grep :<RELAY_PORT>
```

### 3.10 Web 端 HTTP Basic 鉴权

为了避免任何人能直接打开 SPA 页面查看 UI 文案，**静态站点放在 HTTP Basic 后面**。
`/api/` 和 `/ws/` 必须保持不带 Basic（agent / browser 客户端有自己的 token 鉴
权，加 Basic 会导致它们登不上）。

生成 htpasswd（不依赖 `httpd-tools`，只用 openssl）：

```bash
HASH=$(openssl passwd -apr1 '<BASIC_PASSWORD>')
printf '<BASIC_USER>:%s\n' "$HASH" > /etc/nginx/ghostty-relay.htpasswd
chown root:nginx /etc/nginx/ghostty-relay.htpasswd
chmod 640 /etc/nginx/ghostty-relay.htpasswd
```

`/etc/nginx/conf.d/ghostty-relay.conf` 里的 location 必须按下面的结构来写——
`/api/` 和 `/ws/` 排在 `/` 之前并且**不**继承 `auth_basic`：

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:18080;
}
location /ws/ {
    proxy_pass http://127.0.0.1:18080;
}
location / {
    auth_basic           "Ghostty Session Sharing";
    auth_basic_user_file /etc/nginx/ghostty-relay.htpasswd;
    proxy_pass http://127.0.0.1:18080;
}
```

reload 后烟测：

```bash
# 静态站点（无凭证 / 错凭证 / 正确凭证）
curl -sS -o /dev/null -w "%{http_code}\n" https://<RELAY_DOMAIN>:<RELAY_PORT>/                     # 401
curl -sS -o /dev/null -u 'wrong:wrong' -w "%{http_code}\n" https://<RELAY_DOMAIN>:<RELAY_PORT>/    # 401
curl -sS -o /dev/null -u '<BASIC_USER>:<BASIC_PASSWORD>' \
  -w "%{http_code}\n" https://<RELAY_DOMAIN>:<RELAY_PORT>/                                          # 200

# /api/ 必须能在不带 Basic 的情况下被 token 鉴权
curl -sS -i -X POST https://<RELAY_DOMAIN>:<RELAY_PORT>/api/register \
  -H 'Content-Type: application/json' \
  --data '{"session_id":"smoke","name":"smoke","token":"<USER_TOKEN>"}' | head -1   # 200
```

### 3.11 安全组

阿里云控制台 → 安全组 → 入方向 → 新增 `TCP <RELAY_PORT>` → 来源
`0.0.0.0/0`（如有内网限制按需收紧）。

### 3.12 烟测

```bash
# 本机 admin 健康检查
curl -sS http://127.0.0.1:18081/healthz   # 期望 {"ok": true}

# 公网 register（正确 token）
curl -sS -i https://<RELAY_DOMAIN>:<RELAY_PORT>/api/register \
  -X POST -H 'Content-Type: application/json' \
  --data '{"session_id":"smoke","name":"smoke","token":"<USER_TOKEN>"}'
# 期望 200，body 含 agent_token / client_token / expires_at

# 错误 token 应该 401
curl -sS -i https://<RELAY_DOMAIN>:<RELAY_PORT>/api/register \
  -X POST -H 'Content-Type: application/json' \
  --data '{"session_id":"smoke","name":"smoke","token":"WRONG"}'
# 期望 401 invalid user token

# Web 客户端
curl -sS -o /dev/null -w "%{http_code}\n" https://<RELAY_DOMAIN>:<RELAY_PORT>/
# 期望 200
```

## 4. 最终落点

| 项 | 路径 / 值 |
| --- | --- |
| 客户端 relay 地址 | `<RELAY_DOMAIN>:<RELAY_PORT>` |
| 客户端 user token | `<USER_TOKEN>` |
| Web 客户端 | `https://<RELAY_DOMAIN>:<RELAY_PORT>/`（HTTP Basic：`<BASIC_USER>` / `<BASIC_PASSWORD>`） |
| relay 监听 | `127.0.0.1:18080` |
| admin 监听 | `127.0.0.1:18081`（`/healthz` `/readyz` `/metrics`） |
| 代码目录 | `/opt/ghostty-session-sharing/` |
| 静态站点 | `/opt/ghostty-session-sharing/ghostty-web-client/dist/` |
| Python 解释器 | `/opt/python-3.11/bin/python3.11` |
| OpenSSL prefix | `/opt/openssl11-prefix/`（symlink 指向 `openssl11` RPM） |
| 配置文件 | `/etc/ghostty-relay.env`（`root:ghostty-relay`，`0640`） |
| systemd unit | `/etc/systemd/system/ghostty-relay.service` |
| 状态目录 | `/var/lib/ghostty-relay/`（`0700`） |
| nginx 反代 | `/etc/nginx/conf.d/ghostty-relay.conf` |
| HTTP Basic 凭证 | `/etc/nginx/ghostty-relay.htpasswd`（`root:nginx`，`0640`） |
| 运行用户 | `ghostty-relay`（系统用户，无 shell） |

## 5. 运维 Runbook

```bash
# 看实时日志
journalctl -u ghostty-relay -f

# 重启 relay（改 env 后）
systemctl restart ghostty-relay

# 改 nginx（注意：不是 systemctl reload nginx）
nginx -t && nginx -s reload

# 增加 user token：编辑 env 后逗号分隔
sed -i 's|^GHOSTTY_RELAY_USER_TOKENS=.*|GHOSTTY_RELAY_USER_TOKENS=token1,token2|' /etc/ghostty-relay.env
systemctl restart ghostty-relay

# 升级 relay 代码：从开发机重推 tar，覆盖即可
tar --exclude='__pycache__' --exclude='*.pyc' \
  -czf /tmp/relay.tar.gz -C contrib/session-sharing/relay .
scp /tmp/relay.tar.gz root@<RELAY_HOST>:/tmp/
ssh root@<RELAY_HOST> "
  tar -xzf /tmp/relay.tar.gz \
    -C /opt/ghostty-session-sharing/contrib/session-sharing/relay &&
  systemctl restart ghostty-relay"

# 改 Basic 凭证（htpasswd 文件每次请求读，无需 nginx reload）
# 替换全部凭证：
HASH=$(openssl passwd -apr1 '<NEW_PASSWORD>')
printf '<BASIC_USER>:%s\n' "$HASH" > /etc/nginx/ghostty-relay.htpasswd
# 追加额外用户：
HASH=$(openssl passwd -apr1 '<NEW_PASSWORD>')
printf '<NEW_USER>:%s\n' "$HASH" >> /etc/nginx/ghostty-relay.htpasswd

# 升级 web 客户端
tar -czf /tmp/web-client.tar.gz \
  -C contrib/session-sharing/ghostty-web-client/dist .
scp /tmp/web-client.tar.gz root@<RELAY_HOST>:/tmp/
ssh root@<RELAY_HOST> "
  rm -rf /opt/ghostty-session-sharing/ghostty-web-client/dist/* &&
  tar -xzf /tmp/web-client.tar.gz \
    -C /opt/ghostty-session-sharing/ghostty-web-client/dist"
# 静态文件无需重启 relay
```

## 6. 后续计划

### 6.1 把 Web 静态门换成「复用 user token 网关」（暂未实现）

当前用 nginx HTTP Basic 简单挡住 SPA 入口，凭证（`<BASIC_USER>` /
`<BASIC_PASSWORD>`）和 relay 的 `<USER_TOKEN>` 是两套独立的密钥。后续可考虑把入口
改为 **复用现有 `<USER_TOKEN>`** 的方式：

- 在 `contrib/session-sharing/relay/server.py` 的 `serve_static` 路径上加 token
  校验：
  - 若请求带 `?token=<USER_TOKEN>` 或 `Authorization: Bearer <USER_TOKEN>`：通过，
    并下发一个 `HttpOnly; Secure; SameSite=Strict` 的短期 cookie
  - 后续请求带 cookie 即可，无 token 也无 cookie 直接 401
- nginx 侧把 `auth_basic` 那段从 `location /` 摘掉
- 烟测覆盖：未带 token / 带正确 token / 带过期 cookie 三种 case

收益：
- 单一密钥源，吊销/轮换 token 时一并失效页面访问
- 客户端可以在 ghostty 弹出共享对话框时直接生成一条带 token 的短链给手机扫，省去
  在浏览器里输 Basic 凭证

风险：
- 改 Python 代码，要走 deploy 流程（`scp` + `systemctl restart ghostty-relay`）
- 需要给 cookie 加 `Secure`，依赖 HTTPS 已经就绪（已满足）

## 7. 已知坑 / 注意事项

- **CentOS 7 已 EOL**。如果哪天 `openssl11` 从 EPEL 下架，需要自行编 OpenSSL 1.1。
- **nginx 不在 systemd 下**。任何 `systemctl reload nginx` 都会失败，必须 `nginx -s reload`。
- **`<RELAY_PORT>` 不是 443**。客户端必须在 relay 字段里带端口号（`<RELAY_DOMAIN>:<RELAY_PORT>`）。
- **token 作为入场券**。明文存放在 `/etc/ghostty-relay.env`，权限 0640，
  group=ghostty-relay。一旦泄露需替换并 restart。
- **CentOS 7 默认 `nproc` 较小**。本机是 2 核，编译 Python ≈ 4 分钟。
- **Aliyun 安全组 是 真正 的防火墙**。本机 firewalld 关着，开/关端口要在控制台改。
