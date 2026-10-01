# =============================================================================
# builtin_agg_fns_firstlast.mojo — Built-in FIRST/LAST cells
# =============================================================================
#
# FIRST(col) and LAST(col) cells for the
# 10 fixed-width primitive types. State reuses the MinMaxStateT shape
# (value + seen flag).
#
# DuckDB cite: src/function/aggregate/distributive/first.cpp
#   FirstFunctionBase::Operation: if !seen then write & set seen.
#   LastFunctionBase::Operation: always write.
#
# Semantics:
#   FIRST: returns the first non-null value encountered in the group. The
#          State sticks after the first update; subsequent updates are
#          no-ops.
#   LAST:  returns the last non-null value encountered. Every update
#          overwrites the State.
#
# Note: in a non-ordered aggregation context, FIRST / LAST are inherently
# non-deterministic — the result depends on the row arrival order. DuckDB
# warns about this; we match its semantics. For ordered aggregation
# (WINDOW), the engine relies on a different path (the SortMerge sink
# guarantees order).
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
    MinMaxStateI8, MinMaxStateI16, MinMaxStateI32, MinMaxStateI64,
    MinMaxStateU8, MinMaxStateU16, MinMaxStateU32, MinMaxStateU64,
    MinMaxStateF32, MinMaxStateF64,
)


# =============================================================================
# FIRST cells. Write only on the first update. Merge: keep `a` if seen,
# else take `b`.
# =============================================================================


@fieldwise_init
struct FirstI8(AggFn):
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["first_v", DT_I8]()
    comptime OutType = DType.int8
    comptime State = MinMaxStateI8
    comptime UDF_ID = UInt32(0x0004_0601)

    def init(self) -> MinMaxStateI8:
        return MinMaxStateI8(Int8(0), False)

    def update(self, mut s: MinMaxStateI8, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI8, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Int8](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateI8, b: MinMaxStateI8) -> MinMaxStateI8:
        if a.seen:
            return MinMaxStateI8(a.value, True)
        return MinMaxStateI8(b.value, b.seen)

    def finalize(self, s: MinMaxStateI8) -> Scalar[DType.int8]:
        return s.value


@fieldwise_init
struct FirstI16(AggFn):
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["first_v", DT_I16]()
    comptime OutType = DType.int16
    comptime State = MinMaxStateI16
    comptime UDF_ID = UInt32(0x0004_0602)

    def init(self) -> MinMaxStateI16:
        return MinMaxStateI16(Int16(0), False)

    def update(self, mut s: MinMaxStateI16, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI16, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Int16](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateI16, b: MinMaxStateI16) -> MinMaxStateI16:
        if a.seen:
            return MinMaxStateI16(a.value, True)
        return MinMaxStateI16(b.value, b.seen)

    def finalize(self, s: MinMaxStateI16) -> Scalar[DType.int16]:
        return s.value


@fieldwise_init
struct FirstI32(AggFn):
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["first_v", DT_I32]()
    comptime OutType = DType.int32
    comptime State = MinMaxStateI32
    comptime UDF_ID = UInt32(0x0004_0603)

    def init(self) -> MinMaxStateI32:
        return MinMaxStateI32(Int32(0), False)

    def update(self, mut s: MinMaxStateI32, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI32, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Int32](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateI32, b: MinMaxStateI32) -> MinMaxStateI32:
        if a.seen:
            return MinMaxStateI32(a.value, True)
        return MinMaxStateI32(b.value, b.seen)

    def finalize(self, s: MinMaxStateI32) -> Scalar[DType.int32]:
        return s.value


@fieldwise_init
struct FirstI64(AggFn):
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["first_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0604)

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(0), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Int64](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if a.seen:
            return MinMaxStateI64(a.value, True)
        return MinMaxStateI64(b.value, b.seen)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


@fieldwise_init
struct FirstU8(AggFn):
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["first_v", DT_U8]()
    comptime OutType = DType.uint8
    comptime State = MinMaxStateU8
    comptime UDF_ID = UInt32(0x0004_0605)

    def init(self) -> MinMaxStateU8:
        return MinMaxStateU8(UInt8(0), False)

    def update(self, mut s: MinMaxStateU8, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU8, *vals: *Ts):
        if not s.seen:
            s.value = rebind[UInt8](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateU8, b: MinMaxStateU8) -> MinMaxStateU8:
        if a.seen:
            return MinMaxStateU8(a.value, True)
        return MinMaxStateU8(b.value, b.seen)

    def finalize(self, s: MinMaxStateU8) -> Scalar[DType.uint8]:
        return s.value


@fieldwise_init
struct FirstU16(AggFn):
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["first_v", DT_U16]()
    comptime OutType = DType.uint16
    comptime State = MinMaxStateU16
    comptime UDF_ID = UInt32(0x0004_0606)

    def init(self) -> MinMaxStateU16:
        return MinMaxStateU16(UInt16(0), False)

    def update(self, mut s: MinMaxStateU16, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU16, *vals: *Ts):
        if not s.seen:
            s.value = rebind[UInt16](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateU16, b: MinMaxStateU16) -> MinMaxStateU16:
        if a.seen:
            return MinMaxStateU16(a.value, True)
        return MinMaxStateU16(b.value, b.seen)

    def finalize(self, s: MinMaxStateU16) -> Scalar[DType.uint16]:
        return s.value


@fieldwise_init
struct FirstU32(AggFn):
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["first_v", DT_U32]()
    comptime OutType = DType.uint32
    comptime State = MinMaxStateU32
    comptime UDF_ID = UInt32(0x0004_0607)

    def init(self) -> MinMaxStateU32:
        return MinMaxStateU32(UInt32(0), False)

    def update(self, mut s: MinMaxStateU32, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU32, *vals: *Ts):
        if not s.seen:
            s.value = rebind[UInt32](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateU32, b: MinMaxStateU32) -> MinMaxStateU32:
        if a.seen:
            return MinMaxStateU32(a.value, True)
        return MinMaxStateU32(b.value, b.seen)

    def finalize(self, s: MinMaxStateU32) -> Scalar[DType.uint32]:
        return s.value


@fieldwise_init
struct FirstU64(AggFn):
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["first_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = MinMaxStateU64
    comptime UDF_ID = UInt32(0x0004_0608)

    def init(self) -> MinMaxStateU64:
        return MinMaxStateU64(UInt64(0), False)

    def update(self, mut s: MinMaxStateU64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU64, *vals: *Ts):
        if not s.seen:
            s.value = rebind[UInt64](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateU64, b: MinMaxStateU64) -> MinMaxStateU64:
        if a.seen:
            return MinMaxStateU64(a.value, True)
        return MinMaxStateU64(b.value, b.seen)

    def finalize(self, s: MinMaxStateU64) -> Scalar[DType.uint64]:
        return s.value


@fieldwise_init
struct FirstF32(AggFn):
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["first_v", DT_F32]()
    comptime OutType = DType.float32
    comptime State = MinMaxStateF32
    comptime UDF_ID = UInt32(0x0004_0609)

    def init(self) -> MinMaxStateF32:
        return MinMaxStateF32(Float32(0.0), False)

    def update(self, mut s: MinMaxStateF32, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF32, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Float32](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateF32, b: MinMaxStateF32) -> MinMaxStateF32:
        if a.seen:
            return MinMaxStateF32(a.value, True)
        return MinMaxStateF32(b.value, b.seen)

    def finalize(self, s: MinMaxStateF32) -> Scalar[DType.float32]:
        return s.value


@fieldwise_init
struct FirstF64(AggFn):
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["first_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = MinMaxStateF64
    comptime UDF_ID = UInt32(0x0004_060A)

    def init(self) -> MinMaxStateF64:
        return MinMaxStateF64(Float64(0.0), False)

    def update(self, mut s: MinMaxStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF64, *vals: *Ts):
        if not s.seen:
            s.value = rebind[Float64](vals[0])
            s.seen = True

    def merge(self, a: MinMaxStateF64, b: MinMaxStateF64) -> MinMaxStateF64:
        if a.seen:
            return MinMaxStateF64(a.value, True)
        return MinMaxStateF64(b.value, b.seen)

    def finalize(self, s: MinMaxStateF64) -> Scalar[DType.float64]:
        return s.value


# =============================================================================
# LAST cells. Always overwrite. Merge: take `b` if seen, else keep `a`.
# =============================================================================


@fieldwise_init
struct LastI8(AggFn):
    comptime InRow = RowI8
    comptime OutputSchema = schema_of["last_v", DT_I8]()
    comptime OutType = DType.int8
    comptime State = MinMaxStateI8
    comptime UDF_ID = UInt32(0x0004_0701)

    def init(self) -> MinMaxStateI8:
        return MinMaxStateI8(Int8(0), False)

    def update(self, mut s: MinMaxStateI8, row: RowI8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI8, *vals: *Ts):
        s.value = rebind[Int8](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateI8, b: MinMaxStateI8) -> MinMaxStateI8:
        if b.seen:
            return MinMaxStateI8(b.value, True)
        return MinMaxStateI8(a.value, a.seen)

    def finalize(self, s: MinMaxStateI8) -> Scalar[DType.int8]:
        return s.value


@fieldwise_init
struct LastI16(AggFn):
    comptime InRow = RowI16
    comptime OutputSchema = schema_of["last_v", DT_I16]()
    comptime OutType = DType.int16
    comptime State = MinMaxStateI16
    comptime UDF_ID = UInt32(0x0004_0702)

    def init(self) -> MinMaxStateI16:
        return MinMaxStateI16(Int16(0), False)

    def update(self, mut s: MinMaxStateI16, row: RowI16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI16, *vals: *Ts):
        s.value = rebind[Int16](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateI16, b: MinMaxStateI16) -> MinMaxStateI16:
        if b.seen:
            return MinMaxStateI16(b.value, True)
        return MinMaxStateI16(a.value, a.seen)

    def finalize(self, s: MinMaxStateI16) -> Scalar[DType.int16]:
        return s.value


@fieldwise_init
struct LastI32(AggFn):
    comptime InRow = RowI32
    comptime OutputSchema = schema_of["last_v", DT_I32]()
    comptime OutType = DType.int32
    comptime State = MinMaxStateI32
    comptime UDF_ID = UInt32(0x0004_0703)

    def init(self) -> MinMaxStateI32:
        return MinMaxStateI32(Int32(0), False)

    def update(self, mut s: MinMaxStateI32, row: RowI32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI32, *vals: *Ts):
        s.value = rebind[Int32](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateI32, b: MinMaxStateI32) -> MinMaxStateI32:
        if b.seen:
            return MinMaxStateI32(b.value, True)
        return MinMaxStateI32(a.value, a.seen)

    def finalize(self, s: MinMaxStateI32) -> Scalar[DType.int32]:
        return s.value


@fieldwise_init
struct LastI64(AggFn):
    comptime InRow = RowI64
    comptime OutputSchema = schema_of["last_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = MinMaxStateI64
    comptime UDF_ID = UInt32(0x0004_0704)

    def init(self) -> MinMaxStateI64:
        return MinMaxStateI64(Int64(0), False)

    def update(self, mut s: MinMaxStateI64, row: RowI64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateI64, *vals: *Ts):
        s.value = rebind[Int64](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateI64, b: MinMaxStateI64) -> MinMaxStateI64:
        if b.seen:
            return MinMaxStateI64(b.value, True)
        return MinMaxStateI64(a.value, a.seen)

    def finalize(self, s: MinMaxStateI64) -> Scalar[DType.int64]:
        return s.value


@fieldwise_init
struct LastU8(AggFn):
    comptime InRow = RowU8
    comptime OutputSchema = schema_of["last_v", DT_U8]()
    comptime OutType = DType.uint8
    comptime State = MinMaxStateU8
    comptime UDF_ID = UInt32(0x0004_0705)

    def init(self) -> MinMaxStateU8:
        return MinMaxStateU8(UInt8(0), False)

    def update(self, mut s: MinMaxStateU8, row: RowU8):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU8, *vals: *Ts):
        s.value = rebind[UInt8](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateU8, b: MinMaxStateU8) -> MinMaxStateU8:
        if b.seen:
            return MinMaxStateU8(b.value, True)
        return MinMaxStateU8(a.value, a.seen)

    def finalize(self, s: MinMaxStateU8) -> Scalar[DType.uint8]:
        return s.value


@fieldwise_init
struct LastU16(AggFn):
    comptime InRow = RowU16
    comptime OutputSchema = schema_of["last_v", DT_U16]()
    comptime OutType = DType.uint16
    comptime State = MinMaxStateU16
    comptime UDF_ID = UInt32(0x0004_0706)

    def init(self) -> MinMaxStateU16:
        return MinMaxStateU16(UInt16(0), False)

    def update(self, mut s: MinMaxStateU16, row: RowU16):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU16, *vals: *Ts):
        s.value = rebind[UInt16](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateU16, b: MinMaxStateU16) -> MinMaxStateU16:
        if b.seen:
            return MinMaxStateU16(b.value, True)
        return MinMaxStateU16(a.value, a.seen)

    def finalize(self, s: MinMaxStateU16) -> Scalar[DType.uint16]:
        return s.value


@fieldwise_init
struct LastU32(AggFn):
    comptime InRow = RowU32
    comptime OutputSchema = schema_of["last_v", DT_U32]()
    comptime OutType = DType.uint32
    comptime State = MinMaxStateU32
    comptime UDF_ID = UInt32(0x0004_0707)

    def init(self) -> MinMaxStateU32:
        return MinMaxStateU32(UInt32(0), False)

    def update(self, mut s: MinMaxStateU32, row: RowU32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU32, *vals: *Ts):
        s.value = rebind[UInt32](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateU32, b: MinMaxStateU32) -> MinMaxStateU32:
        if b.seen:
            return MinMaxStateU32(b.value, True)
        return MinMaxStateU32(a.value, a.seen)

    def finalize(self, s: MinMaxStateU32) -> Scalar[DType.uint32]:
        return s.value


@fieldwise_init
struct LastU64(AggFn):
    comptime InRow = RowU64
    comptime OutputSchema = schema_of["last_v", DT_U64]()
    comptime OutType = DType.uint64
    comptime State = MinMaxStateU64
    comptime UDF_ID = UInt32(0x0004_0708)

    def init(self) -> MinMaxStateU64:
        return MinMaxStateU64(UInt64(0), False)

    def update(self, mut s: MinMaxStateU64, row: RowU64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateU64, *vals: *Ts):
        s.value = rebind[UInt64](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateU64, b: MinMaxStateU64) -> MinMaxStateU64:
        if b.seen:
            return MinMaxStateU64(b.value, True)
        return MinMaxStateU64(a.value, a.seen)

    def finalize(self, s: MinMaxStateU64) -> Scalar[DType.uint64]:
        return s.value


@fieldwise_init
struct LastF32(AggFn):
    comptime InRow = RowF32
    comptime OutputSchema = schema_of["last_v", DT_F32]()
    comptime OutType = DType.float32
    comptime State = MinMaxStateF32
    comptime UDF_ID = UInt32(0x0004_0709)

    def init(self) -> MinMaxStateF32:
        return MinMaxStateF32(Float32(0.0), False)

    def update(self, mut s: MinMaxStateF32, row: RowF32):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF32, *vals: *Ts):
        s.value = rebind[Float32](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateF32, b: MinMaxStateF32) -> MinMaxStateF32:
        if b.seen:
            return MinMaxStateF32(b.value, True)
        return MinMaxStateF32(a.value, a.seen)

    def finalize(self, s: MinMaxStateF32) -> Scalar[DType.float32]:
        return s.value


@fieldwise_init
struct LastF64(AggFn):
    comptime InRow = RowF64
    comptime OutputSchema = schema_of["last_v", DT_F64]()
    comptime OutType = DType.float64
    comptime State = MinMaxStateF64
    comptime UDF_ID = UInt32(0x0004_070A)

    def init(self) -> MinMaxStateF64:
        return MinMaxStateF64(Float64(0.0), False)

    def update(self, mut s: MinMaxStateF64, row: RowF64):
        self.update_scalar(s, row.v)

    def update_scalar[*Ts: Copyable & Movable](self, mut s: MinMaxStateF64, *vals: *Ts):
        s.value = rebind[Float64](vals[0])
        s.seen = True

    def merge(self, a: MinMaxStateF64, b: MinMaxStateF64) -> MinMaxStateF64:
        if b.seen:
            return MinMaxStateF64(b.value, True)
        return MinMaxStateF64(a.value, a.seen)

    def finalize(self, s: MinMaxStateF64) -> Scalar[DType.float64]:
        return s.value
