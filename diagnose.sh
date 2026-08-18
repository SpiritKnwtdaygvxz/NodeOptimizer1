#!/usr/bin/env bash

set -u

echo "============================================================"
echo "        PTERODACTYL NODE PERFORMANCE DIAGNOSTICS"
echo "============================================================"

echo
echo "[ SYSTEM ]"
cat /etc/os-release 2>/dev/null | grep -E 'PRETTY_NAME|VERSION_ID' || true
echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"

echo
echo "[ CPU ]"
lscpu 2>/dev/null |
grep -E \
'Model name|CPU\(s\)|Core|Thread|Socket|NUMA|Vendor ID' || true

echo
echo "[ CPU TOPOLOGY ]"
lscpu -e 2>/dev/null || true

echo
echo "[ NUMA ]"
if command -v numactl >/dev/null 2>&1; then
    numactl --hardware 2>/dev/null || true
else
    echo "numactl unavailable"
fi

echo
echo "[ MEMORY ]"
free -h

echo
echo "[ SWAP ]"
swapon --show 2>/dev/null || true
sysctl vm.swappiness 2>/dev/null || true

echo
echo "[ CPU STEAL ]"
if command -v mpstat >/dev/null 2>&1; then
    mpstat -P ALL 1 5
else
    echo "sysstat/mpstat unavailable"
fi

echo
echo "[ DISK ]"
lsblk -o NAME,MODEL,SIZE,ROTA,FSTYPE,MOUNTPOINTS,SCHED 2>/dev/null || true

echo
echo "[ FILESYSTEM ]"
findmnt -t ext4,xfs 2>/dev/null || true

echo
echo "[ DISK I/O ]"
if command -v iostat >/dev/null 2>&1; then
    iostat -xz 1 3
else
    echo "iostat unavailable"
fi

echo
echo "[ NETWORK ]"
ip -br link 2>/dev/null || true

echo
echo "[ NETWORK ERRORS ]"
for iface in /sys/class/net/*; do
    name="$(basename "$iface")"
    [[ "$name" == "lo" ]] && continue

    echo "--- $name ---"
    ip -s link show "$name" 2>/dev/null |
        grep -A2 -E 'RX:|TX:' || true
done

echo
echo "[ DOCKER ]"
if command -v docker >/dev/null 2>&1; then
    docker info 2>/dev/null |
        grep -E \
        'Server Version|Storage Driver|Logging Driver|Cgroup Driver|Cgroup Version|CPUs|Total Memory' \
        || true

    echo
    docker stats --no-stream 2>/dev/null || true
else
    echo "Docker unavailable"
fi

echo
echo "[ WINGS ]"
if systemctl list-unit-files 2>/dev/null |
    grep -q '^wings.service'; then

    systemctl is-active wings || true

    echo
    journalctl -u wings \
        --since "30 minutes ago" \
        --no-pager 2>/dev/null |
        grep -Ei 'error|failed|oom|panic|fatal' |
        tail -30 ||
        true
else
    echo "Wings unavailable"
fi

echo
echo "[ PRESSURE ]"

if [[ -f /proc/pressure/cpu ]]; then
    echo "--- CPU ---"
    cat /proc/pressure/cpu
fi

if [[ -f /proc/pressure/memory ]]; then
    echo "--- MEMORY ---"
    cat /proc/pressure/memory
fi

if [[ -f /proc/pressure/io ]]; then
    echo "--- IO ---"
    cat /proc/pressure/io
fi

echo
echo "============================================================"
echo "                    DIAGNOSTICS COMPLETE"
echo "============================================================"
