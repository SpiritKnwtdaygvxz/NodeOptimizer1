#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.0"
LOG="/var/log/pterodactyl-node-optimizer-v2.log"
BACKUP="/root/pterodactyl-node-v2-backup-$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET} $*"; }

mkdir -p "$BACKUP"
touch "$LOG"

exec > >(tee -a "$LOG") 2>&1

if [[ "$EUID" -ne 0 ]]; then
    fail "Run as root."
    exit 1
fi

source /etc/os-release 2>/dev/null || true

echo
echo "============================================================"
echo "       PTERODACTYL NODE OPTIMIZER v$VERSION"
echo "============================================================"
echo

info "Starting aggressive guest-level optimization."
info "Proxmox host configuration will NOT be modified."
echo

# ============================================================
# DETECTION
# ============================================================

VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
CPU_VENDOR="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/ /,"",$2); print $2; exit}')"
CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
CPU_THREADS="$(nproc)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

info "OS: ${PRETTY_NAME:-unknown}"
info "Virtualization: $VIRT"
info "CPU vendor: ${CPU_VENDOR:-unknown}"
info "CPU: ${CPU_MODEL:-unknown}"
info "vCPU threads: $CPU_THREADS"
info "RAM: ${RAM_MB} MB"

if [[ "$VIRT" == "none" ]]; then
    warn "Bare metal detected."
    warn "This script is intended for Pterodactyl guest nodes."
fi

# ============================================================
# BACKUP
# ============================================================

info "Creating backups..."

cp -a /etc/sysctl.conf "$BACKUP/" 2>/dev/null || true
cp -a /etc/sysctl.d "$BACKUP/" 2>/dev/null || true
cp -a /etc/security/limits.conf "$BACKUP/" 2>/dev/null || true
cp -a /etc/security/limits.d "$BACKUP/" 2>/dev/null || true
cp -a /etc/systemd/system.conf.d "$BACKUP/" 2>/dev/null || true
cp -a /etc/fstab "$BACKUP/" 2>/dev/null || true

[[ -f /etc/docker/daemon.json ]] &&
    cp -a /etc/docker/daemon.json "$BACKUP/" || true

[[ -f /etc/pterodactyl/config.yml ]] &&
    cp -a /etc/pterodactyl/config.yml "$BACKUP/" || true

ok "Backup created: $BACKUP"

# ============================================================
# CPU
# ============================================================

echo
info "CPU topology:"

lscpu 2>/dev/null |
    grep -E \
    'Architecture|Vendor ID|Model name|CPU\(s\)|Thread|Core|Socket|NUMA|Virtualization' \
    || true

echo

if command -v numactl >/dev/null 2>&1; then
    numactl --hardware 2>/dev/null || true
fi

# ============================================================
# CPU GOVERNOR
# ============================================================

info "Checking CPU frequency controls..."

PERF_FOUND=0

for f in \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors \
    /sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors
do
    [[ -f "$f" ]] || continue

    if grep -qw performance "$f" 2>/dev/null; then
        PERF_FOUND=1
        break
    fi
done

if [[ "$PERF_FOUND" -eq 1 ]]; then

    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -w "$policy/scaling_governor" ]] || continue
        echo performance > "$policy/scaling_governor" || true
    done

    ok "Performance governor enabled."

else
    warn "Guest does not expose performance governor."
    warn "CPU frequency policy is controlled by the virtualization host."
fi

# ============================================================
# SYSCTL
# ============================================================

info "Applying high-performance guest kernel tuning..."

cat > /etc/sysctl.d/99-pterodactyl-node-v2.conf <<'EOF'

# ============================================================
# Pterodactyl Node Optimizer v2
# ============================================================

# Memory
vm.swappiness = 1
vm.vfs_cache_pressure = 50

# Dirty page/writeback behavior
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15

# Process/file limits
fs.file-max = 4194304

# Network queues
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384

net.ipv4.tcp_max_syn_backlog = 8192

# TCP
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600

# Local ephemeral port range
net.ipv4.ip_local_port_range = 10240 65535

EOF

sysctl --system >/dev/null 2>&1 || true

ok "Kernel tuning applied."

# ============================================================
# FILE DESCRIPTORS
# ============================================================

info "Configuring file descriptor limits..."

cat > /etc/security/limits.d/99-pterodactyl-node-v2.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d

cat > /etc/systemd/system.conf.d/99-pterodactyl-node-v2.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

systemctl daemon-reload >/dev/null 2>&1 || true

ok "File descriptor limits configured."

# ============================================================
# THP
# ============================================================

info "Checking Transparent Huge Pages..."

THP="/sys/kernel/mm/transparent_hugepage/enabled"

if [[ -f "$THP" ]]; then

    CURRENT_THP="$(cat "$THP")"
    info "Current THP: $CURRENT_THP"

    if grep -qw madvise "$THP" 2>/dev/null; then
        echo madvise > "$THP" 2>/dev/null || true
        ok "THP set to madvise."
    else
        warn "madvise mode unavailable; THP left unchanged."
    fi

else
    warn "THP controls unavailable inside this guest."

fi

# ============================================================
# MEMORY PRESSURE
# ============================================================

info "Checking memory pressure interface..."

if [[ -f /proc/pressure/memory ]]; then
    cat /proc/pressure/memory
else
    warn "Memory PSI unavailable."
fi

# ============================================================
# SWAP
# ============================================================

echo
info "Swap configuration:"

swapon --show 2>/dev/null || true

sysctl vm.swappiness 2>/dev/null || true

info "Swap is intentionally NOT deleted."

# ============================================================
# STORAGE
# ============================================================

echo
info "Storage topology:"

lsblk -o NAME,MODEL,SIZE,ROTA,FSTYPE,MOUNTPOINTS,SCHED 2>/dev/null || true

echo

for d in /sys/block/*; do
    [[ -f "$d/queue/scheduler" ]] || continue

    name="$(basename "$d")"
    scheduler="$(cat "$d/queue/scheduler" 2>/dev/null || true)"

    info "$name scheduler: $scheduler"
done

warn "Schedulers are only changed when the guest safely exposes control."
warn "No blind scheduler forcing is performed."

# ============================================================
# I/O QUEUES
# ============================================================

info "Checking block queue settings..."

for d in /sys/block/*; do

    [[ -d "$d/queue" ]] || continue

    name="$(basename "$d")"

    read_ahead="$d/queue/read_ahead_kb"

    if [[ -w "$read_ahead" ]]; then
        current="$(cat "$read_ahead" 2>/dev/null || echo 128)"

        # Moderate read-ahead for Minecraft workloads.
        if [[ "$current" -lt 128 ]]; then
            echo 128 > "$read_ahead" || true
        fi

        info "$name read_ahead_kb: $(cat "$read_ahead")"
    fi

done

# ============================================================
# NETWORK
# ============================================================

echo
info "Network interfaces:"

ip -br link 2>/dev/null || true

echo

for iface in /sys/class/net/*; do

    name="$(basename "$iface")"

    [[ "$name" == "lo" ]] && continue

    info "Interface: $name"

    if command -v ethtool >/dev/null 2>&1; then

        ethtool "$name" 2>/dev/null |
            grep -E 'Speed:|Duplex:|Link detected:' ||
            true

    fi

done

# ============================================================
# IRQBALANCE
# ============================================================

if command -v irqbalance >/dev/null 2>&1 ||
   [[ -f /usr/sbin/irqbalance ]]; then

    info "irqbalance detected."

    if [[ "$VIRT" != "none" ]]; then
        info "Guest detected; leaving host IRQ management alone."
    fi

else

    info "irqbalance not installed."
    info "Not installing it automatically inside a VPS."

fi

# ============================================================
# DOCKER
# ============================================================

echo
info "Docker optimization..."

if command -v docker >/dev/null 2>&1; then

    ok "Docker detected."

    docker info 2>/dev/null |
        grep -E \
        'Server Version|Storage Driver|Logging Driver|Cgroup Driver|Cgroup Version|CPUs|Total Memory' \
        || true

    echo

    if docker info 2>/dev/null | grep -q "Cgroup Version: 2"; then
        ok "cgroup v2 detected."
    fi

    if docker info 2>/dev/null | grep -q "Cgroup Driver: systemd"; then
        ok "systemd cgroup driver detected."
    fi

else

    warn "Docker not installed."

fi

# ============================================================
# DOCKER LOGGING
# ============================================================

if [[ -f /etc/docker/daemon.json ]]; then

    info "Docker daemon.json exists."
    info "Preserving existing configuration."

else

    info "Docker daemon.json does not exist."
    info "No daemon configuration was required."

fi

# ============================================================
# WINGS
# ============================================================

echo
info "Pterodactyl Wings..."

if systemctl list-unit-files 2>/dev/null |
    grep -q '^wings.service'; then

    ok "Wings detected."

    systemctl is-active wings || true

    if [[ -f /etc/pterodactyl/config.yml ]]; then

        echo
        info "Wings configuration:"
        grep -E \
            'disk_check_interval|throttle|detect|network' \
            /etc/pterodactyl/config.yml \
            2>/dev/null || true

    fi

else

    warn "Wings service not found."

fi

# ============================================================
# CPU STEAL
# ============================================================

echo
info "Measuring CPU steal..."

if command -v mpstat >/dev/null 2>&1; then

    mpstat -P ALL 1 5 || true

    echo
    info "CPU steal indicates host contention."

fi

# ============================================================
# PROCESS LIMITS
# ============================================================

info "Checking PID/process limits..."

sysctl kernel.pid_max 2>/dev/null || true

# ============================================================
# DOCKER RESOURCE SNAPSHOT
# ============================================================

if command -v docker >/dev/null 2>&1 &&
   systemctl is-active --quiet docker; then

    echo
    info "Docker resource snapshot:"
    docker stats --no-stream 2>/dev/null || true

fi

# ============================================================
# FINAL STATUS
# ============================================================

echo
echo "============================================================"
echo "                    FINAL STATUS"
echo "============================================================"

echo

info "CPU:"
nproc

echo

info "RAM:"
free -h

echo

info "Swap:"
sysctl vm.swappiness 2>/dev/null || true

echo

info "Network:"
sysctl net.core.somaxconn 2>/dev/null || true
sysctl net.core.netdev_max_backlog 2>/dev/null || true
sysctl net.ipv4.tcp_max_syn_backlog 2>/dev/null || true

echo

info "File table:"
sysctl fs.file-max 2>/dev/null || true

echo

info "Virtualization:"
echo "$VIRT"

echo

info "CPU:"
echo "$CPU_MODEL"

echo

info "Backup:"
echo "$BACKUP"

echo

info "Log:"
echo "$LOG"

echo
echo "============================================================"
echo "              OPTIMIZATION FINISHED"
echo "============================================================"
echo
echo "Changes were applied only where the guest OS exposed control."
echo
