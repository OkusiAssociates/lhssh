#!/usr/bin/env bats
# blocking.bats - Tests for the lhssh host-blocking subsystem (-K/-U/-L)
#
# Exercises validate_ip, nft_ensure_chain, kill_host, unkill_host and
# list_killed against mock `sudo` and `nft` commands (see tests/mocks/).
# The nft mock persists a tiny ruleset under $HOME so blocks survive across
# the kill -> list -> unkill calls within a single test.
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
# validate_ip()
# ============================================================

@test "validate_ip: accepts dotted IPv4" {
  run validate_ip 192.168.1.99
  [[ "$status" -eq 0 ]]
}

@test "validate_ip: accepts IPv6 with zone id" {
  run validate_ip 'fe80::1%eth0'
  [[ "$status" -eq 0 ]]
}

@test "validate_ip: rejects short octet (not a full IP)" {
  run validate_ip 152
  [[ "$status" -eq 22 ]]
  [[ "$output" == *"Invalid IP address"* ]]
}

@test "validate_ip: rejects garbage" {
  run validate_ip 'not-an-ip'
  [[ "$status" -eq 22 ]]
}

# ============================================================
# nft_ensure_chain() — H2: must use the input hook
# ============================================================

@test "kill_host: creates the nft chain with hook input (not forward)" {
  run kill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  # The mock records the chain spec it was asked to create
  grep -q 'hook input' "$HOME/.nft.chain"
  ! grep -q 'hook forward' "$HOME/.nft.chain"
}

# ============================================================
# kill_host() — IPv4
# ============================================================

@test "kill_host: blocks an IPv4 address with 'ip saddr'" {
  run kill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  grep -q 'ip saddr 192.168.1.99 drop' "$HOME/.nft.rules"
  # Must be IPv4 'ip saddr', never the IPv6 'ip6 saddr' form
  ! grep -q 'ip6 saddr 192.168.1.99' "$HOME/.nft.rules"
}

@test "kill_host: blocking the same IPv4 twice reports already blocked" {
  run kill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  run kill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"already blocked"* ]]
  # Only one rule should exist
  [[ "$(grep -c 'saddr 192.168.1.99 ' "$HOME/.nft.rules")" -eq 1 ]]
}

@test "kill_host: rejects a short octet before touching nft" {
  run kill_host 99
  [[ "$status" -eq 22 ]]
  [[ ! -f "$HOME/.nft.table" ]]
}

# ============================================================
# kill_host() — IPv6 (H3: must use 'ip6 saddr' and strip %zone)
# ============================================================

@test "kill_host: blocks an IPv6 address with 'ip6 saddr' and strips zone" {
  run kill_host 'fe80::1%eth0'
  [[ "$status" -eq 0 ]]
  grep -q 'ip6 saddr fe80::1 drop' "$HOME/.nft.rules"
  # The %zone suffix must not reach the nft rule
  ! grep -q '%eth0' "$HOME/.nft.rules"
}

# ============================================================
# list_killed()
# ============================================================

@test "list_killed: reports none when no table exists" {
  run list_killed
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No blocked hosts"* ]]
}

@test "list_killed: shows blocked IPv4 and IPv6 addresses" {
  run kill_host 192.168.1.50
  run kill_host 'fe80::1%eth0'
  run list_killed
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"192.168.1.50"* ]]
  [[ "$output" == *"fe80::1"* ]]
}

# ============================================================
# unkill_host()
# ============================================================

@test "unkill_host: removes a previously blocked IPv4 address" {
  run kill_host 192.168.1.99
  run list_killed
  [[ "$output" == *"192.168.1.99"* ]]
  run unkill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  run list_killed
  [[ "$output" != *"192.168.1.99"* ]]
}

@test "unkill_host: warns when the IP is not blocked" {
  run kill_host 192.168.1.50
  run unkill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"not blocked"* ]]
}

@test "unkill_host: warns when no table exists" {
  run unkill_host 192.168.1.99
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No blocked hosts"* ]]
}

@test "unkill_host: removes a blocked IPv6 address (zone stripped)" {
  run kill_host 'fe80::1%eth0'
  run unkill_host 'fe80::1%eth0'
  [[ "$status" -eq 0 ]]
  run list_killed
  [[ "$output" != *"fe80::1"* ]]
}
#fin
