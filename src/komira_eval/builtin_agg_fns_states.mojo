# =============================================================================
# builtin_agg_fns_states.mojo — Shared State + Row structs for built-in AggFn
# =============================================================================
#
# Mirrors `agg_fn_acc.mojo` / the
# `WAvgRow` / `WAvgState` test pattern:
#
#   - Per-type `RowT` (a single-field `@fieldwise_init struct (Copyable, Movable)`
#     wrapping a typed scalar; the `AggFn.InRow` requirement).
#   - Shared `StateT` types (one per distinct State shape; reused across
#     cells whose State has identical physical layout). All conform to
#     `PodState` (Copyable + Movable + Deinitable — the stale-slab
#     compile-time gate from `komira_eval.agg_fn`).
#
# Sharing the State structs across cells (e.g. SumI8, SumI16, SumI32, SumI64
# all use `SumStateI64` since they all widen to Int64) means the
# `merge_aligned` path in `AggFnAcc[F]` can compose with future SIMD reduce
# kernels without re-typing per cell.
#
# DuckDB cite: `src/include/duckdb/function/aggregate/distributive_functions.hpp`
# defines `SumState<T>` / `MinMaxState<T>` / `AvgState` / etc. — one template
# per agg op. Mojo lacks struct templates, so we declare one State struct per
# physical type; the `comptime State` member on each conformer picks the
# matching one.
#
# Mojo discipline
# ---------------
# - No `UnsafePointer` in any signature.
# - No wildcard origins.
# - File < 1000 LOC.
# - All structs are `@fieldwise_init` PodState/Movable+Copyable conformers.
# =============================================================================

from komira_eval.agg_fn import PodState
from komira_eval.auto_komira_schema import AutoKomiraSchema


# =============================================================================
# RowT — typed named-struct InRow (one per primitive dtype).
#
# All RowT structs conform to `AutoKomiraSchema`
# — the marker trait that the user-facing UDF
# traits' `comptime InRow` member bind to. With `_derive_schema[Self.InRow]()`
# as the trait default for `AggFn.InputSchema` 
# the schema is auto-derived from each RowT's single `var v: <DType>` field.
# Marker conformance is empty (pure type tag) — adding it is byte-additive
# and does NOT change any existing builtin agg behavior.
# =============================================================================


@fieldwise_init
struct RowI8(Copyable, Movable, AutoKomiraSchema):
    var v: Int8


@fieldwise_init
struct RowI16(Copyable, Movable, AutoKomiraSchema):
    var v: Int16


@fieldwise_init
struct RowI32(Copyable, Movable, AutoKomiraSchema):
    var v: Int32


@fieldwise_init
struct RowI64(Copyable, Movable, AutoKomiraSchema):
    var v: Int64


@fieldwise_init
struct RowU8(Copyable, Movable, AutoKomiraSchema):
    var v: UInt8


@fieldwise_init
struct RowU16(Copyable, Movable, AutoKomiraSchema):
    var v: UInt16


@fieldwise_init
struct RowU32(Copyable, Movable, AutoKomiraSchema):
    var v: UInt32


@fieldwise_init
struct RowU64(Copyable, Movable, AutoKomiraSchema):
    var v: UInt64


@fieldwise_init
struct RowF32(Copyable, Movable, AutoKomiraSchema):
    var v: Float32


@fieldwise_init
struct RowF64(Copyable, Movable, AutoKomiraSchema):
    var v: Float64


@fieldwise_init
struct RowBool(Copyable, Movable, AutoKomiraSchema):
    var v: Bool


# =============================================================================
# SUM states — widened-to-I64/U64/F64 single-field POD.
# =============================================================================


@fieldwise_init
struct SumStateI64(PodState):
    """SUM accumulator over a signed integer column (widened to Int64)."""
    var sum: Int64


@fieldwise_init
struct SumStateU64(PodState):
    """SUM accumulator over an unsigned integer column (widened to UInt64)."""
    var sum: UInt64


@fieldwise_init
struct SumStateF64(PodState):
    """SUM accumulator over a Float64 column (no Kahan in this trait — see
    `SumF64KahanAcc` in `columnar_acc_typed.mojo` for the precision path)."""
    var sum: Float64


# =============================================================================
# COUNT state — Int64.
# =============================================================================


@fieldwise_init
struct CountState(PodState):
    """COUNT accumulator (non-null rows; the trait's PROPAGATE semantics
    skip null rows in `update_record_batch` so we count by simple +1)."""
    var count: Int64


# =============================================================================
# MIN/MAX states — paired (value, seen). One struct per typed value field.
# =============================================================================


@fieldwise_init
struct MinMaxStateI8(PodState):
    var value: Int8
    var seen: Bool


@fieldwise_init
struct MinMaxStateI16(PodState):
    var value: Int16
    var seen: Bool


@fieldwise_init
struct MinMaxStateI32(PodState):
    var value: Int32
    var seen: Bool


@fieldwise_init
struct MinMaxStateI64(PodState):
    var value: Int64
    var seen: Bool


@fieldwise_init
struct MinMaxStateU8(PodState):
    var value: UInt8
    var seen: Bool


@fieldwise_init
struct MinMaxStateU16(PodState):
    var value: UInt16
    var seen: Bool


@fieldwise_init
struct MinMaxStateU32(PodState):
    var value: UInt32
    var seen: Bool


@fieldwise_init
struct MinMaxStateU64(PodState):
    var value: UInt64
    var seen: Bool


@fieldwise_init
struct MinMaxStateF32(PodState):
    var value: Float32
    var seen: Bool


@fieldwise_init
struct MinMaxStateF64(PodState):
    var value: Float64
    var seen: Bool


@fieldwise_init
struct MinMaxStateBool(PodState):
    var value: Bool
    var seen: Bool


# =============================================================================
# AVG state — (Float64 sum, Int64 count).
# =============================================================================


@fieldwise_init
struct AvgStateF64(PodState):
    var sum: Float64
    var count: Int64


@fieldwise_init
struct WelfordStateF64(PodState):
    """Running-moment (Welford/M2) state for STDDEV_SAMP. 24-byte POD
    `[count | mean | m2]`; m2 = running sum of squared deviations from the
    running mean. Identity = (0, 0.0, 0.0)."""

    var count: Int64
    var mean: Float64
    var m2: Float64


# =============================================================================
# FIRST/LAST states — share MinMaxState shape (value + seen).
# We alias-by-reuse: `First<T>` and `Last<T>` use the MinMaxState<T> types
# above. The semantics differ in the update body (write-once for First,
# write-each for Last), but the State layout is identical.
# =============================================================================
