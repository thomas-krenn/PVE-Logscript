#!/usr/bin/env bash
#
# Version: 4.1.0 - 09/2026
# Thomas-Krenn.AG - Proxmox Backup Server Support Log Collector
# Author: Samuel Mueller
# Contact: smueller@thomas-krenn.com
#
# Purpose:
#   This script collects diagnostically relevant system information from
#   Proxmox Backup Server hosts to make error situations more reproducible,
#   faster, and easier to analyze for support. Execution is read-only,
#   except for the optional installation of tools such as nvme-cli,
#   ipmitool, etc.
#
#   Backup chunk data (.chunks), private keys, password hashes, and tape
#   encryption keys are never copied.
#
# Feature scope:
#   - Two operating modes: Default, --full
#   - Progress output to STDOUT (Collect / Copy / Pack)
#   - Collection of kernel, journal, system, storage, and network data
#   - Aggregation of PBS services, datastores, disks, and tasks
#   - SMART and optional NVMe-SMART data
#   - Hardware information (IPMI, thermal) in --full mode
#   - PBS jobs (sync, prune, verify), remotes, tape, S3 in --full mode
#   - Firewall, certificates, and SSH configuration in --full mode
#   - Performance data (iostat, vmstat, sar) in --full mode
#   - Storage of used optional tools (_tools_used.txt)
#   - Storage of warnings and notices (_errors.txt)
#   - Checksum generation (SHA256/MD5)
#
# Operating modes:
#   Default   Standard scope: Journal, dmesg, PBS services, network,
#             storage, SMART, datastores, disks, recent tasks (no flag)
#   --full    Full: Default + hardware (IPMI, thermal), PBS jobs/remotes,
#             tape, S3, identity providers, firewall, performance
#
# Privacy / GDPR notice:
#   This script can read hostnames, usernames, datastore names, and IP
#   addresses. Review of contents is recommended before sharing with
#   third parties.
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
readonly VERSION="4.1.0"
readonly MIN_DISK_SPACE_MB=600
readonly CMD_TIMEOUT=60
readonly TASK_LOG_MAX_AGE_DAYS=7
readonly TASK_LOG_MAX_FILES=300
readonly TASK_LOG_MAX_BYTES=10485760  # 10 MiB per task log file

# ---------- Global variables ----------
ERRORS_FILE=""
TOOLS_USED_FILE=""
OUTDIR=""

# ---------- Options ----------
MODE="normal"              # normal|full
VERBOSE="no"               # yes|no
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

readonly VALID_EXCLUDE_SECTIONS=(
  smart
  network
  storage
  pbs
  pbs-extended
  tape
  hardware
  firewall
  performance
  system-extended
)

log_verbose() {
  [[ "$VERBOSE" == "yes" ]] && printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"
  return 0
}

is_excluded() {
  local section normalized
  section="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  normalized=",$EXCLUDE_SECTIONS,"
  [[ -n "$EXCLUDE_SECTIONS" && "$normalized" == *",$section,"* ]] && return 0
  return 1
}

normalize_exclude_sections() {
  [[ -z "$EXCLUDE_SECTIONS" ]] && return 0

  local raw item cleaned allowed valid normalized=""
  IFS=',' read -r -a raw <<< "$EXCLUDE_SECTIONS"

  for item in "${raw[@]}"; do
    cleaned="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$cleaned" ]] && continue

    valid="no"
    for allowed in "${VALID_EXCLUDE_SECTIONS[@]}"; do
      if [[ "$cleaned" == "$allowed" ]]; then
        valid="yes"
        break
      fi
    done

    if [[ "$valid" == "yes" ]]; then
      [[ ",$normalized," == *",$cleaned,"* ]] || normalized+="${normalized:+,}$cleaned"
    else
      warn "Unknown section in --exclude ignored: $cleaned"
    fi
  done

  EXCLUDE_SECTIONS="$normalized"
}

is_mode_full() {
  [[ "$MODE" == "full" ]] && return 0
  return 1
}

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

write_json_meta() {
  [[ "$JSON_META" != "yes" ]] && return

  local tools_json=""
  if [[ -f "$TOOLS_USED_FILE" && -s "$TOOLS_USED_FILE" ]]; then
    tools_json=$(awk 'BEGIN{ORS=""} {if(NR>1)printf ","; printf "\"%s\"", $0}' "$TOOLS_USED_FILE")
  fi

  cat > "$OUTDIR/_meta.json" <<EOF
{
  "version": "$VERSION",
  "product": "pbs",
  "hostname": "$HOST",
  "serial": "$SN",
  "timestamp": "$TS",
  "mode": "$MODE",
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
  local df_target="$target_dir"
  local available_mb
  [[ -d "$df_target" ]] || df_target="$(dirname -- "$df_target")"
  [[ -d "$df_target" ]] || df_target="."
  available_mb=$(df -Pm "$df_target" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$available_mb" =~ ^[0-9]+$ ]] && (( available_mb < MIN_DISK_SPACE_MB )); then
    warn "Less than ${MIN_DISK_SPACE_MB}MB disk space available (${available_mb}MB). Aborting."
    exit 1
  fi
}

cleanup() {
  local exit_code=$?
  if [[ -n "$OUTDIR" && -d "$OUTDIR" && "$KEEP_WORK" != "yes" ]]; then
    rm -rf "$OUTDIR" 2>/dev/null || true
  fi
  exit $exit_code
}

list_datastores() {
  if [[ -f /etc/proxmox-backup/datastore.cfg ]]; then
    awk '/^datastore:[[:space:]]/{print $2}' /etc/proxmox-backup/datastore.cfg
  fi
}

# ---------- Option parsing ----------
AUTO_INSTALL_TOOLS="ask"   # ask|yes|no
KEEP_WORK="no"

show_help() {
  cat <<EOF
Usage: getpbslogs.sh [OPTIONS]

Proxmox Backup Server Support Log Collector v${VERSION}
Collects diagnostically relevant system information from PBS hosts.

Operating modes:
  Default             Standard scope (no flag)
  --full              Full data collection incl. hardware, jobs, tape

Tool installation:
  --install-tools     Automatically install missing tools
  --no-install        Do not install tools

Output:
  --output-dir PATH   Set output directory
  --exclude SECTIONS  Exclude sections (comma-separated).
                      Valid: smart,network,storage,pbs,pbs-extended,
                      tape,hardware,firewall,performance,system-extended
  --json-meta         Export metadata as JSON
  --verbose           Detailed output

Miscellaneous:
  --keep-work         Keep working directory
  --check             Self-test (shows available tools)
  -v, --version       Show version
  -h, --help          Show this help

Examples:
  sudo ./getpbslogs.sh --full --install-tools
  sudo ./getpbslogs.sh --output-dir /tmp
  sudo ./getpbslogs.sh --exclude tape,smart

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)           MODE="full"            ;;
    --install-tools)  AUTO_INSTALL_TOOLS="yes" ;;
    --no-install)     AUTO_INSTALL_TOOLS="no"  ;;
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
    --json-meta)      JSON_META="yes"        ;;
    --verbose)        VERBOSE="yes"          ;;
    --keep-work)      KEEP_WORK="yes"        ;;
    --check)
      RUN_SELFTEST="yes"
      ;;
    -v|--version)
      echo "getpbslogs.sh v${VERSION}"
      exit 0
      ;;
    -h|--help)
      show_help
      ;;
    *)
      warn "Unknown option: $1"
      echo "Use -h or --help for usage." >&2
      exit 1
      ;;
  esac
  shift
done

RUN_SELFTEST="${RUN_SELFTEST:-no}"
normalize_exclude_sections

# ---------- Tool check ----------

check_all_tools() {
  if ! is_excluded "smart"; then
    have smartctl || MISSING_TOOLS[smartmontools]="SMART data (SATA/SAS)"
    have nvme     || MISSING_TOOLS[nvme-cli]="NVMe SMART data"
  fi

  if [[ "$MODE" == "full" ]]; then
    if ! is_excluded "hardware"; then
      have ipmitool || MISSING_TOOLS[ipmitool]="IPMI/BMC sensor data"
      have sensors  || MISSING_TOOLS[lm-sensors]="Thermal data"
    fi
    if ! is_excluded "performance"; then
      have iostat   || MISSING_TOOLS[sysstat]="Performance statistics (iostat, sar)"
    fi
  fi
}

install_missing_tools() {
  if ! have apt-get; then
    warn "No apt-get available - installation not possible."
    return 1
  fi

  log "Updating package lists..."
  if ! apt-get update -qq; then
    warn "apt-get update failed - skipping tool installation."
    return 1
  fi

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

# ---------- Collectors ----------

collect_hardware_extended() {
  is_mode_full || return 0
  is_excluded "hardware" && return 0

  log "Collecting extended hardware information..."

  if have ipmitool; then
    note_tool_use "ipmitool"
    log "  - IPMI sensor data..."
    run "$OUTDIR/hardware/ipmi_sensors.txt" ipmitool sensor list
    run "$OUTDIR/hardware/ipmi_sel.txt" ipmitool sel list
    run "$OUTDIR/hardware/ipmi_fru.txt" ipmitool fru print
  else
    log "  - IPMI: ipmitool not available (skipped)"
  fi

  if have sensors; then
    note_tool_use "lm-sensors"
    log "  - Thermal data (lm-sensors)..."
    run_quick "$OUTDIR/hardware/sensors.txt" sensors -A
  else
    log "  - Thermal: lm-sensors not available (skipped)"
  fi
}

collect_pbs_extended() {
  is_mode_full || return 0
  is_excluded "pbs-extended" && return 0
  have proxmox-backup-manager || return 0

  log "Collecting extended PBS information..."

  # Safe config copies (no keys, password hashes, TFA secrets, remote credentials)
  log "  - PBS configuration files..."
  mkdir -p "$OUTDIR/pbs/config"
  local cfg skip
  if [[ -d /etc/proxmox-backup ]]; then
    for cfg in /etc/proxmox-backup/*.cfg; do
      [[ -f "$cfg" ]] || continue
      skip="$(basename "$cfg")"
      case "$skip" in
        user.cfg|tfa.cfg|remote.cfg|domains.cfg) continue ;;
      esac
      cp -a "$cfg" "$OUTDIR/pbs/config/" 2>/dev/null || true
    done
  fi

  log "  - Users and ACL..."
  run_quick "$OUTDIR/pbs/user_list.txt" proxmox-backup-manager user list
  run_quick "$OUTDIR/pbs/acl_list.txt" proxmox-backup-manager acl list

  log "  - Remotes and sync jobs..."
  run_quick "$OUTDIR/pbs/remote_list.txt" proxmox-backup-manager remote list
  run_quick "$OUTDIR/pbs/sync_jobs.txt" proxmox-backup-manager sync-job list

  log "  - Prune and verify jobs..."
  run_quick "$OUTDIR/pbs/prune_jobs.txt" proxmox-backup-manager prune-job list
  run_quick "$OUTDIR/pbs/verify_jobs.txt" proxmox-backup-manager verify-job list

  log "  - Garbage collection..."
  run_quick "$OUTDIR/pbs/gc_list.txt" proxmox-backup-manager garbage-collection list

  local store
  for store in $(list_datastores); do
    [[ -n "$store" ]] || continue
    {
      echo "=== Datastore: $store ==="
      proxmox-backup-manager datastore show "$store" 2>/dev/null || echo "(show failed)"
      echo ""
      echo "=== Garbage collection status: $store ==="
      proxmox-backup-manager garbage-collection status "$store" 2>/dev/null || echo "(status failed)"
      echo ""
    } >> "$OUTDIR/pbs/datastore_details.txt" 2>&1 || true
  done

  log "  - Traffic control..."
  run_quick "$OUTDIR/pbs/traffic_control.txt" proxmox-backup-manager traffic-control list

  log "  - Notifications..."
  {
    echo "=== Notification targets ==="
    proxmox-backup-manager notification target list 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== Matchers ==="
    proxmox-backup-manager notification matcher list 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/pbs/notifications.txt" 2>&1

  log "  - Identity providers (LDAP/AD/OpenID)..."
  {
    echo "=== LDAP ==="
    proxmox-backup-manager ldap list 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== Active Directory ==="
    proxmox-backup-manager ad list 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== OpenID ==="
    proxmox-backup-manager openid list 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/pbs/identity_providers.txt" 2>&1

  log "  - ACME / certificates..."
  {
    echo "=== Certificate info ==="
    proxmox-backup-manager cert info 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== ACME accounts ==="
    proxmox-backup-manager acme account list 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== ACME plugins ==="
    proxmox-backup-manager acme plugin list 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/pbs/acme.txt" 2>&1

  log "  - S3 endpoints..."
  run_quick "$OUTDIR/pbs/s3_endpoints.txt" proxmox-backup-manager s3 endpoint list

  log "  - Subscription status..."
  {
    echo "=== Subscription Status ==="
    proxmox-backup-manager subscription get 2>/dev/null | sed -e 's/^\([[:space:]]*key:[[:space:]]*\).*/\1[REDACTED]/' || echo "(not available)"
  } >> "$OUTDIR/pbs/subscription.txt" 2>&1
}

collect_tape() {
  is_mode_full || return 0
  is_excluded "tape" && return 0

  if ! have proxmox-tape; then
    log "Tape: proxmox-tape not available (skipped)"
    return 0
  fi

  note_tool_use "proxmox-tape"
  log "Collecting tape information..."

  run_quick "$OUTDIR/tape/status.txt" proxmox-tape status
  run_quick "$OUTDIR/tape/drives.txt" proxmox-tape drive list
  run_quick "$OUTDIR/tape/drive_config.txt" proxmox-tape drive config
  run_quick "$OUTDIR/tape/changers.txt" proxmox-tape changer list
  run_quick "$OUTDIR/tape/changer_status.txt" proxmox-tape changer status
  run_quick "$OUTDIR/tape/inventory.txt" proxmox-tape inventory
  run_quick "$OUTDIR/tape/media.txt" proxmox-tape media list
  run_quick "$OUTDIR/tape/pools.txt" proxmox-tape pool list
  run_quick "$OUTDIR/tape/backup_jobs.txt" proxmox-tape backup-job list
  # Key IDs only — do not dump encryption secrets
  run_quick "$OUTDIR/tape/key_list.txt" proxmox-tape key list
}

collect_firewall() {
  is_mode_full || return 0
  is_excluded "firewall" && return 0

  log "Collecting firewall and security information..."

  {
    echo "=== nftables ==="
    if have nft; then
      nft list ruleset 2>/dev/null || echo "(nft list failed)"
    else
      echo "(nft not available)"
    fi
    echo ""
    echo "=== iptables ==="
    if have iptables-save; then
      iptables-save 2>/dev/null || echo "(iptables-save failed)"
    else
      echo "(iptables-save not available)"
    fi
    echo ""
    echo "=== ip6tables ==="
    if have ip6tables-save; then
      ip6tables-save 2>/dev/null || echo "(ip6tables-save failed)"
    else
      echo "(ip6tables-save not available)"
    fi
  } >> "$OUTDIR/security/firewall.txt" 2>&1

  log "  - SSL certificate information..."
  {
    echo "=== PBS Proxy Certificate ==="
    if [[ -f /etc/proxmox-backup/proxy.pem ]]; then
      if have openssl; then
        openssl x509 -in /etc/proxmox-backup/proxy.pem -noout -dates -subject -issuer 2>/dev/null || echo "(error reading)"
      else
        echo "(openssl not available)"
      fi
    else
      echo "(not present)"
    fi
    echo ""
    echo "=== proxmox-backup-manager cert info ==="
    if have proxmox-backup-manager; then
      proxmox-backup-manager cert info 2>/dev/null || echo "(not available)"
    fi
  } >> "$OUTDIR/security/ssl_info.txt" 2>&1

  log "  - SSH configuration..."
  [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$OUTDIR/security/sshd_config.txt" 2>/dev/null || true
}

collect_performance() {
  is_mode_full || return 0
  is_excluded "performance" && return 0

  log "Collecting performance data..."

  log "  - Top processes (CPU/Memory)..."
  {
    echo "=== Top 20 by Memory ==="
    ps aux --sort=-%mem 2>/dev/null | head -21 || true
    echo ""
    echo "=== Top 20 by CPU ==="
    ps aux --sort=-%cpu 2>/dev/null | head -21 || true
  } >> "$OUTDIR/performance/top_processes.txt" 2>&1

  if have iostat; then
    note_tool_use "sysstat (iostat)"
    log "  - I/O statistics (iostat)..."
    run_quick "$OUTDIR/performance/iostat.txt" iostat -xz 1 3
  else
    log "  - iostat: not available (skipped)"
  fi

  if have vmstat; then
    log "  - VM statistics (vmstat)..."
    run_quick "$OUTDIR/performance/vmstat.txt" vmstat 1 5
  else
    log "  - vmstat: not available (skipped)"
  fi

  if have sar; then
    note_tool_use "sysstat (sar)"
    log "  - System Activity Reports (sar)..."
    run "$OUTDIR/performance/sar_cpu.txt" sar -u 1 5
    run "$OUTDIR/performance/sar_disk.txt" sar -d 1 5
  else
    log "  - sar: not available (skipped)"
  fi
}

collect_system_extended() {
  is_mode_full || return 0
  is_excluded "system-extended" && return 0

  log "Collecting extended system information..."

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

  log "  - Systemd timers..."
  {
    echo "=== Systemd Timers ==="
    systemctl list-timers --all --no-pager 2>/dev/null || echo "(not available)"
  } >> "$OUTDIR/system/systemd_timers.txt" 2>&1
}

copy_pbs_task_logs() {
  local src="/var/log/proxmox-backup"
  local dst="$OUTDIR/logs/proxmox-backup"
  local f base sz count=0

  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"

  for f in "$src"/*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "tasks" ]] && continue
    if [[ -f "$f" ]]; then
      cp -a "$f" "$dst/" 2>/dev/null || true
    fi
  done

  [[ -d "$src/tasks" ]] || return 0
  mkdir -p "$dst/tasks"

  for f in "$src/tasks"/archive*; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "$dst/tasks/" 2>/dev/null || true
  done

  while IFS= read -r -d '' f; do
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" =~ ^[0-9]+$ ]] || continue
    (( sz > TASK_LOG_MAX_BYTES )) && continue
    cp -a "$f" "$dst/tasks/" 2>/dev/null || true
    count=$((count + 1))
    (( count >= TASK_LOG_MAX_FILES )) && break
  done < <(find "$src/tasks" -type f ! -name 'archive*' -mtime -"$TASK_LOG_MAX_AGE_DAYS" -print0 2>/dev/null)

  {
    echo "Task log copy limits:"
    echo "  max age: ${TASK_LOG_MAX_AGE_DAYS} days"
    echo "  max files: ${TASK_LOG_MAX_FILES}"
    echo "  max size per file: ${TASK_LOG_MAX_BYTES} bytes"
    echo "  copied task log files: ${count}"
  } >> "$dst/tasks/_copy_limits.txt"
}

# ---------- Self-test ----------

run_selftest() {
  echo "========================================"
  echo "  PBS Logscript Self-Test"
  echo "========================================"
  echo ""
  echo "Version: $VERSION"
  echo ""
  echo "System tools:"

  local tool
  for tool in timeout tar gzip zstd sha256sum md5sum; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "Storage tools:"
  for tool in smartctl nvme zpool zfs mdadm pvs vgs lvs; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "PBS tools:"
  for tool in proxmox-backup-manager proxmox-backup-client proxmox-backup-debug proxmox-tape; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "Hardware tools (for --full mode):"
  for tool in ipmitool sensors dmidecode lspci lsusb ethtool; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "Performance tools (for --full mode):"
  for tool in iostat vmstat sar; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "Other:"
  for tool in journalctl openssl nft iptables-save; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done

  echo ""
  echo "========================================"
  echo "Disk space: $(df -Ph . 2>/dev/null | awk 'NR==2 {print $4}') available"
  echo "========================================"
}

# ---------- Setup ----------

if [[ "$RUN_SELFTEST" == "yes" ]]; then
  run_selftest
  exit 0
fi

require_root

trap cleanup EXIT INT TERM

umask 077
export LC_ALL=C

log "PBS Support Log Collector v${VERSION}"
log "Mode: $MODE"
[[ "$VERBOSE" == "yes" ]] && log "Verbose mode: enabled"
[[ -n "$EXCLUDE_SECTIONS" ]] && log "Excluded sections: $EXCLUDE_SECTIONS"

if ! have proxmox-backup-manager && [[ ! -d /etc/proxmox-backup ]]; then
  warn "This does not look like a Proxmox Backup Server host (proxmox-backup-manager missing). Collecting system data only."
fi

log "Checking available tools..."
check_all_tools
prompt_install_tools

TARGET_DIR="${OUTPUT_DIR:-$(pwd)}"

if [[ -n "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"
fi

check_disk_space "$TARGET_DIR"

_rawSN="$(dmidecode -s system-serial-number 2>/dev/null || echo UNKNOWN_SN)"
_rawHOST="$(hostname -f 2>/dev/null || hostname || echo unknown-host)"

SN="$(printf '%s' "$_rawSN" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SN" ]] && SN="UNKNOWN"

HOST="$(printf '%s' "$_rawHOST" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$HOST" ]] && HOST="unknown-host"

TS="$(date -u +'%Y%m%d-%H%M%S')"

OUTDIR="$(mktemp -d -p "$TARGET_DIR" "${HOST}_${SN}_${TS}.pbslogs.XXXX")"
TOOLS_USED_FILE="$OUTDIR/_tools_used.txt"
ERRORS_FILE="$OUTDIR/_errors.txt"

touch "$TOOLS_USED_FILE" "$ERRORS_FILE"

log "Working directory: $OUTDIR"

mkdir -p "$OUTDIR/logs"
mkdir -p "$OUTDIR/system"
mkdir -p "$OUTDIR/network/net-if"
mkdir -p "$OUTDIR/pbs"
mkdir -p "$OUTDIR/security"
mkdir -p "$OUTDIR/hardware"
mkdir -p "$OUTDIR/performance"
mkdir -p "$OUTDIR/tape"

ARCHIVE_ZST="${TARGET_DIR}/${HOST}_${SN}_${TS}.pbs-supportlogs.tar.zst"
ARCHIVE_GZ="${TARGET_DIR}/${HOST}_${SN}_${TS}.pbs-supportlogs.tar.gz"

# ---------- Basic information ----------
log "Collecting basic information..."

{
  echo "========================================"
  echo "  PBS Support Log Collector"
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
    lsb_release -a 2>/dev/null || true
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

{
  for f in /var/log/apt/history.log*; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == *.gz ]]; then
      zcat "$f" 2>/dev/null || gzip -dc "$f" 2>/dev/null || true
    else
      cat "$f" 2>/dev/null || true
    fi
  done
} >> "$OUTDIR/system/apt_history.txt" 2>&1

# ---------- Journal / Syslog ----------
log "Collecting journald/syslog..."
if have journalctl; then
  run "$OUTDIR/journal_current.txt" journalctl -b --no-pager
  run "$OUTDIR/journal_7d.txt" journalctl --since="-7 days" --no-pager
  run "$OUTDIR/journal_pbs.txt" journalctl -u proxmox-backup -u proxmox-backup-proxy --since="-7 days" --no-pager
else
  {
    cat /var/log/syslog* 2>/dev/null || cat /var/log/messages* 2>/dev/null || true
  } >> "$OUTDIR/system/syslog.txt" 2>&1
fi

# ---------- Network ----------
if ! is_excluded "network"; then
  log "Collecting network data..."

  {
    echo "=== IP Addresses ==="
    ip -br a 2>/dev/null || true
    echo ""
    echo "=== Routing Table ==="
    ip r 2>/dev/null || true
    echo ""
    echo "=== Listening Ports ==="
    if have ss; then
      ss -tulpn 2>/dev/null || true
    elif have netstat; then
      netstat -tulpn 2>/dev/null || true
    fi
  } >> "$OUTDIR/network/network.txt" 2>&1

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

  {
    if [[ -f /etc/network/interfaces ]]; then
      echo "# /etc/network/interfaces"
      cat /etc/network/interfaces 2>/dev/null || true
      echo ""
    fi
    for f in /etc/network/interfaces.d/*; do
      if [[ -f "$f" ]]; then
        echo "### $f"
        cat "$f" 2>/dev/null || true
        echo ""
      fi
    done
  } >> "$OUTDIR/network/network_config.txt" 2>&1

  if have proxmox-backup-manager; then
    run_quick "$OUTDIR/network/pbs_network.txt" proxmox-backup-manager network list
    run_quick "$OUTDIR/network/pbs_dns.txt" proxmox-backup-manager dns get
  fi
else
  log "Skipping network data (--exclude network)"
fi

# ---------- Storage ----------
if ! is_excluded "storage"; then
  log "Collecting storage information..."

  {
    echo "=== MDADM Scan ==="
    mdadm --detail --scan 2>/dev/null || true
    echo ""
    for a in /dev/md[0-9] /dev/md[0-9][0-9] /dev/md[0-9][0-9][0-9] /dev/md/*; do
      if [[ -b "$a" ]]; then
        echo "=== $a ==="
        mdadm --detail "$a" 2>/dev/null || true
      fi
    done
  } >> "$OUTDIR/system/mdadm.txt" 2>&1

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
        echo "=== ZFS Properties (locally set) ==="
        zfs get all -s local 2>/dev/null || true
      fi
    } >> "$OUTDIR/zfs.txt" 2>&1
  fi

  if have proxmox-backup-manager; then
    {
      echo "=== PBS Disks ==="
      proxmox-backup-manager disk list 2>/dev/null || true
      echo ""
      echo "=== PBS Filesystems ==="
      proxmox-backup-manager disk fs list 2>/dev/null || true
      echo ""
      echo "=== PBS ZFS Pools ==="
      proxmox-backup-manager disk zpool list 2>/dev/null || true
    } >> "$OUTDIR/storage.txt" 2>&1
  fi
fi

# ---------- PBS core ----------
if have proxmox-backup-manager && ! is_excluded "pbs"; then
  note_tool_use "Proxmox Backup Server"
  log "Collecting PBS information..."

  run_quick "$OUTDIR/pbs/versions.txt" proxmox-backup-manager versions
  have proxmox-backup-client && run_quick "$OUTDIR/pbs/client_version.txt" proxmox-backup-client version
  run "$OUTDIR/pbs/report.txt" proxmox-backup-manager report
  run_quick "$OUTDIR/pbs/node.txt" proxmox-backup-manager node show
  run_quick "$OUTDIR/pbs/server_identity.txt" proxmox-backup-manager node server-identity
  run_quick "$OUTDIR/pbs/datastores.txt" proxmox-backup-manager datastore list
  run_quick "$OUTDIR/pbs/tasks.txt" proxmox-backup-manager task list --all --limit 1000

  {
    echo "=== Failed Units ==="
    systemctl --failed 2>/dev/null || true
    echo ""
    echo "=== PBS Service Status ==="
    for svc in proxmox-backup proxmox-backup-proxy proxmox-backup-banner postfix; do
      echo "--- $svc ---"
      systemctl status --no-pager "$svc" 2>/dev/null || true
      echo ""
    done
  } >> "$OUTDIR/pbs/services.txt" 2>&1
elif is_excluded "pbs"; then
  log "Skipping PBS data (--exclude pbs)"
fi

# ---------- SMART ----------
if ! is_excluded "smart"; then
  log "Collecting SMART data..."
  SMART_OUT="$OUTDIR/smart.txt"

  if have smartctl; then
    note_tool_use "smartmontools"
    for DEV in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/hd[a-z] /dev/vd[a-z] /dev/vd[a-z][a-z] /dev/xvd[a-z]; do
      [[ -b "$DEV" ]] || continue
      {
        echo "=== SMART: $DEV ==="
        smartctl -a "$DEV" 2>&1 || true
        echo ""
      } >> "$SMART_OUT"
    done
  fi

  log "Collecting NVMe data..."
  if have nvme; then
    note_tool_use "nvme-cli"
    run_quick "$OUTDIR/nvme_list.txt" nvme list

    for NV in /dev/nvme*n*; do
      [[ -b "$NV" ]] || continue
      [[ "$NV" == *p[0-9]* ]] && continue
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

# ---------- Copy system / PBS logs ----------
log "Copying relevant system logs..."

LOG_PATTERNS=(
  /var/log/syslog*
  /var/log/messages*
  /var/log/kern.log*
  /var/log/daemon.log*
)

for pattern in "${LOG_PATTERNS[@]}"; do
  for f in $pattern; do
    [[ -e "$f" ]] && cp -a "$f" "$OUTDIR/logs/" 2>/dev/null || true
  done
done

if ! is_excluded "pbs"; then
  log "Copying PBS task logs (recent, size-limited)..."
  copy_pbs_task_logs
fi

# ---------- Extended data collection (--full mode only) ----------
if is_mode_full; then
  log "Collecting extended data (--full mode)..."
  collect_hardware_extended
  collect_pbs_extended
  collect_tape
  collect_firewall
  collect_performance
  collect_system_extended
fi

# ---------- JSON metadata ----------
write_json_meta

# ---------- Pack ----------
log "Packing archive..."

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

if [[ -n "$ARCHIVE_CREATED" && -f "$ARCHIVE_CREATED" ]]; then
  generate_checksums "$ARCHIVE_CREATED"
fi

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
