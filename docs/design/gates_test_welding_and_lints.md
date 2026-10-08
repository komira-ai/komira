# Build gates, test welding and lints: the build is the gate

The reference for declaring a gated library is [tools/build/mojo/README.md](../../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate); the tests that prove each property are in [tools/build/tests/README.md](../../tools/build/tests/README.md). This doc records why the gate and the lints are built the way they are. The compiler and the wrapper they run on are in [Mojo rules and toolchain](mojo_rules_and_toolchain.md).

## What is it for, and what is out of scope?

A Mojo library declares `test_srcs`. Building the library builds and runs each test, and publishes the package only if every test passed, so nothing that depends on the library builds against a package whose tests fail. No separate test step exists to forget. Lints work the other way: they are validations that `buck2 build` runs for any graph that holds them.

Out of scope:

- Running a binary as a test with `buck2 test`: [tools/build/mojo/README.md](../../tools/build/mojo/README.md#binaries-and-tests).
- The compiler environment, the watchdog and the toolchain pin: [Mojo rules and toolchain](mojo_rules_and_toolchain.md).
- Linting Mojo source. The lint rules in `tools/build/lint` check shell scripts, GitHub workflows, committed build configuration and documentation links; `test_weld` reads only the paths of Mojo files, to find test files, and which of them the build graph's targets weld.

## How does it work?

For a library `L` with import name `I` and tests `t1`, `t2`:

```
mojo precompile  ->  L/ungated/I.mojoc
                       |                    \
        build t1 against it, run (gate_runner.sh) -> L/tests/t1.passed   "PASS <label>"
        build t2 against it, run                  -> L/tests/t2.passed
                       |                    /
        cp ungated/I.mojoc  (markers are hidden inputs)  ->  L/pkg/I.mojoc   (the public package)
```

The public package is a `cp` of the ungated one whose inputs include every marker, so it cannot exist unless every test passed, and neither can anything that names `L` in `deps`. The `[ungated]` sub-target carries files only and no `MojoInfo`, so `deps` rejects it. A library with no `test_srcs` publishes its ungated package directly.

Each test runs from a tree staged for that test alone. Its working directory is `root/share`, which holds exactly the declared data. `PATH` holds only busybox applets, and `TMPDIR`, `TEST_TMPDIR` and `HOME` are empty per-run directories.

A lint is a rule in `tools/build/lint/defs.bzl`. One action runs the pinned linter over files copied into `buck-out` and writes a JSON verdict as a `ValidationInfo`. The action itself succeeds either way; buck2 fails any build or test whose graph holds the target.

## Why is it built this way?

### Why is the gate an input of a copy, not a check beside the build?

**Decision.** The public package is produced by a `cp` action whose hidden inputs are every test's marker, and the gated library's output path is only that copy's.

**Because.** A gate that sits beside the build can be skipped by building the artifact alone, and a record of an earlier run can say less than its readers assume. An input edge cannot cover less than it says: the package is absent until every marker exists, and no flag reaches the edge.

**Alternatives weighed.**

- A validation: it fails the command but is not an input of the artifact, which is the right shape for a lint and the wrong one for a gate.
- Put the markers on the compile: correct, but the compile could not begin until every test had run, and every test needs the compile's output. See the next decision.

**Revisit if.** buck2 can make a validation an order-only input that keeps an output absent.

### Why does the copy exist, and why do tests build against the ungated package?

**Decision.** The compile writes `ungated/I.mojoc`, the tests compile against that file inside the rule, and `pkg/I.mojoc` is a copy taken after the markers exist.

**Because.** A test needs the library it tests. If the published package were gated on its own tests, the dependency would be a cycle: library, marker, test, library. Splitting the compile from the copy breaks it, and the tests start as soon as the compile finishes, in parallel with each other. The copy is byte-identical to the file the tests compiled against, so the tests ran against exactly what is published.

The tests reach `ungated` in the rule and never through a label. That is why a binary that names `[ungated]` in `deps` fails analysis ([test 2](../../tools/build/tests/README.md#2-gate)): the only way to compile against a library is through its gated package. A test's own dependencies enter as published packages, so a library's tests see gated copies of everything beneath it.

**Alternatives weighed.**

- Tests as `srcs` of the library: editing a test would change the package and rebuild every consumer. `test_srcs` files are built apart from the package and never reach the `.mojoc`.
- Gate only the shipped binaries: a library's tests would then run only when some binary was built, and a library consumed by another library would be unguarded.

**Revisit if.** Mojo can compile a test against a package without that package's gate in the way.

### Why is the marker a constant?

**Decision.** A passing test writes `PASS <label>` and nothing else; its bytes never depend on the run.

**Because.** The marker is an input of the copy. If it held a timing or a log, every rerun of a passing test would change the copy's input and, through the copy, the digest of every consumer. With a constant, editing a test that still passes leaves the package and everything above it unchanged.

**Revisit if.** A marker needs to carry more than a verdict.

### Why does the test run in a staged tree with a fixed environment?

**Decision.** `gate_runner.sh` runs a test from a tree of its own, with a fixed environment, and gives a `test_env` variable to the test process only, never to the runner's own shell. The rule refuses the reserved names, and the script refuses them again.

**Because.** A test that reaches a file it did not declare passes here and fails somewhere that lacks the file. Staging the declared data under `share/` and running from there makes a relative path reach a declared file and nothing else. Exported into the runner's shell, a variable would reach the values the verdict is computed from, so a `BIN` set in `env` would change what the runner decides. Putting the variable on the test's own command line closes that.

**Revisit if.** buck2 gives a test action a sandbox that already limits what it reads.

### Why is a lint a validation, not an input?

**Decision.** A lint's result is a `ValidationInfo`. Buck2 runs a target's validations whenever a build or test resolves a graph holding that target and fails the command if one reports failure. No lint is an input of the targets it guards.

**Because.** Adding a lint, or fixing a finding, then changes no other action's digest, so a lint never invalidates the build cache. A target that must not build while a script has a finding names that script's lint as a validation instead. The Mojo and Rust toolchains do this with `_script_lint`, so no Mojo or Rust target builds while a script the rules run has a finding. [Test 31](../../tools/build/tests/README.md#31-lint-weld) pins the lists, then plants one finding in a script of each lint target on the Mojo and Rust lists to prove that the Mojo or Rust build goes red through its toolchain.

**Alternatives weighed.**

- Make the lint an input: every lint edit would rebuild the world.
- A separate lint command: it is skipped unless someone remembers it. `buck2 build //...` runs every lint, and the cell's other lints are reached through `//:tests_lints`, because `//...` does not enter another cell.

**Revisit if.** The cost of a lint in the digest becomes negligible.

### Why does a lint refuse to check nothing?

**Decision.** At analysis, `shell_lint` with no `srcs`, `no_endpoint` with no `buckconfigs`, `markdown_docs` with no Markdown and `lint_suite` with no `lints` fail. `action_pins` and `push_verdicts` have no analysis check: when the set holds no `uses:` or no push-triggered workflow, the report says `checked nothing` and the validation fails when the action runs. A `shell_lint` exclusion that names a file not in `srcs` fails too.

**Because.** A lint over an empty set is green by construction. A glob that matched nothing, or a file that was renamed, would turn the lint off while the build stayed green. An exclusion that outlives its file is the same failure in smaller form, so it has to be deleted along with the file.

**Revisit if.** buck2 can state that a glob must match.

### Why do lints run over copies in `buck-out` and name files by their package path?

**Decision.** The lint rule copies its files into `buck-out` with `copied_dir`, runs the linter on the copies, and prints findings as `<cell>//<package>/<path>`.

**Because.** A source file's path in an action is relative to the project root, so it differs between a standalone checkout and a repository that mounts komira as a cell. Linting the copies, which sit at the same `buck-out` path in both, gives the same action digest, so the lint shares cache entries across checkouts as every other action here does. The finding is rewritten to the package path so it points at the file a person edits.

**Revisit if.** An action's source paths stop depending on where a cell is mounted.

### Why does `//:docs` check links across the whole tree through `doc_tree` targets?

**Decision.** Every package declares a `doc_tree` that holds its own files and collects its subpackages' ones; every komira rule and macro, and, through the `[buildfile] includes` module, every prelude rule, declares it automatically. `//:docs` stages the root tree and checks that each relative link and `#anchor` in every Markdown file resolves to a file, a directory or a heading in it.

**Because.** A target may name only the files of its own package, and a glob stops at a subpackage, so no one target can name the repository. Subpackages come from buck2 itself, not from a list, so a package that declares no `doc_tree` is an analysis error of its parent naming the missing target, rather than a package silently left out. A link to a file that has not landed, or to a heading that was renamed, fails the build.

**Revisit if.** A single target can name a whole cell's files.

## What must always hold?

- **No passing test, no published package.** The public package is written only by the copy whose inputs include every marker. Fixtures: `tests//negative/libgate_bad` (test 2).
- **A passing test edit does not move the package.** Marker bytes do not depend on the run.
- **A test sees only its declared data.** It runs from `root/share`, in a fixed environment.
- **A package reaches the compiler only through `deps`.** `[ungated]` carries no `MojoInfo`.
- **No lint is empty.** `shell_lint`, `workflow_lint`, `no_endpoint`, `lint_suite` and `markdown_docs` refuse an empty set at analysis. `action_pins` and `push_verdicts` have no analysis check; they write `checked nothing` to the report, so the validation fails when the action runs.
- **A script the Mojo or Rust rules run is linted before any Mojo or Rust target builds.** Test 31 plants a finding in one script of each lint target on those lists and requires the build to fail.
- **Every relative link in the Markdown resolves.** `//:docs`, test 17.

## Where is the code?

| What | Where |
|---|---|
| The gate: compile, tests, copy | `tools/build/mojo/defs.bzl` (`mojo_library`) |
| The test runner | `tools/build/mojo/gate_runner.sh` |
| The lint rules | `tools/build/lint/defs.bzl`, `lint.sh` |
| The pinned linters | `tools/build/lint/BUCK` (shellcheck, actionlint) |
| The doc tree | `tools/build/lint/doc_tree.bzl`, `includes.bzl` |
| The repository's lint targets | the root `BUCK` |

### Which lints exist?

| Rule | What it requires |
|---|---|
| `shell_lint` | every file passes shellcheck at severity warning, under the shell its shebang or `shellcheck shell=` directive names, else busybox |
| `workflow_lint` | the GitHub workflows pass actionlint, with shellcheck over their `run:` steps |
| `action_pins` | every `uses:` names an action by a full 40-hex commit SHA |
| `push_verdicts` | a push-triggered workflow whose top-level `concurrency` group can hold more than one push keys that group on `github.sha`, so no push loses its run. No target declares it now: `kci.yml`, the only push-triggered workflow, is held to the opposite on purpose (its pushes to main share one group so the newest pending release replaces an older one; kci_workflow_check rule R16 holds that group byte for byte), and the lint refuses a set with no push-triggered workflow, so a target would be empty. Declare one again if a push-triggered workflow gains a concurrency group |
| `no_endpoint` | no committed buckconfig sets a remote-execution endpoint or instance key, `.gitignore` ignores `/.buckconfig.local`, and no file names a `grpc://` or `grpcs://` address outside the `example.*` domains |
| `markdown_docs` | every relative link and anchor in every Markdown file resolves |
| `lint_suite` | groups lints another graph does not reach, so their validations run in any build holding the suite |
| `retired_names` | no file of the cell holds a renamed package's or type's old name except on a line carrying a `YYYY-MM-DD` date (a history note); `tools/build/lint/retired_names.bzl`, and a target with no `names` fails at analysis |
| `src_layout` | `src/<name>` holds what komira ships; a package that exists only to test others is `src/tests/<kind>/<name>`, kind `e2e` (`*_e2e`, `*_loopback`), `conformance` (`*_conformance`) or `helpers` (a harness), so an `*_e2e`, `*_loopback` or `*_conformance` package anywhere else under `src/` is a finding, as is a `komira_test_*` package directly under `src/` that its `shipped` list does not name. The packages are read from the build graph (the root package's subpackages), so a new one is checked with no edit. `tools/build/lint/defs.bzl`, `//:src_layout`, test 45 |
| `test_weld` | every `tests/test_*.mojo` under `src/` is welded, in each package (`src/<name>`, or `src/tests/<kind>/<name>` for a test-only one) (a mojo_library's `test_srcs` or a mojo_test's `main`, read from the build graph, so a computed list counts and a comment does not, and Buck2 says where each welded file is), and every package with a `.mojo` source welds a test; the exceptions are the rows of `tests/known_untested.tsv`, a ledger that only shrinks (a row whose test or package is welded is a finding). `tools/build/lint/test_weld.bzl`, test 39. Not a validation: a rule cannot query the targets of `//src/...`, so the `test_weld` target declares the lint and `buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint //:test_weld` checks it; the pull request's check runs that for every `test_weld` target of a unit (`release/ci/build_targets.sh`), and `./buck2 build //...` does not |
| `pointer_lint` | the Mojo pointer rules of [mojo_safety_and_idioms.md](mojo_safety_and_idioms.md), over every `.mojo` file of the cell: no wildcard origin outside the FFI modules `tests/pointer_lint_ffi.tsv` lists (each holds a `# FFI-BOUNDARY:` comment line), no `unsafe_from_address=`, no partial move through a pointer (one statement or two), no `parallelize[`, no second declaration of libc `read` or `open`, and no public function of a library file under `src/` taking or returning a pointer; the sites that predate it are the rows of `tests/pointer_lint_holds.tsv`, per rule and file at an exact count, a ledger that only shrinks; `tools/build/lint/defs.bzl` (`pointer_lint`), the reader `pointer_lint.awk`, the action `lint.sh` |
| `public_boundary` | what a public repository may not hold, over every file of the repository but binary data (whose paths are read), and every path: no date from 2025 up to the public history (2026-09-01), home directory naming a person, private or written-out network address, URL host outside the reserved example names and `tests/public_boundary_hosts.tsv` (every row used), email address outside the reserved example domains, or commit id in prose; the findings a file must keep are the rows of `tests/public_boundary_holds.tsv`, per rule and file at an exact count, a ledger that only shrinks; a private consumer passes words of its own as a list kept outside the repository (`-c komira_lint.public_boundary_deny=`), which no row can hold; `tools/build/lint/defs.bzl` (`public_boundary`), the reader `public_boundary.awk` (its rules and limits), the action `lint.sh`, test 44 |
| `readme_api_coverage` | README API coverage: per package under `src/`, the public symbols its `__init__.mojo` exports and which of them its README examples use, written as a census (`[packages]`, `[symbols]`, `[report]`); report-only (`enforce = False`), failing on a malformed or stale row of its shrink-only ledger, `tests/readme_api_exceptions.tsv`; `tools/build/lint/readme_api_coverage.bzl`, rules and census in [readme_api_coverage.md](../readme_api_coverage.md) |
| `surface_capability_matrix` | product coverage: for every surface and every capability of the plan, the surface e2e test target that exercises it (in `src/tests/e2e/<surface>_e2e/`), or `-`, written as a census (`[matrix]`, `[report]`); a missing cell is never a finding; fails on a malformed or lying row of its ledger, `tests/surface_capability_matrix.bzl` (an unknown name, a pair with two rows or none, a target outside its surface's package exactly, an alias of a test elsewhere, no test, one test filling two cells of a surface, or not existing: every named target is a dependency, so an incompatible one fails the build too), on a capability not grounded in the plan constants of its grounding files (or a constant of a grounding family no capability names, or in a form it cannot read), and on fewer filled cells than `floor` (that the floor only rises is a review rule); `tools/build/lint/surface_capability_matrix.bzl`, test 53, rules and census in [surface_capability_matrix.md](../surface_capability_matrix.md) |

## How is it tested?

[Test 2](../../tools/build/tests/README.md#2-gate) builds a library whose test fails on purpose and checks that the library and its consumer go red while `[ungated]` builds. [Test 17](../../tools/build/tests/README.md#17-doc-links) plants dead links, and test 31 plants one unused variable (SC2034) in one script of each lint target on the Mojo and Rust toolchains' lists, alone in a snapshot of the tree. It requires the build of `//tools/build/examples:hello` (Mojo list) or `//tools/build/examples/rust:prost_roundtrip` (Rust list) to fail naming that validation, and requires the lists to equal the pinned ones.

## What are its limits and open questions?

- `buck2 test` on a `mojo_library` runs nothing, because Buck2 reserves the name `tests`; the tests run when the library, or anything that depends on it, is built.
- The lints run on the Linux x86_64 `light` workers, and the pinned linters are Linux x86_64 binaries.
- A lint reaches only the graph that holds it. The root `BUCK` names the tests cell's lints in `//:tests_lints` because `//...` does not cross cells.
