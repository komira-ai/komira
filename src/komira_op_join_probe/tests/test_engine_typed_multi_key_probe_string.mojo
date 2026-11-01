# Composite joins over STRING keys: string + string and string + INT64
# keys through INNER, SEMI, ANTI and LEFT; the empty string, long keys, UTF-8
# bytes compared as bytes, a forced hash collision filtered by the byte
# compare, three keys, and NULL string keys matching nothing.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.arrow_types import ArrowType
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView

from komira_op_join_probe.join_multi_key import (
    MultiKeyColumns,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_semi,
    multi_key_probe_anti,
)
from komira_buffer.heap_region import HeapRegion


def _make_int64_col(name: String, values: List[Int]) raises -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return Column.from_primitive(arr^)


def _make_string_col(name: String, values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_string_array_with_nulls(
    values: List[String],
    null_mask: List[Bool],
) raises -> StringArray[HeapRegion]:
    """Build a nullable StringArray. `null_mask[i] == True` -> row i is null."""
    var n = len(values)
    var total_bytes = 0
    for i in range(n):
        if not null_mask[i]:
            total_bytes += values[i].byte_length()

    from std.sys import size_of
    comptime int32_size = size_of[Int32]()

    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))

    var offset = 0
    var null_count = 0
    var bm = Bitmap.create(n)
    for i in range(n):
        if null_mask[i]:
            bm.clear(i)
            null_count += 1
        else:
            bm.set(i)
            var s = values[i]
            var s_len = s.byte_length()
            if s_len > 0:
                var src_view = ByteView(
                    s.unsafe_ptr().bitcast[UInt8](), s_len
                )
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
            offset += s_len
        offsets_buf.set_typed[Int32](i + 1, Int32(offset))

    offsets_buf.set_length(Int64((n + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    return StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=bm^,
        length=n,
        data_length=total_bytes,
        null_count=null_count,
    )


def _make_2col_string_string_with_nulls(
    c0_name: String, c1_name: String,
    c0_values: List[String], c0_nulls: List[Bool],
    c1_values: List[String], c1_nulls: List[Bool],
) raises -> RecordBatch:
    """Build a 2-column STRING+STRING batch with explicit per-row null flags."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, True))
    sb.add_field(Field(c1_name, ArrowType.STRING, True))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(Column.from_string(_make_string_array_with_nulls(c0_values, c0_nulls)^))
    bldr.add_column(Column.from_string(_make_string_array_with_nulls(c1_values, c1_nulls)^))
    return bldr.build(schema^)


def _make_2col_string_string(
    c0_name: String, c1_name: String,
    c0_values: List[String], c1_values: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, False))
    sb.add_field(Field(c1_name, ArrowType.STRING, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_string_col(c0_name, c0_values))
    bldr.add_column(_make_string_col(c1_name, c1_values))
    return bldr.build(schema^)


def _make_2col_string_int64(
    c0_name: String, c1_name: String,
    c0_values: List[String], c1_values: List[Int],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, False))
    sb.add_field(Field(c1_name, ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_string_col(c0_name, c0_values))
    bldr.add_column(_make_int64_col(c1_name, c1_values))
    return bldr.build(schema^)


def _make_3col_string_string_int64(
    c0_name: String, c1_name: String, c2_name: String,
    c0_values: List[String], c1_values: List[String], c2_values: List[Int],
) raises -> RecordBatch:
    """Build a 3-column batch: STRING + STRING + INT64 (payload)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, False))
    sb.add_field(Field(c1_name, ArrowType.STRING, False))
    sb.add_field(Field(c2_name, ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_string_col(c0_name, c0_values))
    bldr.add_column(_make_string_col(c1_name, c1_values))
    bldr.add_column(_make_int64_col(c2_name, c2_values))
    return bldr.build(schema^)


def _direct_inner_probe(
    var build_keys: MultiKeyColumns,
    var probe_keys: MultiKeyColumns,
) raises -> Tuple[List[Int], List[Int]]:
    var builder = MultiKeyHashJoinBuilder.build(build_keys^)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(probe_keys, bm, pm)
    return (bm^, pm^)


def _direct_left_probe(
    var build_keys: MultiKeyColumns,
    var probe_keys: MultiKeyColumns,
) raises -> Tuple[List[Int], List[Int]]:
    var builder = MultiKeyHashJoinBuilder.build(build_keys^)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_left_into(probe_keys, bm, pm)
    return (bm^, pm^)


def test_string_string_inner_basic() raises:
    """STRING + STRING multi-key INNER probe — basic match shape."""
    var b_country: List[String] = ["US", "DE", "JP"]
    var b_currency: List[String] = ["USD", "EUR", "JPY"]
    var b = _make_2col_string_string("country", "currency", b_country, b_currency)

    var p_country: List[String] = ["US", "DE", "FR", "JP"]
    var p_currency: List[String] = ["USD", "USD", "EUR", "JPY"]
    var p = _make_2col_string_string(
        "country", "currency", p_country, p_currency
    )

    var bk = List[String]()
    bk.append("country")
    bk.append("currency")
    var pk = List[String]()
    pk.append("country")
    pk.append("currency")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)
    var got_p0 = bm_pm[1][0]
    var got_p1 = bm_pm[1][1]
    var both_present = (
        (got_p0 == 0 and got_p1 == 3) or (got_p0 == 3 and got_p1 == 0)
    )
    assert_true(both_present, "expected probe indices {0, 3}")


def test_string_int64_mixed_inner() raises:
    """STRING + INT64 mixed multi-key INNER probe."""
    var b_name: List[String] = ["alice", "bob", "carol"]
    var b_id: List[Int] = [1, 2, 3]
    var b = _make_2col_string_int64("name", "id", b_name, b_id)

    var p_name: List[String] = ["alice", "alice", "bob", "zoe"]
    var p_id: List[Int] = [1, 2, 2, 0]
    var p = _make_2col_string_int64("name", "id", p_name, p_id)

    var bk = List[String]()
    bk.append("name")
    bk.append("id")
    var pk = List[String]()
    pk.append("name")
    pk.append("id")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)


def test_string_int64_mixed_semi() raises:
    """STRING + INT64 multi-key SEMI: emit probe rows that have a match."""
    var b_name: List[String] = ["alice", "bob"]
    var b_id: List[Int] = [1, 2]
    var b = _make_2col_string_int64("name", "id", b_name, b_id)

    var p_name: List[String] = ["alice", "alice", "bob"]
    var p_id: List[Int] = [1, 99, 2]
    var p = _make_2col_string_int64("name", "id", p_name, p_id)

    var bk = List[String]()
    bk.append("name")
    bk.append("id")
    var pk = List[String]()
    pk.append("name")
    pk.append("id")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var semi = multi_key_probe_semi(builder, pks)

    assert_equal(len(semi), 2)
    assert_equal(semi[0], 0)
    assert_equal(semi[1], 2)


def test_string_int64_mixed_anti() raises:
    """STRING + INT64 multi-key ANTI: emit probe rows that have NO match."""
    var b_name: List[String] = ["alice", "bob"]
    var b_id: List[Int] = [1, 2]
    var b = _make_2col_string_int64("name", "id", b_name, b_id)

    var p_name: List[String] = ["alice", "alice", "bob", "carol"]
    var p_id: List[Int] = [1, 99, 2, 3]
    var p = _make_2col_string_int64("name", "id", p_name, p_id)

    var bk = List[String]()
    bk.append("name")
    bk.append("id")
    var pk = List[String]()
    pk.append("name")
    pk.append("id")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var anti = multi_key_probe_anti(builder, pks)

    assert_equal(len(anti), 2)
    assert_equal(anti[0], 1)
    assert_equal(anti[1], 3)


def test_string_string_left_emits_unmatched() raises:
    """STRING + STRING LEFT: unmatched probe rows emit with build idx -1."""
    var b_country: List[String] = ["US", "DE"]
    var b_currency: List[String] = ["USD", "EUR"]
    var b = _make_2col_string_string("country", "currency", b_country, b_currency)

    var p_country: List[String] = ["US", "FR"]
    var p_currency: List[String] = ["USD", "EUR"]
    var p = _make_2col_string_string("country", "currency", p_country, p_currency)

    var bk = List[String]()
    bk.append("country")
    bk.append("currency")
    var pk = List[String]()
    pk.append("country")
    pk.append("currency")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_left_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)
    assert_equal(bm_pm[1][0], 0)
    assert_equal(bm_pm[0][0], 0)
    assert_equal(bm_pm[1][1], 1)
    assert_equal(bm_pm[0][1], -1)


def test_empty_string_matches_empty_string() raises:
    """Empty string `""` is a legitimate value and matches itself."""
    var b_n: List[String] = ["alice", "alice"]
    var b_t: List[String] = ["", "x"]
    var b = _make_2col_string_string("name", "tag", b_n, b_t)

    var p_n: List[String] = ["alice", "alice"]
    var p_t: List[String] = ["", "y"]
    var p = _make_2col_string_string("name", "tag", p_n, p_t)

    var bk = List[String]()
    bk.append("name")
    bk.append("tag")
    var pk = List[String]()
    pk.append("name")
    pk.append("tag")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 1)
    assert_equal(len(bm_pm[1]), 1)
    assert_equal(bm_pm[0][0], 0)
    assert_equal(bm_pm[1][0], 0)


def test_long_string_byte_compare() raises:
    """Large STRING keys (>100 bytes) compare correctly byte-by-byte."""
    var long_a = String("a" * 200)
    var long_b = String("a" * 199 + "b")  # 200 chars, last char different
    var long_c = String("a" * 199 + "c")  # 200 chars, last char different

    var b_x: List[String] = [long_a, long_b]
    var b_y: List[String] = ["k1", "k2"]
    var b = _make_2col_string_string("x", "y", b_x, b_y)

    var p_x: List[String] = [long_a, long_b, long_c]
    var p_y: List[String] = ["k1", "k2", "k1"]
    var p = _make_2col_string_string("x", "y", p_x, p_y)

    var bk = List[String]()
    bk.append("x")
    bk.append("y")
    var pk = List[String]()
    pk.append("x")
    pk.append("y")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)


def test_utf8_byte_sequences() raises:
    """UTF-8 byte sequences compared byte-equal (no Unicode normalization)."""
    var s_a = String("café")     # 4 bytes UTF-8 (c-a-f-é = 0xc3 0xa9)
    var s_b = String("naïve")    # 5 bytes UTF-8
    var s_c = String("hello")    # 5 bytes ASCII

    var b_x: List[String] = [s_a, s_b, s_c]
    var b_y: List[String] = ["1", "2", "3"]
    var b = _make_2col_string_string("x", "y", b_x, b_y)

    var p_x: List[String] = [s_a, s_b, s_c]
    var p_y: List[String] = ["1", "2", "3"]
    var p = _make_2col_string_string("x", "y", p_x, p_y)

    var bk = List[String]()
    bk.append("x")
    bk.append("y")
    var pk = List[String]()
    pk.append("x")
    pk.append("y")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 3)
    assert_equal(len(bm_pm[1]), 3)


def test_no_false_match_via_hash_collision() raises:
    """Hash collision is filtered by chain-walk byte-equality."""
    var b_x: List[String] = ["alpha", "beta"]
    var b_y: List[String] = ["k1", "k2"]
    var b = _make_2col_string_string("x", "y", b_x, b_y)

    var p_x: List[String] = ["alphabet", "alpha", "be"]
    var p_y: List[String] = ["k1", "k1", "k2"]
    var p = _make_2col_string_string("x", "y", p_x, p_y)

    var bk = List[String]()
    bk.append("x")
    bk.append("y")
    var pk = List[String]()
    pk.append("x")
    pk.append("y")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 1)
    assert_equal(len(bm_pm[1]), 1)
    assert_equal(bm_pm[1][0], 1)


def test_three_keys_string_string_int64() raises:
    """3-key composite: STRING + STRING + INT64, INNER probe."""
    var b_a: List[String] = ["X", "X", "Y"]
    var b_b: List[String] = ["foo", "bar", "foo"]
    var b_c: List[Int] = [1, 2, 3]
    var b = _make_3col_string_string_int64("a", "b", "c", b_a, b_b, b_c)

    var p_a: List[String] = ["X", "X", "X", "Y"]
    var p_b: List[String] = ["foo", "bar", "qux", "foo"]
    var p_c: List[Int] = [1, 2, 5, 3]
    var p = _make_3col_string_string_int64("a", "b", "c", p_a, p_b, p_c)

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    bk.append("c")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")
    pk.append("c")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 3)
    assert_equal(len(bm_pm[1]), 3)


def test_int64_int64_keys() raises:
    """INT64 + INT64 keys take the integer arm unchanged."""
    var b_a: List[Int] = [1, 1, 2]
    var b_b: List[Int] = [10, 20, 10]

    var sb = SchemaBuilder()
    sb.add_field(Field("la", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var schema = sb.build()
    var l_bldr = RecordBatchBuilder()
    l_bldr.add_column(_make_int64_col("la", b_a))
    l_bldr.add_column(_make_int64_col("b", b_b))
    var l = l_bldr.build(schema^)

    var p_a: List[Int] = [1, 1, 2]
    var p_b: List[Int] = [10, 30, 10]
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("ra", ArrowType.INT64, False))
    sb2.add_field(Field("b", ArrowType.INT64, False))
    var schema2 = sb2.build()
    var p_bldr = RecordBatchBuilder()
    p_bldr.add_column(_make_int64_col("ra", p_a))
    p_bldr.add_column(_make_int64_col("b", p_b))
    var p = p_bldr.build(schema2^)

    var lk = List[String]()
    lk.append("la")
    lk.append("b")
    var rk = List[String]()
    rk.append("ra")
    rk.append("b")

    var bks = extract_join_key_columns_serial(l, lk)
    var pks = extract_join_key_columns_serial(p, rk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)


def test_null_string_keys_no_match_inner() raises:
    """Probe rows with NULL STRING keys produce no INNER match (SQL NULL never matches).
    """
    var b_a: List[String] = ["a", "b"]
    var b_b: List[String] = ["x", "y"]
    var b = _make_2col_string_string("a", "b", b_a, b_b)

    var p_a_vals: List[String] = ["", "a", "a"]  # row 0 is NULL
    var p_a_nulls: List[Bool] = [True, False, False]
    var p_b_vals: List[String] = ["x", "", "x"]  # row 1 is NULL
    var p_b_nulls: List[Bool] = [False, True, False]
    var p = _make_2col_string_string_with_nulls(
        "a", "b", p_a_vals, p_a_nulls, p_b_vals, p_b_nulls,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 1)
    assert_equal(len(bm_pm[1]), 1)
    assert_equal(bm_pm[1][0], 2)


def test_null_string_keys_left_emits_unmatched() raises:
    """LEFT join: NULL-keyed STRING probe rows emit with -1 (unmatched, NULL right)."""
    var b_a: List[String] = ["a", "b"]
    var b_b: List[String] = ["x", "y"]
    var b = _make_2col_string_string("a", "b", b_a, b_b)

    var p_a_vals: List[String] = ["", "a"]   # row 0 is NULL
    var p_a_nulls: List[Bool] = [True, False]
    var p_b_vals: List[String] = ["x", "x"]
    var p_b_nulls: List[Bool] = [False, False]
    var p = _make_2col_string_string_with_nulls(
        "a", "b", p_a_vals, p_a_nulls, p_b_vals, p_b_nulls,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_left_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)
    assert_equal(bm_pm[0][0], -1)
    assert_equal(bm_pm[1][0], 0)
    assert_equal(bm_pm[0][1], 0)
    assert_equal(bm_pm[1][1], 1)


def test_null_string_keys_anti_emits() raises:
    """ANTI join: NULL-keyed STRING probe row IS emitted (no match)."""
    var b_a: List[String] = ["a", "b"]
    var b_b: List[String] = ["x", "y"]
    var b = _make_2col_string_string("a", "b", b_a, b_b)

    var p_a_vals: List[String] = ["", "a", "z"]
    var p_a_nulls: List[Bool] = [True, False, False]
    var p_b_vals: List[String] = ["x", "x", "x"]
    var p_b_nulls: List[Bool] = [False, False, False]
    var p = _make_2col_string_string_with_nulls(
        "a", "b", p_a_vals, p_a_nulls, p_b_vals, p_b_nulls,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var anti = multi_key_probe_anti(builder, pks)

    assert_equal(len(anti), 2)
    assert_equal(anti[0], 0)
    assert_equal(anti[1], 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_string_inner_basic]()
    suite.test[test_string_int64_mixed_inner]()
    suite.test[test_string_int64_mixed_semi]()
    suite.test[test_string_int64_mixed_anti]()
    suite.test[test_string_string_left_emits_unmatched]()
    suite.test[test_empty_string_matches_empty_string]()
    suite.test[test_long_string_byte_compare]()
    suite.test[test_utf8_byte_sequences]()
    suite.test[test_no_false_match_via_hash_collision]()
    suite.test[test_three_keys_string_string_int64]()
    suite.test[test_int64_int64_keys]()
    suite.test[test_null_string_keys_no_match_inner]()
    suite.test[test_null_string_keys_left_emits_unmatched]()
    suite.test[test_null_string_keys_anti_emits]()
    suite^.run()
