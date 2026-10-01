# =============================================================================
# builtin_agg_fns_bool.mojo — Built-in AggFn conformers for Bool inputs
# =============================================================================
#
# Bool-input aggregations:
#
#   AnyBool   -- True if any non-null input was True
#   AllBool   -- True if every non-null input was True (vacuously True on
#                empty group)
#   CountBool -- counts non-null rows; State Int64
#
# DuckDB cite: src/function/aggregate/distributive/bool.cpp (Bool_Or /
# Bool_And) — though DuckDB models BOOL_OR / BOOL_AND as the SQL standard
# names. We use AnyBool / AllBool to keep with the aggregate cell-naming
# convention.
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from komira_eval.agg_fn import AggFn
from komira_eval.schema_descriptor import schema_of, DT_BOOL, DT_I64
from komira_eval.builtin_agg_fns_states import (
    RowBool, MinMaxStateBool, CountState,
)


@fieldwise_init
struct AnyBool(AggFn):
    """ANY(Bool) -> Bool. SQL standard BOOL_OR.

    State: MinMaxStateBool (value + seen). On first non-null row, set value
    = input + seen = True. Thereafter, OR into value. Final value
    indicates whether any input was True.
    """
    comptime InRow = RowBool
    comptime OutputSchema = schema_of["any_v", DT_BOOL]()
    comptime OutType = DType.bool
    comptime State = MinMaxStateBool
    comptime UDF_ID = UInt32(0x0004_080B)

    def init(self) -> MinMaxStateBool:
        return MinMaxStateBool(False, False)

    def update(self, mut s: MinMaxStateBool, row: RowBool):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateBool, *vals: *Ts):
        var v = rebind[Bool](vals[0])
        if not s.seen:
            s.value = v
            s.seen = True
        else:
            s.value = s.value or v

    def merge(self, a: MinMaxStateBool, b: MinMaxStateBool) -> MinMaxStateBool:
        if not a.seen:
            return MinMaxStateBool(b.value, b.seen)
        if not b.seen:
            return MinMaxStateBool(a.value, a.seen)
        return MinMaxStateBool(a.value or b.value, True)

    def finalize(self, s: MinMaxStateBool) -> Scalar[DType.bool]:
        return s.value


@fieldwise_init
struct AllBool(AggFn):
    """ALL(Bool) -> Bool. SQL standard BOOL_AND.

    State: MinMaxStateBool. On first non-null row, set value = input.
    Thereafter, AND into value. Final value indicates whether every
    input was True.
    """
    comptime InRow = RowBool
    comptime OutputSchema = schema_of["all_v", DT_BOOL]()
    comptime OutType = DType.bool
    comptime State = MinMaxStateBool
    comptime UDF_ID = UInt32(0x0004_080C)

    def init(self) -> MinMaxStateBool:
        return MinMaxStateBool(True, False)

    def update(self, mut s: MinMaxStateBool, row: RowBool):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateBool, *vals: *Ts):
        var v = rebind[Bool](vals[0])
        if not s.seen:
            s.value = v
            s.seen = True
        else:
            s.value = s.value and v

    def merge(self, a: MinMaxStateBool, b: MinMaxStateBool) -> MinMaxStateBool:
        if not a.seen:
            return MinMaxStateBool(b.value, b.seen)
        if not b.seen:
            return MinMaxStateBool(a.value, a.seen)
        return MinMaxStateBool(a.value and b.value, True)

    def finalize(self, s: MinMaxStateBool) -> Scalar[DType.bool]:
        return s.value


@fieldwise_init
struct CountBool(AggFn):
    """COUNT(Bool) -> Int64. Counts non-null rows (the input value is
    ignored — the PROPAGATE-null filter in AggFnAcc handles the
    skip-null contract)."""
    comptime InRow = RowBool
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_040B)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowBool):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count
