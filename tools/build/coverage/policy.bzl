"""The coverage policy of the build gate (README.md, "The build gate").

With `-c komira.coverage=true`, every mojo_library's package
(tools/build/mojo/README.md, "Coverage builds") waits for `covcheck gate`
over its tests' kcov reports, run in COVERAGE_MODE against
COVERAGE_TARGET_BP. Only a fixture of the `tests` cell may name another
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

# The ledger of libraries whose own package cannot wait for a coverage gate,
# by label, each with why and where it is gated instead.
# tools/build/coverage/no_gate.bxl holds this list equal to the Mojo
# libraries the gate depends on (covcheck_bin's, and through komira_json's
# README the README tool's), so a row whose library leaves that closure
# fails the check until it is deleted, and a library that joins it fails
# until it has a row (without one, its package would depend on its own
# gate: a cycle). It only shrinks: the check also holds it within the
# frozen list `_CEILING` of no_gate.bxl, so a new row means a reviewed edit
# of that list too, not only a new dependency of covcheck.
#
# Each still has its coverage binaries and runs, and its package still waits
# for them (a test failing at -O0 or under kcov fails it); its gate is the
# target `<name>_cov_gate`, which its conda package (what ships) waits for.
_CLOSURE = "covcheck_bin, the gate's tool, depends on it"

COVERAGE_NO_GATE = {
    "komira//src/komira_json:komira_json": _CLOSURE + " (covcheck reads and writes JSON with it)",
    "komira//tools/build/coverage:covcheck": _CLOSURE + " (the library covcheck_bin runs)",
    "komira//tools/build/readme_examples:readme_examples": _CLOSURE + " (komira_json and covcheck have a README.md, whose examples its tool turns into a test)",
}

# The libraries whose coverage gate reads their tests' branch records
# (tools/build/coverage/branch/README.md; covcheck's --branch-lcov), by
# label, each with its evidence. Their packages then wait for every branch
# coverage action of their tests (bitcode, instrumented link, run, profile
# applied, classifier), so a branch the classifier refuses fails the
# library's coverage build in every mode, and the packages of every library
# depending on it. The classifier refuses what it has no evidence for
# (README.md of tools/build/coverage/branch, "Classes"), and most code has
# shapes it has not seen yet (a comparison of Strings, indexing, `+=`, a
# returned `and`), so a library joins this list only when its tests'
# branches all classify; the sweep of every library grows it. Joining also
# means covcheck's refusal of two tests' records that give one location a
# different number of decisions (branch_lcov.mojo, DecisionShapes) fails
# the gate in every mode: a new test instantiating one of the library's
# generic functions with another specialisation can turn its coverage build
# red in census mode. A fixture of the tests cell reads its branch records
# unless it passes `coverage_branch_gate = False` (coverage.bzl). A library
# not on the list keeps BranchNotMeasured.
COVERAGE_BRANCH_GATE = {
    "komira//src/komira_retry:komira_retry": "its six tests' branches all classify (74 arms of 4 files)",
}
