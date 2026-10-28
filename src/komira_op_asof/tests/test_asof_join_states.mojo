# =============================================================================
# test_asof_join_states -- the stage ASOF breaker states: `AsofJoinBuildState`
# feeds a table from build batches, `AsofJoinProbeState` probes it per batch
# (komira_op_asof.asof_join_build_state, asof_join_probe_state)
# =============================================================================
#
# DuckDB `SELECT p.t, b.* FROM p ASOF JOIN b ON p.t <= b.t` (FORWARD, INNER):
#
#   * a NULL build temporal key is not a key: the row is not stored, so a
#     probe passes over it to the next real row (a NULL stored with slot 0 would
#     otherwise be the match of a probe of -5);
#   * a NULL probe temporal key emits nothing (the slot's value is never
#     probed);
#   * the type minimum is a key (no "empty" sentinel sits at Int64.MIN, so
#     an Int64.MIN probe finds its row);
#   * payloads keep their type and NULL: an INT64 of 2^53 + 1 comes back
#     exactly (not through a Float64) and a NULL payload comes back NULL (not 0);
#   * FLOAT64 temporal keys order by `sort_key_lt` (NaN above every number).
#   * a row whose payload read raises leaves no partial row behind, and a
#     feed after the take raises.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_expr.stage_program import BREAKER_ASOF_JOIN, BREAKER_ASOF_JOIN_BUILD

from komira_op_asof.asof_join_build import (
    AsofJoinBuildTable,
    AsofKeyBundle0,
    PayloadBlock,
    PayloadColumn,
    PayloadSlot,
    payload_slot,
)
from komira_op_asof.asof_join_build_state import AsofJoinBuildState
from komira_op_asof.asof_join_probe_state import AsofJoinProbeState


comptime I64 = DType.int64
comptime F64 = DType.float64
comptime BIG: Int64 = 9007199254740993  # 2^53 + 1

comptime Table = AsofJoinBuildTable[
    AsofKeyBundle0, I64, PayloadSlot[I64], PayloadSlot[F64]
]
comptime Build = AsofJoinBuildState[
    0, 2, AsofKeyBundle0, I64, PayloadSlot[I64], PayloadSlot[F64]
]
comptime Probe = AsofJoinProbeState[
    0, AsofKeyBundle0, I64, PayloadSlot[I64], PayloadSlot[F64]
]


def _col[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool]) raises -> Column[HeapRegion]:
    """A column of `values`; a True in `nulls` makes that row NULL (its slot
    keeps the value)."""
    var a = PrimitiveArray[dt].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _build_batch() raises -> RecordBatch:
    """Build rows, ascending t (the NULL's slot holds 0):
        t       p0       p1
        MIN     1        1.5
        NULL    2        2.5
        10      BIG      NULL
        20      4        4.5
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.INT64, True))
    sb.add_field(Field(String("p0"), ArrowType.INT64, True))
    sb.add_field(Field(String("p1"), ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(_col[I64]([Int64.MIN, 0, 10, 20], [False, True, False, False]))
    rbb.add_column(_col[I64]([1, 2, BIG, 4], [False, False, False, False]))
    rbb.add_column(_col[F64]([1.5, 2.5, 0.0, 4.5], [False, False, True, False]))
    return rbb.build(sb.build())


def _probe_batch(t: List[Int64], nulls: List[Bool]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.INT64, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(_col[I64](t, nulls))
    return rbb.build(sb.build())


def _feed_all[bo: Origin[mut=False]](mut st: Build, bv: BatchView[bo]) raises:
    for r in range(bv.n_rows()):
        st.feed_row(bv, r)


def _probe_state() raises -> Probe:
    var st = Build(
        Table(
            PayloadBlock[PayloadSlot[I64], PayloadSlot[F64]](
                payload_slot[I64](4), payload_slot[F64](4)
            )
        )
    )
    var b = _build_batch()
    _feed_all(st, batch_view_over(b))
    var owned = st.take_asof_build_table()
    return Probe(owned^.take())


def _probe[bo: Origin[mut=False]](
    mut st: Probe, bv: BatchView[bo]
) raises -> Optional[RecordBatch]:
    return st.probe_asof_batch[bo](bv)


struct RefusingPayload(PayloadColumn):
    """An INT64 payload column that refuses a negative cell: its
    `append_from_batch` raises for one, which stands in for a failed read."""

    comptime DT: DType = I64

    var values: List[Int64]

    def __init__(out self, capacity: Int):
        self.values = List[Int64](capacity=capacity)

    @staticmethod
    def make(capacity: Int) -> Self:
        return Self(capacity)

    def append_from_batch[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], col: Int, row: Int
    ) raises:
        var v = batch.col_scalar[I64](col, row)
        if v < 0:
            raise Error("RefusingPayload: negative cell")
        self.values.append(v)

    def append_f64(mut self, value: Float64):
        self.values.append(Int64(value))

    def read_slot_f64(self, slot: Int) -> Float64:
        return Float64(self.values[slot])

    def slot_is_null(self, slot: Int) -> Bool:
        return False

    def gather_column(self, slots: List[Int]) raises -> Column[HeapRegion]:
        raise Error("RefusingPayload: not gathered")

    def length(self) -> Int:
        return len(self.values)

    def truncate(mut self, n: Int):
        while len(self.values) > n:
            _ = self.values.pop()


def test_state_tags() raises:
    assert_equal(Build.state_tag(), BREAKER_ASOF_JOIN_BUILD)
    assert_equal(Probe.state_tag(), BREAKER_ASOF_JOIN)


def test_build_skips_a_null_temporal_key() raises:
    """Three of the four build rows are stored; the NULL one is not."""
    var st = Build(
        Table(
            PayloadBlock[PayloadSlot[I64], PayloadSlot[F64]](
                payload_slot[I64](4), payload_slot[F64](4)
            )
        )
    )
    var b = _build_batch()
    _feed_all(st, batch_view_over(b))
    var owned = st.take_asof_build_table()
    var t = owned^.take()
    assert_equal(t.n_rows(), 3)
    assert_equal(t.temp_at(0), Int64.MIN)
    assert_equal(t.temp_at(1), Int64(10))
    var raised = False
    try:
        _ = st.take_asof_build_table()
    except e:
        raised = True
    assert_true(raised, "a second take raises")


def test_feed_row_after_the_take_raises() raises:
    var st = Build(
        Table(
            PayloadBlock[PayloadSlot[I64], PayloadSlot[F64]](
                payload_slot[I64](4), payload_slot[F64](4)
            )
        )
    )
    var b = _build_batch()
    var bv = batch_view_over(b)
    st.feed_row(bv, 0)
    _ = st.take_asof_build_table()
    var raised = False
    try:
        st.feed_row(bv, 2)
    except e:
        raised = True
    assert_true(raised, "feed_row after the take raises")


def test_a_failed_row_read_leaves_no_partial_row() raises:
    """Rows (t, p0, p1) = (10, 1, 5), (20, 2, -1), (30, 3, 7); p1 refuses a
    negative cell. Feeding the second row raises after its temporal key and
    p0 were read; the table keeps rows one and three only, and the temporal
    column and both payload columns stay the same length."""
    comptime RTable = AsofJoinBuildTable[
        AsofKeyBundle0, I64, PayloadSlot[I64], RefusingPayload
    ]
    comptime RBuild = AsofJoinBuildState[
        0, 2, AsofKeyBundle0, I64, PayloadSlot[I64], RefusingPayload
    ]
    var st = RBuild(
        RTable(
            PayloadBlock[PayloadSlot[I64], RefusingPayload](
                payload_slot[I64](4), RefusingPayload(4)
            )
        )
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.INT64, False))
    sb.add_field(Field(String("p0"), ArrowType.INT64, False))
    sb.add_field(Field(String("p1"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(_col[I64]([10, 20, 30], [False, False, False]))
    rbb.add_column(_col[I64]([1, 2, 3], [False, False, False]))
    rbb.add_column(_col[I64]([5, -1, 7], [False, False, False]))
    var b = rbb.build(sb.build())
    var bv = batch_view_over(b)
    var failures = 0
    for r in range(3):
        try:
            st.feed_row(bv, r)
        except e:
            failures += 1
    assert_equal(failures, 1, "only the negative cell fails")
    var owned = st.take_asof_build_table()
    var t = owned^.take()
    assert_equal(t.n_rows(), 2)
    assert_equal(len(t.temporal), 2)
    assert_equal(t.payload[0].length(), 2)
    assert_equal(t.payload[1].length(), 2)
    assert_equal(t.temp_at(1), Int64(30))
    assert_equal(Int(t.payload_read_f64[0](1)), 3, "p0 of row three")
    assert_equal(Int(t.payload_read_f64[1](1)), 7, "p1 of row three")


def test_probe_rows_types_and_nulls() raises:
    """Probe t = [-5, NULL(slot 0), MIN, 15, 25]:
        -5   -> t=10 row: p0=BIG, p1 NULL (not the NULL-t row with slot 0)
        NULL -> nothing
        MIN  -> the MIN row: p0=1, p1=1.5
        15   -> t=20 row: p0=4, p1=4.5
        25   -> nothing (no build t at or after 25)
    """
    var st = _probe_state()
    var p = _probe_batch(
        [-5, 0, Int64.MIN, 15, 25], [False, True, False, False, False]
    )
    var res = _probe(st, batch_view_over(p))
    assert_true(Bool(res), "rows were emitted")
    var rb = res.take()
    assert_equal(rb.num_rows(), 3)
    assert_true(rb.column_arrow_type(0) == ArrowType.INT64)
    assert_true(rb.column_arrow_type(1) == ArrowType.INT64)
    assert_true(rb.column_arrow_type(2) == ArrowType.FLOAT64, "p1 stays FLOAT64")
    assert_false(rb.schema.field_nullable(0), "atemp is never NULL")
    assert_true(rb.schema.field_nullable(1))
    assert_true(rb.schema.field_nullable(2))

    var atemp = rb.column_as_primitive[I64](0)
    var p0 = rb.column_as_primitive[I64](1)
    var p1 = rb.column_as_primitive[F64](2)
    assert_equal(atemp.get(0), Int64(-5))
    assert_equal(p0.get(0), BIG, "INT64 payload exact past 2^53")
    assert_true(rb.column_at(2).is_null_at(0), "NULL payload stays NULL")
    assert_equal(atemp.get(1), Int64.MIN, "the type minimum is a key")
    assert_equal(p0.get(1), Int64(1))
    assert_equal(p1.get(1), Float64(1.5))
    assert_equal(atemp.get(2), Int64(15))
    assert_equal(p0.get(2), Int64(4))
    assert_equal(p1.get(2), Float64(4.5))


def test_probe_without_a_match_is_none() raises:
    var st = _probe_state()
    var p = _probe_batch([25, 0], [False, True])
    assert_false(Bool(_probe(st, batch_view_over(p))), "no row matched")


def test_float_temporal_key_orders_nan_last() raises:
    """FLOAT64 temporal keys [1.5, NaN] (ascending in `sort_key_lt` order).
    Probe 2.0 -> the NaN row (NaN is above every number); probe NaN -> the
    NaN row; probe -0.0 -> the 1.5 row."""
    comptime FBuild = AsofJoinBuildState[0, 1, AsofKeyBundle0, F64, PayloadSlot[I64]]
    comptime FProbe = AsofJoinProbeState[0, AsofKeyBundle0, F64, PayloadSlot[I64]]
    var st = FBuild(
        AsofJoinBuildTable[AsofKeyBundle0, F64, PayloadSlot[I64]](
            PayloadBlock[PayloadSlot[I64]](payload_slot[I64](2))
        )
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("p0"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_col[F64]([1.5, nan[F64]()], [False, False]))
    rbb.add_column(_col[I64]([1, 2], [False, False]))
    var b = rbb.build(sb.build())
    var bv = batch_view_over(b)
    for r in range(2):
        st.feed_row(bv, r)
    var owned = st.take_asof_build_table()
    var probe = FProbe(owned^.take())

    var psb = SchemaBuilder()
    psb.add_field(Field(String("t"), ArrowType.FLOAT64, False))
    var prb = RecordBatchBuilder.with_capacity(1)
    prb.add_column(_col[F64]([2.0, nan[F64](), -0.0], [False, False, False]))
    var pb = prb.build(psb.build())
    var res = probe.probe_asof_batch(batch_view_over(pb))
    assert_true(Bool(res))
    var rb = res.take()
    assert_equal(rb.num_rows(), 3)
    assert_true(rb.column_arrow_type(0) == ArrowType.FLOAT64)
    var p0 = rb.column_as_primitive[I64](1)
    assert_equal(p0.get(0), Int64(2), "2.0 -> NaN row")
    assert_equal(p0.get(1), Int64(2), "NaN -> NaN row")
    assert_equal(p0.get(2), Int64(1), "-0.0 -> 1.5 row")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
