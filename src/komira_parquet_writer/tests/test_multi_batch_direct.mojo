# The multi-array encoders (`writer_multi_batch`).
#
# The oracle is the single-array encoder: encoding two arrays must give, byte
# for byte, the page `encode_plain_column` / `encode_string_column_page` gives
# for their concatenation, and the same statistics.
#
#   * test_two_primitives_equal_the_concatenation: INT32, INT64 and DOUBLE,
#     OPTIONAL with nulls in both arrays (the second SLICED, so offset > 0)
#     and REQUIRED, uncompressed and SNAPPY. Catches definition levels that
#     cover one array only, a second array read from offset 0, and null
#     slots written as values.
#   * test_two_strings_equal_the_concatenation: the same for BYTE_ARRAY.
#   * test_n_primitives_from_byte_views: three arrays given as raw bytes equal
#     the concatenation's page (statistics aside: the byte form carries
#     none); mismatched lists and a short view are refused.
#   * test_required_refuses_a_null: nullable=False with a null raises.
#   * test_two_to_buffer_splits_header_and_body: the EncodedColumn's header
#     and body are the page's bytes, and sizes are the page's.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer import (
    encode_plain_column,
    encode_string_column_page,
)
from komira_parquet_writer.writer_multi_batch import (
    encode_n_primitives,
    encode_two_primitives,
    encode_two_strings,
    encode_two_to_buffer,
)


def _same_list(a: List[UInt8], b: List[UInt8], what: String) raises:
    assert_equal(len(a), len(b), what + ": length")
    for i in range(len(a)):
        assert_equal(Int(a[i]), Int(b[i]), what + " byte " + String(i))


def _same_opt(a: Optional[List[UInt8]], b: Optional[List[UInt8]], what: String) raises:
    assert_equal(Bool(a), Bool(b), what)
    if a:
        _same_list(a.value(), b.value(), what)


def _same_stats(a: Optional[Statistics], b: Optional[Statistics]) raises:
    assert_equal(Bool(a), Bool(b), "statistics present")
    if not a:
        return
    assert_equal(a.value().null_count.value(), b.value().null_count.value())
    _same_opt(a.value().min_value, b.value().min_value, "min")
    _same_opt(a.value().max_value, b.value().max_value, "max")
    _same_opt(a.value().hll_registers, b.value().hll_registers, "registers")
    assert_equal(Bool(a.value().nan_count), Bool(b.value().nan_count))


def _val(i: Int) -> Int:
    return (i * 37) % 101 - 40


def _arr[
    dtype: DType
](start: Int, n: Int, null_every: Int) raises -> PrimitiveArray[dtype]:
    var a = PrimitiveArray[dtype].allocate_nullable(n) if null_every > 0 else PrimitiveArray[dtype].allocate(n)
    for i in range(n):
        if null_every > 0 and (start + i) % null_every == 2:
            a.set(i, Scalar[dtype](9999))
            a._set_null(i)
        else:
            a.set(i, Scalar[dtype](_val(start + i)))
    return a^


def _check_two[dtype: DType](nullable: Bool, codec: CompressionCodec) raises:
    var every = 6 if nullable else 0
    var first = _arr[dtype](0, 300, every)
    # The second array is a slice, so its offset is 40.
    var second_full = _arr[dtype](300, 400, every)
    var second = second_full.slice(40, 333)
    var whole = PrimitiveArray[dtype].allocate_nullable(633) if nullable else PrimitiveArray[dtype].allocate(633)
    for i in range(633):
        var r = i if i < 300 else 340 + (i - 300)
        if nullable and r % 6 == 2:
            whole.set(i, Scalar[dtype](9999))
            whole._set_null(i)
        else:
            whole.set(i, Scalar[dtype](_val(r)))
    var got = encode_two_primitives[dtype](0, first, second, "c", nullable=nullable, codec=codec)
    var want = encode_plain_column[dtype](0, whole, "c", nullable=nullable, codec=codec)
    _same_list(got.data, want.data, "page")
    assert_equal(got.num_values, 633)
    assert_equal(got.uncompressed_size, want.uncompressed_size)
    assert_equal(got.compressed_size, want.compressed_size)
    assert_equal(len(got.encodings), len(want.encodings))
    _same_stats(got.statistics.copy(), want.statistics.copy())


def test_two_primitives_equal_the_concatenation() raises:
    for nullable in [False, True]:
        for codec in [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]:
            _check_two[DType.int32](nullable, codec)
            _check_two[DType.int64](nullable, codec)
            _check_two[DType.float64](nullable, codec)


def _strings(start: Int, n: Int, null_every: Int, mut valid: List[Bool]) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("v") + String((start + i) * 13 % 29) + String("x") * ((start + i) % 5))
        valid.append(not (null_every > 0 and (start + i) % null_every == 3))
    return out^


def test_two_strings_equal_the_concatenation() raises:
    for nullable in [False, True]:
        var every = 7 if nullable else 0
        var v1 = List[Bool]()
        var v2 = List[Bool]()
        var s1 = _strings(0, 120, every, v1)
        var s2 = _strings(120, 90, every, v2)
        var all = s1.copy()
        all.extend(s2.copy())
        var vall = v1.copy()
        vall.extend(v2.copy())
        var a1 = StringArray.from_strings_with_validity(s1, v1)
        var a2 = StringArray.from_strings_with_validity(s2, v2)
        var whole = StringArray.from_strings_with_validity(all, vall)
        var got = encode_two_strings(0, a1, a2, "s", nullable=nullable, codec=CompressionCodec.SNAPPY)
        var want = encode_string_column_page(0, whole, "s", nullable=nullable, codec=CompressionCodec.SNAPPY)
        _same_list(got.data, want.data, "string page")
        assert_equal(got.num_values, 210)
        assert_false(Bool(got.statistics))


def test_n_primitives_from_byte_views() raises:
    var whole = _arr[DType.int64](0, 150, 0)
    # One list needs one origin: the three arrays' views are taken from a
    # single backing array sliced three ways.
    var base = whole.slice(0, 150)
    var lengths: List[Int] = [50, 70, 30]
    var offsets: List[Int] = [0, 50, 120]
    var parts = List[ByteView[origin_of(base)]]()
    for i in range(3):
        parts.append(base.view_ro().sub(offsets[i] * 8, lengths[i] * 8))
    var got = encode_n_primitives[DType.int64](0, parts, lengths, "c")
    var want = encode_plain_column[DType.int64](0, whole, "c")
    _same_list(got.data, want.data, "n-ary page")
    assert_false(Bool(got.statistics))
    var short: List[Int] = [50, 70]
    with assert_raises(contains="3 views but 2 lengths"):
        _ = encode_n_primitives[DType.int64](0, parts, short, "c")
    var too_long: List[Int] = [50, 70, 31]
    with assert_raises(contains="array 2 has 240 bytes for 31 elements"):
        _ = encode_n_primitives[DType.int64](0, parts, too_long, "c")


def test_required_refuses_a_null() raises:
    var a = _arr[DType.int32](0, 10, 6)
    var b = _arr[DType.int32](10, 10, 0)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_two_primitives[DType.int32](0, a, b, "c", nullable=False)
    var v: List[Bool] = [True, False]
    var s: List[String] = ["a", "b"]
    var sa = StringArray.from_strings_with_validity(s, v)
    with assert_raises(contains="is REQUIRED but holds"):
        _ = encode_two_strings(0, sa, sa, "s", nullable=False)


def test_two_to_buffer_splits_header_and_body() raises:
    var a = _arr[DType.int64](0, 500, 0)
    var b = _arr[DType.int64](500, 500, 0)
    var page = encode_two_primitives[DType.int64](0, a, b, "c", codec=CompressionCodec.SNAPPY)
    var enc = encode_two_to_buffer[DType.int64](0, a, b, "c", codec=CompressionCodec.SNAPPY)
    var joined = enc.page_header_bytes.copy()
    joined.extend(enc.data_bytes.copy())
    _same_list(joined, page.data, "header + body")
    assert_equal(enc.data_size, page.uncompressed_size)
    assert_equal(enc.compressed_size, page.compressed_size)
    assert_equal(len(enc.data_bytes), page.compressed_size)
    assert_equal(enc.num_values, 1000)
    assert_true(enc.compressed_size < enc.data_size)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
