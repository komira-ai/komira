# shellcheck shell=bash
# proto_checks.sh -- check 23, mojo_proto_library. Sourced by run_checks.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT and $uncached it
# uses.

# 23. mojo_proto_library: generated Mojo compiled into a package and used by
#     tests. The generated code follows the .proto: the renamed field shows
#     up in the generated struct, and the test written for the original name
#     fails to compile against it. A .proto whose messages refer to an
#     imported file's messages compiles only with that file generated into
#     the same package (bundle_proto_deps), and bundle_only generates part
#     of that closure. mojo_db_proto_library: protoc-gen-mojo-db's
#     DbStorable code for the table of tasks.proto passes test_tasks_db, and
#     a declared file the plugin does not write fails the generation.
if "$BUCK2" test checks//proto:test_person checks//proto:test_team checks//proto:test_tasks_db \
    > "$LOG/proto_tests.log" 2>&1 &&
    [ "$(grep -c 'Pass: checks//proto:test_' "$LOG/proto_tests.log")" = 3 ]; then
    pass "proto: generated packages pass test_person, test_team and test_tasks_db"
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
expect_red proto_db_undeclared "protoc-gen-mojo_db wrote no code (or an empty file) for the expected note_db.mojo" \
    checks//proto:tasks_db_wrong_outs
# bundle_only: roster.proto imports person.proto (used) and the db options
# (annotation only). The selected package holds exactly roster and person
# and compiles; bundling the whole closure also generates options.mojo, which
# the package cannot compile; a selection outside the closure is refused.
if ! "$BUCK2" build checks//proto:roster_proto 'checks//proto:roster_proto[gen]' --show-full-output \
    > "$LOG/proto_select.out" 2> "$LOG/proto_select.log"; then
    fail "proto: bundle_only package roster_proto (see $LOG/proto_select.log)"
elif got=$(ls -A "$(awk '/\[gen\]/{print $2}' "$LOG/proto_select.out")" | tr '\n' ' ') &&
    [ "$got" = "__init__.mojo person.mojo roster.mojo " ]; then
    pass "proto: bundle_only generates the selected files only"
else
    fail "proto: bundle_only package holds: ${got:-nothing} (see $LOG/proto_select.out)"
fi
expect_red proto_full_bundle "roster_proto/options.mojo" checks//proto:roster_full_bundle
expect_red proto_bad_selection "which is not a .proto of the proto_deps closure" checks//proto:roster_bad_selection

# 23, determinism. Generation is deterministic: two uncached builds (an
#     isolated daemon, its buck-out cleaned, --no-remote-cache, so the plugin
#     is compiled and run again) produce the same bytes for the plugin, the
#     generated sources and the compiled package. Each build must have run
#     both plugins' rustc and every generation (remotely, or locally in a
#     local-only run), or the comparison proves nothing. About 16 minutes;
#     skipped with --no-uncached.
DET=komira_checks_det
# An action that really ran, not a cache hit: `re(...)` remotely, `local` in a local-only run.
if [ "${MODE:?set by run_checks.sh}" = local ]; then EXEC_RAN_RE='^local'; else EXEC_RAN_RE='^re\('; fi
DET_TARGETS=(komira//tools/build/proto-codegen:protoc-gen-mojo komira//tools/build/proto-codegen:protoc-gen-mojo-db
    'checks//proto:person_proto[gen]' 'checks//proto:team_proto[gen]' 'checks//proto:tasks_db[gen]'
    checks//proto:person_proto checks//proto:tasks_db)
det_build() { # run number; prints a reason on failure
    if ! "$BUCK2" --isolation-dir "$DET" clean > "$LOG/det_clean$1.log" 2>&1; then
        echo "cannot clean the isolated buck-out (see $LOG/det_clean$1.log)"
    elif ! timeout 1500 "$BUCK2" --isolation-dir "$DET" build --no-remote-cache --materializations all \
        --show-full-output "${DET_TARGETS[@]}" > "$LOG/det$1.out" 2> "$LOG/det$1.log"; then
        echo "uncached build $1 failed (see $LOG/det$1.log)"
    elif ! "$BUCK2" --isolation-dir "$DET" log what-ran > "$LOG/det$1.what_ran.txt" 2>&1; then
        echo "cannot read what-ran of build $1"
    elif [ "$(awk -F'\t' -v re="${EXEC_RAN_RE:?}" '$3 ~ re && $2 ~ /\(rustc protoc_gen_mojo\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" = 0 ] ||
        [ "$(awk -F'\t' -v re="$EXEC_RAN_RE" '$3 ~ re && $2 ~ /\(rustc protoc_gen_mojo_db\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" = 0 ] ||
        [ "$(awk -F'\t' -v re="$EXEC_RAN_RE" '$3 ~ re && $2 ~ /\(mojo_proto_gen\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" -lt 2 ] ||
        [ "$(awk -F'\t' -v re="$EXEC_RAN_RE" '$3 ~ re && $2 ~ /\(mojo_db_proto_gen\)$/' "$LOG/det$1.what_ran.txt" | wc -l)" = 0 ]; then
        echo "build $1 did not run both plugin compiles and every generation (${MODE:?} execution; see $LOG/det$1.what_ran.txt)"
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
elif [ "$(wc -l < "$LOG/det1.sha")" -lt 10 ]; then
    fail "proto determinism: only $(wc -l < "$LOG/det1.sha") output files to compare (see $LOG/det1.sha)"
elif ! diff "$LOG/det1.sha" "$LOG/det2.sha" > "$LOG/det.diff"; then
    fail "proto determinism: outputs differ between two uncached builds: $(grep -c '^<' "$LOG/det.diff") file(s) (see $LOG/det.diff)"
else
    pass "proto determinism: $(wc -l < "$LOG/det1.sha") output files identical across two uncached builds"
fi
"$BUCK2" --isolation-dir "$DET" kill > /dev/null 2>&1
