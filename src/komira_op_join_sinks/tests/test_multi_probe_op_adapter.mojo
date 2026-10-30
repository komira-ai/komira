# The join probe cascades, `MultiProbeOpAdapter` (single-key `JoinProbeOp`s)
# and `MultiKeyProbeCascadeAdapter` (composite-key `MultiKeyJoinProbeOp`s):
#   * one probe: the probe's own rows, partition_id and origin_hint kept;
#   * two INNER probes, A then B, where B joins on a column A added: every
#     row carries both builds' values, checked row by row (an adapter that ran
#     only the first probe, or ran both on the input, gets different columns);
#   * a first probe with no match: zero rows and NEED_MORE_INPUT;
#   * a two-probe cascade whose first probe returns HAVE_MORE_OUTPUT (a
#     resumable INNER with 90,000 matches) is REFUSED with an error. Passing
#     it on as NEED_MORE_INPUT, as the adapter once did, keeps the first
#     65,536 rows and loses the rest of that probe's output;
#   * an empty cascade is refused at construction;
#   * the composite cascade: a 2-key INNER join with a NULL key on each side
#     (a NULL matches nothing), then a FLOAT64-key join whose keys follow the
#     float model (NaN equals NaN, -0.0 equals +0.0, as in DuckDB).

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER

from komira_op_join_build.join import HashJoinBuilder, PROBE_CHUNK_SIZE
from komira_op_join_probe.join_key_extract import extract_join_key_columns_serial
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    ColumnarProbeSharedState,
    build_shared_probe_state,
)
from komira_op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp

from komira_op_join_sinks.multi_probe_op_adapter import (
    MultiKeyProbeCascadeAdapter,
    MultiProbeOpAdapter,
)


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


def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(vals))


def _kv(k: String, keys: List[Int64], v: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(k, ArrowType.INT64, True))
    sb.add_field(Field(v, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(keys))
    rb.add_column(_i64(vals))
    return rb.build(sb.build())


def _schema(names: List[String]) raises -> Schema:
    var sb = SchemaBuilder()
    for n in names:
        sb.add_field(Field(n, ArrowType.INT64, True))
    return sb.build()


def _probe_op(
    build_keys: List[Int64],
    build_vals: List[Int64],
    bk: String,
    bv: String,
    pk: String,
    out_names: List[String],
    slot: Bool = False,
) raises -> JoinProbeOp:
    var shared = Optional[ArcPointer[ColumnarProbeSharedState]](None)
    if slot:
        shared = build_shared_probe_state(1)
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](
            HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(build_keys))
        ),
        ArcPointer[RecordBatch](_kv(bk, build_keys, bv, build_vals)),
        pk,
        bk,
        ArcPointer[Schema](_schema(out_names)),
        JOIN_INNER,
        shared=shared^,
        local_id=0 if slot else -1,
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


def test_one_probe_is_the_probe() raises:
    var inner = Slab[JoinProbeOp].create(1)
    inner.append(
        _probe_op([10, 20, 30, 40, 50], [100, 200, 300, 400, 500], "bk", "bv", "pk",
                  ["pk", "pv", "bk", "bv"])
    )
    var a = MultiProbeOpAdapter(inner^)
    var m = Morsel(_kv("pk", [30, 99, 20, 77, 50], "pv", [0, 1, 2, 3, 4]), 0, 7, 42)
    assert_true(a.execute(m).is_need_more_input())
    assert_equal(m.partition_id, 7, "partition_id kept")
    assert_equal(m.origin_hint, 42, "origin_hint kept")
    _assert(_col(m.batch, "pv"), [0, 2, 4], "pv")
    _assert(_col(m.batch, "bv"), [300, 200, 500], "bv")
    assert_true(a.metrics_snapshot().count() > 0, "the probe's metrics")


def test_two_probes_cascade() raises:
    """A: pk -> av. B joins on av -> bv. Probe key 3 has no A row."""
    var inner = Slab[JoinProbeOp].create(2)
    inner.append(
        _probe_op([1, 2, 4], [100, 200, 400], "ak", "av", "pk", ["pk", "pv", "ak", "av"])
    )
    inner.append(
        _probe_op([400, 100, 200], [4000, 1000, 2000], "bk", "bv", "av",
                  ["pk", "pv", "ak", "av", "bk", "bv"])
    )
    var a = MultiProbeOpAdapter(inner^)
    var m = Morsel(_kv("pk", [1, 2, 3, 4], "pv", [10, 20, 30, 40]), 0, 0, 0)
    assert_true(a.execute(m).is_need_more_input())
    assert_equal(m.batch.num_columns(), 6, "both builds' columns")
    _assert(_col(m.batch, "pv"), [10, 20, 40], "pv")
    _assert(_col(m.batch, "av"), [100, 200, 400], "av")
    _assert(_col(m.batch, "bv"), [1000, 2000, 4000], "bv")


def test_first_probe_empty_ends_the_chain() raises:
    var inner = Slab[JoinProbeOp].create(2)
    inner.append(
        _probe_op([1, 2, 3], [100, 200, 300], "ak", "av", "pk", ["pk", "pv", "ak", "av"])
    )
    inner.append(
        _probe_op([100, 200, 300], [1, 2, 3], "bk", "bv", "av",
                  ["pk", "pv", "ak", "av", "bk", "bv"])
    )
    var a = MultiProbeOpAdapter(inner^)
    var m = Morsel(_kv("pk", [99, 88, 77], "pv", [1, 2, 3]), 0, 0, 0)
    assert_true(a.execute(m).is_need_more_input())
    assert_equal(m.batch.num_rows(), 0, "no rows")


def test_partial_output_in_a_cascade_is_refused() raises:
    """Probe 0 is a resumable INNER: key 1 three times against 30,000 probe
    rows of key 1 is 90,000 matches, more than one 65,536-row chunk."""
    var inner = Slab[JoinProbeOp].create(2)
    inner.append(
        _probe_op([1, 1, 1], [7, 8, 9], "ak", "av", "pk", ["pk", "pv", "ak", "av"], slot=True)
    )
    inner.append(
        _probe_op([7, 8, 9], [70, 80, 90], "bk", "bv", "av",
                  ["pk", "pv", "ak", "av", "bk", "bv"])
    )
    var a = MultiProbeOpAdapter(inner^)
    var pk = List[Int64]()
    var pv = List[Int64]()
    for i in range(30_000):
        pk.append(1)
        pv.append(Int64(i))
    var m = Morsel(_kv("pk", pk, "pv", pv), 0, 0, 0)
    assert_true(PROBE_CHUNK_SIZE < 90_000, "fixture: more than one chunk")
    with assert_raises(contains="HAVE_MORE_OUTPUT"):
        _ = a.execute(m)


def test_empty_cascade_is_refused() raises:
    with assert_raises(contains="at least one probe"):
        _ = MultiProbeOpAdapter(Slab[JoinProbeOp].create(0))
    with assert_raises(contains="at least one probe"):
        _ = MultiKeyProbeCascadeAdapter(Slab[MultiKeyJoinProbeOp].create(0))


# ---------------------------------------------------------------------------
# The composite cascade
# ---------------------------------------------------------------------------


def _input() raises -> RecordBatch:
    """a, b (INT64), x (FLOAT64), id. Row 3 has a NULL `a`."""
    var nan = Float64(0.0) / Float64(0.0)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64([1, 1, 2, NULL, 1]))
    rb.add_column(_i64([1, 2, 2, 1, 1]))
    rb.add_column(_f64([nan, Float64(-1.0) * Float64(0.0), 5.0, nan, 7.0]))
    rb.add_column(_i64([0, 1, 2, 3, 4]))
    return rb.build(sb.build())


def _build_a() raises -> RecordBatch:
    """(a2, b2) -> av. The (NULL, 1) row matches nothing."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a2", ArrowType.INT64, True))
    sb.add_field(Field("b2", ArrowType.INT64, False))
    sb.add_field(Field("av", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64([1, 1, 3, NULL]))
    rb.add_column(_i64([1, 2, 3, 1]))
    rb.add_column(_i64([10, 20, 30, 40]))
    return rb.build(sb.build())


def _build_b() raises -> RecordBatch:
    """x2 -> xv: NaN, +0.0 and 5.0 (no 7.0)."""
    var nan = Float64(0.0) / Float64(0.0)
    var sb = SchemaBuilder()
    sb.add_field(Field("x2", ArrowType.FLOAT64, False))
    sb.add_field(Field("xv", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_f64([nan, 0.0, 5.0]))
    rb.add_column(_i64([100, 200, 300]))
    return rb.build(sb.build())


def _concat_schema(imm left: Schema, imm right: Schema) raises -> Schema:
    var sb = SchemaBuilder()
    for c in range(left.num_columns()):
        sb.add_field(Field(left.field_name(c), left.field_arrow_type(c), True))
    for c in range(right.num_columns()):
        sb.add_field(Field(right.field_name(c), right.field_arrow_type(c), True))
    return sb.build()


def _mk_op(
    var build: RecordBatch,
    probe_keys: List[String],
    build_keys: List[String],
    var out: Schema,
) raises -> MultiKeyJoinProbeOp:
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, build_keys)
    )
    return MultiKeyJoinProbeOp(
        ArcPointer[MultiKeyHashJoinBuilder](builder^),
        ArcPointer[RecordBatch](build^),
        probe_keys.copy(),
        build_keys.copy(),
        ArcPointer[Schema](out^),
        JOIN_INNER,
    )


def test_composite_cascade_null_and_float_keys() raises:
    var in_schema = _input().schema.copy()
    var s0 = _concat_schema(in_schema, _build_a().schema)
    var s1 = _concat_schema(s0, _build_b().schema)
    var inner = Slab[MultiKeyJoinProbeOp].create(2)
    inner.append(_mk_op(_build_a(), ["a", "b"], ["a2", "b2"], s0^))
    inner.append(_mk_op(_build_b(), ["x"], ["x2"], s1^))
    var a = MultiKeyProbeCascadeAdapter(inner^)
    var m = Morsel(_input(), 0, 3, 9)
    assert_true(a.execute(m).is_need_more_input())
    assert_equal(m.partition_id, 3, "partition_id kept")
    # Probe A: id 0 (1,1) -> 10, id 1 (1,2) -> 20, id 4 (1,1) -> 10; id 2
    # (2,2) has no row; id 3's NULL `a` matches nothing (not the (NULL,1) row).
    # Probe B: id 0's NaN -> 100, id 1's -0.0 -> +0.0's 200, id 4's 7.0 none.
    var ids = _col(m.batch, "id")
    var av = _col(m.batch, "av")
    var xv = _col(m.batch, "xv")
    assert_equal(len(ids), 2, "two rows survive both joins")
    for r in range(len(ids)):
        if ids[r] == 0:
            assert_equal(av[r], 10, "id 0 av")
            assert_equal(xv[r], 100, "id 0: NaN equals NaN")
        elif ids[r] == 1:
            assert_equal(av[r], 20, "id 1 av")
            assert_equal(xv[r], 200, "id 1: -0.0 equals +0.0")
        else:
            raise Error("unexpected row id " + String(ids[r]))
    assert_true(ids[0] != ids[1], "each row once")


def test_composite_one_probe_is_the_probe() raises:
    var in_schema = _input().schema.copy()
    var s0 = _concat_schema(in_schema, _build_a().schema)
    var inner = Slab[MultiKeyJoinProbeOp].create(1)
    inner.append(_mk_op(_build_a(), ["a", "b"], ["a2", "b2"], s0^))
    var a = MultiKeyProbeCascadeAdapter(inner^)
    var m = Morsel(_input(), 0, 0, 0)
    assert_true(a.execute(m).is_need_more_input())
    var ids = _col(m.batch, "id")
    assert_equal(len(ids), 3, "ids 0, 1 and 4 match A")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
