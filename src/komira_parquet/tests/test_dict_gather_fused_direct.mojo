# Direct tests of `dict_gather_fused.mojo`: the per-block bounds check
# `_block_in_bounds`, the two gather arms behind `resolve_gather_fused` (flat
# for a dictionary that fits in L2, prefetched for one that does not), and
# the clamping gather `gather_flat_clamped`. Every expected value is the
# definition of a dictionary gather: output[i] = dictionary[code[i]], with
# `gather_flat_clamped` mapping a code outside [0, len(dictionary)) to
# dictionary[0] (or 0 for an empty dictionary) and filling rows past
# `rows_val` with the same value.
from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet.dict_gather_fused import (
    _block_in_bounds,
    gather_flat_clamped,
    resolve_gather_fused,
)


def _codes(values: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    return arr^


def _dict_i64(n: Int) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Int64(i) * 1000003 - 7)
    return arr^


def _in_bounds(
    codes: PrimitiveArray[DType.int32], start: Int, end: Int, dict_len: Int
) -> Bool:
    var view = codes.view_ro()
    var ptr = view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var ok = _block_in_bounds(ptr, start, end, dict_len)
    _ = view^
    return ok


def _ramp(n: Int, modulo: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append((i * 7 + 3) % modulo)
    return out^


# --- _block_in_bounds --------------------------------------------------------


def test_block_in_bounds_every_shape() raises:
    """In range at every length around the SIMD width, and out of range when
    one code at the first, middle or last position is -1 or `dict_len`. The
    out-of-range code at the last position lands in the scalar tail when the
    length is not a multiple of W, so both the SIMD and the tail min/max are
    checked."""
    comptime W = simd_width_of[DType.int32]()
    var lengths: List[Int] = [1, 2, W - 1, W, W + 1, 2 * W, 2 * W + 3, 5 * W + 1]
    for li in range(len(lengths)):
        var n = lengths[li]
        var vals = _ramp(n, 10)
        assert_true(_in_bounds(_codes(vals), 0, n, 10), "in range n=" + String(n))
        var positions: List[Int] = [0, n // 2, n - 1]
        for pi in range(len(positions)):
            var p = positions[pi]
            var low = vals.copy()
            low[p] = -1
            assert_false(
                _in_bounds(_codes(low), 0, n, 10),
                "-1 at " + String(p) + " of " + String(n),
            )
            var high = vals.copy()
            high[p] = 10
            assert_false(
                _in_bounds(_codes(high), 0, n, 10),
                "dict_len at " + String(p) + " of " + String(n),
            )


def test_block_in_bounds_tail_min_and_max_and_a_window() raises:
    """The tail sees values both below and above the SIMD lanes' min/max, and
    a window [start, end) ignores codes outside it."""
    comptime W = simd_width_of[DType.int32]()
    var vals = List[Int]()
    for _ in range(W):
        vals.append(5)
    vals.append(1)  # tail: below the SIMD min
    vals.append(8)  # tail: above the SIMD max
    vals.append(5)
    assert_true(_in_bounds(_codes(vals), 0, len(vals), 9))
    assert_false(_in_bounds(_codes(vals), 0, len(vals), 8))
    # The scalar-only path (n < W): the tail starts from the first value.
    var short: List[Int] = [4, 2, 6]
    assert_true(_in_bounds(_codes(short), 0, 3, 7))
    assert_false(_in_bounds(_codes(short), 0, 3, 6))
    # A window: the bad codes at both ends are outside [1, 3).
    var windowed: List[Int] = [-9, 1, 2, 99]
    assert_true(_in_bounds(_codes(windowed), 1, 3, 3))
    assert_false(_in_bounds(_codes(windowed), 0, 3, 3))
    assert_false(_in_bounds(_codes(windowed), 1, 4, 3))


def test_block_in_bounds_empty_window_is_in_bounds() raises:
    var vals: List[Int] = [-1, -1]
    assert_true(_in_bounds(_codes(vals), 1, 1, 0))
    assert_true(_in_bounds(_codes(vals), 2, 1, 0))


# --- resolve_gather_fused ----------------------------------------------------


def _check_gather[
    T: DType
](codes: List[Int], dict_vals: PrimitiveArray[T]) raises:
    var got = resolve_gather_fused[T](_codes(codes), dict_vals)
    assert_true(Bool(got), "in-range codes must gather")
    var arr = got.take()
    assert_equal(arr.length, len(codes))
    for i in range(len(codes)):
        assert_equal(arr.get(i), dict_vals.get(codes[i]), "row " + String(i))


def test_flat_arm_every_dtype_and_block_boundary() raises:
    """A small dictionary takes the flat arm. Counts cover the 4x unroll and
    its tail, one block, a block and one, and several blocks."""
    var counts: List[Int] = [1, 3, 4, 5, 39, 2048, 2049, 4100]
    var d32 = PrimitiveArray[DType.int32].allocate(13)
    var d64 = PrimitiveArray[DType.int64].allocate(13)
    var f32 = PrimitiveArray[DType.float32].allocate(13)
    var f64 = PrimitiveArray[DType.float64].allocate(13)
    for i in range(13):
        d32.set(i, Int32(-i * 11 + 3))
        d64.set(i, Int64(i) * 123456789012)
        f32.set(i, Float32(i) * 0.5 - 2.25)
        f64.set(i, Float64(i) * -1.125 + 9.5)
    for ci in range(len(counts)):
        var codes = _ramp(counts[ci], 13)
        _check_gather[DType.int32](codes, d32)
        _check_gather[DType.int64](codes, d64)
        _check_gather[DType.float32](codes, f32)
        _check_gather[DType.float64](codes, f64)


def test_prefetch_arm_for_a_dictionary_past_256_kib() raises:
    """32,769 Int64 entries are 262,152 bytes, past the 256 KiB threshold, so
    the prefetched arm runs; codes reach both ends of the dictionary and the
    prefetch distance runs past the last code."""
    var d = _dict_i64(32769)
    var codes = List[Int]()
    for i in range(4103):
        codes.append((i * 7919) % 32769)
    codes[0] = 32768
    codes[1] = 0
    _check_gather[DType.int64](codes, d)
    var short: List[Int] = [32768, 5, 1]
    _check_gather[DType.int64](short, d)


def test_empty_codes_empty_dictionary_and_out_of_range() raises:
    var d = _dict_i64(4)
    var none = resolve_gather_fused[DType.int64](_codes(List[Int]()), d)
    assert_true(Bool(none))
    assert_equal(none.take().length, 0)
    # Codes to resolve and no dictionary: None, the caller raises.
    var empty = PrimitiveArray[DType.int64].allocate(0)
    var one: List[Int] = [0]
    assert_false(Bool(resolve_gather_fused[DType.int64](_codes(one), empty)))
    # A bad code in the first block, and one in the third.
    var bad_first = _ramp(10, 4)
    bad_first[3] = 4
    assert_false(Bool(resolve_gather_fused[DType.int64](_codes(bad_first), d)))
    var bad_late = _ramp(5000, 4)
    bad_late[4999] = -2
    assert_false(Bool(resolve_gather_fused[DType.int64](_codes(bad_late), d)))
    # The prefetched arm refuses the same way.
    var big = _dict_i64(32769)
    var bad_big = _ramp(3000, 32769)
    bad_big[2500] = 32769
    assert_false(Bool(resolve_gather_fused[DType.int64](_codes(bad_big), big)))


# --- gather_flat_clamped -----------------------------------------------------


def _code_buf(values: List[Int], length_bytes: Int) -> OwnedAlignedBuffer:
    var buf = OwnedAlignedBuffer(max(len(values) * 4, 4))
    for i in range(len(values)):
        buf.set_typed[Int32](i, Int32(values[i]))
    buf.set_length(Int64(length_bytes))
    return buf^


def _expect_clamped(
    codes: List[Int], n_rows: Int, rows_val: Int, d: List[Int64]
) -> List[Int64]:
    var fill = d[0] if len(d) > 0 else Int64(0)
    var out = List[Int64]()
    var nv = min(n_rows, rows_val)
    for r in range(n_rows):
        if r >= nv:
            out.append(fill)
            continue
        var c = codes[r]
        if c < 0 or c >= len(d):
            c = 0
        out.append(d[c] if len(d) > 0 else Int64(0))
    return out^


def _check_clamped(
    codes: List[Int], n_rows: Int, rows_val: Int, d: List[Int64]
) raises:
    var buf = _code_buf(codes, len(codes) * 4)
    var got = gather_flat_clamped[DType.int64](buf, n_rows, rows_val, d)
    var want = _expect_clamped(codes, n_rows, rows_val, d)
    assert_equal(got.length, n_rows)
    for r in range(n_rows):
        assert_equal(got.get(r), want[r], "row " + String(r))


def test_clamped_fast_path_and_unroll_tail() raises:
    var d: List[Int64] = [Int64(-1), Int64(10), Int64(20), Int64(30), Int64(40)]
    var counts: List[Int] = [1, 3, 4, 7, 2048, 2051]
    for ci in range(len(counts)):
        var codes = _ramp(counts[ci], 5)
        _check_clamped(codes, counts[ci], counts[ci], d)


def test_clamped_slow_path_maps_bad_codes_to_entry_zero() raises:
    """A block holding a negative code, a code equal to the dictionary size
    and a huge code takes the per-value loop; every bad code reads entry 0
    and the good codes in that block still resolve. The next block is clean
    and takes the fast path."""
    var d: List[Int64] = [Int64(7), Int64(8), Int64(9)]
    var codes = _ramp(2048 + 10, 3)
    codes[0] = -5
    codes[1] = 3
    codes[2] = 2147483647
    _check_clamped(codes, len(codes), len(codes), d)


def test_clamped_fill_past_rows_val_and_rows_val_past_n_rows() raises:
    var d: List[Int64] = [Int64(5), Int64(6)]
    var codes: List[Int] = [1, 1, 0, 1, 1, 1]
    _check_clamped(codes, 6, 2, d)  # rows 2..5 are dict[0]
    _check_clamped(codes, 3, 6, d)  # only n_rows codes are read
    _check_clamped(codes, 4, 0, d)  # nothing read, all fill


def test_clamped_empty_dictionary_reads_zero() raises:
    var d = List[Int64]()
    var codes: List[Int] = [0, 1, -1, 2, 0]
    _check_clamped(codes, 7, 5, d)


def test_clamped_refusals() raises:
    var d: List[Int64] = [Int64(1)]
    var codes: List[Int] = [0, 0, 0]
    var refusals: List[Int] = [-1, 0, 0, -1]
    for k in range(2):
        var raised = False
        try:
            var buf = _code_buf(codes, 12)
            _ = gather_flat_clamped[DType.int64](
                buf, refusals[2 * k], refusals[2 * k + 1], d
            )
        except e:
            raised = True
            assert_true("negative row count" in String(e), String(e))
        assert_true(raised, "a negative row count must be refused")
    # Three codes to read, eleven bytes of buffer: refused before any read.
    var raised = False
    try:
        var short = _code_buf(codes, 11)
        _ = gather_flat_clamped[DType.int64](short, 3, 3, d)
    except e:
        raised = True
        assert_true("holds 11 bytes" in String(e), String(e))
    assert_true(raised, "a code buffer shorter than the codes must be refused")
    # Exactly enough bytes is accepted; rows past rows_val read nothing.
    var exact = _code_buf(codes, 12)
    var got = gather_flat_clamped[DType.int64](exact, 5, 3, d)
    assert_equal(got.length, 5)
    var none = _code_buf(List[Int](), 0)
    var zero_rows = gather_flat_clamped[DType.int64](none, 0, 0, d)
    assert_equal(zero_rows.length, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
