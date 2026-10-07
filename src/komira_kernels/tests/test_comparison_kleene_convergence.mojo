# =============================================================================
# Differential tests — one null-implementation for comparisons
# =============================================================================
#
# Pins BYTE-EQUIVALENCE between the columnar DECIMAL predicate's null handling
# (`compiler_eval_predicate._eval_decimal_col_vs_literal` / `_col_vs_col` /
# the null-literal arm, routed through the ONE mechanism in
# `komira_kernels.comparison_kleene`) and a per-row `is_null`-gate reference.
# Semantics == the SQL-3VL base profile.
#
# Two differential families, over nullable fixtures incl. all-null / none-null
# / scattered / empty:
#
#   Part A — the converged mechanism directly: the six nullable comparison
#            variants (`eval_col_{gt,lt,eq,ne,le,ge}_nullable`) vs an
#            independent SQL-3VL scalar oracle (validity = lvalid & rvalid;
#            data on valid lanes = cmp; NULL lanes masked to data=0).
#
#   Part B — decimal reference == mechanism: a per-row `is_null`-gate loop
#            (the reference) diffed against the converged mechanism (bulk
#            decimal compare + `kleene_cmp_finalize_*`, which is precisely the
#            body production's decimal helpers run), plus the null-literal
#            all-null arm.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_kernels.comparison_kleene import (
    NullPolicy,
    NULL_POLICY_THREE_VALUED,
    merge_cmp_validity,
    kleene_cmp_finalize,
    kleene_cmp_finalize_scalar,
    kleene_all_null_predicate,
    eval_col_gt_nullable,
    eval_col_lt_nullable,
    eval_col_eq_nullable,
    eval_col_ne_nullable,
    eval_col_le_nullable,
    eval_col_ge_nullable,
)
from komira_scalar_arithmetic.decimal_compare import (
    decimal_cmp_i128,
    DEC_CMP_LT, DEC_CMP_LE, DEC_CMP_GT, DEC_CMP_GE, DEC_CMP_EQ, DEC_CMP_NE,
)


# =============================================================================
# Fixture + comparison helpers
# =============================================================================


def _build_i64_nullable(
    values: List[Int64], nulls: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """Nullable Int64 array; `nulls` lists indices to mark NULL."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](values[i]))
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    arr.null_count = len(nulls)
    return arr^


def _build_dec_nullable(
    values: List[Int], nulls: List[Int], precision: Int, scale: Int
) raises -> Decimal128Array[HeapRegion]:
    """Nullable Decimal128 array (unscaled i128 values); `nulls` = NULL rows."""
    var n = len(values)
    var arr = Decimal128Array.allocate_nullable(n, precision, scale)
    for i in range(n):
        arr.set_i128(i, SIMD[DType.int128, 1](values[i]))
    for j in range(len(nulls)):
        arr.set_null(nulls[j])
    return arr^


@always_inline
def _i64_cmp(op: String, a: Int64, b: Int64) -> Bool:
    if op == "gt":
        return a > b
    if op == "lt":
        return a < b
    if op == "eq":
        return a == b
    if op == "ne":
        return a != b
    if op == "le":
        return a <= b
    return a >= b  # "ge"


def _oracle_i64_col_col(
    left: PrimitiveArray[DType.int64],
    right: PrimitiveArray[DType.int64],
    op: String,
) raises -> BooleanArray:
    """Independent SQL-3VL spec: validity = lvalid & rvalid; data on valid
    lanes = cmp(l, r); NULL lanes = data 0."""
    var n = left.length
    var out = BooleanArray.allocate_nullable(n)
    var nulls = 0
    for i in range(n):
        if left.is_null(i) or right.is_null(i):
            out.validity.value().clear(i)
            nulls += 1
        else:
            out.set(i, _i64_cmp(op, Int64(left.load[1](i)), Int64(right.load[1](i))))
    out.null_count = nulls
    return out^


def _masks_equal(a: BooleanArray, b: BooleanArray) raises -> Bool:
    """True iff a and b are observably identical: same length, same null_count,
    same per-row validity, same data on valid lanes, AND data=0 on NULL lanes
    in BOTH (the filter-drop contract — `filter_to_indices` reads DATA only)."""
    if a.length != b.length:
        return False
    if a.null_count != b.null_count:
        return False
    for i in range(a.length):
        var an = a.is_null(i)
        var bn = b.is_null(i)
        if an != bn:
            return False
        if an:
            # NULL lane: both must read data=0 so the row drops from a filter.
            if a.get(i) or b.get(i):
                return False
        else:
            if a.get(i) != b.get(i):
                return False
    return True


# =============================================================================
# OLD-path oracles — the EXACT pre-convergence per-row is_null gate loops
# =============================================================================


def _old_decimal_col_vs_scalar(
    arr: Decimal128Array[HeapRegion],
    rhs_v: SIMD[DType.int128, 1],
    rhs_s: Int,
    cs: Int,
    dec_op: UInt8,
) raises -> BooleanArray:
    """Verbatim reproduction of the removed
    `_eval_decimal_col_vs_literal` per-row loop (data only on valid rows;
    validity cleared per `arr.is_null(i)`; null_count counted)."""
    var n = arr.length
    var out = BooleanArray.allocate_nullable(n)
    var nulls = 0
    for i in range(n):
        if arr.is_null(i):
            out.validity.value().clear(i)
            nulls += 1
        else:
            out.set(i, decimal_cmp_i128(arr.get_i128(i), cs, rhs_v, rhs_s, dec_op))
    out.null_count = nulls
    return out^


def _new_decimal_col_vs_scalar(
    arr: Decimal128Array[HeapRegion],
    rhs_v: SIMD[DType.int128, 1],
    rhs_s: Int,
    cs: Int,
    dec_op: UInt8,
) raises -> BooleanArray:
    """The NEW converged body (identical to production's decimal col-vs-literal
    helper): bulk compare on all lanes + the ONE mechanism finalize."""
    var n = arr.length
    var out = BooleanArray.allocate_nullable(n)
    for i in range(n):
        out.set(i, decimal_cmp_i128(arr.get_i128(i), cs, rhs_v, rhs_s, dec_op))
    return kleene_cmp_finalize_scalar(out^, arr.validity, NullPolicy.three_valued())


def _old_decimal_col_vs_col(
    larr: Decimal128Array[HeapRegion],
    rarr: Decimal128Array[HeapRegion],
    ls: Int,
    rs: Int,
    dec_op: UInt8,
) raises -> BooleanArray:
    """Verbatim reproduction of the removed `_eval_decimal_col_vs_col` loop."""
    var n = larr.length
    var out = BooleanArray.allocate_nullable(n)
    var nulls = 0
    for i in range(n):
        if larr.is_null(i) or rarr.is_null(i):
            out.validity.value().clear(i)
            nulls += 1
        else:
            out.set(i, decimal_cmp_i128(larr.get_i128(i), ls, rarr.get_i128(i), rs, dec_op))
    out.null_count = nulls
    return out^


def _new_decimal_col_vs_col(
    larr: Decimal128Array[HeapRegion],
    rarr: Decimal128Array[HeapRegion],
    ls: Int,
    rs: Int,
    dec_op: UInt8,
) raises -> BooleanArray:
    """The NEW converged body (identical to production's decimal col-vs-col)."""
    var n = larr.length
    var out = BooleanArray.allocate_nullable(n)
    for i in range(n):
        out.set(i, decimal_cmp_i128(larr.get_i128(i), ls, rarr.get_i128(i), rs, dec_op))
    return kleene_cmp_finalize(
        out^, larr.validity, rarr.validity, NullPolicy.three_valued()
    )


def _old_all_null(length: Int) raises -> BooleanArray:
    """Verbatim reproduction of the removed decimal null-literal arm."""
    var out = BooleanArray.allocate_nullable(length)
    for i in range(length):
        out.validity.value().clear(i)
    out.null_count = length
    return out^


# =============================================================================
# Part A — the six nullable comparison variants vs the SQL-3VL oracle
# =============================================================================


def _check_col_col_all_ops(
    lvals: List[Int64], lnulls: List[Int],
    rvals: List[Int64], rnulls: List[Int],
) raises:
    var lg = _build_i64_nullable(lvals, lnulls)
    var rg = _build_i64_nullable(rvals, rnulls)
    assert_true(_masks_equal(eval_col_gt_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "gt")))
    assert_true(_masks_equal(eval_col_lt_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "lt")))
    assert_true(_masks_equal(eval_col_eq_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "eq")))
    assert_true(_masks_equal(eval_col_ne_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "ne")))
    assert_true(_masks_equal(eval_col_le_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "le")))
    assert_true(_masks_equal(eval_col_ge_nullable[DType.int64](lg, rg), _oracle_i64_col_col(lg, rg, "ge")))


def test_partA_scattered_nulls_all_ops() raises:
    """Scattered nulls on both sides, non-byte-aligned length (11)."""
    var lvals: List[Int64] = [5, 2, 7, 1, 9, 3, 8, 4, 6, 0, 10]
    var lnulls: List[Int] = [1, 4, 9]
    var rvals: List[Int64] = [3, 4, 6, 0, 9, 3, 2, 5, 6, 1, 10]
    var rnulls: List[Int] = [0, 4, 7]
    _check_col_col_all_ops(lvals, lnulls, rvals, rnulls)


def test_partA_all_null_left() raises:
    """Every left row NULL -> every result NULL, data all 0 (all-null fixture)."""
    var lvals: List[Int64] = [5, 2, 7, 1, 9]
    var lnulls: List[Int] = [0, 1, 2, 3, 4]
    var rvals: List[Int64] = [3, 4, 6, 0, 2]
    var rnulls = List[Int]()
    _check_col_col_all_ops(lvals, lnulls, rvals, rnulls)


def test_partA_none_null() raises:
    """No nulls -> validity all-valid, data = raw compare (none-null fixture)."""
    var lvals: List[Int64] = [5, 2, 7, 1, 9, 3, 8, 4]
    var lnulls = List[Int]()
    var rvals: List[Int64] = [3, 4, 6, 0, 9, 3, 2, 5]
    var rnulls = List[Int]()
    _check_col_col_all_ops(lvals, lnulls, rvals, rnulls)


def test_partA_empty_batch() raises:
    """Length-0 batch -> length-0, null_count 0 result (empty fixture)."""
    var lvals = List[Int64]()
    var lnulls = List[Int]()
    var rvals = List[Int64]()
    var rnulls = List[Int]()
    _check_col_col_all_ops(lvals, lnulls, rvals, rnulls)


def test_partA_ge_le_are_masked_on_null() raises:
    """Direct pin that a NULL lane reads data=0 (filter-drop contract) even
    where the raw compare of the underlying (garbage) values would be True."""
    # Left row 2 NULL but its stored value 999 > right 6 would be True raw.
    var lvals: List[Int64] = [5, 2, 999, 1]
    var lnulls: List[Int] = [2]
    var rvals: List[Int64] = [3, 4, 6, 0]
    var rnulls = List[Int]()
    var lg = _build_i64_nullable(lvals, lnulls)
    var rg = _build_i64_nullable(rvals, rnulls)
    var res = eval_col_gt_nullable[DType.int64](lg, rg)
    assert_true(res.is_null(2))          # NULL propagated
    assert_false(res.get(2))             # data masked to 0 -> row drops from filter
    assert_equal(res.null_count, 1)
    assert_true(res.get(0))              # 5 > 3
    assert_false(res.is_null(0))


# =============================================================================
# Part B — decimal old-path == new-path
# =============================================================================


def test_partB_decimal_col_vs_scalar_scattered() raises:
    """Col <op> literal, scattered nulls, scale-aligned. OLD gate == NEW mechanism."""
    var vals: List[Int] = [1250, 300, 9900, 75, 6400, 12, 880, 4500, 6, 100, 20000]
    var nulls: List[Int] = [2, 5, 8]
    var arr = _build_dec_nullable(vals, nulls, precision=10, scale=2)
    var rhs_v = SIMD[DType.int128, 1](500)   # 5.00 at scale 2
    var ops: List[UInt8] = [DEC_CMP_LT, DEC_CMP_LE, DEC_CMP_GT, DEC_CMP_GE, DEC_CMP_EQ, DEC_CMP_NE]
    for k in range(len(ops)):
        var dec_op = ops[k]
        var old = _old_decimal_col_vs_scalar(arr, rhs_v, 2, 2, dec_op)
        var new = _new_decimal_col_vs_scalar(arr, rhs_v, 2, 2, dec_op)
        assert_true(_masks_equal(old^, new^))


def test_partB_decimal_col_vs_scalar_all_null() raises:
    """Every decimal row NULL (all-null fixture)."""
    var vals: List[Int] = [1250, 300, 9900, 75]
    var nulls: List[Int] = [0, 1, 2, 3]
    var arr = _build_dec_nullable(vals, nulls, precision=10, scale=2)
    var rhs_v = SIMD[DType.int128, 1](500)
    var old = _old_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_GT)
    var new = _new_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_GT)
    assert_true(_masks_equal(old^, new^))


def test_partB_decimal_col_vs_scalar_none_null() raises:
    """No nulls -> both keep the always-nullable all-valid shape (none-null)."""
    var vals: List[Int] = [1250, 300, 9900, 75, 6400]
    var nulls = List[Int]()
    var arr = _build_dec_nullable(vals, nulls, precision=10, scale=2)
    var rhs_v = SIMD[DType.int128, 1](500)
    var old = _old_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_LE)
    var new = _new_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_LE)
    assert_true(_masks_equal(old^, new^))
    assert_equal(new.null_count, 0)


def test_partB_decimal_col_vs_scalar_empty() raises:
    """Empty decimal batch (empty fixture)."""
    var vals = List[Int]()
    var nulls = List[Int]()
    var arr = _build_dec_nullable(vals, nulls, precision=10, scale=2)
    var rhs_v = SIMD[DType.int128, 1](500)
    var old = _old_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_EQ)
    var new = _new_decimal_col_vs_scalar(arr, rhs_v, 2, 2, DEC_CMP_EQ)
    assert_true(_masks_equal(old^, new^))
    assert_equal(new.length, 0)


def test_partB_decimal_col_vs_col_mixed_patterns() raises:
    """Col <op> col, DIFFERENT null patterns on the two operands (union of nulls
    drops out), non-byte-aligned length (13)."""
    var lvals: List[Int] = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200, 1300]
    var lnulls: List[Int] = [1, 5, 10]
    var rvals: List[Int] = [150, 200, 250, 400, 550, 600, 650, 800, 950, 1000, 1050, 1200, 1300]
    var rnulls: List[Int] = [2, 5, 11]
    var larr = _build_dec_nullable(lvals, lnulls, precision=10, scale=2)
    var rarr = _build_dec_nullable(rvals, rnulls, precision=10, scale=2)
    var ops: List[UInt8] = [DEC_CMP_LT, DEC_CMP_LE, DEC_CMP_GT, DEC_CMP_GE, DEC_CMP_EQ, DEC_CMP_NE]
    for k in range(len(ops)):
        var dec_op = ops[k]
        var old = _old_decimal_col_vs_col(larr, rarr, 2, 2, dec_op)
        var new = _new_decimal_col_vs_col(larr, rarr, 2, 2, dec_op)
        assert_true(_masks_equal(old^, new^))


def test_partB_decimal_col_vs_col_empty() raises:
    """Empty col-vs-col (empty fixture)."""
    var larr = _build_dec_nullable(List[Int](), List[Int](), precision=10, scale=2)
    var rarr = _build_dec_nullable(List[Int](), List[Int](), precision=10, scale=2)
    var old = _old_decimal_col_vs_col(larr, rarr, 2, 2, DEC_CMP_GT)
    var new = _new_decimal_col_vs_col(larr, rarr, 2, 2, DEC_CMP_GT)
    assert_true(_masks_equal(old^, new^))


def test_partB_null_literal_all_null() raises:
    """`col <op> NULL` -> all-null predicate. OLD inline == kleene_all_null_predicate."""
    var lengths: List[Int] = [0, 1, 7, 8, 13, 64]
    for k in range(len(lengths)):
        var length = lengths[k]
        var old = _old_all_null(length)
        var new = kleene_all_null_predicate(length, NullPolicy.three_valued())
        assert_true(_masks_equal(old^, new^))
        assert_equal(new.null_count, length)


# =============================================================================
# Mechanism-level pins — merge_cmp_validity + policy seam
# =============================================================================


def test_merge_both_all_valid_returns_none() raises:
    """3VL fast path: both operands absent-validity -> None (non-nullable)."""
    var none_bm = Optional[Bitmap[HeapRegion]](None)
    var merged = merge_cmp_validity(none_bm, none_bm, 8, NullPolicy.three_valued())
    assert_false(Bool(merged))


def test_policy_default_is_three_valued() raises:
    """The default NullPolicy is 3VL-absorb (the profile-ready default)."""
    assert_true(NullPolicy().is_three_valued())
    assert_true(NullPolicy.three_valued().is_three_valued())
    assert_equal(Int(NULL_POLICY_THREE_VALUED), 0)


def test_unimplemented_policy_raises() raises:
    """A non-3VL policy code fails loud (the seam where a future profile slots
    in) rather than silently mis-propagating."""
    var none_bm = Optional[Bitmap[HeapRegion]](None)
    var some = _build_i64_nullable([Int64(1), Int64(2)], [0])
    var raised = False
    try:
        # left has validity -> forces the merge body (not the all-valid fast path)
        _ = merge_cmp_validity(some.validity, none_bm, 2, NullPolicy(UInt8(99)))
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
