# =============================================================================
# test_typed_schema_tags.mojo: the column-type tag tables of typed_schema.
#
# Every function here maps a tag to another
# value through a chain of `if t == X: return Y` arms. Each test walks every
# arm with the value the module's own table (its header comments, the Arrow
# type it documents, the runtime rule it mirrors) says it must return, plus at
# least one tag outside every arm, so a swapped, dropped or merged arm reads a
# wrong value here.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.typed_schema import (
    TYPE_UNKNOWN, TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64,
    TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64,
    TYPE_FLOAT32, TYPE_FLOAT64, TYPE_BOOL, TYPE_STRING,
    TYPE_DATE32, TYPE_DATE64, TYPE_TIMESTAMP, TYPE_DECIMAL128,
    TYPE_STRUCT, TYPE_MAP,
    Int8Col, Int16Col, Int32Col, Int64Col, UInt8Col, UInt16Col, UInt32Col,
    UInt64Col, Float32Col, Float64Col, BoolCol, StringCol, Date32Col,
    Date64Col, TimestampCol, Decimal128Col, StructCol, MapCol,
    SchemaDescriptor,
    type_name, arrow_type_of, _tag_of_arrow_type, infer_binary_out_type,
)


def test_tag_codes_and_marker_aliases() raises:
    """The tag codes are the documented small Ints and each `*Col` marker is
    its tag: a user schema written with markers and one written with tags
    must be the same descriptor."""
    assert_equal(TYPE_UNKNOWN, -1)
    assert_equal(TYPE_INT8, 0)
    assert_equal(TYPE_DECIMAL128, 15)
    assert_equal(TYPE_STRUCT, 16)
    assert_equal(TYPE_MAP, 17)
    assert_equal(Int8Col, TYPE_INT8)
    assert_equal(Int16Col, TYPE_INT16)
    assert_equal(Int32Col, TYPE_INT32)
    assert_equal(Int64Col, TYPE_INT64)
    assert_equal(UInt8Col, TYPE_UINT8)
    assert_equal(UInt16Col, TYPE_UINT16)
    assert_equal(UInt32Col, TYPE_UINT32)
    assert_equal(UInt64Col, TYPE_UINT64)
    assert_equal(Float32Col, TYPE_FLOAT32)
    assert_equal(Float64Col, TYPE_FLOAT64)
    assert_equal(BoolCol, TYPE_BOOL)
    assert_equal(StringCol, TYPE_STRING)
    assert_equal(Date32Col, TYPE_DATE32)
    assert_equal(Date64Col, TYPE_DATE64)
    assert_equal(TimestampCol, TYPE_TIMESTAMP)
    assert_equal(Decimal128Col, TYPE_DECIMAL128)
    assert_equal(StructCol, TYPE_STRUCT)
    assert_equal(MapCol, TYPE_MAP)


def test_type_name_every_tag() raises:
    """`type_name` is what a schema-mismatch error prints: each tag has its
    own name (BOOL, STRING, STRUCT and MAP print their marker name), and a
    code outside the table prints `Unknown`."""
    assert_equal(type_name(TYPE_INT8), "Int8")
    assert_equal(type_name(TYPE_INT16), "Int16")
    assert_equal(type_name(TYPE_INT32), "Int32")
    assert_equal(type_name(TYPE_INT64), "Int64")
    assert_equal(type_name(TYPE_UINT8), "UInt8")
    assert_equal(type_name(TYPE_UINT16), "UInt16")
    assert_equal(type_name(TYPE_UINT32), "UInt32")
    assert_equal(type_name(TYPE_UINT64), "UInt64")
    assert_equal(type_name(TYPE_FLOAT32), "Float32")
    assert_equal(type_name(TYPE_FLOAT64), "Float64")
    assert_equal(type_name(TYPE_BOOL), "BoolCol")
    assert_equal(type_name(TYPE_STRING), "StringCol")
    assert_equal(type_name(TYPE_DATE32), "Date32")
    assert_equal(type_name(TYPE_DATE64), "Date64")
    assert_equal(type_name(TYPE_TIMESTAMP), "Timestamp")
    assert_equal(type_name(TYPE_DECIMAL128), "Decimal128")
    assert_equal(type_name(TYPE_STRUCT), "StructCol")
    assert_equal(type_name(TYPE_MAP), "MapCol")
    assert_equal(type_name(TYPE_UNKNOWN), "Unknown")
    assert_equal(type_name(18), "Unknown")


def test_arrow_type_of_every_tag() raises:
    """Each tag's Arrow type for the footer handshake. The date/time tags map
    to their storage integer (DATE32 -> INT32; DATE64 and TIMESTAMP -> INT64),
    DECIMAL128 to the true DECIMAL128, STRUCT and MAP to theirs, and a code
    outside the table to INT64."""
    assert_true(arrow_type_of(TYPE_INT8) == ArrowType.INT8)
    assert_true(arrow_type_of(TYPE_INT16) == ArrowType.INT16)
    assert_true(arrow_type_of(TYPE_INT32) == ArrowType.INT32)
    assert_true(arrow_type_of(TYPE_INT64) == ArrowType.INT64)
    assert_true(arrow_type_of(TYPE_UINT8) == ArrowType.UINT8)
    assert_true(arrow_type_of(TYPE_UINT16) == ArrowType.UINT16)
    assert_true(arrow_type_of(TYPE_UINT32) == ArrowType.UINT32)
    assert_true(arrow_type_of(TYPE_UINT64) == ArrowType.UINT64)
    assert_true(arrow_type_of(TYPE_FLOAT32) == ArrowType.FLOAT32)
    assert_true(arrow_type_of(TYPE_FLOAT64) == ArrowType.FLOAT64)
    assert_true(arrow_type_of(TYPE_BOOL) == ArrowType.BOOL)
    assert_true(arrow_type_of(TYPE_STRING) == ArrowType.STRING)
    assert_true(arrow_type_of(TYPE_DATE32) == ArrowType.INT32)
    assert_true(arrow_type_of(TYPE_DATE64) == ArrowType.INT64)
    assert_true(arrow_type_of(TYPE_TIMESTAMP) == ArrowType.INT64)
    assert_true(arrow_type_of(TYPE_DECIMAL128) == ArrowType.DECIMAL128)
    assert_true(arrow_type_of(TYPE_STRUCT) == ArrowType.STRUCT)
    assert_true(arrow_type_of(TYPE_MAP) == ArrowType.MAP)
    assert_true(arrow_type_of(TYPE_UNKNOWN) == ArrowType.INT64)
    assert_true(arrow_type_of(18) == ArrowType.INT64)


def test_tag_of_arrow_type_every_arm() raises:
    """The inverse used for the footer-type name: the twelve primitive types
    and DECIMAL128 come back as their tag; a type with no tag of its own
    (Arrow DATE32, STRUCT, MAP, BINARY) is UNKNOWN."""
    assert_equal(_tag_of_arrow_type(ArrowType.INT8), TYPE_INT8)
    assert_equal(_tag_of_arrow_type(ArrowType.INT16), TYPE_INT16)
    assert_equal(_tag_of_arrow_type(ArrowType.INT32), TYPE_INT32)
    assert_equal(_tag_of_arrow_type(ArrowType.INT64), TYPE_INT64)
    assert_equal(_tag_of_arrow_type(ArrowType.UINT8), TYPE_UINT8)
    assert_equal(_tag_of_arrow_type(ArrowType.UINT16), TYPE_UINT16)
    assert_equal(_tag_of_arrow_type(ArrowType.UINT32), TYPE_UINT32)
    assert_equal(_tag_of_arrow_type(ArrowType.UINT64), TYPE_UINT64)
    assert_equal(_tag_of_arrow_type(ArrowType.FLOAT32), TYPE_FLOAT32)
    assert_equal(_tag_of_arrow_type(ArrowType.FLOAT64), TYPE_FLOAT64)
    assert_equal(_tag_of_arrow_type(ArrowType.BOOL), TYPE_BOOL)
    assert_equal(_tag_of_arrow_type(ArrowType.STRING), TYPE_STRING)
    assert_equal(_tag_of_arrow_type(ArrowType.DECIMAL128), TYPE_DECIMAL128)
    assert_equal(_tag_of_arrow_type(ArrowType.DATE32), TYPE_UNKNOWN)
    assert_equal(_tag_of_arrow_type(ArrowType.STRUCT), TYPE_UNKNOWN)
    assert_equal(_tag_of_arrow_type(ArrowType.MAP), TYPE_UNKNOWN)
    assert_equal(_tag_of_arrow_type(ArrowType.BINARY), TYPE_UNKNOWN)


def test_tag_arrow_round_trip_on_primitives() raises:
    """For every tag whose Arrow type is its own (not a date/time storage
    integer), the inverse gives the tag back."""
    var tags: List[Int] = [
        TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64,
        TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64,
        TYPE_FLOAT32, TYPE_FLOAT64, TYPE_BOOL, TYPE_STRING, TYPE_DECIMAL128,
    ]
    for i in range(len(tags)):
        assert_equal(_tag_of_arrow_type(arrow_type_of(tags[i])), tags[i])


def test_row_fixed_width_of_every_tag() raises:
    """The packed-row cell widths the method's docstring gives: 1 for the
    byte types and BOOL, 2, 4 (DATE32 is an i32), 8 (DATE64, TIMESTAMP and
    the STRING (offset, length) descriptor too), 16 for DECIMAL128, 0 for the
    nested tags and anything unknown."""
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_INT8), 1)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_UINT8), 1)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_BOOL), 1)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_INT16), 2)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_UINT16), 2)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_INT32), 4)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_UINT32), 4)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_FLOAT32), 4)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_DATE32), 4)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_INT64), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_UINT64), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_FLOAT64), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_DATE64), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_TIMESTAMP), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_STRING), 8)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_DECIMAL128), 16)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_STRUCT), 0)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_MAP), 0)
    assert_equal(SchemaDescriptor.row_fixed_width_of_tag(TYPE_UNKNOWN), 0)


def test_infer_binary_out_type_left_wins() raises:
    """The non-decimal BinaryOp rule: the left operand's tag, unconditionally
    (no widening, no float promotion for `/`); an UNKNOWN left is UNKNOWN."""
    assert_equal(infer_binary_out_type(TYPE_INT8, TYPE_INT16), TYPE_INT8)
    assert_equal(infer_binary_out_type(TYPE_FLOAT64, TYPE_INT64), TYPE_FLOAT64)
    assert_equal(infer_binary_out_type(TYPE_INT32, TYPE_INT32), TYPE_INT32)
    assert_equal(infer_binary_out_type(TYPE_UNKNOWN, TYPE_INT64), TYPE_UNKNOWN)
    assert_equal(infer_binary_out_type(TYPE_INT64, TYPE_UNKNOWN), TYPE_INT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
