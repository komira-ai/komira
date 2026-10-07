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
# generic functions with another specialisation can turn its coverage build
# red in census mode. A fixture of the tests cell reads its branch records
# unless it passes `coverage_branch_gate = False` (coverage.bzl). A library
# not on the list keeps BranchNotMeasured.
COVERAGE_BRANCH_GATE = {
    "komira//src/kci_cloud_fake:kci_cloud_fake": "its nine tests' branches all classify (474 arms of 7 files)",
    "komira//src/kci_secret_writer:kci_secret_writer": "its test's branches all classify (16 arms of 1 file)",
    "komira//src/kci_validator_rows:kci_validator_rows": "its test's branches all classify (40 arms of 2 files)",
    "komira//src/komira_agg:komira_agg": "its ten tests' branches all classify (228 arms of 7 files)",
    "komira//src/komira_async_api:komira_async_api": "its test's branches all classify (2 arms of 1 file)",
    "komira//src/komira_buffer:komira_buffer": "its eleven tests' branches all classify (154 arms of 6 files)",
    "komira//src/komira_clock:komira_clock": "its test's branches all classify (2 arms of 1 file)",
    "komira//src/komira_column_format:komira_column_format": "its two tests' branches all classify (170 arms of 1 file)",
    "komira//src/komira_compression:komira_compression": "its four tests' branches all classify (64 arms of 5 files)",
    "komira//src/komira_counters:komira_counters": "its five tests' branches all classify (78 arms of 3 files)",
    "komira//src/komira_dynamic_filter:komira_dynamic_filter": "its six tests' branches all classify (52 arms of 4 files)",
    "komira//src/komira_exec_types:komira_exec_types": "its test's branches all classify (58 arms of 1 file)",
    "komira//src/komira_fork_join:komira_fork_join": "its test's branches all classify (24 arms of 1 file)",
    "komira//src/komira_hash:komira_hash": "its test's branches all classify (4 arms of 1 file)",
    "komira//src/komira_json:komira_json": "its six tests' branches all classify (564 arms of 3 files)",
    "komira//src/komira_jwks:komira_jwks": "its test's branches all classify (6 arms of 2 files)",
    "komira//src/komira_libc:komira_libc": "its eight tests' branches all classify (94 arms of 5 files)",
    "komira//src/komira_lz4:komira_lz4": "its three tests' branches all classify (60 arms of 2 files)",
    "komira//src/komira_name_registry:komira_name_registry": "its test's branches all classify (32 arms of 1 file)",
    "komira//src/komira_parquet:komira_parquet": "its 23 tests' branches all classify (676 arms of 12 files)",
    "komira//src/komira_parquet_api:komira_parquet_api": "its four tests' branches all classify (124 arms of 2 files)",
    "komira//src/komira_parquet_codec:komira_parquet_codec": "its 15 tests' branches all classify (438 arms of 9 files)",
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
    "komira//src/komira_spsc_ring:komira_spsc_ring": "its two tests' branches all classify (48 arms of 2 files)",
    "komira//src/komira_sync:komira_sync": "its test's branches all classify (4 arms of 1 file)",
    "komira//src/komira_test_run_id:komira_test_run_id": "its two tests' branches all classify (12 arms of 2 files)",
    "komira//src/komira_trace:komira_trace": "its eight tests' branches all classify (102 arms of 2 files)",
    "komira//src/komira_udf:komira_udf": "its four tests' branches all classify (36 arms of 1 file)",
    "komira//src/komira_uuid:komira_uuid": "its test's branches all classify (84 arms of 2 files)",
    "komira//src/komira_wkt:komira_wkt": "its six tests' branches all classify (548 arms of 6 files)",
    "komira//src/komira_zlib:komira_zlib": "its test's branches all classify (74 arms of 1 file)",
    "komira//src/tests/e2e/komira_udf_e2e:komira_udf_e2e": "its four tests' branches all classify (16 arms of 1 file)",
    "komira//src/tests/support/komira_test_minio:komira_test_minio": "its two tests' branches all classify (68 arms of 4 files)",
}
