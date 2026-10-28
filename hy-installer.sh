#!/usr/bin/env bash
# =========================================================
#  Hysteria 2 一键极速安装与管理脚本 (生产优化版)
#  - 支持 Certbot 自动停启 Web 服务释放 80 端口
#  - 支持 Hysteria 2 内置 ACME 独立申请与热更新
#  - 支持 UDP 端口跳跃 (Port Hopping / mport)
#  - 支持 Salamander 协议特征混淆 (Obfs)
#  - 强制 ignoreClientBandwidth + BBR 防 QoS 调优
# =========================================================

set -e

# 必须 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo -i 后再运行)"
  exit 1
fi

echo "========================================================="
echo "           Hysteria 2 自动化部署向导"
echo "========================================================="

# ----------------- 1. 环境检测 -----------------
echo "=== [1/5] 系统硬件与环境检测 ==="
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "❌ 错误: 当前脚本仅支持 x86_64 (amd64) 架构，当前系统架构为: $ARCH"
  exit 1
fi

CPU_CORES=$(nproc)
TOTAL_MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
FREE_MEM_MB=$(free -m | awk '/Mem:/ {print $4}')
echo "硬件规格: CPU 核心数 = $CPU_CORES, 总内存 = ${TOTAL_MEM_MB}MB, 空闲内存 = ${FREE_MEM_MB}MB"

# ----------------- 2. 用户交互配置 -----------------
echo ""
read -p "请输入绑定的 Hysteria 域名 (例如 hy.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "❌ 域名不能为空！"
  exit 1
fi

echo ""
echo "--------------------------------------------------------"
echo "【选项 1: TLS 证书申请与管理模式】"
echo "  1) Certbot 自动管理 (推荐: 续期时自动停启 Nginx/Apache 释放 80 端口，全自动化)"
echo "  2) Hysteria 2 内置 ACME (适合无 Web 服务的机器，80 端口须长期空闲)"
echo "  3) 手动指定现有证书路径 (已有本地证书文件)"
echo "--------------------------------------------------------"
read -p "请输入证书选项 [1-3，默认 1]: " CERT_MODE
CERT_MODE=${CERT_MODE:-1}

TLS_CONFIG_BLOCK=""
if [ "$CERT_MODE" == "1" ]; then
  read -p "请输入接收证书通知的邮箱 (例如 admin@example.com): " ACME_EMAIL
  if [ -z "$ACME_EMAIL" ]; then
    echo "❌ 邮箱不能为空！"
    exit 1
  fi

  echo "正在安装 Certbot 依赖组件..."
  apt-get update -y && apt-get install -y certbot 2>/dev/null || yum install -y epel-release certbot 2>/dev/null || true

  CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

  echo "正在申请 Let's Encrypt 证书并绑定自动停启服务钩子..."
  certbot certonly --standalone -d "$DOMAIN" -m "$ACME_EMAIL" --agree-tos -n \
    --pre-hook "systemctl stop nginx apache2 httpd caddy 2>/dev/null || true" \
    --post-hook "systemctl start nginx apache2 httpd caddy 2>/dev/null || true; systemctl try-restart hysteria-server 2>/dev/null || true"

  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ Certbot 申请证书失败，未生成证书文件。请确认 80 端口畅通且域名 DNS 已解析到本机！"
    exit 1
  fi

  TLS_CONFIG_BLOCK=$(cat << CERTBOT_EOF
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
  sniGuard: dns-san
CERTBOT_EOF
)
elif [ "$CERT_MODE" == "2" ]; then
  read -p "请输入接收证书通知的邮箱 (例如 admin@example.com): " ACME_EMAIL
  if [ -z "$ACME_EMAIL" ]; then
    echo "❌ 邮箱不能为空！"
    exit 1
  fi

  # Hysteria 2 官方规范: acme 必须为顶层配置，不能写在 tls 内部
  TLS_CONFIG_BLOCK=$(cat << ACME_EOF
acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
ACME_EOF
)
else
  DEFAULT_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  DEFAULT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  read -p "请输入证书完整路径 [默认: $DEFAULT_CERT]: " CERT_FILE
  CERT_FILE=${CERT_FILE:-$DEFAULT_CERT}
  read -p "请输入私钥完整路径 [默认: $DEFAULT_KEY]: " KEY_FILE
  KEY_FILE=${KEY_FILE:-$DEFAULT_KEY}

  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ 错误: 未找到指定的证书或私钥文件！"
    exit 1
  fi

  TLS_CONFIG_BLOCK=$(cat << MANUAL_EOF
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
  sniGuard: dns-san
MANUAL_EOF
)
fi

echo ""
read -p "请输入连接密码 (留空则随机生成): " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(openssl rand -hex 12)
  echo "已生成随机密码: $PASSWORD"
fi

# 选项 2: 端口跳跃
echo ""
echo "--------------------------------------------------------"
echo "【选项 2: UDP 端口跳跃 (Port Hopping)】"
echo "说明: 将一段 UDP 端口重定向至 443，可有效抵抗单端口长连接 QoS 封锁。"
echo "--------------------------------------------------------"
read -p "是否开启端口跳跃？[y/N，默认 N]: " ENABLE_HOPPING
ENABLE_HOPPING=${ENABLE_HOPPING:-n}

PORT_RANGE=""
if [[ "$ENABLE_HOPPING" =~ ^[Yy]$ ]]; then
  read -p "请输入 UDP 端口范围 [默认 20000:40000]: " USER_RANGE
  USER_RANGE=${USER_RANGE:-"20000:40000"}
  PORT_RANGE=$(echo "$USER_RANGE" | tr '-' ':')
  echo "✅ 端口跳跃已启用: $PORT_RANGE -> 443"
fi

# 选项 3: 混淆
echo ""
echo "--------------------------------------------------------"
echo "【选项 3: Salamander 协议混淆 (Obfs)】"
echo "说明: 将 QUIC 数据包头部转为无序随机密文，抵御特定运营商的 QUIC 阻断。"
echo "--------------------------------------------------------"
read -p "是否开启 Salamander 混淆？[y/N，默认 N]: " ENABLE_OBFS
ENABLE_OBFS=${ENABLE_OBFS:-n}

OBFS_CONFIG_BLOCK=""
OBFS_PASSWORD=""
if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
  read -p "请输入混淆密码 (留空则随机生成): " OBFS_PASSWORD
  if [ -z "$OBFS_PASSWORD" ]; then
    OBFS_PASSWORD=$(openssl rand -hex 8)
    echo "已生成混淆密码: $OBFS_PASSWORD"
  fi
  OBFS_CONFIG_BLOCK=$(cat << OBFS_EOF

obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASSWORD"
OBFS_EOF
)
  echo "✅ Salamander 混淆已启用！"
fi

# ----------------- 3. 下载与安装 -----------------
echo ""
echo "=== [2/5] 下载安装 Hysteria 2 内核 ==="
apt-get update -y && apt-get install -y iptables ethtool curl 2>/dev/null || yum install -y iptables ethtool curl 2>/dev/null || true

if grep -q avx /proc/cpuinfo; then
  BIN_NAME="hysteria-linux-amd64-avx"
  echo "✅ 检测到 AVX 指令集，下载 AVX 增强版..."
else
  BIN_NAME="hysteria-linux-amd64"
  echo "ℹ️ CPU 不支持 AVX，下载标准版..."
fi

curl -fL -o /usr/local/bin/hysteria.tmp "https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
chmod +x /usr/local/bin/hysteria.tmp
mv -f /usr/local/bin/hysteria.tmp /usr/local/bin/hysteria

mkdir -p /etc/hysteria

# ----------------- 4. 写入服务端配置 -----------------
echo "=== [3/5] 写入服务端配置 ==="
cat << CONFIGEOF > /etc/hysteria/config.yaml
listen: :443

$TLS_CONFIG_BLOCK

auth:
  type: password
  password: "$PASSWORD"
$OBFS_CONFIG_BLOCK

ignoreClientBandwidth: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 2048
  disablePathMTUDiscovery: false

congestion:
  type: bbr
  bbrProfile: standard

outbounds:
  - name: direct_v4
    type: direct
    direct:
      mode: 4
      fastOpen: true

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
CONFIGEOF
chmod 600 /etc/hysteria/config.yaml

# ----------------- 5. 内核网络调优与端口转发规则 -----------------
echo "=== [4/5] 应用网络性能调优与防火墙规则 ==="
cat << 'SYSEOF' > /etc/sysctl.d/99-hysteria-tuned.conf
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.netdev_max_backlog = 500000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.optmem_max = 65536
SYSEOF
sysctl --system >/dev/null 2>&1 || true

NIC=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [ -n "$NIC" ]; then
  ethtool -K "$NIC" gro on gso on tso on 2>/dev/null || true
  ethtool -K "$NIC" tx-udp-segmentation on 2>/dev/null || true
fi

cat << 'RULEROOT' > /etc/hysteria/apply-rules.sh
#!/bin/bash
setup_rules() {
  local range="$1"
  [ -z "$range" ] && exit 0

  iptables -t nat -D PREROUTING -j HYSTERIA_HOPPING 2>/dev/null || true
  iptables -t nat -F HYSTERIA_HOPPING 2>/dev/null || true
  iptables -t nat -X HYSTERIA_HOPPING 2>/dev/null || true

  iptables -t nat -N HYSTERIA_HOPPING
  iptables -t nat -A HYSTERIA_HOPPING -p udp --dport "$range" -j REDIRECT --to-ports 443
  iptables -t nat -A PREROUTING -j HYSTERIA_HOPPING

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -D PREROUTING -j HYSTERIA_HOPPING 2>/dev/null || true
    ip6tables -t nat -F HYSTERIA_HOPPING 2>/dev/null || true
    ip6tables -t nat -X HYSTERIA_HOPPING 2>/dev/null || true
    ip6tables -t nat -N HYSTERIA_HOPPING 2>/dev/null || true
    ip6tables -t nat -A HYSTERIA_HOPPING -p udp --dport "$range" -j REDIRECT --to-ports 443 2>/dev/null || true
    ip6tables -t nat -A PREROUTING -j HYSTERIA_HOPPING 2>/dev/null || true
  fi
}
RULEROOT

echo "PORT_HOPPING_RANGE=\"$PORT_RANGE\"" > /etc/hysteria/hopping.env
echo 'setup_rules "$PORT_HOPPING_RANGE"' >> /etc/hysteria/apply-rules.sh
chmod +x /etc/hysteria/apply-rules.sh
/etc/hysteria/apply-rules.sh

# ----------------- 6. 注册 Systemd 并严格检验存活 -----------------
echo "=== [5/5] 配置守护进程并启动服务 ==="
cat << 'SERVICEEOF' > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Nice=-10
LimitNOFILE=1048576
ExecStartPre=-/etc/hysteria/apply-rules.sh
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 进程存活检查
sleep 2
if ! systemctl is-active --quiet hysteria-server; then
  echo "❌ 启动失败！以下为最新 15 行错误日志："
  journalctl -u hysteria-server --no-pager -n 15
  exit 1
fi

# ----------------- 7. 生成全局管理命令 hy -----------------
cat << 'HYEOF' > /usr/local/bin/hy
#!/usr/bin/env bash
get_domain() {
    local d=$(grep -A 2 "^acme:" /etc/hysteria/config.yaml 2>/dev/null | grep "-" | awk '{print $2}' | tr -d ' ')
    if [ -z "$d" ]; then
      d=$(grep "cert:" /etc/hysteria/config.yaml 2>/dev/null | awk -F'/' '{print $5}')
    fi
    echo "$d"
}
get_pass() {
    grep -A 2 "^auth:" /etc/hysteria/config.yaml 2>/dev/null | grep "password:" | head -n 1 | awk -F'"' '{print $2}'
}
get_obfs_pass() {
    grep -A 4 "^obfs:" /etc/hysteria/config.yaml 2>/dev/null | grep "password:" | head -n 1 | awk -F'"' '{print $2}'
}
get_hop_range() {
    if [ -f /etc/hysteria/hopping.env ]; then
      source /etc/hysteria/hopping.env
      echo "$PORT_HOPPING_RANGE"
    fi
}

case "$1" in
    start)
        /etc/hysteria/apply-rules.sh
        systemctl start hysteria-server
        echo "✅ Hysteria 服务已启动"
        ;;
    stop)
        systemctl stop hysteria-server
        echo "⏹️ Hysteria 服务已停止"
        ;;
    restart)
        /etc/hysteria/apply-rules.sh
        systemctl restart hysteria-server
        echo "🔄 Hysteria 服务已重启"
        ;;
    status)
        systemctl status hysteria-server --no-pager
        ;;
    logs)
        journalctl -u hysteria-server -f
        ;;
    server)
        echo "=== 服务端完整配置文件 (/etc/hysteria/config.yaml) ==="
        cat /etc/hysteria/config.yaml
        ;;
    client)
        DOMAIN=$(get_domain)
        PASS=$(get_pass)
        OBFS_PASS=$(get_obfs_pass)
        HOP_RANGE=$(get_hop_range)

        MPORT_PARAM=""
        MPORT_YAML="443"
        if [ -n "$HOP_RANGE" ]; then
          DASH_RANGE=$(echo "$HOP_RANGE" | tr ':' '-')
          MPORT_PARAM="&mport=$DASH_RANGE"
          MPORT_YAML="443,$DASH_RANGE"
        fi

        OBFS_URI_PARAM=""
        OBFS_YAML_BLOCK=""
        if [ -n "$OBFS_PASS" ]; then
          OBFS_URI_PARAM="&obfs=salamander&obfs-password=$OBFS_PASS"
          OBFS_YAML_BLOCK=$(cat << YAML_OBFS
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"
YAML_OBFS
)
        fi

        echo "=== 客户端通用 URI 链接 ==="
        echo "hysteria2://$PASS@$DOMAIN:443/?sni=$DOMAIN&insecure=0${MPORT_PARAM}${OBFS_URI_PARAM}#Hy2-Server"
        echo ""
        echo "=== 客户端 YAML 配置 (client.yaml) ==="
        echo "server: $DOMAIN:$MPORT_YAML"
        echo "auth: \"$PASS\""
        if [ -n "$OBFS_YAML_BLOCK" ]; then
          echo "$OBFS_YAML_BLOCK"
        fi
        echo "fastOpen: true"
        echo "tls:"
        echo "  sni: $DOMAIN"
        echo "  insecure: false"
        echo "congestion:"
        echo "  type: bbr"
        echo "  bbrProfile: standard"
        echo "quic:"
        echo "  initStreamReceiveWindow: 8388608"
        echo "  maxStreamReceiveWindow: 8388608"
        echo "  initConnReceiveWindow: 20971520"
        echo "  maxConnReceiveWindow: 20971520"
        echo "socks5:"
        echo "  listen: 127.0.0.1:10808"
        ;;
    *)
        echo "用法: hy {start|stop|restart|status|logs|server|client}"
        ;;
esac
HYEOF

chmod +x /usr/local/bin/hy

echo ""
echo "========================================================="
echo "🎉 Hysteria 2 安装成功且已正常运行！"
echo "管理命令: hy {start|stop|restart|status|logs|server|client}"
echo "========================================================="
/usr/local/bin/hy client
