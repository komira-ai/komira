# =============================================================================
# test_cd_parallel_driver_edges -- the grouped COUNT(DISTINCT) driver refuses a
# value column it cannot read, emits nothing for a grouped empty input, and
# keeps a multi-key group's NULL flags and full key straight
# =============================================================================
#
# Every expectation is computed in the test from the raw fixture lists with a
# `Set` per group, never by another kernel. What each test catches:
#   * `test_an_unreadable_value_type_is_refused_by_name`: a COUNT(DISTINCT)
#     over an INT16 or STRING column read as 8-byte words (a silently wrong
#     count from reading past the buffer); the error must name the column and
#     its type;
#   * `test_a_float64_and_an_int32_value_are_still_served`: a refusal wider
#     than the types the driver reads;
#   * `test_a_grouped_empty_input_emits_no_group`: a group (with a bogus
#     index) invented for a grouped aggregate over no rows, for one key and
#     for two keys of different kinds;
#   * `test_null_flags_of_a_later_key_are_kept`: the NULL flag of key 1 read
#     from key 0's bit, which makes a NULL in a later key come back as a value;
#   * `test_a_hash_twin_that_differs_only_in_later_keys_stays_apart`: a heavy
#     group's fold that compares only the first key, which adds a group whose
#     hash is equal and whose first key is equal into the heavy group.
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_cd_heavy_split import (
    cd_heavy_merged_count,
    reset_cd_heavy_counters,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
)

comptime _WORKERS: Int = 4
comptime _BIG: Int = 70_000


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(
    imm batch: RecordBatch, keys: List[String], out_fields: List[Field]
) raises -> RecordBatch:
    """`SELECT keys.., COUNT(DISTINCT v) GROUP BY keys` on `_WORKERS` workers."""
    var group_by = ExprArray()
    for i in range(len(keys)):
        group_by.append(col(keys[i]).copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    for i in range(len(out_fields)):
        osb.add_field(out_fields[i])
    var sink = AggSinkData(group_by^, aggs^, osb.build())
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, len(keys), 1, batch.num_rows()
    )


def _i64_col(vals: List[Int], nulls: List[Bool]) raises -> Column[HeapRegion]:
    """INT64 column; a NULL cell keeps `vals[i]` as the word under it."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a.set(i, Int64(vals[i]))
        if len(nulls) > 0 and nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


def _out_fields(nkeys: Int) -> List[Field]:
    var f = List[Field]()
    for i in range(nkeys):
        f.append(Field("k" + String(i), ArrowType.INT64, True))
    f.append(Field("n", ArrowType.INT64, False))
    return f^


def _tag(imm rb: RecordBatch, row: Int, nkeys: Int) raises -> String:
    """The row's key as text, `N` for a NULL key cell."""
    var s = String("")
    for k in range(nkeys):
        if k > 0:
            s += "|"
        if rb.column_at(k).is_null_at(row):
            s += "N"
        else:
            s += String(Int(rb.column_at(k).as_primitive[DType.int64]().get(row)))
    return s


# -----------------------------------------------------------------------------
# The value column's type
# -----------------------------------------------------------------------------


def test_an_unreadable_value_type_is_refused_by_name() raises:
    var ks = List[Int]()
    for r in range(8):
        ks.append(r % 2)
    var i16 = PrimitiveArray[DType.int16].allocate(8)
    for r in range(8):
        i16.set(r, Int16(r))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("amount", ArrowType.INT16, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(ks, List[Bool]()))
    b.add_column(Column.from_primitive[DType.int16](i16^))
    var named = b.build(sb.build())
    var f = List[Field]()
    f.append(Field("k", ArrowType.INT64, False))
    f.append(Field("n", ArrowType.INT64, False))
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("amount")))
    var osb = SchemaBuilder()
    osb.add_field(f[0])
    osb.add_field(f[1])
    var sink = AggSinkData(group_by^, aggs^, osb.build())
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    with assert_raises(contains="value column 'amount' has type int16"):
        _ = _execute_count_distinct_agg_parallel(
            disp, ct.clone(), named, sink, 1, 1, 8
        )


def test_a_float64_and_an_int32_value_are_still_served() raises:
    var ks = List[Int]()
    for r in range(8):
        ks.append(r % 2)
    var f64 = PrimitiveArray[DType.float64].allocate(8)
    var i32 = PrimitiveArray[DType.int32].allocate(8)
    for r in range(8):
        # Group 0 sees 1.5 and 2.5 only; group 1 sees 7.5 four times.
        f64.set(r, Float64(7.5) if r % 2 == 1 else Float64(1.5 + Float64(r // 2 % 2)))
        i32.set(r, Int32(7) if r % 2 == 1 else Int32(r // 2 % 2))
    for which in range(2):
        var sb = SchemaBuilder()
        sb.add_field(Field("k", ArrowType.INT64, False))
        sb.add_field(Field("v", ArrowType.FLOAT64 if which == 0 else ArrowType.INT32, False))
        var b = RecordBatchBuilder.with_capacity(2)
        b.add_column(_i64_col(ks, List[Bool]()))
        if which == 0:
            b.add_column(Column.from_primitive[DType.float64](f64))
        else:
            b.add_column(Column.from_primitive[DType.int32](i32))
        var f = List[Field]()
        f.append(Field("k", ArrowType.INT64, False))
        f.append(Field("n", ArrowType.INT64, False))
        var rb = _run(b.build(sb.build()), ["k"], f)
        assert_equal(rb.num_rows(), 2)
        for r in range(2):
            var k = Int(rb.column_at(0).as_primitive[DType.int64]().get(r))
            assert_equal(
                Int(rb.column_at(1).as_primitive[DType.int64]().get(r)),
                2 if k == 0 else 1,
                "kind " + String(which) + " key " + String(k),
            )


# -----------------------------------------------------------------------------
# A grouped aggregate over no rows
# -----------------------------------------------------------------------------


def test_a_grouped_empty_input_emits_no_group() raises:
    var none = List[Int]()
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(none, List[Bool]()))
    b.add_column(_i64_col(none, List[Bool]()))
    var one_key = _run(b.build(sb.build()), ["k0"], _out_fields(1))
    assert_equal(one_key.num_rows(), 0, "no rows, no group")

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("k0", ArrowType.INT64, True))
    sb2.add_field(Field("k1", ArrowType.STRING, True))
    sb2.add_field(Field("v", ArrowType.INT64, True))
    var b2 = RecordBatchBuilder.with_capacity(3)
    b2.add_column(_i64_col(none, List[Bool]()))
    b2.add_column(Column.from_string(StringArray.from_strings(List[String]())))
    b2.add_column(_i64_col(none, List[Bool]()))
    var f2 = List[Field]()
    f2.append(Field("k0", ArrowType.INT64, True))
    f2.append(Field("k1", ArrowType.STRING, True))
    f2.append(Field("n", ArrowType.INT64, False))
    var two_keys = _run(b2.build(sb2.build()), ["k0", "k1"], f2)
    assert_equal(two_keys.num_rows(), 0, "no rows, no group (two keys)")


# -----------------------------------------------------------------------------
# Multi-key groups
# -----------------------------------------------------------------------------


def test_null_flags_of_a_later_key_are_kept() raises:
    """Key 0 is NULL on every 7th row and key 1 on every 5th; under a NULL cell
    sits the row number, so a NULL read back as its word is a visibly different
    group. Every (k0, k1) pair, NULL included, is its own group."""
    var k0 = List[Int]()
    var k1 = List[Int]()
    var vs = List[Int]()
    var n0 = List[Bool]()
    var n1 = List[Bool]()
    var oracle = Dict[String, Set[Int]]()
    for r in range(_BIG):
        var is0 = r % 7 == 0
        var is1 = r % 5 == 0
        var a = r if is0 else r % 3
        var b = r if is1 else (r // 3) % 4
        k0.append(a)
        k1.append(b)
        n0.append(is0)
        n1.append(is1)
        vs.append((r // 20) % 9)
        var tag = (String("N") if is0 else String(a)) + "|" + (String("N") if is1 else String(b))
        if tag not in oracle:
            oracle[tag] = Set[Int]()
        oracle[tag].add((r // 20) % 9)
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var bb = RecordBatchBuilder.with_capacity(3)
    bb.add_column(_i64_col(k0, n0))
    bb.add_column(_i64_col(k1, n1))
    bb.add_column(_i64_col(vs, List[Bool]()))
    var rb = _run(bb.build(sb.build()), ["k0", "k1"], _out_fields(2))
    assert_equal(rb.num_rows(), len(oracle), "one row per (k0, k1) pair")
    var seen = Set[String]()
    var cnts = rb.column_at(2).as_primitive[DType.int64]()
    for r in range(rb.num_rows()):
        var tag = _tag(rb, r, 2)
        assert_true(tag in oracle, "an emitted group that does not exist: " + tag)
        assert_true(tag not in seen, "group emitted twice: " + tag)
        seen.add(tag)
        assert_equal(Int(cnts.get(r)), len(oracle[tag]), "group " + tag)


def _fnv3(a: Int, b: Int, c: Int) -> Int:
    """The driver's composite hash for three non-NULL integer keys: FNV-1a
    basis 0x811C9DC5, prime 0x01000193, keys in order."""
    var h: Int = 0x811C9DC5
    h = (h ^ a) * 0x01000193
    h = (h ^ b) * 0x01000193
    h = (h ^ c) * 0x01000193
    return h


def test_a_hash_twin_that_differs_only_in_later_keys_stays_apart() raises:
    """The heavy group (0, 0, 0) holds 90% of the rows. The group (0, 1, c)
    agrees with it on key 0 and, with `c` chosen so the composite hashes are
    equal, lands on the same workers; it must fold only with itself. The third
    group is an ordinary light one."""
    var p: Int = 0x01000193
    var h1: Int = (0x811C9DC5 ^ 0) * p
    var heavy_h2 = (h1 ^ 0) * p
    var twin_h2 = (h1 ^ 1) * p
    var c = twin_h2 ^ heavy_h2
    assert_equal(_fnv3(0, 1, c), _fnv3(0, 0, 0), "FIXTURE: the hashes collide")
    var k0 = List[Int]()
    var k1 = List[Int]()
    var k2 = List[Int]()
    var vs = List[Int]()
    var oracle = Dict[String, Set[Int]]()
    for i in range(80_000):
        var r = i % 20
        var a = 0
        var b = 0
        var cc = 0
        var v = (i * 7919) % 4001
        if r == 0:
            b = 1
            cc = c
            v = i % 37
        elif r == 1:
            a = 2
            b = 3
            cc = 5
            v = i % 11
        k0.append(a)
        k1.append(b)
        k2.append(cc)
        vs.append(v)
        var tag = String(a) + "|" + String(b) + "|" + String(cc)
        if tag not in oracle:
            oracle[tag] = Set[Int]()
        oracle[tag].add(v)
    var none = List[Bool]()
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("k2", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var bb = RecordBatchBuilder.with_capacity(4)
    bb.add_column(_i64_col(k0, none))
    bb.add_column(_i64_col(k1, none))
    bb.add_column(_i64_col(k2, none))
    bb.add_column(_i64_col(vs, none))
    reset_cd_heavy_counters()
    var rb = _run(bb.build(sb.build()), ["k0", "k1", "k2"], _out_fields(3))
    assert_equal(rb.num_rows(), 3, "the heavy group, its hash twin and the light group")
    var cnts = rb.column_at(3).as_primitive[DType.int64]()
    for r in range(rb.num_rows()):
        var tag = _tag(rb, r, 3)
        assert_true(tag in oracle, "an emitted group that does not exist: " + tag)
        assert_equal(Int(cnts.get(r)), len(oracle[tag]), "group " + tag)
    assert_true(
        cd_heavy_merged_count() >= 2,
        "both the heavy group and its hash twin were split and folded",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
