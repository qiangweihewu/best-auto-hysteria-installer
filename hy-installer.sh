#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本 (sudo -i)"
  exit 1
fi

if [ "$1" == "install" ] || [ ! -f /etc/hysteria/config.yaml ]; then
    echo "=== [1/5] 检测系统硬件与环境 ==="
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
      echo "❌ 当前脚本仅针对 x86_64 架构编写，当前架构为: $ARCH"
      exit 1
    fi

    CPU_CORES=$(nproc)
    TOTAL_MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
    FREE_MEM_MB=$(free -m | awk '/Mem:/ {print $4}')
    echo "检测到: CPU 核心数 = $CPU_CORES, 总内存 = ${TOTAL_MEM_MB}MB, 空闲内存 = ${FREE_MEM_MB}MB"

    read -p "请输入你的 Hysteria 域名 (例如 hy.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
      echo "❌ 域名不能为空！"
      exit 1
    fi

    echo ""
    echo "--------------------------------------------------------"
    echo "【选项 1: TLS 证书配置】"
    echo "说明: Hysteria 2 基于 QUIC/TLS 1.3，必须绑定一个有效域名证书。"
    echo "  1) 开启内置 ACME 自动申请证书 (需确保 80 端口未被占用，域名已解析到本机)"
    echo "  2) 使用已有证书文件 (例如 Certbot / acme.sh 现成证书)"
    echo "--------------------------------------------------------"
    read -p "请输入选项 [1 或 2，默认 1]: " CERT_MODE
    CERT_MODE=${CERT_MODE:-1}

    if [ "$CERT_MODE" == "1" ]; then
      read -p "请输入接收证书通知的邮箱 (例如 admin@example.com): " ACME_EMAIL
      if [ -z "$ACME_EMAIL" ]; then
        echo "❌ 邮箱不能为空！"
        exit 1
      fi
      TLS_CONFIG_BLOCK=$(cat << ACME_EOF
tls:
  sniGuard: dns-san
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
        echo "⚠️ 警告: 未找到指定的证书或私钥文件，服务可能因缺少证书无法启动！"
      fi

      TLS_CONFIG_BLOCK=$(cat << MANUAL_EOF
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
  sniGuard: dns-san
MANUAL_EOF
)
    fi

    read -p "请输入你的 Hysteria 核心连接密码 (留空则随机生成): " PASSWORD
    if [ -z "$PASSWORD" ]; then
      PASSWORD=$(openssl rand -hex 12)
      echo "已自动生成随机密码: $PASSWORD"
    fi

    # 选项 2: 端口跳跃
    echo ""
    echo "--------------------------------------------------------"
    echo "【选项 2: UDP 端口跳跃 (Port Hopping)】"
    echo "说明: 运营商若检测到单一端口长时间跑大量 UDP 流量，会触发限速或丢包。"
    echo "      端口跳跃通过 iptables 开启一段端口区间转发至 443，客户端在区间内"
    echo "      动态切换发包端口，有效抵抗单端口 UDP QoS 封锁。"
    echo "--------------------------------------------------------"
    read -p "是否开启端口跳跃？[y/N，默认 N]: " ENABLE_HOPPING
    ENABLE_HOPPING=${ENABLE_HOPPING:-n}

    PORT_RANGE=""
    if [[ "$ENABLE_HOPPING" =~ ^[Yy]$ ]]; then
      read -p "请输入跳跃 UDP 端口范围 [默认 20000:40000]: " USER_RANGE
      USER_RANGE=${USER_RANGE:-"20000:40000"}
      PORT_RANGE=$(echo "$USER_RANGE" | tr '-' ':')
      echo "✅ 端口跳跃已启用，转发范围: $PORT_RANGE -> 443"
    fi

    # 选项 3: 流量混淆 (Salamander)
    echo ""
    echo "--------------------------------------------------------"
    echo "【选项 3: Salamander 协议混淆 (Obfs)】"
    echo "说明: 某些运营商采用 DPI 设备直接识别标准 QUIC 协议握手特征并进行干扰。"
    echo "      开启 Salamander 混淆后，所有数据包头部会被转为纯随机密文，使其伪装"
    echo "      成不可识别的无序 UDP 流量。若你的网络未对 QUIC 做特征封锁，通常无需开启。"
    echo "--------------------------------------------------------"
    read -p "是否开启 Salamander 混淆？[y/N，默认 N]: " ENABLE_OBFS
    ENABLE_OBFS=${ENABLE_OBFS:-n}

    OBFS_CONFIG_BLOCK=""
    OBFS_PASSWORD=""
    if [[ "$ENABLE_OBFS" =~ ^[Yy]$ ]]; then
      read -p "请输入混淆密码 (留空则随机生成): " OBFS_PASSWORD
      if [ -z "$OBFS_PASSWORD" ]; then
        OBFS_PASSWORD=$(openssl rand -hex 8)
        echo "已自动生成混淆密码: $OBFS_PASSWORD"
      fi
      OBFS_CONFIG_BLOCK=$(cat << OBFS_EOF

# Salamander 协议特征混淆配置
obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASSWORD"
OBFS_EOF
)
      echo "✅ Salamander 混淆已启用！"
    fi

    echo "=== [2/5] 安装 Hysteria 2 及网络依赖 ==="
    apt-get update && apt-get install -y iptables ethtool 2>/dev/null || yum install -y iptables ethtool 2>/dev/null || true

    if grep -q avx /proc/cpuinfo; then
      BIN_NAME="hysteria-linux-amd64-avx"
      echo "✅ 检测到 CPU 支持 AVX 指令集，下载 AVX 增强版..."
    else
      BIN_NAME="hysteria-linux-amd64"
      echo "ℹ️ CPU 不支持 AVX，下载通用版..."
    fi

    curl -fL -o /usr/local/bin/hysteria.tmp "https://github.com/apernet/hysteria/releases/latest/download/${BIN_NAME}"
    chmod +x /usr/local/bin/hysteria.tmp
    mv -f /usr/local/bin/hysteria.tmp /usr/local/bin/hysteria

    mkdir -p /etc/hysteria

    echo "=== [3/5] 写入平衡版服务端配置 (防 QoS 优化) ==="
    cat << CONFIGEOF > /etc/hysteria/config.yaml
listen: :443

$TLS_CONFIG_BLOCK

auth:
  type: password
  password: "$PASSWORD"
$OBFS_CONFIG_BLOCK

# 强制服务端控制，忽略客户端带宽参数，保证下方 BBR 生效并避免被 QoS
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

    echo "=== [4/5] 内核、网卡硬件卸载及端口跳跃规则调优 ==="
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

    NIC=$(ip -4 route show default | awk '{print $5}' | head -n1)
    if [ -n "$NIC" ]; then
      ethtool -K "$NIC" gro on gso on tso on 2>/dev/null || true
      ethtool -K "$NIC" tx-udp-segmentation on 2>/dev/null || true
    fi

    # 配置 iptables 规则脚本
    cat << 'RULEROOT' > /etc/hysteria/apply-rules.sh
#!/bin/bash
setup_rules() {
  local range="$1"
  [ -z "$range" ] && exit 0

  # 清理旧链
  iptables -t nat -D PREROUTING -j HYSTERIA_HOPPING 2>/dev/null || true
  iptables -t nat -F HYSTERIA_HOPPING 2>/dev/null || true
  iptables -t nat -X HYSTERIA_HOPPING 2>/dev/null || true

  # 新建并添加规则 (IPv4)
  iptables -t nat -N HYSTERIA_HOPPING
  iptables -t nat -A HYSTERIA_HOPPING -p udp --dport "$range" -j REDIRECT --to-ports 443
  iptables -t nat -A PREROUTING -j HYSTERIA_HOPPING

  # 新建并添加规则 (IPv6，若支持)
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

    echo "=== [5/5] 配置 Systemd 服务并启动 ==="
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
    echo "✅ Hysteria 2 安装并已尝试启动！"
    echo "   如使用内置 ACME，请查看日志关注证书申请状态：hy logs"
fi

# 核心：生成全局管理命令 /usr/local/bin/hy
cat << 'HYEOF' > /usr/local/bin/hy
#!/bin/bash
get_domain() {
    local d=$(grep -A 2 "acme:" /etc/hysteria/config.yaml 2>/dev/null | grep "-" | awk '{print $2}' | tr -d ' ')
    if [ -z "$d" ]; then
      d=$(grep "cert:" /etc/hysteria/config.yaml 2>/dev/null | awk -F'/' '{print $5}')
    fi
    echo "$d"
}
get_pass() {
    grep -A 2 "auth:" /etc/hysteria/config.yaml 2>/dev/null | grep "password:" | head -n 1 | awk -F'"' '{print $2}'
}
get_obfs_pass() {
    grep -A 4 "obfs:" /etc/hysteria/config.yaml 2>/dev/null | grep "password:" | head -n 1 | awk -F'"' '{print $2}'
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

        # 端口跳跃解析
        MPORT_PARAM=""
        MPORT_YAML="443"
        if [ -n "$HOP_RANGE" ]; then
          DASH_RANGE=$(echo "$HOP_RANGE" | tr ':' '-')
          MPORT_PARAM="&mport=$DASH_RANGE"
          MPORT_YAML="443,$DASH_RANGE"
        fi

        # 混淆参数解析
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
        echo "hysteria2://$PASS@$DOMAIN:443/?sni=$DOMAIN&insecure=0${MPORT_PARAM}${OBFS_URI_PARAM}#Hy2-Balanced"
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
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  status  - 查看运行状态"
        echo "  logs    - 实时查看运行日志"
        echo "  server  - 查看服务端完整配置"
        echo "  client  - 生成客户端链接与配置"
        ;;
esac
HYEOF

chmod +x /usr/local/bin/hy
echo "✅ 全局管理命令 'hy' 已成功挂载！"
