# lhssh Critical-Analysis Report

**Target:** `/ai/scripts/lhssh/lhssh` (v2.0.0, 722 lines)
**Date:** 2026-06-03
**Method:** Multi-agent adversarial review — 6 dimensions (correctness, security, network, BCS-style, design-UX, robustness), each finding verified by 2 independent skeptics; confirmed on majority vote. 35 raw findings → 32 confirmed → deduplicated to **14 unique issues** + 7 completeness gaps.

## Overall Health Verdict

The script is well-structured and idiomatic (consistent logging, traps, typed locals, BCS-style conventions), but it carries one genuinely dangerous time-bomb (`ping6 -W` unit error causing ~2.7-hour hangs) and a cluster of input-handling defects where the documented contract and the code disagree — most notably the combined-short-option splitter silently corrupting GNU-style attached arguments, which the project's own `CLAUDE.md` explicitly forbids. The advertised IPv6 host-blocking feature is entirely non-functional, and the `nft` blocking that *does* run uses the wrong hook (`forward`) so it gives users a false sense of having blocked a LAN device.

---

## Top Risks (shortlist)

1. **`ping6 -W` is fed milliseconds but the flag is seconds** — `lhssh -6` hangs for ~2.7 hours (per probe, ~5.5h with `-c 2`) on a quiet IPv6 segment. (`lhssh:300-301`)
2. **`nft` block uses `hook forward`** — `-K` reports success but does NOT block traffic *to this host*; users get a false sense of security. (`lhssh:445`)
3. **IPv6 blocking is fully broken** — `validate_ip` accepts IPv6, but `kill_host` emits IPv4-only `ip saddr`, which `nft` rejects every time. (`lhssh:455-460`)
4. **Combined-short-option splitter mangles attached args** — `-n10.0.0.`, `-b50`, `-uroot` silently become `-10.0.0.`, `-50`, `-root`; violates the documented invariant. (`lhssh:664`)
5. **Config is `source`d from a non-root-writable path** (`/usr/local/etc`, owned by uid 1000 here) — arbitrary code execution as any user who later runs `lhssh`. (`lhssh:256-272`)

---

## Critical

*No issues rise to Critical. The config-sourcing issue (below) is the closest, but its exploitability depends on a non-default directory-ownership condition rather than the shipped code path alone.*

---

## High

### H1. `ping6 -W` is given milliseconds but the option expects seconds (1000× too large) — IPv6 scan hangs for hours
**Location:** `lhssh:300-301` (`discover_ipv6_neighbors`)
**Merged from:** correctness, network, bcs-style, robustness dimensions (4 reports, same defect).

```bash
local -i timeout_ms=$((SSH_CONNECT_TIMEOUT * 1000))
ping6 -c 2 -W "$timeout_ms" "ff02::1%${iface}" 2>/dev/null \
```

**Problem.** iputils `ping`/`ping6 -W` is the response-wait timeout **in seconds**, not milliseconds. Verified on this host: `man ping` states *"Time to wait for a response, in seconds"*, and `/usr/bin/ping6` is a symlink to `/usr/bin/ping`. With the default `SSH_CONNECT_TIMEOUT=10`, the code passes `-W 10000`, i.e. a 10000-second (~2.7 hour) wait. The variable name `timeout_ms` reflects the unit confusion. The man page notes `-W` only governs behaviour *in absence of responses*, so the bug is masked whenever any node replies — it triggers precisely on a quiet/empty/firewalled segment or a wrong interface, exactly when the timeout is supposed to protect the user.

**Impact.** `lhssh -6` against a link with no responsive IPv6 hosts blocks for up to ~10000s per probe (≈5.5h across `-c 2`) with a frozen terminal; Ctrl+C is the only escape. The config comment at `lhssh:228` claims `SSH_CONNECT_TIMEOUT` "also controls IPv6 ping timeout" — the effective value is 1000× the documented one.

**Fix.** Pass seconds directly and drop the multiplier and the misnamed variable:
```bash
ping6 -c 2 -W "$SSH_CONNECT_TIMEOUT" "ff02::1%${iface}" 2>/dev/null
```
Better still, wrap the discovery in `timeout` as a hard ceiling and cap the per-probe wait to 1–2s (LAN multicast neighbor replies are near-instant).

---

### H2. `nft` block uses the `forward` hook, which never sees traffic destined to the local host
**Location:** `lhssh:445` (`nft_ensure_chain`), `lhssh:460` (`kill_host`)

```bash
sudo nft add chain inet "$NFT_TABLE" "$NFT_CHAIN" '{ type filter hook forward priority 0; policy accept; }'
```

**Problem.** Per the `nft` man page (verified on this host), the `forward` hook processes only *"Packets forwarded to a different host"* — i.e. routed **through** this box. Packets destined to a local socket (this host's SSH, etc.) traverse the `input` hook, never `forward`. The documented use case (`lhssh.md`: "Block rogue devices"; help text: "Block an IP address") is about protecting *this* machine, but on a normal dev/desktop that is not the LAN gateway, a drop rule in the `forward` chain has zero effect on the rogue device reaching this host.

**Impact.** `lhssh -K 192.168.1.99` reports "Blocked …" and the rule shows up in `lhssh -L`, but the rogue device's traffic to this host is unaffected. Users get a **false sense of security** — arguably the worst failure mode for a security feature, since it silently does nothing.

**Fix.** Use `hook input` to protect this host (or create both `input` and `forward` chains if gateway protection is also wanted). For true LAN-device isolation, a `prerouting`/`ingress` drop is more appropriate. If `forward` is intentional, document loudly that `-K` only affects routed/forwarded traffic.

---

### H3. IPv6 host blocking is non-functional: `kill_host` emits IPv4-only `ip saddr` for IPv6 addresses that `validate_ip` accepts
**Location:** `lhssh:455-460` (`kill_host`), `lhssh:468-492` (`unkill_host`), `lhssh:495-511` (`list_killed`); cf. `validate_ip` `lhssh:426-438`
**Merged from:** correctness, network, bcs-style dimensions (3 reports).

```bash
if sudo nft add rule inet "$NFT_TABLE" "$NFT_CHAIN" ip saddr "$ip" drop; then
```

**Problem.** `validate_ip` has a dedicated IPv6 branch (`[[ $ip =~ : ]]`) that accepts addresses with an optional `%zone` suffix, so an IPv6 argument passes validation and reaches the rule builder. But `kill_host` unconditionally emits `ip saddr`, the IPv4 match for an `inet` table. In nftables an IPv6 address requires `ip6 saddr`; `nft add rule inet lhssh blocked ip saddr fe80::1 drop` fails with an address-family error, and the zone-id form (`fe80::1%enp12s0`) is a hard syntax error. The `grep "saddr $ip "` dedup/unkill/list paths are only self-consistent with the broken IPv4-only rules.

**Impact.** `lhssh -K fe80::abcd%enp12s0` (or any IPv6) passes validation, invokes `sudo nft`, needlessly creates the table/chain, then always fails with "Failed to block". IPv6 blocking is advertised but never works; unkill/list of IPv6 are correspondingly broken.

**Fix.** Detect family from the address (presence of `:`) in `kill_host`/`unkill_host` and the dedup/list `grep`s; emit `ip6 saddr` for IPv6, `ip saddr` for IPv4. Strip the `%zone` suffix before the `nft` match (nft does not accept it in a `saddr` match — without stripping, link-local blocks cannot be expressed at all). If IPv6 blocking is out of scope, reject IPv6 explicitly on the kill/unkill path.

---

### H4. Config files are `source`d from non-root-writable search-path dirs → arbitrary code execution
**Location:** `lhssh:256-272` (`load_config`)

```bash
/usr/local/etc/"$SCRIPT_NAME"/"$SCRIPT_NAME".conf
/usr/share/"$SCRIPT_NAME"/"$SCRIPT_NAME".conf
/usr/lib/"$SCRIPT_NAME"/"$SCRIPT_NAME".conf
...
source "$conf_file" || { log_error ...; return 1; }
```

**Problem.** `load_config` `source`s the first existing config from a list that includes `/usr/local/etc`, `/usr/share`, and `/usr/lib`. Sourcing runs the file as bash in the caller's context, so any top-level command or redefined function executes with the invoking user's privileges. **Verified on this host:** `/usr/local/etc` is `drwxr-xr-x sysadmin sysadmin` (uid 1000, non-root). A non-root user can therefore plant `/usr/local/etc/lhssh/lhssh.conf` and have it executed by anyone who later runs `lhssh`. Because `-K`/`-U` use `sudo`, a planted config can also redefine `kill_host`/`nft_ensure_chain` or simply run `sudo nft flush ruleset` at source time.

**Impact.** Privilege escalation / code execution on any system where one of these search dirs is writable by an unprivileged account (true here). This is shipped behaviour, not a contrived edge case — though it requires the local directory-ownership precondition to be exploitable, which is why it sits at High rather than Critical.

**Fix.** Don't blindly `source`. Preferred: parse config as a `KEY=VALUE` whitelist (`grep`/`read` into known variables) so no code in the file can run. At minimum, before sourcing, verify each file is root-owned (or owned by the invoking user for the XDG path) and not group/other-writable (`stat -c '%u %a'`), and **drop `/usr/local/etc`, `/usr/share`, `/usr/lib`** from the user-config list — these are package/data dirs, not per-user config.

---

## Medium

### M1. Argument-taking flags are in the combined-short-option character class, silently corrupting GNU-style attached values
**Location:** `lhssh:664` (`main`)
**Merged from:** correctness, network, bcs-style, design-ux dimensions (4 reports — the single most-reported defect).

```bash
-[hVvqspHCleSnbfutT6]?*) set -- "${1:0:2}" "-${1:2}" "${@:2}"
  continue
  ;;
```

**Problem.** The re-expansion class includes the argument-taking flags `n b f u t T`. The splitter peels the first two chars and re-prefixes the remainder with `-`, so for a value-flag the attached value arrives with a spurious leading `-`. The project `CLAUDE.md` explicitly states: *"Only boolean flags are in the character class; argument-taking flags (`-n`, `-I`, `-P`, etc.) are excluded."* The code contradicts its own documented contract. **Verified:** `-n10.0.0.` re-expands to `-n` + `-10.0.0.`; `-b50` → START `-50`; `-uroot` → username `-root`. No error is raised — these are then consumed with no validation.

**Impact.** Standard `getopt`-style bundled arguments silently produce garbage: `lhssh -n10.0.0.` scans the bogus prefix `-10.0.0.x` and finds nothing; `lhssh -b50 -f60` scans from octet `-50`; `lhssh -uroot host cmd` connects as user `-root`. Users get silently wrong scans/connections.

**Fix.** Reduce the class to true booleans only — e.g. `-[hVvqspHCleS6]?*` (add `K`/`U`/`L` if those should bundle). Bundled value-flags then fall through to their own `require_arg` handling or the unknown-option branch. Optionally add explicit attached-value cases (`-n*) LOCALHOST_HEAD=${1#-n} …`) if attached forms are a desired feature.

---

### M2. No numeric validation on `-b`/`-f`/`-t`/`-T`: nounset crash, silent arithmetic eval, and a conditional command-injection surface
**Location:** `lhssh:603-622` (`main` `-b`/`-f`/`-t`/`-T` handlers)
**Merged from:** correctness, bcs-style, robustness dimensions (3 reports).

```bash
-b|--begin)
  require_arg "$@"; shift
  LOCALHOST_START_IP=$1
  ;;
```

**Problem.** The raw argument is assigned straight into a `declare -i` variable. Bash arithmetic-*evaluates* the RHS of an integer assignment, which means:
- **Crash:** a bareword like `abc` is treated as an unset variable reference; under `set -u` this aborts with `abc: unbound variable`, caught by the EXIT trap and mis-reported as the generic `[ERROR] Exit: General error` (exit 1). **Verified.**
- **Silent wrong value:** `-t 1+1` is silently evaluated to `2`; `-b -50` sets a negative octet that `generate_ip_list` happily loops from. **Verified.**
- **Conditional code execution:** an array-index payload such as `-t 'args[$(touch /tmp/PWNED)]'` executes the command substitution **provided the array base name is already in scope**. **Verified:** in `main()`'s scope the local arrays `args` and `ssh_command` exist (declared empty), so `args[$(…)]` satisfies `set -u` and the `$(…)` runs. (Bare-identifier payloads like `$(cmd)` alone are blocked by `set -u`.) This is a *self-inflicted / config-injection* surface, not a remote one — it requires the attacker to control the CLI args or config — which is why it is Medium, not High.

**Impact.** No clean diagnostic for malformed numeric input; silent acceptance of negatives and arithmetic; and a real (if narrow) arithmetic-eval injection path reachable when option values come from an untrusted config or wrapper.

**Fix.** Validate before assigning, into a string first:
```bash
-b|--begin)
  require_arg "$@"; shift
  [[ $1 =~ ^[0-9]+$ ]] || { log_error "-b expects a number, got ${1@Q}"; return 9; }
  ((10#$1 >= 1 && 10#$1 <= 254)) || { log_error "-b out of range: ${1@Q}"; return 9; }
  LOCALHOST_START_IP=$((10#$1))
  ;;
```
Apply to `-b`, `-f` (octets 1–254) and `-t`, `-T` (positive integers). Use the already-defined-but-dead code `9` (*Value out of range*) / `22`.

---

### M3. `--` terminator before the target silently triggers a network scan and discards target + command
**Location:** `lhssh:657-660` (the `--` branch) and `lhssh:681-686` (action dispatch)

```bash
--)
  shift
  ssh_command=("$@")
  break
  ;;
```

**Problem.** Action dispatch keys off the `args` array (bare positional tokens), but the `--` branch populates only `ssh_command` and breaks without recording any target in `args`. When `--` precedes the target, `args` stays empty, `((${#args[@]}))` is false, `action` remains `scan`, and the populated `ssh_command` is never used. **Verified:** `main -- 152 uptime` → `action=scan`, target none, `ssh_command=(152 uptime)`.

**Impact.** `lhssh -- 152 uptime` (a natural way to stop option parsing before the target) silently runs a full network scan instead of connecting to `192.168.1.152` and running `uptime`. Target and command are dropped with no warning.

**Fix.** After the `--` break, treat the first post-`--` token as the target. E.g. have the `--` branch push the first token into `args` and the rest into `ssh_command`, or make the action/target extraction consult `ssh_command` when `args` is empty.

---

### M4. `--quiet` makes `ssh` MORE verbose (inverted verbosity-to-ssh-flag mapping)
**Location:** `lhssh:538` (`ssh_connect`)
**Merged from:** bcs-style, design-ux dimensions (2 reports).

```bash
((VERBOSE==0)) || ssh_opts+=(-v)
```

**Problem.** `-v` is added whenever `VERBOSE != 0`. But `-q`/`--quiet` sets `VERBOSE=-1` (`lhssh:576`), which is non-zero, so quiet mode satisfies the `||` branch and appends `ssh -v`. **Verified:** with `VERBOSE=-1`, `ssh_opts` becomes `(-v)`.

**Impact.** `lhssh -q 152 cmd` floods stderr with OpenSSH `debug1/debug2` chatter — the exact opposite of "Disable all non-essential output". Any scripted use of `-q` for clean output is broken. Also note there is no `-vv` passthrough for `VERBOSE>=2`.

**Fix.** Gate on positive intent: `((VERBOSE > 0)) && ssh_opts+=(-v)`. Optionally scale (`-vv` for `VERBOSE >= 2`); treat `VERBOSE < 0` as never adding `-v`.

---

## Low

### L1. `validate_ip` accepts out-of-range / leading-zero IPv4 before handing it to `sudo nft`
**Location:** `lhssh:432` (`validate_ip`)
**Merged from:** security, robustness dimensions (2 reports).

```bash
elif [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  :
```

**Problem.** The IPv4 branch checks only dotted-quad *shape* — no per-octet 0–255 bound, accepts arbitrary digit runs and leading zeros. Accepts `999.999.999.999`, `256.0.0.1`, `01.02.03.04`, `0.0.0.0`. This is the sole gate before the value reaches `sudo nft … ip saddr "$ip" drop`. **Not a shell-injection escape** — the value is a single argv element and `nft` rejects malformed input — but the privileged-command gate is materially weaker than its name and security rationale imply.

**Impact.** Garbage like `lhssh -K 999.1.1.1` passes validation and reaches `sudo nft`, producing a raw nft parse error rather than a friendly lhssh diagnostic. The "strong validation gating sudo" assumption is false; don't rely on it as a security boundary.

**Fix.** Bound each octet 0–255 and reject leading zeros, e.g. `^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$`, or per-octet numeric check.

### L2. Leading-zero short octet (`08`/`09`) triggers an octal arithmetic error and bypasses the range check
**Location:** `lhssh:525` (`ssh_connect`)

```bash
if [[ ! "$target" =~ ^[0-9]+$ ]] || ((target < 1 || target > 254)); then
```

**Problem.** Bash treats a leading-zero literal as octal, so `08`/`09` are invalid octal and the `((…))` aborts. Because it's an `if` condition, errexit doesn't fire, but the failing condition reads as *false*, so the range guard is **skipped** and the raw value passes through. **Verified:** `lhssh 08 uptime` emits `lhssh: line 525: ((: 08: value too great for base (error token is "08")` to stderr, then builds `192.168.x.08`.

**Impact.** Range guard silently defeated for `08`/`09`; a confusing internal bash error leaks to the user; the resulting target fails resolution (exit 255).

**Fix.** Force base-10: `((10#$target < 1 || 10#$target > 254))`, and normalise before building the target: `target=$((10#$target))`.

### L3. IPv6 mode hard-depends on `ping6` and `ip`, neither declared nor capability-checked
**Location:** `lhssh:9-13` (dependency header), `lhssh:289` (`ip`), `lhssh:301` (`ping6`)

**Problem.** The dependency header never mentions `ping6` or `ip`, both invoked unconditionally in IPv6 mode. `ping6` is a legacy alias (here a symlink to `ping`) that many modern distros no longer ship; the portable form is `ping -6`. Unlike the IPv4 path (which probes `command -v ssh-keyscan`/`nc` and errors clearly), the IPv6 path has no capability check, and `2>/dev/null` + a `sort -u`-terminated pipeline (exit 0) swallows any failure.

**Impact.** On a system without `ping6`, `lhssh -6` reports "No SSH hosts found via IPv6" with no hint the tool is missing — failure misattributed to the network. Same swallowing if `ip` is absent in `detect_ipv6_interface`.

**Fix.** Use `ping -6` or detect (`command -v ping6 || ping -6`); add `ping`/iproute2 (`ip`) to the dependency list; guard the IPv6 path like the IPv4 path guards its scanners.

### L4. Missing-scan-tool error is swallowed by process substitution → "No SSH hosts found" instead of the real cause
**Location:** `lhssh:373-376` (`scan_hosts`), `lhssh:692-704` (`main` scan case)

```bash
readarray -t hosts < <(scan_hosts)
...
if ((${#hosts[@]} == 0)); then
```

**Problem.** When neither `ssh-keyscan` nor `nc` exists, `scan_hosts` logs and `return 1`, but it runs inside `< <(…)`, so its non-zero status reaches neither `readarray` nor `set -e`. `main` then sees zero hosts and reports "No SSH hosts found in range …", exit 0.

**Impact.** On a box lacking both scanners, the failure is misattributed to an empty network; consumers of `lhssh -p` (e.g. `lhssh-cmd`) can't distinguish "empty network" from "broken tooling".

**Fix.** Probe for scan tools in `main` before scanning and hard-fail non-zero; or capture `scan_hosts`'s status via a temp file / `PIPESTATUS` and distinguish tool-missing (exit 1) from empty result (exit 0).

### L5. Config sourcing only catches a failure on the file's *last* line → partially-broken configs silently half-apply
**Location:** `lhssh:262-272` (`load_config`)

```bash
source "$conf_file" || { log_error "Failed to load config file ${conf_file@Q}"; return 1; }
```

**Problem.** `source` returns the status of the *last* command in the file. A mid-file error (typo'd command, command-not-found, bad RHS) does not stop sourcing, and the final assignment succeeds, so the `||` guard never fires. The generated config even ships a `#!/bin/bash` shebang and `#fin`, encouraging users to treat it as a real script where mid-file errors matter.

**Impact.** A corrupted config (e.g. `LOCALHOST_HEAD = 192.168.1.` with stray spaces) is silently half-applied — a mix of defaults and partial config, no warning, hard to debug. (Compounds with H4: the right fix solves both.)

**Fix.** Don't rely on `source`'s last-command status. Use a key=value whitelist parser, or re-validate expected variables after sourcing, or source in a subshell with `set -e` and capture the status.

### L6. `-S`/`-e`/`-l` operate on whichever config layer was loaded, which may be a read-only system path
**Location:** `lhssh:269` (`CONFIG_FILE=$conf_file`), `lhssh:653-655` (`-S`), `lhssh:623-630` (`-l`/`-e`)

**Problem.** When a user config is found, `CONFIG_FILE` is reassigned to the matched search path — including `/usr/local/etc`, `/usr/share`, `/usr/lib`. `-S` then writes (chmod 600) to that path; `-e` opens it in `$EDITOR`. If the loaded config came from a system/package dir, `-S` either fails (permission denied) or, if writable, clobbers a shared file with `0600`.

**Impact.** `-S` ("Save current options") has a non-deterministic target from the user's perspective; users can't rely on it landing in their own XDG file.

**Fix.** Keep a separate, always-XDG save target distinct from the loaded-from path. `-S` always writes the XDG user config; `-l` shows the effective loaded file.

### L7. `load_config` runs before arg parsing, so `--help`/`--version`/`-L` create a config file as a side effect
**Location:** `lhssh:559` (`main`), `lhssh:274-275` (`load_config` → `create_config_file`)

**Problem.** `main` calls `load_config` before the argument loop; with no user config it falls through to `create_config_file`, which `mkdir -p`'s the XDG dir and writes a 0600 file — regardless of what the user asked for, including pure reads (`--help`, `--version`, `-L`, `-K`/`-U`).

**Impact.** `lhssh --version` on a fresh machine silently creates `~/.config/lhssh/lhssh.conf` — a surprising filesystem side effect for a read-only command. Also masks the real "no config yet" state from `-l`.

**Fix.** Defer `create_config_file` until an action that needs config (scan/connect), or only auto-create on `-S`/`-e`. Parse and return for `--help`/`--version` before touching config.

### L8. Help text for `-p`/`--supershort` contradicts actual IPv6 behaviour
**Location:** `lhssh:150` (`show_help`), `lhssh:394` (`format_output`)

**Problem.** Help says `-p` shows "only last octet". For IPv6, `format_output` only truncates to `${host##*.}` when `!is_ipv6`; otherwise it prints the full address (the config comment at `lhssh:226` already acknowledges this, but the user-facing help does not).

**Impact.** `lhssh -6 -p` returns full IPv6 addresses, not last octets, with no help explaining the difference.

**Fix.** Reword: `-p, --supershort   Show only last octet (IPv4); full address (IPv6)`.

### L9. `--quiet` does not suppress the unconditional "SSH Hosts Found:" banner
**Location:** `lhssh:408` (`format_output`), `lhssh:575-577` (`-q` handler)

```bash
>&2 echo 'SSH Hosts Found:'
```

**Problem.** `--quiet` (`VERBOSE=-1`) gates WARN/INFO/DEBUG, but this decorative banner in the default (non-short) output path is an ungated `>&2 echo`. **Verified** by code path. So quiet mode still emits it.

**Impact.** `lhssh -q` still prints "SSH Hosts Found:" to stderr, contradicting "disable all non-essential output".

**Fix.** Route through `log_info`, or gate: `((VERBOSE >= 0)) && >&2 echo 'SSH Hosts Found:'`.

### L10. `timeout` exits 124/137 but `error_msg` has no entry; codes 8/9/24/25 are dead vocabulary
**Location:** `lhssh:97-116` (`error_msg`), `lhssh:545` (`ssh_connect` timeout), `lhssh:57` / `lhssh:432` (`require_arg`/`validate_ip` return 22)

**Problem.** GNU `timeout` exits 124 on timeout / 137 after `--kill-after`; neither is in the `error_msg` table, so a real session timeout reports "Unknown error (code: 124)". Meanwhile the table maps 24→"Operation timed out" and 8→"Required argument missing", but the script never returns 24 or 8 (it returns 22 for both missing-arg *and* invalid-value, plus 1/0/255/124/137 passthroughs). The curated table is out of sync with the codes actually emitted, and misfires on the one path (timeout) where it would matter most.

**Impact.** Users see "Unknown error (code: 124)" on a genuine session timeout instead of a timeout message; callers keying on exit codes can't distinguish "missing argument" (should be 8) from "bad value" (22, also from `validate_ip`).

**Fix.** Add 124 and 137 to `error_msg`; return 8 from `require_arg` and 9 from numeric validation (see M2) so the table's vocabulary is actually used — or drop the unused 8/9/24/25 entries to keep the table truthful.

---

## Nit

### N1. Documented legacy config path `~/.lhssh.conf` is never searched *(1/2 votes — lower confidence)*
**Location:** `lhssh:254-261` (`load_config` `search_paths`)

**Problem.** Both the enterprise rule and project `CLAUDE.md` describe the cascade as `~/.lhssh.conf` (legacy) → XDG → `/usr/local/etc/…`, but `search_paths` starts at the XDG path; `$HOME/.lhssh.conf` appears nowhere in the script. Either the docs are wrong or a search entry is missing. *(Noted at lower confidence — this finding carried only a 1/2 skeptic vote, and the resolution may be to fix the docs rather than the code.)*

**Impact.** A user who created `~/.lhssh.conf` per the docs has it silently ignored; lhssh creates a fresh XDG config from defaults, masking their customisations.

**Fix.** Make code and docs agree: either add `"$HOME/.lhssh.conf"` as the first legacy entry in `search_paths`, or drop the legacy path from all three `CLAUDE.md` descriptions and the enterprise rule.

---

## Cross-cutting note for the fix sprint

Several Low/Medium items share root fixes:
- **Numeric validation (M2 + L1 + L2)** — a single "validate-then-coerce, base-10, bounded" helper for octets/timeouts resolves the crash, the silent-eval, the injection surface, and the octal bypass, and lets you retire dead codes 8/9 (L10).
- **Config handling (H4 + L5 + L6 + L7)** — replacing `source` with a key=value whitelist parser and deferring/scoping auto-creation fixes the RCE, the half-apply, the save-target ambiguity, and the read-command side effect together.
- **Verbosity gating (M4 + L9)** — one consistent rule (`> 0` adds `-v`, `>= 0` shows banners, route decoration through `log_info`) fixes both quiet-mode defects.

---

## Completeness Review — areas the 14 findings MISSED

The findings above are strong on argument parsing, config sourcing, nft semantics, and IPv6 ping. A completeness critic re-read the full script and identified these additional gaps (file:line pointers; most reproduced directly). The test tree is 139/139 passing on the current source.

### GAP 1 (HIGH) — EXIT trap turns every nonzero remote command exit into a spurious lhssh "[ERROR]"
**`lhssh:118-129` (`cleanup` + trap), reached via `:545-546` / `:710`.**
`trap 'cleanup $?' ... EXIT` fires on normal exit. `cleanup` logs `log_error "Exit: $(error_msg "$exit_code")"` for any code except 0 and 255. In command mode (`lhssh 152 <cmd>`), `ssh`/`timeout` propagate the **remote command's** exit code. So `lhssh 152 grep foo /etc/x` (grep no-match → 1) prints `[ERROR] Exit: General error`; any remote failing command or `exit 2` gets a bogus lhssh error line stapled on; `timeout` exit 137 → `[ERROR] Exit: Unknown error (code: 137)`. This corrupts the documented core use case and pollutes `lhssh-cmd`'s per-host status. L10 noticed the table is out of sync; it missed that the trap fires `error_msg` on legitimate command-mode exit codes at all. **Fix:** in command mode, exit with the SSH/command status without routing through the error-logging trap (e.g. exempt the connect path, or only log for internal errors).

### GAP 2 (HIGH) — Entire host-blocking subsystem has ZERO automated test coverage
`validate_ip` (`:426`), `kill_host` (`:449`), `unkill_host` (`:468`), `list_killed` (`:495`), `nft_ensure_chain` (`:441`) — no `tests/*.bats` references them, nor `-K`/`-U`/`-L`. The suite is otherwise dense (81 unit + 24 cmd + 34 integration) and mocks `ssh-keyscan`/`nc`/`ping6`/`ip`/`getent`/`ssh`/`timeout`, but there is no `nft` mock and no test exercising the feature H2/H3/L1 declare broken. The most severe functional claims sit on a feature with no regression net. **Fix:** add an `nft` mock and bats coverage for the blocking paths.

### GAP 3 (MEDIUM) — `-n` prefix accepts malformed / non-`/24` input silently
**`lhssh:591-601`.** The CIDR branch keys only on `/24$`. `-n 10.0.0.0/16` → not `/24$` → plain branch → `LOCALHOST_HEAD='10.0.0.0/16.'` (garbage); `-n 10.0.0.5/24` → silently drops `.5`; `-n garbage` → `LOCALHOST_HEAD='garbage.'`. Help advertises "CIDR /24" but only literal `/24` works. No validation the prefix looks like an IPv4 prefix.

### GAP 4 (MEDIUM) — `ssh_connect` skips all validation when the target contains a dot
**`lhssh:519-530`.** The `elif [[ ! "$target" =~ \. ]]` guard means the octet 1–254 check and the IPv6 regex only run for dotless / colon-bearing targets. Anything with a dot — `999.999.999.999`, `10.0.0.5.6.7` — skips validation and is handed straight to `ssh user@<target>`. Not shell-injection (single argv element), but mirrors L1's "validation weaker than its name" on the connect path users type most.

### GAP 5 (MEDIUM) — `format_output` IPv4 sort hardcodes field 4
**`lhssh:387` (`sort -t. -k4 -n`).** With a 2- or 3-octet prefix (reachable via `-n 10.0.` or the `/24` stripping logic), addresses have fewer than 4 fields, so the numeric sort silently falls back to lexicographic (`10.0.5 / 10.0.50 / 10.0.9`). Output ordering wrong for any non-`a.b.c.` prefix.

### GAP 6 (MEDIUM) — `is_ipv6` decided from `$1` only, applied to the whole list
**`lhssh:380-381`.** `format_output` sets `is_ipv6` from the first argument and uses it for sort mode, column width, and supershort truncation of *every* element. A mixed/misordered list is formatted under one family for all rows. Minor in practice (single-family scans) but an unguarded assumption in a function the findings left unscrutinised.

### GAP 7 (LOW) — `-6I<iface>` attached form breaks (extends M1)
`-6Ieth0` → splitter peels `-6`, re-queues `-Ieth0`; `-I` is (correctly) excluded from the combined class, so `-Ieth0` matches neither `-I` exact nor the class and dies as "Unknown option". The spaced form `-6 -I eth0` works; the bundled form a user would naturally try fails.

### Checked and found SOUND
- Empty-array expansion `"${ssh_command[@]}"` / `"${args[@]:1}"` under `set -u` — safe (argc=0, no unbound error).
- Bare `-` routes to unknown-option, not mistaken for a target.
- `cleanup` does not double-fire: it runs `trap - SIGINT SIGTERM EXIT` first.
- No genuine race in the parallel scan path: `ssh-keyscan -f -` / `xargs -P 20` write independent lines piped to `sort -u`; no shared mutable file.

---

## Refuted findings (raised, then killed by skeptics — 0/2 votes)

| Finding | Location | Why refuted |
|---------|----------|-------------|
| nft `grep` uses `$ip` as unanchored regex (dots = wildcards) | `lhssh:455`, `:479-480` | Dotted IPs are structured; the trailing-space-anchored `grep` does not cause real mismatches in practice. |
| `EDITOR` invoked with word-splitting → arg injection | `lhssh:628` | `EDITOR` is user-controlled by definition; word-splitting an editor command is standard, not a vulnerability. |
| Color path breaks under `set -e` when `TERM` unset | `lhssh:48` | `tput colors &>/dev/null` is in an `if` test; failure is handled by the `else` branch, errexit does not fire. |

---

*Generated by a 6-dimension adversarial multi-agent review (78 agents). Each finding was independently verified by 2 skeptics and confirmed on majority vote. Severity reflects real-world impact, not theoretical reachability.*
