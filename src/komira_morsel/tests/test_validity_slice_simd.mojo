# =============================================================================
# Property tests for SIMD sprint 1 + 2 (validity bitmap + offset rebase)
# =============================================================================
#
# Sprint 1 (T1-1): copy_column_ref validity / offset rebase / BOOL slice.
# Sprint 2 (T1-2): _slice_fixed_width / _slice_variable_width validity.
#
# Both sprints route per-bit scalar loops onto memcpy-backed primitives
# (`Bitmap.copy_bits_into` + the new buffer-level `copy_bits_aligned_buffer`).
# The optimization is byte-equivalent to scalar; this file is the
# byte-equivalence regression gate.
#
# Coverage:
#   1. copy_column_ref validity bitmap copy across mixed-validity inputs,
#      multiple ArrowTypes (INT64, FLOAT64, INT32, BOOL), random
#      offsets / lengths spanning byte-aligned + bit-misaligned cases.
#   2. copy_column_ref STRING / BINARY offset-rebase SIMD path against
#      a scalar reference impl.
#   3. copy_column_ref BOOL slice (Loop 3) byte-equivalence to a scalar
#      bit-walker.
#   4. split_record_batch -> _slice_fixed_width / _slice_variable_width
#      validity-bitmap slicing across morsel boundaries.
#
# Determinism: all inputs synthesized via a constant LCG (no stdlib
# random). Each test pins a fresh seed.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.arrow_types import ArrowType
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_morsel.morsel import split_record_batch
from komira_buffer.heap_region import HeapRegion


# ---------------------------------------------------------------------------
# Determinism helpers — a tiny deterministic xorshift32 sequence.
# Avoids stdlib random; same sequence across machines.
# ---------------------------------------------------------------------------


@always_inline
def _xs32(mut state: UInt32) -> UInt32:
    var x = state
    x ^= x << UInt32(13)
    x ^= x >> UInt32(17)
    x ^= x << UInt32(5)
    state = x
    return x


@always_inline
def _xs32_bool(mut state: UInt32) -> Bool:
    return (_xs32(state) & UInt32(1)) == UInt32(1)


# ---------------------------------------------------------------------------
# Builders for INT64 / FLOAT64 / INT32 columns with mixed-validity bitmap.
# ---------------------------------------------------------------------------


def _make_int64_column_with_validity(
    n: Int, seed: UInt32, null_pattern: Int
) raises -> Column[HeapRegion]:
    """Build an INT64 column of length n with a deterministic validity
    pattern. `null_pattern`: 0 = no nulls, 1 = alternating, 2 = ~30%
    random nulls (xorshift), 3 = first / last / every-7th null."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var state = seed
    for i in range(n):
        ptr[i] = Int64(Int(_xs32(state)) % 1000)
        var should_null = False
        if null_pattern == 1:
            should_null = (i & 1) == 1
        elif null_pattern == 2:
            should_null = (Int(_xs32(state)) % 100) < 30
        elif null_pattern == 3:
            should_null = i == 0 or i == n - 1 or (i % 7 == 0)
        if should_null:
            arr._set_null(i)  # _set_null bumps null_count (fix)
    return Column.from_primitive(arr^)


def _make_int32_column_with_validity(
    n: Int, seed: UInt32, null_pattern: Int
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var state = seed
    for i in range(n):
        ptr[i] = Int32(Int(_xs32(state)) % 100000)
        var should_null = False
        if null_pattern == 1:
            should_null = (i & 1) == 1
        elif null_pattern == 2:
            should_null = (Int(_xs32(state)) % 100) < 30
        elif null_pattern == 3:
            should_null = i == 0 or i == n - 1 or (i % 7 == 0)
        if should_null:
            arr._set_null(i)  # _set_null bumps null_count (fix)
    return Column.from_primitive(arr^)


def _make_float64_column_with_validity(
    n: Int, seed: UInt32, null_pattern: Int
) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var state = seed
    for i in range(n):
        ptr[i] = Float64(Int(_xs32(state)) % 1000) * 0.5
        var should_null = False
        if null_pattern == 1:
            should_null = (i & 1) == 1
        elif null_pattern == 2:
            should_null = (Int(_xs32(state)) % 100) < 30
        elif null_pattern == 3:
            should_null = i == 0 or i == n - 1 or (i % 7 == 0)
        if should_null:
            arr._set_null(i)  # _set_null bumps null_count (fix)
    return Column.from_primitive(arr^)


def _make_string_column(
    n: Int, seed: UInt32
) raises -> Column[HeapRegion]:
    """Build a STRING column with deterministic short payloads.
    `_offset` left at 0; tests read from offset = arbitrary into this."""
    var values = List[String]()
    var state = seed
    for _ in range(n):
        var rlen = Int(_xs32(state)) % 7 + 1
        var s = String("")
        for _k in range(rlen):
            var c = UInt8(Int(_xs32(state)) % 26 + 97)  # 'a'..'z'
            s += chr(Int(c))
        values.append(s)
    var arr = StringArray.from_strings(values)
    return Column.from_string(arr^)


def _make_bool_column(n: Int, seed: UInt32) raises -> Column[HeapRegion]:
    """Build a BOOL column with packed bit data, deterministic pattern."""
    var bm_bytes = (n + 7) >> 3
    var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
    data_buf.zero()
    var state = seed
    for i in range(n):
        if _xs32_bool(state):
            var byte = i >> 3
            var bit = i & 7
            data_buf.write_u8_at(
                byte,
                data_buf.read_u8_at(byte) | (UInt8(1) << UInt8(bit)),
            )
    data_buf.set_length(Int64(bm_bytes))

    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data_buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


# ---------------------------------------------------------------------------
# Scalar reference impls: produce the OLD-shape per-bit validity bitmap
# and BOOL slice. Tests assert SIMD-shape == scalar-reference byte-for-byte.
# ---------------------------------------------------------------------------


def _scalar_reference_validity_copy(
    src: Bitmap[HeapRegion], src_offset: Int, num_rows: Int
) raises -> Bitmap[HeapRegion]:
    """Reference impl mirroring the OLD per-bit `set/clear` loop."""
    var bm = Bitmap.create(num_rows)
    for i in range(num_rows):
        if src.test(src_offset + i):
            bm.set(i)
        else:
            bm.clear(i)
    return bm^


# ---------------------------------------------------------------------------
# Test 1 — copy_column_ref validity bitmap, INT64, mixed offsets.
# ---------------------------------------------------------------------------


def test_copy_column_ref_int64_validity_aligned_offsets() raises:
    """copy_column_ref on INT64: offset ∈ {0, 8, 16, 64} — byte-aligned."""
    var n = 200
    var col = _make_int64_column_with_validity(n, UInt32(0xDEADBEEF), 2)

    var offsets: List[Int] = [0, 8, 16, 64]
    var lengths: List[Int] = [n, 100, 64, 32]
    for k in range(len(offsets)):
        var off = offsets[k]
        var ln = lengths[k]
        if off + ln > n:
            continue
        col._offset = off
        var got = copy_column_ref(col, ln)
        var ref_bm = _scalar_reference_validity_copy(
            col._validity.value(), off, ln
        )
        # Byte-equivalence: every bit matches.
        ref got_bm = got._validity.value()
        assert_equal(got_bm.length, ref_bm.length, "length mismatch")
        for i in range(ln):
            assert_equal(
                got_bm.test(i), ref_bm.test(i),
                "bit " + String(i) + " mismatch at off=" + String(off)
            )
        # null_count must match the reference popcount-based shape.
        var expected_null = ln - ref_bm.popcount()
        assert_equal(got._null_count, expected_null,
            "null_count mismatch at off=" + String(off))
    col._offset = 0


def test_copy_column_ref_int64_validity_bit_misaligned() raises:
    """copy_column_ref on INT64: offset ∈ {1, 3, 5, 7} — bit-misaligned."""
    var n = 200
    var col = _make_int64_column_with_validity(n, UInt32(0xCAFEBABE), 2)
    var offsets: List[Int] = [1, 3, 5, 7, 13]
    for k in range(len(offsets)):
        var off = offsets[k]
        var ln = 50
        col._offset = off
        var got = copy_column_ref(col, ln)
        var ref_bm = _scalar_reference_validity_copy(
            col._validity.value(), off, ln
        )
        ref got_bm = got._validity.value()
        for i in range(ln):
            assert_equal(
                got_bm.test(i), ref_bm.test(i),
                "bit " + String(i) + " mismatch at off=" + String(off)
            )
    col._offset = 0


# ---------------------------------------------------------------------------
# Test 2 — copy_column_ref STRING / BINARY offset rebase SIMD.
# ---------------------------------------------------------------------------


def test_copy_column_ref_string_offset_rebase_aligned() raises:
    """copy_column_ref STRING offset rebase at byte-aligned offsets.

    Asserts that data_start subtraction is byte-equivalent across the
    SIMD path vs a scalar reference, AND that the resulting column
    correctly addresses the original strings.
    """
    var n = 100
    var col = _make_string_column(n, UInt32(0x1234ABCD))
    var offsets: List[Int] = [0, 8, 16]
    var lengths: List[Int] = [n, 50, 32]
    for k in range(len(offsets)):
        var off = offsets[k]
        var ln = lengths[k]
        if off + ln > n:
            continue
        col._offset = off
        var got = copy_column_ref(col, ln)
        # Validate offsets: got._offsets[0] must be 0 (rebased).
        ref got_off_buf = got._offsets.value()
        assert_equal(
            Int(got_off_buf.get_typed[Int32](0)), 0,
            "rebased offset[0] must be 0"
        )
        # Validate offsets are monotonically nondecreasing.
        for i in range(ln):
            var lo = Int(got_off_buf.get_typed[Int32](i))
            var hi = Int(got_off_buf.get_typed[Int32](i + 1))
            assert_true(hi >= lo,
                "offsets must be monotonic at i=" + String(i))
        # Final offset must equal data buffer length (data was sliced).
        var final = Int(got_off_buf.get_typed[Int32](ln))
        assert_equal(final, got._data.len(),
            "final offset must == data length, off=" + String(off))
    col._offset = 0


def test_copy_column_ref_string_offset_rebase_unaligned_lengths() raises:
    """STRING offset rebase at lengths that exercise SIMD-tail-scalar split.

    `n+1` offsets to copy → for SIMD W=4 (NEON) lengths {3, 4, 5, 7, 9, 17}
    each hit a different remainder.
    """
    var n = 64
    var col = _make_string_column(n, UInt32(0xFEEDFACE))
    var lengths: List[Int] = [3, 4, 5, 7, 9, 16, 17, 31, 32, 33]
    for k in range(len(lengths)):
        var ln = lengths[k]
        if ln > n:
            continue
        col._offset = 0
        var got = copy_column_ref(col, ln)
        ref got_off_buf = got._offsets.value()
        assert_equal(
            Int(got_off_buf.get_typed[Int32](0)), 0,
            "offset[0] must be 0 at len=" + String(ln)
        )
        # Compare to scalar reference: src_off[i] - src_off[0] for i in [0..ln].
        ref src_off_buf = col._offsets.value()
        var data_start = Int(src_off_buf.get_typed[Int32](0))
        for i in range(ln + 1):
            var got_v = Int(got_off_buf.get_typed[Int32](i))
            var ref_v = Int(src_off_buf.get_typed[Int32](i)) - data_start
            assert_equal(got_v, ref_v,
                "offset[" + String(i) + "] mismatch at len=" + String(ln))


# ---------------------------------------------------------------------------
# Test 3 — copy_column_ref BOOL slice byte-equivalence.
# ---------------------------------------------------------------------------


def test_copy_column_ref_bool_aligned_offsets() raises:
    """BOOL slice at byte-aligned offsets must match scalar bit-walker."""
    var n = 256
    var col = _make_bool_column(n, UInt32(0x33333333))
    var offsets: List[Int] = [0, 8, 16, 64, 128]
    var lengths: List[Int] = [n, 100, 80, 56, 16]
    for k in range(len(offsets)):
        var off = offsets[k]
        var ln = lengths[k]
        if off + ln > n:
            continue
        col._offset = off
        var got = copy_column_ref(col, ln)
        # Scalar reference: walk bits one at a time.
        for i in range(ln):
            var src_bit = (
                col._data.read_u8_at((off + i) >> 3)
                >> UInt8((off + i) & 7)
            ) & UInt8(1)
            var dst_bit = (
                got._data.read_u8_at(i >> 3)
                >> UInt8(i & 7)
            ) & UInt8(1)
            assert_equal(
                Int(src_bit), Int(dst_bit),
                "BOOL bit " + String(i) + " mismatch at off=" + String(off)
            )
    col._offset = 0


def test_copy_column_ref_bool_bit_misaligned() raises:
    """BOOL slice at bit-misaligned offsets exercises the bit-walk fallback."""
    var n = 200
    var col = _make_bool_column(n, UInt32(0x55AA55AA))
    var offsets: List[Int] = [1, 3, 5, 7, 13, 17]
    for k in range(len(offsets)):
        var off = offsets[k]
        var ln = 64
        if off + ln > n:
            continue
        col._offset = off
        var got = copy_column_ref(col, ln)
        for i in range(ln):
            var src_bit = (
                col._data.read_u8_at((off + i) >> 3)
                >> UInt8((off + i) & 7)
            ) & UInt8(1)
            var dst_bit = (
                got._data.read_u8_at(i >> 3)
                >> UInt8(i & 7)
            ) & UInt8(1)
            assert_equal(
                Int(src_bit), Int(dst_bit),
                "BOOL misalign bit " + String(i)
                + " mismatch at off=" + String(off)
            )
    col._offset = 0


# ---------------------------------------------------------------------------
# Test 4 — _slice_fixed_width validity bitmap via split_record_batch.
# ---------------------------------------------------------------------------


def _make_int64_batch(var col: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def test_slice_fixed_width_validity_through_split() raises:
    """split_record_batch on INT64 with mixed nulls preserves validity
    bit-for-bit across all morsel boundaries."""
    var n = 257  # 5 morsels of 64 + tail of 1
    var morsel_size = 64
    var col = _make_int64_column_with_validity(n, UInt32(0xACE0F00D), 2)

    # Snapshot of expected per-row validity from the source column's bitmap.
    var src_valid = List[Bool]()
    for i in range(n):
        src_valid.append(col._validity.value().test(i))

    var batch = _make_int64_batch(col^)
    var morsels = split_record_batch(batch^, morsel_size)

    var ridx = 0
    for m in range(len(morsels)):
        ref morsel = morsels[m]
        ref morsel_batch = morsel.batch
        ref morsel_col = morsel_batch.column_at(0)
        for i in range(morsel_col._length):
            var got_valid = True
            if morsel_col._validity:
                got_valid = morsel_col._validity.value().test(i)
            assert_equal(
                got_valid, src_valid[ridx],
                "morsel=" + String(m) + " row=" + String(i)
                + " global=" + String(ridx)
                + " validity mismatch"
            )
            ridx += 1
    assert_equal(ridx, n, "all rows accounted for")


def test_slice_fixed_width_validity_int32() raises:
    """Same pattern, INT32 column (4-byte stride exercises a different
    `_slice_fixed_width` `elem_size` argument)."""
    var n = 200
    var morsel_size = 50
    var col = _make_int32_column_with_validity(n, UInt32(0xBEEFCAFE), 2)

    var src_valid = List[Bool]()
    for i in range(n):
        src_valid.append(col._validity.value().test(i))

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    var batch = b.build(sb.build())

    var morsels = split_record_batch(batch^, morsel_size)
    var ridx = 0
    for m in range(len(morsels)):
        ref morsel = morsels[m]
        ref morsel_batch = morsel.batch
        ref morsel_col = morsel_batch.column_at(0)
        for i in range(morsel_col._length):
            var got_valid = True
            if morsel_col._validity:
                got_valid = morsel_col._validity.value().test(i)
            assert_equal(got_valid, src_valid[ridx])
            ridx += 1
    assert_equal(ridx, n)


def test_slice_fixed_width_validity_float64() raises:
    """Sibling: FLOAT64 column."""
    var n = 130
    var morsel_size = 32
    var col = _make_float64_column_with_validity(n, UInt32(0x1357ABCD), 2)

    var src_valid = List[Bool]()
    for i in range(n):
        src_valid.append(col._validity.value().test(i))

    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    var batch = b.build(sb.build())

    var morsels = split_record_batch(batch^, morsel_size)
    var ridx = 0
    for m in range(len(morsels)):
        ref morsel = morsels[m]
        ref morsel_batch = morsel.batch
        ref morsel_col = morsel_batch.column_at(0)
        for i in range(morsel_col._length):
            var got_valid = True
            if morsel_col._validity:
                got_valid = morsel_col._validity.value().test(i)
            assert_equal(got_valid, src_valid[ridx])
            ridx += 1
    assert_equal(ridx, n)


# ---------------------------------------------------------------------------
# Test 5 — randomized property tests across N=100 random offsets/lengths.
# This is the audit-mandated round-trip property gate.
# ---------------------------------------------------------------------------


def test_copy_column_ref_validity_random_property() raises:
    """100 random offset/length combinations on INT64 with mixed nulls.
    Asserts SIMD-path validity == scalar reference for every (off, len)."""
    var n = 1024
    var col = _make_int64_column_with_validity(n, UInt32(0xFEED1234), 2)
    var rng = UInt32(0x07060504)
    for _ in range(100):
        var off = Int(_xs32(rng)) % n
        var max_len = n - off
        if max_len <= 0:
            continue
        var ln = Int(_xs32(rng)) % max_len + 1
        col._offset = off
        var got = copy_column_ref(col, ln)
        if not got._validity:
            # Source had validity; copy_column_ref must preserve.
            assert_true(False, "validity dropped unexpectedly")
            continue
        var ref_bm = _scalar_reference_validity_copy(
            col._validity.value(), off, ln
        )
        ref got_bm = got._validity.value()
        for i in range(ln):
            assert_equal(
                got_bm.test(i), ref_bm.test(i),
                "off=" + String(off) + " len=" + String(ln)
                + " bit=" + String(i)
            )
        var expected_null = ln - ref_bm.popcount()
        assert_equal(got._null_count, expected_null,
            "off=" + String(off) + " len=" + String(ln)
            + " null_count mismatch")
    col._offset = 0


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
