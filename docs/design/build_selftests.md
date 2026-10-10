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
   tool a bad input and asserts the exit code and the message. It lives next to the tool's source. This
   design uses the repo's existing welded form, `zig_test` (`tools/build/mojo/toolchain.bzl`): `zig test`
   runs as a build action that the tool's `zig_exe` consumes through `unit_tests`, so the tool cannot be
   built unless its tests pass. A plain `buck2 test` target next to the tool would also run in
   `pr / check`, because every `zig_exe` is in the komira cell and `build_targets.sh` runs `buck2 test`
   over a unit's komira-cell targets. The choice between the two is a preference with a real trade-off,
   and the CEO rules on it (see "Open decisions"). A tool that is Rust (the proto-codegen plugin) or Mojo
   (covcheck) keeps its tests in its own language, next to it.
3. **A scenario.** This covers only what must drive buck2 from outside: what ran and where (local: 0),
   two-build determinism, consumer-cell clones, analysis-time and load-time refusals, builds that must
   go red, and client queries (`aquery`, `cquery`, `audit`, `log what-ran`). Each scenario is **one Zig
   test target**, named, runnable alone, under `//tools/build/selftest/`. They share one small helper
   library. Scenarios are kept out of `pr / check` by a platform constraint, and one target,
   `//tools/build/selftest:scenarios`, runs them all on the farm-attached CI runner (see "Keeping
   scenarios out of the gate" and "How a scenario runs").

This follows the build-architecture ruling:
- the rules are Starlark;
- every CI entrypoint is a Buck2 target, so a workflow step is one `./buck2 build|test|run` and holds
  no logic;
- rules invoke only Zig-built tools;
- there is no host shell outside an allowlisted set of thin wrappers.

Every action this design adds runs a Zig-built tool, and every CI step it adds is one `./buck2` command
on one target. It adds no shell. Existing rule scripts that the rows below lean on (`run_check.sh`, the
`cases.sh` actions) keep running until their own Zig port. Rows 28, 29 and 49 schedule the ports of the
case scripts. The rest belong to the port of rule scripts under the build-architecture ruling, not to
this design.

A fourth outcome is **delete**: the check repeats what `pr / check` already builds. Every converted check
has a planted mutant that turns it red, and each slice deletes its shell part in the same pull request.

"Already in the gate" has a precise meaning here. `pr / check` builds the derived units the change
reaches. Its universe is `//...` and `tests//functional/...` (`release/ci/derive_checks.py`); it is not
a whole `//...` build. It runs `buck2 test` only on targets outside `tests//`
(`release/ci/build_targets.sh`). It does not build sub-targets such as `[run_check]`. It never builds
`tests//negative`. The universe is a `cquery` for the default target platform, so a target that is
incompatible with that platform is in no derived check.

## Cross-cutting gaps (bucket 1 work that unblocks many rows)

- **`[run_check]` as a validation.** The `[run_check]` of `mojo_binary` and of `rust_binary`
  (`rust/defs.bzl`) is a sub-target only, so nothing in the gate runs it. Making it a `ValidationInfo`
  of every binary with `expected_stdout` puts rows 1, 21, 26, 22 and 35 in the gate.
  Mutant: change `:hello`'s `expected_stdout` to `hello from mojoX\n`. The unit must go red.
- **Green fixtures parked under `tests//negative`** move to `tests//functional`:
  `rust_test:bin_green`, `rust_test:env_scrubbed`, `test_weld/real:ok`, the external-test greens of 35.
- **`mojo_test` targets in `tests//functional`** are built but never run. Weld them as `test_srcs`
  (proto), or move them to the komira cell, where `build_targets.sh` already runs `buck2 test` (slice 2
  does this for `td_mojo_test`), or keep them in the `test_limits` scenario.
- **Sub-targets and `tests//negative`/`tests//src` greens** need a root alias that names them (like
  `//:tests_lints`). Plain `tests//functional` targets need no alias.
- **Report floors move into the action.** Today the client counts "ok" lines (watchdog >= 15,
  runner_cases >= 5, mem_cap >= 4, test_deadline >= 6). A count floor is the only guard against a
  case list that runs nothing. In slice 2 the existing case action refuses a short report. That is an
  edit to a script that already exists, not a new one. In slice 7 each case becomes its own named Zig
  test, and the case script is deleted.
- **A toolchains-cell file list.** The scans 17 tc_md and 19 exported_cells cover `tools/build/cells`.
  A komira-cell lint sees that directory only through a file-list target inside the toolchains cell, as
  `tests//:doc_tree` does for the tests cell. Without that target, the lint passes without reading the
  files.

## Scenario inventory

Bucket: `1` target, `2` Zig (or tool-language) unit test, `3` scenario, `del` delete, `open` needs a
ruling. Numbers are the test numbers in `run_tests.sh`. Scenario names are under `//tools/build/selftest:`.
**Slice** is the one pull request that deletes the row's shell lines (see "Slice plan"). A mixed row
(`3 + 2`) is deleted in the slice of its last part. Its earlier parts land in earlier slices, and the
shell lines stay until then. Each of the 187 rows names exactly one slice. A fixture under `negative/`
goes with the last row that uses it.

### run_tests.sh, its own tests

| id | what | bucket | lands in | mutant | slice |
|---|---|---|---|---|---|
| 1 examples | the example targets build | del | already in their units | a compile error in hello.mojo reds the unit | 2 |
| 1 run_checks | hello, hello_pkg_user, cadd_user print their expected_stdout | 1 | `[run_check]` as a validation | change hello's expected_stdout | 2 |
| 1 check_executor | every action of the run ran remotely or was a cache hit | 3 | `local_zero` (one what-ran scenario for every former `check_executor` call, with one `buck2 test` leg) | a hybrid executor that prefers local on one platform, so the action really runs locally; a run that executes nothing must fail too, not SKIP | 5 |
| 2 gate_red | a library whose welded test fails does not build: GATED TEST FAILED | 3 + 2 | `gate_wiring` case "library default output red"; gate runner unit test (exit, message) | `default_output = ungated` with MojoInfo still gated (scenario); runner exits 0 on a failing test (unit) | 7 |
| 2 gate_ungated_green, sharedlib_*_ungated | the `[ungated]` fixtures compile, so the red comes from the test | 3 | precondition inside `gate_wiring` / `shared_lib_gate` (could also be a functional target depending on the sub-target) | a compile error in the fixture fails the precondition | 4 |
| 2 gate_consumer_red | a binary on a red library fails | 3 | `gate_wiring` | the published .mojoc stops taking the PASS markers as inputs | 4 |
| 2 gate_bypass_refused | `[ungated]` in deps fails analysis | 3 | `analysis_refusals_mojo` | `[ungated]` returns MojoInfo | 3 |
| 2 sharedlib gate reds | missing export, unresolved symbol, failing driver, force_load, leaking symbols, duplicate definition | 3 | `shared_lib_gate` | drop the version script / `--exclude-libs`; drop `--whole-archive` | 4 |
| 2 sharedlib_empty_exports | empty exports refused at analysis | 3 | `analysis_refusals_mojo` | delete the empty-exports `fail()` | 3 |
| 3 missing_dep | a binary importing a package not in deps does not compile | 3 | `compile_isolation` | stage every package of the cell on `-I` | 4 |
| 4 closure_refusal | the compile wrapper refuses an incomplete toolchain closure | 2 | compile wrapper (Zig port) unit test: exit 2 and `REFUSING: toolchain member` (the shell checked only the text) | skip the closure check | 7 |
| 5 host_paths | no action argv or env names an absolute host path; scanner self-check on `/bin/sh` | open | `aquery_host_paths`, or a BXL check in the gate; scanner unit test in the helper lib | add `/usr/bin/env` to the mojo_build command | 5 |
| 6 outputs | hello has exactly `DT_RUNPATH $ORIGIN/lib`, no `buck-out/`, and first finds a NEEDED runtime library | 1 (proposed) | Zig ELF check tool run as a validation of hello, with unit tests over fixture ELFs, including one with no dynamic section | an absolute run path in the link | 8 |
| 7 umbrella_cache | consumer-cell clones hit the same cache digests | 3 | `consumer_cell_cache` | a root-cell-relative path in an action's argv | 9 |
| 8 host_floor | loader trace: libstdc++/libgcc_s from the toolchain, the rest glibc | 1 | Zig checker inside `functional/runtime_libs:loader_trace` | drop the toolchain lib dir from the run's library path | 8 |
| 8 runtime_libs | loaded toolchain libs equal `hello[runnable]/lib` | 1 | `functional/runtime_libs:runtime_libs_match` | add a library to `mojo_runtime`'s list | 8 |
| 8 runtime_run_paths | every run path in `hello[runnable]/lib` is `$ORIGIN`-relative, at least one read | 1 (proposed) | the ELF check tool of 6 | an unrewritten vendor DT_RPATH | 8 |
| 9 buck2_run | `buck2 run` from a fresh clone: greeting, downloads, relocatable | 3 | `buck2_run_fresh_clone` | RunInfo points outside run_dir | 9 |
| 10 exec_platforms | Mojo, toolchain and C targets resolve to linux-x86_64 | 3 | `exec_platforms` (one table with 20's C rows) | register a second platform first | 3 |
| 11 | retired; a comment | del | nothing | n/a | 2 |
| 12 action_platforms | an uncached build runs 7 categories with the farm property set | open | `action_properties` | an empty property set for one category | 10 |
| 13 bundle_parity | functional parity target builds | del | already in the gate | n/a | 2 |
| 14 launcher_levels | level_test; launcher level equals glibc's on the host | del + 1 | level_test stays; `level_vs_glibc`, a Zig check action on a worker that compares the launcher's level for the worker's CPU with the worker's glibc loader | launcher level one too high without AVX2 | 8 |
| 15 bundle | layout, run paths, SHA256SUMS, a relocated and a symlinked run, the below-v3 refusal; two-build determinism | 1 + open | the layout and run legs as Zig check actions over `hello`'s bundle (functional targets); `bundle_determinism` | a timestamp in the tarball; an absolute run path in the bundle | 10 |
| 16 formats | tarball/OCI content and its determinism rules, pinned base layers; `docker load` and `docker run` | 1 + 3 | Zig check actions over the tarball and image; `docker_run` on the CI runner | drop mtime normalization in `oci/src/tar.zig` | 9 |
| 17 docs green | `//:docs`, doc_links:ok | del | already in the gate | n/a | 2 |
| 17 doc_links_dead | the link checker names missing file, bad anchor, escape, count | 2 | unit tests of doc_links (Mojo today; Zig if ported) | accept any `#fragment` | 6 |
| 17 doc_pkgs | every package is in `deps(//:docs)` | open | `docs_package_coverage`, or a BXL check in the gate | a rule that does not call declares_docs | 5 |
| 17 tc_md | `tools/build/cells` holds no Markdown | 1 | doc lint over the committed files, with the toolchains-cell file list | commit a NOTES.md there | 6 |
| 17 named_doc_tree | no BUCK file calls doc_tree/package_docs itself | 1 | Zig lint over committed BUCK files | add `doc_tree(name = "x")` | 6 |
| 17 package_boundary_exceptions | neither cell sets it | 1 | lint over the committed .buckconfig files | set it in the tests cell's .buckconfig | 6 |
| 18 config_hashes | the only configuration in hello's closure is the pinned hash | open | `config_hash_pin`, or a BXL check | add a constraint to the platform | 5 |
| 19 exported_cells | labels in exported BUCK/.bzl name only komira, prelude, toolchains (floor of 20) | 1 | Zig lint, with the toolchains-cell file list | a `tests//` label in mojo/defs.bzl | 6 |
| 21 location_path | `location_path:main[run_check]` | 1 | `[run_check]` as a validation | remove the staging-dir prefix map | 2 |
| 24 darwin platform | macOS registration only when configured, resolution, compile command lines, linux actions unchanged | 3 | `darwin_platform` (cquery/aquery with `--target-platforms` darwin-arm64, one aquery diff of the linux actions) | register the macOS platform with no configuration | 11 |
| 24 darwin Mach-O, stand-ins | the osx-arm64 closure's Mach-O load commands; the macOS scripts against stand-ins, the compile watchdog included | 1 + 2 | a Zig Mach-O check action over the unpacked closure (with the ELF tool); unit tests of each macOS script's Zig port | an absolute load path in the closure; the watchdog never fires | 11 |
| 24 darwin build_run | build and run check of `hello` on macOS workers, only when they are configured | open | a `darwin_build_run` scenario once macOS workers are in CI; until then the leg is dropped, not skipped (a scenario never SKIPs) | n/a | 11 |
| 25 local_default | a clone without farm config is local-only and refuses forced remote | 3 | `fresh_clone_local_default` (CI runner only: it builds locally by design) | pick a remote executor when the farm config is absent | 9 |
| 28 watchdog | cases build, no BAD, at least 15 ok | 1 | floor inside the action; later Zig supervisor tests | delete a case | 2 |
| 29 td_declared, test_deps, args_action | plain builds | del | already in the gate | n/a | 2 |
| 29 td_mojo_test(_args) | `buck2 test` of two mojo_tests passes | 1 | tested by the gate (move to the komira cell, or extend `build_targets.sh`) | drop test_env/data from the test info | 2 |
| 29 td_undeclared | an undeclared fixture is not staged | 3 | `compile_isolation` | stage the whole package as share/ | 4 |
| 29 td_skip_77 | exit 77 is red | 2 | gate runner unit test | treat 77 as pass | 7 |
| 29 td_env_bin(_lib) | `BIN=true` cannot replace a red test | 2 | gate runner unit test, BIN set through `--env` and in the process env | runner execs `$BIN` | 7 |
| 29 runner_cases | cases build, at least 5 ok | 1 | floor inside the action | reuse one TEST_TMPDIR | 2 |
| 29 td_bad_*, test_deps refusals | 7 analysis refusals | 3 | `analysis_refusals_mojo` | delete the shell-name check in test_runtime.bzl | 3 |
| 29 td_test_deps_src/consumer | a library and its consumer cannot import test_deps | 3 | `compile_isolation` | add test_deps to the compile path | 4 |
| 30 opt_level | per-kind `-O` levels from aquery | 3 | `aquery_opt_levels` | mojo_binary default `-O1` | 5 |
| 30 opt_bad_level | `fast` refused | 3 | `analysis_refusals_mojo` | remove the level check | 5 |
| 31 lint_weld (planted) | a planted shellcheck finding reds the Mojo and Rust examples | 3 | `lint_weld` (scratch tree) | drop one target from `_script_lint` | 9 |
| 31 lint_weld (lists) | the toolchains' lint lists are complete | 3 | `lint_weld` derives the scripts the rules run from the graph, independent of the lists (a shared constant cannot catch a drop) | drop `rust:shell_lint` from the Rust list | 9 |
| 32 bootstrap | `./buck2` installs only the pinned release, refuses wrong sha/size | 3 (2 if ported) | `bootstrap_pin`: a made-up pin and release in a scratch dir, no network, `./buck2` run as the program under test; unit tests instead if the bootstrap becomes Zig | skip the sha256 check | 9 |
| 33a install_gate | builds | del | already in the gate | n/a | 2 |
| 33a/b conda, conda_set | determinism, manifests, pixi install | 1 + 3 + open | manifest checks as targets; `conda_determinism`; install on CI | n/a | 10 |
| 33 client | the runner refuses a non Linux x86_64 client | 2 | helper lib client guard unit test | accept Darwin arm64 | 11 |
| 34 aws_codegen | green build; harness reds (golden, accepted, must_contain) | del + 2 | Zig checker replacing aws_codegen.sh, unit-tested on text | match must_contain as a substring | 8 |
| 35 rust_test_unit | marker reads `N passed`, N >= 1 | 2 | Rust test runner (Zig port) unit test | PASS on `0 passed` | 7 |
| 35 rust_test_compiles | the red fixture compiles | 3 | `gate_wiring` precondition | compile error in the fixture | 4 |
| 35 red, unwinds, bin_red, lib_consumer_red | a failing test reds test, binary, consumer; the panic unwound | 3 | `gate_wiring` | `-C panic=abort`; binary not on the marker | 4 |
| 35 bin_green, env_scrubbed | builds and runs; env is HOME/PATH/TMPDIR | 1 | move to `tests//functional/rust_test`, rust `[run_check]` as a validation | expected_stdout `hellX\n` | 2 |
| 35 empty, ignored | EMPTY GATE; ignored test refused | 2 | runner unit tests over captured real libtest output | accept `0 passed` | 7 |
| 35 hang | timed out after the fixture's 3 s | 2 + 3 | runner unit test (deadline, exit 142); `gate_wiring` case requiring `timed out after 3s` | runner uses the default timeout instead of `test_timeout_s` | 7 |
| 35 buck2_test | `buck2 test` of proto-codegen passes | del | already tested by the gate | n/a | 2 |
| 35 buck2_test_red | `buck2 test` of a binary on a red test fails | 3 | `gate_wiring` | TestInfo skips the welded test | 4 |
| 36 greens | AWS client targets build | del | already in the gate | n/a | 2 |
| 36 analysis refusals | 11 mojo_aws_client `fail()`s | 3 | `analysis_refusals_aws_client` | delete the duplicate-operation check | 3 |
| 36 unknown_operation | the generator refuses an unknown operation | 2 (Rust) | Rust unit test in `aws_in.rs`, if absent | skip unknown operations | 2 |
| 36 caller_test_red | a failing caller test reds the client | 3 | `gate_wiring` | leave caller tests out of the gate | 4 |
| 36 env scan reds | getenv, pathlib spellings, t-strings, control bytes | 2 (open) | unit tests of the env scanner once extracted from aws.bzl into a tool | stop joining continuation lines | 6 |
| 37 platform_table | load-time table cases; a platform per registered row and none for the reserved one; `host` is the client's platform; the reserved row's key refused; the default platform's own key decides remote (legs 1-5) | 3 | `analysis_refusals_platform_table`; the key legs in `exec_platforms` | accept a pending pin; read another platform's key | 3 |
| 37 limits | limits.tsv: the real tree passes; a limit with no marker, a marker with no row, a row with no marker, a merged row with its marker are refused (leg 6) | 2 | unit tests of the limits checker's Zig port over fixture trees (the real tree stays a target) | accept a row with no marker | 6 |
| 37 table_vs_tree | each registered row's golden_config_hash is buck2's hash for the platform; the macOS row's applets (leg 7) | 3 | `config_hash_pin` (one scenario with 18) | a stale golden_config_hash | 5 |
| 38 readme_examples green | builds | del | already in the gate | n/a | 2 |
| 38 readme_marker | ok says PASS, none says NO EXAMPLE | 1 | a Zig check action over the two sub-target outputs | PASS without an example | 6 |
| 38 raises, skip_word, shipped_relative_link | readme tool findings | 2 | readme_examples tool unit tests | accept a `mojo skip` fence | 6 |
| 38 compile_error, unowned | README compile errors name `README.md:9` | 3 + 2 | `compile_isolation`; extractor unit test for the line marker | drop the line trailer; ignore `readme=False` | 6 |
| 38 owner_base_no_readme, readme_keyword | load refusals | 3 | `analysis_refusals_readme` | remove the bool check | 3 |
| 39 test_weld greens | the bxl passes | del + 1 | two already in the gate; move `real:ok` to functional | count a commented test_srcs | 2 |
| 39 test_weld planted reds | the checker names each ledger and weld defect | 2 | test_weld checker (Zig port) unit tests | let a row for a welded test pass | 6 |
| 39 test_weld_real_red | over the real rules, exactly 3 unwelded files named | open | `test_weld_real_graph`, or the BXL in the gate | read test_srcs from BUCK text | 5 |
| 40 readme_api_coverage | ledger reds | del + 2 | checker unit tests | accept a row for a used symbol | 6 |
| 42 pointer_lint | 31 planted sites and ledger defects | del + 2 | pointer lint (Zig port) unit tests | drop two-statement partial-move tracking | 6 |
| 42 no_tree/both | xor refused | 3 | `analysis_refusals_lint` (all five xor copies) | delete one of the five `fail()`s | 3 |
| 45 src_layout | 17 findings | del + 2 | src_layout lint unit tests | stop refusing `*_loopback` under src/ | 6 |
| 51 python_oracle | 6 analysis refusals | 3 | `analysis_refusals_python_oracle` | drop the third_party owner check | 3 |
| 52 mojo_doc_json | green; compile error | del + 3 | `compile_isolation` | ignore the doc action's exit status | 4 |
| 52 golden_differs, missing_symbol | doc JSON checker | 2 | doc JSON checker unit tests | walk only top-level symbols | 6 |
| 53 surface_capability_matrix | 19 reds, 5 the only finding | del + 2 | matrix checker unit tests, facts fed as input | refuse no longer-named package | 6 |
| 53 dangling, incompatible | unknown target; incompatible test under a pattern | 3 | `analysis_refusals_lint` (scratch tree, not an in-place copy) | make the deps soft | 3 |
| 55 refused_imports | 25 spellings | del + 2 | scanner unit tests | stop following continuations | 6 |
| 55 bad_entry | non-dotted entry refused | 3 | `analysis_refusals_lint` | drop the dotted-name check | 3 |
| order switches | `--no-run`, `--no-umbrella`, local SKIPs | del | each scenario runs alone | n/a | 11 |
| harness mode | local/remote mode detection | 2 | helper lib farm guard, unit-tested | accept a mixed list | 11 |
| harness silence | a sub-script that reports nothing, or SKIPs on CI, is red | 2 | helper lib: a scenario that executes nothing or asserts nothing fails | return early with no assertion | 11 |

### Sourced: assert_level, c_libs, cxx, coverage

| id | what | bucket | lands in | mutant | slice |
|---|---|---|---|---|---|
| 49 assert_level commands | `-D ASSERT=`, defines, mem_cap reach the right commands (aquery, audit providers) | 3 | `assert_level_commands` | drop `-D ASSERT=` from the coverage compile | 5 |
| 49 functional, mem_cap builds | fixtures build | del | already in functional | n/a | 2 |
| 49 branch_runs | branch runs get the level and defines | 1 / 3 | forced-coverage fixtures, else `coverage_switch` | bitcode without `-D` | 5 |
| 49 run_check | `bin_none[run_check]` | 1 | `[run_check]` as a validation | ignore assert_level | 2 |
| 49 test_none | `buck2 test` passes at ASSERT=none | 3 | `test_limits` (green and red buck2-test cases) | mojo_test drops test_assert_level | 4 |
| 49 mem_cap, test_deadline cases | stand-in runs leave nothing alive | 2 | bounded-run tool (Zig port), each case a named test; built today | kill the pid, not the group | 7 |
| 49 assert reds | twins fail at their levels | 3 | `assert_level_reds` | always compile at none | 4 |
| 49 analysis refusals | bad level, define twice, bad cap | 3 | `analysis_refusals_mojo` | delete the define-twice `fail()` | 3 |
| 49 test_default, test_unbounded, deadline_slow | buck2 test of must-fail mojo_tests | 3 | `test_limits` | test command drops mem_cap; limit is timeout, not timeout-60 | 4 |
| 49 unbounded, over_cap | `lib_unbounded` and `lib_over_cap` do not build: MEMORY CAP at their configured caps (512 and 192 MiB), GATED TEST FAILED (exit 137), the fixture started | 2 + 3 | bounded-run tool unit test (KiB vs MiB, exit 137); `test_limits` cases, one per library, requiring the cap line with its MiB, the started line and the gate's exit 137 | compare KiB against MiB (unit); the rule drops `test_memory_cap_mib` from the gate action (scenario) | 7 |
| 49 deadline_bad_abc/60 | `-c komira.test_timeout_s` refused at load | 3 | `config_refusals` | `<=` margin becomes `<` | 3 |
| 26 drift | srcs_drift | del | already tested | n/a | 2 |
| 26 aws_lc_kat, s2n_handshake | run_checks | 1 | `[run_check]` as a validation | change one KAT byte | 2 |
| 26 s2n_probes_enabled | each feature's probe compiles | del + 1 | already in functional; add a load-time `fail()`: every feature has a probe | add a feature with no probe | 2 |
| 26 s2n_probe_disabled | probes for absent features fail | 3 | `planted_red_builds` (require the probe's own diagnostic, not `error:`) | drop a feature that does compile | 4 |
| 26 exports, 20 C++ runtime | binaries export no defined dynamic symbol; libc++abi linked | 1 (proposed) | Zig ELF check, with fixture unit tests | build aws-lc without hidden visibility | 8 |
| 20 c_dep_linked | C link and run_check | del + 1 | functional; `[run_check]` validation | drop cxx deps from the link | 2 |
| 20 c_dep_missing | a C lib not in deps does not link | 3 | `planted_red_builds` | link every cxx_library | 4 |
| 20 c_dep_kind | a non-Mojo, non-C dep refused | 3 | `analysis_refusals_mojo` | skip such deps silently | 3 |
| 20 test_source_paths | cshim builds | del | already in the gate | n/a | 2 |
| 20 uquery | the unconfigured query reaches the untaken branch | 3 | `uquery_select_branches` | delete `cxx_no_default_deps` | 3 |
| 41 coverage_platforms | on darwin the switch sets nothing | 3 | `coverage_platforms` | darwin gets the linux branch | 5 |
| 41/43/46 coverage_keys, shared_lib, waits | the switch moves no release action; joins wait for exactly the runs and the gate | 3 | `coverage_keys` (one aquery diff), with rows for covlow_conda and the REFUSED path of covnotests_conda | the gate join takes the gate as input | 5 |
| 41 coverage_binaries, 43 runs, 46 greens, 47 greens | coverage fixtures build | del + 1 | functional; alias for sub-targets and negative greens | export LC_ALL to the test | 2 |
| 41 abs_*, no_reldir | the hermetic checker refuses planted strings | 2 | Zig port of the checker | early return in the path scan | 7 |
| 41 noop_relocate | wrapper refuses an output holding the cwd | 2 + 3 | wrapper unit test; `coverage_analysis` row that the coverage compile is scanned | remove the cwd scan | 7 |
| 41 switch_yes | `komira.coverage=yes` refused | 3 | `config_refusals` (plus mutation's twin) | treat any value but true as false | 3 |
| 43 tracer, parent_fails, killed, banner, lostdir, refused, longarg, lingers, generated | cov_run decisions | 2 | cov_run (Zig port) unit tests with stand-ins | report the last child's status | 7 |
| 43 proc | `lingerproc`: `/proc is not readable as this run's own` | 2 + 3 | cov_run unit test with an injected process-table root it cannot read; `coverage_gate_reds` keeps the real fixture, since only a real kernel proves the read | treat an unreadable `/proc` as no survivors | 7 |
| 43 lost, shared_lib_skip | unmapped source; `--must-contain` | del + 3 | existing cov_normalize cases; `coverage_analysis` row for the `--map` prefixes | ignore `--must-contain` | 5 |
| 43 data_clash, data_buckout | analysis refusals | 3 | `analysis_refusals_coverage` | delete the buck-out check | 3 |
| 43 shared_lib_switch, 46 switch_*, published | builds under the switch | 3 | `coverage_switch` | no version script at `-O0` | 5 |
| 46 enforce reds | enforce gates exit 3 with the banner; the conda package, not the library or a dependent, is blocked | 2 + 3 | gate step unit test; `coverage_gate_reds` (each enforce fixture red with the banner, `covlow_user` and the libraries green) | always census mode; the conda join skips the gate | 7 |
| 46 shared_lib_run | a shared library's driver fails under kcov (`COVERAGE RUN FAILED`) while its published file builds | 3 | `coverage_gate_reds` (the published file green, then the driver's run red with the message) | cov_run exits 0 when the driver fails under kcov | 4 |
| 46 finding texts | each red names its own finding (BelowTarget line/branch with the percent, BranchNotMeasured, NotMeasured, UnmeasuredFile, `### Findings (1)`) | 3 | `coverage_gate_reds`: each red's expected text is its finding line. covcheck's `test_cli.mojo` and the e2e `summary.md` golden already cover the rendering; they do not cover which finding a real fixture under kcov yields | count a try arm as taken | 4 |
| 46 not_test_only | `src/testsuite` is not test-only | 3 | `coverage_analysis` | prefix match without a segment boundary | 5 |
| 46 census_malformed | exit 1 fails in every mode | 2 | gate step unit test | exit 1 treated like 3 | 7 |
| 46 floor | a Regression is red in census mode; its conda package red; `covfloor_held` green | 2 + 3 | covcheck ratchet test plus gate unit test; `coverage_gate_reds` (census-mode red with the Regression line) | census mode ignores regressions | 7 |
| 46 census_doc_edited, floor_lowered, pin_no_reason | census check reds | 2 | census tool (Zig port) unit tests | compare only line counts | 7 |
| 46 mojo_test_conda | the conda waits for a named mojo_test's run | 3 | `coverage_keys` row | drop coverage_tests runs from the join | 5 |
| 46 mojo_test refusals, test_path, shared_lib_enforce | analysis refusals | 3 | `analysis_refusals_coverage` | delete the no-args check | 3 |
| 46 codegen, coverage_tests_analysis, no_gate | gate counts under the switch; ledger | 3 | `coverage_analysis` | add a gate to a coverage_tests library | 5 |
| 46 branch_gate_rows | each row names a library under src/ | 1 | target depending on each row, requiring MojoInfo (drops the rule-kind check) | a row naming nothing | 2 |
| 47 test_fails, banner, no_profile, raw_version | cov_branch_run decisions | 2 | Zig port unit tests | skip the version check | 7 |
| 47 annotate refusals, branchwide | cov_branch_annotate refuses; reads its whole input | 2 | Zig port unit tests on captured fixtures | drop the branch-weights scan | 7 |
| 47 nodebug | classify refuses a nodebug call site | 2 | existing classify cases plus a captured Mojo IR fixture | accept the call site | 7 |
| 47 test_env | LLVM_PROFILE_FILE refused | 3 | `analysis_refusals_coverage` | delete the `fail()` | 3 |
| 47 link_line | a link without `-lm` is not the release link | 2 | Zig port of the comparer | ignore removed flags | 7 |

### Sourced: node, proto, public_boundary, rust; golden.sh; lint_weld.sh; negative/

| id | what | bucket | lands in | mutant | slice |
|---|---|---|---|---|---|
| 54 node_test verdict | stderr-only, fixed-string, case-sensitive expect_error | 2 | node_test runner (Zig port of the embedded script) | match as a regex | 8 |
| 54 node analysis refusals | 8 `fail()`s | 3 | `analysis_refusals_node` | delete the staged-twice check | 3 |
| 54 unresolved_import | a failing esbuild fails the build | 3 | `planted_red_builds` (no Zig port only for this) | ignore esbuild's exit status | 4 |
| 54 npm integrity | SRI checks, all 64 bytes | 2 | npm_unpack (Zig port) unit tests | compare a digest prefix | 8 |
| 54 npm package.json | top-level string name/version compared whole; nested_distractors is a must-accept case | 2 | npm_unpack unit tests, a duplicate-key case decided | take the first `"name"` anywhere | 8 |
| 54 npm exe | exe runs and prints the pin | 2 | npm_unpack unit tests | skip the version compare | 8 |
| 54 node_dist | bin/node, node_api.h, exact version | 2 | node_dist check (Zig port) | `-e` for `-f` | 8 |
| 54 c_warns | `-Wall -Werror` | 3 | `planted_red_builds` (2 only after a Zig launcher) | drop `-Werror` | 4 |
| 23 proto generated tests | test_person, test_team, test_tasks_db pass | 1 | welded as test_srcs (a small library for the bundled team) | wrong field type | 8 |
| 23 check_executor | proto build ran remotely | 3 | `local_zero` | a local test executor | 5 |
| 23 id/ident, proto_mismatch | generated struct follows the .proto, old name absent | 1 | gen_check present/absent on both `[gen]` outputs | emit both names | 8 |
| 23 proto_unbundled | without bundling only its own files are generated | 1 + 3 | gen-set check on a generate-only form; one `planted_red_builds` row | bundle the closure anyway | 8 |
| 23 db_undeclared | a declared output not written fails | 2 | shared generation wrapper (proto and aws) | drop the non-empty check | 8 |
| 23 bundle_only, full_bundle | exactly the selected files | 1 + del | gen-set check | ignore bundle_only | 8 |
| 23 bad_selection | outside the closure refused | 3 | `analysis_refusals_proto` | delete the membership check | 3 |
| 23 gcp greens, functional | build | del | already in the gate | n/a | 2 |
| 23 gcp analysis refusals | 10 `fail()`s | 3 | `analysis_refusals_gcp_client` | delete the roots-or-methods check | 3 |
| 23 omit_unknown_field, rest_streaming | plugin refusals | del | existing Rust unit tests | n/a | 2 |
| 23 omit_pruned_field | pruned-message field refused | 2 (Rust) | new Rust unit test in lower.rs | drop the pruned check | 2 |
| 23 rest_reaches_plugin | default protocol reaches the plugin | 1 | gen_check on a default-protocol client | default to grpc | 8 |
| 23 caller_test_red | a failing caller test blocks the client | del | tests_check plus the gate runner unit test, so the shell row stays until that test exists | drop caller tests from the gate | 7 |
| 23 absence/tests_check_can_fail | the checkers can go red | 2 | gen/tests checker (Zig port) | compare as a subset | 8 |
| 23 proto_codegen, proto_fixture greens | build | del | already in functional | n/a | 2 |
| 23 proto_fixture planted defects | 11 legs refused | del | `refuses_*` twins in proto_fixture_testdata | n/a | 2 |
| 23 determinism | two builds give identical plugins, sources, package | 1 + open | in-action double run of each plugin; `determinism_proto` for compile bytes | HashMap-ordered output | 10 |
| 44 public_boundary greens | lint and ok tree | del | already in the gate | n/a | 2 |
| 44 dates, home, ip, host, email, sha, file classes | each planted spelling is a finding | 2 | public_boundary (Zig port) table tests | drop the compact date matcher | 6 |
| 44 paths_attr | a file given through `paths` is read | 1 | a held finding in a `paths`-only file of ok | stop staging `paths` | 6 |
| 44 holds, hosts ledgers | ledger rows validated, shrink exactly | 2 | ledger parser shared with pointer_lint | accept a held count above actual | 6 |
| 44 window, empty | bad window refused; empty tree fails | 2 | public_boundary args; zero-input guard in the shared lint runner | drop the checked>0 guard | 6 |
| 44 window pin | the root target's window | 1 / del | load-time check, or delete | narrow the window | 2 |
| 44 no_tree, both | xor refused | 3 | `analysis_refusals_lint` | delete the `fail()` | 3 |
| 22 rust_example | prost example run_check | 1 | rust `[run_check]` as a validation | change expected stdout | 2 |
| 22 rust_missing_dep | a crate not in deps does not reach rustc | 3 | `planted_red_builds` | pass every vendored crate | 4 |
| 22 rust host floor | rustc and sysroot NEEDED resolve via `$ORIGIN` or glibc | 1 (proposed) | Zig ELF-closure check over the sysroot | a sysroot with an absolute RUNPATH | 8 |
| 35 rust ext green | external tests gate the library | 1 | move to the komira cell plus a marker-list check, `both` included | drop test_srcs from the gate | 2 |
| 35 rust ext red | a failing external or unit test blocks the library and its consumer: `ext_red` (with `1 passed; 1 failed`), `ext_red_consumer`, `both_red`, `both_ext_red` | 2 + 3 | gate runner unit test; `gate_wiring` cases, one per target | accept a non-zero harness exit (unit); the library's marker list drops the external test's marker (scenario) | 7 |
| 35 rust ext refusals | test_srcs must be `tests/<ident>.rs` | 3 | `analysis_refusals_rust` | delete the `.rs` check | 3 |
| golden check | config hash and per-sample aquery hashes equal the golden; a flipped digit refused | 3 | `golden_linux_x86_64`, keeping the empty-aquery and unreadable-configuration guards | add a flag to the compile command | 5 |
| golden gen | regenerates | 3 | `--regen` flag of that scenario | n/a | 5 |
| golden tree, actions | hand tools, no caller | del | nothing | n/a | 5 |
| golden shell_lint | shellcheck of golden.sh | del | removed with golden.sh | n/a | 5 |
| tool_lib.sh | inspect, cfg_value, props_norm, whatran_actions | 3 | helper lib, each with a fixture unit test | take the first ` (` when cutting the identity | 11 |
| negative/spsc_ring_* | element refusal; race falsifier; no caller | open | a scenario, or delete as one-off proofs | n/a | 11 |
| negative/ fixtures | planted inputs | per row | become Zig test data or scenario fixtures with their rows | n/a | with its last row |

## Bucket-3 scenarios

All under `//tools/build/selftest/`, one Zig test target each:

- Executors and platforms: `local_zero`, `action_properties`, `exec_platforms`, `uquery_select_branches`,
  `darwin_platform`.
- Graph queries (or BXL checks in the gate, see "Open decisions"): `aquery_host_paths`,
  `config_hash_pin`, `docs_package_coverage`, `test_weld_real_graph`, `golden_linux_x86_64`.
- Analysis and load refusals (tables of target, `-c` overrides, exact message):
  `analysis_refusals_mojo`, `_aws_client`, `_gcp_client`, `_proto`, `_readme`, `_lint`,
  `_python_oracle`, `_node`, `_rust`, `_coverage`, `_platform_table`, and `config_refusals`.
- Builds that must go red: `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
  `assert_level_reds`, `test_limits`, `coverage_gate_reds`.
- aquery diffs: `assert_level_commands`, `aquery_opt_levels`, `coverage_platforms`, `coverage_keys`,
  `coverage_analysis`, `coverage_switch`.
- Scratch trees and clones: `consumer_cell_cache`, `buck2_run_fresh_clone`, `fresh_clone_local_default`,
  `lint_weld`, `bootstrap_pin`, `docker_run`.
- Determinism (blocked on the forced-execution ruling): `bundle_determinism`, `conda_determinism`,
  `determinism_proto`.
- Not before macOS workers are in CI: `darwin_build_run`.

## Keeping scenarios out of the gate

Every scenario test target carries `target_compatible_with` a constraint value,
`//tools/build/selftest:on_runner`. Its setting, `//tools/build/selftest:runner_setting`, has no value in
any platform of `tools/build/platforms` and no default. One platform holds it:
`//tools/build/selftest:runner`, which is `linux-x86_64`'s constraints plus `on_runner`. This keeps the
scenarios out of `pr / check` at both steps:

- **derive_checks.py.** Its universe is `buck2 cquery //... + tests//functional/...` for the default
  target platform, and its own docstring says that a target incompatible with that platform is not in
  the universe. So no scenario target is in `tools_build` or in any other derived check.
- **build_targets.sh.** It runs `buck2 build` and then `buck2 test` on the unit's patterns
  (`//tools/build/...` for `tools_build`). When buck2 expands a pattern, it skips incompatible targets,
  so neither command reaches a scenario. A unit that named a scenario label exactly would fail, because
  an incompatible target named on the command line is an error. No declared unit may do that.
- **What still runs in the gate.** The scenario binaries (`zig_exe`) and `//tools/build/selftest:lib`
  stay compatible with the default platform, with their welded unit tests. So a scenario that no longer
  compiles, or a helper unit test that fails, turns `pr / check` red. Only the test targets that drive
  buck2 are kept out.
- **Defense in depth.** The rule passes `--on-runner` only through
  `select({":on_runner": [...], "DEFAULT": []})`, and the helper library refuses to run without it. The
  planted mutant for this section is to delete `target_compatible_with` from one scenario. Then
  `pr / check` on a `tools/build` change runs that scenario, and it goes red on the missing flag instead
  of driving buck2 on the gate. Slice 3 shows this red.

Rejected options:
- A cell of its own. It is outside the universe, so the scenario code would not even be compiled in the
  gate until the scheduled run. Putting the scenarios in the tests cell outside `tests//functional` has
  the same problem.
- A label that `build_targets.sh` excludes. That is filter logic in a shell script, which the
  build-architecture ruling refuses, and `derive_checks.py` would still list the targets.

**The CI entrypoint is one target.** `//tools/build/selftest:scenarios` is a `selftest_suite` whose
`tests` attribute names every scenario. It carries the same constraint, so it is out of the gate too.
The scheduled workflow's step is

```sh
./buck2 test --target-platforms //tools/build/selftest:runner //tools/build/selftest:scenarios
```

The step has no logic in YAML. The one flag selects the platform that the scenarios are compatible
with, and that flag is the opt-in. A single scenario runs the same way, with its own label. A
developer's `./buck2 test //...` skips every scenario as incompatible.

## How a scenario runs

A scenario is a `buck2 test` target that runs buck2. Four things make that work.

1. **The rule.** `selftest_scenario` (Starlark, `tools/build/selftest/defs.bzl`) returns an
   `ExternalRunnerTestInfo`. Its command is the scenario's Zig binary itself, with no shell around it.
   The rule takes that binary as an `exec_dep`, so it is configured as the gate configures it and is a
   cache hit from the gate. Its other inputs:
   - The pinned buck2 release, also an `exec_dep`: a `pinned_file` of the asset `tools/buck2` names,
     unpacked by a Zig tool. The `./buck2` script is used only by the `bootstrap_pin` scenario, as the
     program under test.
   - The fixtures, as `data`.
   - `--on-runner`.

   The rule sets `run_from_project_root = True` and a `default_executor` that is local-only.
2. **Local execution, on the runner only.** A scenario is a client of buck2. It needs the checkout,
   which is what it tests, and a daemon. A remote worker has neither, so the test process runs on the
   client. This is the one local execution in the design. It is a test execution, not a build action:
   the scenario binary and every action that an inner build runs execute on the farm. The constraint
   above means the client is the farm-attached CI runner. Reading the checkout outside declared inputs
   is what a scenario is for, and the rule says so by running from the project root. A build action
   never does this.
3. **No recursion into the outer daemon.** The outer `buck2 test` holds its daemon until every test
   has finished. An inner command in the same project root, under the default isolation dir, would
   reach that same busy daemon. So every inner command the runner issues in the checkout passes
   `--isolation-dir selftest_<scenario>`. That is one daemon per scenario, so scenarios that
   `buck2 test` runs in parallel share none. The helper library stops that daemon
   (`buck2 --isolation-dir selftest_<scenario> kill`) on every exit path, including failures. An
   inner command never runs a scenario: the library refuses any `--target-platforms` naming the runner
   platform, so every scenario target stays incompatible inside.
   - A separate isolation dir changes output paths, so the inner builds do not hit the gate's cache
     entries. That costs remote execution, not correctness.
   - A scenario whose expectation depends on paths (`golden_linux_x86_64`, `consumer_cell_cache`, the
     clone scenarios) runs in a scratch tree instead. A scratch tree is its own project root, so it has
     its own daemon under the default isolation dir.
   - Slice 3 measures how many daemons the runner holds at once. If that is too many, the rule requires
     a local resource with a fixed number of slots, so concurrency is not set in YAML.
4. **The guard and the all-remote rule.** The guard checks the inner client's configuration. The
   client must be Linux x86_64, and every execution platform the inner daemon registers must be remote
   (`audit config`, `audit providers`). Local execution of the outer test process does not conflict
   with this: a test executor is not a registered execution platform, and the test process runs no
   build action. `local_zero` measures the inner builds, and what-ran for those builds must say local: 0.
   The one exception is `fresh_clone_local_default`. Its rule attribute sets `expect = "local"`, and it
   builds a scratch clone with no farm configuration on the runner, by design. That clone's daemon is
   the only one that executes locally, and it exists only on the runner.

## The helper library

`//tools/build/selftest:lib`, a Zig library with its own unit tests on captured fixtures (welded, so
they run in `pr / check`). Files stay under 1000 lines. It offers only what the scenarios above use:

- **Guard.** As above: `--on-runner`, a Linux x86_64 client, and every registered execution platform
  remote (or local for the one `expect = "local"` scenario). A refusal is a failure, never a pass.
- **Runner.** The buck2 binary comes from the rule's `--buck2`. The runner takes argv, a cwd (the
  project root or a scratch tree), `-c` pairs, `--target-platforms` and a timeout. It always adds the
  scenario's `--isolation-dir` in the checkout. It captures exit, stdout and stderr into a per-scenario
  log directory under the test's `$TMPDIR`. Every failure names its log file. Every daemon it started
  is stopped with `buck2 kill` under the same isolation dir.
- **Expectations.**
  - `expectBuildOk(targets)`.
  - `expectBuildFails(target, text)`. "Built but must fail" and "failed without the text" are distinct
    failures.
  - `expectTestFails(target, text, test_args)`.
  - `expectAbsent(log, patterns)`.
  - `expectFindings(log, n)`.
  - A refusal table runner that builds analysis only.
- **No silent pass.** A scenario that executes nothing, asserts nothing, or SKIPs fails.
- **Parsers.**
  - what-ran JSON into actions with category, executor and normalized properties. An empty run is a
    failure.
  - aquery JSON into actions with category, identifier, argv, env and inputs, plus a diff across
    configs and an absolute-path scanner.
  - cquery configurations, `audit execution-platform-resolution`, uquery label sets, `audit config`
    values, and a BXL runner.
- **Scratch tree.** It snapshots the committed tree, plus the local farm config if present, under
  `$TMPDIR`. It plants a file or BUCK edit, runs the tree's own daemon, and always kills that daemon and
  deletes the tree, even on failure (`--keep-scratch` keeps it).
- **Digests.** A sorted file-hash manifest of output trees, and a diff that names the files that differ
  (determinism).
- **Golden I/O.** It compares the scenario output to a committed golden line by line, and supports
  `--regen`.

## How CI runs it

Bucket 1 and bucket 2 run inside `pr / check` like any other target. They are the gate.

Bucket 3 runs only in the scheduled build-system self-test workflow, which is farm-attached and today
runs `run_tests.sh`. Slice 3 adds the step above before the `run_tests.sh` step. Until slice 11, the
workflow keeps calling `run_tests.sh` for the rows that are not converted yet. Slice 10 removes the
pixi step, because the conda install scenario takes `//tools/build/toolchains:pixi` as a dep. Slice 11
removes the `run_tests.sh` step, so the workflow is checkout, farm-connect, the one `./buck2 test`
step and `./buck2 kill`.

## Slice plan

Each slice is one pull request. It converts its rows (the **slice** column), shows each row's planted
mutant going red (in the PR text), and deletes those shell lines, fixtures and lint entries in the same
commit. The bookkeeping goes with them:
- the `tools/build/tests/BUCK` shell_lint globs and the `export_file`s of deleted scripts;
- the root `//:tests_lints` entries;
- the sections of `tools/build/tests/README.md` for the converted rows, which each slice cuts to a
  pointer at the new target, test or scenario;
- the README, `docs/ci.md` and platform README pointers.

A slice that deletes a script also deletes the line that calls it, and a caller is deleted only in or
after the slice of its last callee. Slice 11 deletes `run_tests.sh` last.

1. **This design.** Docs only.
2. **Deletes and gate gaps (no new tool).**
   - Delete the `del` rows.
   - Make `[run_check]` a validation for Mojo and Rust.
   - Move the parked greens to functional, and move `td_mojo_test` to the komira cell so that
     `build_targets.sh` tests it.
   - Move the report floors into the case actions.
   - Add the s2n probe `fail()` and the `branch_gate_rows` target.
   - Add the two Rust unit tests (`omit_pruned_field`, `unknown_operation`) and the window-pin check.
3. **Helper lib, the scenario rule and the analysis-only scenarios.**
   - `//tools/build/selftest:lib` with its unit tests.
   - `selftest_scenario`, `selftest_suite`, the constraint and the runner platform, with the
     `target_compatible_with` mutant red.
   - `exec_platforms`, `uquery_select_branches`, and the `analysis_refusals_*` and `config_refusals`
     tables.
   - The workflow step.
4. **Red builds.** `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
   `assert_level_reds`, `test_limits`, `coverage_gate_reds`.
5. **aquery, what-ran and graph queries.**
   - `local_zero`, `assert_level_commands`, `aquery_opt_levels`, and the `coverage_*` aquery scenarios.
   - `config_hash_pin` and the other graph-query rows, as BXL or as scenarios per the ruling.
   - `golden_linux_x86_64`.
6. **Lints and checkers, with unit tests.**
   - The Zig ports: test_weld, pointer_lint, src_layout, refused_imports, readme_api_coverage,
     surface_capability_matrix, public_boundary, the shared lint runner and the limits checker.
   - The unit tests of the Mojo tools: doc_links, readme_examples and the doc JSON checker.
   - The new file lints (17, 19) with the toolchains-cell file list, the readme marker check, and the
     aws env scanner.
7. **Runners to Zig.**
   - The gate runner, the compile wrapper (with its watchdog cases), the Rust test runner and the
     bounded-run tool (mem_cap and test_deadline cases).
   - cov_run, the gate step, the census tool, cov_branch and the link-line comparer.
   - Each with the unit tests its rows list.
8. **Inspection tools and generators.**
   - The ELF and Mach-O check tool (if the proposal below is accepted), the glibc level check, and the
     bundle and format content checks.
   - The node tools.
   - The proto and aws generation wrapper, the gen/tests checker and the aws_codegen checker.
9. **Clones and scratch trees.** `consumer_cell_cache`, `buck2_run_fresh_clone`,
   `fresh_clone_local_default`, `lint_weld`, `bootstrap_pin`, `docker_run`.
10. **Forced execution and determinism**, once ruled on: `action_properties`, `bundle_determinism`,
    `conda_determinism` with the conda manifest checks and the pixi install, and `determinism_proto`
    with the in-action double run.
11. **The rest, then the harness.**
    - Darwin (24): `darwin_platform`, and the Mach-O and stand-in checks on the slice 8 tools.
    - The spsc_ring ruling.
    - Then delete `run_tests.sh`, `tool_lib.sh` and the shell_lint target.
    - Replace `tools/build/tests/README.md` with a short page: what the tests cell holds (fixtures for
      targets and scenarios), how to run a scenario, and a link to this inventory.

### Shell files and the slice that deletes them

The harness: `run_tests.sh` 11, `tool_lib.sh` 11.

Sourced sections:

| file | slice |
|---|---|
| `cxx_tests.sh` | 8 |
| `c_libs_tests.sh` | 8 |
| `rust_tests.sh` | 8 |
| `proto_tests.sh` | 10 |
| `coverage_tests.sh` | 7 |
| `coverage_run_tests.sh` | 7 |
| `coverage_gate_tests.sh` | 7 |
| `coverage_branch_tests.sh` | 7 |
| `public_boundary_tests.sh` | 6 |
| `assert_level_tests.sh` | 7 |
| `node_tests.sh` | 8 |
| `golden/golden.sh` | 5 (with its call in `platform_table/check.sh`) |
| `negative/lint_weld.sh` | 9 |
| `negative/spsc_ring_element.sh`, `negative/spsc_ring_prefix_layout.sh` | 11 |

The 16 `functional/` drivers the harness calls:

| driver | slice |
|---|---|
| `assert_level.sh` | 5 |
| `opt_level.sh` | 5 |
| `coverage_keys.sh` | 5 |
| `coverage_platforms.sh` | 5 |
| `coverage_shared_lib.sh` | 5 |
| `platform_table/check.sh` | 6 |
| `glibc_level.sh` | 8 |
| `umbrella_cache.sh` | 9 |
| `buck2_run.sh` | 9 |
| `local_default.sh` | 9 |
| `bootstrap.sh` | 9 |
| `formats.sh` | 9 |
| `bundle.sh` | 10 |
| `conda.sh` | 10 |
| `conda_set.sh` | 10 |
| `darwin/check.sh` | 11 |

When `conda.sh` and `conda_set.sh` go, slice 10 also drops their argument case from
`functional/install_gate:cases`.

Action scripts that targets run, not the harness:
- Replaced by their rows' Zig ports: `functional/aws_codegen/aws_codegen.sh` 8,
  `platform_table/limits_retired.sh` 6, `coverage/link_line.sh` 7, `mem_cap/cases.sh` 7,
  `test_deadline/cases.sh` 7, `watchdog/cases.sh` 7, `test_data/runner_cases.sh` and
  `test_command_case.sh` 7.
- Not in this design: `bundle_parity/parity.sh`, `coverage/{check,report,branch_check}.sh` and
  `install_gate/{cases,install_gate}.sh`. They are the actions of green functional targets that are
  already in the gate. Their port is part of the rule-script work under the build-architecture
  ruling.

The Markdown of the tests cell:
- `README.md` shrinks each slice and is replaced in slice 11.
- `lint_tests.md` and `readme_examples.md` are deleted in slice 6.
- `assert_level.md` and `coverage_runs.md` are deleted in slice 7.
- Each of these files has a check / proves / mutant table. Those facts move into the doc comment of the
  scenario or unit test that takes the row, and links to them (`tools/build/mojo/README.md`,
  `docs/ci.md`) are updated in the same slice.

`re_probe/` is not a check, and nothing in the harness runs it. It is a diagnostic that
`tools/build/toolchains/README.md` cites as the evidence for the host floor. It stays in the tests cell,
and no slice changes it. Its action runs a busybox shell script, so it falls under the rule-script work
of the build-architecture ruling: a Zig probe, or an allowlisted entry.

## Open decisions

- **Bucket 2 form.** The direction says plain `buck2 test` targets next to the tool. Both forms run in
  `pr / check`. The trade-off:
  - **Welded `zig_test`** (the repo's precedent, and this design's preference). The tool cannot be
    built unless its tests pass, so every build that uses the tool runs them or reuses them from the
    cache. A cache hit is proof of a pass on identical inputs. The cost is that a red test blocks every
    build that uses the tool, unrelated work included, and the failure is reported as a build failure,
    not as a test result.
  - **A plain `buck2 test` target.** It reports per test through `buck2 test`, and a red test does not
    stop other builds. But it runs only when a change reaches the tool's derived check, and a consumer
    can be built on a tool whose tests are red. Whether a passing test result is reused across runs
    depends on the test executor. A welded build action is always cached by its digest.
- **Forcing execution with the cache on.** Rows 12, 15, 33a/b and proto determinism use
  `--no-remote-cache` and `--isolation-dir` today. The proposal is a salt (`-c selftest.salt=<nonce>`)
  that every rule folds into its action keys. Until that is ruled on, slice 10 cannot land as written.
- **ELF inspection as bucket 1.** The direction lists ELF inspection under scenarios. Rows 6, 8
  runtime_run_paths, 26 exports, 20 C++ runtime and 22 host floor read only built artifacts. An in-build
  Zig ELF check puts them in the gate and drops the host `readelf`. This is a proposed deviation.
- **Graph queries as BXL in the gate.** Rows 5, 17 doc_pkgs, 18 and 39 real_red could run as BXL checks,
  following the test_weld precedent in `build_targets.sh`, instead of as scenarios.
- **Scope of the Zig port.** doc_links and readme_examples are Mojo tools today. The aws env scanner is
  Mojo text generated in aws.bzl. The Rust plugin's tests stay in Rust.
- **darwin build and run (24).** The leg runs only when macOS workers are configured, which CI does not
  have today. It is dropped, not skipped, until they are, and then it returns as `darwin_build_run`.
- **lint_weld after the port.** Once the rules run no shell, the scenario re-aims at whatever lint stays
  welded, or goes away.
- **The spsc_ring scripts.** Nothing runs them. Keep them as scenarios or delete them as one-off proofs
  (slice 11 either way).
