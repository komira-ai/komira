# Direct tests of `decode_helpers.mojo`: the Parquet-to-Arrow type mapping
# (physical type plus ConvertedType / LogicalType annotation, per
# parquet.thrift and LogicalTypes.md), the post-decode re-labels and the
# narrow-int narrowing, the Arrow `Field` built for a schema element, the
# bulk bit-set, and the List-to-array copies. Expected values are the
# format's: e.g. ConvertedType JSON is 19 and is UTF-8 text, BSON is 20 and
# is binary, an unannotated BYTE_ARRAY is binary.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import (
    CONVERTED_TYPE_BSON,
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_ENUM,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_JSON,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UTF8,
    FieldRepetitionType,
    ParquetType,
)

from komira_parquet.decode_helpers import (
    LOGICAL_TS_UNIT_MICROS,
    LOGICAL_TS_UNIT_MILLIS,
    LOGICAL_TS_UNIT_NANOS,
    _arrow_timestamp_type_for_unit,
    _byte_array_is_text,
    _is_decimal_annotated,
    _list_to_float32_array_from_values,
    _list_to_float64_array_from_values,
    _list_to_int32_array,
    _list_to_int32_array_from_values,
    _list_to_int64_array_from_values,
    _narrow_int_logical_type,
    _parquet_type_to_arrow_type_opt,
    _relabel_byte_array_binary,
    _relabel_int_logical_type,
    _relabel_timestamp_logical_type,
    _schema_element_to_arrow_type,
    _set_bits_bulk,
    field_from_schema_element,
    flba_schema_info,
    schema_element_arrow_type,
    schema_element_decimal_ps,
)


def _same(a: ArrowType, b: ArrowType, what: String) raises:
    assert_true(a == b, what)


# --- type mapping ------------------------------------------------------------


def test_byte_array_text_annotations_follow_parquet_thrift() raises:
    """UTF8 (0), ENUM (4) and JSON (19) are text; BSON (20) is binary, and so
    are the values 24 and 25 (INTERVAL is 21; 24 and 25 name nothing), which
    an earlier table used for JSON and BSON."""
    assert_equal(CONVERTED_TYPE_JSON, 19)
    assert_equal(CONVERTED_TYPE_BSON, 20)
    assert_true(_byte_array_is_text(CONVERTED_TYPE_UTF8))
    assert_true(_byte_array_is_text(CONVERTED_TYPE_ENUM))
    assert_true(_byte_array_is_text(CONVERTED_TYPE_JSON))
    assert_false(_byte_array_is_text(CONVERTED_TYPE_BSON))
    assert_false(_byte_array_is_text(24))
    assert_false(_byte_array_is_text(25))
    assert_false(_byte_array_is_text(-1))
    var ba = ParquetType.BYTE_ARRAY
    _same(_schema_element_to_arrow_type(ba, 19), ArrowType.STRING, "JSON")
    _same(_schema_element_to_arrow_type(ba, 20), ArrowType.BINARY, "BSON")
    _same(_schema_element_to_arrow_type(ba, 0), ArrowType.STRING, "UTF8")
    _same(_schema_element_to_arrow_type(ba, -1), ArrowType.BINARY, "none")


def test_timestamp_units() raises:
    _same(_arrow_timestamp_type_for_unit(LOGICAL_TS_UNIT_MILLIS), ArrowType.TIMESTAMP_MS, "ms")
    _same(_arrow_timestamp_type_for_unit(LOGICAL_TS_UNIT_MICROS), ArrowType.TIMESTAMP_US, "us")
    _same(_arrow_timestamp_type_for_unit(LOGICAL_TS_UNIT_NANOS), ArrowType.TIMESTAMP_NS, "ns")
    _same(_arrow_timestamp_type_for_unit(9), ArrowType.TIMESTAMP_US, "other")


def test_physical_type_map() raises:
    _same(_parquet_type_to_arrow_type_opt(ParquetType.BOOLEAN), ArrowType.BOOL, "b")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.INT32), ArrowType.INT32, "i32")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.INT64), ArrowType.INT64, "i64")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.INT96), ArrowType.INT64, "i96")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.FLOAT), ArrowType.FLOAT32, "f")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.DOUBLE), ArrowType.FLOAT64, "d")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.BYTE_ARRAY), ArrowType.STRING, "ba")
    _same(_parquet_type_to_arrow_type_opt(ParquetType.FIXED_LEN_BYTE_ARRAY), ArrowType.BINARY, "flba")
    _same(_parquet_type_to_arrow_type_opt(ParquetType(UInt8(42))), ArrowType.STRING, "unknown")


def test_decimal_annotation() raises:
    var d = CONVERTED_TYPE_DECIMAL
    assert_true(_is_decimal_annotated(ParquetType.INT32, d))
    assert_true(_is_decimal_annotated(ParquetType.INT64, d))
    assert_true(_is_decimal_annotated(ParquetType.FIXED_LEN_BYTE_ARRAY, d))
    assert_false(_is_decimal_annotated(ParquetType.BYTE_ARRAY, d))
    assert_false(_is_decimal_annotated(ParquetType.INT32, -1))
    _same(_schema_element_to_arrow_type(ParquetType.INT64, d), ArrowType.DECIMAL128, "dec")
    _same(_schema_element_to_arrow_type(ParquetType.BYTE_ARRAY, d), ArrowType.BINARY, "ba dec")


def test_annotated_int_map() raises:
    var i32 = ParquetType.INT32
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_UINT_32), ArrowType.UINT32, "u32")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_DATE), ArrowType.DATE32, "date")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_INT_8), ArrowType.INT8, "i8")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_INT_16), ArrowType.INT16, "i16")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_UINT_8), ArrowType.UINT8, "u8")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_UINT_16), ArrowType.UINT16, "u16")
    _same(_schema_element_to_arrow_type(i32, CONVERTED_TYPE_UINT_64), ArrowType.INT32, "i32 other")
    var i64 = ParquetType.INT64
    _same(_schema_element_to_arrow_type(i64, CONVERTED_TYPE_UINT_64), ArrowType.UINT64, "u64")
    _same(_schema_element_to_arrow_type(i64, CONVERTED_TYPE_UINT_32), ArrowType.INT64, "i64 other")
    _same(_schema_element_to_arrow_type(ParquetType.DOUBLE, -1), ArrowType.FLOAT64, "double")


def test_schema_element_arrow_type() raises:
    _same(schema_element_arrow_type(SchemaElement("g", num_children=1)), ArrowType.STRING, "group")
    var ts = SchemaElement("t", type=ParquetType.INT64, logical_timestamp_unit=LOGICAL_TS_UNIT_NANOS)
    _same(schema_element_arrow_type(ts), ArrowType.TIMESTAMP_NS, "ts")
    var ts32 = SchemaElement("t", type=ParquetType.INT32, logical_timestamp_unit=LOGICAL_TS_UNIT_NANOS)
    _same(schema_element_arrow_type(ts32), ArrowType.INT32, "unit on INT32 ignored")
    var u = SchemaElement("u", type=ParquetType.INT32, converted_type=CONVERTED_TYPE_UINT_32)
    _same(schema_element_arrow_type(u), ArrowType.UINT32, "annotated")
    _same(schema_element_arrow_type(SchemaElement("p", type=ParquetType.INT64)), ArrowType.INT64, "plain")


# --- re-labels and narrowing -------------------------------------------------


def _i32_col(values: List[Int]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    return Column.from_primitive[DType.int32](arr)


def _i64_col() raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(2)
    arr.set(0, Int64(-1))
    arr.set(1, Int64(7))
    return Column.from_primitive[DType.int64](arr)


def test_relabel_int_logical_type() raises:
    var one: List[Int] = [1]
    var i32 = ParquetType.INT32
    _same(_relabel_int_logical_type(_i32_col(one), i32, -1).arrow_type, ArrowType.INT32, "absent")
    _same(_relabel_int_logical_type(_i32_col(one), i32, CONVERTED_TYPE_UINT_32).arrow_type, ArrowType.UINT32, "u32")
    _same(_relabel_int_logical_type(_i32_col(one), i32, CONVERTED_TYPE_DATE).arrow_type, ArrowType.DATE32, "date")
    _same(_relabel_int_logical_type(_i32_col(one), i32, CONVERTED_TYPE_INT_8).arrow_type, ArrowType.INT32, "not a relabel")
    _same(_relabel_int_logical_type(_i64_col(), ParquetType.INT64, CONVERTED_TYPE_UINT_64).arrow_type, ArrowType.UINT64, "u64")
    _same(_relabel_int_logical_type(_i64_col(), ParquetType.INT64, CONVERTED_TYPE_DATE).arrow_type, ArrowType.INT64, "i64 other")
    # The column is not the bare physical type: left alone.
    _same(_relabel_int_logical_type(_i64_col(), i32, CONVERTED_TYPE_UINT_32).arrow_type, ArrowType.INT64, "mismatch")
    _same(_relabel_int_logical_type(_i32_col(one), ParquetType.INT64, CONVERTED_TYPE_UINT_64).arrow_type, ArrowType.INT32, "mismatch 64")


def test_relabel_byte_array_binary() raises:
    var strs: List[String] = ["a", "b"]
    var col = Column.from_string(StringArray.from_strings(strs))
    var ba = ParquetType.BYTE_ARRAY
    _same(_relabel_byte_array_binary(Column.from_string(StringArray.from_strings(strs)), ba, -1).arrow_type, ArrowType.BINARY, "binary")
    _same(_relabel_byte_array_binary(Column.from_string(StringArray.from_strings(strs)), ba, CONVERTED_TYPE_UTF8).arrow_type, ArrowType.STRING, "text")
    _same(_relabel_byte_array_binary(col^, ParquetType.INT32, -1).arrow_type, ArrowType.STRING, "not BA")
    var one: List[Int] = [1]
    _same(_relabel_byte_array_binary(_i32_col(one), ba, -1).arrow_type, ArrowType.INT32, "not STRING")


def test_narrow_int_every_width_and_the_nulls() raises:
    var vals: List[Int] = [-128, 127, 5, -1, 300]
    var i32 = ParquetType.INT32
    var c8 = _narrow_int_logical_type(_i32_col(vals), i32, CONVERTED_TYPE_INT_8)
    _same(c8.arrow_type, ArrowType.INT8, "int8")
    var a8 = c8.as_primitive[DType.int8]()
    assert_equal(a8.get(0), Int8(-128))
    assert_equal(a8.get(1), Int8(127))
    assert_equal(a8.get(4), Int8(44))  # 300 truncated to its low byte
    var c16 = _narrow_int_logical_type(_i32_col(vals), i32, CONVERTED_TYPE_INT_16)
    assert_equal(c16.as_primitive[DType.int16]().get(4), Int16(300))
    var cu8 = _narrow_int_logical_type(_i32_col(vals), i32, CONVERTED_TYPE_UINT_8)
    assert_equal(cu8.as_primitive[DType.uint8]().get(3), UInt8(255))
    var cu16 = _narrow_int_logical_type(_i32_col(vals), i32, CONVERTED_TYPE_UINT_16)
    assert_equal(cu16.as_primitive[DType.uint16]().get(3), UInt16(65535))
    _same(_narrow_int_logical_type(_i32_col(vals), i32, CONVERTED_TYPE_UINT_32).arrow_type, ArrowType.INT32, "not narrow")
    _same(_narrow_int_logical_type(_i32_col(vals), i32, -1).arrow_type, ArrowType.INT32, "absent")
    _same(_narrow_int_logical_type(_i32_col(vals), ParquetType.INT64, CONVERTED_TYPE_INT_8).arrow_type, ArrowType.INT32, "not INT32 physical")
    _same(_narrow_int_logical_type(_i64_col(), i32, CONVERTED_TYPE_INT_8).arrow_type, ArrowType.INT64, "not INT32 column")
    # Nulls carry over.
    var n = PrimitiveArray[DType.int32].allocate_nullable(3)
    n.set(0, Int32(9))
    n.set(2, Int32(-9))
    n.validity.value().clear(1)
    n.null_count = 1
    var cn = _narrow_int_logical_type(Column.from_primitive[DType.int32](n), i32, CONVERTED_TYPE_INT_8)
    var an = cn.as_primitive[DType.int8]()
    assert_equal(an.null_count, 1)
    assert_true(Bool(an.validity))
    assert_false(an.validity.value().test(1))
    assert_true(an.validity.value().test(2))
    assert_equal(an.get(2), Int8(-9))
    # A nullable column of no rows: a validity of no bytes.
    var empty = PrimitiveArray[DType.int32].allocate_nullable(0)
    var ce = _narrow_int_logical_type(Column.from_primitive[DType.int32](empty), i32, CONVERTED_TYPE_INT_16)
    assert_equal(ce.as_primitive[DType.int16]().length, 0)


def test_relabel_timestamp() raises:
    var i64 = ParquetType.INT64
    _same(_relabel_timestamp_logical_type(_i64_col(), i64, 0).arrow_type, ArrowType.INT64, "no unit")
    _same(_relabel_timestamp_logical_type(_i64_col(), i64, LOGICAL_TS_UNIT_MILLIS).arrow_type, ArrowType.TIMESTAMP_MS, "ms")
    _same(_relabel_timestamp_logical_type(_i64_col(), ParquetType.INT32, LOGICAL_TS_UNIT_MILLIS).arrow_type, ArrowType.INT64, "not INT64")


# --- Field and schema info ---------------------------------------------------


def test_decimal_ps() raises:
    var no_type = SchemaElement("g")
    assert_equal(schema_element_decimal_ps(no_type)[0], 0)
    var plain = SchemaElement("p", type=ParquetType.INT32)
    assert_equal(schema_element_decimal_ps(plain)[1], 0)
    var bare = SchemaElement("d", type=ParquetType.INT64, converted_type=CONVERTED_TYPE_DECIMAL)
    assert_equal(schema_element_decimal_ps(bare)[0], 0)
    assert_equal(schema_element_decimal_ps(bare)[1], 0)
    var full = SchemaElement("d", type=ParquetType.INT64, converted_type=CONVERTED_TYPE_DECIMAL, scale=2, precision=12)
    assert_equal(schema_element_decimal_ps(full)[0], 12)
    assert_equal(schema_element_decimal_ps(full)[1], 2)


def test_field_nullability_and_plain_types() raises:
    var req = SchemaElement("r", type=ParquetType.INT32, repetition_type=FieldRepetitionType.REQUIRED)
    var f = field_from_schema_element(req)
    assert_equal(f.name, String("r"))
    assert_false(f.nullable)
    _same(f.arrow_type, ArrowType.INT32, "int32")
    var opt = SchemaElement("o", type=ParquetType.DOUBLE, repetition_type=FieldRepetitionType.OPTIONAL)
    assert_true(field_from_schema_element(opt).nullable)
    assert_true(field_from_schema_element(SchemaElement("x", type=ParquetType.BOOLEAN)).nullable)


def test_field_timestamps() raises:
    var units: List[Int] = [LOGICAL_TS_UNIT_MILLIS, LOGICAL_TS_UNIT_MICROS]
    for k in range(3):
        var utc: Optional[Bool] = None
        if k == 0:
            utc = True
        elif k == 1:
            utc = False
        var e = SchemaElement("t", type=ParquetType.INT64, logical_timestamp_unit=units[k % 2], logical_timestamp_is_utc=utc)
        var f = field_from_schema_element(e)
        assert_true(f.arrow_type.is_timestamp())
        assert_equal(f._tz, String("UTC") if k == 0 else String(""))


def test_field_decimal_precision_from_the_backing_width() raises:
    """A DECIMAL without a declared precision gets the largest the backing
    width holds; a scale past the precision is cut to it."""
    var dec = CONVERTED_TYPE_DECIMAL
    var cases = List[Tuple[Int, Int, Int]]()  # (physical, type_length, precision)
    cases.append((1, 0, 9))  # INT32
    cases.append((2, 0, 18))  # INT64
    cases.append((7, 16, 38))
    cases.append((7, 20, 38))
    cases.append((7, 8, 18))
    cases.append((7, 4, 9))
    cases.append((7, 3, 5))  # (3 * 8 - 1) // 4
    cases.append((7, 1, 1))
    cases.append((7, 0, 38))  # no type_length
    for i in range(len(cases)):
        var c = cases[i]
        var tl: Optional[Int] = None
        if c[1] > 0:
            tl = c[1]
        var e = SchemaElement("d", type=ParquetType(UInt8(c[0])), type_length=tl, converted_type=dec, scale=40)
        var f = field_from_schema_element(e)
        _same(f.arrow_type, ArrowType.DECIMAL128, "decimal")
        assert_equal(f.decimal_precision, c[2], "case " + String(i))
        assert_equal(f.decimal_scale, c[2], "scale cut to precision")
    var given = SchemaElement("d", type=ParquetType.INT64, converted_type=dec, scale=3, precision=10)
    var g = field_from_schema_element(given)
    assert_equal(g.decimal_precision, 10)
    assert_equal(g.decimal_scale, 3)


def test_flba_schema_info() raises:
    var none = flba_schema_info(SchemaElement("x"))
    assert_equal(none[0], 0)
    assert_equal(none[1], -1)
    assert_equal(none[2], 0)
    assert_equal(none[3], 0)
    var full = flba_schema_info(SchemaElement("x", type_length=16, converted_type=5, scale=2, precision=30))
    assert_equal(full[0], 16)
    assert_equal(full[1], 5)
    assert_equal(full[2], 2)
    assert_equal(full[3], 30)


# --- bulk bit-set and list copies --------------------------------------------


def test_set_bits_bulk_every_shape() raises:
    """Against a bit-by-bit reference: an empty run, a run inside one byte,
    byte-aligned and unaligned starts and ends, with and without whole
    interior bytes."""
    var cases: List[Int] = [3, 0, 2, 3, 3, 13, 5, 20, 0, 16, 8, 9, 1, 8, 7, 1, 0, 40]
    for c in range(0, len(cases), 2):
        var start = cases[c]
        var nbits = cases[c + 1]
        var buf = List[UInt8](length=8, fill=0)
        buf[0] = UInt8(0x01)  # a bit outside the run stays set
        _set_bits_bulk(buf.unsafe_ptr(), start, nbits)
        for bit in range(64):
            var want = (start <= bit and bit < start + nbits) or bit == 0
            var got = ((Int(buf[bit >> 3]) >> (bit & 7)) & 1) == 1
            assert_equal(got, want, "start " + String(start) + " n " + String(nbits) + " bit " + String(bit))


def test_list_copies() raises:
    var i32: List[Int32] = [Int32(-1), Int32(2), Int32(2147483647)]
    var a = _list_to_int32_array(i32)
    assert_equal(a.length, 3)
    assert_equal(a.get(2), Int32(2147483647))
    assert_equal(_list_to_int32_array_from_values(i32).get(0), Int32(-1))
    assert_equal(_list_to_int32_array(List[Int32]()).length, 0)
    var i64: List[Int64] = [Int64(-9), Int64(1) << 50]
    assert_equal(_list_to_int64_array_from_values(i64).get(1), Int64(1) << 50)
    assert_equal(_list_to_int64_array_from_values(List[Int64]()).length, 0)
    var f32: List[Float32] = [Float32(0.5)]
    assert_equal(_list_to_float32_array_from_values(f32).get(0), Float32(0.5))
    assert_equal(_list_to_float32_array_from_values(List[Float32]()).length, 0)
    var f64: List[Float64] = [Float64(-2.5), Float64(3)]
    assert_equal(_list_to_float64_array_from_values(f64).get(1), Float64(3))
    assert_equal(_list_to_float64_array_from_values(List[Float64]()).length, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
