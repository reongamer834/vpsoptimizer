#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ██████╗ ███████╗ ██████╗ ███╗   ██╗
# ██╔══██╗██╔════╝██╔═══██╗████╗  ██║
# ██████╔╝█████╗  ██║   ██║██╔██╗ ██║
# ██╔══██╗██╔══╝  ██║   ██║██║╚██╗██║
# ██║  ██║███████╗╚██████╔╝██║ ╚████║
# ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═══╝
#           R E O N   D E V
# ═══════════════════════════════════════════════════════════════════════════════
#  VPS OPTIMIZER — Ubuntu/Debian Minecraft Server Performance Tuning
#  Authorized Penetration Testing & System Hardening Tool
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
NC='\033[0m' # No Color

# ─── Configuration ────────────────────────────────────────────────────────────
BACKUP_DIR="/root/vps-optimizer-backups-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/vps-optimizer.log"
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_DIR="${MINECRAFT_DIR:-/opt/minecraft}"
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB / 1024))
RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
CPU_CORES=$(nproc)
DISK_ROTATIONAL=$(cat /sys/block/$(lsblk -d -o name | tail -1)/queue/rotational 2>/dev/null || echo 1)

# ─── Logging ──────────────────────────────────────────────────────────────────
log() { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[X]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}[*]${NC} $*" | tee -a "$LOG_FILE"; }
header() { echo -e "\n${MAGENTA}${BOLD}━━━ $* ━━━${NC}\n"; }

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
        warn "This script is designed for Ubuntu/Debian. Your OS ($OS) may have compatibility issues."
    fi
}

# ─── Backup System Files ──────────────────────────────────────────────────────
backup_system() {
    header "Creating System Backup"
    
    mkdir -p "$BACKUP_DIR"
    log "Backup directory: $BACKUP_DIR"
    
    # Backup critical config files
    local files=(
        "/etc/sysctl.conf"
        "/etc/security/limits.conf"
        "/etc/systemd/logind.conf"
        "/etc/default/grub"
        "/etc/fstab"
        "/etc/ntp.conf"
        "/etc/needrestart/needrestart.conf"
    )
    
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            cp "$f" "$BACKUP_DIR/" 2>/dev/null || true
        fi
    done
    
    # Backup sysctl.d
    if [[ -d /etc/sysctl.d ]]; then
        cp -r /etc/sysctl.d "$BACKUP_DIR/sysctl.d" 2>/dev/null || true
    fi
    
    log "System configuration backed up to $BACKUP_DIR"
}

# ─── System Updates ───────────────────────────────────────────────────────────
update_system() {
    header "System Updates"
    
    log "Updating package lists..."
    apt-get update -qq 2>/dev/null
    
    log "Upgrading system packages..."
    apt-get upgrade -y -qq 2>/dev/null
    
    log "Installing performance tools..."
    apt-get install -y -qq \
        cpufrequtils \
        irqbalance \
        htop \
        iotop \
        sysstat \
        linux-tools-common \
        linux-tools-generic \
        ethtool \
        haveged \
        tuned \
        earlyoom \
        preload 2>/dev/null || true
    
    log "System packages updated and performance tools installed."
}

# ─── CPU Governor — Performance Mode ─────────────────────────────────────────
optimize_cpu_governor() {
    header "CPU Governor Optimization"
    
    info "CPU Cores: $CPU_CORES"
    info "Current governor(s): $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
    
    # Set performance governor
    if command -v cpupower &>/dev/null; then
        cpupower frequency-set -g performance 2>/dev/null || true
    fi
    
    # Fallback: manually set each CPU
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > "$cpu" 2>/dev/null || true
    done
    
    log "CPU governor set to: ${GREEN}performance${NC}"
    
    # Make persistent
    if [[ -f /etc/default/cpufrequtils ]]; then
        cp "$BACKUP_DIR/cpufrequtils" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
    
    # Disable ondemand service
    systemctl disable ondemand 2>/dev/null || true
    systemctl enable cpufrequtils 2>/dev/null || true
    
    # Configure IRQ balance for performance
    if command -v irqbalance &>/dev/null; then
        cat > /etc/default/irqbalance << 'EOF'
ENABLED="yes"
IRQBALANCE_BANNED_CPUS=""
IRQBALANCE_ARGS="--powerthresh=0 --hintpolicy=exact"
EOF
        systemctl enable irqbalance 2>/dev/null || true
        systemctl restart irqbalance 2>/dev/null || true
        log "IRQ balance configured for performance."
    fi
}

# ─── Kernel Parameters (sysctl) — Ultra Low Latency ──────────────────────────
optimize_kernel() {
    header "Kernel Network & Memory Optimization"
    
    cat > /etc/sysctl.d/99-minecraft-lowlatency.conf << 'SYSCTL_EOF'
# ═══════════════════════════════════════════════════════════════════════════════
# Minecraft Server — Ultra Low Latency Kernel Tuning
# ═══════════════════════════════════════════════════════════════════════════════

# ─── TCP/UDP Network Stack ─────────────────────────────────────────────────────
# Reduce minimum TCP buffer sizes for faster small-packet handling
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# TCP low latency mode - prioritize latency over throughput
net.ipv4.tcp_low_latency = 1

# Disable slow start after idle - instant full speed
net.ipv4.tcp_slow_start_after_idle = 0

# Enable TCP Fast Open (client+server)
net.ipv4.tcp_fastopen = 3

# Increase TCP backlog
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 50000
net.ipv4.tcp_max_syn_backlog = 65535

# Aggressive TCP keepalive
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3

# Enable TCP window scaling
net.ipv4.tcp_window_scaling = 1

# Enable selective ACKs
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Enable MTU probing
net.ipv4.tcp_mtu_probing = 1

# Faster connection recycling
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5

# Disable TCP timestamps (saves CPU, minor security trade-off)
net.ipv4.tcp_timestamps = 0

# Increase local port range
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_local_reserved_ports = 25565,25575,25580-25589

# Congestion control: BBR for best latency/throughput
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ─── UDP specifics ────────────────────────────────────────────────────────────
# Increase UDP buffer sizes (important for Minecraft protocol)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ─── Network Busy Polling ──────────────────────────────────────────────────────
# Reduces latency for network-heavy applications
net.core.busy_poll = 50
net.core.busy_read = 50

# ─── Memory Management ────────────────────────────────────────────────────────
# Aggressive I/O - minimize disk cache latency
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100

# Reduce swapping to near zero
vm.swappiness = 1
vm.vfs_cache_pressure = 200

# Keep minimum free memory for system stability
vm.min_free_kbytes = 131072
vm.extra_free_kbytes = 65536

# Reduce page allocation latency
vm.zone_reclaim_mode = 1

# Disable NUMA balancing (can cause latency spikes)
kernel.numa_balancing = 0

# Optimize page table recycling
vm.max_map_count = 1048576

# ─── File System ──────────────────────────────────────────────────────────────
# Increase file handles and inotify watches
fs.file-max = 2097152
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768

# ─── CPU Scheduler ────────────────────────────────────────────────────────────
# Reduce scheduler latency for interactive workloads
kernel.sched_min_granularity_ns = 5000000
kernel.sched_wakeup_granularity_ns = 6000000
kernel.sched_migration_cost_ns = 2500000
kernel.sched_child_runs_first = 1
kernel.sched_latency_ns = 10000000

# Prefer SCHED_OTHER tasks for lower latency
kernel.sched_nr_migrate = 4

# ─── Kernel General ───────────────────────────────────────────────────────────
# Reduce kernel timer frequency overhead
kernel.timer_migration = 1

# Enable CPU frequency notification (for performance governor)
kernel.sched_autogroup_enabled = 1

# Reduce kernel log verbosity (less I/O contention)
kernel.printk = 3 3 3 3

# Disable core dumps (wasteful I/O for game servers)
kernel.core_uses_pid = 1
fs.suid_dumpable = 0

# Shared memory for Java
kernel.shmmax = 17179869184
kernel.shmall = 4194304

# ─── Virtual Memory / OOM ────────────────────────────────────────────────────
# Prefer killing largest process (Minecraft) over system hangs
vm.overcommit_memory = 1
vm.overcommit_ratio = 50
SYSCTL_EOF

    # Apply immediately
    sysctl --system 2>/dev/null | grep -v "net.core.busy" || true
    sysctl -p /etc/sysctl.d/99-minecraft-lowlatency.conf 2>/dev/null || true
    
    log "Kernel parameters optimized for low-latency Minecraft."
    log "BBR congestion control enabled."
}

# ─── Disk & I/O Optimization ──────────────────────────────────────────────────
optimize_disk_io() {
    header "Disk I/O Optimization"
    
    # Detect disk type
    local disk_dev
    disk_dev=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]//g' || echo "")
    
    if [[ -z "$disk_dev" ]]; then
        disk_dev=$(lsblk -d -o name | tail -1)
    fi
    
    local disk_path="/sys/block/$(basename "$disk_dev")"
    
    if [[ -d "$disk_path" ]]; then
        local rotational
        rotational=$(cat "$disk_path/queue/rotational" 2>/dev/null || echo 1)
        
        if [[ "$rotational" == "0" ]]; then
            log "Detected SSD/NVMe storage."
            # SSD optimizations
            echo "none" > "$disk_path/queue/scheduler" 2>/dev/null || true
            echo "256" > "$disk_path/queue/nr_requests" 2>/dev/null || true
            echo "4096" > "$disk_path/queue/read_ahead_kb" 2>/dev/null || true
            log "I/O scheduler: ${GREEN}none${NC} (NVMe/SSD optimal)"
        else
            log "Detected HDD storage."
            # HDD optimizations
            echo "deadline" > "$disk_path/queue/scheduler" 2>/dev/null || true
            echo "512" > "$disk_path/queue/nr_requests" 2>/dev/null || true
            echo "2048" > "$disk_path/queue/read_ahead_kb" 2>/dev/null || true
            log "I/O scheduler: ${YELLOW}deadline${NC} (HDD optimal)"
        fi
        
        # Common optimizations
        echo "0" > "$disk_path/queue/iostats" 2>/dev/null || true
        echo "2" > "$disk_path/queue/rq_affinity" 2>/dev/null || true
    fi
    
    # Disable auditd for less disk I/O
    if systemctl is-enabled auditd &>/dev/null; then
        systemctl stop auditd 2>/dev/null || true
        systemctl disable auditd 2>/dev/null || true
        log "auditd disabled (reduces disk writes)."
    fi
    
    # Optimize fstab — noatime + discard for SSDs
    local fstab_file="/etc/fstab"
    if grep -q "ext4" "$fstab_file" 2>/dev/null; then
        sed -i 's/errors=remount-ro/errors=remount-ro,noatime,nodiratime/' "$fstab_file" 2>/dev/null || true
        log "Added noatime,nodiratime mount options to fstab."
    fi
    
    # Disable filesystem journaling on temp directories
    if ! grep -q "/tmp" "$fstab_file" 2>/dev/null | grep -q "tmpfs"; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec 0 0" >> "$fstab_file"
        echo "tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,noexec,size=512M 0 0" >> "$fstab_file"
        echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,noexec 0 0" >> "$fstab_file"
        log "Added tmpfs mounts for /tmp, /var/log, /var/tmp (reduces disk I/O)."
    fi
}

# ─── Memory & Swap Optimization ───────────────────────────────────────────────
optimize_memory() {
    header "Memory Management Optimization"
    
    local ram_gb=$RAM_TOTAL_GB
    local suggested_heap=$((ram_gb * 75 / 100)) # 75% of RAM for Minecraft
    
    info "Total RAM: ${RAM_TOTAL_MB}MB (${ram_gb}GB)"
    info "Suggested Minecraft heap: ${suggested_heap}GB"
    
    # EarlyOOM for faster OOM killing
    if command -v earlyoom &>/dev/null; then
        cat > /etc/default/earlyoom << 'EOF'
EARLYOOM_ARGS="-m 5 -s 10 -r 60 -n --prefer '(java|minecraft)' --avoid '(systemd|sshd|bash)'"
EOF
        systemctl enable earlyoom 2>/dev/null || true
        systemctl restart earlyoom 2>/dev/null || true
        log "earlyoom configured: kills at 5% memory, reports at 60s intervals."
    fi
    
    # Disable swap unless absolutely necessary
    if [[ $ram_gb -ge 4 ]]; then
        swapoff -a 2>/dev/null || true
        log "Swap disabled (${ram_gb}GB RAM sufficient)."
    else
        warn "Low RAM detected (${ram_gb}GB). Configuring minimal swap."
        # Small swap file on SSD
        if [[ ! -f /swapfile ]]; then
            dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile 2>/dev/null
            swapon /swapfile 2>/dev/null
            log "Created 1GB swap file."
        fi
    fi
    
    # Disable transparent hugepages (causes latency spikes in Java)
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
        echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
        log "Transparent Huge Pages: ${GREEN}disabled${NC} (prevents Java GC latency spikes)."
    fi
    
    # Make THP disable persistent
    cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable disable-thp 2>/dev/null || true
    systemctl start disable-thp 2>/dev/null || true
    
    # Preload — cache frequently used libraries
    if command -v preload &>/dev/null; then
        systemctl enable preload 2>/dev/null || true
        systemctl restart preload 2>/dev/null || true
        log "preload enabled (faster library loading)."
    fi
    
    # Ulimits for Minecraft user
    cat >> /etc/security/limits.d/99-minecraft.conf << 'EOF'
# Minecraft server limits
minecraft    soft    nofile    2097152
minecraft    hard    nofile    2097152
minecraft    soft    nproc     65536
minecraft    hard    nproc     65536
minecraft    soft    memlock   unlimited
minecraft    hard    memlock   unlimited
minecraft    soft    as        unlimited
minecraft    hard    as        unlimited
*            soft    nofile    2097152
*            hard    nofile    2097152
*            soft    nproc     65536
*            hard    nproc     65536
EOF
    log "File descriptor limits increased to 2,097,152."
}

# ─── Network Interface Optimization ───────────────────────────────────────────
optimize_network() {
    header "Network Interface Optimization"
    
    # Get default interface
    local iface
    iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null || echo "eth0")
    
    info "Primary interface: $iface"
    
    # Optimize with ethtool
    if command -v ethtool &>/dev/null; then
        # Increase ring buffer sizes
        ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null && \
            log "Ring buffers increased: rx=4096 tx=4096" || \
            warn "Could not increase ring buffers (unsupported)."
        
        # Increase coalescing for more interrupts per second
        ethtool -C "$iface" rx-usecs 1 tx-usecs 1 2>/dev/null && \
            log "Interrupt coalescing set to 1us (microseconds)." || \
            warn "Could not set interrupt coalescing."
        
        # Adaptive RX/TX
        ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || true
        
        # Increase ring parameters
        ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
        
        # Set network card to max speed
        ethtool -s "$iface" speed 10000 duplex full autoneg on 2>/dev/null || \
        ethtool -s "$iface" speed 1000 duplex full autoneg on 2>/dev/null || true
        
        log "Network interface $iface optimized."
    fi
    
    # Systemd network tweaks
    cat > /etc/systemd/networkd.conf.d/99-minecraft.conf << 'EOF'
[Network]
SpeedMeter=yes
SpeedMeterIntervalSec=1sec
EOF
    
    # Disable IPv6 (reduces overhead, prevents double-stack latency)
    if sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "0"; then
        cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null || true
        log "IPv6 disabled (reduces network stack overhead)."
    fi
    
    # Enable haveged for better entropy (affects crypto/RNG latency)
    if command -v haveged &>/dev/null; then
        systemctl enable haveged 2>/dev/null || true
        systemctl restart haveged 2>/dev/null || true
        log "haveged enabled (improves entropy pool, reduces random-blocking)."
    fi
}

# ─── Disable Unnecessary Services ────────────────────────────────────────────
disable_bloat() {
    header "Disabling Unnecessary Services"
    
    local services_to_disable=(
        # Desktop/services not needed on a game server VPS
        "cups" "cups-browsed"
        "bluetooth" "bluez"
        "avahi-daemon"
        "whoopsie"
        "apport"
        "ModemManager"
        "accounts-daemon"
        "colord"
        "packagekit"
        "pulseaudio"
        "speech-dispatcher"
        "switcheroo-control"
        "upower"
        "udisks2"
        "zeitgeist"
        "vmtoolsd" 2>/dev/null || true
        # Postfix/mail - not needed for game server
        "postfix" "sendmail"
        # NFS/Samba file sharing
        "nfs-server" "nfs-kernel-server"
        "smbd" "nmbd"
        # Printing
        "cups" "cups-browsed"
        # Other
        "apt-daily-upgrade.timer"
        "apt-daily.timer"
        "unattended-upgrades"
        "motd-news.timer"
    )
    
    local count=0
