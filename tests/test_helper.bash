#!/usr/bin/bash
# test_helper.bash - Shared test utilities for lhssh test suite
#
# Provides:
#   - Isolated test environment (temp HOME, config, PATH)
#   - Mock command infrastructure
#   - Source helpers for loading script functions without executing main

# Project root (one level up from tests/)
PROJECT_DIR="${BATS_TEST_DIRNAME}/.."
MOCK_DIR="${BATS_TEST_DIRNAME}/mocks"

# Create isolated test environment
# Sets up a temp HOME so config files don't pollute the real system
setup_test_env() {
  TEST_HOME=$(mktemp -d)
  export HOME="$TEST_HOME"
  export CONFIG_FILE="$TEST_HOME/.lhssh.conf"
  # Ensure no color in tests for predictable output
  export NO_COLOR=1
  # Disable verbose by default
  export VERBOSE=0
}

# Tear down test environment
teardown_test_env() {
  if [[ -d "${TEST_HOME:-}" ]]; then
    rm -rf "$TEST_HOME"
  fi
}

# Source lhssh functions into current shell
# The BASH_SOURCE guard prevents main() from running.
# We disable errexit around the source to prevent bats interference,
# then undo all strict-mode settings the sourced script installs.
source_lhssh() {
  set +euo pipefail
  # shellcheck source=../lhssh
  source "$PROJECT_DIR/lhssh" || true
  set +euo pipefail
  shopt -u inherit_errexit 2>/dev/null || true
  trap - SIGINT SIGTERM EXIT
}

# Source lhssh-cmd functions into current shell
source_lhssh_cmd() {
  set +euo pipefail
  # shellcheck source=../lhssh-cmd
  source "$PROJECT_DIR/lhssh-cmd" || true
  set +euo pipefail
  shopt -u inherit_errexit 2>/dev/null || true
  trap - SIGINT SIGTERM EXIT
}

# Enable mock commands by prepending mock dir to PATH
enable_mocks() {
  export ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_DIR:$PATH"
}

# Disable mock commands
disable_mocks() {
  if [[ -n "${ORIGINAL_PATH:-}" ]]; then
    export PATH="$ORIGINAL_PATH"
  fi
}

# Create a temporary mock command
# Usage: create_temp_mock <name> <script_body>
# Returns: path to the mock
create_temp_mock() {
  local -- name=$1
  local -- body=$2
  local -- mock_path="$TEST_HOME/bin/$name"
  mkdir -p "$TEST_HOME/bin"
  cat > "$mock_path" <<EOF
#!/usr/bin/bash
$body
EOF
  chmod +x "$mock_path"
  export PATH="$TEST_HOME/bin:$PATH"
  echo "$mock_path"
}

# Write a test config file
# Usage: write_test_config [key=value ...]
write_test_config() {
  cat > "$CONFIG_FILE" <<'CONF'
LOCALHOST_HEAD='192.168.1.'
LOCALHOST_START_IP=50
LOCALHOST_END_IP=230
LOGIN_USERNAME='testuser'
SHORT_DISPLAY=0
SUPER_SHORT=0
SSH_CONNECT_TIMEOUT=10
SSH_SESSION_TIMEOUT=600
COLOR_OUTPUT=0
PARALLEL_SCAN=1
CONF
  # Apply any overrides
  local -- kv
  for kv in "$@"; do
    local -- key="${kv%%=*}"
    local -- val="${kv#*=}"
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
  done
  chmod 600 "$CONFIG_FILE"
}
