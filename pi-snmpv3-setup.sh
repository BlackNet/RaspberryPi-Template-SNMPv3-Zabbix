#!/usr/bin/env bash
# =============================================================================
# Raspberry Pi — SNMPv3 Setup for Zabbix
# Compatible with Raspberry Pi OS Bullseye / Bookworm  |  Pi 4B & Pi 5
#
# Run as root:  sudo bash pi-snmpv3-setup.sh
#
# What this does:
#   1. Prompts for SNMPv3 credentials (never hardcoded)
#   2. Stops snmpd cleanly
#   3. Creates the SNMPv3 user in /var/lib/snmp/snmpd.conf
#   4. Patches /etc/snmp/snmpd.conf:
#        - Sets agentaddress to listen on all interfaces (udp:161)
#        - Adds rouser directive for authPriv access
#        - Disables the default public v2c community
#        - Ensures includeDir /etc/snmp/conf.d is present
#   5. Restarts snmpd and runs a local self-test
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Colour helpers
# --------------------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YEL}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Run this script as root (sudo bash $0)"

SNMPD_CONF="/etc/snmp/snmpd.conf"
SNMPD_VAR="/var/lib/snmp/snmpd.conf"
CONF_D="/etc/snmp/conf.d"

# --------------------------------------------------------------------------
# [1/6] Collect credentials interactively
# --------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Raspberry Pi SNMPv3 Setup for Zabbix"
echo "============================================================"
echo ""
echo "  Protocols used: SHA-256 (auth)  +  AES-128 (priv)"
echo "  Security level: authPriv  (authentication + encryption)"
echo ""

read -rp "  SNMPv3 username  [default: zabbix]:       " SNMP_USER
SNMP_USER="${SNMP_USER:-zabbix}"

while true; do
    read -rsp "  Auth passphrase  (min 8 chars):           " SNMP_AUTH
    echo
    [[ ${#SNMP_AUTH} -ge 8 ]] && break
    warn "Passphrase must be at least 8 characters."
done

while true; do
    read -rsp "  Priv passphrase  (min 8 chars):           " SNMP_PRIV
    echo
    [[ ${#SNMP_PRIV} -ge 8 ]] && break
    warn "Passphrase must be at least 8 characters."
done

echo ""
info "Username  : $SNMP_USER"
info "Auth proto: SHA-256"
info "Priv proto: AES-128"
info "Sec level : authPriv"
echo ""
read -rp "  Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# --------------------------------------------------------------------------
# [2/6] Stop snmpd  — MUST be stopped before editing the user DB
# --------------------------------------------------------------------------
info "[2/6] Stopping snmpd ..."
systemctl stop snmpd 2>/dev/null || true
sleep 1

# --------------------------------------------------------------------------
# [3/6] Create the SNMPv3 user in the net-snmp persistent user database
#
# /var/lib/snmp/snmpd.conf is the runtime user store — net-snmp reads
# 'createUser' lines on startup, hashes the passphrases into keys, then
# replaces the line with a 'usmUser' key-storage line automatically.
# We must write this ONLY while snmpd is stopped.
# --------------------------------------------------------------------------
info "[3/6] Writing SNMPv3 user to $SNMPD_VAR ..."
mkdir -p "$(dirname "$SNMPD_VAR")"

# Remove any existing entry for this username to avoid duplicates
if [[ -f "$SNMPD_VAR" ]]; then
    sed -i "/^createUser[[:space:]]\+${SNMP_USER}[[:space:]]/d" "$SNMPD_VAR"
    sed -i "/^usmUser.*${SNMP_USER}/d"                          "$SNMPD_VAR"
fi

# Append the new createUser directive
cat >> "$SNMPD_VAR" << USEREOF
createUser ${SNMP_USER} SHA-256 "${SNMP_AUTH}" AES "${SNMP_PRIV}"
USEREOF
info "  createUser written."

# --------------------------------------------------------------------------
# [4/6] Patch /etc/snmp/snmpd.conf
# --------------------------------------------------------------------------
info "[4/6] Patching $SNMPD_CONF ..."

# Back up original
cp -n "$SNMPD_CONF" "${SNMPD_CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

# -- 4a. Fix agentaddress to listen on all interfaces --------------------
if grep -q '^agentaddress' "$SNMPD_CONF"; then
    sed -i 's|^agentaddress.*|agentaddress udp:161,udp6:161|' "$SNMPD_CONF"
    info "  agentaddress updated to udp:161,udp6:161"
else
    echo "agentaddress udp:161,udp6:161" >> "$SNMPD_CONF"
    info "  agentaddress added (udp:161,udp6:161)"
fi

# -- 4b. Disable the default public v2c community (security) ------------
if grep -qE '^rocommunity\s+public' "$SNMPD_CONF"; then
    sed -i 's|^\(rocommunity\s\+public\)|# \1  # disabled by snmpv3 setup|g' "$SNMPD_CONF"
    info "  Public v2c community disabled."
fi
if grep -qE '^rocommunity6\s+public' "$SNMPD_CONF"; then
    sed -i 's|^\(rocommunity6\s\+public\)|# \1  # disabled by snmpv3 setup|g' "$SNMPD_CONF"
fi

# -- 4c. Add or update the rouser directive for our v3 user --------------
if grep -q "^rouser[[:space:]]\+${SNMP_USER}" "$SNMPD_CONF"; then
    sed -i "s|^rouser[[:space:]]\+${SNMP_USER}.*|rouser ${SNMP_USER} authpriv|" "$SNMPD_CONF"
    info "  Existing rouser line updated."
else
    cat >> "$SNMPD_CONF" << ROUSEREOF

# --- SNMPv3 user added by pi-snmpv3-setup.sh ---
rouser ${SNMP_USER} authpriv
ROUSEREOF
    info "  rouser ${SNMP_USER} authpriv added."
fi

# -- 4d. Ensure includeDir is present ------------------------------------
mkdir -p "$CONF_D"
if ! grep -q "^includeDir\s\+${CONF_D}" "$SNMPD_CONF"; then
    echo "includeDir ${CONF_D}" >> "$SNMPD_CONF"
    info "  includeDir ${CONF_D} added."
fi

# -- 4e. Ensure sysLocation / sysContact exist (required by some MIBs) --
grep -q '^sysLocation' "$SNMPD_CONF" || echo 'sysLocation  Raspberry Pi' >> "$SNMPD_CONF"
grep -q '^sysContact'  "$SNMPD_CONF" || echo 'sysContact   admin@localhost' >> "$SNMPD_CONF"

# --------------------------------------------------------------------------
# [5/6] Start snmpd
# --------------------------------------------------------------------------
info "[5/6] Starting snmpd ..."
systemctl start snmpd
sleep 2

if ! systemctl is-active --quiet snmpd; then
    error "snmpd failed to start. Check: journalctl -u snmpd -n 30"
fi
info "  snmpd is running."

# --------------------------------------------------------------------------
# [6/6] Local self-test
# --------------------------------------------------------------------------
info "[6/6] Running local SNMPv3 self-test ..."
sleep 1

# Test sysDescr
if snmpget \
    -v3 \
    -u "$SNMP_USER" \
    -l authPriv \
    -a SHA-256 \
    -A "$SNMP_AUTH" \
    -x AES \
    -X "$SNMP_PRIV" \
    127.0.0.1 \
    .1.3.6.1.2.1.1.1.0 \
    >/dev/null 2>&1; then
    info "  sysDescr test: PASS"
else
    warn "  sysDescr test: FAIL — snmpd may still be initialising. Retry in 5s:"
    warn "    snmpget -v3 -u $SNMP_USER -l authPriv -a SHA-256 -A '<auth>' -x AES -X '<priv>' 127.0.0.1 .1.3.6.1.2.1.1.1.0"
fi

# Test extend OID (pi-cpu-temp)
if snmpget \
    -v3 \
    -u "$SNMP_USER" \
    -l authPriv \
    -a SHA-256 \
    -A "$SNMP_AUTH" \
    -x AES \
    -X "$SNMP_PRIV" \
    127.0.0.1 \
    .1.3.6.1.4.1.8072.1.3.2.3.1.2 \
    >/dev/null 2>&1; then
    info "  Extend OID test (pi-* scripts): PASS"
else
    warn "  Extend OID test: FAIL — ensure wrapper scripts are installed first."
    warn "  Run pi-snmp-wrapper-scripts.sh if you haven't already."
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SNMPv3 setup complete!"
echo ""
echo "  Username    : $SNMP_USER"
echo "  Auth proto  : SHA-256"
echo "  Priv proto  : AES-128"
echo "  Sec level   : authPriv"
echo ""
echo "  Remote test from Zabbix server / another host:"
echo "    snmpwalk \\"
echo "      -v3 -u $SNMP_USER -l authPriv \\"
echo "      -a SHA-256 -A '<auth_passphrase>' \\"
echo "      -x AES    -X '<priv_passphrase>' \\"
echo "      <PI_IP> .1.3.6.1.4.1.8072.1.3.2.3.1.2"
echo ""
echo "  Zabbix host interface settings:"
echo "    SNMP version  : SNMPv3"
echo "    Security name : $SNMP_USER"
echo "    Security level: authPriv"
echo "    Auth protocol : SHA256"
echo "    Priv protocol : AES128"
echo "    (enter passphrases you chose above)"
echo "============================================================"
