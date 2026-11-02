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
