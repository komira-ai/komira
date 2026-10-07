# =============================================================================
# `agg_mixed_cd_fold`: the three gates, the row ceiling and its lowering, the
# small helpers, and every decline of the per-batch extraction.
#
# What each part proves:
#
#   * `agg_mixed_count_distinct_servable` and `agg_mixed_offcell_candidate`:
#     each refusal on its own, each op of the admitted set reaching its own
#     operand of the op-set test, and the two MIXED shapes the candidate
#     admits (a CD beside anything; a MIN/MAX beside a plain aggregate);
#   * `mixed_offcell_servable_for_schema`: a CD, a MIN/MAX over STRING or
#     LARGE_STRING admit; a numeric MIN/MAX and a MIN/MAX over a column the
#     schema lacks do not;
#   * the ceiling: one derived number, lowered only by a positive argument
#     that is smaller (`lowered_to` replaced an environment read);
#   * the packing of a (batch, row) pair, the schema agreement used across
#     batches, the in-place byte compare in both overloads (prefix in both
#     orders, unsigned bytes), and the two column emitters with and without
#     NULLs;
#   * `_mix_extract_batch`, called directly so the declines its public
#     callers' gates already rule out are still exercised: every key, CD,
#     string and fixed-cell refusal.
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
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MAX, AGG_MEAN, AGG_MEDIAN,
    AGG_MIN, AGG_SUM,
)
from komira_plan_expr.expr import BIN_ADD, Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_mixed_cd_fold import (
    _MIX_FOLD_MAX_ROWS,
    _MixFoldInputs,
    _mix_any_null,
    _mix_batch_of,
    _mix_col_f64,
    _mix_col_i64,
    _mix_extract_batch,
    _mix_fold_ceiling_test_floor,
    _mix_is_float_family,
    _mix_is_int_family,
    _mix_is_minmax,
    _mix_pack_row,
    _mix_row_of,
    _mix_schemas_agree,
    _mix_str_row_is_before,
    agg_mixed_count_distinct_servable,
    agg_mixed_offcell_candidate,
    mixed_offcell_row_ceiling_for_schema,
    mixed_offcell_servable_for_schema,
)


# =============================================================================
# Fixture and plan builders
# =============================================================================


def _batch() raises -> RecordBatch:
    """k STRING, kn INT64 (one NULL), v INT64, s STRING, ls LARGE_STRING,
    f FLOAT64, h INT16 — three rows."""
    var rbb = RecordBatchBuilder.with_capacity(7)
    var sb = SchemaBuilder()
    var ks: List[String] = [String("a"), String("b"), String("a")]
    rbb.add_column(Column.from_string(StringArray.from_strings(ks)))
    sb.add_field(Field(String("k"), ArrowType.STRING, False))
    var kn = PrimitiveArray[DType.int64].allocate_nullable(3)
    kn.set(0, 1)
    kn.set(1, 2)
    kn._set_null(2)
    rbb.add_column(Column.from_primitive[DType.int64](kn^))
    sb.add_field(Field(String("kn"), ArrowType.INT64, True))
    var v = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        v._typed_ptr_mut()[i] = Int64(i)
    rbb.add_column(Column.from_primitive[DType.int64](v^))
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    rbb.add_column(Column.from_string(StringArray.from_strings(ks)))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    rbb.add_column(Column.from_large_string(LargeStringArray.from_strings(ks)))
    sb.add_field(Field(String("ls"), ArrowType.LARGE_STRING, False))
    var f = PrimitiveArray[DType.float64].allocate(3)
    for i in range(3):
        f._typed_ptr_mut()[i] = Float64(i)
    rbb.add_column(Column.from_primitive[DType.float64](f^))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    var h = PrimitiveArray[DType.int16].allocate(3)
    for i in range(3):
        h._typed_ptr_mut()[i] = Int16(i)
    rbb.add_column(Column.from_primitive[DType.int16](h^))
    sb.add_field(Field(String("h"), ArrowType.INT16, False))
    return rbb.build(sb.build())


def _a(func: UInt8, col: String) raises -> AggExpr:
    return AggExpr(func, Optional[Expr](Expr.col_ref(col)), Optional[String](None))


def _bare(func: UInt8) raises -> AggExpr:
    return AggExpr(func, Optional[Expr](None), Optional[String](None))


def _computed(func: UInt8) raises -> AggExpr:
    return AggExpr(
        func,
        Optional[Expr](Expr.binary(BIN_ADD, Expr.col_ref(String("v")), Expr.col_ref(String("v")))),
        Optional[String](None),
    )


def _plan(var aggs: AggExprArray, key: String = "k") raises -> AggregateData:
    var k = ExprArray()
    if key == "<computed>":
        k.append(Expr.binary(BIN_ADD, Expr.col_ref(String("v")), Expr.col_ref(String("v"))))
    elif key.byte_length() > 0:
        k.append(Expr.col_ref(key))
    var child = LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _batch().schema.copy())
    return AggregateData(k^, aggs^, child^)


def _two(var x: AggExpr, var y: AggExpr) -> AggExprArray:
    var a = AggExprArray()
    a.append(x^)
    a.append(y^)
    return a^


# =============================================================================
# The structural gates
# =============================================================================


def test_mixed_cd_gate_refusals_and_admits() raises:
    """`agg_mixed_count_distinct_servable`: one aggregate; a CD without input;
    a computed CD input; an op outside the set; a SUM without input; a
    computed SUM input; no CD; no fixed-cell aggregate; a computed key — each
    False. A CD beside each of SUM, COUNT(col), COUNT(*), MIN, MAX and MEAN
    is True. Catches `n_aggs < 2` written `< 1` and an op dropped from the
    set."""
    var one = AggExprArray()
    one.append(_a(AGG_COUNT_DISTINCT, String("v")))
    assert_false(agg_mixed_count_distinct_servable(_plan(one^)))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_bare(AGG_COUNT_DISTINCT), _a(AGG_SUM, String("v"))))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_computed(AGG_COUNT_DISTINCT), _a(AGG_SUM, String("v"))))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_MEDIAN, String("v"))))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_SUM)))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _computed(AGG_SUM)))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_SUM, String("v")), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_COUNT_DISTINCT, String("f"))))))
    assert_false(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String("<computed>"))))
    var ops: List[UInt8] = [AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN]
    for i in range(len(ops)):
        assert_true(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(ops[i], String("v"))))))
    assert_true(agg_mixed_count_distinct_servable(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String(""))))


def test_offcell_candidate_refusals_and_both_mixed_shapes() raises:
    """`agg_mixed_offcell_candidate`: the same refusals, plus an all-MIN/MAX
    node, an all-plain node and an all-CD node are not candidates; a CD
    beside a MIN, and a MIN or MAX beside COUNT(*), SUM or MEAN, are. Catches
    the second shape's `and` written `or` (an all-MIN/MAX node would be
    stolen from the all-string fold)."""
    var one = AggExprArray()
    one.append(_a(AGG_MIN, String("s")))
    assert_false(agg_mixed_offcell_candidate(_plan(one^)))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_bare(AGG_COUNT_DISTINCT), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_computed(AGG_COUNT_DISTINCT), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MIN, String("s")), _a(AGG_MEDIAN, String("v"))))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_bare(AGG_MIN), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_computed(AGG_MAX), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MIN, String("s")), _bare(AGG_COUNT)), String("<computed>"))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MIN, String("s")), _a(AGG_MAX, String("s"))))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_SUM, String("v")), _bare(AGG_COUNT)))))
    assert_false(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_COUNT_DISTINCT, String("f"))))))
    assert_true(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_MIN, String("s"))))))
    assert_true(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MIN, String("s")), _bare(AGG_COUNT)))))
    assert_true(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MAX, String("s")), _a(AGG_SUM, String("v"))))))
    assert_true(agg_mixed_offcell_candidate(_plan(_two(_a(AGG_MEAN, String("v")), _a(AGG_MAX, String("s"))))))


def test_schema_gate_admits_only_a_real_offcell_aggregate() raises:
    """Not a candidate: False. A CD: True. MIN over STRING or MAX over
    LARGE_STRING beside COUNT(*): True. MIN over INT64 beside SUM, and MIN
    over a column the schema lacks: False. Catches the LARGE_STRING operand
    dropped and a numeric MIN admitted (it belongs to the parallel kernel)."""
    var s = _batch().schema.copy()
    assert_false(mixed_offcell_servable_for_schema(_plan(_two(_a(AGG_SUM, String("v")), _bare(AGG_COUNT))), s))
    assert_true(mixed_offcell_servable_for_schema(_plan(_two(_bare(AGG_COUNT), _a(AGG_COUNT_DISTINCT, String("v")))), s))
    assert_true(mixed_offcell_servable_for_schema(_plan(_two(_bare(AGG_COUNT), _a(AGG_MIN, String("s")))), s))
    assert_true(mixed_offcell_servable_for_schema(_plan(_two(_bare(AGG_COUNT), _a(AGG_MAX, String("ls")))), s))
    assert_false(mixed_offcell_servable_for_schema(_plan(_two(_a(AGG_SUM, String("v")), _a(AGG_MIN, String("v")))), s))
    assert_false(mixed_offcell_servable_for_schema(_plan(_two(_bare(AGG_COUNT), _a(AGG_MIN, String("nope")))), s))


# =============================================================================
# The ceiling
# =============================================================================


def test_ceiling_is_one_number_lowered_only_downward() raises:
    """The derived ceiling is 128,000,000; `lowered_to = 64` gives 64; 0 and
    a negative value leave the derived ceiling; a value above it does not
    raise it. Catches the `min()` written as assignment (a caller could hand
    the serial fold a bigger budget) and a negative value honoured."""
    var ad = _plan(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)))
    var s = _batch().schema.copy()
    assert_equal(_MIX_FOLD_MAX_ROWS, 128_000_000)
    assert_equal(mixed_offcell_row_ceiling_for_schema(ad, s), _MIX_FOLD_MAX_ROWS)
    assert_equal(mixed_offcell_row_ceiling_for_schema(ad, s, 64), 64)
    assert_equal(mixed_offcell_row_ceiling_for_schema(ad, s, 0), _MIX_FOLD_MAX_ROWS)
    assert_equal(mixed_offcell_row_ceiling_for_schema(ad, s, -5), _MIX_FOLD_MAX_ROWS)
    assert_equal(mixed_offcell_row_ceiling_for_schema(ad, s, _MIX_FOLD_MAX_ROWS + 1), _MIX_FOLD_MAX_ROWS)
    assert_equal(_mix_fold_ceiling_test_floor(100, 99), 99)
    assert_equal(_mix_fold_ceiling_test_floor(100, 100), 100)


# =============================================================================
# Helpers
# =============================================================================


def test_row_packing_round_trips() raises:
    """(0, 0) packs to 0 (a valid best, not the -1 sentinel), and (3,
    0xFFFFFFFF) unpacks to its own batch and row. Catches the row mask
    narrowed to 31 bits."""
    assert_equal(_mix_pack_row(0, 0), 0)
    var p = _mix_pack_row(3, 0xFFFFFFFF)
    assert_true(p >= 0)
    assert_equal(_mix_batch_of(p), 3)
    assert_equal(_mix_row_of(p), 0xFFFFFFFF)


def _schema(imm names: List[String], imm types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], i == 0))
    return sb.build()


def test_schema_agreement_compares_width_names_and_types() raises:
    """Agreement ignores nullability; a different width, name or type
    disagrees. Catches any one compare removed."""
    var n: List[String] = [String("a"), String("b")]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.STRING]
    var base = _schema(n, t)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.STRING, True))
    assert_true(_mix_schemas_agree(base, sb.build()))
    var n1: List[String] = [String("a")]
    var t1: List[ArrowType] = [ArrowType.INT64]
    assert_false(_mix_schemas_agree(base, _schema(n1, t1)))
    var n2: List[String] = [String("a"), String("c")]
    assert_false(_mix_schemas_agree(base, _schema(n2, t)))
    var t2: List[ArrowType] = [ArrowType.INT64, ArrowType.LARGE_STRING]
    assert_false(_mix_schemas_agree(base, _schema(n, t2)))


def test_in_place_byte_order() raises:
    """The same-array overload: 'abc' sorts before 'abcd' and not after it
    (both orders), equal cells are not before each other, the first
    differing byte decides ('abd' after 'abc'), and bytes are UNSIGNED: 'z'
    (0x7A) sorts before 'é' (0xC3 0xA9). The two-array overload agrees
    across arrays. Catches the length tie-break inverted and a signed byte
    compare."""
    var v: List[String] = [String("abc"), String("abcd"), String("abd"), String("z"), String("é"), String("abc")]
    var sa = StringArray.from_strings(v)
    assert_true(_mix_str_row_is_before(sa, 0, 1))
    assert_false(_mix_str_row_is_before(sa, 1, 0))
    assert_false(_mix_str_row_is_before(sa, 0, 5))
    assert_true(_mix_str_row_is_before(sa, 0, 2))
    assert_false(_mix_str_row_is_before(sa, 2, 0))
    assert_true(_mix_str_row_is_before(sa, 3, 4))
    assert_false(_mix_str_row_is_before(sa, 4, 3))
    var w: List[String] = [String("abcd")]
    var sb = StringArray.from_strings(w)
    assert_true(_mix_str_row_is_before(sa, 0, sb, 0))
    assert_false(_mix_str_row_is_before(sb, 0, sa, 0))


def test_column_emitters_with_and_without_nulls() raises:
    """`_mix_any_null` answers both ways; the INT64 and FLOAT64 emitters give
    a column with no NULL when told none, and one with the NULL at its row and
    the null count set when told one. Catches the null count left 0 over a
    cleared bit."""
    var none: List[Bool] = [False, False]
    var one: List[Bool] = [False, True]
    assert_false(_mix_any_null(none))
    assert_true(_mix_any_null(one))
    var iv: List[Int64] = [4, 9]
    var fv: List[Float64] = [1.5, 2.5]
    var c = _mix_col_i64(iv, none, False)
    assert_equal(c.null_count(), 0)
    var cn = _mix_col_i64(iv, one, True)
    assert_equal(cn.null_count(), 1)
    assert_true(cn.is_null_at(1))
    assert_false(cn.is_null_at(0))
    var f = _mix_col_f64(fv, none, False)
    assert_equal(f.null_count(), 0)
    var fnull = _mix_col_f64(fv, one, True)
    assert_equal(fnull.null_count(), 1)
    assert_true(fnull.is_null_at(1))


def test_type_family_predicates() raises:
    """INT64 and INT32 are the int family read here (INT16 is not); FLOAT64
    and FLOAT32 are the float family; MIN and MAX are the min/max ops."""
    assert_true(_mix_is_int_family(ArrowType.INT64))
    assert_true(_mix_is_int_family(ArrowType.INT32))
    assert_false(_mix_is_int_family(ArrowType.INT16))
    assert_true(_mix_is_float_family(ArrowType.FLOAT64))
    assert_true(_mix_is_float_family(ArrowType.FLOAT32))
    assert_false(_mix_is_float_family(ArrowType.INT64))
    assert_true(_mix_is_minmax(AGG_MIN))
    assert_true(_mix_is_minmax(AGG_MAX))
    assert_false(_mix_is_minmax(AGG_SUM))


# =============================================================================
# `_mix_extract_batch`, every decline
# =============================================================================


def _extract_declines(var aggs: AggExprArray, key: String, why: String) raises:
    var st = _MixFoldInputs()
    assert_false(_mix_extract_batch(_plan(aggs^, key), _batch(), st, True), why)


def test_extraction_declines_every_key_reason() raises:
    """A computed key, a missing key, a FLOAT key and a key column holding a
    NULL each decline. Catches the null-count gate removed (the mixed fold
    would then pick one of two disagreeing NULL-key semantics silently)."""
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String("<computed>"), "computed key")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String("nope"), "missing key")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String("f"), "float key")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_COUNT)), String("kn"), "null-bearing key")


def test_extraction_declines_every_aggregate_reason() raises:
    """CD: no input, computed input, missing column, a STRING input (no exact
    Int64 key). MIN/MAX: computed input, missing column, no input (it falls
    to the fixed-cell arm, which refuses it). Fixed cell: SUM
    without input, computed input, missing column, a STRING input, an INT16
    input (outside the two int widths read here). Each declines. Catches any
    guard removed."""
    _extract_declines(_two(_bare(AGG_COUNT_DISTINCT), _bare(AGG_COUNT)), String("k"), "CD no input")
    _extract_declines(_two(_computed(AGG_COUNT_DISTINCT), _bare(AGG_COUNT)), String("k"), "CD computed")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("nope")), _bare(AGG_COUNT)), String("k"), "CD missing")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("s")), _bare(AGG_COUNT)), String("k"), "CD string")
    _extract_declines(_two(_computed(AGG_MIN), _bare(AGG_COUNT)), String("k"), "MIN computed")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_MIN)), String("k"), "MIN no input")
    _extract_declines(_two(_a(AGG_MAX, String("nope")), _bare(AGG_COUNT)), String("k"), "MAX missing")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _bare(AGG_SUM)), String("k"), "SUM no input")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _computed(AGG_SUM)), String("k"), "SUM computed")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_SUM, String("nope"))), String("k"), "SUM missing")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_SUM, String("s"))), String("k"), "SUM string")
    _extract_declines(_two(_a(AGG_COUNT_DISTINCT, String("v")), _a(AGG_MEAN, String("h"))), String("k"), "MEAN int16")


def test_extraction_resolves_slots_once_and_appends_rows() raises:
    """A CD, a STRING MIN and two fixed cells over one batch: three rows, one
    key column, one CD slot, one string slot, two base slots, the output
    names from `agg_out_field_name`. A second, non-first batch appends rows
    without adding plans or names. Catches the plan re-appended per batch."""
    var aggs = AggExprArray()
    aggs.append(_a(AGG_COUNT_DISTINCT, String("v")))
    aggs.append(_a(AGG_MIN, String("s")))
    aggs.append(_bare(AGG_COUNT))
    aggs.append(_a(AGG_SUM, String("f")))
    var ad = _plan(aggs^)
    var st = _MixFoldInputs()
    assert_true(_mix_extract_batch(ad, _batch(), st, True))
    assert_true(_mix_extract_batch(ad, _batch(), st, False))
    assert_equal(st.n_rows, 6)
    assert_equal(len(st.plans), 4)
    assert_equal(len(st.out_names), 4)
    assert_equal(len(st.key_names), 1)
    assert_equal(st.n_cd_slots, 1)
    assert_equal(st.n_str_slots, 1)
    assert_equal(st.n_base_slots, 2)
    assert_equal(len(st.cd_vals[0]), 6)
    assert_equal(len(st.base_f64[1]), 6)
    assert_equal(st.row_base[1], 3)
    assert_equal(len(st.key_cols), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
