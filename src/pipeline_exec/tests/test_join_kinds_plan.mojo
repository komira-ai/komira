# =============================================================================
# LEFT, RIGHT, FULL, SEMI, ANTI and CROSS joins as hand-built plans
# =============================================================================
#
# The plans of `test_join_plan`, with the probe's join type changed: a build
# segment ending in SINK_HASH_BUILD and a probe segment whose chain carries an
# OP_JOIN_PROBE, written by hand (`join_harness`) and run through `run_plan`
# and `RealBuilder` on a dispatcher that runs the workers one after another.
# Every answer is compared as a multiset of rows with a nested-loop join
# written in this file for each kind, over the tables of `join_harness`
# (orders probing customers: NULL keys, duplicate keys and keys with no
# partner on both sides). RIGHT and FULL owe the build rows no probe row
# matched, which the segment's driver pushes after the workers have finished
# (the operator's tail). What these tests prove:
#
#   test_a_left_join_equals_the_oracle_on_one_to_seven_workers
#   test_a_right_join_equals_the_oracle_on_one_to_seven_workers
#   test_a_full_join_equals_the_oracle_on_one_to_seven_workers
#   test_a_semi_join_equals_the_oracle_on_one_to_seven_workers
#   test_an_anti_join_equals_the_oracle_on_one_to_seven_workers
#   test_a_cross_join_equals_the_oracle_on_one_to_seven_workers
#       Each kind over a large and a small probe side, on one, two, three and
#       seven workers and on morsel sizes of 0 (the default), 5 and 16 rows,
#       gives the oracle's rows and column names; the pool holds nothing after.
#   test_every_keyed_kind_over_a_build_side_of_only_null_keys_equals_the_oracle
#       A build side of only NULL keys matches nothing: LEFT, FULL and ANTI keep
#       every probe row, RIGHT and FULL give every build row, SEMI gives none.
#   test_every_kind_over_an_empty_build_side_equals_the_oracle
#       LEFT, FULL and ANTI keep every probe row; RIGHT, SEMI and CROSS give none.
#   test_right_and_full_give_each_unmatched_build_row_exactly_once
#       The tail lists each unmatched build row once on every worker count.
#   test_a_right_or_full_probe_side_that_yields_no_row_gives_every_build_row
#       With a filter rejecting every probe row, the result is every build row,
#       the probe columns NULL, nullable and of the probe's types, whatever the
#       size (0 default, 1, 4) of the tail's batches.
#   test_a_projection_before_the_probe_names_and_types_the_tail_probe_columns
#   test_a_projection_before_the_probe_of_a_right_join_equals_the_oracle
#       The tail's probe columns are those the projection before the probe
#       leaves (renamed, dropped, reordered), with no probe row and with some.
#   test_a_tail_flows_through_a_filter_after_the_probe
#       A filter after a RIGHT or FULL probe is applied to the tail's rows.
#   test_a_tail_is_counted_by_an_ungrouped_aggregation_in_the_probe_segment
#   test_a_tail_is_counted_by_an_aggregation_segment_after_the_probe_segment
#       COUNT(*) over a RIGHT or FULL join counts the tail's rows.
#   test_a_limit_after_a_right_probe_stops_at_its_count
#   test_a_limit_inside_the_tail_ends_the_tail
#       A limit after the probe returns exactly its count, also when only the
#       tail reaches it, and the whole tail when the tail is shorter.
#   test_the_tail_of_a_right_probe_is_probed_by_the_next_right_probe
#       Two probes in one chain give the oracle's rows: the first probe's tail
#       rows are probed by the second, whose tail follows.
#   test_a_spent_limit_between_two_right_probes_keeps_the_later_tail
#       RIGHT probe, LIMIT 0, RIGHT probe: the limit ends the first probe's
#       tail, and the second probe still emits every one of its build rows.
#   test_a_cross_join_that_names_a_key_is_refused_by_name
#       A CROSS probe with keys fails the plan with the operator's refusal.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, SchemaBuilder
from async_api.token import CancellationToken
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import MorselOp, SegmentDescPod
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.join_harness import (
    NULL_TEXT,
    JoinTable,
    build_segment,
    customer_batch,
    expect_rows,
    keep_rows,
    key_names,
    null_key_customer_batch,
    nation_batch,
    oracle_join_kind,
    orders_batch,
    rows_of,
    select_columns,
    sorted_rows,
    table_of,
    with_build_dep,
)
from pipeline_exec.plan_harness import (
    agg_list,
    batch_segment,
    chain,
    column_names,
    output_segment,
    ungrouped_agg_data,
    with_agg_sink,
)
from pipeline_exec.published_outputs import PublishedOutputs
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.segment_builder import SegmentBuilder
from plan_expr.agg_expr import AGG_COUNT, AggExpr
from plan_expr.expr import BIN_GT, BIN_LT, Expr, UN_IS_NULL
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    JOIN_ANTI,
    JOIN_CROSS,
    JOIN_FULL,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
)


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


def _counts() -> List[Int]:
    """The worker counts every plan runs on."""
    return [1, 2, 3, 7]


def _sizes() -> List[Int]:
    """The probe morsel sizes: the default (0), then two that split both
    inputs."""
    return [0, 5, 16]


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


def _expect_names(ref batch: RecordBatch, want: List[String]) raises:
    var got = column_names(batch)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "column " + String(i))


def _type_at(ref batch: RecordBatch, i: Int) -> ArrowType:
    return batch.schema.field_at_unchecked(i).arrow_type


def _nullable_at(ref batch: RecordBatch, i: Int) -> Bool:
    return batch.schema.field_at_unchecked(i).nullable


def _count_of(ref batch: RecordBatch) raises -> Int:
    return Int(batch.column_at(0).as_primitive[DType.int64]().get(0))


def _kinds() -> List[UInt8]:
    """The keyed kinds."""
    return [JOIN_LEFT, JOIN_RIGHT, JOIN_FULL, JOIN_SEMI, JOIN_ANTI]


def _customers(rows: Int, null_keys: Bool) raises -> RecordBatch:
    if null_keys:
        return null_key_customer_batch(rows)
    return customer_batch(rows)


def _probe_keys(kind: UInt8) -> List[String]:
    if kind == JOIN_CROSS:
        return List[String]()
    return key_names("o_custkey")


def _build_keys(kind: UInt8) -> List[String]:
    if kind == JOIN_CROSS:
        return List[String]()
    return key_names("c_custkey")


def _probe(build_seg: Int, kind: UInt8) -> MorselOp:
    """An OP_JOIN_PROBE of `kind` over orders and customers: no key for a CROSS
    join, the customer key otherwise."""
    return MorselOp.join_probe(
        build_seg, _probe_keys(kind), _build_keys(kind), kind
    )


def _probe_desc(
    seg_id: Int, handle: Int, var ops: Slab[MorselOp], morsel_rows: Int
) -> SegmentDescPod:
    """A segment over resident batch `handle` with `ops`, depending on segment
    0, the build side."""
    return with_build_dep(batch_segment(seg_id, handle, ops^, morsel_rows), 0)


def _joined_names() -> List[String]:
    var out = _names("o_id", "o_custkey", "o_total")
    out.append("c_custkey")
    out.append("c_name")
    out.append("c_nation")
    return out^


def _null_in_first_column(ref table: JoinTable) -> List[Bool]:
    """Per row, whether column 0 is NULL: the rows of a RIGHT or FULL join
    that no probe row matched (orders' o_id is never NULL)."""
    var out = List[Bool]()
    for r in range(table.num_rows()):
        out.append(table.shown[r][0] == NULL_TEXT)
    return out^


def _check(
    kind: UInt8,
    orders_rows: Int,
    customers_rows: Int,
    null_keys: Bool = False,
    empty_build: Bool = False,
) raises -> Int:
    """Run the join of `kind` over orders `0 .. orders_rows` and customers on
    every worker count and probe morsel size, assert its rows and column names
    equal the oracle's, and return the number of rows the oracle has."""
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(_customers(customers_rows, null_keys))
    var orders = builder.add_resident(orders_batch(0, orders_rows))
    var build_rows = customers_rows
    if empty_build:
        build_rows = 0
    var oracle = oracle_join_kind(
        kind,
        table_of(orders_batch(0, orders_rows)),
        table_of(_customers(build_rows, null_keys)),
        _probe_keys(kind),
        _build_keys(kind),
    )
    var want = sorted_rows(oracle)
    var sizes = _sizes()
    var workers = _counts()
    for s in range(len(sizes)):
        var build_ops = Slab[MorselOp]()
        if empty_build:
            # No customer has a nation above 1000.
            build_ops = chain(MorselOp.filter(_cmp(BIN_GT, "c_nation", 1000)))
        var descs = _two(
            build_segment(0, customers, build_ops^, 6),
            _probe_desc(1, orders, chain(_probe(0, kind)), sizes[s]),
        )
        for w in range(len(workers)):
            var out = _run(descs, builder, workers[w])
            assert_false(out.has(0))
            var batch = out.take(1)
            _expect_names(batch, oracle.names)
            expect_rows(
                rows_of(batch),
                want,
                "kind "
                + String(Int(kind))
                + ", morsel "
                + String(sizes[s])
                + ", workers "
                + String(workers[w]),
            )
            assert_equal(builder.pool_granted(), 0)
    return len(want)


# ---- every kind against the oracle ---------------------------------------------------


def test_a_left_join_equals_the_oracle_on_one_to_seven_workers() raises:
    assert_true(_check(JOIN_LEFT, 100, 25) > 100)
    assert_true(_check(JOIN_LEFT, 6, 25) >= 6)


def test_a_right_join_equals_the_oracle_on_one_to_seven_workers() raises:
    assert_true(_check(JOIN_RIGHT, 100, 25) > 50)
    assert_true(_check(JOIN_RIGHT, 6, 25) > 6)


def test_a_full_join_equals_the_oracle_on_one_to_seven_workers() raises:
    assert_true(_check(JOIN_FULL, 100, 25) > 100)
    assert_true(_check(JOIN_FULL, 6, 25) > 6)


def test_a_semi_join_equals_the_oracle_on_one_to_seven_workers() raises:
    var large = _check(JOIN_SEMI, 100, 25)
    assert_true(large > 0)
    assert_true(large < 100)
    assert_true(_check(JOIN_SEMI, 6, 25) > 0)


def test_an_anti_join_equals_the_oracle_on_one_to_seven_workers() raises:
    var large = _check(JOIN_ANTI, 100, 25)
    assert_true(large > 0)
    assert_true(large < 100)
    assert_true(_check(JOIN_ANTI, 6, 25) > 0)


def test_a_cross_join_equals_the_oracle_on_one_to_seven_workers() raises:
    assert_equal(_check(JOIN_CROSS, 100, 25), 2500)
    assert_equal(_check(JOIN_CROSS, 6, 25), 150)


def test_every_keyed_kind_over_a_build_side_of_only_null_keys_equals_the_oracle() raises:
    var kinds = _kinds()
    for k in range(len(kinds)):
        var rows = _check(kinds[k], 30, 12, null_keys=True)
        if kinds[k] == JOIN_SEMI:
            assert_equal(rows, 0)
        elif kinds[k] == JOIN_RIGHT:
            assert_equal(rows, 12)
        elif kinds[k] == JOIN_FULL:
            assert_equal(rows, 42)
        else:
            assert_equal(rows, 30)


def test_every_kind_over_an_empty_build_side_equals_the_oracle() raises:
    var kinds = _kinds()
    kinds.append(JOIN_CROSS)
    for k in range(len(kinds)):
        var rows = _check(kinds[k], 30, 25, empty_build=True)
        if kinds[k] == JOIN_LEFT or kinds[k] == JOIN_FULL or kinds[k] == JOIN_ANTI:
            assert_equal(rows, 30)
        else:
            assert_equal(rows, 0)


# ---- the tail --------------------------------------------------------------------------


def _unmatched_build_names(ref table: JoinTable) -> List[String]:
    """The sorted c_name of the rows of `table` (a RIGHT or FULL result) whose
    first column is NULL."""
    var name_col = 4
    var out = List[String]()
    for r in range(table.num_rows()):
        if table.shown[r][0] == NULL_TEXT:
            out.append(table.shown[r][name_col].copy())
    sort(out)
    return out^


def test_right_and_full_give_each_unmatched_build_row_exactly_once() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    # Orders 0 .. 5 hold keys 0, 7, 1, 8, NULL and 9: most customers go
    # unmatched.
    var orders = builder.add_resident(orders_batch(0, 6))
    var kinds: List[UInt8] = [JOIN_RIGHT, JOIN_FULL]
    var workers = _counts()
    for k in range(len(kinds)):
        var oracle = oracle_join_kind(
            kinds[k],
            table_of(orders_batch(0, 6)),
            table_of(customer_batch(25)),
            _probe_keys(kinds[k]),
            _build_keys(kinds[k]),
        )
        var want = _unmatched_build_names(oracle)
        assert_true(len(want) > 10)
        assert_true(len(want) < 25)
        for w in range(len(workers)):
            var descs = _two(
                build_segment(0, customers),
                _probe_desc(1, orders, chain(_probe(0, kinds[k])), 2),
            )
            var out = _run(descs, builder, workers[w])
            var got = _unmatched_build_names(table_of(out.take(1)))
            expect_rows(
                got,
                want,
                "kind " + String(Int(kinds[k])) + ", workers " + String(workers[w]),
            )
            assert_equal(builder.pool_granted(), 0)


def test_a_right_or_full_probe_side_that_yields_no_row_gives_every_build_row() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var kinds: List[UInt8] = [JOIN_RIGHT, JOIN_FULL]
    var sizes: List[Int] = [0, 1, 4]
    var workers = _counts()
    for k in range(len(kinds)):
        var want = sorted_rows(
            oracle_join_kind(
                kinds[k],
                table_of(orders_batch(0, 0)),
                table_of(customer_batch(25)),
                _probe_keys(kinds[k]),
                _build_keys(kinds[k]),
            )
        )
        assert_equal(len(want), 25)
        for s in range(len(sizes)):
            # No order has an id below 0.
            var ops = chain(
                MorselOp.filter(_cmp(BIN_LT, "o_id", 0)), _probe(0, kinds[k])
            )
            var descs = _two(
                build_segment(0, customers),
                _probe_desc(1, orders, ops^, sizes[s]),
            )
            for w in range(len(workers)):
                var out = _run(descs, builder, workers[w])
                var batch = out.take(1)
                _expect_names(batch, _joined_names())
                assert_equal(batch.num_rows(), 25)
                expect_rows(
                    rows_of(batch),
                    want,
                    "kind "
                    + String(Int(kinds[k]))
                    + ", tail batches of "
                    + String(sizes[s])
                    + ", workers "
                    + String(workers[w]),
                )
                for c in range(3):
                    assert_true(_type_at(batch, c) == ArrowType.INT64)
                    assert_true(_nullable_at(batch, c))
                    for r in range(batch.num_rows()):
                        assert_true(batch.column_at(c).is_null_at(r))
                assert_true(_type_at(batch, 3) == ArrowType.INT32)
                assert_true(_type_at(batch, 4) == ArrowType.STRING)
                assert_true(_type_at(batch, 5) == ArrowType.INT64)
                assert_equal(builder.pool_granted(), 0)


def _renaming_projection() -> MorselOp:
    """An OP_PROJECT that keeps o_custkey as `k` and o_id as `id`, drops
    o_total."""
    var exprs = Slab[Expr]()
    exprs.append(Expr.col_ref("o_custkey"))
    exprs.append(Expr.col_ref("o_id"))
    return MorselOp.project(exprs^, _names("k", "id"))


def _renamed_orders(rows: Int) raises -> JoinTable:
    """The orders' o_custkey and o_id as the projection leaves them."""
    var t = select_columns(
        table_of(orders_batch(0, rows)), _names("o_custkey", "o_id")
    )
    t.names = _names("k", "id")
    return t^


def _renamed_names() -> List[String]:
    var out = _names("k", "id", "c_custkey")
    out.append("c_name")
    out.append("c_nation")
    return out^


def test_a_projection_before_the_probe_names_and_types_the_tail_probe_columns() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var ops = chain(
        MorselOp.filter(_cmp(BIN_LT, "o_id", 0)),
        _renaming_projection(),
        MorselOp.join_probe(
            0, key_names("k"), key_names("c_custkey"), JOIN_RIGHT
        ),
    )
    var descs = _two(
        build_segment(0, customers), _probe_desc(1, orders, ops^, 9)
    )
    var want = sorted_rows(
        oracle_join_kind(
            JOIN_RIGHT,
            _renamed_orders(0),
            table_of(customer_batch(25)),
            key_names("k"),
            key_names("c_custkey"),
        )
    )
    assert_equal(len(want), 25)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        var batch = out.take(1)
        _expect_names(batch, _renamed_names())
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_true(_type_at(batch, 0) == ArrowType.INT64)
        assert_true(_type_at(batch, 1) == ArrowType.INT64)
        for c in range(2):
            for r in range(batch.num_rows()):
                assert_true(batch.column_at(c).is_null_at(r))
        assert_equal(builder.pool_granted(), 0)


def test_a_projection_before_the_probe_of_a_right_join_equals_the_oracle() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 6))
    var ops = chain(
        _renaming_projection(),
        MorselOp.join_probe(
            0, key_names("k"), key_names("c_custkey"), JOIN_RIGHT
        ),
    )
    var descs = _two(
        build_segment(0, customers), _probe_desc(1, orders, ops^, 4)
    )
    var want = sorted_rows(
        oracle_join_kind(
            JOIN_RIGHT,
            _renamed_orders(6),
            table_of(customer_batch(25)),
            key_names("k"),
            key_names("c_custkey"),
        )
    )
    assert_true(len(want) > 6)
    var workers = _counts()
    for w in range(len(workers)):
        var out = _run(descs, builder, workers[w])
        var batch = out.take(1)
        _expect_names(batch, _renamed_names())
        expect_rows(rows_of(batch), want, "workers " + String(workers[w]))
        assert_equal(builder.pool_granted(), 0)


def test_a_tail_flows_through_a_filter_after_the_probe() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var kinds: List[UInt8] = [JOIN_RIGHT, JOIN_FULL]
    var workers = _counts()
    for k in range(len(kinds)):
        var oracle = oracle_join_kind(
            kinds[k],
            table_of(orders_batch(0, 100)),
            table_of(customer_batch(25)),
            _probe_keys(kinds[k]),
            _build_keys(kinds[k]),
        )
        var want = sorted_rows(
            keep_rows(oracle, _null_in_first_column(oracle))
        )
        # Only customers with a NULL key are unmatched by 100 orders.
        assert_true(len(want) > 0)
        assert_true(len(want) < 25)
        for w in range(len(workers)):
            var ops = chain(
                _probe(0, kinds[k]),
                MorselOp.filter(Expr.unary(UN_IS_NULL, Expr.col_ref("o_id"))),
            )
            var descs = _two(
                build_segment(0, customers),
                _probe_desc(1, orders, ops^, 13),
            )
            var out = _run(descs, builder, workers[w])
            expect_rows(
                rows_of(out.take(1)),
                want,
                "kind " + String(Int(kinds[k])) + ", workers " + String(workers[w]),
            )
            assert_equal(builder.pool_granted(), 0)


def test_a_tail_is_counted_by_an_ungrouped_aggregation_in_the_probe_segment() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 6))
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, False))
    var sink = builder.add_agg_sink(
        ungrouped_agg_data(
            agg_list(AggExpr(AGG_COUNT, None, None)), sb.build()
        )
    )
    var kinds: List[UInt8] = [JOIN_RIGHT, JOIN_FULL]
    var workers = _counts()
    for k in range(len(kinds)):
        var want = len(
            oracle_join_kind(
                kinds[k],
                table_of(orders_batch(0, 6)),
                table_of(customer_batch(25)),
                _probe_keys(kinds[k]),
                _build_keys(kinds[k]),
            ).shown
        )
        assert_true(want >= 25)
        for w in range(len(workers)):
            var descs = _two(
                build_segment(0, customers),
                with_agg_sink(
                    _probe_desc(1, orders, chain(_probe(0, kinds[k])), 3),
                    sink,
                ),
            )
            var out = _run(descs, builder, workers[w])
            var batch = out.take(1)
            assert_equal(batch.num_rows(), 1)
            assert_equal(_count_of(batch), want)
            assert_equal(builder.pool_granted(), 0)


def test_a_tail_is_counted_by_an_aggregation_segment_after_the_probe_segment() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 6))
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, False))
    var sink = builder.add_agg_sink(
        ungrouped_agg_data(
            agg_list(AggExpr(AGG_COUNT, None, None)), sb.build()
        )
    )
    var want = len(
        oracle_join_kind(
            JOIN_RIGHT,
            table_of(orders_batch(0, 6)),
            table_of(customer_batch(25)),
            _probe_keys(JOIN_RIGHT),
            _build_keys(JOIN_RIGHT),
        ).shown
    )
    var workers = _counts()
    for w in range(len(workers)):
        var descs = _three(
            build_segment(0, customers),
            _probe_desc(1, orders, chain(_probe(0, JOIN_RIGHT)), 3),
            with_agg_sink(output_segment(2, 1, Slab[MorselOp](), 7), sink),
        )
        var out = _run(descs, builder, workers[w])
        assert_false(out.has(1))
        var batch = out.take(2)
        assert_equal(batch.num_rows(), 1)
        assert_equal(_count_of(batch), want)
        assert_equal(builder.pool_granted(), 0)


# ---- a limit after the probe -------------------------------------------------------------


def _in(ref s: String, ref rows: List[String]) -> Bool:
    for i in range(len(rows)):
        if rows[i] == s:
            return True
    return False


def test_a_limit_after_a_right_probe_stops_at_its_count() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 6))
    var want = sorted_rows(
        oracle_join_kind(
            JOIN_RIGHT,
            table_of(orders_batch(0, 6)),
            table_of(customer_batch(25)),
            _probe_keys(JOIN_RIGHT),
            _build_keys(JOIN_RIGHT),
        )
    )
    assert_true(len(want) > 10)
    var workers = _counts()
    for w in range(len(workers)):
        var ops = chain(_probe(0, JOIN_RIGHT), MorselOp.limit(10))
        var descs = _two(
            build_segment(0, customers), _probe_desc(1, orders, ops^, 4)
        )
        var out = _run(descs, builder, workers[w])
        var got = rows_of(out.take(1))
        assert_equal(len(got), 10, "workers " + String(workers[w]))
        for i in range(len(got)):
            assert_true(_in(got[i], want), "row " + got[i])
        assert_equal(builder.pool_granted(), 0)


def test_a_limit_inside_the_tail_ends_the_tail() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var orders = builder.add_resident(orders_batch(0, 100))
    var want = sorted_rows(
        oracle_join_kind(
            JOIN_RIGHT,
            table_of(orders_batch(0, 0)),
            table_of(customer_batch(25)),
            _probe_keys(JOIN_RIGHT),
            _build_keys(JOIN_RIGHT),
        )
    )
    assert_equal(len(want), 25)
    var limits: List[Int] = [10, 40]
    var workers = _counts()
    for l in range(len(limits)):
        for w in range(len(workers)):
            # No probe row reaches the join: the tail alone feeds the limit,
            # four rows to a batch.
            var ops = chain(
                MorselOp.filter(_cmp(BIN_LT, "o_id", 0)),
                _probe(0, JOIN_RIGHT),
                MorselOp.limit(limits[l]),
            )
            var descs = _two(
                build_segment(0, customers), _probe_desc(1, orders, ops^, 4)
            )
            var out = _run(descs, builder, workers[w])
            var got = rows_of(out.take(1))
            assert_equal(len(got), min(limits[l], 25), "limit " + String(limits[l]))
            for i in range(len(got)):
                assert_true(_in(got[i], want), "row " + got[i])
            for i in range(1, len(got)):
                assert_true(got[i] != got[i - 1], "a repeated row " + got[i])
            assert_equal(builder.pool_granted(), 0)


# ---- two probes in one chain ----------------------------------------------------------------


def test_the_tail_of_a_right_probe_is_probed_by_the_next_right_probe() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var nations = builder.add_resident(nation_batch(4))
    var orders = builder.add_resident(orders_batch(0, 6))
    var firsts: List[UInt8] = [JOIN_RIGHT, JOIN_FULL, JOIN_RIGHT, JOIN_LEFT]
    var seconds: List[UInt8] = [JOIN_RIGHT, JOIN_RIGHT, JOIN_FULL, JOIN_RIGHT]
    var workers = _counts()
    for c in range(len(firsts)):
        var first = oracle_join_kind(
            firsts[c],
            table_of(orders_batch(0, 6)),
            table_of(customer_batch(25)),
            key_names("o_custkey"),
            key_names("c_custkey"),
        )
        var second = oracle_join_kind(
            seconds[c],
            first,
            table_of(nation_batch(4)),
            key_names("c_nation"),
            key_names("n_nationkey"),
        )
        var want = sorted_rows(second)
        assert_true(len(want) > 5)
        for w in range(len(workers)):
            var ops = chain(
                MorselOp.join_probe(
                    0,
                    key_names("o_custkey"),
                    key_names("c_custkey"),
                    firsts[c],
                ),
                MorselOp.join_probe(
                    1,
                    key_names("c_nation"),
                    key_names("n_nationkey"),
                    seconds[c],
                ),
            )
            var probe = with_build_dep(
                with_build_dep(batch_segment(2, orders, ops^, 4), 0), 1
            )
            var descs = _three(
                build_segment(0, customers, morsel_rows=8),
                build_segment(1, nations),
                probe^,
            )
            var out = _run(descs, builder, workers[w])
            var batch = out.take(2)
            _expect_names(batch, second.names)
            expect_rows(
                rows_of(batch),
                want,
                "kinds "
                + String(Int(firsts[c]))
                + " then "
                + String(Int(seconds[c]))
                + ", workers "
                + String(workers[w]),
            )
            assert_equal(builder.pool_granted(), 0)


def test_a_spent_limit_between_two_right_probes_keeps_the_later_tail() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var customers = builder.add_resident(customer_batch(25))
    var nations = builder.add_resident(nation_batch(4))
    var orders = builder.add_resident(orders_batch(0, 6))
    # No row passes LIMIT 0, so the second probe sees none: its output is its
    # tail, every nation row with NULL columns before it.
    var first = oracle_join_kind(
        JOIN_RIGHT,
        table_of(orders_batch(0, 6)),
        table_of(customer_batch(25)),
        key_names("o_custkey"),
        key_names("c_custkey"),
    )
    var none = List[Bool](length=first.num_rows(), fill=False)
    var second = oracle_join_kind(
        JOIN_RIGHT,
        keep_rows(first, none),
        table_of(nation_batch(4)),
        key_names("c_nation"),
        key_names("n_nationkey"),
    )
    var want = sorted_rows(second)
    assert_equal(len(want), 4)
    var workers = _counts()
    for w in range(len(workers)):
        var ops = chain(
            MorselOp.join_probe(
                0, key_names("o_custkey"), key_names("c_custkey"), JOIN_RIGHT
            ),
            MorselOp.limit(0),
            MorselOp.join_probe(
                1, key_names("c_nation"), key_names("n_nationkey"), JOIN_RIGHT
            ),
        )
        var probe = with_build_dep(
            with_build_dep(batch_segment(2, orders, ops^, 4), 0), 1
        )
        var descs = _three(
            build_segment(0, customers), build_segment(1, nations), probe^
        )
        var out = _run(descs, builder, workers[w])
        var batch = out.take(2)
        _expect_names(batch, second.names)
        expect_rows(
            rows_of(batch), want, "workers " + String(workers[w])
        )
        assert_equal(builder.pool_granted(), 0)


# ---- what the operator refuses ---------------------------------------------------------------


def test_a_cross_join_that_names_a_key_is_refused_by_name() raises:
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
            0, key_names("o_custkey"), key_names("c_custkey"), JOIN_CROSS
        )
    )
    var descs = _two(
        build_segment(0, customers), _probe_desc(1, orders, ops^, 0)
    )
    with assert_raises(
        contains="OP_JOIN_PROBE refuses a CROSS join with 1 probe keys and 1"
        " build keys; a CROSS join has none"
    ):
        _ = _run(descs, builder, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
