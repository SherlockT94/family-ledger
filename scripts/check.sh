#!/usr/bin/env bash
# ==============================================================================
#  Family Ledger · 部署环境自检
#  用法:  bash check.sh [你的域名]
#  例:    bash check.sh ledger.example.com
#
#  这个脚本只读不写，不会修改系统任何配置。
#  它做的事: 在装之前把"会卡住你的那几件事"先找出来。
# ==============================================================================

set -uo pipefail

DOMAIN="${1:-}"
PASS=0; WARN=0; FAIL=0

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; Y=""; R=""; B=""; D=""; N=""
fi

ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
warn() { printf '  %s[WARN]%s %s\n' "$Y" "$N" "$*"; WARN=$((WARN+1)); }
fail() { printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
note() { printf '         %s%s%s\n' "$D" "$*" "$N"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

printf '\n%s============================================================%s\n' "$B" "$N"
printf '%s  Family Ledger · 部署环境自检%s\n' "$B" "$N"
printf '  时间: %s   主机: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname 2>/dev/null || echo unknown)"
printf '%s============================================================%s\n' "$B" "$N"

# ---------------------------------------------------------------- 1. 系统
echo; hr; echo " 1 / 8  操作系统"; hr

OS_NAME="unknown"; OS_VER=""; ARCH="$(uname -m)"

if [ "$(uname -s)" != "Linux" ]; then
  fail "当前系统不是 Linux（检测到 $(uname -s)）"
  note "本项目只支持 Linux 服务器。macOS / Windows 仅供本地开发，不作为部署环境。"
else
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"; OS_VER="${VERSION_ID:-}"
  fi
  case "$OS_NAME$OS_VER" in
    *Ubuntu*22.04*|*Ubuntu*24.04*|*Debian*12*|*Debian*13*|*Rocky*9*|*AlmaLinux*9*|*CentOS*9*)
      ok "$OS_NAME $OS_VER ($ARCH) — 在支持列表内" ;;
    *Ubuntu*20.04*)
      warn "$OS_NAME $OS_VER 偏旧，Docker 需要手动装新版"
      note "建议升级到 22.04 / 24.04，否则 Caddy 与 Docker 的兼容性需要自己处理。" ;;
    *CentOS*7*|*CentOS*8*|*Debian*10*|*Debian*11*)
      warn "$OS_NAME $OS_VER 已停止维护(EOL)，不建议使用"
      note "老系统的 iptables / glibc 版本会导致容器网络异常。" ;;
    *)
      warn "未能识别的发行版: $OS_NAME $OS_VER"
      note "非官方测试环境。大概率能跑，但出问题时排查成本高。" ;;
  esac

  case "$ARCH" in
    x86_64|aarch64) ok "架构 $ARCH 受支持" ;;
    *) warn "架构 $ARCH 未测试（镜像可能不存在）" ;;
  esac

  # 容器内运行检测
  if [ -f /.dockerenv ] || grep -qa 'lxc\|docker\|kvm' /proc/1/cgroup 2>/dev/null; then
    warn "当前环境看起来是 容器 / LXC 内部"
    note "在容器里跑 Docker 需要额外权限(--privileged 或嵌套虚拟化)，通常不建议。"
  fi
fi

# ---------------------------------------------------------------- 2. 资源
echo; hr; echo " 2 / 8  硬件资源"; hr

if [ -r /proc/meminfo ]; then
  MEM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
  if [ "$MEM_MB" -ge 3800 ]; then
    ok "内存 ${MEM_MB} MB"
  elif [ "$MEM_MB" -ge 1800 ]; then
    ok "内存 ${MEM_MB} MB — 达到最低要求"
    note "2G 够跑一个家庭。如果同时跑别的服务，建议加到 4G。"
  else
    fail "内存仅 ${MEM_MB} MB，低于最低要求 2G"
    note "内存不足会导致 SQLite 写入阻塞、容器被 OOM Killer 杀掉。"
  fi
fi

DISK_GB=$(df -Pk / 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')
if [ -n "${DISK_GB:-}" ]; then
  if [ "$DISK_GB" -ge 15 ]; then
    ok "根分区可用 ${DISK_GB} GB"
  elif [ "$DISK_GB" -ge 8 ]; then
    warn "根分区可用仅 ${DISK_GB} GB"
    note "镜像 + 日志 + 备份，建议预留 15G 以上。"
  else
    fail "根分区可用 ${DISK_GB} GB，空间不足"
  fi
fi

CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
if [ "$CORES" -ge 2 ]; then ok "CPU ${CORES} 核"; else warn "CPU 仅 1 核，首次构建/启动会明显变慢"; fi

SWAP=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$SWAP" -eq 0 ] && [ "${MEM_MB:-0}" -lt 3800 ]; then
  warn "未启用 Swap"
  note "2G 内存建议开 1–2G swap，避免偶发 OOM。"
fi

# ---------------------------------------------------------------- 3. Docker
echo; hr; echo " 3 / 8  Docker 环境"; hr

if ! command -v docker >/dev/null 2>&1; then
  fail "未安装 Docker"
  note "安装: curl -fsSL https://get.docker.com | sh"
else
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
  if [ -z "$DOCKER_VER" ]; then
    fail "Docker 已安装，但守护进程未运行或无权限访问"
    note "尝试: sudo systemctl start docker"
    note "若报 permission denied: sudo usermod -aG docker \$USER 后重新登录"
  else
    MAJOR=${DOCKER_VER%%.*}
    if [ "${MAJOR:-0}" -ge 24 ]; then
      ok "Docker $DOCKER_VER"
    elif [ "${MAJOR:-0}" -ge 20 ]; then
      warn "Docker $DOCKER_VER 偏旧，建议升级到 24+"
    else
      fail "Docker $DOCKER_VER 过旧（需要 24 以上）"
    fi
  fi
fi

if docker compose version >/dev/null 2>&1; then
  CV=$(docker compose version --short 2>/dev/null || echo "?")
  ok "Docker Compose 插件 v$CV"
elif command -v docker-compose >/dev/null 2>&1; then
  fail "检测到旧版 docker-compose (v1)，本项目使用 Compose v2"
  note "v1 已停止维护，启动会报 'version' 属性错误。"
  note "安装 v2: sudo apt install docker-compose-plugin"
else
  warn "未检测到 Docker Compose"
  note "安装: sudo apt install docker-compose-plugin"
fi

# ---------------------------------------------------------------- 4. 端口
echo; hr; echo " 4 / 8  端口占用（80 / 443 / 8000）"; hr

port_busy() {
  local p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn 2>/dev/null | awk -v P=":$p" '$4 ~ P"$"' | grep -q . && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v P=":$p" '$4 ~ P"$"' | grep -q . && return 0
  fi
  return 1
}

for P in 80 443; do
  if port_busy "$P"; then
    fail "端口 $P 已被占用 —— Caddy 无法启动"
    command -v ss >/dev/null 2>&1 && note "占用进程: $(ss -Hltnp 2>/dev/null | awk -v P=":$P" '$4 ~ P"$"' | head -1 | sed 's/^[[:space:]]*//')"
    note "最常见原因: 已装宝塔面板 / nginx / apache / 其他 Web 服务。"
    note "解决: 停掉占用服务，或换一台干净的机器（推荐后者，更省事）。"
  else
    ok "端口 $P 空闲"
  fi
done

if port_busy 8000; then
  warn "端口 8000 被占用（应用默认端口）"
  note "可以在 .env 里改 APP_PORT，不影响使用。"
else
  ok "端口 8000 空闲"
fi

# 已知冲突软件
CONFLICT_HIT=0
for proc in nginx apache2 httpd bt; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    fail "检测到运行中的 $proc —— 与 Caddy 抢占 80/443"
    CONFLICT_HIT=1
  fi
done
[ -d /www/server/panel ] && { fail "检测到宝塔面板 (/www/server/panel)"; CONFLICT_HIT=1; }
[ "$CONFLICT_HIT" -eq 0 ] && ok "未发现宝塔 / nginx / apache 冲突"

# ---------------------------------------------------------------- 5. 网络
echo; hr; echo " 5 / 8  网络连通性"; hr

if command -v curl >/dev/null 2>&1; then
  HUB_CODE=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null)
  HUB_CODE=${HUB_CODE:-000}
  MIRRORS=$(docker info --format '{{join .RegistryConfig.Mirrors ","}}' 2>/dev/null || echo "")
  case "$HUB_CODE" in
    200|401)
      ok "可访问 Docker Hub（镜像可拉取）" ;;
    000)
      if [ -n "$MIRRORS" ]; then
        warn "无法直连 Docker Hub，但已配置镜像加速: $MIRRORS"
        note "通常可以正常拉取。若后面拉镜像超时，优先排查加速器是否失效。"
      else
        fail "无法访问 Docker Hub，且未配置镜像加速 —— 镜像拉不下来"
        note "国内服务器常见。在 /etc/docker/daemon.json 加 registry-mirrors 后重启 Docker。"
        note "也可在部署包内的 .env 里指定 IMAGE_PREFIX 走国内仓库。"
      fi ;;
    *)
      warn "Docker Hub 返回 HTTP $HUB_CODE，镜像拉取可能异常"
      note "多为网络中间层拦截。可尝试配置镜像加速。" ;;
  esac

  if curl -sS -m 10 -o /dev/null https://acme-v02.api.letsencrypt.org/directory 2>/dev/null; then
    ok "可访问 Let's Encrypt（Caddy 自动签发 HTTPS 需要）"
  else
    fail "无法访问 Let's Encrypt 接口"
    note "证书签不出来，HTTPS 会失败。检查防火墙出站规则，或确认网络未被代理拦截。"
  fi

  # 时间偏差（TLS 握手对时间敏感）
  REMOTE_TS=$(curl -sI -m 8 https://www.baidu.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
  if [ -n "$REMOTE_TS" ]; then
    R_EPOCH=$(date -d "$REMOTE_TS" +%s 2>/dev/null || echo "")
    L_EPOCH=$(date +%s)
    if [ -n "$R_EPOCH" ]; then
      DIFF=$(( L_EPOCH - R_EPOCH )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
      if [ "$DIFF" -le 60 ]; then
        ok "系统时间准确（偏差 ${DIFF}s）"
      else
        warn "系统时间偏差 ${DIFF} 秒"
        note "时间不同步会导致 HTTPS 证书校验失败。开启 NTP: timedatectl set-ntp true"
      fi
    fi
  fi
else
  warn "未安装 curl，跳过网络检查"
fi

# ---------------------------------------------------------------- 6. 域名
echo; hr; echo " 6 / 8  域名解析"; hr

if [ -n "$DOMAIN" ]; then
  RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$RESOLVED" ]; then
    fail "域名 $DOMAIN 解析不到任何 IPv4 地址"
    note "去域名服务商添加 A 记录，指向这台服务器的公网 IP。"
  else
    ok "域名 $DOMAIN → $RESOLVED"
    PUBLIC_IP=$(curl -sS -m 8 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$PUBLIC_IP" ]; then
      if [ "$RESOLVED" = "$PUBLIC_IP" ]; then
        ok "解析结果与本机公网 IP 一致（$PUBLIC_IP）"
      else
        warn "解析到 $RESOLVED，但本机公网 IP 是 $PUBLIC_IP"
        note "不一致时证书签发会失败。若走了 CDN/代理，需确认回源配置。"
      fi
    fi
  fi
  # ICP 备案提醒
  note "国内服务器 + 域名对外提供 Web 服务，按规定需完成 ICP 备案。"
else
  warn "未传入域名，跳过解析检查"
  note "用法: bash check.sh 你的域名"
  note "本项目需要域名才能自动签发 HTTPS 证书。纯 IP 访问会失败。"
fi

# ---------------------------------------------------------------- 7. 防火墙
echo; hr; echo " 7 / 8  防火墙与安全策略"; hr

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ok "ufw 已启用"
  ufw status 2>/dev/null | grep -qE '^80(/tcp)?\s+ALLOW' || warn "ufw 未显式放行 80 端口"
  ufw status 2>/dev/null | grep -qE '^443(/tcp)?\s+ALLOW' || warn "ufw 未显式放行 443 端口"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  ok "firewalld 已启用"
  firewall-cmd --list-ports 2>/dev/null | grep -q '80/tcp' || warn "firewalld 未放行 80/tcp"
  firewall-cmd --list-ports 2>/dev/null | grep -q '443/tcp' || warn "firewalld 未放行 443/tcp"
else
  ok "本机未启用 ufw / firewalld"
  note "注意: 云厂商的「安全组」是独立一层，必须在控制台放行 80/443。"
  note "这是最常见的『本机都正常但外网打不开』原因。"
fi

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  warn "SELinux 处于 Enforcing"
  note "可能导致容器挂载目录权限被拒。可临时 setenforce 0 验证，长期用 chcon 或加策略。"
fi

# ---------------------------------------------------------------- 8. 汇总
echo; hr; echo " 8 / 8  结论"; hr

TOTAL=$((PASS+WARN+FAIL))
printf '  共检查 %d 项：%s%d 通过%s，%s%d 警告%s，%s%d 失败%s\n\n' \
  "$TOTAL" "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  printf '  %s环境完全符合要求，可以开始部署。%s\n' "$G$B" "$N"
elif [ "$FAIL" -eq 0 ]; then
  printf '  %s可以部署。上面的 [WARN] 项建议先处理，否则可能变成售后问题。%s\n' "$Y$B" "$N"
else
  printf '  %s有 %d 项必须先解决，否则部署一定失败。%s\n' "$R$B" "$FAIL" "$N"
  printf '  请把本页完整截图发给卖家，我们会告诉你下一步怎么做。\n'
fi

printf '\n  自检结束。日志已输出到终端，可直接复制。\n\n'
exit 0
