# Build self-tests: dissolving run_tests.sh

This is the design for replacing [tools/build/tests/run_tests.sh](../../tools/build/tests/run_tests.sh),
the files it sources, [tool_lib.sh](../../tools/build/tests/tool_lib.sh),
[golden.sh](../../tools/build/tests/golden/golden.sh) and
[lint_weld.sh](../../tools/build/tests/negative/lint_weld.sh). The build system's tooling is Zig, so its
tests are Zig too. The script is not ported as one runner with a table of cases. It is dissolved: each
check moves to the cheapest place that can still fail. This doc lists every check, says where it goes and
which planted defect proves it can go red. The conversion then lands in slices (the last section).

Status: design, nothing converted yet. Today the script runs nightly
([ci.md](../ci.md#build-system-self-tests)) and is not the gate. When the conversion is done, every
check runs in `pr / check`, and nothing runs on a schedule.

## The three buckets

1. **A target.** A "this should build" check is an ordinary target in a unit that `pr / check`
   builds. When a check only reads built artifacts (an ELF or Mach-O binary, a report, a marker), it
   becomes an action that takes them as inputs. Then it runs on the farm and sits in the gate. Two kinds
   of bucket-1 check are decided and have their own sections: binary inspection, an in-build Zig step
   (see "Binary inspection"), and graph checks, BXL scripts that the gate runs (see "Graph checks in the
   gate").
2. **A welded Zig unit test next to the tool.** A check of the form "our tool must refuse this input"
   feeds the tool a bad input and asserts the exit code and the message. It lives next to the tool's
   source as a `zig_test` (`tools/build/mojo/toolchain.bzl`), welded into the tool: `zig test` runs as a
   build action that the tool's `zig_exe` consumes through `unit_tests`, so the tool cannot be built
   unless its tests pass, and a cache hit is a pass on identical inputs. This form is decided (see
   "Decisions"). A tool that is Rust (the proto-codegen plugin) or Mojo (covcheck) keeps its tests in its
   own language, next to it.
3. **A scenario.** This covers only what must drive buck2 from outside: what ran and where (local: 0),
   two-build determinism, consumer-cell clones, analysis-time and load-time refusals, builds that must
   go red, and client queries that need their own `-c` overrides or target platforms (`aquery`,
   `cquery`, `audit`, `log what-ran`). Each scenario is **one Zig
   test target**, named, runnable alone, under `//tools/build/selftest/`. They share one small helper
   library. Scenarios run in `pr / check`, like every other test, whenever a pull request touches
   `tools/build/**`: their package is one declared check, and such a change widens the check to every
   unit (see "Scenarios run in pr / check" and "How a scenario runs").

This follows the build-architecture ruling:
- the rules are Starlark;
- every CI entrypoint is a Buck2 target, so a workflow step is one `./buck2 build|test|run` and holds
  no logic;
- rules invoke only Zig-built tools;
- there is no host shell outside an allowlisted set of thin wrappers.

Every action this design adds runs a Zig-built tool, and every check it adds is a Buck2 target. It adds
no CI step, no workflow logic and no shell: a scenario is a `buck2 test` target that `pr / check`
already runs through its existing commands (`derive_checks.py`, `build_targets.sh`). The design
changes `derive_checks.py` not at all and `build_targets.sh` in one place: its BXL step, which runs the
test_weld check today, also runs the graph checks (see "Graph checks in the gate"). Existing rule scripts that the rows below lean on (`run_check.sh`, the
`cases.sh` actions) keep running until their own Zig port. Rows 28, 29 and 49 schedule the ports of the
case scripts. The rest, and the port of `derive_checks.py` and `build_targets.sh`, belong to the
build-architecture ruling's own work, not to this design.

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

## Binary inspection

Binary inspection is an in-build Zig step (bucket 1). One Zig tool, `//tools/build/binary_check`, has one
check API for both formats. It reads the file's magic and parses an ELF on Linux or a Mach-O on macOS.
There is no PE or Windows support now. The five checks:

| check | ELF (Linux) | Mach-O (macOS) |
|---|---|---|
| run paths | `DT_RUNPATH` and `DT_RPATH` | `LC_RPATH` |
| needed libraries | `DT_NEEDED` | `LC_LOAD_DYLIB` |
| exported symbols | defined symbols in `.dynsym` | the export trie |
| C++ runtime | libstdc++ or libc++ | libstdc++ or libc++ |
| platform floor | the highest `GLIBC_` symbol version the file needs | `LC_BUILD_VERSION` `minos` |

- **The C++ runtime check** reports which runtime a binary uses, from its needed libraries and, for a
  static link, from the runtime's own symbols. The caller states the expected runtime.
- **The platform floor** is compared with the platform row's floor in `tools/build/platforms/table.bzl`:
  glibc 2.34 for the Linux rows, `macos-11.0` for darwin-arm64.
- **How it fails the build.** A Starlark helper adds a `binary_check` action that takes the binary (or an
  unpacked tree) as its input and the expectations as arguments. The tool writes its report only when
  every check passes. Otherwise it exits non-zero and prints each finding. The report is a
  `ValidationInfo` of the checked target, or the default output of a functional check target, so the
  unit that builds the target fails. A check that reads nothing fails too: no dynamic section where run
  paths are expected, or zero run paths read across a tree.
- **Its unit tests** are a welded `zig_test`. The fixture binaries are built by `zig cc` as build actions
  of the test, as ELF and as Mach-O (Zig cross-compiles both from Linux). Each check has a passing case
  and a planted-defect case, and the no-dynamic-section case is one of them.
- **The planted mutants in the real build**, one per check (each row below names its own):
  - run paths: an absolute run path in `hello`'s link (row 6), an unrewritten vendor `DT_RPATH` (row 8),
    an absolute `LC_RPATH` in the darwin `hello` (row 24);
  - needed libraries: a non-glibc library in the bundle launcher's link (row 15), an `LC_LOAD_DYLIB`
    outside the runtime library and the system (row 24);
  - exported symbols: aws-lc built without hidden visibility (row 26);
  - C++ runtime: snappy's test linked against libstdc++ (row 20);
  - platform floor: the glibc version dropped from the launcher's `zig_triple`, so it links against
    Zig's default glibc and needs a newer `GLIBC_` version (row 15); `.11.0` dropped from the darwin
    `zig_triple` (row 24).
- It replaces the host's `readelf`, `objdump` and `otool` in the shell rows. Slice 8 lands the tool and
  the Linux checks, and slice 11 the darwin checks.

## Graph checks in the gate

A graph check reads the build graph, not built files: a `cquery`, `uquery` or `aquery` of the real
rules. Graph checks are BXL scripts that the gate runs, following the test_weld precedent in
`build_targets.sh`. They are not scenarios.

- **The target.** Each graph check is a `graph_check` target under `//tools/build/selftest/graph/`, in
  the declared check `build_selftests`. It names the check and the targets it queries as strings, never
  as dependencies. Its only dependencies are its BXL source and its Zig checker.
- **How the gate runs it.** `build_targets.sh` runs `buck2 bxl //tools/build/lint/test_weld.bxl:check`
  for every `test_weld_rule` target of the batch today. That step also queries the batch for
  `graph_check` targets and runs `buck2 bxl //tools/build/selftest/graph/checks.bxl:check -- --check
  <label>` for each one. This is the one change to `build_targets.sh`.
- **How it fails.** The BXL collects the facts and writes them to a file. The check's Zig checker then
  runs over that file as a build action on the farm. A finding fails that action, `buck2 bxl` exits
  non-zero, and the unit fails. Each checker has welded unit tests over captured facts.
- **The checks:**
  - `aquery_host_paths` (row 5): no action argv or env names an absolute host path.
  - `docs_package_coverage` (row 17 doc_pkgs): every package is in `deps(//:docs)`.
  - `config_hash_pin` (rows 18 and 37 table_vs_tree): the only configuration in `hello`'s closure is the
    pinned hash, and each registered row's `golden_config_hash` is buck2's hash for its platform.
  - `test_weld_real_graph` (row 39 test_weld_real_red): over the real rules, exactly the 3 unwelded
    files are named.
  - `golden_linux_x86_64` (the golden rows): the configuration hash and the per-sample aquery hashes
    equal the committed golden. `-- --regen` prints a new golden.
  - `selftest_closure` (no row; slice 3): the closure of `//tools/build/selftest/...` holds no `//src/`
    label. It keeps true what slice 3's `--plan` proof shows once (see "Only a widened change reaches
    `build_selftests`"). Mutant: the same one as the `--plan` proof, a library under `src/` added as a
    dependency of one scenario target.
- A graph query that needs its own `-c` overrides, such as the aquery diffs across coverage and
  optimization switches, stays a scenario: a BXL script runs in the gate's own configuration.

## Scenario inventory

Bucket: `1` target, `1 (BXL)` a graph check run in the gate, `2` Zig (or tool-language) unit test,
`3` scenario, `del` delete, `open` needs a ruling. Numbers are the test numbers in `run_tests.sh`. Scenario names are under `//tools/build/selftest:`.
**Slice** is the one pull request that deletes the row's shell lines (see "Slice plan"). A mixed row
(`3 + 2`) is deleted in the slice of its last part. Its earlier parts land in earlier slices, and the
shell lines stay until then. Each of the 188 rows names exactly one slice. A fixture under `negative/`
goes with the last row that uses it.

### run_tests.sh, its own tests

| id | what | bucket | lands in | mutant | slice |
|---|---|---|---|---|---|
| 1 examples | the example targets build | del | already in their units | a compile error in hello.mojo reds the unit | 2 |
| 1 run_checks | hello, hello_pkg_user, cadd_user print their expected_stdout | 1 | `[run_check]` as a validation | change hello's expected_stdout | 2 |
| 1 check_executor | every action of the run ran remotely or was a cache hit | 3 | the helper runner's what-ran check after every inner build (local: 0 in every scenario); `local_zero` proves that check can go red, with one `buck2 test` leg. `local_zero` plants a per-run change (a new value in a fixture source of its scratch tree) so that at least one action executes on every run, warm cache or not, and it fails when no action executed | a hybrid executor that prefers local on one platform, so the planted action really runs locally; a what-ran that lists no action must fail too, not SKIP | 5 |
| 2 gate_red | a library whose welded test fails does not build: GATED TEST FAILED | 3 + 2 | `gate_wiring` case "library default output red"; gate runner unit test (exit, message) | `default_output = ungated` with MojoInfo still gated (scenario); runner exits 0 on a failing test (unit) | 7 |
| 2 gate_ungated_green, sharedlib_*_ungated | the `[ungated]` fixtures compile, so the red comes from the test | 3 | precondition inside `gate_wiring` / `shared_lib_gate` (could also be a functional target depending on the sub-target) | a compile error in the fixture fails the precondition | 4 |
| 2 gate_consumer_red | a binary on a red library fails | 3 | `gate_wiring` | the published .mojoc stops taking the PASS markers as inputs | 4 |
| 2 gate_bypass_refused | `[ungated]` in deps fails analysis | 3 | `analysis_refusals_mojo` | `[ungated]` returns MojoInfo | 3 |
| 2 sharedlib gate reds | missing export, unresolved symbol, failing driver, force_load, leaking symbols, duplicate definition | 3 | `shared_lib_gate` | drop the version script / `--exclude-libs`; drop `--whole-archive` | 4 |
| 2 sharedlib_empty_exports | empty exports refused at analysis | 3 | `analysis_refusals_mojo` | delete the empty-exports `fail()` | 3 |
| 3 missing_dep | a binary importing a package not in deps does not compile | 3 | `compile_isolation` | stage every package of the cell on `-I` | 4 |
| 4 closure_refusal | the compile wrapper refuses an incomplete toolchain closure | 2 | compile wrapper (Zig port) unit test: exit 2 and `REFUSING: toolchain member` (the shell checked only the text) | skip the closure check | 7 |
| 5 host_paths | no action argv or env names an absolute host path; scanner self-check on `/bin/sh` | 1 (BXL) | `aquery_host_paths` graph check; the scanner is its Zig checker, and the `/bin/sh` self-check is its unit test | add `/usr/bin/env` to the mojo_build command | 5 |
| 6 outputs | hello has exactly `DT_RUNPATH $ORIGIN/lib`, no `buck-out/`, and first finds a NEEDED runtime library | 1 | `binary_check` as a validation of hello: run paths exactly `$ORIGIN/lib`, the runtime library first in needed libraries; the `buck-out/` byte scan in the same action | an absolute run path in the link | 8 |
| 7 umbrella_cache | consumer-cell clones hit the same cache digests | 3 | `consumer_cell_cache` | a root-cell-relative path in an action's argv | 9 |
| 8 host_floor | loader trace: libstdc++/libgcc_s from the toolchain, the rest glibc | 1 | Zig checker inside `functional/runtime_libs:loader_trace` | drop the toolchain lib dir from the run's library path | 8 |
| 8 runtime_libs | loaded toolchain libs equal `hello[runnable]/lib` | 1 | `functional/runtime_libs:runtime_libs_match` | add a library to `mojo_runtime`'s list | 8 |
| 8 runtime_run_paths | every run path in `hello[runnable]/lib` is `$ORIGIN`-relative, at least one read | 1 | `binary_check` run-path check over the tree, which fails when it reads no run path | an unrewritten vendor DT_RPATH | 8 |
| 9 buck2_run | `buck2 run` from a fresh clone: greeting, downloads, relocatable | 3 | `buck2_run_fresh_clone` | RunInfo points outside run_dir | 9 |
| 10 exec_platforms | Mojo, toolchain and C targets resolve to linux-x86_64 | 3 | `exec_platforms` (one table with 20's C rows) | register a second platform first | 3 |
| 11 | retired; a comment | del | nothing | n/a | 2 |
| 12 action_platforms | a build runs 7 categories with the farm property set | 3 | `action_properties`, under its own isolation dir (see "Why a scenario's builds are fresh") | an empty property set for one category | 10 |
| 13 bundle_parity | functional parity target builds | del | already in the gate | n/a | 2 |
| 14 launcher_levels | level_test; launcher level equals glibc's on the host | del + 1 | level_test stays; `level_vs_glibc`, a Zig check action on a worker that compares the launcher's level for the worker's CPU with the worker's glibc loader | launcher level one too high without AVX2 | 8 |
| 15 bundle | layout, run paths, SHA256SUMS, a relocated and a symlinked run, the below-v3 refusal; two-build determinism | 1 + 3 | the layout and run legs as Zig check actions over `hello`'s bundle (functional targets), with `binary_check` for the run paths, the launcher's needed libraries (glibc only) and its platform floor (glibc 2.34); `bundle_determinism` (two isolation dirs) | a timestamp in the tarball; an absolute run path in the bundle; a non-glibc library in the launcher's link; the glibc version dropped from the launcher's `zig_triple` | 10 |
| 16 formats | tarball/OCI content and its determinism rules, pinned base layers; `docker load` and `docker run` | 1 + 3 | Zig check actions over the tarball and image; `docker_run` (`docker load` and `docker run` on `pr / check`'s runner) | drop mtime normalization in `oci/src/tar.zig` | 9 |
| 17 docs green | `//:docs`, doc_links:ok | del | already in the gate | n/a | 2 |
| 17 doc_links_dead | the link checker names missing file, bad anchor, escape, count | 2 | welded unit tests of the Zig `doc_links` port, which reads Markdown through the shared Zig markdown module (slice 6) | accept any `#fragment` | 6 |
| 17 doc_pkgs | every package is in `deps(//:docs)` | 1 (BXL) | `docs_package_coverage` graph check | a rule that does not call declares_docs | 5 |
| 17 tc_md | `tools/build/cells` holds no Markdown | 1 | doc lint over the committed files, with the toolchains-cell file list | commit a NOTES.md there | 6 |
| 17 named_doc_tree | no BUCK file calls doc_tree/package_docs itself | 1 | Zig lint over committed BUCK files | add `doc_tree(name = "x")` | 6 |
| 17 package_boundary_exceptions | neither cell sets it | 1 | lint over the committed .buckconfig files | set it in the tests cell's .buckconfig | 6 |
| 18 config_hashes | the only configuration in hello's closure is the pinned hash | 1 (BXL) | `config_hash_pin` graph check | add a constraint to the platform | 5 |
| 19 exported_cells | labels in exported BUCK/.bzl name only komira, prelude, toolchains (floor of 20) | 1 | Zig lint, with the toolchains-cell file list | a `tests//` label in mojo/defs.bzl | 6 |
| 21 location_path | `location_path:main[run_check]` | 1 | `[run_check]` as a validation | remove the staging-dir prefix map | 2 |
| 24 darwin platform | macOS registration only when configured, resolution, compile command lines, linux actions unchanged | 3 | `darwin_platform` (cquery/aquery with `--target-platforms` darwin-arm64, one aquery diff of the linux actions) | register the macOS platform with no configuration | 11 |
| 24 darwin Mach-O, stand-ins | the osx-arm64 closure's Mach-O load commands; the macOS scripts against stand-ins, the compile watchdog included | 1 + 2 | `binary_check` over the unpacked closure (run paths, needed libraries, platform floor `minos` 11.0), run on a Linux worker; unit tests of each macOS script's Zig port | an absolute `LC_RPATH` or `LC_LOAD_DYLIB` in the closure; `.11.0` dropped from the darwin `zig_triple`; the watchdog never fires | 11 |
| 24 darwin build_run | build and run check of `hello` and the shared-lib gates on macOS workers | 3 | `darwin_build_run`, planned in slice 11; its test target lands when the macOS build hosts are connected to CI (see "darwin_build_run") | an absolute load path in `hello`; the darwin property set dropped from the platform | 11 |
| 25 local_default config | a clone without farm config registers one local platform and refuses forced remote (legs 1-3: configuration only, no build command) | 3 | `fresh_clone_local_default` (scratch clone, `HOME` in the scratch dir, no user or system buckconfig) | pick a remote executor when the farm config is absent | 9 |
| 25 local_default builds | that clone builds toolchain actions, `hello` and the proto_check cases on the client (legs 4-6) | open | the local legs of `fresh_clone_local_default`, or deleted (see "Decisions") | local actions share scratch space | 9 |
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
| 33a/b conda, conda_set | determinism, manifests, pixi install | 1 + 3 | manifest checks as targets; `conda_determinism` (two isolation dirs), which also runs the pixi install | a build timestamp in the package | 10 |
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
| 36 env scan reds | getenv, pathlib spellings, t-strings, control bytes | 2 | unit tests of the env scanner, extracted from aws.bzl into a Zig tool | stop joining continuation lines | 6 |
| 37 platform_table | load-time table cases; a platform per registered row and none for the reserved one; `host` is the client's platform; the reserved row's key refused; the default platform's own key decides remote (legs 1-5) | 3 | `analysis_refusals_platform_table`; the key legs in `exec_platforms` | accept a pending pin; read another platform's key | 3 |
| 37 limits | limits.tsv: the real tree passes; a limit with no marker, a marker with no row, a row with no marker, a merged row with its marker are refused (leg 6) | 2 | unit tests of the limits checker's Zig port over fixture trees (the real tree stays a target) | accept a row with no marker | 6 |
| 37 table_vs_tree | each registered row's golden_config_hash is buck2's hash for the platform; the macOS row's applets (leg 7) | 1 (BXL) | `config_hash_pin` graph check (one check with 18) | a stale golden_config_hash | 5 |
| 38 readme_examples green | builds | del | already in the gate | n/a | 2 |
| 38 readme_marker | ok says one PASS line per example, none says NO EXAMPLE | 1 | a Zig check action over the sub-target outputs | PASS without an example | 6 |
| 38 raises, skip_word, shipped_relative_link | readme tool findings | 2 | unit tests of the Zig `readme_examples` tool, which the README examples work (#1273) writes | accept a `mojo skip` fence | 6 |
| 38 compile_error, unowned | a README compile error names the README's own line | 3 + 2 | `compile_isolation`; the Zig `readme_examples` tool's unit test (#1273) that line n of an example's program is README line n | shift a copied line off its README line; ignore `readme=False` | 6 |
| 38 owner_base_no_readme, readme_keyword | load refusals | 3 | `analysis_refusals_readme` | remove the bool check | 3 |
| 39 test_weld greens | the bxl passes | del + 1 | two already in the gate; move `real:ok` to functional | count a commented test_srcs | 2 |
| 39 test_weld planted reds | the checker names each ledger and weld defect | 2 | test_weld checker (Zig port) unit tests | let a row for a welded test pass | 6 |
| 39 test_weld_real_red | over the real rules, exactly 3 unwelded files named | 1 (BXL) | `test_weld_real_graph` graph check | read test_srcs from BUCK text | 5 |
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
| harness silence | a sub-script that reports nothing, or SKIPs on CI, is red | 2 | helper lib: a scenario that asserts nothing or SKIPs fails, and so does a build command whose what-ran lists no action | return early with no assertion | 11 |

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
| 26 exports, 20 C++ runtime | binaries export no defined dynamic symbol; libc++abi linked | 1 | `binary_check` exported-symbols check (none) and C++ runtime check (libc++, static) as validations of the c_libs and snappy test binaries | build aws-lc without hidden visibility; link snappy's test against libstdc++ | 8 |
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
| 23 determinism | two builds give identical plugins, sources, package | 1 + 3 | in-action double run of each plugin; `determinism_proto` for compile bytes (two isolation dirs) | HashMap-ordered output | 10 |
| 44 public_boundary greens | lint and ok tree | del | already in the gate | n/a | 2 |
| 44 dates, home, ip, host, email, sha, file classes | each planted spelling is a finding | 2 | public_boundary (Zig port) table tests | drop the compact date matcher | 6 |
| 44 paths_attr | a file given through `paths` is read | 1 | a held finding in a `paths`-only file of ok | stop staging `paths` | 6 |
| 44 holds, hosts ledgers | ledger rows validated, shrink exactly | 2 | ledger parser shared with pointer_lint | accept a held count above actual | 6 |
| 44 window, empty | bad window refused; empty tree fails | 2 | public_boundary args; zero-input guard in the shared lint runner | drop the checked>0 guard | 6 |
| 44 window pin | the root target's window | 1 / del | load-time check, or delete | narrow the window | 2 |
| 44 no_tree, both | xor refused | 3 | `analysis_refusals_lint` | delete the `fail()` | 3 |
| 22 rust_example | prost example run_check | 1 | rust `[run_check]` as a validation | change expected stdout | 2 |
| 22 rust_missing_dep | a crate not in deps does not reach rustc | 3 | `planted_red_builds` | pass every vendored crate | 4 |
| 22 rust host floor | rustc and sysroot NEEDED resolve via `$ORIGIN` or glibc | 1 | `binary_check` over the unpacked sysroot: run paths `$ORIGIN`-relative, needed libraries either files of the sysroot or glibc's | a sysroot with an absolute RUNPATH | 8 |
| 35 rust ext green | external tests gate the library | 1 | move to the komira cell plus a marker-list check, `both` included | drop test_srcs from the gate | 2 |
| 35 rust ext red | a failing external or unit test blocks the library and its consumer: `ext_red` (with `1 passed; 1 failed`), `ext_red_consumer`, `both_red`, `both_ext_red` | 2 + 3 | gate runner unit test; `gate_wiring` cases, one per target | accept a non-zero harness exit (unit); the library's marker list drops the external test's marker (scenario) | 7 |
| 35 rust ext refusals | test_srcs must be `tests/<ident>.rs` | 3 | `analysis_refusals_rust` | delete the `.rs` check | 3 |
| golden check | config hash and per-sample aquery hashes equal the golden; a flipped digit refused | 1 (BXL) | `golden_linux_x86_64` graph check, keeping the empty-aquery and unreadable-configuration guards; the flipped digit is a unit test of its checker | add a flag to the compile command | 5 |
| golden gen | regenerates | 1 (BXL) | `-- --regen` argument of that graph check | n/a | 5 |
| golden tree, actions | hand tools, no caller | del | nothing | n/a | 5 |
| golden shell_lint | shellcheck of golden.sh | del | removed with golden.sh | n/a | 5 |
| tool_lib.sh | inspect, cfg_value, props_norm, whatran_actions | 3 | helper lib, each with a fixture unit test | take the first ` (` when cutting the identity | 11 |
| negative/spsc_ring_* | element refusal; race falsifier; no caller | del | nothing: the scripts and their fixtures are deleted | n/a | 2 |
| negative/ fixtures | planted inputs | per row | become Zig test data or scenario fixtures with their rows | n/a | with its last row |

## Bucket-3 scenarios

All under `//tools/build/selftest/`, one Zig test target each:

- Executors and platforms: `local_zero`, `action_properties`, `exec_platforms`, `uquery_select_branches`,
  `darwin_platform`.
- Analysis and load refusals (tables of target, `-c` overrides, exact message):
  `analysis_refusals_mojo`, `_aws_client`, `_gcp_client`, `_proto`, `_readme`, `_lint`,
  `_python_oracle`, `_node`, `_rust`, `_coverage`, `_platform_table`, and `config_refusals`.
- Builds that must go red: `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
  `assert_level_reds`, `test_limits`, `coverage_gate_reds`.
- aquery diffs: `assert_level_commands`, `aquery_opt_levels`, `coverage_platforms`, `coverage_keys`,
  `coverage_analysis`, `coverage_switch`.
- Scratch trees and clones: `consumer_cell_cache`, `buck2_run_fresh_clone`, `fresh_clone_local_default`,
  `lint_weld`, `bootstrap_pin`, `docker_run`.
- Determinism, each as two builds under two isolation dirs: `bundle_determinism`, `conda_determinism`,
  `determinism_proto`.
- Planned now, its test target added when the macOS build hosts are connected to CI:
  `darwin_build_run` (see "darwin_build_run").

The graph checks (`aquery_host_paths`, `config_hash_pin`, `docs_package_coverage`,
`test_weld_real_graph`, `golden_linux_x86_64`, `selftest_closure`) are not scenarios. They are BXL
scripts run in the gate (see "Graph checks in the gate").

## Scenarios run in pr / check

The scenarios run in `pr / check` whenever a pull request touches `tools/build/**`. They are selected
by the derivation that already exists. Nothing in `pr.yml` or `derive_checks.py` changes, and nothing
filters them. The one change to `build_targets.sh` is for the graph checks, not for the scenarios (see
"Graph checks in the gate").

- **They are in the universe.** A scenario test target is compatible with the default target
  platform, so the `cquery` of `//...` in `derive_checks.py` sees it like any other target.
- **They are one declared check.** Slice 3 adds one check, `build_selftests`, to
  `release/artifacts.textproto`, with the `buck2` build system and the one target pattern
  `//tools/build/selftest/...`. No check is declared there today. A target a declared unit matches is
  not derived again, so the package leaves the derived check `tools_build`.
  It has to leave it. `tools_build` is reached through reverse dependencies by changes far outside
  `tools/build`: targets under `tools/build` depend on libraries under `src/` (`tools/build/coverage`
  on `komira_json`, `tools/build/examples/shared_lib_mid` on seven libraries; `git grep '"//src/'
  -- 'tools/build/**/BUCK'` lists them). In `tools_build`, a change to one of those libraries would run
  every scenario.
- **Only a widened change reaches `build_selftests`.** `//tools/build/ci:affected` maps each changed
  file to the targets that own it and takes their reverse dependencies. A scenario target depends
  only on its Zig binary, the helper library, the pinned buck2 and tools from `tools/build` and the
  toolchains cell. It names every target its inner builds build as a string argument, never as a
  dependency or as `data`. So no file outside those reaches it. A change to `tools/build/**` answers
  `WIDENED` ([`rules.txt`](../../tools/build/ci/rules.txt)): every unit, `build_selftests` included,
  and the scenarios' own code is under `tools/build`, so changing a scenario runs the scenarios. The
  same rules widen on `.buckconfig`, the buck2 pin and wrapper, `prelude/**` and `third_party/**`, so
  those changes run the scenarios too.
- **`build_targets.sh` runs them.** For a reached unit it runs `buck2 build`, then `buck2 test` over
  the unit's patterns, so `buck2 test //tools/build/selftest/...` runs every scenario, each one test.
  A widened change builds all units in one batch over the union of their targets, so the scenarios run
  in the same `buck2 test` as every other unit's tests. When a batch fails, kci retries unit by unit,
  and `build_selftests` is one of those units.
- **The proof of the selection.** Slice 3 shows `kci run --stage pr --affected-by <base> --plan`
  listing `build_selftests` for a change to a file under `tools/build/`, and not listing it for a
  change to one library under `src/`. The planted mutant makes that library a dependency of one
  scenario target. The `src/` change then lists `build_selftests`. That proof holds at one commit. The
  graph check `selftest_closure` keeps it true: it fails when the closure of
  `//tools/build/selftest/...` holds a `//src/` label (see "Graph checks in the gate").
- **The cost.** The scenarios run inside the job's budget: `pr / check` gives kci what is left of 115
  minutes, while the scheduled self-test job has 300 today. Each slice reports the wall time its
  scenarios add to a widened check, and slice 3 measures how many inner daemons the runner holds at
  once (see "How a scenario runs").

### The farm connection

`pr / check` runs on a GitHub-hosted runner. Its `farm-connect` step writes the farm's machine
buckconfig (`$HOME/.buckconfig.d/farm.buckconfig`: the `[buck2_re_client]` addresses and
`[komira_re] linux_x86_64_properties`), and the step after it fails the job when that key is empty.
Every buck2 daemon on the runner reads that file, whatever its project root or isolation dir. So a
scenario's inner daemon, in the checkout under its own isolation dir or in a scratch tree under
`$TMPDIR`, executes on the same farm as the outer build. The scenario needs no flag, variable or
secret of its own for that. On a developer's machine the farm configuration is the root's
`.buckconfig.local`, which the scratch-tree snapshot copies.

The all-remote rule (inner builds run on the farm) is checked, not assumed:
- The guard refuses to start when the inner daemon registers an execution platform that is not
  remote (`audit config`, `audit providers`).
- After every inner command that executes actions, the runner reads `buck2 log what-ran` and fails on
  any local action. So local: 0 is checked for every inner build of every scenario, not only in
  `local_zero`. `local_zero` is the scenario that shows this check can go red (row 1 check_executor).

Three things run on the runner itself, none of them a build action: each scenario's test process (a
buck2 client, below), the `docker load` and `docker run` of `docker_run`, and the local legs of
`fresh_clone_local_default`, which are still a proposal (see "Decisions").

### The recursion guard

`target_compatible_with` does not keep the scenarios out of the gate. It only keeps them out of their
own inner builds.

- Every inner command the runner issues passes `-c komira_selftest.inner=true`.
- A `config_setting` on that key, `//tools/build/selftest:inner`, selects a constraint that no platform
  satisfies into every scenario's `target_compatible_with`. So an inner command whose pattern covers
  `//tools/build/selftest/` (`//...`, `//tools/build/...`) skips every scenario as incompatible
  instead of running it a level deeper. The key is meant to change no target's configuration. That is
  not confirmed yet. Slice 3 confirms it by comparing `audit configurations` of `hello` with and without
  the key (equal hashes). After slice 5, `exec_platforms` runs the `config_hash_pin` BXL as an inner
  command, with the key set, so it would go red if the key moved a configuration hash.
- **Defense in depth.** The rule passes `--nested` to the scenario binary only through
  `select({":inner": ["--nested"], "DEFAULT": []})`, and the helper library refuses to run with it.
  The planted mutant is to delete `target_compatible_with` from one scenario and run
  `buck2 test //tools/build/selftest/...` as an inner command. The nested scenario then fails on
  `--nested` instead of driving buck2. Slice 3 shows this red.

Rejected options:
- A scheduled or nightly workflow, or a separate farm-attached runner. The scenarios check the build
  system, so they gate the changes to it.
- Leaving the scenarios in the derived check `tools_build`, which changes under `src/` reach (above).
- A label that `build_targets.sh` excludes, or any selection in YAML or in a shell script. That is
  filter logic outside a Buck2 target, which the build-architecture ruling refuses.
- A cell of its own. It is outside the universe, so no check would build it.

A single scenario runs with its own label, `./buck2 test //tools/build/selftest:<scenario>`, and all of
them with `./buck2 test //tools/build/selftest/...`.

## How a scenario runs

A scenario is a `buck2 test` target that runs buck2. Four things make that work.

1. **The rule.** `selftest_scenario` (Starlark, `tools/build/selftest/defs.bzl`) returns an
   `ExternalRunnerTestInfo`. Its command is the scenario's Zig binary itself, with no shell around it.
   The rule takes that binary as an `exec_dep`, so it is configured as the gate configures it and is a
   cache hit from the gate. Its other inputs:
   - The pinned buck2 release, also an `exec_dep`: a `pinned_file` of the asset `tools/buck2` names,
     unpacked by a Zig tool. The `./buck2` script is used only by the `bootstrap_pin` scenario, as the
     program under test.
   - Fixtures as source files only, never as targets (see "Only a widened change reaches
     `build_selftests`").
   - `--nested`, only through the recursion guard's `select`.

   The rule sets `run_from_project_root = True` and a `default_executor` that is local-only.
2. **A local test process, inner builds on the farm.** A scenario is a client of buck2. It needs the
   checkout, which is what it tests, and a daemon. A remote worker has neither, so the test process
   runs on the client: in `pr / check` that is the job's runner. This is the one local execution in
   the design. It is a test execution, not a build action: the scenario binary and every action that
   an inner build runs execute on the farm. Reading the checkout outside declared inputs is what a
   scenario is for, and the rule says so by running from the project root. A build action never does
   this.
3. **No recursion into the outer daemon.** The outer `buck2 test` holds its daemon until every test
   has finished. An inner command in the same project root, under the default isolation dir, would
   reach that same busy daemon. So every inner command the runner issues in the checkout passes
   `--isolation-dir selftest_<scenario>`. That is one daemon per scenario, so scenarios that
   `buck2 test` runs in parallel share none. The helper library stops that daemon
   (`buck2 --isolation-dir selftest_<scenario> kill`) on every exit path, including failures. An
   inner command never runs a scenario (see "The recursion guard").
   - A scenario whose expectation depends on paths (`consumer_cell_cache`, the clone scenarios), or
     that plants a per-run change (`local_zero`), runs in a scratch tree instead. A scratch tree is its
     own project root, so it has its own daemon under the default isolation dir (see "Scratch tree" in
     "The helper library" for how the helper makes sure of that).
   - Slice 3 measures how many daemons the runner holds at once. If that is too many, the rule requires
     a local resource with a fixed number of slots, so concurrency is not set in YAML.
4. **The guard and the all-remote rule.** The guard checks the inner client's configuration. The
   client must be Linux x86_64, and every execution platform the inner daemon registers must be remote
   (`audit config`, `audit providers`). Local execution of the outer test process does not conflict
   with this: a test executor is not a registered execution platform, and the test process runs no
   build action. The runner checks what-ran after every inner build (local: 0, see "The farm
   connection"). The one exception is `fresh_clone_local_default`. Its rule attribute sets
   `expect = "local"`, and it reads the configuration of a scratch clone with no farm configuration,
   `HOME` in the scratch dir and no user or system buckconfig, so that clone registers only a local
   platform by design.

## Why a scenario's builds are fresh

No scenario passes `--no-remote-cache`, and no rule takes a salt. A scenario's inner builds are fresh
because each one runs under the scenario's own isolation dir, or in a scratch tree that is its own
project root:

- **Its own daemon and `buck-out`.** Nothing is reused from the outer build's daemon state or from
  outputs the outer build materialized.
- **Its own action keys.** Under an isolation dir every output path is under
  `buck-out/<isolation dir>`. Output paths are part of every action's key, so no inner action has a key
  the gate's builds computed, and none is a hit on the gate's cache entries.
- **A hit on its own earlier run is proof.** A later run of the same scenario on identical inputs hits
  the entries its earlier run wrote. The key covers the inputs, the command and, for a remote action,
  the platform property set, so that hit is a pass on identical inputs, the same proof `pr / check`
  relies on everywhere. A change the scenario is meant to see changes the keys it reaches, so those
  actions execute.
- **`local_zero` is the exception: it must execute something on every run.** Its defect, a hybrid
  executor that prefers local, changes where an action runs, not its key. Once the cache is warm every
  action would be a hit, nothing would run locally and the scenario would stay green with the defect in
  place. So `local_zero` plants a per-run change in its scratch tree: it writes a new value (the run's own
  id) into a fixture source, so that fixture's compile has a new key on every run and executes. The
  scenario fails when what-ran lists no executed action, and fails on that action if it ran locally.

What that means for the rows that used `--no-remote-cache` before (12, 15, 33a/b, 23 determinism):
- **`action_properties` (12)** reads the property set recorded for each action of its build. The
  property set is part of the key, so an executed action and a hit prove the same thing. Its mutant, an
  empty property set for one category, changes that category's keys and recorded properties, and the
  scenario goes red. This relies on what-ran recording the property set for a cache hit as well as for
  an executed action. That is not confirmed yet; slice 10 confirms it on a warm run before the scenario
  depends on it.
- **The determinism scenarios** build twice, under `selftest_<scenario>_a` and `selftest_<scenario>_b`.
  The two builds' keys differ in their output paths, so each output tree comes from its own execution,
  and the digest diff compares two independent executions. An output that embeds its own `buck-out`
  path (debug info's compilation directory, for example) differs between the two, and the scenario
  reports it as a relocatability defect. This is stricter than today's double build at one path, so
  slice 10 expects such findings and handles them (see the slice plan).
- **Scratch trees** use the default isolation dir under their own root. Their unchanged actions have
  the checkout's keys and hit the gate's entries, which is what `consumer_cell_cache` asserts. What a
  scratch tree plants changes the keys of the actions it reaches, so those execute.

## The helper library

`//tools/build/selftest:lib`, a Zig library with its own unit tests on captured fixtures (welded, so
they run in `pr / check`). Files stay under 1000 lines. It offers only what the scenarios above use:

- **Guard.** As above: no `--nested`, a Linux x86_64 client, and every registered execution platform
  remote (or local for the one `expect = "local"` scenario). A refusal is a failure, never a pass.
- **Runner.** The buck2 binary comes from the rule's `--buck2`. The runner takes argv, a cwd (the
  project root or a scratch tree), `-c` pairs, `--target-platforms` and a timeout. It always adds the
  scenario's `--isolation-dir` in the checkout, and `-c komira_selftest.inner=true` everywhere. After
  every command that executes actions it reads what-ran and fails on a local action (local: 0). It
  captures exit, stdout and stderr into a per-scenario log directory under the test's `$TMPDIR`. Every
  failure names its log file. Every daemon it started is stopped with `buck2 kill` under the same
  isolation dir.
- **Expectations.**
  - `expectBuildOk(targets)`.
  - `expectBuildFails(target, text)`. "Built but must fail" and "failed without the text" are distinct
    failures.
  - `expectTestFails(target, text, test_args)`.
  - `expectAbsent(log, patterns)`.
  - `expectFindings(log, n)`.
  - A refusal table runner that builds analysis only.
- **No silent pass.** A scenario that asserts nothing or SKIPs fails. A build or test command whose
  what-ran lists no action at all (none executed and none a cache hit) fails too, so a build that
  matched no target is not a pass. A cache hit is a listed action, so a warm rerun passes (see "A hit on
  its own earlier run is proof"). Analysis-only commands (refusal tables, `audit`) run no build and are
  not held to this.
- **Parsers.**
  - what-ran JSON into actions with category, executor and normalized properties. A what-ran that lists
    no action is a failure.
  - aquery JSON into actions with category, identifier, argv, env and inputs, plus a diff across
    configs and an absolute-path scanner.
  - cquery configurations, `audit execution-platform-resolution`, uquery label sets, `audit config`
    values, and a BXL runner.
- **Scratch tree.** It snapshots the committed tree, plus the local farm config if present, under
  `$TMPDIR`. A test's `$TMPDIR` can lie inside the checkout (under `buck-out`). Without a `.buckroot`,
  buck2 takes the topmost directory holding a `.buckconfig` as the project root, so such a tree would
  resolve to the checkout. The helper therefore writes a `.buckroot` at the root of every scratch tree.
  It plants a file or BUCK edit, runs the tree's own daemon, and always kills that daemon and deletes
  the tree, even on failure (`--keep-scratch` keeps it). Slice 3 confirms the project root: in a scratch
  tree, `buck2 root --kind project` prints the scratch tree, and with the `.buckroot` left out (the
  mutant) it prints the checkout and the helper's unit test fails.
- **Digests.** A sorted file-hash manifest of output trees, and a diff that names the files that differ
  (determinism).
- **Golden I/O.** It compares the scenario output to a committed golden line by line, and supports
  `--regen`.

## How CI runs it

All three buckets run in `pr / check`. Bucket 1 and bucket 2 run in whichever unit holds their target.
The graph checks run in the BXL step of `build_targets.sh` for the unit `build_selftests`.
Bucket 3 runs in the declared check `build_selftests`, which every change to `tools/build/**` reaches
(see "Scenarios run in pr / check"). Slice 3 declares that check. No workflow gains a step.

The scheduled build-system self-test workflow keeps calling `run_tests.sh` for the rows that are not
converted yet. Slice 10 removes its pixi step, because the conda install scenario takes
`//tools/build/toolchains:pixi` as a dep. Slice 11 deletes `run_tests.sh`, the workflow file and its
section of `docs/ci.md`. After that, nothing runs on a schedule.

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
   - Delete the spsc_ring falsifier scripts and their fixtures: `negative/spsc_ring_element.sh`,
     `negative/spsc_ring_prefix_layout.sh` and `negative/spsc_ring_prefix_layout/` (two `.mojo`
     files). Nothing calls them. The regression tests they falsified stay in `komira_spsc_ring`
     (`test_consumer_polling_before_the_slot_store_exists`, `test_layout_guards`). What goes is the
     script that showed the first one can fail, by a race seen in at least one of 30 runs.
3. **Helper lib, the scenario rule and the analysis-only scenarios.**
   - `//tools/build/selftest:lib` with its unit tests.
   - `selftest_scenario` and the recursion guard (`:inner`, `--nested`), with the
     `target_compatible_with` mutant red.
   - The declared check `build_selftests` in `release/artifacts.textproto`, with the `--plan` proof and
     its mutant (see "Scenarios run in pr / check").
   - The `graph_check` rule, `//tools/build/selftest/graph/checks.bxl`, the BXL step's one change in
     `build_targets.sh`, and the first graph check, `selftest_closure`, red on the `--plan` mutant.
   - To confirm, before later slices rely on them: the inner key moves no configuration hash (see "The
     recursion guard"), and each scratch tree is its own project root (see "Scratch tree").
   - `exec_platforms`, `uquery_select_branches`, and the `analysis_refusals_*` and `config_refusals`
     tables.
   - The wall time these scenarios add to a widened check, and the peak number of inner daemons.
4. **Red builds.** `gate_wiring`, `shared_lib_gate`, `compile_isolation`, `planted_red_builds`,
   `assert_level_reds`, `test_limits`, `coverage_gate_reds`.
5. **aquery, what-ran and graph checks.**
   - `local_zero`, with its per-run change, red on the hybrid-executor mutant on a warm cache;
     `assert_level_commands`, `aquery_opt_levels`, and the `coverage_*` aquery scenarios.
   - The graph checks, each a BXL script run in the gate, each red on its row's mutant:
     `aquery_host_paths`, `docs_package_coverage`, `config_hash_pin`, `test_weld_real_graph` and
     `golden_linux_x86_64`. golden.sh goes with them.
6. **Lints and checkers, with unit tests.**
   - The Zig ports: test_weld, pointer_lint, src_layout, refused_imports, readme_api_coverage,
     surface_capability_matrix, public_boundary, the shared lint runner and the limits checker.
   - The Zig `doc_links` port (below), and the unit tests of the doc JSON checker.
   - The new file lints (17, 19) with the toolchains-cell file list, the readme marker check, and the
     aws env scanner as a Zig tool.
   - **README examples and doc_links: who writes what, and in which order.** The README generator and
     the Markdown link checker `doc_links` (`tools/build/inspect/buildtools/doc_links.mojo`) share one
     CommonMark reader today, so the two agree on what is code. The Zig port keeps one reader:
     1. **The shared Zig markdown module** lands first, in its own pull request: fences, links and the
        skipping of HTML comments, with a welded `zig_test` and a parity run against the Mojo reader.
     2. **The README examples work (#1273, a draft today)** then writes the Zig `readme_examples` tool
        on that module. It replaces the Mojo tool at the same path, `//tools/build/readme_examples`,
        with the same `generate` and `map` interface. It ports the per-block design: one program per
        example, line n of a program is README line n, the `mojo module` fence. Its unit tests carry
        the README cases (rows 38 raises, skip_word, shipped_relative_link and the unit part of 38
        compile_error), and it moves the generator's consumers.
     3. **This doc's `doc_links` slice** comes last. It ports `doc_links` to Zig on the shared markdown
        module and writes no second reader. Its welded unit tests carry the link cases of
        `test_buildtools` (row 17 doc_links_dead), each with the planted defect it names. It moves the
        `doc_links` lint (`tools/build/lint/defs.bzl`, which runs `inspect doc-links` today) to the Zig
        binary. The rest of `tools/build/inspect` is not part of this slice.
   - Rows 38 readme_marker, compile_error (`compile_isolation`) and owner_base_no_readme, readme_keyword
     (`analysis_refusals_readme`) stay checks of this design: a target and selftest scenarios. Slice 6
     deletes the shell lines of the row-38 README rows once the Zig `readme_examples` tool has landed.
7. **Runners to Zig.**
   - The gate runner, the compile wrapper (with its watchdog cases), the Rust test runner and the
     bounded-run tool (mem_cap and test_deadline cases).
   - cov_run, the gate step, the census tool, cov_branch and the link-line comparer.
   - Each with the unit tests its rows list.
8. **Inspection tools and generators.**
   - `binary_check` (see "Binary inspection") with its welded unit tests, as validations for rows 6,
     8 runtime_run_paths, 20, 22 and 26, each red on its row's mutant; the glibc level check, and the
     bundle and format content checks.
   - The node tools.
   - The proto and aws generation wrapper, the gen/tests checker and the aws_codegen checker.
9. **Clones and scratch trees.** `consumer_cell_cache`, `buck2_run_fresh_clone`,
   `fresh_clone_local_default`, `lint_weld`, `bootstrap_pin`, `docker_run`.
10. **Execution properties and determinism.**
    - `action_properties`. To confirm first: what-ran records the property set for a cache hit (see
      "Why a scenario's builds are fresh").
    - `bundle_determinism` (with `binary_check` for the bundle's run paths, launcher needed libraries
      and platform floor), `conda_determinism` with the conda manifest checks and the pixi install, and
      `determinism_proto` with the in-action double run.
    - Each determinism scenario builds twice under two isolation dirs (see "Why a scenario's builds
      are fresh"). The slice expects outputs that embed their own `buck-out` path to differ. It runs
      each scenario once and, for every such output, either makes the output relocatable in the rule
      or lists it in the scenario's committed allow list with the reason. The scenario then fails on
      any other difference, and on an allow-list entry that no longer differs, so the list only
      shrinks.
11. **The rest, then the harness.**
    - Darwin (24): `darwin_platform`, the darwin checks of `binary_check` and the stand-in checks on
      the slice 8 tools, and `darwin_build_run` as planned below.
    - Then delete `run_tests.sh`, `tool_lib.sh`, the shell_lint target, the scheduled self-test
      workflow and its section of `docs/ci.md`.
    - Replace `tools/build/tests/README.md` with a short page: what the tests cell holds (fixtures for
      targets and scenarios), how to run a scenario, and a link to this inventory.

### darwin_build_run

Row 24's build and run leg on macOS. It is planned now and lands in slice 11. Its test target is added
once the macOS build hosts are connected to CI.

What is known now (`functional/darwin/check.sh` section 7, `.buckconfig.local.example`):
- The darwin-arm64 execution platform is registered only when `[komira_re] darwin_arm64_properties`
  and `[komira_re] darwin_macos_hosts` are both set. `darwin_platform` covers the unset case and a
  placeholder set in `pr / check`, with no macOS worker.
- What the scenario asserts, in the checkout under its isolation dir, with `--target-platforms`
  darwin-arm64:
  - every host identity the workers report (`tests//functional/darwin:host_census`) is listed in
    `darwin_macos_hosts`;
  - `//tools/build/examples:hello` and its run check build and pass on the macOS workers, with the
    configured property set in what-ran and local: 0;
  - the binary is an arm64 Mach-O whose platform floor (`LC_BUILD_VERSION` `minos`) is 11.0, whose
    only run path is `@loader_path/lib` and which loads only the runtime library and the system (read
    by `binary_check`);
  - the `mojo_shared_lib` examples, their gates and `libgate_ok`'s welded test pass there;
  - a compile whose host list names no worker is refused on the worker (exit 2).
- Mutants: an absolute load path in `hello`; the property set dropped from the darwin platform; a host
  list that leaves out a worker that reports itself.
- What lands in slice 11: the scenario binary, its expectations, and their welded unit tests over
  what-ran, aquery and Mach-O output captured from a run on the macOS build hosts. The binary builds,
  and its unit tests run, in every widened `pr / check`.

What waits for the macOS build hosts in CI:
- `farm-connect` writes only `linux_x86_64_properties` today. It gains the darwin property set and the
  host list as inputs, and the `pr / check` step that refuses a runner without the farm checks them too.
- The scenario's test target lands in the same pull request as that change. A scenario never SKIPs,
  so the target is not added before the hosts can serve it.
- Section 7 of `darwin/check.sh` is the only runner of this leg today, and it SKIPs wherever the
  darwin keys are unset. The scheduled workflow does not set them: its `farm-connect` writes only
  `linux_x86_64_properties`. So section 7 SKIPs on the scheduled job today and has never run there.
  Slice 11 deletes `darwin/check.sh` with it, and no check that runs in CI is lost. From slice 11
  until the macOS build hosts are connected, the live leg runs nowhere, as in CI today, and what it
  asserts is kept in the scenario's binary and its unit tests.

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
| `negative/spsc_ring_element.sh`, `negative/spsc_ring_prefix_layout.sh` (with `negative/spsc_ring_prefix_layout/`) | 2 |

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

## Decisions

Decided (2026-10-10):
- **Scenarios run in `pr / check`** whenever a pull request touches `tools/build/**`, which already
  widens the check. Not on a schedule, and not on a separate runner (see "Scenarios run in pr / check").
- **Bucket 2 is a welded `zig_test`.** The tool cannot be built unless its tests pass, so every build
  that uses the tool runs them or reuses them from the cache, and a cache hit is a pass on identical
  inputs. The accepted cost: a red test blocks every build that uses the tool, unrelated work included,
  and is reported as a build failure, not as a test result.
- **No salt and no `--no-remote-cache`.** Each scenario's inner builds run under its own isolation dir
  or in a scratch tree, so they execute fresh (see "Why a scenario's builds are fresh").
- **doc_links and readme_examples move to Zig on one shared Zig markdown module.** The order is the
  markdown module, then the README examples work's Zig `readme_examples` tool (#1273), then this doc's
  `doc_links` slice (slice 6).
- **Binary inspection is an in-build Zig step** (bucket 1): one `binary_check` API over ELF on Linux
  and Mach-O on macOS, for run paths, needed libraries, exported symbols, the C++ runtime and the
  platform floor. No PE or Windows now (see "Binary inspection").
- **Graph checks are BXL scripts run in the gate** (see "Graph checks in the gate"), with one change to
  the BXL step of `build_targets.sh`.
- **`darwin_build_run` is planned now** (slice 11, "darwin_build_run"). It is not dropped; its test
  target is added when the macOS build hosts are connected to CI.
- **The spsc_ring falsifier scripts and their fixtures are deleted** (slice 2).
- **The build-architecture ruling:** every CI entrypoint is a Buck2 target, the rules invoke Zig tools
  only, and there is no shell. So the aws env scanner, once extracted from aws.bzl, is a Zig tool.

Still proposals:
- **The local legs of `fresh_clone_local_default` (row 25, legs 4-6).** They build on the client by
  design: toolchain actions, `hello` and the proto_check cases, in a clone with no farm configuration.
  In `pr / check` that client is the job's runner, and the all-remote rule holds the inner builds to
  the farm. The proposal is to keep them as the one declared exception (`expect = "local"`), run only
  where the platform-set CI marker says the client is a CI runner, and failing, never skipping,
  anywhere else.
  The alternative is to delete them and keep legs 1-3, which run no build.
- **lint_weld after the port.** Once the rules run no shell, the scenario re-aims at whatever lint stays
  welded, or goes away.
