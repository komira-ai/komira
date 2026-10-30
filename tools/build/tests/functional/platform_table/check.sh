#!/usr/bin/env bash
# tools/build/tests/functional/platform_table/check.sh -- the platform table against the
# tree: its limits, its configuration hashes and applets, the linux-x86_64
# golden. (Its load-time cases, the platforms it declares, `host`, the
# reserved row's key and the key that decides remote execution are the
# scenarios //tools/build/selftest:analysis_refusals_platform_table and
# :exec_platforms.)
#
# usage: tools/build/tests/functional/platform_table/check.sh <log_dir>   (from the repo root; BUCK2 names
#        the buck2 binary). Prints PASS/FAIL lines; exits 1 if any failed.
#
#   1-5. (The scenarios named above; the legs keep their numbers.)
#   6. The limits (tools/build/platforms/limits.tsv): no row's retiring PR
#      has merged, by `limits_check merged` over the commit subjects of main
#      (origin/main, else HEAD), which no build action can read. The rest of
#      the limits check is the validation //:limits; the tool's unit tests
#      (tools/build/platforms/limits) hold every case of both modes.
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

# 6
ref=HEAD
git rev-parse --verify -q origin/main > /dev/null 2>&1 && ref=origin/main
if ! git log --format=%s "$ref" > "$LOG/limits_subjects" 2> "$LOG/limits_subjects.err"; then
    fail "limits: no git history to read the merged PRs from (see $LOG/limits_subjects.err)"
elif out=$("$BUCK2" run komira//tools/build/platforms/limits:limits_check -- merged --limits "$PWD/tools/build/platforms/limits.tsv" --subjects "$(cd "$LOG" && pwd)/limits_subjects" 2> "$LOG/limits_run.err"); then
    pass "limits: ${out#PASS  limits: }"
else
    fail "limits: $out (see $LOG/limits_run.err)"
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

# zig_dist unpacks the zig archive with `busybox tar`: both lists must carry tar, so a
# macOS build that runs every action on a Mac can unpack its tools.
case " $dar_table " in
    *" tar "*) case " $dar_sh " in
        *" tar "*) pass "table: tar is an applet of the darwin-arm64 row and of busybox.sh (zig_dist's unpack)" ;;
        *) fail "busybox.sh: APPLETS has no tar, which zig_dist's unpack runs" ;;
        esac ;;
    *) fail "table: the darwin-arm64 applets have no tar, which zig_dist's unpack runs" ;;
esac

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
