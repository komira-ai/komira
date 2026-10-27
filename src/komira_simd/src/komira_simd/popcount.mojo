# =============================================================================
# popcount.mojo — SIMD per-lane and bool-mask population-count primitives.
# =============================================================================
#
# PERF-CRITICAL. Per-lane popcount is the inner workload of every bitmap
# null-count loop (Arrow validity scan, Parquet null-count scan; see
# `komira_arrow/bitmap.mojo:_simd_popcount_bytes`), every dense
# RLE-bit-packed Parquet level decoder, every selection-vector cardinality
# count under AdaptiveFilter convergence, and every JSON key-scan that
# computes match cardinality per chunk.
#
# Bool-mask popcount is the cardinality-count hot path for selection-vector
# emission: after building a `SIMD[Bool, W]` per-lane mask in a Filter /
# Compare / ExpressionExecutor kernel, the popcount tells you how many
# lanes survive — used as both the output-buffer advance count and the
# AdaptiveFilter convergence counter.
#
# This module wraps the stdlib `std.bit.pop_count(SIMD[T, W])` overload
# (which lowers to `llvm.ctpop.vNT` and on ARM NEON to the native
# `cnt.16b` instruction, on AVX-512 BITALG to `vpopcntb` / `vpopcntw` /
# `vpopcntd` / `vpopcntq`) behind a uniform set of public
# `popcount_uNxW` primitives. The wrappers are thin (one line each) but
# the public API guarantees a stable call-site shape independent of any
# future stdlib rename, and gives the SIMD primitive library a single
# place to add an AVX-512 explicit-intrinsic arm if the LLVM default
# lowering turns out suboptimal vs `vpopcntb` direct.
#
# Architecture dispatch:
#   * ARM64 NEON:     `cnt.16b` (u8x16) + reduce/widen for u16/u32/u64.
#   * x86 AVX-512 BITALG (Ice Lake+):  `vpopcntb` / `vpopcntw` / `vpopcntd`
#                     / `vpopcntq` direct instructions.
#   * x86 AVX-512 without BITALG (Skylake-X, Cannon Lake) / AVX2:
#                     LLVM Wilkes-Wheeler-Gill byte-LUT lowering —
#                     SIMD-accelerated, far better than scalar popcnt-per-lane.
#   * Scalar fallback (W=1): LLVM `popcnt` instruction on x86 / `clz`-cycle
#                     on ARM.
#
# All paths go through the SAME stdlib `pop_count` call — Mojo + LLVM
# pick the right instruction per target. No `comptime if CompilationTarget`
# arch branch is needed at the wrapper level.
#
# Encapsulation: this module's public API is pure SIMD-value-in,
# SIMD-value-out (per-lane) or Int-out (mask). NO `UnsafePointer`, no
# `Span`, no buffer mutation.
#
# Mojo gotchas:
#   * `pop_count(SIMD[T, W])` is in `std.bit`, not `std.sys.intrinsics`.
#     Same import shape as `bitmap.mojo`.
#   * `pop_count` of `SIMD[uint8, W]` returns `SIMD[uint8, W]` (the
#     per-lane bit count, range 0..8) — NOT a scalar. Callers that want
#     a total walk-sum chain `pop_count(v).reduce_add()` or
#     `pop_count(v).cast[uint64]().reduce_add()` if W*8 might overflow
#     UInt8 (W>=32 with all-ones lanes; not a concern for our largest W=16).
#   * `SIMD[Bool, W].cast[uint8]()` is a no-op reinterpret (bool is 1
#     byte per lane); `.reduce_add()` is then a
#     small horizontal-sum. For W <= 16 the result always fits in UInt8.
#   * `simd_width_of[T]()` is honest on every target Mojo supports —
#     u8=16 on NEON / 32 on AVX-512BW; u16=8 NEON / 16 AVX-512; u32=4
#     NEON / 8 AVX2 / 16 AVX-512; u64=2 NEON / 4 AVX2 / 8 AVX-512.
#
# `komira_arrow/bitmap.mojo`'s `_simd_popcount_bytes` uses the same
# lowering (`cnt.16b` on NEON).
# =============================================================================

from std.bit import pop_count


# =============================================================================
# Per-DType per-lane popcount primitives.
# =============================================================================
#
# Five public wrappers, one per (T, W) family Mojo SIMD supports:
#
#   popcount_u8xW : SIMD[UInt8,  W] -> SIMD[UInt8,  W]    (per-lane bit-count 0..8)
#   popcount_u16xW: SIMD[UInt16, W] -> SIMD[UInt16, W]    (per-lane bit-count 0..16)
#   popcount_u32xW: SIMD[UInt32, W] -> SIMD[UInt32, W]    (per-lane bit-count 0..32)
#   popcount_u64xW: SIMD[UInt64, W] -> SIMD[UInt64, W]    (per-lane bit-count 0..64)
#   popcount_mask : SIMD[Bool,   W] -> Int                (total set lanes)
#
# W is INFERRED from the input SIMD type (parametric); on each call site
# Mojo derives W from the caller's `simd_width_of[T]()` choice. The
# stdlib lowering automatically selects the native instruction per
# target architecture.
# =============================================================================


@always_inline
def popcount_u8xW[W: SIMDLength, //](v: SIMD[DType.uint8, W]) -> SIMD[DType.uint8, W]:
    """Per-lane popcount for UInt8 lanes. Range per lane: 0..8.

    ARM64 NEON (W=16): single `cnt.16b` instruction (~1 cycle throughput on
    Apple Silicon / Cortex-A).
    x86 AVX-512 BITALG (W=64): single `vpopcntb` instruction (Ice Lake+).
    x86 AVX-512 without BITALG / AVX2: LLVM byte-LUT lowering.
    Scalar (W=1): native `popcnt` (x86) / `cnt` (ARM scalar) instruction.

    Use case: walking an Arrow validity bitmap; chunk the bitmap into
    SIMD[u8, 16] loads, popcount each chunk, accumulate via reduce_add:

        var chunk = view.load_simd[DType.uint8, 16](off)
        var cnts = popcount_u8xW(chunk)
        total += Int(cnts.reduce_add())

    This matches the in-tree pattern at `bitmap.mojo:_simd_popcount_bytes`.
    """
    return pop_count(v)


@always_inline
def popcount_u16xW[W: SIMDLength, //](
    v: SIMD[DType.uint16, W]
) -> SIMD[DType.uint16, W]:
    """Per-lane popcount for UInt16 lanes. Range per lane: 0..16.

    ARM64 NEON (W=8): widening reduce — `cnt.8b` on each lane-byte then
    pairwise-add to u16 lanes (LLVM lowers via `<8 x i8>` widening).
    x86 AVX-512 BITALG (W=32): single `vpopcntw` instruction.
    x86 AVX-512 without BITALG / AVX2: LLVM byte-LUT lowering, then a
    widening accumulation to u16.
    """
    return pop_count(v)


@always_inline
def popcount_u32xW[W: SIMDLength, //](
    v: SIMD[DType.uint32, W]
) -> SIMD[DType.uint32, W]:
    """Per-lane popcount for UInt32 lanes. Range per lane: 0..32.

    ARM64 NEON (W=4): `cnt.16b` of the 4-element bitcast then 8-bit-to-32
    pairwise reduction (`uaddlp.4h` chain), or LLVM may also emit
    `udot.4s` on Apple Silicon.
    x86 AVX-512 BITALG (W=16): single `vpopcntd` instruction.
    x86 AVX-512 without BITALG / AVX2: byte-LUT + 4-byte horizontal sum.
    """
    return pop_count(v)


@always_inline
def popcount_u64xW[W: SIMDLength, //](
    v: SIMD[DType.uint64, W]
) -> SIMD[DType.uint64, W]:
    """Per-lane popcount for UInt64 lanes. Range per lane: 0..64.

    ARM64 NEON (W=2): `cnt.16b` + `udot.4s` + `uadalp.2d` accumulator
    cascade — the same canonical clang-O3 pattern in
    `bitmap.mojo:_simd_popcount_bytes`. Two u64 popcounts per 1 SIMD op.
    x86 AVX-512 BITALG (W=8): single `vpopcntq` instruction.
    x86 AVX-512 without BITALG / AVX2: byte-LUT + 8-byte horizontal sum.
    x86 scalar (W=1): native `popcnt` instruction.
    """
    return pop_count(v)


# =============================================================================
# Bool-mask popcount — selection-vector cardinality.
# =============================================================================


@always_inline
def popcount_mask[W: SIMDLength, //](mask: SIMD[DType.bool, W]) -> Int:
    """Total count of `True` lanes in a SIMD bool mask.

    For W <= 255 this is `mask.cast[DType.uint8]().reduce_add()` — the
    `cast[uint8]` is a no-op reinterpret (bool is one
    byte per lane, byte value 0 or 1), so the chain compiles to a single
    `reduce_add()` on the underlying u8 lanes. On ARM NEON this lowers
    to `addv b0, v.16b` (W=16) or `addv b0, v.Nb` for smaller W; on x86
    AVX-512 it lowers to `vpsadbw` + `vpermilq` horizontal-sum.

    The returned `Int` is the natural type for downstream consumers
    (AdaptiveFilter convergence counters, selection-vector advance
    counts, hash-join probe survivor counts). The intermediate UInt8
    sum can hold any value 0..W for W <= 255 — comfortably wider than
    any SIMD width Mojo can produce.

    Use case: after a SIMD filter mask is computed, advance the output
    selection-vector cursor by the survivor count:

        var keep = (col_vec > threshold)              # SIMD[Bool, W]
        var n_keep = popcount_mask(keep)
        compress_*xW(keep, lanes_vec)                 # emit survivors
        out_count += n_keep                           # advance cursor

    For W > 255 the intermediate sum could in principle overflow UInt8,
    but Mojo does not produce SIMD widths > 64 lanes from any
    legal `simd_width_of[T]()` call (AVX-512 byte = 64 lanes), so the
    practical ceiling is W=64, comfortably below 256.
    """
    comptime assert W <= 255, "popcount_mask: SIMD width must be <= 255 lanes"
    return Int(mask.cast[DType.uint8]().reduce_add())
