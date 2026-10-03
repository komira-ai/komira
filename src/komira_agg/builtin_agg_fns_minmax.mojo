# =============================================================================
# builtin_agg_fns_minmax.mojo — Built-in MIN/MAX cells
# =============================================================================
#
# MIN and MAX cells for the 10 fixed-width
# primitive types. State is `MinMaxState<T>` (value + seen flag); output type
# matches input type.
#
# DuckDB cite: src/function/aggregate/distributive/min_max.cpp
#   MinMaxBase<MIN_OP, T> with `static void Operation(STATE &state, T &input,
#   ...)` that initializes on first row + compares thereafter.
#
# We split MIN and MAX into separate `@fieldwise_init struct (AggFn)` cells
# (not parameterized on a `< vs >` flag), mirroring the cell-per-(op,type)
# pattern of the MatchFn fanout. This keeps the trait surface
# orthogonal to the op direction and avoids comptime branches in the
# innermost `update_scalar` body.
#
# ⛔ THE FLOAT CELLS DO NOT FOLD ON BARE `<` / `>` (fixed)
# --------------------------------------------------------------------
# `MinF32`/`MinF64`/`MaxF32`/`MaxF64` compare through
# `komira_udf.float_quotient_order`, NOT through `<` / `>`. Every IEEE
# comparison against a NaN is FALSE, so `if not s.seen or v < s.value` can
# never displace a NaN that has reached `s.value`: a NaN in the FIRST row of a
# partition stuck forever, while the same NaN arriving LATER was silently
# dropped. `merge` had the identical shape, so under fork-join the answer was a
# function of HOW THE WORKERS PARTITIONED THE INPUT. MEASURED before the fix,
# over {1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}:
#
#   MAX, the 8 rotations      inf inf inf inf inf inf nan nan   (DuckDB: nan)
#   MAX, the 9 2-worker cuts  inf 1.0 inf inf inf inf inf inf   (DuckDB: nan)
#
# The `cut1=1.0` cell is the whole defect in one number: the SAME eight rows,
# the SAME order, a different morsel boundary, an answer that is neither the
# old wrong one nor the right one. The order puts NaN ABOVE +inf (DuckDB's
# model, measured); the integer cells are unaffected and still use `<` / `>`,
# which IS a strict weak ordering over integers.
#
# Sentinel + seen
# ---------------
# Each cell initializes its State to (sentinel, False) where sentinel is the
# identity-element for the op (T_MAX for MIN; T_MIN for MAX). The `seen`
# flag distinguishes "saw nothing" from "saw the sentinel value". Caller
# uses `seen` (visible via `finalize`'s OutputSchema nullability) to emit
# NULL for unseen groups in SQL.
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from komira_udf.agg_fn import AggFn
from komira_udf.schema_descriptor import (
    schema_of, DT_I8, DT_I16, DT_I32, DT_I64,
    DT_U8, DT_U16, DT_U32, DT_U64, DT_F32, DT_F64,
)
from komira_udf.float_quotient_order import (
    float_quotient_gt_f32,
    float_quotient_gt_f64,
    float_quotient_lt_f32,
    float_quotient_lt_f64,
)
from komira_agg.builtin_agg_fns_states import (
    RowI8, RowI16, RowI32, RowI64,
    RowU8, RowU16, RowU32, RowU64,
    RowF32, RowF64,
    MinMaxStateI8, MinMaxStateI16, MinMaxStateI32, MinMaxStateI64,
    MinMaxStateU8, MinMaxStateU16, MinMaxStateU32, MinMaxStateU64,
    MinMaxStateF32, MinMaxStateF64,
)


# =============================================================================
# MIN cells. Sentinel = max-of-T. Update on `not seen or v < value`.
# =============================================================================


@fieldwise_init
struct MinI8(AggFn):
    """MIN(Int8) -> Int8."""
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["min_v", DT_I8]()
    comptime OutType = DType.int8
    comptime State = MinMaxStateI8
    comptime UDF_ID = UInt32(0x0004_0201)

    def init(self) -> MinMaxStateI8:
        return MinMaxStateI8(Int8(127), False)  # I8 max

    def update(self, mut s: MinMaxStateI8, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI8, *vals: *Ts):
        var v = rebind[Int8](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI8, b: MinMaxStateI8) -> MinMaxStateI8:
        if not a.seen:
            return MinMaxStateI8(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI8(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateI8(b.value, True)
        return MinMaxStateI8(a.value, True)

    def finalize(self, s: MinMaxStateI8) -> Scalar[DType.int8]:
        return s.value


@fieldwise_init
struct MinI16(AggFn):
    """MIN(Int16) -> Int16."""
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["min_v", DT_I16]()
    comptime OutType = DType.int16
    comptime State = MinMaxStateI16
    comptime UDF_ID = UInt32(0x0004_0202)

    def init(self) -> MinMaxStateI16:
        return MinMaxStateI16(Int16(32767), False)

    def update(self, mut s: MinMaxStateI16, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI16, *vals: *Ts):
        var v = rebind[Int16](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI16, b: MinMaxStateI16) -> MinMaxStateI16:
        if not a.seen:
            return MinMaxStateI16(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI16(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateI16(b.value, True)
        return MinMaxStateI16(a.value, True)

    def finalize(self, s: MinMaxStateI16) -> Scalar[DType.int16]:
        return s.value


@fieldwise_init
struct MinI32(AggFn):
    """MIN(Int32) -> Int32."""
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["min_v", DT_I32]()
    comptime OutType = DType.int32
    comptime State = MinMaxStateI32
    comptime UDF_ID = UInt32(0x0004_0203)

    def init(self) -> MinMaxStateI32:
        return MinMaxStateI32(Int32(2147483647), False)

    def update(self, mut s: MinMaxStateI32, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI32, *vals: *Ts):
        var v = rebind[Int32](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI32, b: MinMaxStateI32) -> MinMaxStateI32:
        if not a.seen:
            return MinMaxStateI32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI32(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateI32(b.value, True)
        return MinMaxStateI32(a.value, True)

    def finalize(self, s: MinMaxStateI32) -> Scalar[DType.int32]:
        return s.value


@fieldwise_init
struct MinI64(AggFn):
    """MIN(Int64) -> Int64."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["min_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0204)

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(9223372036854775807), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        var v = rebind[Int64](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if not a.seen:
            return MinMaxStateI64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI64(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateI64(b.value, True)
        return MinMaxStateI64(a.value, True)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


@fieldwise_init
struct MinU8(AggFn):
    """MIN(UInt8) -> UInt8."""
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["min_v", DT_U8]()
    comptime OutType = DType.uint8
    comptime State = MinMaxStateU8
    comptime UDF_ID = UInt32(0x0004_0205)

    def init(self) -> MinMaxStateU8:
        return MinMaxStateU8(UInt8(255), False)

    def update(self, mut s: MinMaxStateU8, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU8, *vals: *Ts):
        var v = rebind[UInt8](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU8, b: MinMaxStateU8) -> MinMaxStateU8:
        if not a.seen:
            return MinMaxStateU8(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU8(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateU8(b.value, True)
        return MinMaxStateU8(a.value, True)

    def finalize(self, s: MinMaxStateU8) -> Scalar[DType.uint8]:
        return s.value


@fieldwise_init
struct MinU16(AggFn):
    """MIN(UInt16) -> UInt16."""
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["min_v", DT_U16]()
    comptime OutType = DType.uint16
    comptime State = MinMaxStateU16
    comptime UDF_ID = UInt32(0x0004_0206)

    def init(self) -> MinMaxStateU16:
        return MinMaxStateU16(UInt16(65535), False)

    def update(self, mut s: MinMaxStateU16, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU16, *vals: *Ts):
        var v = rebind[UInt16](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU16, b: MinMaxStateU16) -> MinMaxStateU16:
        if not a.seen:
            return MinMaxStateU16(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU16(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateU16(b.value, True)
        return MinMaxStateU16(a.value, True)

    def finalize(self, s: MinMaxStateU16) -> Scalar[DType.uint16]:
        return s.value


@fieldwise_init
struct MinU32(AggFn):
    """MIN(UInt32) -> UInt32."""
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["min_v", DT_U32]()
    comptime OutType = DType.uint32
    comptime State = MinMaxStateU32
    comptime UDF_ID = UInt32(0x0004_0207)

    def init(self) -> MinMaxStateU32:
        return MinMaxStateU32(UInt32(4294967295), False)

    def update(self, mut s: MinMaxStateU32, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU32, *vals: *Ts):
        var v = rebind[UInt32](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU32, b: MinMaxStateU32) -> MinMaxStateU32:
        if not a.seen:
            return MinMaxStateU32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU32(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateU32(b.value, True)
        return MinMaxStateU32(a.value, True)

    def finalize(self, s: MinMaxStateU32) -> Scalar[DType.uint32]:
        return s.value


@fieldwise_init
struct MinU64(AggFn):
    """MIN(UInt64) -> UInt64."""
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["min_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = MinMaxStateU64
    comptime UDF_ID = UInt32(0x0004_0208)

    def init(self) -> MinMaxStateU64:
        return MinMaxStateU64(UInt64(18446744073709551615), False)

    def update(self, mut s: MinMaxStateU64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU64, *vals: *Ts):
        var v = rebind[UInt64](vals[0])
        if not s.seen or v < s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU64, b: MinMaxStateU64) -> MinMaxStateU64:
        if not a.seen:
            return MinMaxStateU64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU64(a.value, a.seen)
        if b.value < a.value:
            return MinMaxStateU64(b.value, True)
        return MinMaxStateU64(a.value, True)

    def finalize(self, s: MinMaxStateU64) -> Scalar[DType.uint64]:
        return s.value


@fieldwise_init
struct MinF32(AggFn):
    """MIN(Float32) -> Float32."""
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["min_v", DT_F32]()
    comptime OutType = DType.float32
    comptime State = MinMaxStateF32
    comptime UDF_ID = UInt32(0x0004_0209)

    def init(self) -> MinMaxStateF32:
        return MinMaxStateF32(Float32(3.4028234663852886e38), False)  # ~F32_MAX

    def update(self, mut s: MinMaxStateF32, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF32, *vals: *Ts):
        var v = rebind[Float32](vals[0])
        if not s.seen or float_quotient_lt_f32(v, s.value):
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateF32, b: MinMaxStateF32) -> MinMaxStateF32:
        if not a.seen:
            return MinMaxStateF32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateF32(a.value, a.seen)
        if float_quotient_lt_f32(b.value, a.value):
            return MinMaxStateF32(b.value, True)
        return MinMaxStateF32(a.value, True)

    def finalize(self, s: MinMaxStateF32) -> Scalar[DType.float32]:
        return s.value


@fieldwise_init
struct MinF64(AggFn):
    """MIN(Float64) -> Float64."""
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["min_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = MinMaxStateF64
    comptime UDF_ID = UInt32(0x0004_020A)

    def init(self) -> MinMaxStateF64:
        return MinMaxStateF64(Float64(1.7976931348623157e308), False)  # ~F64_MAX

    def update(self, mut s: MinMaxStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF64, *vals: *Ts):
        var v = rebind[Float64](vals[0])
        if not s.seen or float_quotient_lt_f64(v, s.value):
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateF64, b: MinMaxStateF64) -> MinMaxStateF64:
        if not a.seen:
            return MinMaxStateF64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateF64(a.value, a.seen)
        if float_quotient_lt_f64(b.value, a.value):
            return MinMaxStateF64(b.value, True)
        return MinMaxStateF64(a.value, True)

    def finalize(self, s: MinMaxStateF64) -> Scalar[DType.float64]:
        return s.value


# =============================================================================
# MAX cells. Sentinel = min-of-T. Update on `not seen or v > value`.
# =============================================================================


@fieldwise_init
struct MaxI8(AggFn):
    """MAX(Int8) -> Int8."""
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["max_v", DT_I8]()
    comptime OutType = DType.int8
    comptime State = MinMaxStateI8
    comptime UDF_ID = UInt32(0x0004_0301)

    def init(self) -> MinMaxStateI8:
        return MinMaxStateI8(Int8(-128), False)

    def update(self, mut s: MinMaxStateI8, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI8, *vals: *Ts):
        var v = rebind[Int8](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI8, b: MinMaxStateI8) -> MinMaxStateI8:
        if not a.seen:
            return MinMaxStateI8(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI8(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateI8(b.value, True)
        return MinMaxStateI8(a.value, True)

    def finalize(self, s: MinMaxStateI8) -> Scalar[DType.int8]:
        return s.value


@fieldwise_init
struct MaxI16(AggFn):
    """MAX(Int16) -> Int16."""
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["max_v", DT_I16]()
    comptime OutType = DType.int16
    comptime State = MinMaxStateI16
    comptime UDF_ID = UInt32(0x0004_0302)

    def init(self) -> MinMaxStateI16:
        return MinMaxStateI16(Int16(-32768), False)

    def update(self, mut s: MinMaxStateI16, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI16, *vals: *Ts):
        var v = rebind[Int16](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI16, b: MinMaxStateI16) -> MinMaxStateI16:
        if not a.seen:
            return MinMaxStateI16(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI16(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateI16(b.value, True)
        return MinMaxStateI16(a.value, True)

    def finalize(self, s: MinMaxStateI16) -> Scalar[DType.int16]:
        return s.value


@fieldwise_init
struct MaxI32(AggFn):
    """MAX(Int32) -> Int32."""
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["max_v", DT_I32]()
    comptime OutType = DType.int32
    comptime State = MinMaxStateI32
    comptime UDF_ID = UInt32(0x0004_0303)

    def init(self) -> MinMaxStateI32:
        return MinMaxStateI32(Int32(-2147483648), False)

    def update(self, mut s: MinMaxStateI32, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI32, *vals: *Ts):
        var v = rebind[Int32](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI32, b: MinMaxStateI32) -> MinMaxStateI32:
        if not a.seen:
            return MinMaxStateI32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI32(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateI32(b.value, True)
        return MinMaxStateI32(a.value, True)

    def finalize(self, s: MinMaxStateI32) -> Scalar[DType.int32]:
        return s.value


@fieldwise_init
struct MaxI64(AggFn):
    """MAX(Int64) -> Int64."""
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["max_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0304)

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(-9223372036854775808), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        var v = rebind[Int64](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if not a.seen:
            return MinMaxStateI64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateI64(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateI64(b.value, True)
        return MinMaxStateI64(a.value, True)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


@fieldwise_init
struct MaxU8(AggFn):
    """MAX(UInt8) -> UInt8."""
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["max_v", DT_U8]()
    comptime OutType = DType.uint8
    comptime State = MinMaxStateU8
    comptime UDF_ID = UInt32(0x0004_0305)

    def init(self) -> MinMaxStateU8:
        return MinMaxStateU8(UInt8(0), False)

    def update(self, mut s: MinMaxStateU8, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU8, *vals: *Ts):
        var v = rebind[UInt8](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU8, b: MinMaxStateU8) -> MinMaxStateU8:
        if not a.seen:
            return MinMaxStateU8(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU8(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateU8(b.value, True)
        return MinMaxStateU8(a.value, True)

    def finalize(self, s: MinMaxStateU8) -> Scalar[DType.uint8]:
        return s.value


@fieldwise_init
struct MaxU16(AggFn):
    """MAX(UInt16) -> UInt16."""
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["max_v", DT_U16]()
    comptime OutType = DType.uint16
    comptime State = MinMaxStateU16
    comptime UDF_ID = UInt32(0x0004_0306)

    def init(self) -> MinMaxStateU16:
        return MinMaxStateU16(UInt16(0), False)

    def update(self, mut s: MinMaxStateU16, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU16, *vals: *Ts):
        var v = rebind[UInt16](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU16, b: MinMaxStateU16) -> MinMaxStateU16:
        if not a.seen:
            return MinMaxStateU16(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU16(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateU16(b.value, True)
        return MinMaxStateU16(a.value, True)

    def finalize(self, s: MinMaxStateU16) -> Scalar[DType.uint16]:
        return s.value


@fieldwise_init
struct MaxU32(AggFn):
    """MAX(UInt32) -> UInt32."""
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["max_v", DT_U32]()
    comptime OutType = DType.uint32
    comptime State = MinMaxStateU32
    comptime UDF_ID = UInt32(0x0004_0307)

    def init(self) -> MinMaxStateU32:
        return MinMaxStateU32(UInt32(0), False)

    def update(self, mut s: MinMaxStateU32, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU32, *vals: *Ts):
        var v = rebind[UInt32](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU32, b: MinMaxStateU32) -> MinMaxStateU32:
        if not a.seen:
            return MinMaxStateU32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU32(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateU32(b.value, True)
        return MinMaxStateU32(a.value, True)

    def finalize(self, s: MinMaxStateU32) -> Scalar[DType.uint32]:
        return s.value


@fieldwise_init
struct MaxU64(AggFn):
    """MAX(UInt64) -> UInt64."""
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["max_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = MinMaxStateU64
    comptime UDF_ID = UInt32(0x0004_0308)

    def init(self) -> MinMaxStateU64:
        return MinMaxStateU64(UInt64(0), False)

    def update(self, mut s: MinMaxStateU64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU64, *vals: *Ts):
        var v = rebind[UInt64](vals[0])
        if not s.seen or v > s.value:
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateU64, b: MinMaxStateU64) -> MinMaxStateU64:
        if not a.seen:
            return MinMaxStateU64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateU64(a.value, a.seen)
        if b.value > a.value:
            return MinMaxStateU64(b.value, True)
        return MinMaxStateU64(a.value, True)

    def finalize(self, s: MinMaxStateU64) -> Scalar[DType.uint64]:
        return s.value


@fieldwise_init
struct MaxF32(AggFn):
    """MAX(Float32) -> Float32."""
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["max_v", DT_F32]()
    comptime OutType = DType.float32
    comptime State = MinMaxStateF32
    comptime UDF_ID = UInt32(0x0004_0309)

    def init(self) -> MinMaxStateF32:
        return MinMaxStateF32(Float32(-3.4028234663852886e38), False)

    def update(self, mut s: MinMaxStateF32, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF32, *vals: *Ts):
        var v = rebind[Float32](vals[0])
        if not s.seen or float_quotient_gt_f32(v, s.value):
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateF32, b: MinMaxStateF32) -> MinMaxStateF32:
        if not a.seen:
            return MinMaxStateF32(b.value, b.seen)
        if not b.seen:
            return MinMaxStateF32(a.value, a.seen)
        if float_quotient_gt_f32(b.value, a.value):
            return MinMaxStateF32(b.value, True)
        return MinMaxStateF32(a.value, True)

    def finalize(self, s: MinMaxStateF32) -> Scalar[DType.float32]:
        return s.value


@fieldwise_init
struct MaxF64(AggFn):
    """MAX(Float64) -> Float64."""
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["max_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = MinMaxStateF64
    comptime UDF_ID = UInt32(0x0004_030A)

    def init(self) -> MinMaxStateF64:
        return MinMaxStateF64(Float64(-1.7976931348623157e308), False)

    def update(self, mut s: MinMaxStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF64, *vals: *Ts):
        var v = rebind[Float64](vals[0])
        if not s.seen or float_quotient_gt_f64(v, s.value):
            s.value = v
            s.seen = True

    def merge(self, a: MinMaxStateF64, b: MinMaxStateF64) -> MinMaxStateF64:
        if not a.seen:
            return MinMaxStateF64(b.value, b.seen)
        if not b.seen:
            return MinMaxStateF64(a.value, a.seen)
        if float_quotient_gt_f64(b.value, a.value):
            return MinMaxStateF64(b.value, True)
        return MinMaxStateF64(a.value, True)

    def finalize(self, s: MinMaxStateF64) -> Scalar[DType.float64]:
        return s.value
