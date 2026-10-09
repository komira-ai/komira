"""The coverage policy of the build gate (README.md, "The build gate").

With `-c komira.coverage=true`, every mojo_library's conda package (what
ships; tools/build/mojo/README.md, "Coverage builds") waits for `covcheck
gate` over its tests' kcov reports, run in COVERAGE_MODE against
COVERAGE_TARGET_BP. The library itself, and its dependents, do not. Only a fixture of the `tests` cell may name another
mode (`coverage_mode`, tools/build/mojo/coverage.bzl).

Enforce is not reachable with kcov alone: the target is line and branch,
kcov's reports hold no branch record, and covcheck finds BranchNotMeasured
for every measured package while COVERAGE_TARGET_BP is above 0. The branch
source is the branch records of tools/build/coverage/branch, which a gate
reads only for a library of COVERAGE_BRANCH_GATE (below) or a fixture of
the tests cell that does not pass `coverage_branch_gate = False`; every
other library's gate still finds BranchNotMeasured.
So in enforce mode every library with a test outside that list would fail,
whatever its line coverage, and every library with no non-generated
source (a cloud SDK client, whose sources all pass through its generator)
would fail as NotMeasured. Moving to enforce first needs that list to
cover the libraries (or a decided split of the target into line and
branch) and a decision for generated libraries (README.md, "The build
gate").
"""

# census: findings are listed, never fatal; neutral: the same; enforce: a
# package with any finding fails its build (covcheck gate exits 3).
COVERAGE_MODE = "census"

# Basis points of line (and branch) coverage per package: 10000 is 100%.
COVERAGE_TARGET_BP = 10000

# The mode of every mojo_shared_lib's coverage gate (tools/build/mojo/coverage.bzl,
# coverage_shared_lib): a shared library's drivers are measured and their
# reports and the gate's result are its `[coverage]`, but it has no coverage
# target. Decided: a shared library is the C ABI of code whose own
# libraries are measured and gated by their tests (a library's gate reads its
# own tests' reports only), and one loaded by a program's end-to-end tests
# exists for those tests, so its line coverage is reported, never enforced.
# This is its own constant, not COVERAGE_MODE: moving the libraries to enforce
# moves no shared library. coverage.bzl refuses `enforce` here, and for any
# mojo_shared_lib, a tests-cell fixture included (in analysis); and nothing
# waits for a shared library's coverage runs or gate (it ships no conda
# package), so its published file builds whatever they find. Reported means
# its `[coverage]` (`[coverage][gate][summary]`) when built by name: the pull
# request's coverage workflow (.github/ci/coverage_measure.sh) selects
# mojo_library targets only, so no workflow reports a shared library's gate
# yet. Its report counts the shared library's own sources (its C ABI), not
# the code compiled into it from its Mojo dependencies, which their own
# tests measure.
COVERAGE_SHARED_LIB_MODE = "census"

# The directories of test-only packages, relative to a cell's root (the
# layout of src/: test-only packages are under src/tests/<kind>/). A
# package in one of them or under it, at a path-segment boundary, is
# measured and shown as every package is, but held to no target: what
# covcheck finds in it is information (covcheck --info-package), never a
# finding, so its coverage gate never fails on a finding, in any mode, and
# a check run neither fails on it nor annotates it above `notice`. An input
# covcheck refuses (its exit 1 or 2) still fails the gate. Every finding
# of the package is information, BelowTarget and the ratchet's (a
# Regression below a row it has) included, and covcheck proposes no
# ratchet row for it: a test-only package has no floor. An entry must be
# a relative directory with no empty, `.` or `..` segment and no trailing
# `/` (tools/build/mojo/coverage.bzl fails at load otherwise). Read by the
# gate and, as written on this one line, by .github/ci/coverage_measure.sh.
COVERAGE_INFO_ONLY_DIRS = ["src/tests"]

# The ledger of libraries that cannot have a coverage gate of their own, by
# label, each with why and where it is gated instead.
# tools/build/coverage/no_gate.bxl holds this list equal to the Mojo
# libraries the gate depends on (covcheck_bin's, and through komira_json's
# README the README tool's), so a row whose library leaves that closure
# fails the check until it is deleted, and a library that joins it fails
# until it has a row (without one, the library would depend on its own
# gate's directory, which depends on the library: a cycle of configured
# targets, whatever waits for the gate). It only shrinks: the check also holds it within the
# frozen list `_CEILING` of no_gate.bxl, so a new row means a reviewed edit
# of that list too, not only a new dependency of covcheck.
#
# Each still has its coverage binaries and runs; its gate is the target
# `<name>_cov_gate`, and its conda package (what ships) waits for both, as
# every library's conda package waits for its runs and its gate.
_CLOSURE = "covcheck_bin, the gate's tool, depends on it"

COVERAGE_NO_GATE = {
    "komira//src/komira_json:komira_json": _CLOSURE + " (covcheck reads and writes JSON with it)",
    "komira//tools/build/coverage:covcheck": _CLOSURE + " (the library covcheck_bin runs)",
    "komira//tools/build/readme_examples:readme_examples": _CLOSURE + " (komira_json and covcheck have a README.md, whose examples its tool turns into a test)",
}

# The libraries whose coverage gate reads their tests' branch records
# (tools/build/coverage/branch/README.md; covcheck's --branch-lcov), by
# label, each with its evidence. Their gates then wait for every branch
# coverage action of their tests (bitcode, instrumented link, run, profile
# applied, classifier), so a branch the classifier refuses fails the
# library's coverage gate in every mode, which blocks its conda package
# (what ships) and nothing else. The classifier refuses what it has no evidence for
# (README.md of tools/build/coverage/branch, "Classes"), and some code has
# shapes it refuses (an `and`/`or` whose result is returned, stored or
# passed on; copies of a function that disagree: that README's "Refusals
# that stay"), so a library joins this list only when its tests' branches
# all classify and its records hold an arm; the sweep of every library
# grows it. A library of the ledger COVERAGE_NO_GATE is read by its
# `<name>_cov_gate`. Joining also
# means covcheck's refusal of two tests' records that give one location a
# different number of decisions (branch_lcov.mojo, DecisionShapes) fails
# the gate in every mode: a new test instantiating one of the library's
# generic functions with another specialisation can turn its coverage gate
# red in census mode. A fixture of the tests cell reads its branch records
# unless it passes `coverage_branch_gate = False` (coverage.bzl). A library
# not on the list keeps BranchNotMeasured. mojo_library looks itself up by
# its label, so a row whose library moved would be read by nothing:
# branch_gate.bxl fails unless every row names a mojo_library.
#
# A raising call in a `try:` body of its function is a decision of two arms
# (kind `try`: the call returned, it raised into the handler), so a
# library's tests must make each such call raise as well as return; a call
# whose error goes to its caller is not one (branch/README.md, "try"). A
# library whose `try:` bodies hold a shape the classifier refuses leaves
# the list, with the reason, rather than the rule being weakened.
#
# The decision on mutation testing (covcheck's --mutants, README.md "The
# mutants file"): once a package's branch coverage is enforced, mutation
# testing is not its enforced gate; its branch arms are. What the code does
# today: no build action passes --mutants, so mutation never gates a
# package. covcheck itself would still fail an enforce gate on a
# MutantSurvived finding if a gate were given --mutants (any finding exits
# 3 in enforce mode); making mutation results report-only there is future
# work, not done.
COVERAGE_BRANCH_GATE = {
    "komira//src/kci_cloud_fake:kci_cloud_fake": "its eleven tests' branches all classify (556 arms of 9 files, 6 of them `try` arms)",
    "komira//src/kci_secret_writer:kci_secret_writer": "its test's branches all classify (16 arms of 1 file)",
    "komira//src/kci_validator_rows:kci_validator_rows": "its test's branches all classify (40 arms of 2 files)",
    "komira//src/komira_agg:komira_agg": "its ten tests' branches all classify (228 arms of 7 files)",
    "komira//src/komira_async_api:komira_async_api": "its test's branches all classify (2 arms of 1 file)",
    "komira//src/komira_buffer:komira_buffer": "its eleven tests' branches all classify (154 arms of 6 files)",
    "komira//src/komira_clock:komira_clock": "its test's branches all classify (2 arms of 1 file)",
    "komira//src/komira_column_format:komira_column_format": "its two tests' branches all classify (170 arms of 1 file)",
    "komira//src/komira_compression:komira_compression": "its four tests' branches all classify (100 arms of 6 files, 36 of them `try` arms)",
    "komira//src/komira_counters:komira_counters": "its five tests' branches all classify (80 arms of 3 files, 2 of them `try` arms)",
    "komira//src/komira_dynamic_filter:komira_dynamic_filter": "its six tests' branches all classify (52 arms of 4 files)",
    "komira//src/komira_exec_types:komira_exec_types": "its test's branches all classify (58 arms of 1 file)",
    "komira//src/komira_fork_join:komira_fork_join": "its test's branches all classify (26 arms of 1 file, 2 of them `try` arms)",
    "komira//src/komira_hash:komira_hash": "its test's branches all classify (4 arms of 1 file)",
    "komira//src/komira_json:komira_json": "its six tests' branches all classify (564 arms of 3 files)",
    "komira//src/komira_jwks:komira_jwks": "its test's branches all classify (6 arms of 2 files)",
    "komira//src/komira_libc:komira_libc": "its eight tests' branches all classify (94 arms of 5 files)",
    "komira//src/komira_lz4:komira_lz4": "its three tests' branches all classify (76 arms of 2 files, 16 of them `try` arms)",
    "komira//src/komira_name_registry:komira_name_registry": "its test's branches all classify (32 arms of 1 file)",
    # komira_parquet left the list: ten of its tests' branches do not all
    # classify at this head, without the `try` rule as with it. An `or` and
    # an `and` whose result is returned (decode_helpers.mojo 210:9,
    # dict_gather_fused.mojo 144:31), and at calls in `try:` bodies
    # (def_level_bitmap.mojo 99:40 `read_byte(`, footer_header.mojo
    # 325:31, 326:35, 330:38 `byte_at(`) a select and a br on an inlined
    # callee's String flags carried through a `select`, which the String
    # rule does not read: the select refused before the rule, the br, a
    # call's compiler-made branch before, refused in a `try:` body by it.
    "komira//src/komira_parquet_api:komira_parquet_api": "its four tests' branches all classify (124 arms of 2 files)",
    "komira//src/komira_parquet_codec:komira_parquet_codec": "its 16 tests' branches all classify (416 arms of 8 files, 14 of them `try` arms)",
    "komira//src/komira_plan_ir:komira_plan_ir": "its 19 tests' branches all classify (1130 arms of 9 files)",
    "komira//src/komira_plan_stats:komira_plan_stats": "its test's branches all classify (116 arms of 2 files)",
    "komira//src/komira_protobuf:komira_protobuf": "its two tests' branches all classify (106 arms of 2 files)",
    "komira//src/komira_resources:komira_resources": "its test's branches all classify (2 arms of 1 file)",
    "komira//src/komira_retry:komira_retry": "its six tests' branches all classify (74 arms of 4 files)",
    "komira//src/komira_row_format:komira_row_format": "its nine tests' branches all classify (682 arms of 5 files)",
    "komira//src/komira_scalar_arithmetic:komira_scalar_arithmetic": "its test's branches all classify (24 arms of 1 file)",
    "komira//src/komira_secret_registry:komira_secret_registry": "its test's branches all classify (16 arms of 2 files)",
    "komira//src/komira_secret_store:komira_secret_store": "its test's branches all classify (10 arms of 2 files)",
    "komira//src/komira_snapshotter:komira_snapshotter": "its test's branches all classify (28 arms of 1 file)",
    "komira//src/komira_spsc_ring:komira_spsc_ring": "its two tests' branches all classify (50 arms of 2 files, 2 of them `try` arms)",
    "komira//src/komira_sync:komira_sync": "its test's branches all classify (4 arms of 1 file)",
    "komira//src/komira_test_run_id:komira_test_run_id": "its two tests' branches all classify (16 arms of 2 files, 4 of them `try` arms)",
    "komira//src/komira_trace:komira_trace": "its eight tests' branches all classify (102 arms of 2 files)",
    "komira//src/komira_udf:komira_udf": "its four tests' branches all classify (36 arms of 1 file)",
    "komira//src/komira_uuid:komira_uuid": "its test's branches all classify (84 arms of 2 files)",
    "komira//src/komira_wkt:komira_wkt": "its eight tests' branches all classify (556 arms of 6 files, 2 of them `try` arms)",
    "komira//src/komira_zlib:komira_zlib": "its test's branches all classify (76 arms of 1 file, 2 of them `try` arms)",
    "komira//src/tests/e2e/komira_udf_e2e:komira_udf_e2e": "its four tests' branches all classify (16 arms of 1 file)",
    "komira//src/tests/helpers/komira_test_minio:komira_test_minio": "its two tests' branches all classify (110 arms of 4 files, 42 of them `try` arms)",
}
