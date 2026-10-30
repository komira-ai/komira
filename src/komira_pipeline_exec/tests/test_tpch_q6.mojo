# =============================================================================
# TPC-H Q6 from a hand-built plan, end to end through the driver
# =============================================================================
#
#   SELECT SUM(l_extendedprice * l_discount) FROM lineitem
#   WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01'
#     AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24
#
# The table is written to Parquet with `komira_parquet_writer` in several row
# groups, with the column types of the real files (DECIMAL(15,2) money and
# quantity, DATE32 ship date). Money is held in cents, so the expected sum is
# an integer computed here, row by row, from the same table, never from the
# engine, and the answer is compared as a DECIMAL(38,4) value (the unscaled
# 128-bit integer, its precision and scale), not as a float. What these tests
# prove:
#
#   * On the boundary rows, the answer is the hand-computed 954.9401: the first
#     and last day of the year are in and the day before and the exclusive end
#     are out; discounts 0.05 and 0.07 are in and 0.04 and 0.08 out; quantity
#     23.99 is in and 24.00 out; a NULL discount drops its row and a NULL price
#     leaves the sum without that row's product.
#   * The filter alone keeps exactly the five boundary rows that satisfy the
#     predicate (including the one with a NULL price), in file order.
#   * Over 3,000 generated rows in twelve row groups, the answer equals the
#     row-at-a-time oracle on one, three and seven workers and on morsels that
#     do not divide the row groups, and the table has rows rejected by each
#     conjunct on its own, so no conjunct goes unchecked.
#   * Giving the scan the predicate as its decode filter too gives the same sum.
#   * The pool the sink drew from is whole again after each run.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import RecordBatch
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import MorselOp, SegmentDescPod
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.plan_harness import chain, parquet_segment
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.tpch_q6 import (
    LineitemTable,
    Q6_DATE_FROM,
    Q6_DATE_TO,
    lineitem_batch,
    q6_boundary_table,
    q6_predicate,
    q6_projection,
    q6_segment,
    q6_sink_data,
    q6_table,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_string


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _write(name: String, ref t: LineitemTable, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        lineitem_batch(t, 0, t.rows()), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


struct _Oracle(Movable):
    """What a row-at-a-time evaluation of Q6 gives, in cents x cents."""

    var revenue: Int
    var passing: Int
    var summed: Int
    var rejected_by_date: Int
    var rejected_by_discount: Int
    var rejected_by_quantity: Int

    def __init__(out self):
        self.revenue = 0
        self.passing = 0
        self.summed = 0
        self.rejected_by_date = 0
        self.rejected_by_discount = 0
        self.rejected_by_quantity = 0


def _oracle(ref t: LineitemTable) -> _Oracle:
    var o = _Oracle()
    for r in range(t.rows()):
        # A NULL discount makes the predicate UNKNOWN, which drops the row.
        if t.discount_null[r]:
            continue
        var date_ok = t.shipdate[r] >= Q6_DATE_FROM and t.shipdate[r] < Q6_DATE_TO
        var disc_ok = t.discount[r] >= 5 and t.discount[r] <= 7
        var qty_ok = t.quantity[r] < 2400
        if not date_ok and disc_ok and qty_ok:
            o.rejected_by_date += 1
        if not disc_ok and date_ok and qty_ok:
            o.rejected_by_discount += 1
        if not qty_ok and date_ok and disc_ok:
            o.rejected_by_quantity += 1
        if date_ok and disc_ok and qty_ok:
            o.passing += 1
            if not t.price_null[r]:
                o.summed += 1
                o.revenue += t.price[r] * t.discount[r]
    return o^


def _run_q6(
    path: String, workers: Int, morsel_rows: Int, push: Bool = False
) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var id = builder.add_agg_sink(q6_sink_data())
    var descs = List[SegmentDescPod]()
    descs.append(q6_segment(0, path, id, morsel_rows, push))
    var dispatch = InlineDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    assert_equal(builder.pool_granted(), 0)
    return out.take(0)


def _check_revenue(ref batch: RecordBatch, want_cents: Int) raises:
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.schema.field_name(0), "revenue")
    ref col = batch.column_at(0)
    assert_equal(col.decimal_precision(), 38)
    assert_equal(col.decimal_scale(), 4)
    assert_true(not col.is_null_at(0))
    var got = col.as_decimal128().get_i128(0)
    assert_true(
        got == _w(want_cents),
        "revenue " + decimal_to_string(got, 4) + ", wanted "
        + decimal_to_string(_w(want_cents), 4),
    )


def test_q6_on_the_boundary_rows_is_the_hand_computed_revenue() raises:
    var t = q6_boundary_table()
    var path = _write("q6_boundary", t, 4)
    # The rows that qualify, as price x discount in units of 0.0001:
    #   100000 x 5 + 234567 x 7 + 5 x 6 + 1234567 x 6
    #   = 500000 + 1641969 + 30 + 7407402 = 9549401, that is 954.9401.
    var o = _oracle(t)
    assert_equal(o.revenue, 9549401)
    assert_equal(o.passing, 5)
    assert_equal(o.summed, 4)
    for workers in range(1, 6):
        for morsel_rows in range(2, 5):
            var batch = _run_q6(path, workers, morsel_rows)
            _check_revenue(batch, 9549401)
            assert_equal(
                decimal_to_string(batch.column_at(0).as_decimal128().get_i128(0), 4),
                "954.9401",
            )


def test_the_q6_filter_keeps_the_five_boundary_rows_that_satisfy_it() raises:
    var t = q6_boundary_table()
    var path = _write("q6_filter_only", t, 4)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var descs = List[SegmentDescPod]()
    descs.append(
        parquet_segment(
            0, path, Optional(q6_projection()), None,
            chain(MorselOp.filter(q6_predicate())), 3,
        )
    )
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 3, CancellationToken.new())
    var batch = out.take(0)
    # Rows 0, 1, 7, 8 and 9 of the table, in file order.
    assert_equal(batch.num_rows(), 5)
    var days = batch.column_at(0).as_primitive[DType.int32]()
    var want = List[Int]()
    want.append(Q6_DATE_FROM)
    want.append(Q6_DATE_TO - 1)
    want.append(Q6_DATE_FROM + 20)
    want.append(Q6_DATE_FROM + 200)
    want.append(Q6_DATE_FROM + 30)
    for i in range(5):
        assert_equal(Int(days.get(i)), want[i], "row " + String(i))


def test_q6_over_generated_rows_equals_the_oracle_on_every_worker_count() raises:
    var t = q6_table(3000)
    var path = _write("q6_generated", t, 250)
    var o = _oracle(t)
    # Each conjunct, alone, rejects some row; the sum has many terms.
    assert_true(o.rejected_by_date > 100, "date rejects " + String(o.rejected_by_date))
    assert_true(o.rejected_by_discount > 100, "discount rejects " + String(o.rejected_by_discount))
    assert_true(o.rejected_by_quantity > 20, "quantity rejects " + String(o.rejected_by_quantity))
    assert_true(o.summed > 50, "rows summed " + String(o.summed))
    var worker_counts = List[Int]()
    worker_counts.append(1)
    worker_counts.append(3)
    worker_counts.append(7)
    for k in range(len(worker_counts)):
        _check_revenue(_run_q6(path, worker_counts[k], 128), o.revenue)
        _check_revenue(_run_q6(path, worker_counts[k], 97), o.revenue)


def test_q6_with_the_predicate_also_pushed_to_the_scan_gives_the_same_sum() raises:
    var t = q6_table(3000)
    var path = _write("q6_pushed", t, 250)
    var o = _oracle(t)
    _check_revenue(_run_q6(path, 3, 128, True), o.revenue)
    var small = q6_boundary_table()
    var small_path = _write("q6_pushed_boundary", small, 4)
    _check_revenue(_run_q6(small_path, 2, 3, True), 9549401)


def main() raises:
    var suite = TestSuite()
    suite.test[test_q6_on_the_boundary_rows_is_the_hand_computed_revenue]()
    suite.test[test_the_q6_filter_keeps_the_five_boundary_rows_that_satisfy_it]()
    suite.test[test_q6_over_generated_rows_equals_the_oracle_on_every_worker_count]()
    suite.test[test_q6_with_the_predicate_also_pushed_to_the_scan_gives_the_same_sum]()
    suite^.run()
