#!/usr/bin/env bash
#
# Version: 3.2.0 - 01/2026
# Thomas-Krenn.AG - Proxmox VE Support Log Collector
# Autor: Samuel Mueller
# Kontakt: smueller@thomas-krenn.com
#
# Zweck:
#   Dieses Skript sammelt diagnostisch relevante Systeminformationen von
#   Proxmox VE Hosts, um Fehlersituationen reproduzierbarer, schneller und
#   supportseitig besser analysieren zu koennen. Die Ausfuehrung ist read-only,
#   abgesehen von der optionalen Installation von "nvme-cli".
#
# Funktionsumfang:
#   - Fortschritt-Ausgabe auf STDOUT (Sammle / Kopiere / Packe)
#   - Erfassung von Kernel-, Journal-, System-, Storage- und Netzwerkdaten
#   - Aggregation von Proxmox-Service- sowie VM/CT-Informationen
#   - SMART- und optional NVMe-SMART-Daten
#   - Ceph-Informationen (falls vorhanden) im eigenen Unterordner
#   - Speicherung genutzter optionaler Tools (_tools_used.txt)
#   - Speicherung von Warnungen und Hinweisen (_errors.txt)
#
# Betriebsmodi / Verhalten:
#   - Single-Node ohne Cluster: Cluster- und Ceph-Abschnitte werden ausgelassen.
#   - Cluster-Nodes: Corosync-, Quorum- und Storage-Informationen werden erfasst.
#   - Ceph-Nodes: PG-/OSD-/Health-Informationen werden gezielt gesammelt.
#   - NVMe-Support: Fragt (Standard) oder installiert nach Option "nvme-cli".
#
# Parameter:
#   --install-tools   Installiert fehlende Tools ohne Rueckfrage.
#   --no-install      Installiert keine Tools; fehlende Bereiche werden ausgelassen.
#   --keep-work       Loescht das temporaere Arbeitsverzeichnis nicht.
#   -h / --help       Zeigt diese Hilfe an.
#
# Ausgabestruktur:
#   <hostname>_<serial>_<timestamp>.logs-XXXX/
#       |_ logs/              System-/Proxmox-Logs
#       |_ ceph/              Ceph-bezogene Daten (falls vorhanden)
#       |_ net-if/            Schnittstellen-Statistiken
#       |_ .supportlogs.tar.* Archivierter Export
#
# Datenschutz / DSGVO-Hinweis:
#   Dieses Skript kann Hostnamen, Benutzernamen, VM-Namen und IP-Adressen auslesen.
#   Vor Weitergabe an Dritte ist eine Pruefung des Inhalts empfohlen.
#
# Haftungsausschluss:
#   Dieses Skript stellt eine Hilfestellung dar. Die Thomas-Krenn.AG uebernimmt
#   keine Haftung fuer Datenverlust, Systemverhalten oder Interpretationsfehler.
#   Die Ausfuehrung sollte durch fachkundige Personen erfolgen.
#
# Empfehlung:
#   Vor Ausfuehrung: Sicherstellen, dass ausreichend Speicherplatz verfuegbar ist.
#   Nach Ausfuehrung: Archiv generiert in lokalem Arbeitsverzeichnis.
#

set -Eeuo pipefail
shopt -s nullglob
shopt -s lastpipe

# ---------- Konstanten ----------
readonly VERSION="3.2.0"
readonly MIN_DISK_SPACE_MB=500
readonly CMD_TIMEOUT=60

# ---------- Globale Variablen ----------
ERRORS_FILE=""
TOOLS_USED_FILE=""
OUTDIR=""

# ---------- Helpers ----------
log()  { printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"; }

warn() {
  local msg
  msg=$(printf '[%s] WARN: %s\n' "$(date -u +'%F %T UTC')" "$*")
  printf '%s' "$msg" >&2
  [[ -n "$ERRORS_FILE" && -f "$ERRORS_FILE" ]] && printf '%s' "$msg" >> "$ERRORS_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }

note_tool_use() {
  [[ -n "$TOOLS_USED_FILE" && -f "$TOOLS_USED_FILE" ]] && echo "$1" >> "$TOOLS_USED_FILE"
}

# Verbesserte run-Funktion mit optionalem Timeout
run() {
  local out="$1"
  shift
  local timeout_cmd=()
  if have timeout; then
    timeout_cmd=(timeout "${CMD_TIMEOUT}s")
  fi
  { "${timeout_cmd[@]}" "$@" >>"$out" 2>&1; } || warn "Fehler bei: $* (siehe $(basename "$out"))"
}

# Run ohne Timeout (fuer schnelle Befehle)
run_quick() {
  local out="$1"
  shift
  { "$@" >>"$out" 2>&1; } || warn "Fehler bei: $* (siehe $(basename "$out"))"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Bitte als root ausfuehren."
    exit 1
  fi
}

check_disk_space() {
  local target_dir="$1"
  local available_mb
  available_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$available_mb" && "$available_mb" -lt "$MIN_DISK_SPACE_MB" ]]; then
    warn "Weniger als ${MIN_DISK_SPACE_MB}MB Speicherplatz verfuegbar (${available_mb}MB). Abbruch."
    exit 1
  fi
}

# Cleanup-Funktion fuer Trap
cleanup() {
  local exit_code=$?
  if [[ -n "$OUTDIR" && -d "$OUTDIR" && "$KEEP_WORK" != "yes" ]]; then
    rm -rf "$OUTDIR" 2>/dev/null || true
  fi
  exit $exit_code
}

# ---------- Options ----------
AUTO_INSTALL_TOOLS="ask"   # ask|yes|no
KEEP_WORK="no"

for arg in "$@"; do
  case "$arg" in
    --install-tools) AUTO_INSTALL_TOOLS="yes" ;;
    --no-install)    AUTO_INSTALL_TOOLS="no"  ;;
    --keep-work)     KEEP_WORK="yes"          ;;
    -v|--version)    echo "getpvelogs.sh v${VERSION}"; exit 0 ;;
    -h|--help)
      cat <<EOF
Usage: getpvelogs.sh [--install-tools|--no-install] [--keep-work] [-v|--version]
  --install-tools   Fehlt nvme-cli, wird es ohne Rueckfrage via apt-get installiert.
  --no-install      Keine Installation fehlender Tools.
  (Default)         Interaktive Rueckfrage bei fehlendem nvme-cli.
  --keep-work       Arbeitsverzeichnis NICHT loeschen (zum Debuggen).
  -v, --version     Zeigt die Version an.
EOF
      exit 0
      ;;
    *) warn "Unbekannte Option: $arg" ;;
  esac
done

# ---------- Optional installs ----------
maybe_install_nvme_cli() {
  if have nvme; then
    note_tool_use "nvme-cli"
    return 0
  fi

  case "$AUTO_INSTALL_TOOLS" in
    no)
      warn "nvme-cli fehlt - NVMe-Details werden ausgelassen."
      return 1
      ;;
    ask)
      read -rp "nvme-cli ist nicht installiert. Installieren? [y/N] " ans || true
      case "$ans" in
        y|Y) AUTO_INSTALL_TOOLS="yes" ;;
        *)   AUTO_INSTALL_TOOLS="no"
             warn "nvme-cli fehlt - NVMe-Details werden ausgelassen."
             return 1 ;;
      esac
      ;;
  esac

  if [[ "$AUTO_INSTALL_TOOLS" == "yes" ]]; then
    if have apt-get; then
      log "Installiere nvme-cli..."
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli >/dev/null || warn "nvme-cli Installation fehlgeschlagen."
      if have nvme; then
        note_tool_use "nvme-cli (nachinstalliert)"
      else
        return 1
      fi
    else
      warn "Kein apt-get verfuegbar - Installation nicht moeglich."
      return 1
    fi
  fi
}

# ---------- Setup ----------
require_root

# Trap fuer sauberes Aufraumen bei Abbruch
trap cleanup EXIT INT TERM

umask 077
export LC_ALL=C

# Disk-Space pruefen
check_disk_space "$(pwd)"

# Rohwerte holen
_rawSN="$(dmidecode -s system-serial-number 2>/dev/null || echo UNKNOWN_SN)"
_rawHOST="$(hostname -f 2>/dev/null || hostname || echo unknown-host)"

# Serial Number sanitizen (keine Leerzeichen, Tabs, Slashes etc.)
SN="$(printf '%s' "$_rawSN" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$SN" ]] && SN="UNKNOWN"

# Hostname leicht sanitizen
HOST="$(printf '%s' "$_rawHOST" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$HOST" ]] && HOST="unknown-host"

TS="$(date -u +'%Y%m%d-%H%M%S')"

OUTDIR="$(mktemp -d -p "$(pwd)" "${HOST}_${SN}_${TS}.logs.XXXX")"
TOOLS_USED_FILE="$OUTDIR/_tools_used.txt"
ERRORS_FILE="$OUTDIR/_errors.txt"

# Initialisiere Meta-Dateien
touch "$TOOLS_USED_FILE" "$ERRORS_FILE"

log "Arbeitsverzeichnis: $OUTDIR"
log "Script-Version: $VERSION"

mkdir -p "$OUTDIR/logs" "$OUTDIR/net-if" "$OUTDIR/ceph"

ARCHIVE_ZST="${HOST}_${SN}_${TS}.supportlogs.tar.zst"
ARCHIVE_GZ="${HOST}_${SN}_${TS}.supportlogs.tar.gz"

# ---------- Basisinformationen ----------
log "Sammle Basisinformationen..."

# Meta-Informationen gesammelt schreiben
{
  echo "========================================"
  echo "  PVE Support Log Collector"
  echo "========================================"
  echo ""
  echo "Tool-Version:    $VERSION"
  echo "Hostname:        $HOST"
  echo "Seriennummer:    $SN"
  echo "Ausgefuehrt am:  $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
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
} >> "$OUTDIR/hw.txt" 2>&1

run_quick "$OUTDIR/kernel_dmesg.txt" dmesg

# APT History
{
  for f in /var/log/apt/history.log*; do
    [[ -f "$f" ]] && cat "$f" 2>/dev/null
  done
} >> "$OUTDIR/apt_history.txt" 2>&1

# ---------- Journal / Syslog ----------
log "Sammle Journald/Syslog..."
if have journalctl; then
  run "$OUTDIR/journal_current.txt" journalctl -b --no-pager
  run "$OUTDIR/journal_7d.txt" journalctl --since="-7 days" --no-pager
else
  {
    cat /var/log/syslog* 2>/dev/null || cat /var/log/messages* 2>/dev/null || true
  } >> "$OUTDIR/syslog.txt" 2>&1
fi

# ---------- Netzwerk ----------
log "Sammle Netzwerkdaten..."

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
} >> "$OUTDIR/network.txt" 2>&1

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
  } >> "$OUTDIR/net-if/${IF}.txt"
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
} >> "$OUTDIR/network_config.txt" 2>&1

# ---------- Storage ----------
log "Sammle Storageinformationen..."

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
} >> "$OUTDIR/mdadm.txt" 2>&1

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
} >> "$OUTDIR/lvm.txt" 2>&1

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
    fi
  } >> "$OUTDIR/zfs.txt" 2>&1
fi

# ---------- Proxmox ----------
if have pveversion; then
  note_tool_use "Proxmox VE"

  run_quick "$OUTDIR/pveversion.txt" pveversion -v
  have pvereport && run "$OUTDIR/pvereport.txt" pvereport

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
  } >> "$OUTDIR/pve_services.txt" 2>&1

  # VMs und Container
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
  } >> "$OUTDIR/pve_vms.txt" 2>&1

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
  } >> "$OUTDIR/cluster.txt" 2>&1
fi

# ---------- Ceph ----------
if have ceph; then
  note_tool_use "Ceph"
  log "Sammle Ceph-Informationen..."

  # Timeout-Array fuer sichere Ausfuehrung
  TOUT=()
  have timeout && TOUT=(timeout "${CMD_TIMEOUT}s")

  run_quick "$OUTDIR/ceph/ceph_status.txt" ceph -s
  run_quick "$OUTDIR/ceph/ceph_health.txt" ceph health detail
  run_quick "$OUTDIR/ceph/ceph_osd.txt" ceph osd tree
  run_quick "$OUTDIR/ceph/ceph_mons.txt" ceph mon dump

  # Potentiell langsame Befehle mit Timeout
  { "${TOUT[@]}" ceph pg dump --format json >> "$OUTDIR/ceph/ceph_pg.txt" 2>&1; } || warn "ceph pg dump fehlgeschlagen oder Timeout"
  { "${TOUT[@]}" ceph osd df >> "$OUTDIR/ceph/ceph_osd_df.txt" 2>&1; } || warn "ceph osd df fehlgeschlagen oder Timeout"
fi

# ---------- SMART ----------
log "Sammle SMART-Daten..."
SMART_OUT="$OUTDIR/smart.txt"

if have smartctl; then
  note_tool_use "smartmontools"
  # Erweiterte Glob-Patterns fuer mehr Laufwerke (sda-sdz, sdaa-sdzz)
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
log "Sammle NVMe-Daten..."
maybe_install_nvme_cli || true

if have nvme; then
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
  warn "nvme-cli nicht verfuegbar - NVMe-Details ausgelassen."
fi

# ---------- Systemlogs kopieren ----------
log "Kopiere relevante Systemlogs..."

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

# ---------- Pack ----------
log "Packe Archiv..."

# Entferne leere Verzeichnisse
find "$OUTDIR" -type d -empty -delete 2>/dev/null || true

if have zstd; then
  note_tool_use "zstd"
  tar -C "$(dirname "$OUTDIR")" -I "zstd -19 --threads=0" -cf "$ARCHIVE_ZST" "$(basename "$OUTDIR")"
  log "Archiv erstellt: $ARCHIVE_ZST"
else
  note_tool_use "gzip"
  tar -C "$(dirname "$OUTDIR")" -czf "$ARCHIVE_GZ" "$(basename "$OUTDIR")"
  log "Archiv erstellt: $ARCHIVE_GZ"
fi

# ---------- Cleanup ----------
# Trap deaktivieren da wir jetzt manuell aufraeumen
trap - EXIT INT TERM

if [[ "$KEEP_WORK" == "yes" ]]; then
  log "Arbeitsverzeichnis bleibt erhalten: $OUTDIR"
else
  rm -rf "$OUTDIR"
fi

log "Fertig."
