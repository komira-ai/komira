# test_agg_fn_slot.mojo — AggFnSlot, a user-defined AggFn as an AggColumn.
#
# The slot calls the UDF instance's init / update_scalar / merge / finalize;
# a NULL input is skipped (as AggFnAcc skips it); inside a HashAggTable it
# groups, merges and drains like any aggregate column.

from std.testing import TestSuite, assert_almost_equal, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_udf.agg_fn import AggFn, PodState
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.schema_descriptor import DT_F64, schema_of

from komira_op_agg_stage.agg_column import AggBlock
from komira_op_agg_stage.agg_fn_slot import AggFnSlot, agg_fn_slot
from komira_op_agg_stage.hash_agg import HashAggTable
from komira_op_agg_stage.key_block import KeyTuple1, KeyTupleScalar


@fieldwise_init
struct SumF64InRow(AutoKomiraSchema, Copyable, Movable):
    var v: Float64


@fieldwise_init
struct SumF64State(PodState):
    var total: Float64


@fieldwise_init
struct SumF64(AggFn):
    comptime InRow = SumF64InRow
    comptime OutType = DType.float64
    comptime State = SumF64State
    comptime OutputSchema = schema_of["sum_v", DT_F64]()
    comptime UDF_ID = UInt32(9201)

    def init(self) -> SumF64State:
        return SumF64State(0.0)

    def update(self, mut s: SumF64State, row: SumF64InRow):
        self.update_scalar(s, row.v)

    def update_scalar[
        *Ts: Copyable & Movable
    ](self, mut s: SumF64State, *vals: *Ts):
        s.total += rebind[Float64](vals[0])

    def merge(self, a: SumF64State, b: SumF64State) -> SumF64State:
        return SumF64State(a.total + b.total)

    def finalize(self, s: SumF64State) -> Scalar[DType.float64]:
        return s.total


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


def _fixture(null_row: Int = -1) raises -> RecordBatch:
    """k = [1, 1, 2, 2]; v = [1.5, 2.5, 3.5, 4.5], row `null_row` NULL with
    1000.0 under it."""
    var k = PrimitiveArray[DType.int64].from_list(_li(1, 1, 2, 2))
    var v = PrimitiveArray[DType.float64].allocate_nullable(4)
    var vals = _lf(1.5, 2.5, 3.5, 4.5)
    for i in range(4):
        v.set(i, vals[i] if i != null_row else Float64(1000.0))
    if null_row >= 0:
        v._set_null(null_row)
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.float64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    return rb.build(sb.build())


def test_factory_round_trip() raises:
    var slot = agg_fn_slot[SumF64, 1](SumF64())
    assert_almost_equal(slot.udf.init().total, Float64(0.0))


def test_update_row_delegates_to_update_scalar() raises:
    var rb = _fixture()
    var view = BatchView(rb)
    var slot = agg_fn_slot[SumF64, 1](SumF64())
    slot.push_identity_group()
    for r in range(4):
        slot.update_row(0, view, r)
    assert_almost_equal(slot.finalize_f64(0), Float64(12.0))


def test_combine_into_bridges_merge() raises:
    var rb = _fixture()
    var view = BatchView(rb)
    var dst = agg_fn_slot[SumF64, 1](SumF64())
    var src = agg_fn_slot[SumF64, 1](SumF64())
    dst.push_identity_group()
    src.push_identity_group()
    dst.update_row(0, view, 0)
    dst.update_row(0, view, 1)
    src.update_row(0, view, 2)
    src.update_row(0, view, 3)
    assert_almost_equal(dst.finalize_f64(0), Float64(4.0))
    assert_almost_equal(src.finalize_f64(0), Float64(8.0))
    dst.combine_into(0, src^)
    assert_almost_equal(dst.finalize_f64(0), Float64(12.0))


def test_finalize_of_an_unfolded_group_is_init() raises:
    var slot = agg_fn_slot[SumF64, 1](SumF64())
    for _ in range(16):
        slot.push_identity_group()
    assert_almost_equal(slot.finalize_f64(0), Float64(0.0))
    assert_almost_equal(slot.finalize_f64(15), Float64(0.0))


def test_reset_drops_every_group() raises:
    var rb = _fixture()
    var view = BatchView(rb)
    var slot = agg_fn_slot[SumF64, 1](SumF64())
    slot.push_identity_group()
    slot.update_row(0, view, 0)
    slot.update_row(0, view, 1)
    assert_almost_equal(slot.finalize_f64(0), Float64(4.0))
    slot.reset()
    slot.push_identity_group()
    assert_almost_equal(slot.finalize_f64(0), Float64(0.0))


def test_a_null_input_is_skipped() raises:
    # Row 1 is NULL with 1000.0 under it: the sum is 1.5 + 3.5 + 4.5.
    var rb = _fixture(1)
    var view = BatchView(rb)
    var slot = agg_fn_slot[SumF64, 1](SumF64())
    slot.push_identity_group()
    for r in range(4):
        slot.update_row(0, view, r)
    assert_almost_equal(slot.finalize_f64(0), Float64(9.5))


def test_grouped_in_a_table_with_a_merge() raises:
    comptime S = AggFnSlot[SumF64, 1]
    comptime T = HashAggTable[KeyTuple1[DType.int64, 0], S]
    var rb = _fixture(2)
    var view = BatchView(rb)
    var a = T(AggBlock[S](agg_fn_slot[SumF64, 1](SumF64())))
    var b = T(AggBlock[S](agg_fn_slot[SumF64, 1](SumF64())))
    a.feed_row(view, 0)
    a.feed_row(view, 2)
    b.feed_row(view, 1)
    b.feed_row(view, 3)
    a.combine(b^)
    var res = a.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 2, "two groups")
    var col = out.column_at(1).as_primitive[DType.float64]()
    assert_almost_equal(col.get(0), Float64(4.0), "key 1: 1.5 + 2.5")
    assert_almost_equal(col.get(1), Float64(4.5), "key 2: NULL skipped")


def test_ungrouped_over_no_rows_answers_init() raises:
    comptime S = AggFnSlot[SumF64, 1]
    var t = HashAggTable[KeyTupleScalar, S](
        AggBlock[S](agg_fn_slot[SumF64, 1](SumF64()))
    )
    var res = t.drain_to_record_batch()
    ref out = res.value()
    assert_equal(out.num_rows(), 1, "one row")
    assert_almost_equal(
        out.column_at(0).as_primitive[DType.float64]().get(0), Float64(0.0)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
