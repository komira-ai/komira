# shellcheck shell=bash
# proto_tests.sh -- test 23, mojo_proto_library. Sourced by run_tests.sh,
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
if "$BUCK2" test tests//functional/proto:test_person tests//functional/proto:test_team tests//functional/proto:test_tasks_db \
    > "$LOG/proto_tests.log" 2>&1 &&
    [ "$(grep -c 'Pass: tests//functional/proto:test_' "$LOG/proto_tests.log")" = 3 ]; then
    pass "proto: generated packages pass test_person, test_team and test_tasks_db"
else
    fail "proto: generated package tests (see $LOG/proto_tests.log)"
fi
check_executor proto_tests
if ! "$BUCK2" build 'tests//functional/proto:person_proto[person.mojo]' --out "$LOG/person.mojo" > "$LOG/proto_gen.log" 2>&1 ||
    ! "$BUCK2" build 'tests//negative/proto:person_renamed_proto[person.mojo]' --out "$LOG/person_renamed.mojo" >> "$LOG/proto_gen.log" 2>&1; then
    fail "proto: generating person.mojo (see $LOG/proto_gen.log)"
elif grep -q 'var id: Int64' "$LOG/person.mojo" && ! grep -q 'var ident:' "$LOG/person.mojo" &&
    grep -q 'var ident: Int64' "$LOG/person_renamed.mojo" && ! grep -q 'var id:' "$LOG/person_renamed.mojo"; then
    pass "proto: the generated struct follows the .proto (id vs ident)"
else
    fail "proto: generated person.mojo does not follow its .proto (see $LOG/person.mojo, $LOG/person_renamed.mojo)"
fi
expect_red proto_mismatch "'Person' value has no attribute 'id'" tests//negative/proto:test_person_renamed
expect_red proto_unbundled "unable to locate module 'person'" tests//negative/proto:team_unbundled_proto
expect_red proto_db_undeclared "protoc-gen-mojo_db wrote no code (or an empty file) for the expected note_db.mojo" \
    tests//negative/proto:tasks_db_wrong_outs
# bundle_only: roster.proto imports person.proto (used) and the db options
# (annotation only). The selected package holds exactly roster and person
# and compiles; bundling the whole closure also generates options.mojo, which
# the package cannot compile; a selection outside the closure is refused.
if ! "$BUCK2" build tests//functional/proto:roster_proto 'tests//functional/proto:roster_proto[gen]' --show-full-output \
    > "$LOG/proto_select.out" 2> "$LOG/proto_select.log"; then
    fail "proto: bundle_only package roster_proto (see $LOG/proto_select.log)"
elif got=$(ls -A "$(awk '/\[gen\]/{print $2}' "$LOG/proto_select.out")" | tr '\n' ' ') &&
    [ "$got" = "__init__.mojo person.mojo roster.mojo " ]; then
    pass "proto: bundle_only generates the selected files only"
else
    fail "proto: bundle_only package holds: ${got:-nothing} (see $LOG/proto_select.out)"
fi
expect_red proto_full_bundle "roster_proto/options.mojo" tests//negative/proto:roster_full_bundle
expect_red proto_bad_selection "which is not a .proto of the proto_deps closure" tests//negative/proto:roster_bad_selection

# 23, mojo_gcp_client (tools/build/cloud/gcp.bzl). Building the package builds
# each scoped client, which runs its welded tests (the generated layout probe
# among them), each gen_check (the generated files, what is absent, what is
# present) and each tests_check (exactly which welded tests passed). The
# refusals of the rule, and each check going red, are expect_reds. A
# `protocol = "grpc"` client with a service, compiled against the real
# komira_grpc and komira_gcp_core (komira//tools/build/proto-codegen/gcp_grpc),
# builds only once its welded test of the token hook and the status mapping
# passes; that client's gen_check and tests_check are in
# tests//functional/mojo_gcp_client, which is built next. A `protocol = "rest"`
# client of a service with no `google.api.default_host`
# (komira//tools/build/proto-codegen/gcp_rest) builds only once its welded test
# shows it refuses to send, before any dial, until a host is set.
expect_green gcp_grpc_client //tools/build/proto-codegen/gcp_grpc:
expect_green gcp_rest_client //tools/build/proto-codegen/gcp_rest:
if "$BUCK2" build tests//functional/mojo_gcp_client: > "$LOG/mojo_gcp_client.log" 2>&1; then
    pass "mojo_gcp_client: scoped clients, their welded tests, gen_check and tests_check"
else
    fail "mojo_gcp_client: tests//functional/mojo_gcp_client: (see $LOG/mojo_gcp_client.log)"
fi
expect_red gcp_client_unscoped 'neither `roots` nor `methods` is set' tests//negative/mojo_gcp_client:unscoped
expect_red gcp_client_joined_items 'is not a proto name' tests//negative/mojo_gcp_client:joined_items
expect_red gcp_client_no_runtime '`deps` is empty' tests//negative/mojo_gcp_client:no_runtime
expect_red gcp_client_whole_closure 'with an empty `bundle_only`' tests//negative/mojo_gcp_client:whole_closure
expect_red gcp_client_label_in_protos 'is not a source path of a `.proto` file' tests//negative/mojo_gcp_client:label_in_protos
expect_red gcp_client_omit_unknown_field 'message `.example.shop.v1.Item` has no field `colour`' tests//negative/mojo_gcp_client:omit_unknown_field
expect_red gcp_client_omit_pruned_field 'omit_fields: `example.shop.v1.ItemTombstone.name` is a field of `.example.shop.v1.ItemTombstone`, which this scope does not generate' tests//negative/mojo_gcp_client:omit_pruned_field
expect_red gcp_client_caller_test_red 'GATED TEST FAILED' tests//negative/mojo_gcp_client:caller_test_red
expect_red gcp_client_absence_check 'which must be absent' tests//negative/mojo_gcp_client:absence_check_can_fail
expect_red gcp_client_tests_check 'expected exactly:' tests//negative/mojo_gcp_client:tests_check_can_fail
expect_red gcp_client_unknown_protocol '`protocol` `connect` is not one of "rest", "grpc"' tests//negative/mojo_gcp_client:unknown_protocol
expect_red gcp_client_rest_reaches_plugin 'no `(google.api.http)` annotation' tests//negative/mojo_gcp_client:rest_reaches_plugin
expect_red gcp_client_rest_streaming_method 'method `WatchItems` is bidirectional-streaming' tests//negative/mojo_gcp_client:rest_streaming_method
expect_red gcp_client_module_names_stray 'which this target does not generate' tests//negative/mojo_gcp_client:module_names_stray
expect_red gcp_client_module_names_not_a_module 'is not a Mojo module name the generated package can hold' tests//negative/mojo_gcp_client:module_names_not_a_module
expect_red gcp_client_module_names_keyword 'gives `example/shop/v1/item.proto` the module `import`, which is not a Mojo module name the generated package can hold' tests//negative/mojo_gcp_client:module_names_keyword
expect_red gcp_client_module_names_unrenamed 'would be generated as module `thing.min`, which is not a Mojo module name: give it one in `module_names`' tests//negative/mojo_gcp_client:module_names_unrenamed_stem

# 23, protoc-gen-mojo's options and text goldens (tests//functional/proto_codegen):
# each case runs protoc over a corpus with one option string and holds the
# output to golden files, or protoc's error to the text the case states; the
# REST URL helpers of a generated client compile and pass their welded test.
expect_green proto_codegen tests//functional/proto_codegen:

# 23, proto_fixture_check (tools/build/mojo/proto_fixture.bzl): protoc reads
# wire fixtures in a build action. The self-test builds (a producer's
# non-canonical bytes, and proto_encode's output read back), and with it the
# welded proto_fixture_case targets (tools/build/mojo/proto_fixture_testdata),
# which the pull-request check runs. Here, end to end and only in this suite,
# each planted defect fails with the leg that names it.
expect_green proto_fixture tests//functional/proto_fixture:
expect_red proto_fixture_hex_odd "hex_odd: FIXTURE: hex_odd.hex holds an odd number of hex digits (3)" \
    tests//negative/proto_fixture:hex_odd
expect_red proto_fixture_leg0_duplicate "leg0_duplicate: LEG 0: leg0_duplicate.hex writes a singular field of example.fixture.v1.Sample more than once" \
    tests//negative/proto_fixture:leg0_duplicate
expect_red proto_fixture_leg0_duplicate_message "leg0_duplicate_message: LEG 0: leg0_duplicate_message.hex writes a singular field of example.fixture.v1.Sample more than once" \
    tests//negative/proto_fixture:leg0_duplicate_message
expect_red proto_fixture_leg0_identical "leg0_identical: LEG 0: leg0_identical.hex is byte for byte leg0_identical.canonical.hex" \
    tests//negative/proto_fixture:leg0_identical
expect_red proto_fixture_leg1 "leg1_value: LEG 1: protoc's decode of leg1_value.hex as example.fixture.v1.Sample differs from leg1_value.txtpb" \
    tests//negative/proto_fixture:leg1_value
expect_red proto_fixture_leg2 "leg2_unknown: LEG 2: leg2_unknown.hex carries field numbers example.fixture.v1.Sample does not declare" \
    tests//negative/proto_fixture:leg2_unknown
expect_red proto_fixture_leg2_nested "leg2_nested: LEG 2: leg2_nested.hex carries field numbers example.fixture.v1.Sample does not declare" \
    tests//negative/proto_fixture:leg2_nested
expect_red proto_fixture_leg2_group "leg2_group: LEG 2: leg2_group.hex carries field numbers example.fixture.v1.Sample does not declare" \
    tests//negative/proto_fixture:leg2_group
expect_red proto_fixture_leg3 "leg3_noncanonical: LEG 3: leg3_noncanonical.canonical.hex is not protoc's encoding of leg3_noncanonical.txtpb" \
    tests//negative/proto_fixture:leg3_noncanonical
expect_red proto_fixture_leg4 "leg4_root: LEG 4: leg4_root.txtpb names example.fixture.v1.Meters on its '# proto-message:' line, but the fixture is checked as example.fixture.v1.Feet" \
    tests//negative/proto_fixture:leg4_root
expect_red proto_fixture_leg5 "leg5_enum: LEG 5: leg5_enum.hex carries enum values the schema does not name" \
    tests//negative/proto_fixture:leg5_enum

# 23, determinism. Generation is deterministic: two uncached builds (an
#     isolated daemon, its buck-out cleaned, --no-remote-cache, so the plugin
#     is compiled and run again) produce the same bytes for the plugin, the
#     generated sources and the compiled package. Each build must have run
#     both plugins' rustc and every generation (remotely, or locally in a
#     local-only run), or the comparison proves nothing. About 16 minutes;
#     skipped with --no-uncached.
DET=komira_tests_det
# An action that really ran, not a cache hit: `re(...)` remotely, `local` in a local-only run.
if [ "${MODE:?set by run_tests.sh}" = local ]; then EXEC_RAN_RE='^local'; else EXEC_RAN_RE='^re\('; fi
DET_TARGETS=(komira//tools/build/proto-codegen:protoc-gen-mojo komira//tools/build/proto-codegen:protoc-gen-mojo-db
    'tests//functional/proto:person_proto[gen]' 'tests//functional/proto:team_proto[gen]' 'tests//functional/proto:tasks_db[gen]'
    tests//functional/proto:person_proto tests//functional/proto:tasks_db)
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
if [ "${uncached:?set by run_tests.sh}" != 1 ]; then
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
