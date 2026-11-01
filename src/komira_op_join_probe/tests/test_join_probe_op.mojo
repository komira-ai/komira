# `JoinProbeOp`, the streaming single-key join probe, arm by arm, each answer
# checked row by row:
#   * INNER without a worker slot (the whole morsel at once), with
#     partition_id and origin_hint kept, across four workers' operators, on
#     an empty and an unmatched morsel;
#   * LEFT, SEMI and ANTI with a NULL probe key whose slot holds a real build
#     key: LEFT keeps the row with a NULL build side, SEMI drops it, ANTI keeps
#     it (a NULL matches nothing, as in DuckDB);
#   * SEMI and ANTI in count-only form;
#   * STRATEGY_PERFECT and STRATEGY_RADIX, a NULL probe key included;
#   * the RESUMABLE INNER arm: 90,000 matches leave in two chunks
#     (HAVE_MORE_OUTPUT with 65,536 rows, then NEED_MORE_INPUT), the slot is
#     ready for the next morsel, and the result is the same with buffer reuse
#     on (counted as reuse).

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI

from komira_op_join_build.join import HashJoinBuilder, PROBE_CHUNK_SIZE
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_probe.join_probe_levers import (
    join_probe_buf_fresh_count,
    join_probe_buf_reuse_configure,
    join_probe_buf_reuse_count,
    join_probe_buf_reuse_reset_config,
    reset_join_probe_lever_counters,
)
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    STRATEGY_PERFECT,
    STRATEGY_RADIX,
    ColumnarProbeSharedState,
    build_shared_probe_state,
)
from komira_op_join_probe.radix_join import RadixPartitionedHashJoin


comptime NULL: Int64 = -999


def _i64(vals: List[Int64]) -> Column[HeapRegion]:
    """`NULL` entries are NULL with slot value 0."""
    var has_null = False
    for v in vals:
        if v == NULL:
            has_null = True
    if not has_null:
        return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals))
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr._typed_ptr_mut()[i] = Int64(0) if vals[i] == NULL else vals[i]
        if vals[i] == NULL:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr^)


def _kv(k: String, keys: List[Int64], v: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, True))
    sb.add_field(Field(v, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(keys))
    rb.add_column(_i64(vals))
    return rb.build(sb.build())


def _build_keys() -> List[Int64]:
    return [10, 20, 30, 40, 50, 0]


def _build() raises -> RecordBatch:
    """bk 10..50 and 0, bv = 10 * bk (0 -> 0)."""
    return _kv("bk", _build_keys(), "bv", [100, 200, 300, 400, 500, 0])


def _schema(join_type: UInt8) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, True))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    if join_type == JOIN_INNER or join_type == JOIN_LEFT:
        sb.add_field(Field("bk", ArrowType.INT64, True))
        sb.add_field(Field("bv", ArrowType.INT64, True))
    return sb.build()


def _op(
    join_type: UInt8,
    strategy: UInt8 = 0,
    count_only: Bool = False,
    slot: Bool = False,
    build_keys: List[Int64] = _build_keys(),
    var build: Optional[RecordBatch] = None,
) raises -> JoinProbeOp:
    var b = build.take() if build else _build()
    var keys = PrimitiveArray[DType.int64].from_list(build_keys)
    var perfect = Optional[ArcPointer[PerfectHashJoin]](None)
    var radix = Optional[ArcPointer[RadixPartitionedHashJoin]](None)
    if strategy == STRATEGY_PERFECT:
        var p = PerfectHashJoin.try_build(keys)
        assert_true(Bool(p), "fixture: the build keys admit a perfect hash")
        perfect = ArcPointer[PerfectHashJoin](p.take())
    elif strategy == STRATEGY_RADIX:
        radix = ArcPointer[RadixPartitionedHashJoin](RadixPartitionedHashJoin.build(keys))
    var shared = Optional[ArcPointer[ColumnarProbeSharedState]](None)
    if slot:
        shared = build_shared_probe_state(1)
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](HashJoinBuilder.build(keys)),
        ArcPointer[RecordBatch](b^),
        "pk",
        "bk",
        ArcPointer[Schema](_schema(join_type)),
        join_type,
        shared=shared^,
        local_id=0 if slot else -1,
        strategy=strategy,
        perfect=perfect^,
        radix=radix^,
        count_only=count_only,
    )


def _col(imm b: RecordBatch, name: String) raises -> List[Int64]:
    var a = b.column_at(b.schema.column_index(name)).as_primitive[DType.int64]()
    var out = List[Int64]()
    for i in range(a.length):
        out.append(NULL if a.is_null(i) else a.get(i))
    return out^


def _assert(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _probe() raises -> RecordBatch:
    """pk 30, 99, 20, NULL (slot 0, the build has 0), 50; pv 1000..1004."""
    return _kv("pk", [30, 99, 20, NULL, 50], "pv", [1000, 1001, 1002, 1003, 1004])


def test_inner_whole_morsel() raises:
    var op = _op(JOIN_INNER)
    var m = Morsel(_probe(), 0, 7, 42)
    assert_true(op.execute(m).is_need_more_input())
    assert_equal(m.partition_id, 7, "partition_id kept")
    assert_equal(m.origin_hint, 42, "origin_hint kept")
    assert_equal(m.batch.num_columns(), 4, "probe then build columns")
    _assert(_col(m.batch, "pv"), [1000, 1002, 1004], "INNER pv")
    _assert(_col(m.batch, "bv"), [300, 200, 500], "INNER bv")


def test_inner_four_workers() raises:
    """Four operators sharing one table, each over its own 25-row morsel."""
    var keys = List[Int64]()
    var vals = List[Int64]()
    for i in range(100):
        keys.append(Int64(i))
        vals.append(Int64(i * 7))
    var idx = ArcPointer[HashJoinBuilder](
        HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(keys))
    )
    var build = ArcPointer[RecordBatch](_kv("bk", keys, "bv", vals))
    var schema = ArcPointer[Schema](_schema(JOIN_INNER))
    for w in range(4):
        var pk = List[Int64]()
        var pv = List[Int64]()
        for j in range(25):
            pk.append(Int64(w * 25 + j))
            pv.append(Int64(-j))
        var op = JoinProbeOp(
            ArcPointer[HashJoinBuilder](copy=idx),
            ArcPointer[RecordBatch](copy=build),
            "pk", "bk",
            ArcPointer[Schema](copy=schema),
        )
        var m = Morsel(_kv("pk", pk, "pv", pv), w, w, 0)
        _ = op.execute(m)
        var got_pk = _col(m.batch, "pk")
        var got_bv = _col(m.batch, "bv")
        assert_equal(len(got_pk), 25, "worker rows")
        for i in range(25):
            assert_equal(got_bv[i], got_pk[i] * 7, "worker row value")


def test_empty_and_unmatched_morsels() raises:
    var op = _op(JOIN_INNER)
    var empty = Morsel(_kv("pk", List[Int64](), "pv", List[Int64]()), 0, 0, 0)
    assert_true(op.execute(empty).is_need_more_input())
    assert_equal(empty.batch.num_rows(), 0, "empty morsel")
    var miss = Morsel(_kv("pk", [100, 200], "pv", [1, 2]), 0, 0, 0)
    _ = op.execute(miss)
    assert_equal(miss.batch.num_rows(), 0, "no match")


def test_left_keeps_a_null_key_row() raises:
    var op = _op(JOIN_LEFT)
    var m = Morsel(_probe(), 0, 0, 0)
    _ = op.execute(m)
    _assert(_col(m.batch, "pv"), [1000, 1001, 1002, 1003, 1004], "LEFT pv")
    _assert(_col(m.batch, "bv"), [300, NULL, 200, NULL, 500], "LEFT bv")


def test_semi_and_anti_with_a_null_key() raises:
    var semi = _op(JOIN_SEMI)
    var m = Morsel(_probe(), 0, 0, 0)
    _ = semi.execute(m)
    assert_equal(m.batch.num_columns(), 2, "SEMI: probe columns")
    _assert(_col(m.batch, "pv"), [1000, 1002, 1004], "SEMI")
    var anti = _op(JOIN_ANTI)
    var m2 = Morsel(_probe(), 0, 0, 0)
    _ = anti.execute(m2)
    _assert(_col(m2.batch, "pv"), [1001, 1003], "ANTI keeps the NULL key row")


def test_count_only_semi_and_anti() raises:
    var semi = _op(JOIN_SEMI, count_only=True)
    var m = Morsel(_probe(), 0, 0, 0)
    _ = semi.execute(m)
    assert_equal(m.batch.num_columns(), 0, "count only: no columns")
    assert_equal(m.batch.num_rows(), 3, "SEMI count")
    var anti = _op(JOIN_ANTI, count_only=True)
    var m2 = Morsel(_probe(), 0, 0, 0)
    _ = anti.execute(m2)
    assert_equal(m2.batch.num_rows(), 2, "ANTI count")


def test_perfect_and_radix_strategies() raises:
    """Build keys 0..5 (dense, unique): the perfect hash; the same through the
    radix table. Probe NULL's slot is 0, a build key: it matches nothing."""
    var keys: List[Int64] = [0, 1, 2, 3, 4, 5]
    for strat in [STRATEGY_PERFECT, STRATEGY_RADIX]:
        var op = _op(
            JOIN_INNER, strategy=strat, build_keys=keys,
            build=_kv("bk", keys, "bv", [0, 10, 20, 30, 40, 50]),
        )
        var m = Morsel(_kv("pk", [3, NULL, 9, 5, 0], "pv", [1, 2, 3, 4, 5]), 0, 0, 0)
        _ = op.execute(m)
        var pv = _col(m.batch, "pv")
        var bv = _col(m.batch, "bv")
        sort(pv)
        sort(bv)
        _assert(pv, [1, 4, 5], "strategy " + String(Int(strat)) + " pv")
        _assert(bv, [0, 30, 50], "strategy " + String(Int(strat)) + " bv")


def _resumable(reuse: Bool) raises:
    """Build: key 1 three times. Probe: 30,000 rows of key 1 and one NULL
    (slot 0). 90,000 matches: one full chunk, then the rest."""
    join_probe_buf_reuse_configure(reuse)
    reset_join_probe_lever_counters()
    var op = _op(
        JOIN_INNER, slot=True, build_keys=[1, 1, 1],
        build=_kv("bk", [1, 1, 1], "bv", [7, 8, 9]),
    )
    var pk = List[Int64]()
    var pv = List[Int64]()
    for i in range(30_000):
        pk.append(1)
        pv.append(Int64(i))
    pk.append(NULL)
    pv.append(-1)
    var m = Morsel(_kv("pk", pk, "pv", pv), 0, 0, 0)
    var rc = op.execute(m)
    assert_true(rc.is_have_more_output(), "a full chunk leaves more")
    assert_equal(m.batch.num_rows(), PROBE_CHUNK_SIZE, "first chunk")
    var total = m.batch.num_rows()
    var bv_sum = Int64(0)
    var first_bv = _col(m.batch, "bv")
    for v in first_bv:
        bv_sum += v
    rc = op.execute(m)
    assert_true(rc.is_need_more_input(), "drained")
    total += m.batch.num_rows()
    var second_bv = _col(m.batch, "bv")
    for v in second_bv:
        bv_sum += v
    assert_equal(total, 90_000, "every match once, the NULL row none")
    assert_equal(bv_sum, Int64(30_000 * (7 + 8 + 9)), "each build row per probe row")
    # The slot is free: the next morsel starts fresh.
    var m2 = Morsel(_kv("pk", [1], "pv", [5]), 0, 0, 0)
    assert_true(op.execute(m2).is_need_more_input(), "next morsel")
    assert_equal(m2.batch.num_rows(), 3, "next morsel rows")
    if reuse:
        assert_equal(join_probe_buf_reuse_count(), 3, "three chunks from the slot")
        assert_equal(join_probe_buf_fresh_count(), 0, "no fresh buffers")
    join_probe_buf_reuse_reset_config()


def test_resumable_inner_across_chunks() raises:
    _resumable(False)


def test_resumable_inner_with_buffer_reuse() raises:
    _resumable(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
