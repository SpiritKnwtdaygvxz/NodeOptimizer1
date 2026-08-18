#!/usr/bin/env bash

# ============================================================
# Pterodactyl Node Optimizer
# ============================================================
# Purpose:
#   Safe performance tuning for Pterodactyl Wings nodes.
#
# Supported:
#   - Debian
#   - Ubuntu
#   - KVM VPS/VDS
#   - Proxmox VMs
#   - Docker
#   - Pterodactyl Wings
#
# Does NOT:
#   - Modify the Proxmox host
#   - Automatically pin CPUs
#   - Disable security mitigations
#   - Delete swap
#   - Modify Minecraft server files
#   - Blindly overwrite Docker/Wings configuration
#
# ============================================================

set -Eeuo pipefail

VERSION="1.0.0"
LOG_FILE="/var/log/pterodactyl-node-optimizer.log"
BACKUP_DIR="/root/pterodactyl-node-backup-$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[ OK ]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

error() {
    echo -e "${RED}[FAIL]${RESET} $*"
}

section() {
    echo
    echo -e "${CYAN}============================================================${RESET}"
    echo -e "${CYAN}$*${RESET}"
    echo -e "${CYAN}============================================================${RESET}"
    echo
}

cleanup() {
    echo
    info "Optimizer finished."
}

trap cleanup EXIT

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root."
    echo
    echo "Example:"
    echo "  sudo bash optimize-node.sh"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Log everything while keeping terminal output visible.
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

clear 2>/dev/null || true

echo -e "${CYAN}"
echo "============================================================"
echo "          PTERODACTYL NODE OPTIMIZER"
echo "============================================================"
echo -e "${RESET}"
echo "Version : $VERSION"
echo "Purpose : Production Pterodactyl/Wings node tuning"
echo

# ------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------

section "SYSTEM DETECTION"

if [[ ! -f /etc/os-release ]]; then
    error "Cannot detect operating system."
    exit 1
fi

source /etc/os-release

OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_NAME="${PRETTY_NAME:-unknown}"

info "Operating System : $OS_NAME"

case "$OS_ID" in
    debian|ubuntu)
        success "Supported operating system detected."
        ;;
    *)
        warn "This script was designed primarily for Debian/Ubuntu."
        warn "Continuing, but unsupported systems may behave differently."
        ;;
esac

# ------------------------------------------------------------
# Virtualization
# ------------------------------------------------------------

VIRT="unknown"

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
fi

info "Virtualization : $VIRT"

case "$VIRT" in
    none)
        warn "Bare metal detected."
        warn "This optimizer is intended primarily for VPS/VDS nodes."
        ;;
    kvm)
        success "KVM guest detected."
        ;;
    qemu)
        success "QEMU guest detected."
        ;;
    lxc)
        warn "LXC detected."
        warn "Some kernel settings may be controlled by the host."
        ;;
    openvz)
        warn "OpenVZ detected."
        warn "Many kernel controls may be unavailable."
        ;;
    *)
        warn "Unknown virtualization environment."
        ;;
esac

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------

section "CPU DETECTION"

CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +| +$/, "", $2); print $2; exit}')"
CPU_THREADS="$(nproc 2>/dev/null || echo unknown)"
CPU_CORES="$(lscpu 2>/dev/null | awk -F: '/Core\\(s\\) per socket/ {gsub(/^ +| +$/, "", $2); print $2; exit}')"
CPU_SOCKETS="$(lscpu 2>/dev/null | awk -F: '/Socket\\(s\\)/ {gsub(/^ +| +$/, "", $2); print $2; exit}')"

info "CPU Model   : ${CPU_MODEL:-unknown}"
info "Threads     : ${CPU_THREADS:-unknown}"
info "Cores/socket: ${CPU_CORES:-unknown}"
info "Sockets     : ${CPU_SOCKETS:-unknown}"

# ------------------------------------------------------------
# NUMA
# ------------------------------------------------------------

if command -v numactl >/dev/null 2>&1; then
    info "NUMA topology:"
    numactl --hardware 2>/dev/null || true
else
    info "numactl not installed."
fi

# ------------------------------------------------------------
# RAM
# ------------------------------------------------------------

section "MEMORY"

free -h

SWAP_TOTAL="$(free -m | awk '/Swap:/ {print $2}')"

if [[ "${SWAP_TOTAL:-0}" -gt 0 ]]; then
    success "Swap detected: ${SWAP_TOTAL} MB"
else
    warn "No swap detected."
fi

# ------------------------------------------------------------
# CPU governor
# ------------------------------------------------------------

section "CPU PERFORMANCE"

GOVERNOR_SUPPORTED=0

if compgen -G "/sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors" >/dev/null 2>&1; then

    GOVERNORS="$(
        cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors \
        2>/dev/null |
        tr ' ' '\n' |
        sort -u |
        tr '\n' ' '
    )"

    info "Available governors: $GOVERNORS"

    if echo "$GOVERNORS" | grep -qw "performance"; then
        GOVERNOR_SUPPORTED=1
    fi
fi

if [[ "$GOVERNOR_SUPPORTED" -eq 1 ]]; then

    for POLICY in /sys/devices/system/cpu/cpufreq/policy*; do
        if [[ -w "$POLICY/scaling_governor" ]]; then
            echo performance > "$POLICY/scaling_governor" || true
        fi
    done

    success "Performance governor applied."

else

    warn "CPU governor control unavailable inside this guest."
    warn "This is normal on many VPS/VDS providers."

fi

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

section "CONFIGURATION BACKUP"

mkdir -p "$BACKUP_DIR"

backup_file() {
    local FILE="$1"

    if [[ -e "$FILE" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$FILE")"
        cp -a "$FILE" "$BACKUP_DIR$FILE"
        success "Backed up: $FILE"
    fi
}

backup_file "/etc/sysctl.conf"
backup_file "/etc/security/limits.conf"
backup_file "/etc/fstab"
backup_file "/etc/docker/daemon.json"
backup_file "/etc/pterodactyl/config.yml"

if [[ -d /etc/sysctl.d ]]; then
    cp -a /etc/sysctl.d "$BACKUP_DIR/" 2>/dev/null || true
fi

if [[ -d /etc/security/limits.d ]]; then
    cp -a /etc/security/limits.d "$BACKUP_DIR/" 2>/dev/null || true
fi

info "Backup location:"
echo "  $BACKUP_DIR"

# ------------------------------------------------------------
# Sysctl
# ------------------------------------------------------------

section "KERNEL / MEMORY / NETWORK TUNING"

SYSCTL_FILE="/etc/sysctl.d/99-pterodactyl-node.conf"

cat > "$SYSCTL_FILE" <<'EOF'
# ============================================================
# Pterodactyl Node Optimizer
# Conservative production tuning
# ============================================================

# Memory
vm.swappiness = 1
vm.vfs_cache_pressure = 50

# Writeback
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20

# Network queues
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# TCP
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600

# File table
fs.file-max = 2097152
EOF

if sysctl --system >/dev/null 2>&1; then
    success "Kernel tuning applied."
else
    warn "Some sysctl values were rejected by the host kernel."
    warn "This is normal on restricted VPS/LXC environments."
fi

# ------------------------------------------------------------
# File limits
# ------------------------------------------------------------

section "FILE DESCRIPTORS"

LIMITS_FILE="/etc/security/limits.d/99-pterodactyl-node.conf"

cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d

SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-pterodactyl-limits.conf"

cat > "$SYSTEMD_LIMITS" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

systemctl daemon-reload >/dev/null 2>&1 || true

success "File descriptor limits configured."

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

section "STORAGE"

lsblk -o NAME,MODEL,SIZE,ROTA,FSTYPE,MOUNTPOINTS,SCHED 2>/dev/null || true

echo

for DEV in /sys/block/*; do
    if [[ -f "$DEV/queue/scheduler" ]]; then
        DEVICE_NAME="$(basename "$DEV")"
        info "$DEVICE_NAME scheduler: $(cat "$DEV/queue/scheduler")"
    fi
done

echo

info "Storage schedulers are intentionally NOT forced."
info "The VPS/provider may control the physical storage layer."

# ------------------------------------------------------------
# Filesystem
# ------------------------------------------------------------

section "FILESYSTEM"

findmnt -t ext4,xfs 2>/dev/null || true

echo

info "Filesystem mount options are intentionally not rewritten."
info "Changing /etc/fstab automatically can make a production node unbootable."

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

section "DOCKER"

if command -v docker >/dev/null 2>&1; then

    success "Docker detected."

    if systemctl is-active --quiet docker; then
        success "Docker service is running."
    else
        warn "Docker is installed but not currently running."
    fi

    echo

    docker info 2>/dev/null |
        grep -E \
        'Server Version|Storage Driver|Logging Driver|Cgroup Driver|Cgroup Version|CPUs|Total Memory' \
        || true

else

    warn "Docker was not detected."

fi

# ------------------------------------------------------------
# Docker daemon
# ------------------------------------------------------------

if [[ -f /etc/docker/daemon.json ]]; then

    info "Existing Docker daemon.json detected."
    info "It will NOT be overwritten."

else

    info "No Docker daemon.json found."
    info "Docker defaults remain unchanged."

fi

# ------------------------------------------------------------
# Wings
# ------------------------------------------------------------

section "PTERODACTYL WINGS"

if systemctl list-unit-files 2>/dev/null | grep -q '^wings.service'; then

    success "Wings service detected."

    WINGS_STATE="$(systemctl is-active wings 2>/dev/null || true)"

    info "Wings status: ${WINGS_STATE:-unknown}"

    if [[ -f /etc/pterodactyl/config.yml ]]; then

        success "Wings configuration detected."

        echo
        info "Current disk check interval:"

        grep -E 'disk_check_interval:' \
            /etc/pterodactyl/config.yml \
            2>/dev/null ||
            echo "Not explicitly configured."

        echo
        info "Existing Wings configuration was preserved."

    fi

else

    warn "Wings service was not detected."

fi

# ------------------------------------------------------------
# CPU steal
# ------------------------------------------------------------

section "VIRTUALIZATION HEALTH"

if command -v mpstat >/dev/null 2>&1; then

    info "CPU steal measurement:"
    mpstat -P ALL 1 5 || true

    echo
    info "For VPS/VDS:"
    echo "  ~0-1% steal  = excellent"
    echo "  ~1-3% steal  = acceptable"
    echo "  ~3-5% steal  = investigate"
    echo "  5%+ sustained = provider contention"

fi

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------

section "NETWORK"

ip -br link 2>/dev/null || true

echo

for IFACE in /sys/class/net/*; do

    NAME="$(basename "$IFACE")"

    [[ "$NAME" == "lo" ]] && continue

    info "Interface: $NAME"

    ip -s link show "$NAME" 2>/dev/null |
        grep -A2 -E 'RX:|TX:' ||
        true

done

# ------------------------------------------------------------
# Current resource usage
# ------------------------------------------------------------

section "CURRENT RESOURCE USAGE"

info "Memory:"
free -h

echo

info "Filesystem:"
df -hT

echo

if command -v docker >/dev/null 2>&1 &&
   systemctl is-active --quiet docker; then

    info "Docker containers:"
    docker stats --no-stream 2>/dev/null || true

fi

# ------------------------------------------------------------
# Wings logs
# ------------------------------------------------------------

section "WINGS HEALTH"

if systemctl list-unit-files 2>/dev/null | grep -q '^wings.service'; then

    systemctl status wings \
        --no-pager \
        --lines=10 ||
        true

    echo

    info "Recent Wings errors:"
    journalctl -u wings \
        --since "30 minutes ago" \
        --no-pager \
        2>/dev/null |
        grep -Ei 'error|failed|oom|panic|fatal' |
        tail -20 ||
        echo "No obvious recent errors found."

fi

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

section "VERIFICATION"

info "vm.swappiness:"
sysctl vm.swappiness 2>/dev/null || true

info "vm.vfs_cache_pressure:"
sysctl vm.vfs_cache_pressure 2>/dev/null || true

info "somaxconn:"
sysctl net.core.somaxconn 2>/dev/null || true

info "tcp_max_syn_backlog:"
sysctl net.ipv4.tcp_max_syn_backlog 2>/dev/null || true

info "file-max:"
sysctl fs.file-max 2>/dev/null || true

echo

info "Virtualization:"
echo "$VIRT"

echo

info "CPU:"
echo "$CPU_MODEL"

echo

info "CPU threads:"
echo "$CPU_THREADS"

echo

info "Backup:"
echo "$BACKUP_DIR"

echo

info "Log:"
echo "$LOG_FILE"

# ------------------------------------------------------------
# Final message
# ------------------------------------------------------------

section "COMPLETE"

success "Pterodactyl node optimization completed."

echo
echo "Important:"
echo "  - Existing Minecraft servers were NOT modified."
echo "  - Existing Docker configuration was NOT overwritten."
echo "  - Existing Wings configuration was NOT overwritten."
echo "  - CPU pinning was NOT changed automatically."
echo "  - Proxmox host settings were NOT touched."
echo "  - Security mitigations were NOT disabled."
echo
echo "A reboot is normally NOT required for the changes applied here."
echo
echo "Backup:"
echo "  $BACKUP_DIR"
echo
echo "Log:"
echo "  $LOG_FILE"
echo
