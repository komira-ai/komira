# =============================================================================
# test_agg_fn_acc_arity34.mojo — AggFnAcc over a 3-input and a 4-input UDF
# aggregate (update_record_batch's `_update_arity3` / `_update_arity4`)
# =============================================================================
#
# What it pins:
#   - each input column is resolved BY NAME (the batch lists them in a
#     different order from the row struct), and its value reaches the UDF in
#     the row struct's field order;
#   - a row with a NULL in ANY one input column is skipped: each column holds
#     a NULL on its own row, over a poison value that would move the answer;
#   - rows fold per gid; a gid past ensure_capacity is refused by name.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, SchemaBuilder, RecordBatch, RecordBatchBuilder
from komira_udf.agg_fn import AggFn, PodState
from komira_udf.schema_descriptor import schema_of, DT_F64
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_op_agg_state.agg_fn_acc import AggFnAcc


@fieldwise_init
struct Row3(Copyable, Movable, AutoKomiraSchema):
    var price: Float64
    var qty: Int64
    var disc: Float64


@fieldwise_init
struct Row4(Copyable, Movable, AutoKomiraSchema):
    var a: Float64
    var b: Int64
    var c: Float64
    var d: Int64


@fieldwise_init
struct Acc1(PodState):
    var total: Float64


@fieldwise_init
struct Revenue3(AggFn):
    """sum(price * qty * (1 - disc))."""
    comptime InRow = Row3
    comptime OutputSchema = schema_of["revenue", DT_F64]()
    comptime OutType = DType.float64
    comptime State = Acc1
    comptime UDF_ID = UInt32(0x7E57_0003)

    def init(self) -> Acc1:
        return Acc1(0.0)

    def update(self, mut s: Acc1, row: Row3):
        self.update_scalar(s, row.price, row.qty, row.disc)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: Acc1, *vals: *Ts):
        s.total += (
            rebind[Float64](vals[0])
            * Float64(rebind[Int64](vals[1]))
            * (1.0 - rebind[Float64](vals[2]))
        )

    def merge(self, a: Acc1, b: Acc1) -> Acc1:
        return Acc1(a.total + b.total)

    def finalize(self, s: Acc1) -> Scalar[DType.float64]:
        return s.total


@fieldwise_init
struct Dot4(AggFn):
    """sum(a * b + 100 * c * d): the factor keeps a swap of (a, b) with
    (c, d) visible."""
    comptime InRow = Row4
    comptime OutputSchema = schema_of["dot", DT_F64]()
    comptime OutType = DType.float64
    comptime State = Acc1
    comptime UDF_ID = UInt32(0x7E57_0004)

    def init(self) -> Acc1:
        return Acc1(0.0)

    def update(self, mut s: Acc1, row: Row4):
        self.update_scalar(s, row.a, row.b, row.c, row.d)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: Acc1, *vals: *Ts):
        s.total += rebind[Float64](vals[0]) * Float64(rebind[Int64](vals[1]))
        s.total += 100.0 * rebind[Float64](vals[2]) * Float64(rebind[Int64](vals[3]))

    def merge(self, a: Acc1, b: Acc1) -> Acc1:
        return Acc1(a.total + b.total)

    def finalize(self, s: Acc1) -> Scalar[DType.float64]:
        return s.total


def _f64_col(vals: List[Float64], null_row: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    if null_row >= 0:
        arr._set_null(null_row)
    return Column.from_primitive[DType.float64](arr^)


def _i64_col(vals: List[Int64], null_row: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    if null_row >= 0:
        arr._set_null(null_row)
    return Column.from_primitive[DType.int64](arr^)


def _finalized[F: AggFn](mut acc: AggFnAcc[F]) raises -> List[Float64]:
    var col = acc.finalize_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    var out = List[Float64]()
    for i in range(col.length()):
        out.append(p[i])
    return out^


def test_arity3_resolves_by_name_and_skips_any_null() raises:
    # Rows: 0 ok g0, 1 NULL price, 2 NULL qty, 3 NULL disc, 4 ok g1, 5 ok g0.
    var price: List[Float64] = [10.0, 1.0e9, 20.0, 30.0, 5.0, 2.0]
    var qty: List[Int64] = [2, 3, Int64(1) << 40, 4, 6, 5]
    var disc: List[Float64] = [0.5, 0.0, 0.0, -1.0e9, 0.25, 0.0]
    # The batch lists the columns disc, price, qty: resolution is by name.
    var sb = SchemaBuilder()
    sb.add_field(Field("disc", ArrowType.from_dtype(DType.float64), True))
    sb.add_field(Field("price", ArrowType.from_dtype(DType.float64), True))
    sb.add_field(Field("qty", ArrowType.from_dtype(DType.int64), True))
    var b = RecordBatchBuilder()
    b.add_column(_f64_col(disc, 3))
    b.add_column(_f64_col(price, 1))
    b.add_column(_i64_col(qty, 2))
    var batch = b.build(sb.build())

    var acc = AggFnAcc[Revenue3](Revenue3())
    acc.ensure_capacity(2)
    var gids: List[Int] = [0, 0, 1, 1, 1, 0]
    acc.update_record_batch(gids, batch)
    var out = _finalized(acc)
    # g0: 10*2*0.5 + 2*5*1 = 20; g1: 5*6*0.75 = 22.5.
    assert_equal(out[0], Float64(20.0))
    assert_equal(out[1], Float64(22.5))

    var bad: List[Int] = [0, 0, 0, 0, 0, 2]
    var msg = String("")
    var raised = False
    try:
        acc.update_record_batch(bad, batch)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_equal(msg, "AggFnAcc.update_record_batch: gid out of range — caller must ensure_capacity first")


def test_arity4_resolves_by_name_and_skips_any_null() raises:
    # Rows: 0 ok g0, 1 NULL a, 2 NULL b, 3 NULL c, 4 NULL d, 5 ok g1.
    var a: List[Float64] = [1.0, 1.0e9, 1.0, 1.0, 1.0, 3.0]
    var bb: List[Int64] = [2, 1, Int64(1) << 40, 1, 1, 4]
    var c: List[Float64] = [0.5, 1.0, 1.0, 1.0e9, 1.0, 2.0]
    var d: List[Int64] = [3, 1, 1, 1, Int64(1) << 40, 1]
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.from_dtype(DType.int64), True))
    sb.add_field(Field("c", ArrowType.from_dtype(DType.float64), True))
    sb.add_field(Field("b", ArrowType.from_dtype(DType.int64), True))
    sb.add_field(Field("a", ArrowType.from_dtype(DType.float64), True))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(d, 4))
    rb.add_column(_f64_col(c, 3))
    rb.add_column(_i64_col(bb, 2))
    rb.add_column(_f64_col(a, 1))
    var batch = rb.build(sb.build())

    var acc = AggFnAcc[Dot4](Dot4())
    acc.ensure_capacity(2)
    var gids: List[Int] = [0, 0, 0, 1, 1, 1]
    acc.update_record_batch(gids, batch)
    var out = _finalized(acc)
    # g0: 1*2 + 100*0.5*3 = 152; g1: 3*4 + 100*2*1 = 212.
    assert_equal(out[0], Float64(152.0))
    assert_equal(out[1], Float64(212.0))

    var bad: List[Int] = [0, 0, 0, 0, 0, -1]
    var raised = False
    try:
        acc.update_record_batch(bad, batch)
    except:
        raised = True
    assert_true(raised, "gid -1 must be refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
