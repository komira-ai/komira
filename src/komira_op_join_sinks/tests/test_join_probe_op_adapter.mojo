# `JoinProbeOpAdapter` forwards to the `JoinProbeOp` it wraps, every argument
# and every result:
#   * INNER, LEFT, SEMI and ANTI with a NULL probe key whose slot holds a real
#     build key: the rows are the ones written here (a NULL matches nothing,
#     as in DuckDB: LEFT keeps the row with a NULL build side, SEMI drops it,
#     ANTI keeps it), and the same rows a bare `JoinProbeOp` gives. A
#     constructor that dropped the join type would answer INNER for all four.
#   * SEMI in count-only form: one count-only batch with the count.
#   * the resumable INNER arm with a worker slot: 90,000 matches leave as
#     HAVE_MORE_OUTPUT with 65,536 rows, then NEED_MORE_INPUT with the rest.
#     An adapter that turned HAVE_MORE_OUTPUT into NEED_MORE_INPUT would lose
#     the second chunk.
#   * the metrics are the wrapped operator's, not an empty snapshot.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_ANTI, JOIN_INNER, JOIN_LEFT, JOIN_SEMI

from komira_op_join_build.join import HashJoinBuilder, PROBE_CHUNK_SIZE
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import build_shared_probe_state

from komira_op_join_sinks.join_probe_op_adapter import JoinProbeOpAdapter


comptime NULL: Int64 = -999
"""An INT64 entry written as NULL (its slot holds 0)."""


def _i64(vals: List[Int64]) -> Column[HeapRegion]:
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


def _schema(join_type: UInt8) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, True))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    if join_type == JOIN_INNER or join_type == JOIN_LEFT:
        sb.add_field(Field("bk", ArrowType.INT64, True))
        sb.add_field(Field("bv", ArrowType.INT64, True))
    return sb.build()


def _build_keys() -> List[Int64]:
    return [10, 20, 30, 40, 50, 0]


def _build() raises -> RecordBatch:
    return _kv("bk", _build_keys(), "bv", [100, 200, 300, 400, 500, 0])


def _probe() raises -> RecordBatch:
    """pk 30, 99, 20, NULL (slot 0, which the build has), 50."""
    return _kv("pk", [30, 99, 20, NULL, 50], "pv", [1000, 1001, 1002, 1003, 1004])


def _adapter(join_type: UInt8, count_only: Bool = False) raises -> JoinProbeOpAdapter:
    return JoinProbeOpAdapter(
        ArcPointer[HashJoinBuilder](
            HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(_build_keys()))
        ),
        ArcPointer[RecordBatch](_build()),
        "pk",
        "bk",
        ArcPointer[Schema](_schema(join_type)),
        join_type,
        count_only=count_only,
    )


def _bare(join_type: UInt8) raises -> JoinProbeOp:
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](
            HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(_build_keys()))
        ),
        ArcPointer[RecordBatch](_build()),
        "pk",
        "bk",
        ArcPointer[Schema](_schema(join_type)),
        join_type,
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


def _check(join_type: UInt8, want_pv: List[Int64], want_bv: List[Int64], what: String) raises:
    var a = _adapter(join_type)
    var m = Morsel(_probe(), 0, 7, 42)
    assert_true(a.execute(m).is_need_more_input(), what + ": one call")
    assert_equal(m.partition_id, 7, what + ": partition_id kept")
    assert_equal(m.origin_hint, 42, what + ": origin_hint kept")
    _assert(_col(m.batch, "pv"), want_pv, what + " pv")
    if len(want_bv) > 0:
        _assert(_col(m.batch, "bv"), want_bv, what + " bv")
    else:
        assert_equal(m.batch.num_columns(), 2, what + ": probe columns only")
    # The bare operator over the same input: the same rows.
    var o = _bare(join_type)
    var m2 = Morsel(_probe(), 0, 7, 42)
    _ = o.execute(m2)
    _assert(_col(m.batch, "pv"), _col(m2.batch, "pv"), what + " vs bare")


def test_inner() raises:
    _check(JOIN_INNER, [1000, 1002, 1004], [300, 200, 500], "INNER")


def test_left_keeps_null_key_row() raises:
    _check(
        JOIN_LEFT,
        [1000, 1001, 1002, 1003, 1004],
        [300, NULL, 200, NULL, 500],
        "LEFT",
    )


def test_semi_drops_null_key_row() raises:
    _check(JOIN_SEMI, [1000, 1002, 1004], List[Int64](), "SEMI")


def test_anti_keeps_null_key_row() raises:
    _check(JOIN_ANTI, [1001, 1003], List[Int64](), "ANTI")


def test_semi_count_only() raises:
    var a = _adapter(JOIN_SEMI, count_only=True)
    var m = Morsel(_probe(), 0, 0, 0)
    assert_true(a.execute(m).is_need_more_input())
    assert_equal(m.batch.num_columns(), 0, "count-only batch")
    assert_equal(m.batch.num_rows(), 3, "three probe rows kept")


def test_resumable_inner_forwards_have_more_output() raises:
    """Build: key 1 three times. Probe: 30,000 rows of key 1. 90,000 matches:
    one full chunk (HAVE_MORE_OUTPUT), then the rest (NEED_MORE_INPUT)."""
    var a = JoinProbeOpAdapter(
        ArcPointer[HashJoinBuilder](
            HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list([1, 1, 1]))
        ),
        ArcPointer[RecordBatch](_kv("bk", [1, 1, 1], "bv", [7, 8, 9])),
        "pk",
        "bk",
        ArcPointer[Schema](_schema(JOIN_INNER)),
        JOIN_INNER,
        shared=build_shared_probe_state(1),
        local_id=0,
    )
    var pk = List[Int64]()
    var pv = List[Int64]()
    for i in range(30_000):
        pk.append(1)
        pv.append(Int64(i))
    var m = Morsel(_kv("pk", pk, "pv", pv), 0, 0, 0)
    var rc = a.execute(m)
    assert_true(rc.is_have_more_output(), "a full chunk leaves more")
    assert_equal(m.batch.num_rows(), PROBE_CHUNK_SIZE, "first chunk")
    var total = m.batch.num_rows()
    rc = a.execute(m)
    assert_true(rc.is_need_more_input(), "drained")
    total += m.batch.num_rows()
    assert_equal(total, 90_000, "every match once")
    # The wrapped operator registers its metrics up front; the default
    # (operator-less) snapshot is empty.
    assert_true(a.metrics_snapshot().count() > 0, "the wrapped operator's metrics")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
