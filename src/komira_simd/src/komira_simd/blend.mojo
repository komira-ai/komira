# =============================================================================
# blend.mojo — SIMD mask-driven per-lane blend (bitwise select) primitives.
# =============================================================================
#
# PERF-CRITICAL. The mask-driven blend pattern
#
#     out[k] = true_v[k] if mask[k] else false_v[k]    for k in 0..W-1
#
# is the inner shape of every CASE-expression fast path, every
# AdaptiveFilter explore-arm result-merge, every null-default coercion in
# the Arrow validity scan, and every format-driven defaulting path (e.g.
# `JsonCompatible.read_field` with default-value substitution under a
# presence mask). It is also load-bearing for the typed-expression fast
# paths where a SIMD compare result needs to be merged with a scalar
# fallback under a per-lane bool mask.
#
# Architecture lowering:
#   * ARM64 NEON: stdlib `SIMD[Bool, W].select(true_v, false_v)` lowers
#     to `bsl.16b` (bitwise select on byte-mask): a 3-instruction
#     bool-byte → SIMD-lane-mask widening + ONE `bsl.16b`.
#   * x86 AVX-512: stdlib `.select()` lowers via `llvm.select <N x i1>` +
#     LLVM AVX-512 codegen pattern matcher. The expected lowering is the
#     native AVX-512 blend family (`vblendmps` / `vpblendmd` /
#     `vpblendmq` / `vblendmpd`). If a target emits a scalar fallback
#     instead, swap each wrapper body for a hand-staged
#     `llvm.x86.avx512.mask.blend.{ps,pd,d,q}.512` intrinsic call — same
#     recipe as `compress.mojo` / `gather.mojo`. The mask-i1 family of
#     AVX-512 intrinsics is accepted by Mojo's LLVM overload matcher
#     (gather works because of the `<N x i1>` mask shape).
#   * x86 AVX2 / scalar: stdlib `.select()` lowers via the same
#     `llvm.select <N x i1>` path; on AVX2 emits `vblendvps` /
#     `vblendvpd` / `vpblendvb`, on scalar emits per-lane `csel` /
#     `cmov`.
#
# All paths go through the SAME stdlib `SIMD[Bool, W].select()` call —
# Mojo + LLVM pick the right instruction per target. No
# `comptime if CompilationTarget` arch branch is needed at the wrapper
# level.
#
# Encapsulation: this module's public API is pure SIMD-value-in,
# SIMD-value-out (per-lane). NO `UnsafePointer`, no `Span`, no buffer
# mutation.
#
# Mojo gotchas:
#   * `SIMD[Bool, W].select(true_v, false_v)`: the receiver is the MASK
#     (the bool SIMD), and the args are the per-lane source vectors.
#     Lane k of result is `true_v[k]` when `mask[k]` is True, else
#     `false_v[k]`.
#   * `SIMD[Bool, W].cast[uint8]()` is a no-op reinterpret (bool is 1 byte
#     per lane). This is a property used by the downstream `bsl.16b`
#     lowering — the bool byte gets sign-extended across the SIMD-lane
#     width via `ushll + shl + cmlt` on NEON, then `bsl.16b` does the
#     bitwise blend.
#   * `simd_width_of[T]()` is honest on every target — see popcount.mojo
#     §"Mojo gotchas" for the per-target width table.
#
# Codegen is checked with `@no_inline` wrappers over random inputs, which
# force the optimizer to emit the real lowering for inspection.
# =============================================================================


# =============================================================================
# Per-DType public blend primitives.
# =============================================================================
#
# Five public wrappers, one per (T, W) family:
#
#   blend_u32xW : SIMD[Bool, W] × SIMD[UInt32,  W] × SIMD[UInt32,  W] -> SIMD[UInt32,  W]
#   blend_u64xW : SIMD[Bool, W] × SIMD[UInt64,  W] × SIMD[UInt64,  W] -> SIMD[UInt64,  W]
#   blend_i64xW : SIMD[Bool, W] × SIMD[Int64,   W] × SIMD[Int64,   W] -> SIMD[Int64,   W]
#   blend_f32xW : SIMD[Bool, W] × SIMD[Float32, W] × SIMD[Float32, W] -> SIMD[Float32, W]
#   blend_f64xW : SIMD[Bool, W] × SIMD[Float64, W] × SIMD[Float64, W] -> SIMD[Float64, W]
#
# Semantics: lane k of result is `true_v[k]` when `mask[k]` is True,
# else `false_v[k]`. This matches the stdlib `SIMD.select()` semantics
# and is the canonical SIMD-blend operation (NEON `bsl`, AVX-512 `vblendm*`).
#
# W is INFERRED from the input SIMD types (parametric); on each call site
# Mojo derives W from the caller's `simd_width_of[T]()` choice. The
# stdlib lowering automatically selects the native instruction per
# target architecture and lane width.
# =============================================================================


@always_inline
def blend_u32xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.uint32, W],
    false_v: SIMD[DType.uint32, W],
) -> SIMD[DType.uint32, W]:
    """Per-lane mask-driven blend for UInt32 lanes.

    Lane k of result is `true_v[k]` when `mask[k]` is True, else `false_v[k]`.

    ARM64 NEON (W=4): `ushll.4s + shl.4s #0x1f + cmlt.4s + bsl.16b` —
    bool-byte widened to i32 lane-mask + single `bsl.16b` bitwise select.
    x86 AVX-512 (W=16): expected `vpblendmd zmm0{k1}, zmm1, zmm2`.
    x86 AVX2 (W=8): `vpblendvb`. Scalar (W=1): `csel`/`cmov`.

    Use case: CASE-expression fast path where a SIMD-compare result selects
    between two pre-computed result vectors:

        var keep = (col_vec > threshold)              # SIMD[Bool, W]
        var case_result = blend_u32xW(keep, then_v, else_v)
    """
    return mask.select(true_v, false_v)


@always_inline
def blend_u64xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.uint64, W],
    false_v: SIMD[DType.uint64, W],
) -> SIMD[DType.uint64, W]:
    """Per-lane mask-driven blend for UInt64 lanes.

    ARM64 NEON (W=2): `ushll.2d + shl.2d #0x3f + cmlt.2d + bsl.16b`.
    x86 AVX-512 (W=8): expected `vpblendmq zmm0{k1}, zmm1, zmm2`.
    """
    return mask.select(true_v, false_v)


@always_inline
def blend_i64xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.int64, W],
    false_v: SIMD[DType.int64, W],
) -> SIMD[DType.int64, W]:
    """Per-lane mask-driven blend for Int64 lanes.

    Same instruction as `blend_u64xW` (LLVM signed/unsigned 64-bit blend
    is bit-identical at the SIMD lane level). NEON `bsl.16b` and AVX-512
    `vpblendmq` preserve the sign bit verbatim.

    Use case: Int64 column projection with NULL-default substitution where
    the presence-mask blends between the real value and a sentinel like 0
    or INT64_MIN:

        var present = read_validity_simd[Int64, W](off)        # SIMD[Bool, W]
        var sentinels = SIMD[DType.int64, W](Int64.MIN)
        var col = blend_i64xW(present, raw_values, sentinels)
    """
    return mask.select(true_v, false_v)


@always_inline
def blend_f32xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.float32, W],
    false_v: SIMD[DType.float32, W],
) -> SIMD[DType.float32, W]:
    """Per-lane mask-driven blend for Float32 lanes.

    ARM64 NEON (W=4): same `bsl.16b` pattern (bitwise; preserves the f32
    mantissa + exponent + sign bit exactly).
    x86 AVX-512 (W=16): expected `vblendmps zmm0{k1}, zmm1, zmm2`.
    """
    return mask.select(true_v, false_v)


@always_inline
def blend_f64xW[W: SIMDLength, //](
    mask: SIMD[DType.bool, W],
    true_v: SIMD[DType.float64, W],
    false_v: SIMD[DType.float64, W],
) -> SIMD[DType.float64, W]:
    """Per-lane mask-driven blend for Float64 lanes.

    ARM64 NEON (W=2): `ushll.2d + shl.2d #0x3f + cmlt.2d + bsl.16b`.
    x86 AVX-512 (W=8): expected `vblendmpd zmm0{k1}, zmm1, zmm2`.

    Use case: typed-expression fast path where a SIMD comparison decides
    between a fast-path SIMD result and a scalar fallback:

        var fast_result = ...                              # SIMD[Float64, W]
        var slow_result = ...                              # SIMD[Float64, W]
        var use_fast = ...                                 # SIMD[Bool, W]
        var out = blend_f64xW(use_fast, fast_result, slow_result)
    """
    return mask.select(true_v, false_v)
