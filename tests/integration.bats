#!/usr/bin/env bats
# integration.bats - Integration tests for lhssh and lhssh-cmd
#
# Tests full script invocation (not sourced).
# Uses mocked external commands to avoid real network activity.
bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  enable_mocks
  export MOCK_SSH_HOSTS=""
  export PARALLEL_SCAN=0
}

teardown() {
  disable_mocks
  teardown_test_env
}

LHSSH="$BATS_TEST_DIRNAME/../lhssh"
LHSSH_CMD="$BATS_TEST_DIRNAME/../lhssh-cmd"

# ============================================================
# lhssh: help, version, config
# ============================================================

@test "integration: lhssh --help exits 0 with usage text" {
  run "$LHSSH" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"USAGE:"* ]]
  [[ "$output" == *"OPTIONS:"* ]]
  [[ "$output" == *"EXAMPLES:"* ]]
  [[ "$output" == *"CONFIGURATION FILE:"* ]]
}

@test "integration: lhssh -h exits 0" {
  run "$LHSSH" -h
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"USAGE:"* ]]
}

@test "integration: lhssh --version exits 0 with version" {
  run "$LHSSH" --version
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"2.0.0"* ]]
}

@test "integration: lhssh -V exits 0" {
  run "$LHSSH" -V
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"2.0.0"* ]]
}

@test "integration: lhssh -S creates config file" {
  [[ ! -f "$CONFIG_FILE" ]]
  run "$LHSSH" -S
  [[ "$status" -eq 0 ]]
  [[ -f "$CONFIG_FILE" ]]
  # Verify permissions
  local -- perms
  perms=$(stat -c '%a' "$CONFIG_FILE")
  [[ "$perms" == "600" ]]
}

@test "integration: lhssh -l shows config content" {
  write_test_config
  run "$LHSSH" -l
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"LOCALHOST_HEAD"* ]]
  [[ "$output" == *"LOGIN_USERNAME"* ]]
  # Should NOT show shebang line
  [[ "$output" != *"#!/bin/bash"* ]]
}

# ============================================================
# lhssh: scan mode
# ============================================================

@test "integration: lhssh scan with no hosts shows warning" {
  export MOCK_SSH_HOSTS=""
  write_test_config "PARALLEL_SCAN=0"
  run --separate-stderr "$LHSSH" -b 100 -f 101
  [[ "$status" -eq 0 ]]
  [[ "$stderr" == *"No SSH hosts found"* ]]
}

@test "integration: lhssh scan finds mocked hosts" {
  export MOCK_SSH_HOSTS="192.168.1.100 192.168.1.101"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -b 100 -f 101
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"192.168.1.100"* ]]
  [[ "$output" == *"192.168.1.101"* ]]
}

@test "integration: lhssh -s shows IPs only" {
  export MOCK_SSH_HOSTS="192.168.1.100"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -s -b 100 -f 100
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"SSH Hosts Found"* ]]
  [[ "$output" == *"192.168.1.100"* ]]
}

@test "integration: lhssh -p shows last octets only" {
  export MOCK_SSH_HOSTS="192.168.1.100 192.168.1.150"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -p -b 100 -f 150
  [[ "$status" -eq 0 ]]
  echo "$output" | grep -qx '100'
  echo "$output" | grep -qx '150'
}

@test "integration: lhssh -n sets network prefix" {
  export MOCK_SSH_HOSTS="10.0.0.5"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -n "10.0.0." -b 5 -f 5 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"10.0.0.5"* ]]
}

@test "integration: lhssh -n with CIDR /24" {
  export MOCK_SSH_HOSTS="10.99.10.1"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -n "10.99.10.0/24" -b 1 -f 1 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"10.99.10.1"* ]]
}

# ============================================================
# lhssh: connect mode
# ============================================================

@test "integration: lhssh connects to short octet" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT="hostname-result"
  write_test_config
  run "$LHSSH" 152 hostname
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"hostname-result"* ]]
  grep -q 'testuser@192.168.1.152' "$MOCK_SSH_LOG"
}

@test "integration: lhssh connects to full IP" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT="ok"
  write_test_config
  run "$LHSSH" 10.0.0.5 uptime
  [[ "$status" -eq 0 ]]
  grep -q 'testuser@10.0.0.5' "$MOCK_SSH_LOG"
}

@test "integration: lhssh -u overrides username" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  write_test_config
  run "$LHSSH" -u admin 100 hostname
  grep -q 'admin@192.168.1.100' "$MOCK_SSH_LOG"
}

@test "integration: lhssh -t overrides connect timeout" {
  export MOCK_SSH_LOG="$TEST_HOME/ssh.log"
  export MOCK_SSH_OUTPUT=""
  write_test_config
  run "$LHSSH" -t 30 100 hostname
  grep -q 'ConnectTimeout=30' "$MOCK_SSH_LOG"
}

@test "integration: lhssh rejects invalid target" {
  write_test_config
  run "$LHSSH" abc hostname
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh rejects out-of-range octet" {
  write_test_config
  run "$LHSSH" 999 hostname
  [[ "$status" -ne 0 ]]
}

# ============================================================
# lhssh: combined options
# ============================================================

@test "integration: lhssh -vp combines verbose and supershort" {
  export MOCK_SSH_HOSTS="192.168.1.100"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -vp -b 100 -f 100
  [[ "$status" -eq 0 ]]
  echo "$output" | grep -qx '100'
}

@test "integration: lhssh -Cs combines no-color and short" {
  export MOCK_SSH_HOSTS="192.168.1.100"
  write_test_config "PARALLEL_SCAN=0"
  run "$LHSSH" -Cs -b 100 -f 100
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"192.168.1.100"* ]]
  [[ "$output" != *"SSH Hosts Found"* ]]
}

# ============================================================
# lhssh: error cases
# ============================================================

@test "integration: lhssh unknown option fails" {
  run "$LHSSH" --nonexistent
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh -n without argument fails" {
  run "$LHSSH" -n
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh -b without argument fails" {
  run "$LHSSH" -b
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh -u without argument fails" {
  run "$LHSSH" -u
  [[ "$status" -ne 0 ]]
}

# ============================================================
# lhssh: IPv6 scan mode
# ============================================================

@test "integration: lhssh -6 discovers IPv6 SSH hosts" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::aa%eth0\nfe80::bb%eth0'
  export MOCK_SSH_HOSTS="fe80::aa%eth0"
  run "$LHSSH" -6 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::aa%eth0"* ]]
  [[ "$output" != *"fe80::bb%eth0"* ]]
}

@test "integration: lhssh -6 -p outputs full IPv6 for scripting" {
  export MOCK_IPV6_INTERFACE="eth0"
  export MOCK_PING6_RESPONSES=$'fe80::1%eth0'
  export MOCK_SSH_HOSTS="fe80::1%eth0"
  run "$LHSSH" -6 -p
  [[ "$status" -eq 0 ]]
  echo "$output" | grep -q 'fe80::1%eth0'
}

@test "integration: lhssh -I overrides interface" {
  export MOCK_PING6_RESPONSES=$'fe80::1%wlan0'
  export MOCK_SSH_HOSTS="fe80::1%wlan0"
  run "$LHSSH" -I wlan0 -s
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"fe80::1%wlan0"* ]]
}

# ============================================================
# lhssh-cmd: help, version
# ============================================================

@test "integration: lhssh-cmd --help exits 0 with usage" {
  run "$LHSSH_CMD" --help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"USAGE:"* ]]
  [[ "$output" == *"OPTIONS:"* ]]
}

@test "integration: lhssh-cmd --version exits 0" {
  run "$LHSSH_CMD" --version
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"2.0.0"* ]]
}

# ============================================================
# lhssh-cmd: execution
# ============================================================

@test "integration: lhssh-cmd runs command on discovered hosts" {
  # Create mock lhssh in PATH
  create_temp_mock "lhssh" '
    case "${1:-}" in
      -p) echo "100"; echo "101" ;;
      100|101)
        shift
        [[ "${1:-}" == "--" ]] && shift
        echo "uptime-result"
        ;;
    esac
  '
  run "$LHSSH_CMD" uptime
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"uptime-result"* ]]
}

@test "integration: lhssh-cmd without command shows error" {
  run "$LHSSH_CMD"
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh-cmd unknown option fails" {
  run "$LHSSH_CMD" --bogus
  [[ "$status" -ne 0 ]]
}

@test "integration: lhssh-cmd -P without argument fails" {
  run "$LHSSH_CMD" -P
  [[ "$status" -ne 0 ]]
}

# ============================================================
# lhssh-cmd: parallel mode
# ============================================================

@test "integration: lhssh-cmd -p runs in parallel" {
  create_temp_mock "lhssh" '
    case "${1:-}" in
      -p) echo "100" ;;
      100)
        shift
        [[ "${1:-}" == "--" ]] && shift
        echo "parallel-result"
        ;;
    esac
  '
  run "$LHSSH_CMD" -p hostname
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"parallel-result"* ]]
}
