# lhssh - Local Host SSH Scanner and Connection Manager

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](https://github.com/OkusiAssociates/lhssh)
[![License](https://img.shields.io/badge/license-GPL3-green)](LICENSE)

A modern, dependency-free bash utility for scanning and managing SSH connections to hosts on local networks. Supports IPv4 range scanning, IPv6 link-local discovery, and batch command execution across multiple hosts.

## Installation

**One-liner:**
```bash
git clone https://github.com/OkusiAssociates/lhssh.git && cd lhssh && sudo make install
```

**Manual:**
```bash
git clone https://github.com/OkusiAssociates/lhssh.git
cd lhssh
sudo make install
```

This installs `lhssh` and `lhssh-cmd` to `/usr/local/bin/`, bash completion to `/etc/bash_completion.d/`, and a system-wide default config to `/etc/lhssh/lhssh.conf`.

To uninstall:
```bash
sudo make uninstall
```

## Quick Start

```bash
lhssh                    # Scan network for SSH hosts
lhssh 152                # Connect to 192.168.1.152 (short notation)
lhssh 152 uptime         # Run command on host
lhssh -p                 # List host octets only (for scripting)
lhssh -6                 # Scan IPv6 link-local neighbors
lhssh-cmd "df -h"        # Run command on ALL discovered hosts
lhssh-cmd -p uptime      # Parallel execution across all hosts
```

## Requirements

- Bash 5.2+
- OpenSSH client (`ssh`, `ssh-keyscan`)
- GNU coreutils (`timeout`)
- `ping6` (for IPv6 scanning)
- Standard Unix tools: `grep`, `sort`, `xargs`, `awk`, `getent`, `tput`, `realpath`

## Usage

```
lhssh [OPTIONS] [TARGET [COMMAND...]]
```

TARGET can be a short octet (`152`), full IPv4 (`192.168.1.152`), or IPv6 address (`fe80::1%enp12s0`).

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-V, --version` | Show version information |
| `-v, --verbose` | Verbose output (use `-vv` for debug) |
| `-q, --quiet` | Suppress non-essential output |
| **Display** | |
| `-s, --short` | Show IP addresses only |
| `-p, --supershort` | Show last octet only (IPv4) or full address (IPv6) |
| `-H, --with-hostname` | Add hostname to `-s`/`-p` output (tab-separated) |
| `-C, --no-color` | Disable colored output |
| **Network** | |
| `-n, --network PREFIX` | Set network prefix or CIDR /24 (default: `192.168.1.`) |
| `-b, --begin IP` | Start IP for scanning (default: `50`) |
| `-f, --finish IP` | End IP for scanning (default: `230`) |
| `-6, --ipv6` | Scan IPv6 link-local neighbors instead of IPv4 |
| `-I, --interface IFACE` | Network interface for IPv6 scanning (default: auto) |
| **SSH** | |
| `-u, --user USERNAME` | SSH username (default: current user) |
| `-t, --timeout SECS` | Connection timeout in seconds (default: `10`) |
| `-T, --session-time SECS` | Session timeout in seconds (default: `600`) |
| **Configuration** | |
| `-l, --list` | Show current configuration |
| `-e, --edit` | Edit configuration file |
| `-S, --save-config` | Save current options to configuration |

### Examples

```bash
# Scan a different network range
lhssh -n 10.0.0. -b 1 -f 50

# Scan a /24 network using CIDR notation
lhssh -n 10.99.10.0/24

# Connect as different user with longer timeout
lhssh -u admin -t 30 152

# Scan IPv6 neighbors for SSH hosts
lhssh -6

# Scan IPv6 on a specific interface
lhssh -6 -I eth0

# Connect to an IPv6 host
lhssh fe80::1%enp12s0 hostname

# Execute command on all discovered hosts
for ip in $(lhssh -p); do
    lhssh $ip "hostname -f"
done

# Short output with hostnames (tab-separated)
lhssh -sH     # 192.168.1.50\thostname
lhssh -pH     # 50\thostname

# Combine short options
lhssh -vp     # Verbose + supershort
lhssh -6s     # IPv6 + short display
```

## lhssh-cmd

Batch command executor that wraps `lhssh` to run commands across all discovered hosts.

```bash
lhssh-cmd [OPTIONS] COMMAND...
```

| Option | Description |
|--------|-------------|
| `-p, --parallel` | Execute commands in parallel |
| `-P, --max-parallel N` | Max parallel connections (default: `10`) |
| `-6, --ipv6` | Discover IPv6 hosts instead of IPv4 |
| `-I, --interface IFACE` | Network interface for IPv6 scanning |
| `--lhssh PATH` | Path to lhssh command |

```bash
lhssh-cmd "df -h"            # Check disk on all hosts
lhssh-cmd -p uptime          # Parallel uptime check
lhssh-cmd -6 hostname        # Run on all IPv6 hosts
lhssh-cmd -- 'ps aux | grep nginx'  # Complex commands after --
```

## Configuration

Configuration is loaded in layers (each overrides the previous):

1. **System defaults**: `/etc/lhssh/lhssh.conf`
2. **User config** (first found):
   - `~/.lhssh.conf` (legacy)
   - `~/.config/lhssh/lhssh.conf` (XDG)
   - `/usr/local/etc/lhssh/lhssh.conf`

### Configuration Variables

```bash
LOCALHOST_HEAD='192.168.1.'   # Network prefix (must end with dot)
LOCALHOST_START_IP=50         # First IP in scan range
LOCALHOST_END_IP=230          # Last IP in scan range
LOGIN_USERNAME='root'         # SSH login username
SHORT_DISPLAY=0               # 0=detailed, 1=IPs only
SUPER_SHORT=0                 # 0=full IPs, 1=last octet only
SSH_CONNECT_TIMEOUT=10        # Connection timeout (seconds)
SSH_SESSION_TIMEOUT=600       # Session timeout (seconds)
COLOR_OUTPUT=1                # 0=disable, 1=enable
PARALLEL_SCAN=1               # 0=sequential, 1=parallel
IPV6_INTERFACE=''             # IPv6 interface (empty=auto-detect)
```

```bash
lhssh -S    # Save current options to config
lhssh -e    # Edit config in $EDITOR
lhssh -l    # Show current config
```

## IPv6 Scanning

lhssh discovers IPv6 hosts by sending an ICMPv6 all-nodes multicast ping (`ff02::1`) on the local interface, then filtering responding hosts through `ssh-keyscan`.

```bash
lhssh -6                  # Auto-detect interface, scan IPv6
lhssh -6 -I enp12s0       # Specify interface
lhssh -6 -p               # List IPv6 hosts for scripting
lhssh -6 -t 1             # Faster scan (1s ping timeout)
```

The `-t` timeout controls both SSH connection timeout (connect mode) and multicast ping timeout (IPv6 scan mode).

IPv6 addresses with zone IDs (e.g., `fe80::1%enp12s0`) are fully supported for direct connections.

## Security

- Key-based authentication only (`PasswordAuthentication=no`)
- Configuration files created with `600` permissions
- SSH host key checking set to `accept-new`
- Respects `NO_COLOR` environment variable ([no-color.org](https://no-color.org))
- IPv6 address input validated against injection characters

## Testing

```bash
make test          # Run full test suite (requires bats)
bats tests/        # Run directly
```

## Version History

### v2.0.0 (Current)
- Complete refactor to remove external dependencies
- IPv6 host discovery via multicast ping (`-6`, `-I`)
- IPv6 address validation
- Parallel scanning with native `ssh-keyscan` multi-host mode
- CIDR `/24` notation for network scanning
- XDG-compliant configuration with cascading system/user config
- Batch command execution (`lhssh-cmd`) with parallel mode
- BCS1212-compliant Makefile installation
- Bash completion
- `NO_COLOR` support
- Comprehensive test suite (139 tests)

### v1.0.0
- Initial release with nmap dependency
- Basic scanning and connection features

## License

GPL-3.0 - see [LICENSE](LICENSE) for details.

## Links

- GitHub: [https://github.com/OkusiAssociates/lhssh](https://github.com/OkusiAssociates/lhssh)
- Issues: [https://github.com/OkusiAssociates/lhssh/issues](https://github.com/OkusiAssociates/lhssh/issues)
