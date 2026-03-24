#!/usr/bin/env bash
#
# Version: 4.0.6 - 03/2026
# Thomas-Krenn.AG - Proxmox VE Support Log Collector
# Author: Samuel Mueller
# Contact: smueller@thomas-krenn.com
#
# Purpose:
#   This script collects diagnostically relevant system information from
#   Proxmox VE hosts to make error situations more reproducible, faster, and
#   easier to analyze for support. Execution is read-only, except for the
#   optional installation of tools such as nvme-cli, ipmitool, etc.
#
# Feature scope:
#   - Two operating modes: Default, --full
#   - Progress output to STDOUT (Collect / Copy / Pack)
#   - Collection of kernel, journal, system, storage, and network data
#   - Aggregation of Proxmox service and VM/CT information
#   - SMART and optional NVMe-SMART data
#   - Ceph information (if present) in its own subfolder
#   - Hardware information (IPMI, thermal) in --full mode
#   - VM/CT configurations, backup, HA, replication in --full mode
#   - Firewall configuration and SSL certificates in --full mode
#   - Performance data (iostat, vmstat, sar) in --full mode
#   - Optional anonymization of IPs, MACs, and hostnames
#   - Storage of used optional tools (_tools_used.txt)
#   - Storage of warnings and notices (_errors.txt)
#   - Checksum generation (SHA256/MD5)
#
# Operating modes:
#   Default   Standard scope: Journal, dmesg, PVE services, network,
#             storage, SMART, Ceph, cluster, VM/CT lists (no flag)
#   --full    Full: Default + hardware (IPMI, thermal), VM/CT configs,
#             firewall, performance, backup/HA/replication
#
# Privacy / GDPR notice:
#   This script can read hostnames, usernames, VM names, and IP addresses.
#   Use --anonymize to anonymize this data before sharing.
#   Review of contents is recommended before sharing with third parties.
#
# Disclaimer:
#   This script serves as a technical aid. Thomas-Krenn.AG assumes no
#   liability for data loss, system behavior, or interpretation errors.
#   Execution should be performed by qualified personnel.
#
# Recommendation:
#   Before execution: Ensure sufficient disk space is available.
#   After execution: Archive generated in local working directory.
#

set -Eeuo pipefail
shopt -s nullglob
shopt -s lastpipe

# ---------- Constants ----------
readonly VERSION="4.0.6"
readonly MIN_DISK_SPACE_MB=500
readonly CMD_TIMEOUT=60

# ---------- Global variables ----------
ERRORS_FILE=""
TOOLS_USED_FILE=""
OUTDIR=""

# ---------- New options (v4.0) ----------
MODE="normal"              # normal|full
VERBOSE="no"               # yes|no
ANONYMIZE="no"             # yes|no
OUTPUT_DIR=""              # Custom output directory
EXCLUDE_SECTIONS=""        # Comma-separated list of sections to exclude
JSON_META="no"             # yes|no - export JSON metadata

# Associative array for missing tools
declare -A MISSING_TOOLS=()

# ---------- Helpers ----------
log()  { printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"; }

warn() {
  local msg
  msg=$(printf '[%s] WARN: %s' "$(date -u +'%F %T UTC')" "$*")
  printf '%s\n' "$msg" >&2
  [[ -n "$ERRORS_FILE" && -f "$ERRORS_FILE" ]] && printf '%s\n' "$msg" >> "$ERRORS_FILE"
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

note_tool_use() {
  [[ -n "$TOOLS_USED_FILE" && -f "$TOOLS_USED_FILE" ]] && echo "$1" >> "$TOOLS_USED_FILE"
  return 0
}

# Improved run function with optional timeout
run() {
  local out="$1"
  shift
  local timeout_cmd=()
  if have timeout; then
    timeout_cmd=(timeout "${CMD_TIMEOUT}s")
  fi
  { "${timeout_cmd[@]}" "$@" >>"$out" 2>&1; } || warn "Error at: $* (see $(basename "$out"))"
}

# Run without timeout (for fast commands)
run_quick() {
  local out="$1"
  shift
  { "$@" >>"$out" 2>&1; } || warn "Error at: $* (see $(basename "$out"))"
}

# ---------- New helper functions (v4.0) ----------

# Verbose logging
log_verbose() {
  [[ "$VERBOSE" == "yes" ]] && printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"
  return 0
}

# Check if a section is excluded
is_excluded() {
  local section="$1"
  [[ -n "$EXCLUDE_SECTIONS" && "$EXCLUDE_SECTIONS" == *"$section"* ]] && return 0
  return 1
}

# Check if mode is at least 'normal' (normal or full)
is_mode_normal_or_full() {
  [[ "$MODE" == "normal" || "$MODE" == "full" ]] && return 0
  return 1
}

# Check if mode is 'full'
is_mode_full() {
  [[ "$MODE" == "full" ]] && return 0
  return 1
}

# Generate checksums for the archive
generate_checksums() {
  local archive="$1"
  
  if have sha256sum; then
    sha256sum "$archive" > "${archive}.sha256"
    log "SHA256: $(cat "${archive}.sha256")"
  elif have md5sum; then
    md5sum "$archive" > "${archive}.md5"
    log "MD5: $(cat "${archive}.md5")"
  fi
}

# Write JSON metadata
write_json_meta() {
  [[ "$JSON_META" != "yes" ]] && return
  
  local tools_json=""
  if [[ -f "$TOOLS_USED_FILE" && -s "$TOOLS_USED_FILE" ]]; then
    # Format tools as JSON array
    tools_json=$(awk 'BEGIN{ORS=""} {if(NR>1)printf ","; printf "\"%s\"", $0}' "$TOOLS_USED_FILE")
  fi
  
  cat > "$OUTDIR/_meta.json" <<EOF
{
  "version": "$VERSION",
  "hostname": "$HOST",
  "serial": "$SN",
  "timestamp": "$TS",
  "mode": "$MODE",
  "anonymized": $( [[ "$ANONYMIZE" == "yes" ]] && echo "true" || echo "false" ),
  "tools_used": [$tools_json],
  "excluded_sections": "$EXCLUDE_SECTIONS"
}
EOF
  log_verbose "JSON metadata written: _meta.json"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Please run as root."
    exit 1
  fi
}

check_disk_space() {
  local target_dir="$1"
  local available_mb
  available_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$available_mb" && "$available_mb" -lt "$MIN_DISK_SPACE_MB" ]]; then
    warn "Less than ${MIN_DISK_SPACE_MB}MB disk space available (${available_mb}MB). Aborting."
    exit 1
  fi
}

# Cleanup function for trap
cleanup() {
  local exit_code=$?
  if [[ -n "$OUTDIR" && -d "$OUTDIR" && "$KEEP_WORK" != "yes" ]]; then
    rm -rf "$OUTDIR" 2>/dev/null || true
  fi
  exit $exit_code
}

# ---------- Option parsing ----------
AUTO_INSTALL_TOOLS="ask"   # ask|yes|no
KEEP_WORK="no"

show_help() {
  cat <<EOF
Usage: getpvelogs.sh [OPTIONS]

Proxmox VE Support Log Collector v${VERSION}
Collects diagnostically relevant system information from Proxmox VE hosts.

Operating modes:
  Default             Standard scope (no flag)
  --full              Full data collection incl. hardware

Tool installation:
  --install-tools     Automatically install missing tools
  --no-install        Do not install tools

Output:
  --output-dir PATH   Set output directory
  --exclude SECTIONS  Exclude sections (comma-separated: ceph,smart,network,storage,proxmox)
  --anonymize         Anonymize IPs, MACs, and hostnames
  --json-meta         Export metadata as JSON
  --verbose           Detailed output

Miscellaneous:
  --keep-work         Keep working directory
  --check             Self-test (shows available tools)
  -v, --version       Show version
  -h, --help          Show this help

Examples:
  sudo ./getpvelogs.sh --full --install-tools
  sudo ./getpvelogs.sh --output-dir /tmp
  sudo ./getpvelogs.sh --exclude ceph,smart --anonymize

EOF
  exit 0
}

# Parameter parsing with while loop for arguments with values
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Operating modes
    --full)           MODE="full"            ;;
    
    # Tool installation
    --install-tools)  AUTO_INSTALL_TOOLS="yes" ;;
    --no-install)     AUTO_INSTALL_TOOLS="no"  ;;
    
    # Output options
    --output-dir)
      shift
      [[ $# -eq 0 ]] && { warn "--output-dir requires a path"; exit 1; }
      OUTPUT_DIR="$1"
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      ;;
    --exclude)
      shift
      [[ $# -eq 0 ]] && { warn "--exclude requires a section list"; exit 1; }
      EXCLUDE_SECTIONS="$1"
      ;;
    --exclude=*)
      EXCLUDE_SECTIONS="${1#*=}"
      ;;
    --anonymize)      ANONYMIZE="yes"        ;;
    --json-meta)      JSON_META="yes"        ;;
    --verbose)        VERBOSE="yes"          ;;
    
    # Miscellaneous
    --keep-work)      KEEP_WORK="yes"        ;;
    --check)
      # Self-test will be executed later
      RUN_SELFTEST="yes"
      ;;
    -v|--version)
      echo "getpvelogs.sh v${VERSION}"
      exit 0
      ;;
    -h|--help)
      show_help
      ;;
    *)
      warn "Unknown option: $1"
      ;;
  esac
  shift
done

# Initialize variable for self-test if not set
RUN_SELFTEST="${RUN_SELFTEST:-no}"

# ---------- Tool-Check-System ----------
# Checks all required tools and prompts for installation

check_all_tools() {
  # Check tools only in corresponding mode
  have nvme     || MISSING_TOOLS[nvme-cli]="NVMe SMART-Daten"
  
  # Tools only relevant for --full mode
  if [[ "$MODE" == "full" ]]; then
    have ipmitool || MISSING_TOOLS[ipmitool]="IPMI/BMC sensor data"
    have sensors  || MISSING_TOOLS[lm-sensors]="Thermal data"
    have iostat   || MISSING_TOOLS[sysstat]="Performance statistics (iostat, sar)"
  fi
}

install_missing_tools() {
  if ! have apt-get; then
    warn "No apt-get available - installation not possible."
    return 1
  fi
  
  log "Updating package lists..."
  apt-get update -qq
  
  for pkg in "${!MISSING_TOOLS[@]}"; do
    log "Installing $pkg..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
      note_tool_use "$pkg (installed)"
      unset "MISSING_TOOLS[$pkg]"
    else
      warn "Installation of $pkg failed."
    fi
  done
}

prompt_install_tools() {
  [[ ${#MISSING_TOOLS[@]} -eq 0 ]] && return 0
  
  echo ""
  echo "The following optional tools are missing:"
  for pkg in "${!MISSING_TOOLS[@]}"; do
    echo "  - $pkg: ${MISSING_TOOLS[$pkg]}"
  done
  echo ""
  
  case "$AUTO_INSTALL_TOOLS" in
    yes)
      install_missing_tools
      ;;
    no)
      warn "Tools will not be installed - some sections will be skipped."
      ;;
    ask)
      read -rp "Do you want to install the missing tools? [y/N] " ans || true
      case "$ans" in
        y|Y)
          install_missing_tools
          ;;
        *)
          warn "Tools will not be installed - some sections will be skipped."
          ;;
      esac
      ;;
  esac
}

# Legacy function for compatibility (no longer used directly)
maybe_install_nvme_cli() {
  if have nvme; then
    note_tool_use "nvme-cli"
    return 0
  fi
  return 1
}

# ---------- New data collectors (v4.0) ----------

# Hardware data collector: IPMI and thermal (--full only)
collect_hardware_extended() {
  is_mode_full || return 0
  is_excluded "hardware" && return 0
  
  log "Collecting extended hardware information..."
  
  # IPMI/BMC
  if have ipmitool; then
    note_tool_use "ipmitool"
    log "  - IPMI sensor data..."
    run "$OUTDIR/hardware/ipmi_sensors.txt" ipmitool sensor list
    run "$OUTDIR/hardware/ipmi_sel.txt" ipmitool sel list
    run "$OUTDIR/hardware/ipmi_fru.txt" ipmitool fru print
  else
    log "  - IPMI: ipmitool not available (skipped)"
  fi
  
  # Thermal (lm-sensors)
  if have sensors; then
    note_tool_use "lm-sensors"
    log "  - Thermal data (lm-sensors)..."
    run_quick "$OUTDIR/hardware/sensors.txt" sensors -A
  else
    log "  - Thermal: lm-sensors not available (skipped)"
  fi
}

# Proxmox data collector: VM/CT configs, backup, HA, replication, etc. (--full only)
collect_pve_extended() {
  is_mode_full || return 0
  is_excluded "proxmox-extended" && return 0
  have pveversion || return 0
  
  log "Collecting extended Proxmox information..."
  
  # VM-Konfigurationen
  if [[ -d /etc/pve/qemu-server ]]; then
    local vm_count
    vm_count=$(find /etc/pve/qemu-server -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)
    if [[ "$vm_count" -gt 0 ]]; then
      mkdir -p "$OUTDIR/proxmox/vm-configs"
      for conf in /etc/pve/qemu-server/*.conf; do
        [[ -f "$conf" ]] && cp "$conf" "$OUTDIR/proxmox/vm-configs/" 2>/dev/null || true
      done
      log "  - VM configurations: $vm_count VMs copied"
    else
      log "  - VM configurations: no VMs present"
    fi
  fi
  
  # CT-Konfigurationen
  if [[ -d /etc/pve/lxc ]]; then
    local ct_count
    ct_count=$(find /etc/pve/lxc -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)
    if [[ "$ct_count" -gt 0 ]]; then
      mkdir -p "$OUTDIR/proxmox/ct-configs"
      for conf in /etc/pve/lxc/*.conf; do
        [[ -f "$conf" ]] && cp "$conf" "$OUTDIR/proxmox/ct-configs/" 2>/dev/null || true
      done
      log "  - CT configurations: $ct_count containers copied"
    else
      log "  - CT configurations: no containers present"
    fi
  fi
  
  # Backup-Konfiguration
  log "  - Backup configuration..."
  {
    echo "=== vzdump.conf ==="
    cat /etc/vzdump.conf 2>/dev/null || echo "(not present)"
    echo ""
    echo "=== Backup Jobs (vzdump.cron) ==="
    cat /etc/pve/vzdump.cron 2>/dev/null || echo "(not present)"
    echo ""
    echo "=== Backup Jobs (jobs.cfg) ==="
    cat /etc/pve/jobs.cfg 2>/dev/null || echo "(not present)"
  } >> "$OUTDIR/proxmox/backup_config.txt" 2>&1
  
  # HA-Manager
  if have ha-manager; then
    log "  - HA-Manager status..."
    run_quick "$OUTDIR/proxmox/ha_status.txt" ha-manager status
    
    if [[ -d /etc/pve/ha ]]; then
      mkdir -p "$OUTDIR/proxmox/ha-config"
      cp -r /etc/pve/ha/* "$OUTDIR/proxmox/ha-config/" 2>/dev/null || true
    fi
  else
    log "  - HA-Manager: not available (skipped)"
  fi
  
  # Replication
  if have pvesr; then
    log "  - Replication status..."
    run_quick "$OUTDIR/proxmox/replication_status.txt" pvesr status
    [[ -f /etc/pve/replication.cfg ]] && cp /etc/pve/replication.cfg "$OUTDIR/proxmox/" 2>/dev/null || true
  else
    log "  - Replication: pvesr not available (skipped)"
  fi
  
  # Subscription
  log "  - Subscription status..."
  {
    echo "=== Subscription Status ==="
    pvesubscription get 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/proxmox/subscription.txt" 2>&1
  
  # SDN (Software Defined Networking)
  if [[ -d /etc/pve/sdn ]]; then
    log "  - SDN configuration..."
    mkdir -p "$OUTDIR/proxmox/sdn-config"
    cp -r /etc/pve/sdn/* "$OUTDIR/proxmox/sdn-config/" 2>/dev/null || true
  else
    log "  - SDN: not configured (skipped)"
  fi
  
  # PBS (Proxmox Backup Server) Client Status
  if have proxmox-backup-client; then
    log "  - PBS client status..."
    note_tool_use "proxmox-backup-client"
    run_quick "$OUTDIR/proxmox/pbs_status.txt" proxmox-backup-client version
  fi
}

# Firewall data collector (--full only)
collect_firewall() {
  is_mode_full || return 0
  is_excluded "firewall" && return 0
  
  log "Collecting firewall and security information..."
  
  # PVE Firewall Status
  if have pve-firewall; then
    log "  - PVE Firewall status..."
    run_quick "$OUTDIR/security/firewall_status.txt" pve-firewall status
  else
    log "  - PVE Firewall: not available (skipped)"
  fi
  
  # Copy firewall configs
  log "  - Firewall configurations..."
  mkdir -p "$OUTDIR/security/firewall"
  
  # Cluster Firewall
  [[ -f /etc/pve/firewall/cluster.fw ]] && cp /etc/pve/firewall/cluster.fw "$OUTDIR/security/firewall/" 2>/dev/null || true
  
  # Host Firewall
  for fw in /etc/pve/nodes/*/host.fw; do
    [[ -f "$fw" ]] && cp "$fw" "$OUTDIR/security/firewall/$(basename "$(dirname "$fw")")_host.fw" 2>/dev/null || true
  done
  
  # VM/CT Firewall
  for fw in /etc/pve/firewall/*.fw; do
    [[ -f "$fw" ]] && cp "$fw" "$OUTDIR/security/firewall/" 2>/dev/null || true
  done
  
  # SSL certificate info
  log "  - SSL certificate information..."
  {
    echo "=== PVE SSL Certificate ==="
    if [[ -f /etc/pve/local/pve-ssl.pem ]]; then
      openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -dates -subject -issuer 2>/dev/null || echo "(error reading)"
    else
      echo "(not present)"
    fi
    echo ""
    echo "=== PVE Root CA ==="
    if [[ -f /etc/pve/pve-root-ca.pem ]]; then
      openssl x509 -in /etc/pve/pve-root-ca.pem -noout -dates -subject 2>/dev/null || echo "(error reading)"
    else
      echo "(not present)"
    fi
  } >> "$OUTDIR/security/ssl_info.txt" 2>&1
  
  # SSH config (without private keys!)
  log "  - SSH configuration..."
  [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$OUTDIR/security/sshd_config.txt" 2>/dev/null || true
}

# Performance data collector (--full only)
collect_performance() {
  is_mode_full || return 0
  is_excluded "performance" && return 0
  
  log "Collecting performance data..."
  
  # Top processes
  log "  - Top processes (CPU/Memory)..."
  {
    echo "=== Top 20 by Memory ==="
    ps aux --sort=-%mem 2>/dev/null | head -21
    echo ""
    echo "=== Top 20 by CPU ==="
    ps aux --sort=-%cpu 2>/dev/null | head -21
  } >> "$OUTDIR/performance/top_processes.txt" 2>&1
  
  # iostat
  if have iostat; then
    note_tool_use "sysstat (iostat)"
    log "  - I/O statistics (iostat)..."
    run_quick "$OUTDIR/performance/iostat.txt" iostat -xz 1 3
  else
    log "  - iostat: not available (skipped)"
  fi
  
  # vmstat
  if have vmstat; then
    log "  - VM statistics (vmstat)..."
    run_quick "$OUTDIR/performance/vmstat.txt" vmstat 1 5
  else
    log "  - vmstat: not available (skipped)"
  fi
  
  # sar (if present)
  if have sar; then
    note_tool_use "sysstat (sar)"
    log "  - System Activity Reports (sar)..."
    run "$OUTDIR/performance/sar_cpu.txt" sar -u 1 5
    run "$OUTDIR/performance/sar_disk.txt" sar -d 1 5
  else
    log "  - sar: not available (skipped)"
  fi
}

# System extensions (--full only)
collect_system_extended() {
  is_mode_full || return 0
  is_excluded "system-extended" && return 0
  
  log "Collecting extended system information..."
  
  # Boot configuration
  log "  - Boot configuration (Kernel, GRUB, modules)..."
  {
    echo "=== Kernel Cmdline ==="
    cat /proc/cmdline 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== GRUB Config ==="
    cat /etc/default/grub 2>/dev/null || echo "(not present)"
    echo ""
    echo "=== Kernel Modules ==="
    lsmod 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/system/boot_config.txt" 2>&1
  
  # Systemd timers
  log "  - Systemd timers..."
  {
    echo "=== Systemd Timers ==="
    systemctl list-timers --all --no-pager 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/system/systemd_timers.txt" 2>&1
}

# ---------- Anonymisierung ----------

anonymize_output() {
  [[ "$ANONYMIZE" != "yes" ]] && return 0
  
  log "Anonymizing collected data..."
  log_verbose "Replacing IP addresses, MAC addresses, and hostnames..."
  
  # Counter for replacements
  local ip_count=0
  local mac_count=0
  
  # Find all text files in output directory
  while IFS= read -r -d '' file; do
    # Process only text files
    if file -b "$file" 2>/dev/null | grep -q "text"; then
      log_verbose "Anonymizing: $(basename "$file")"
      
      # Replace IPv4 addresses (first and last octet remain visible)
      # Beispiel: 192.168.1.100 -> 192.X.X.100
      sed -i \
        -e 's/\b\([0-9]\{1,3\}\)\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.\([0-9]\{1,3\}\)\b/\1.X.X.\2/g' \
        "$file" 2>/dev/null || true
      
      # Replace MAC addresses (last 3 blocks remain visible)
      # Example: AA:BB:CC:DD:EE:FF -> XX:XX:XX:DD:EE:FF
      sed -i \
        -e 's/\b[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:\([0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\)\b/XX:XX:XX:\1/g' \
        "$file" 2>/dev/null || true
      
      # Replace hostname (only if not empty)
      if [[ -n "$HOST" && "$HOST" != "unknown-host" ]]; then
        sed -i \
          -e "s/${HOST}/HOSTNAME/g" \
          "$file" 2>/dev/null || true
      fi
    fi
  done < <(find "$OUTDIR" -type f -print0)
  
  # Add notice to _meta.txt
  {
    echo ""
    echo "========================================"
    echo "  NOTICE: Data has been anonymized"
    echo "========================================"
    echo "IP addresses: partially masked (first.X.X.last octet)"
    echo "MAC addresses: partially masked (XX:XX:XX:last:three:blocks)"
    echo "Hostname: replaced by HOSTNAME"
  } >> "$OUTDIR/_meta.txt"
  
  log "Anonymization completed."
}

# ---------- Self-test ----------

run_selftest() {
  echo "========================================"
  echo "  PVE Logscript Self-Test"
  echo "========================================"
  echo ""
  echo "Version: $VERSION"
  echo ""
  echo "System tools:"
  
  local sys_tools=(timeout tar gzip zstd sha256sum md5sum)
  for tool in "${sys_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Storage tools:"
  
  local storage_tools=(smartctl nvme zpool zfs mdadm pvs vgs lvs)
  for tool in "${storage_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Proxmox tools:"
  
  local pve_tools=(pveversion pvereport pvecm pvesm qm pct ha-manager pvesr pve-firewall)
  for tool in "${pve_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Hardware tools (for --full mode):"
  
  local hw_tools=(ipmitool sensors dmidecode lspci lsusb ethtool)
  for tool in "${hw_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Performance tools (for --full mode):"
  
  local perf_tools=(iostat vmstat sar)
  for tool in "${perf_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Other:"
  
  local other_tools=(ceph corosync-quorumtool corosync-cfgtool journalctl openssl)
  for tool in "${other_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "========================================"
  echo "Disk space: $(df -h . 2>/dev/null | awk 'NR==2 {print $4}') available"
  echo "========================================"
}

# ---------- Setup ----------

# Self-test mode (--check) - does not require root
if [[ "$RUN_SELFTEST" == "yes" ]]; then
  run_selftest
  exit 0
fi

require_root

# Trap for clean cleanup on abort
trap cleanup EXIT INT TERM

umask 077
export LC_ALL=C

# Output mode and options
log "PVE Support Log Collector v${VERSION}"
log "Mode: $MODE"
[[ "$VERBOSE" == "yes" ]] && log "Verbose mode: enabled"
[[ "$ANONYMIZE" == "yes" ]] && log "Anonymization: enabled"
[[ -n "$EXCLUDE_SECTIONS" ]] && log "Excluded sections: $EXCLUDE_SECTIONS"

# Tool check and installation (before data collection)
log "Checking available tools..."
check_all_tools
prompt_install_tools

# Ausgabeverzeichnis bestimmen
TARGET_DIR="${OUTPUT_DIR:-$(pwd)}"

# Disk-Space pruefen
check_disk_space "$TARGET_DIR"

# Get raw values
_rawSN="$(dmidecode -s system-serial-number 2>/dev/null || echo UNKNOWN_SN)"
_rawHOST="$(hostname -f 2>/dev/null || hostname || echo unknown-host)"

# Sanitize serial number (no spaces, tabs, slashes, etc.)
SN="$(printf '%s' "$_rawSN" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SN" ]] && SN="UNKNOWN"

# Lightly sanitize hostname
HOST="$(printf '%s' "$_rawHOST" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$HOST" ]] && HOST="unknown-host"

TS="$(date -u +'%Y%m%d-%H%M%S')"

# Create output directory (in TARGET_DIR)
if [[ -n "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"
fi
OUTDIR="$(mktemp -d -p "$TARGET_DIR" "${HOST}_${SN}_${TS}.logs.XXXX")"
TOOLS_USED_FILE="$OUTDIR/_tools_used.txt"
ERRORS_FILE="$OUTDIR/_errors.txt"

# Initialisiere Meta-Dateien
touch "$TOOLS_USED_FILE" "$ERRORS_FILE"

log "Working directory: $OUTDIR"

# Create directory structure
mkdir -p "$OUTDIR/logs"
mkdir -p "$OUTDIR/system"
mkdir -p "$OUTDIR/network/net-if"
mkdir -p "$OUTDIR/proxmox"
mkdir -p "$OUTDIR/security"
mkdir -p "$OUTDIR/hardware"
mkdir -p "$OUTDIR/performance"
mkdir -p "$OUTDIR/ceph"

# Archive names (in same directory as OUTDIR)
ARCHIVE_ZST="${TARGET_DIR}/${HOST}_${SN}_${TS}.supportlogs.tar.zst"
ARCHIVE_GZ="${TARGET_DIR}/${HOST}_${SN}_${TS}.supportlogs.tar.gz"

# ---------- Basic information ----------
log "Collecting basic information..."

# Write collected meta information
{
  echo "========================================"
  echo "  PVE Support Log Collector"
  echo "========================================"
  echo ""
  echo "Tool-Version:    $VERSION"
  echo "Hostname:        $HOST"
  echo "Serial number:   $SN"
  echo "Mode:           $MODE"
  echo "Executed at:    $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  [[ -n "$EXCLUDE_SECTIONS" ]] && echo "Excluded:       $EXCLUDE_SECTIONS"
  echo ""
  echo "========================================"
  echo ""
  echo "=== System Information ==="
  uname -a
  echo ""
  if have lsb_release; then
    lsb_release -a 2>/dev/null
  else
    cat /etc/os-release 2>/dev/null || true
  fi
  echo ""
  echo "=== Time & Date ==="
  timedatectl 2>/dev/null || date
  echo ""
  echo "=== Uptime ==="
  uptime
  echo ""
  echo "=== Disk Usage ==="
  df -h
  echo ""
  echo "=== Memory ==="
  free -h
} >> "$OUTDIR/_meta.txt" 2>&1

# Hardware-Informationen gesammelt
{
  echo "=== CPU ==="
  lscpu 2>/dev/null || true
  echo ""
  echo "=== Block Devices ==="
  lsblk -e7 -o NAME,MAJ:MIN,SIZE,ROTA,TYPE,MOUNTPOINT,FSTYPE,MODEL,SERIAL 2>/dev/null || true
  echo ""
  echo "=== PCI Devices ==="
  lspci -nn 2>/dev/null || true
  echo ""
  echo "=== USB Devices ==="
  lsusb 2>/dev/null || true
  echo ""
  echo "=== DMI Info ==="
  dmidecode -t system -t baseboard 2>/dev/null || true
} >> "$OUTDIR/system/hw.txt" 2>&1

run_quick "$OUTDIR/kernel_dmesg.txt" dmesg

# APT History (nur Textdateien; .gz mit zcat dekomprimieren)
{
  for f in /var/log/apt/history.log*; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == *.gz ]]; then
      zcat "$f" 2>/dev/null || gzip -dc "$f" 2>/dev/null
    else
      cat "$f" 2>/dev/null
    fi
  done
} >> "$OUTDIR/system/apt_history.txt" 2>&1

# ---------- Journal / Syslog ----------
log "Collecting journald/syslog..."
if have journalctl; then
  run "$OUTDIR/journal_current.txt" journalctl -b --no-pager
  run "$OUTDIR/journal_7d.txt" journalctl --since="-7 days" --no-pager
else
  {
    cat /var/log/syslog* 2>/dev/null || cat /var/log/messages* 2>/dev/null || true
  } >> "$OUTDIR/system/syslog.txt" 2>&1
fi

# ---------- Netzwerk ----------
log "Collecting network data..."

{
  echo "=== IP Addresses ==="
  ip -br a
  echo ""
  echo "=== Routing Table ==="
  ip r
  echo ""
  echo "=== Listening Ports ==="
  if have ss; then
    ss -tulpn
  elif have netstat; then
    netstat -tulpn
  fi
} >> "$OUTDIR/network/network.txt" 2>&1

# Interface-Details
for IF in /sys/class/net/*; do
  IF="$(basename "$IF")"
  {
    echo "### $IF"
    if have ethtool; then
      ethtool -i "$IF" 2>/dev/null || true
      ethtool "$IF" 2>/dev/null || true
      ethtool -S "$IF" 2>/dev/null || true
    fi
  } >> "$OUTDIR/network/net-if/${IF}.txt"
done

# Netzwerk-Konfiguration
{
  if [[ -f /etc/network/interfaces ]]; then
    echo "# /etc/network/interfaces"
    cat /etc/network/interfaces
    echo ""
  fi
  for f in /etc/network/interfaces.d/*; do
    if [[ -f "$f" ]]; then
      echo "### $f"
      cat "$f"
      echo ""
    fi
  done
} >> "$OUTDIR/network/network_config.txt" 2>&1

# ---------- Storage ----------
# Storage information only in normal/full mode
if is_mode_normal_or_full && ! is_excluded "storage"; then
  log "Collecting storage information..."

  # MDADM
  {
    echo "=== MDADM Scan ==="
    mdadm --detail --scan 2>/dev/null || true
    echo ""
    for a in /dev/md/*; do
      if [[ -b "$a" ]]; then
        echo "=== $a ==="
        mdadm --detail "$a" 2>/dev/null || true
      fi
    done
  } >> "$OUTDIR/system/mdadm.txt" 2>&1

  # LVM
  {
    echo "=== Physical Volumes ==="
    pvs 2>/dev/null || true
    echo ""
    echo "=== Volume Groups ==="
    vgs 2>/dev/null || true
    echo ""
    echo "=== Logical Volumes ==="
    lvs -a 2>/dev/null || true
  } >> "$OUTDIR/system/lvm.txt" 2>&1

  # ZFS
  if have zpool; then
    note_tool_use "ZFS"
    {
      echo "=== ZPool Status ==="
      zpool status -v 2>/dev/null || true
      echo ""
      echo "=== ZPool List ==="
      zpool list 2>/dev/null || true
      echo ""
      if have zfs; then
        echo "=== ZFS List ==="
        zfs list -t all -o name,used,avail,refer,mountpoint 2>/dev/null || true
        echo ""
        echo "=== ZFS Properties (zfs get all) ==="
        zfs get all 2>/dev/null || true
      fi
    } >> "$OUTDIR/zfs.txt" 2>&1
  fi
fi

# ---------- Proxmox ----------
if have pveversion && ! is_excluded "proxmox"; then
  note_tool_use "Proxmox VE"

  run_quick "$OUTDIR/pveversion.txt" pveversion -v
  have pvereport && run "$OUTDIR/proxmox/pvereport.txt" pvereport

  # Services
  {
    echo "=== Failed Units ==="
    systemctl --failed 2>/dev/null || true
    echo ""
    echo "=== PVE Service Status ==="
    for svc in pvedaemon pveproxy pve-cluster pvestatd pve-firewall; do
      echo "--- $svc ---"
      systemctl status --no-pager "$svc" 2>/dev/null || true
      echo ""
    done
  } >> "$OUTDIR/proxmox/pve_services.txt" 2>&1

  # VMs and containers (normal/full only)
  if is_mode_normal_or_full; then
    {
      if have qm; then
        echo "=== QEMU VMs ==="
        qm list 2>/dev/null || true
        echo ""
      fi
      if have pct; then
        echo "=== LXC Containers ==="
        pct list 2>/dev/null || true
      fi
    } >> "$OUTDIR/proxmox/pve_vms.txt" 2>&1

    # Storage
    if have pvesm; then
      {
        echo "=== Storage Status ==="
        pvesm status 2>/dev/null || true
        echo ""
        echo "=== Local Storage Content ==="
        pvesm list local 2>/dev/null || true
      } >> "$OUTDIR/storage.txt" 2>&1
    fi

    # Cluster
    {
      if have pvecm; then
        echo "=== Cluster Status ==="
        pvecm status 2>/dev/null || true
        echo ""
        echo "=== Cluster Nodes ==="
        pvecm nodes 2>/dev/null || true
        echo ""
      fi
      if have corosync-quorumtool; then
        echo "=== Quorum Status ==="
        corosync-quorumtool -s 2>/dev/null || true
        echo ""
      fi
      if have corosync-cfgtool; then
        echo "=== Corosync Ring Status ==="
        corosync-cfgtool -s 2>/dev/null || true
      fi
    } >> "$OUTDIR/proxmox/cluster.txt" 2>&1
  fi
fi

# ---------- Ceph ----------
if have ceph && is_mode_normal_or_full && ! is_excluded "ceph"; then
  note_tool_use "Ceph"
  log "Collecting Ceph information..."

  # Timeout array for safe execution
  TOUT=()
  have timeout && TOUT=(timeout "${CMD_TIMEOUT}s")

  run_quick "$OUTDIR/ceph/ceph_status.txt" ceph -s
  run_quick "$OUTDIR/ceph/ceph_health.txt" ceph health detail
  run_quick "$OUTDIR/ceph/ceph_osd.txt" ceph osd tree
  run_quick "$OUTDIR/ceph/ceph_mons.txt" ceph mon dump

  # Potentially slow commands with timeout
  { "${TOUT[@]}" ceph pg dump --format json >> "$OUTDIR/ceph/ceph_pg.txt" 2>&1; } || warn "ceph pg dump failed or timeout"
  { "${TOUT[@]}" ceph osd df >> "$OUTDIR/ceph/ceph_osd_df.txt" 2>&1; } || warn "ceph osd df failed or timeout"

  # OSD -> device -> serial mapping
  MAPPING_FILE="$OUTDIR/ceph/osd_device_mapping.txt"
  {
    echo "OSD|DEVICE|SERIAL"
    if have ceph-volume; then
      note_tool_use "ceph-volume"
      CEPH_VOLUME_RAW="$OUTDIR/ceph/ceph_volume_lvm_list.txt"
      ceph-volume lvm list > "$CEPH_VOLUME_RAW" 2>&1 || warn "ceph-volume lvm list failed (see ceph_volume_lvm_list.txt)"

      osd=""
      found_mapping=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if [[ "$line" =~ osd\.([0-9]+) ]]; then
          osd="${BASH_REMATCH[1]}"
          continue
        fi

        if [[ "$line" =~ ^[[:space:]]*devices[[:space:]]+(.+) ]] && [[ -n "$osd" ]]; then
          devices_raw="${BASH_REMATCH[1]}"
          devices_raw="${devices_raw//,/ }"

          for raw_dev in $devices_raw; do
            [[ "$raw_dev" == /dev/* ]] || continue

            real_dev=$(readlink -f "$raw_dev" 2>/dev/null || true)
            [[ -n "$real_dev" ]] || real_dev="$raw_dev"

            disk_dev=$(lsblk -ndo PATH,TYPE -s "$real_dev" 2>/dev/null | awk '$2=="disk"{d=$1} END{print d}')
            [[ -n "$disk_dev" ]] || disk_dev="$real_dev"

            serial=$(lsblk -ndo SERIAL "$disk_dev" 2>/dev/null | awk 'NR==1{print; exit}')
            if [[ -z "$serial" ]] && have udevadm; then
              serial=$(udevadm info --query=property --name "$disk_dev" 2>/dev/null | awk -F= '/^(ID_SERIAL_SHORT|ID_SERIAL)=/{print $2; exit}')
            fi
            [[ -n "$serial" ]] || serial="unknown"

            printf '%s|%s|%s\n' "$osd" "$disk_dev" "$serial"
            found_mapping=1
          done
        fi
      done < "$CEPH_VOLUME_RAW"

      if [[ "$found_mapping" -eq 0 ]]; then
        echo "INFO|no osd-device mapping parsed|unknown"
      fi
    else
      echo "INFO|ceph-volume missing|serial mapping unavailable"
    fi
  } > "$MAPPING_FILE"
fi

# ---------- SMART ----------
if is_mode_normal_or_full && ! is_excluded "smart"; then
  log "Collecting SMART data..."
  SMART_OUT="$OUTDIR/smart.txt"

  if have smartctl; then
    note_tool_use "smartmontools"
    # Extended glob patterns for more drives (sda-sdz, sdaa-sdzz)
    for DEV in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/hd[a-z] /dev/xvd[a-z]; do
      [[ -b "$DEV" ]] || continue
      {
        echo "=== SMART: $DEV ==="
        smartctl -a "$DEV" 2>&1 || true
        echo ""
      } >> "$SMART_OUT"
    done
  fi

  # ---------- NVMe ----------
  log "Collecting NVMe data..."
  # Tool installation was already performed above
  if have nvme; then
    note_tool_use "nvme-cli"
    run_quick "$OUTDIR/nvme_list.txt" nvme list

    for NV in /dev/nvme*n1; do
      [[ -b "$NV" ]] || continue
      {
        echo "=== NVMe SMART: $NV ==="
        nvme smart-log "$NV" 2>&1 || true
        echo ""
        echo "=== NVMe Error Log: $NV ==="
        nvme error-log "$NV" 2>&1 || true
        echo ""
        echo "=== NVMe Namespaces: $NV ==="
        nvme list-ns "$NV" 2>&1 || true
        echo ""
      } >> "$SMART_OUT"
    done
  else
    log_verbose "nvme-cli not available - NVMe details will be skipped."
  fi
fi

# ---------- Systemlogs kopieren ----------
log "Copying relevant system logs..."

LOG_PATTERNS=(
  /var/log/syslog*
  /var/log/messages*
  /var/log/kern.log*
  /var/log/daemon.log*
  /var/log/pveproxy/*
  /var/log/pvedaemon/*
  /var/log/pvescheduler/*
  /var/log/pvestatd/*
)

for pattern in "${LOG_PATTERNS[@]}"; do
  for f in $pattern; do
    [[ -e "$f" ]] && cp -a "$f" "$OUTDIR/logs/" 2>/dev/null || true
  done
done

# ---------- Extended data collection (--full mode only) ----------
if is_mode_full; then
  log "Collecting extended data (--full mode)..."
  collect_hardware_extended
  collect_pve_extended
  collect_firewall
  collect_performance
  collect_system_extended
fi

# ---------- JSON-Metadaten ----------
write_json_meta

# ---------- Anonymization (BEFORE archiving) ----------
anonymize_output

# ---------- Pack ----------
log "Packing archive..."

# Remove empty directories
find "$OUTDIR" -type d -empty -delete 2>/dev/null || true

ARCHIVE_CREATED=""
if have zstd; then
  note_tool_use "zstd"
  tar -C "$(dirname "$OUTDIR")" -I "zstd -19 --threads=0" -cf "$ARCHIVE_ZST" "$(basename "$OUTDIR")"
  log "Archive created: $ARCHIVE_ZST"
  ARCHIVE_CREATED="$ARCHIVE_ZST"
else
  note_tool_use "gzip"
  tar -C "$(dirname "$OUTDIR")" -czf "$ARCHIVE_GZ" "$(basename "$OUTDIR")"
  log "Archive created: $ARCHIVE_GZ"
  ARCHIVE_CREATED="$ARCHIVE_GZ"
fi

# ---------- Checksums ----------
if [[ -n "$ARCHIVE_CREATED" && -f "$ARCHIVE_CREATED" ]]; then
  generate_checksums "$ARCHIVE_CREATED"
fi

# ---------- Cleanup ----------
# Disable trap since we are now cleaning up manually
trap - EXIT INT TERM

if [[ "$KEEP_WORK" == "yes" ]]; then
  log "Working directory retained: $OUTDIR"
else
  rm -rf "$OUTDIR"
fi

log "Done."
log ""
log "Output files:"
log "  Archive: $ARCHIVE_CREATED"
[[ -f "${ARCHIVE_CREATED}.sha256" ]] && log "  SHA256: ${ARCHIVE_CREATED}.sha256"
[[ -f "${ARCHIVE_CREATED}.md5" ]] && log "  MD5:    ${ARCHIVE_CREATED}.md5"
