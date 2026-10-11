# =============================================================================
# builtin_hash_fns: the validity of a SLICED input to the nullable hash cells.
#
# A sliced `PrimitiveArray` keeps its validity bitmap indexed ABSOLUTELY:
# logical row i is bit `offset + i`, while `load(i)` already adds the offset.
# A validity read without the offset pairs row i's value with the null bit of
# parent row i, so the wrong rows get NULL_HASH and the returned non-null
# count is wrong (komira issue 1271).
#
# Expected values: a null row is NULL_HASH; a valid row is what the
# NON-nullable cell (HashI64 / HashF64, the INPUT_VALID=False loop, which
# reads no bitmap) returns for the same value in a fresh, unsliced array. The
# null rows are chosen by hand from the absolute parent rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_kernels.builtin_hash_fns import HashI64, HashI64_V, HashF64, HashF64_V
from komira_kernels.hash_fn import NULL_HASH


comptime N = 20


def _has(xs: List[Int], x: Int) -> Bool:
    for k in range(len(xs)):
        if xs[k] == x:
            return True
    return False


def _i64_window(
    null_abs: List[Int], offset: Int, n: Int
) raises -> PrimitiveArray[DType.int64]:
    """A length-n window at `offset` of a parent whose row r holds 100 + r and
    whose null rows are `null_abs` (ABSOLUTE parent rows)."""
    var parent = PrimitiveArray[DType.int64].allocate_nullable(offset + n)
    for r in range(offset + n):
        parent.set(r, Int64(100 + r))
    for j in range(len(null_abs)):
        parent._set_null(null_abs[j])
    parent.null_count = len(null_abs)
    return parent.slice(offset, n)


def _f64_window(
    null_abs: List[Int], offset: Int, n: Int
) raises -> PrimitiveArray[DType.float64]:
    var parent = PrimitiveArray[DType.float64].allocate_nullable(offset + n)
    for r in range(offset + n):
        parent.set(r, Float64(r) + 0.5)
    for j in range(len(null_abs)):
        parent._set_null(null_abs[j])
    parent.null_count = len(null_abs)
    return parent.slice(offset, n)


def _check_i64(null_abs: List[Int], offset: Int, n: Int, want_null: List[Int]) raises:
    var what = "HashI64_V offset " + String(offset) + " "
    var w = _i64_window(null_abs, offset, n)
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var c = HashI64_V().hash_chunk(w, out, n)
    var plain = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        plain.set(i, Int64(100 + offset + i))
    var ref_out = PrimitiveArray[DType.uint64].allocate(n)
    _ = HashI64().hash_chunk(plain, ref_out, n)
    for i in range(n):
        if _has(want_null, i):
            assert_equal(out.get(i), NULL_HASH, what + "null row " + String(i))
        else:
            assert_true(ref_out.get(i) != NULL_HASH, what + "reference row " + String(i))
            assert_equal(out.get(i), ref_out.get(i), what + "valid row " + String(i))
    assert_equal(c, n - len(want_null), what + "non-null count")


def _check_f64(null_abs: List[Int], offset: Int, n: Int, want_null: List[Int]) raises:
    var what = "HashF64_V offset " + String(offset) + " "
    var w = _f64_window(null_abs, offset, n)
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var c = HashF64_V().hash_chunk(w, out, n)
    var plain = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        plain.set(i, Float64(offset + i) + 0.5)
    var ref_out = PrimitiveArray[DType.uint64].allocate(n)
    _ = HashF64().hash_chunk(plain, ref_out, n)
    for i in range(n):
        if _has(want_null, i):
            assert_equal(out.get(i), NULL_HASH, what + "null row " + String(i))
        else:
            assert_true(ref_out.get(i) != NULL_HASH, what + "reference row " + String(i))
            assert_equal(out.get(i), ref_out.get(i), what + "valid row " + String(i))
    assert_equal(c, n - len(want_null), what + "non-null count")


def test_i64_v_issue_shape_null_before_the_window() raises:
    """The issue's shape: the parent's only null is row 0; slice(1, 19) has
    no null row and 19 non-null cells. An offset-blind read nulls row 0."""
    _check_i64([0], 1, 19, List[Int]())


def test_f64_v_issue_shape_null_before_the_window() raises:
    _check_f64([0], 1, 19, List[Int]())


def test_i64_v_unaligned_and_byte_aligned_offsets() raises:
    """Offset 3: nulls at absolute 0, 4, 13, 22 are logical 1, 10, 19 (row 0
    sits before the window). Offset 8: nulls at absolute 0, 5, 9, 22, 27 are
    logical 1, 14, 19."""
    _check_i64([0, 4, 13, 22], 3, N, [1, 10, 19])
    _check_i64([0, 5, 9, 22, 27], 8, N, [1, 14, 19])


def test_f64_v_unaligned_and_byte_aligned_offsets() raises:
    _check_f64([0, 4, 13, 22], 3, N, [1, 10, 19])
    _check_f64([0, 5, 9, 22, 27], 8, N, [1, 14, 19])


def test_offset_zero_still_reads_bit_i() raises:
    """An unsliced nullable array: logical row i is bit i."""
    _check_i64([2, 7, 18], 0, N, [2, 7, 18])
    _check_f64([2, 7, 18], 0, N, [2, 7, 18])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
