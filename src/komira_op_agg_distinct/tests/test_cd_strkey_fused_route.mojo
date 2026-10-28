# =============================================================================
# test_cd_strkey_fused_route -- the fused string-key COUNT(DISTINCT) route
# answers what the general driver answers, in first-seen order, and declines
# every shape it does not own
# =============================================================================
#
# `agg_cd_strkey_fused` serves `GROUP BY <one STRING key>` with only
# COUNT(DISTINCT) aggregates by admitting the (key, value) pairs inside the
# sharded dictionary pass. Its correctness argument is one sentence (a key's
# rows all hash to one shard, so a shard's distinct set is globally correct),
# and this file is where that sentence fails if it is wrong.
#
# What each test catches:
#   * admission: a shape the route does not own served (two keys, an INT or
#     DICTIONARY key, a non-CD aggregate, one worker, a small input);
#   * the shard selector: a shard never reached at a non-power-of-two width;
#   * counts and order: a wrong count, a dropped or duplicated key, or a key
#     out of FIRST-SEEN order, against the fixture's own generator;
#   * two aggregates and NULLs: a NULL value admitted, an all-NULL key dropped;
#   * equal to the general driver (the oracle arm, `allow_fused=False`), and a
#     bounded top-k drain equal to the full drain plus top-N;
#   * a heavy key not handed back (route witness);
#   * a NULL key not handed back: the route has no NULL group, so a key column
#     with a NULL must go to the general driver, whose NULL group is apart
#     from '' (without the decline NULL would merge into '');
#   * a LARGE_STRING key read at the wrong offset width;
#   * a value column of a type the value lanes cannot read refused by column
#     name and type before the route runs, as the general driver refuses it;
#   * FLOAT64 and INT32 value columns counted exactly (1.1 and 1.9 are two
#     values, -0.0 and 0.0 one), against a Dict oracle and the general driver;
#   * long keys that differ only in their last byte, and few large groups;
#   * one key owning every row (declines), and an empty input (declines).
#
# Every fused-route test asserts the SERVED counter moved; the decline tests
# assert it did not.
# =============================================================================

from std.collections import Dict, List, Optional, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_plan_expr.agg_expr import count, count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData, TopNSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_group_topk import CdGroupTopKHint
from komira_op_agg_distinct.agg_cd_strenc_parb import _PHASEB_MIN_ROWS
from komira_op_agg_distinct.agg_cd_strkey_fused import (
    CD_FUSED_MAX_SHARDS,
    cd_fused_shard_count,
    cd_fused_shard_of,
    cd_strkey_fused_heavy_decline_count,
    cd_strkey_fused_served_count,
    cd_strkey_fused_shape_admits,
    reset_cd_strkey_fused_counters,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
)
from komira_op_sort.sort_topn_sink import _execute_topn_sink

comptime _ROWS: Int = _PHASEB_MIN_ROWS
comptime _KEYS: Int = 40_000
comptime _WORKERS: Int = 4


# =============================================================================
# Fixture: key k first appears at row k; key k sees 1 + k % 7 distinct values
# in `v`, and (in the two-aggregate fixture) 1 + k % 3 in `w`, with `w` NULL on
# every third row and on EVERY row of key 7
# =============================================================================


def _key(k: Int) -> String:
    """Varied lengths, an EMPTY key, a multi-byte UTF-8 key every eleventh."""
    if k == 0:
        return String("")
    var s = String("ÄÖ-") if k % 11 == 5 else String("k")
    s += String(k)
    for _ in range(k % 13):
        s += String("x")
    return s


def _v_distinct(k: Int) -> Int:
    return 1 + k % 7


def _w_distinct(k: Int) -> Int:
    """Distinct non-NULL `w` values of key k (key 7: all NULL -> 0)."""
    if k == 7:
        return 0
    return 1 + k % 3


def _w_null(r: Int) -> Bool:
    return (r % 3) == 2 or (r % _KEYS) == 7


def _keys_list(n_keys: Int, heavy: Bool) -> List[String]:
    """Row r carries key `r % n_keys`; with `heavy`, EVERY EVEN row is key 1
    instead — one key holding half the rows."""
    var keys = List[String](capacity=_ROWS)
    for r in range(_ROWS):
        if heavy and r % 2 == 0:
            keys.append(_key(1))
        else:
            keys.append(_key(r % n_keys))
    return keys^


def _batch(
    key_at: ArrowType, two_aggs: Bool, heavy: Bool = False
) raises -> RecordBatch:
    var keys = _keys_list(_KEYS, heavy)
    var varr = PrimitiveArray[DType.int64].allocate(_ROWS)
    for r in range(_ROWS):
        var k = r % _KEYS
        varr.store[1](r, Scalar[DType.int64]((r // _KEYS) % _v_distinct(k)))
    var rbb = RecordBatchBuilder.with_capacity(3)
    if key_at == ArrowType.LARGE_STRING:
        rbb.add_column(Column.from_large_string(LargeStringArray.from_strings(keys)))
    else:
        rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", key_at, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    if two_aggs:
        var warr = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
        for r in range(_ROWS):
            var k = r % _KEYS
            warr.store[1](
                r, Scalar[DType.int64](100 + (r // _KEYS) % (1 + k % 3))
            )
        for r in range(_ROWS):
            if _w_null(r):
                warr._set_null(r)
        rbb.add_column(Column.from_primitive[DType.int64](warr^))
        sb.add_field(Field("w", ArrowType.INT64, True))
    return rbb.build(sb.build())


def _sink(two_aggs: Bool) raises -> AggSinkData:
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    # STRING for both input widths: the emit always builds an Int32-offset
    # `string` (see `test_agg_cd_parallel_large_string_offsets.mojo`).
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    if two_aggs:
        aggs.append(count_distinct(col("w")))
        osb.add_field(Field("m", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(
    imm batch: RecordBatch,
    two_aggs: Bool,
    var hint: Optional[CdGroupTopKHint],
    allow_fused: Bool = True,
) raises -> RecordBatch:
    var sink = _sink(two_aggs)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp,
        ct.clone(),
        batch,
        sink,
        1,
        2 if two_aggs else 1,
        batch.num_rows(),
        hint^,
        allow_fused,
    )



# =============================================================================
# ADMISSION
# =============================================================================


def test_shape_admission_serves_only_its_own_shape() raises:
    var one = _sink(False)
    var s = ArrowType.STRING
    assert_true(
        cd_strkey_fused_shape_admits(1, s, one, 1, _ROWS, 4), "one STRING key, COUNT(DISTINCT) only"
    )
    assert_true(
        cd_strkey_fused_shape_admits(1, ArrowType.LARGE_STRING, one, 1, _ROWS, 4),
        "a LARGE_STRING key",
    )
    assert_false(
        cd_strkey_fused_shape_admits(2, s, one, 1, _ROWS, 4), "two keys"
    )
    assert_false(
        cd_strkey_fused_shape_admits(1, ArrowType.INT64, one, 1, _ROWS, 4),
        "an INT key",
    )
    assert_false(
        cd_strkey_fused_shape_admits(1, ArrowType.DICTIONARY, one, 1, _ROWS, 4),
        "a DICTIONARY key",
    )
    assert_false(
        cd_strkey_fused_shape_admits(1, s, one, 1, _ROWS, 1), "one worker"
    )
    assert_false(
        cd_strkey_fused_shape_admits(1, s, one, 1, _ROWS - 1, 4),
        "below the sharded Phase B's row floor",
    )
    var mixed_aggs = AggExprArray()
    mixed_aggs.append(count_distinct(col("v")))
    mixed_aggs.append(count(col("v")))
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var osb = SchemaBuilder()
    osb.add_field(Field("k", ArrowType.STRING, False))
    osb.add_field(Field("n", ArrowType.INT64, False))
    osb.add_field(Field("c", ArrowType.INT64, False))
    var mixed = AggSinkData(gb^, mixed_aggs^, osb.build())
    assert_false(
        cd_strkey_fused_shape_admits(1, s, mixed, 2, _ROWS, 4),
        "a non-COUNT(DISTINCT) aggregate",
    )


def test_shard_selector_covers_every_shard_at_any_width() raises:
    """P is the worker count, not a power of two, so the selector is a
    multiply-shift. Every shard in [0, P) must be reached and none flooded,
    at widths that are and are not powers of two — a selector that dropped a
    shard would still answer correctly, just on fewer cores."""
    var widths = List[Int]()
    widths.append(3)
    widths.append(16)
    widths.append(20)
    widths.append(32)
    for wi in range(len(widths)):
        var P = widths[wi]
        var hits = List[Int](length=P, fill=0)
        var n = 64_000
        for i in range(n):
            var h = Int64(i) * Int64(-7046029254386353131)  # a 64-bit mix
            var p = cd_fused_shard_of(h, P)
            assert_true(p >= 0 and p < P, "shard out of range at P=" + String(P))
            hits[p] += 1
        for p in range(P):
            assert_true(
                hits[p] > (n // P) // 2 and hits[p] < 2 * (n // P),
                "P=" + String(P) + " shard " + String(p) + " got "
                + String(hits[p]) + " of " + String(n),
            )
    assert_equal(cd_fused_shard_count(20), 20, "one shard per worker")
    assert_equal(cd_fused_shard_count(88), CD_FUSED_MAX_SHARDS, "capped")
    assert_equal(cd_fused_shard_count(1), 1, "floor")


# =============================================================================
# THE ANSWER, AND ITS ORDER, AGAINST AN INDEPENDENT ORACLE
# =============================================================================


def test_fused_route_counts_and_first_seen_order() raises:
    reset_cd_strkey_fused_counters()
    var batch = _batch(ArrowType.STRING, False)
    var got = _run(batch, False, None)
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    assert_equal(got.num_rows(), _KEYS, "one row per key")
    var ks = got.column_at(0).as_string()
    var ns = got.column_at(1).as_primitive[DType.int64]()
    for i in range(_KEYS):
        # Key i first appears at row i, so first-seen order IS key order.
        assert_equal(ks.get(i), _key(i), "row " + String(i) + ": key/order")
        assert_equal(Int(ns.get(i)), _v_distinct(i), "row " + String(i) + ": count")


# =============================================================================
# TWO AGGREGATES, NULLS, AN ALL-NULL KEY
# =============================================================================


def test_two_aggregates_and_nulls() raises:
    reset_cd_strkey_fused_counters()
    var batch = _batch(ArrowType.STRING, True)
    var got = _run(batch, True, None)
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    assert_equal(got.num_rows(), _KEYS, "one row per key, key 7 included")
    var ks = got.column_at(0).as_string()
    var ns = got.column_at(1).as_primitive[DType.int64]()
    var ms = got.column_at(2).as_primitive[DType.int64]()
    for i in range(_KEYS):
        assert_equal(ks.get(i), _key(i), "row " + String(i) + ": key")
        assert_equal(Int(ns.get(i)), _v_distinct(i), "row " + String(i) + ": v")
        # w's distinct values are drawn from the rows whose w is NOT NULL, so
        # compute the expectation from the generator directly.
        var seen = Dict[Int, Int]()
        var r = i
        while r < _ROWS:
            if not _w_null(r):
                seen[100 + (r // _KEYS) % (1 + i % 3)] = 1
            r += _KEYS
        assert_equal(Int(ms.get(i)), len(seen), "row " + String(i) + ": w")
    assert_equal(Int(ms.get(7)), 0, "the all-NULL key counts 0 and is emitted")


# =============================================================================
# THE SAME ANSWER AS THE GENERAL DRIVER; BOUNDED == FULL + TOPN
# =============================================================================


def _as_map(imm rb: RecordBatch, col_ix: Int) raises -> Dict[String, Int]:
    var out = Dict[String, Int]()
    var ks = rb.column_at(0).as_string()
    var ns = rb.column_at(col_ix).as_primitive[DType.int64]()
    for i in range(rb.num_rows()):
        var k = ks.get(i)
        assert_false(k in out, "key emitted twice: '" + k + "'")
        out[k] = Int(ns.get(i))
    return out^


def test_fused_equals_the_general_driver() raises:
    reset_cd_strkey_fused_counters()
    var batch = _batch(ArrowType.STRING, True)
    var fused = _run(batch, True, None)
    assert_equal(cd_strkey_fused_served_count(), 1, "fused arm served")
    var general = _run(batch, True, None, allow_fused=False)
    assert_equal(cd_strkey_fused_served_count(), 1, "oracle arm is the GENERAL driver")
    assert_equal(fused.num_rows(), general.num_rows(), "row count")
    for c in range(1, 3):
        var a = _as_map(fused, c)
        var b = _as_map(general, c)
        for e in b.items():
            assert_true(e.key in a, "general key missing from fused: " + e.key)
            assert_equal(a[e.key], e.value, "column " + String(c) + " key " + e.key)


def test_bounded_drain_equals_full_drain_plus_topn() raises:
    var batch = _batch(ArrowType.STRING, False)
    var cols = List[String]()
    cols.append(String("n"))
    var d = List[Bool]()
    d.append(True)
    reset_cd_strkey_fused_counters()
    var got = _run(batch, False, Optional(CdGroupTopKHint(cols^, d^, 10)))
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    var full = _run(batch, False, None)
    var keys = List[String]()
    keys.append(String("n"))
    var dd = List[Bool]()
    dd.append(True)
    var want = _execute_topn_sink(full^, TopNSinkData(keys^, dd^, 10))
    assert_equal(got.num_rows(), want.num_rows(), "row count")
    var gs = got.column_at(0).as_string()
    var ws = want.column_at(0).as_string()
    var gn = got.column_at(1).as_primitive[DType.int64]()
    var wn = want.column_at(1).as_primitive[DType.int64]()
    for i in range(want.num_rows()):
        assert_equal(gs.get(i), ws.get(i), "key " + String(i))
        assert_equal(Int(gn.get(i)), Int(wn.get(i)), "count " + String(i))


# =============================================================================
# A HEAVY KEY IS HANDED BACK
# =============================================================================


def test_heavy_key_declines_and_the_general_driver_answers() raises:
    reset_cd_strkey_fused_counters()
    var batch = _batch(ArrowType.STRING, False, heavy=True)
    var got = _run(batch, False, None)
    assert_equal(cd_strkey_fused_served_count(), 0, "a heavy key must decline")
    assert_equal(
        cd_strkey_fused_heavy_decline_count(), 1, "and say it declined for that"
    )
    # Independent oracle: key 1 owns every even row plus its odd ones; every
    # other key keeps only its odd rows.
    var want = Dict[String, Int]()
    for k in range(_KEYS):
        var seen = Dict[Int, Int]()
        var r = k
        while r < _ROWS:
            if r % 2 == 1:
                seen[(r // _KEYS) % _v_distinct(k)] = 1
            r += _KEYS
        if len(seen) > 0:
            want[_key(k)] = len(seen)
    # Key 1's even rows carry the values of the row's OWN position.
    var s1 = Dict[Int, Int]()
    for r in range(_ROWS):
        if r % 2 == 0 or r % _KEYS == 1:
            s1[(r // _KEYS) % _v_distinct(r % _KEYS)] = 1
    want[_key(1)] = len(s1)
    var have = _as_map(got, 1)
    assert_equal(len(have), len(want), "key count")
    for e in want.items():
        assert_true(e.key in have, "missing key " + e.key)
        assert_equal(have[e.key], e.value, "key " + e.key)


# =============================================================================
# A LARGE_STRING KEY (Int64 offsets)
# =============================================================================


def test_large_string_key_through_the_fused_route() raises:
    reset_cd_strkey_fused_counters()
    var batch = _batch(ArrowType.LARGE_STRING, False)
    var got = _run(batch, False, None)
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    assert_equal(got.num_rows(), _KEYS, "one row per key")
    var ks = got.column_at(0).as_string()
    var ns = got.column_at(1).as_primitive[DType.int64]()
    for i in range(_KEYS):
        assert_equal(ks.get(i), _key(i), "row " + String(i) + ": key")
        assert_equal(Int(ns.get(i)), _v_distinct(i), "row " + String(i) + ": count")
# =============================================================================
# A NULL key is handed back
# =============================================================================


def test_null_key_declines_and_the_general_driver_keeps_it_apart() raises:
    """The fixture with every 9th row's key NULL (its bytes are '', and key 0
    is the real ''): the fused route declines, and the general driver emits a
    NULL group apart from ''."""
    var keys = _keys_list(_KEYS, False)
    var valid = List[Bool](capacity=_ROWS)
    var vals = List[Int64](capacity=_ROWS)
    var oracle = Dict[String, Set[Int64]]()
    for r in range(_ROWS):
        var is_null = r % 9 == 4
        valid.append(not is_null)
        if is_null:
            keys[r] = String("")
        var v = Int64(r % 17)
        vals.append(v)
        var tag = String("<NULL>") if is_null else keys[r]
        if tag not in oracle:
            oracle[tag] = Set[Int64]()
        oracle[tag].add(v)
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings_with_validity(keys, valid)))
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals))
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    reset_cd_strkey_fused_counters()
    var got = _run(rbb.build(sb.build()), False, None)
    assert_equal(cd_strkey_fused_served_count(), 0, "a NULL key must decline")
    assert_equal(got.num_rows(), len(oracle), "one row per key, NULL included")
    var ks = got.column_at(0).as_string()
    var ns = got.column_at(1).as_primitive[DType.int64]()
    for i in range(got.num_rows()):
        var tag = String("<NULL>") if got.column_at(0).is_null_at(i) else ks.get(i)
        assert_equal(Int(ns.get(i)), len(oracle[tag]), "group " + tag)


# =============================================================================
# Custom-column fixtures: a key list plus one value column of a chosen type
# =============================================================================


def _run_one_value(
    var keys: List[String],
    var vcol: Column,
    vtype: ArrowType,
    allow_fused: Bool = True,
) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(StringArray.from_strings(keys)))
    rbb.add_column(vcol^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("v", vtype, False))
    return _run(rbb.build(sb.build()), False, None, allow_fused)


def _i64_col(vals: List[Int64]) raises -> Column:
    return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals))


def test_unreadable_value_type_is_refused_by_name_and_type() raises:
    reset_cd_strkey_fused_counters()
    var keys = List[String](capacity=_ROWS)
    var svals = List[String](capacity=_ROWS)
    for r in range(_ROWS):
        keys.append(_key(r % _KEYS))
        svals.append(String(r % 5))
    var raised = False
    try:
        _ = _run_one_value(
            keys^, Column.from_string(StringArray.from_strings(svals)), ArrowType.STRING
        )
    except e:
        raised = True
        var msg = String(e)
        assert_true("'v'" in msg, "names the column: " + msg)
        assert_true(
            "only INT32, INT64 and FLOAT64 are supported" in msg,
            "says which types are read: " + msg,
        )
    assert_true(raised, "a STRING value column must be refused")
    assert_equal(cd_strkey_fused_served_count(), 0, "the route did not run")


def test_float64_values_count_exactly() raises:
    """1.1 and 1.9 are two values (a truncating key would make them one);
    -0.0 and 0.0 are one."""
    reset_cd_strkey_fused_counters()
    var keys = List[String](capacity=_ROWS)
    var fvals = List[Float64](capacity=_ROWS)
    var oracle = Dict[String, Set[Int64]]()
    for r in range(_ROWS):
        var k = r % _KEYS
        var t = (r // _KEYS) % 4
        var f = Float64(1.1)
        var code = Int64(0)
        if t == 1:
            f = Float64(1.9)
            code = 1
        elif t == 2:
            f = Float64(0.0)
            code = 2
        elif t == 3:
            f = Float64(-0.0)
            code = 2
        keys.append(_key(k))
        fvals.append(f)
        if _key(k) not in oracle:
            oracle[_key(k)] = Set[Int64]()
        oracle[_key(k)].add(code)
    var got = _run_one_value(
        keys.copy(),
        Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(fvals)),
        ArrowType.FLOAT64,
    )
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    var have = _as_map(got, 1)
    assert_equal(len(have), len(oracle), "key count")
    for e in oracle.items():
        assert_equal(have[e.key], len(e.value), "key " + e.key)


def test_int32_values_count_exactly() raises:
    reset_cd_strkey_fused_counters()
    var keys = List[String](capacity=_ROWS)
    var vals = List[Int32](capacity=_ROWS)
    var oracle = Dict[String, Set[Int32]]()
    for r in range(_ROWS):
        var k = r % _KEYS
        # Includes values past 2^31 - 1 wrapped by Int32, and negatives.
        var v = Int32((r // _KEYS) * 1_000_003 % 5 - 2)
        keys.append(_key(k))
        vals.append(v)
        if _key(k) not in oracle:
            oracle[_key(k)] = Set[Int32]()
        oracle[_key(k)].add(v)
    var got = _run_one_value(
        keys^,
        Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(vals)),
        ArrowType.INT32,
    )
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    var have = _as_map(got, 1)
    assert_equal(len(have), len(oracle), "key count")
    for e in oracle.items():
        assert_equal(have[e.key], len(e.value), "key " + e.key)


def test_long_keys_differing_in_the_last_byte_and_few_groups() raises:
    """Fifty groups whose keys share a 1 KiB prefix and differ in the last
    byte only; every key repeats on many rows."""
    reset_cd_strkey_fused_counters()
    var prefix = String("")
    for _ in range(1024):
        prefix += String("p")
    var keys = List[String](capacity=_ROWS)
    var vals = List[Int64](capacity=_ROWS)
    var oracle = Dict[String, Set[Int64]]()
    for r in range(_ROWS):
        var k = prefix + String(chr(Int(ord("A")) + r % 50))
        var v = Int64((r // 50) % 11)
        keys.append(k)
        vals.append(v)
        if k not in oracle:
            oracle[k] = Set[Int64]()
        oracle[k].add(v)
    var got = _run_one_value(keys.copy(), _i64_col(vals), ArrowType.INT64)
    assert_equal(cd_strkey_fused_served_count(), 1, "the fused route served")
    var have = _as_map(got, 1)
    assert_equal(len(have), 50, "fifty groups")
    for e in oracle.items():
        assert_true(e.key in have, "missing a long key")
        assert_equal(have[e.key], len(e.value), "a long key's count")
    var ks = got.column_at(0).as_string()
    for i in range(50):
        assert_equal(
            ks.get(i), prefix + String(chr(Int(ord("A")) + i)), "first-seen order"
        )


def test_one_key_owning_every_row_declines_and_counts_right() raises:
    reset_cd_strkey_fused_counters()
    var keys = List[String](capacity=_ROWS)
    var vals = List[Int64](capacity=_ROWS)
    var seen = Set[Int64]()
    for r in range(_ROWS):
        keys.append(String("only"))
        vals.append(Int64(r % 1013))
        seen.add(Int64(r % 1013))
    var got = _run_one_value(keys^, _i64_col(vals), ArrowType.INT64)
    assert_equal(cd_strkey_fused_served_count(), 0, "one hot key must decline")
    assert_equal(cd_strkey_fused_heavy_decline_count(), 1, "declined as heavy")
    assert_equal(got.num_rows(), 1, "one group")
    assert_equal(Int(got.column_at(1).as_primitive[DType.int64]().get(0)), len(seen), "its count")


def test_empty_input_is_not_served_and_yields_no_groups() raises:
    reset_cd_strkey_fused_counters()
    var keys = List[String]()
    var vals = List[Int64]()
    var got = _run_one_value(keys^, _i64_col(vals), ArrowType.INT64)
    assert_equal(cd_strkey_fused_served_count(), 0, "an empty input is not served")
    assert_equal(got.num_rows(), 0, "no rows, no groups")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
