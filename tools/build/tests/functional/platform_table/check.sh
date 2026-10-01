#!/usr/bin/env bash
# tools/build/tests/functional/platform_table/check.sh -- the platform table, the default
# target platform and the reserved row.
#
# usage: tools/build/tests/functional/platform_table/check.sh <log_dir>   (from the repo root; BUCK2 names
#        the buck2 binary). Prints PASS/FAIL lines; exits 1 if any failed.
#
#   1. Loading tests//functional/platform_table: runs the load-time cases of
#      cases.bzl: the committed table is complete, and a table missing a pin
#      (or any field), with a pending pin in a registered row, a malformed
#      sha256, a duplicate key or host, is refused naming the row and the pin;
#      each host_info() selects the right row or is refused with a reason.
#   2. komira//tools/build/platforms: declares a platform for each registered
#      row and the `host` default, and none for the reserved row (linux-arm64:
#      not a build key).
#   3. `host` is this client's own platform: on Linux x86_64 it is
#      linux-x86_64 and a target stating no --target-platforms is configured
#      for it; on macOS arm64 it is darwin-arm64; on any other host analysing
#      it fails, naming why.
#   4. `[komira_re] linux_arm64_properties`, the reserved row's key, is refused
#      naming the platform.
set -uo pipefail

LOG=${1:?usage: check.sh <log_dir>}
BUCK2=${BUCK2:-./buck2}
rc=0
pass() { echo "PASS  platform table: $1"; }
fail() { echo "FAIL  platform table: $1"; rc=1; }

# 1
if "$BUCK2" targets tests//functional/platform_table: > "$LOG/platform_table_cases.txt" 2>&1; then
    pass "the committed table is complete; the load-time cases of cases.bzl (a missing or pending pin, a bad sha256, a duplicate key or host, each host) hold"
else
    fail "tests//functional/platform_table: did not load (see $LOG/platform_table_cases.txt)"
fi

# 2
got=$("$BUCK2" targets komira//tools/build/platforms: 2> "$LOG/platform_targets.err" | sed 's/.*://' | grep -v '^doc_tree$' | LC_ALL=C sort | paste -sd' ' -)
if [ "$got" = "darwin-arm64 host linux-x86_64" ]; then
    pass "komira//tools/build/platforms: declares darwin-arm64, host and linux-x86_64, and no platform for the reserved linux-arm64"
else
    fail "komira//tools/build/platforms: declares [$got], want [darwin-arm64 host linux-x86_64] (see $LOG/platform_targets.err)"
fi

# 3
case "$(uname -s) $(uname -m)" in
    "Linux x86_64") want=linux-x86_64 ;;
    "Darwin arm64") want=darwin-arm64 ;;
    *) want= ;;
esac
if [ -n "$want" ]; then
    if ! "$BUCK2" audit providers komira//tools/build/platforms:host > "$LOG/platform_host.txt" 2>&1; then
        fail "host: analysis failed on $(uname -s) $(uname -m) (see $LOG/platform_host.txt)"
    elif ! grep -qE "label[=:] *\"?komira//tools/build/platforms:$want\"?" "$LOG/platform_host.txt" &&
        ! grep -qF "komira//tools/build/platforms:$want" "$LOG/platform_host.txt"; then
        fail "host: is not $want on $(uname -s) $(uname -m) (see $LOG/platform_host.txt)"
    elif ! "$BUCK2" cquery komira//tools/build/toolchains:conda_unpack > "$LOG/platform_default.txt" 2>&1 ||
        ! grep -qE "komira//tools/build/platforms:$want#[0-9a-f]+" "$LOG/platform_default.txt"; then
        fail "host: a target stating no --target-platforms is not configured for $want (see $LOG/platform_default.txt)"
    else
        pass "host: this $(uname -s) $(uname -m) client's default target platform is $want"
    fi
else
    if "$BUCK2" audit providers komira//tools/build/platforms:host > "$LOG/platform_host.txt" 2>&1; then
        fail "host: analysed on $(uname -s) $(uname -m), which no row matches (see $LOG/platform_host.txt)"
    elif ! grep -qE 'no platform row matches this host|reserves a row' "$LOG/platform_host.txt"; then
        fail "host: refused on $(uname -s) $(uname -m) without saying why (see $LOG/platform_host.txt)"
    else
        pass "host: no row matches this $(uname -s) $(uname -m) client, and the default platform refuses, naming why"
    fi
fi

# 4
if "$BUCK2" audit providers -c komira_re.linux_arm64_properties=pool=reserved-check komira//tools/build/platforms/default:default > "$LOG/platform_reserved.txt" 2>&1; then
    fail "reserved: [komira_re] linux_arm64_properties was accepted (see $LOG/platform_reserved.txt)"
elif ! grep -qF 'is reserved for the linux-arm64 platform' "$LOG/platform_reserved.txt"; then
    fail "reserved: [komira_re] linux_arm64_properties was refused without naming linux-arm64 (see $LOG/platform_reserved.txt)"
else
    pass "reserved: [komira_re] linux_arm64_properties is refused, naming the linux-arm64 platform"
fi

exit "$rc"
