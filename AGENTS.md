# Engineering rules

Every change to this repository is written to these rules, by people and by coding agents alike, and
review checks each change against them. Each rule has an id: cite it in a review comment, a commit
message or a pull request when a rule is the reason for something. [CLAUDE.md](CLAUDE.md) imports
this file, so every agent reads the same text.

The file has three parts: the shared core, which is the same text in every repository that carries an
`AGENTS.md`; the rules of the languages this repository is written in; and the rules of this
repository. How the shared core is kept the same is at the [end](#keeping-the-shared-core).

<!-- shared-core:begin -->
## Shared core

Severity: **BLOCK** is fixed before merge. **SHOULD** is fixed unless the author gives a reason.

### Tests and coverage

- **T1 BLOCK.** Every touched package or crate is at least 99% line and 99% branch as measured by
  the pull request's check. Aim for 100%; the requirement is 99, never higher. Check: the coverage
  job's table. Fix: add behaviour tests for the uncovered lines and branches.
- **T2 SHOULD.** Coverage means line and branch percent, never a count of test files or test
  functions.
- **T3 BLOCK.** No coverage floor or baseline is lowered or set below 99, and no shared coverage
  census or shared ratchet file is added. Floors live in each package.
- **T4 BLOCK.** Do not hide code from measurement: no `#[cfg(not(coverage))]`, no
  `#[coverage(off)]`, no moving a crate into `exclude`, no `test = false` binaries. A `main.rs`
  only forwards to its library.
- **T5 BLOCK.** A bug fix ships a test that failed before the fix, and the test is wired in
  (`#[test]` in the crate; named in `test_srcs` for Mojo). The pull request says what it asserts.
- **T7 BLOCK.** Never edit a test green over a capability gap: no weakened or deleted assertions, no
  tests removed from `test_srcs`, no `tests_known_failing`.
- **T8 BLOCK.** Tests assert behaviour. The pull request body lists the tests by name with the
  behaviour each proves. A "Catches ..." line is allowed; stating the defect it catches is SHOULD.
- **T9 BLOCK.** No bookkeeping of injected-defect runs in code or pull request text: no tables of
  injected defects, no run ids for them, no notes that a test was once watched failing, and no test
  name or comment about them. A test's name and comments say what behaviour it holds.
- **T10 BLOCK.** Tests never assert timing: no elapsed-time bounds, latency ceilings, or sleeps
  racing real timeouts. Inject a clock or use explicit progress events.
- **T11 BLOCK.** Tests are written in the component's own language. No new shell or Python tests
  (`*_selftest.sh`, `tests/*.sh`, `py_test`), and no growth of existing shell selftests, except
  for the Python SDK surface. New cases of a script go to a tool in the repository's language, with
  tests in that language.
- **T12 BLOCK.** Tests are hermetic and deterministic: no network or DNS (use fakes), no hard-coded
  ports or fixed paths, no shared state between tests, no silent skip (a skip states its reason), no
  retry-until-green. Use the repository's scratch helpers; tests never touch the host's real service
  directories.
- **T13 SHOULD.** Tests cover failure and boundary cases, not only the happy path. A no-leak or
  redaction test asserts the full message by exact equality.
- **T15 BLOCK.** A new gate, lint, or check has a negative case that fails on a defect. A warm
  cached green does not prove a change to what a check reads. Describe the negative case as a
  behaviour test (T9 applies).
- **T19 SHOULD.** A behaviour change updates goldens and any docs describing it in the same pull
  request; a generator or codegen change moves its goldens in the same pull request (BLOCK for
  codegen).

### Design and change shape

- **B8 BLOCK.** Formats change additively only: a new optional field, record type, oneof case,
  table, or column with a default. Never renumber, rename on the wire, remove or re-mean a shipped
  field, add a required field, refuse unknown data, or raise a version floor. The pull request names
  the test that runs the previous release on new data and the new release on old data.
- **B20 SHOULD.** Do not answer a config mistake with runtime machinery (gates, counters, extra
  metrics, dry-runs). Fix the config at the source and check it once at deploy. No speculative
  abstractions or ports without a concrete use case.
- **B22 SHOULD.** A change touching more than one package, or taking more than a day to reverse,
  links a design doc. Moving or deleting a package first shows what supersedes each of its uses.
- **P7 SHOULD.** One subject per pull request. Refactors are split from behaviour changes;
  interfaces land before the code that uses them.
- **P10 SHOULD.** Docs, headers, and comments describe only what the code does. A change updates
  every doc it contradicts or leaves stale (BLOCK when a header contradicts its code).

### CI and workflows

- **B9 BLOCK.** A pull request runs only the build and unit tests with coverage: no release
  dry-runs, no `pull_request` trigger on a release workflow, no new pull-request gate jobs, no slow
  tests in the pull request's set, and no darwin or macOS jobs or targets in per-pull-request checks.
  Advisories never block; licences, bans and sources do.
- **B10 BLOCK.** Workflows run on hosted runners only (no self-hosted or paid ones), pin every
  action by commit SHA, set top-level `permissions: {}` where a repository requires it, never use
  `pull_request_target`, and pin external tools by URL and SHA-256. Workflows are actionlint clean.
- **B12 SHOULD.** Releases are automatic from main: no manual tag step, and no bake period or
  staged verdict that holds a release back.

### Pull request text and commits

- **P1 SHOULD.** The title says concretely what changes. No vague words: trustworthy, harden,
  robust, improve.
- **P2 SHOULD.** The body leads with the user-facing change (before and after, and what does not
  change); then a layer-by-layer walk in reading order with the why; then compatibility and failure
  modes; then the tests by name with the behaviour each asserts. Plain language. Split off any part
  that can land alone.
- **P3 BLOCK.** Commit messages cite issues as `Refs komira-ai/<repo>#<n>`, never with `Fixes`,
  `Closes` or `Resolves`. A bare `#12` is SHOULD: name the repository.
- **P4 SHOULD.** Authors commit under their own identity. A commit written with a model ends with a
  `Co-authored-by:` trailer naming that model. In a repository that enforces DCO, every commit,
  merge commits included, has a `Signed-off-by:` trailer matching the author email (BLOCK there).
- **P5 SHOULD.** History is not rewritten: no `fixup!` or `squash!` commits, no force-push, no
  amend or rebase of pushed commits. A correction is a new commit saying what it corrects.
- **P6 BLOCK.** A pull request contains only the paths its purpose needs: no `.claude/agent-memory/`
  files, scratch files, logs, `.out` files, or unrelated churn.
- **P8 SHOULD.** Stacked pull requests: the body states the stack and the merge order; the base is
  main at merge time; a stacked train lands with merge commits, not squashed.
- **P9 BLOCK.** CI ran on the pull request's head commit, not on a stale merge ref.
- **P11 SHOULD.** Every number in pull request text (tests, callers, pull requests, cache
  percentages) names the query that produced it and separates what was measured from what was
  inferred.

### Secrets and configuration

- **S1 BLOCK.** No secret, token, key, endpoint address, or worker property set is committed, and
  no remote-execution endpoint or `instance_name`.
- **S2 BLOCK.** Configuration is passed as flags, not environment variables. The allowed
  environment is platform-set mode markers, secret material, and provider-standard credentials
  (`AWS_*`, `GOOGLE_*`).
- **S3 BLOCK.** A change never makes a cluster write, upload, deploy, or cloud spend run by default,
  or run against a gamma or prod account. A step only the owner runs is a held script: dry-run by
  default, never forcing, `bash -n` clean, in its documented location.
- **S4 SHOULD.** Committed scripts and docs put temporary files in the workspace's scratch
  directory, not `/tmp`. No `rm -rf` in scripts; remove scratch with the repository's scratch
  helpers.
<!-- shared-core:end -->

## Language rules

### Rust

The Rust tools under `tools/build/` (the proto code generator and the Rust examples).

- **R1 BLOCK.** `cargo fmt --all --check` and
  `cargo clippy --workspace --all-targets --locked -- -D warnings` are green. No new `#[allow(...)]`
  or `#![allow(...)]` without a stated reason.
- **R2 BLOCK.** No `unsafe`.
- **R3 BLOCK.** No new `.unwrap()` or `.expect(` in production paths. Libraries use `thiserror`
  enums with context; `anyhow` only in binaries; no `Box<dyn Error>` in library signatures.
- **R6 BLOCK.** Dependencies come from crates.io (or pinned sibling-repository revisions) with a
  permissive licence; `cargo deny` licences, bans, and sources pass. Advisories (RUSTSEC) never
  block a pull request.
- **R7 BLOCK.** Manifests parse after the merge: no duplicate keys or merge artifacts in a changed
  `Cargo.toml`.
- **R8 BLOCK.** Crate drift: if main changed anything under a crate this pull request touches (its
  sources, tests or Cargo files) since CI ran, merge main and get a fresh CI run.
- **R9 SHOULD.** Minimal public API: small trait bounds, ownership visible in signatures, newtypes,
  no trait with a single implementation, no speculative abstraction.
- **R11 SHOULD.** A new Buck2 Rust crate or dependency is a BUCK change from the vendored list.
- **R12 SHOULD.** Files stay under 1000 lines.
- **T17 SHOULD.** Rust coverage does not rely on tests the pull request's profile skips; arms of one
  function covered only by different test binaries or generic instantiations count as missed.

### Mojo

Every `.mojo` file, checked on added lines (the rules describe new code, not the existing tree). The
reasons behind the pointer rules are in
[docs/design/mojo_safety_and_idioms.md](docs/design/mojo_safety_and_idioms.md); `//:pointer_lint`
holds M1 and M4 to M8.

- **M1 BLOCK.** No pointer type in a public API. No public `fn`, `def` or struct field takes or
  returns `UnsafePointer`, `Pointer[`, or an alias that resolves to one. Expose values,
  `ref [origin] T`, `ByteView`, `OwnedPointer[T]`, or `ArcPointer[T]`.
- **M2 SHOULD.** Prefer, in order: no pointer, `OwnedPointer`, `ArcPointer` (shared ownership only),
  then a concrete-origin `UnsafePointer` inside a body or a private signature.
- **M3 BLOCK.** Every `UnsafePointer` carries an adjacent `# SAFETY:` comment with a real soundness
  argument and a concrete origin.
- **M4 BLOCK.** Banned outside a module's FFI internals: `MutAnyOrigin`, `ImmutAnyOrigin`,
  `MutExternalOrigin`, `MutUntrackedOrigin`.
- **M5 BLOCK.** Banned: `unsafe_from_address=`.
- **M6 BLOCK.** Banned: moving a field out through a pointer
  (`UnsafePointer(to=x.f).take_pointee()`). Use `Optional.take()`, `OwnedPointer.take()`, `swap`,
  `List.pop()`, or `Slab.take_slot_*`.
- **M7 BLOCK.** Banned: stdlib `parallelize[`. Use a `ParallelDispatch` or `fork_join_shared` from
  `komira_core`.
- **M8 BLOCK.** Banned: re-declaring libc `read` or `open`. Platform constants go through a C shim.
- **M9 BLOCK.** FFI lives in the module that owns the foreign resource, behind a safe pointer-free
  function, with an `# FFI-BOUNDARY:` comment saying who owns and frees each pointer.
- **M10 BLOCK.** Heap-owning types (`List`, `String`, owned pointers) are never stored in a
  byte-typed slab through a wildcard-origin pointer.
- **M11 BLOCK.** Packaging is `.mojoc`, never `.mojopkg`. A library's dependency list is named
  `deps` (never `mojoc_deps`) and is the full transitive closure of its imports.
- **M12 SHOULD.** Do not work around a spelling or compiler error with a pointer cast.
- **M13 SHOULD.** A "compiler bug" claim needs a minimal standalone repro using no komira code. Do
  not remove a workaround whose comment cites a regression without saying why it is safe to.
- **M14 SHOULD.** Movable-only values go in `Slab[T]` or behind `OwnedPointer`, not in `List[T]`.
- **M15 BLOCK.** Files stay under 1000 lines. Keep `PERF-CRITICAL` comments through refactors; a
  pull request that removes one shows that `git blame` was checked.
- **T6 BLOCK.** A new Mojo test file appears in its library's `test_srcs`.
- **T16 SHOULD.** A standalone Mojo test covers something the welded tests do not already catch.
- **T18 SHOULD.** Every new or changed public Mojo API appears in a README example.

### Zig and Buck2

- **B1 BLOCK.** Name targets; never `komira//...` in scripts, docs, or CI. A pull request that
  reports build results uses the form `Commands: N (cached: N, remote: N, local: N)` with
  `local: 0`.
- **B2 SHOULD.** No `--no-remote-cache`, `--isolation-dir`, or `buck2 killall` in committed
  scripts, docs, or CI, except for a stated reproducibility or flake need, a sanctioned cold
  measurement, or a second concurrent daemon.
- **B3 BLOCK.** The toolchains and platforms BUCK files are templates that consuming repositories
  copy: a change to one lands together with every copy, and a change to a copy lands here. A new
  platform needs a row in `platforms/table.bzl` plus pins; a `target_compatible_with` needs a
  `komira-limit:<id>` marker and a `limits.tsv` row. Keep the `komira` cell name.
- **B4 BLOCK.** No new shell scripts, shell actions in rules, or multi-line logic in workflow
  `run:` steps where a Zig, Rust or Starlark target will do. Every CI step is one named command or
  Buck2 target. No `sh -c` in production code. New scripts are shellcheck and `bash -n` clean.
- **B5 BLOCK.** No Python (or other unpinned interpreter) dependency for non-Python targets: no
  `py_test`, `pyrun`, or helper `.py` scripts. Allowed: the Python SDK, the UDF runtime, and the
  existing fixture generators.
- **B6 BLOCK.** No negative fixtures or lints that only test buck2 built-ins or duplicate what the
  build already enforces. Negative fixtures for our own rules sit outside the pull request's query
  universe. A target the selection query cannot analyze fails loudly by name and never widens the
  pull request's check.
- **B7 SHOULD.** Build tooling under `tools/build` is Zig with Zig tests, one test target per
  scenario. A tool in another language needs a written justification.
- **B11 BLOCK.** Release platforms are `linux-x86_64`, `linux-arm64` and `macos-arm64` only.
  Platform selection uses only daemon-reported properties; no hand-set `pool=` labels; unknown
  platform keys are refused loudly; `os_version` means at-least.

## komira rules

- **B21 BLOCK.** Product constraints:
  - Query results equal DuckDB's for the same SQL. Departures only for Arrow representation limits
    (128-bit ints, infinite dates, uint64 mixed with signed), and they fail with a named error.
    Unsupported features are refused by name.
  - The job manager accepts only a serializable OptimizedPlan: no SQL text, no optimizing or
    decoding the plan body. Every engine accepts every plan a released producer emitted.
  - Durable tables stay interoperable (Iceberg via the customer's catalog, Delta, Hive Parquet); no
    komira-only readers.
  - UDFs have one mode per language: Python zygote-forked workers, Node workers, native in-process.
    No sub-interpreters, free-threaded mode, isolates, JVM or .NET.
  - The public resource schema is cloud-agnostic: no vendor words outside the override mechanism;
    clouds are values, never branched on by name.
- **B23 SHOULD.** Benchmarks: TPC-H ships with TPC's notice and is never called a TPC-H result;
  ClickBench is fetched at run time pinned by commit and sha256, never shipped (BLOCK if shipped).
- **B24 SHOULD.** Site pages: install first, then demo, then why; features not built yet are tagged
  "specified"; demos replay real runs, never invented numbers; competitors are described only as
  "not completely open source".
- **T14 BLOCK.** Tests that touch a cloud clean up after themselves and tag every billable resource
  with the validation run id.

## Keeping the shared core

The shared core is the text between the `shared-core:begin` and `shared-core:end` lines above. It is
word for word the same in every repository that carries an `AGENTS.md`, and its canonical copy is
committed here as [tools/build/agents_md/shared_core.md](tools/build/agents_md/shared_core.md),
with that copy's SHA-256 in `tools/build/agents_md/shared_core.sha256`. `//:agents_md_cases` fails
the build when this file's shared core differs from the copy by a byte, when the copy's hash is not
the recorded one, or when `CLAUDE.md` does not import this file. To change the core, change it here,
in the copy and in the hash in one commit, and make the same change in every other repository's
`AGENTS.md`, copy and hash. Everything outside the core is this repository's own and changes like
any other doc.
