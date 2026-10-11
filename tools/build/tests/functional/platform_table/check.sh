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
