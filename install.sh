#!/bin/sh
# sing-box 1.14.4 一键搭建脚本
# 节点: VLESS Reality + Hysteria2 + TUIC + AnyTLS (自签证书)
# 可选: Shadowsocks (aes-256-gcm), 跑完 4 节点后询问, 回车默认不装, 输入 y 安装
# 兼容: Ubuntu / Debian / CentOS / Alpine / Arch 等 (systemd / OpenRC / 无 init)
# 用法: curl -fsSL https://singbox.mm87.eu.org/install.sh | sh  (需 root)
#       或下载后 sh install.sh
# 端口: 运行时逐个询问, 直接回车 = 随机端口
set -e

SINGBOX_VERSION="1.14.4"
INSTALL_DIR="/opt/sing-box-nodes"
CONF_DIR="$INSTALL_DIR/conf"
BIN="/usr/local/bin/sing-box"
SVC_NAME="sing-box-nodes"

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# ---------- 必须 root ----------
if [ "$(id -u)" -ne 0 ]; then
  die "请用 root 运行: sudo sh $0"
fi

# ---------- 从终端读输入 (curl | sh 时 stdin 是脚本本身, 必须读 /dev/tty) ----------
read_tty() {
  if [ -c /dev/tty ]; then
    IFS= read -r "$1" < /dev/tty
  else
    IFS= read -r "$1"
  fi
}

# ---------- 检测系统 ----------
OS_ID="unknown"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
fi

INIT="none"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT="systemd"
elif command -v rc-service >/dev/null 2>&1; then
  INIT="openrc"
fi
info "系统: $OS_ID, 启动方式: $INIT"

# ---------- 纯 IPv6 检测与常驻 IPv4 出口 (与 sb 内同名函数保持一致) ----------
have_ipv4() {
# 有 IPv4 出口返回 0 (两个端点任一通即可)
curl -4 -fsS --max-time 6 -o /dev/null https://api.ipify.org 2>/dev/null && return 0
curl -4 -fsS --max-time 6 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && return 0
return 1
}

setup_v4exit() {
# 纯 IPv6 机器常驻 IPv4 出口 (改编自 Otis 提供的 v4.txt 方案):
# usque 从 GitHub 仓库拉取 (raw 主源, sb.shabby.skin 反代与 jsDelivr 双栈兜底), 注册 WARP 后装常驻服务 + 默认 v4 路由服务
# 已有 IPv4 出口则跳过; 出口建立成功返回 0
have_ipv4 && { echo "本机已有 IPv4 出口, 无需设置"; return 0; }
[ -e /dev/net/tun ] || { echo "无法建立 IPv4 出口: 无 /dev/net/tun (容器未映射 tun 设备时常见)"; return 1; }
if command -v ip >/dev/null 2>&1; then
if ip tuntap add dev sbv4test0 mode tun 2>/dev/null; then
ip link del sbv4test0 2>/dev/null || true
else
echo "无法建立 IPv4 出口: 无权创建 tun 设备 (容器缺 NET_ADMIN 权限时常见)"
return 1
fi
fi
_ua=""
case "$(uname -m)" in
x86_64|amd64) _ua="amd64";;
aarch64|arm64) _ua="arm64";;
*) echo "无法建立 IPv4 出口: 不支持的架构 $(uname -m)"; return 1;;
esac
if [ ! -x /usr/local/bin/usque ]; then
echo "正在下载 usque (GitHub 仓库)..."
_ut=$(mktemp -d)
if ! curl -fsSL --max-time 90 -o "$_ut/usque.gz" "https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/tools/usque-linux-$_ua.gz" \
&& ! curl -fsSL --max-time 90 -o "$_ut/usque.gz" "https://sb.shabby.skin/tools/usque-linux-$_ua.gz" \
&& ! curl -fsSL --max-time 90 -o "$_ut/usque.gz" "https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/tools/usque-linux-$_ua.gz"; then
rm -rf "$_ut"; echo "usque 下载失败"; return 1
fi
if ! gzip -dc "$_ut/usque.gz" > /usr/local/bin/usque 2>/dev/null; then
rm -rf "$_ut"; echo "usque 下载失败"; return 1
fi
rm -rf "$_ut"
chmod +x /usr/local/bin/usque
fi
if [ ! -f /usr/local/etc/usque/config.json ]; then
echo "正在注册 WARP 账号..."
_ut=$(mktemp -d)
if ! (cd "$_ut" && /usr/local/bin/usque register -a >/dev/null 2>&1) || [ ! -f "$_ut/config.json" ]; then
rm -rf "$_ut"; echo "WARP 注册失败"; return 1
fi
mkdir -p /usr/local/etc/usque
cp "$_ut/config.json" /usr/local/etc/usque/config.json
chmod 600 /usr/local/etc/usque/config.json
rm -rf "$_ut"
fi
case "$INIT" in
systemd)
cat > /etc/systemd/system/usque.service <<'UEOF'
[Unit]
Description=usque WARP tunnel (IPv4 exit for IPv6-only host)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/usque -c /usr/local/etc/usque/config.json nativetun -6
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UEOF
cat > /etc/systemd/system/ipv42tun.service <<'REOF'
[Unit]
Description=Default IPv4 route via usque tun0
After=network-online.target usque.service
Wants=network-online.target
Requires=usque.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 30 ]; do ip -4 link show dev tun0 >/dev/null 2>&1 && break; i=$((i+1)); sleep 1; done; ip -4 route replace default dev tun0 metric 50'

[Install]
WantedBy=multi-user.target
REOF
systemctl daemon-reload
systemctl enable --now usque.service >/dev/null 2>&1
systemctl enable --now ipv42tun.service >/dev/null 2>&1
;;
openrc)
cat > /etc/init.d/usque <<'UEOF'
#!/sbin/openrc-run
name="usque"
description="usque WARP tunnel (IPv4 exit for IPv6-only host)"
command="/usr/local/bin/usque"
command_args="-c /usr/local/etc/usque/config.json nativetun -6"
command_background=true
pidfile="/run/usque.pid"
depend() {
    need net
}

remove_v4exit() {
# 清理常驻 IPv4 出口 (路由 + usque 服务 + 二进制与配置), 卸载时调用
ip -4 route del default dev tun0 2>/dev/null || true
case "$INIT" in
systemd)
systemctl disable --now ipv42tun.service >/dev/null 2>&1 || true
systemctl disable --now usque.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/usque.service /etc/systemd/system/ipv42tun.service
systemctl daemon-reload 2>/dev/null || true
;;
openrc)
rc-service usque stop >/dev/null 2>&1 || true
rc-update del usque default >/dev/null 2>&1 || true
rm -f /etc/init.d/usque /etc/local.d/ipv42tun.start
;;
*)
pkill -f "usque.*nativetun" 2>/dev/null || true
;;
esac
rm -f /usr/local/bin/usque
rm -rf /usr/local/etc/usque
}
UEOF
chmod +x /etc/init.d/usque
rc-update add usque default >/dev/null 2>&1
rc-service usque restart >/dev/null 2>&1 || rc-service usque start >/dev/null 2>&1
mkdir -p /etc/local.d
cat > /etc/local.d/ipv42tun.start <<'REOF'
#!/bin/sh
i=0
while [ $i -lt 30 ]; do
  ip -4 link show dev tun0 >/dev/null 2>&1 && break
  i=$((i+1)); sleep 1
done
ip -4 route replace default dev tun0 metric 50 2>/dev/null
REOF
chmod +x /etc/local.d/ipv42tun.start
rc-update add local default >/dev/null 2>&1
/etc/local.d/ipv42tun.start
;;
*)
echo "无 systemd/OpenRC, 无法设置常驻服务; usque 二进制与配置已就位, 可手动运行:"
echo "  usque -c /usr/local/etc/usque/config.json nativetun -6  然后另开终端: ip -4 route add default dev tun0 metric 50"
return 1
;;
esac
_i=0
while [ "$_i" -lt 10 ]; do
sleep 2
if have_ipv4; then
echo "IPv4 出口已建立 (usque/WARP 常驻服务, 开机自启; 出口 IP 为 Cloudflare WARP)"
return 0
fi
_i=$((_i + 1))
done
echo "IPv4 出口暂未生效: usque 服务已安装并会持续重试, 稍后可用 curl -4 https://api.ipify.org 自行检查"
return 1
}

# ---------- 装依赖 (curl / openssl, Alpine 还要 gcompat 跑 glibc 二进制) ----------
install_deps() {
  need=""
  command -v curl >/dev/null 2>&1 || need="$need curl"
  command -v openssl >/dev/null 2>&1 || need="$need openssl"
  command -v jq >/dev/null 2>&1 || need="$need jq"
  # sing-box 官方二进制是 glibc 动态链接, Alpine (musl) 需 gcompat 提供加载器
  if [ "$OS_ID" = "alpine" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
    need="$need gcompat"
  fi
  if [ -z "$need" ]; then return 0; fi
  info "安装依赖:$need"
  case "$OS_ID" in
    alpine)
      apk add --no-cache $need ;;
    debian|ubuntu)
      apt-get update -qq && apt-get install -y -qq $need ;;
    centos|rhel|fedora|rocky|almalinux|oracle)
      if command -v dnf >/dev/null 2>&1; then dnf install -y -q $need;
      else yum install -y -q $need; fi ;;
    arch|manjaro)
      pacman -Sy --noconfirm --needed $need ;;
    *)
      warn "未知发行版, 请手动安装:$need 后重跑"
      exit 1 ;;
  esac
}
# ---------- 已安装且正在运行 -> 直接进菜单, 不重装节点 ----------
if [ -x /usr/local/bin/sb ] && [ -f "$INSTALL_DIR/config.json" ]; then
  _already_running=0
  case "$INIT" in
    systemd)
      if systemctl is-active --quiet "$SVC_NAME"; then _already_running=1; fi
      ;;
    openrc)
      if rc-service "$SVC_NAME" status 2>/dev/null | grep -qi "started"; then _already_running=1; fi
      ;;
    *)
      if pgrep -f "sing-box run -c $INSTALL_DIR/config.json" >/dev/null; then _already_running=1; fi
      ;;
  esac
  if [ "$_already_running" = "1" ]; then
    echo "检测到 sing-box 正在运行, 直接进入管理菜单 (不重装节点)..."
    exec /usr/local/bin/sb
  fi
fi

# ---------- 初始菜单 ----------
echo ""
echo "========== 自用 sing-box 一键安装 =========="
echo " 1) 安装"
echo " 2) 退出"
echo "=============================================="
printf "请选择 [1-2]: "
read_tty INSTALL_CHOICE
case "$INSTALL_CHOICE" in
  1) ;;
  2) echo "已退出"; exit 0;;
  *) echo "无效选择"; exit 1;;
esac

install_deps

# ---------- 随机端口 ----------
random_port() {
  if command -v shuf >/dev/null 2>&1; then
    shuf -i 10000-60000 -n 1
    return
  fi
  # 无 shuf 时用 /dev/urandom
  n=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
  [ -z "$n" ] && n=12345
  echo $((10000 + n % 50001))
}

port_in_use() {
  _p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":${_p} " && return 0
    ss -uln 2>/dev/null | grep -q ":${_p} " && return 0
    return 1
  fi
  _hex=$(printf '%04X' "$_p")
  grep -qi ":${_hex} " /proc/net/tcp /proc/net/udp 2>/dev/null && return 0
  return 1
}

# 注意: 提示语一律走 stderr, 只有最后的端口号走 stdout (否则 $(...) 会把提示语也吞进变量)
ask_port() {
  _name="$1"
  while true; do
    printf '请输入 %s 端口 (直接回车=随机): ' "$_name" >&2
    read_tty _in
    if [ -z "$_in" ]; then
      _p=$(random_port)
      _t=0
      while port_in_use "$_p" && [ "$_t" -lt 20 ]; do
        _p=$(random_port); _t=$((_t + 1))
      done
      echo "  -> 随机端口: $_p" >&2
      echo "$_p"
      return
    fi
    case "$_in" in
      *[!0-9]*) echo "  端口必须是数字" >&2; continue ;;
    esac
    if [ "$_in" -lt 1 ] || [ "$_in" -gt 65535 ]; then
      echo "  端口范围 1-65535" >&2; continue
    fi
    if port_in_use "$_in"; then
      echo "  端口 $_in 已被占用" >&2; continue
    fi
    echo "$_in"
    return
  done
}

# ---------- 节点地址 ----------
printf '节点地址 (域名或IP, 回车自动检测公网IP): '
read_tty HOST_INPUT
if [ -z "$HOST_INPUT" ]; then
  HOST=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
      || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
      || curl -fsS --max-time 10 https://api64.ipify.org 2>/dev/null \
      || true)
  [ -z "$HOST" ] && die "无法自动检测公网IP, 请手动输入域名或IP后重跑"
  info "自动检测到地址: $HOST"
else
  HOST="$HOST_INPUT"
fi
# IPv6 加方括号
case "$HOST" in
  *:*)
    HOST_B="[$HOST]" ;;
  *)
    HOST_B="$HOST" ;;
esac

# 纯 IPv6: 无 IPv4 出口时自动建立常驻 IPv4 出口 (usque/WARP, 改编自 v4.txt 方案); 建立失败则清理残留并终止安装 (Otis 2026-11-13 定: 出口失败没必要继续装)
if ! have_ipv4; then
  info "检测到纯 IPv6 网络 (无 IPv4 出口), 正在建立常驻 IPv4 出口..."
  if ! setup_v4exit; then
    remove_v4exit >/dev/null 2>&1 || true
    warn "安装失败: IPv4 出口建立失败, 安装终止。请处理上面提示的问题 (如容器 tun 权限) 后重新运行安装。"
    exit 1
  fi
fi

# ---------- 端口 (首次安装不提问, 直接随机) ----------
PORT_VLESS=$(random_port)
while port_in_use "$PORT_VLESS"; do
  PORT_VLESS=$(random_port)
done

# ---------- 下载 sing-box ----------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "不支持的架构: $ARCH (仅支持 amd64/arm64)" ;;
esac

TARBALL="sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
URL_GH="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TARBALL}"
URL_MIRROR="https://gh-proxy.com/https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${TARBALL}"

URL_SLIM_GH="https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/core/v${SINGBOX_VERSION}/sing-box-linux-${ARCH}.gz"
URL_SLIM_CF="https://sb.shabby.skin/core/v${SINGBOX_VERSION}/sing-box-linux-${ARCH}.gz"
URL_SLIM_JSD="https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/core/v${SINGBOX_VERSION}/sing-box-linux-${ARCH}.gz"

mkdir -p "$INSTALL_DIR"
if ! "$BIN" version 2>/dev/null | grep -q "$SINGBOX_VERSION"; then
  cd /tmp
  # 精简版核心: 主源 GitHub 仓库, 依次经 sb.shabby.skin 反代、jsDelivr 兜底 (双栈, 纯 IPv6 机器可达); 均做 sha256 校验
  info "下载 sing-box $SINGBOX_VERSION 精简版 ($ARCH)..."
  _slim_ok=""
  for _su in "$URL_SLIM_GH" "$URL_SLIM_CF" "$URL_SLIM_JSD"; do
    if curl -fsSL --connect-timeout 20 -o "sb-slim.gz" "$_su" \
      && curl -fsSL --connect-timeout 20 -o "sb-slim.sha256" "$_su.sha256" \
      && [ "$(sha256sum "sb-slim.gz" | awk '{print $1}')" = "$(awk '{print $1}' "sb-slim.sha256")" ] \
      && gzip -dc "sb-slim.gz" > "$BIN" 2>/dev/null; then
      _slim_ok=1
      break
    fi
    rm -f "sb-slim.gz" "sb-slim.sha256"
  done
  if [ -n "$_slim_ok" ]; then
    chmod +x "$BIN"
    rm -f "sb-slim.gz" "sb-slim.sha256"
    info "精简版核心安装完成"
  else
    rm -f "sb-slim.gz" "sb-slim.sha256"
    warn "精简版下载失败, 回退 GitHub 官方版..."
    if ! curl -fL --connect-timeout 20 -o "$TARBALL" "$URL_GH"; then
      warn "GitHub 直连失败, 尝试 gh-proxy 镜像..."
      curl -fL --connect-timeout 20 -o "$TARBALL" "$URL_MIRROR" \
        || die "下载失败, 请检查网络后重跑"
    fi
    tar -xzf "$TARBALL"
    cp "sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box" "$BIN"
    chmod +x "$BIN"
    rm -rf "$TARBALL" "sing-box-${SINGBOX_VERSION}-linux-${ARCH}"
  fi
else
  info "sing-box $SINGBOX_VERSION 已安装, 跳过下载"
fi

# 校验二进制能跑 (Alpine 缺 gcompat 时这里会报 not found)
if ! "$BIN" version >/dev/null 2>&1; then
  if [ "$OS_ID" = "alpine" ]; then
    warn "sing-box 无法运行, 补装 gcompat 后重试..."
    apk add --no-cache gcompat
    "$BIN" version >/dev/null 2>&1 || die "安装 gcompat 后仍无法运行 sing-box"
  else
    die "sing-box 无法运行: $BIN"
  fi
fi
"$BIN" version | head -1

# ---------- 生成凭证 ----------
info "生成密钥与证书..."
KEYPAIR=$("$BIN" generate reality-keypair)
PRIVATE_KEY=$(printf '%s' "$KEYPAIR" | grep -i 'PrivateKey' | awk '{print $2}')
PUBLIC_KEY=$(printf '%s' "$KEYPAIR" | grep -i 'PublicKey' | awk '{print $2}')
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "Reality 密钥生成失败"

UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)
SNI="www.amazon.com"

# 自签证书 (Hy2/TUIC/AnyTLS 共用)
openssl req -x509 -newkey rsa:2048 \
  -keyout "$INSTALL_DIR/cert.key" \
  -out "$INSTALL_DIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=$SNI" 2>/dev/null \
  || die "自签证书生成失败"
chmod 600 "$INSTALL_DIR/cert.key"

# ---------- 写碎片 (每个协议一个函数, 参数: tag 端口 凭证...) ----------
write_frag_vless() {
  # $1=tag $2=port $3=uuid $4=private_key $5=short_id
  cat > "$CONF_DIR/$1.json" <<EOF
{
  "type": "vless",
  "tag": "$1",
  "listen": "::",
  "listen_port": $2,
  "users": [{ "uuid": "$3", "flow": "xtls-rprx-vision" }],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "reality": {
      "enabled": true,
      "handshake": { "server": "$SNI", "server_port": 443 },
      "private_key": "$4",
      "short_id": ["$5"]
    }
  }
}
EOF
}

write_frag_hy2() {
  # $1=tag $2=port $3=password
  cat > "$CONF_DIR/$1.json" <<EOF
{
  "type": "hysteria2",
  "tag": "$1",
  "listen": "::",
  "listen_port": $2,
  "users": [{ "password": "$3" }],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "certificate_path": "$INSTALL_DIR/cert.pem",
    "key_path": "$INSTALL_DIR/cert.key"
  }
}
EOF
}

write_frag_tuic() {
  # $1=tag $2=port $3=uuid $4=password
  cat > "$CONF_DIR/$1.json" <<EOF
{
  "type": "tuic",
  "tag": "$1",
  "listen": "::",
  "listen_port": $2,
  "users": [{ "uuid": "$3", "password": "$4" }],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "alpn": ["h3"],
    "certificate_path": "$INSTALL_DIR/cert.pem",
    "key_path": "$INSTALL_DIR/cert.key"
  }
}
EOF
}

write_frag_anytls() {
  # $1=tag $2=port $3=password
  cat > "$CONF_DIR/$1.json" <<EOF
{
  "type": "anytls",
  "tag": "$1",
  "listen": "::",
  "listen_port": $2,
  "users": [{ "password": "$3" }],
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "certificate_path": "$INSTALL_DIR/cert.pem",
    "key_path": "$INSTALL_DIR/cert.key"
  }
}
EOF
}

write_frag_ss() {
  # $1=tag $2=port $3=password
  cat > "$CONF_DIR/$1.json" <<EOF
{
  "type": "shadowsocks",
  "tag": "$1",
  "listen": "::",
  "listen_port": $2,
  "method": "aes-256-gcm",
  "password": "$3"
}
EOF
}


# ---------- 合并碎片 -> config.json ----------
assemble_config() {
  set -- "$CONF_DIR"/*.json
  [ -f "$1" ] || die "conf/ 下没有任何节点碎片"
  jq -s '{log: {level: "info", timestamp: true}, inbounds: ., outbounds: [{type: "direct", tag: "direct"}], route: {final: "direct"}}' "$CONF_DIR"/*.json > "$INSTALL_DIR/config.json" \
    || die "合并配置失败"
  "$BIN" check -c "$INSTALL_DIR/config.json" || die "配置校验失败"
}

info "写入节点碎片: $INSTALL_DIR/conf/"
mkdir -p "$CONF_DIR"
write_frag_vless "vless-reality" "$PORT_VLESS" "$UUID_VLESS" "$PRIVATE_KEY" "$SHORT_ID"
printf '%s' "$PUBLIC_KEY" > "$CONF_DIR/vless-reality.pub"
assemble_config

# ---------- 重启服务 ----------
restart_service() {
  case "$INIT" in
    systemd)
      systemctl restart "$SVC_NAME"
      sleep 2
      systemctl is-active --quiet "$SVC_NAME" || die "服务启动失败"
      ;;
    openrc)
      rc-service "$SVC_NAME" restart
      sleep 2
      rc-service "$SVC_NAME" status | grep -qi "started" || die "服务启动失败"
      ;;
    *)
      pkill -f "sing-box run -c $INSTALL_DIR/config.json" 2>/dev/null || true
      sleep 1
      nohup "$BIN" run -c "$INSTALL_DIR/config.json" \
        > "$INSTALL_DIR/sing-box.log" 2>&1 &
      sleep 2
      pgrep -f "sing-box run -c $INSTALL_DIR/config.json" >/dev/null \
        || die "后台启动失败, 见 $INSTALL_DIR/sing-box.log"
      ;;
  esac
}

info "设置开机自启并启动 (启动方式: $INIT)..."
case "$INIT" in
  systemd)
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=sing-box nodes (Reality/Hy2/TUIC/AnyTLS)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$BIN run -c $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    restart_service
    ;;
  openrc)
    cat > "/etc/init.d/$SVC_NAME" <<EOF
#!/sbin/openrc-run
name="$SVC_NAME"
description="sing-box nodes (Reality/Hy2/TUIC/AnyTLS)"
command="$BIN"
command_args="run -c $INSTALL_DIR/config.json"
command_background=true
pidfile="/run/${SVC_NAME}.pid"
depend() {
    need net
    after firewall
}
EOF
    chmod +x "/etc/init.d/$SVC_NAME"
    rc-update add "$SVC_NAME" default >/dev/null 2>&1
    restart_service
    ;;
  *)
    warn "未检测到 systemd/OpenRC, 改用 nohup 后台运行 + cron 开机自启"
    if command -v crontab >/dev/null 2>&1; then
      (crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/config.json"; \
       echo "@reboot $BIN run -c $INSTALL_DIR/config.json > $INSTALL_DIR/sing-box.log 2>&1 &") \
       | crontab -
    fi
    restart_service
    ;;
esac



# ---------- 安装管理脚本 sb (菜单: 添加/更改/查看/删除配置) ----------
info "安装管理脚本: /usr/local/bin/sb"
cat > /usr/local/bin/sb <<'SB_EOF'
#!/bin/sh
# sing-box 节点管理脚本 (sb)
# 菜单: 1) 添加配置 2) 更改配置 3) 查看配置 4) 删除配置 5) 运行管理 6) 版本更新 (更新内核/更新脚本) 7) 安装加速 (BBR/eBPF) 8) 卸载脚本
# 支持的协议 (7 种): VLESS Reality / Hysteria2 / TUIC / AnyTLS / Shadowsocks(aes-256-gcm/2022-blake3-aes-256-gcm) / Snell v6 / Direct(端口转发, TCP+UDP)
# 用法: sb (无参数出菜单)
set -e

INSTALL_DIR="/opt/sing-box-nodes"
CONF_DIR="$INSTALL_DIR/conf"
BIN="/usr/local/bin/sing-box"
SVC_NAME="sing-box-nodes"
SNI="www.amazon.com"
SB_VERSION="5.18"

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && die "请用 root 运行: sudo sb"
command -v jq >/dev/null 2>&1 || die "需要 jq, 请先运行 install.sh 安装"
[ -d "$CONF_DIR" ] || die "未找到配置目录 $CONF_DIR, 请先运行 install.sh 安装节点"

# ---------- 从终端读输入 ----------
read_tty() {
if [ -c /dev/tty ]; then
IFS= read -r "$1" < /dev/tty
else
IFS= read -r "$1"
fi
}

# ---------- 检测启动方式 ----------
INIT="none"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
INIT="systemd"
elif command -v rc-service >/dev/null 2>&1; then
INIT="openrc"
fi

# ---------- 节点地址 (从 info.txt 读, 读不到则自动检测) ----------
get_host() {
HOST=""
if [ -f "$INSTALL_DIR/info.txt" ]; then
HOST=$(grep '^地址:' "$INSTALL_DIR/info.txt" 2>/dev/null | head -1 | sed 's/^地址: *//')
fi
if [ -z "$HOST" ]; then
HOST=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
|| curl -fsS --max-time 10 https://api64.ipify.org 2>/dev/null \
|| true)
fi
[ -n "$HOST" ] || die "无法确定节点地址"
case "$HOST" in
*:*)
HOST_B="[$HOST]";;
*)
HOST_B="$HOST";;
esac
}

# ---------- 随机端口 / 端口占用 ----------
random_port() {
if command -v shuf >/dev/null 2>&1; then
shuf -i 10000-60000 -n 1
return
fi
n=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
[ -z "$n" ] && n=12345
echo $((10000 + n % 50001))
}

port_in_use() {
_p="$1"
if command -v ss >/dev/null 2>&1; then
ss -tln 2>/dev/null | grep -q ":${_p} " && return 0
ss -uln 2>/dev/null | grep -q ":${_p} " && return 0
return 1
fi
_hex=$(printf '%04X' "$_p")
grep -qi ":${_hex} " /proc/net/tcp /proc/net/udp 2>/dev/null && return 0
return 1
}

# 提示语走 stderr, 只有端口号走 stdout
ask_port() {
_name="$1"
while true; do
printf '请输入 %s 端口 (直接回车=随机): ' "$_name" >&2
read_tty _in
if [ -z "$_in" ]; then
_p=$(random_port)
_t=0
while port_in_use "$_p" && [ "$_t" -lt 20 ]; do
_p=$(random_port); _t=$((_t + 1))
done
echo " -> 随机端口: $_p" >&2
echo "$_p"
return
fi
case "$_in" in
*[!0-9]*) echo " 端口必须是数字" >&2; continue;;
esac
if [ "$_in" -lt 1 ] || [ "$_in" -gt 65535 ]; then
echo " 端口范围 1-65535" >&2; continue
fi
if port_in_use "$_in"; then
echo " 端口 $_in 已被占用" >&2; continue
fi
echo "$_in"
return
done
}

# ---------- 节点列表 ----------
node_count() {
_c=0
for _f in "$CONF_DIR"/*.json; do
[ -f "$_f" ] && _c=$((_c + 1))
done
echo "$_c"
}

node_tag_by_index() {
# $1=序号(从 1 起), 输出对应 tag
_i=0
for _f in "$CONF_DIR"/*.json; do
[ -f "$_f" ] || continue
_i=$((_i + 1))
if [ "$_i" = "$1" ]; then
basename "$_f" .json
return 0
fi
done
return 1
}

# ---------- 网络工具 (纯 IPv6 检测 / 域名解析校验 / GitHub 临时通道) ----------
have_ipv4() {
# 有 IPv4 出口返回 0 (两个端点任一通即可)
curl -4 -fsS --max-time 6 -o /dev/null https://api.ipify.org 2>/dev/null && return 0
curl -4 -fsS --max-time 6 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && return 0
return 1
}

check_domain_local() {
# $1=域名: 解析结果包含本机地址 ($HOST) 才算通过
[ "$1" = "$HOST" ] && return 0
_ips=$(getent hosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)
if [ -z "$_ips" ]; then
_ips=$( { curl -fsS --max-time 8 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null | jq -r '.Answer[]?.data'; curl -fsS --max-time 8 "https://dns.google/resolve?name=$1&type=AAAA" 2>/dev/null | jq -r '.Answer[]?.data'; } 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$' | sort -u)
fi
for _ip in $_ips; do
[ "$_ip" = "$HOST" ] && return 0
done
return 1
}

gh64_on() {
# 临时给 GitHub 域名写 NAT64 解析 (志愿者网关), 用完 gh64_off 清除
grep -q "# singbox-gh64 begin" /etc/hosts 2>/dev/null && return 0
{
echo "# singbox-gh64 begin"
echo "2a01:4f8:c010:d56::2 github.com"
echo "2a01:4f8:c010:d56::3 api.github.com"
echo "2a01:4f8:c010:d56::4 codeload.github.com"
echo "2a01:4f8:c010:d56::6 ghcr.io"
echo "2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com"
echo "2a01:4f8:c010:d56::8 uploads.github.com"
echo "2606:50c0:8000::133 objects.githubusercontent.com www.objects.githubusercontent.com release-assets.githubusercontent.com gist.githubusercontent.com repository-images.githubusercontent.com camo.githubusercontent.com private-user-images.githubusercontent.com avatars0.githubusercontent.com avatars1.githubusercontent.com avatars2.githubusercontent.com avatars3.githubusercontent.com cloud.githubusercontent.com desktop.githubusercontent.com support.github.com"
echo "2606:50c0:8000::154 support-assets.githubassets.com github.githubassets.com opengraph.githubassets.com github-registry-files.githubusercontent.com github-cloud.githubusercontent.com"
echo "# singbox-gh64 end"
} >> /etc/hosts
}

gh64_off() {
sed -i '/# singbox-gh64 begin/,/# singbox-gh64 end/d' /etc/hosts 2>/dev/null || true
}

usque_begin() {
# 从 GitHub 仓库拉 usque (raw 主源, 反代/jsDelivr 双栈兜底), 注册 WARP 并拉起临时 tun; 成功返回 0, 通道保持到 usque_end
UTMP=$(mktemp -d)
case "$(uname -m)" in
x86_64|amd64) _ua="amd64";;
aarch64|arm64) _ua="arm64";;
*) rm -rf "$UTMP"; return 1;;
esac
if ! curl -fsSL --max-time 90 -o "$UTMP/usque.gz" "https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/tools/usque-linux-$_ua.gz" \
&& ! curl -fsSL --max-time 90 -o "$UTMP/usque.gz" "https://sb.shabby.skin/tools/usque-linux-$_ua.gz" \
&& ! curl -fsSL --max-time 90 -o "$UTMP/usque.gz" "https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/tools/usque-linux-$_ua.gz"; then
rm -rf "$UTMP"; return 1
fi
gzip -dc "$UTMP/usque.gz" > "$UTMP/usque" 2>/dev/null && chmod +x "$UTMP/usque" || { rm -rf "$UTMP"; return 1; }
(cd "$UTMP" && ./usque register -a >/dev/null 2>&1) || { rm -rf "$UTMP"; return 1; }
(cd "$UTMP" && exec ./usque nativetun > usque.log 2>&1) &
UPID=$!
_i=0
while [ "$_i" -lt 10 ]; do
sleep 2
have_ipv4 && return 0
_i=$((_i + 1))
done
usque_end
return 1
}

usque_end() {
[ -n "$UPID" ] && kill "$UPID" 2>/dev/null
[ -n "$UTMP" ] && rm -rf "$UTMP"
UPID=""
UTMP=""
}

remove_v4exit() {
# 清理常驻 IPv4 出口 (路由 + usque 服务 + 二进制与配置), 卸载时调用
ip -4 route del default dev tun0 2>/dev/null || true
case "$INIT" in
systemd)
systemctl disable --now ipv42tun.service >/dev/null 2>&1 || true
systemctl disable --now usque.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/usque.service /etc/systemd/system/ipv42tun.service
systemctl daemon-reload 2>/dev/null || true
;;
openrc)
rc-service usque stop >/dev/null 2>&1 || true
rc-update del usque default >/dev/null 2>&1 || true
rm -f /etc/init.d/usque /etc/local.d/ipv42tun.start
;;
*)
pkill -f "usque.*nativetun" 2>/dev/null || true
;;
esac
rm -f /usr/local/bin/usque
rm -rf /usr/local/etc/usque
}

restart_service_wait() {
# 与 restart_service 相同, 但不 die: 等待服务稳定运行 (PID 连续两次不变) 后返回 0, 超时返回 1
# Naive 的 ACME 签发在启动阶段进行且耗时, 普通 sleep 2 判断不了
case "$INIT" in
systemd) systemctl restart "$SVC_NAME" 2>/dev/null || return 1;;
openrc) rc-service "$SVC_NAME" restart 2>/dev/null || return 1;;
*)
pkill -f "sing-box run -c $INSTALL_DIR/config.json" 2>/dev/null || true
sleep 1
nohup "$BIN" run -c "$INSTALL_DIR/config.json" > "$INSTALL_DIR/sing-box.log" 2>&1 &
;;
esac
_lastpid=""
_i=0
while [ "$_i" -lt 10 ]; do
sleep 3
if svc_is_active; then
case "$INIT" in
systemd) _pid=$(systemctl show -p MainPID --value "$SVC_NAME" 2>/dev/null);;
*) _pid=$(pgrep -f "sing-box run -c $INSTALL_DIR/config.json" | head -1);;
esac
if [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" = "$_lastpid" ]; then
return 0
fi
_lastpid="$_pid"
else
_lastpid=""
fi
_i=$((_i + 1))
done
return 1
}

proto_name() {
# $1=type, 输出中文协议名
case "$1" in
vless) echo "VLESS Reality";;
hysteria2) echo "Hysteria2";;
tuic) echo "TUIC";;
naive) echo "Naive";;
anytls) echo "AnyTLS";;
shadowsocks) echo "Shadowsocks";;
snell) echo "Snell v6";;
direct) echo "Direct";;
*) echo "$1";;
esac
}

list_nodes() {
_i=0
for _f in "$CONF_DIR"/*.json; do
[ -f "$_f" ] || continue
_i=$((_i + 1))
_tag=$(basename "$_f" .json)
_type=$(jq -r '.type' "$_f")
_port=$(jq -r '.listen_port' "$_f")
_pname=$(proto_name "$_type")
if [ "$_type" = "shadowsocks" ] && [ "$(jq -r '.method' "$_f")" = "2022-blake3-aes-256-gcm" ]; then
_pname="Shadowsocks 2022"
fi
printf ' %s) %s (%s, 端口 %s)\n' "$_i" "$_tag" "$_pname" "$_port"
done
}

# ---------- 合并碎片 -> config.json ----------
assemble_config() {
set -- "$CONF_DIR"/*.json
[ -f "$1" ] || die "conf/ 下没有任何节点碎片"
jq -s '{log: {level: "info", timestamp: true}, inbounds:., outbounds: [{type: "direct", tag: "direct"}], route: {final: "direct"}}' "$CONF_DIR"/*.json > "$INSTALL_DIR/config.json" \
|| die "合并配置失败"
"$BIN" check -c "$INSTALL_DIR/config.json" || die "配置校验失败"
}

# ---------- 服务启停 ----------
svc_is_active() {
case "$INIT" in
systemd) systemctl is-active --quiet "$SVC_NAME";;
openrc) rc-service "$SVC_NAME" status 2>/dev/null | grep -qi "started";;
*) pgrep -f "sing-box run -c $INSTALL_DIR/config.json" >/dev/null;;
esac
}

start_service() {
case "$INIT" in
systemd)
systemctl start "$SVC_NAME"
sleep 2
svc_is_active || die "启动失败"
;;
openrc)
rc-service "$SVC_NAME" start
sleep 2
svc_is_active || die "启动失败"
;;
*)
if svc_is_active; then
echo "服务已在运行"
return
fi
nohup "$BIN" run -c "$INSTALL_DIR/config.json" \
> "$INSTALL_DIR/sing-box.log" 2>&1 &
sleep 2
svc_is_active || die "后台启动失败, 见 $INSTALL_DIR/sing-box.log"
;;
esac
echo "服务已启动"
}

stop_service() {
case "$INIT" in
systemd)
systemctl stop "$SVC_NAME"
sleep 1
if svc_is_active; then die "停止失败"; else echo "服务已停止"; fi
;;
openrc)
rc-service "$SVC_NAME" stop
sleep 1
if svc_is_active; then die "停止失败"; else echo "服务已停止"; fi
;;
*)
pkill -f "sing-box run -c $INSTALL_DIR/config.json" 2>/dev/null || true
sleep 1
if svc_is_active; then die "停止失败"; else echo "服务已停止"; fi
;;
esac
}

restart_service() {
case "$INIT" in
systemd)
systemctl restart "$SVC_NAME"
sleep 2
svc_is_active || die "服务启动失败"
;;
openrc)
rc-service "$SVC_NAME" restart
sleep 2
svc_is_active || die "服务启动失败"
;;
*)
pkill -f "sing-box run -c $INSTALL_DIR/config.json" 2>/dev/null || true
sleep 1
nohup "$BIN" run -c "$INSTALL_DIR/config.json" \
> "$INSTALL_DIR/sing-box.log" 2>&1 &
sleep 2
svc_is_active || die "后台启动失败, 见 $INSTALL_DIR/sing-box.log"
;;
esac
}

# ---------- 写碎片 (每个协议一个函数, 参数: tag 端口 凭证...) ----------
write_frag_vless() {
# $1=tag $2=port $3=uuid $4=private_key $5=short_id
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "vless",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"users": [{ "uuid": "$3", "flow": "xtls-rprx-vision"}],
"tls": {
"enabled": true,
"server_name": "$SNI",
"reality": {
"enabled": true,
"handshake": { "server": "$SNI", "server_port": 443},
"private_key": "$4",
"short_id": ["$5" ]
}
}
}
EOF
}

write_frag_hy2() {
# $1=tag $2=port $3=password
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "hysteria2",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"users": [{ "password": "$3"}],
"tls": {
"enabled": true,
"server_name": "$SNI",
"certificate_path": "$INSTALL_DIR/cert.pem",
"key_path": "$INSTALL_DIR/cert.key"
}
}
EOF
}

write_frag_tuic() {
# $1=tag $2=port $3=uuid $4=password
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "tuic",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"users": [{ "uuid": "$3", "password": "$4"}],
"congestion_control": "bbr",
"tls": {
"enabled": true,
"server_name": "$SNI",
"alpn": ["h3" ],
"certificate_path": "$INSTALL_DIR/cert.pem",
"key_path": "$INSTALL_DIR/cert.key"
}
}
EOF
}

write_frag_anytls() {
# $1=tag $2=port $3=password
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "anytls",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"users": [{ "password": "$3"}],
"tls": {
"enabled": true,
"server_name": "$SNI",
"certificate_path": "$INSTALL_DIR/cert.pem",
"key_path": "$INSTALL_DIR/cert.key"
}
}
EOF
}

write_frag_ss() {
# $1=tag $2=port $3=password $4=method (aes-256-gcm 或 2022-blake3-aes-256-gcm)
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "shadowsocks",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"method": "$4",
"password": "$3"
}
EOF
}

write_frag_snell() {
# $1=tag $2=port $3=psk (v6 要求 psk 长度 12-255)
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "snell",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"version": 6,
"psk": "$3",
"mode": "default"
}
EOF
}

write_frag_naive() {
# $1=tag $2=port $3=username $4=password $5=domain (证书走 ACME 自动签发)
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "naive",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"users": [{ "username": "$3", "password": "$4" }],
"tls": {
"enabled": true,
"server_name": "$5",
"acme": {
"domain": ["$5"],
"data_directory": "$INSTALL_DIR/acme"
}
}
}
EOF
}

write_frag_direct() {
# $1=tag $2=port $3=目标地址 $4=目标端口 (network 留空=TCP+UDP 都监听)
cat > "$CONF_DIR/$1.json" <<EOF
{
"type": "direct",
"tag": "$1",
"listen": "::",
"listen_port": $2,
"override_address": "$3",
"override_port": $4
}
EOF
}

# ---------- jq 原子改碎片 ----------
# 用法: jq_set <碎片文件> <jq 参数...> <jq 表达式>, 例: jq_set f --argjson p 18448 '.listen_port = $p'
jq_set() {
_f="$1"; shift
jq "$@" "$_f" > "$_f.tmp" || { rm -f "$_f.tmp"; return 1; }
mv "$_f.tmp" "$_f"
}

# ---------- 打印单条节点链接 ----------
print_link() {
# $1=tag (碎片文件名去掉.json)
_f="$CONF_DIR/$1.json"
[ -f "$_f" ] || return
_type=$(jq -r '.type' "$_f")
_port=$(jq -r '.listen_port' "$_f")
case "$_type" in
vless)
_uuid=$(jq -r '.users[0].uuid' "$_f")
_sid=$(jq -r '.tls.reality.short_id[0]' "$_f")
_pub=""
[ -f "$CONF_DIR/$1.pub" ] && _pub=$(cat "$CONF_DIR/$1.pub")
[ -z "$_pub" ] && _pub=$(grep "^VLESS Reality:.*PublicKey: " "$INSTALL_DIR/info.txt" 2>/dev/null | sed 's/.*PublicKey: *//' | head -1)
[ -n "$_pub" ] || { echo "[$1] VLESS Reality: 缺少公钥 (请查看 info.txt)"; return; }
echo "vless://${_uuid}@${HOST_B}:${_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${_pub}&sid=${_sid}&type=tcp#$1"
;;
hysteria2)
_pass=$(jq -r '.users[0].password' "$_f")
echo "hysteria2://${_pass}@${HOST_B}:${_port}?insecure=1&sni=${SNI}#$1"
;;
tuic)
_uuid=$(jq -r '.users[0].uuid' "$_f")
_pass=$(jq -r '.users[0].password' "$_f")
echo "tuic://${_uuid}:${_pass}@${HOST_B}:${_port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}&allow_insecure=1#$1"
;;
anytls)
_pass=$(jq -r '.users[0].password' "$_f")
echo "anytls://${_pass}@${HOST_B}:${_port}?insecure=1&sni=${SNI}#$1"
;;
shadowsocks)
_method=$(jq -r '.method' "$_f")
_pass=$(jq -r '.password' "$_f")
_ui=$(printf '%s' "${_method}:$_pass" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
echo "ss://${_ui}@${HOST_B}:${_port}#$1"
;;
snell)
_psk=$(jq -r '.psk' "$_f")
echo "$1 = snell, ${HOST_B}, ${_port}, psk=${_psk}, version=6"
;;
naive)
_nuser=$(jq -r '.users[0].username' "$_f")
_pass=$(jq -r '.users[0].password' "$_f")
_ndomain=$(jq -r '.tls.server_name' "$_f")
echo "naive+https://${_nuser}:${_pass}@${_ndomain}:${_port}#$1"
;;
direct)
_oa=$(jq -r '.override_address' "$_f")
_op=$(jq -r '.override_port' "$_f")
echo "[$1] Direct 转发: [${HOST_B}]:${_port} -> ${_oa}:${_op} (TCP+UDP)"
;;
esac
}

# ---------- 打印单条节点的 sing-box 客户端 (outbound) 格式, 可直接贴入 SFM 等客户端配置 ----------
print_client_json() {
# $1=tag; Direct 是端口转发, 无客户端格式, 不打印
_f="$CONF_DIR/$1.json"
[ -f "$_f" ] || return
_type=$(jq -r '.type' "$_f")
_port=$(jq -r '.listen_port' "$_f")
case "$_type" in
vless)
_uuid=$(jq -r '.users[0].uuid' "$_f")
_sid=$(jq -r '.tls.reality.short_id[0]' "$_f")
_pub=""
[ -f "$CONF_DIR/$1.pub" ] && _pub=$(cat "$CONF_DIR/$1.pub")
[ -z "$_pub" ] && _pub=$(grep "^VLESS Reality:.*PublicKey: " "$INSTALL_DIR/info.txt" 2>/dev/null | sed 's/.*PublicKey: *//' | head -1)
[ -n "$_pub" ] || { echo "[$1] VLESS Reality: 缺少公钥, 无法生成客户端格式"; return; }
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg uuid "$_uuid" --arg sni "$SNI" --arg pub "$_pub" --arg sid "$_sid" \
'{tag: $tag, type: "vless", server: $server, server_port: $port, uuid: $uuid, packet_encoding: "xudp", flow: "xtls-rprx-vision", tls: {enabled: true, insecure: false, server_name: $sni, reality: {enabled: true, public_key: $pub, short_id: $sid}, utls: {enabled: true, fingerprint: "chrome"}}}' | sed 's/^/    /'
;;
hysteria2)
_pass=$(jq -r '.users[0].password' "$_f")
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg pass "$_pass" --arg sni "$SNI" \
'{tag: $tag, type: "hysteria2", server: $server, server_port: $port, password: $pass, tls: {enabled: true, server_name: $sni, insecure: true, alpn: ["h3"]}}' | sed 's/^/    /'
;;
tuic)
_uuid=$(jq -r '.users[0].uuid' "$_f")
_pass=$(jq -r '.users[0].password' "$_f")
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg uuid "$_uuid" --arg pass "$_pass" --arg sni "$SNI" \
'{tag: $tag, type: "tuic", server: $server, server_port: $port, uuid: $uuid, password: $pass, tls: {enabled: true, server_name: $sni, alpn: ["h3"], insecure: true}}' | sed 's/^/    /'
;;
anytls)
_pass=$(jq -r '.users[0].password' "$_f")
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg pass "$_pass" --arg sni "$SNI" \
'{tag: $tag, type: "anytls", server: $server, server_port: $port, password: $pass, tls: {enabled: true, server_name: $sni, insecure: true}}' | sed 's/^/    /'
;;
naive)
_nuser=$(jq -r '.users[0].username' "$_f")
_pass=$(jq -r '.users[0].password' "$_f")
_ndomain=$(jq -r '.tls.server_name' "$_f")
jq -n --arg tag "$1" --arg server "$_ndomain" --argjson port "$_port" --arg user "$_nuser" --arg pass "$_pass" --arg sni "$_ndomain" \
'{tag: $tag, type: "naive", server: $server, server_port: $port, username: $user, password: $pass, tls: {enabled: true, server_name: $sni}}' | sed 's/^/    /'
;;
shadowsocks)
_method=$(jq -r '.method' "$_f")
_pass=$(jq -r '.password' "$_f")
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg method "$_method" --arg pass "$_pass" \
'{tag: $tag, type: "shadowsocks", server: $server, server_port: $port, method: $method, password: $pass}' | sed 's/^/    /'
;;
snell)
_psk=$(jq -r '.psk' "$_f")
_mode=$(jq -r '.mode // "default"' "$_f")
jq -n --arg tag "$1" --arg server "$HOST" --argjson port "$_port" --arg psk "$_psk" --arg mode "$_mode" \
'{tag: $tag, type: "snell", server: $server, server_port: $port, version: 6, psk: $psk, mode: $mode}' | sed 's/^/    /'
;;
esac
}

print_all_links() {
# 按固定协议顺序打印全部节点, 排版与首次安装一致 (标签+空行+分隔线)
echo ""
echo "==================== 全部节点 ===================="
for _type in vless hysteria2 tuic naive anytls shadowsocks snell direct; do
for _f in "$CONF_DIR"/*.json; do
[ -f "$_f" ] || continue
[ "$(jq -r '.type' "$_f")" = "$_type" ] || continue
_tag=$(basename "$_f" .json)
echo ""
echo "$(proto_name "$_type"):"
print_link "$_tag"
done
done
echo ""
echo "=================================================="
}

# ---------- 更改用的小函数 ----------
change_port() {
# $1=碎片文件 $2=tag
NEWPORT=$(ask_port "新端口")
jq_set "$1" --argjson p "$NEWPORT" '.listen_port = $p' || die "修改失败"
echo "$2 端口改为 $NEWPORT" >> "$INSTALL_DIR/info.txt"
}

change_uuid() {
# $1=碎片文件 $2=tag
printf "请输入新 UUID (直接回车=自动生成): "
read_tty NEWUUID
[ -z "$NEWUUID" ] && NEWUUID=$(cat /proc/sys/kernel/random/uuid)
jq_set "$1" --arg u "$NEWUUID" '.users[0].uuid = $u' || die "修改失败"
echo "$2 UUID 改为 $NEWUUID" >> "$INSTALL_DIR/info.txt"
}

change_password() {
# $1=碎片文件 $2=tag $3=jq 路径 (.users[0].password 或.password) $4=生成方式 (可选: base64-32, SS 2022 专用)
printf "请输入新密码 (直接回车=自动生成): "
read_tty NEWPASS
if [ -z "$NEWPASS" ]; then
if [ "$4" = "base64-32" ]; then
NEWPASS=$(openssl rand -base64 32 | tr -d '\n')
else
NEWPASS=$(openssl rand -hex 12)
fi
elif [ "$4" = "base64-32" ]; then
# SS 2022 的密钥必须是 32 字节的 Base64, 手输不合法就不动配置
_klen=$(printf '%s' "$NEWPASS" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
if [ "$_klen" != "32" ]; then
echo "2022 密钥不合法: 必须是 32 字节密钥的 Base64 (44 字符), 已取消修改"
return
fi
fi
jq_set "$1" --arg pw "$NEWPASS" "$3 = \$pw" || die "修改失败"
echo "$2 密码改为 $NEWPASS" >> "$INSTALL_DIR/info.txt"
}

change_target_addr() {
# $1=碎片文件 $2=tag
printf "请输入新目标地址 (IP 或域名): "
read_tty NEWADDR
[ -n "$NEWADDR" ] || { echo "目标地址不能为空"; return; }
jq_set "$1" --arg a "$NEWADDR" '.override_address = $a' || die "修改失败"
echo "$2 目标地址改为 $NEWADDR" >> "$INSTALL_DIR/info.txt"
}

change_target_port() {
# $1=碎片文件 $2=tag
printf "请输入新目标端口: "
read_tty NEWTPORT
case "$NEWTPORT" in
*[!0-9]*|"") echo "目标端口无效"; return;;
esac
[ "$NEWTPORT" -ge 1 ] && [ "$NEWTPORT" -le 65535 ] || { echo "目标端口无效"; return; }
jq_set "$1" --argjson p "$NEWTPORT" '.override_port = $p' || die "修改失败"
echo "$2 目标端口改为 $NEWTPORT" >> "$INSTALL_DIR/info.txt"
}

# ---------- 1) 添加配置 ----------
do_add() {
get_host
echo ""
echo "请选择要添加的协议:"
echo " 1) TUIC"
echo " 2) Naive"
echo " 3) AnyTLS"
echo " 4) Snell v6"
echo " 5) Hysteria2"
echo " 6) Shadowsocks"
echo " 7) VLESS Reality"
echo " 8) Direct (端口转发)"
echo " 0) 返回"
printf "请选择 [0-8]: "
read_tty PICK
case "$PICK" in
1) PROTO="tuic"; BASE_TAG="tuic";;
2) PROTO="naive"; BASE_TAG="naive";;
3) PROTO="anytls"; BASE_TAG="anytls";;
4) PROTO="snell"; BASE_TAG="snell";;
5) PROTO="hy2"; BASE_TAG="hy2";;
6) PROTO="ss"; BASE_TAG="ss";;
7) PROTO="vless"; BASE_TAG="vless-reality";;
8) PROTO="direct"; BASE_TAG="direct";;
0) return;;
*) echo "无效选择"; return;;
esac

# Naive 先问域名并校验解析到本机 (顺序: 域名 -> 端口, Otis 定)
NDOMAIN=""
NAIVE_INFO=""
if [ "$PROTO" = "naive" ]; then
printf "请输入 Naive 域名 (需解析到本机, 证书将自动签发): "
read_tty NDOMAIN
[ -n "$NDOMAIN" ] || { echo "域名不能为空, 已取消"; return; }
echo "正在检测域名解析..."
if ! check_domain_local "$NDOMAIN"; then
echo "域名 $NDOMAIN 未解析到本机 ($HOST), 无法安装 Naive 协议"
echo "请先把该域名解析到本机地址, 再回来添加"
return
fi
echo "域名解析正常: $NDOMAIN"
echo "提示: 证书签发需要本机 80 端口可达 (Let's Encrypt 验证)"
fi

# 同协议已存在时, 新节点用 <协议>-<端口> 做 tag, 保证唯一
if [ -f "$CONF_DIR/$BASE_TAG.json" ]; then
echo "提示: 已存在 $BASE_TAG 节点, 将添加第二个同协议节点"
NEED_SUFFIX=1
else
NEED_SUFFIX=0
fi

case "$PROTO" in
vless) PORT=$(ask_port "VLESS Reality");;
hy2) PORT=$(ask_port "Hysteria2");;
tuic) PORT=$(ask_port "TUIC");;
anytls) PORT=$(ask_port "AnyTLS");;
naive) PORT=$(ask_port "Naive");;
ss) PORT=$(ask_port "Shadowsocks");;
snell) PORT=$(ask_port "Snell");;
direct) PORT=$(ask_port "Direct");;
esac

if [ "$NEED_SUFFIX" = "1" ]; then
TAG="$BASE_TAG-$PORT"
else
TAG="$BASE_TAG"
fi

case "$PROTO" in
vless)
UUID=$(cat /proc/sys/kernel/random/uuid)
KEYPAIR=$("$BIN" generate reality-keypair)
PRIV=$(printf '%s' "$KEYPAIR" | grep -i 'PrivateKey' | awk '{print $2}')
PUB=$(printf '%s' "$KEYPAIR" | grep -i 'PublicKey' | awk '{print $2}')
SID=$(openssl rand -hex 4)
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "Reality 密钥生成失败"
write_frag_vless "$TAG" "$PORT" "$UUID" "$PRIV" "$SID"
printf '%s' "$PUB" > "$CONF_DIR/$TAG.pub"
{
echo ""
echo "VLESS Reality: 端口 $PORT, UUID $UUID"
echo " PrivateKey: $PRIV"
echo " PublicKey: $PUB"
echo " ShortID: $SID"
} >> "$INSTALL_DIR/info.txt"
;;
hy2)
PASS=$(openssl rand -hex 12)
write_frag_hy2 "$TAG" "$PORT" "$PASS"
echo "Hysteria2: 端口 $PORT, 密码 $PASS" >> "$INSTALL_DIR/info.txt"
;;
tuic)
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(openssl rand -hex 12)
write_frag_tuic "$TAG" "$PORT" "$UUID" "$PASS"
echo "TUIC: 端口 $PORT, UUID $UUID, 密码 $PASS" >> "$INSTALL_DIR/info.txt"
;;
anytls)
PASS=$(openssl rand -hex 12)
write_frag_anytls "$TAG" "$PORT" "$PASS"
echo "AnyTLS: 端口 $PORT, 密码 $PASS" >> "$INSTALL_DIR/info.txt"
;;
ss)
printf "加密方式 (直接回车=aes-256-gcm, 输入任意字符=2022-blake3-aes-256-gcm): "
read_tty _method_in
if [ -z "$_method_in" ]; then
METHOD="aes-256-gcm"
PASS=$(openssl rand -hex 16)
else
METHOD="2022-blake3-aes-256-gcm"
PASS=$(openssl rand -base64 32 | tr -d '\n')
fi
write_frag_ss "$TAG" "$PORT" "$PASS" "$METHOD"
echo "Shadowsocks: 端口 $PORT, 方法 $METHOD, 密码 $PASS" >> "$INSTALL_DIR/info.txt"
;;
naive)
NUSER=$(openssl rand -hex 4)
PASS=$(openssl rand -hex 12)
write_frag_naive "$TAG" "$PORT" "$NUSER" "$PASS" "$NDOMAIN"
NAIVE_INFO="Naive: 端口 $PORT, 域名 $NDOMAIN, 用户名 $NUSER, 密码 $PASS"
;;
snell)
PASS=$(openssl rand -hex 16)
write_frag_snell "$TAG" "$PORT" "$PASS"
echo "Snell v6: 端口 $PORT, PSK $PASS" >> "$INSTALL_DIR/info.txt"
;;
direct)
printf "请输入目标地址 (IP 或域名): "
read_tty TADDR
[ -n "$TADDR" ] || die "目标地址不能为空"
printf "请输入目标端口: "
read_tty TPORT
case "$TPORT" in
*[!0-9]*|"") die "目标端口无效";;
esac
[ "$TPORT" -ge 1 ] && [ "$TPORT" -le 65535 ] || die "目标端口无效"
write_frag_direct "$TAG" "$PORT" "$TADDR" "$TPORT"
echo "Direct: 监听端口 $PORT -> $TADDR:$TPORT (TCP+UDP)" >> "$INSTALL_DIR/info.txt"
;;
esac

if [ "$PROTO" = "naive" ]; then
# Naive 的证书在服务启动时才向 Let's Encrypt 签发, 失败则回滚本次添加, 不留坏节点
# 注意: 进程存活不等于签发成功 (certmagic 失败时在后台重试, 进程不退出), 必须探到端口真能完成 TLS 握手才算成功
echo "正在启动服务并等待证书签发 (最长约 90 秒)..."
NAIVE_FAIL=""
if ! (assemble_config) || ! restart_service_wait; then
NAIVE_FAIL=1
else
_i=0
while [ "$_i" -lt 15 ]; do
curl -sk --max-time 4 -o /dev/null "https://127.0.0.1:$PORT/" 2>/dev/null && break
sleep 3
_i=$((_i + 1))
done
[ "$_i" -ge 15 ] && NAIVE_FAIL=1
fi
if [ -n "$NAIVE_FAIL" ]; then
echo ""
echo "Naive 节点启动失败, 已回滚本次添加 (原有节点不受影响)"
echo "常见原因: 域名未真正解析到本机 / 80 端口不可达 / Let's Encrypt 签发失败"
rm -f "$CONF_DIR/$TAG.json"
assemble_config
restart_service
return
fi
[ -n "$NAIVE_INFO" ] && echo "$NAIVE_INFO" >> "$INSTALL_DIR/info.txt"
else
assemble_config
restart_service
fi
echo ""
echo "==================== 添加完成 ===================="
print_link "$TAG"
if [ "$(jq -r '.type' "$CONF_DIR/$TAG.json")" != "direct" ]; then
echo ""
echo "sing-box 客户端格式:"
print_client_json "$TAG"
fi
echo "=================================================="
}

# ---------- 2) 更改配置 ----------
do_change() {
_n=$(node_count)
[ "$_n" -gt 0 ] || { echo "暂无节点"; return; }
echo ""
echo "请选择要更改的节点:"
list_nodes
echo " 0) 返回"
printf "请选择 [0-%s]: " "$_n"
read_tty PICK
case "$PICK" in
0) return;;
*[!0-9]*) echo "无效选择"; return;;
esac
[ "$PICK" -ge 1 ] && [ "$PICK" -le "$_n" ] || { echo "无效选择"; return; }
TAG=$(node_tag_by_index "$PICK") || { echo "无效选择"; return; }
_f="$CONF_DIR/$TAG.json"
_type=$(jq -r '.type' "$_f")
_port=$(jq -r '.listen_port' "$_f")
echo ""
echo "节点 $TAG ($(proto_name "$_type"), 端口 $_port), 请选择要更改的项:"
case "$_type" in
vless)
echo " 1) 端口"
echo " 2) UUID"
echo " 3) Reality 密钥 (重新生成)"
echo " 4) Short ID"
echo " 0) 返回"
printf "请选择 [0-4]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_uuid "$_f" "$TAG";;
3)
KEYPAIR=$("$BIN" generate reality-keypair)
PRIV=$(printf '%s' "$KEYPAIR" | grep -i 'PrivateKey' | awk '{print $2}')
PUB=$(printf '%s' "$KEYPAIR" | grep -i 'PublicKey' | awk '{print $2}')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "Reality 密钥生成失败"
jq_set "$_f" --arg k "$PRIV" '.tls.reality.private_key = $k' || die "修改失败"
printf '%s' "$PUB" > "$CONF_DIR/$TAG.pub"
{
echo ""
echo "$TAG Reality 密钥已重新生成"
echo " PrivateKey: $PRIV"
echo " PublicKey: $PUB"
} >> "$INSTALL_DIR/info.txt"
;;
4)
printf "请输入新 Short ID (直接回车=自动生成, 8 位 hex): "
read_tty NEWSID
[ -z "$NEWSID" ] && NEWSID=$(openssl rand -hex 4)
jq_set "$_f" --arg s "$NEWSID" '.tls.reality.short_id = [$s]' || die "修改失败"
echo "$TAG Short ID 改为 $NEWSID" >> "$INSTALL_DIR/info.txt"
;;
0) return;;
*) echo "无效选择"; return;;
esac
;;
hysteria2)
echo " 1) 端口"
echo " 2) 密码"
echo " 0) 返回"
printf "请选择 [0-2]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_password "$_f" "$TAG" ".users[0].password";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
tuic)
echo " 1) 端口"
echo " 2) UUID"
echo " 3) 密码"
echo " 0) 返回"
printf "请选择 [0-3]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_uuid "$_f" "$TAG";;
3) change_password "$_f" "$TAG" ".users[0].password";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
anytls)
echo " 1) 端口"
echo " 2) 密码"
echo " 0) 返回"
printf "请选择 [0-2]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_password "$_f" "$TAG" ".users[0].password";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
naive)
echo " 1) 端口"
echo " 2) 密码"
echo " 0) 返回"
printf "请选择 [0-2]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_password "$_f" "$TAG" ".users[0].password";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
shadowsocks)
echo " 1) 端口"
echo " 2) 密码"
echo " 0) 返回"
printf "请选择 [0-2]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2)
if [ "$(jq -r '.method' "$_f")" = "2022-blake3-aes-256-gcm" ]; then
change_password "$_f" "$TAG" ".password" "base64-32"
else
change_password "$_f" "$TAG" ".password"
fi
;;
0) return;;
*) echo "无效选择"; return;;
esac
;;
snell)
echo " 1) 端口"
echo " 2) PSK"
echo " 0) 返回"
printf "请选择 [0-2]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_password "$_f" "$TAG" ".psk";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
direct)
echo " 1) 端口"
echo " 2) 目标地址"
echo " 3) 目标端口"
echo " 0) 返回"
printf "请选择 [0-3]: "
read_tty FIELD
case "$FIELD" in
1) change_port "$_f" "$TAG";;
2) change_target_addr "$_f" "$TAG";;
3) change_target_port "$_f" "$TAG";;
0) return;;
*) echo "无效选择"; return;;
esac
;;
*)
echo "未知协议类型: $_type"; return;;
esac

assemble_config
restart_service
get_host
echo ""
echo "==================== 更改完成 ===================="
print_link "$TAG"
echo "=================================================="
}

# ---------- 3) 查看配置 ----------
do_view() {
get_host
_n=$(node_count)
[ "$_n" -gt 0 ] || { echo "暂无节点"; return; }
echo ""
echo "请选择要查看的节点:"
list_nodes
echo " a) 查看全部"
echo " 0) 返回"
printf "请选择 [0-%s / a]: " "$_n"
read_tty PICK
case "$PICK" in
0) return;;
a|A)
print_all_links
;;
*[!0-9]*) echo "无效选择"; return;;
*)
[ "$PICK" -ge 1 ] && [ "$PICK" -le "$_n" ] || { echo "无效选择"; return; }
TAG=$(node_tag_by_index "$PICK") || { echo "无效选择"; return; }
echo ""
print_link "$TAG"
if [ "$(jq -r '.type' "$CONF_DIR/$TAG.json")" != "direct" ]; then
echo ""
echo "sing-box 客户端格式:"
print_client_json "$TAG"
fi
;;
esac
}

# ---------- 4) 删除配置 ----------
do_del() {
_n=$(node_count)
[ "$_n" -gt 0 ] || { echo "暂无节点"; return; }
if [ "$_n" -le 1 ]; then
echo "只剩最后一个节点, 不能删除 (要清空请用 8) 卸载脚本)"
return
fi
echo ""
echo "请选择要删除的节点:"
list_nodes
echo " 0) 返回"
printf "请选择 [0-%s]: " "$_n"
read_tty PICK
case "$PICK" in
0) return;;
*[!0-9]*) echo "无效选择"; return;;
esac
[ "$PICK" -ge 1 ] && [ "$PICK" -le "$_n" ] || { echo "无效选择"; return; }
TAG=$(node_tag_by_index "$PICK") || { echo "无效选择"; return; }
_f="$CONF_DIR/$TAG.json"
_type=$(jq -r '.type' "$_f")
_port=$(jq -r '.listen_port' "$_f")
printf "确定删除 %s (%s, 端口 %s) 吗? [y/N]: " "$TAG" "$(proto_name "$_type")" "$_port"
read_tty CONFIRM
case "$CONFIRM" in
y|Y);;
*) echo "已取消"; return;;
esac
rm -f "$_f" "$CONF_DIR/$TAG.pub"
echo "$TAG ($(proto_name "$_type"), 端口 $_port) 已删除" >> "$INSTALL_DIR/info.txt"
assemble_config
restart_service
echo "已删除 $TAG"
}

# ---------- 5) 启动/停止/重启 ----------
do_manage() {
echo ""
echo "请选择操作:"
echo " 1) 启动"
echo " 2) 停止"
echo " 3) 重启"
echo " 0) 返回"
printf "请选择 [0-3]: "
read_tty ACT
case "$ACT" in
1) start_service;;
2) stop_service;;
3) restart_service; echo "服务已重启";;
0) return;;
*) echo "无效选择"; return;;
esac
}

# ---------- 6) 更新 (二级菜单) ----------
do_update_menu() {
  echo ""
  echo "请选择操作:"
  echo "  1) 更新内核"
  echo "  2) 更新脚本"
  echo "  0) 返回"
  printf "请选择 [0-2]: "
  read_tty UACT
  case "$UACT" in
    1) do_update_core ;;
    2) do_update_script ;;
    0) return ;;
    *) echo "无效选择"; return ;;
  esac
}

do_update_script() {
  echo "正在下载最新版 install.sh..."
  TMPDL=$(mktemp)
  if ! curl -fsSL --max-time 30 -o "$TMPDL" "https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/install.sh" \
  && ! curl -fsSL --max-time 30 -o "$TMPDL" "https://sb.shabby.skin/install.sh" \
  && ! curl -fsSL --max-time 30 -o "$TMPDL" "https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/install.sh"; then
    rm -f "$TMPDL"
    echo "下载失败, 请检查网络"
    return
  fi
  _dl="SB_EO""F"
  _s=$(grep -nFx "cat > /usr/local/bin/sb <<'$_dl'" "$TMPDL" | head -1 | cut -d: -f1)
  _e=$(grep -nFx "$_dl" "$TMPDL" | head -1 | cut -d: -f1)
  if [ -z "$_s" ] || [ -z "$_e" ] || [ "$_e" -le "$_s" ]; then echo "提取 sb 失败"; rm -f "$TMPDL"; return; fi
  sed -n "$((_s+1)),$((_e-1))p" "$TMPDL" > /tmp/sb.new
  rm -f "$TMPDL"
  [ -s /tmp/sb.new ] || { echo "提取 sb 失败"; rm -f /tmp/sb.new; return; }
  sh -n /tmp/sb.new || { echo "新版 sb 语法校验失败, 已保留旧版"; rm -f /tmp/sb.new; return; }
  cp -f /tmp/sb.new /usr/local/bin/sb
  chmod +x /usr/local/bin/sb
  ln -sf /usr/local/bin/sb /usr/local/bin/sing-box-nodes 2>/dev/null || true
  rm -f /tmp/sb.new
  echo "脚本已更新到最新版, 正在重新进入菜单..."
  exec /usr/local/bin/sb
}

# ---------- 6) 更新内核 ----------
get_core_version() {
"$BIN" version 2>/dev/null | head -n1 | awk '{print $3}' | sed 's/^v//'
}

do_update_core() {
CUR_VER=$(get_core_version)
[ -n "$CUR_VER" ] || CUR_VER="(未知)"
echo ""
echo "当前内核版本: v$CUR_VER"
printf "是否更新内核? [Y/n] (回车默认更新): "
read_tty ANS
case "$ANS" in
n|N) echo "已退出"; exit 0;;
esac
# 精简版核心主源为 GitHub 仓库 (core/ 目录), sb.shabby.skin 反代与 jsDelivr 为双栈兜底; 版本以仓库清单为准
LATEST=$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/core/latest.txt" 2>/dev/null | tr -d ' \r\n')
[ -n "$LATEST" ] || LATEST=$(curl -fsSL --max-time 15 "https://sb.shabby.skin/core/latest.txt" 2>/dev/null | tr -d ' \r\n')
[ -n "$LATEST" ] || LATEST=$(curl -fsSL --max-time 15 "https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/core/latest.txt" 2>/dev/null | tr -d ' \r\n')
[ -n "$LATEST" ] || die "获取精简版最新版本失败"
echo "精简版最新版本: v$LATEST"
if [ "$LATEST" = "$CUR_VER" ]; then
echo "已是最新版本, 无需更新"
return
fi
case $(uname -m) in
x86_64|amd64) ARCH="amd64";;
aarch64|arm64|armv8*) ARCH="arm64";;
*) die "不支持的架构: $(uname -m)";;
esac
TMPD=$(mktemp -d)
NEWBIN="$TMPD/sing-box"
SLIM_OK=""
for URL in "https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/core/v$LATEST/sing-box-linux-$ARCH.gz" "https://sb.shabby.skin/core/v$LATEST/sing-box-linux-$ARCH.gz" "https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/core/v$LATEST/sing-box-linux-$ARCH.gz"; do
echo "下载精简版核心: $URL"
if curl -fsSL --max-time 120 -o "$TMPD/sb.gz" "$URL" \
&& curl -fsSL --max-time 30 -o "$TMPD/sb.sha256" "$URL.sha256" \
&& [ "$(sha256sum "$TMPD/sb.gz" | awk '{print $1}')" = "$(awk '{print $1}' "$TMPD/sb.sha256")" ] \
&& gzip -dc "$TMPD/sb.gz" > "$NEWBIN" 2>/dev/null; then
chmod +x "$NEWBIN"
SLIM_OK=1
break
fi
rm -f "$TMPD/sb.gz" "$TMPD/sb.sha256"
done
if [ -z "$SLIM_OK" ]; then
echo "精简版下载失败, 回退 GitHub 官方版..."
TARBALL="$TMPD/sing-box.tar.gz"
GHURL="https://github.com/SagerNet/sing-box/releases/download/v$LATEST/sing-box-$LATEST-linux-$ARCH.tar.gz"
if ! curl -fsSL --max-time 120 -o "$TARBALL" "$GHURL"; then
echo "GitHub 直连失败, 尝试 gh-proxy 镜像..."
curl -fsSL --max-time 180 -o "$TARBALL" "https://gh-proxy.com/$GHURL" \
|| { rm -rf "$TMPD"; die "下载失败, 已保留旧内核"; }
fi
tar -xzf "$TARBALL" -C "$TMPD" || { rm -rf "$TMPD"; die "解压失败, 已保留旧内核"; }
NEWBIN=$(find "$TMPD" -name "sing-box" -type f | head -1)
[ -n "$NEWBIN" ] || { rm -rf "$TMPD"; die "未找到新内核文件, 已保留旧内核"; }
fi
# 先验新内核能跑、配置能过, 再替换
"$NEWBIN" version >/dev/null 2>&1 || { rm -rf "$TMPD"; die "新内核无法运行, 已保留旧内核"; }
"$NEWBIN" check -c "$INSTALL_DIR/config.json" || { rm -rf "$TMPD"; die "新内核校验配置失败, 已保留旧内核"; }
cp -f "$NEWBIN" "$BIN"
chmod +x "$BIN"
rm -rf "$TMPD"
restart_service
NEW_VER=$(get_core_version)
echo "内核已更新到 v$NEW_VER"
}

# ---------- 7) 安装加速 ----------
do_accel_menu() {
  echo ""
  echo "请选择加速:"
  echo "  1) BBR"
  echo "  2) eBPF"
  echo "  0) 返回"
  printf "请选择 [0-2]: "
  read_tty AACT
  case "$AACT" in
    1) do_accel_bbr ;;
    2) do_accel_skyline ;;
    0) return ;;
    *) echo "无效选择"; return ;;
  esac
}

do_accel_bbr() {
  echo "正在安装 BBR + FQ_PIE 加速..."
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    echo "BBR 已启用, 当前拥塞控制: bbr, 默认队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    return
  fi
  if ! modprobe tcp_bbr 2>/dev/null; then
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      echo "本台机器不适合安装 BBR: 内核不支持 BBR (需要 Linux 4.9+ 且开启 BBR)"
      return
    fi
  fi
  _qdisc="fq_pie"
  if ! modprobe sch_fq_pie 2>/dev/null; then
    _qdisc="fq"
    if ! modprobe sch_fq 2>/dev/null; then
      _qdisc="fq_codel"
    fi
  fi
  echo "使用队列: $_qdisc"
  mkdir -p /etc/sysctl.d 2>/dev/null || true
  printf "net.core.default_qdisc=%s\nnet.ipv4.tcp_congestion_control=bbr\n" "$_qdisc" > /etc/sysctl.d/99-singbox-bbr.conf
  if ! sysctl -p /etc/sysctl.d/99-singbox-bbr.conf 2>/dev/null; then
    rm -f /etc/sysctl.d/99-singbox-bbr.conf
    echo "本台机器不适合安装 BBR: 无法修改系统参数 (容器内内核参数由宿主机控制)"
    return
  fi
  _cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  _qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  if [ "$_cc" = "bbr" ]; then
    echo "BBR 已启用, 当前拥塞控制: $_cc, 默认队列: $_qd"
  else
    echo "BBR 启用失败, 当前拥塞控制: $_cc (本台机器可能不适合)"
  fi
}

do_accel_skyline() {
  echo "正在安装 Skyline 加速..."
  echo "提示: 源码编译约需 5-10 分钟, 请耐心等待。"
  if [ -x /usr/local/sbin/skyline-speederd ]; then
    echo "Skyline 已安装 ($(skyline-speederd --version 2>/dev/null | awk '{print $2}'))"
    return
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "本台机器不适合安装 Skyline: 缺少 curl/wget"
    return
  fi
  _skyline_ok() { [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "skyline_cc" ]; }
  if have_ipv4; then
    _skyline_dl
  else
    # 纯 IPv6: GitHub 无 AAAA, 先走 NAT64 临时解析, 不通再开 usque 临时 WARP 通道
    echo "检测到纯 IPv6 网络, 先用 NAT64 通道拉取 GitHub..."
    gh64_on
    _skyline_dl
    gh64_off
    if ! _skyline_ok; then
      echo "NAT64 通道未成功, 改用临时 WARP (usque) 通道重试..."
      if usque_begin; then
        _skyline_dl
        usque_end
      else
        echo "usque 临时通道建立失败"
      fi
    fi
  fi
  if _skyline_ok; then
    echo "Skyline 安装成功, 当前拥塞控制: skyline_cc"
  else
    echo "Skyline 未启用 (本台机器可能不适合, 详见 /var/log/skyline-speeder-install.log)"
  fi
}

_skyline_dl() {
  if command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh | SKYLINE_FEEDBACK=no bash
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh | SKYLINE_FEEDBACK=no sh
  fi
}

# ---------- 8) 卸载脚本 ----------
do_uninstall() {
echo ""
echo "卸载将删除: 服务、sing-box 二进制、/opt/sing-box-nodes (含全部节点配置与证书)、sb 管理命令，以及已安装的加速 (BBR / Skyline)。"
printf "确定卸载吗? [y/N] (回车默认不卸载): "
read_tty ANS
case "$ANS" in
y|Y);;
*) echo "已取消"; return;;
esac
# ---------- 清理加速 (Skyline 先, 再 BBR, 最后拥塞控制回到 cubic) ----------
if [ -x /usr/local/sbin/skyline-speederd ] || [ -d /usr/local/src/skyline-speeder ]; then
  if [ -x /usr/local/src/skyline-speeder/install.sh ]; then
    SKYLINE_FEEDBACK=no /usr/local/src/skyline-speeder/install.sh --uninstall 2>/dev/null || true
  elif command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh | SKYLINE_FEEDBACK=no bash -s -- --uninstall 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh | SKYLINE_FEEDBACK=no sh -s -- --uninstall 2>/dev/null || true
  fi
  echo "已清理 Skyline 加速"
fi
if [ -f /etc/sysctl.d/99-singbox-bbr.conf ]; then
  rm -f /etc/sysctl.d/99-singbox-bbr.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
  sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null || true
  echo "已清理 BBR 加速"
fi
if [ -x /usr/local/bin/usque ] || [ -f /etc/systemd/system/usque.service ] || [ -f /etc/init.d/usque ]; then
  remove_v4exit
  echo "已清理 IPv4 出口 (usque)"
fi
case "$INIT" in
systemd)
systemctl stop "$SVC_NAME" 2>/dev/null || true
systemctl disable "$SVC_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/${SVC_NAME}.service"
systemctl daemon-reload 2>/dev/null || true
;;
openrc)
rc-service "$SVC_NAME" stop 2>/dev/null || true
rc-update del "$SVC_NAME" default 2>/dev/null || true
rm -f "/etc/init.d/$SVC_NAME"
;;
*)
pkill -f "sing-box run -c $INSTALL_DIR/config.json" 2>/dev/null || true
if command -v crontab >/dev/null 2>&1; then
crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/config.json" | crontab - 2>/dev/null || true
fi
;;
esac
rm -f "$BIN"
rm -rf "$INSTALL_DIR"
rm -f /usr/local/bin/sb /usr/local/bin/sing-box-nodes
echo "已卸载"
exit 0
}

# ---------- 菜单 ----------
show_menu() {
echo ""
echo "========== 自用 sing-box 脚本 v$SB_VERSION =========="
  _ver=$(get_core_version)
  [ -n "$_ver" ] || _ver="(未知)"
  echo "当前版本:  sing-box $_ver"
  if svc_is_active; then
    printf "运行状态:  \033[32mrunning\033[0m\n"
  else
    printf "运行状态:  \033[31mstopping\033[0m\n"
  fi
  echo ""
echo " 1) 添加配置"
echo " 2) 更改配置"
echo " 3) 查看配置"
echo " 4) 删除配置"
echo " 5) 运行管理"
echo " 6) 版本更新"
echo " 7) 安装加速"
echo " 8) 卸载脚本"
echo "======================================"
printf "请选择 [1-8]: "
read_tty CHOICE
case "$CHOICE" in
1) do_add;;
2) do_change;;
3) do_view;;
4) do_del;;
5) do_manage;;
6) do_update_menu;;
7) do_accel_menu;;
8) do_uninstall;;
*) echo "无效选择";;
esac
}

show_menu
SB_EOF
chmod +x /usr/local/bin/sb
ln -sf /usr/local/bin/sb /usr/local/bin/sing-box-nodes 2>/dev/null || true

# ---------- 保存凭证备份 ----------
{
  echo "sing-box $SINGBOX_VERSION 节点 (生成于 $(date '+%Y-%m-%d %H:%M:%S'))"
  echo "地址: $HOST"
  echo "SNI: $SNI"
  echo ""
  echo "VLESS Reality: 端口 $PORT_VLESS, UUID $UUID_VLESS"
  echo "  PrivateKey: $PRIVATE_KEY"
  echo "  PublicKey: $PUBLIC_KEY"
  echo "  ShortID: $SHORT_ID"
  echo ""
  echo "配置: $INSTALL_DIR/config.json"
  echo "证书: $INSTALL_DIR/cert.pem / $INSTALL_DIR/cert.key (菜单后加 Hy2/TUIC/AnyTLS 时用)"
} > "$INSTALL_DIR/info.txt"
chmod 600 "$INSTALL_DIR/info.txt"

# ---------- 打印节点链接 ----------
echo ""
echo "==================== 搭建完成 ===================="
echo "VLESS Reality:"
echo "vless://${UUID_VLESS}@${HOST_B}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-Reality"
echo ""
echo "sing-box 客户端格式:"
jq -n --arg server "$HOST" --argjson port "$PORT_VLESS" --arg uuid "$UUID_VLESS" --arg sni "$SNI" --arg pub "$PUBLIC_KEY" --arg sid "$SHORT_ID" \
'{tag: "vless-reality", type: "vless", server: $server, server_port: $port, uuid: $uuid, packet_encoding: "xudp", flow: "xtls-rprx-vision", tls: {enabled: true, insecure: false, server_name: $sni, reality: {enabled: true, public_key: $pub, short_id: $sid}, utls: {enabled: true, fingerprint: "chrome"}}}' | sed 's/^/    /'
echo ""
echo "如需其他协议, 进管理菜单 1) 添加配置 (sb)"
echo "凭证已保存到: $INSTALL_DIR/info.txt"
echo "=================================================="
