#!/bin/bash
# ============================================================
# pi-snmp-setup.sh  (v16)
# Raspberry Pi SNMPv3 + vcgencmd extend setup for Zabbix
#
# Tested on: Raspberry Pi OS Bullseye / Bookworm (Pi 4B / Pi 5)
# Zabbix template: Raspberry Pi by SNMP v16
#
# What this script does:
#   1. Installs net-snmp if missing
#   2. Creates 12 wrapper scripts in /usr/local/bin/zabbix-pi/
#        11 vcgencmd scripts  (hardware telemetry)
#         1 /proc/meminfo script (pi-mem-used-pct — OS RAM %)
#   3. Adds SNMPv3 user (username: zabbix)
#   4. Writes snmpd.conf (agentaddress, view, access, extend stanzas)
#   5. Adds Debian-snmp to the 'video' group (needed for vcgencmd)
#   6. Restarts snmpd and verifies all 12 scripts return data
#
# Usage:
#   sudo bash pi-snmp-setup.sh [auth-passphrase] [priv-passphrase]
#
#   If passphrases are omitted you will be prompted interactively.
#   Both passphrases must be >= 8 characters.
#
# ============================================================

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"

# ── Passphrases ──────────────────────────────────────────────
AUTH_PASS="${1:-}"
PRIV_PASS="${2:-}"

if [[ -z "$AUTH_PASS" ]]; then
    read -rsp "SNMPv3 auth passphrase (>=8 chars): " AUTH_PASS; echo
fi
if [[ -z "$PRIV_PASS" ]]; then
    read -rsp "SNMPv3 priv passphrase (>=8 chars): " PRIV_PASS; echo
fi

[[ ${#AUTH_PASS} -ge 8 ]] || die "Auth passphrase must be at least 8 characters"
[[ ${#PRIV_PASS} -ge 8 ]] || die "Priv passphrase must be at least 8 characters"

SNMP_USER="zabbix"
SCRIPT_DIR="/usr/local/bin/zabbix-pi"

# ── 1. Install net-snmp ──────────────────────────────────────
info "Checking net-snmp..."
if ! dpkg -l snmpd &>/dev/null; then
    info "Installing snmpd..."
    apt-get update -qq
    apt-get install -y -qq snmpd
    ok "snmpd installed"
else
    ok "snmpd already installed"
fi

# ── 2. Create wrapper scripts ────────────────────────────────
info "Creating wrapper scripts in $SCRIPT_DIR ..."
mkdir -p "$SCRIPT_DIR"

# Helper: write a script and make it executable
write_script() {
    local name="$1"; shift
    cat > "$SCRIPT_DIR/$name" << SCRIPT
#!/bin/bash
$*
SCRIPT
    chmod +x "$SCRIPT_DIR/$name"
}

# ── vcgencmd scripts ─────────────────────────────────────────

# SoC Temperature
write_script pi-cpu-temp \
    "vcgencmd measure_temp | grep -oP '[\d.]+'"

# Clock frequencies — lookbehind anchors to Hz value after '='
# vcgencmd outputs: frequency(48)=1500345728
# grep -oP '(?<==)\d+' returns only: 1500345728
write_script pi-arm-clock \
    "vcgencmd measure_clock arm  | grep -oP '(?<==)\d+'"

write_script pi-core-clock \
    "vcgencmd measure_clock core | grep -oP '(?<==)\d+'"

write_script pi-gpu-clock \
    "vcgencmd measure_clock v3d  | grep -oP '(?<==)\d+'"

# Voltages
write_script pi-volt-core \
    "vcgencmd measure_volts core    | grep -oP '[\d.]+'"

write_script pi-volt-sdram-c \
    "vcgencmd measure_volts sdram_c | grep -oP '[\d.]+'"

write_script pi-volt-sdram-i \
    "vcgencmd measure_volts sdram_i | grep -oP '[\d.]+'"

write_script pi-volt-sdram-p \
    "vcgencmd measure_volts sdram_p | grep -oP '[\d.]+'"

# Throttle register — convert hex to decimal for Zabbix
write_script pi-throttle \
    "printf '%d\n' \$(vcgencmd get_throttled | grep -oP '0x[\da-fA-F]+')"

# Memory split — convert MB to bytes
write_script pi-mem-arm \
    "vcgencmd get_mem arm | grep -oP '\d+' | awk '{print \$1 * 1048576}'"

write_script pi-mem-gpu \
    "vcgencmd get_mem gpu | grep -oP '\d+' | awk '{print \$1 * 1048576}'"

# AVS temperature (Pi 5 only; Pi 4 returns 0)
write_script pi-avs-temp \
    "vcgencmd get_config int 2>/dev/null | grep avs_temp | grep -oP '[\d.]+' || echo 0"

# ── /proc/meminfo script (NEW in v16) ────────────────────────
# RAM usage percentage: (MemTotal - MemAvailable) / MemTotal * 100
# Uses awk for one-shot parsing — no bc, no python dependency
cat > "$SCRIPT_DIR/pi-mem-used-pct" << 'MEMSCRIPT'
#!/bin/bash
awk '
  /^MemTotal:/     { total = $2 }
  /^MemAvailable:/ { avail = $2 }
  END {
    if (total > 0)
      printf "%.1f\n", (total - avail) / total * 100
    else
      print "0"
  }
' /proc/meminfo
MEMSCRIPT
chmod +x "$SCRIPT_DIR/pi-mem-used-pct"

ok "12 wrapper scripts created (11 vcgencmd + 1 /proc/meminfo)"

# ── 3. SNMPv3 user ───────────────────────────────────────────
info "Configuring SNMPv3 user '$SNMP_USER'..."
systemctl stop snmpd 2>/dev/null || true

# Remove existing user if present to allow passphrase updates
if grep -q "^usmUser.*$SNMP_USER" /var/lib/snmp/snmpd.conf 2>/dev/null; then
    warn "Existing SNMPv3 user found — removing for clean re-creation"
    sed -i "/^usmUser.*$SNMP_USER/d" /var/lib/snmp/snmpd.conf
fi

# Create user with SHA-256 auth + AES128 priv
net-snmp-create-v3-user \
    -ro \
    -a SHA-256 \
    -A "$AUTH_PASS" \
    -x AES \
    -X "$PRIV_PASS" \
    "$SNMP_USER" \
    || die "net-snmp-create-v3-user failed"

ok "SNMPv3 user '$SNMP_USER' created (SHA-256 / AES128)"

# ── 4. Write snmpd.conf ──────────────────────────────────────
info "Writing /etc/snmp/snmpd.conf ..."
CONF_FILE="/etc/snmp/snmpd.conf"
BACKUP="/etc/snmp/snmpd.conf.bak.$(date +%Y%m%d%H%M%S)"

[[ -f "$CONF_FILE" ]] && cp "$CONF_FILE" "$BACKUP" && info "Backed up to $BACKUP"

cat > "$CONF_FILE" << CONF
# /etc/snmp/snmpd.conf
# Generated by pi-snmp-setup.sh (v16) for Zabbix 'Raspberry Pi by SNMP' template
# $(date)

# ── Listen on all interfaces (UDP only) ──────────────────────
agentaddress udp:161,udp6:161

# ── System info ──────────────────────────────────────────────
sysLocation    Raspberry Pi
sysContact     admin@localhost
sysServices    72

# ── SNMPv3 view / access ─────────────────────────────────────
view   zabbixView  included  .1
access zabbixGroup ""  usm priv exact zabbixView none none
group  zabbixGroup usm $SNMP_USER

# ── Pi hardware extend scripts (vcgencmd) ────────────────────
extend pi-cpu-temp     $SCRIPT_DIR/pi-cpu-temp
extend pi-arm-clock    $SCRIPT_DIR/pi-arm-clock
extend pi-core-clock   $SCRIPT_DIR/pi-core-clock
extend pi-gpu-clock    $SCRIPT_DIR/pi-gpu-clock
extend pi-volt-core    $SCRIPT_DIR/pi-volt-core
extend pi-volt-sdram-c $SCRIPT_DIR/pi-volt-sdram-c
extend pi-volt-sdram-i $SCRIPT_DIR/pi-volt-sdram-i
extend pi-volt-sdram-p $SCRIPT_DIR/pi-volt-sdram-p
extend pi-throttle     $SCRIPT_DIR/pi-throttle
extend pi-mem-arm      $SCRIPT_DIR/pi-mem-arm
extend pi-mem-gpu      $SCRIPT_DIR/pi-mem-gpu
extend pi-avs-temp     $SCRIPT_DIR/pi-avs-temp

# ── OS RAM usage extend script (NEW v16) ─────────────────────
extend pi-mem-used-pct $SCRIPT_DIR/pi-mem-used-pct
CONF

ok "snmpd.conf written (13 extend stanzas)"

# ── 5. Add Debian-snmp to video group ────────────────────────
info "Adding Debian-snmp to 'video' group (required for vcgencmd)..."
if getent group video | grep -q Debian-snmp; then
    ok "Debian-snmp already in video group"
else
    usermod -aG video Debian-snmp
    ok "Debian-snmp added to video group"
fi

# ── 6. Start snmpd and verify ────────────────────────────────
info "Starting snmpd..."
systemctl enable snmpd
systemctl start snmpd
sleep 2

if systemctl is-active --quiet snmpd; then
    ok "snmpd is running"
else
    die "snmpd failed to start — check: journalctl -u snmpd -n 50"
fi

# ── 7. Verify all 12 scripts return data ─────────────────────
info "Verifying all 12 extend scripts..."
SCRIPTS=(
    pi-cpu-temp pi-arm-clock pi-core-clock pi-gpu-clock
    pi-volt-core pi-volt-sdram-c pi-volt-sdram-i pi-volt-sdram-p
    pi-throttle pi-mem-arm pi-mem-gpu pi-avs-temp
    pi-mem-used-pct
)

ALL_OK=true
for s in "${SCRIPTS[@]}"; do
    val=$("$SCRIPT_DIR/$s" 2>/dev/null | head -1)
    if [[ -n "$val" ]]; then
        ok "$s → $val"
    else
        warn "$s → NO OUTPUT"
        ALL_OK=false
    fi
done

echo ""
if $ALL_OK; then
    ok "All 12 scripts verified."
else
    warn "Some scripts returned no output."
    warn "vcgencmd scripts need vcgencmd in PATH for the Debian-snmp user."
    warn "Try:  which vcgencmd"
    warn "      ls /usr/bin/vcgencmd /opt/vc/bin/vcgencmd"
    warn "pi-mem-used-pct should always work — check /proc/meminfo permissions."
fi

# ── 8. Quick OID sanity check ────────────────────────────────
echo ""
info "Spot-checking pi-mem-used-pct via snmpget (loopback)..."
MEM_OID=".1.3.6.1.4.1.8072.1.3.2.3.1.2.15.112.105.45.109.101.109.45.117.115.101.100.45.112.99.116"
MEM_VAL=$(snmpget -v3 -u "$SNMP_USER" -l authPriv \
    -a SHA-256 -A "$AUTH_PASS" \
    -x AES    -X "$PRIV_PASS" \
    localhost "$MEM_OID" 2>/dev/null | awk '{print $NF}') || true

if [[ -n "$MEM_VAL" ]]; then
    ok "pi-mem-used-pct OID → $MEM_VAL%"
else
    warn "OID check failed — snmpd may need a moment to load extend scripts."
    warn "Retry manually:  snmpget -v3 -u $SNMP_USER -l authPriv \\"
    warn "  -a SHA-256 -A '<pass>' -x AES -X '<pass>' \\"
    warn "  localhost $MEM_OID"
fi

# ── 9. Summary ───────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!  (v16)${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "  SNMP user  : $SNMP_USER"
echo "  Auth       : SHA-256"
echo "  Priv       : AES128"
echo "  Port       : UDP 161"
echo "  Scripts    : 12 (11 vcgencmd + 1 /proc/meminfo)"
echo ""
echo "  Test from Zabbix server:"
echo "  snmpwalk -v3 -u $SNMP_USER -l authPriv \\"
echo "    -a SHA-256 -A '<auth-pass>' \\"
echo "    -x AES -X '<priv-pass>' \\"
echo "    <this-pi-ip> .1.3.6.1.4.1.8072.1.3.2.3.1.2"
echo ""
echo "  In Zabbix: add SNMP interface <ip>:161, SNMPv3, authPriv"
echo "  Template : 'Raspberry Pi by SNMP' (v16)"
echo ""
