# =============================================================================
# test_arrow_ipc_flatbuf_type_arms_fanout.mojo — Type union arm fan-out
# =============================================================================
#
# Validates the Type union arms beyond Int / FloatingPoint / Utf8 / Bool
# (Date / Time / Timestamp / Duration / Interval / Decimal / FixedSizeBinary /
# FixedSizeList / Map / Union + 12 tag-only arms).
#
# Tag-only arms (Null / Binary / LargeBinary / LargeUtf8 / List / LargeList /
# Struct / RunEndEncoded / BinaryView / Utf8View / ListView / LargeListView)
# are validated by Field-table round-trip with the matching type_tag — the
# tag value preserved end-to-end is sufficient signal for tag-only variants.
# Typed arms get full field round-trip coverage.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    # Tag-only writers:
    write_type_null,
    write_type_binary,
    write_type_large_binary,
    write_type_large_utf8,
    write_type_list,
    write_type_large_list,
    write_type_struct,
    write_type_run_end_encoded,
    write_type_binary_view,
    write_type_utf8_view,
    write_type_list_view,
    write_type_large_list_view,
    # Typed writers:
    write_type_decimal,
    write_type_date,
    write_type_time,
    write_type_timestamp,
    write_type_interval,
    write_type_duration,
    write_type_fixed_size_binary,
    write_type_fixed_size_list,
    write_type_map,
    write_type_union,
    # Field + Schema:
    write_field,
    write_schema,
    read_schema,
    # Typed readers:
    read_type_decimal,
    read_type_date,
    read_type_time,
    read_type_timestamp,
    read_type_interval,
    read_type_duration,
    read_type_fixed_size_binary,
    read_type_fixed_size_list,
    read_type_map,
    read_type_union,
    # Tag constants:
    TYPE_NULL,
    TYPE_BINARY,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    TYPE_LIST,
    TYPE_LARGE_LIST,
    TYPE_STRUCT_,
    TYPE_RUN_END_ENCODED,
    TYPE_BINARY_VIEW,
    TYPE_UTF8_VIEW,
    TYPE_LIST_VIEW,
    TYPE_LARGE_LIST_VIEW,
    TYPE_DECIMAL,
    TYPE_DATE,
    TYPE_TIME,
    TYPE_TIMESTAMP,
    TYPE_INTERVAL,
    TYPE_DURATION,
    TYPE_FIXED_SIZE_BINARY,
    TYPE_FIXED_SIZE_LIST,
    TYPE_MAP,
    TYPE_UNION,
    # Enums:
    DATE_UNIT_DAY,
    DATE_UNIT_MILLISECOND,
    TIME_UNIT_MICROSECOND,
    TIME_UNIT_NANOSECOND,
    INTERVAL_UNIT_MONTH_DAY_NANO,
    UNION_MODE_DENSE,
    ENDIANNESS_LITTLE,
)


# ---------------------------------------------------------------------------
# Helper: build a 1-field Schema, finalize, read back, assert tag
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Tag-only arms — tag preservation through Field round-trip
# ---------------------------------------------------------------------------


def test_tag_only_null() raises:
    """Null type tag round-trip through Schema/Field."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_null(w)
    var field_pos = write_field(w, "n", True, TYPE_NULL, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_NULL)


def test_tag_only_binary() raises:
    var w = FlatbufWriter(512)
    var type_pos = write_type_binary(w)
    var field_pos = write_field(w, "b", True, TYPE_BINARY, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_BINARY)


def test_tag_only_large_utf8() raises:
    var w = FlatbufWriter(512)
    var type_pos = write_type_large_utf8(w)
    var field_pos = write_field(w, "s", True, TYPE_LARGE_UTF8, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_LARGE_UTF8)


def test_tag_only_list() raises:
    var w = FlatbufWriter(512)
    var type_pos = write_type_list(w)
    var field_pos = write_field(w, "l", True, TYPE_LIST, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_LIST)


def test_tag_only_struct() raises:
    var w = FlatbufWriter(512)
    var type_pos = write_type_struct(w)
    var field_pos = write_field(w, "st", True, TYPE_STRUCT_, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_STRUCT_)


def test_tag_only_run_end_encoded() raises:
    """RunEndEncoded tag round-trip."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_run_end_encoded(w)
    var field_pos = write_field(w, "r", True, TYPE_RUN_END_ENCODED, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_RUN_END_ENCODED)


def test_tag_only_binary_view() raises:
    """BinaryView tag round-trip."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_binary_view(w)
    var field_pos = write_field(w, "bv", True, TYPE_BINARY_VIEW, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)
    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(sd.fields[0].type_tag, TYPE_BINARY_VIEW)


# ---------------------------------------------------------------------------
# Typed arms — full field round-trip
# ---------------------------------------------------------------------------


def test_typed_decimal_precision_scale_bit_width() raises:
    """Decimal type: precision=18, scale=4, bit_width=128 round-trip."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_decimal(w, 18, 4, 128)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var root = reader.read_root_offset()
    var dd = read_type_decimal(reader, root)
    assert_equal(dd.precision, 18)
    assert_equal(dd.scale, 4)
    assert_equal(dd.bit_width, 128)


def test_typed_decimal_256() raises:
    """Decimal256 (precision=76, scale=10, bit_width=256)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_decimal(w, 76, 10, 256)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var dd = read_type_decimal(reader, reader.read_root_offset())
    assert_equal(dd.bit_width, 256)


def test_typed_date_day_unit() raises:
    """Date32 (unit=DAY)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_date(w, DATE_UNIT_DAY)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var dd = read_type_date(reader, reader.read_root_offset())
    assert_equal(dd.unit, DATE_UNIT_DAY)


def test_typed_date_millisecond_unit() raises:
    """Date64 (unit=MILLISECOND)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_date(w, DATE_UNIT_MILLISECOND)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var dd = read_type_date(reader, reader.read_root_offset())
    assert_equal(dd.unit, DATE_UNIT_MILLISECOND)


def test_typed_time_microsecond_64() raises:
    """Time64 (unit=MICROSECOND, bit_width=64)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_time(w, TIME_UNIT_MICROSECOND, 64)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_type_time(reader, reader.read_root_offset())
    assert_equal(td.unit, TIME_UNIT_MICROSECOND)
    assert_equal(td.bit_width, 64)


def test_typed_timestamp_nano_with_tz() raises:
    """Timestamp[ns, UTC]."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_timestamp(w, TIME_UNIT_NANOSECOND, "UTC")
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_type_timestamp(reader, reader.read_root_offset())
    assert_equal(td.unit, TIME_UNIT_NANOSECOND)
    assert_equal(String(td.timezone), String("UTC"))


def test_typed_timestamp_no_tz() raises:
    """Timestamp[ns] with no timezone."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_timestamp(w, TIME_UNIT_NANOSECOND, "")
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_type_timestamp(reader, reader.read_root_offset())
    assert_equal(td.unit, TIME_UNIT_NANOSECOND)
    assert_equal(td.timezone.byte_length(), 0)


def test_typed_interval_month_day_nano() raises:
    """Interval[MONTH_DAY_NANO]."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_interval(w, INTERVAL_UNIT_MONTH_DAY_NANO)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var id = read_type_interval(reader, reader.read_root_offset())
    assert_equal(id.unit, INTERVAL_UNIT_MONTH_DAY_NANO)


def test_typed_duration_microsecond() raises:
    """Duration[MICROSECOND]."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_duration(w, TIME_UNIT_MICROSECOND)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var dd = read_type_duration(reader, reader.read_root_offset())
    assert_equal(dd.unit, TIME_UNIT_MICROSECOND)


def test_typed_fixed_size_binary_16() raises:
    """FixedSizeBinary(byte_width=16) — e.g. UUID."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_fixed_size_binary(w, 16)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var fsd = read_type_fixed_size_binary(reader, reader.read_root_offset())
    assert_equal(fsd.byte_width, 16)


def test_typed_fixed_size_list_4() raises:
    """FixedSizeList(list_size=4) — e.g. RGBA tensor row."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_fixed_size_list(w, 4)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var fld = read_type_fixed_size_list(reader, reader.read_root_offset())
    assert_equal(fld.list_size, 4)


def test_typed_map_keys_sorted_true() raises:
    """Map(keys_sorted=True)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_map(w, True)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var mtd = read_type_map(reader, reader.read_root_offset())
    assert_true(mtd.keys_sorted)


def test_typed_map_keys_sorted_false() raises:
    """Map(keys_sorted=False)."""
    var w = FlatbufWriter(512)
    var type_pos = write_type_map(w, False)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var mtd = read_type_map(reader, reader.read_root_offset())
    assert_false(mtd.keys_sorted)


def test_typed_union_dense_3_types() raises:
    """Union(DENSE, type_ids=[0, 1, 2])."""
    var w = FlatbufWriter(512)
    var type_ids = List[Int32]()
    type_ids.append(Int32(0))
    type_ids.append(Int32(1))
    type_ids.append(Int32(2))
    var type_pos = write_type_union(w, UNION_MODE_DENSE, type_ids)
    var buf = w^.finalize(type_pos)
    var reader = flatbuf_reader_over(buf)
    var ud = read_type_union(reader, reader.read_root_offset())
    assert_equal(ud.mode, UNION_MODE_DENSE)
    assert_equal(len(ud.type_ids), 3)
    assert_equal(ud.type_ids[0], Int32(0))
    assert_equal(ud.type_ids[1], Int32(1))
    assert_equal(ud.type_ids[2], Int32(2))


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    # Tag-only arms (representative sample of the 12; the rest are covered
    # by the message / tensor round-trip fixtures).
    suite.test[test_tag_only_null]()
    suite.test[test_tag_only_binary]()
    suite.test[test_tag_only_large_utf8]()
    suite.test[test_tag_only_list]()
    suite.test[test_tag_only_struct]()
    suite.test[test_tag_only_run_end_encoded]()
    suite.test[test_tag_only_binary_view]()

    # Typed arms — full field round-trip.
    suite.test[test_typed_decimal_precision_scale_bit_width]()
    suite.test[test_typed_decimal_256]()
    suite.test[test_typed_date_day_unit]()
    suite.test[test_typed_date_millisecond_unit]()
    suite.test[test_typed_time_microsecond_64]()
    suite.test[test_typed_timestamp_nano_with_tz]()
    suite.test[test_typed_timestamp_no_tz]()
    suite.test[test_typed_interval_month_day_nano]()
    suite.test[test_typed_duration_microsecond]()
    suite.test[test_typed_fixed_size_binary_16]()
    suite.test[test_typed_fixed_size_list_4]()
    suite.test[test_typed_map_keys_sorted_true]()
    suite.test[test_typed_map_keys_sorted_false]()
    suite.test[test_typed_union_dense_3_types]()

    suite^.run()
