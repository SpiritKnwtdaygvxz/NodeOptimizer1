#!/usr/bin/env bash

# ============================================================
# PTERODACTYL NODE SETUP + OPTIMIZER
# Ubuntu 24.04 / KVM
#
# Installs:
#   - Docker
#   - Pterodactyl Wings
#   - ZRAM
#   - Optional disk swap
#   - Docker log rotation
#   - Conservative kernel tuning
#   - Automatic cleanup
#   - RAM/CPU/disk monitoring
#   - systemd timers
#
# Does NOT:
#   - Create the Pterodactyl Panel Node
#   - Delete Minecraft server files
#   - Delete Docker volumes
#   - Restart Minecraft servers during cleanup
#   - Reboot automatically
# ============================================================

set -Eeuo pipefail

VERSION="1.0"
INSTALL_DIR="/opt/ptero-node"
CONFIG="/etc/ptero-node.conf"
LOG="/var/log/ptero-node.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

warn() {
    echo -e "${YELLOW}!${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

die() {
    error "$*"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

detect_system() {
    source /etc/os-release

    echo
    echo "================================================"
    echo " PTERODACTYL NODE SETUP"
    echo "================================================"
    echo
    echo "OS: ${PRETTY_NAME:-Unknown}"
    echo "Kernel: $(uname -r)"
    echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
    echo "CPU: $(nproc) vCPU"
    echo "RAM:"
    free -h | head -2
    echo
    echo "Disk:"
    df -h / | tail -1
    echo

    [[ "$ID" == "ubuntu" ]] || \
        die "This installer currently supports Ubuntu."

    [[ "$VERSION_ID" == "24.04" ]] || \
        warn "This was designed for Ubuntu 24.04. Continuing anyway."
}

confirm() {
    echo
    read -rp "Continue with installation? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || exit 0
}

install_packages() {

    log "Updating package lists..."

    apt-get update

    log "Installing required packages..."

    apt-get install -y \
        curl \
        wget \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        jq \
        unzip \
        tar \
        htop \
        btop \
        iotop \
        sysstat \
        lm-sensors \
        logrotate \
        zram-tools \
        util-linux \
        cron

    success "Required packages installed."
}

install_docker() {

    if command -v docker >/dev/null 2>&1; then
        success "Docker already installed."
    else

        log "Installing Docker..."

        install -m 0755 -d /etc/apt/keyrings

        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
            curl -fsSL \
                https://download.docker.com/linux/ubuntu/gpg \
                -o /etc/apt/keyrings/docker.asc

            chmod a+r /etc/apt/keyrings/docker.asc
        fi

        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable
EOF

        apt-get update

        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        systemctl enable docker
        systemctl start docker

        success "Docker installed."
    fi

    systemctl is-active --quiet docker || \
        die "Docker is not running."

    docker version >/dev/null 2>&1 || \
        die "Docker installation failed."

    success "Docker is working."
}

configure_docker() {

    log "Configuring Docker..."

    mkdir -p /etc/docker

    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json \
            /etc/docker/daemon.json.ptero-backup
    fi

    cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "25m",
        "max-file": "3"
    },
    "live-restore": true
}
EOF

    systemctl restart docker

    success "Docker log rotation configured."
}

install_wings() {

    if command -v wings >/dev/null 2>&1; then
        success "Wings already installed."
        return
    fi

    log "Installing Pterodactyl Wings..."

    mkdir -p /etc/pterodactyl
    mkdir -p /var/lib/pterodactyl
    mkdir -p /var/log/pterodactyl
    mkdir -p /var/lib/pterodactyl/volumes
    mkdir -p /var/lib/pterodactyl/backups

    WINGS_VERSION="$(
        curl -fsSL https://api.github.com/repos/pterodactyl/wings/releases/latest |
        jq -r '.tag_name'
    )"

    [[ -n "$WINGS_VERSION" && "$WINGS_VERSION" != "null" ]] || \
        die "Could not determine latest Wings version."

    log "Installing Wings ${WINGS_VERSION}..."

    curl -L \
        "https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/wings_linux_amd64" \
        -o /usr/local/bin/wings

    chmod 0755 /usr/local/bin/wings

    wings --version || \
        die "Wings installation failed."

    success "Wings installed."
}

create_wings_service() {

    log "Creating Wings systemd service..."

    cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /var/run/wings

    systemctl daemon-reload
    systemctl enable wings

    success "Wings service created."
}

configure_zram() {

    log "Configuring ZRAM..."

    # 13% gives approximately 4GB on this 32GB node.
    cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=13
PRIORITY=100
EOF

    systemctl daemon-reload

    if systemctl restart zramswap; then
        success "ZRAM enabled."
    else
        warn "ZRAM failed to start. Disabling it instead of risking the node."
        systemctl disable --now zramswap 2>/dev/null || true
    fi

    if swapon --show | grep -q zram; then
        success "ZRAM is active."
    else
        warn "ZRAM is not active. The node will continue without it."
    fi
}

configure_swap() {

    echo
    echo "================================================"
    echo " SWAP CONFIGURATION"
    echo "================================================"
    echo
    echo "ZRAM is already configured."
    echo "A small disk swap can provide an emergency memory"
    echo "buffer, but it is NOT additional fast RAM."
    echo

    read -rp "Create an 8GB emergency disk swap? [Y/n]: " answer

    if [[ "$answer" =~ ^[Nn]$ ]]; then
        success "Disk swap skipped."
        return
    fi

    if swapon --show | grep -v zram | grep -q '^/'; then
        success "Existing disk swap detected."
        return
    fi

    log "Creating 8GB swap file..."

    if ! fallocate -l 8G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null

    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
    fi

    success "8GB emergency disk swap enabled."
}

configure_kernel() {

    log "Applying conservative kernel settings..."

    cat > /etc/sysctl.d/99-pterodactyl-node.conf <<'EOF'
# Pterodactyl Node Optimizer
#
# Conservative values intended for a Minecraft hosting node.

vm.swappiness=10
vm.vfs_cache_pressure=50

# Keep the existing overcommit behavior.
# This allows applications to request virtual memory
# without pretending that physical RAM has increased.
vm.overcommit_memory=1

# Network buffers.
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# TCP behavior.
net.ipv4.tcp_mtu_probing=1

# Increase connection backlog.
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096

# Reduce unnecessary ICMP redirects.
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF

    sysctl --system >/dev/null

    success "Kernel settings applied."
}

configure_limits() {

    log "Configuring file descriptor limits..."

    cat > /etc/security/limits.d/pterodactyl.conf <<'EOF'
root soft nofile 65535
root hard nofile 65535
EOF

    success "File descriptor limits configured."
}

create_optimizer_config() {

    mkdir -p "$INSTALL_DIR"

    cat > "$CONFIG" <<'EOF'
# Pterodactyl Node Optimizer

JOURNAL_MAX_AGE="14d"
JOURNAL_MAX_SIZE="1G"

ENABLE_APT_CLEANUP=true
ENABLE_DOCKER_BUILDCACHE_CLEANUP=true

MEMORY_WARNING=85
DISK_WARNING=85
SWAP_WARNING=70

# Maintenance interval:
# systemd timer runs every 4 hours with a random delay
# of up to 1 hour.
EOF

    chmod 0640 "$CONFIG"
}

create_optimizer() {

    log "Creating optimizer..."

    cat > /usr/local/sbin/ptero-node <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG="/etc/ptero-node.conf"
LOG="/var/log/ptero-node.log"

source "$CONFIG"

log() {
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

cleanup() {

    log "===== Maintenance started ====="

    # APT cache
    if [[ "$ENABLE_APT_CLEANUP" == true ]]; then
        apt-get clean >> "$LOG" 2>&1 || true
    fi

    # System journal
    journalctl \
        --vacuum-time="$JOURNAL_MAX_AGE" \
        >> "$LOG" 2>&1 || true

    journalctl \
        --vacuum-size="$JOURNAL_MAX_SIZE" \
        >> "$LOG" 2>&1 || true

    # Docker build cache only.
    #
    # IMPORTANT:
    # We intentionally DO NOT run:
    #
    # docker system prune -a --volumes
    #
    # because Pterodactyl owns Docker resources and volumes.
    if [[ "$ENABLE_DOCKER_BUILDCACHE_CLEANUP" == true ]]; then

        if command -v docker >/dev/null 2>&1 &&
           docker info >/dev/null 2>&1; then

            docker builder prune \
                -af \
                --filter "until=168h" \
                >> "$LOG" 2>&1 || true
        fi
    fi

    log "===== Maintenance completed ====="
}

status() {

    echo
    echo "=========================================="
    echo " PTERODACTYL NODE STATUS"
    echo "=========================================="
    echo

    echo "CPU:"
    nproc

    echo
    echo "RAM:"
    free -h

    echo
    echo "SWAP:"
    swapon --show

    echo
    echo "DISK:"
    df -h /

    echo
    echo "DOCKER:"
    systemctl is-active docker || true

    echo
    echo "WINGS:"
    systemctl is-active wings || true

    echo
    echo "ZRAM:"
    zramctl 2>/dev/null || true

    echo
    echo "TIMERS:"
    systemctl list-timers \
        ptero-node-maintenance.timer \
        ptero-node-monitor.timer \
        --no-pager

    echo
}

monitor() {

    TOTAL=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    AVAILABLE=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

    USED=$((TOTAL - AVAILABLE))

    MEMORY_PERCENT=$((USED * 100 / TOTAL))

    DISK_PERCENT=$(
        df -P / |
        awk 'NR==2 {gsub("%","",$5); print $5}'
    )

    SWAP_TOTAL=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
    SWAP_FREE=$(awk '/SwapFree:/ {print $2}' /proc/meminfo)

    if (( SWAP_TOTAL > 0 )); then
        SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
        SWAP_PERCENT=$((SWAP_USED * 100 / SWAP_TOTAL))
    else
        SWAP_PERCENT=0
    fi

    if (( MEMORY_PERCENT >= MEMORY_WARNING )); then
        log "WARNING: RAM usage ${MEMORY_PERCENT}%"
    fi

    if (( DISK_PERCENT >= DISK_WARNING )); then
        log "WARNING: Disk usage ${DISK_PERCENT}%"
    fi

    if (( SWAP_PERCENT >= SWAP_WARNING )); then
        log "WARNING: Swap usage ${SWAP_PERCENT}%"
    fi

    # Detect recent OOM events.
    journalctl \
        -k \
        --since "6 minutes ago" \
        --no-pager 2>/dev/null |
        grep -Ei \
        'out of memory|oom-kill|killed process' |
        tail -10 |
        while read -r line; do
            log "OOM EVENT: $line"
        done
}

case "${1:-status}" in

    cleanup)
        cleanup
        ;;

    monitor)
        monitor
        ;;

    status)
        status
        ;;

    *)
        echo "Usage:"
        echo "  ptero-node status"
        echo "  ptero-node cleanup"
        echo "  ptero-node monitor"
        exit 1
        ;;

esac
EOF

    chmod 0755 /usr/local/sbin/ptero-node

    touch "$LOG"
    chmod 0640 "$LOG"

    success "Optimizer created."
}

create_maintenance_timer() {

    log "Creating maintenance timer..."

    cat > /etc/systemd/system/ptero-node-maintenance.service <<'EOF'
[Unit]
Description=Pterodactyl Node Maintenance
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ptero-node cleanup
Nice=10
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ptero-node-maintenance.timer <<'EOF'
[Unit]
Description=Pterodactyl maintenance every 4-5 hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=4h
RandomizedDelaySec=1h
Persistent=true
Unit=ptero-node-maintenance.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now ptero-node-maintenance.timer

    success "4-5 hour maintenance timer enabled."
}

create_monitor_timer() {

    log "Creating monitoring timer..."

    cat > /etc/systemd/system/ptero-node-monitor.service <<'EOF'
[Unit]
Description=Pterodactyl Node Health Monitor

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ptero-node monitor
Nice=19
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ptero-node-monitor.timer <<'EOF'
[Unit]
Description=Pterodactyl node health monitoring

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
Unit=ptero-node-monitor.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now ptero-node-monitor.timer

    success "5 minute monitoring enabled."
}

configure_logrotate() {

    cat > /etc/logrotate.d/ptero-node <<'EOF'
/var/log/ptero-node.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

    success "Optimizer log rotation enabled."
}

verify() {

    echo
    echo "================================================"
    echo " INSTALLATION VERIFICATION"
    echo "================================================"
    echo

    echo "Docker:"
    docker --version

    echo
    echo "Wings:"
    wings --version

    echo
    echo "ZRAM:"
    zramctl 2>/dev/null || true

    echo
    echo "Swap:"
    swapon --show

    echo
    echo "Memory:"
    free -h

    echo
    echo "Disk:"
    df -h /

    echo
    echo "Docker service:"
    systemctl is-active docker

    echo
    echo "Wings service:"
    systemctl is-enabled wings

    echo
    echo "Maintenance timer:"
    systemctl is-active ptero-node-maintenance.timer

    echo
    echo "Monitor timer:"
    systemctl is-active ptero-node-monitor.timer

    echo
    echo "Kernel:"
    sysctl vm.swappiness
    sysctl vm.overcommit_memory

    echo
}

show_next_steps() {

    echo
    echo "============================================================"
    echo "                 SETUP PAUSED HERE"
    echo "============================================================"
    echo
    echo "Docker + Wings + node optimization are installed."
    echo
    echo "NOW create the node in your Pterodactyl Panel."
    echo
    echo "Panel:"
    echo "  Administration"
    echo "    -> Nodes"
    echo "      -> Create New"
    echo
    echo "Use the resources of THIS node:"
    echo
    echo "  RAM:        approximately 31 GB"
    echo "  Disk:       approximately 145 GB"
    echo "  Allocations: configure your desired ports"
    echo
    echo "After creating the node:"
    echo
    echo "  Open the node"
    echo "  -> Configuration"
    echo
    echo "Copy the COMPLETE Wings configuration generated"
    echo "by the Panel."
    echo
    echo "Then run:"
    echo
    echo "  nano /etc/pterodactyl/config.yml"
    echo
    echo "Paste the configuration and save."
    echo
    echo "Then:"
    echo
    echo "  systemctl start wings"
    echo
    echo "Check:"
    echo
    echo "  systemctl status wings --no-pager"
    echo
    echo "============================================================"
    echo
    echo "Useful commands after installation:"
    echo
    echo "  ptero-node status"
    echo "  ptero-node cleanup"
    echo "  ptero-node monitor"
    echo
    echo "Logs:"
    echo "  tail -f /var/log/ptero-node.log"
    echo
    echo "Maintenance schedule:"
    echo "  systemctl list-timers ptero-node-maintenance.timer"
    echo
    echo "============================================================"
}

main() {

    require_root

    touch "$LOG"

    detect_system
    confirm

    install_packages
    install_docker
    configure_docker

    install_wings
    create_wings_service

    configure_zram
    configure_swap

    configure_kernel
    configure_limits

    create_optimizer_config
    create_optimizer
    create_maintenance_timer
    create_monitor_timer
    configure_logrotate

    verify
    show_next_steps
}

main "$@"
