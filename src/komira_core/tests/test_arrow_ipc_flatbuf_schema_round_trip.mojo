# =============================================================================
# test_arrow_ipc_flatbuf_schema_round_trip.mojo — Schema / Field flatbuffers
# =============================================================================
#
# Validates the FlatbufWriter table primitives + Type union arms +
# Schema/Field writer.
#
# Coverage:
#   1. Single-field Int Schema round-trip.
#   2. Single-field FloatingPoint Schema round-trip.
#   3. Single-field Utf8 Schema round-trip (tag-only Type).
#   4. Single-field Bool Schema round-trip.
#   5. Multi-field Schema (Int + Float + Utf8 + Bool).
#   6. Nullability + name preservation.
#   7. Endianness flag preservation.
#
# The remaining Type union arms (Date / Time / Timestamp / Duration /
# Interval / List / etc.) are covered by
# `test_arrow_ipc_flatbuf_type_arms_fanout.mojo`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    write_type_int,
    write_type_floating_point,
    write_type_utf8,
    write_type_bool,
    write_field,
    write_schema,
    read_schema,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    TYPE_UTF8,
    TYPE_BOOL,
    PRECISION_SINGLE,
    PRECISION_DOUBLE,
    ENDIANNESS_LITTLE,
)


# ---------------------------------------------------------------------------
# Single-field Schema round-trips
# ---------------------------------------------------------------------------


def test_schema_single_int64_field() raises:
    """Schema(endianness=LE, fields=[Field("a", nullable=False, Int(64,signed))])."""
    var w = FlatbufWriter(1024)
    var type_pos = write_type_int(w, 64, True)
    var field_pos = write_field(w, "a", False, TYPE_INT, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var schema_decoded_pos = reader.read_root_offset()
    var sd = read_schema(reader, schema_decoded_pos)

    assert_equal(sd.endianness, ENDIANNESS_LITTLE)
    assert_equal(len(sd.fields), 1)
    ref f0 = sd.fields[0]
    assert_equal(String(f0.name), String("a"))
    assert_false(f0.nullable)
    assert_equal(f0.type_tag, TYPE_INT)


def test_schema_single_float64_field() raises:
    """Schema with one Float64 field."""
    var w = FlatbufWriter(1024)
    var type_pos = write_type_floating_point(w, Int(PRECISION_DOUBLE))
    var field_pos = write_field(w, "x", True, TYPE_FLOATING_POINT, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var schema_decoded_pos = reader.read_root_offset()
    var sd = read_schema(reader, schema_decoded_pos)

    assert_equal(len(sd.fields), 1)
    ref f0 = sd.fields[0]
    assert_equal(String(f0.name), String("x"))
    assert_true(f0.nullable)
    assert_equal(f0.type_tag, TYPE_FLOATING_POINT)


def test_schema_single_utf8_field() raises:
    """Schema with one Utf8 (tag-only) field."""
    var w = FlatbufWriter(1024)
    var type_pos = write_type_utf8(w)
    var field_pos = write_field(w, "s", True, TYPE_UTF8, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(len(sd.fields), 1)
    assert_equal(sd.fields[0].type_tag, TYPE_UTF8)
    assert_equal(String(sd.fields[0].name), String("s"))


def test_schema_single_bool_field() raises:
    """Schema with one Bool (tag-only) field."""
    var w = FlatbufWriter(1024)
    var type_pos = write_type_bool(w)
    var field_pos = write_field(w, "b", False, TYPE_BOOL, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(len(sd.fields), 1)
    assert_equal(sd.fields[0].type_tag, TYPE_BOOL)


# ---------------------------------------------------------------------------
# Multi-field Schema
# ---------------------------------------------------------------------------


def test_schema_multi_field_int_float_utf8_bool() raises:
    """4-field Schema covering the Int / FloatingPoint / Utf8 / Bool Type arms."""
    var w = FlatbufWriter(2048)
    var t0 = write_type_int(w, 64, True)
    var t1 = write_type_floating_point(w, Int(PRECISION_DOUBLE))
    var t2 = write_type_utf8(w)
    var t3 = write_type_bool(w)
    var f0 = write_field(w, "i", False, TYPE_INT, t0)
    var f1 = write_field(w, "f", True, TYPE_FLOATING_POINT, t1)
    var f2 = write_field(w, "s", True, TYPE_UTF8, t2)
    var f3 = write_field(w, "b", False, TYPE_BOOL, t3)
    var fields = List[Int]()
    fields.append(f0)
    fields.append(f1)
    fields.append(f2)
    fields.append(f3)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(len(sd.fields), 4)
    assert_equal(sd.fields[0].type_tag, TYPE_INT)
    assert_equal(sd.fields[1].type_tag, TYPE_FLOATING_POINT)
    assert_equal(sd.fields[2].type_tag, TYPE_UTF8)
    assert_equal(sd.fields[3].type_tag, TYPE_BOOL)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_schema_single_int64_field]()
    suite.test[test_schema_single_float64_field]()
    suite.test[test_schema_single_utf8_field]()
    suite.test[test_schema_single_bool_field]()
    suite.test[test_schema_multi_field_int_float_utf8_bool]()
    suite^.run()
