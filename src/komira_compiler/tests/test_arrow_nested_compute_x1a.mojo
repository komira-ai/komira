# =============================================================================
# STRUCT field access — by-name and by-idx variants
# =============================================================================
#
# Extends test_arrow_nested_compute_spike.mojo with dual-variant coverage:
#
#   1. By-name variant (EXPR_STRUCT_FIELD) — untyped DF surface
#      `col("addr").field("city")`. The 4 spike tests are ported.
#   2. By-idx variant (EXPR_STRUCT_FIELD_IDX) — typed DF surface
#      `df.field["addr", "city"]`. Resolves field_idx at COMPTIME via
#      `comptime_struct_field_index[S, parent, name]`.
#   3. Nested struct chaining (both variants).
#   4. Bound-idx range-check raise (idx out of range).
#   5. _infer_expr_field STRUCT arm — projected Field metadata test.
#
# The spike test file remains in place as a regression guard for the
# original by-name surface.
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
from komira_core.plan.expr import (
    Expr,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_COL_REF,
)
from komira_core.plan.col_expr import col, ColExpr
from komira_core.plan.logical_plan import _infer_expr_field
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_core.io.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Helpers — building STRUCT columns / batches for the tests
# -----------------------------------------------------------------------------


def _make_struct_addr_column() raises -> Column[HeapRegion]:
    """STRUCT<name: Utf8, city: Utf8> Column[HeapRegion] with 4 rows.
    Rows: (Alice, NYC), (Bob, LA), (Carol, SF), (Dave, CHI)."""
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
    """1-column RecordBatch with a STRUCT column 'addr'."""
    var sb = SchemaBuilder()
    sb.add_field(Field("addr", ArrowType.STRUCT, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_make_struct_addr_column())
    return rbb.build(schema^)


def _make_nested_struct_column() raises -> Column[HeapRegion]:
    """STRUCT<name: Utf8, addr: STRUCT<city: Utf8, zip: Utf8>> with 2 rows.
    Exercises the recursive eval path (col.field.field)."""
    var names = List[String]()
    names.append(String("Alice"))
    names.append(String("Bob"))
    var name_arr = StringArray.from_strings(names)
    var name_col = Column.from_string(name_arr^)

    var cities = List[String]()
    cities.append(String("NYC"))
    cities.append(String("LA"))
    var city_arr = StringArray.from_strings(cities)
    var city_col = Column.from_string(city_arr^)

    var zips = List[String]()
    zips.append(String("10001"))
    zips.append(String("90001"))
    var zip_arr = StringArray.from_strings(zips)
    var zip_col = Column.from_string(zip_arr^)

    var inner_fields = List[String]()
    inner_fields.append(String("city"))
    inner_fields.append(String("zip"))
    var inner_sa = StructArray.from_columns_2(inner_fields, city_col^, zip_col^)
    var inner_col = inner_sa.to_column()

    var outer_fields = List[String]()
    outer_fields.append(String("name"))
    outer_fields.append(String("addr"))
    var outer_sa = StructArray.from_columns_2(outer_fields, name_col^, inner_col^)
    return outer_sa.to_column()


def _make_batch_with_nested_struct() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("person", ArrowType.STRUCT, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_make_nested_struct_column())
    return rbb.build(schema^)


# =============================================================================
# Section 1 — Ported spike tests (by-name variant, EXPR_STRUCT_FIELD)
# =============================================================================


def test_by_name_struct_field_projection() raises:
    """Spike test ported: `col("addr").field("city")` extracts city."""
    var batch = _make_batch_with_struct()
    assert_equal(batch.num_rows(), 4, "batch has 4 rows")
    var ce = col("addr").field("city")
    var expr = ce.take_expr()
    assert_equal(Int(expr.tag), Int(EXPR_STRUCT_FIELD), "tag is EXPR_STRUCT_FIELD")
    assert_true(expr.is_struct_field(), "is_struct_field()")
    assert_true(expr.struct_field_name() == String("city"), "field name 'city'")
    var result = _eval_column_expr(expr, batch)
    assert_equal(Int(result.arrow_type.type_id), Int(ArrowType.STRING.type_id), "STRING")
    assert_equal(result.length(), 4, "4 rows")
    var sa = result.as_string()
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(3) == String("CHI"), "row 3 = CHI")


def test_by_name_other_field() raises:
    """Same STRUCT, project the `name` child."""
    var batch = _make_batch_with_struct()
    var expr = col("addr").field("name").take_expr()
    var result = _eval_column_expr(expr, batch)
    assert_equal(result.length(), 4, "4 rows")
    var sa = result.as_string()
    assert_true(sa.get(0) == String("Alice"), "row 0 = Alice")
    assert_true(sa.get(2) == String("Carol"), "row 2 = Carol")


def test_by_name_missing_field_raises() raises:
    """Missing field name raises a clear error."""
    var batch = _make_batch_with_struct()
    var expr = col("addr").field("zip").take_expr()
    var raised = False
    try:
        var _r = _eval_column_expr(expr, batch)
    except e:
        raised = True
    assert_true(raised, "missing-field projection raised")


def test_by_name_copy_round_trip() raises:
    """Expr.copy preserves EXPR_STRUCT_FIELD tag + payload."""
    var expr = col("addr").field("city").take_expr()
    var cloned = expr.copy()
    assert_equal(Int(cloned.tag), Int(EXPR_STRUCT_FIELD), "copied tag")
    assert_true(cloned.struct_field_name() == String("city"), "field name")
    assert_equal(Int(cloned.struct_field_parent_ref().tag), Int(EXPR_COL_REF), "parent COL_REF")


# =============================================================================
# Section 2 — By-idx variant (EXPR_STRUCT_FIELD_IDX), explicit factory
# =============================================================================


def test_by_idx_struct_field_projection() raises:
    """Direct factory: Expr.struct_field_idx(parent, 1) extracts the city column
    (idx 1 in STRUCT<name, city>)."""
    var batch = _make_batch_with_struct()
    var parent_expr = Expr.col_ref(String("addr"))
    var expr = Expr.struct_field_idx(parent_expr^, 1)
    assert_equal(Int(expr.tag), Int(EXPR_STRUCT_FIELD_IDX), "tag is EXPR_STRUCT_FIELD_IDX")
    assert_true(expr.is_struct_field_idx(), "is_struct_field_idx()")
    assert_equal(expr.struct_field_index(), 1, "field_idx = 1")
    var result = _eval_column_expr(expr, batch)
    assert_equal(Int(result.arrow_type.type_id), Int(ArrowType.STRING.type_id), "STRING")
    assert_equal(result.length(), 4, "4 rows")
    var sa = result.as_string()
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(3) == String("CHI"), "row 3 = CHI")


def test_by_idx_first_field() raises:
    """idx 0 of STRUCT<name, city> -> name column."""
    var batch = _make_batch_with_struct()
    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, 0)
    var result = _eval_column_expr(expr, batch)
    var sa = result.as_string()
    assert_true(sa.get(0) == String("Alice"), "row 0 = Alice")
    assert_true(sa.get(2) == String("Carol"), "row 2 = Carol")


def test_by_idx_out_of_range_raises() raises:
    """idx >= num_children raises a clear error."""
    var batch = _make_batch_with_struct()
    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, 5)
    var raised = False
    try:
        var _r = _eval_column_expr(expr, batch)
    except e:
        raised = True
    assert_true(raised, "out-of-range idx raised")


def test_by_idx_negative_raises() raises:
    """Negative idx raises (the runtime safety net behind the comptime guard)."""
    var batch = _make_batch_with_struct()
    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, -1)
    var raised = False
    try:
        var _r = _eval_column_expr(expr, batch)
    except e:
        raised = True
    assert_true(raised, "negative idx raised")


def test_by_idx_copy_round_trip() raises:
    """Expr.copy preserves EXPR_STRUCT_FIELD_IDX tag + payload."""
    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, 1)
    var cloned = expr.copy()
    assert_equal(Int(cloned.tag), Int(EXPR_STRUCT_FIELD_IDX), "copied tag")
    assert_equal(cloned.struct_field_index(), 1, "field_idx preserved")
    assert_equal(Int(cloned.struct_field_idx_parent_ref().tag), Int(EXPR_COL_REF), "parent COL_REF")


# =============================================================================
# Section 3 — Nested STRUCT chaining (recursive eval works automatically)
# =============================================================================


def test_nested_struct_by_name() raises:
    """col('person').field('addr').field('city') — by-name recursion."""
    var batch = _make_batch_with_nested_struct()
    var expr = col("person").field("addr").field("city").take_expr()
    var result = _eval_column_expr(expr, batch)
    var sa = result.as_string()
    assert_equal(result.length(), 2, "2 rows")
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(1) == String("LA"), "row 1 = LA")


def test_nested_struct_by_idx() raises:
    """Expr.struct_field_idx composed (by-idx recursion)."""
    var batch = _make_batch_with_nested_struct()
    # outer STRUCT<name, addr> idx 1 -> addr; inner STRUCT<city, zip> idx 0 -> city
    var inner = Expr.struct_field_idx(Expr.col_ref(String("person"))^, 1)
    var expr = Expr.struct_field_idx(inner^, 0)
    var result = _eval_column_expr(expr, batch)
    var sa = result.as_string()
    assert_equal(result.length(), 2, "2 rows")
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")


def test_nested_struct_mixed_variants() raises:
    """Mix by-name (outer) + by-idx (inner) — verifies both arms recurse correctly."""
    var batch = _make_batch_with_nested_struct()
    # by-name outer to get addr; by-idx inner to get city (idx 0)
    var addr = Expr.struct_field(Expr.col_ref(String("person"))^, String("addr"))
    var expr = Expr.struct_field_idx(addr^, 0)
    var result = _eval_column_expr(expr, batch)
    var sa = result.as_string()
    assert_equal(result.length(), 2, "2 rows")
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(1) == String("LA"), "row 1 = LA")


# =============================================================================
# Section 4 — _infer_expr_field STRUCT arm — schema propagation tests
# =============================================================================


def test_infer_expr_field_struct_by_name() raises:
    """_infer_expr_field walks parent_field's _child_* slots for STRUCT_FIELD."""
    # Build a schema where 'addr' is a STRUCT with declared children.
    var sb = SchemaBuilder()
    var addr_field = Field("addr", ArrowType.STRUCT, nullable=True)
    addr_field.add_child("name", ArrowType.STRING, True)
    addr_field.add_child("city", ArrowType.STRING, True)
    sb.add_field(addr_field^)
    var schema = sb.build()

    # by-name lookup
    var expr = col("addr").field("city").take_expr()
    var result_field = _infer_expr_field(expr, schema)
    assert_equal(result_field.name, String("city"), "Field.name is the child name")
    assert_true(result_field.arrow_type == ArrowType.STRING, "child arrow_type STRING")
    assert_true(result_field.nullable, "child nullable propagated")


def test_infer_expr_field_struct_by_idx() raises:
    """By-idx schema arm: _child_* indexed directly."""
    var sb = SchemaBuilder()
    var addr_field = Field("addr", ArrowType.STRUCT, nullable=True)
    addr_field.add_child("name", ArrowType.STRING, True)
    addr_field.add_child("zip", ArrowType.INT32, False)
    sb.add_field(addr_field^)
    var schema = sb.build()

    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, 1)
    var result_field = _infer_expr_field(expr, schema)
    assert_equal(result_field.name, String("zip"), "child name propagated by idx")
    assert_true(result_field.arrow_type == ArrowType.INT32, "child arrow_type INT32")
    assert_true(not result_field.nullable, "child nullable propagated (False)")


def test_infer_expr_field_missing_child_returns_placeholder() raises:
    """Missing-field arm returns a NULL-typed placeholder; eval-time error is louder."""
    var sb = SchemaBuilder()
    var addr_field = Field("addr", ArrowType.STRUCT, nullable=True)
    addr_field.add_child("name", ArrowType.STRING, True)
    sb.add_field(addr_field^)
    var schema = sb.build()

    var expr = col("addr").field("nonexistent").take_expr()
    var result_field = _infer_expr_field(expr, schema)
    # The placeholder is `Field(fname, ArrowType.NULL, True)`; both schema and
    # eval arms behave consistently — eval raises later.
    assert_true(result_field.arrow_type == ArrowType.NULL, "missing-child placeholder NULL")


# =============================================================================
# Section 5 — write_to / EXPLAIN surface (cosmetic but breaks if accessor is wrong)
# =============================================================================


def test_write_to_surface_by_idx() raises:
    """The EXPLAIN string for EXPR_STRUCT_FIELD_IDX includes the idx."""
    var expr = Expr.struct_field_idx(Expr.col_ref(String("addr"))^, 1)
    var s = String("")
    expr.write_to(s)
    # The format is StructFieldIdx(<parent>, #<idx>) — assert idx token present.
    assert_true("#1" in s, "EXPLAIN surface mentions #1")
    assert_true("StructFieldIdx" in s, "EXPLAIN surface labels variant")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
