# Jailed

Lightweight VPN isolation for Linux - secure network namespaces with fail-safe architecture and hardware acceleration.

**Jailed** lets you run applications through a VPN in complete network isolation, without the overhead of virtual machines. If the VPN connection fails, traffic is blocked entirely - you go offline, not exposed.

**Perfect for video streaming**: Watch media through your VPN with complete hardware acceleration and network isolation. Whether you're avoiding ISP throttling, accessing geo-restricted content, or simply maintaining privacy - you get full performance without compromising security.

## Quick Start

### Prerequisites

- Linux with network namespace support
- WireGuard with `wg-quick`, Firejail
   ```bash
   sudo apt install wireguard firejail
   ```
- Root access (for namespace setup)

### Basic Usage

1. **Start the isolated VPN namespace:**

   ```bash
   sudo ./jailed.sh /path/to/your/wireguard.conf
   ```

   The script will set up the namespace, start WireGuard, verify the connection, then "hang":
   ```bash
   [INFO]    WireGuard process started. Verifying connection handshake...
   [SUCCESS] WireGuard connection verified and active.
   Press 'enter' when done to cleanup
   ```

2. **In another terminal, launch your application** (as your regular user):

   ```bash
   ./run_firefox.sh
   ```

   Firefox will run isolated with all traffic going through the VPN.

   **Verify it's working:**
   - VPN connection: Use your provider's check tool (e.g., https://mullvad.net/en/check)
   - Hardware acceleration: In Firefox, visit `about:support` and check "Graphics" section. In Chromium, visit `chrome://gpu` and look for "Hardware accelerated" entries. Playing a video should show low CPU usage.

3. **When done**, press Enter in the first terminal to clean up everything. (This will also kill all processes in Firejail, so you may want to close Firefox normally first to avoid "Firefox closed unexpectedly")

### Example Output

```
$ sudo ./jailed.sh ~/.config/Mullvad/wireguard.conf
[INFO]    Parsing WireGuard configuration...
[INFO]    Interface: 'wg-config', Endpoint: 203.0.113.42:51820, DNS: 10.64.0.1
[INFO]    Host egress interface to endpoint: eth0
[INFO]    Setting up namespace-specific DNS and temporary WG config.
[INFO]    Creating namespace 'jailed_ns' and veth pair.
[INFO]    Enabling host forwarding and restricted NAT for WireGuard.
[INFO]    Creating and populating firewall chain 'JAIL_FWD_jailed_ns'.
[INFO]    Adding specific route to WireGuard endpoint ONLY.
[INFO]    Applying 'fail-closed' firewall rules inside 'jailed_ns'.
[INFO]    Attempting to start WireGuard interface 'wg-config'...
[#] ip link add wg-config type wireguard
[#] wg setconf wg-config /dev/fd/63
[#] ip -4 address add 10.1.2.3/32 dev wg-config
[#] ip link set mtu 1420 up dev wg-config
[INFO]    WireGuard process started. Verifying connection handshake...
[SUCCESS] WireGuard connection verified and active.
Press 'enter' when done to cleanup
```

## Why Jailed?

### Isolation + Fail-Closed = Peace of Mind

**Complete Network Isolation**: Your VPN activities are completely separated from your main system. Applications in the jailed namespace cannot access your local network or real network interfaces - they only see the VPN tunnel.

**Fail-Closed by Design**: This is not a "kill switch" that reacts to failures. There is simply **no route to leak traffic** in the first place. If the VPN disconnects, applications lose internet connectivity entirely - you go offline, not exposed. No race conditions, no detection delays, no bypass possibilities.

### Hardware Acceleration Matters

GPU passthrough in VMs and containers can be difficult, if not impossible. Jailed runs applications directly on your hardware with full graphics acceleration.

### Common Use Cases

- **Stream videos privately** with full GPU acceleration
- **Browse without exposing your entire system** - only specific applications use the VPN
- **Avoid ISP throttling** on video streams and media
- **Access geo-restricted content** while keeping other services on your local network
- **Test applications** in isolated network environments

## How It Works

**Jailed** combines several Linux technologies to achieve secure, fail-safe VPN isolation:

### The Problem

Traditional approaches have significant drawbacks:

- **System-wide VPN**: No isolation. All traffic goes through the VPN, maximizing metadata exposure and potentially leaking your identity.
- **Virtual Machines**: Perfect isolation but difficult/no hardware acceleration, complex setup, significant overhead, and maintenance burden.
- **Containers** (Docker/Podman): Configuration complexity and hardware acceleration challenges.

### The Solution

**Jailed** creates an isolated network namespace with fail-closed firewall rules (default DROP) and restricted routing. Before the VPN tunnel is up, only one route exists - to the WireGuard endpoint. Everything else is blocked. Firejail adds filesystem isolation while preserving full hardware acceleration.

**The key insight**: Jailed can't leak traffic because it has no route to leak it in the first place. If the VPN fails, you go offline - not exposed.

### What This Protects Against

- VPN connection failures (traffic blocked, not leaked)
- DNS leaks (namespace uses VPN DNS only)
- IPv6 leaks (disabled on veth pair, tunneled by WireGuard)
- Application bypass attempts (no route exists)
- WebRTC leaks (no direct network access)

### What This Does NOT Protect Against

- **Bad habits** - Logging into personal accounts, revealing your identity or data online, etc.
- **Application-level privacy** - Browser fingerprinting, etc. is not addressed
- **VPN provider seeing your traffic** - This is inherent to using a VPN
- **Traffic analysis** - Your ISP can see you're using a VPN

General risks like compromised host systems apply to all software and are out of scope of this document.

### Limitations

- **IPv4 endpoints only**: WireGuard endpoint must be an IP address, not a hostname
- **Single DNS server**: Only the first DNS entry is parsed from your config

### Best Practices

1. **Keep software updated**: kernel, WireGuard, Firejail, iptables
2. **Verify your VPN is working**: Use your provider's check tool (e.g., https://mullvad.net/en/check)
3. **Use the isolated home**: Keep `~/.jailed` separate from your main home directory
4. **Learn about privacy**:
   - [r/privacy](https://www.reddit.com/r/privacy/) - Privacy-focused community
   - [EFF's Surveillance Self-Defense](https://ssd.eff.org/) - Tips, tools and how-tos for safer online communications
   - [PrivacyGuides](https://www.privacyguides.org/) - Privacy tools and knowledge

## Configuration

### Customizing the Launcher Script

Edit `run_firefox.sh` or create your own launcher:

```bash
#!/usr/bin/env bash

CONSTANTS_FILE="$(dirname "$0")/constants.sh"
source "$CONSTANTS_FILE"

APP=(
    firejail
    --netns="${NS}"              # Use the jailed namespace
    --private="${HOMEJ}"         # Isolated home directory
    your-application             # Your application here
    --your-flags
)

"${APP[@]}"
```

### Adjusting Constants

Edit `constants.sh` to modify defaults:

```bash
NS="jailed_ns"                   # Namespace name
HOMEJ="/home/${USER}/.jailed"   # Isolated home directory
HOST_IP="10.200.200.1"          # Host end of veth pair
NS_IP="10.200.200.2"            # Namespace end of veth pair
HANDSHAKE_TIMEOUT=5             # Seconds to wait for WG handshake
```

### WireGuard Configuration

Jailed works with any standard WireGuard configuration file. Required fields:

- `Endpoint` - Must be an IPv4 address (not hostname)
- `DNS` - Used for handshake verification

IPv6 traffic is tunneled by WireGuard; the namespace itself has no IPv6 routing.

## VPN Provider Compatibility

Jailed works with **any VPN provider that supports WireGuard**, including:

- Mullvad (tested)
- ProtonVPN
- IVPN
- Any provider offering WireGuard configs

Simply use their WireGuard configuration file.

## Troubleshooting

### "Could not parse Endpoint IP"

Your WireGuard config has a hostname in the `Endpoint` field. Resolve it to an IP:

```bash
# Find the hostname
grep Endpoint your-config.conf

# Resolve it
dig +short hostname.example.com

# Replace in the config file
Endpoint = 203.0.113.42:51820
```

### "WireGuard verification failed (no handshake)"

- Check your WireGuard config is valid
- Verify your host has internet connectivity
- Ensure the endpoint IP/port is reachable
- Check firewall rules on your host

### "Could not determine host egress interface"

Your system has no default route. Jailed needs to know which interface reaches the internet.

### Applications can't resolve DNS

The namespace uses DNS from your WireGuard config. If that server is unreachable, DNS fails. Check the `DNS` line in your WireGuard config.

### Permission denied errors

- Main script (`jailed.sh`): run as root with `sudo`
- Launcher script (`run_firefox.sh`): runs as a regular user

## Design Philosophy

**Jailed** is designed to be:

- **Simple**: Two commands, usable default configuration (optionally editable)
- **Visible**: See exactly what's happening, easy to monitor and control
- **Fail-safe**: If something breaks, you're offline, not exposed
- **Lightweight**: No VMs, full hardware acceleration, minimal overhead
- **Clean**: Complete cleanup on exit, no persistent changes

## Creating Desktop Launchers

You can create a `.desktop` file for easy launching:

```desktop
[Desktop Entry]
Type=Application
Name=Firefox (VPN)
Exec=/path/to/Jailed/run_firefox.sh
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
```

Remember to start `jailed.sh` first!

## License

GNU General Public License v3.0 - see LICENSE file for details.

## Acknowledgments

Built with:
- Linux network namespaces
- [WireGuard](https://www.wireguard.com/) - Fast, modern VPN protocol
- [Firejail](https://firejail.wordpress.com/) - SUID sandbox program

---

**Disclaimer**: This is a personal project. No professional security audit has been performed. The software is provided "as is" under GPL v3.0. **Use at your own risk.** Use responsibly and in accordance with your VPN provider's terms of service, as well as the laws in your country.
