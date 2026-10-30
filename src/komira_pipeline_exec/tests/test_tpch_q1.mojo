# =============================================================================
# TPC-H Q1 from a hand-built plan, end to end through the driver
# =============================================================================
#
#   SELECT l_returnflag, l_linestatus, SUM(l_quantity), SUM(l_extendedprice),
#          SUM(l_extendedprice * (1 - l_discount)),
#          SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
#          AVG(l_quantity), AVG(l_extendedprice), AVG(l_discount), COUNT(*)
#   FROM lineitem WHERE l_shipdate <= DATE '1998-09-02'
#   GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus
#
# Two segments (`tpch_q1`): scan, filter, project and a string-keyed grouped
# sink; then the sort of its output. The table is written to Parquet twice: in
# row groups of 256, where both key columns are dictionary encoded (with the
# dictionary in a different order from row group to row group), and in row
# groups of four, where the writer falls back to plain encoding for both. Money
# is held in cents, so the expected sums are integers computed here, row by
# row, from the same table, never from the engine; the sums are compared as
# DECIMAL(38,s) values (the unscaled 128-bit integer, its precision and
# scale), the averages as DOUBLEs computed as the design says (one conversion
# of the exact sum and one division by the count). What these tests prove:
#
#   * On eight rows the oracle's answer is the hand-computed one (the numbers
#     are written out below), and the plan returns it, sorted, from the
#     dictionary file and the plain file, with the DICT_ENCODED and with the
#     COLUMNAR sink, on one to four workers.
#   * Over 2,000 generated rows the plan equals the oracle in all four
#     combinations (file x sink), on one, three and seven workers, with row
#     group sized morsels and with morsels that cut across row groups.
#   * The DICT_ENCODED sink makes the Parquet source hand it DICTIONARY
#     columns, and the COLUMNAR sink gets STRING ones; a plain chunk under the
#     DICT_ENCODED sink arrives as STRING and is grouped all the same.
#   * A flag that the filter removes from every row ('R' here, whose dictionary
#     entry is still in the file) is not in the answer.
#   * The pool the sinks drew from is whole again after every run.

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_async_api.token import CancellationToken
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_physical_plan.physical_plan import SegmentDescPod
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.published_outputs import PublishedOutputs
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.tpch_q1 import (
    Q1_CUTOFF,
    Q1Table,
    q1_batch,
    q1_plan,
    q1_sink_data,
    q1_sort_data,
    q1_table,
)
from komira_plan_expr.expr_pool import ExprPool
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _write(name: String, ref t: Q1Table, rows_per_group: Int) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        q1_batch(t, 0, t.rows()), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


struct _Group(Copyable, Movable):
    var flag: String
    var status: String
    var count: Int
    var qty: Int
    var price: Int
    var disc: Int
    var disc_price: Int
    var charge: Int

    def __init__(out self, flag: String, status: String):
        self.flag = flag
        self.status = status
        self.count = 0
        self.qty = 0
        self.price = 0
        self.disc = 0
        self.disc_price = 0
        self.charge = 0


def _oracle(ref t: Q1Table) raises -> List[_Group]:
    """The groups of Q1 over `t`, row at a time, sorted by flag then status."""
    var index = Dict[String, Int]()
    var groups = List[_Group]()
    for r in range(t.rows()):
        if t.shipdate[r] > Q1_CUTOFF:
            continue
        var key = t.flag[r] + "|" + t.status[r]
        if key not in index:
            index[key] = len(groups)
            groups.append(_Group(t.flag[r], t.status[r]))
        var g = index[key]
        groups[g].count += 1
        groups[g].qty += t.quantity[r]
        groups[g].price += t.price[r]
        groups[g].disc += t.discount[r]
        # Cents x hundredths: scale 4, then scale 6.
        var dp = t.price[r] * (100 - t.discount[r])
        groups[g].disc_price += dp
        groups[g].charge += dp * (100 + t.tax[r])
    # Insertion sort by (flag, status); there are a handful of groups.
    for i in range(1, len(groups)):
        var j = i
        while j > 0 and (
            groups[j - 1].flag > groups[j].flag
            or (
                groups[j - 1].flag == groups[j].flag
                and groups[j - 1].status > groups[j].status
            )
        ):
            var tmp = groups[j - 1].copy()
            groups[j - 1] = groups[j].copy()
            groups[j] = tmp^
            j -= 1
    return groups^


def _run_q1(
    path: String, workers: Int, morsel_rows: Int, dict_encoded: Bool
) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var agg = builder.add_agg_sink(q1_sink_data())
    var sort = builder.add_sort_sink(q1_sort_data())
    var descs = q1_plan(path, agg, sort, dict_encoded, morsel_rows)
    var dispatch = InlineDispatch()
    var out = run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )
    assert_equal(builder.pool_granted(), 0)
    return out.take(1)


def _check_decimal(
    ref out: RecordBatch, col: Int, row: Int, want: Int, scale: Int, what: String
) raises:
    ref c = out.column_at(col)
    assert_equal(c.decimal_precision(), 38, what + " precision")
    assert_equal(c.decimal_scale(), scale, what + " scale")
    assert_true(not c.is_null_at(row), what + " is NULL")
    assert_true(c.as_decimal128().get_i128(row) == _w(want), what + " differs")


def _check(ref out: RecordBatch, ref t: Q1Table) raises:
    var want = _oracle(t)
    assert_equal(out.num_rows(), len(want), "number of groups")
    assert_equal(out.num_columns(), 10)
    var flags = out.column_at(0).as_string()
    var statuses = out.column_at(1).as_string()
    for i in range(len(want)):
        ref g = want[i]
        var who = g.flag + g.status
        assert_equal(flags.get(i), g.flag, "flag of row " + String(i))
        assert_equal(statuses.get(i), g.status, "status of row " + String(i))
        _check_decimal(out, 2, i, g.qty, 2, "sum_qty of " + who)
        _check_decimal(out, 3, i, g.price, 2, "sum_base_price of " + who)
        _check_decimal(out, 4, i, g.disc_price, 4, "sum_disc_price of " + who)
        _check_decimal(out, 5, i, g.charge, 6, "sum_charge of " + who)
        var n = Float64(g.count)
        assert_equal(
            out.column_at(6).as_primitive[DType.float64]().get(i),
            Float64(g.qty) / 100.0 / n,
            "avg_qty of " + who,
        )
        assert_equal(
            out.column_at(7).as_primitive[DType.float64]().get(i),
            Float64(g.price) / 100.0 / n,
            "avg_price of " + who,
        )
        assert_equal(
            out.column_at(8).as_primitive[DType.float64]().get(i),
            Float64(g.disc) / 100.0 / n,
            "avg_disc of " + who,
        )
        assert_equal(
            Int(out.column_at(9).as_primitive[DType.int64]().get(i)),
            g.count,
            "count_order of " + who,
        )


def _eight_rows() -> Q1Table:
    var t = Q1Table()
    #     flag status qty   price disc tax date
    t.add("A", "F", 1000, 10000, 5, 8, 8036)  # in
    t.add("A", "F", 2000, 20000, 0, 0, 8037)  # in
    t.add("N", "F", 500, 5000, 10, 2, Q1_CUTOFF)  # the cut-off day: in
    t.add("N", "O", 100, 1000, 0, 0, Q1_CUTOFF + 1)  # a day late: out
    t.add("N", "O", 300, 3000, 10, 10, 9000)  # in
    t.add("R", "F", 700, 7000, 5, 0, 9500)  # in
    t.add("R", "F", 100, 100, 0, 0, 9600)  # in
    t.add("A", "F", 50, 50, 0, 0, 10500)  # out
    return t^


def test_the_oracle_is_the_hand_computed_answer_on_eight_rows() raises:
    # Pins the oracle the other tests compare with, from numbers written out by
    # hand. A F: rows 0 and 1. qty 10.00 + 20.00 = 30.00, price 300.00,
    # disc_price = 10000 x 95 + 20000 x 100 = 2950000 (295.0000), charge =
    # 950000 x 108 + 2000000 x 100 = 302600000 (302.600000).
    var g = _oracle(_eight_rows())
    assert_equal(len(g), 4)
    assert_equal(g[0].flag + g[0].status, "AF")
    assert_equal(g[0].count, 2)
    assert_equal(g[0].qty, 3000)
    assert_equal(g[0].price, 30000)
    assert_equal(g[0].disc_price, 2950000)
    assert_equal(g[0].charge, 302600000)
    assert_equal(g[0].disc, 5)
    # N F: row 2 alone. N O: row 4 alone (row 3 is a day late).
    assert_equal(g[1].flag + g[1].status, "NF")
    assert_equal(g[1].disc_price, 450000)
    assert_equal(g[1].charge, 45900000)
    assert_equal(g[2].flag + g[2].status, "NO")
    assert_equal(g[2].count, 1)
    assert_equal(g[2].qty, 300)
    assert_equal(g[2].disc_price, 270000)
    assert_equal(g[2].charge, 29700000)
    # R F: rows 5 and 6. disc_price = 7000 x 95 + 100 x 100 = 675000,
    # charge = 665000 x 100 + 10000 x 100 = 67500000.
    assert_equal(g[3].flag + g[3].status, "RF")
    assert_equal(g[3].count, 2)
    assert_equal(g[3].price, 7100)
    assert_equal(g[3].disc_price, 675000)
    assert_equal(g[3].charge, 67500000)


def test_q1_on_eight_rows_is_the_hand_computed_answer_from_both_files() raises:
    var t = _eight_rows()
    var dict_path = _write("q1_eight_dict", t, 8)
    var plain_path = _write("q1_eight_plain", t, 4)
    for workers in range(1, 5):
        for dict_encoded in [False, True]:
            for path in [dict_path, plain_path]:
                var out = _run_q1(path, workers, 3, dict_encoded)
                _check(out, t)
    # The averages of A F and R F, written out: (10.00 + 20.00) / 2 = 15,
    # (100.00 + 200.00) / 2 = 150, (0.05 + 0.00) / 2 = 0.025.
    var out = _run_q1(dict_path, 2, 0, True)
    var avg_qty = out.column_at(6).as_primitive[DType.float64]()
    var avg_price = out.column_at(7).as_primitive[DType.float64]()
    var avg_disc = out.column_at(8).as_primitive[DType.float64]()
    assert_equal(avg_qty.get(0), 15.0)
    assert_equal(avg_price.get(0), 150.0)
    assert_equal(avg_disc.get(0), 0.025)
    assert_equal(avg_price.get(3), 35.5)


def test_q1_over_generated_rows_equals_the_oracle_in_every_combination() raises:
    var t = q1_table(2000)
    var want = _oracle(t)
    assert_equal(len(want), 4)
    assert_true(want[0].count > 100)
    var dict_path = _write("q1_gen_dict", t, 256)
    var plain_path = _write("q1_gen_plain", t, 4)
    var worker_counts = List[Int]()
    worker_counts.append(1)
    worker_counts.append(3)
    worker_counts.append(7)
    for k in range(len(worker_counts)):
        for dict_encoded in [False, True]:
            _check(_run_q1(dict_path, worker_counts[k], 0, dict_encoded), t)
            _check(_run_q1(dict_path, worker_counts[k], 97, dict_encoded), t)
            _check(_run_q1(plain_path, worker_counts[k], 0, dict_encoded), t)
            _check(_run_q1(plain_path, worker_counts[k], 97, dict_encoded), t)


def _first_key_type(path: String, dict_encoded: Bool) raises -> ArrowType:
    """The type of the key column of the first morsel the source of segment 0
    hands the workers."""
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var agg_id = builder.add_agg_sink(q1_sink_data())
    var sort_id = builder.add_sort_sink(q1_sort_data())
    var descs = q1_plan(path, agg_id, sort_id, dict_encoded, 0)
    var published = PublishedOutputs(2)
    var source = builder.build_source(descs[0], published, 1)
    var morsel = source.next_morsel(0)
    assert_true(Bool(morsel), "the source gave no morsel")
    return morsel.value().batch.column_at(0).arrow_type


def test_the_dict_encoded_sink_gets_dictionary_columns_and_the_other_gets_strings() raises:
    var t = q1_table(1024)
    var dict_path = _write("q1_src_dict", t, 256)
    var plain_path = _write("q1_src_plain", t, 4)
    assert_equal(_first_key_type(dict_path, True), ArrowType.DICTIONARY)
    assert_equal(_first_key_type(dict_path, False), ArrowType.STRING)
    # A chunk that fell back to plain encoding has no dictionary to keep.
    assert_equal(_first_key_type(plain_path, True), ArrowType.STRING)
    assert_equal(_first_key_type(plain_path, False), ArrowType.STRING)


def test_a_flag_the_filter_removes_from_every_row_is_not_in_the_answer() raises:
    var t = q1_table(1024)
    for r in range(t.rows()):
        if t.flag[r] == "R":
            t.shipdate[r] = Q1_CUTOFF + 100
    var path = _write("q1_no_r", t, 256)
    var want = _oracle(t)
    assert_equal(len(want), 3)
    for workers in range(1, 4):
        for dict_encoded in [False, True]:
            var out = _run_q1(path, workers, 0, dict_encoded)
            _check(out, t)
            assert_equal(out.num_rows(), 3)
            var flags = out.column_at(0).as_string()
            for i in range(out.num_rows()):
                assert_true(flags.get(i) != "R", "the flag R is in the answer")


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_oracle_is_the_hand_computed_answer_on_eight_rows]()
    suite.test[test_q1_on_eight_rows_is_the_hand_computed_answer_from_both_files]()
    suite.test[test_q1_over_generated_rows_equals_the_oracle_in_every_combination]()
    suite.test[test_the_dict_encoded_sink_gets_dictionary_columns_and_the_other_gets_strings]()
    suite.test[test_a_flag_the_filter_removes_from_every_row_is_not_in_the_answer]()
    suite^.run()
