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
#   5. Where actions run is decided by the default platform's own key: with
#      only the host platform's `[komira_re]` key set, the one execution
#      platform is remote; with only ANOTHER platform's key set, it is the
#      local one and nothing fails. (No key at all is local_default.sh's.)
#   6. The limits (tools/build/platforms/limits.tsv, limits_retired.sh): the
#      real tree passes; a limit with no marker, a marker with no row, a row
#      with no marker, and a row whose retiring PR has merged while its marker
#      remains are each refused (fixture trees; every real row's PR named as
#      merged turns the real tree red).
#   7. The table agrees with the tree: each registered row's golden_config_hash
#      is the configuration hash buck2 gives its platform, and the macOS row's
#      applets are those of tools/build/mojo/darwin/busybox.sh.
#   8. The linux-x86_64 golden (tools/build/tests/golden): its configuration
#      and the action hashes of the sample targets equal the committed file,
#      and a copy with one hex digit changed is refused (the check can fail).
#      A Linux x86_64 client only: it needs that execution platform.
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

# 5
case "$(uname -s) $(uname -m)" in
    "Linux x86_64") host_key=linux_x86_64_properties other_key=darwin_arm64_properties ;;
    "Darwin arm64") host_key=darwin_arm64_properties other_key=linux_x86_64_properties ;;
    *) host_key='' other_key='' ;;
esac
if [ -n "$host_key" ]; then
    EP=komira//tools/build/platforms/default:default
    # `execution=auto` and both keys stated: a user buckconfig forcing a mode, or an
    # inherited key, must not decide this check. The identity list is only
    # read for a macOS property set.
    MODE=(-c komira.execution=auto -c komira_re.darwin_macos_hosts=26.5-0123456789abcdef)
    if ! "$BUCK2" audit providers "${MODE[@]}" -c "komira_re.$host_key=pool=host-check" -c "komira_re.$other_key=" "$EP" > "$LOG/platform_ex_host.txt" 2>&1 ||
        [ "$(grep -c 'executor: Remote(' "$LOG/platform_ex_host.txt")" != 1 ] || grep -q 'executor: Local(' "$LOG/platform_ex_host.txt"; then
        fail "execution: with only [komira_re] $host_key set the platform is not the one remote one (see $LOG/platform_ex_host.txt)"
    elif ! "$BUCK2" audit providers "${MODE[@]}" -c "komira_re.$host_key=" -c "komira_re.$other_key=pool=other-check" "$EP" > "$LOG/platform_ex_other.txt" 2>&1 ||
        [ "$(grep -c 'executor: Local(' "$LOG/platform_ex_other.txt")" != 1 ] || grep -q 'executor: Remote(' "$LOG/platform_ex_other.txt"; then
        fail "execution: with only [komira_re] $other_key set (another platform's) the platform is not the one local one, or the build failed (see $LOG/platform_ex_other.txt)"
    else
        pass "execution: only the host platform's key ($host_key) selects remote; only another platform's key ($other_key) builds locally and does not fail"
    fi
fi

# 6
LIM=tools/build/tests/functional/platform_table/limits_retired.sh
if out=$(bash "$LIM" 2>&1); then
    pass "limits: $(echo "$out" | sed 's/^PASS  limits: //')"
else
    fail "limits: the real tree is refused: $out"
fi
FX="$LOG/limits_fx"
rm -rf "$FX"
mk_fx() { # tsv body, BUCK body
    rm -rf "$FX"
    mkdir -p "$FX/tools/build/platforms" "$FX/tools/build/tests/functional/platform_table" "$FX/pkg"
    printf 'id\tretired_by\treason\n%b' "$1" > "$FX/tools/build/platforms/limits.tsv"
    printf '%b' "$2" > "$FX/pkg/BUCK"
    cp "$LIM" "$FX/tools/build/tests/functional/platform_table/limits_retired.sh"
}
expect_limits() { # what, want-sentence, subjects-file-or-empty
    if [ -n "$3" ]; then got=$(bash "$FX/tools/build/tests/functional/platform_table/limits_retired.sh" --subjects "$3" 2>&1); else got=$(bash "$FX/tools/build/tests/functional/platform_table/limits_retired.sh" --subjects /dev/null 2>&1); fi
    rcx=$?
    if [ -z "$2" ]; then
        [ "$rcx" = 0 ] || fail "limits fixture ($1): refused a tree it should pass: $got"
    elif [ "$rcx" = 0 ] || ! printf '%s' "$got" | grep -qF "$2"; then
        fail "limits fixture ($1): not refused with \`$2\`: $got"
    fi
}
GOOD_TSV='a-limit\tnative-pr:4\tpkg/BUCK: x only\n'
GOOD_BUCK='t(\n    target_compatible_with = X,  # komira-limit:a-limit\n)\n'
mk_fx "$GOOD_TSV" "$GOOD_BUCK"; expect_limits "a declared limit whose PR has not merged" "" ""
mk_fx "$GOOD_TSV" "$GOOD_BUCK\nt(\n    target_compatible_with = Y,\n)\n"; expect_limits "a limit with no marker" "undeclared limit" ""
mk_fx "$GOOD_TSV" "$GOOD_BUCK# komira-limit:other-limit\n"; expect_limits "a marker with no row" "marker \`komira-limit:other-limit\`" ""
mk_fx "$GOOD_TSV" "t(\n)\n"; expect_limits "a row with no marker" "row \`a-limit\` has no marker" ""
printf 'build: a thing [native-pr:4]\n' > "$LOG/limits_subjects_merged"
printf 'build: a thing [native-pr:44]\nbuild: [native-pr:4b]\n' > "$LOG/limits_subjects_other"
mk_fx "$GOOD_TSV" "$GOOD_BUCK"; expect_limits "a limit whose retiring PR has merged" "limit \`a-limit\` is retired by native-pr:4, whose PR has merged" "$LOG/limits_subjects_merged"
mk_fx "$GOOD_TSV" "$GOOD_BUCK"; expect_limits "a subject naming a different PR (44, 4b) is not PR 4" "" "$LOG/limits_subjects_other"
mk_fx 'a-limit\tnever\tbecause\n' "$GOOD_BUCK"; expect_limits "never with no product reason" "needs a reason starting" ""
mk_fx "$GOOD_TSV$GOOD_TSV" "$GOOD_BUCK"; expect_limits "a duplicate row" "appears twice" ""
rm -rf "$FX"
# The real rows, each with its PR named as merged: every one that is not `never` must be refused.
all=$(awk -F'\t' '$2 ~ /^native-pr:/ {print "build: [" $2 "]"}' tools/build/platforms/limits.tsv | sort -u)
printf '%s\n' "$all" > "$LOG/limits_subjects_all"
want_n=$(awk -F'\t' '$2 ~ /^native-pr:/ {n++} END {print n + 0}' tools/build/platforms/limits.tsv)
got_n=$(bash "$LIM" --subjects "$LOG/limits_subjects_all" 2>&1 | grep -c '^FAIL  limits: limit `' || true)
if [ "$want_n" -gt 0 ] && [ "$got_n" = "$want_n" ]; then
    pass "limits: with every retiring PR named as merged, all $want_n retirable limits are refused (the check can fail)"
else
    fail "limits: with every retiring PR named as merged, $got_n of $want_n retirable limits were refused"
fi

# 7
table_val() { # row, field -> the string value in table.bzl
    awk -v row="    \"$1\": {" -v f="        \"$2\": " 'index($0, row) == 1 {on = 1; next} on && /^    },/ {on = 0} on && index($0, f) == 1 {sub(f, ""); gsub(/[",]/, ""); print; exit}' tools/build/platforms/table.bzl
}
bad=
for r in linux-x86_64 darwin-arm64; do
    want=$(table_val "$r" golden_config_hash)
    if ! "$BUCK2" cquery --target-platforms "komira//tools/build/platforms:$r" komira//tools/build/toolchains:conda_unpack > "$LOG/platform_hash_$r.txt" 2>&1 ||
        ! grep -qF "komira//tools/build/platforms:$r#$want" "$LOG/platform_hash_$r.txt"; then
        bad="$bad $r(table says ${want:-nothing}; see $LOG/platform_hash_$r.txt)"
    fi
done
if [ -n "$bad" ]; then
    fail "table: golden_config_hash differs from the configuration buck2 gives the platform:$bad"
else
    pass "table: golden_config_hash of linux-x86_64 and darwin-arm64 is the configuration hash buck2 gives each platform"
fi
dar_table=$(table_val darwin-arm64 applets | tr -d '[]' | tr ',' ' ' | xargs)
dar_sh=$(sed -n 's/^APPLETS="\(.*\)"$/\1/p' tools/build/mojo/darwin/busybox.sh)
if [ -n "$dar_sh" ] && [ "$dar_table" = "$dar_sh" ]; then
    pass "table: the darwin-arm64 applets are those of tools/build/mojo/darwin/busybox.sh"
else
    fail "table: darwin-arm64 applets [$dar_table] differ from busybox.sh's [$dar_sh]"
fi

# 8
if [ "$(uname -s) $(uname -m)" = "Linux x86_64" ]; then
    GOLD=tools/build/tests/golden/golden.sh
    if out=$(BUCK2="$BUCK2" bash "$GOLD" check 2>&1); then
        pass "${out#PASS  }"
    else
        fail "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
    fi
    # One digit of one sample's hash changed: the check must go red, naming it.
    awk '!done && $1 == "sample" { $2 = (substr($2, 1, 1) == "0" ? "1" : "0") substr($2, 2); done = 1 } { print }' tools/build/tests/golden/linux-x86_64.golden > "$LOG/golden_flipped"
    if cmp -s "$LOG/golden_flipped" tools/build/tests/golden/linux-x86_64.golden; then
        fail "golden: could not make a one-digit change to it"
    elif out=$(BUCK2="$BUCK2" bash "$GOLD" check "$LOG/golden_flipped" 2>&1); then
        fail "golden: a copy with one digit changed was accepted"
    elif ! printf '%s' "$out" | grep -qF 'komira//tools/build/examples:hello'; then
        fail "golden: a copy with one digit changed was refused without naming the sample: $out"
    else
        pass "golden: a copy with one hex digit of one sample's hash changed is refused, naming the sample"
    fi
fi

exit "$rc"
