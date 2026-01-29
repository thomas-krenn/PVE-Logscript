#!/usr/bin/env bash
#
# Version: 4.0.2 - 01/2026
# Thomas-Krenn.AG - Proxmox VE Support Log Collector
# Autor: Samuel Mueller
# Kontakt: smueller@thomas-krenn.com
#
# Zweck:
#   Dieses Skript sammelt diagnostisch relevante Systeminformationen von
#   Proxmox VE Hosts, um Fehlersituationen reproduzierbarer, schneller und
#   supportseitig besser analysieren zu koennen. Die Ausfuehrung ist read-only,
#   abgesehen von der optionalen Installation von Tools wie nvme-cli, ipmitool, etc.
#
# Funktionsumfang:
#   - Zwei Betriebsmodi: --normal (Default), --full
#   - Fortschritt-Ausgabe auf STDOUT (Sammle / Kopiere / Packe)
#   - Erfassung von Kernel-, Journal-, System-, Storage- und Netzwerkdaten
#   - Aggregation von Proxmox-Service- sowie VM/CT-Informationen
#   - SMART- und optional NVMe-SMART-Daten
#   - Ceph-Informationen (falls vorhanden) im eigenen Unterordner
#   - Hardware-Informationen (IPMI, Thermal) im --full Modus
#   - VM/CT-Konfigurationen, Backup, HA, Replication im --full Modus
#   - Firewall-Konfiguration und SSL-Zertifikate im --full Modus
#   - Performance-Daten (iostat, vmstat, sar) im --full Modus
#   - Optionale Anonymisierung von IPs, MACs und Hostnamen
#   - Speicherung genutzter optionaler Tools (_tools_used.txt)
#   - Speicherung von Warnungen und Hinweisen (_errors.txt)
#   - Checksummen-Generierung (SHA256/MD5)
#
# Betriebsmodi:
#   --normal  Standard-Umfang: Journal, dmesg, PVE-Services, Netzwerk,
#             Storage, SMART, Ceph, Cluster, VM/CT-Listen (Default)
#   --full    Normal + Hardware (IPMI, Thermal), VM/CT-Configs, Firewall,
#             Performance, Backup/HA/Replication
#
# Datenschutz / DSGVO-Hinweis:
#   Dieses Skript kann Hostnamen, Benutzernamen, VM-Namen und IP-Adressen auslesen.
#   Verwenden Sie --anonymize um diese Daten vor Weitergabe zu anonymisieren.
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
readonly VERSION="4.0.2"
readonly MIN_DISK_SPACE_MB=500
readonly CMD_TIMEOUT=60

# ---------- Globale Variablen ----------
ERRORS_FILE=""
TOOLS_USED_FILE=""
OUTDIR=""

# ---------- Neue Optionen (v4.0) ----------
MODE="normal"              # normal|full
VERBOSE="no"               # yes|no
ANONYMIZE="no"             # yes|no
OUTPUT_DIR=""              # Benutzerdefiniertes Ausgabeverzeichnis
EXCLUDE_SECTIONS=""        # Kommaseparierte Liste auszuschliessender Bereiche
JSON_META="no"             # yes|no - JSON-Metadaten exportieren

# Assoziatives Array fuer fehlende Tools
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

# ---------- Neue Helper-Funktionen (v4.0) ----------

# Verbose-Logging
log_verbose() {
  [[ "$VERBOSE" == "yes" ]] && printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"
  return 0
}

# Prueft ob ein Bereich ausgeschlossen ist
is_excluded() {
  local section="$1"
  [[ -n "$EXCLUDE_SECTIONS" && "$EXCLUDE_SECTIONS" == *"$section"* ]] && return 0
  return 1
}

# Prueft ob Modus mindestens 'normal' ist (normal oder full)
is_mode_normal_or_full() {
  [[ "$MODE" == "normal" || "$MODE" == "full" ]] && return 0
  return 1
}

# Prueft ob Modus 'full' ist
is_mode_full() {
  [[ "$MODE" == "full" ]] && return 0
  return 1
}

# Generiert Checksummen fuer das Archiv
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

# Schreibt JSON-Metadaten
write_json_meta() {
  [[ "$JSON_META" != "yes" ]] && return
  
  local tools_json=""
  if [[ -f "$TOOLS_USED_FILE" && -s "$TOOLS_USED_FILE" ]]; then
    # Tools als JSON-Array formatieren
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
  log_verbose "JSON-Metadaten geschrieben: _meta.json"
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

show_help() {
  cat <<EOF
Usage: getpvelogs.sh [OPTIONS]

Proxmox VE Support Log Collector v${VERSION}
Sammelt diagnostisch relevante Systeminformationen von Proxmox VE Hosts.

Betriebsmodi:
  --normal            Standard-Umfang (Default)
  --full              Vollstaendige Datensammlung inkl. Hardware

Tool-Installation:
  --install-tools     Fehlende Tools automatisch installieren
  --no-install        Keine Tools installieren

Ausgabe:
  --output-dir PATH   Ausgabeverzeichnis festlegen
  --exclude SECTIONS  Bereiche ausschliessen (kommasepariert: ceph,smart,network,storage,proxmox)
  --anonymize         IPs, MACs und Hostnamen anonymisieren
  --json-meta         Metadaten als JSON exportieren
  --verbose           Detaillierte Ausgabe

Sonstiges:
  --keep-work         Arbeitsverzeichnis behalten
  --check             Selbsttest (zeigt verfuegbare Tools)
  -v, --version       Version anzeigen
  -h, --help          Diese Hilfe anzeigen

Beispiele:
  sudo ./getpvelogs.sh --full --install-tools
  sudo ./getpvelogs.sh --normal --output-dir /tmp
  sudo ./getpvelogs.sh --normal --exclude ceph,smart --anonymize

EOF
  exit 0
}

# Parameter-Parsing mit while-Schleife fuer Argumente mit Werten
while [[ $# -gt 0 ]]; do
  case "$1" in
    # Betriebsmodi
    --normal)         MODE="normal"          ;;
    --full)           MODE="full"            ;;
    
    # Tool-Installation
    --install-tools)  AUTO_INSTALL_TOOLS="yes" ;;
    --no-install)     AUTO_INSTALL_TOOLS="no"  ;;
    
    # Ausgabe-Optionen
    --output-dir)
      shift
      [[ $# -eq 0 ]] && { warn "--output-dir benoetigt einen Pfad"; exit 1; }
      OUTPUT_DIR="$1"
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      ;;
    --exclude)
      shift
      [[ $# -eq 0 ]] && { warn "--exclude benoetigt eine Bereichsliste"; exit 1; }
      EXCLUDE_SECTIONS="$1"
      ;;
    --exclude=*)
      EXCLUDE_SECTIONS="${1#*=}"
      ;;
    --anonymize)      ANONYMIZE="yes"        ;;
    --json-meta)      JSON_META="yes"        ;;
    --verbose)        VERBOSE="yes"          ;;
    
    # Sonstiges
    --keep-work)      KEEP_WORK="yes"        ;;
    --check)
      # Selbsttest wird spaeter ausgefuehrt
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
      warn "Unbekannte Option: $1"
      ;;
  esac
  shift
done

# Variable fuer Selbsttest initialisieren falls nicht gesetzt
RUN_SELFTEST="${RUN_SELFTEST:-no}"

# ---------- Tool-Check-System ----------
# Prueft alle benoetigten Tools und fragt gesammelt nach Installation

check_all_tools() {
  # Tools nur im entsprechenden Modus pruefen
  have nvme     || MISSING_TOOLS[nvme-cli]="NVMe SMART-Daten"
  
  # Tools nur fuer --full Modus relevant
  if [[ "$MODE" == "full" ]]; then
    have ipmitool || MISSING_TOOLS[ipmitool]="IPMI/BMC Sensor-Daten"
    have sensors  || MISSING_TOOLS[lm-sensors]="Thermal-Daten"
    have iostat   || MISSING_TOOLS[sysstat]="Performance-Statistiken (iostat, sar)"
  fi
}

install_missing_tools() {
  if ! have apt-get; then
    warn "Kein apt-get verfuegbar - Installation nicht moeglich."
    return 1
  fi
  
  log "Aktualisiere Paketlisten..."
  apt-get update -qq
  
  for pkg in "${!MISSING_TOOLS[@]}"; do
    log "Installiere $pkg..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
      note_tool_use "$pkg (nachinstalliert)"
      unset "MISSING_TOOLS[$pkg]"
    else
      warn "Installation von $pkg fehlgeschlagen."
    fi
  done
}

prompt_install_tools() {
  [[ ${#MISSING_TOOLS[@]} -eq 0 ]] && return 0
  
  echo ""
  echo "Folgende optionale Tools fehlen:"
  for pkg in "${!MISSING_TOOLS[@]}"; do
    echo "  - $pkg: ${MISSING_TOOLS[$pkg]}"
  done
  echo ""
  
  case "$AUTO_INSTALL_TOOLS" in
    yes)
      install_missing_tools
      ;;
    no)
      warn "Tools werden nicht installiert - einige Bereiche werden ausgelassen."
      ;;
    ask)
      read -rp "Moechten Sie die fehlenden Tools installieren? [y/N] " ans || true
      case "$ans" in
        y|Y)
          install_missing_tools
          ;;
        *)
          warn "Tools werden nicht installiert - einige Bereiche werden ausgelassen."
          ;;
      esac
      ;;
  esac
}

# Legacy-Funktion fuer Kompatibilitaet (wird nicht mehr direkt verwendet)
maybe_install_nvme_cli() {
  if have nvme; then
    note_tool_use "nvme-cli"
    return 0
  fi
  return 1
}

# ---------- Neue Datensammler (v4.0) ----------

# Hardware-Datensammler: IPMI und Thermal (nur --full)
collect_hardware_extended() {
  is_mode_full || return 0
  is_excluded "hardware" && return 0
  
  log "Sammle erweiterte Hardware-Informationen..."
  
  # IPMI/BMC
  if have ipmitool; then
    note_tool_use "ipmitool"
    log "  - IPMI-Sensordaten..."
    run "$OUTDIR/hardware/ipmi_sensors.txt" ipmitool sensor list
    run "$OUTDIR/hardware/ipmi_sel.txt" ipmitool sel list
    run "$OUTDIR/hardware/ipmi_fru.txt" ipmitool fru print
  else
    log "  - IPMI: ipmitool nicht verfuegbar (uebersprungen)"
  fi
  
  # Thermal (lm-sensors)
  if have sensors; then
    note_tool_use "lm-sensors"
    log "  - Thermal-Daten (lm-sensors)..."
    run_quick "$OUTDIR/hardware/sensors.txt" sensors -A
  else
    log "  - Thermal: lm-sensors nicht verfuegbar (uebersprungen)"
  fi
}

# Proxmox-Datensammler: VM/CT-Configs, Backup, HA, Replication, etc. (nur --full)
collect_pve_extended() {
  is_mode_full || return 0
  is_excluded "proxmox-extended" && return 0
  have pveversion || return 0
  
  log "Sammle erweiterte Proxmox-Informationen..."
  
  # VM-Konfigurationen
  if [[ -d /etc/pve/qemu-server ]]; then
    local vm_count
    vm_count=$(find /etc/pve/qemu-server -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)
    if [[ "$vm_count" -gt 0 ]]; then
      mkdir -p "$OUTDIR/proxmox/vm-configs"
      for conf in /etc/pve/qemu-server/*.conf; do
        [[ -f "$conf" ]] && cp "$conf" "$OUTDIR/proxmox/vm-configs/" 2>/dev/null || true
      done
      log "  - VM-Konfigurationen: $vm_count VMs kopiert"
    else
      log "  - VM-Konfigurationen: keine VMs vorhanden"
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
      log "  - CT-Konfigurationen: $ct_count Container kopiert"
    else
      log "  - CT-Konfigurationen: keine Container vorhanden"
    fi
  fi
  
  # Backup-Konfiguration
  log "  - Backup-Konfiguration..."
  {
    echo "=== vzdump.conf ==="
    cat /etc/vzdump.conf 2>/dev/null || echo "(nicht vorhanden)"
    echo ""
    echo "=== Backup Jobs (vzdump.cron) ==="
    cat /etc/pve/vzdump.cron 2>/dev/null || echo "(nicht vorhanden)"
    echo ""
    echo "=== Backup Jobs (jobs.cfg) ==="
    cat /etc/pve/jobs.cfg 2>/dev/null || echo "(nicht vorhanden)"
  } >> "$OUTDIR/proxmox/backup_config.txt" 2>&1
  
  # HA-Manager
  if have ha-manager; then
    log "  - HA-Manager Status..."
    run_quick "$OUTDIR/proxmox/ha_status.txt" ha-manager status
    
    if [[ -d /etc/pve/ha ]]; then
      mkdir -p "$OUTDIR/proxmox/ha-config"
      cp -r /etc/pve/ha/* "$OUTDIR/proxmox/ha-config/" 2>/dev/null || true
    fi
  else
    log "  - HA-Manager: nicht verfuegbar (uebersprungen)"
  fi
  
  # Replication
  if have pvesr; then
    log "  - Replication-Status..."
    run_quick "$OUTDIR/proxmox/replication_status.txt" pvesr status
    [[ -f /etc/pve/replication.cfg ]] && cp /etc/pve/replication.cfg "$OUTDIR/proxmox/" 2>/dev/null || true
  else
    log "  - Replication: pvesr nicht verfuegbar (uebersprungen)"
  fi
  
  # Subscription
  log "  - Subscription-Status..."
  {
    echo "=== Subscription Status ==="
    pvesubscription get 2>/dev/null || echo "(nicht verfuegbar)"
  } >> "$OUTDIR/proxmox/subscription.txt" 2>&1
  
  # SDN (Software Defined Networking)
  if [[ -d /etc/pve/sdn ]]; then
    log "  - SDN-Konfiguration..."
    mkdir -p "$OUTDIR/proxmox/sdn-config"
    cp -r /etc/pve/sdn/* "$OUTDIR/proxmox/sdn-config/" 2>/dev/null || true
  else
    log "  - SDN: nicht konfiguriert (uebersprungen)"
  fi
  
  # PBS (Proxmox Backup Server) Client Status
  if have proxmox-backup-client; then
    log "  - PBS-Client Status..."
    note_tool_use "proxmox-backup-client"
    run_quick "$OUTDIR/proxmox/pbs_status.txt" proxmox-backup-client version
  fi
}

# Firewall-Datensammler (nur --full)
collect_firewall() {
  is_mode_full || return 0
  is_excluded "firewall" && return 0
  
  log "Sammle Firewall- und Sicherheitsinformationen..."
  
  # PVE Firewall Status
  if have pve-firewall; then
    log "  - PVE Firewall-Status..."
    run_quick "$OUTDIR/security/firewall_status.txt" pve-firewall status
  else
    log "  - PVE Firewall: nicht verfuegbar (uebersprungen)"
  fi
  
  # Firewall-Configs kopieren
  log "  - Firewall-Konfigurationen..."
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
  
  # SSL-Zertifikat Info
  log "  - SSL-Zertifikat-Informationen..."
  {
    echo "=== PVE SSL Certificate ==="
    if [[ -f /etc/pve/local/pve-ssl.pem ]]; then
      openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -dates -subject -issuer 2>/dev/null || echo "(Fehler beim Lesen)"
    else
      echo "(nicht vorhanden)"
    fi
    echo ""
    echo "=== PVE Root CA ==="
    if [[ -f /etc/pve/pve-root-ca.pem ]]; then
      openssl x509 -in /etc/pve/pve-root-ca.pem -noout -dates -subject 2>/dev/null || echo "(Fehler beim Lesen)"
    else
      echo "(nicht vorhanden)"
    fi
  } >> "$OUTDIR/security/ssl_info.txt" 2>&1
  
  # SSH Config (ohne private Keys!)
  log "  - SSH-Konfiguration..."
  [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$OUTDIR/security/sshd_config.txt" 2>/dev/null || true
}

# Performance-Datensammler (nur --full)
collect_performance() {
  is_mode_full || return 0
  is_excluded "performance" && return 0
  
  log "Sammle Performance-Daten..."
  
  # Top Prozesse
  log "  - Top-Prozesse (CPU/Memory)..."
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
    log "  - I/O-Statistiken (iostat)..."
    run_quick "$OUTDIR/performance/iostat.txt" iostat -xz 1 3
  else
    log "  - iostat: nicht verfuegbar (uebersprungen)"
  fi
  
  # vmstat
  if have vmstat; then
    log "  - VM-Statistiken (vmstat)..."
    run_quick "$OUTDIR/performance/vmstat.txt" vmstat 1 5
  else
    log "  - vmstat: nicht verfuegbar (uebersprungen)"
  fi
  
  # sar (falls vorhanden)
  if have sar; then
    note_tool_use "sysstat (sar)"
    log "  - System Activity Reports (sar)..."
    run "$OUTDIR/performance/sar_cpu.txt" sar -u 1 5
    run "$OUTDIR/performance/sar_disk.txt" sar -d 1 5
  else
    log "  - sar: nicht verfuegbar (uebersprungen)"
  fi
}

# System-Erweiterungen (nur --full)
collect_system_extended() {
  is_mode_full || return 0
  is_excluded "system-extended" && return 0
  
  log "Sammle erweiterte System-Informationen..."
  
  # Boot-Konfiguration
  log "  - Boot-Konfiguration (Kernel, GRUB, Module)..."
  {
    echo "=== Kernel Cmdline ==="
    cat /proc/cmdline 2>/dev/null || echo "(nicht verfuegbar)"
    echo ""
    echo "=== GRUB Config ==="
    cat /etc/default/grub 2>/dev/null || echo "(nicht vorhanden)"
    echo ""
    echo "=== Kernel Modules ==="
    lsmod 2>/dev/null || echo "(nicht verfuegbar)"
  } >> "$OUTDIR/system/boot_config.txt" 2>&1
  
  # Systemd Timer
  log "  - Systemd-Timer..."
  {
    echo "=== Systemd Timers ==="
    systemctl list-timers --all --no-pager 2>/dev/null || echo "(nicht verfuegbar)"
  } >> "$OUTDIR/system/systemd_timers.txt" 2>&1
}

# ---------- Anonymisierung ----------

anonymize_output() {
  [[ "$ANONYMIZE" != "yes" ]] && return 0
  
  log "Anonymisiere gesammelte Daten..."
  log_verbose "Ersetze IP-Adressen, MAC-Adressen und Hostnamen..."
  
  # Zaehler fuer Ersetzungen
  local ip_count=0
  local mac_count=0
  
  # Alle Textdateien im Ausgabeverzeichnis finden
  while IFS= read -r -d '' file; do
    # Nur Textdateien verarbeiten
    if file -b "$file" 2>/dev/null | grep -q "text"; then
      log_verbose "Anonymisiere: $(basename "$file")"
      
      # IPv4-Adressen ersetzen (erstes und letztes Oktett bleiben sichtbar)
      # Beispiel: 192.168.1.100 -> 192.X.X.100
      sed -i \
        -e 's/\b\([0-9]\{1,3\}\)\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.\([0-9]\{1,3\}\)\b/\1.X.X.\2/g' \
        "$file" 2>/dev/null || true
      
      # MAC-Adressen ersetzen (letzte 3 Bloecke bleiben sichtbar)
      # Beispiel: AA:BB:CC:DD:EE:FF -> XX:XX:XX:DD:EE:FF
      sed -i \
        -e 's/\b[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:\([0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\)\b/XX:XX:XX:\1/g' \
        "$file" 2>/dev/null || true
      
      # Hostname ersetzen (nur wenn nicht leer)
      if [[ -n "$HOST" && "$HOST" != "unknown-host" ]]; then
        sed -i \
          -e "s/${HOST}/HOSTNAME/g" \
          "$file" 2>/dev/null || true
      fi
    fi
  done < <(find "$OUTDIR" -type f -print0)
  
  # Hinweis in _meta.txt hinzufuegen
  {
    echo ""
    echo "========================================"
    echo "  HINWEIS: Daten wurden anonymisiert"
    echo "========================================"
    echo "IP-Adressen: teilweise maskiert (erstes.X.X.letztes Oktett)"
    echo "MAC-Adressen: teilweise maskiert (XX:XX:XX:letzte:drei:bloecke)"
    echo "Hostname: ersetzt durch HOSTNAME"
  } >> "$OUTDIR/_meta.txt"
  
  log "Anonymisierung abgeschlossen."
}

# ---------- Selbsttest ----------

run_selftest() {
  echo "========================================"
  echo "  PVE Logscript Selbsttest"
  echo "========================================"
  echo ""
  echo "Version: $VERSION"
  echo ""
  echo "System-Tools:"
  
  local sys_tools=(timeout tar gzip zstd sha256sum md5sum)
  for tool in "${sys_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Storage-Tools:"
  
  local storage_tools=(smartctl nvme zpool zfs mdadm pvs vgs lvs)
  for tool in "${storage_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Proxmox-Tools:"
  
  local pve_tools=(pveversion pvereport pvecm pvesm qm pct ha-manager pvesr pve-firewall)
  for tool in "${pve_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Hardware-Tools (fuer --full Modus):"
  
  local hw_tools=(ipmitool sensors dmidecode lspci lsusb ethtool)
  for tool in "${hw_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Performance-Tools (fuer --full Modus):"
  
  local perf_tools=(iostat vmstat sar)
  for tool in "${perf_tools[@]}"; do
    if have "$tool"; then
      printf "  [\033[32m✓\033[0m] %s\n" "$tool"
    else
      printf "  [\033[31m✗\033[0m] %s\n" "$tool"
    fi
  done
  
  echo ""
  echo "Sonstiges:"
  
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
  echo "Speicherplatz: $(df -h . 2>/dev/null | awk 'NR==2 {print $4}') verfuegbar"
  echo "========================================"
}

# ---------- Setup ----------

# Selbsttest-Modus (--check) - benoetigt kein root
if [[ "$RUN_SELFTEST" == "yes" ]]; then
  run_selftest
  exit 0
fi

require_root

# Trap fuer sauberes Aufraumen bei Abbruch
trap cleanup EXIT INT TERM

umask 077
export LC_ALL=C

# Modus und Optionen ausgeben
log "PVE Support Log Collector v${VERSION}"
log "Modus: $MODE"
[[ "$VERBOSE" == "yes" ]] && log "Verbose-Modus: aktiviert"
[[ "$ANONYMIZE" == "yes" ]] && log "Anonymisierung: aktiviert"
[[ -n "$EXCLUDE_SECTIONS" ]] && log "Ausgeschlossene Bereiche: $EXCLUDE_SECTIONS"

# Tool-Check und Installation (vor der Datensammlung)
log "Pruefe verfuegbare Tools..."
check_all_tools
prompt_install_tools

# Ausgabeverzeichnis bestimmen
TARGET_DIR="${OUTPUT_DIR:-$(pwd)}"

# Disk-Space pruefen
check_disk_space "$TARGET_DIR"

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

# Ausgabeverzeichnis erstellen (in TARGET_DIR)
if [[ -n "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR"
fi
OUTDIR="$(mktemp -d -p "$TARGET_DIR" "${HOST}_${SN}_${TS}.logs.XXXX")"
TOOLS_USED_FILE="$OUTDIR/_tools_used.txt"
ERRORS_FILE="$OUTDIR/_errors.txt"

# Initialisiere Meta-Dateien
touch "$TOOLS_USED_FILE" "$ERRORS_FILE"

log "Arbeitsverzeichnis: $OUTDIR"

# Ordnerstruktur erstellen
mkdir -p "$OUTDIR/logs"
mkdir -p "$OUTDIR/system"
mkdir -p "$OUTDIR/network/net-if"
mkdir -p "$OUTDIR/proxmox"
mkdir -p "$OUTDIR/security"
mkdir -p "$OUTDIR/hardware"
mkdir -p "$OUTDIR/performance"
mkdir -p "$OUTDIR/ceph"

# Archivnamen (im gleichen Verzeichnis wie OUTDIR)
ARCHIVE_ZST="${TARGET_DIR}/${HOST}_${SN}_${TS}.supportlogs.tar.zst"
ARCHIVE_GZ="${TARGET_DIR}/${HOST}_${SN}_${TS}.supportlogs.tar.gz"

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
  echo "Modus:           $MODE"
  echo "Ausgefuehrt am:  $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  [[ -n "$EXCLUDE_SECTIONS" ]] && echo "Ausgeschlossen:  $EXCLUDE_SECTIONS"
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

# APT History
{
  for f in /var/log/apt/history.log*; do
    [[ -f "$f" ]] && cat "$f" 2>/dev/null
  done
} >> "$OUTDIR/system/apt_history.txt" 2>&1

# ---------- Journal / Syslog ----------
log "Sammle Journald/Syslog..."
if have journalctl; then
  run "$OUTDIR/journal_current.txt" journalctl -b --no-pager
  run "$OUTDIR/journal_7d.txt" journalctl --since="-7 days" --no-pager
else
  {
    cat /var/log/syslog* 2>/dev/null || cat /var/log/messages* 2>/dev/null || true
  } >> "$OUTDIR/system/syslog.txt" 2>&1
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
# Storage-Informationen nur bei normal/full Modus
if is_mode_normal_or_full && ! is_excluded "storage"; then
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

  # VMs und Container (nur bei normal/full)
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
if is_mode_normal_or_full && ! is_excluded "smart"; then
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
  # Tool-Installation wurde bereits oben durchgefuehrt
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
    log_verbose "nvme-cli nicht verfuegbar - NVMe-Details werden ausgelassen."
  fi
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

# ---------- Erweiterte Datensammlung (nur --full Modus) ----------
if is_mode_full; then
  log "Sammle erweiterte Daten (--full Modus)..."
  collect_hardware_extended
  collect_pve_extended
  collect_firewall
  collect_performance
  collect_system_extended
fi

# ---------- JSON-Metadaten ----------
write_json_meta

# ---------- Anonymisierung (VOR dem Archivieren) ----------
anonymize_output

# ---------- Pack ----------
log "Packe Archiv..."

# Entferne leere Verzeichnisse
find "$OUTDIR" -type d -empty -delete 2>/dev/null || true

ARCHIVE_CREATED=""
if have zstd; then
  note_tool_use "zstd"
  tar -C "$(dirname "$OUTDIR")" -I "zstd -19 --threads=0" -cf "$ARCHIVE_ZST" "$(basename "$OUTDIR")"
  log "Archiv erstellt: $ARCHIVE_ZST"
  ARCHIVE_CREATED="$ARCHIVE_ZST"
else
  note_tool_use "gzip"
  tar -C "$(dirname "$OUTDIR")" -czf "$ARCHIVE_GZ" "$(basename "$OUTDIR")"
  log "Archiv erstellt: $ARCHIVE_GZ"
  ARCHIVE_CREATED="$ARCHIVE_GZ"
fi

# ---------- Checksummen ----------
if [[ -n "$ARCHIVE_CREATED" && -f "$ARCHIVE_CREATED" ]]; then
  generate_checksums "$ARCHIVE_CREATED"
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
log ""
log "Ausgabedateien:"
log "  Archiv: $ARCHIVE_CREATED"
[[ -f "${ARCHIVE_CREATED}.sha256" ]] && log "  SHA256: ${ARCHIVE_CREATED}.sha256"
[[ -f "${ARCHIVE_CREATED}.md5" ]] && log "  MD5:    ${ARCHIVE_CREATED}.md5"
