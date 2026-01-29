# Proxmox VE Support Log Collector

**Version:** 4.0.0 — 01/2026

**Autor:** Samuel Müller

**Kontakt:** [smueller@thomas-krenn.com](mailto:smueller@thomas-krenn.com)

---

## Zweck

Dieses Skript sammelt diagnostisch relevante Systeminformationen von **Proxmox VE Hosts**, um Fehlersituationen reproduzierbarer, schneller und supportseitig besser analysieren zu können.

Die Ausführung erfolgt **read-only**, mit Ausnahme der **optionalen Installation von Tools** wie `nvme-cli`, `ipmitool`, `lm-sensors` und `sysstat`.

---

## Neuerungen in Version 4.0

* **Interaktive TUI:** Neuer geführter Modus mit `--interactive` (whiptail-basiert)
* **Drei Betriebsmodi:** `--fast`, `--normal` (Standard), `--full`
* **Automatische Tool-Erkennung:** Alle benötigten Tools werden vor der Sammlung geprüft und bei Bedarf gesammelt nachinstalliert
* **Anonymisierung:** Mit `--anonymize` werden IPs, MACs und Hostnamen automatisch ersetzt
* **Erweiterte Hardware-Daten:** IPMI/BMC-Sensoren, Thermal-Daten (im `--full` Modus)
* **Erweiterte Proxmox-Daten:** VM/CT-Konfigurationen, Backup-Jobs, HA, Replication, SDN (im `--full` Modus)
* **Firewall-Konfiguration:** PVE Firewall-Regeln und SSL-Zertifikate (im `--full` Modus)
* **Performance-Daten:** iostat, vmstat, sar Snapshots (im `--full` Modus)
* **Checksummen:** SHA256/MD5 des Archivs wird automatisch erstellt
* **Selbsttest:** Mit `--check` werden alle verfügbaren Tools angezeigt (ohne Datensammlung)

---

## Installation & Verwendung

### 1. Repository klonen

```bash
git clone https://github.com/thomas-krenn/PVE-Logscript.git
```

### 2. In das Verzeichnis wechseln

```bash
cd PVE-Logscript
```

### 3. Skript ausführbar machen

```bash
chmod +x getpvelogs.sh
```

### 4. Skript ausführen (als root)

```bash
sudo ./getpvelogs.sh
```

### Alternativ: Einzeiler

Falls das Skript nur einmalig benötigt wird:

```bash
curl -sL https://raw.githubusercontent.com/thomas-krenn/PVE-Logscript/main/getpvelogs.sh | sudo bash
```

---

## Interaktive TUI

Mit dem Parameter `--interactive` (oder `-i`) startet das Skript eine benutzerfreundliche Text-Oberfläche (TUI), die Sie durch alle Optionen führt.

### Schnellstart-Menü

```
┌──────────────────────────────────────────────────────────────────┐
│ PVE Support Log Collector v4.0.0                                 │
├──────────────────────────────────────────────────────────────────┤
│ ○ Schnellstart - Standardmodus (empfohlen)                       │
│ ○ Schnellstart - Vollständiger Modus                             │
│ ○ Schnellstart - Nur essentielle Logs                            │
│ ○ Benutzerdefiniert - Alle Optionen durchgehen                   │
│ ○ Systemtest - Verfügbare Tools anzeigen                         │
└──────────────────────────────────────────────────────────────────┘
```

### Benutzerdefinierter Modus

Im benutzerdefinierten Modus werden Sie durch folgende Dialoge geführt:

1. **Betriebsmodus** - Wahl zwischen fast/normal/full
2. **Tool-Installation** - Verhalten bei fehlenden Tools
3. **Zusätzliche Optionen** - Anonymisierung, JSON-Meta, Verbose, etc.
4. **Bereiche ausschließen** - Optional Ceph, SMART, etc. überspringen
5. **Ausgabeverzeichnis** - Optional eigenen Pfad wählen
6. **Zusammenfassung** - Bestätigung vor dem Start

### TUI starten

```bash
sudo ./getpvelogs.sh --interactive
# oder kurz:
sudo ./getpvelogs.sh -i
```

> **Hinweis:** Die TUI benötigt `whiptail`, das auf den meisten Debian/Ubuntu-Systemen vorinstalliert ist.

---

## Beispiele

```bash
# Interaktiver Modus mit geführter TUI (empfohlen für Einsteiger)
sudo ./getpvelogs.sh --interactive

# Standard-Ausführung (normal Modus) mit interaktiver Abfrage
sudo ./getpvelogs.sh

# Schnelle Ausführung - nur essentielle Logs
sudo ./getpvelogs.sh --fast

# Vollständige Datensammlung inkl. Hardware und Performance
sudo ./getpvelogs.sh --full --install-tools

# Anonymisierte Ausgabe für DSGVO-konforme Weitergabe
sudo ./getpvelogs.sh --anonymize

# Ausgabe in bestimmtes Verzeichnis
sudo ./getpvelogs.sh --output-dir /tmp/logs

# Bestimmte Bereiche ausschließen
sudo ./getpvelogs.sh --exclude ceph,smart

# Selbsttest - zeigt verfügbare Tools ohne Datensammlung
./getpvelogs.sh --check

# Version anzeigen
./getpvelogs.sh --version
```

---

## Parameter

### Interaktiver Modus

| Parameter | Beschreibung |
|-----------|--------------|
| `-i`, `--interactive` | Startet die interaktive TUI (whiptail) mit geführter Konfiguration |

### Betriebsmodi

| Parameter | Beschreibung |
|-----------|--------------|
| `--fast` | Nur essentielle Logs: Journal, dmesg, PVE-Services, Netzwerk-Basis |
| `--normal` | Fast + Storage, SMART, Ceph, Cluster, VM/CT-Listen (Standard) |
| `--full` | Normal + Hardware (IPMI, Thermal), VM/CT-Configs, Firewall, Performance, Backup/HA/Replication |

### Tool-Installation

| Parameter | Beschreibung |
|-----------|--------------|
| `--install-tools` | Fehlende Tools automatisch installieren |
| `--no-install` | Keine Tools installieren; fehlende Bereiche werden übersprungen |

### Ausgabe-Optionen

| Parameter | Beschreibung |
|-----------|--------------|
| `--output-dir PATH` | Ausgabeverzeichnis festlegen |
| `--exclude SECTIONS` | Bereiche ausschließen (kommasepariert: `ceph,smart,network,storage,proxmox`) |
| `--anonymize` | IPs, MACs und Hostnamen anonymisieren |
| `--json-meta` | Metadaten zusätzlich als JSON exportieren |
| `--verbose` | Detaillierte Ausgabe während der Ausführung |

### Sonstiges

| Parameter | Beschreibung |
|-----------|--------------|
| `--keep-work` | Temporäres Arbeitsverzeichnis nicht löschen |
| `--check` | Selbsttest: zeigt verfügbare Tools ohne Datensammlung |
| `-v`, `--version` | Version anzeigen |
| `-h`, `--help` | Hilfe anzeigen |

---

## Funktionsumfang

### Basis (alle Modi)

* Fortschrittsausgabe auf STDOUT
* Kernel-dmesg und Journal-Logs
* Netzwerk-Konfiguration und Interface-Details
* PVE Service-Status

### Normal-Modus (zusätzlich zu Basis)

* Storage: LVM, ZFS, MDADM
* SMART-Daten (SATA/SAS und NVMe)
* Ceph-Informationen (falls vorhanden)
* Cluster-Status (Corosync, Quorum)
* VM/CT-Listen

### Full-Modus (zusätzlich zu Normal)

* Hardware: IPMI/BMC-Sensoren, Thermal-Daten (lm-sensors)
* VM/CT-Konfigurationsdateien
* Backup-Konfiguration (vzdump, Jobs)
* HA-Manager Status und Konfiguration
* Replication-Status
* SDN-Konfiguration
* Subscription-Status
* Firewall-Regeln (Cluster, Host, VM)
* SSL-Zertifikat-Informationen
* SSH-Konfiguration
* Performance-Snapshots: iostat, vmstat, sar
* Boot-Konfiguration (GRUB, Kernel-Cmdline)
* Systemd-Timer

---

## Ausgabestruktur

### Standard-Ausgabe

```text
<hostname>_<serial>_<timestamp>.logs-XXXX/
├── _meta.txt                 Metadaten und Systemübersicht
├── _meta.json                JSON-Metadaten (bei --json-meta)
├── _tools_used.txt           Liste verwendeter Tools
├── _errors.txt               Warnungen und Fehler
├── hw.txt                    Hardware-Informationen
├── kernel_dmesg.txt          Kernel-Meldungen
├── journal_*.txt             Journald-Logs
├── network.txt               Netzwerk-Status
├── network_config.txt        Netzwerk-Konfiguration
├── logs/                     System- und PVE-Logs
├── net-if/                   Interface-Statistiken
└── ceph/                     Ceph-Daten (falls vorhanden)
```

### Zusätzlich im Full-Modus

```text
├── ipmi_sensors.txt          IPMI Sensor-Werte
├── ipmi_sel.txt              IPMI System Event Log
├── sensors.txt               Thermal-Daten
├── backup_config.txt         Backup-Konfiguration
├── ha_status.txt             HA-Manager Status
├── replication_status.txt    Replication-Status
├── subscription.txt          Subscription-Status
├── firewall_status.txt       Firewall-Status
├── ssl_info.txt              SSL-Zertifikat-Info
├── sshd_config.txt           SSH-Konfiguration
├── top_processes.txt         Top-Prozesse
├── iostat.txt                I/O-Statistiken
├── vmstat.txt                VM-Statistiken
├── boot_config.txt           Boot-Konfiguration
├── systemd_timers.txt        Systemd-Timer
├── vm-configs/               VM-Konfigurationsdateien
├── ct-configs/               CT-Konfigurationsdateien
├── ha-config/                HA-Konfiguration
├── sdn-config/               SDN-Konfiguration
└── firewall/                 Firewall-Regeln
```

---

## Datenschutz / DSGVO-Hinweis

Dieses Skript kann unter anderem folgende Informationen sammeln:

* Hostnamen
* Benutzernamen
* VM- und CT-Namen
* IP-Adressen
* MAC-Adressen

### Anonymisierung

Mit `--anonymize` werden automatisch anonymisiert:

* **IP-Adressen:** ersetzt durch `X.X.X.X`
* **MAC-Adressen:** ersetzt durch `XX:XX:XX:XX:XX:XX`
* **Hostnamen:** ersetzt durch `HOSTNAME`

Vor einer Weitergabe an Dritte wird dennoch empfohlen, den Inhalt des Archivs zu prüfen.

---

## Haftungsausschluss

Dieses Skript dient als technische Hilfestellung.
Die **Thomas-Krenn.AG** übernimmt **keine Haftung** für:

* Datenverlust
* unerwartetes Systemverhalten
* Fehlinterpretationen der gesammelten Daten

Die Ausführung sollte ausschließlich durch **fachkundige Personen** erfolgen.

---

## Technische Details

* **Minimaler Speicherplatz:** 500 MB (wird vor Ausführung geprüft)
* **Timeout:** 60 Sekunden für langsame Befehle (z.B. Ceph-Abfragen)
* **Cleanup:** Bei Abbruch (Ctrl+C) wird das temporäre Verzeichnis automatisch aufgeräumt
* **Laufwerkserkennung:** sda-sdz, sdaa-sdzz, NVMe-Namespaces
* **Komprimierung:** zstd (bevorzugt) oder gzip als Fallback
* **Checksummen:** SHA256 (bevorzugt) oder MD5 als Fallback

---

## Empfehlung

* **Vor Ausführung:**
  Das Skript prüft automatisch den verfügbaren Speicherplatz. Bei weniger als 500 MB wird die Ausführung abgebrochen.

* **Selbsttest:**
  Mit `./getpvelogs.sh --check` können Sie vorab prüfen, welche Tools verfügbar sind.

* **Nach Ausführung:**
  Das erzeugte Archiv und die Checksummen-Datei befinden sich im Arbeitsverzeichnis (oder im mit `--output-dir` angegebenen Verzeichnis) und können direkt für Supportzwecke weitergegeben werden.
