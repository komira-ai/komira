# =============================================================================
# compress.mojo — SIMD mask-driven compact-and-store primitives.
# =============================================================================
#
# PERF-CRITICAL. The mask-driven compact pattern
#
#     comptime for k in range(W):
#         if mask[k]:
#             out[count] = vec[k]
#             count = count + 1
#
# is the inner loop of every selection-vector emission (Filter, Compare,
# ExpressionExecutor) AND of every vector-stream compactor (GroupBy probe,
# Hash-Join probe, NULL-mask compaction). On x86 AVX-512 the comptime-unrolled
# scalar scatter does NOT pattern-match to `vcompresspd` / `vpcompressd` /
# `vpcompressq` — instead the compiler emits 8 `kshiftrb` + `kmovd` +
# `test` + `je` + `mov [out + count*4], reg` + `add count, popcnt(mask_k)`
# blocks per W=8 SIMD chunk (~56 instructions for one column-pair compare),
# several times the cost of the equivalent NEON W=2 unroll.
#
# This module wraps the LLVM AVX-512 compress intrinsics behind a comptime
# dispatch so callers can write
#
#     var r = compress_f64xW(mask, vec)
#     for k in range(Int(r.count)):
#         out_sel[count + k] = i + r.compacted[k]
#     count += Int(r.count)
#
# and ship the same source through both NEON (cheap @parameter-for-k scatter)
# and x86 AVX-512 (single `vcompresspd` + popcount).
#
# Architecture dispatch:
#   * x86 + simd_width_of[T]() == 8 (f64/i64) → `llvm.experimental.vector.compress`
#                                                lowers to `vcompresspd` / `vpcompressq`.
#   * x86 + simd_width_of[T]() == 16 (u32) + W==16 → `llvm.experimental.vector.compress`
#                                                    lowers to `vpcompressd zmm` (16 lanes).
#   * x86 + simd_width_of[T]() == 16 (u32) + W==8  → `llvm.experimental.vector.compress`
#                                                    lowers to `vpcompressd ymm` (8 lanes).
#                                                    Load-bearing for sel_kernels'
#                                                    `_emit_lane_writes[W=8]` shape
#                                                    (f64/i64 column filters).
#   * Otherwise (NEON, AVX2, scalar)          → comptime-unrolled scalar
#                                                scatter (the W=2 / W=4
#                                                NEON pattern, which is
#                                                cheap; same shape used
#                                                in `arithmetic.mojo`).
#
# Mojo gotchas:
#   * `llvm_intrinsic[name, ReturnType](args...)` derives operand types from
#     the wrapper signature. The legacy bare-name AVX-512 mask intrinsic
#     family (`llvm.x86.avx512.mask.compress.{d,q,pd}.512`) is REJECTED by
#     Mojo's bundled LLVM overload matcher
#     ("does not match any of the overloads" + "LLVM Translation failed").
#     The canonical replacement is the target-independent
#     `llvm.experimental.vector.compress`, which lowers to
#     `vpcompressd zmm0{k1}{z}, zmm0` / `vcompresspd` / `vpcompressq` on
#     Skylake-X with ZERO `kshiftrb`.
#     EVC signature: `(<N x T> src, <N x i1> mask, <N x T> passthrough) -> <N x T>`.
#   * `CompilationTarget.has_avx512()` is not exposed. Dispatch via
#     `simd_width_of[T]() == W` value gate: on AVX-512 x86,
#     `simd_width_of[Float64] == 8`; on AVX2 x86, `simd_width_of[Float64] == 4`
#     (so the AVX-512 branch is dead, falls through to scalar scatter as
#     expected). `simd_width_of` is honest on every target.
#   * `@parameter if` → `comptime if`; `@parameter for` → `comptime for`.
#   * `Self.D` / `Self.W` qualifier MANDATORY inside parametric struct
#     bodies.
# =============================================================================

from std.sys.info import CompilationTarget, simd_width_of
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# CompressResult — return shape for the compress primitives.
# =============================================================================


@fieldwise_init
struct CompressResult[D: DType, W: Int](Copyable, Movable):
    """Result of a mask-driven compact: the compacted SIMD vector plus
    the count of valid lanes (popcount of mask).

    Callers consume only the first `count` lanes of `compacted`; the
    trailing lanes carry the AVX-512 intrinsic's passthrough value
    (zero in our wrappers) or the comptime-scatter's pre-initialized
    zero. Lane order is preserved: lanes set in `mask` appear in the
    same relative order in `compacted`.

    For W=8 the count is at most 8; for W=16 at most 16. UInt8 holds
    both. UInt8 also matches the LLVM `i8` mask register width on x86.
    """

    var compacted: SIMD[Self.D, Self.W]
    var count: UInt8


# =============================================================================
# Internal helpers — bool→bitmask + scalar reference.
# =============================================================================


@always_inline
def _bool_mask_to_u8[W: Int](mask: SIMD[DType.bool, W]) -> UInt8:
    """Pack the first up-to-8 lanes of a SIMD[Bool, W] into a UInt8 bitmask
    (LSB = lane 0). For W>8 the high lanes are ignored; this helper exists
    for the W=8 AVX-512 path. For W=16 use `_bool_mask_to_u16`.

    The comptime-unrolled OR-shift compiles to W branchless `or-with-shift`
    instructions on every architecture. Cheap.
    """
    comptime assert W <= 8, "_bool_mask_to_u8 takes mask of <= 8 lanes"
    var bits: UInt8 = 0
    comptime for k in range(W):
        if mask[k]:
            bits = bits | (UInt8(1) << UInt8(k))
    return bits


@always_inline
def _bool_mask_to_u16[W: Int](mask: SIMD[DType.bool, W]) -> UInt16:
    """Pack the first up-to-16 lanes of a SIMD[Bool, W] into a UInt16 bitmask
    (LSB = lane 0). For the AVX-512 W=16 u32 compress path.
    """
    comptime assert W <= 16, "_bool_mask_to_u16 takes mask of <= 16 lanes"
    var bits: UInt16 = 0
    comptime for k in range(W):
        if mask[k]:
            bits = bits | (UInt16(1) << UInt16(k))
    return bits


@always_inline
def _popcount_mask[W: SIMDLength](mask: SIMD[DType.bool, W]) -> UInt8:
    """Popcount of a SIMD[Bool, W] mask: `mask.cast[uint8]().reduce_add()`.

    On NEON `cast[uint8]` is a no-op (bool is
    one byte per lane) and `reduce_add()` becomes `addv`. For W <= 16
    the sum fits in UInt8.
    """
    comptime assert W <= 255, "_popcount_mask: W must fit popcount in UInt8"
    var counts = mask.cast[DType.uint8]()
    return counts.reduce_add()


@always_inline
def _scalar_compress[D: DType, W: Int](
    mask: SIMD[DType.bool, W],
    vec: SIMD[D, W],
) -> CompressResult[D, W]:
    """Scalar comptime-unrolled scatter. Cheap on NEON (W=2 → 2 lane
    checks per chunk); used as fallback on AVX2 + non-x86 + W=1.

    Lane order is preserved. Trailing lanes (count..W) are zeroed.
    """
    var out = SIMD[D, W](0)
    var c: Int = 0
    comptime for k in range(W):
        if mask[k]:
            out[c] = vec[k]
            c = c + 1
    return CompressResult[D, W](compacted=out, count=UInt8(c))


# =============================================================================
# x86 AVX-512 intrinsic wrappers (only callable on x86; dead on NEON).
# =============================================================================
#
# LLVM target-independent vector-compress intrinsic
# (LLVM langref, `lib/IR/Intrinsics.td`):
#
#   declare <N x T> @llvm.experimental.vector.compress.vNT(
#       <N x T> %src, <N x i1> %mask, <N x T> %passthrough)
#
# Lane-0..popcount(mask)-1 of the result hold the compacted values in source
# order where mask bit was set; lane-popcount..N-1 hold the passthrough value
# (we pass zero so the trailing lanes are deterministic).
#
# WHY EVC and not the legacy `llvm.x86.avx512.mask.compress.{d,q,pd}.512`
# family: the legacy bare-name intrinsics are REJECTED by Mojo's
# bundled LLVM overload matcher ("does not match any of the overloads"
# + "LLVM Translation failed for operation: llvm.call_intrinsic"). The
# target-independent EVC intrinsic IS accepted and lowers to the same
# `vpcompressd` / `vcompresspd` / `vpcompressq` instructions on
# Skylake-X.
# =============================================================================


@always_inline
def _avx512_compress_d_x16(
    src: SIMD[DType.uint32, 16],
    mask: SIMD[DType.bool, 16],
    passthrough: SIMD[DType.uint32, 16],
) -> SIMD[DType.uint32, 16]:
    """AVX-512 W=16 UInt32 mask-driven compress. x86_64 ONLY (caller must
    gate via `comptime if CompilationTarget.is_x86() and simd_width_of[uint32]() == 16`).
    Lowers to `vpcompressd zmm0{k1}{z}, zmm0` on Skylake-X.
    """
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.uint32, 16],
    ](src, mask, passthrough)


@always_inline
def _avx512_compress_d_x8(
    src: SIMD[DType.uint32, 8],
    mask: SIMD[DType.bool, 8],
    passthrough: SIMD[DType.uint32, 8],
) -> SIMD[DType.uint32, 8]:
    """AVX-512 W=8 UInt32 mask-driven compress. x86_64 ONLY. Lowers to
    `vpcompressd ymm0{k1}{z}, ymm0` on Skylake-X.

    Why this exists: `_emit_lane_writes[W]` in the selection kernels
    (`sel_kernels`) inherits W from the column DType
    (`simd_width_of[T]()`), which is W=8 for f64/i64 filters. The lane-id
    vector is always UInt32, so `compress_u32xW[W=8]` is the hot dispatch
    for those filters. A W=16-only gate would send them to
    `_scalar_compress`, which lowers to the 56-kshiftrb cliff.
    """
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.uint32, 8],
    ](src, mask, passthrough)


@always_inline
def _avx512_compress_q_x8(
    src: SIMD[DType.int64, 8],
    mask: SIMD[DType.bool, 8],
    passthrough: SIMD[DType.int64, 8],
) -> SIMD[DType.int64, 8]:
    """AVX-512 W=8 Int64 mask-driven compress. x86_64 ONLY.
    Lowers to `vpcompressq zmm0{k1}{z}, zmm0` on Skylake-X.
    """
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.int64, 8],
    ](src, mask, passthrough)


@always_inline
def _avx512_compress_pd_x8(
    src: SIMD[DType.float64, 8],
    mask: SIMD[DType.bool, 8],
    passthrough: SIMD[DType.float64, 8],
) -> SIMD[DType.float64, 8]:
    """AVX-512 W=8 Float64 mask-driven compress. x86_64 ONLY.
    Lowers to `vcompresspd zmm0{k1}{z}, zmm0` on Skylake-X.
    """
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.float64, 8],
    ](src, mask, passthrough)


# =============================================================================
# Public API — comptime-dispatched primitives.
# =============================================================================
#
# Three primitives, one per (T, W=native_avx512_width) shape:
#
#   compress_u32xW: SIMD[Bool, W] × SIMD[UInt32, W] -> CompressResult[UInt32, W]
#   compress_f64xW: SIMD[Bool, W] × SIMD[Float64, W] -> CompressResult[Float64, W]
#   compress_i64xW: SIMD[Bool, W] × SIMD[Int64, W] -> CompressResult[Int64, W]
#
# W is INFERRED from the input SIMD types (parametric); on each call site
# Mojo derives W from the caller's `simd_width_of[T]()` choice. The
# AVX-512 intrinsic fires only when W matches the AVX-512 register
# width (16 for u32, 8 for f64/i64). All other widths fall through to
# the scalar-scatter helper, which is correct for any W.
# =============================================================================


@always_inline
def compress_u32xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.uint32, W],
) -> CompressResult[DType.uint32, W]:
    """Mask-driven compact for UInt32 lanes. Selection-vector emission shape.

    Use case: in a filter / comparison kernel, after building a SIMD bool
    mask over an input lane chunk, emit the surviving INPUT-RELATIVE
    lane indices into a selection-vector buffer:

        var lanes = SIMD[DType.uint32, W](0,1,2,...,W-1) + UInt32(base_i)
        var r = compress_u32xW(mask, lanes)
        memcpy(out_sel + count, &r.compacted, Int(r.count) * 4)
        count += Int(r.count)

    x86 AVX-512 (W=16): single `vpcompressd zmm0{k1}{z}, zmm0` (one cycle on
    Skylake-X). Trailing lanes are zero.
    x86 AVX-512 (W=8): single `vpcompressd ymm0{k1}{z}, ymm0` (ymm half-width
    form; same instruction family, 8-lane register). Required for
    `_emit_lane_writes[W=8]` in sel_kernels.mojo when called from f64/i64
    column filter shapes.
    NEON / AVX2 / scalar: comptime-unrolled lane scatter.
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16 and W == 16:
        var pop = _popcount_mask(mask)
        var pt = SIMD[DType.uint32, 16](0)
        var compacted = _avx512_compress_d_x16(
            rebind[SIMD[DType.uint32, 16]](vec),
            rebind[SIMD[DType.bool, 16]](mask),
            pt,
        )
        return CompressResult[DType.uint32, W](
            compacted=rebind[SIMD[DType.uint32, W]](compacted),
            count=pop,
        )
    elif CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16 and W == 8:
        # AVX-512 ymm half-width path: vpcompressd ymm0{k1}{z}, ymm0.
        # The platform's native u32 width is 16 (zmm), but EVC accepts
        # arbitrary <N x i32> widths and LLVM emits the ymm-form
        # vpcompressd for N=8. This arm is load-bearing for sel_kernels
        # f64/i64-column filter shapes — see _avx512_compress_d_x8 docstring.
        var pop = _popcount_mask(mask)
        var pt = SIMD[DType.uint32, 8](0)
        var compacted = _avx512_compress_d_x8(
            rebind[SIMD[DType.uint32, 8]](vec),
            rebind[SIMD[DType.bool, 8]](mask),
            pt,
        )
        return CompressResult[DType.uint32, W](
            compacted=rebind[SIMD[DType.uint32, W]](compacted),
            count=pop,
        )
    else:
        return _scalar_compress[DType.uint32, W](mask, vec)


@always_inline
def compress_f64xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.float64, W],
) -> CompressResult[DType.float64, W]:
    """Mask-driven compact for Float64 lanes.

    x86 AVX-512 (W=8): single `vcompresspd` instruction.
    NEON / AVX2 / scalar: comptime-unrolled lane scatter.
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.float64]() == 8 and W == 8:
        var pop = _popcount_mask(mask)
        var pt = SIMD[DType.float64, 8](0)
        var compacted = _avx512_compress_pd_x8(
            rebind[SIMD[DType.float64, 8]](vec),
            rebind[SIMD[DType.bool, 8]](mask),
            pt,
        )
        return CompressResult[DType.float64, W](
            compacted=rebind[SIMD[DType.float64, W]](compacted),
            count=pop,
        )
    else:
        return _scalar_compress[DType.float64, W](mask, vec)


@always_inline
def compress_i64xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    vec: SIMD[DType.int64, W],
) -> CompressResult[DType.int64, W]:
    """Mask-driven compact for Int64 lanes.

    x86 AVX-512 (W=8): single `vpcompressq` instruction (LLVM intrinsic
    name `llvm.x86.avx512.mask.compress.q.512` covers both signed and
    unsigned 64-bit integers — Mojo's signed Int64 maps to LLVM `i64`
    same as unsigned).
    NEON / AVX2 / scalar: comptime-unrolled lane scatter.
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.int64]() == 8 and W == 8:
        var pop = _popcount_mask(mask)
        var pt = SIMD[DType.int64, 8](0)
        var compacted = _avx512_compress_q_x8(
            rebind[SIMD[DType.int64, 8]](vec),
            rebind[SIMD[DType.bool, 8]](mask),
            pt,
        )
        return CompressResult[DType.int64, W](
            compacted=rebind[SIMD[DType.int64, W]](compacted),
            count=pop,
        )
    else:
        return _scalar_compress[DType.int64, W](mask, vec)
