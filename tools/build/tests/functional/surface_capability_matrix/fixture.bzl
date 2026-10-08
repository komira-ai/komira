"""The planted matrix of test 53 (the surface capability matrix).

Two surfaces, pandas and polars, whose e2e packages are planted under
src/tests/e2e/ of this directory (real mojo_library and mojo_test targets,
the lint only analyses them; tests//functional/... builds them). Five
capabilities, grounded in
two planted grounding files:

plan.txt (src/plan/plan.mojo in the tree, families PLAN_ and JOIN_) declares
PLAN_SCAN, PLAN_FILTER, PLAN_JOIN, PLAN_CSE_REF, JOIN_INNER, JOIN_LEFT and
JOIN_ALGO_HASH, each named by a capability or a NOT_CAPABILITIES row (so the
family check passes), and SOURCE_CSV, outside the families, which a
capability names. Near misses that are no declaration, each of which would
be an unnamed PLAN_ constant if read: `comptime PLAN_TAG_COUNT: Int` (not
UInt8), a commented-out PLAN_RETIRED and an indented PLAN_NESTED. PLAN_UNTYPED
is declared as `comptime PLAN_UNTYPED = UInt8(16)`, the unannotated form,
which the lint reads: a NOT_CAPABILITIES row names it, so reading it is what
keeps `ok` green.
udf.txt (src/plan/udf.mojo, no family) declares UDF_KIND_MAP, which udf_map
names, and UDF_KIND_SPARE, which nothing names and nothing has to.

MATRIX fills three of the ten cells: pandas scan_csv with a mojo_library
whose test_srcs weld a test, pandas filter with a mojo_test named by a
label relative to this cell (`//functional/...`, so the package check reads
where Buck2 puts the target, not the text), and polars filter. The census
must equal expect_matrix.tsv and expect_report.txt byte for byte, with
FLOOR, the count of filled cells. negative/surface_capability_matrix plants
one defect each in these lists, naming the other planted targets: in
pandas_e2e, lib_no_tests (a mojo_library that welds no test), alias_outside
(an alias of test_outside) and test_mac (incompatible with Linux); the
packages pandas_e2e/sub and pandas_e2e_extra, which are not the surface's
package; and test_outside, a test of this package, outside src/tests/e2e.
"""

_DIR = "tests//functional/surface_capability_matrix:"
_E2E = "tests//functional/surface_capability_matrix/src/tests/e2e/"

E2E = _E2E

SCM_ROOT = "functional/surface_capability_matrix/src"

SCM_FILES = {
    "src/plan/plan.mojo": _DIR + "plan.txt",
    "src/plan/udf.mojo": _DIR + "udf.txt",
}

SCM_GROUNDING = {
    "src/plan/plan.mojo": ["PLAN_", "JOIN_"],
    "src/plan/udf.mojo": [],
}

SCM_SURFACES = ["pandas", "polars"]

SCM_CAPABILITIES = [
    ("scan_csv", "PLAN_SCAN,SOURCE_CSV", "read CSV files"),
    ("filter", "PLAN_FILTER", "keep the rows a predicate holds for"),
    ("join_left", "PLAN_JOIN,JOIN_LEFT", "left outer join"),
    ("udf_map", "UDF_KIND_MAP", "a user function computing a column"),
    ("errors", "contract", "a failure raises to the caller"),
]

SCM_NOT_CAPABILITIES = [
    ("PLAN_CSE_REF", "made only by an optimizer rewrite"),
    ("PLAN_UNTYPED", "declared without an annotation, as UInt8(16): read all the same"),
    ("JOIN_INNER,JOIN_ALGO_HASH", "left out of this fixture's vocabulary"),
]

SCM_MATRIX = [
    ("pandas", "scan_csv", _E2E + "pandas_e2e:pandas_e2e", "its welded test_srcs"),
    ("pandas", "filter", "//functional/surface_capability_matrix/src/tests/e2e/pandas_e2e:test_filter", "a mojo_test, by a cell-relative label"),
    ("pandas", "join_left", "-", "no test yet"),
    ("pandas", "udf_map", "-", ""),
    ("pandas", "errors", "-", "no test yet"),
    ("polars", "scan_csv", "-", "no test yet"),
    ("polars", "filter", _E2E + "polars_e2e:test_filter", "a mojo_test"),
    ("polars", "join_left", "-", "no test yet"),
    ("polars", "udf_map", "-", "no test yet"),
    ("polars", "errors", "-", "no test yet"),
]

SCM_FLOOR = 3

def scm_set(rows, surface, capability, target):
    """`rows` with the target of (surface, capability) replaced (a negative's plant)."""
    return [(s, c, target if (s, c) == (surface, capability) else t, n) for s, c, t, n in rows]
