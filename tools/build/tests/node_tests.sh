# shellcheck shell=bash
# node_tests.sh -- test 54 (the hermetic Node.js rules' planted defects).
# Sourced by run_tests.sh, whose expect_red helper and $BUCK2 and $LOG it
# uses. What works is in src/tests/helpers/komira_test_node; what each target
# below plants is written above it in tools/build/tests/negative/node/BUCK.

N=tests//negative/node
# node_test's verdict: a failing script fails its target (with the script's
# own error shown), a wrong expected error and an unexpected pass fail too.
expect_red node_script_fails "the negative fixture fails its own assertion" "$N:script_fails"
expect_red node_error_not_on_stderr "failed, but its stderr does not hold: text the script never prints" "$N:error_not_on_stderr"
expect_red node_error_on_stdout "failed, but its stderr does not hold: printed on stdout only" "$N:error_on_stdout"
expect_red node_expected_fail_passed "exited 0; it was expected to fail with: any error" "$N:expected_fail_passed"
expect_red node_error_other_case "stderr does not hold: THE NEGATIVE FIXTURE FAILS ITS OWN ASSERTION" "$N:error_other_case"
expect_red node_error_as_pattern "stderr does not hold: negative fixture.fails" "$N:error_as_pattern"
# Analysis refuses an empty expect_error or exe, and what would stage two files
# at one path or one package twice.
expect_red node_expect_error_empty "$N:expect_error_empty: expect_error is empty" "$N:expect_error_empty"
expect_red node_exe_empty "$N:exe_empty: exe is empty" "$N:exe_empty"
expect_red node_src_listed_twice "$N:src_listed_twice: pass.js is listed twice" "$N:src_listed_twice"
expect_red node_data_is_source "$N:data_is_source: data destination pass.js is also a source" "$N:data_is_source"
expect_red node_data_is_package "$N:data_is_package: data destination node_modules/tslib is also a package of deps" "$N:data_is_package"
expect_red node_version_conflict "$N:version_conflict: tslib is pinned at 1.0.0 and at 2.0.0 in its deps" "$N:version_conflict"
expect_red node_bundle_listed_twice "$N:bundle_listed_twice: bundle/main.mjs is listed twice" "$N:bundle_listed_twice"
expect_red node_own_dep "$N:own_dep: tslib is in its own deps" "$N:own_dep"
# esbuild fails on an import it cannot resolve.
expect_red node_unresolved_import 'Could not resolve "./absent.mjs"' "$N:unresolved_import"
# The pins: npm_package's integrity, name, version and exe checks, node_dist's
# archive and version checks.
expect_red node_integrity_not_sha512 "npm_package: tslib: integrity sha256-AAAA is not sha512-<base64>" "$N:integrity_not_sha512"
expect_red node_integrity_empty "npm_package: tslib: integrity sha512- is not sha512-<base64>" "$N:integrity_empty"
expect_red node_integrity_not_leading "is not sha512-<base64>" "$N:integrity_not_leading"
expect_red node_integrity_differs "npm_package: tslib: the sha512 of" "$N:integrity_differs"
expect_red node_integrity_last_byte "npm_package: tslib: the sha512 of" "$N:integrity_last_byte"
# 64 zero bytes: 86 base64 "A"s and "==", 128 hex zeros.
expect_red node_integrity_repeated_rows "the pinned integrity sha512-$(printf '%086d' 0 | tr 0 A)== is $(printf '%0128d' 0)" "$N:integrity_repeated_rows"
expect_red node_no_package_json "holds no package/package.json" "$N:no_package_json"
expect_red node_name_differs "npm_package: tslib2: package.json of" "$N:name_differs"
expect_red node_name_differs_key 'does not state "name":"tslib2"' "$N:name_differs"
expect_red node_name_prefix 'does not state "name":"tsli"' "$N:name_prefix"
expect_red node_version_differs 'does not state "version":"2.8.0"' "$N:version_differs"
expect_red node_version_prefix 'does not state "version":"2.8"' "$N:version_prefix"
expect_red node_exe_does_not_run "npm_package: tslib: package.json does not run" "$N:exe_does_not_run"
# package.json is parsed: only its top-level name and version count, as strings.
expect_red node_name_nested 'does not state "name":"komira-fixture" at its top level; its top-level "name" is "komira-fixture-other"' "$N:name_nested"
expect_red node_name_absent 'does not state "name":"komira-fixture" at its top level; its top-level "name" is absent' "$N:name_absent"
expect_red node_version_nested 'does not state "version":"1.0.0" at its top level; its top-level "version" is "1.0.1"' "$N:version_nested"
expect_red node_version_number 'does not state "version":"1" at its top level; its top-level "version" is 1' "$N:version_number"
expect_red node_nested_distractors "npm_package: komira-fixture: package.json does not run" "$N:nested_distractors"
expect_red node_exe_other_version "npm_package: komira-fixture: bin/echo --version prints --version, the pin says 1.0.0" "$N:exe_other_version"
expect_red node_dist_version_differs "is v24.21.0, the pin says v24.20.0" "$N:version_differs_node"
expect_red node_dist_version_prefix "is v24.21.0, the pin says v24.21" "$N:version_prefix_node"
expect_red node_dist_version_suffix "is v24.21.0, the pin says v4.21.0" "$N:version_suffix_node"
expect_red node_dist_not_node "holds no package/bin/node or package/include/node/node_api.h" "$N:not_node"
expect_red node_dist_no_bin_node "holds no node-x/bin/node or node-x/include/node/node_api.h" "$N:no_bin_node"
expect_red node_dist_no_header "holds no node-x/bin/node or node-x/include/node/node_api.h" "$N:no_header"
expect_red node_dist_header_is_dir "holds no node-x/bin/node or node-x/include/node/node_api.h" "$N:header_is_dir"
expect_red node_dist_not_executable "holds no node-x/bin/node or node-x/include/node/node_api.h" "$N:node_not_executable"
expect_red node_dist_does_not_run "/bin/node does not run" "$N:node_does_not_run"
# c_shared_lib compiles with -Wall -Werror.
expect_red node_c_warns "error: unused variable 'unused_on_purpose'" "$N:warns"
# The runtime is test-only: a package outside third_party/node/BUCK's
# _TEST_ONLY and _NEGATIVE (a subpackage of $N) cannot name it.
expect_red node_not_visible "\`komira//third_party/node:node\` is not visible to \`$N/visibility:node_not_visible\`" "$N/visibility:node_not_visible"
