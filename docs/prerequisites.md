# 部署前提清单

> 这份文档的目的只有一个：**在你花钱之前，先确定这台机器能装上。**
> 逐条对一遍，比装到一半卡住再找人问要快得多。

自检脚本会覆盖其中大部分项目：

```bash
bash check.sh 你的域名.com
```

---

## 一、必须满足（不满足一定装不上）

### 1. 操作系统

| 支持 | 已测试 |
|---|---|
| Ubuntu 22.04 / 24.04 | ✅ |
| Debian 12 / 13 | ✅ |
| Rocky Linux 9 / AlmaLinux 9 | ✅ |

**不支持：** CentOS 7/8、Debian 10/11（已 EOL，glibc 与 iptables 版本会导致容器网络异常）、Windows、macOS、WSL。

```bash
cat /etc/os-release | head -3
```

### 2. 硬件

| 项 | 最低 | 推荐 |
|---|---|---|
| CPU | 1 核 | 2 核 |
| 内存 | 2 GB | 4 GB |
| 磁盘可用 | 8 GB | 20 GB |

2 GB 内存的机器建议开 1–2 GB swap，避免偶发 OOM 把容器杀掉：

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 3. 一台干净的机器

这是**最高频的失败原因**。以下任一情况都会导致部署失败：

- 已装 **宝塔面板**（`/www/server/panel`）
- 已装 **nginx / apache / httpd** 并在运行
- 已有其他服务占用 **80 或 443** 端口

```bash
# 自查
ss -ltnp | grep -E ':(80|443)\s'
pgrep -x nginx; pgrep -x apache2; pgrep -x httpd
ls -d /www/server/panel 2>/dev/null
```

**有输出就说明冲突。** 建议直接换一台干净的机器（新开一台按量付费的，装完再决定留哪台），比在旧机器上拆服务省事得多。

### 4. 域名

必须有一个域名，且 A 记录已解析到这台服务器的**公网 IP**：

```bash
dig +short 你的域名.com
curl -s https://api.ipify.org    # 本机公网 IP，两者应一致
```

- 系统用 Caddy 自动申请 Let's Encrypt 证书，**必须能通过 80 端口完成 HTTP-01 验证**
- 纯 IP 访问不支持：证书签不出来，手机端会被浏览器拦截
- 域名走了 CDN 也可以，但需要确认回源配置正确，否则验证会失败

> 国内服务器 + 域名对外提供 Web 服务，按规定需完成 **ICP 备案**。没备案的域名在 80/443 上会被拦，这一步无法绕过。

### 5. Docker

需要 **Docker 24+** 与 **Compose v2**（`docker compose` 命令，不是旧版的 `docker-compose`）。

```bash
docker version --format '{{.Server.Version}}'
docker compose version
```

未安装：

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # 之后重新登录
```

只装了旧版 `docker-compose`（v1）会报 `version` 属性错误，需装 v2 插件：

```bash
sudo apt install docker-compose-plugin    # Debian/Ubuntu
sudo dnf install docker-compose-plugin    # Rocky/Alma
```

### 6. 能拉取镜像

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://registry-1.docker.io/v2/
```

返回 `200` 或 `401` 都算通（401 是正常的未认证响应）。返回 `000` 说明连不上，国内服务器常见，需配置镜像加速：

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"]
}
EOF
sudo systemctl restart docker
```

> 镜像加速器地址会失效、也会换，用之前确认一下当前可用性。腾讯云内网机器用上面的地址通常可用。

### 7. 出站能到 Let's Encrypt

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://acme-v02.api.letsencrypt.org/directory
```

不通则证书签不出来。检查防火墙出站规则、是否有透明代理拦截。

---

## 二、容易漏掉的（装上了但访问不了）

### 8. 云厂商安全组

**本机 `ufw` / `firewalld` 全放行了，外网还是打不开——九成是安全组没放行。**

去云控制台 → 安全组 → 入方向，放行 `80/tcp` 与 `443/tcp`（源地址 `0.0.0.0/0`）。阿里云、腾讯云、华为云、AWS、Azure 都有这一层，且默认不开。

### 9. 系统时间

时间偏差超过几分钟会导致 TLS 握手失败，表现为「证书签不出来」或「浏览器报证书错误」，但日志里看不出明显原因。

```bash
timedatectl set-ntp true
timedatectl status | grep -i synchronized
```

### 10. SELinux

Rocky / Alma 默认 `Enforcing`，容器挂载宿主机目录时可能被拒：

```bash
getenforce
# 临时验证
sudo setenforce 0
```

若 `setenforce 0` 后正常，长期方案是给目录加正确的 context（`chcon -Rt container_file_t`），不要长期关掉 SELinux。

---

## 三、症状对照表

装的时候卡住了，先在这里找。

| 症状 | 原因 | 解决 |
|---|---|---|
| `bind: address already in use` | 80/443 被 nginx、宝塔或别的容器占用 | `ss -ltnp \| grep :80` 找出进程，停掉；或换干净机器 |
| 容器起来了，浏览器打不开 | 云安全组没放行 80/443 | 控制台放行入方向 |
| 浏览器提示「连接不是私密连接」 | 证书没签成功 | 检查域名解析、80 端口可达性、Let's Encrypt 出站 |
| 日志里 `acme: challenge failed` | 80 端口不通，或域名没解析到本机 | `dig +short 域名` 对比 `curl ipify` |
| `permission denied while trying to connect to the Docker daemon` | 当前用户不在 docker 组 | `sudo usermod -aG docker $USER` 后重新登录 |
| `pull access denied` / 拉镜像超时 | 访问不了 Docker Hub | 配 `registry-mirrors` |
| 启动后很快退出，日志无报错 | 内存不足被 OOM Killer 杀掉 | `dmesg \| grep -i oom` 确认，加内存或加 swap |
| 页面能开但很慢、偶尔 502 | 磁盘 IO 打满（低配云盘的常见问题） | 换 SSD 云盘，或提高 IOPS |
| `docker compose` 命令不存在 | 只装了 v1 | 装 `docker-compose-plugin` |
| 数据目录权限错误 | SELinux 或运行用户 UID 不匹配 | `chcon` 修 context，或按手册设置 `PUID` |

---

## 四、什么情况下应该直接放弃

说清楚比说好听有用。遇到以下情况，**建议不要买**：

- 服务器上已经在跑其他业务（尤其是宝塔、nginx、多个站点）
- 没有域名，也不打算买域名
- 服务器是公司/单位的内网机器，出站受限
- 用的是共享虚拟主机或不能跑容器的环境
- 希望「装完就永远不用管」——这套东西需要偶尔看一眼备份是否正常

这些不是能力问题，是场景不匹配。装不上再退款，对双方都是浪费时间。

---

## 五、还是搞不定？

把自检脚本的完整输出截图发过来（`bash check.sh 你的域名.com`）。有这张图，绝大多数问题一眼能定位。
