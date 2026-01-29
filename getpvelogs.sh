#!/usr/bin/env bash
#
# Version: 4.0.2-tui - 01/2026
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
readonly VERSION="4.0.2-tui"
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
  msg="[$(date -u +'%F %T UTC')] WARN: $*"
  printf '%s\n' "$msg" >&2
  [[ -n "$ERRORS_FILE" && -f "$ERRORS_FILE" ]] && printf '%s\n' "$msg" >> "$ERRORS_FILE"
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

# ---------- Neue Helper-Funktionen (v4.0) ----------

# Verbose-Logging
log_verbose() {
  [[ "$VERBOSE" == "yes" ]] && printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"
}

# Prueft ob ein Bereich ausgeschlossen ist
is_excluded() {
  local section="$1"
  [[ -n "$EXCLUDE_SECTIONS" && "$EXCLUDE_SECTIONS" == *"$section"* ]]
}

# Prueft ob Modus mindestens 'normal' ist (normal oder full)
is_mode_normal_or_full() {
  [[ "$MODE" == "normal" || "$MODE" == "full" ]]
}

# Prueft ob Modus 'full' ist
is_mode_full() {
  [[ "$MODE" == "full" ]]
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
  [[ "$JSON_META" != "yes" ]] && return 0
  
  local tools_json=""
  if [[ -f "$TOOLS_USED_FILE" && -s "$TOOLS_USED_FILE" ]]; then
    # Tools als JSON-Array formatieren
    tools_json=$(awk 'BEGIN{ORS=""} {if(NR>1)printf ","; printf "\"%s\"", $0}' "$TOOLS_USED_FILE") || true
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
  return 0
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

Interaktiver Modus:
  -i, --interactive   Interaktive TUI (whiptail) starten

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
  sudo ./getpvelogs.sh --interactive        # Interaktiver Modus mit TUI
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
    -i|--interactive)
      INTERACTIVE="yes"
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
INTERACTIVE="${INTERACTIVE:-no}"

# ---------- Interaktive TUI (whiptail) ----------

# Prueft ob whiptail verfuegbar ist
check_whiptail() {
  if ! have whiptail; then
    echo "FEHLER: whiptail ist nicht installiert."
    echo "Installieren Sie es mit: apt-get install whiptail"
    echo ""
    echo "Alternativ koennen Sie das Skript mit Parametern ausfuehren:"
    echo "  $0 --help"
    exit 1
  fi
}

# Zeigt den Willkommens-Dialog
show_welcome() {
  whiptail --title "PVE Support Log Collector v${VERSION}" \
    --msgbox "Willkommen zum Proxmox VE Support Log Collector!\n\n\
Dieses Tool sammelt diagnostisch relevante Systeminformationen\n\
von Proxmox VE Hosts fuer den Support.\n\n\
Die Ausfuehrung ist read-only (bis auf optionale Tool-Installation).\n\n\
Druecken Sie OK, um fortzufahren." 16 65
}

# Modus-Auswahl
select_mode() {
  local choice
  choice=$(whiptail --title "Betriebsmodus waehlen" \
    --radiolist "Waehlen Sie den Umfang der Datensammlung:\n\n\
Verwenden Sie LEERTASTE zum Auswaehlen, ENTER zum Bestaetigen." 16 78 2 \
    "normal" "Standard: Journal, dmesg, Storage, SMART, Ceph, Cluster [Empfohlen]" ON \
    "full" "Vollstaendig: + Hardware, VM-Configs, Performance" OFF \
    3>&1 1>&2 2>&3)
  
  local exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    return 1
  fi
  
  MODE="$choice"
  return 0
}

# Tool-Installation Option
select_tool_install() {
  local choice
  choice=$(whiptail --title "Tool-Installation" \
    --radiolist "Wie sollen fehlende optionale Tools behandelt werden?\n\n\
Optionale Tools erweitern die Datensammlung (z.B. nvme-cli, ipmitool)." 16 70 3 \
    "ask" "Nachfragen - Bei fehlenden Tools einzeln fragen" ON \
    "yes" "Automatisch - Fehlende Tools ohne Nachfrage installieren" OFF \
    "no" "Nicht installieren - Fehlende Bereiche ueberspringen" OFF \
    3>&1 1>&2 2>&3)
  
  local exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    return 1
  fi
  
  AUTO_INSTALL_TOOLS="$choice"
  return 0
}

# Optionale Features (Checkboxen)
select_options() {
  local choices
  choices=$(whiptail --title "Zusaetzliche Optionen" \
    --checklist "Waehlen Sie zusaetzliche Optionen:\n\n\
Verwenden Sie LEERTASTE zum Auswaehlen, ENTER zum Bestaetigen." 18 75 6 \
    "anonymize" "Anonymisieren - IPs, MACs und Hostnamen ersetzen" OFF \
    "json-meta" "JSON-Metadaten - Zusaetzliche JSON-Datei erstellen" OFF \
    "verbose" "Verbose - Detaillierte Ausgabe waehrend Sammlung" OFF \
    "keep-work" "Arbeitsverzeichnis behalten (nicht loeschen)" OFF \
    3>&1 1>&2 2>&3)
  
  local exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    return 1
  fi
  
  # Optionen parsen
  [[ "$choices" == *"anonymize"* ]] && ANONYMIZE="yes"
  [[ "$choices" == *"json-meta"* ]] && JSON_META="yes"
  [[ "$choices" == *"verbose"* ]] && VERBOSE="yes"
  [[ "$choices" == *"keep-work"* ]] && KEEP_WORK="yes"
  
  return 0
}

# Bereiche ausschliessen (optional)
select_excludes() {
  # Nur fragen wenn gewuenscht
  if ! whiptail --title "Bereiche ausschliessen?" \
    --yesno "Moechten Sie bestimmte Bereiche von der Datensammlung ausschliessen?\n\n\
Dies ist nuetzlich, wenn Sie z.B. kein Ceph nutzen oder\n\
SMART-Daten nicht benoetigen." 12 65; then
    return 0
  fi
  
  local choices
  choices=$(whiptail --title "Bereiche ausschliessen" \
    --checklist "Waehlen Sie Bereiche, die NICHT gesammelt werden sollen:\n\n\
Verwenden Sie LEERTASTE zum Auswaehlen, ENTER zum Bestaetigen." 18 70 6 \
    "ceph" "Ceph-Cluster Informationen" OFF \
    "smart" "SMART/NVMe Festplattendaten" OFF \
    "storage" "Storage-Informationen (LVM, ZFS, MDADM)" OFF \
    "network" "Erweiterte Netzwerkdaten" OFF \
    "proxmox" "Proxmox-spezifische Daten" OFF \
    "hardware" "Hardware-Daten (nur bei --full relevant)" OFF \
    "firewall" "Firewall-Konfiguration (nur bei --full)" OFF \
    "performance" "Performance-Daten (nur bei --full)" OFF \
    3>&1 1>&2 2>&3)
  
  local exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    return 1
  fi
  
  # Kommaseparierte Liste erstellen
  if [[ -n "$choices" ]]; then
    # Anfuehrungszeichen entfernen und durch Kommas trennen
    EXCLUDE_SECTIONS=$(echo "$choices" | tr -d '"' | tr ' ' ',')
  fi
  
  return 0
}

# Ausgabeverzeichnis waehlen (optional)
select_output_dir() {
  if ! whiptail --title "Ausgabeverzeichnis" \
    --yesno "Moechten Sie ein eigenes Ausgabeverzeichnis festlegen?\n\n\
Standard: Aktuelles Verzeichnis ($(pwd))" 10 65; then
    return 0
  fi
  
  local dir
  dir=$(whiptail --title "Ausgabeverzeichnis" \
    --inputbox "Geben Sie den Pfad zum Ausgabeverzeichnis ein:" 10 65 \
    "$(pwd)" 3>&1 1>&2 2>&3)
  
  local exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    return 1
  fi
  
  if [[ -n "$dir" ]]; then
    OUTPUT_DIR="$dir"
  fi
  
  return 0
}

# Zusammenfassung und Bestaetigung
show_summary() {
  local exclude_text="Keine"
  [[ -n "$EXCLUDE_SECTIONS" ]] && exclude_text="$EXCLUDE_SECTIONS"
  
  local output_text="${OUTPUT_DIR:-$(pwd)}"
  
  local options_text=""
  [[ "$ANONYMIZE" == "yes" ]] && options_text+="Anonymisierung, "
  [[ "$JSON_META" == "yes" ]] && options_text+="JSON-Meta, "
  [[ "$VERBOSE" == "yes" ]] && options_text+="Verbose, "
  [[ "$KEEP_WORK" == "yes" ]] && options_text+="Arbeitsverz. behalten, "
  [[ -z "$options_text" ]] && options_text="Keine"
  options_text="${options_text%, }"  # Letztes Komma entfernen
  
  local install_text="Nachfragen"
  [[ "$AUTO_INSTALL_TOOLS" == "yes" ]] && install_text="Automatisch"
  [[ "$AUTO_INSTALL_TOOLS" == "no" ]] && install_text="Nicht installieren"
  
  whiptail --title "Zusammenfassung" \
    --yesno "Bitte ueberpruefen Sie Ihre Auswahl:\n\n\
  Betriebsmodus:       $MODE\n\
  Tool-Installation:   $install_text\n\
  Ausgabeverzeichnis:  $output_text\n\
  Ausgeschlossen:      $exclude_text\n\
  Optionen:            $options_text\n\n\
Moechten Sie die Datensammlung jetzt starten?" 18 70
  
  return $?
}

# Fortschritts-Dialog (Gauge)
show_progress() {
  local percent=$1
  local message=$2
  echo -e "XXX\n$percent\n$message\nXXX"
}

# Schnellstart-Menue
# Setzt TUI_QUICKSTART="yes" wenn Schnellstart gewaehlt wurde
# Setzt TUI_CUSTOM="yes" wenn benutzerdefiniert gewaehlt wurde
# Return 0 = Erfolg, Return 1 = Abgebrochen
TUI_QUICKSTART="no"
TUI_CUSTOM="no"

show_quickstart() {
  TUI_QUICKSTART="no"
  TUI_CUSTOM="no"
  
  local choice
  choice=$(whiptail --title "PVE Support Log Collector v${VERSION}" \
    --menu "Willkommen! Waehlen Sie eine Option:" 16 70 4 \
    "quick-normal" "Schnellstart - Standardmodus (empfohlen)" \
    "quick-full" "Schnellstart - Vollstaendiger Modus" \
    "custom" "Benutzerdefiniert - Alle Optionen durchgehen" \
    "selftest" "Systemtest - Verfuegbare Tools anzeigen" \
    3>&1 1>&2 2>&3) || {
      # Benutzer hat Abbrechen gedrueckt
      return 1
    }
  
  case "$choice" in
    quick-normal)
      MODE="normal"
      AUTO_INSTALL_TOOLS="ask"
      TUI_QUICKSTART="yes"
      return 0
      ;;
    quick-full)
      MODE="full"
      AUTO_INSTALL_TOOLS="ask"
      TUI_QUICKSTART="yes"
      return 0
      ;;
    custom)
      TUI_CUSTOM="yes"
      return 0
      ;;
    selftest)
      clear
      run_selftest
      echo ""
      read -rp "Druecken Sie ENTER um fortzufahren..." || true
      # Rekursiv neu starten
      show_quickstart
      return $?
      ;;
    *)
      # Sollte nicht passieren, aber sicherheitshalber
      return 1
      ;;
  esac
}

# Bestaetigung fuer Schnellstart
confirm_quickstart() {
  local mode_desc=""
  case "$MODE" in
    normal) mode_desc="Standard (empfohlen)" ;;
    full)   mode_desc="Vollstaendig (inkl. Hardware/Performance)" ;;
  esac
  
  whiptail --title "Schnellstart bestaetigen" \
    --yesno "Datensammlung starten mit:\n\n\
  Modus: $mode_desc\n\
  Ausgabe: $(pwd)\n\
  Tool-Installation: Bei Bedarf nachfragen\n\n\
Moechten Sie fortfahren?" 14 60
  
  return $?
}

# Hauptfunktion fuer die TUI
run_interactive_tui() {
  check_whiptail
  
  # Pruefe root-Rechte vor TUI-Start
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    whiptail --title "Fehler" \
      --msgbox "Dieses Skript muss als root ausgefuehrt werden!\n\n\
Bitte starten Sie es erneut mit:\n\
  sudo $0 --interactive" 12 55
    exit 1
  fi
  
  # Schnellstart-Menue anzeigen
  if ! show_quickstart; then
    whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
    exit 0
  fi
  
  if [[ "$TUI_QUICKSTART" == "yes" ]]; then
    # Schnellstart - nur Bestaetigung
    if ! confirm_quickstart; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
  elif [[ "$TUI_CUSTOM" == "yes" ]]; then
    # Benutzerdefiniert - alle Dialoge durchlaufen
    
    # Willkommen
    show_welcome
    
    # Modus auswaehlen
    if ! select_mode; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
    
    # Tool-Installation
    if ! select_tool_install; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
    
    # Zusaetzliche Optionen
    if ! select_options; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
    
    # Bereiche ausschliessen
    if ! select_excludes; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
    
    # Ausgabeverzeichnis
    if ! select_output_dir; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
    
    # Zusammenfassung und Bestaetigung
    if ! show_summary; then
      whiptail --title "Abgebrochen" --msgbox "Vorgang abgebrochen." 8 40
      exit 0
    fi
  fi
  
  # TUI beenden, normaler Ablauf wird fortgesetzt
  whiptail --title "Starte Datensammlung" \
    --infobox "Die Datensammlung wird gestartet...\n\n\
Die Ausgabe erfolgt nun im Terminal." 8 50
  
  sleep 2
  clear
  
  # Zurueck zum normalen Skript-Ablauf
  return 0
}

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
    return 0  # Kein Fehler, nur Warnung
  fi
  
  log "Aktualisiere Paketlisten..."
  apt-get update -qq || warn "apt-get update fehlgeschlagen"
  
  for pkg in "${!MISSING_TOOLS[@]}"; do
    log "Installiere $pkg..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
      note_tool_use "$pkg (nachinstalliert)"
      unset "MISSING_TOOLS[$pkg]" || true
    else
      warn "Installation von $pkg fehlgeschlagen."
    fi
  done
  
  return 0
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
      install_missing_tools || true
      ;;
    no)
      log "Tools werden nicht installiert - einige Bereiche werden ausgelassen."
      ;;
    ask)
      read -rp "Moechten Sie die fehlenden Tools installieren? [y/N] " ans || true
      case "$ans" in
        y|Y)
          install_missing_tools || true
          ;;
        *)
          log "Tools werden nicht installiert - einige Bereiche werden ausgelassen."
          ;;
      esac
      ;;
  esac
  
  return 0
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
  
  log_verbose "Sammle erweiterte Hardware-Informationen..."
  
  # IPMI/BMC - mit schneller Vorab-Pruefung
  if have ipmitool; then
    # Schneller Test ob IPMI ueberhaupt verfuegbar ist (max 5 Sekunden)
    if timeout 5s ipmitool mc info >/dev/null 2>&1; then
      note_tool_use "ipmitool"
      log_verbose "Sammle IPMI-Sensordaten..."
      
      # BMC Info sammeln
      {
        echo "=== BMC Info ==="
        timeout 10s ipmitool mc info 2>&1 || echo "(Fehler beim Abrufen)"
        echo ""
      } > "$OUTDIR/hardware/ipmi_info.txt"
      
      # Sensoren (mit Fallback-Nachricht)
      {
        echo "=== IPMI Sensors ==="
        local sensor_output
        sensor_output=$(timeout 15s ipmitool sensor list 2>&1) || true
        if [[ -z "$sensor_output" ]]; then
          echo "(Keine IPMI-Sensoren verfuegbar oder konfiguriert)"
        elif [[ "$sensor_output" == *"not found"* ]] || [[ "$sensor_output" == *"Unknown"* ]]; then
          echo "(IPMI-Sensoren nicht lesbar)"
          echo ""
          echo "Rohe Ausgabe:"
          echo "$sensor_output"
        else
          echo "$sensor_output"
        fi
      } > "$OUTDIR/hardware/ipmi_sensors.txt"
      
      # System Event Log (mit Fallback-Nachricht)
      {
        echo "=== IPMI System Event Log ==="
        local sel_output
        sel_output=$(timeout 15s ipmitool sel list 2>&1) || true
        if [[ -z "$sel_output" ]]; then
          echo "(System Event Log ist leer)"
        elif [[ "$sel_output" == *"not found"* ]]; then
          echo "(Keine SEL-Eintraege vorhanden - System Event Log ist leer)"
        else
          echo "$sel_output"
        fi
      } > "$OUTDIR/hardware/ipmi_sel.txt"
      
      # FRU Daten (mit Fallback-Nachricht)
      {
        echo "=== IPMI FRU Data ==="
        local fru_output
        fru_output=$(timeout 15s ipmitool fru print 2>&1) || true
        if [[ -z "$fru_output" ]]; then
          echo "(Keine FRU-Daten verfuegbar)"
        elif [[ "$fru_output" == *"Unknown FRU"* ]] || [[ "$fru_output" == *"not found"* ]]; then
          echo "(FRU-Daten nicht konfiguriert oder nicht lesbar)"
          echo ""
          echo "Rohe Ausgabe:"
          echo "$fru_output"
        else
          echo "$fru_output"
        fi
      } > "$OUTDIR/hardware/ipmi_fru.txt"
      
    else
      log_verbose "IPMI/BMC nicht erreichbar - IPMI-Daten werden ausgelassen."
      {
        echo "=== IPMI Status ==="
        echo "IPMI/BMC nicht erreichbar oder nicht vorhanden."
        echo ""
        echo "Moegliche Ursachen:"
        echo "  - System ist eine virtuelle Maschine"
        echo "  - Kein BMC/IPMI-Controller vorhanden"
        echo "  - IPMI-Treiber nicht geladen (ipmi_devintf, ipmi_si)"
        echo "  - BMC nicht konfiguriert"
      } > "$OUTDIR/hardware/ipmi_info.txt"
    fi
  else
    log_verbose "ipmitool nicht verfuegbar - IPMI-Daten werden ausgelassen."
  fi
  
  # Thermal (lm-sensors)
  if have sensors; then
    note_tool_use "lm-sensors"
    log_verbose "Sammle Thermal-Daten..."
    run_quick "$OUTDIR/hardware/sensors.txt" sensors -A
  else
    log_verbose "lm-sensors nicht verfuegbar - Thermal-Daten werden ausgelassen."
  fi
  
  return 0
}

# Proxmox-Datensammler: VM/CT-Configs, Backup, HA, Replication, etc. (nur --full)
collect_pve_extended() {
  is_mode_full || return 0
  is_excluded "proxmox-extended" && return 0
  have pveversion || return 0
  
  log_verbose "Sammle erweiterte Proxmox-Informationen..."
  
  # VM-Konfigurationen
  if [[ -d /etc/pve/qemu-server ]]; then
    mkdir -p "$OUTDIR/proxmox/vm-configs"
    for conf in /etc/pve/qemu-server/*.conf; do
      [[ -f "$conf" ]] && cp "$conf" "$OUTDIR/proxmox/vm-configs/" 2>/dev/null || true
    done
    log_verbose "VM-Konfigurationen kopiert."
  fi
  
  # CT-Konfigurationen
  if [[ -d /etc/pve/lxc ]]; then
    mkdir -p "$OUTDIR/proxmox/ct-configs"
    for conf in /etc/pve/lxc/*.conf; do
      [[ -f "$conf" ]] && cp "$conf" "$OUTDIR/proxmox/ct-configs/" 2>/dev/null || true
    done
    log_verbose "CT-Konfigurationen kopiert."
  fi
  
  # Backup-Konfiguration
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
    log_verbose "Sammle HA-Manager Status..."
    run_quick "$OUTDIR/proxmox/ha_status.txt" ha-manager status
    
    if [[ -d /etc/pve/ha ]]; then
      mkdir -p "$OUTDIR/ha-config"
      cp -r /etc/pve/ha/* "$OUTDIR/proxmox/ha-config/" 2>/dev/null || true
    fi
  fi
  
  # Replication
  if have pvesr; then
    log_verbose "Sammle Replication-Status..."
    run_quick "$OUTDIR/replication_status.txt" pvesr status
    [[ -f /etc/pve/replication.cfg ]] && cp /etc/pve/replication.cfg "$OUTDIR/proxmox/" 2>/dev/null || true
  fi
  
  # Subscription
  log_verbose "Sammle Subscription-Status..."
  {
    echo "=== Subscription Status ==="
    pvesubscription get 2>/dev/null || echo "(nicht verfuegbar)"
  } >> "$OUTDIR/proxmox/subscription.txt" 2>&1
  
  # SDN (Software Defined Networking)
  if [[ -d /etc/pve/sdn ]]; then
    log_verbose "Sammle SDN-Konfiguration..."
    mkdir -p "$OUTDIR/sdn-config"
    cp -r /etc/pve/sdn/* "$OUTDIR/proxmox/sdn-config/" 2>/dev/null || true
  fi
  
  # PBS (Proxmox Backup Server) Client Status
  if have proxmox-backup-client; then
    log_verbose "Sammle PBS-Client Status..."
    note_tool_use "proxmox-backup-client"
    run_quick "$OUTDIR/pbs_status.txt" proxmox-backup-client version
  fi
  
  return 0
}

# Firewall-Datensammler (nur --full)
collect_firewall() {
  is_mode_full || return 0
  is_excluded "firewall" && return 0
  
  log_verbose "Sammle Firewall-Informationen..."
  
  # PVE Firewall Status
  if have pve-firewall; then
    run_quick "$OUTDIR/security/firewall_status.txt" pve-firewall status
  fi
  
  # Firewall-Configs kopieren
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
  [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$OUTDIR/security/sshd_config.txt" 2>/dev/null || true
  
  return 0
}

# Performance-Datensammler (nur --full)
collect_performance() {
  is_mode_full || return 0
  is_excluded "performance" && return 0
  
  log_verbose "Sammle Performance-Daten..."
  
  # Top Prozesse
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
    log_verbose "Sammle iostat-Daten..."
    run_quick "$OUTDIR/performance/iostat.txt" iostat -xz 1 3
  fi
  
  # vmstat
  if have vmstat; then
    log_verbose "Sammle vmstat-Daten..."
    run_quick "$OUTDIR/performance/vmstat.txt" vmstat 1 5
  fi
  
  # sar (falls vorhanden)
  if have sar; then
    note_tool_use "sysstat (sar)"
    log_verbose "Sammle sar-Daten..."
    run "$OUTDIR/performance/sar_cpu.txt" sar -u 1 5
    run "$OUTDIR/performance/sar_disk.txt" sar -d 1 5
  fi
  
  return 0
}

# System-Erweiterungen (nur --full)
collect_system_extended() {
  is_mode_full || return 0
  is_excluded "system-extended" && return 0
  
  log_verbose "Sammle erweiterte System-Informationen..."
  
  # Boot-Konfiguration
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
  {
    echo "=== Systemd Timers ==="
    systemctl list-timers --all --no-pager 2>/dev/null || echo "(nicht verfuegbar)"
  } >> "$OUTDIR/system/systemd_timers.txt" 2>&1
  
  return 0
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
      
      # IPv4-Adressen ersetzen (aber nicht 127.0.0.1 und 0.0.0.0)
      sed -i \
        -e 's/\b\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\b/X.X.X.X/g' \
        "$file" 2>/dev/null || true
      
      # MAC-Adressen ersetzen (Format: XX:XX:XX:XX:XX:XX)
      sed -i \
        -e 's/\b[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\b/XX:XX:XX:XX:XX:XX/g' \
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
    echo "IP-Adressen: ersetzt durch X.X.X.X"
    echo "MAC-Adressen: ersetzt durch XX:XX:XX:XX:XX:XX"
    echo "Hostname: ersetzt durch HOSTNAME"
  } >> "$OUTDIR/_meta.txt"
  
  log "Anonymisierung abgeschlossen."
  return 0
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

# Interaktiver TUI-Modus
if [[ "$INTERACTIVE" == "yes" ]]; then
  run_interactive_tui
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

  run_quick "$OUTDIR/proxmox/pveversion.txt" pveversion -v
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
  collect_hardware_extended || true
  collect_pve_extended || true
  collect_firewall || true
  collect_performance || true
  collect_system_extended || true
fi

# ---------- JSON-Metadaten ----------
write_json_meta || true

# ---------- Anonymisierung (VOR dem Archivieren) ----------
anonymize_output || true

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
