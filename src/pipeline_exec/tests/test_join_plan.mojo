# =============================================================================
# Inner equi joins as hand-built plans, end to end
# =============================================================================
#
# A join is a build segment ending in SINK_HASH_BUILD and a probe segment whose
# chain carries OP_JOIN_PROBE naming it, written by hand (`join_harness`) and
# run through `run_plan` and `RealBuilder` on a dispatcher that runs the
# workers one after another. Every answer is compared as a multiset of rows
# (worker schedules change the order) with the nested-loop join of
# `join_harness`, computed from the same tables. What these tests prove:
#
#   * A resident probe side joined to a resident build side equals the oracle on
#     one, two, three and seven workers and on morsel sizes that split both
#     inputs; the build side's output is taken by the probe and not returned.
#   * A Parquet scan of several row groups as the probe side joins to a resident
#     build side as the oracle does.
#   * A filter before the probe (a selection mask the probe gathers) and a
#     projection after it give the oracle's rows with the projected columns; a
#     filter after the probe reads the build side's columns.
#   * Two probes in one chain, over two build segments, equal the oracle, with
#     names that do not collide and with names that do (`o_id_right`).
#   * A probe segment whose source is another segment's output (a sort) joins as
#     the oracle does, and a segment that reads the join's own output sees its
#     rows.
#   * An empty build side, a probe that matches nothing and a build side of only
#     NULL keys give no row, and the result batch still has the join's schema:
#     the probe columns, then the build columns.
#   * A probe whose build segment is not among its dependencies is refused by
#     name, and so is a probe the operator does not serve (a LEFT join).
#   * The same plan run twice on one builder gives the same rows, and the
#     segment pool holds nothing after each run.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from arrow.schema import RecordBatch
from async_api.token import CancellationToken
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from physical_plan.physical_plan import MorselOp, SegmentDescPod, SortSinkData
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.join_harness import (
        build_segment,
    customer_batch,
    expect_rows,
    expected_rows,
    keep_rows,
    key_names,
    nation_batch,
    null_key_customer_batch,
    oracle_join,
    orders_batch,
    probe_op,
    probe_segment,
    refund_batch,
    rows_of,
    select_columns,
    sorted_rows,
    table_of,
    with_build_dep,
)
from pipeline_exec.plan_harness import (
    batch_segment,
    chain,
    column_names,
    output_segment,
    parquet_segment,
    project_columns,
    with_sort_sink,
)
from pipeline_exec.published_outputs import PublishedOutputs
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_builder import SegmentBuilder
from plan_expr.expr import BIN_AND, BIN_GE, BIN_GT, BIN_LT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import JOIN_LEFT
from runtime_paths import test_tmpdir


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), _lit(v))


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _flags(a: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    return out^


def _counts() -> List[Int]:
    """The worker counts every plan runs on."""
    var out = List[Int]()
    out.append(1)
    out.append(2)
    out.append(3)
    out.append(7)
    return out^


def _two(var a: SegmentDescPod, var b: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(a^)
    out.append(b^)
    return out^


def _three(
    var a: SegmentDescPod, var b: SegmentDescPod, var c: SegmentDescPod
) -> List[SegmentDescPod]:
    var out = _two(a^, b^)
    out.append(c^)
    return out^


def _run[
    B: SegmentBuilder
](ref descs: List[SegmentDescPod], mut builder: B, workers: Int) raises -> PublishedOutputs:
    var dispatch = InlineDispatch()
    return run_plan(
        descs, builder, dispatch, workers, CancellationToken.new()
    )


def _write(
    name: String, ref batch: RecordBatch, rows_per_group: Int
) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        batch, max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _expect_names(ref batch: RecordBatch, want: List[String]) raises:
    var got = column_names(batch)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "column " + String(i))


def _joined_names() -> List[String]:
    """The columns of orders joined to customers."""
    var out = _names("o_id", "o_custkey", "o_total")
    out.append("c_custkey")
    out.append("c_name")
    out.append("c_nation")
    return out^


def _orders_x_customers(orders_rows: Int, customers: Int) raises -> List[String]:
    return expected_rows(
        orders_batch(0, orders_rows),
        customer_batch(customers),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )


# ---- resident sides ------------------------------------------------------------


def test_a_resident_join_equals_the_oracle_on_one_to_seven_workers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var want = _orders_x_customers(100, 25)
    assert_true(len(want) > 50)
    var sizes = List[Int]()
    sizes.append(7)
    sizes.append(16)
    var workers = _counts()
    for s in range(len(sizes)):
        var descs = _two(
            build_segment(0, customers, morsel_rows=6),
            probe_segment(
                1,
                orders,
                0,
                key_names("o_custkey"),
                key_names("c_custkey"),
                sizes[s],
            ),
        )
        for w in range(len(workers)):
            var out = _run(descs, builder, workers[w])
            assert_false(out.has(0))
            var batch = out.take(1)
            _expect_names(batch, _joined_names())
            expect_rows(
                rows_of(batch),
                want,
                "morsel " + String(sizes[s]) + ", workers " + String(workers[w]),
            )
            assert_equal(builder.pool_granted(), 0)


def test_the_same_plan_run_twice_on_one_builder_gives_the_same_rows() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var descs = _two(
        build_segment(0, customers, morsel_rows=6),
        probe_segment(
            1, orders, 0, key_names("o_custkey"), key_names("c_custkey"), 9
        ),
    )
    var first = _run(descs, builder, 3)
    var first_rows = rows_of(first.take(1))
    assert_equal(builder.pool_granted(), 0)
    var second = _run(descs, builder, 2)
    var second_rows = rows_of(second.take(1))
    assert_equal(builder.pool_granted(), 0)
    expect_rows(first_rows, _orders_x_customers(100, 25), "first run")
    expect_rows(second_rows, first_rows, "second run")


# ---- a Parquet probe side --------------------------------------------------------


def test_a_parquet_probe_scan_joins_a_resident_build_side() raises:
    var path = _write("join_probe_scan", orders_batch(0, 90), 20)
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var scan = with_build_dep(
        parquet_segment(
            1,
            path,
            ops=chain(
                probe_op(0, key_names("o_custkey"), key_names("c_custkey"))
            ),
            morsel_rows=16,
        ),
        0,
    )
    var descs = _two(build_segment(0, customers), scan^)
    var want = _orders_x_customers(90, 25)
    assert_true(len(want) > 0)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        var batch = out.take(1)
        _expect_names(batch, _joined_names())
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_equal(builder.pool_granted(), 0)


# ---- operators around the probe -----------------------------------------------------


def test_a_filter_before_the_probe_and_a_projection_after_it() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    # Orders 20 .. 69 reach the probe as a selection mask.
    var ops = chain(
        MorselOp.filter(
            Expr.binary(BIN_AND, _cmp(BIN_GE, "o_id", 20), _cmp(BIN_LT, "o_id", 70))
        ),
        probe_op(0, key_names("o_custkey"), key_names("c_custkey")),
        project_columns(_names("c_name", "o_id")),
    )
    var descs = _two(
        build_segment(0, customers),
        with_build_dep(batch_segment(1, orders, ops^, 11), 0),
    )
    var want = sorted_rows(
        select_columns(
            oracle_join(
                table_of(orders_batch(20, 50)),
                table_of(customer_batch(25)),
                key_names("o_custkey"),
                key_names("c_custkey"),
            ),
            _names("c_name", "o_id"),
        )
    )
    assert_true(len(want) > 0)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        var batch = out.take(1)
        _expect_names(batch, _names("c_name", "o_id"))
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_equal(builder.pool_granted(), 0)


def test_a_filter_after_the_probe_reads_the_build_columns() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var ops = chain(
        probe_op(0, key_names("o_custkey"), key_names("c_custkey")),
        MorselOp.filter(_cmp(BIN_GT, "c_nation", 0)),
    )
    var descs = _two(
        build_segment(0, customers),
        with_build_dep(batch_segment(1, orders, ops^, 13), 0),
    )
    # The rows of the join whose customer has a non-NULL nation above 0.
    var joined = oracle_join(
        table_of(orders_batch(0, 100)),
        table_of(customer_batch(25)),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    var nation = joined.column("c_nation")
    var keep = List[Bool]()
    for r in range(joined.num_rows()):
        var cell = joined.shown[r][nation].copy()
        keep.append(cell == "1" or cell == "2")
    var want = sorted_rows(keep_rows(joined, keep))
    assert_true(len(want) > 0)
    assert_true(len(want) < joined.num_rows())
    var out = _run(descs, builder, 3)
    expect_rows(rows_of(out.take(1)), want, "filter after the probe")
    assert_equal(builder.pool_granted(), 0)


# ---- two probes in one chain -----------------------------------------------------------


def test_two_probes_in_one_chain_over_two_build_segments() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var nations = builder.add_resident(nation_batch(4))
    var orders = builder.add_resident(orders_batch(0, 100))
    # orders -> customer on the order's key, then -> nation on the customer's
    # nation.
    var ops = chain(
        probe_op(0, key_names("o_custkey"), key_names("c_custkey")),
        probe_op(1, key_names("c_nation"), key_names("n_nationkey")),
    )
    var probe = with_build_dep(
        with_build_dep(batch_segment(2, orders, ops^, 10), 0), 1
    )
    var descs = _three(
        build_segment(0, customers, morsel_rows=8),
        build_segment(1, nations),
        probe^,
    )
    var first = oracle_join(
        table_of(orders_batch(0, 100)),
        table_of(customer_batch(25)),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    var want = sorted_rows(
        oracle_join(
            first,
            table_of(nation_batch(4)),
            key_names("c_nation"),
            key_names("n_nationkey"),
        )
    )
    assert_true(len(want) > 0)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        assert_false(out.has(0))
        assert_false(out.has(1))
        var batch = out.take(2)
        var names = _joined_names()
        names.append("n_nationkey")
        names.append("n_name")
        _expect_names(batch, names)
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_equal(builder.pool_granted(), 0)


def test_two_probes_whose_build_names_collide_with_the_chain() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var refunds = builder.add_resident(refund_batch(30))
    var orders = builder.add_resident(orders_batch(0, 100))
    var ops = chain(
        probe_op(0, key_names("o_custkey"), key_names("c_custkey")),
        probe_op(1, key_names("o_id"), key_names("o_id")),
    )
    var probe = with_build_dep(
        with_build_dep(batch_segment(2, orders, ops^, 10), 0), 1
    )
    var descs = _three(
        build_segment(0, customers),
        build_segment(1, refunds),
        probe^,
    )
    var first = oracle_join(
        table_of(orders_batch(0, 100)),
        table_of(customer_batch(25)),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    var second = oracle_join(
        first, table_of(refund_batch(30)), key_names("o_id"), key_names("o_id")
    )
    var want = sorted_rows(second)
    assert_true(len(want) > 0)
    var out = _run(descs, builder, 3)
    var batch = out.take(2)
    var names = _joined_names()
    names.append("o_id_right")
    names.append("o_total_right")
    names.append("reason")
    _expect_names(batch, names)
    expect_rows(rows_of(batch), want, "colliding names")
    assert_equal(builder.pool_granted(), 0)


# ---- a probe whose source is another segment's output ----------------------------------


def test_a_probe_reads_the_output_of_a_sort_segment() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var sort_id = builder.add_sort_sink(
        SortSinkData(_names("o_id"), _flags(True), 0, _flags(True))
    )
    var sorted_orders = with_sort_sink(
        batch_segment(1, orders, morsel_rows=16), sort_id
    )
    var probe = with_build_dep(
        output_segment(
            2,
            1,
            chain(probe_op(0, key_names("o_custkey"), key_names("c_custkey"))),
            12,
        ),
        0,
    )
    var descs = _three(build_segment(0, customers), sorted_orders^, probe^)
    var want = _orders_x_customers(100, 25)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        assert_false(out.has(0))
        assert_false(out.has(1))
        var batch = out.take(2)
        _expect_names(batch, _joined_names())
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_equal(builder.pool_granted(), 0)


def test_a_segment_reads_the_output_of_a_join() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var descs = _three(
        build_segment(0, customers),
        probe_segment(
            1, orders, 0, key_names("o_custkey"), key_names("c_custkey"), 10
        ),
        output_segment(
            2, 1, chain(project_columns(_names("o_id", "c_name"))), 9
        ),
    )
    var want = sorted_rows(
        select_columns(
            oracle_join(
                table_of(orders_batch(0, 100)),
                table_of(customer_batch(25)),
                key_names("o_custkey"),
                key_names("c_custkey"),
            ),
            _names("o_id", "c_name"),
        )
    )
    var out = _run(descs, builder, 3)
    assert_false(out.has(1))
    var batch = out.take(2)
    _expect_names(batch, _names("o_id", "c_name"))
    expect_rows(rows_of(batch), want, "joined output read on")
    assert_equal(builder.pool_granted(), 0)


# ---- no row, and the schema --------------------------------------------------------------


def test_an_empty_build_side_gives_no_row_and_the_joined_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    # No customer has a nation above 1000.
    var nobody = build_segment(
        0, customers, chain(MorselOp.filter(_cmp(BIN_GT, "c_nation", 1000)))
    )
    var descs = _two(
        nobody^,
        probe_segment(
            1, orders, 0, key_names("o_custkey"), key_names("c_custkey"), 10
        ),
    )
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        var batch = out.take(1)
        assert_equal(batch.num_rows(), 0)
        _expect_names(batch, _joined_names())
        assert_equal(builder.pool_granted(), 0)


def test_a_probe_that_matches_no_row_gives_the_joined_schema() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    # Customer keys are 0 .. 9; the orders kept have keys 10 .. 12.
    var customers = builder.add_resident(customer_batch(10))
    var orders = builder.add_resident(orders_batch(0, 100))
    var ops = chain(
        MorselOp.filter(_cmp(BIN_GE, "o_custkey", 10)),
        probe_op(0, key_names("o_custkey"), key_names("c_custkey")),
    )
    var descs = _two(
        build_segment(0, customers),
        with_build_dep(batch_segment(1, orders, ops^, 10), 0),
    )
    var out = _run(descs, builder, 3)
    var batch = out.take(1)
    assert_equal(batch.num_rows(), 0)
    _expect_names(batch, _joined_names())
    assert_equal(builder.pool_granted(), 0)


def test_a_build_side_of_only_null_keys_gives_no_row() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(null_key_customer_batch(12))
    var orders = builder.add_resident(orders_batch(0, 100))
    var descs = _two(
        build_segment(0, customers),
        probe_segment(
            1, orders, 0, key_names("o_custkey"), key_names("c_custkey"), 10
        ),
    )
    var out = _run(descs, builder, 3)
    var batch = out.take(1)
    assert_equal(batch.num_rows(), 0)
    _expect_names(batch, _joined_names())
    assert_equal(builder.pool_granted(), 0)


# ---- what the builder refuses ----------------------------------------------------------------


def test_a_probe_whose_build_segment_is_not_a_dependency_is_refused() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 10))
    var ops = chain(probe_op(0, key_names("o_custkey"), key_names("c_custkey")))
    # Segment 1 names the build side of segment 0 and does not depend on it.
    var descs = _two(
        build_segment(0, customers), batch_segment(1, orders, ops^)
    )
    with assert_raises(
        contains="the join probe of segment 1 reads the build side of segment"
        " 0, which is not among its dependencies"
    ):
        _ = _run(descs, builder, 2)


def test_a_probe_the_operator_does_not_serve_fails_the_plan_by_name() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 10))
    var ops = chain(
        MorselOp.join_probe(
            0, key_names("o_custkey"), key_names("c_custkey"), JOIN_LEFT
        )
    )
    var descs = _two(
        build_segment(0, customers),
        with_build_dep(batch_segment(1, orders, ops^), 0),
    )
    with assert_raises(contains="OP_JOIN_PROBE refuses join type 1"):
        _ = _run(descs, builder, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
