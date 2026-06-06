#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ██████╗ ███████╗ ██████╗ ███╗   ██╗
# ██╔══██╗██╔════╝██╔═══██╗████╗  ██║
# ██████╔╝█████╗  ██║   ██║██╔██╗ ██║
# ██╔══██╗██╔══╝  ██║   ██║██║╚██╗██║
# ██║  ██║███████╗╚██████╔╝██║ ╚████║
# ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═══╝
#      R E O N   D E V
# ═══════════════════════════════════════════════════════════════════════════════
#  VPS OPTIMIZER v2.0 — Ubuntu/Debian Minecraft Server Performance Tuning
#  For Authorized System Administration
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────────────
BACKUP_DIR="/root/vps-optimizer-backups-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/vps-optimizer.log"
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_DIR="${MINECRAFT_DIR:-/opt/minecraft}"
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB / 1024))
RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
CPU_CORES=$(nproc)

# ─── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error(){ echo -e "${RED}[X]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}[*]${NC} $*" | tee -a "$LOG_FILE"; }
header(){ echo -e "\n${MAGENTA}${BOLD}━━━ $* ━━━${NC}\n"; }

# ─── Root Check ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)."
        exit 1
    fi
}

# ─── OS Detection ─────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="$VERSION_ID"
    else
        OS="unknown"
        OS_VERSION="unknown"
    fi
    info "Detected OS: $OS $OS_VERSION"
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        warn "Designed for Ubuntu/Debian. Your OS ($OS) may have issues."
    fi
}

# ─── Backup ────────────────────────────────────────────────────────────────────
backup_system() {
    header "Creating System Configuration Backup"
    mkdir -p "$BACKUP_DIR"
    log "Backup directory: $BACKUP_DIR"

    local files=(
        "/etc/sysctl.conf" "/etc/security/limits.conf"
        "/etc/systemd/logind.conf" "/etc/default/grub"
        "/etc/fstab" "/etc/ntp.conf"
    )
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && cp "$f" "$BACKUP_DIR/" 2>/dev/null || true
    done
    [[ -d /etc/sysctl.d ]] && cp -r /etc/sysctl.d "$BACKUP_DIR/sysctl.d" 2>/dev/null || true
    log "Backup saved to $BACKUP_DIR"
}

# ─── System Updates ───────────────────────────────────────────────────────────
update_system() {
    header "System Updates & Tools Installation"
    log "Updating package lists..."
    apt-get update -qq 2>/dev/null
    log "Upgrading packages..."
    apt-get upgrade -y -qq 2>/dev/null
    log "Installing performance tools..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        cpufrequtils irqbalance htop iotop sysstat linux-tools-common \
        linux-tools-generic ethtool haveged earlyoom preload 2>/dev/null || true
    log "System updated and tools installed."
}

# ─── CPU Governor — Performance Mode ─────────────────────────────────────────
optimize_cpu_governor() {
    header "CPU Governor — Forcing Performance Mode"
    info "CPU Cores: $CPU_CORES"
    local cur_gov
    cur_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    info "Current governor: $cur_gov"

    # Set performance now
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > "$cpu" 2>/dev/null || true
    done
    log "CPU governor set to: ${GREEN}performance${NC}"

    # Persist
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
    systemctl disable ondemand 2>/dev/null || true
    systemctl enable cpufrequtils 2>/dev/null || true
    systemctl restart cpufrequtils 2>/dev/null || true

    # IRQ balancer — distribute interrupts across all cores
    if command -v irqbalance &>/dev/null; then
        cat > /etc/default/irqbalance << 'IRQEOF'
ENABLED="yes"
IRQBALANCE_BANNED_CPUS=""
IRQBALANCE_ARGS="--powerthresh=0 --hintpolicy=exact"
IRQEOF
        systemctl enable irqbalance 2>/dev/null || true
        systemctl restart irqbalance 2>/dev/null || true
        log "irqbalance configured for performance."
    fi
}

# ─── Kernel Parameters — Low Latency ──────────────────────────────────────────
optimize_kernel() {
    header "Kernel Network & Memory Optimization"

    cat > /etc/sysctl.d/99-minecraft-lowlatency.conf << 'SYSCTL'
# ═══════════════════════════════════════════════════════════════════════════════
# Minecraft Server — Ultra Low Latency Kernel Tuning
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Network Buffers ─────────────────────────────────────────────────────────
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 50000
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_timestamps = 0

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_local_reserved_ports = 25565,25575,25580-25589

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.core.busy_poll = 50
net.core.busy_read = 50

# ─── Memory / VM ─────────────────────────────────────────────────────────────
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
vm.swappiness = 1
vm.vfs_cache_pressure = 200
vm.min_free_kbytes = 131072
vm.extra_free_kbytes = 65536
vm.zone_reclaim_mode = 1
kernel.numa_balancing = 0
vm.max_map_count = 1048576

# ─── File System ─────────────────────────────────────────────────────────────
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768

# ─── CPU Scheduler ───────────────────────────────────────────────────────────
kernel.sched_min_granularity_ns = 5000000
kernel.sched_wakeup_granularity_ns = 6000000
kernel.sched_migration_cost_ns = 2500000
kernel.sched_child_runs_first = 1
kernel.sched_latency_ns = 10000000
kernel.sched_nr_migrate = 4
kernel.timer_migration = 1
kernel.sched_autogroup_enabled = 1

# ─── Kernel / Debug ──────────────────────────────────────────────────────────
kernel.printk = 3 3 3 3
kernel.core_uses_pid = 1
fs.suid_dumpable = 0
kernel.shmmax = 17179869184
kernel.shmall = 4194304
vm.overcommit_memory = 1
vm.overcommit_ratio = 50
SYSCTL

    # Apply
    sysctl --system 2>/dev/null | grep -v "net.core.busy" || true
    sysctl -p /etc/sysctl.d/99-minecraft-lowlatency.conf 2>/dev/null || true
    log "Kernel parameters optimized. BBR congestion control enabled."
}

# ─── Disk I/O Optimization ────────────────────────────────────────────────────
optimize_disk_io() {
    header "Disk I/O Optimization"

    local disk_dev
    disk_dev=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]//g')
    [[ -z "$disk_dev" ]] && disk_dev=$(lsblk -d -o name | tail -1)
    local disk_path="/sys/block/$(basename "$disk_dev")"

    if [[ -d "$disk_path" ]]; then
        local rotational
        rotational=$(cat "$disk_path/queue/rotational" 2>/dev/null || echo 1)
        if [[ "$rotational" == "0" ]]; then
            log "SSD detected → scheduler: none, readahead: 4096K"
            echo "none"      > "$disk_path/queue/scheduler"    2>/dev/null || true
            echo "256"       > "$disk_path/queue/nr_requests"  2>/dev/null || true
            echo "4096"      > "$disk_path/queue/read_ahead_kb" 2>/dev/null || true
        else
            log "HDD detected → scheduler: deadline, readahead: 2048K"
            echo "deadline"  > "$disk_path/queue/scheduler"     2>/dev/null || true
            echo "512"       > "$disk_path/queue/nr_requests"   2>/dev/null || true
            echo "2048"      > "$disk_path/queue/read_ahead_kb" 2>/dev/null || true
        fi
        echo "0" > "$disk_path/queue/iostats"     2>/dev/null || true
        echo "2" > "$disk_path/queue/rq_affinity" 2>/dev/null || true
    fi

    # Disable auditd — heavy disk writer
    if systemctl is-enabled auditd &>/dev/null; then
        systemctl stop auditd 2>/dev/null || true
        systemctl disable auditd 2>/dev/null || true
        log "auditd disabled (reduces disk writes significantly)."
    fi

    # noatime + nodiratime for all ext4 mounts
    if grep -q "ext4" /etc/fstab 2>/dev/null; then
        sed -i 's/errors=remount-ro/errors=remount-ro,noatime,nodiratime/' /etc/fstab 2>/dev/null || true
        log "noatime,nodiratime added to fstab."
    fi

    # tmpfs for volatile directories
    if ! grep -q "/tmp.*tmpfs" /etc/fstab 2>/dev/null; then
        cat >> /etc/fstab << 'TMPFS'
tmpfs /tmp      tmpfs defaults,noatime,nosuid,nodev,noexec,size=1G 0 0
tmpfs /var/log  tmpfs defaults,noatime,nosuid,nodev,noexec,size=512M 0 0
tmpfs /var/tmp  tmpfs defaults,noatime,nosuid,nodev,noexec,size=512M 0 0
TMPFS
        log "tmpfs mounts added for /tmp, /var/log, /var/tmp."
    fi
}

# ─── Memory, Swap & THP ───────────────────────────────────────────────────────
optimize_memory() {
    header "Memory & Swap Optimization"
    info "Total RAM: ${RAM_TOTAL_MB}MB (${RAM_TOTAL_GB}GB)"
    local suggested_heap=$((RAM_TOTAL_GB * 75 / 100))
    info "Suggested Minecraft heap: ${suggested_heap}GB"

    # EarlyOOM
    if command -v earlyoom &>/dev/null; then
        cat > /etc/default/earlyoom << 'EOF'
EARLYOOM_ARGS="-m 5 -s 10 -r 60 -n --prefer '(java|minecraft)' --avoid '(systemd|sshd|bash)'"
EOF
        systemctl enable earlyoom 2>/dev/null || true
        systemctl restart earlyoom 2>/dev/null || true
        log "earlyoom configured (kill at 5% RAM, prefer Java)."
    fi

    # Swap
    if [[ $RAM_TOTAL_GB -ge 4 ]]; then
        swapoff -a 2>/dev/null || true
        log "Swap disabled (${RAM_TOTAL_GB}GB RAM sufficient)."
    else
        warn "Low RAM (${RAM_TOTAL_GB}GB). Creating 1G swap file."
        if [[ ! -f /swapfile ]]; then
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
            chmod 600 /swapfile
            mkswap /swapfile 2>/dev/null
            swapon /swapfile 2>/dev/null
        fi
    fi

    # Disable Transparent Huge Pages
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
        echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
        log "Transparent Huge Pages disabled (prevents Java GC latency spikes)."
    fi

    # systemd unit to persist THP disable across reboots
    cat > /etc/systemd/system/disable-thp.service << 'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
THPEOF
    systemctl daemon-reload
    systemctl enable disable-thp 2>/dev/null || true
    systemctl start disable-thp 2>/dev/null || true

    # Preload
    if command -v preload &>/dev/null; then
        systemctl enable preload 2>/dev/null || true
        systemctl restart preload 2>/dev/null || true
        log "preload enabled."
    fi

    # File descriptor limits
    cat > /etc/security/limits.d/99-minecraft.conf << 'LIMEOF'
minecraft    soft    nofile    2097152
minecraft    hard    nofile    2097152
minecraft    soft    nproc     65536
minecraft    hard    nproc     65536
minecraft    soft    memlock   unlimited
minecraft    hard    memlock   unlimited
*            soft    nofile    2097152
*            hard    nofile    2097152
*            soft    nproc     65536
*            hard    nproc     65536
LIMEOF
    log "File descriptor limits raised to 2,097,152."
}

# ─── Network Interface ────────────────────────────────────────────────────────
optimize_network_interface() {
    header "Network Interface Optimization"
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
    iface="${iface:-eth0}"
    info "Primary interface: $iface"

    if command -v ethtool &>/dev/null; then
        ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null && log "Ring buffers: rx=4096 tx=4096" || true
        ethtool -C "$iface" rx-usecs 1 tx-usecs 1 2>/dev/null && log "Coalescing: 1μs" || true
        ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || true
        log "ethtool optimizations applied."
    fi

    # Disable IPv6
    if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) == "0" ]]; then
        cat > /etc/sysctl.d/99-disable-ipv6.conf << 'IPV6EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6EOF
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true
        log "IPv6 disabled."
    fi

    # haveged for entropy
    if command -v haveged &>/dev/null; then
        systemctl enable haveged 2>/dev/null || true
        systemctl restart haveged 2>/dev/null || true
        log "haveged enabled (entropy pool)."
    fi
}

# ─── Disable Bloat Services ───────────────────────────────────────────────────
disable_bloat_services() {
    header "Disabling Unnecessary Services"

    local services=(
        cups cups-browsed bluetooth bluez avahi-daemon
        whoopsie apport ModemManager accounts-daemon
        colord packagekit pulseaudio speech-dispatcher
        switcheroo-control cups-core-drivers sane-utils
        hplip systemd-resolved unattended-upgrades
        snapd snapd.apparmor fwupd
    )

    local count=0
    for svc in "${services[@]}"; do
        if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            ((count++))
        fi
    done

    log "Disabled $count unnecessary services."

    # Remove snapd aggressively (memory hog)
    if dpkg -l snapd &>/dev/null 2>&1; then
        apt-get purge -y snapd 2>/dev/null || true
        rm -rf /var/lib/snapd /snap /var/snap 2>/dev/null || true
        log "snapd purged (saves ~200MB RAM)."
    fi

    # Mask packagekit if still running
    systemctl mask packagekit 2>/dev/null || true
    systemctl mask packagekit-offline-update 2>/dev/null || true
}

# ─── Java / Aikar's Flags Generator ───────────────────────────────────────────
generate_aikar_flags() {
    header "Minecraft Aikar's Flags Generator"

    local ram_gb=$RAM_TOTAL_GB
    local heap_gb=$((ram_gb * 75 / 100))
    [[ $heap_gb -lt 2 ]] && heap_gb=2
    [[ $heap_gb -gt 32 ]] && heap_gb=32

    # Memory for G1GC region sizing
    local g1_regions=$(( heap_gb * 1024 / 2 ))
    [[ $g1_regions -lt 1 ]] && g1_regions=1

    local flags="# ═══════════════════════════════════════════════════════════════
# Aikar's Flags — Minecraft JVM Optimization
# Heap: ${heap_gb}G | CPU: ${CPU_CORES} cores
# ═══════════════════════════════════════════════════════════════════
java -Xms${heap_gb}G -Xmx${heap_gb}G \\
    -XX:+UseG1GC \\
    -XX:+ParallelRefProcEnabled \\
    -XX:MaxGCPauseMillis=200 \\
    -XX:+UnlockExperimentalVMOptions \\
    -XX:+DisableExplicitGC \\
    -XX:+AlwaysPreTouch \\
    -XX:G1HeapWastePercent=5 \\
    -XX:G1MixedGCCountTarget=4 \\
    -XX:G1MixedGCLiveThresholdPercent=85 \\
    -XX:G1RSetUpdatingPauseTimePercent=5 \\
    -XX:SurvivorRatio=32 \\
    -XX:+PerfDisableSharedMem \\
    -XX:MaxTenuringThreshold=1 \\
    -XX:G1NewSizePercent=30 \\
    -XX:G1MaxNewSizePercent=40 \\
    -XX:G1HeapRegionSize=${g1_regions}M \\
    -XX:G1ReservePercent=20 \\
    -XX:+UseStringDeduplication \\
    -XX:+OptimizeStringConcat \\
    -XX:+UseCompressedOops \\
    -XX:+UseLargePages \\
    -XX:LargePageSizeInBytes=2m \\
    -Dfile.encoding=UTF-8 \\
    -Duser.timezone=UTC \\
    -jar server.jar nogui"

    echo "$flags" > /root/minecraft-aikar-flags.txt
    log "Aikar's Flags saved to ${GREEN}/root/minecraft-aikar-flags.txt${NC}"

    # Also generate a systemd service template
    cat > /etc/systemd/system/minecraft.service.template << 'SERVEOF'
[Unit]
Description=Minecraft Server
After=network.target

[Service]
User=minecraft
Group=minecraft
WorkingDirectory=/opt/minecraft
ExecStart=/usr/bin/java -Xms${heap}G -Xmx${heap}G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:G1MixedGCLiveThresholdPercent=85 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=${regions}M -XX:G1ReservePercent=20 -XX:+UseStringDeduplication -XX:+OptimizeStringConcat -XX:+UseCompressedOops -XX:+UseLargePages -XX:LargePageSizeInBytes=2m -Dfile.encoding=UTF-8 -Duser.timezone=UTC -jar server.jar nogui
Restart=on-failure
RestartSec=10
Nice=-10
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitNOFILE=2097152
LimitNPROC=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
SERVEOF
    sed -i "s/\${heap}/$heap_gb/g; s/\${regions}/$g1_regions/g" /etc/systemd/system/minecraft.service.template
    log "Minecraft systemd service template created."
}

# ─── GRUB Boot Parameters ─────────────────────────────────────────────────────
optimize_grub() {
    header "GRUB Boot Parameters"

    local grub_file="/etc/default/grub"
    [[ ! -f "$grub_file" ]] && return

    local current
    current=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" 2>/dev/null | sed 's/GRUB_CMDLINE_LINUX_DEFAULT=//g; s/"//g')
    info "Current: $current"

    local addopts="mitigations=off intel_pstate=disable processor.max_cstate=1 intel_idle.max_cstate=0 idle=poll nowatchdog nmi_watchdog=0 rcu_nocbs=0-${CPU_CORES} nohz_full=0-${CPU_CORES} skew_tick=1"
    local newline="GRUB_CMDLINE_LINUX_DEFAULT=\"$current $addopts\""

    # Don't duplicate if already applied
    if ! echo "$current" | grep -q "mitigations=off"; then
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file"; then
            sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/$newline/" "$grub_file"
        else
            echo "$newline" >> "$grub_file"
        fi
        log "Boot parameters added: mitigations=off, idle=poll, nowatchdog, nohz_full"
        update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        log "GRUB updated. Reboot recommended to apply."
    else
        log "Boot parameters already optimized. Skipping."
    fi
}

# ─── Report ────────────────────────────────────────────────────────────────────
show_report() {
    header "Optimization Summary"
    echo -e "${BOLD}System Info:${NC}"
    echo "  OS:         $OS $OS_VERSION"
    echo "  CPU Cores:  $CPU_CORES"
    echo "  RAM:        ${RAM_TOTAL_MB}MB (${RAM_TOTAL_GB}GB)"
    echo "  Disk:       $(df -h / | tail -1 | awk '{print $2}') total, $(df -h / | tail -1 | awk '{print $4}') free"
    echo ""
    echo -e "${BOLD}Applied Optimizations:${NC}"
    echo "  ✓ CPU Governor       → performance"
    echo "  ✓ I/O Scheduler      → $(cat /sys/block/$(lsblk -d -o name | tail -1)/queue/scheduler 2>/dev/null | grep -o '\[.*\]' || echo 'N/A')"
    echo "  ✓ Kernel             → low-latency sysctl parameters"
    echo "  ✓ Network            → BBR + ethtool tuning"
    echo "  ✓ Memory             → THP disabled, earlyoom configured"
    echo "  ✓ Disk               → noatime, tmpfs for logs"
    echo "  ✓ Services           → bloat removed"
    echo "  ✓ File Descriptors   → 2,097,152"
    echo "  ✓ JVM Flags          → /root/minecraft-aikar-flags.txt"
    echo "  ✓ Minecraft Service  → /etc/systemd/system/minecraft.service.template"
    echo ""
    echo -e "${YELLOW}⚠  A reboot is recommended to apply GRUB boot parameters.${NC}"
    echo -e "${YELLOW}⚠  Run: sudo reboot${NC}"
    echo ""
    echo -e "${BOLD}Low-Ping Checklist for Minecraft:${NC}"
    echo "  1. Use PaperMC/Purpur instead of vanilla"
    echo "  2. Apply Aikar's flags from /root/minecraft-aikar-flags.txt"
    echo "  3. Place server in ${GREEN}/opt/minecraft${NC} owned by user 'minecraft'"
    echo "  4. Use the systemd service template for automatic restarts"
    echo "  5. Set server.properties: network-compression-threshold=512"
    echo "  6. Choose a VPS close to your players (geographic latency matters)"
    echo "  7. Use PaperMC's 'lag-profiler' to identify bottlenecks"
    echo ""
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "${MAGENTA}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║        VPS OPTIMIZER v2.0 — Minecraft Edition               ║"
    echo "  ║     Ubuntu/Debian — Low Latency Performance Tuning           ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    detect_os
    backup_system
    update_system
    optimize_cpu_governor
    optimize_kernel
    optimize_disk_io
    optimize_memory
    optimize_network_interface
    disable_bloat_services
    generate_aikar_flags
    optimize_grub
    show_report

    log "VPS Optimization complete! Log: $LOG_FILE"
}

main "$@"
