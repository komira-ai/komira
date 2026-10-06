# =============================================================================
# test_udf_e2e_map_filter.mojo: typed Map sugar and a FilterFn over a
# RecordBatch with nulls, through komira's own projection emit.
# =============================================================================
#
# The path: a 10-row batch of four nullable columns (float64, int64, int32,
# float32) -> a `FilterFn` conformer evaluated through `Predicate.eval[W]`'s
# default body, four lanes at a time (the last chunk runs past the end of the
# batch) -> the surviving row indices -> `ProjectList[MapFnRT[Map1[...]], ...]`
# `.emit_projected`, one output column per `Map1` (a plain `def` with named
# columns). Every expected value below is written out by hand.
#
# What komira does NOT do, and this test therefore does not claim:
#   * NULL PROPAGATION THROUGH A MAP. `MapFn.null_mode` defaults to PROPAGATE,
#     but no komira code reads it: `MapFnRT` loads the slot whatever its
#     validity bit, and `ProjectList.emit_projected` declares every output
#     column non-nullable. A null input row projected through it comes out as
#     `f(0)`, VALID. So the predicate below refuses a row with a null in any
#     column the projection reads, and the projection only ever sees valid rows.
#   * FILTER SUGAR. `typed_udf_sugar` offers `Map1`/`Map2`, not a filter
#     adapter (its header says why), so the predicate is a hand-written
#     `FilterFn` conformer: `keep_row` plus the `eval_scalar` that reads it.
#   * `Map2` has no column adapter (`MapFnRT` reads one input column), so it
#     is driven through `run_row` on rows read off the same batch.
#
# Planted mutant (reverted): `ProjectList.emit_projected`, numeric arm,
# `survivors[si]` -> `si` (project rows 0..3 instead of the survivors 0, 3, 7,
# 8). `test_filter_then_project` went red ("gross row 1": 0.0, which is row 1's
# NULL price slot projected as a valid value, instead of 31.25), and so did
# `test_a_failing_udf_surfaces_its_own_error` (no row over the cap was reached).
#
# Planted mutant (reverted): `Predicate.eval`'s default body, the in-bounds
# guard `if i + lane < n:` -> `if True:`. Only
# `test_past_the_end_lanes_are_never_evaluated` went red (12 rows kept
# instead of 10); komira_udf's own welded tests stayed green.
#
# Planted mutant (reverted; in this file, since the refusal is the
# conformer's own code): `BigLine.eval_scalar`'s NULL check
# `if batch.col_is_null(c, i):` -> `if False:`.
# `test_predicate_keeps_exactly_the_valid_big_lines` and
# `test_filter_then_project` went red (6 survivors instead of 4: rows 4 and
# 9, NULL in rate and units, kept on their values), and so did
# `test_two_column_map_over_the_survivors` (42.0, row 4's total, in row 7's
# place).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.multi_column_builder import (
    ColumnSlot,
    MultiColumnBuilder,
    column_slot,
)

from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.column_resolver import ColumnResolver
from komira_udf.filter_fn import FilterFn
from komira_udf.map_fn_rt import MapFnRT
from komira_udf.schema_descriptor import (
    DT_F32,
    DT_F64,
    DT_I32,
    DT_I64,
)
from komira_expr.typed_projects import ProjectList
from komira_expr.typed_udf_sugar import Map1, Map2, Row2

from komira_udf_e2e.columns import (
    f32_column,
    f64_column,
    i32_column,
    i64_column,
)


# --- the batch ---------------------------------------------------------------
#
#   row  price  qty   units  rate   price*qty  kept?
#    0   10.0   3     1      0.5    30         yes
#    1   NULL   5     2      0.25   -          no (price null)
#    2    4.0   NULL  NULL   0.5    -          no (qty null)
#    3   25.0   2     4      2.0    50         yes
#    4    6.0   7     5      NULL   42         no (rate null; 42 > 15 on value)
#    5    8.0   1     6      1.5     8         no (8 <= 15)
#    6    2.5   NULL  7      0.75   -          no (qty null)
#    7   40.0   4     8      0.5   160         yes
#    8    3.0   9     9      4.0    27         yes
#    9   10.0   2     NULL   1.0    20         no (units null; 20 > 15 on value)
#
# No valid cell holds 0, so a null slot (which holds 0) that reached a UDF as
# a value would show up as a wrong number rather than a lucky right one.
# Rows 4 and 9 pass `price * qty > 15` on their values; only the NULL in a
# column the predicate does not multiply (rate, units) keeps them out. So a
# predicate that stopped refusing NULLs (`BatchView.col_is_null` answering
# False, or the refusal loop gone) keeps them, and the survivor lists change.

comptime N_ROWS = 10


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("price", DType.float64, True))
    sb.add_field(Field("qty", DType.int64, True))
    sb.add_field(Field("units", DType.int32, True))
    sb.add_field(Field("rate", DType.float32, True))
    var price: List[Float64] = [10.0, 0.0, 4.0, 25.0, 6.0, 8.0, 2.5, 40.0, 3.0, 10.0]
    var price_ok: List[Bool] = [True, False, True, True, True, True, True, True, True, True]
    var qty: List[Int64] = [3, 5, 0, 2, 7, 1, 0, 4, 9, 2]
    var qty_ok: List[Bool] = [True, True, False, True, True, True, False, True, True, True]
    var units: List[Int32] = [1, 2, 0, 4, 5, 6, 7, 8, 9, 0]
    var units_ok: List[Bool] = [True, True, False, True, True, True, True, True, True, False]
    var rate: List[Float32] = [0.5, 0.25, 0.5, 2.0, 0.0, 1.5, 0.75, 0.5, 4.0, 1.0]
    var rate_ok: List[Bool] = [True, True, True, True, False, True, True, True, True, True]
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        f64_column(price, price_ok),
        i64_column(qty, qty_ok),
        i32_column(units, units_ok),
        f32_column(rate, rate_ok),
    )


# --- the customer's functions --------------------------------------------------


def with_tax(p: Float64) -> Float64:
    return p * 1.25


def doubled(q: Int64) -> Int64:
    return q * 2


def plus_one(u: Int32) -> Int32:
    return u + 1


def halve(r: Float32) -> Float32:
    return r * 0.5


def line_total(p: Float64, q: Int64) -> Float64:
    return p * Float64(q)


def capped(p: Float64) raises -> Float64:
    """A UDF that fails: its own error must reach the caller unchanged."""
    if p > 30.0:
        raise Error("capped: price " + String(p) + " is over the cap")
    return p


comptime Gross = Map1[f=with_tax, out_name="gross", in0="price"]
comptime Qty2 = Map1[f=doubled, out_name="qty2", in0="qty"]
comptime UnitsP1 = Map1[f=plus_one, out_name="units_p1", in0="units"]
comptime HalfRate = Map1[f=halve, out_name="half_rate", in0="rate"]
comptime Total = Map2[f=line_total, out_name="total", in0="price", in1="qty"]
comptime Capped = Map1[f=capped, out_name="capped", in0="price"]

comptime GrossRT = MapFnRT[Gross, 0]
comptime Qty2RT = MapFnRT[Qty2, 1]
comptime UnitsP1RT = MapFnRT[UnitsP1, 2]
comptime HalfRateRT = MapFnRT[HalfRate, 3]


# --- the predicate -------------------------------------------------------------


@fieldwise_init
struct PriceQty(AutoKomiraSchema, Copyable, Movable):
    var price: Float64
    var qty: Int64


@fieldwise_init
struct BigLine(FilterFn):
    """Keep a line whose `price * qty` exceeds the captured `min_total`.

    `eval_scalar` returns False for a row with a NULL in any of the four
    columns the projection reads: a NULL predicate input is not TRUE, and
    (see the header) nothing downstream would null the projection out."""

    var min_total: Float64
    comptime InRow = PriceQty
    comptime UDF_ID = UInt32(20_001)

    def keep_row(mut self, row: PriceQty) raises -> Bool:
        return row.price * Float64(row.qty) > self.min_total

    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        for c in range(4):
            if batch.col_is_null(c, i):
                return False
        return self.keep_row(
            PriceQty(
                batch.col_f64(0).load[1](i)[0], batch.col_i64(1).load[1](i)[0]
            )
        )


def _survivors[
    P: FilterFn, bo: Origin[mut=False]
](mut pred: P, bv: BatchView[bo]) raises -> List[Int]:
    """Row indices `pred` keeps, through `Predicate.eval[4]`'s default body.
    The third chunk starts at row 8, so lanes 10 and 11 are past the end and
    must come back False rather than be evaluated (`test_past_the_end_lanes_
    are_never_evaluated` is the check that can see this)."""
    var out = List[Int]()
    var i = 0
    while i < bv.n_rows():
        var mask = pred.eval[4, bo](bv, i)  # the trait's default body
        for lane in range(4):
            if mask[lane]:
                out.append(i + lane)
        i += 4
    return out^


@fieldwise_init
struct KeepAll(FilterFn):
    """Keeps every row it is asked about, without reading the batch, and
    counts the rows it was asked about. Under it, a lane past the end of the
    batch that got evaluated would come back True, so `Predicate.eval`'s
    in-bounds guard is the only thing that keeps rows 10 and 11 out."""

    var asked: Int
    comptime InRow = PriceQty
    comptime UDF_ID = UInt32(20_002)

    def keep_row(mut self, row: PriceQty) raises -> Bool:
        return True

    def eval_scalar[
        bo: Origin[mut=False]
    ](mut self, batch: BatchView[bo], i: Int) raises -> Bool:
        self.asked += 1
        return True


# --- tests -----------------------------------------------------------------------


def test_sugar_schemas_are_the_named_columns() raises:
    """What the plan would see: `Map1`/`Map2` derive their schemas from the
    names at the call site and the dtypes of the function's signature, and
    the `FilterFn` row derives its schema from its fields."""
    var gi = materialize[Gross.InputSchema]()
    var go = materialize[Gross.OutputSchema]()
    assert_equal(gi.cols[0].name, "price")
    assert_equal(gi.cols[0].dtype, DT_F64)
    assert_equal(go.cols[0].name, "gross")
    assert_equal(go.cols[0].dtype, DT_F64)
    assert_equal(materialize[Qty2.InputSchema]().cols[0].dtype, DT_I64)
    assert_equal(materialize[UnitsP1.InputSchema]().cols[0].dtype, DT_I32)
    assert_equal(materialize[HalfRate.OutputSchema]().cols[0].dtype, DT_F32)
    var ti = materialize[Total.InputSchema]()
    assert_equal(ti.num_cols(), 2)
    assert_equal(ti.cols[1].name, "qty")
    assert_equal(ti.cols[1].dtype, DT_I64)
    assert_equal(materialize[Total.OutputSchema]().cols[0].name, "total")
    var fi = materialize[BigLine.InputSchema]()
    assert_equal(fi.num_cols(), 2)
    assert_equal(fi.cols[0].name, "price")
    assert_equal(fi.cols[1].name, "qty")
    assert_equal(fi.cols[1].dtype, DT_I64)
    assert_true(GrossRT.dtype_at[0]() == DType.float64)
    assert_true(Qty2RT.dtype_at[0]() == DType.int64)


def test_predicate_keeps_exactly_the_valid_big_lines() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var pred = BigLine(min_total=15.0)
    var kept = _survivors(pred, bv)
    # The fixture: rows 4 and 9 would pass on value alone, so the lists
    # below can only hold if the NULL refusal ran.
    assert_true(pred.keep_row(PriceQty(6.0, 7)), "row 4 must pass on value")
    assert_true(pred.keep_row(PriceQty(10.0, 2)), "row 9 must pass on value")
    var want: List[Int] = [0, 3, 7, 8]
    assert_equal(len(kept), len(want), "survivor count (NULL rows 4, 9 out)")
    for k in range(len(want)):
        assert_equal(kept[k], want[k], "survivor " + String(k))
    # The capture is the threshold: raising it drops 27 and 30 (rows 8, 0);
    # row 4 (42, rate NULL) stays out.
    var strict = BigLine(min_total=40.0)
    var kept_strict = _survivors(strict, bv)
    assert_equal(len(kept_strict), 2, "strict survivor count (row 4 out)")
    assert_equal(kept_strict[0], 3)
    assert_equal(kept_strict[1], 7)


def test_past_the_end_lanes_are_never_evaluated() raises:
    """`KeepAll` through `eval[4]` over the 10-row batch: chunks at 0, 4, 8;
    the last chunk's lanes 2 and 3 (rows 10, 11) are past the end. Exactly
    rows 0..9 come back, and `eval_scalar` was asked exactly 10 times."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var pred = KeepAll(0)
    var out = _survivors(pred, bv)
    assert_equal(len(out), N_ROWS, "rows kept past the end of the batch")
    for k in range(len(out)):
        assert_equal(out[k], k, "kept row " + String(k))
    assert_equal(pred.asked, N_ROWS, "eval_scalar asked about a row past the end")


def test_filter_then_project() raises:
    """Four `Map1` outputs, one per input dtype, emitted over the survivors."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var pred = BigLine(min_total=15.0)
    var kept = _survivors(pred, bv)

    var projects = ProjectList[GrossRT, Qty2RT, UnitsP1RT, HalfRateRT](
        GrossRT(Gross()), Qty2RT(Qty2()), UnitsP1RT(UnitsP1()), HalfRateRT(HalfRate())
    )
    projects.bind(ColumnResolver.from_arrow_schema(batch.schema))
    var out = projects.emit_projected(bv, kept)

    assert_equal(out.num_rows(), 4)
    assert_equal(out.schema.num_columns(), 4)
    for c in range(4):
        assert_equal(out.column_at(c).null_count(), 0, "out col nulls")
    var gross = out.column_as_primitive_float64(0)
    var qty2 = out.column_as_primitive_int64(1)
    var units = out.column_as_primitive_int32(2)
    var half = out.column_as_primitive_float32(3)
    var want_gross: List[Float64] = [12.5, 31.25, 50.0, 3.75]
    var want_qty2: List[Int64] = [6, 4, 8, 18]
    var want_units: List[Int32] = [2, 5, 9, 10]
    var want_half: List[Float32] = [0.25, 1.0, 0.25, 2.0]
    for r in range(4):
        assert_equal(gross.get(r), want_gross[r], "gross row " + String(r))
        assert_equal(qty2.get(r), want_qty2[r], "qty2 row " + String(r))
        assert_equal(units.get(r), want_units[r], "units_p1 row " + String(r))
        assert_equal(half.get(r), want_half[r], "half_rate row " + String(r))


def test_write_one_matches_project_one() raises:
    """`MapFnRT.write_one` (slot 0 of a one-slot builder) lands the same value
    `project_one` does, for each of the four input dtypes."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var g = GrossRT(Gross())
    var q = Qty2RT(Qty2())
    var u = UnitsP1RT(UnitsP1())
    var h = HalfRateRT(HalfRate())
    var mg = MultiColumnBuilder[ColumnSlot[DType.float64]](column_slot[DType.float64](2))
    var mq = MultiColumnBuilder[ColumnSlot[DType.int64]](column_slot[DType.int64](2))
    var mu = MultiColumnBuilder[ColumnSlot[DType.int32]](column_slot[DType.int32](2))
    var mh = MultiColumnBuilder[ColumnSlot[DType.float32]](column_slot[DType.float32](2))
    var rows: List[Int] = [3, 8]
    for k in range(len(rows)):
        var r = rows[k]
        g.write_one(bv, r, mg)
        q.write_one(bv, r, mq)
        u.write_one(bv, r, mu)
        h.write_one(bv, r, mh)
    var cg = mg.finalize_at[0]()
    var cq = mq.finalize_at[0]()
    var cu = mu.finalize_at[0]()
    var ch = mh.finalize_at[0]()
    assert_equal(cg.length(), 2)
    var sb = SchemaBuilder()
    sb.add_field(Field("g", DType.float64, False))
    sb.add_field(Field("q", DType.int64, False))
    sb.add_field(Field("u", DType.int32, False))
    sb.add_field(Field("h", DType.float32, False))
    var rb = RecordBatch.from_typed_columns_4(sb.build(), cg^, cq^, cu^, ch^)
    assert_equal(rb.column_as_primitive_float64(0).get(0), 31.25)
    assert_equal(rb.column_as_primitive_float64(0).get(1), 3.75)
    assert_equal(rb.column_as_primitive_int64(1).get(0), 4)
    assert_equal(rb.column_as_primitive_int64(1).get(1), 18)
    assert_equal(rb.column_as_primitive_int32(2).get(0), 5)
    assert_equal(rb.column_as_primitive_int32(2).get(1), 10)
    assert_equal(rb.column_as_primitive_float32(3).get(0), 1.0)
    assert_equal(rb.column_as_primitive_float32(3).get(1), 2.0)


def test_two_column_map_over_the_survivors() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var pred = BigLine(min_total=15.0)
    var kept = _survivors(pred, bv)
    var m = Total()
    var want: List[Float64] = [30.0, 50.0, 160.0, 27.0]
    for k in range(len(kept)):
        var r = kept[k]
        var row = Row2[Float64, Int64](
            bv.col_f64(0).load[1](r)[0], bv.col_i64(1).load[1](r)[0]
        )
        assert_equal(m.run_row(row), want[k], "total survivor " + String(k))


def test_a_failing_udf_surfaces_its_own_error() raises:
    """`capped` passes 10.0 and 25.0 and refuses 40.0 (row 7): the projection
    raises, and the message is the customer's, byte for byte."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var pred = BigLine(min_total=15.0)
    var kept = _survivors(pred, bv)
    var projects = ProjectList[MapFnRT[Capped, 0]](MapFnRT[Capped, 0](Capped()))
    var raised = False
    try:
        var out = projects.emit_projected(bv, kept)
        _ = out^
    except e:
        raised = True
        assert_equal(String(e), "capped: price 40.0 is over the cap")
    assert_true(raised, "a raising UDF was swallowed by the projection")
    # The two rows before row 7 are under the cap.
    var first_two: List[Int] = [0, 3]
    var ok = ProjectList[MapFnRT[Capped, 0]](MapFnRT[Capped, 0](Capped()))
    var out2 = ok.emit_projected(bv, first_two)
    assert_equal(out2.column_as_primitive_float64(0).get(0), 10.0)
    assert_equal(out2.column_as_primitive_float64(0).get(1), 25.0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_sugar_schemas_are_the_named_columns]()
    suite.test[test_predicate_keeps_exactly_the_valid_big_lines]()
    suite.test[test_past_the_end_lanes_are_never_evaluated]()
    suite.test[test_filter_then_project]()
    suite.test[test_write_one_matches_project_one]()
    suite.test[test_two_column_map_over_the_survivors]()
    suite.test[test_a_failing_udf_surfaces_its_own_error]()
    suite^.run()
