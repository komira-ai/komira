# =============================================================================
# test_avro_accumulator_growth.mojo -- the serial reader's typed accumulators
# keep values and nulls across a reserve that reallocates.
# =============================================================================
#
# The reader decodes block by block. Before each block it reserves room for
# the block's records, and a numeric accumulator allocates its validity bitmap
# lazily, at the first null. A reserve that reallocates after that first null
# must carry the bitmap over; a reserve that dropped it once lost every null
# marker written before the realloc (found when the block-parallel decode
# first disagreed with the serial one).
#
# The oracle is absolute: each test states the value or null it wrote at every
# row. test_avro_block_parallel_decode compares the parallel reader against
# the serial one, so a defect shared by both (they use the same accumulators)
# cancels out there; it does not cancel here.
#
#   nullable_reserve_preserves_validity  two blocks; the first holds a null,
#       the second's reserve reallocates; every row's value and null is read
#       back.
#   nullable_multi_block_growth  20 blocks of 10 rows, every 7th row null:
#       several reallocations, each after nulls already written.
#   float64_values / int32_values  the double and int arms over thousands of
#       rows in one block, negative ints included.
#
# Mutant planted (red at "row 1 null, written before the realloc"): in
# `_I64Acc.reserve`, build the new all-valid bitmap without clearing the bits
# of the nulls already written (the defect described above).
#
# Public API only; no private symbols are imported.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_avro import read_avro_bytes


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_double(d: Float64, mut out: List[UInt8]):
    var bits = bitcast[DType.uint64, 1](d)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))


def _header(schema_json: String) -> List[UInt8]:
    var out: List[UInt8] = [0x4F, 0x62, 0x6A, 0x01]  # "Obj" 1
    _enc_long(Int64(2), out)
    _enc_str("avro.schema", out)
    _enc_str(schema_json, out)
    _enc_str("avro.codec", out)
    _enc_str("null", out)
    _enc_long(Int64(0), out)
    for i in range(16):
        out.append(UInt8(0xC1 + i))
    return out^


def _block(mut out: List[UInt8], count: Int, payload: List[UInt8]):
    _enc_long(Int64(count), out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    for i in range(16):
        out.append(UInt8(0xC1 + i))


comptime _NULLABLE_LONG = (
    '{"type":"record","name":"R","fields":[{"name":"v","type":["null","long"]}]}'
)


def test_nullable_reserve_preserves_validity() raises:
    var bytes = _header(_NULLABLE_LONG)
    # Block A: 100, null, 200. The null allocates the bitmap.
    var pa = List[UInt8]()
    _enc_long(1, pa)
    _enc_long(100, pa)
    _enc_long(0, pa)
    _enc_long(1, pa)
    _enc_long(200, pa)
    _block(bytes, 3, pa)
    # Block B: null, 400, 500. Its reserve reallocates past block A's rows.
    var pb = List[UInt8]()
    _enc_long(0, pb)
    _enc_long(1, pb)
    _enc_long(400, pb)
    _enc_long(1, pb)
    _enc_long(500, pb)
    _block(bytes, 3, pb)

    var rb = read_avro_bytes(Span(bytes))
    assert_equal(rb.num_rows(), 6)
    assert_equal(rb.column_at(0).null_count(), 2, "two nulls")
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    assert_true(not arr.is_null(0), "row 0 valid")
    assert_equal(Int(arr.get(0)), 100)
    assert_true(arr.is_null(1), "row 1 null, written before the realloc")
    assert_true(not arr.is_null(2), "row 2 valid")
    assert_equal(Int(arr.get(2)), 200)
    assert_true(arr.is_null(3), "row 3 null")
    assert_true(not arr.is_null(4), "row 4 valid")
    assert_equal(Int(arr.get(4)), 400)
    assert_true(not arr.is_null(5), "row 5 valid")
    assert_equal(Int(arr.get(5)), 500)
    print("  test_nullable_reserve_preserves_validity PASS")


def test_nullable_multi_block_growth() raises:
    comptime NB = 20
    comptime PER = 10
    var bytes = _header(_NULLABLE_LONG)
    for bi in range(NB):
        var p = List[UInt8]()
        for ri in range(PER):
            var idx = bi * PER + ri
            if idx % 7 == 0:
                _enc_long(0, p)
            else:
                _enc_long(1, p)
                _enc_long(Int64(idx), p)
        _block(bytes, PER, p)

    var rb = read_avro_bytes(Span(bytes))
    assert_equal(rb.num_rows(), NB * PER)
    var want_nulls = 0
    for idx in range(NB * PER):
        if idx % 7 == 0:
            want_nulls += 1
    assert_equal(rb.column_at(0).null_count(), want_nulls)
    var arr = rb.column_at(0).as_primitive[DType.int64]()
    for idx in range(NB * PER):
        if idx % 7 == 0:
            assert_true(arr.is_null(idx), "row " + String(idx) + " null")
        else:
            assert_true(not arr.is_null(idx), "row " + String(idx) + " valid")
            assert_equal(Int(arr.get(idx)), idx, "row " + String(idx))
    print("  test_nullable_multi_block_growth PASS")


def test_float64_values() raises:
    comptime N = 10_000
    var bytes = _header(
        '{"type":"record","name":"R","fields":[{"name":"v","type":"double"}]}'
    )
    var p = List[UInt8]()
    for i in range(N):
        _enc_double(Float64(i) * 0.5, p)
    _block(bytes, N, p)
    var rb = read_avro_bytes(Span(bytes))
    assert_equal(rb.num_rows(), N)
    var arr = rb.column_at(0).as_primitive[DType.float64]()
    for i in range(N):
        assert_equal(arr.get(i), Float64(i) * 0.5, "row " + String(i))
    print("  test_float64_values PASS")


def test_int32_values() raises:
    comptime N = 5_000
    var bytes = _header(
        '{"type":"record","name":"R","fields":[{"name":"v","type":"int"}]}'
    )
    var p = List[UInt8]()
    for i in range(N):
        _enc_long(Int64(i - 2500), p)  # an Avro int is a zigzag varint too
    _block(bytes, N, p)
    var rb = read_avro_bytes(Span(bytes))
    assert_equal(rb.num_rows(), N)
    var arr = rb.column_at(0).as_primitive[DType.int32]()
    for i in range(N):
        assert_equal(Int(arr.get(i)), i - 2500, "row " + String(i))
    print("  test_int32_values PASS")


def main() raises:
    test_nullable_reserve_preserves_validity()
    test_nullable_multi_block_growth()
    test_float64_values()
    test_int32_values()
    print("test_avro_accumulator_growth: ALL PASS")
