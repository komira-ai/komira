# =============================================================================
# `cd_grouped_fold.fold_grouped_string_minmax_over_batch`: the grouped
# all-MIN/MAX-over-STRING fold.
#
# What each part proves:
#
#   * VALUES. Per group, MIN and MAX in byte order over a nullable STRING and
#     a LARGE_STRING input, with NULL inputs skipped, a group whose inputs are
#     all NULL emitting NULL, and the first value replaced in both directions;
#     a NULL key forms ONE group read back as NULL, over STRING, INT64 and
#     INT32 keys; an INT key is emitted INT64.
#   * THE TWO WITNESSES. Every call moves the arming count, including a
#     decline; only a call that passed every decline moves the row-work
#     count. A numeric MIN declines without touching a row.
#   * EVERY DECLINE, each by its own reason.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AggExpr, AGG_MAX, AGG_MIN, AGG_SUM
from komira_plan_expr.expr import BIN_ADD, Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_driver_witness import (
    agg_str_minmax_fold_calls,
    agg_str_minmax_fold_row_passes,
)
from komira_dispatch_agg_folds.cd_grouped_fold import (
    _CD_FOLD_MAX_ROWS,
    fold_grouped_string_minmax_over_batch,
)


# =============================================================================
# Fixture
# =============================================================================


def _str(imm v: List[String], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings_with_validity(v, ok))


def _i64(imm v: List[Int64], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(v))
    for i in range(len(v)):
        a.set(i, v[i])
        if not ok[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


def _i32(imm v: List[Int32], imm ok: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int32].allocate_nullable(len(v))
    for i in range(len(v)):
        a.set(i, v[i])
        if not ok[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int32](a^)


def _fixture() raises -> RecordBatch:
    """Seven rows, keys in three types, values in two widths, and a FLOAT64
    column `f` (0..6) that no fold here admits as a key.

    row | ks   | ki64 | ki32 | s      | ls     | n
      0 | a    | 1    | 1    | 'm'    | 'm'    | 5
      1 | NULL | NULL | 1    | 'q'    | 'q'    | 6
      2 | a    | 1    | 2    | 'c'    | NULL   | 7
      3 | b    | 2    | 2    | NULL   | 'x'    | 8
      4 | a    | 1    | 1    | 'z'    | 'b'    | 9
      5 | NULL | NULL | 2    | 'k'    | 'k'    | 1
      6 | b    | 2    | 1    | NULL   | NULL   | 2

    By `ks`: a -> min 'c' max 'z'; NULL -> min 'k' max 'q'; b -> NULL/NULL.
    By `ks` over `ls`: a -> min 'b' max 'm'; NULL -> 'k'/'q'; b -> 'x'/'x'.
    By `ki32` over `s`: 1 -> min 'm' max 'z'; 2 -> min 'c' max 'k'."""
    var ks: List[String] = [String("a"), String(""), String("a"), String("b"), String("a"), String(""), String("b")]
    var ksok: List[Bool] = [True, False, True, True, True, False, True]
    var k64: List[Int64] = [1, 1, 1, 2, 1, 2, 2]
    var k32: List[Int32] = [1, 1, 2, 2, 1, 2, 1]
    var s: List[String] = [String("m"), String("q"), String("c"), String(""), String("z"), String("k"), String("")]
    var sok: List[Bool] = [True, True, True, False, True, True, False]
    var ls: List[String] = [String("m"), String("q"), String(""), String("x"), String("b"), String("k"), String("")]
    var lsok: List[Bool] = [True, True, False, True, True, True, False]
    var n: List[Int64] = [5, 6, 7, 8, 9, 1, 2]
    var all7: List[Bool] = [True, True, True, True, True, True, True]
    var rbb = RecordBatchBuilder.with_capacity(6)
    var sb = SchemaBuilder()
    rbb.add_column(_str(ks, ksok))
    sb.add_field(Field(String("ks"), ArrowType.STRING, True))
    rbb.add_column(_i64(k64, ksok))
    sb.add_field(Field(String("ki64"), ArrowType.INT64, True))
    rbb.add_column(_i32(k32, all7))
    sb.add_field(Field(String("ki32"), ArrowType.INT32, True))
    rbb.add_column(_str(s, sok))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    rbb.add_column(Column.from_large_string(LargeStringArray.from_strings_with_validity(ls, lsok)))
    sb.add_field(Field(String("ls"), ArrowType.LARGE_STRING, True))
    rbb.add_column(_i64(n, all7))
    sb.add_field(Field(String("n"), ArrowType.INT64, True))
    var f = PrimitiveArray[DType.float64].allocate(7)
    for i in range(7):
        f._typed_ptr_mut()[i] = Float64(i)
    rbb.add_column(Column.from_primitive[DType.float64](f^))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    return rbb.build(sb.build())


def _agg(key: String, var aggs: AggExprArray, imm schema: Schema) raises -> AggregateData:
    var k = ExprArray()
    if key.byte_length() > 0:
        k.append(Expr.col_ref(key))
    var child = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, schema.copy())
    return AggregateData(k^, aggs^, child^)


def _mm(func: UInt8, col: String, name: Optional[String]) raises -> AggExpr:
    return AggExpr(func, Optional[Expr](Expr.col_ref(col)), name)


def _min_max(col: String) raises -> AggExprArray:
    var a = AggExprArray()
    a.append(_mm(AGG_MIN, col, Optional[String](String("lo"))))
    a.append(_mm(AGG_MAX, col, Optional[String](None)))
    return a^


def _serve(imm ad: AggregateData, imm batch: RecordBatch) raises -> RecordBatch:
    var o = fold_grouped_string_minmax_over_batch(ad, batch)
    assert_true(o.__bool__(), "the fold declined a shape it serves")
    return o.take()


def _cell(imm out: RecordBatch, c: Int, r: Int) raises -> String:
    var sa = out.column_as_string(c)
    if sa.is_null(r):
        return String("<NULL>")
    return sa.get(r)


# =============================================================================
# Values
# =============================================================================


def test_string_key_min_max_with_null_key_and_all_null_group() raises:
    """By the STRING key over `s`: a -> 'c'/'z', NULL -> 'k'/'q', b -> NULL/
    NULL, in first-occurrence order; the NULL key reads back NULL; the
    aliased MIN is named `lo` and the unaliased MAX `minmax_1`; the value
    columns are nullable. Catches the MIN arm comparing with `>`, the NULL
    input skip removed (b would read ''), and the NULL key group dropped."""
    var batch = _fixture()
    var out = _serve(_agg(String("ks"), _min_max(String("s")), batch.schema), batch)
    assert_equal(out.num_rows(), 3)
    assert_equal(_cell(out, 0, 0), "a")
    assert_equal(_cell(out, 0, 1), "<NULL>")
    assert_equal(_cell(out, 0, 2), "b")
    assert_equal(_cell(out, 1, 0), "c")
    assert_equal(_cell(out, 2, 0), "z")
    assert_equal(_cell(out, 1, 1), "k")
    assert_equal(_cell(out, 2, 1), "q")
    assert_equal(_cell(out, 1, 2), "<NULL>")
    assert_equal(_cell(out, 2, 2), "<NULL>")
    assert_equal(out.schema.field_name(1), "lo")
    assert_equal(out.schema.field_name(2), "minmax_1")
    assert_true(out.schema.field_at_unchecked(0).nullable)
    assert_true(out.schema.field_at_unchecked(1).nullable)


def test_large_string_input_is_read_through_the_string_reader() raises:
    """The same keys over the LARGE_STRING `ls`: a -> 'b'/'m', NULL ->
    'k'/'q', b -> 'x'/'x'. Catches the LARGE_STRING admission removed (the
    fold would decline) or a reader that loses its validity."""
    var batch = _fixture()
    var out = _serve(_agg(String("ks"), _min_max(String("ls")), batch.schema), batch)
    assert_equal(_cell(out, 1, 0), "b")
    assert_equal(_cell(out, 2, 0), "m")
    assert_equal(_cell(out, 1, 2), "x")
    assert_equal(_cell(out, 2, 2), "x")


def test_int64_key_with_nulls_emits_a_nullable_int64_key() raises:
    """The INT64 key with NULL rows: groups 1, NULL, 2 with the NULL group
    read back NULL and the key field nullable. Catches the INT key's NULL
    rows merged into the group their data word names (1 and 2)."""
    var batch = _fixture()
    var out = _serve(_agg(String("ki64"), _min_max(String("s")), batch.schema), batch)
    assert_equal(out.num_rows(), 3)
    var k = out.column_as_primitive_int64(0)
    assert_equal(Int(k.get(0)), 1)
    assert_true(k.is_null(1))
    assert_equal(Int(k.get(2)), 2)
    assert_true(out.schema.field_at_unchecked(0).nullable)
    assert_equal(_cell(out, 1, 1), "k")


def test_int32_key_without_nulls_is_widened_and_not_nullable() raises:
    """The null-free INT32 key: groups 1 and 2, emitted INT64 and not
    nullable; 1 -> 'm'/'z', 2 -> 'c'/'k'. Catches validity emitted for a
    null-free key."""
    var batch = _fixture()
    var out = _serve(_agg(String("ki32"), _min_max(String("s")), batch.schema), batch)
    assert_equal(out.num_rows(), 2)
    assert_true(out.column_arrow_type(0) == ArrowType.INT64)
    assert_false(out.schema.field_at_unchecked(0).nullable)
    assert_equal(Int(out.column_as_primitive_int64(0).get(1)), 2)
    assert_equal(_cell(out, 1, 0), "m")
    assert_equal(_cell(out, 2, 0), "z")
    assert_equal(_cell(out, 1, 1), "c")
    assert_equal(_cell(out, 2, 1), "k")


# =============================================================================
# The witnesses and the declines
# =============================================================================


def _declines(imm ad: AggregateData, imm batch: RecordBatch, why: String) raises:
    var c0 = agg_str_minmax_fold_calls()
    var r0 = agg_str_minmax_fold_row_passes()
    assert_false(fold_grouped_string_minmax_over_batch(ad, batch).__bool__(), why)
    assert_equal(agg_str_minmax_fold_calls() - c0, 1, why + ": a call is armed")
    assert_equal(agg_str_minmax_fold_row_passes() - r0, 0, why + ": no row work")


def test_a_served_call_moves_both_witnesses() raises:
    """A served call moves the arming count and the row-work count by one
    each. Catches the work witness removed from the serving path."""
    var batch = _fixture()
    var c0 = agg_str_minmax_fold_calls()
    var r0 = agg_str_minmax_fold_row_passes()
    _ = fold_grouped_string_minmax_over_batch(_agg(String("ks"), _min_max(String("s")), batch.schema), batch)
    assert_equal(agg_str_minmax_fold_calls() - c0, 1)
    assert_equal(agg_str_minmax_fold_row_passes() - r0, 1)


def test_every_decline_is_cheap_and_named() raises:
    """No key; no aggregate; above the row ceiling; a computed key; a missing
    key; a FLOAT key; a SUM; a MIN without input; a computed input; a missing
    input; a NUMERIC input. Each returns None, moves the arming count and
    leaves the row-work count alone. Catches the work witness moved above a
    decline and any guard removed."""
    var batch = _fixture()
    var s = batch.schema.copy()
    _declines(_agg(String(""), _min_max(String("s")), s), batch, "no key")
    _declines(_agg(String("ks"), AggExprArray(), s), batch, "no aggregate")
    _declines(_agg(String("ks"), _min_max(String("s")), s), RecordBatch.count_only(_CD_FOLD_MAX_ROWS + 1), "above the ceiling")
    var ck = ExprArray()
    ck.append(Expr.binary(BIN_ADD, Expr.col_ref(String("n")), Expr.col_ref(String("n"))))
    _declines(AggregateData(ck^, _min_max(String("s")), LogicalPlan.scan(String("t"), SOURCE_PARQUET, s.copy())), batch, "computed key")
    _declines(_agg(String("nope"), _min_max(String("s")), s), batch, "missing key")
    _declines(_agg(String("f"), _min_max(String("s")), s), batch, "float key")
    var sum = AggExprArray()
    sum.append(AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref(String("n"))), Optional[String](None)))
    _declines(_agg(String("ks"), sum^, s), batch, "a SUM")
    var bare = AggExprArray()
    bare.append(AggExpr(AGG_MIN, Optional[Expr](None), Optional[String](None)))
    _declines(_agg(String("ks"), bare^, s), batch, "MIN without input")
    var comp = AggExprArray()
    comp.append(AggExpr(AGG_MAX, Optional[Expr](Expr.binary(BIN_ADD, Expr.col_ref(String("n")), Expr.col_ref(String("n")))), Optional[String](None)))
    _declines(_agg(String("ks"), comp^, s), batch, "computed input")
    _declines(_agg(String("ks"), _min_max(String("nope")), s), batch, "missing input")
    _declines(_agg(String("ks"), _min_max(String("n")), s), batch, "numeric input")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
