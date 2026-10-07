"""`agg_pick_output_conform`: a min / max / first / last / any_value column
leaves the aggregate node in its INPUT column's type.

What is proved, piece by piece:

- `pick_conform_step` returns a non-KEEP step for exactly the closed set of
  the module header (INT64 over a narrower integer, FLOAT64 over FLOAT32, a
  zone-less timestamp over a zoned one of the same unit) and KEEP for every
  neighbour of it.
- `AggPickConform.of` records a declared Field only for a pick over a plain
  (alias-stripped) column, and records nothing for a plan it does not
  describe.
- `conform_agg_picks` narrows, retags and moves columns as the steps say,
  keeps NULLs, NaN and the order of columns, and returns a batch it does not
  describe unchanged.
- Every narrowing is checked: a value outside the input's type raises, naming
  the column, for each of the six integer widths and for FLOAT32.
"""

from std.math import inf
from std.testing import assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_ANY_VALUE,
    AGG_COUNT,
    AGG_FIRST,
    AGG_LAST,
    AGG_MAX,
    AGG_MIN,
    AGG_SUM,
)
from komira_plan_expr.expr import Expr, BIN_ADD
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
)

from komira_dispatch_agg_exec.agg_pick_output_conform import (
    AggPickConform,
    PICK_CONFORM_KEEP,
    PICK_CONFORM_NARROW_F32,
    PICK_CONFORM_NARROW_INT,
    PICK_CONFORM_RETAG_TZ,
    _narrowed,
    conform_agg_picks,
    pick_conform_step,
)


# =============================================================================
# Fixtures
# =============================================================================


def _i64_col(values: List[Int64], null_at: Int = -1) raises -> Column[HeapRegion]:
    """An INT64 column of `values`; row `null_at` is NULL (none when -1, and
    then the column has no validity bitmap at all)."""
    var n = len(values)
    var a = PrimitiveArray[DType.int64].allocate_nullable(n) if null_at >= 0 else PrimitiveArray[DType.int64].allocate(n)
    for r in range(n):
        if r == null_at:
            a._set_null(r)
        else:
            a.set(r, values[r])
    return Column.from_primitive_with_arrow_type[DType.int64](a, ArrowType.INT64)


def _ts_col(values: List[Int64], arrow_type: ArrowType) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate(len(values))
    for r in range(len(values)):
        a.set(r, values[r])
    return Column.from_primitive_with_arrow_type[DType.int64](a, arrow_type)


def _f64_col(values: List[Float64], null_at: Int = -1) raises -> Column[HeapRegion]:
    var n = len(values)
    var a = PrimitiveArray[DType.float64].allocate_nullable(n) if null_at >= 0 else PrimitiveArray[DType.float64].allocate(n)
    for r in range(n):
        if r == null_at:
            a._set_null(r)
        else:
            a.set(r, values[r])
    return Column.from_primitive_with_arrow_type[DType.float64](a, ArrowType.FLOAT64)


def _one_col_batch(var f: Field, var c: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(f^)
    var bb = RecordBatchBuilder.with_capacity(1)
    bb.add_column(c^)
    return bb.build(sb.build())


def _nan() -> Float64:
    var zero = Float64(0.0)
    return zero / zero


def _i64s(a: Int64, b: Int64, c: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _f64s(a: Float64, b: Float64, c: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def _input_scan() raises -> LogicalPlan:
    """The aggregate's input: g INT64, v8 INT8, f FLOAT32, ts TIMESTAMP_US in
    UTC, w INT64."""
    var b = SchemaBuilder()
    b.add_field(Field(String("g"), ArrowType.INT64, False))
    b.add_field(Field(String("v8"), ArrowType.INT8, True))
    b.add_field(Field(String("f"), ArrowType.FLOAT32, True))
    b.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String("UTC"), True))
    b.add_field(Field(String("w"), ArrowType.INT64, True))
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, b.build())


def _agg(func: UInt8, var child: Optional[Expr], name: String) -> AggExpr:
    return AggExpr(func, child^, Optional[String](name))


def _col(name: String) -> Optional[Expr]:
    return Optional[Expr](Expr.col_ref(name))


def _the_plan() raises -> LogicalPlan:
    """GROUP BY g with eleven aggregates, one of each shape `of` decides on.
    Output columns, in order (index: what it is -> declared?):
      0 g (key) -> no;  1 min(v8) -> INT8;  2 max(f) -> FLOAT32;
      3 first(ts) -> TIMESTAMP_US UTC;  4 count(*) -> no;  5 sum(v8) -> no;
      6 min(w AS w2) -> INT64;  7 max(v8 + 1) -> no;  8 last(v8) -> INT8;
      9 any_value(v8) -> INT8;  10 min(f) -> FLOAT32."""
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("g")))
    var ax = AggExprArray()
    ax.append(_agg(AGG_MIN, _col(String("v8")), String("min_v8")))
    ax.append(_agg(AGG_MAX, _col(String("f")), String("max_f")))
    ax.append(_agg(AGG_FIRST, _col(String("ts")), String("first_ts")))
    ax.append(_agg(AGG_COUNT, Optional[Expr](), String("n")))
    ax.append(_agg(AGG_SUM, _col(String("v8")), String("sum_v8")))
    ax.append(
        _agg(AGG_MIN, Optional[Expr](Expr.col_ref(String("w")).alias(String("w2"))), String("min_w"))
    )
    ax.append(
        _agg(
            AGG_MAX,
            Optional[Expr](
                Expr.binary(BIN_ADD, Expr.col_ref(String("v8")), Expr.literal(ScalarValue.from_int(1)))
            ),
            String("max_v8p1"),
        )
    )
    ax.append(_agg(AGG_LAST, _col(String("v8")), String("last_v8")))
    ax.append(_agg(AGG_ANY_VALUE, _col(String("v8")), String("any_v8")))
    ax.append(_agg(AGG_MIN, _col(String("f")), String("min_f")))
    return LogicalPlan.aggregate(gb^, ax^, _input_scan())


# =============================================================================
# pick_conform_step
# =============================================================================


def test_step_is_non_keep_for_exactly_the_closed_set() raises:
    """Each member of the closed set gets its step, and each neighbour of it
    (same drained type with a wider or equal declared type, a narrow drained
    type, a timestamp whose unit differs, already has a zone, or is declared
    without one) gets KEEP.
    MUTANT: drop `d == w` from the timestamp arm and the MS-declared column
    over a US cell is retagged (a wrong unit, no byte moved); drop the
    declared-zone test and a naive declared timestamp is retagged with no
    zone."""
    var i64 = Field(String("x"), ArrowType.INT64, True)
    var narrow = List[ArrowType]()
    narrow.append(ArrowType.INT8)
    narrow.append(ArrowType.INT16)
    narrow.append(ArrowType.INT32)
    narrow.append(ArrowType.UINT8)
    narrow.append(ArrowType.UINT16)
    narrow.append(ArrowType.UINT32)
    for i in range(len(narrow)):
        assert_equal(
            pick_conform_step(i64, Field(String("x"), narrow[i], True)), PICK_CONFORM_NARROW_INT
        )
    assert_equal(pick_conform_step(i64, i64), PICK_CONFORM_KEEP)
    assert_equal(
        pick_conform_step(i64, Field(String("x"), ArrowType.UINT64, True)), PICK_CONFORM_KEEP
    )
    assert_equal(
        pick_conform_step(i64, Field(String("x"), ArrowType.FLOAT32, True)), PICK_CONFORM_KEEP
    )
    assert_equal(
        pick_conform_step(
            Field(String("x"), ArrowType.INT32, True), Field(String("x"), ArrowType.INT8, True)
        ),
        PICK_CONFORM_KEEP,
    )

    var f64 = Field(String("x"), ArrowType.FLOAT64, True)
    assert_equal(
        pick_conform_step(f64, Field(String("x"), ArrowType.FLOAT32, True)), PICK_CONFORM_NARROW_F32
    )
    assert_equal(pick_conform_step(f64, f64), PICK_CONFORM_KEEP)

    var naive_us = Field(String("x"), ArrowType.TIMESTAMP_US, True)
    var utc_us = Field.timestamp(String("x"), ArrowType.TIMESTAMP_US, String("UTC"), True)
    var utc_ms = Field.timestamp(String("x"), ArrowType.TIMESTAMP_MS, String("UTC"), True)
    assert_equal(pick_conform_step(naive_us, utc_us), PICK_CONFORM_RETAG_TZ)
    assert_equal(pick_conform_step(naive_us, utc_ms), PICK_CONFORM_KEEP)
    assert_equal(pick_conform_step(utc_us, utc_us), PICK_CONFORM_KEEP)
    assert_equal(pick_conform_step(naive_us, naive_us), PICK_CONFORM_KEEP)
    assert_equal(pick_conform_step(i64, utc_us), PICK_CONFORM_KEEP)


# =============================================================================
# AggPickConform.of
# =============================================================================


def test_of_declares_only_picks_over_plain_columns() raises:
    """Of the eleven output columns of `_the_plan`, exactly 1, 2, 3, 6, 8, 9
    and 10 are declared, each with the plan's own output Field (the zone of
    the timestamp included).
    MUTANT: drop the plain-column test and column 7 (max(v8 + 1)) is
    declared; drop `agg_picks_by_arrival_order` from `_is_pick` and columns
    3, 8 and 9 are not."""
    var c = AggPickConform.of(_the_plan())
    assert_equal(c.n_cols, 11)
    assert_equal(len(c.declared), 11)
    var want = List[Bool]()
    for _ in range(11):
        want.append(False)
    want[1] = True
    want[2] = True
    want[3] = True
    want[6] = True
    want[8] = True
    want[9] = True
    want[10] = True
    for i in range(11):
        assert_equal(Bool(c.declared[i]), want[i], String("declared[") + String(i) + "]")
    assert_true(c.declared[1].value().arrow_type == ArrowType.INT8)
    assert_true(c.declared[2].value().arrow_type == ArrowType.FLOAT32)
    assert_true(c.declared[3].value().arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(c.declared[3].value().timezone(), String("UTC"))
    assert_true(c.declared[6].value().arrow_type == ArrowType.INT64)


def test_of_describes_nothing_for_a_plan_it_does_not_own() raises:
    """A non-aggregate plan, an AGGREGATE tag without its data, an aggregate
    whose output arity is not keys + aggregates, and an aggregate with no
    pick all yield a conform that changes nothing (n_cols -1, no fields).
    MUTANT: keep `n_cols` when no pick was found and the no-pick conform
    claims 3 columns."""
    var not_agg = AggPickConform.of(_input_scan())
    assert_equal(not_agg.n_cols, -1)
    assert_equal(len(not_agg.declared), 0)

    var empty = SchemaBuilder()
    var bare = AggPickConform.of(LogicalPlan(PLAN_AGGREGATE, empty.build()))
    assert_equal(bare.n_cols, -1)

    var wide = _the_plan()
    var sb = SchemaBuilder()
    for i in range(wide.output_schema.num_columns()):
        sb.add_field(wide.output_schema.field_at_unchecked(i))
    sb.add_field(Field(String("udf_extra"), ArrowType.INT64, True))
    wide.output_schema = sb.build()
    var arity = AggPickConform.of(wide)
    assert_equal(arity.n_cols, -1)
    assert_equal(len(arity.declared), 0)

    var gb = ExprArray()
    gb.append(Expr.col_ref(String("g")))
    var ax = AggExprArray()
    ax.append(_agg(AGG_COUNT, Optional[Expr](), String("n")))
    ax.append(_agg(AGG_SUM, _col(String("w")), String("s")))
    var no_pick = AggPickConform.of(LogicalPlan.aggregate(gb^, ax^, _input_scan()))
    assert_equal(no_pick.n_cols, -1)
    assert_equal(len(no_pick.declared), 0)


# =============================================================================
# conform_agg_picks
# =============================================================================


def _drained_batch() raises -> RecordBatch:
    """What a route hands back for `_the_plan`: every integer pick in an INT64
    cell, every float pick in a FLOAT64 cell, the timestamp without its zone.
    Three groups."""
    var nan = _nan()
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder.with_capacity(11)
    sb.add_field(Field(String("g"), ArrowType.INT64, False))
    bb.add_column(_i64_col(_i64s(1, 2, 3)))
    sb.add_field(Field(String("min_v8"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(-128, 127, 0), null_at=2))
    sb.add_field(Field(String("max_f"), ArrowType.FLOAT64, True))
    bb.add_column(_f64_col(_f64s(1.5, nan, 0.0), null_at=2))
    sb.add_field(Field(String("first_ts"), ArrowType.TIMESTAMP_US, True))
    bb.add_column(_ts_col(_i64s(10, 20, 30), ArrowType.TIMESTAMP_US))
    sb.add_field(Field(String("n"), ArrowType.INT64, False))
    bb.add_column(_i64_col(_i64s(4, 5, 6)))
    sb.add_field(Field(String("sum_v8"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(1_000, 2_000, 3_000)))
    sb.add_field(Field(String("min_w"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(-5_000_000_000, 7, 8)))
    sb.add_field(Field(String("max_v8p1"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(128, 200, 300)))
    sb.add_field(Field(String("last_v8"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(-1, 0, 1)))
    sb.add_field(Field(String("any_v8"), ArrowType.INT64, True))
    bb.add_column(_i64_col(_i64s(5, 6, 7), null_at=0))
    sb.add_field(Field(String("min_f"), ArrowType.FLOAT64, True))
    bb.add_column(_f64_col(_f64s(-0.0, 0.25, -1099511627776.0)))
    return bb.build(sb.build())


def test_conform_narrows_retags_and_moves_in_schema_order() raises:
    """The drained batch comes back with every declared pick in its input's
    type and every other column exactly as drained, in the same order, with
    NULLs and NaN where they were.
    MUTANT: return `moved` without the reversal (push order) and the columns
    come back in reverse; build every column from `moved` and the narrowed
    columns keep their INT64 cells."""
    var out = conform_agg_picks(_drained_batch(), AggPickConform.of(_the_plan()))
    assert_equal(out.num_columns(), 11)
    assert_equal(out.num_rows(), 3)
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT8)
    types.append(ArrowType.FLOAT32)
    types.append(ArrowType.TIMESTAMP_US)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT8)
    types.append(ArrowType.INT8)
    types.append(ArrowType.FLOAT32)
    for c in range(11):
        assert_true(
            out.schema.field_at(c).arrow_type == types[c], String("column ") + String(c) + " type"
        )
    assert_equal(out.schema.field_at(1).name, String("min_v8"))
    assert_equal(out.schema.field_at(3).timezone(), String("UTC"))
    assert_equal(out.schema.field_at(3).name, String("first_ts"))

    var g = out.column_as_primitive[DType.int64](0)
    assert_equal(g.get(0), 1)
    assert_equal(g.get(2), 3)
    var v8 = out.column_as_primitive[DType.int8](1)
    assert_equal(v8.get(0), Int8(-128))
    assert_equal(v8.get(1), Int8(127))
    assert_true(v8.is_null(2))
    var mf = out.column_as_primitive[DType.float32](2)
    assert_equal(mf.get(0), Float32(1.5))
    assert_true(mf.get(1) != mf.get(1), "NaN did not survive the narrowing")
    assert_true(mf.is_null(2))
    var ts = out.column_as_primitive[DType.int64](3)
    assert_equal(ts.get(0), 10)
    assert_equal(ts.get(2), 30)
    assert_equal(out.column_as_primitive[DType.int64](5).get(1), 2_000)
    assert_equal(out.column_as_primitive[DType.int64](6).get(0), -5_000_000_000)
    assert_equal(out.column_as_primitive[DType.int64](7).get(2), 300)
    var last = out.column_as_primitive[DType.int8](8)
    assert_equal(last.get(0), Int8(-1))
    assert_equal(last.get(2), Int8(1))
    var anyv = out.column_as_primitive[DType.int8](9)
    assert_true(anyv.is_null(0))
    assert_equal(anyv.get(2), Int8(7))
    var minf = out.column_as_primitive[DType.float32](10)
    assert_equal(minf.get(1), Float32(0.25))
    assert_equal(minf.get(2), Float32(-1099511627776.0))


def test_conform_returns_an_undescribed_batch_unchanged() raises:
    """A conform with no picks, a batch whose column count is not the plan's,
    and a batch whose picks are already in their input's type are all handed
    back as they came.
    MUTANT: drop the column-count check and the one-column batch is
    re-typed by the eleven-column plan (or aborts)."""
    var none = conform_agg_picks(
        _one_col_batch(Field(String("a"), ArrowType.INT64, True), _i64_col(_i64s(1, 2, 3))),
        AggPickConform(),
    )
    assert_true(none.schema.field_at(0).arrow_type == ArrowType.INT64)

    var short = conform_agg_picks(
        _one_col_batch(Field(String("a"), ArrowType.INT64, True), _i64_col(_i64s(1, 2, 3))),
        AggPickConform.of(_the_plan()),
    )
    assert_equal(short.num_columns(), 1)
    assert_true(short.schema.field_at(0).arrow_type == ArrowType.INT64)

    # Every declared column already drained in its declared type: no step.
    var already = AggPickConform.of(_the_plan())
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder.with_capacity(11)
    var plan = _the_plan()
    for c in range(11):
        var f = plan.output_schema.field_at_unchecked(c)
        var t = f.arrow_type
        if t == ArrowType.INT8:
            var a = PrimitiveArray[DType.int8].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.int8](a, t))
        elif t == ArrowType.INT16:
            var a = PrimitiveArray[DType.int16].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.int16](a, t))
        elif t == ArrowType.INT32:
            var a = PrimitiveArray[DType.int32].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.int32](a, t))
        elif t == ArrowType.FLOAT64:
            var a = PrimitiveArray[DType.float64].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.float64](a, t))
        elif t == ArrowType.FLOAT32:
            var a = PrimitiveArray[DType.float32].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.float32](a, t))
        else:
            var a = PrimitiveArray[DType.int64].allocate(3)
            bb.add_column(Column.from_primitive_with_arrow_type[DType.int64](a, t))
        sb.add_field(f^)
    var same = conform_agg_picks(bb.build(sb.build()), already)
    assert_equal(same.num_columns(), 11)
    assert_true(same.schema.field_at(1).arrow_type == ArrowType.INT8)
    assert_equal(same.schema.field_at(3).timezone(), String("UTC"))


# =============================================================================
# The checked narrowings
# =============================================================================


def _int_ladder_case[
    dst: DType
](target: ArrowType, lo: Int64, hi: Int64) raises:
    """`target`'s two extremes narrow exactly (with and without a NULL
    alongside), and one past each extreme raises naming the column."""
    var declared = Field(String("pick_col"), target, True)
    var ok = _one_col_batch(
        Field(String("pick_col"), ArrowType.INT64, True), _i64_col(_i64s(lo, hi, 0), null_at=2)
    )
    var col = _narrowed(ok, 0, PICK_CONFORM_NARROW_INT, declared)
    assert_true(col.arrow_type == target)
    var ok2 = _one_col_batch(
        Field(String("pick_col"), ArrowType.INT64, True), _i64_col(_i64s(lo, hi, 0))
    )
    _ = _narrowed(ok2, 0, PICK_CONFORM_NARROW_INT, declared)
    var below = _one_col_batch(
        Field(String("pick_col"), ArrowType.INT64, True), _i64_col(_i64s(0, lo - 1, 0))
    )
    with assert_raises(contains="pick_col"):
        _ = _narrowed(below, 0, PICK_CONFORM_NARROW_INT, declared)
    var above = _one_col_batch(
        Field(String("pick_col"), ArrowType.INT64, True), _i64_col(_i64s(hi + 1, 0, 0), null_at=2)
    )
    with assert_raises(contains="route defect"):
        _ = _narrowed(above, 0, PICK_CONFORM_NARROW_INT, declared)


def test_every_integer_width_is_checked_at_both_extremes() raises:
    """INT8, INT16, INT32, UINT8, UINT16 and UINT32: the extremes pass, one
    past either raises.
    MUTANT: drop the round-trip check (`back != v`) and 128 wraps to -128 as
    an INT8 answer instead of raising; route UINT8 to the INT8 arm and 255
    raises."""
    _int_ladder_case[DType.int8](ArrowType.INT8, -128, 127)
    _int_ladder_case[DType.int16](ArrowType.INT16, -32_768, 32_767)
    _int_ladder_case[DType.int32](ArrowType.INT32, -2_147_483_648, 2_147_483_647)
    _int_ladder_case[DType.uint8](ArrowType.UINT8, 0, 255)
    _int_ladder_case[DType.uint16](ArrowType.UINT16, 0, 65_535)
    _int_ladder_case[DType.uint32](ArrowType.UINT32, 0, 4_294_967_295)


def test_a_float_that_is_not_a_float32_value_raises() raises:
    """0.1 and the largest FLOAT64 (the fold's init sentinel) do not
    round-trip through FLOAT32, so neither was ever in a FLOAT32 column: both
    raise. NaN, infinity and the signed zeros round-trip and pass.
    MUTANT: drop the round-trip check and the sentinel becomes +inf, a second
    wrong answer, silently; drop the `v == v` guard and NaN raises."""
    var declared = Field(String("fcol"), ArrowType.FLOAT32, True)
    var ok = _one_col_batch(
        Field(String("fcol"), ArrowType.FLOAT64, True),
        _f64_col(_f64s(_nan(), inf[DType.float64](), -0.0)),
    )
    var col = _narrowed(ok, 0, PICK_CONFORM_NARROW_F32, declared)
    assert_true(col.arrow_type == ArrowType.FLOAT32)
    var tenth = _one_col_batch(
        Field(String("fcol"), ArrowType.FLOAT64, True), _f64_col(_f64s(0.5, 0.1, 0.0), null_at=2)
    )
    with assert_raises(contains="fcol"):
        _ = _narrowed(tenth, 0, PICK_CONFORM_NARROW_F32, declared)
    var sentinel = _one_col_batch(
        Field(String("fcol"), ArrowType.FLOAT64, True),
        _f64_col(_f64s(Float64.MAX_FINITE, 0.0, 0.0)),
    )
    with assert_raises(contains="float32 column"):
        _ = _narrowed(sentinel, 0, PICK_CONFORM_NARROW_F32, declared)


def test_narrowed_refuses_a_type_outside_its_ladder() raises:
    """`_narrowed` is only reached for a type `pick_conform_step` names; asked
    for any other, it raises rather than guessing a width.
    MUTANT: fall through to the INT8 arm and INT64 is narrowed to one byte."""
    var b = _one_col_batch(Field(String("x"), ArrowType.INT64, True), _i64_col(_i64s(1, 2, 3)))
    with assert_raises(contains="no narrowing"):
        _ = _narrowed(b, 0, PICK_CONFORM_NARROW_INT, Field(String("x"), ArrowType.INT64, True))


def main() raises:
    test_step_is_non_keep_for_exactly_the_closed_set()
    test_of_declares_only_picks_over_plain_columns()
    test_of_describes_nothing_for_a_plan_it_does_not_own()
    test_conform_narrows_retags_and_moves_in_schema_order()
    test_conform_returns_an_undescribed_batch_unchanged()
    test_every_integer_width_is_checked_at_both_extremes()
    test_a_float_that_is_not_a_float32_value_raises()
    test_narrowed_refuses_a_type_outside_its_ladder()
    print("All 8 agg_pick_output_conform tests passed.")
