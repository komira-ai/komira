# Build self-tests: dissolving run_tests.sh

This is the design for replacing [tools/build/tests/run_tests.sh](../../tools/build/tests/run_tests.sh),
the files it sources, [tool_lib.sh](../../tools/build/tests/tool_lib.sh),
[golden.sh](../../tools/build/tests/golden/golden.sh) and
[lint_weld.sh](../../tools/build/tests/negative/lint_weld.sh). The build system's tooling is Zig, so its
tests are Zig too. The script is not ported as one runner with a table of cases. It is dissolved: each
check moves to the cheapest place that can still fail. This doc lists every check, says where it goes and
which planted defect proves it can go red. The conversion then lands in slices (the last section).

Status: design, nothing converted yet. Today the script runs nightly
([ci.md](../ci.md#build-system-self-tests)) and is not the gate.

## The three buckets

1. **A target.** A "this should build" check is an ordinary target in a unit that `pr / check`
   builds. When a check only reads built artifacts (an ELF, a report, a marker), it becomes an action
   that takes them as inputs. Then it runs on the farm and sits in the gate.
2. **A Zig unit test next to the tool.** A check of the form "our tool must refuse this input" feeds the
   tool a bad input and asserts the exit code and the message. It lives next to the tool's source. The
   form follows the repo's existing `zig_test` (`tools/build/mojo/toolchain.bzl`): `zig test` runs as a
   build action welded into the tool's `zig_exe` through `unit_tests`. That way `pr / check` runs it.
   A plain `buck2 test` target would not run, because the check only builds (see "Open decisions").
   A tool that is Rust (the proto-codegen plugin) or Mojo (covcheck) keeps its tests in its own
   language, next to it.
3. **A scenario.** This covers only what must drive buck2 from outside: what ran and where (local: 0),
   two-build determinism, consumer-cell clones, analysis-time and load-time refusals, builds that must
   go red, and client queries (`aquery`, `cquery`, `audit`, `log what-ran`). Each scenario is **one Zig
   test target**, named, runnable alone, under `//tools/build/selftest/`. They share one small helper
   library. One entry point runs them all: `buck2 test //tools/build/selftest/...`.

A fourth outcome is **delete**: the check repeats what `pr / check` already builds. Every converted check
has a planted mutant that turns it red, and each slice deletes its shell part in the same pull request.

"Already in the gate" has a precise meaning here. `pr / check` builds the derived units the change
reaches. Its universe is `//...` and `tests//functional/...` (`release/ci/derive_checks.py`); it is not
a whole `//...` build. It runs `buck2 test` only on targets outside `tests//`
(`release/ci/build_targets.sh`). It does not build sub-targets such as `[run_check]`. It never builds
`tests//negative`.

## Cross-cutting gaps (bucket 1 work that unblocks many rows)

- **`[run_check]` as a validation.** The `[run_check]` of `mojo_binary` and of `rust_binary`
  (`rust/defs.bzl`) is a sub-target only, so nothing in the gate runs it. Making it a `ValidationInfo`
  of every binary with `expected_stdout` puts rows 1, 21, 26, 22 and 35 in the gate.
  Mutant: change `:hello`'s `expected_stdout` to `hello from mojoX\n`. The unit must go red.
- **Green fixtures parked under `tests//negative`** move to `tests//functional`:
  `rust_test:bin_green`, `rust_test:env_scrubbed`, `test_weld/real:ok`, the external-test greens of 35.
- **`mojo_test` targets in `tests//functional`** are built but never run. Weld them as `test_srcs`
  (proto), or teach `build_targets.sh` to `buck2 test` them, or keep them in the `test_limits` scenario.
- **Sub-targets and `tests//negative`/`tests//src` greens** need a root alias that names them (like
  `//:tests_lints`). Plain `tests//functional` targets need no alias.
- **Report floors move into the action.** Today the client counts "ok" lines (watchdog >= 15,
  runner_cases >= 5, mem_cap >= 4, test_deadline >= 6). A count floor is the only guard against a
  case list that runs nothing. The action refuses a short report, and later each case becomes its own
  named Zig test.
- **A toolchains-cell file list.** The scans 17 tc_md and 19 exported_cells cover `tools/build/cells`.
  A komira-cell lint sees that directory only through a file-list target inside the toolchains cell, as
  `tests//:doc_tree` does for the tests cell. Without that target, the lint passes without reading the
  files.

## Scenario inventory

Bucket: `1` target, `2` Zig (or tool-language) unit test, `3` scenario, `del` delete, `open` needs a
ruling. Numbers are the test numbers in `run_tests.sh`. Scenario names are under `//tools/build/selftest:`.

### run_tests.sh, its own tests

| id | what | bucket | lands in | mutant |
|---|---|---|---|---|
| 1 examples | the example targets build | del | already in their units | a compile error in hello.mojo reds the unit |
| 1 run_checks | hello, hello_pkg_user, cadd_user print their expected_stdout | 1 | `[run_check]` as a validation | change hello's expected_stdout |
| 1 check_executor | every action of the run ran remotely or was a cache hit | 3 | `local_zero` (one what-ran scenario for every former `check_executor` call, with one `buck2 test` leg) | a hybrid executor that prefers local on one platform, so the action really runs locally; a run that executes nothing must fail too, not SKIP |
| 2 gate_red | a library whose welded test fails does not build: GATED TEST FAILED | 3 + 2 | `gate_wiring` case "library default output red"; gate runner unit test (exit, message) | `default_output = ungated` with MojoInfo still gated (scenario); runner exits 0 on a failing test (unit) |
| 2 gate_ungated_green, sharedlib_*_ungated | the `[ungated]` fixtures compile, so the red comes from the test | 3 | precondition inside `gate_wiring` / `shared_lib_gate` (could also be a functional target depending on the sub-target) | a compile error in the fixture fails the precondition |
| 2 gate_consumer_red | a binary on a red library fails | 3 | `gate_wiring` | the published .mojoc stops taking the PASS markers as inputs |
| 2 gate_bypass_refused | `[ungated]` in deps fails analysis | 3 | `analysis_refusals_mojo` | `[ungated]` returns MojoInfo |
| 2 sharedlib gate reds | missing export, unresolved symbol, failing driver, force_load, leaking symbols, duplicate definition | 3 | `shared_lib_gate` | drop the version script / `--exclude-libs`; drop `--whole-archive` |
| 2 sharedlib_empty_exports | empty exports refused at analysis | 3 | `analysis_refusals_mojo` | delete the empty-exports `fail()` |
| 3 missing_dep | a binary importing a package not in deps does not compile | 3 | `compile_isolation` | stage every package of the cell on `-I` |
| 4 closure_refusal | the compile wrapper refuses an incomplete toolchain closure | 2 | compile wrapper (Zig port) unit test: exit 2 and `REFUSING: toolchain member` (the shell checked only the text) | skip the closure check |
| 5 host_paths | no action argv or env names an absolute host path; scanner self-check on `/bin/sh` | open | `aquery_host_paths`, or a BXL check in the gate; scanner unit test in the helper lib | add `/usr/bin/env` to the mojo_build command |
| 6 outputs | hello has exactly `DT_RUNPATH $ORIGIN/lib`, no `buck-out/`, and first finds a NEEDED runtime library | 1 (proposed) | Zig ELF check tool run as a validation of hello, with unit tests over fixture ELFs, including one with no dynamic section | an absolute run path in the link |
| 7 umbrella_cache | consumer-cell clones hit the same cache digests | 3 | `consumer_cell_cache` | a root-cell-relative path in an action's argv |
| 8 host_floor | loader trace: libstdc++/libgcc_s from the toolchain, the rest glibc | 1 | Zig checker inside `functional/runtime_libs:loader_trace` | drop the toolchain lib dir from the run's library path |
| 8 runtime_libs | loaded toolchain libs equal `hello[runnable]/lib` | 1 | `functional/runtime_libs:runtime_libs_match` | add a library to `mojo_runtime`'s list |
| 8 runtime_run_paths | every run path in `hello[runnable]/lib` is `$ORIGIN`-relative, at least one read | 1 (proposed) | the ELF check tool of 6 | an unrewritten vendor DT_RPATH |
| 9 buck2_run | `buck2 run` from a fresh clone: greeting, downloads, relocatable | 3 | `buck2_run_fresh_clone` | RunInfo points outside run_dir |
| 10 exec_platforms | Mojo, toolchain and C targets resolve to linux-x86_64 | 3 | `exec_platforms` (one table with 20's C rows) | register a second platform first |
| 11 | retired; a comment | del | nothing | n/a |
| 12 action_platforms | an uncached build runs 7 categories with the farm property set | open | `action_properties` | an empty property set for one category |
| 13 bundle_parity | functional parity target builds | del | already in the gate | n/a |
| 14 launcher_levels | level_test; launcher level equals glibc's on the host | del + 1 | level_test stays; `level_vs_glibc` check action on a worker | launcher level one too high without AVX2 |
| 15 bundle | bundle layout and two-build determinism | 1 + open | layout in functional targets; `bundle_determinism` | a timestamp in the tarball |
| 16 formats | tarball/OCI content and determinism; `docker load` and `docker run` | 1 + 3 | functional checks; `docker_run` on the CI runner | drop mtime normalization in `oci/src/tar.zig` |
| 17 docs green | `//:docs`, doc_links:ok | del | already in the gate | n/a |
| 17 doc_links_dead | the link checker names missing file, bad anchor, escape, count | 2 | unit tests of doc_links (Mojo today; Zig if ported) | accept any `#fragment` |
| 17 doc_pkgs | every package is in `deps(//:docs)` | open | `docs_package_coverage`, or a BXL check in the gate | a rule that does not call declares_docs |
| 17 tc_md | `tools/build/cells` holds no Markdown | 1 | doc lint over the committed files, with the toolchains-cell file list | commit a NOTES.md there |
| 17 named_doc_tree | no BUCK file calls doc_tree/package_docs itself | 1 | Zig lint over committed BUCK files | add `doc_tree(name = "x")` |
| 17 package_boundary_exceptions | neither cell sets it | 1 | lint over the committed .buckconfig files | set it in the tests cell's .buckconfig |
| 18 config_hashes | the only configuration in hello's closure is the pinned hash | open | `config_hash_pin`, or a BXL check | add a constraint to the platform |
| 19 exported_cells | labels in exported BUCK/.bzl name only komira, prelude, toolchains (floor of 20) | 1 | Zig lint, with the toolchains-cell file list | a `tests//` label in mojo/defs.bzl |
| 21 location_path | `location_path:main[run_check]` | 1 | `[run_check]` as a validation | remove the staging-dir prefix map |
| 24 darwin | macOS registration, command lines, Mach-O | open | port with Linux or freeze | n/a |
| 25 local_default | a clone without farm config is local-only and refuses forced remote | 3 | `fresh_clone_local_default` (CI runner only: it builds locally by design) | pick a remote executor when the farm config is absent |
| 28 watchdog | cases build, no BAD, at least 15 ok | 1 | floor inside the action; later Zig supervisor tests | delete a case |
| 29 td_declared, test_deps, args_action | plain builds | del | already in the gate | n/a |
| 29 td_mojo_test(_args) | `buck2 test` of two mojo_tests passes | 1 | tested by the gate (move to the komira cell, or extend `build_targets.sh`) | drop test_env/data from the test info |
| 29 td_undeclared | an undeclared fixture is not staged | 3 | `compile_isolation` | stage the whole package as share/ |
| 29 td_skip_77 | exit 77 is red | 2 | gate runner unit test | treat 77 as pass |
| 29 td_env_bin(_lib) | `BIN=true` cannot replace a red test | 2 | gate runner unit test, BIN set through `--env` and in the process env | runner execs `$BIN` |
| 29 runner_cases | cases build, at least 5 ok | 1 | floor inside the action | reuse one TEST_TMPDIR |
| 29 td_bad_*, test_deps refusals | 7 analysis refusals | 3 | `analysis_refusals_mojo` | delete the shell-name check in test_runtime.bzl |
| 29 td_test_deps_src/consumer | a library and its consumer cannot import test_deps | 3 | `compile_isolation` | add test_deps to the compile path |
| 30 opt_level | per-kind `-O` levels from aquery | 3 | `aquery_opt_levels` | mojo_binary default `-O1` |
| 30 opt_bad_level | `fast` refused | 3 | `analysis_refusals_mojo` | remove the level check |
| 31 lint_weld (planted) | a planted shellcheck finding reds the Mojo and Rust examples | 3 | `lint_weld` (scratch tree) | drop one target from `_script_lint` |
| 31 lint_weld (lists) | the toolchains' lint lists are complete | 3 | `lint_weld` derives the scripts the rules run from the graph, independent of the lists (a shared constant cannot catch a drop) | drop `rust:shell_lint` from the Rust list |
| 32 bootstrap | `./buck2` installs only the pinned release, refuses wrong sha/size | 2 | unit tests of the bootstrap if it becomes Zig | skip the sha256 check |
| 33a install_gate | builds | del | already in the gate | n/a |
| 33a/b conda, conda_set | determinism, manifests, pixi install | 1 + 3 + open | manifest checks as targets; `conda_determinism`; install on CI | n/a |
| 33 client | the runner refuses a non Linux x86_64 client | 2 | helper lib client guard unit test | accept Darwin arm64 |
| 34 aws_codegen | green build; harness reds (golden, accepted, must_contain) | del + 2 | Zig checker replacing aws_codegen.sh, unit-tested on text | match must_contain as a substring |
| 35 rust_test_unit | marker reads `N passed`, N >= 1 | 2 | Rust test runner (Zig port) unit test | PASS on `0 passed` |
| 35 rust_test_compiles | the red fixture compiles | 3 | `gate_wiring` precondition | compile error in the fixture |
| 35 red, unwinds, bin_red, lib_consumer_red | a failing test reds test, binary, consumer; the panic unwound | 3 | `gate_wiring` | `-C panic=abort`; binary not on the marker |
| 35 bin_green, env_scrubbed | builds and runs; env is HOME/PATH/TMPDIR | 1 | move to `tests//functional/rust_test`, rust `[run_check]` as a validation | expected_stdout `hellX\n` |
| 35 empty, ignored | EMPTY GATE; ignored test refused | 2 | runner unit tests over captured real libtest output | accept `0 passed` |
| 35 hang | timed out after the fixture's 3 s | 2 + 3 | runner unit test (deadline, exit 142); `gate_wiring` case requiring `timed out after 3s` | runner uses the default timeout instead of `test_timeout_s` |
| 35 buck2_test | `buck2 test` of proto-codegen passes | del | already tested by the gate | n/a |
| 35 buck2_test_red | `buck2 test` of a binary on a red test fails | 3 | `gate_wiring` | TestInfo skips the welded test |
| 36 greens | AWS client targets build | del | already in the gate | n/a |
| 36 analysis refusals | 11 mojo_aws_client `fail()`s | 3 | `analysis_refusals_aws_client` | delete the duplicate-operation check |
| 36 unknown_operation | the generator refuses an unknown operation | 2 (Rust) | Rust unit test in `aws_in.rs`, if absent | skip unknown operations |
| 36 caller_test_red | a failing caller test reds the client | 3 | `gate_wiring` | leave caller tests out of the gate |
| 36 env scan reds | getenv, pathlib spellings, t-strings, control bytes | 2 (open) | unit tests of the env scanner once extracted from aws.bzl into a tool | stop joining continuation lines |
| 37 platform_table | load-time table cases, reserved row | 3 | `analysis_refusals_platform_table` | accept a pending pin |
| 38 readme_examples green | builds | del | already in the gate | n/a |
| 38 readme_marker | ok says PASS, none says NO EXAMPLE | 1 | check target over the two sub-target outputs | PASS without an example |
| 38 raises, skip_word, shipped_relative_link | readme tool findings | 2 | readme_examples tool unit tests | accept a `mojo skip` fence |
| 38 compile_error, unowned | README compile errors name `README.md:9` | 3 + 2 | `compile_isolation`; extractor unit test for the line marker | drop the line trailer; ignore `readme=False` |
| 38 owner_base_no_readme, readme_keyword | load refusals | 3 | `analysis_refusals_readme` | remove the bool check |
| 39 test_weld greens | the bxl passes | del + 1 | two already in the gate; move `real:ok` to functional | count a commented test_srcs |
| 39 test_weld planted reds | the checker names each ledger and weld defect | 2 | test_weld checker (Zig port) unit tests | let a row for a welded test pass |
| 39 test_weld_real_red | over the real rules, exactly 3 unwelded files named | open | `test_weld_real_graph`, or the BXL in the gate | read test_srcs from BUCK text |
| 40 readme_api_coverage | ledger reds | del + 2 | checker unit tests | accept a row for a used symbol |
| 42 pointer_lint | 31 planted sites and ledger defects | del + 2 | pointer lint (Zig port) unit tests | drop two-statement partial-move tracking |
| 42 no_tree/both | xor refused | 3 | `analysis_refusals_lint` (all five xor copies) | delete one of the five `fail()`s |
| 45 src_layout | 17 findings | del + 2 | src_layout lint unit tests | stop refusing `*_loopback` under src/ |
| 51 python_oracle | 6 analysis refusals | 3 | `analysis_refusals_python_oracle` | drop the third_party owner check |
| 52 mojo_doc_json | green; compile error | del + 3 | `compile_isolation` | ignore the doc action's exit status |
| 52 golden_differs, missing_symbol | doc JSON checker | 2 | doc JSON checker unit tests | walk only top-level symbols |
| 53 surface_capability_matrix | 19 reds, 5 the only finding | del + 2 | matrix checker unit tests, facts fed as input | refuse no longer-named package |
| 53 dangling, incompatible | unknown target; incompatible test under a pattern | 3 | `analysis_refusals_lint` (scratch tree, not an in-place copy) | make the deps soft |
| 55 refused_imports | 25 spellings | del + 2 | scanner unit tests | stop following continuations |
| 55 bad_entry | non-dotted entry refused | 3 | `analysis_refusals_lint` | drop the dotted-name check |
| order switches | `--no-run`, `--no-umbrella`, local SKIPs | del | each scenario runs alone | n/a |
| harness mode | local/remote mode detection | 2 | helper lib farm guard, unit-tested | accept a mixed list |
| harness silence | a sub-script that reports nothing, or SKIPs on CI, is red | 2 | helper lib: a scenario that executes nothing or asserts nothing fails | return early with no assertion |

### Sourced: assert_level, c_libs, cxx, coverage

| id | what | bucket | lands in | mutant |
|---|---|---|---|---|
| 49 assert_level commands | `-D ASSERT=`, defines, mem_cap reach the right commands (aquery, audit providers) | 3 | `assert_level_commands` | drop `-D ASSERT=` from the coverage compile |
| 49 functional, mem_cap builds | fixtures build | del | already in functional | n/a |
| 49 branch_runs | branch runs get the level and defines | 1 / 3 | forced-coverage fixtures, else `coverage_switch` | bitcode without `-D` |
| 49 run_check | `bin_none[run_check]` | 1 | `[run_check]` as a validation | ignore assert_level |
| 49 test_none | `buck2 test` passes at ASSERT=none | 3 | `test_limits` (green and red buck2-test cases) | mojo_test drops test_assert_level |
| 49 mem_cap, test_deadline cases | stand-in runs leave nothing alive | 2 | bounded-run tool (Zig port), each case a named test; built today | kill the pid, not the group |
| 49 assert reds | twins fail at their levels | 3 | `assert_level_reds` | always compile at none |
| 49 analysis refusals | bad level, define twice, bad cap | 3 | `analysis_refusals_mojo` | delete the define-twice `fail()` |
| 49 test_default, test_unbounded, deadline_slow | buck2 test of must-fail mojo_tests | 3 | `test_limits` | test command drops mem_cap; limit is timeout, not timeout-60 |
| 49 unbounded, over_cap | MEMORY CAP, exit 137 | 2 | bounded-run tool unit test | compare KiB against MiB |
| 49 deadline_bad_abc/60 | `-c komira.test_timeout_s` refused at load | 3 | `config_refusals` | `<=` margin becomes `<` |
| 26 drift | srcs_drift | del | already tested | n/a |
| 26 aws_lc_kat, s2n_handshake | run_checks | 1 | `[run_check]` as a validation | change one KAT byte |
| 26 s2n_probes_enabled | each feature's probe compiles | del + 1 | already in functional; add a load-time `fail()`: every feature has a probe | add a feature with no probe |
| 26 s2n_probe_disabled | probes for absent features fail | 3 | `planted_red_builds` (require the probe's own diagnostic, not `error:`) | drop a feature that does compile |
| 26 exports, 20 C++ runtime | binaries export no defined dynamic symbol; libc++abi linked | 1 (proposed) | Zig ELF check, with fixture unit tests | build aws-lc without hidden visibility |
| 20 c_dep_linked | C link and run_check | del + 1 | functional; `[run_check]` validation | drop cxx deps from the link |
| 20 c_dep_missing | a C lib not in deps does not link | 3 | `planted_red_builds` | link every cxx_library |
| 20 c_dep_kind | a non-Mojo, non-C dep refused | 3 | `analysis_refusals_mojo` | skip such deps silently |
| 20 test_source_paths | cshim builds | del | already in the gate | n/a |
| 20 uquery | the unconfigured query reaches the untaken branch | 3 | `uquery_select_branches` | delete `cxx_no_default_deps` |
| 41 coverage_platforms | on darwin the switch sets nothing | 3 | `coverage_platforms` | darwin gets the linux branch |
| 41/43/46 coverage_keys, shared_lib, waits | the switch moves no release action; joins wait for exactly the runs and the gate | 3 | `coverage_keys` (one aquery diff), with rows for covlow_conda and the REFUSED path of covnotests_conda | the gate join takes the gate as input |
| 41 coverage_binaries, 43 runs, 46 greens, 47 greens | coverage fixtures build | del + 1 | functional; alias for sub-targets and negative greens | export LC_ALL to the test |
| 41 abs_*, no_reldir | the hermetic checker refuses planted strings | 2 | Zig port of the checker | early return in the path scan |
| 41 noop_relocate | wrapper refuses an output holding the cwd | 2 + 3 | wrapper unit test; `coverage_analysis` row that the coverage compile is scanned | remove the cwd scan |
| 41 switch_yes | `komira.coverage=yes` refused | 3 | `config_refusals` (plus mutation's twin) | treat any value but true as false |
| 43 tracer, parent_fails, killed, banner, lostdir, refused, longarg, lingers, generated | cov_run decisions | 2 | cov_run (Zig port) unit tests with stand-ins | report the last child's status |
| 43 lost, shared_lib_skip | unmapped source; `--must-contain` | del + 3 | existing cov_normalize cases; `coverage_analysis` row for the `--map` prefixes | ignore `--must-contain` |
| 43 data_clash, data_buckout | analysis refusals | 3 | `analysis_refusals_coverage` | delete the buck-out check |
| 43 shared_lib_switch, 46 switch_*, published | builds under the switch | 3 | `coverage_switch` | no version script at `-O0` |
| 46 enforce reds | enforce gates exit 3 with the banner | 2 + 3 | gate step unit test; `coverage_analysis` rows that each fixture's gate runs in enforce | always census mode |
| 46 finding texts | each red names its finding | del | census twins' result goldens (confirm a Markdown rendering test exists) | count a try arm as taken |
| 46 not_test_only | `src/testsuite` is not test-only | 3 | `coverage_analysis` | prefix match without a segment boundary |
| 46 census_malformed | exit 1 fails in every mode | 2 | gate step unit test | exit 1 treated like 3 |
| 46 floor | a Regression is red in census mode | 2 | covcheck ratchet test plus gate unit test | census mode ignores regressions |
| 46 census_doc_edited, floor_lowered, pin_no_reason | census check reds | 2 | census tool (Zig port) unit tests | compare only line counts |
| 46 mojo_test_conda | the conda waits for a named mojo_test's run | 3 | `coverage_keys` row | drop coverage_tests runs from the join |
| 46 mojo_test refusals, test_path, shared_lib_enforce | analysis refusals | 3 | `analysis_refusals_coverage` | delete the no-args check |
| 46 codegen, coverage_tests_analysis, no_gate | gate counts under the switch; ledger | 3 | `coverage_analysis` | add a gate to a coverage_tests library |
| 46 branch_gate_rows | each row names a library under src/ | 1 | target depending on each row, requiring MojoInfo (drops the rule-kind check) | a row naming nothing |
| 47 test_fails, banner, no_profile, raw_version | cov_branch_run decisions | 2 | Zig port unit tests | skip the version check |
| 47 annotate refusals, branchwide | cov_branch_annotate refuses; reads its whole input | 2 | Zig port unit tests on captured fixtures | drop the branch-weights scan |
| 47 nodebug | classify refuses a nodebug call site | 2 | existing classify cases plus a captured Mojo IR fixture | accept the call site |
| 47 test_env | LLVM_PROFILE_FILE refused | 3 | `analysis_refusals_coverage` | delete the `fail()` |
| 47 link_line | a link without `-lm` is not the release link | 2 | Zig port of the comparer | ignore removed flags |

### Sourced: node, proto, public_boundary, rust; golden.sh; lint_weld.sh; negative/

| id | what | bucket | lands in | mutant |
|---|---|---|---|---|
| 54 node_test verdict | stderr-only, fixed-string, case-sensitive expect_error | 2 | node_test runner (Zig port of the embedded script) | match as a regex |
| 54 node analysis refusals | 8 `fail()`s | 3 | `analysis_refusals_node` | delete the staged-twice check |
| 54 unresolved_import | a failing esbuild fails the build | 3 | `planted_red_builds` (no Zig port only for this) | ignore esbuild's exit status |
| 54 npm integrity | SRI checks, all 64 bytes | 2 | npm_unpack (Zig port) unit tests | compare a digest prefix |
| 54 npm package.json | top-level string name/version compared whole; nested_distractors is a must-accept case | 2 | npm_unpack unit tests, a duplicate-key case decided | take the first `"name"` anywhere |
| 54 npm exe | exe runs and prints the pin | 2 | npm_unpack unit tests | skip the version compare |
| 54 node_dist | bin/node, node_api.h, exact version | 2 | node_dist check (Zig port) | `-e` for `-f` |
| 54 c_warns | `-Wall -Werror` | 3 | `planted_red_builds` (2 only after a Zig launcher) | drop `-Werror` |
| 23 proto generated tests | test_person, test_team, test_tasks_db pass | 1 | welded as test_srcs (a small library for the bundled team) | wrong field type |
| 23 check_executor | proto build ran remotely | 3 | `local_zero` | a local test executor |
| 23 id/ident, proto_mismatch | generated struct follows the .proto, old name absent | 1 | gen_check present/absent on both `[gen]` outputs | emit both names |
| 23 proto_unbundled | without bundling only its own files are generated | 1 + 3 | gen-set check on a generate-only form; one `planted_red_builds` row | bundle the closure anyway |
| 23 db_undeclared | a declared output not written fails | 2 | shared generation wrapper (proto and aws) | drop the non-empty check |
| 23 bundle_only, full_bundle | exactly the selected files | 1 + del | gen-set check | ignore bundle_only |
| 23 bad_selection | outside the closure refused | 3 | `analysis_refusals_proto` | delete the membership check |
| 23 gcp greens, functional | build | del | already in the gate | n/a |
| 23 gcp analysis refusals | 10 `fail()`s | 3 | `analysis_refusals_gcp_client` | delete the roots-or-methods check |
| 23 omit_unknown_field, rest_streaming | plugin refusals | del | existing Rust unit tests | n/a |
| 23 omit_pruned_field | pruned-message field refused | 2 (Rust) | new Rust unit test in lower.rs | drop the pruned check |
| 23 rest_reaches_plugin | default protocol reaches the plugin | 1 | gen_check on a default-protocol client | default to grpc |
| 23 caller_test_red | a failing caller test blocks the client | del | tests_check plus the runner unit test | drop caller tests from the gate |
| 23 absence/tests_check_can_fail | the checkers can go red | 2 | gen/tests checker (Zig port) | compare as a subset |
| 23 proto_codegen, proto_fixture greens | build | del | already in functional | n/a |
| 23 proto_fixture planted defects | 11 legs refused | del | `refuses_*` twins in proto_fixture_testdata | n/a |
| 23 determinism | two builds give identical plugins, sources, package | 1 + open | in-action double run of each plugin; `determinism_proto` for compile bytes | HashMap-ordered output |
| 44 public_boundary greens | lint and ok tree | del | already in the gate | n/a |
| 44 dates, home, ip, host, email, sha, file classes | each planted spelling is a finding | 2 | public_boundary (Zig port) table tests | drop the compact date matcher |
| 44 paths_attr | a file given through `paths` is read | 1 | a held finding in a `paths`-only file of ok | stop staging `paths` |
| 44 holds, hosts ledgers | ledger rows validated, shrink exactly | 2 | ledger parser shared with pointer_lint | accept a held count above actual |
| 44 window, empty | bad window refused; empty tree fails | 2 | public_boundary args; zero-input guard in the shared lint runner | drop the checked>0 guard |
| 44 window pin | the root target's window | 1 / del | load-time check, or delete | narrow the window |
| 44 no_tree, both | xor refused | 3 | `analysis_refusals_lint` | delete the `fail()` |
| 22 rust_example | prost example run_check | 1 | rust `[run_check]` as a validation | change expected stdout |
| 22 rust_missing_dep | a crate not in deps does not reach rustc | 3 | `planted_red_builds` | pass every vendored crate |
| 22 rust host floor | rustc and sysroot NEEDED resolve via `$ORIGIN` or glibc | 1 (proposed) | Zig ELF-closure check over the sysroot | a sysroot with an absolute RUNPATH |
| 35 rust ext green | external tests gate the library | 1 | move to the komira cell plus a marker-list check, `both` included | drop test_srcs from the gate |
| 35 rust ext red | failing external or unit test blocks library and consumer | 2 | gate runner unit test | accept a non-zero harness exit |
| 35 rust ext refusals | test_srcs must be `tests/<ident>.rs` | 3 | `analysis_refusals_rust` | delete the `.rs` check |
| golden check | config hash and per-sample aquery hashes equal the golden; a flipped digit refused | 3 | `golden_linux_x86_64`, keeping the empty-aquery and unreadable-configuration guards | add a flag to the compile command |
| golden gen | regenerates | 3 | `--regen` flag of that scenario | n/a |
| golden tree, actions | hand tools, no caller | del | nothing | n/a |
| golden shell_lint | shellcheck of golden.sh | del | removed with golden.sh | n/a |
| tool_lib.sh | inspect, cfg_value, props_norm, whatran_actions | 3 | helper lib, each with a fixture unit test | take the first ` (` when cutting the identity |
| negative/spsc_ring_* | element refusal; race falsifier; no caller | open | a scenario, or delete as one-off proofs | n/a |
| negative/ fixtures | planted inputs | per row | become Zig test data or scenario fixtures with their rows | n/a |

## Bucket-3 scenarios

All under `//tools/build/selftest/`, one Zig test target each:

- Executors and platforms: `local_zero`, `action_properties`, `exec_platforms`, `uquery_select_branches`.
- Graph queries (or BXL checks in the gate, see "Open decisions"): `aquery_host_paths`,
  `config_hash_pin`, `docs_package_coverage`, `test_weld_real_graph`, `golden_linux_x86_64`.
- Analysis and load refusals (tables of target, `-c` overrides, exact message):
  `analysis_refusals_mojo`, `_aws_client`, `_gcp_client`, `_proto`, `_readme`, `_lint`,
  `_python_oracle`, `_node`, `_rust`, `_coverage`, `_platform_table`, and `config_refusals`.
- Builds that must go red: `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
  `assert_level_reds`, `test_limits`.
- aquery diffs: `assert_level_commands`, `aquery_opt_levels`, `coverage_platforms`, `coverage_keys`,
  `coverage_analysis`, `coverage_switch`.
- Scratch trees and clones: `consumer_cell_cache`, `buck2_run_fresh_clone`, `fresh_clone_local_default`,
  `lint_weld`, `docker_run`.
- Determinism (blocked on the forced-execution ruling): `bundle_determinism`, `conda_determinism`,
  `determinism_proto`.

## The helper library

`//tools/build/selftest:lib`, a Zig library with its own unit tests on captured fixtures. Files stay
under 1000 lines. It offers only what the scenarios above use:

- **Guard.** It refuses to run unless the client is Linux x86_64 and every registered execution platform
  is remote. It reads the list through `audit config` and `audit providers`. A refusal is a failure on
  CI and never a pass.
- **Runner.** The buck2 path comes from a flag. The runner takes argv, a cwd, `-c` pairs,
  `--target-platforms` and a timeout. It captures exit, stdout and stderr into a per-scenario log
  directory under `$TMPDIR`. Every failure names its log file. Any daemon it started is stopped with
  `buck2 kill`.
- **Expectations.**
  - `expectBuildOk(targets)`.
  - `expectBuildFails(target, text)`. "Built but must fail" and "failed without the text" are distinct
    failures.
  - `expectTestFails(target, text, test_args)`.
  - `expectAbsent(log, patterns)`.
  - `expectFindings(log, n)`.
  - A refusal table runner that builds analysis only.
- **No silent pass.** A scenario that executes nothing, asserts nothing, or SKIPs on CI fails.
- **Parsers.**
  - what-ran JSON into actions with category, executor and normalized properties. An empty run is a
    failure.
  - aquery JSON into actions with category, identifier, argv, env and inputs, plus a diff across
    configs and an absolute-path scanner.
  - cquery configurations, `audit execution-platform-resolution`, uquery label sets, `audit config`
    values, and a BXL runner.
- **Scratch tree.** It snapshots the committed tree, plus the local farm config if present, under
  `$TMPDIR`. It plants a file or BUCK edit, runs the tree's own daemon, and always kills that daemon and
  deletes the tree, even on failure (`KEEP_SCRATCH` keeps it).
- **Digests.** A sorted file-hash manifest of output trees, and a diff that names the files that differ
  (determinism).
- **Golden I/O.** It compares the scenario output to a committed golden line by line, and supports
  `--regen`.

## How CI runs it

Bucket 1 and bucket 2 run inside `pr / check` like any other target. They are the gate.

Bucket 3 drives buck2, so it runs only on the farm-attached CI runner. That is the scheduled
build-system self-test workflow, which today runs `run_tests.sh`. Its step becomes
`./buck2 test //tools/build/selftest/...`. A scenario never runs on a developer machine: the guard
refuses a client whose execution platforms are not all remote. The one exception is
`fresh_clone_local_default`, which builds locally by design and so runs on the CI runner alone. The
workflow keeps calling `run_tests.sh` for the checks that are not converted yet, until the last slice
deletes the script.

## Slice plan

Each slice is one pull request. It converts its rows, shows each row's planted mutant going red (in the
PR text), and deletes those shell lines, fixtures and lint entries in the same commit. The bookkeeping
goes with them: the `tools/build/tests/BUCK` shell_lint globs, the root `//:tests_lints` entries, and
the README and platform README pointers.

1. **This design.** Docs only.
2. **Deletes and gate gaps.** Delete the `del` rows. Make `[run_check]` a validation for Mojo and Rust.
   Move the parked greens to functional. Move report floors into the actions. Add the s2n probe
   `fail()`.
3. **Helper lib and first scenarios.** Add `//tools/build/selftest:lib` with its unit tests. Add
   `exec_platforms`, `uquery_select_branches`, and the `analysis_refusals_*` and `config_refusals`
   tables (analysis only, cheap). Switch the workflow step to run both the new targets and `run_tests.sh`.
4. **Red builds.** `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
   `assert_level_reds`, `test_limits`.
5. **aquery and what-ran.** `local_zero`, `assert_level_commands`, `aquery_opt_levels`, and the
   `coverage_*` scenarios. Also the graph-query rows, as BXL or as scenarios, per the ruling.
6. **Lints to Zig, with unit tests.** test_weld, pointer_lint, src_layout, refused_imports,
   readme_api_coverage, surface_capability_matrix, public_boundary and the shared lint runner, plus the
   new file lints (17, 19) and the toolchains-cell file list.
7. **Runners to Zig.** The gate runner, compile wrapper, Rust test runner, bounded-run tool, and the
   cov_run and cov_branch tools, each with the unit tests their rows list.
8. **ELF checks** (if the proposal below is accepted), the node tools, and the proto generation wrapper.
9. **Clones and determinism.** `consumer_cell_cache`, `buck2_run_fresh_clone`,
   `fresh_clone_local_default`, `lint_weld`, `docker_run`, and the determinism scenarios once forced
   execution is ruled on. Then delete `run_tests.sh`, `tool_lib.sh`, `golden.sh` and `lint_weld.sh`.

## Open decisions

- **Forcing execution with the cache on.** Rows 12, 15, 33a/b and proto determinism use
  `--no-remote-cache` and `--isolation-dir` today. The proposal is a salt (`-c selftest.salt=<nonce>`)
  that every rule folds into its action keys. Until that is ruled on, those scenarios cannot be
  converted as written.
- **ELF inspection as bucket 1.** The direction lists ELF inspection under scenarios. Rows 6, 8
  runtime_run_paths, 26 exports, 20 C++ runtime and 22 host floor read only built artifacts. An in-build
  Zig ELF check puts them in the gate and drops the host `readelf`. This is a proposed deviation.
- **Graph queries as BXL in the gate.** Rows 5, 17 doc_pkgs, 18 and 39 real_red could run as BXL checks,
  following the test_weld precedent in `build_targets.sh`, instead of as scenarios.
- **Bucket 2 form.** The direction says plain `buck2 test` targets. Welded `zig_test` build actions are
  what `pr / check` actually runs. This design uses the welded form.
- **Scope of the Zig port.** doc_links and readme_examples are Mojo tools today. The aws env scanner is
  Mojo text generated in aws.bzl. The Rust plugin's tests stay in Rust.
- **darwin (24).** Port it in step with Linux, or freeze it until macOS workers are in CI.
- **lint_weld after the port.** Once the rules run no shell, the scenario re-aims at whatever lint stays
  welded, or goes away.
- **The spsc_ring scripts.** Nothing runs them. Keep them as scenarios or delete them as one-off proofs.
