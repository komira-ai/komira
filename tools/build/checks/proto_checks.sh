# proto_checks.sh -- check 23, mojo_proto_library. Sourced by run_checks.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT it uses.

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
check_remote proto_tests
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
