# =============================================================================
# test_cd_strkey_fused_served_and_values -- the fused string-key route is
# served exactly where it should be, and its answers equal the general
# driver's and an independent oracle on varied keys and values
# =============================================================================
#
# Every case builds a batch, runs it with the fused route allowed and with it
# forbidden, and compares both with a Dict-of-Set oracle and the first-seen
# key order. What each test catches:
#   * many groups, INT32 at a non-power-of-two width, FLOAT64 with NaN
#     payloads / signed zero / infinities, a zero-copy sliced nullable value
#     column, a key column that is not first: a wrong or missing group, a
#     NULL value admitted, a column read at the wrong offset;
#   * a hot key below the heavy bar, and eight equal groups, still SERVED
#     (a route that declines far too eagerly answers correctly and is caught
#     only by the served counter);
#   * a hot key just above the bar declined as heavy.
# =============================================================================

from std.collections import Dict, List, Optional, Set
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_plan_expr.agg_expr import count, count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_strkey_fused import (
    cd_strkey_fused_heavy_decline_count,
    cd_strkey_fused_served_count,
    reset_cd_strkey_fused_counters,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
)

comptime FLOOR: Int = 1_048_576


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Int:
        self.s = self.s * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        return Int(self.s >> 33)


def make_keys(mode: Int, n: Int, mut rng: Rng, hot_pct: Int = 0) -> List[String]:
    """mode 0: ~600k groups plus the empty key; 1: eight equal groups, one of
    them the empty key; 2: one key holding `hot_pct` percent of the rows, the
    rest spread over 50k keys."""
    var out = List[String](capacity=n)
    for _ in range(n):
        var x = rng.next()
        if mode == 0:
            if x % 997 == 0:
                out.append(String(""))
            else:
                out.append(String("g") + String(x % 600000))
        elif mode == 1:
            var k = x % 8
            out.append(String("") if k == 0 else String("few") + String(k))
        else:
            if x % 100 < hot_pct:
                out.append(String("HOT"))
            else:
                out.append(String("c") + String(x % 50000))
    return out^


def sink1(vname: String, extra_count: Bool = False) raises -> AggSinkData:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col(vname)))
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    if extra_count:
        aggs.append(count(col(vname)))
        osb.add_field(Field("c", ArrowType.INT64, False))
    return AggSinkData(gb^, aggs^, osb.build())


def run(imm batch: RecordBatch, imm sink: AggSinkData, naggs: Int, workers: Int, fused: Bool) raises -> RecordBatch:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(workers, _noop, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, 1, naggs, batch.num_rows(), None, fused
    )


def to_map(imm rb: RecordBatch) raises -> Dict[String, Int]:
    var out = Dict[String, Int]()
    var ks = rb.column_at(0).as_string()
    var ns = rb.column_at(1).as_primitive[DType.int64]()
    for i in range(rb.num_rows()):
        var k = ks.get(i)
        assert_false(k in out, "dup key " + k)
        out[k] = Int(ns.get(i))
    return out^


def check(
    name: String,
    batch: RecordBatch,
    keys: List[String],
    codes: List[Int64],
    valid: List[Bool],
    workers: Int,
    expect_served: Int,
) raises:
    var oracle = Dict[String, Set[Int64]]()
    for r in range(len(keys)):
        if keys[r] not in oracle:
            oracle[keys[r]] = Set[Int64]()
        if valid[r]:
            oracle[keys[r]].add(codes[r])
    var sink = sink1("v")
    reset_cd_strkey_fused_counters()
    var f = run(batch, sink, 1, workers, True)
    var served = cd_strkey_fused_served_count()
    assert_equal(served, expect_served, name + ": served")
    var g = run(batch, sink, 1, workers, False)
    assert_equal(cd_strkey_fused_served_count(), served, name + ": general did not use fused")
    var fm = to_map(f)
    var gm = to_map(g)
    assert_equal(len(fm), len(oracle), name + ": fused group count")
    assert_equal(len(gm), len(oracle), name + ": general group count")
    for e in oracle.items():
        assert_true(e.key in fm, name + ": fused missing " + e.key)
        assert_equal(fm[e.key], len(e.value), name + ": fused count " + e.key)
        assert_equal(gm[e.key], len(e.value), name + ": general count " + e.key)
    # first-seen order of fused result
    var seen = Dict[String, Int]()
    var order = List[String]()
    for r in range(len(keys)):
        if keys[r] not in seen:
            seen[keys[r]] = 1
            order.append(keys[r])
    if served == 1:
        var ks = f.column_at(0).as_string()
        for i in range(len(order)):
            assert_equal(ks.get(i), order[i], name + ": first-seen order")


def batch_i64(keys: List[String], vals: List[Int64], valid: List[Bool], nullable: Bool, i32: Bool = False) raises -> RecordBatch:
    var n = len(keys)
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    if i32:
        var a = PrimitiveArray[DType.int32].allocate_nullable(n) if nullable else PrimitiveArray[DType.int32].allocate(n)
        for r in range(n):
            a.store[1](r, Scalar[DType.int32](Int32(vals[r])))
        if nullable:
            for r in range(n):
                if not valid[r]:
                    a._set_null(r)
        rbb.add_column(Column.from_primitive[DType.int32](a^))
        sb.add_field(Field("v", ArrowType.INT32, nullable))
    else:
        var a = PrimitiveArray[DType.int64].allocate_nullable(n) if nullable else PrimitiveArray[DType.int64].allocate(n)
        for r in range(n):
            a.store[1](r, Scalar[DType.int64](vals[r]))
        if nullable:
            for r in range(n):
                if not valid[r]:
                    a._set_null(r)
        rbb.add_column(Column.from_primitive[DType.int64](a^))
        sb.add_field(Field("v", ArrowType.INT64, nullable))
    return rbb.build(sb.build())


def scenario_int(name: String, mode: Int, n: Int, workers: Int, expect_served: Int, i32: Bool, nulls: Bool, vmod: Int, hot_pct: Int = 0) raises:
    var rng = Rng(UInt64(mode * 7919 + n % 1000 + workers))
    var keys = make_keys(mode, n, rng, hot_pct)
    var vals = List[Int64](capacity=n)
    var valid = List[Bool](capacity=n)
    for r in range(n):
        var x = rng.next()
        vals.append(Int64(x % vmod) - Int64(vmod // 2))
        valid.append(not (nulls and x % 5 == 0))
    var b = batch_i64(keys, vals, valid, nulls, i32)
    check(name, b, keys, vals, valid, workers, expect_served)


# FLOAT64 palette: code -> value
def fpal(c: Int) -> Float64:
    if c == 0:
        return Float64(1.1)
    if c == 1:
        return Float64(1.9)
    if c == 2:
        return Float64(0.0)
    if c == 3:
        return Float64(-0.0)
    if c == 4:
        return bitcast[DType.float64](UInt64(0x7FF8000000000000))
    if c == 5:
        return bitcast[DType.float64](UInt64(0xFFF8000000000123))
    if c == 6:
        return bitcast[DType.float64](UInt64(0x7FF0000000000001))  # signalling NaN
    if c == 7:
        return Float64(1.0) / Float64(0.0) if False else bitcast[DType.float64](UInt64(0x7FF0000000000000))
    if c == 8:
        return bitcast[DType.float64](UInt64(0xFFF0000000000000))
    return Float64(c)


def fcode(c: Int) -> Int64:
    if c == 3:
        return 2
    if c == 5 or c == 6:
        return 4
    return Int64(c)


def scenario_f64(name: String, mode: Int, n: Int, workers: Int, expect_served: Int, nulls: Bool, palette: Int) raises:
    var rng = Rng(UInt64(99 + mode))
    var keys = make_keys(mode, n, rng)
    var codes = List[Int64](capacity=n)
    var valid = List[Bool](capacity=n)
    var a = PrimitiveArray[DType.float64].allocate_nullable(n) if nulls else PrimitiveArray[DType.float64].allocate(n)
    for r in range(n):
        var x = rng.next()
        var c = x % palette
        a.store[1](r, fpal(c))
        codes.append(fcode(c))
        valid.append(not (nulls and (x // 16) % 4 == 0))
    if nulls:
        for r in range(n):
            if not valid[r]:
                a._set_null(r)
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    rbb.add_column(Column.from_primitive[DType.float64](a^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, nulls))
    check(name, rbb.build(sb.build()), keys, codes, valid, workers, expect_served)


def test_many_groups_int64_with_nulls_fused_equals_general() raises:
    scenario_int("many_i64", 0, FLOOR, 4, 1, False, True, 6)


def test_non_power_of_two_workers_int32_with_nulls() raises:
    scenario_int("many_i32_w3", 0, FLOOR + 5, 3, 1, True, True, 5)


def test_float64_nan_payloads_signed_zero_and_infinities() raises:
    """Three NaN payloads (one signalling) are one value, -0.0 and 0.0 one,
    +inf and -inf two; NULLs are skipped."""
    scenario_f64("f64_many", 0, FLOOR, 4, 1, True, 9)
    scenario_f64("f64_few", 1, FLOOR, 4, 1, False, 9)


def test_sliced_nullable_value_column() raises:
    var n = FLOOR
    var rng = Rng(77)
    var keys = make_keys(0, n, rng)
    var vals = List[Int64](capacity=n + 11)
    for r in range(n + 11):
        vals.append(Int64(rng.next() % 7))
    var a = PrimitiveArray[DType.int64].allocate_nullable(n + 11)
    for r in range(n + 11):
        a.store[1](r, Scalar[DType.int64](vals[r]))
    for r in range(n + 11):
        if r % 13 == 0:
            a._set_null(r)
    var full = Column.from_primitive[DType.int64](a^)
    var sl = full.slice(11, n)
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    rbb.add_column(sl^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var b = rbb.build(sb.build())
    var codes = List[Int64](capacity=n)
    var valid = List[Bool](capacity=n)
    for r in range(n):
        codes.append(vals[r + 11])
        valid.append((r + 11) % 13 != 0)
    check("sliced", b, keys, codes, valid, 4, 1)


def test_key_column_is_not_the_first_column() raises:
    var n = FLOOR
    var rng = Rng(3)
    var keys = make_keys(1, n, rng)
    var vals = List[Int64](capacity=n)
    for r in range(n):
        vals.append(Int64(rng.next() % 7))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals)))
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("k", ArrowType.STRING, False))
    var codes = vals.copy()
    var valid = List[Bool](length=n, fill=True)
    check("keysecond", rbb.build(sb.build()), keys, codes, valid, 4, 1)


# The heavy-key bar is a sampled share above 2/P: 50% at 4 workers.


def test_hot_key_below_the_bar_is_still_served() raises:
    scenario_int("hot40", 2, FLOOR, 4, 1, False, False, 30, 40)


def test_eight_equal_groups_are_served() raises:
    scenario_int("eight_equal", 1, FLOOR, 4, 1, False, False, 1000)


def test_hot_key_just_above_the_bar_declines() raises:
    scenario_int("hot55", 2, FLOOR, 4, 0, False, False, 30, 55)
    assert_equal(cd_strkey_fused_heavy_decline_count(), 1, "declined as heavy")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
