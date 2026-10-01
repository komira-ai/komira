# =============================================================================
# builtin_agg_fns_count.mojo — Built-in COUNT cells
# =============================================================================
#
# COUNT(col) cells for the 10 fixed-width
# primitive types. State carries Int64; output is always Int64.
#
# DuckDB cite: src/function/aggregate/distributive/count.cpp
#   CountFunctionBase::CountUpdate / CountStarFunction. The trait's
#   PROPAGATE-null semantics in `AggFnAcc.update_record_batch` skips null
#   rows so we increment unconditionally in the body.
#
# COUNT(*) is a runtime engine-level concept (no input columns); not a kernel
# fanout — handled by the agg compile path independently.
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from komira_eval.agg_fn import AggFn
from komira_eval.schema_descriptor import (
    schema_of, DT_I8, DT_I16, DT_I32, DT_I64,
    DT_U8, DT_U16, DT_U32, DT_U64, DT_F32, DT_F64,
)
from komira_eval.builtin_agg_fns_states import (
    RowI8, RowI16, RowI32, RowI64,
    RowU8, RowU16, RowU32, RowU64,
    RowF32, RowF64,
    CountState,
)


@fieldwise_init
struct CountI8(AggFn):
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0401)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountI16(AggFn):
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0402)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountI32(AggFn):
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0403)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountI64(AggFn):
    """COUNT(Int64) -> Int64 (non-null rows). The canonical cell."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0404)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountU8(AggFn):
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0405)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountU16(AggFn):
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0406)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountU32(AggFn):
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0407)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountU64(AggFn):
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0408)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountF32(AggFn):
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_0409)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count


@fieldwise_init
struct CountF64(AggFn):
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_040A)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count
