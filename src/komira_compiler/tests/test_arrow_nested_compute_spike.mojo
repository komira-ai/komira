# =============================================================================
# STRUCT field access — the minimal end-to-end case
# =============================================================================
#
# Validates end-to-end that EXPR_STRUCT_FIELD works on the dataplane.
#
# Spike scope (minimum viable end-to-end):
#   1. SDK surface: `col("addr").field("city")` returns a ColExpr.
#   2. EXPR_STRUCT_FIELD tag + StructFieldData payload in expr.mojo.
#   3. Compiler eval arm in compiler_eval_column._eval_column_expr that
#      walks a STRUCT Column's _children / _field_names and returns the
#      child column matching the field name.
#   4. One end-to-end test: build a 4-row STRUCT<name: Utf8, city: Utf8>
#      column, project `.field("city")`, assert the result strings.
#
# Goal: prove the architectural pattern; the by-idx variant and MAP lookup
# have their own test files.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    StringArray,
    StructArray,
)
from komira_core.plan.expr import Expr, EXPR_STRUCT_FIELD
from komira_core.plan.col_expr import col, ColExpr
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_core.io.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _make_struct_addr_column() raises -> Column[HeapRegion]:
    """Build a STRUCT<name: Utf8, city: Utf8> Column[HeapRegion] with 4 rows.

    Rows: (Alice, NYC), (Bob, LA), (Carol, SF), (Dave, CHI).
    Mirrors the STRUCT column round-trip construction.
    """
    var names = List[String]()
    names.append(String("Alice"))
    names.append(String("Bob"))
    names.append(String("Carol"))
    names.append(String("Dave"))
    var name_arr = StringArray.from_strings(names)
    var name_col = Column.from_string(name_arr^)

    var cities = List[String]()
    cities.append(String("NYC"))
    cities.append(String("LA"))
    cities.append(String("SF"))
    cities.append(String("CHI"))
    var city_arr = StringArray.from_strings(cities)
    var city_col = Column.from_string(city_arr^)

    var field_names = List[String]()
    field_names.append(String("name"))
    field_names.append(String("city"))

    var sa = StructArray.from_columns_2(field_names, name_col^, city_col^)
    return sa.to_column()


def _make_batch_with_struct() raises -> RecordBatch:
    """A 1-column RecordBatch where the single column is a STRUCT.

    For the spike, schema metadata for STRUCT field types is best-effort:
    Field carries the STRUCT ArrowType tag; the child columns ride on the
    Column's `_children` slot at runtime. Productionization will pipe the
    child Field metadata through `Field._child_*` slots.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("addr", ArrowType.STRUCT, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_make_struct_addr_column())
    return rbb.build(schema^)


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_spike_struct_field_projection() raises:
    """The marquee spike test: `df.col("addr").field("city")` extracts
    the city column out of the addr STRUCT.

    This validates: ColExpr.field → Expr.struct_field → EXPR_STRUCT_FIELD
    tag → _eval_column_expr dispatch arm → child column extraction.
    """
    var batch = _make_batch_with_struct()
    assert_equal(batch.num_rows(), 4, "batch has 4 rows")

    # SDK surface — `col("addr").field("city")`.
    var ce = col("addr").field("city")
    var expr = ce.take_expr()
    assert_equal(Int(expr.tag), Int(EXPR_STRUCT_FIELD), "tag is EXPR_STRUCT_FIELD")
    assert_true(expr.is_struct_field(), "is_struct_field()")
    assert_true(
        expr.struct_field_name() == String("city"),
        "field name is 'city'",
    )

    # Run the compiler eval arm.
    var result = _eval_column_expr(expr, batch)

    # The result should be a 4-row STRING column with city values.
    assert_equal(
        Int(result.arrow_type.type_id),
        Int(ArrowType.STRING.type_id),
        "result is STRING",
    )
    assert_equal(result.length(), 4, "result has 4 rows")

    var sa = result.as_string()
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(1) == String("LA"), "row 1 = LA")
    assert_true(sa.get(2) == String("SF"), "row 2 = SF")
    assert_true(sa.get(3) == String("CHI"), "row 3 = CHI")


def test_spike_struct_field_other_field() raises:
    """Same STRUCT, different field — extract `name`."""
    var batch = _make_batch_with_struct()

    var expr = col("addr").field("name").take_expr()
    var result = _eval_column_expr(expr, batch)

    assert_equal(
        Int(result.arrow_type.type_id),
        Int(ArrowType.STRING.type_id),
        "result is STRING",
    )
    assert_equal(result.length(), 4, "result has 4 rows")

    var sa = result.as_string()
    assert_true(sa.get(0) == String("Alice"), "row 0 = Alice")
    assert_true(sa.get(1) == String("Bob"), "row 1 = Bob")
    assert_true(sa.get(2) == String("Carol"), "row 2 = Carol")
    assert_true(sa.get(3) == String("Dave"), "row 3 = Dave")


def test_spike_struct_field_missing_field_raises() raises:
    """Asking for a non-existent field surfaces a clear error rather than
    silently returning empty / null."""
    var batch = _make_batch_with_struct()

    var expr = col("addr").field("zip").take_expr()
    var raised = False
    try:
        var _r = _eval_column_expr(expr, batch)
    except e:
        raised = True
    assert_true(raised, "missing-field projection raised")


def test_spike_struct_field_expr_copy_round_trip() raises:
    """Expr.copy must preserve EXPR_STRUCT_FIELD tag + payload (parent
    + field_name) — required for plan-tree deep-copy passes."""
    var expr = col("addr").field("city").take_expr()
    var cloned = expr.copy()
    assert_equal(Int(cloned.tag), Int(EXPR_STRUCT_FIELD), "copied tag")
    assert_true(
        cloned.struct_field_name() == String("city"),
        "copied field name",
    )
    assert_equal(
        Int(cloned.struct_field_parent_ref().tag),
        Int(0),  # EXPR_COL_REF == 0
        "copied parent is EXPR_COL_REF",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
