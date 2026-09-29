# shellcheck shell=bash
# proto_checks.sh -- check 23, mojo_proto_library. Sourced by run_checks.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT and $uncached it
# uses.

# 23. mojo_proto_library: generated Mojo compiled into a package and used by
#     tests. The generated code follows the .proto: the renamed field shows
#     up in the generated struct, and the test written for the original name
#     fails to compile against it. A .proto whose messages refer to an
#     imported file's messages compiles only with that file generated into
#     the same package (bundle_proto_deps).
if "$BUCK2" test checks//proto:test_person checks//proto:test_team > "$LOG/proto_tests.log" 2>&1 &&
    [ "$(grep -c 'Pass: checks//proto:test_' "$LOG/proto_tests.log")" = 2 ]; then
    pass "proto: generated packages pass test_person and test_team"
else
    fail "proto: generated package tests (see $LOG/proto_tests.log)"
fi
check_executor proto_tests
if ! "$BUCK2" build 'checks//proto:person_proto[person.mojo]' --out "$LOG/person.mojo" > "$LOG/proto_gen.log" 2>&1 ||
    ! "$BUCK2" build 'checks//proto:person_renamed_proto[person.mojo]' --out "$LOG/person_renamed.mojo" >> "$LOG/proto_gen.log" 2>&1; then
    fail "proto: generating person.mojo (see $LOG/proto_gen.log)"
elif grep -q 'var id: Int64' "$LOG/person.mojo" && ! grep -q 'var ident:' "$LOG/person.mojo" &&
    grep -q 'var ident: Int64' "$LOG/person_renamed.mojo" && ! grep -q 'var id:' "$LOG/person_renamed.mojo"; then
    pass "proto: the generated struct follows the .proto (id vs ident)"
else
    fail "proto: generated person.mojo does not follow its .proto (see $LOG/person.mojo, $LOG/person_renamed.mojo)"
fi
expect_red proto_mismatch "'Person' value has no attribute 'id'" checks//proto:test_person_renamed
expect_red proto_unbundled "unable to locate module 'person'" checks//proto:team_unbundled_proto

# 23, determinism. Generation is deterministic: two uncached builds (an
#     isolated daemon, its buck-out cleaned, --no-remote-cache, so the plugin
#     is compiled and run again) produce the same bytes for the plugin, the
#     generated sources and the compiled package. Each build must have run
#     the plugin's rustc and the generation (remotely, or locally in a
#     local-only run), or the comparison
#     proves nothing. About 16 minutes; skipped with --no-uncached.
DET=komira_checks_det
# An action that really ran, not a cache hit: `re(...)` remotely, `local` in a local-only run.
if [ "${MODE:?set by run_checks.sh}" = local ]; then EXEC_RAN_RE='^local'; else EXEC_RAN_RE='^re\('; fi
DET_TARGETS=(komira//tools/build/proto-codegen:protoc-gen-mojo 'checks//proto:person_proto[gen]'
    'checks//proto:team_proto[gen]' checks//proto:person_proto)
det_build() { # run number; prints a reason on failure
    if ! "$BUCK2" --isolation-dir "$DET" clean > "$LOG/det_clean$1.log" 2>&1; then
        echo "cannot clean the isolated buck-out (see $LOG/det_clean$1.log)"
    elif ! timeout 1500 "$BUCK2" --isolation-dir "$DET" build --no-remote-cache --materializations all \
        --show-full-output "${DET_TARGETS[@]}" > "$LOG/det$1.out" 2> "$LOG/det$1.log"; then
        echo "uncached build $1 failed (see $LOG/det$1.log)"
    elif ! "$BUCK2" --isolation-dir "$DET" log what-ran > "$LOG/det$1.what_ran.txt" 2>&1; then
        echo "cannot read what-ran of build $1"
    elif [ "$(awk -F'\t' -v re="${EXEC_RAN_RE:?}" '$3 ~ re && $2 ~ /\(rustc protoc_gen_mojo\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" = 0 ] ||
        [ "$(awk -F'\t' -v re="$EXEC_RAN_RE" '$3 ~ re && $2 ~ /\(mojo_proto_gen\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" -lt 2 ]; then
        echo "build $1 did not run the plugin compile and both generations (${MODE:?} execution; see $LOG/det$1.what_ran.txt)"
    else
        awk '{print $2}' "$LOG/det$1.out" | while read -r p; do find -L "$p" -type f; done |
            sort | xargs sha256sum > "$LOG/det$1.sha"
    fi
}
if [ "${uncached:?set by run_checks.sh}" != 1 ]; then
    echo "SKIP  proto determinism (--no-uncached)"
elif ! why=$(det_build 1) || [ -n "$why" ]; then
    fail "proto determinism: $why"
elif ! why=$(det_build 2) || [ -n "$why" ]; then
    fail "proto determinism: $why"
elif [ "$(wc -l < "$LOG/det1.sha")" -lt 6 ]; then
    fail "proto determinism: only $(wc -l < "$LOG/det1.sha") output files to compare (see $LOG/det1.sha)"
elif ! diff "$LOG/det1.sha" "$LOG/det2.sha" > "$LOG/det.diff"; then
    fail "proto determinism: outputs differ between two uncached builds: $(grep -c '^<' "$LOG/det.diff") file(s) (see $LOG/det.diff)"
else
    pass "proto determinism: $(wc -l < "$LOG/det1.sha") output files identical across two uncached builds"
fi
"$BUCK2" --isolation-dir "$DET" kill > /dev/null 2>&1
