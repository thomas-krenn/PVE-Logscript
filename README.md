# Proxmox VE Support Log Collector

**Version:** 3.1.0 — 10/2025

**Unternehmen:** Thomas-Krenn.AG

**Autor:** Samuel Müller

**Kontakt:** [smueller@thomas-krenn.com](mailto:smueller@thomas-krenn.com)

---

## Zweck

Dieses Skript sammelt diagnostisch relevante Systeminformationen von **Proxmox VE Hosts**, um Fehlersituationen reproduzierbarer, schneller und supportseitig besser analysieren zu können.

Die Ausführung erfolgt **read-only**, mit Ausnahme der **optionalen Installation von `nvme-cli`**, sofern NVMe-Daten abgefragt werden sollen.

---

## Funktionsumfang

* Fortschrittsausgabe auf **STDOUT** (Sammle / Kopiere / Packe)
* Erfassung von:

  * Kernel-, Journal- und Systeminformationen
  * Storage- und Netzwerkdaten
* Aggregation von:

  * Proxmox-Diensten
  * VM- und CT-Informationen
* SMART-Daten (SATA/SAS)
* Optionale **NVMe-SMART-Daten**
* **Ceph-Informationen** (falls vorhanden) in separatem Unterordner
* Protokollierung verwendeter optionaler Tools (`_tools_used.txt`)
* Protokollierung von Warnungen und Hinweisen (`_errors.txt`)

---

## Betriebsmodi / Verhalten

* **Single-Node (kein Cluster):**
  Cluster- und Ceph-Abschnitte werden automatisch ausgelassen.

* **Cluster-Nodes:**
  Corosync-, Quorum- und Storage-Informationen werden erfasst.

* **Ceph-Nodes:**
  Gezielt Sammlung von PG-, OSD- und Health-Informationen.

* **NVMe-Support:**
  `nvme-cli` wird standardmäßig angefragt oder optional automatisch installiert.

---

## Parameter

| Parameter         | Beschreibung                                                   |
| ----------------- | -------------------------------------------------------------- |
| `--install-tools` | Installiert fehlende Tools ohne Rückfrage                      |
| `--no-install`    | Installiert keine Tools; fehlende Bereiche werden übersprungen |
| `--keep-work`     | Temporäres Arbeitsverzeichnis wird nicht gelöscht              |
| `-h`, `--help`    | Zeigt die Hilfe an                                             |

---

## Ausgabestruktur

```text
<hostname>_<serial>_<timestamp>.logs-XXXX/
├─ logs/               System- und Proxmox-Logs
├─ ceph/               Ceph-Daten (falls vorhanden)
├─ net-if/             Netzwerk-Interface-Statistiken
└─ .supportlogs.tar.*  Archivierter Gesamtexport
```

---

## Datenschutz / DSGVO-Hinweis

Dieses Skript kann unter anderem folgende Informationen enthalten:

* Hostnamen
* Benutzernamen
* VM- und CT-Namen
* IP-Adressen

Vor einer Weitergabe an Dritte wird dringend empfohlen, den Inhalt des erzeugten Archivs zu prüfen und ggf. zu bereinigen.

---

## Haftungsausschluss

Dieses Skript dient als technische Hilfestellung.
Die **Thomas-Krenn.AG** übernimmt **keine Haftung** für:

* Datenverlust
* unerwartetes Systemverhalten
* Fehlinterpretationen der gesammelten Daten

Die Ausführung sollte ausschließlich durch **fachkundige Personen** erfolgen.

---

## Empfehlung

* **Vor Ausführung:**
  Sicherstellen, dass ausreichend freier Speicherplatz vorhanden ist.

* **Nach Ausführung:**
  Das erzeugte Archiv befindet sich im lokalen Arbeitsverzeichnis und kann direkt für Supportzwecke weitergegeben werden.
