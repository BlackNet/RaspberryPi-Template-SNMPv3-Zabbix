# Raspberry Pi by SNMP — Zabbix 8.0 Template

![Zabbix](https://img.shields.io/badge/Zabbix-8.0-red?logo=zabbix)
![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%204B%20%2F%205-c51a4a?logo=raspberry-pi)
![Pi OS](https://img.shields.io/badge/Pi%20OS-Bullseye%20%2F%20Bookworm-green)
![Server OS](https://img.shields.io/badge/Server%20OS-Debian%20Trixie-blue)
![Protocol](https://img.shields.io/badge/Protocol-SNMPv3%20authPriv-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

A comprehensive Zabbix 8.0 template for monitoring **Raspberry Pi hardware telemetry** via SNMPv3.  
Collects Pi-specific metrics that the standard Linux agent template cannot see — directly from the firmware via `vcgencmd` — with no polling agent required on the monitored host.

---

## Table of Contents

1. [What This Template Monitors](#what-this-template-monitors)
2. [Architecture Overview](#architecture-overview)
3. [Prerequisites](#prerequisites)
4. [Files in This Repository](#files-in-this-repository)
5. [Quick Start](#quick-start)
6. [Step 1 — Pi-Side Setup (extend_setup.sh)](#step-1--pi-side-setup-extend_setupsh)
7. [Step 2 — Zabbix-Side Setup](#step-2--zabbix-side-setup)
8. [Template Reference](#template-reference)
   - [Items](#items)
   - [Triggers](#triggers)
   - [Macros](#macros)
   - [Graphs](#graphs)
   - [Dashboard](#dashboard)
   - [Value Map](#value-map)
9. [Stacking with the Linux Agent Template](#stacking-with-the-linux-agent-template)
10. [Troubleshooting](#troubleshooting)
11. [Tested Platforms](#tested-platforms)
12. [Changelog](#changelog)

---

## What This Template Monitors

13 hardware telemetry items polled every 30–300 seconds via SNMPv3 NET-SNMP extend scripts:

| Metric | Description | Units | Interval |
|--------|-------------|-------|----------|
| SoC Temperature | System-on-chip core temperature | °C | 60 s |
| AVS Temperature | Adaptive Voltage Scaling sensor (Pi 5; returns 0 on Pi 4) | m°C | 60 s |
| ARM Clock Frequency | ARM CPU clock speed | Hz | 60 s |
| Core (VPU) Clock Frequency | VideoCore GPU / VPU clock speed | Hz | 60 s |
| GPU (V3D) Clock Frequency | 3D graphics engine clock speed | Hz | 60 s |
| Core Voltage | CPU core supply voltage (DVFS idle ~0.88 V) | V | 60 s |
| SDRAM-C Voltage | SDRAM controller voltage | V | 60 s |
| SDRAM-I Voltage | SDRAM I/O voltage | V | 60 s |
| SDRAM-P Voltage | SDRAM PHY voltage | V | 60 s |
| Throttle Register | Bitmask: under-voltage / freq-capped / throttled (now + since boot) | — | 30 s |
| ARM Memory Split | RAM allocated to the ARM CPU | B | 300 s |
| GPU Memory Split | RAM allocated to the GPU | B | 300 s |
| RAM Usage | System RAM used percentage (from `/proc/meminfo`) | % | 60 s |

> OS-level metrics (CPU load, disk I/O, network) are **intentionally omitted** — stack this template with the built-in **"Linux by Zabbix agent"** template and there is zero item overlap.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                  Raspberry Pi                            │
│                                                          │
│  vcgencmd ──► wrapper scripts ──► NET-SNMP extend        │
│              /usr/local/bin/        snmpd (UDP 161)       │
│              zabbix-pi/                                   │
│                                                          │
│  /proc/meminfo ──► pi-mem-used-pct script ──► snmpd      │
└───────────────────────────┬──────────────────────────────┘
                            │  SNMPv3  authPriv
                            │  SHA-256 / AES-128
                            ▼
┌──────────────────────────────────────────────────────────┐
│                   Zabbix Server                          │
│                                                          │
│  Template: Raspberry Pi by SNMP  ◄──  SNMP polling       │
│  Template: Linux by Zabbix agent ◄──  Agent 2 (no overlap│
└──────────────────────────────────────────────────────────┘
```

**Why SNMP instead of Agent UserParameters?**

- `vcgencmd` is a **firmware-only** command — it does not produce data accessible via standard Linux agent checks.
- NET-SNMP `extend` exposes each script output as its own OID, so Zabbix polls them natively with no custom agent configuration.
- SNMPv3 `authPriv` mode provides encrypted, authenticated transport — no community strings.
- The Zabbix agent (or Agent 2) can still run on the same Pi for OS-level metrics without any conflict.

---

## Prerequisites

### On each Raspberry Pi

| Requirement | Notes |
|-------------|-------|
| Raspberry Pi OS Bullseye or Bookworm | Tested on both; other Debian-based distros may work |
| `vcgencmd` in PATH | Pre-installed on Raspberry Pi OS; confirms firmware access |
| `net-snmp` (`snmpd`) | Installed automatically by `extend_setup.sh` if missing |
| `sudo` / root access | Required to run the setup script |

### On the Zabbix Server

| Requirement | Notes |
|-------------|-------|
| Zabbix 8.0 | Template format targets 8.0; will not import on older versions |
| Debian Trixie (tested) | Zabbix server OS — other Debian/Ubuntu releases should work equally well |
| SNMP polling enabled | Zabbix server/proxy must be able to reach Pi on UDP port 161 |
| Network path to Pi | Direct LAN, WireGuard, Tailscale, or other VPN all work |

---

## Files in This Repository

```
.
├── zbx_raspberry_pi_snmp_v18.yaml   # Zabbix template — import this into Zabbix
├── extend_setup.sh                  # Pi-side setup script — run on each Pi
└── README.md                        # This file
```

---

## Quick Start

```bash
# 1. Clone the repository on your workstation
git clone https://github.com/YOUR_USERNAME/zabbix-rpi-snmp.git

# 2. Copy the setup script to each Raspberry Pi
scp extend_setup.sh pi@<pi-ip>:~/

# 3. SSH into each Pi and run the setup
ssh pi@<pi-ip>
sudo bash extend_setup.sh

# 4. In Zabbix UI: import the template and create/update the host
#    (detailed steps below)
```

---

## Step 1 — Pi-Side Setup (`extend_setup.sh`)

The setup script fully automates the Pi-side configuration in one shot.

### What the script does

1. **Installs `snmpd`** via `apt` if not already present
2. **Creates 13 wrapper scripts** in `/usr/local/bin/zabbix-pi/`:
   - 11 `vcgencmd` scripts (temperature, clocks, voltages, throttle, memory split)
   - 1 AVS temperature script (`vcgencmd get_config int | grep avs_temp`)
   - 1 pure-`awk` RAM usage script reading `/proc/meminfo`
3. **Creates an SNMPv3 user** named `zabbix` with SHA-256 authentication and AES-128 privacy
4. **Writes `/etc/snmp/snmpd.conf`** with all 13 `extend` stanzas
5. **Adds `Debian-snmp` to the `video` group** (required for `vcgencmd` access)
6. **Restarts `snmpd`** and verifies each script returns data
7. **Runs a loopback `snmpget`** on the RAM-usage OID as a final sanity check

### Usage

```bash
# Interactive (recommended for first use — prompts for passphrases)
sudo bash extend_setup.sh

# Non-interactive (passphrases as arguments)
sudo bash extend_setup.sh "MyAuthPassphrase" "MyPrivPassphrase"
```

> **Passphrase requirements:** Both passphrases must be **at least 8 characters**. Choose strong, unique values — these credentials protect SNMP access to your Pi.

### Script output example

```
[INFO]  Checking net-snmp...
[ OK ]  snmpd already installed
[INFO]  Creating wrapper scripts in /usr/local/bin/zabbix-pi ...
[ OK ]  13 wrapper scripts created
[INFO]  Creating SNMPv3 user 'zabbix' ...
[ OK ]  SNMPv3 user created
[INFO]  Writing /etc/snmp/snmpd.conf ...
[ OK ]  snmpd.conf written
[INFO]  Restarting snmpd ...
[ OK ]  snmpd restarted
[INFO]  Verifying all scripts return data ...
[ OK ]  pi-cpu-temp       → 51.0
[ OK ]  pi-arm-clock      → 1800000000
[ OK ]  pi-core-clock     → 500000000
[ OK ]  pi-gpu-clock      → 500000000
[ OK ]  pi-volt-core      → 0.8800
[ OK ]  pi-volt-sdram-c   → 1.1000
[ OK ]  pi-volt-sdram-i   → 1.1000
[ OK ]  pi-volt-sdram-p   → 1.1250
[ OK ]  pi-throttle       → 0
[ OK ]  pi-mem-arm        → 3968
[ OK ]  pi-mem-gpu        → 128
[ OK ]  pi-avs-temp       → 0
[ OK ]  pi-mem-used-pct   → 34.72
[INFO]  Loopback snmpget sanity check ...
[ OK ]  snmpget returned: 34.72
[ OK ]  Setup complete!
```

### Verify manually (optional)

After the script completes you can verify the SNMP extend OIDs from another machine:

```bash
snmpwalk -v3 -l authPriv \
  -u zabbix \
  -a SHA-256 -A "YourAuthPassphrase" \
  -x AES -X "YourPrivPassphrase" \
  <pi-ip> 1.3.6.1.4.1.8072.1.3.2
```

You should see one string value per extend script — 13 total.

---

## Step 2 — Zabbix-Side Setup

### 2a. Import the Template

1. In the Zabbix UI go to **Data collection → Templates**
2. Click **Import** (top-right)
3. Select `zbx_raspberry_pi_snmp_v18.yaml`
4. Leave **"Delete missing"** unchecked (preserves history if upgrading)
5. Click **Import**

The template will appear in **Templates/RaspberryPi**.

> **Upgrading from an older version?** Import directly over the existing template — same UUID means Zabbix does an in-place update. All historical data, host links, and per-host macro overrides are preserved. Do **not** delete the old template first.

### 2b. Create or Update the Host

1. Go to **Data collection → Hosts** → select your Pi (or click **Create host**)
2. **Host name:** e.g. `Pi-Tofu`
3. **Templates tab:** Add `Raspberry Pi by SNMP`
   - Optionally also add `Linux by Zabbix agent` — the two templates have zero item overlap
4. **Interfaces tab:** Add an **SNMP** interface:

   | Field | Value |
   |-------|-------|
   | Type | SNMP |
   | IP address | Pi's IP (or Tailscale IP) |
   | Port | 161 |
   | SNMP version | SNMPv3 |
   | Security name | `zabbix` |
   | Security level | `authPriv` |
   | Auth protocol | `SHA-256` |
   | Auth passphrase | *(your auth passphrase from setup)* |
   | Priv protocol | `AES128` |
   | Priv passphrase | *(your priv passphrase from setup)* |
   | Context name | *(leave blank)* |

5. Click **Update** / **Add**

### 2c. Verify Data is Flowing

1. Go to **Monitoring → Latest data**
2. Filter by your Pi host
3. Within 60–90 seconds all 13 items should show current values

If items show "No data" see the [Troubleshooting](#troubleshooting) section.

### 2d. Override Macros Per Host (Optional)

All thresholds are driven by template macros. To customize for a specific Pi:

1. Open the host → **Macros** tab
2. Switch to **Inherited and host macros**
3. Click the pencil icon on any macro to override it for this host only

---

## Template Reference

### Items

| Item Name | Key | OID (suffix) | Units | Interval |
|-----------|-----|--------------|-------|----------|
| SoC Temperature | `pi.cpu.temp` | `...2.3.1.2.11.112.105.45.99.112.117.45.116.101.109.112` | °C | 60 s |
| AVS Temperature | `pi.avs.temp` | `...2.3.1.2.11.112.105.45.97.118.115.45.116.101.109.112` | m°C | 60 s |
| ARM Clock Frequency | `pi.arm.clock` | `...2.3.1.2.12.112.105.45.97.114.109.45.99.108.111.99.107` | Hz | 60 s |
| Core (VPU) Clock Frequency | `pi.core.clock` | `...2.3.1.2.13.112.105.45.99.111.114.101.45.99.108.111.99.107` | Hz | 60 s |
| GPU (V3D) Clock Frequency | `pi.gpu.clock` | `...2.3.1.2.12.112.105.45.103.112.117.45.99.108.111.99.107` | Hz | 60 s |
| Core Voltage | `pi.volt.core` | `...2.3.1.2.12.112.105.45.118.111.108.116.45.99.111.114.101` | V | 60 s |
| SDRAM-C Voltage | `pi.volt.sdram.c` | `...2.3.1.2.15.112.105.45.118.111.108.116.45.115.100.114.97.109.45.99` | V | 60 s |
| SDRAM-I Voltage | `pi.volt.sdram.i` | `...2.3.1.2.15.112.105.45.118.111.108.116.45.115.100.114.97.109.45.105` | V | 60 s |
| SDRAM-P Voltage | `pi.volt.sdram.p` | `...2.3.1.2.15.112.105.45.118.111.108.116.45.115.100.114.97.109.45.112` | V | 60 s |
| Throttle Register | `pi.throttle` | `...2.3.1.2.11.112.105.45.116.104.114.111.116.116.108.101` | bitmask | 30 s |
| ARM Memory | `pi.mem.arm` | `...2.3.1.2.10.112.105.45.109.101.109.45.97.114.109` | B | 300 s |
| GPU Memory | `pi.mem.gpu` | `...2.3.1.2.10.112.105.45.109.101.109.45.103.112.117` | B | 300 s |
| RAM Usage | `pi.mem.used.pct` | `...2.3.1.2.15.112.105.45.109.101.109.45.117.115.101.100.45.112.99.116` | % | 60 s |

All OIDs share the prefix `1.3.6.1.4.1.8072.1.3.2.3.1.2.` (NET-SNMP extend string output table).

### Triggers

| Trigger | Expression | Severity | Notes |
|---------|-----------|----------|-------|
| SoC temperature elevated | `> {$PI.TEMP.MAX.ELEV}` (60 °C) | AVERAGE | Informational early warning |
| SoC temperature warning | `> {$PI.TEMP.MAX.WARN}` (70 °C) | WARNING | Sustained for 3 min |
| SoC temperature critical | `> {$PI.TEMP.MAX.CRIT}` (80 °C) | HIGH | Throttling imminent |
| Core voltage low | `< {$PI.VOLT.MIN.WARN}` (0.75 V) | WARNING | Power supply issue |
| Under-voltage NOW | bit 0 of throttle register | HIGH | Active under-voltage |
| Frequency capped NOW | bit 1 of throttle register | WARNING | Active freq-cap |
| Throttled NOW | bit 2 of throttle register | HIGH | CPU actively throttled |
| Under-voltage since boot | bit 16 of throttle register | WARNING | Historical event recorded |
| RAM usage high | `> {$PI.MEM.USED.WARN}` (85%) | WARNING | System memory pressure |

### Macros

| Macro | Default | Description |
|-------|---------|-------------|
| `{$PI.TEMP.MAX.ELEV}` | `60` | SoC temperature elevated threshold (°C) |
| `{$PI.TEMP.MAX.WARN}` | `70` | SoC temperature warning threshold (°C) |
| `{$PI.TEMP.MAX.CRIT}` | `80` | SoC temperature critical threshold (°C) |
| `{$PI.VOLT.MIN.WARN}` | `0.75` | Minimum core voltage warning threshold (V) |
| `{$PI.MEM.USED.WARN}` | `85` | RAM usage warning threshold (%) |
| `{$PI.THROTTLE.WARN}` | `0` | Throttle register level to warn on (0 = any event) |

> **DVFS note:** Core voltage at idle is approximately 0.88 V due to Dynamic Voltage and Frequency Scaling. The default threshold of 0.75 V gives comfortable headroom while still catching genuine power supply problems.

### Graphs

Seven pre-built graphs are included:

1. **SoC Temperature** — line graph with warning/critical threshold references
2. **AVS Temperature** — Pi 5 adaptive voltage scaling sensor (shows 0 on Pi 4)
3. **CPU and GPU Clock Frequencies** — ARM, VPU, and V3D clocks on one canvas
4. **Supply Voltages** — Core, SDRAM-C, SDRAM-I, SDRAM-P
5. **Throttle Register** — bitmask value over time
6. **ARM and GPU Memory Split** — stacked view of firmware memory allocation
7. **RAM Usage** — system RAM usage percentage

### Dashboard

The template ships with a pre-configured dashboard (`Raspberry Pi Hardware`) using a 58-column grid:

| Row | Widget | Position | Size |
|-----|--------|----------|------|
| 1 | RAM Usage Gauge | x=0 | w=14, h=4 |
| 1 | RAM Usage Graph | x=14 | w=44, h=4 |
| 2 | SoC Temperature Graph | x=0 | w=29, h=4 |
| 2 | Throttle Register Graph | x=29 | w=29, h=4 |
| 3 | CPU & GPU Clock Frequencies | x=0 | w=29, h=4 |
| 3 | Supply Voltages | x=29 | w=29, h=4 |
| 4 | ARM & GPU Memory Split | x=0 | w=29, h=4 |
| 4 | AVS Temperature | x=29 | w=29, h=4 |

You can resize or rearrange widgets at any time — click the pencil (Edit) icon on the dashboard to enter edit mode, then drag/resize as needed.

### Value Map

The **"Pi Throttle Bitmask"** value map translates raw throttle register values into readable labels:

| Raw Value | Label |
|-----------|-------|
| `0` | Clean |
| `1` | Under-voltage NOW |
| `2` | Freq-capped NOW |
| `4` | Throttled NOW |
| `65536` | Under-voltage since boot |
| `131072` | Freq-capped since boot |
| `262144` | Throttled since boot |

---

## Stacking with the Linux Agent Template

This template is designed to **stack cleanly** with Zabbix's built-in **"Linux by Zabbix agent"** (or Agent 2) template. Assign both to the same Pi host and configure two interfaces:

| Interface | Type | Purpose |
|-----------|------|---------|
| SNMP | SNMPv3, port 161 | Pi hardware telemetry (this template) |
| Agent | Zabbix agent / Agent 2 | OS metrics: CPU, disk, network, processes |

There is **zero item key overlap** between the two templates — no conflicts, no inventory collisions.

> **Important:** Do NOT use "Linux by SNMP" and "Linux by Zabbix agent" together on the same host. They conflict on the inventory field **Name** (`system.name` vs `system.hostname`). For any Linux host with an agent installed, use the agent template only for OS metrics and reserve SNMP for Pi-specific hardware data via this template.

---

## Troubleshooting

### All items show "No data" or "Cannot connect"

```bash
# Test SNMP connectivity from the Zabbix server
snmpget -v3 -l authPriv \
  -u zabbix \
  -a SHA-256 -A "YourAuthPassphrase" \
  -x AES -X "YourPrivPassphrase" \
  <pi-ip> 1.3.6.1.4.1.8072.1.3.2.3.1.2.11.112.105.45.99.112.117.45.116.101.109.112
```

Expected output: `STRING: "51.0"` (your Pi's current temperature).

- **Timeout / no response:** Check firewall — UDP port 161 must be open
- **Authentication failure:** Passphrases in Zabbix host config must exactly match what was used during setup
- **Wrong OID:** Ensure you ran `extend_setup.sh` on this Pi and snmpd is running (`systemctl status snmpd`)

### Only SoC temperature works, other items show "No data"

This is almost always an OID length-prefix mismatch. The NET-SNMP extend OID structure requires the script name length as a prefix before the ASCII bytes. Verify by running a full walk:

```bash
snmpwalk -v3 -l authPriv -u zabbix \
  -a SHA-256 -A "YourAuthPassphrase" \
  -x AES -X "YourPrivPassphrase" \
  <pi-ip> 1.3.6.1.4.1.8072.1.3.2.3.1.2
```

You should see 13 lines. If you see only 1, the extend stanzas in `/etc/snmp/snmpd.conf` may not have loaded. Check `journalctl -u snmpd` for errors.

### `vcgencmd: command not found` in script output

```bash
# Verify vcgencmd is accessible to the Debian-snmp user
sudo -u Debian-snmp vcgencmd measure_temp
```

If this fails, ensure the `video` group membership was applied:

```bash
groups Debian-snmp   # should include 'video'
# If missing:
sudo usermod -aG video Debian-snmp
sudo systemctl restart snmpd
```

### AVS Temperature always shows 0

This is expected on Raspberry Pi 4 — the AVS sensor only exists on Pi 5. The item will collect data (value = 0) without triggering any errors or alerts.

### Core voltage trigger fires at idle

Core voltage drops to ~0.88 V under DVFS at low CPU load. If the trigger is firing unexpectedly, lower the `{$PI.VOLT.MIN.WARN}` macro on that host to `0.70` or below. The default 0.75 V threshold is intentionally conservative.

### snmpd fails to start after setup

```bash
# Check for config syntax errors
snmpd -C -c /etc/snmp/snmpd.conf
# Check logs
journalctl -u snmpd -n 50
```

### Template import fails or items are duplicated

- Ensure you are importing `zbx_raspberry_pi_snmp_v18.yaml`, not an older version
- If you accidentally deleted the old template before importing, re-import will recreate it — but historical data will be gone
- Leave **"Delete missing"** unchecked during import to preserve existing data

---

## Tested Platforms

### Raspberry Pi (monitored hosts)

| Hardware | OS | Zabbix Template |
|----------|----|----------------|
| Raspberry Pi 4 Model B (4 GB) | Raspberry Pi OS Bullseye (32-bit) | 8.0 |
| Raspberry Pi 4 Model B (8 GB) | Raspberry Pi OS Bookworm (64-bit) | 8.0 |
| Raspberry Pi 5 (8 GB) | Raspberry Pi OS Bookworm (64-bit) | 8.0 |

### Zabbix Server

| OS | Zabbix Version |
|----|----------------|
| Debian Trixie (testing) | 8.0 |

Network transports tested: direct LAN, Tailscale VPN.

> **Note on Debian Trixie:** Trixie is Debian's current "testing" branch. The template was developed and validated on a Zabbix 8.0 server running Debian Trixie. No compatibility issues have been observed; the template should work equally well on Debian Bookworm (stable) or any Ubuntu LTS release.

---

## Changelog

| Version | Changes |
|---------|---------|
| v18 | Dashboard layout updated: RAM gauge + graph moved to row 1; 58-col grid; widget sizes aligned to user preference |
| v17 | RAM usage gauge widget added to dashboard |
| v16 | Added RAM usage item (`pi.mem.used.pct`) from `/proc/meminfo`; added `{$PI.MEM.USED.WARN}` macro and trigger |
| v15 | Added `{$PI.TEMP.MAX.ELEV}` macro; three-tier temperature triggers (elevated / warning / critical) |
| v14 | Added AVS temperature item and graph; added `{$PI.THROTTLE.WARN}` macro |
| v13 | Fixed OID length-prefix for all items — corrected "no data" for 10 of 11 items |
| v1–v12 | Initial development: template structure, SNMPv3 configuration, items, triggers, graphs |

---

## License

MIT License — free to use, modify, and distribute. Attribution appreciated but not required.

---

## Contributing

Pull requests welcome! If you test on a new Pi model or OS version, please open an issue or PR to update the tested platforms table.
