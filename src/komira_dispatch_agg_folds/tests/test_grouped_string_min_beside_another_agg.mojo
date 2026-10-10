# =============================================================================
# `SELECT k, min(<varchar>), count(*) ... GROUP BY k` — a grouped STRING MIN/MAX
# BESIDE another aggregate (the shape of ClickBench Q21 / Q22 / Q28).
# =============================================================================
#
# ★ WHAT THIS GUARDS, AND IT IS NOT ABOUT STRINGS. Grouped `min(<varchar>)`
#   ALONE is served by `fold_grouped_string_minmax_over_batch`
#   (`execute_agg_plan` routes it there). Add ONE `count(*)` beside it and
#   `grouped_string_minmax_servable` no longer applies, because it requires
#   EVERY aggregate in the node to be a MIN/MAX. Without another route the
#   query drops onto the fixed-cell descriptor build, whose
#   `_agg_input_supported(STRING)` is False, and is refused with
#
#     agg_node_exec: unsupported grouped-agg shape (every group key +
#     agg input must be a plain column reference, and every agg must be
#     SUM/COUNT/MIN/MAX/MEAN over a supported DType)
#
#   So the question is the MIXTURE, not the capability.
#
#   `agg_mixed_cd_fold` serves the mixture by putting the STRING best-value
#   BESIDE the distinct sets — `_MIX_KIND_STR`. Both are OFF-CELL for the same
#   reason: a variable-length value has no fixed-width `AggSpec` slab cell.
#
# ⚠⚠ THE RISK THAT CREATES, AND §4/§5 ARE WHAT HOLD IT. `min(<varchar>)` and
#   `min(<bigint>)` are the SAME PLAN NODE. A gate widened structurally would
#   route every ordinary numeric `min(v), count(*)` — which the PARALLEL
#   fixed-cell kernel serves — into this SERIAL fold. That is why the gate is
#   split: `agg_mixed_offcell_candidate` (structural, may only say "ask again")
#   and `mixed_offcell_servable_for_schema` (resolves the DTypes, and is the only
#   one a caller may raise on). §4 and §5 are the falsifiers for that split, and
#   they PASS WITH OR WITHOUT THE STRING ARM — which is what makes them guards
#   on the widening rather than restatements of it.
#
# ============================ THE ORACLE =====================================
#
# NOT this engine. DuckDB, over the same eight rows:
#
#   CREATE TABLE t(k VARCHAR, s VARCHAR, u VARCHAR, v BIGINT);
#   INSERT INTO t VALUES ('a','zebra','q',10), ('a',NULL,'b',10),
#     ('a','','m',20), ('b','delta','z',30), ('b','alpha','a',30),
#     ('c',NULL,'k',40), ('c',NULL,'kk',41), ('a','apple','c',10);
#
#   SELECT k, min(s), count(*) FROM t GROUP BY k ORDER BY k;
#   -- a | (empty string) | 4
#   -- b | alpha          | 2
#   -- c | NULL           | 2
#
#   SELECT k, min(s), max(u), count(*), count(DISTINCT v) FROM t GROUP BY k
#   ORDER BY k;
#   -- a | (empty string) | q  | 4 | 2
#   -- b | alpha          | z  | 2 | 1
#   -- c | NULL           | kk | 2 | 2
#
# ⚠ THE EMPTY STRING AT k='a' IS THE ANSWER, NOT A MISSING ONE. It is a VALUE,
#   it is the lexicographic minimum of its group, and an accumulator that used
#   "best is still empty" as its not-yet-seen sentinel would report it as NULL —
#   indistinguishable from group 'c', whose `s` really is all NULL. That is the
#   exact pair §3 measures, and it is why `_MIX_KIND_STR`'s not-yet-seen marker
#   is a negative retained row (-1), never an empty best value.
#
# ============================ WHICH MUTANT TURNS IT RED ======================
#
# Delete the `_MIX_KIND_STR` arm from `agg_mixed_cd_fold.fold_mixed_count_
# distinct_over_batch` (or narrow `agg_mixed_offcell_candidate` to
# `agg_mixed_count_distinct_servable`) and §1, §2 and §3 go RED — the fold
# returns None, which is the out-of-envelope raise the caller reports. §4, §5
# and §6 stay GREEN under that mutant, BY CONSTRUCTION.
#
# Encapsulation (pointer rules): NO UnsafePointer / wildcard origins /
#   unsafe_from_address / take_pointee in THIS test.
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_plan_expr.expr import Expr
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan, SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import AggregateData

from komira_dispatch_agg_folds.agg_mixed_cd_fold import (
    agg_mixed_count_distinct_servable,
    agg_mixed_offcell_candidate,
    mixed_offcell_servable_for_schema,
    fold_mixed_count_distinct_over_batch,
)


# =============================================================================
# THE FIXTURE — eight rows, three groups, and a NULL pattern that separates
# "the empty string is the min" from "this group saw no value at all".
# =============================================================================

comptime _N: Int = 8


def _fixture() raises -> RecordBatch:
    """STRING key `k`, nullable STRING `s`, non-null STRING `u`, INT64 `v`.

    row | k | s       | u  | v
      0 | a | 'zebra' | q  | 10
      1 | a | NULL    | b  | 10
      2 | a | ''      | m  | 20
      3 | b | 'delta' | z  | 30
      4 | b | 'alpha' | a  | 30
      5 | c | NULL    | k  | 40
      6 | c | NULL    | kk | 41
      7 | a | 'apple' | c  | 10

    Group 'c' has NO non-null `s` at all; group 'a' has an EMPTY-STRING `s`
    that IS its minimum. Those two cases must not read alike."""
    var kvals: List[String] = [
        String("a"), String("a"), String("a"), String("b"),
        String("b"), String("c"), String("c"), String("a"),
    ]
    var karr = StringArray.from_strings(kvals)

    var svals: List[String] = [
        String("zebra"), String(""), String(""), String("delta"),
        String("alpha"), String(""), String(""), String("apple"),
    ]
    var svalid: List[Bool] = [
        True, False, True, True, True, False, False, True,
    ]
    var sarr = StringArray.from_strings_with_validity(svals, svalid)

    var uvals: List[String] = [
        String("q"), String("b"), String("m"), String("z"),
        String("a"), String("k"), String("kk"), String("c"),
    ]
    var uarr = StringArray.from_strings(uvals)

    var varr = PrimitiveArray[DType.int64].allocate(_N)
    var vsrc: List[Int64] = [
        Int64(10), Int64(10), Int64(20), Int64(30),
        Int64(30), Int64(40), Int64(41), Int64(10),
    ]
    for i in range(_N):
        varr._typed_ptr_mut()[i] = vsrc[i]

    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_string(karr^))
    rbb.add_column(Column.from_string(sarr^))
    rbb.add_column(Column.from_string(uarr^))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))

    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.STRING, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    sb.add_field(Field(String("u"), ArrowType.STRING, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    return rbb.build(sb.build())


def _placeholder_child(imm schema: Schema) raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("dummy.parquet"), SOURCE_PARQUET, schema.copy()
    )


def _agg(var aggs: AggExprArray, imm schema: Schema) raises -> AggregateData:
    """`SELECT k, <aggs...> FROM t GROUP BY k` over the fixture schema."""
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("k")))
    var child = _placeholder_child(schema)
    return AggregateData(keys^, aggs^, child^)


def _one(func: UInt8, column: String, name: String) raises -> AggExpr:
    return AggExpr(
        func,
        Optional[Expr](Expr.col_ref(column)),
        Optional[String](name),
    )


def _count_star(name: String) raises -> AggExpr:
    return AggExpr(AGG_COUNT, Optional[Expr](None), Optional[String](name))


def _row_of_key(imm out: RecordBatch, key: String) raises -> Int:
    """Locate a group by its KEY VALUE. The fold emits groups in first-
    occurrence order; reading by slot index would pass for the wrong reason."""
    var kc = out.column_as_string(0)
    for g in range(out.num_rows()):
        if kc.get(g) == key:
            return g
    raise Error("group key not found in the fold output: " + key)


def _assert_str_cell(
    imm out: RecordBatch, col: Int, row: Int, want: String, msg: String
) raises:
    var c = out.column_as_string(col)
    assert_false(c.is_null(row), msg + " — must not be NULL")
    assert_equal(c.get(row), want, msg)


def _assert_i64_cell(
    imm out: RecordBatch, col: Int, row: Int, want: Int, msg: String
) raises:
    var c = out.column_as_primitive_int64(col)
    assert_false(c.is_null(row), msg + " — must not be NULL")
    assert_equal(Int(c.get(row)), want, msg)


# =============================================================================
# §1 — ⭐ THE Q21 SHAPE: `min(<varchar>)` beside `count(*)`.
# =============================================================================


def test_Q21_shape_grouped_string_MIN_beside_COUNT_STAR() raises:
    """ClickBench Q21 in miniature. A DECLINE here IS the failure: the caller
    turns `None` into the "unsupported grouped-agg shape" raise."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)

    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    if not out_opt:
        raise Error(
            "the mixed fold DECLINED `min(<varchar>), count(*)` — which the"
            " caller reports as an out-of-envelope raise"
        )
    var out = out_opt.take()
    assert_equal(out.num_rows(), 3, "three groups")
    assert_equal(out.schema.num_columns(), 3, "k + min_s + c")
    assert_equal(
        String(out.schema.field_at_unchecked(1).arrow_type),
        String(ArrowType.STRING),
        "a STRING MIN emits a STRING column, not an INT64 cell",
    )

    var ga = _row_of_key(out, String("a"))
    var gb = _row_of_key(out, String("b"))
    var gc = _row_of_key(out, String("c"))

    _assert_str_cell(
        out, 1, ga, String(""), "min(s) for k='a' is the EMPTY STRING"
    )
    _assert_str_cell(out, 1, gb, String("alpha"), "min(s) for k='b'")
    assert_true(
        out.column_as_string(1).is_null(gc),
        "min(s) for k='c' is NULL — every `s` in that group is NULL, and SQL"
        " min() over no values is NULL",
    )
    _assert_i64_cell(out, 2, ga, 4, "count(*) for k='a'")
    _assert_i64_cell(out, 2, gb, 2, "count(*) for k='b'")
    _assert_i64_cell(out, 2, gc, 2, "count(*) for k='c'")


# =============================================================================
# §2 — ⭐ THE Q22 SHAPE: TWO string MINs + `count(*)` + `count(DISTINCT)`.
# =============================================================================


def test_Q22_shape_two_string_minmax_beside_count_star_and_cd() raises:
    """ClickBench Q22 in miniature — and the case that proves the two OFF-CELL
    accumulators fold in ONE pass: a `Set[Int64]` and two retained best rows
    sharing one group table."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    aggs.append(_one(AGG_MAX, String("u"), String("max_u")))
    aggs.append(_count_star(String("c")))
    aggs.append(_one(AGG_COUNT_DISTINCT, String("v"), String("u_cnt")))
    var ad = _agg(aggs^, batch.schema)

    var out_opt = fold_mixed_count_distinct_over_batch(ad, batch)
    if not out_opt:
        raise Error(
            "the mixed fold DECLINED the Q22 shape (two STRING MIN/MAX beside"
            " count(*) and count(DISTINCT))"
        )
    var out = out_opt.take()
    assert_equal(out.num_rows(), 3, "three groups")
    assert_equal(out.schema.num_columns(), 5, "k + 4 aggregates")

    var ga = _row_of_key(out, String("a"))
    var gb = _row_of_key(out, String("b"))
    var gc = _row_of_key(out, String("c"))

    _assert_str_cell(out, 1, ga, String(""), "min(s) k='a'")
    _assert_str_cell(out, 1, gb, String("alpha"), "min(s) k='b'")
    assert_true(out.column_as_string(1).is_null(gc), "min(s) k='c' is NULL")

    _assert_str_cell(out, 2, ga, String("q"), "max(u) k='a'")
    _assert_str_cell(out, 2, gb, String("z"), "max(u) k='b'")
    _assert_str_cell(out, 2, gc, String("kk"), "max(u) k='c'")

    _assert_i64_cell(out, 3, ga, 4, "count(*) k='a'")
    _assert_i64_cell(out, 3, gb, 2, "count(*) k='b'")
    _assert_i64_cell(out, 3, gc, 2, "count(*) k='c'")

    _assert_i64_cell(out, 4, ga, 2, "count(DISTINCT v) k='a' — {10,20}")
    _assert_i64_cell(out, 4, gb, 1, "count(DISTINCT v) k='b' — {30}")
    _assert_i64_cell(out, 4, gc, 2, "count(DISTINCT v) k='c' — {40,41}")


# =============================================================================
# §3 — ⚠ THE EMPTY STRING IS A VALUE. The pair that separates "min is ''" from
#      "this group saw nothing".
# =============================================================================


def test_an_EMPTY_STRING_min_is_not_a_NULL_min() raises:
    """If the accumulator used "best is still empty" as its not-yet-seen
    sentinel, group 'a' (whose min IS the empty string) and group 'c' (whose
    `s` is entirely NULL) would read IDENTICALLY. They must not."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    aggs.append(_count_star(String("c")))
    var out_opt = fold_mixed_count_distinct_over_batch(
        _agg(aggs^, batch.schema), batch
    )
    if not out_opt:
        raise Error("the mixed fold DECLINED `min(<varchar>), count(*)`")
    var out = out_opt.take()

    var ga = _row_of_key(out, String("a"))
    var gc = _row_of_key(out, String("c"))
    var col = out.column_as_string(1)
    assert_false(col.is_null(ga), "k='a' saw a value")
    assert_equal(col.get(ga).byte_length(), 0, "and that value is zero bytes")
    assert_true(col.is_null(gc), "k='c' saw none")
    assert_true(
        out.schema.field_at_unchecked(1).nullable,
        "the emitted column must declare itself nullable when a group is NULL —"
        " a consumer gating on `nullable` must not be told otherwise",
    )


def test_the_fixture_really_does_hold_both_cases() raises:
    """⚠ NON-VACUOUSNESS. §3 can only discriminate if the fixture actually
    contains an empty-string value AND an all-null group. Asserted against the
    fixture itself, not against the fold."""
    var batch = _fixture()
    var s = batch.column_as_string(1)
    assert_false(s.is_null(2), "row 2 of `s` is a non-null empty string")
    assert_equal(s.get(2).byte_length(), 0, "and it is zero bytes")
    assert_true(s.is_null(5) and s.is_null(6), "group 'c' rows are both NULL")


# =============================================================================
# §4 — ⛔ THE FALSIFIER THAT MATTERS: a NUMERIC MIN/MAX MUST NOT BE STOLEN.
#      GREEN with or without the string arm, by construction.
# =============================================================================


def test_a_NUMERIC_min_beside_count_star_is_DECLINED() raises:
    """`SELECT k, min(v), count(*) FROM t GROUP BY k` over a BIGINT `v` is an
    ordinary fixed-cell aggregate the PARALLEL kernel serves. Serving it here
    would not be WRONG, it would be SLOW — a single-threaded fold in place of a
    parallel hash aggregate — so the fold must DECLINE and let the caller fall
    through to the fixed-cell route."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("v"), String("min_v")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_false(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "the SCHEMA-aware gate must refuse a numeric-only MIN/MAX node",
    )
    assert_false(
        fold_mixed_count_distinct_over_batch(ad, batch).__bool__(),
        "and the fold itself — the last word — must refuse it too",
    )


def test_the_structural_gate_admits_it_and_that_is_why_it_is_SPLIT() raises:
    """⚠ THE REASON THERE ARE TWO PREDICATES, STATED AS A MEASUREMENT.
    `min(v), count(*)` and `min(s), count(*)` are the SAME PLAN NODE; only a
    schema tells them apart. So the structural gate says YES to both — and a
    caller that raised on IT rather than on the schema-aware one would turn a
    working numeric aggregate into an error."""
    var batch = _fixture()
    var num = AggExprArray()
    num.append(_one(AGG_MIN, String("v"), String("min_v")))
    num.append(_count_star(String("c")))
    assert_true(
        agg_mixed_offcell_candidate(_agg(num^, batch.schema)),
        "structurally indistinguishable from the STRING case",
    )
    var strs = AggExprArray()
    strs.append(_one(AGG_MIN, String("s"), String("min_s")))
    strs.append(_count_star(String("c")))
    var sad = _agg(strs^, batch.schema)
    assert_true(agg_mixed_offcell_candidate(sad), "and so is the STRING case")
    assert_true(
        mixed_offcell_servable_for_schema(sad, batch.schema),
        "the schema is what separates them",
    )


# =============================================================================
# §5 — ⛔ ARM BOUNDARIES. The widening must not take work from its neighbours.
# =============================================================================


def test_an_ALL_MINMAX_node_is_left_to_the_all_string_fold() raises:
    """`SELECT k, min(s), max(u) FROM t GROUP BY k` is
    `fold_grouped_string_minmax_over_batch`'s shape. The mixed gate must not
    claim it — two folds racing for one node is how a group ORDER or a null
    convention silently forks."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MIN, String("s"), String("min_s")))
    aggs.append(_one(AGG_MAX, String("u"), String("max_u")))
    assert_false(
        agg_mixed_offcell_candidate(_agg(aggs^, batch.schema)),
        "an ALL-MIN/MAX node belongs to the all-string fold",
    )


def test_the_widened_gate_is_a_SUPERSET_of_the_mixed_CD_gate() raises:
    """Every node the mixed-CD gate admitted must still be admitted — the
    widening may add shapes, never remove one."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_COUNT_DISTINCT, String("v"), String("cd")))
    aggs.append(_one(AGG_SUM, String("v"), String("sv")))
    var ad = _agg(aggs^, batch.schema)
    assert_true(agg_mixed_count_distinct_servable(ad), "the C11 shape")
    assert_true(agg_mixed_offcell_candidate(ad), "still admitted")
    assert_true(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "a COUNT(DISTINCT) is off-cell whatever the MIN/MAX inputs are",
    )


# =============================================================================
# §6 — the SUM/MEAN falsifier: the widening is MIN/MAX-only.
# =============================================================================


def test_a_SUM_over_a_STRING_column_is_STILL_refused() raises:
    """SUM folds VALUES into a numeric cell; there is no lexicographic answer
    for it. A DECLINE is the CORRECT behaviour and must survive the widening."""
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_SUM, String("s"), String("ss")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_false(
        mixed_offcell_servable_for_schema(ad, batch.schema),
        "sum(<string col>) is not an off-cell aggregate this fold serves",
    )
    assert_false(
        fold_mixed_count_distinct_over_batch(ad, batch).__bool__(),
        "and the fold refuses it",
    )


def test_a_MEAN_over_a_STRING_column_is_STILL_refused() raises:
    var batch = _fixture()
    var aggs = AggExprArray()
    aggs.append(_one(AGG_MEAN, String("s"), String("ms")))
    aggs.append(_count_star(String("c")))
    var ad = _agg(aggs^, batch.schema)
    assert_false(
        fold_mixed_count_distinct_over_batch(ad, batch).__bool__(),
        "mean(<string col>) must still DECLINE",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
