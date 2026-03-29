#!/usr/bin/env bats
# lhssh_unit.bats - Unit tests for lhssh functions
#
# Tests individual functions by sourcing lhssh into the test shell.
# External commands (ssh, ssh-keyscan, nc) are mocked.
bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  enable_mocks
  source_lhssh
}

teardown() {
  disable_mocks
  teardown_test_env
}

# ============================================================
# error_msg()
# ============================================================

@test "error_msg: returns correct message for known exit codes" {
  [[ "$(error_msg 0)" == "Success" ]]
  [[ "$(error_msg 1)" == "General error" ]]
  [[ "$(error_msg 2)" == "Usage error" ]]
  [[ "$(error_msg 22)" == "Invalid argument" ]]
  [[ "$(error_msg 127)" == "Command not found" ]]
  [[ "$(error_msg 130)" == "Interrupted by Ctrl+C" ]]
  [[ "$(error_msg 255)" == "SSH connection failed" ]]
}

@test "error_msg: returns unknown for unrecognized codes" {
  local -- result
  result=$(error_msg 42)
  [[ "$result" == *"Unknown error"* ]]
  [[ "$result" == *"42"* ]]
}

# ============================================================
# log() and convenience functions
# ============================================================

@test "log: ERROR writes to stderr" {
  run --separate-stderr log ERROR "test error"
  [[ "$stderr" == *"[ERROR]"* ]]
  [[ "$stderr" == *"test error"* ]]
}

@test "log: WARN writes to stderr" {
  run --separate-stderr log WARN "test warning"
  [[ "$stderr" == *"[WARN]"* ]]
  [[ "$stderr" == *"test warning"* ]]
}

@test "log: INFO suppressed when VERBOSE=0" {
  VERBOSE=0
  run log INFO "should not appear"
  [[ -z "$output" ]]
}

@test "log: INFO shown when VERBOSE>=1" {
  VERBOSE=1
  run --separate-stderr log INFO "visible info"
  [[ "$stderr" == *"[INFO]"* ]]
  [[ "$stderr" == *"visible info"* ]]
}

@test "log: DEBUG suppressed when VERBOSE<2" {
  VERBOSE=1
  run log DEBUG "should not appear"
  [[ -z "$output" ]]
}

@test "log: DEBUG shown when VERBOSE>=2" {
  VERBOSE=2
  run --separate-stderr log DEBUG "debug msg"
  [[ "$stderr" == *"[DEBUG]"* ]]
  [[ "$stderr" == *"debug msg"* ]]
}

@test "log_error: delegates to log ERROR" {
  run --separate-stderr log_error "err test"
  [[ "$stderr" == *"[ERROR]"* ]]
  [[ "$stderr" == *"err test"* ]]
}

@test "log_warn: delegates to log WARN" {
  run --separate-stderr log_warn "warn test"
  [[ "$stderr" == *"[WARN]"* ]]
}

# ============================================================
# load_config()
# ============================================================

@test "load_config: creates config file if missing" {
  [[ ! -f "$CONFIG_FILE" ]]
  load_config
  [[ -f "$CONFIG_FILE" ]]
}

@test "load_config: created config has 600 permissions" {
  load_config
  local -- perms
  perms=$(stat -c '%a' "$CONFIG_FILE")
  [[ "$perms" == "600" ]]
}

@test "load_config: sources existing config values" {
  write_test_config "LOCALHOST_HEAD='10.0.0.'" "LOCALHOST_START_IP=5"
  load_config
  [[ "$LOCALHOST_HEAD" == "10.0.0." ]]
  ((LOCALHOST_START_IP == 5))
}

@test "load_config: default config contains all expected variables" {
  load_config
  # Verify all variables are present in generated config
  grep -q 'LOCALHOST_HEAD=' "$CONFIG_FILE"
  grep -q 'LOCALHOST_START_IP=' "$CONFIG_FILE"
  grep -q 'LOCALHOST_END_IP=' "$CONFIG_FILE"
  grep -q 'LOGIN_USERNAME=' "$CONFIG_FILE"
  grep -q 'SHORT_DISPLAY=' "$CONFIG_FILE"
  grep -q 'SUPER_SHORT=' "$CONFIG_FILE"
  grep -q 'SSH_CONNECT_TIMEOUT=' "$CONFIG_FILE"
  grep -q 'SSH_SESSION_TIMEOUT=' "$CONFIG_FILE"
  grep -q 'COLOR_OUTPUT=' "$CONFIG_FILE"
  grep -q 'PARALLEL_SCAN=' "$CONFIG_FILE"
}

# ============================================================
# create_config_file()
# ============================================================

@test "create_config_file: overwrites existing config" {
  echo "old content" > "$CONFIG_FILE"
  create_config_file
  ! grep -q 'old content' "$CONFIG_FILE"
  grep -q 'LOCALHOST_HEAD=' "$CONFIG_FILE"
}

@test "create_config_file: preserves current variable values" {
  LOCALHOST_HEAD='172.16.0.'
  LOCALHOST_START_IP=10
  create_config_file
  grep -q "LOCALHOST_HEAD='172.16.0.'" "$CONFIG_FILE"
  grep -q "LOCALHOST_START_IP=10" "$CONFIG_FILE"
}

# ============================================================
# format_output()
# ============================================================

@test "format_output: detailed mode shows header and IPs" {
  SHORT_DISPLAY=0
  SUPER_SHORT=0
  export MOCK_GETENT_DATA=""
  run format_output "192.168.1.100" "192.168.1.50"
  [[ "$output" == *"SSH Hosts Found:"* ]]
  [[ "$output" == *"192.168.1.50"* ]]
  [[ "$output" == *"192.168.1.100"* ]]
}

@test "format_output: detailed mode sorts by last octet" {
  SHORT_DISPLAY=0
  SUPER_SHORT=0
  export MOCK_GETENT_DATA=""
  run format_output "192.168.1.200" "192.168.1.50" "192.168.1.100"
  # Check order: 50 before 100 before 200
  local -- pos_50 pos_100 pos_200
  pos_50=$(echo "$output" | grep -n '\.50' | head -1 | cut -d: -f1)
  pos_100=$(echo "$output" | grep -n '\.100' | head -1 | cut -d: -f1)
  pos_200=$(echo "$output" | grep -n '\.200' | head -1 | cut -d: -f1)
  ((pos_50 < pos_100))
  ((pos_100 < pos_200))
}

@test "format_output: detailed mode shows hostname when available" {
  SHORT_DISPLAY=0
  SUPER_SHORT=0
  export MOCK_GETENT_DATA="192.168.1.50=server1.local"
  run format_output "192.168.1.50"
  [[ "$output" == *"server1.local"* ]]
}

@test "format_output: short mode shows only IPs" {
  SHORT_DISPLAY=1
  SUPER_SHORT=0
  run format_output "192.168.1.100" "192.168.1.50"
  [[ "$output" != *"SSH Hosts Found"* ]]
  [[ "$output" == *"192.168.1.50"* ]]
  [[ "$output" == *"192.168.1.100"* ]]
}

@test "format_output: supershort mode shows only last octets" {
  SHORT_DISPLAY=1
  SUPER_SHORT=1
  run format_output "192.168.1.100" "192.168.1.50"
  [[ "$output" != *"192.168"* ]]
  # Should contain just the numbers
  echo "$output" | grep -q '^50$'
  echo "$output" | grep -q '^100$'
}

@test "format_output: supershort mode sorts numerically" {
  SHORT_DISPLAY=1
  SUPER_SHORT=1
  run format_output "192.168.1.200" "192.168.1.50" "192.168.1.100"
  local -a lines
  mapfile -t lines <<< "$output"
  ((lines[0] == 50))
  ((lines[1] == 100))
  ((lines[2] == 200))
}

# ============================================================
# format_output() — IPv6 addresses
# ============================================================

@test "format_output: IPv6 detailed mode shows header and addresses" {
  SHORT_DISPLAY=0
  SUPER_SHORT=0
  export MOCK_GETENT_DATA=""
  run format_output "fe80::2%eth0" "fe80::1%eth0"
  [[ "$output" == *"SSH Hosts Found:"* ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
  [[ "$output" == *"fe80::2%eth0"* ]]
}

@test "format_output: IPv6 sorts alphabetically" {
  SHORT_DISPLAY=0
  SUPER_SHORT=0
  export MOCK_GETENT_DATA=""
  run format_output "fe80::b%eth0" "fe80::a%eth0" "fe80::c%eth0"
  local -- pos_a pos_b pos_c
  pos_a=$(echo "$output" | grep -n 'fe80::a' | head -1 | cut -d: -f1)
  pos_b=$(echo "$output" | grep -n 'fe80::b' | head -1 | cut -d: -f1)
  pos_c=$(echo "$output" | grep -n 'fe80::c' | head -1 | cut -d: -f1)
  ((pos_a < pos_b))
  ((pos_b < pos_c))
}

@test "format_output: IPv6 short mode shows full addresses" {
  SHORT_DISPLAY=1
  SUPER_SHORT=0
  run format_output "fe80::1%eth0" "fe80::2%eth0"
  [[ "$output" != *"SSH Hosts Found"* ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
}

@test "format_output: IPv6 supershort outputs full addresses" {
  SHORT_DISPLAY=1
  SUPER_SHORT=1
  run format_output "fe80::1%eth0" "fe80::2%eth0"
  [[ "$output" == *"fe80::1%eth0"* ]]
  [[ "$output" == *"fe80::2%eth0"* ]]
}

# ============================================================
# scan_hosts() — with mocked ssh-keyscan
# ============================================================

@test "scan_hosts: finds hosts using mocked ssh-keyscan" {
  LOCALHOST_HEAD='192.168.1.'
  PARALLEL_SCAN=0
  export MOCK_SSH_HOSTS="192.168.1.100 192.168.1.101"
  run scan_hosts 100 102
  [[ "$output" == *"192.168.1.100"* ]]
  [[ "$output" == *"192.168.1.101"* ]]
  # 102 is not in mock list
  [[ "$output" != *"192.168.1.102"* ]]
}

@test "scan_hosts: parallel mode finds hosts" {
  LOCALHOST_HEAD='192.168.1.'
  PARALLEL_SCAN=1
  export MOCK_SSH_HOSTS="192.168.1.60 192.168.1.70"
  run scan_hosts 60 70
  [[ "$output" == *"192.168.1.60"* ]]
  [[ "$output" == *"192.168.1.70"* ]]
}

@test "scan_hosts: returns empty when no hosts respond" {
  LOCALHOST_HEAD='192.168.1.'
  PARALLEL_SCAN=0
  export MOCK_SSH_HOSTS=""
  run scan_hosts 100 102
  [[ -z "$output" ]]
}

@test "scan_hosts: uses nc fallback when ssh-keyscan unavailable" {
  # Remove ssh-keyscan from mock path, keep nc
  local -- keyscan_mock="$MOCK_DIR/ssh-keyscan"
  mv "$keyscan_mock" "${keyscan_mock}.disabled"
  # Also hide real ssh-keyscan
  create_temp_mock "ssh-keyscan-real" "exit 127"
  # Ensure nc mock is still available
  LOCALHOST_HEAD='192.168.1.'
  PARALLEL_SCAN=0
  export MOCK_SSH_HOSTS="192.168.1.55"
  # Need to re-hash commands
  hash -r
  run scan_ssh_hosts_nc 55 55
  mv "${keyscan_mock}.disabled" "$keyscan_mock"
  [[ "$output" == *"192.168.1.55"* ]]
}

# ============================================================
# IPv6 scanning
# ============================================================

@test "detect_ipv6_interface: returns interface from mock route" {
  export MOCK_IPV6_INTERFACE="eth0"
  run detect_ipv6_interface
  [[ "$status" -eq 0 ]]
  [[ "$output" == "eth0" ]]
}

@test "detect_ipv6_interface: fails when no default route" {
  export MOCK_IPV6_INTERFACE=""
  run detect_ipv6_interface
  [[ "$status" -ne 0 ]]
}

@test "discover_ipv6_neighbors: returns addresses from mock ping6" {
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0\nfe80::2%eth0'
  run discover_ipv6_neighbors eth0
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
  [[ "$output" == *"fe80::2%eth0"* ]]
}

@test "discover_ipv6_neighbors: returns empty for no responses" {
  export MOCK_PING6_RESPONSES=""
  run discover_ipv6_neighbors eth0
  [[ -z "$output" ]]
}

@test "scan_ipv6_hosts: discovers SSH hosts via IPv6" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0\nfe80::2%eth0\nfe80::3%eth0'
  export MOCK_SSH_HOSTS="fe80::1%eth0 fe80::3%eth0"
  IPV6_SCAN=1
  IPV6_INTERFACE=''
  run scan_ipv6_hosts
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
  [[ "$output" == *"fe80::3%eth0"* ]]
  [[ "$output" != *"fe80::2%eth0"* ]]
}

@test "scan_ipv6_hosts: uses IPV6_INTERFACE override" {
  export MOCK_PING6_RESPONSES=$'fe80::a%wlan0'
  export MOCK_SSH_HOSTS="fe80::a%wlan0"
  IPV6_SCAN=1
  IPV6_INTERFACE='wlan0'
  run scan_ipv6_hosts
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::a%wlan0"* ]]
}

@test "scan_hosts: dispatches to IPv6 when IPV6_SCAN=1" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0'
  export MOCK_SSH_HOSTS="fe80::1%eth0"
  IPV6_SCAN=1
  IPV6_INTERFACE=''
  run scan_hosts
  [[ "$output" == *"fe80::1%eth0"* ]]
}

# ============================================================
# ssh_connect() — argument construction
# ============================================================

@test "ssh_connect: expands short octet to full IP" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT="connected"
  LOCALHOST_HEAD='192.168.1.'
  LOGIN_USERNAME='testuser'
  SSH_CONNECT_TIMEOUT=5
  run ssh_connect 152 hostname
  [[ "$status" -eq 0 ]]
  # Verify ssh was called with expanded IP
  grep -q 'testuser@192.168.1.152' "$MOCK_SSH_LOG"
}

@test "ssh_connect: passes full IPv4 through unchanged" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect 10.0.0.5 uptime
  grep -q 'testuser@10.0.0.5' "$MOCK_SSH_LOG"
}

@test "ssh_connect: passes IPv6 through unchanged" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect "fe80::1%enp12s0" hostname
  grep -q 'testuser@fe80::1%enp12s0' "$MOCK_SSH_LOG"
}

@test "ssh_connect: accepts full IPv6 address" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect "2001:db8::1" hostname
  [[ "$status" -eq 0 ]]
  grep -q 'testuser@2001:db8::1' "$MOCK_SSH_LOG"
}

@test "ssh_connect: accepts IPv6 with embedded IPv4" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect "::ffff:192.168.1.1" hostname
  [[ "$status" -eq 0 ]]
  grep -q 'testuser@::ffff:192.168.1.1' "$MOCK_SSH_LOG"
}

@test "ssh_connect: rejects IPv6 with shell metacharacters" {
  run ssh_connect "fe80::1;whoami" hostname
  [[ "$status" -eq 22 ]]
  [[ "$output" == *"Invalid IPv6"* ]]
}

@test "ssh_connect: rejects IPv6 with brackets" {
  run ssh_connect "[::1]" hostname
  [[ "$status" -eq 22 ]]
  [[ "$output" == *"Invalid IPv6"* ]]
}

@test "ssh_connect: rejects invalid octet 0" {
  run ssh_connect 0 hostname
  [[ "$status" -ne 0 ]]
}

@test "ssh_connect: rejects invalid octet 255" {
  run ssh_connect 255 hostname
  [[ "$status" -ne 0 ]]
}

@test "ssh_connect: rejects non-numeric octet" {
  run ssh_connect "abc" hostname
  [[ "$status" -ne 0 ]]
}

@test "ssh_connect: includes ConnectTimeout option" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  SSH_CONNECT_TIMEOUT=15
  LOGIN_USERNAME='testuser'
  run ssh_connect 100 uptime
  grep -q 'ConnectTimeout=15' "$MOCK_SSH_LOG"
}

@test "ssh_connect: includes PasswordAuthentication=no" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect 100 uptime
  grep -q 'PasswordAuthentication=no' "$MOCK_SSH_LOG"
}

@test "ssh_connect: includes StrictHostKeyChecking=accept-new" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  LOGIN_USERNAME='testuser'
  run ssh_connect 100 uptime
  grep -q 'StrictHostKeyChecking=accept-new' "$MOCK_SSH_LOG"
}

@test "ssh_connect: adds -v flag when VERBOSE>0" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  VERBOSE=1
  LOGIN_USERNAME='testuser'
  run ssh_connect 100 uptime
  grep -q '\-v' "$MOCK_SSH_LOG"
}

@test "ssh_connect: propagates ssh exit code" {
  export MOCK_SSH_EXIT=255
  export MOCK_SSH_STDERR="Connection refused"
  LOGIN_USERNAME='testuser'
  run ssh_connect 100 uptime
  [[ "$status" -eq 255 ]]
}

# ============================================================
# Argument parsing (via main)
# ============================================================

@test "main: --version prints version string" {
  run main --version
  [[ "$output" == *"$VERSION"* ]]
  [[ "$output" == *"lhssh"* ]]
}

@test "main: -V prints version string" {
  run main -V
  [[ "$output" == *"$VERSION"* ]]
}

@test "main: --help prints usage" {
  run main --help
  [[ "$output" == *"USAGE:"* ]]
  [[ "$output" == *"OPTIONS:"* ]]
  [[ "$output" == *"EXAMPLES:"* ]]
}

@test "main: -h prints usage" {
  run main -h
  [[ "$output" == *"USAGE:"* ]]
}

@test "main: unknown option returns error 22" {
  run main --bogus
  [[ "$status" -ne 0 ]]
}

@test "main: -n sets network prefix" {
  # Just test parsing — scan will find nothing (no mock hosts)
  export MOCK_SSH_HOSTS=""
  PARALLEL_SCAN=0
  run main -n "10.0.0." -b 1 -f 1
  # Should not error on parse
  [[ "$status" -eq 0 ]]
}

@test "main: -n with CIDR /24 sets range 1-254" {
  export MOCK_SSH_HOSTS="10.99.10.1"
  PARALLEL_SCAN=0
  run main -n "10.99.10.0/24" -b 1 -f 1
  [[ "$status" -eq 0 ]]
}

@test "main: -S saves configuration" {
  run main -S
  [[ "$status" -eq 0 ]]
  [[ -f "$CONFIG_FILE" ]]
}

@test "main: -l shows configuration" {
  write_test_config
  run main -l
  [[ "$output" == *"LOCALHOST_HEAD"* ]]
  [[ "$output" == *"LOGIN_USERNAME"* ]]
}

@test "main: -u sets login username" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  write_test_config
  run main -u admin 100 hostname
  grep -q 'admin@192.168.1.100' "$MOCK_SSH_LOG"
}

@test "main: -t sets connection timeout" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  write_test_config
  run main -t 30 100 hostname
  grep -q 'ConnectTimeout=30' "$MOCK_SSH_LOG"
}

@test "main: -q sets VERBOSE to -1" {
  write_test_config
  source_lhssh
  main -q -S 2>/dev/null || true
  ((VERBOSE == -1))
}

@test "main: -q suppresses warnings" {
  write_test_config
  export MOCK_SSH_HOSTS=""
  PARALLEL_SCAN=0
  run --separate-stderr main -q -b 100 -f 100
  # Quiet mode should suppress "No SSH hosts found" warning
  [[ "$stderr" != *"[WARN]"* ]]
  [[ "$stderr" != *"No SSH hosts found"* ]]
}

# ============================================================
# Combined short options
# ============================================================

@test "main: combined -vp expands correctly" {
  write_test_config
  export MOCK_SSH_HOSTS="192.168.1.100"
  PARALLEL_SCAN=0
  run main -vp -b 100 -f 100
  # -p means supershort — output should be just the octet
  echo "$output" | grep -q '100'
}

@test "main: combined -sp is equivalent to -s -p" {
  write_test_config
  export MOCK_SSH_HOSTS="192.168.1.100"
  PARALLEL_SCAN=0
  run main -sp -b 100 -f 100
  # Supershort: only last octet
  [[ "$output" != *"192.168"* ]] || echo "$output" | grep -qx '100'
}

# ============================================================
# CIDR network parsing
# ============================================================

@test "main: CIDR /24 strips network and trailing octet" {
  export MOCK_SSH_HOSTS="10.99.10.1"
  PARALLEL_SCAN=0
  # The /24 should set range 1-254
  write_test_config
  run main -n "10.99.10.0/24" -b 1 -f 1
  [[ "$status" -eq 0 ]]
}

@test "main: network prefix without dot gets dot appended" {
  export MOCK_SSH_HOSTS="172.16.0.1"
  PARALLEL_SCAN=0
  write_test_config
  run main -n "172.16.0" -b 1 -f 1
  [[ "$status" -eq 0 ]]
}

# ============================================================
# Edge cases
# ============================================================

@test "main: option requiring argument fails without it" {
  run main -n
  [[ "$status" -ne 0 ]]
}

@test "main: -b requires argument" {
  run main -b
  [[ "$status" -ne 0 ]]
}

@test "main: -f requires argument" {
  run main -f
  [[ "$status" -ne 0 ]]
}

@test "main: -u requires argument" {
  run main -u
  [[ "$status" -ne 0 ]]
}

@test "main: -t requires argument" {
  run main -t
  [[ "$status" -ne 0 ]]
}

@test "main: -T requires argument" {
  run main -T
  [[ "$status" -ne 0 ]]
}

@test "main: -- separates options from ssh command" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  write_test_config
  run main 100 -- ls -la
  grep -q 'ls' "$MOCK_SSH_LOG"
}

@test "main: -I requires argument" {
  run main -I
  [[ "$status" -ne 0 ]]
}

@test "main: -6 enables IPv6 scanning" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0'
  export MOCK_SSH_HOSTS="fe80::1%eth0"
  write_test_config
  run main -6 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
}

@test "main: -I sets interface and implies -6" {
  export MOCK_PING6_RESPONSES=$'fe80::1%wlan0'
  export MOCK_SSH_HOSTS="fe80::1%wlan0"
  write_test_config
  run main -I wlan0 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%wlan0"* ]]
}

@test "main: combined -6s works" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0'
  export MOCK_SSH_HOSTS="fe80::1%eth0"
  write_test_config
  run main -6s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%eth0"* ]]
}

@test "scan_hosts: empty range returns empty" {
  LOCALHOST_HEAD='192.168.1.'
  PARALLEL_SCAN=0
  export MOCK_SSH_HOSTS=""
  run scan_hosts 100 99
  [[ -z "$output" ]]
}
