# Proxmox VE Support Log Collector with TUI

**Version:** 4.0.3-tui — 03/2026

**Author:** Samuel Müller

**Contact:** [smueller@thomas-krenn.com](mailto:smueller@thomas-krenn.com)

---

## Purpose

This script collects diagnostically relevant system information from **Proxmox VE hosts** to make error situations more reproducible, faster, and easier to analyze for support purposes.

Execution is **read-only**, except for the **optional installation of tools** such as `nvme-cli`, `ipmitool`, `lm-sensors`, and `sysstat`.

---

## What's New in Version 4.0

* **Interactive TUI:** New guided mode with `--interactive` (whiptail-based)
* **Two operating modes:** `--normal` (default), `--full`
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
git clone -b tui https://github.com/thomas-krenn/PVE-Logscript.git
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
curl -sL https://raw.githubusercontent.com/thomas-krenn/PVE-Logscript/tui/getpvelogs.sh | sudo bash -s -- -i
```

---

## Interactive TUI

With the `--interactive` (or `-i`) parameter, the script starts a user-friendly text-based interface (TUI) that guides you through all options.

### Quick Start Menu

```
┌──────────────────────────────────────────────────────────────────┐
│ PVE Support Log Collector v4.0.3-tui                             │
├──────────────────────────────────────────────────────────────────┤
│ ○ Quick Start - Normal mode (recommended)                        │
│ ○ Quick Start - Full mode                                        │
│ ○ Custom - Go through all options                                │
│ ○ System test - Show available tools                              │
└──────────────────────────────────────────────────────────────────┘
```

### Custom Mode

In custom mode, you are guided through the following dialogs:

1. **Operating mode** - Choose between normal/full
2. **Tool installation** - Behavior when tools are missing
3. **Additional options** - Anonymization, JSON meta, verbose, etc.
4. **Exclude sections** - Optionally skip Ceph, SMART, etc.
5. **Output directory** - Optionally choose a custom path
6. **Summary** - Confirmation before starting

### Start TUI

```bash
sudo ./getpvelogs.sh --interactive
# or short:
sudo ./getpvelogs.sh -i
```

> **Note:** The TUI requires `whiptail`, which is preinstalled on most Debian/Ubuntu systems.

---

## Examples

```bash
# Interactive mode with guided TUI (recommended for beginners)
sudo ./getpvelogs.sh --interactive

# Standard execution (normal mode) with interactive prompt
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

### Interactive Mode

| Parameter | Description |
|-----------|--------------|
| `-i`, `--interactive` | Starts the interactive TUI (whiptail) with guided configuration |

### Operating Modes

| Parameter | Description |
|-----------|--------------|
| `--normal` | Standard scope: Journal, dmesg, PVE services, network, storage, SMART, Ceph, cluster, VM/CT lists (default) |
| `--full` | Normal + hardware (IPMI, thermal), VM/CT configs, firewall, performance, backup/HA/replication |

### Tool Installation

| Parameter | Description |
|-----------|--------------|
| `--install-tools` | Automatically install missing tools |
| `--no-install` | Do not install tools; missing sections are skipped |

### Output Options

| Parameter | Description |
|-----------|--------------|
| `--output-dir PATH` | Set output directory |
| `--exclude SECTIONS` | Exclude sections (comma-separated: `ceph,smart,network,storage,proxmox`) |
| `--anonymize` | Anonymize IPs, MACs, and hostnames |
| `--json-meta` | Export metadata additionally as JSON |
| `--verbose` | Detailed output during execution |

### Other

| Parameter | Description |
|-----------|--------------|
| `--keep-work` | Do not delete temporary working directory |
| `--check` | Self-test: shows available tools without data collection |
| `-v`, `--version` | Show version |
| `-h`, `--help` | Show help |

---

## Features

### Base (all modes)

* Progress output to STDOUT
* Kernel dmesg and journal logs
* Network configuration and interface details
* PVE service status

### Normal Mode (in addition to base)

* Storage: LVM, ZFS, MDADM
* SMART data (SATA/SAS and NVMe)
* Ceph information (if present)
* Cluster status (Corosync, quorum)
* VM/CT lists

### Full Mode (in addition to normal)

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
├── kernel_dmesg.txt         Kernel messages
├── journal_*.txt             Journald logs
├── smart.txt                SMART data
├── nvme_list.txt            NVMe device list
├── zfs.txt                  ZFS status
├── storage.txt              Storage overview
│
├── system/                  System information
│   ├── hw.txt               Hardware details
│   ├── apt_history.txt      Package history
│   ├── lvm.txt              LVM configuration
│   ├── mdadm.txt            RAID status
│   ├── syslog.txt           Syslog (if no journald)
│   ├── boot_config.txt      Boot/GRUB configuration (--full)
│   └── systemd_timers.txt   Systemd timers (--full)
│
├── network/                 Network
│   ├── network.txt          Network status
│   ├── network_config.txt   Network configuration
│   └── net-if/              Interface statistics
│
├── proxmox/                 Proxmox VE
│   ├── pveversion.txt       PVE version
│   ├── pve_services.txt     PVE services
│   ├── pve_vms.txt          VM/CT list
│   ├── pvereport.txt        PVE report
│   ├── cluster.txt          Cluster status
│   ├── subscription.txt     Subscription status (--full)
│   ├── backup_config.txt    Backup configuration (--full)
│   ├── ha_status.txt        HA manager status (--full)
│   ├── replication_status.txt Replication status (--full)
│   ├── pbs_status.txt       PBS client status (--full)
│   ├── vm-configs/          VM configurations (--full)
│   ├── ct-configs/          CT configurations (--full)
│   ├── ha-config/           HA configuration (--full)
│   └── sdn-config/          SDN configuration (--full)
│
├── security/                Security (--full)
│   ├── firewall_status.txt  Firewall status
│   ├── firewall/            Firewall rules
│   ├── ssl_info.txt         SSL certificate info
│   └── sshd_config.txt      SSH configuration
│
├── hardware/                Hardware details (--full)
│   ├── ipmi_sensors.txt     IPMI sensor values
│   ├── ipmi_sel.txt         IPMI system event log
│   ├── ipmi_fru.txt         IPMI FRU data
│   └── sensors.txt          Thermal data (lm-sensors)
│
├── performance/             Performance data (--full)
│   ├── top_processes.txt    Top processes (CPU/memory)
│   ├── iostat.txt           I/O statistics
│   ├── vmstat.txt           VM statistics
│   ├── sar_cpu.txt          SAR CPU data
│   └── sar_disk.txt         SAR disk data
│
├── ceph/                    Ceph data (if present)
│
└── logs/                    System and PVE logs
```

---

## Data Protection / GDPR Notice

This script may collect the following information, among others:

* Hostnames
* Usernames
* VM and CT names
* IP addresses
* MAC addresses

### Anonymization

With `--anonymize`, the following are automatically anonymized:

* **IP addresses:** replaced with `X.X.X.X`
* **MAC addresses:** replaced with `XX:XX:XX:XX:XX:XX`
* **Hostnames:** replaced with `HOSTNAME`

Before sharing with third parties, it is still recommended to review the archive contents.

---

## Disclaimer

This script serves as technical assistance.
**Thomas-Krenn.AG** assumes **no liability** for:

* Data loss
* Unexpected system behavior
* Misinterpretation of collected data

Execution should only be performed by **qualified personnel**.

---

## Technical Details

* **Minimum disk space:** 500 MB (checked before execution)
* **Timeout:** 60 seconds for slow commands (e.g., Ceph queries)
* **Cleanup:** On abort (Ctrl+C), the temporary directory is automatically cleaned up
* **Drive detection:** sda-sdz, sdaa-sdzz, NVMe namespaces
* **Compression:** zstd (preferred) or gzip as fallback
* **Checksums:** SHA256 (preferred) or MD5 as fallback

---

## Recommendations

* **Before execution:**
  The script automatically checks available disk space. Execution is aborted if less than 500 MB is available.

* **Self-test:**
  With `./getpvelogs.sh --check` you can verify in advance which tools are available.

* **After execution:**
  The generated archive and checksum file are located in the working directory (or the directory specified with `--output-dir`) and can be shared directly for support purposes.
