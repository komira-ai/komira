# =============================================================================
# builtin_agg_fns_sum.mojo — Built-in SUM cells
# =============================================================================
#
# SUM cells for the 10 fixed-width
# primitive types. State widens per DuckDB semantics:
#
#   Signed integers (I8/I16/I32/I64)   -> Int64
#   Unsigned integers (U8/U16/U32/U64) -> UInt64
#   Floats (F32/F64)                    -> Float64 (non-Kahan)
#
# DuckDB cite: src/function/aggregate/distributive/sum.cpp
#   `template <class T> struct SumOperation { ... Operation(...) }`
#   The widening is done in `SumOperation::Operation` by `target += T(value)`
#   where `target` has the wider type.
#
# Each conformer is `@fieldwise_init struct (AggFn)`, zero captures.
# `update_scalar` is non-raising (the AggFn trait's `fn` rule).
#
# State pickup
# ------------
# All `Sum<signed>` use `SumStateI64`. All `Sum<unsigned>` use `SumStateU64`.
# `SumF32` and `SumF64` use `SumStateF64`. The State structs live in
# `builtin_agg_fns_states.mojo`.
#
# KERNEL_ID layout (high 16 bits = 0x0004, bank for built-in aggregates;
# next byte = op tag 0x01=Sum; low byte = type tag).
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins.
# - File < 1000 LOC.
# =============================================================================

from komira_udf.agg_fn import AggFn
from komira_udf.schema_descriptor import (
    schema_of, DT_I8, DT_I16, DT_I32, DT_I64,
    DT_U8, DT_U16, DT_U32, DT_U64, DT_F32, DT_F64,
)
from komira_agg.builtin_agg_fns_states import (
    RowI8, RowI16, RowI32, RowI64,
    RowU8, RowU16, RowU32, RowU64,
    RowF32, RowF64,
    SumStateI64, SumStateU64, SumStateF64,
)


# =============================================================================
# SUM(signed integer) -> Int64. Widening cast happens in update_scalar.
# =============================================================================


@fieldwise_init
struct SumI8(AggFn):
    """SUM(Int8) -> Int64. DuckDB's `SumOperation<int8_t>` shape."""
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["sum_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0x0004_0101)

    def init(self) -> SumStateI64:
        return SumStateI64(Int64(0))

    def update(self, mut s: SumStateI64, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateI64, *vals: *Ts):
        s.sum += Int64(rebind[Int8](vals[0]))

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


@fieldwise_init
struct SumI16(AggFn):
    """SUM(Int16) -> Int64."""
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["sum_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0x0004_0102)

    def init(self) -> SumStateI64:
        return SumStateI64(Int64(0))

    def update(self, mut s: SumStateI64, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateI64, *vals: *Ts):
        s.sum += Int64(rebind[Int16](vals[0]))

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


@fieldwise_init
struct SumI32(AggFn):
    """SUM(Int32) -> Int64."""
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["sum_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0x0004_0103)

    def init(self) -> SumStateI64:
        return SumStateI64(Int64(0))

    def update(self, mut s: SumStateI64, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateI64, *vals: *Ts):
        s.sum += Int64(rebind[Int32](vals[0]))

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


@fieldwise_init
struct SumI64(AggFn):
    """SUM(Int64) -> Int64. The canonical cell; DuckDB's `SumOperation<int64_t>`."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["sum_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = SumStateI64
    comptime UDF_ID = UInt32(0x0004_0104)

    def init(self) -> SumStateI64:
        return SumStateI64(Int64(0))

    def update(self, mut s: SumStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateI64, *vals: *Ts):
        s.sum += rebind[Int64](vals[0])

    def merge(self, a: SumStateI64, b: SumStateI64) -> SumStateI64:
        return SumStateI64(a.sum + b.sum)

    def finalize(self, s: SumStateI64) -> Scalar[DType.int64]:
        return s.sum


# =============================================================================
# SUM(unsigned integer) -> UInt64.
# =============================================================================


@fieldwise_init
struct SumU8(AggFn):
    """SUM(UInt8) -> UInt64."""
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["sum_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = SumStateU64
    comptime UDF_ID = UInt32(0x0004_0105)

    def init(self) -> SumStateU64:
        return SumStateU64(UInt64(0))

    def update(self, mut s: SumStateU64, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateU64, *vals: *Ts):
        s.sum += UInt64(rebind[UInt8](vals[0]))

    def merge(self, a: SumStateU64, b: SumStateU64) -> SumStateU64:
        return SumStateU64(a.sum + b.sum)

    def finalize(self, s: SumStateU64) -> Scalar[DType.uint64]:
        return s.sum


@fieldwise_init
struct SumU16(AggFn):
    """SUM(UInt16) -> UInt64."""
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["sum_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = SumStateU64
    comptime UDF_ID = UInt32(0x0004_0106)

    def init(self) -> SumStateU64:
        return SumStateU64(UInt64(0))

    def update(self, mut s: SumStateU64, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateU64, *vals: *Ts):
        s.sum += UInt64(rebind[UInt16](vals[0]))

    def merge(self, a: SumStateU64, b: SumStateU64) -> SumStateU64:
        return SumStateU64(a.sum + b.sum)

    def finalize(self, s: SumStateU64) -> Scalar[DType.uint64]:
        return s.sum


@fieldwise_init
struct SumU32(AggFn):
    """SUM(UInt32) -> UInt64."""
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["sum_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = SumStateU64
    comptime UDF_ID = UInt32(0x0004_0107)

    def init(self) -> SumStateU64:
        return SumStateU64(UInt64(0))

    def update(self, mut s: SumStateU64, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateU64, *vals: *Ts):
        s.sum += UInt64(rebind[UInt32](vals[0]))

    def merge(self, a: SumStateU64, b: SumStateU64) -> SumStateU64:
        return SumStateU64(a.sum + b.sum)

    def finalize(self, s: SumStateU64) -> Scalar[DType.uint64]:
        return s.sum


@fieldwise_init
struct SumU64(AggFn):
    """SUM(UInt64) -> UInt64."""
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["sum_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = SumStateU64
    comptime UDF_ID = UInt32(0x0004_0108)

    def init(self) -> SumStateU64:
        return SumStateU64(UInt64(0))

    def update(self, mut s: SumStateU64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateU64, *vals: *Ts):
        s.sum += rebind[UInt64](vals[0])

    def merge(self, a: SumStateU64, b: SumStateU64) -> SumStateU64:
        return SumStateU64(a.sum + b.sum)

    def finalize(self, s: SumStateU64) -> Scalar[DType.uint64]:
        return s.sum


# =============================================================================
# SUM(float) -> Float64 (non-compensated).
# =============================================================================


@fieldwise_init
struct SumF32(AggFn):
    """SUM(Float32) -> Float64."""
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["sum_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumStateF64
    comptime UDF_ID = UInt32(0x0004_0109)

    def init(self) -> SumStateF64:
        return SumStateF64(Float64(0.0))

    def update(self, mut s: SumStateF64, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateF64, *vals: *Ts):
        s.sum += Float64(rebind[Float32](vals[0]))

    def merge(self, a: SumStateF64, b: SumStateF64) -> SumStateF64:
        return SumStateF64(a.sum + b.sum)

    def finalize(self, s: SumStateF64) -> Scalar[DType.float64]:
        return s.sum


@fieldwise_init
struct SumF64(AggFn):
    """SUM(Float64) -> Float64."""
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["sum_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = SumStateF64
    comptime UDF_ID = UInt32(0x0004_010A)

    def init(self) -> SumStateF64:
        return SumStateF64(Float64(0.0))

    def update(self, mut s: SumStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: SumStateF64, *vals: *Ts):
        s.sum += rebind[Float64](vals[0])

    def merge(self, a: SumStateF64, b: SumStateF64) -> SumStateF64:
        return SumStateF64(a.sum + b.sum)

    def finalize(self, s: SumStateF64) -> Scalar[DType.float64]:
        return s.sum
