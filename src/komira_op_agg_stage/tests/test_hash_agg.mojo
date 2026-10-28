# test_hash_agg.mojo — HashAggTable over the key arities and aggregate packs.
#
# Ungrouped, one-key, two-key and three-key tables, a mixed aggregate pack,
# reset and the comptime arity accessors, driven through `feed_row` (the
# breaker-state surface the stage drives). The aggregators are test-local
# conformers over Int64 column `col_idx`.

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.morsel_view import MorselView
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from komira_agg.aggregator import Aggregator
from komira_agg.count_star_op import CountStarOp
from komira_agg.hash_agg_op_dt import HashAggOpAgg, MinOp, SumOp

from komira_op_agg_stage.agg_column import AggBlock, AggColumn, AggSlot, agg_slot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import (
    KeyTuple,
    KeyTuple1,
    KeyTuple2,
    KeyTuple3,
    KeyTupleScalar,
)


@fieldwise_init
struct SumI64Agg(Aggregator):
    comptime StateTy = Int64
    comptime OUT_DT: DType = DType.int64
    var col_idx: Int

    @staticmethod
    def init() -> Int64:
        return Int64(0)

    @staticmethod
    def make() -> Self:
        comptime assert False, "SumI64Agg needs its col_idx"
        return Self.make()

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Int64, batch: BatchView[bo], i: Int):
        state = state + batch.col_i64(self.col_idx).load[1](i)[0]

    def input_is_null[V: MorselView](self, view: V, i: Int) -> Bool:
        return view.col_is_null(self.col_idx, i)

    def combine(mut self, mut into: Int64, var partial: Int64):
        into = into + partial

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state


@fieldwise_init
struct CountAgg(Aggregator):
    """COUNT(*): every row."""

    comptime StateTy = Int64
    comptime OUT_DT: DType = DType.int64
    comptime EMPTY_IS_NULL: Bool = False
    var col_idx: Int

    @staticmethod
    def init() -> Int64:
        return Int64(0)

    @staticmethod
    def make() -> Self:
        comptime assert False, "CountAgg needs its col_idx"
        return Self.make()

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Int64, batch: BatchView[bo], i: Int):
        state = state + 1

    def input_is_null[V: MorselView](self, view: V, i: Int) -> Bool:
        return False

    def combine(mut self, mut into: Int64, var partial: Int64):
        into = into + partial

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state


@fieldwise_init
struct MinI64Agg(Aggregator):
    comptime StateTy = Int64
    comptime OUT_DT: DType = DType.int64
    var col_idx: Int

    @staticmethod
    def init() -> Int64:
        return Int64.MAX

    @staticmethod
    def make() -> Self:
        comptime assert False, "MinI64Agg needs its col_idx"
        return Self.make()

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Int64, batch: BatchView[bo], i: Int):
        var v = batch.col_i64(self.col_idx).load[1](i)[0]
        if v < state:
            state = v

    def input_is_null[V: MorselView](self, view: V, i: Int) -> Bool:
        return view.col_is_null(self.col_idx, i)

    def combine(mut self, mut into: Int64, var partial: Int64):
        if partial < into:
            into = partial

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state


@fieldwise_init
struct MaxI64Agg(Aggregator):
    comptime StateTy = Int64
    comptime OUT_DT: DType = DType.int64
    var col_idx: Int

    @staticmethod
    def init() -> Int64:
        return Int64.MIN

    @staticmethod
    def make() -> Self:
        comptime assert False, "MaxI64Agg needs its col_idx"
        return Self.make()

    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Int64, batch: BatchView[bo], i: Int):
        var v = batch.col_i64(self.col_idx).load[1](i)[0]
        if v > state:
            state = v

    def input_is_null[V: MorselView](self, view: V, i: Int) -> Bool:
        return view.col_is_null(self.col_idx, i)

    def combine(mut self, mut into: Int64, var partial: Int64):
        if partial > into:
            into = partial

    @staticmethod
    def finalize(state: Int64) -> Int64:
        return state


def _li(*vals: Int64) -> List[Int64]:
    var out = List[Int64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lb(*vals: Bool) -> List[Bool]:
    var out = List[Bool](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _lf(*vals: Float64) -> List[Float64]:
    var out = List[Float64](capacity=len(vals))
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _ls(*vals: StaticString) -> List[String]:
    var out = List[String](capacity=len(vals))
    for i in range(len(vals)):
        out.append(String(vals[i]))
    return out^


def _batch3(
    imm c0: List[Int64], imm c1: List[Int64], imm c2: List[Int64]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, True))
    sb.add_field(Field("c1", ArrowType.INT64, True))
    sb.add_field(Field("c2", ArrowType.INT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(c0)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(c1)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(c2)))
    return rb.build(sb.build())


def _feed_all[
    KB: KeyTuple, *Aggs: AggColumn
](mut table: HashAggTable[KB, *Aggs], batch: RecordBatch) raises:
    var bv = BatchView(batch)
    for i in range(bv.n_rows()):
        table.feed_row(bv, i)


def _filled(n: Int, v: Int64) -> List[Int64]:
    var out = List[Int64](capacity=n)
    for _ in range(n):
        out.append(v)
    return out^


def test_scalar_single_agg() raises:
    var vals = List[Int64]()
    for i in range(6):
        vals.append(Int64(i + 1))
    var batch = _batch3(vals, _filled(6, 0), _filled(6, 0))
    var table = HashAggTable[KeyTupleScalar, AggSlot[SumI64Agg]](
        AggBlock[AggSlot[SumI64Agg]](agg_slot[SumI64Agg](SumI64Agg(0)))
    )
    _feed_all(table, batch)
    assert_equal(table.size(), 1, "an ungrouped aggregate has one group")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 21, "SUM(1..6)")


def test_scalar_multi_agg() raises:
    var vals = List[Int64]()
    for i in range(6):
        vals.append(Int64(i + 1))
    var batch = _batch3(vals, _filled(6, 0), _filled(6, 0))
    comptime A0 = AggSlot[SumI64Agg]
    comptime A1 = AggSlot[CountAgg]
    comptime A2 = AggSlot[MinI64Agg]
    comptime A3 = AggSlot[MaxI64Agg]
    var table = HashAggTable[KeyTupleScalar, A0, A1, A2, A3](
        AggBlock[A0, A1, A2, A3](
            agg_slot[SumI64Agg](SumI64Agg(0)),
            agg_slot[CountAgg](CountAgg(0)),
            agg_slot[MinI64Agg](MinI64Agg(0)),
            agg_slot[MaxI64Agg](MaxI64Agg(0)),
        )
    )
    _feed_all(table, batch)
    assert_equal(Int(table.agg_finalize_f64[0](0)), 21, "SUM")
    assert_equal(Int(table.agg_finalize_f64[1](0)), 6, "COUNT")
    assert_equal(Int(table.agg_finalize_f64[2](0)), 1, "MIN")
    assert_equal(Int(table.agg_finalize_f64[3](0)), 6, "MAX")


def test_single_key_single_agg() raises:
    # keys 1,2,1,2,1,2; values 10..60: key 1 -> 90, key 2 -> 120.
    var keys = List[Int64]()
    var vals = List[Int64]()
    for i in range(6):
        keys.append(Int64(1 + (i % 2)))
        vals.append(Int64(10 * (i + 1)))
    var batch = _batch3(keys, vals, _filled(6, 0))
    var table = HashAggTable[KeyTuple1[DType.int64, 0], AggSlot[SumI64Agg]](
        AggBlock[AggSlot[SumI64Agg]](agg_slot[SumI64Agg](SumI64Agg(1)))
    )
    _feed_all(table, batch)
    assert_equal(table.size(), 2, "two keys")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 90, "key 1 first seen")
    assert_equal(Int(table.agg_finalize_f64[0](1)), 120, "key 2 second")
    var occupied = 0
    for slot in range(table.capacity()):
        if table.keys.is_occupied(slot):
            occupied += 1
    assert_equal(occupied, 2, "two occupied slots")


def test_single_key_multi_agg() raises:
    var vals = List[Int64]()
    for i in range(6):
        vals.append(Int64(i + 1))
    var batch = _batch3(_filled(6, 7), vals, _filled(6, 0))
    comptime A0 = AggSlot[SumI64Agg]
    comptime A1 = AggSlot[CountAgg]
    var table = HashAggTable[KeyTuple1[DType.int64, 0], A0, A1](
        AggBlock[A0, A1](
            agg_slot[SumI64Agg](SumI64Agg(1)), agg_slot[CountAgg](CountAgg(1))
        )
    )
    _feed_all(table, batch)
    assert_equal(table.size(), 1, "one key")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 21, "SUM")
    assert_equal(Int(table.agg_finalize_f64[1](0)), 6, "COUNT")


def test_two_key_composite() raises:
    # (1,1)=5+9, (1,2)=7+11, in that first-seen order.
    var k0 = _li(1, 1, 1, 1)
    var k1 = _li(1, 2, 1, 2)
    var v = _li(5, 7, 9, 11)
    var batch = _batch3(k0, k1, v)
    var table = HashAggTable[
        KeyTuple2[DType.int64, 0, DType.int64, 1], AggSlot[SumI64Agg]
    ](AggBlock[AggSlot[SumI64Agg]](agg_slot[SumI64Agg](SumI64Agg(2))))
    _feed_all(table, batch)
    assert_equal(table.size(), 2, "two composite keys")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 14, "(1,1)")
    assert_equal(Int(table.agg_finalize_f64[0](1)), 18, "(1,2)")


def test_three_key_composite() raises:
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    var k2 = List[Int64]()
    for grp in range(3):
        for _ in range(2):
            k0.append(Int64(grp))
            k1.append(Int64(grp * 10))
            k2.append(Int64(grp * 100 + 1))
    var batch = _batch3(k0, k1, k2)
    var table = HashAggTable[
        KeyTuple3[DType.int64, 0, DType.int64, 1, DType.int64, 2],
        AggSlot[CountAgg],
    ](AggBlock[AggSlot[CountAgg]](agg_slot[CountAgg](CountAgg(0))))
    _feed_all(table, batch)
    assert_equal(table.size(), 3, "three triples")
    for g in range(3):
        assert_equal(Int(table.agg_finalize_f64[0](g)), 2, "two rows each")


def test_heterogeneous_agg_pack() raises:
    var vals = _li(3, 1, 4, 1, 5, 9)
    var batch = _batch3(_filled(6, 42), vals, _filled(6, 0))
    comptime A0 = AggSlot[SumI64Agg]
    comptime A1 = AggSlot[MinI64Agg]
    comptime A2 = AggSlot[MaxI64Agg]
    comptime A3 = AggSlot[CountAgg]
    var table = HashAggTable[KeyTuple1[DType.int64, 0], A0, A1, A2, A3](
        AggBlock[A0, A1, A2, A3](
            agg_slot[SumI64Agg](SumI64Agg(1)),
            agg_slot[MinI64Agg](MinI64Agg(1)),
            agg_slot[MaxI64Agg](MaxI64Agg(1)),
            agg_slot[CountAgg](CountAgg(1)),
        )
    )
    _feed_all(table, batch)
    assert_equal(Int(table.agg_finalize_f64[0](0)), 23, "SUM")
    assert_equal(Int(table.agg_finalize_f64[1](0)), 1, "MIN")
    assert_equal(Int(table.agg_finalize_f64[2](0)), 9, "MAX")
    assert_equal(Int(table.agg_finalize_f64[3](0)), 6, "COUNT")


def test_reset() raises:
    var keys = List[Int64]()
    var vals = List[Int64]()
    for i in range(6):
        keys.append(Int64(1 + (i % 3)))
        vals.append(Int64(i + 1))
    var batch = _batch3(keys, vals, _filled(6, 0))
    var table = HashAggTable[KeyTuple1[DType.int64, 0], AggSlot[SumI64Agg]](
        AggBlock[AggSlot[SumI64Agg]](agg_slot[SumI64Agg](SumI64Agg(1)))
    )
    _feed_all(table, batch)
    assert_equal(table.size(), 3, "three groups")
    table.reset()
    assert_equal(table.size(), 0, "none after reset")
    assert_equal(table.keys.is_occupied(0), False, "slot 0 free after reset")
    _feed_all(table, batch)
    assert_equal(table.size(), 3, "refilled after reset")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 5, "key 1: rows 0 and 3")


def test_arity_accessors() raises:
    comptime A0 = AggSlot[SumI64Agg]
    comptime A1 = AggSlot[CountAgg]
    assert_equal(HashAggTable[KeyTupleScalar, A0].key_arity(), 0, "0 keys")
    assert_equal(
        HashAggTable[KeyTuple1[DType.int64, 0], A0].key_arity(), 1, "1 key"
    )
    assert_equal(
        HashAggTable[
            KeyTuple3[DType.int64, 0, DType.int64, 1, DType.int64, 2], A0
        ].key_arity(),
        3,
        "3 keys",
    )
    assert_equal(
        HashAggTable[KeyTuple1[DType.int64, 0], A0, A1].agg_arity(),
        2,
        "2 aggregates",
    )


def test_more_groups_than_the_first_reserve() raises:
    # 5,000 keys: the directory and the state lists grow past their first
    # reserve, and every group keeps its own sum.
    var keys = List[Int64]()
    var vals = List[Int64]()
    for r in range(10_000):
        keys.append(Int64(r % 5_000))
        vals.append(Int64(r))
    var batch = _batch3(keys, vals, _filled(10_000, 0))
    var table = HashAggTable[KeyTuple1[DType.int64, 0], AggSlot[SumI64Agg]](
        AggBlock[AggSlot[SumI64Agg]](agg_slot[SumI64Agg](SumI64Agg(1)))
    )
    _feed_all(table, batch)
    assert_equal(table.size(), 5_000, "5,000 groups")
    for g in range(5_000):
        assert_equal(
            Int(table.agg_finalize_f64[0](g)), 2 * g + 5_000, "group sum"
        )


comptime _MixSum = AggSlot[HashAggOpAgg[SumOp[DType.float64], 2]]
comptime _MixCnt = AggSlot[HashAggOpAgg[CountStarOp[DType.int64], 1]]
comptime _MixMin = AggSlot[HashAggOpAgg[MinOp[DType.int64], 1]]
comptime _Mixed = HashAggTable[KeyTuple1[DType.int64, 0], _MixSum, _MixCnt, _MixMin]


def _mixed_batch(
    imm k: List[Int64], imm ci: List[Int64], imm cf: List[Float64]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ci)))
    rb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(cf)))
    return rb.build(sb.build())


def test_nullary_construction_mixed_input_types() raises:
    # The nullary constructor builds every AggSlot from `A.make()`.
    # key 1: rows 0,2,3,5 -> SUM(f)=140, COUNT(*)=4, MIN(i)=3.
    # key 2: rows 1,4     -> SUM(f)=70,  COUNT(*)=2, MIN(i)=1.
    var batch = _mixed_batch(
        _li(1, 2, 1, 1, 2, 1),
        _li(5, 9, 7, 3, 1, 4),
        _lf(10, 20, 30, 40, 50, 60),
    )
    var table = _Mixed()
    _feed_all(table, batch)
    assert_equal(table.size(), 2, "two keys")
    assert_equal(Int(table.agg_finalize_f64[0](0)), 140, "key 1 SUM")
    assert_equal(Int(table.agg_finalize_f64[1](0)), 4, "key 1 COUNT")
    assert_equal(Int(table.agg_finalize_f64[2](0)), 3, "key 1 MIN")
    assert_equal(Int(table.agg_finalize_f64[0](1)), 70, "key 2 SUM")
    assert_equal(Int(table.agg_finalize_f64[1](1)), 2, "key 2 COUNT")
    assert_equal(Int(table.agg_finalize_f64[2](1)), 1, "key 2 MIN")


def test_drain_emits_each_aggregate_in_its_native_type() raises:
    var batch = _mixed_batch(
        _li(7, 7, 7, 7),
        _li(2, 3, 4, 5),
        _lf(100, 200, 300, 400),
    )
    var table = _Mixed()
    _feed_all(table, batch)
    table.with_output_names(_ls("total", "n", "lo"))
    var res = table.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_columns(), 4, "key + 3 aggregates")
    assert_equal(out.num_rows(), 1, "one group")
    assert_equal(out.column_at(1).as_primitive[DType.float64]().get(0), Float64(1000), "SUM(f64)")
    assert_equal(out.column_at(2).as_primitive[DType.int64]().get(0), Int64(4), "COUNT(*)")
    assert_equal(out.column_at(3).as_primitive[DType.int64]().get(0), Int64(2), "MIN(i64)")


def test_output_names_must_match_the_aggregate_count() raises:
    var table = _Mixed()
    table.with_output_names(_ls("only_one"))
    var raised = False
    try:
        _ = table.drain_to_record_batch()
    except:
        raised = True
    assert_equal(raised, True, "a name-count mismatch raises")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
