#!/usr/bin/env bash
#
# Version: 3.1.0 — 10/2025
# Thomas-Krenn.AG — Proxmox VE Support Log Collector
# Autor: Samuel Mueller
# Kontakt: smueller@thomas-krenn.com
#
# Zweck:
#   Dieses Skript sammelt diagnostisch relevante Systeminformationen von
#   Proxmox VE Hosts, um Fehlersituationen reproduzierbarer, schneller und
#   supportseitig besser analysieren zu können. Die Ausführung ist read-only,
#   abgesehen von der optionalen Installation von "nvme-cli".
#
# Funktionsumfang:
#   • Fortschritt-Ausgabe auf STDOUT (Sammle / Kopiere / Packe)
#   • Erfassung von Kernel-, Journal-, System-, Storage- und Netzwerkdaten
#   • Aggregation von Proxmox-Service- sowie VM/CT-Informationen
#   • SMART- und optional NVMe-SMART-Daten
#   • Ceph-Informationen (falls vorhanden) im eigenen Unterordner
#   • Speicherung genutzter optionaler Tools (_tools_used.txt)
#   • Speicherung von Warnungen und Hinweisen (_errors.txt)
#
# Betriebsmodi / Verhalten:
#   • Single-Node ohne Cluster: Cluster- und Ceph-Abschnitte werden ausgelassen.
#   • Cluster-Nodes: Corosync-, Quorum- und Storage-Informationen werden erfasst.
#   • Ceph-Nodes: PG-/OSD-/Health-Informationen werden gezielt gesammelt.
#   • NVMe-Support: Fragt (Standard) oder installiert nach Option "nvme-cli".
#
# Parameter:
#   --install-tools   Installiert fehlende Tools ohne Rückfrage.
#   --no-install      Installiert keine Tools; fehlende Bereiche werden ausgelassen.
#   --keep-work       Löscht das temporäre Arbeitsverzeichnis nicht.
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
#   Vor Weitergabe an Dritte ist eine Prüfung des Inhalts empfohlen.
#
# Haftungsausschluss:
#   Dieses Skript stellt eine Hilfestellung dar. Die Thomas-Krenn.AG übernimmt
#   keine Haftung für Datenverlust, Systemverhalten oder Interpretationsfehler.
#   Die Ausführung sollte durch fachkundige Personen erfolgen.
#
# Empfehlung:
#   Vor Ausführung: Sicherstellen, dass ausreichend Speicherplatz verfügbar ist.
#   Nach Ausführung: Archiv generiert in lokalem Arbeitsverzeichnis.
#

set -Eeuo pipefail
shopt -s nullglob
shopt -s lastpipe

# ---------- Helpers ----------
ERRORS_FILE=""
TOOLS_USED_FILE=""

log()   { printf '[%s] %s\n' "$(date -u +'%F %T UTC')" "$*"; }
warn()  {
  local msg; msg=$(printf '[%s] WARN: %s\n' "$(date -u +'%F %T UTC')" "$*")
  printf '%s' "$msg" >&2
  [[ -n "$ERRORS_FILE" ]] && printf '%s' "$msg" >> "$ERRORS_FILE"
}
have()  { command -v "$1" >/dev/null 2>&1; }
note_tool_use(){ [[ -n "$TOOLS_USED_FILE" ]] && echo "$1" >> "$TOOLS_USED_FILE"; }
run() {
  local out="$1"; shift || true
  { "$@" >>"$out" 2>&1; } || warn "Fehler bei: $* (siehe $(basename "$out"))"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Bitte als root ausfÃ¼hren."
    exit 1
  fi
}

# ---------- Options ----------
AUTO_INSTALL_TOOLS="ask"   # ask|yes|no
KEEP_WORK="no"
for arg in "$@"; do
  case "$arg" in
    --install-tools) AUTO_INSTALL_TOOLS="yes" ;;
    --no-install)    AUTO_INSTALL_TOOLS="no"  ;;
    --keep-work)     KEEP_WORK="yes"          ;;
    -h|--help)
      cat <<'EOF'
Usage: getpvelogs.sh [--install-tools|--no-install] [--keep-work]
  --install-tools   Fehlt nvme-cli, wird es ohne RÃ¼ckfrage via apt-get installiert.
  --no-install      Keine Installation fehlender Tools.
  (Default)         Interaktive RÃ¼ckfrage bei fehlendem nvme-cli.
  --keep-work       Arbeitsverzeichnis NICHT lÃ¶schen (zum Debuggen).
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
      warn "nvme-cli fehlt â€“ NVMe-Details werden ausgelassen."
      return 1
      ;;
    ask)
      read -rp "nvme-cli ist nicht installiert. Installieren? [y/N] " ans || true
      case "$ans" in
        y|Y) AUTO_INSTALL_TOOLS="yes" ;;
        *)   AUTO_INSTALL_TOOLS="no"; warn "nvme-cli fehlt â€“ NVMe-Details werden ausgelassen."; return 1 ;;
      esac
      ;;
  esac

  if [[ "$AUTO_INSTALL_TOOLS" = "yes" ]]; then
    if have apt-get; then
      log "Installiere nvme-cliâ€¦"
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli >/dev/null || warn "nvme-cli Installation fehlgeschlagen."
      have nvme && note_tool_use "nvme-cli (nachinstalliert)" || return 1
    else
      warn "Kein apt-get verfÃ¼gbar â€“ Installation nicht mÃ¶glich."
      return 1
    fi
  fi
}

# ---------- Setup ----------
require_root
umask 077
export LC_ALL=C

# Rohwerte holen
_rawSN="$(dmidecode -s system-serial-number 2>/dev/null || echo UNKNOWN_SN)"
_rawHOST="$(hostname -f 2>/dev/null || hostname || echo unknown-host)"

# Serial Number sanitizen (keine Leerzeichen, Tabs, Slashes etc.)
SN="$(printf '%s' "$_rawSN" | tr -cd 'A-Za-z0-9._-')"
# Falls komplett leer -> Fallback
[[ -z "$SN" ]] && SN="UNKNOWN"

# Hostname leicht sanitizen (nur falls nÃ¶tig)
HOST="$(printf '%s' "$_rawHOST" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$HOST" ]] && HOST="unknown-host"

TS="$(date -u +'%Y%m%d-%H%M%S')"

OUTDIR="$(mktemp -d -p "$(pwd)" "${HOST}_${SN}_${TS}.logs.XXXX")"
TOOLS_USED_FILE="$OUTDIR/_tools_used.txt"
ERRORS_FILE="$OUTDIR/_errors.txt"
log "Arbeitsverzeichnis: $OUTDIR"

mkdir -p "$OUTDIR/logs" "$OUTDIR/net-if" "$OUTDIR/ceph"

ARCHIVE_ZST="${HOST}_${SN}_${TS}.supportlogs.tar.zst"
ARCHIVE_GZ="${HOST}_${SN}_${TS}.supportlogs.tar.gz"

# ---------- Basisinformationen ----------
log "Sammle Basisinformationenâ€¦"
run "$OUTDIR/_meta.txt"              bash -lc 'uname -a; if command -v lsb_release >/dev/null; then lsb_release -a; else cat /etc/os-release; fi; timedatectl 2>/dev/null || true; uptime; df -h; free -h'
run "$OUTDIR/hw.txt"                 bash -lc 'lscpu 2>/dev/null || true; lsblk -e7 -o NAME,MAJ:MIN,SIZE,ROTA,TYPE,MOUNTPOINT,FSTYPE,MODEL,SERIAL; (lspci -nn 2>/dev/null || true); (lsusb 2>/dev/null || true); (dmidecode -t system -t baseboard 2>/dev/null || true)'
run "$OUTDIR/kernel_dmesg.txt"       dmesg
run "$OUTDIR/apt_history.txt"        bash -lc 'cat /var/log/apt/history.log* 2>/dev/null || true'

# ---------- Journal / Syslog ----------
log "Sammle Journald/Syslogâ€¦"
if have journalctl; then
  run "$OUTDIR/journal_current.txt"  journalctl -b --no-pager
  run "$OUTDIR/journal_7d.txt"       journalctl --since="-7 days" --no-pager
else
  run "$OUTDIR/syslog.txt"           bash -lc 'cat /var/log/syslog* 2>/dev/null || cat /var/log/messages* 2>/dev/null || true'
fi

# ---------- Netzwerk ----------
log "Sammle Netzwerkdatenâ€¦"
run "$OUTDIR/network.txt"            bash -lc 'ip -br a; ip r'
if have ss; then run "$OUTDIR/network.txt" ss -tulpn; elif have netstat; then run "$OUTDIR/network.txt" netstat -tulpn; fi
for IF in /sys/class/net/*; do
  IF="$(basename "$IF")"
  {
    echo "### $IF"
    have ethtool && { ethtool -i "$IF" 2>/dev/null || true; ethtool "$IF" 2>/dev/null || true; ethtool -S "$IF" 2>/dev/null || true; }
  } >> "$OUTDIR/net-if/${IF}.txt"
done
{
  [[ -f /etc/network/interfaces ]] && { echo "# /etc/network/interfaces"; cat /etc/network/interfaces; echo; }
  for f in /etc/network/interfaces.d/*; do [[ -f "$f" ]] && { echo "### $f"; cat "$f"; echo; }; done
} >> "$OUTDIR/network_config.txt" 2>&1

# ---------- Storage ----------
log "Sammle Storageinformationenâ€¦"
run "$OUTDIR/mdadm.txt"              bash -lc 'mdadm --detail --scan 2>/dev/null || true; for a in /dev/md/*; do mdadm --detail "$a" 2>/dev/null || true; done'
run "$OUTDIR/lvm.txt"                bash -lc 'pvs 2>/dev/null || true; vgs 2>/dev/null || true; lvs -a 2>/dev/null || true'
if have zpool; then
  note_tool_use "ZFS"
  run "$OUTDIR/zfs.txt"              bash -lc 'zpool status -v; zpool list; if command -v zfs >/dev/null; then zfs list -t all -o name,used,avail,refer,mountpoint; fi'
fi

# ---------- Proxmox ----------
if have pveversion; then
  note_tool_use "Proxmox VE"
  run "$OUTDIR/pveversion.txt"       pveversion -v
  have pvereport && run "$OUTDIR/pvereport.txt" pvereport
  run "$OUTDIR/pve_services.txt"     bash -lc 'systemctl --failed; systemctl status --no-pager pvedaemon pveproxy pve-cluster pvestatd pve-firewall 2>/dev/null || true'
  have qm  && run "$OUTDIR/pve_vms.txt" qm list
  have pct && run "$OUTDIR/pve_vms.txt" pct list
  have pvesm && { run "$OUTDIR/storage.txt" pvesm status; run "$OUTDIR/storage.txt" pvesm list local 2>/dev/null || true; }
  have pvecm && { run "$OUTDIR/cluster.txt" pvecm status; run "$OUTDIR/cluster.txt" pvecm nodes; }
  have corosync-quorumtool && run "$OUTDIR/cluster.txt" corosync-quorumtool -s
  have corosync-cfgtool   && run "$OUTDIR/cluster.txt" corosync-cfgtool -s
fi

# ---------- Ceph ----------
if have ceph; then
  note_tool_use "Ceph"
  log "Sammle Ceph-Informationenâ€¦"
  TOUT=""; have timeout && TOUT="timeout 60s"
  run "$OUTDIR/ceph/ceph_status.txt"      ceph -s
  run "$OUTDIR/ceph/ceph_health.txt"      ceph health detail
  run "$OUTDIR/ceph/ceph_osd.txt"         ceph osd tree
  run "$OUTDIR/ceph/ceph_mons.txt"        ceph mon dump
  if [[ -n "$TOUT" ]]; then
    run "$OUTDIR/ceph/ceph_pg.txt"        $TOUT ceph pg dump --format json
    run "$OUTDIR/ceph/ceph_osd_df.txt"    $TOUT ceph osd df
  else
    run "$OUTDIR/ceph/ceph_pg.txt"        ceph pg dump --format json
    run "$OUTDIR/ceph/ceph_osd_df.txt"    ceph osd df
  fi
fi

# ---------- SMART ----------
log "Sammle SMART-Datenâ€¦"
SMART_OUT="$OUTDIR/smart.txt"
if have smartctl; then
  note_tool_use "smartmontools"
  for DEV in /dev/sd? /dev/hd? /dev/xvd? ; do
    [[ -b "$DEV" ]] || continue
    smartctl -a "$DEV" >> "$SMART_OUT" 2>&1 || warn "SMART fehlgeschlagen: $DEV"
  done
fi

# ---------- NVMe ----------
log "Sammle NVMe-Datenâ€¦"
maybe_install_nvme_cli || true
if have nvme; then
  run "$OUTDIR/nvme_list.txt"        nvme list
  for NV in /dev/nvme*n1; do
    [[ -b "$NV" ]] || continue
    run "$SMART_OUT"                 nvme smart-log "$NV"
    run "$SMART_OUT"                 nvme error-log "$NV"
    run "$SMART_OUT"                 nvme list-ns "$NV"
  done
else
  warn "nvme-cli nicht verfÃ¼gbar â€“ NVMe-Details ausgelassen."
fi

# ---------- Systemlogs ----------
log "Kopiere relevante Systemlogsâ€¦"
for f in /var/log/syslog* /var/log/messages* /var/log/kern.log* /var/log/daemon.log* \
         /var/log/pveproxy/* /var/log/pvedaemon/* /var/log/pvescheduler/* /var/log/pvestatd/* ; do
  [[ -e "$f" ]] && cp -a "$f" "$OUTDIR/logs/" || true
done

# ---------- Pack ----------
log "Packe Archivâ€¦"
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
if [[ "$KEEP_WORK" = "yes" ]]; then
  log "Arbeitsverzeichnis bleibt erhalten: $OUTDIR"
else
  rm -rf "$OUTDIR"
  log "Fertig."
fi
