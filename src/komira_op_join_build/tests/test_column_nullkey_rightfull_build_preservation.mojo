# =============================================================================
# test_column_nullkey_rightfull_build_preservation -- a NULL-keyed BUILD row is
# kept by RIGHT and FULL joins (as an unmatched build row), against a DuckDB
# value oracle
# =============================================================================
#
# `HashJoinBuilder.build` RECORDS a NULL build key but leaves it UNLINKED from
# any bucket, so it is never a probe's match target (INNER/LEFT/SEMI/ANTI are
# right) and the `probe_right` / `probe_full` unmatched-build sweep emits it as
# `(build_index, -1)`. A build path that skipped the NULL row at insert would
# drop it from RIGHT/FULL: a silently smaller answer. The oracle is DuckDB's
# answer, hardcoded, not another engine path.
#
# ## OUTPUT CONTRACT (probe_right / probe_full)
# Both return `(build_indices, probe_indices)` where, for a build row with NO
# probe match, the pair is `(build_index, -1)`. `build_index == self.build_indices
# [chain_idx]` is the ORIGINAL build-table row index (here we feed build rows in
# index order 0..n-1, so `build_index` == the build row's original position).
# `probe_index == -1` IS the unmatched-build sweep marker (NULL probe cells);
# `build_index == -1` (FULL only) IS the unmatched-probe marker (NULL build cells).
#
# ## DuckDB-VALUE ORACLE 
#   CREATE TABLE R(k INT, bp INT);  CREATE TABLE S(k INT, pp INT);   -- R=build, S=probe
#   -- §1 RIGHT:  R = (NULL,100),(7,200),(9,201),(9,202) ; S = (NULL,900),(7,901),(8,902)
#   --   S RIGHT JOIN R -> 4 rows: (7<->7 match) + sweep{NULL-keyed 100, 201, 202}.
#   -- §2 FULL:   R = (NULL,100),(7,200),(9,201),(11,202); S = (NULL,900),(7,901),(8,902),(6,903)
#   --   S FULL OUTER JOIN R -> 7 rows: 1 match + 3 unmatched-build (incl NULL 100)
#   --                                  + 3 unmatched-probe (incl NULL probe 900).
#
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder


# A NULL-keyed nullable Int64 column. `values[i]` is stamped at row i; if
# `nulls[i]` the row is marked NULL (the stamped value is then "don't care" but
# we stamp the SQL-irrelevant backing 0 to mirror the engine's NULL encoding).
def _make_nullable_i64(imm values: List[Int], imm nulls: List[Bool]) raises -> PrimitiveArray[DType.int64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](values[i])
    for i in range(n):
        if nulls[i]:
            arr._set_null(i)
    return arr^


def _contains_pair(
    imm build_idx: List[Int], imm probe_idx: List[Int], b: Int, p: Int
) -> Bool:
    """True iff the (build_index, probe_index) pair (b, p) appears in the output."""
    for i in range(len(build_idx)):
        if build_idx[i] == b and probe_idx[i] == p:
            return True
    return False


# =============================================================================
# §1 — COLUMN RIGHT join, NULL-keyed build row preserved (DuckDB-VALUE oracle).
#
# BUILD (row -> key, payload): 0->(NULL,100) ; 1->(7,200) ; 2->(9,201) ; 3->(9,202)
# PROBE (row -> key, payload):  0->(NULL,900) ; 1->(7,901) ; 2->(8,902)
#
# `probe_right` output pairs (build_index, probe_index):
#   * (1, 1)  -> build 7 (row 1) matches probe 7 (row 1).         MATCH
#   * NULL probe (row 0): matches NOTHING -> NO pair (RIGHT drops unmatched probe).
#   * probe 8 (row 2): no build 8 -> no pair.
#   * BUILD sweep (every unmatched build row, probe_index == -1):
#       - (0, -1) -> the NULL-keyed build row 0 (payload 100). ★ The bug-fix row:
#         pre-fix the ROW paths DROPPED it; the COLUMN path always preserved it.
#       - (2, -1) -> build 9 (row 2, payload 201): no probe 9.
#       - (3, -1) -> build 9 (row 3, payload 202): no probe 9.
#   => 4 pairs: 1 match + 3 sweep, byte-identical to DuckDB `S RIGHT JOIN R`.
# =============================================================================
def test_column_nullkey_right_build_preserved() raises:
    var bvals: List[Int] = [0, 7, 9, 9]
    var bnull: List[Bool] = [True, False, False, False]
    var pvals: List[Int] = [0, 7, 8]
    var pnull: List[Bool] = [True, False, False]

    var build_keys = _make_nullable_i64(bvals, bnull)
    var probe_keys = _make_nullable_i64(pvals, pnull)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_right(probe_keys)
    ref build_idx = result[0]
    ref probe_idx = result[1]

    # Total pairs must equal DuckDB's row count.
    assert_equal(
        len(build_idx), 4,
        "column RIGHT nullkey: 1 match + 3 unmatched-build = 4 pairs (DuckDB).",
    )
    assert_equal(len(probe_idx), 4, "column RIGHT nullkey: parallel pair lists.")

    # The single real match: build row 1 (key 7) <-> probe row 1 (key 7).
    assert_true(
        _contains_pair(build_idx, probe_idx, 1, 1),
        "column RIGHT nullkey: build row 1 (7) must match probe row 1 (7).",
    )

    # ★ THE BUG-FIX ASSERTION (column path): the NULL-keyed build row (row 0,
    # payload 100) MUST appear as an unmatched-build pair (build 0, probe -1).
    assert_true(
        _contains_pair(build_idx, probe_idx, 0, -1),
        "column RIGHT nullkey: the NULL-keyed build row 0 (payload 100) MUST be"
        " preserved as an unmatched-build pair (0, -1) — DuckDB-confirmed. The"
        " build records the NULL key but never links it.",
    )

    # The two unmatched 9-keyed build rows (rows 2 + 3): (2, -1) and (3, -1).
    assert_true(
        _contains_pair(build_idx, probe_idx, 2, -1)
        and _contains_pair(build_idx, probe_idx, 3, -1),
        "column RIGHT nullkey: both unmatched 9-keyed build rows must be swept.",
    )

    # A NULL probe key (row 0, key NULL) matches NOTHING and RIGHT drops the
    # unmatched probe, so NO pair may carry probe_index == 0 (the NULL probe row)
    # NOR may the NULL build row 0 be SPURIOUSLY matched to it.
    var saw_probe0 = False
    for i in range(len(probe_idx)):
        if probe_idx[i] == 0:
            saw_probe0 = True
    assert_true(
        not saw_probe0,
        "column RIGHT nullkey: NULL probe (row 0) matches nothing — RIGHT drops"
        " unmatched probe rows, so probe_index 0 must NOT appear (NULL must not"
        " spuriously match the NULL build key).",
    )


# =============================================================================
# §2 — COLUMN FULL join, NULL-keyed build row preserved (DuckDB-VALUE oracle).
#
# BUILD (row -> key, payload): 0->(NULL,100) ; 1->(7,200) ; 2->(9,201) ; 3->(11,202)
# PROBE (row -> key, payload):  0->(NULL,900) ; 1->(7,901) ; 2->(8,902) ; 3->(6,903)
#
# `probe_full` output pairs (build_index, probe_index):
#   * (1, 1)   -> build 7 (row 1) matches probe 7 (row 1).          MATCH
#   * Unmatched-PROBE (build_index == -1, NULL build cells):
#       - (-1, 0) -> NULL probe (row 0): matches nothing -> preserved (FULL keeps
#         every probe row); ★ must NOT be spuriously matched to the NULL build key.
#       - (-1, 2) -> probe 8 (row 2): no build 8.
#       - (-1, 3) -> probe 6 (row 3): no build 6.
#   * Unmatched-BUILD sweep (probe_index == -1, NULL probe cells):
#       - (0, -1) -> the NULL-keyed build row 0 (payload 100). ★ bug-fix row.
#       - (2, -1) -> build 9 (row 2, payload 201).
#       - (3, -1) -> build 11 (row 3, payload 202).
#   => 7 pairs: 1 match + 3 unmatched-probe + 3 unmatched-build, byte-identical
#      to DuckDB `S FULL OUTER JOIN R`.
# =============================================================================
def test_column_nullkey_full_build_preserved() raises:
    var bvals: List[Int] = [0, 7, 9, 11]
    var bnull: List[Bool] = [True, False, False, False]
    var pvals: List[Int] = [0, 7, 8, 6]
    var pnull: List[Bool] = [True, False, False, False]

    var build_keys = _make_nullable_i64(bvals, bnull)
    var probe_keys = _make_nullable_i64(pvals, pnull)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_full(probe_keys)
    ref build_idx = result[0]
    ref probe_idx = result[1]

    assert_equal(
        len(build_idx), 7,
        "column FULL nullkey: 1 match + 3 unmatched-probe + 3 unmatched-build ="
        " 7 pairs (DuckDB `S FULL OUTER JOIN R`).",
    )
    assert_equal(len(probe_idx), 7, "column FULL nullkey: parallel pair lists.")

    # The single real match: build row 1 (7) <-> probe row 1 (7).
    assert_true(
        _contains_pair(build_idx, probe_idx, 1, 1),
        "column FULL nullkey: build row 1 (7) must match probe row 1 (7).",
    )

    # ★ THE BUG-FIX ASSERTION (column path): the NULL-keyed build row 0 (payload
    # 100) MUST be swept as an unmatched-build pair (0, -1).
    assert_true(
        _contains_pair(build_idx, probe_idx, 0, -1),
        "column FULL nullkey: the NULL-keyed build row 0 (payload 100) MUST be"
        " swept as an unmatched-build pair (0, -1) — DuckDB-confirmed.",
    )

    # The two non-NULL unmatched build rows: build 9 (row 2) + build 11 (row 3).
    assert_true(
        _contains_pair(build_idx, probe_idx, 2, -1)
        and _contains_pair(build_idx, probe_idx, 3, -1),
        "column FULL nullkey: the unmatched 9 + 11 build rows must be swept.",
    )

    # The NULL probe (row 0) is PRESERVED unmatched (FULL keeps every probe row)
    # as (-1, 0) — it must NOT be spuriously matched against the NULL build key.
    assert_true(
        _contains_pair(build_idx, probe_idx, -1, 0),
        "column FULL nullkey: the NULL probe (row 0) must be preserved unmatched"
        " as (-1, 0) — NOT spuriously matched to the NULL build key.",
    )

    # The non-matching 8 + 6 probe rows preserved unmatched: (-1, 2) and (-1, 3).
    assert_true(
        _contains_pair(build_idx, probe_idx, -1, 2)
        and _contains_pair(build_idx, probe_idx, -1, 3),
        "column FULL nullkey: the non-matching 8 + 6 probe rows must be preserved"
        " unmatched.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_nullkey_right_build_preserved]()
    suite.test[test_column_nullkey_full_build_preserved]()
    suite^.run()
