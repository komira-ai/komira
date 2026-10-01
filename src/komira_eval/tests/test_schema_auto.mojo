# =============================================================================
# Tests for schema_auto.mojo.
#
# Coverage:
#   - dtype_tag_for_type[T]() returns the right DT_* tag for each scalar
#   - dtype_tag_for_type returns DT_UNKNOWN for unsupported types
#   - auto_schema[RowT]() derives the right SchemaDescriptor for a 3-field
#     row, a mixed-dtype row, and an all-fields-bool row
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_eval.schema_auto import auto_schema, dtype_tag_for_type
from komira_eval.schema_descriptor import (
    SchemaDescriptor,
    DT_F32, DT_F64, DT_I8, DT_I16, DT_I32, DT_I64,
    DT_U8, DT_U16, DT_U32, DT_U64, DT_BOOL, DT_STRING,
    DT_UNKNOWN,
)


# -----------------------------------------------------------------------------
# Test row types
# -----------------------------------------------------------------------------


@fieldwise_init
struct LineItemRow(Copyable, Movable):
    var price: Float64
    var qty: Int64
    var disc: Float64


@fieldwise_init
struct MixedRow(Copyable, Movable):
    var a: Float64
    var b: Int32
    var c: Float32
    var d: Bool


@fieldwise_init
struct UIntRow(Copyable, Movable):
    var u8v: UInt8
    var u16v: UInt16
    var u32v: UInt32
    var u64v: UInt64


@fieldwise_init
struct AllBoolRow(Copyable, Movable):
    var x: Bool
    var y: Bool
    var z: Bool


# -----------------------------------------------------------------------------
# 1) dtype_tag_for_type — per-scalar dispatch
# -----------------------------------------------------------------------------


def test_dtype_tag_float() raises:
    assert_equal(dtype_tag_for_type[Float64](), DT_F64)
    assert_equal(dtype_tag_for_type[Float32](), DT_F32)


def test_dtype_tag_signed_ints() raises:
    assert_equal(dtype_tag_for_type[Int64](), DT_I64)
    assert_equal(dtype_tag_for_type[Int32](), DT_I32)
    assert_equal(dtype_tag_for_type[Int16](), DT_I16)
    assert_equal(dtype_tag_for_type[Int8](), DT_I8)


def test_dtype_tag_unsigned_ints() raises:
    assert_equal(dtype_tag_for_type[UInt64](), DT_U64)
    assert_equal(dtype_tag_for_type[UInt32](), DT_U32)
    assert_equal(dtype_tag_for_type[UInt16](), DT_U16)
    assert_equal(dtype_tag_for_type[UInt8](), DT_U8)


def test_dtype_tag_bool_string() raises:
    assert_equal(dtype_tag_for_type[Bool](), DT_BOOL)
    assert_equal(dtype_tag_for_type[String](), DT_STRING)


def test_dtype_tag_unsupported_returns_unknown() raises:
    """Types Mojo can't disambiguate (no precision/scale) report DT_UNKNOWN.
    A type the helper doesn't know about (a user struct) also reports
    DT_UNKNOWN — caller's `constrained[]` fires the compile error."""
    assert_equal(dtype_tag_for_type[LineItemRow](), DT_UNKNOWN)


# -----------------------------------------------------------------------------
# 2) auto_schema[RowT] — full schema derivation
# -----------------------------------------------------------------------------


def test_auto_schema_lineitem() raises:
    """3-field row of all-supported types → 3-column schema with the right
    names and dtype tags."""
    var s = auto_schema[LineItemRow]()
    assert_equal(s.num_cols(), 3)
    assert_equal(s.cols[0].name, String("price"))
    assert_equal(s.cols[0].dtype, DT_F64)
    assert_equal(s.cols[0].nullable, True)
    assert_equal(s.cols[1].name, String("qty"))
    assert_equal(s.cols[1].dtype, DT_I64)
    assert_equal(s.cols[2].name, String("disc"))
    assert_equal(s.cols[2].dtype, DT_F64)


def test_auto_schema_mixed() raises:
    """Mixed-dtype row exercises every accessor branch (F64/I32/F32/Bool)."""
    var s = auto_schema[MixedRow]()
    assert_equal(s.num_cols(), 4)
    assert_equal(s.cols[0].name, String("a"))
    assert_equal(s.cols[0].dtype, DT_F64)
    assert_equal(s.cols[1].name, String("b"))
    assert_equal(s.cols[1].dtype, DT_I32)
    assert_equal(s.cols[2].name, String("c"))
    assert_equal(s.cols[2].dtype, DT_F32)
    assert_equal(s.cols[3].name, String("d"))
    assert_equal(s.cols[3].dtype, DT_BOOL)


def test_auto_schema_uints() raises:
    """All four unsigned-int sizes."""
    var s = auto_schema[UIntRow]()
    assert_equal(s.num_cols(), 4)
    assert_equal(s.cols[0].dtype, DT_U8)
    assert_equal(s.cols[1].dtype, DT_U16)
    assert_equal(s.cols[2].dtype, DT_U32)
    assert_equal(s.cols[3].dtype, DT_U64)


def test_auto_schema_all_bools() raises:
    """All-bool row: 3 columns of DT_BOOL."""
    var s = auto_schema[AllBoolRow]()
    assert_equal(s.num_cols(), 3)
    for i in range(3):
        assert_equal(s.cols[i].dtype, DT_BOOL)


def test_auto_schema_field_names_match_definition_order() raises:
    """field_names() reflects the @fieldwise_init declaration order."""
    var s = auto_schema[LineItemRow]()
    var names = String("")
    for i in range(s.num_cols()):
        if i > 0:
            names += ","
        names += s.cols[i].name
    assert_equal(names, String("price,qty,disc"))


def test_auto_schema_default_nullable_true() raises:
    """Sub-slot 1 default — nullable=True for every derived column. The
    engine's first-batch validation refines
    against the parent DataFrame schema."""
    var s = auto_schema[MixedRow]()
    for i in range(s.num_cols()):
        assert_true(s.cols[i].nullable)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
