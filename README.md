# Proxmox VE Support Log Collector

**Version:** 4.1.0 — 04/2026

**Author:** Samuel Müller

**Contact:** [smueller@thomas-krenn.com](mailto:smueller@thomas-krenn.com)

---

## Purpose

This script collects diagnostically relevant system information from **Proxmox VE hosts** to make error situations more reproducible, faster, and easier to analyze for support purposes.

Execution is **read-only**, except for the **optional installation of tools** such as `nvme-cli`, `ipmitool`, `lm-sensors`, and `sysstat`.

## TUI Version

A version of the tool with TUI (text-based user interface) is available here:  
https://github.com/thomas-krenn/PVE-Logscript/tree/tui

The TUI version allows convenient selection of information areas to collect via a menu system and provides status displays for collection progress. You need the additional package `dialog` (checked automatically during execution). Operation is fully keyboard-based. All options available in the standard script (operating mode, anonymization, target directory, etc.) are also available there.

---

## What's New in Version 4.1

* **Additional journald JSON export:** In addition to text output, `journalctl` is now also written in JSON format (NDJSON) to `meta-log/`.

* **Two operating modes:** Default (no flag), `--full`
* **Automatic tool detection:** All required tools are checked before collection and installed if needed
* **Anonymization:** With `--anonymize`, IPs, MACs, and hostnames are automatically replaced
* **Extended hardware data:** IPMI/BMC sensors, thermal data (in `--full` mode)
* **Extended Proxmox data:** VM/CT configurations, backup jobs, HA, replication, SDN (in `--full` mode)
* **Firewall configuration:** PVE firewall rules and SSL certificates (in `--full` mode)
* **Performance data:** iostat, vmstat, sar snapshots (in `--full` mode)
* **Checksums:** SHA256/MD5 of the archive is created automatically
* **Self-test:** With `--check`, all available tools are displayed (without data collection)

---

## Installation & Usage

### 1. Clone the repository

```bash
git clone https://github.com/thomas-krenn/PVE-Logscript.git
```

### 2. Change to the directory

```bash
cd PVE-Logscript
```

### 3. Make the script executable

```bash
chmod +x getpvelogs.sh
```

### 4. Run the script (as root)

```bash
sudo ./getpvelogs.sh
```

### Alternative: One-liner

If the script is only needed once:

```bash
curl -sL https://raw.githubusercontent.com/thomas-krenn/PVE-Logscript/main/getpvelogs.sh | sudo bash
```

---

## Examples

```bash
# Standard execution (default) with interactive prompt
sudo ./getpvelogs.sh

# Full data collection incl. hardware and performance
sudo ./getpvelogs.sh --full --install-tools

# Anonymized output for GDPR-compliant sharing
sudo ./getpvelogs.sh --anonymize

# Output to specific directory
sudo ./getpvelogs.sh --output-dir /tmp/logs

# Exclude specific sections
sudo ./getpvelogs.sh --exclude ceph,smart

# Self-test - shows available tools without data collection
./getpvelogs.sh --check

# Show version
./getpvelogs.sh --version
```

---

## Parameters

### Operating Modes

| Parameter | Description |
|-----------|--------------|
| Default (no flag) | Standard scope: Journal, dmesg, PVE services, network, storage, SMART, Ceph, cluster, VM/CT lists |
| `--full` | Full: Default + hardware (IPMI, thermal), VM/CT configs, firewall, performance, backup/HA/replication |

### Tool Installation

| Parameter | Description |
|-----------|--------------|
| `--install-tools` | Automatically install missing tools |
| `--no-install` | Do not install tools; missing sections will be skipped |

### Output Options

| Parameter | Description |
|-----------|--------------|
| `--output-dir PATH` | Set output directory |
| `--exclude SECTIONS` | Exclude sections (comma-separated). Only these sections are accepted: `ceph,smart,network,storage,proxmox,proxmox-extended,hardware,firewall,performance,system-extended` |
| `--anonymize` | Anonymize IPs, MACs, and hostnames |
| `--json-meta` | Export metadata additionally as JSON |
| `--verbose` | Detailed output during execution |

### Miscellaneous

| Parameter | Description |
|-----------|--------------|
| `--keep-work` | Do not delete temporary working directory |
| `--check` | Self-test: shows available tools without data collection |
| `-v`, `--version` | Show version |
| `-h`, `--help` | Show help |

---

## Feature Scope

### Default Mode (in addition to base)

* Progress output to STDOUT
* Kernel dmesg and journal logs
* Network configuration and interface details
* PVE service status
* Storage: LVM, ZFS, MDADM
* SMART data (SATA/SAS and NVMe)
* Ceph information (if present)
* Cluster status (Corosync, quorum)
* VM/CT lists

### Full Mode (in addition to default)

* Hardware: IPMI/BMC sensors, thermal data (lm-sensors)
* VM/CT configuration files
* Backup configuration (vzdump, jobs)
* HA manager status and configuration
* Replication status
* SDN configuration
* Subscription status
* Firewall rules (cluster, host, VM)
* SSL certificate information
* SSH configuration
* Performance snapshots: iostat, vmstat, sar
* Boot configuration (GRUB, kernel cmdline)
* Systemd timers

---

## Output Structure

```text
<hostname>_<serial>_<timestamp>.logs-XXXX/
│
├── _meta.txt                 Metadata and system overview
├── _meta.json                JSON metadata (with --json-meta)
├── _tools_used.txt           List of used tools
├── _errors.txt               Warnings and errors
│
├── kernel_dmesg.txt          Kernel messages
├── journal_*.txt             Journald logs
├── smart.txt                 SMART data
├── nvme_list.txt             NVMe device list
├── zfs.txt                   ZFS status
├── storage.txt               Storage overview
│
├── system/                   System information
│   ├── hw.txt                Hardware details
│   ├── apt_history.txt       Package history
│   ├── lvm.txt               LVM configuration
│   ├── mdadm.txt             RAID status
│   ├── syslog.txt            Syslog (if no journald)
│   ├── boot_config.txt       Boot/GRUB configuration (--full)
│   └── systemd_timers.txt    Systemd timers (--full)
│
├── network/                  Network
│   ├── network.txt           Network status
│   ├── network_config.txt    Network configuration
│   └── net-if/               Interface statistics
│
├── proxmox/                  Proxmox VE
│   ├── pveversion.txt        PVE version
│   ├── pve_services.txt      PVE services
│   ├── pve_vms.txt           VM/CT list
│   ├── pvereport.txt         PVE report
│   ├── cluster.txt           Cluster status
│   ├── subscription.txt      Subscription status (--full)
│   ├── backup_config.txt     Backup configuration (--full)
│   ├── ha_status.txt         HA manager status (--full)
│   ├── replication_status.txt Replication status (--full)
│   ├── pbs_status.txt        PBS client status (--full)
│   ├── vm-configs/           VM configurations (--full)
│   ├── ct-configs/           CT configurations (--full)
│   ├── ha-config/            HA configuration (--full)
│   └── sdn-config/           SDN configuration (--full)
│
├── security/                 Security (--full)
│   ├── firewall_status.txt   Firewall status
│   ├── firewall/             Firewall rules
│   ├── ssl_info.txt          SSL certificate info
│   └── sshd_config.txt       SSH configuration
│
├── hardware/                 Hardware details (--full)
│   ├── ipmi_sensors.txt      IPMI sensor values
│   ├── ipmi_sel.txt          IPMI System Event Log
│   ├── ipmi_fru.txt          IPMI FRU data
│   └── sensors.txt           Thermal data (lm-sensors)
│
├── performance/              Performance data (--full)
│   ├── top_processes.txt     Top processes (CPU/Memory)
│   ├── iostat.txt            I/O statistics
│   ├── vmstat.txt            VM statistics
│   ├── sar_cpu.txt           SAR CPU data
│   └── sar_disk.txt          SAR disk data
│
├── ceph/                     Ceph data (if present)
│   ├── ceph_status.txt       Ceph cluster status
│   ├── ceph_health.txt       Ceph health details
│   ├── ceph_osd.txt          OSD tree
│   ├── ceph_mons.txt         Monitor dump
│   ├── ceph_pg.txt           Placement group data
│   ├── ceph_osd_df.txt       OSD utilization
│   ├── ceph_volume_lvm_list.txt Raw ceph-volume output
│   └── osd_device_mapping.txt OSD -> device -> serial mapping
│
├── meta-log/                 Additional machine-readable logs
│   ├── journal_current.json  Journald current boot (JSON/NDJSON)
│   └── journal_7d.json       Journald last 7 days (JSON/NDJSON)
│
└── logs/                     System and PVE logs
```

---

## Privacy / GDPR Notice

This script may collect the following information among others:

* Hostnames
* Usernames
* VM and CT names
* IP addresses
* MAC addresses

### Anonymization

With `--anonymize`, the following are automatically anonymized:

* **IP addresses:** replaced by `X.X.X.X`
* **MAC addresses:** replaced by `XX:XX:XX:XX:XX:XX`
* **Hostnames:** replaced by `HOSTNAME`

Before sharing with third parties, it is still recommended to review the archive contents.

---

## Disclaimer

This script serves as a technical aid.
**Thomas-Krenn.AG** assumes **no liability** for:

* Data loss
* Unexpected system behavior
* Misinterpretation of collected data

Execution should only be performed by **qualified personnel**.

---

## Technical Details

* **Minimum disk space:** 500 MB (checked before execution)
* **Timeout:** 60 seconds for slow commands (e.g. Ceph queries)
* **Cleanup:** On abort (Ctrl+C), the temporary directory is automatically cleaned up
* **Drive detection:** sda-sdz, sdaa-sdzz, NVMe namespaces
* **Compression:** zstd (preferred) or gzip as fallback
* **Checksums:** SHA256 (preferred) or MD5 as fallback

---

## Recommendations

* **Before execution:**
  The script automatically checks available disk space. With less than 500 MB, execution is aborted.

* **Self-test:**
  Use `./getpvelogs.sh --check` to verify which tools are available beforehand.

* **After execution:**
  The generated archive and checksum file are located in the working directory (or the directory specified with `--output-dir`) and can be shared directly for support purposes.
