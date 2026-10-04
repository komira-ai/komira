# =============================================================================
# MAP[key] lookup tests
# =============================================================================
#
# Tests for the EXPR_MAP_GET (tag 18) expression variant.
#
#   1. Untyped DF surface — `col("metadata").get(lit("city"))`.
#   2. Per-row key (key is a column, not a literal).
#   3. Key-not-found -> NULL row.
#   4. Parent-null row -> NULL output row.
#   5. _keys_sorted = True path (same linear scan — verified
#      that the flag is informational and doesn't break eval).
#   6. INT64-valued Map.
#   7. write_to / EXPLAIN surface.
#   8. copy round-trip for EXPR_MAP_GET.
#   9. _infer_expr_field MAP_GET arm — schema arm returns the value Field.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    MapArray,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    StringArray,
)
from komira_core.plan.expr import (
    Expr,
    EXPR_MAP_GET,
    EXPR_COL_REF,
    EXPR_LITERAL,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.col_expr import col, lit
from komira_core.plan.logical_plan import _infer_expr_field
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_core.io.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Helpers — build MAP columns / batches for the tests
# -----------------------------------------------------------------------------


def _make_str_int_map_column(keys_sorted: Bool = False) raises -> Column[HeapRegion]:
    """MAP<String, Int64> Column[HeapRegion] with 4 rows:
        Row 0: {"city": 1, "zip": 10001}
        Row 1: {"city": 2, "zip": 90001}
        Row 2: {"zip": 60601}        # no 'city' -> .get("city") returns NULL
        Row 3: {"city": 4, "zip": 75001}
    """
    var maps = List[List[Tuple[String, Int]]]()

    var r0 = List[Tuple[String, Int]]()
    r0.append((String("city"), 1))
    r0.append((String("zip"), 10001))
    maps.append(r0^)

    var r1 = List[Tuple[String, Int]]()
    r1.append((String("city"), 2))
    r1.append((String("zip"), 90001))
    maps.append(r1^)

    var r2 = List[Tuple[String, Int]]()
    r2.append((String("zip"), 60601))
    maps.append(r2^)

    var r3 = List[Tuple[String, Int]]()
    r3.append((String("city"), 4))
    r3.append((String("zip"), 75001))
    maps.append(r3^)

    var ma = MapArray.from_string_int_maps(maps^)
    if keys_sorted:
        ma.keys_sorted = True
    return ma.to_column()


def _make_batch_with_map(keys_sorted: Bool = False) raises -> RecordBatch:
    """1-column RecordBatch with a MAP<String, Int64> column 'metadata'."""
    var sb = SchemaBuilder()
    sb.add_field(Field("metadata", ArrowType.MAP, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_make_str_int_map_column(keys_sorted))
    return rbb.build(schema^)


def _make_per_row_key_batch() raises -> RecordBatch:
    """2-column RecordBatch: 'metadata' MAP + 'which_key' StringArray of keys.

    Lets us test `col("metadata").get(col("which_key"))` per-row lookup.
    Row 0: get("city") on {city:1, zip:10001} -> 1
    Row 1: get("zip")  on {city:2, zip:90001} -> 90001
    Row 2: get("city") on {zip:60601}         -> NULL (no match)
    Row 3: get("zip")  on {city:4, zip:75001} -> 75001
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("metadata", ArrowType.MAP, nullable=False))
    sb.add_field(Field("which_key", ArrowType.STRING, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_make_str_int_map_column())
    var keys = List[String]()
    keys.append(String("city"))
    keys.append(String("zip"))
    keys.append(String("city"))
    keys.append(String("zip"))
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    return rbb.build(schema^)


def _make_str_to_str_map_column() raises -> Column[HeapRegion]:
    """MAP<String, String> Column[HeapRegion] with 2 rows:
        Row 0: {"city": "NYC", "state": "NY"}
        Row 1: {"city": "LA",  "state": "CA"}

    Built directly (MapArray.from_string_int_maps doesn't take string values).
    Uses Column.from_map(MapArray(...)) with hand-built keys/values columns.
    """
    var keys_list = List[String]()
    keys_list.append(String("city"))
    keys_list.append(String("state"))
    keys_list.append(String("city"))
    keys_list.append(String("state"))
    var keys_col = Column.from_string(StringArray.from_strings(keys_list))

    var vals_list = List[String]()
    vals_list.append(String("NYC"))
    vals_list.append(String("NY"))
    vals_list.append(String("LA"))
    vals_list.append(String("CA"))
    var vals_col = Column.from_string(StringArray.from_strings(vals_list))

    # offsets: [0, 2, 4] — 2 rows, each with 2 entries
    from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
    from std.sys import size_of
    comptime int32_size = size_of[Int32]()
    var off_buf = OwnedAlignedBuffer(3 * int32_size)
    off_buf.set_typed[Int32](0, Int32(0))
    off_buf.set_typed[Int32](1, Int32(2))
    off_buf.set_typed[Int32](2, Int32(4))
    off_buf.set_length(Int64(3 * int32_size))


    var ma = MapArray(
        offsets=off_buf^,
        keys=keys_col^,
        values=vals_col^,
        validity=None,
        length=2,
        null_count=0,
        keys_sorted=False,
    )
    return ma.to_column()


def _make_batch_with_strstr_map() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("metadata", ArrowType.MAP, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_make_str_to_str_map_column())
    return rbb.build(schema^)


# =============================================================================
# Section 1 — Untyped DF surface (col(...).get(lit(...)))
# =============================================================================


def test_map_get_lookup_int_value() raises:
    """col("metadata").get(lit("city")) returns INT64 column."""
    var batch = _make_batch_with_map()
    assert_equal(batch.num_rows(), 4, "batch has 4 rows")
    var ce = col("metadata").get(lit("city"))
    var expr = ce.take_expr()
    assert_equal(Int(expr.tag), Int(EXPR_MAP_GET), "tag is EXPR_MAP_GET")
    assert_true(expr.is_map_get(), "is_map_get()")
    var result = _eval_column_expr(expr, batch)
    assert_equal(Int(result.arrow_type.type_id), Int(ArrowType.INT64.type_id), "INT64")
    assert_equal(result.length(), 4, "4 rows")
    var pa = result.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 1, "row 0 = 1")
    assert_equal(Int(pa.get(1)), 2, "row 1 = 2")
    # row 2: no 'city' key — should be NULL (validity bit 0)
    assert_true(result.null_count() >= 1, "at least 1 null due to missing key")
    assert_true(result._validity.value().test(0), "row 0 valid")
    assert_true(result._validity.value().test(1), "row 1 valid")
    assert_true(not result._validity.value().test(2), "row 2 NULL (no 'city')")
    assert_true(result._validity.value().test(3), "row 3 valid")
    assert_equal(Int(pa.get(3)), 4, "row 3 = 4")


def test_map_get_string_to_string() raises:
    """col("metadata").get(lit("city")) on MAP<String, String> returns STRING."""
    var batch = _make_batch_with_strstr_map()
    var expr = col("metadata").get(lit("city")).take_expr()
    var result = _eval_column_expr(expr, batch)
    assert_equal(Int(result.arrow_type.type_id), Int(ArrowType.STRING.type_id), "STRING")
    assert_equal(result.length(), 2, "2 rows")
    var sa = result.as_string()
    assert_true(sa.get(0) == String("NYC"), "row 0 = NYC")
    assert_true(sa.get(1) == String("LA"), "row 1 = LA")


# =============================================================================
# Section 2 — Per-row key column lookup
# =============================================================================


def test_map_get_per_row_key() raises:
    """col("metadata").get(col("which_key")) — different key per row."""
    var batch = _make_per_row_key_batch()
    var expr = col("metadata").get(col("which_key")).take_expr()
    var result = _eval_column_expr(expr, batch)
    assert_equal(result.length(), 4, "4 rows")
    var pa = result.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 1, "row 0 get('city') = 1")
    assert_equal(Int(pa.get(1)), 90001, "row 1 get('zip') = 90001")
    # row 2: get('city') on {zip:60601} -> NULL
    assert_true(not result._validity.value().test(2), "row 2 NULL (no 'city')")
    assert_equal(Int(pa.get(3)), 75001, "row 3 get('zip') = 75001")


# =============================================================================
# Section 3 — keys_sorted=True path (verifies the flag doesn't break eval)
# =============================================================================


def test_map_get_keys_sorted_flag() raises:
    """keys_sorted=True path — linear scan still works (the flag is trusted)."""
    var batch = _make_batch_with_map(keys_sorted=True)
    var expr = col("metadata").get(lit("zip")).take_expr()
    var result = _eval_column_expr(expr, batch)
    var pa = result.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 10001, "row 0 zip = 10001")
    assert_equal(Int(pa.get(2)), 60601, "row 2 zip = 60601")


# =============================================================================
# Section 4 — copy / write_to / accessors
# =============================================================================


def test_map_get_copy_round_trip() raises:
    """Expr.copy preserves EXPR_MAP_GET tag + payload."""
    var expr = col("metadata").get(lit("city")).take_expr()
    var cloned = expr.copy()
    assert_equal(Int(cloned.tag), Int(EXPR_MAP_GET), "copied tag")
    assert_true(cloned.is_map_get(), "is_map_get on clone")
    assert_equal(Int(cloned.map_get_parent_ref().tag), Int(EXPR_COL_REF), "parent COL_REF")
    assert_equal(Int(cloned.map_get_key_ref().tag), Int(EXPR_LITERAL), "key LITERAL")


def test_map_get_write_to_surface() raises:
    """EXPLAIN surface: MapGet(<parent>, <key>)."""
    var expr = col("metadata").get(lit("city")).take_expr()
    var s = String("")
    expr.write_to(s)
    assert_true("MapGet" in s, "EXPLAIN labels variant")


# =============================================================================
# Section 5 — _infer_expr_field MAP_GET arm
# =============================================================================


def test_infer_expr_field_map_value_type() raises:
    """_infer_expr_field walks parent_field's _child_* slots for MAP_GET.
    Convention: MAP Field has 2 direct children (key, value); output is child[1]."""
    var sb = SchemaBuilder()
    var meta = Field("metadata", ArrowType.MAP, nullable=True)
    meta.add_child("key", ArrowType.STRING, False)
    meta.add_child("value", ArrowType.INT64, True)
    sb.add_field(meta^)
    var schema = sb.build()

    var expr = col("metadata").get(lit("city")).take_expr()
    var result_field = _infer_expr_field(expr, schema)
    assert_equal(result_field.name, String("value"), "Field.name is 'value'")
    assert_true(result_field.arrow_type == ArrowType.INT64, "value arrow_type INT64")
    assert_true(result_field.nullable, "value nullable propagated")


def test_infer_expr_field_non_map_returns_null_placeholder() raises:
    """Non-MAP parent yields a NULL placeholder Field — eval-time raises with
    a clearer error."""
    var sb = SchemaBuilder()
    sb.add_field(Field("metadata", ArrowType.STRING, nullable=True))
    var schema = sb.build()

    var expr = col("metadata").get(lit("city")).take_expr()
    var result_field = _infer_expr_field(expr, schema)
    assert_true(result_field.arrow_type == ArrowType.NULL, "placeholder NULL")


# =============================================================================
# Section 6 — direct Expr.map_get factory
# =============================================================================


def test_direct_factory_emit() raises:
    """Direct Expr.map_get(parent, key) factory — what the typed-DF surface emits."""
    var batch = _make_batch_with_map()
    var parent_expr = Expr.col_ref(String("metadata"))
    var key_expr = Expr.literal(ScalarValue.from_string(String("city")))
    var expr = Expr.map_get(parent_expr^, key_expr^)
    assert_equal(Int(expr.tag), Int(EXPR_MAP_GET), "tag EXPR_MAP_GET")
    var result = _eval_column_expr(expr, batch)
    var pa = result.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 1, "row 0 = 1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
