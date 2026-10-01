# =============================================================================
# builtin_agg_fns_avg.mojo — Built-in AVG cells
# =============================================================================
#
# AVG(col) cells for the 10 fixed-width
# primitive types. State is `AvgStateF64` (sum: Float64, count: Int64).
# Output is always Float64 (DuckDB widens regardless of input dtype).
#
# DuckDB cite: src/function/aggregate/distributive/avg.cpp
#   AvgFunction<T> with `AvgState { sum, count }` running totals; finalize
#   returns `sum / count`. On count == 0 we emit 0.0 (caller can use
#   OutputSchema nullability + the underlying count check to emit NULL
#   when needed in SQL).
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
    AvgStateF64,
)


@fieldwise_init
struct AvgI8(AggFn):
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0501)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Int8](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgI16(AggFn):
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0502)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Int16](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgI32(AggFn):
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0503)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Int32](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgI64(AggFn):
    """AVG(Int64) -> Float64. Canonical cell; sum widens to F64."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0504)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Int64](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgU8(AggFn):
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0505)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[UInt8](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgU16(AggFn):
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0506)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[UInt16](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgU32(AggFn):
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0507)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[UInt32](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgU64(AggFn):
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0508)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[UInt64](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgF32(AggFn):
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_0509)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Float32](vals[0]))
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)


@fieldwise_init
struct AvgF64(AggFn):
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["avg_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = AvgStateF64
    comptime UDF_ID = UInt32(0x0004_050A)

    def init(self) -> AvgStateF64:
        return AvgStateF64(Float64(0.0), Int64(0))

    def update(self, mut s: AvgStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: AvgStateF64, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])
        s.count += Int64(1)

    def merge(self, a: AvgStateF64, b: AvgStateF64) -> AvgStateF64:
        return AvgStateF64(a.sum + b.sum, a.count + b.count)

    def finalize(self, s: AvgStateF64) -> Scalar[DType.float64]:
        return s.sum / Float64(s.count) if s.count > 0 else Float64(0.0)
