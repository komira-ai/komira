# =============================================================================
# Tests for the small value types UDF conformers carry: `Purity`,
# `FunctionStability` / `NullHandling` / `UdfDescriptor`, `StatefulContract` /
# `KeyList` / `KeyEntry`, and `WindowFrameSpec`'s named constructors; plus
# conformers of the declaration-only traits (`AggFn`, `ExprScalarFn`,
# `ScalarUdf`, `AutoKomiraSchema`) driven through generic functions, so the
# trait defaults (`AggFn.InputSchema`) are checked where a user meets them.
#
# Oracles: the docstrings (PURE = 0 / STATELESS = 1 / STATEFUL = 2, pushable
# means "everything except STATEFUL", the descriptor defaults) and SQL frame
# syntax: `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is a running
# frame, `... AND UNBOUNDED FOLLOWING` the whole partition, and the RANGE
# forms differ from the ROWS forms only in their units.
#
# What each test proves (and the defect it catches):
#   - test_purity: tag per level from both constructors, ==/!= over all nine
#     pairs, is_pure only for PURE, is_pushable for all but STATEFUL. Catches
#     a swapped constant, `!=` written as `==`, is_pushable keyed on PURE.
#   - test_udf_descriptor_defaults: the minimal descriptor's documented
#     defaults (IMMUTABLE, MANUAL, no ordering, no column restriction) and the
#     stability / null-handling tags from both constructors.
#   - test_stateful_contract: the four contract tags, is_stateless only for
#     the stateless contract, KeyList's count and its ", " join for 0, 1 and 3
#     keys, and empty default keys.
#   - test_window_frame_spec_*: each constructor's five fields, one at a time,
#     against the SQL frame it names; `rows`/`range` keep their arguments in
#     place (a start/end swap is caught by distinct offsets 2 and 5).
#   - test_trait_conformers: an `AggFn` folded through its lifecycle by a
#     generic driver (init/update/merge/finalize, merge order-independent),
#     its InputSchema derived from InRow; an `ExprScalarFn` kernel at W = 1
#     and W = 8; a `ScalarUdf` passing a batch through.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
)

from komira_udf.agg_fn import AggFn, PodState
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.expr_scalar_fn import ExprScalarFn
from komira_udf.purity import Purity
from komira_udf.scalar_udf import ScalarUdf
from komira_udf.schema_descriptor import DT_F64, schema_of
from komira_udf.stateful_contract import (
    CONTRACT_MERGEABLE,
    CONTRACT_PARTITION_LOCAL,
    CONTRACT_SERIAL_ORDERED,
    CONTRACT_STATELESS,
    KeyEntry,
    KeyList,
    StatefulContract,
)
from komira_udf.udf_descriptor import (
    FunctionStability,
    NullHandling,
    UdfDescriptor,
)
from komira_udf.window_frame_spec import WindowFrameSpec


# -----------------------------------------------------------------------------
# Purity
# -----------------------------------------------------------------------------


def test_purity() raises:
    var levels: List[Purity] = [Purity.PURE, Purity.STATELESS, Purity.STATEFUL]
    for i in range(3):
        assert_equal(Int(levels[i].tag()), i)
        assert_equal(Int(Purity(UInt8(i)).tag()), i)
        assert_equal(Int(Purity(i).tag()), i)
        for j in range(3):
            assert_equal(levels[i] == levels[j], i == j)
            assert_equal(levels[i] != levels[j], i != j)
    assert_true(Purity.PURE.is_pure())
    assert_false(Purity.STATELESS.is_pure())
    assert_false(Purity.STATEFUL.is_pure())
    assert_true(Purity.PURE.is_pushable())
    assert_true(Purity.STATELESS.is_pushable())
    assert_false(Purity.STATEFUL.is_pushable())


# -----------------------------------------------------------------------------
# UdfDescriptor and its enums
# -----------------------------------------------------------------------------


def test_udf_descriptor_defaults() raises:
    var d = UdfDescriptor("my_udf")
    assert_equal(d.name, "my_udf")
    assert_equal(Int(d.stability._tag), Int(FunctionStability.IMMUTABLE._tag))
    assert_equal(Int(d.null_handling._tag), Int(NullHandling.MANUAL._tag))
    assert_false(d.preserves_ordering)
    assert_false(Bool(d.input_columns))

    assert_equal(Int(FunctionStability.IMMUTABLE._tag), 0)
    assert_equal(Int(FunctionStability.STABLE._tag), 1)
    assert_equal(Int(FunctionStability.VOLATILE._tag), 2)
    assert_equal(Int(FunctionStability(UInt8(2))._tag), 2)
    assert_equal(Int(FunctionStability(1)._tag), 1)
    assert_equal(Int(NullHandling.MANUAL._tag), 0)
    assert_equal(Int(NullHandling.PROPAGATE._tag), 1)
    assert_equal(Int(NullHandling.SKIP_NULL_FAST_PATH._tag), 2)
    assert_equal(Int(NullHandling(UInt8(1))._tag), 1)
    assert_equal(Int(NullHandling(2)._tag), 2)

    # The fields are plain values a registry may set.
    var cols: List[Int] = [3, 1]
    d.input_columns = cols^
    d.preserves_ordering = True
    assert_equal(len(d.input_columns.value()), 2)
    var copy = d.copy()
    assert_equal(copy.input_columns.value()[0], 3)
    assert_true(copy.preserves_ordering)


# -----------------------------------------------------------------------------
# StatefulContract / KeyList
# -----------------------------------------------------------------------------


def test_stateful_contract() raises:
    assert_equal(Int(CONTRACT_STATELESS), 0)
    assert_equal(Int(CONTRACT_SERIAL_ORDERED), 1)
    assert_equal(Int(CONTRACT_MERGEABLE), 2)
    assert_equal(Int(CONTRACT_PARTITION_LOCAL), 3)
    assert_equal(StatefulContract.stateless.tag, CONTRACT_STATELESS)
    assert_equal(StatefulContract.serial_ordered.tag, CONTRACT_SERIAL_ORDERED)
    assert_equal(StatefulContract.mergeable.tag, CONTRACT_MERGEABLE)
    assert_true(StatefulContract.stateless.is_stateless())
    assert_false(StatefulContract.serial_ordered.is_stateless())
    assert_false(StatefulContract.mergeable.is_stateless())
    assert_false(StatefulContract(tag=CONTRACT_PARTITION_LOCAL).is_stateless())
    # Keyless contracts carry no keys.
    assert_equal(materialize[StatefulContract.partition_keys]().num_keys(), 0)
    assert_equal(materialize[StatefulContract.order_keys]().num_keys(), 0)


def test_key_list() raises:
    var none = KeyList()
    assert_equal(none.num_keys(), 0)
    assert_equal(none.names_joined(), "")
    var one = KeyList([KeyEntry("user_id", True)])
    assert_equal(one.num_keys(), 1)
    assert_equal(one.names_joined(), "user_id")
    var three = KeyList([
        KeyEntry("a", True), KeyEntry("b", False), KeyEntry("c", True)
    ])
    assert_equal(three.num_keys(), 3)
    assert_equal(three.names_joined(), "a, b, c")
    assert_false(three.keys[1].ascending)
    assert_true(three.keys[2].ascending)


# -----------------------------------------------------------------------------
# WindowFrameSpec
# -----------------------------------------------------------------------------


def _frame(
    f: WindowFrameSpec, units: UInt8, st: UInt8, so: Int, et: UInt8, eo: Int
) raises:
    assert_equal(f.units, units, "units")
    assert_equal(f.start_tag, st, "start_tag")
    assert_equal(f.start_offset, so, "start_offset")
    assert_equal(f.end_tag, et, "end_tag")
    assert_equal(f.end_offset, eo, "end_offset")


def test_window_frame_spec_rows() raises:
    _frame(
        WindowFrameSpec.rows(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_FOLLOWING, 5),
        FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_FOLLOWING, 5,
    )
    _frame(
        WindowFrameSpec.rows_between_preceding_and_current(3),
        FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 3, FRAME_BOUND_CURRENT_ROW, 0,
    )
    _frame(
        WindowFrameSpec.rows_running(),
        FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
        FRAME_BOUND_CURRENT_ROW, 0,
    )
    _frame(
        WindowFrameSpec.rows_full_partition(),
        FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
        FRAME_BOUND_UNBOUNDED_FOLLOWING, 0,
    )


def test_window_frame_spec_range() raises:
    _frame(
        WindowFrameSpec.range(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_FOLLOWING, 5),
        FRAME_UNITS_RANGE, FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_FOLLOWING, 5,
    )
    _frame(
        WindowFrameSpec.range_between_preceding_and_current(7),
        FRAME_UNITS_RANGE, FRAME_BOUND_PRECEDING, 7, FRAME_BOUND_CURRENT_ROW, 0,
    )
    _frame(
        WindowFrameSpec.range_running(),
        FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
        FRAME_BOUND_CURRENT_ROW, 0,
    )
    _frame(
        WindowFrameSpec.range_full_partition(),
        FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
        FRAME_BOUND_UNBOUNDED_FOLLOWING, 0,
    )
    assert_true(FRAME_UNITS_ROWS != FRAME_UNITS_RANGE)


# -----------------------------------------------------------------------------
# Declaration-only traits, through conformers and generic drivers
# -----------------------------------------------------------------------------


@fieldwise_init
struct _AmountRow(AutoKomiraSchema, Copyable, Movable):
    var amount: Float64


@fieldwise_init
struct _SumCount(PodState, Copyable, Movable):
    var sum: Float64
    var count: Int64


@fieldwise_init
struct _Mean(AggFn):
    """AVG as an AggFn: (sum, count) state; finalize divides."""

    comptime InRow = _AmountRow
    comptime OutputSchema = schema_of["mean", DT_F64]()
    comptime OutType = DType.float64
    comptime State = _SumCount
    comptime UDF_ID = UInt32(7_100)

    def init(self) -> _SumCount:
        return _SumCount(0.0, 0)

    def update(self, mut s: _SumCount, row: _AmountRow):
        self.update_scalar(s, row.amount)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: _SumCount, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])
        s.count += 1

    def merge(self, a: _SumCount, b: _SumCount) -> _SumCount:
        return _SumCount(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: _SumCount) -> Float64:
        return s.sum / Float64(s.count)


def _fold[F: AggFn](f: F, rows: List[F.InRow]) -> F.State:
    """One worker's partial state over `rows`, through the trait only."""
    var s = f.init()
    for r in rows:
        f.update(s, r)
    return s^


def test_trait_conformers() raises:
    # AggFn: the default InputSchema is derived from InRow's one field.
    var schema = materialize[_Mean.InputSchema]()
    assert_equal(schema.num_cols(), 1)
    assert_equal(schema.cols[0].name, "amount")
    assert_equal(schema.cols[0].dtype, DT_F64)
    var f = _Mean()
    var left: List[_AmountRow] = [_AmountRow(1.0), _AmountRow(2.0)]
    var right: List[_AmountRow] = [_AmountRow(6.0)]
    var pl = _fold(f, left)
    var pr = _fold(f, right)
    var ab = f.merge(pl, pr)
    var ba = f.merge(pr, pl)
    assert_equal(f.finalize(ab), 3.0)
    assert_equal(f.finalize(ba), 3.0)
    assert_equal(ab.count, 3)

    # ExprScalarFn: lane-wise, so W = 1 and W = 8 agree lane for lane.
    var x8 = SIMD[DType.int64, 8](-3, -2, -1, 0, 1, 2, 3, 4)
    var y8 = _Square.eval_chunk[8](x8)
    for k in range(8):
        assert_equal(y8[k], x8[k] * x8[k])
        var y1 = _Square.eval_chunk[1](SIMD[DType.int64, 1](x8[k]))
        assert_equal(y1[0], y8[k])
    assert_true(_Square.T_IN == DType.int64)

    # ScalarUdf: N rows in, N rows out.
    var u = _PassThrough()
    var b = _i64_batch(5)
    var out = _drive_scalar_udf(u, b)
    assert_equal(out.num_rows(), 5)
    assert_equal(u.name(), "pass_through")
    assert_equal(u.output_schema().num_columns(), 1)


@fieldwise_init
struct _Square(ExprScalarFn):
    comptime UDF_ID: UInt32 = 7_101
    comptime T_IN: DType = DType.int64
    comptime T_OUT: DType = DType.int64

    @staticmethod
    def eval_chunk[W: Int](input: SIMD[DType.int64, W]) -> SIMD[DType.int64, W]:
        return input * input


def _i64_batch(n: Int) raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("v", DType.int64, True))
    return RecordBatch.from_typed_columns_1(schema^, Column.from_primitive[DType.int64](arr^))


@fieldwise_init
struct _PassThrough(ScalarUdf):
    def name(self) -> String:
        return "pass_through"

    def output_schema(self) -> Schema:
        return Schema.from_fields_1(Field("v", DType.int64, True))

    def evaluate(mut self, batch: RecordBatch) raises -> RecordBatch:
        return _i64_batch(batch.num_rows())


def _drive_scalar_udf[U: ScalarUdf](mut u: U, batch: RecordBatch) raises -> RecordBatch:
    return u.evaluate(batch)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
