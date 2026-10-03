# =============================================================================
# test_bound_schema.mojo — unit test for the BoundSchema primitive
# =============================================================================
#
# Validates `komira_arrow/bound_schema.mojo`:
#   (a) build from Schema; verify index_of("col_a") returns correct index;
#   (b) index_of("missing") raises with diagnostic;
#   (c) dtype_at(idx) returns the correct DType;
#   (d) move semantics: `var b2 = b1^` and b2 still works;
#   (e) duplicate-name schema raises at __init__;
#   (f) bounds-check on dtype_at / name_at.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.bound_schema import BoundSchema
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType


def _build_test_schema() raises -> Schema:
    """Build a 3-column schema: id (INT64), age (INT64), wage (FLOAT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("age", ArrowType.INT64, True))
    sb.add_field(Field("wage", ArrowType.FLOAT64, True))
    return sb.build()


def test_build_and_index_of() raises:
    """(a) Build from Schema; index_of returns the per-column index."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    assert_equal(bs.num_columns(), 3)
    assert_equal(bs.index_of("id"), 0)
    assert_equal(bs.index_of("age"), 1)
    assert_equal(bs.index_of("wage"), 2)


def test_index_of_missing_raises() raises:
    """(b) index_of on a missing column raises with a diagnostic listing
    known columns."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    with assert_raises(contains="no field named 'salary'"):
        _ = bs.index_of("salary")


def test_dtype_at() raises:
    """(c) dtype_at returns the correct DType per the source schema."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    assert_equal(bs.dtype_at(0), DType.int64)
    assert_equal(bs.dtype_at(1), DType.int64)
    assert_equal(bs.dtype_at(2), DType.float64)


def test_dtype_at_out_of_range_raises() raises:
    """(f) dtype_at raises on out-of-range index."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    with assert_raises(contains="out of range"):
        _ = bs.dtype_at(99)
    with assert_raises(contains="out of range"):
        _ = bs.dtype_at(-1)


def test_name_at() raises:
    """name_at returns the correct name."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    assert_equal(bs.name_at(0), String("id"))
    assert_equal(bs.name_at(1), String("age"))
    assert_equal(bs.name_at(2), String("wage"))


def test_name_at_out_of_range_raises() raises:
    """name_at raises on out-of-range index."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    with assert_raises(contains="out of range"):
        _ = bs.name_at(5)


def test_contains() raises:
    """contains returns True for known columns, False for unknown — no raise."""
    var schema = _build_test_schema()
    var bs = BoundSchema(schema)
    assert_true(bs.contains("id"))
    assert_true(bs.contains("age"))
    assert_true(bs.contains("wage"))
    assert_false(bs.contains("salary"))
    assert_false(bs.contains(""))


def test_move_semantics() raises:
    """(d) After moving a BoundSchema, the moved-to copy still works."""
    var schema = _build_test_schema()
    var b1 = BoundSchema(schema)
    var b2 = b1^                              # Move b1 into b2.
    assert_equal(b2.num_columns(), 3)
    assert_equal(b2.index_of("age"), 1)
    assert_equal(b2.dtype_at(2), DType.float64)


def test_duplicate_name_raises() raises:
    """(e) A schema with duplicate column names raises at __init__ — this is
    a real bind-time error (a Schema can't have two fields with the same
    name)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("a", ArrowType.FLOAT64, False))   # duplicate
    var schema = sb.build()
    with assert_raises(contains="duplicate column name 'a'"):
        var _bs = BoundSchema(schema)


def test_single_column_schema() raises:
    """Edge case: single-column schema is well-formed."""
    var sb = SchemaBuilder()
    sb.add_field(Field("only_col", ArrowType.INT32, True))
    var schema = sb.build()
    var bs = BoundSchema(schema)
    assert_equal(bs.num_columns(), 1)
    assert_equal(bs.index_of("only_col"), 0)
    assert_equal(bs.dtype_at(0), DType.int32)


def test_empty_schema() raises:
    """Edge case: an empty (zero-column) Schema produces an empty BoundSchema
    (no probe will ever succeed; lookup raises)."""
    var schema = Schema()
    var bs = BoundSchema(schema)
    assert_equal(bs.num_columns(), 0)
    assert_false(bs.contains("x"))
    with assert_raises(contains="no field named 'x'"):
        _ = bs.index_of("x")


def main() raises:
    test_build_and_index_of()
    test_index_of_missing_raises()
    test_dtype_at()
    test_dtype_at_out_of_range_raises()
    test_name_at()
    test_name_at_out_of_range_raises()
    test_contains()
    test_move_semantics()
    test_duplicate_name_raises()
    test_single_column_schema()
    test_empty_schema()
    print("all BoundSchema tests passed")
