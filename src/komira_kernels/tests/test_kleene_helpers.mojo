# =============================================================================
# Unit tests for Kleene 3VL helpers + comparison Kleene-aware variants
# =============================================================================
#
# Coverage:
#   Kleene chunk helpers (SIMD-W operand):
#     1. _kleene_and_chunk — FALSE AND NULL = FALSE; TRUE AND NULL = NULL;
#        NULL AND NULL = NULL; all-valid AND fast-equiv to bitwise AND.
#     2. _kleene_or_chunk — TRUE OR NULL = TRUE; FALSE OR NULL = NULL;
#        NULL OR NULL = NULL.
#     3. _kleene_not_chunk — NOT NULL preserves invalidity; flips
#        data on valid lanes.
#
#   Kleene byte helpers (bitmap byte operands):
#     4. _kleene_and_byte — formula matches arithmetic.mojo
#        (`(lv & ~ld) | (rv & ~rd) | (lv & rv)`).
#     5. _kleene_or_byte — formula matches arithmetic.mojo.
#     6. _kleene_not_byte — preserves validity unchanged.
#     7. _cmp_result_validity_byte — `lv & rv` (AND of operand
#        validities, no value dependence — for cmp kernels).
#
#   Kleene comparison variants:
#     8. eval_col_gt_kleene — non-nullable inputs preserve fast path;
#        nullable inputs propagate validity per `left.valid & right.valid`.
#     9. eval_col_lt_kleene — same shape.
#    10. eval_col_eq_kleene — same shape.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_kernels.eval_chunks import EvalBoolChunk
from komira_kernels.kleene import (
    _kleene_and_chunk,
    _kleene_or_chunk,
    _kleene_not_chunk,
    _kleene_and_byte,
    _kleene_or_byte,
    _kleene_not_byte,
    _cmp_result_validity_byte,
    _cmp_result_validity_chunk,
)
from komira_column_kernels.comparison import (
    eval_col_gt_kleene,
    eval_col_lt_kleene,
    eval_col_eq_kleene,
)


# =============================================================================
# Chunk helpers — SIMD-W lane semantics
# =============================================================================


def test_kleene_and_chunk_false_short_circuit() raises:
    """FALSE AND NULL = FALSE (left short-circuits). Lane 0 has
    l.value=False, l.valid=True, r.value=any, r.valid=False (NULL).
    """
    var l = EvalBoolChunk[2](
        values=SIMD[DType.bool, 2](False, True),
        validity=SIMD[DType.bool, 2](fill=True),
    )
    var r = EvalBoolChunk[2](
        values=SIMD[DType.bool, 2](True, True),
        validity=SIMD[DType.bool, 2](fill=False),  # NULL on both lanes
    )
    var res = _kleene_and_chunk[2](l, r)
    # Lane 0: FALSE AND NULL = FALSE (value), VALID (result determined)
    assert_equal(Bool(res.values[0]), False)
    assert_equal(Bool(res.validity[0]), True)
    # Lane 1: TRUE AND NULL = NULL. The data field is undefined when
    # validity = False (the validity bit guards consumers). The
    # formula yields `values = l.values & r.values = True & True =
    # True`; consumers MUST NOT read this — they MUST gate on
    # validity. We only assert validity here.
    assert_equal(Bool(res.validity[1]), False)


def test_kleene_and_chunk_all_valid() raises:
    """All-valid AND collapses to bitwise AND on values, all-valid on
    validity (the comptime non-nullable fast path)."""
    var l = EvalBoolChunk[4](
        values=SIMD[DType.bool, 4](True, True, False, False),
        validity=SIMD[DType.bool, 4](fill=True),
    )
    var r = EvalBoolChunk[4](
        values=SIMD[DType.bool, 4](True, False, True, False),
        validity=SIMD[DType.bool, 4](fill=True),
    )
    var res = _kleene_and_chunk[4](l, r)
    assert_equal(Bool(res.values[0]), True)   # T AND T = T
    assert_equal(Bool(res.values[1]), False)  # T AND F = F
    assert_equal(Bool(res.values[2]), False)  # F AND T = F
    assert_equal(Bool(res.values[3]), False)  # F AND F = F
    for i in range(4):
        assert_equal(Bool(res.validity[i]), True)


def test_kleene_or_chunk_true_short_circuit() raises:
    """TRUE OR NULL = TRUE (left short-circuits). Lane 0: l.value=True,
    l.valid=True, r.value=any, r.valid=False (NULL)."""
    var l = EvalBoolChunk[2](
        values=SIMD[DType.bool, 2](True, False),
        validity=SIMD[DType.bool, 2](fill=True),
    )
    var r = EvalBoolChunk[2](
        values=SIMD[DType.bool, 2](False, False),
        validity=SIMD[DType.bool, 2](fill=False),  # NULL
    )
    var res = _kleene_or_chunk[2](l, r)
    # Lane 0: TRUE OR NULL = TRUE, VALID
    assert_equal(Bool(res.values[0]), True)
    assert_equal(Bool(res.validity[0]), True)
    # Lane 1: FALSE OR NULL = NULL
    assert_equal(Bool(res.values[1]), False)
    assert_equal(Bool(res.validity[1]), False)


def test_kleene_not_chunk_preserves_validity() raises:
    """NOT preserves validity unchanged; flips data on valid lanes.
    NOT NULL = NULL (validity stays False)."""
    var x = EvalBoolChunk[2](
        values=SIMD[DType.bool, 2](True, True),
        validity=SIMD[DType.bool, 2](True, False),  # lane 0 valid, lane 1 NULL
    )
    var res = _kleene_not_chunk[2](x)
    assert_equal(Bool(res.values[0]), False)   # NOT TRUE = FALSE (valid)
    assert_equal(Bool(res.validity[0]), True)
    # Lane 1: NOT NULL = NULL (validity unchanged)
    assert_equal(Bool(res.validity[1]), False)


# =============================================================================
# Byte helpers — bitmap-byte semantics
# =============================================================================


def test_kleene_and_byte_short_circuit_lo_lane() raises:
    """One byte = 8 lanes. Lane 0: FALSE AND NULL = FALSE (valid).
    Lane 1: TRUE AND NULL = NULL.
    """
    # Lane 0: l.value=0, l.valid=1; r.value=1, r.valid=0
    # Lane 1: l.value=1, l.valid=1; r.value=1, r.valid=0
    # Build bytes (LSB-first):
    #   ld bit 0 = 0, bit 1 = 1 → ld = 0b00000010 = 2
    #   lv bit 0 = 1, bit 1 = 1 → lv = 0b11111111 = 0xFF
    #   rd bit 0 = 1, bit 1 = 1 → rd = 0b00000011 = 3
    #   rv bit 0 = 0, bit 1 = 0 → rv = 0
    var (data, valid) = _kleene_and_byte(UInt8(0xFF), UInt8(2), UInt8(0), UInt8(3))
    # Lane 0: ld bit 0 = 0, so result value bit 0 = 0
    # Lane 1: ld bit 1 = 1, rd bit 1 = 1, but rv bit 1 = 0 → value bit
    # 1 = 1 in data (1 AND 1 = 1), validity bit 1 = ?
    # Lane 0 valid: lv & ~ld bit 0 = 1 & 1 = 1 → valid bit 0 = 1
    # Lane 1 valid: lv & ~ld bit 1 = 1 & 0 = 0; rv & ~rd bit 1 = 0;
    #               lv & rv bit 1 = 1 & 0 = 0 → valid bit 1 = 0
    assert_equal(Int(data & UInt8(1)), 0)         # lane 0: 0 AND 1 = 0
    assert_equal(Int(valid & UInt8(1)), 1)        # lane 0: VALID (short-circuit)
    assert_equal(Int(data & UInt8(2)), 2)         # lane 1: 1 AND 1 = 1
    assert_equal(Int(valid & UInt8(2)), 0)        # lane 1: NULL


def test_kleene_or_byte_short_circuit_hi_lane() raises:
    """Lane 0: TRUE OR NULL = TRUE (valid).
    Lane 1: FALSE OR NULL = NULL.
    """
    # ld bit 0 = 1, bit 1 = 0 → ld = 1
    # lv bit 0 = 1, bit 1 = 1 → lv = 0xFF
    # rd bit 0 = 0, bit 1 = 0 → rd = 0
    # rv bit 0 = 0, bit 1 = 0 → rv = 0
    var (data, valid) = _kleene_or_byte(UInt8(0xFF), UInt8(1), UInt8(0), UInt8(0))
    # Lane 0: 1 OR 0 = 1 in data; valid = (lv & ld) bit 0 = 1 → VALID
    # Lane 1: 0 OR 0 = 0 in data; valid bit 1 = (lv & ld bit 1=0) |
    #         (rv & rd bit 1=0) | (lv & rv bit 1=0) = 0 → NULL
    assert_equal(Int(data & UInt8(1)), 1)         # lane 0: TRUE
    assert_equal(Int(valid & UInt8(1)), 1)        # lane 0: VALID
    assert_equal(Int(data & UInt8(2)), 0)         # lane 1: FALSE
    assert_equal(Int(valid & UInt8(2)), 0)        # lane 1: NULL


def test_kleene_not_byte_preserves_validity() raises:
    """NOT byte: data is ~ld, validity is unchanged."""
    var ld = UInt8(0b10101010)
    var lv = UInt8(0b11110000)
    var (data, valid) = _kleene_not_byte(lv, ld)
    assert_equal(Int(data), 0x55)          # ~0xAA = 0x55
    assert_equal(Int(valid), Int(lv))      # validity preserved


def test_cmp_result_validity_byte() raises:
    """Comparison validity = lv & rv (no value dependence)."""
    var lv = UInt8(0b11110000)
    var rv = UInt8(0b10101010)
    var v = _cmp_result_validity_byte(lv, rv)
    assert_equal(Int(v), 0b10100000)


def test_cmp_result_validity_chunk() raises:
    """SIMD chunk form of `_cmp_result_validity_byte`."""
    var lv = SIMD[DType.bool, 4](True, True, False, False)
    var rv = SIMD[DType.bool, 4](True, False, True, False)
    var v = _cmp_result_validity_chunk[4](lv, rv)
    assert_equal(Bool(v[0]), True)
    assert_equal(Bool(v[1]), False)
    assert_equal(Bool(v[2]), False)
    assert_equal(Bool(v[3]), False)


# =============================================================================
# Comparison Kleene-aware variants
# =============================================================================


def _build_int64_array(*values: Int64) -> PrimitiveArray[DType.int64]:
    """Helper: build a non-nullable Int64 array from positional values."""
    var lst = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        lst.append(Scalar[DType.int64](values[i]))
    return PrimitiveArray[DType.int64].from_list(lst^)


def _build_int64_nullable(values: List[Int64], nulls: List[Int]) raises -> PrimitiveArray[DType.int64]:
    """Helper: build a nullable Int64 array; `nulls` lists indices to
    mark as null.
    """
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](values[i]))
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    arr.null_count = len(nulls)
    return arr^


def test_eval_col_gt_kleene_non_nullable_fast_path() raises:
    """Both inputs non-nullable → result has no validity bitmap
    (zero-cost fast path, matches arithmetic.mojo)."""
    var left = _build_int64_array(Int64(5), Int64(2), Int64(7), Int64(1))
    var right = _build_int64_array(Int64(3), Int64(4), Int64(6), Int64(0))
    var result = eval_col_gt_kleene[DType.int64](left, right)
    # Validity not attached when neither operand has bitmap.
    assert_false(Bool(result.validity))
    # Compare results: 5>3=T, 2>4=F, 7>6=T, 1>0=T
    assert_equal(result.get(0), True)
    assert_equal(result.get(1), False)
    assert_equal(result.get(2), True)
    assert_equal(result.get(3), True)


def test_eval_col_gt_kleene_left_nullable() raises:
    """Left input nullable, row 1 = NULL. Result lane 1 must be
    NULL regardless of comparison outcome."""
    var lvals = List[Int64]()
    lvals.append(Int64(5))
    lvals.append(Int64(99))  # value at null row — irrelevant
    lvals.append(Int64(7))
    lvals.append(Int64(1))
    var nulls = List[Int]()
    nulls.append(1)
    var left = _build_int64_nullable(lvals^, nulls^)
    var right = _build_int64_array(Int64(3), Int64(4), Int64(6), Int64(0))
    var result = eval_col_gt_kleene[DType.int64](left, right)
    # Validity bitmap attached.
    assert_true(Bool(result.validity))
    # Row 1 should be null in result validity.
    ref vbm = result.validity.value()
    assert_true(vbm.test(0))   # row 0 valid
    assert_false(vbm.test(1))  # row 1 NULL (propagated)
    assert_true(vbm.test(2))   # row 2 valid
    assert_true(vbm.test(3))   # row 3 valid


def test_eval_col_gt_kleene_both_nullable() raises:
    """Both inputs nullable, different null patterns → result null
    when EITHER operand is null."""
    var lvals = List[Int64]()
    lvals.append(Int64(5))
    lvals.append(Int64(2))
    lvals.append(Int64(7))
    lvals.append(Int64(1))
    var lnulls = List[Int]()
    lnulls.append(0)  # left row 0 null
    var left = _build_int64_nullable(lvals^, lnulls^)
    var rvals = List[Int64]()
    rvals.append(Int64(3))
    rvals.append(Int64(4))
    rvals.append(Int64(6))
    rvals.append(Int64(0))
    var rnulls = List[Int]()
    rnulls.append(2)  # right row 2 null
    var right = _build_int64_nullable(rvals^, rnulls^)
    var result = eval_col_gt_kleene[DType.int64](left, right)
    assert_true(Bool(result.validity))
    ref vbm = result.validity.value()
    assert_false(vbm.test(0))  # left null → NULL
    assert_true(vbm.test(1))   # both valid
    assert_false(vbm.test(2))  # right null → NULL
    assert_true(vbm.test(3))   # both valid


def test_eval_col_lt_kleene_validity_match() raises:
    """eval_col_lt_kleene returns the same validity shape as
    eval_col_gt_kleene (delegates through _attach_cmp_kleene_validity)."""
    var lvals = List[Int64]()
    lvals.append(Int64(1))
    lvals.append(Int64(5))
    lvals.append(Int64(3))
    var lnulls = List[Int]()
    lnulls.append(1)
    var left = _build_int64_nullable(lvals^, lnulls^)
    var right = _build_int64_array(Int64(2), Int64(3), Int64(7))
    var result = eval_col_lt_kleene[DType.int64](left, right)
    assert_true(Bool(result.validity))
    ref vbm = result.validity.value()
    assert_true(vbm.test(0))
    assert_false(vbm.test(1))
    assert_true(vbm.test(2))


def test_eval_col_eq_kleene_validity_match() raises:
    """eval_col_eq_kleene also propagates validity as left & right."""
    var lvals = List[Int64]()
    lvals.append(Int64(1))
    lvals.append(Int64(2))
    lvals.append(Int64(3))
    var lnulls = List[Int]()
    var left = _build_int64_nullable(lvals^, lnulls^)
    var rvals = List[Int64]()
    rvals.append(Int64(1))
    rvals.append(Int64(2))
    rvals.append(Int64(3))
    var rnulls = List[Int]()
    rnulls.append(2)
    var right = _build_int64_nullable(rvals^, rnulls^)
    var result = eval_col_eq_kleene[DType.int64](left, right)
    assert_true(Bool(result.validity))
    ref vbm = result.validity.value()
    assert_true(vbm.test(0))
    assert_true(vbm.test(1))
    assert_false(vbm.test(2))  # right row 2 null → NULL


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
