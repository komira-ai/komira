# A NULL probe key matches nothing, on EVERY arm `execute_join_probe` routes an
# INNER single-INT64-key join to. The arms are chosen on row counts, fan-out,
# projection width and what the fused kernels can carry, none of which has to
# do with NULLs, so the same rows must come out whichever arm runs.
#
# Three guards keep each case from passing vacuously:
#   1. Each NULL probe slot holds 0 under its cleared validity bit, and the
#      build side has key 0, so a kernel reading the slot would match it.
#   2. The answer is computed twice off the fixture, excluding and including
#      the NULL rows, and the two are asserted to differ before the join's
#      answer is compared with the first.
#   3. The arm is pinned with the predicates the dispatcher branches on
#      (`PerfectHashJoin.try_build`, `should_use_radix_join`,
#      `avg_chain_length`, `should_parallelize` and
#      `komira_op_fused_kernels.join_fused_route`), so a moved threshold fails
#      naming the arm instead of re-testing a neighbour.
# Every case that returns columns also checks that no output row carries the
# id of a NULL probe row.
#
# The fused and chunked kernels carry no column holding a NULL, so an
# unprojected join whose probe key holds one is gathered per column; the fused
# kernel sees NULL keys only through a projection that leaves the key out.
# The last case is the routing itself: a NULL in a payload column (not the
# key) must also send the join to the gather, which keeps it NULL.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import MorselOp
from komira_plan_ir.logical_plan import JOIN_INNER

from komira_op_fused_kernels.join_fused_route import (
    fused_join_cannot_carry_batches,
    fused_join_cannot_carry_output,
)
from komira_op_fused_kernels.parallel_gate import should_parallelize
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_probe.join_probe import execute_join_probe
from komira_op_join_probe.radix_join import should_use_radix_join


comptime I64 = DType.int64
comptime _POOL: Int = 8
# Above the parallel gate, and above `pool * 16,384` so the fork really splits.
comptime _PAR_ROWS: Int = 140_000
comptime _SMALL_ROWS: Int = 9
comptime _FANOUT_ROWS: Int = 12
comptime _STRIDE: Int = 3
comptime _PAR_STRIDE: Int = 8
comptime _KEYMOD: Int = 5


def _keys_col(vals: List[Int64], null_stride: Int) -> PrimitiveArray[I64]:
    """`vals`, NULL at every row `i % null_stride == 0` (0: no NULL), the
    value left in the slot under the cleared bit."""
    if null_stride == 0:
        return PrimitiveArray[I64].from_list(vals)
    var arr = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr._typed_ptr_mut()[i] = vals[i]
        if i % null_stride == 0:
            arr._set_null(i)
    return arr^


def _probe_vals(n: Int, stride: Int) -> List[Int64]:
    """`i % 5`, except the NULL rows (every `stride`-th), which hold 0."""
    var vals = List[Int64](capacity=n)
    for i in range(n):
        vals.append(Int64(0) if stride > 0 and i % stride == 0 else Int64(i % _KEYMOD))
    return vals^


def _probe(n: Int, stride: Int, pay_null: Bool = False) raises -> RecordBatch:
    """`k` (NULL every `stride`-th row), `pid` (the row id), `pay`
    (`10 * pid`, NULL at row 1 when `pay_null`)."""
    var pids = List[Int64](capacity=n)
    var pays = List[Int64](capacity=n)
    for i in range(n):
        pids.append(Int64(i))
        pays.append(Int64(i) * 10)
    var pay = PrimitiveArray[I64].from_list(pays)
    if pay_null:
        pay = PrimitiveArray[I64].allocate_nullable(n)
        for i in range(n):
            pay._typed_ptr_mut()[i] = Int64(i) * 10
        pay._set_null(1)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, stride > 0))
    sb.add_field(Field("pid", ArrowType.INT64, False))
    sb.add_field(Field("pay", ArrowType.INT64, pay_null))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[I64](_keys_col(_probe_vals(n, stride), stride)))
    b.add_column(Column.from_primitive[I64](PrimitiveArray[I64].from_list(pids)))
    b.add_column(Column.from_primitive[I64](pay^))
    return b.build(sb.build())


def _build(keys: List[Int64]) raises -> RecordBatch:
    """`bk` and `bid` (the build row id)."""
    var bids = List[Int64](capacity=len(keys))
    for i in range(len(keys)):
        bids.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("bk", ArrowType.INT64, False))
    sb.add_field(Field("bid", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[I64](PrimitiveArray[I64].from_list(keys)))
    b.add_column(Column.from_primitive[I64](PrimitiveArray[I64].from_list(bids)))
    return b.build(sb.build())


def _dup0_keys() -> List[Int64]:
    """0 present (a NULL slot's value) and duplicated (perfect hash declines)."""
    return [0, 0, 1, 2, 3]


def _fanout4_keys() -> List[Int64]:
    """0..4 four times each: average chain 4, perfect hash declines."""
    var k = List[Int64]()
    for _ in range(4):
        for v in range(5):
            k.append(Int64(v))
    return k^


def _oracle(n: Int, stride: Int, imm build: List[Int64], exclude: Bool) -> Int:
    """INNER rows counted off the fixture: with `exclude`, the truth; without,
    what a kernel reading the NULL slots would emit."""
    var vals = _probe_vals(n, stride)
    var total = 0
    for i in range(n):
        if exclude and stride > 0 and i % stride == 0:
            continue
        for b in range(len(build)):
            if build[b] == vals[i]:
                total += 1
    return total


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(
    imm probe: RecordBatch, imm build: RecordBatch, output_cols: Optional[List[String]]
) raises -> RecordBatch:
    var op: MorselOp
    if output_cols:
        op = MorselOp.join_probe_projected(
            0, ["k"], ["bk"], JOIN_INNER, output_cols.value().copy()
        )
    else:
        op = MorselOp.join_probe(0, ["k"], ["bk"], JOIN_INNER)
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL,
        sink_factory=_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    return execute_join_probe(d, CancellationToken.never(), probe, op, build)


def _assert_disagree(n: Int, stride: Int, imm build: List[Int64], who: String) raises:
    assert_true(
        _oracle(n, stride, build, False) > _oracle(n, stride, build, True),
        who + ": vacuous fixture, excluding the NULL rows changes nothing",
    )


def _assert_no_null_row(imm out: RecordBatch, stride: Int, who: String) raises:
    var pid = out.column_at(out.schema.column_index("pid")).as_primitive[I64]()
    for r in range(out.num_rows()):
        assert_true(
            Int(pid.get(r)) % stride != 0,
            who + ": a NULL probe row came out, id " + String(pid.get(r)),
        )


def _pin_chained(imm build: List[Int64], scan_rows: Int, fanout4: Bool, par: Bool, who: String) raises:
    var keys = PrimitiveArray[I64].from_list(build)
    assert_false(Bool(PerfectHashJoin.try_build(keys)), who + ": perfect hash")
    assert_false(should_use_radix_join(len(build)), who + ": radix")
    var fan = HashJoinBuilder.build(keys).avg_chain_length()
    assert_equal(fan >= 4, fanout4, who + ": fan-out " + String(fan))
    assert_equal(should_parallelize(scan_rows, _POOL), par, who + ": parallel gate")


def test_serial_gather_arm() raises:
    """9 rows, fan-out 1, unprojected: the NULL key column cannot go to the
    fused kernel, so the pairs are collected and gathered."""
    var bk = _dup0_keys()
    var who = String("serial gather arm")
    _pin_chained(bk, _SMALL_ROWS, False, False, who)
    var probe = _probe(_SMALL_ROWS, _STRIDE)
    var build = _build(bk)
    assert_true(fused_join_cannot_carry_batches(probe, build), who)
    _assert_disagree(_SMALL_ROWS, _STRIDE, bk, who)
    var out = _run(probe, build, None)
    assert_equal(out.num_rows(), _oracle(_SMALL_ROWS, _STRIDE, bk, True), who)
    _assert_no_null_row(out, _STRIDE, who)


def test_high_fanout_gather_arm() raises:
    """Average chain 4 with a NULL key column: the many-to-many collect, then
    the gather (the chunked kernel cannot carry it)."""
    var bk = _fanout4_keys()
    var who = String("high fan-out gather arm")
    _pin_chained(bk, _FANOUT_ROWS, True, False, who)
    _assert_disagree(_FANOUT_ROWS, _STRIDE, bk, who)
    var out = _run(_probe(_FANOUT_ROWS, _STRIDE), _build(bk), None)
    assert_equal(out.num_rows(), _oracle(_FANOUT_ROWS, _STRIDE, bk, True), who)
    _assert_no_null_row(out, _STRIDE, who)


def test_fused_projected_arm() raises:
    """A projection without the key (2 of 5 columns): the fused kernel writes
    just `pid` and `bid`, reading the NULL mask."""
    var bk = _dup0_keys()
    var who = String("fused projected arm")
    _pin_chained(bk, _SMALL_ROWS, False, False, who)
    var probe = _probe(_SMALL_ROWS, _STRIDE)
    var build = _build(bk)
    assert_false(fused_join_cannot_carry_output(probe, build, _names("pid", "bid")), who)
    _assert_disagree(_SMALL_ROWS, _STRIDE, bk, who)
    var out = _run(probe, build, Optional[List[String]](_names("pid", "bid")))
    assert_equal(out.num_columns(), 2, who + ": projected columns")
    assert_equal(out.num_rows(), _oracle(_SMALL_ROWS, _STRIDE, bk, True), who)
    _assert_no_null_row(out, _STRIDE, who)


def test_fused_projected_count_only_arm() raises:
    """An empty projection (a COUNT(*) over the join): the fused kernel's
    counting pass. Only the count exists to check."""
    var bk = _dup0_keys()
    var who = String("fused projected count")
    _assert_disagree(_SMALL_ROWS, _STRIDE, bk, who)
    var out = _run(_probe(_SMALL_ROWS, _STRIDE), _build(bk), Optional[List[String]](List[String]()))
    assert_equal(out.num_rows(), _oracle(_SMALL_ROWS, _STRIDE, bk, True), who)


def test_parallel_arm() raises:
    """140,000 probe rows, fan-out 1: the parallel probe, then the gather."""
    var bk = _dup0_keys()
    var who = String("parallel arm")
    _pin_chained(bk, _PAR_ROWS, False, True, who)
    _assert_disagree(_PAR_ROWS, _PAR_STRIDE, bk, who)
    var out = _run(_probe(_PAR_ROWS, _PAR_STRIDE), _build(bk), None)
    assert_equal(out.num_rows(), _oracle(_PAR_ROWS, _PAR_STRIDE, bk, True), who)
    _assert_no_null_row(out, _PAR_STRIDE, who)


def test_no_null_keys_take_the_fused_arm() raises:
    """The control: no validity bitmap, so the fused kernel runs, and both
    oracles agree with it."""
    var bk = _dup0_keys()
    var probe = _probe(_SMALL_ROWS, 0)
    var build = _build(bk)
    assert_false(fused_join_cannot_carry_batches(probe, build), "control arm")
    var truth = _oracle(_SMALL_ROWS, 0, bk, True)
    assert_equal(truth, _oracle(_SMALL_ROWS, 0, bk, False), "control oracles")
    assert_equal(_run(probe, build, None).num_rows(), truth, "control")


def test_null_payload_is_gathered_and_stays_null() raises:
    """No NULL key, a NULL in the probe payload `pay` (row 1, key 1, which
    matches build row 2). The fused kernel cannot carry the NULL, so the join
    is gathered and `pay` is NULL on that output row and on no other."""
    var bk = _dup0_keys()
    var probe = _probe(_SMALL_ROWS, 0, pay_null=True)
    var build = _build(bk)
    assert_true(fused_join_cannot_carry_batches(probe, build), "payload NULL")
    var out = _run(probe, build, None)
    assert_equal(out.num_rows(), _oracle(_SMALL_ROWS, 0, bk, True), "rows")
    var pid = out.column_at(out.schema.column_index("pid")).as_primitive[I64]()
    var pay = out.column_at(out.schema.column_index("pay")).as_primitive[I64]()
    var nulls = 0
    for r in range(out.num_rows()):
        if pay.is_null(r):
            nulls += 1
            assert_equal(pid.get(r), Int64(1), "the NULL is row 1's")
        else:
            assert_equal(pay.get(r), pid.get(r) * 10, "payload value")
    assert_equal(nulls, 1, "row 1 matches one build row, so one NULL")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
