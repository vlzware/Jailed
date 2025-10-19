#!/usr/bin/env bash
set -eou pipefail

CONSTANTS_FILE="$(dirname "$0")/constants.sh"
if [[ -f "$CONSTANTS_FILE" ]]; then
    source "$CONSTANTS_FILE"
else
    echo "Error: constants.sh file not found" >&2
    exit 1
fi

ORIG_IPF=""
OUT_IF=""
WG_ENDPOINT_IP=""
TEMP_WG_CONF=""

cleanup() {
    log "INFO" "Cleaning up..."

    # If we don't stop them, they keep running, even after "ip netns del ..."
    for pid in $(firejail --list | grep "netns=${NS}" | awk '{print $1}' | cut -d: -f1); do
        firejail --shutdown=$pid
    done
    log "INFO" "All Firejail processses in '${NS}' removed."

    # Firewall Cleanup
    iptables -D FORWARD -j "${FW_CHAIN}" 2>/dev/null
    iptables -F "${FW_CHAIN}" 2>/dev/null
    iptables -X "${FW_CHAIN}" 2>/dev/null
    if [[ -n "$NS_IP" && -n "$OUT_IF" ]]; then
        iptables -t nat -D POSTROUTING -s "${NS_IP}/32" -o "${OUT_IF}" -j MASQUERADE 2>/dev/null
    fi
    log "INFO" "Firewall rules and chain '${FW_CHAIN}' removed."

    # Restore ip_forward if we changed it
    if [[ -n "${ORIG_IPF}" ]]; then
        sysctl -w net.ipv4.ip_forward="${ORIG_IPF}" >/dev/null 2>&1
    fi

    # Cleanup namespace and temp files
    ip netns del "${NS}" >/dev/null 2>&1
    if [[ -n "$TEMP_WG_CONF" ]] && [[ -f "$TEMP_WG_CONF" ]]; then
        rm -f "$TEMP_WG_CONF"
        log "INFO" "Removed temporary WireGuard config."
    fi
    log "INFO" "Cleanup complete."
}

# --- Main Script ---

if [[ $EUID -ne 0 ]]; then
   log "ERROR" "The main script must be run as root."
   exit 1
fi

if [ "$#" -ne 1 ]; then
    log "ERROR" "Usage: sudo $0 /path/to/your/wireguard.conf"
    exit 1
fi

WG_CONF_ORIGINAL="$1"
if [ ! -f "$WG_CONF_ORIGINAL" ]; then
    log "ERROR" "Configuration file not found: ${WG_CONF_ORIGINAL}"
    exit 1
fi

# Ensure cleanup runs on exit, interrupt, or error
trap cleanup EXIT

# Parse Config
log "INFO" "Parsing WireGuard configuration..."
WG_IF_NAME=$(basename "${WG_CONF_ORIGINAL}" .conf)
# this expects IPv4 address, will fail with IPv6 or a hostname
WG_ENDPOINT_IP=$(grep -oP '(?<=Endpoint = )[0-9\.]+' "${WG_CONF_ORIGINAL}")
WG_ENDPOINT_PORT=$(grep -oP '(?<=Endpoint = )[0-9\.:]+' "${WG_CONF_ORIGINAL}" | cut -d: -f2)
# expects a single DNS
WG_DNS=$(grep -oP '(?<=DNS = )[0-9\.]+' "${WG_CONF_ORIGINAL}")

if [[ -z "$WG_ENDPOINT_IP" || -z "$WG_ENDPOINT_PORT" || -z "$WG_IF_NAME" ]]; then
    log "ERROR" "Could not parse Endpoint IP/Port or determine interface name."
    exit 1
fi
if [[ -z "$WG_DNS" ]]; then
    log "ERROR" "Could not parse DNS server from config. A DNS entry is required for the handshake test."
    exit 1
fi

log "INFO" "Interface: '${WG_IF_NAME}', Endpoint: ${WG_ENDPOINT_IP}:${WG_ENDPOINT_PORT}, DNS: ${WG_DNS}"

# Determine host egress interface to reach the endpoint (for NAT/forwarding)
OUT_IF=$(ip route get "${WG_ENDPOINT_IP}" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev"){print $(i+1); exit}}')
if [[ -z "${OUT_IF}" ]]; then
    OUT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
fi
if [[ -z "${OUT_IF}" ]]; then
    log "ERROR" "Could not determine host egress interface for ${WG_ENDPOINT_IP}."
    exit 1
fi
log "INFO" "Host egress interface to endpoint: ${OUT_IF}"

# Wireguard would mess up our resolv.conf system-wide,
# so we set DNS manually - only in the namespace,
# then prepare a config without DNS entries
log "INFO" "Setting up namespace-specific DNS and temporary WG config."
mkdir -p "/etc/netns/${NS}"
echo "nameserver ${WG_DNS}" | tee "/etc/netns/${NS}/resolv.conf" >/dev/null
# 'mktemp' would require some 'XXXXXX', thus needing additional parsing
TEMP_WG_CONF="/tmp/${WG_IF_NAME}.conf"
touch "${TEMP_WG_CONF}"
chown root:root "${TEMP_WG_CONF}"
chmod 600 "${TEMP_WG_CONF}"
grep -vE '^\s*DNS\s*=' "${WG_CONF_ORIGINAL}" | tee "${TEMP_WG_CONF}" >/dev/null

log "INFO" "Creating namespace '${NS}' and veth pair."
ip netns add "${NS}"
# Setting up interfaces
ip link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
ip link set "${VETH_HOST}" up
ip link set "${VETH_NS}" netns "${NS}"

ip addr add "${HOST_IP}/${SUBNET_MASK}" dev "${VETH_HOST}"
ip netns exec "${NS}" ip addr add "${NS_IP}/${SUBNET_MASK}" dev "${VETH_NS}"
ip netns exec "${NS}" ip link set dev "${VETH_NS}" up
ip netns exec "${NS}" ip link set dev lo up

# no IPv6 communication through the veth pair
# alternatively: disable IPv6 globally in the namespace (see below)
sysctl -w net.ipv6.conf."${VETH_HOST}".disable_ipv6=1 >/dev/null
ip netns exec "${NS}" sysctl -w net.ipv6.conf."${VETH_NS}".disable_ipv6=1 >/dev/null

log "INFO" "Enabling host forwarding and restricted NAT for WireGuard."
ORIG_IPF=$(sysctl -n net.ipv4.ip_forward)
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# dedicated fw chain for easier cleanup
log "INFO" "Creating and populating firewall chain '${FW_CHAIN}'."
iptables -N "${FW_CHAIN}"
iptables -A "${FW_CHAIN}" -i "${VETH_HOST}" -o "${OUT_IF}" -d "${WG_ENDPOINT_IP}" -p udp --dport "${WG_ENDPOINT_PORT}" -j ACCEPT
iptables -A "${FW_CHAIN}" -i "${OUT_IF}" -o "${VETH_HOST}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "${FW_CHAIN}" -i "${VETH_HOST}" -j DROP
iptables -A "${FW_CHAIN}" -o "${VETH_HOST}" -j DROP
iptables -I FORWARD 1 -j "${FW_CHAIN}"
iptables -t nat -I POSTROUTING 1 -s "${NS_IP}/32" -o "${OUT_IF}" -j MASQUERADE

log "INFO" "Adding specific route to WireGuard endpoint ONLY."
# This is the only route out of the namespace pre-tunnel. It only tells the
# kernel how to reach the WG endpoint. All other traffic has no route and fails.
ip netns exec "${NS}" ip route add "${WG_ENDPOINT_IP}" via "${HOST_IP}"

log "INFO" "Applying 'fail-closed' firewall rules inside '${NS}'."
# defaults
ip netns exec "${NS}" iptables -P INPUT DROP
ip netns exec "${NS}" iptables -P OUTPUT DROP
ip netns exec "${NS}" iptables -P FORWARD DROP
ip netns exec "${NS}" iptables -F INPUT
ip netns exec "${NS}" iptables -F OUTPUT
ip netns exec "${NS}" iptables -F FORWARD
# lo
ip netns exec "${NS}" iptables -A INPUT -i lo -j ACCEPT
ip netns exec "${NS}" iptables -A OUTPUT -o lo -j ACCEPT
# Wireguard handshake - the only allowed comm outside the tunnel
ip netns exec "${NS}" iptables -A INPUT -i "${VETH_NS}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip netns exec "${NS}" iptables -A OUTPUT -d "${WG_ENDPOINT_IP}" -p udp --dport "${WG_ENDPOINT_PORT}" -j ACCEPT
# Wireguard tunnel
ip netns exec "${NS}" iptables -A INPUT -i "${WG_IF_NAME}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip netns exec "${NS}" iptables -A OUTPUT -o "${WG_IF_NAME}" -j ACCEPT

log "INFO" "Attempting to start WireGuard interface '${WG_IF_NAME}'..."
ip netns exec "${NS}" wg-quick up "${TEMP_WG_CONF}"

# alternatively: turn IPv6 globally off in the namespace
#ip netns exec "${NS}" sysctl -w net.ipv6.conf.default.disable_ipv6=1
#ip netns exec "${NS}" sysctl -w net.ipv6.conf.all.disable_ipv6=1

log "INFO" "WireGuard process started. Verifying connection handshake..."
HANDSHAKE_VERIFIED=false
for (( i=0; i<HANDSHAKE_TIMEOUT; i++ )); do
    # Probe DNS to generate traffic and trigger a handshake.
    ip netns exec "${NS}" ping -c 1 -W 1 "${WG_DNS}" &>/dev/null || true
    HANDSHAKE=$(ip netns exec "${NS}" wg show "${WG_IF_NAME}" latest-handshakes | awk '{print $2}')
    if [[ -n "$HANDSHAKE" && "$HANDSHAKE" != "0" ]]; then
        HANDSHAKE_VERIFIED=true
        break
    fi
    sleep 1
done

if ! $HANDSHAKE_VERIFIED; then
    log "ERROR" "WireGuard verification failed (no handshake). Killing tunnel."
    exit 1
fi

log "SUCCESS" "WireGuard connection verified and active."

echo -e "${color_yellow}Press 'enter' when done to cleanup${color_nc}"
read ans
echo -e "${color_red}START CLEANUP?${color_nc}"
read ans

log "INFO" "Application closed. This script will now clean up and exit."
exit 0
