# =============================================================================
# gather.mojo — SIMD index-driven gather (random-access load) primitives.
# =============================================================================
#
# PERF-CRITICAL. The index-driven gather pattern
#
#     out[k] = base[indices[k]]    for k in 0..W-1
#
# is the inner load of every selection-vector consumer (`*_with_sel` kernel
# family in `eval/sel_kernels.mojo`, expression-executor in
# `expr_executor_mvp.mojo`, partition probe in `engine/runtime`),
# every dictionary-decode loop (Parquet RLE_DICTIONARY scan, Arrow
# DictionaryArray materialize), and every JSON key-scan that walks a
# packed-index buffer. It matters on x86 AVX-512 because the source-level
# `col[sel[k]]` double-List-subscript pattern does NOT pattern-match to
# `vpgatherqq` / `vgatherqpd` / `vpgatherdd` — instead the compiler emits
# one scalar `vmovsd xmm1, QWORD PTR [r8+r11*8]` per lane and an
# `objdump | grep -iE 'vgather|vpgather'` returns ZERO hits.
#
# This module wraps the LLVM AVX-512 gather intrinsics behind a comptime
# dispatch so callers can write
#
#     var values = gather_f64xW(col_span, sel_chunk)     # 1 vgatherqpd on AVX-512
#     var keep   = values > threshold
#     var r      = compress_f64xW(keep, values)
#     sink.append(r.compacted, Int(r.count))
#
# and ship the same source to every target: x86 AVX-512 takes the
# single-instruction branch below, every other target takes the scalar
# fallback (one load per lane).
#
# Architecture dispatch:
#   * x86 + simd_width_of[T]() == 8 (f64/i64/u64) → `llvm.x86.avx512.mask.gather.qpd.512`
#                                                    or `...qpq.512`.
#   * x86 + simd_width_of[T]() == 16 (u32)        → `llvm.x86.avx512.mask.gather.dpi.512`.
#   * Otherwise (NEON, AVX2, scalar)              → `_scalar_gather`: a
#                                                    comptime-unrolled load per
#                                                    lane (W `ldr` on NEON, W
#                                                    scalar loads on AVX2).
#
# Why the fallback is scalar, not the stdlib `UnsafePointer.gather()`: the
# stdlib lowers it to `llvm.masked.gather` and passes the alignment as a
# runtime `Int32` through `llvm_intrinsic`; LLVM needs that operand to be a
# constant, and only the optimizer folds it. At -O0 (coverage builds) the
# compile fails ("llvm.masked.gather alignment must be a constant, got
# runtime value"). The same immarg limit is why
# `byte_class/masked_memory.mojo` is scalar. Nothing is lost on the shipped
# targets: for x86-64-v3 LLVM already scalarized `masked.gather` (the
# release `test_simd_gather` binary disassembles to zero `vgather` /
# `vpgather` with the stdlib call and with this fallback), and NEON has no
# gather instruction.
#
# The AVX-512 branches are selected only when `simd_width_of` reports a
# 512-bit register file, which no pinned target CPU does, so no build here
# compiles them. They pass the `scale` immarg the same way (a runtime
# `Int32`), so they would likely hit the same -O0 refusal; unverified.
#
# Encapsulation (`UnsafePointer` must NEVER cross a module boundary): public
# API accepts a SAFE `Span[T, origin]` view instead of a raw
# `UnsafePointer[T, _]`. The Span is the canonical view type (used
# throughout `arrow/mmap_aligned_buffer.mojo`); callers convert from
# `List[T]` via `Span(my_list)` or from `MmapAlignedBuffer[T]` via
# `buf.get_typed_span[T, o]()`. The raw pointer is extracted via
# `base.unsafe_ptr()` INSIDE this module only — at the LLVM intrinsic
# call site — and never escapes back to callers.
#
# Bounds-check policy: gather is PERF-CRITICAL hot path; bounds-checking
# each index per call would defeat the SIMD parallelism. Caller's contract:
# every `indices[k] < base.size()`. Matches Highway / VOLK / Eve convention.
#
# Mojo gotchas:
#   * `llvm_intrinsic[name, ReturnType](args...)` derives operand types from
#     the wrapper signature. The NAME-level variant suffix (`.qpq.512` etc.)
#     IS part of the canonical LLVM name; only the EXTRA mangled type-suffix
#     (`.v8i64`) is banned. Same shape as the `compress.mojo` AVX-512
#     wrappers.
#   * AVX-512 gather intrinsic operand shapes:
#       - 8-lane qpq / qpd: indices are `<8 x i64>` — cast `SIMD[UInt32, 8]`
#         to `SIMD[Int64, 8]` (one `vpmovzxdq` on AVX-512, cheap).
#       - 16-lane dpi: indices are `<16 x i32>` — cast `SIMD[UInt32, 16]`
#         to `SIMD[Int32, 16]` (bit-preserving, free).
#       - Base pointer: `i8*` — bitcast typed pointer via `.bitcast[UInt8]()`.
#       - Mask: `<W x i1>` SIMD-bool vector — caller passes `SIMD[Bool, W](True)`
#         for unconditional gather; future masked-gather call sites pass a
#         non-trivial mask. Passthrough lanes (where mask is False) take
#         from `src` arg which we set to `SIMD[T, W](0)` for deterministic zero.
#       - Scale: comptime constant `i32` — `8` for 8-byte elements, `4` for 4-byte.
#   * `CompilationTarget.has_avx512()` is not exposed — same gate as
#     `compress.mojo`: `comptime if CompilationTarget.is_x86() and
#     simd_width_of[T]() == AVX512_W`. `simd_width_of` is honest on every
#     target.
#   * `Origin[mut=False]` is the parametric immutable-origin form.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.info import CompilationTarget, simd_width_of
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# Scalar fallback — used on NEON, AVX2, and AVX-512 widths that don't match
# the native intrinsic shape.
# =============================================================================


@always_inline
def _scalar_gather[
    dtype: DType, W: SIMDLength, origin: Origin[mut=False], //,
](
    base: Span[Scalar[dtype], origin],
    indices: SIMD[DType.uint32, W],
) -> SIMD[dtype, W]:
    """Fallback gather: `out[k] = base[indices[k]]`, one load per lane.

    Comptime-unrolled, so it compiles at every optimization level (see the
    module header for why the stdlib `.gather()` does not at -O0). On NEON
    this is W independent `ldr`; on AVX2 it is W scalar loads, which is
    what LLVM produced from `masked.gather` on x86-64-v3 anyway.
    """
    # SAFETY: `base.unsafe_ptr()` aliases the Span and does not leave this
    # function. Every `indices[k] < len(base)` is the caller's contract
    # (module header, bounds-check policy); UInt32 -> Int is a widening.
    var p = base.unsafe_ptr()
    var out = SIMD[dtype, W](0)
    comptime for k in range(Int(W)):
        out[k] = p[Int(indices[k])]
    return out


# =============================================================================
# x86 AVX-512 intrinsic wrappers (only callable on x86; dead on NEON).
# =============================================================================
#
# LLVM intrinsic signatures (per `llvm/test/CodeGen/X86/avx512-gather-scatter-intrin.ll`):
#
#   declare <16 x i32> @llvm.x86.avx512.mask.gather.dpi.512(
#       <16 x i32> %src, i8* %base, <16 x i32> %indices,
#       <16 x i1>  %mask, i32 %scale)
#   declare <8 x i64>  @llvm.x86.avx512.mask.gather.qpq.512(
#       <8 x i64>  %src, i8* %base, <8 x i64>  %indices,
#       <8 x i1>   %mask, i32 %scale)
#   declare <8 x double> @llvm.x86.avx512.mask.gather.qpd.512(
#       <8 x double> %src, i8* %base, <8 x i64>  %indices,
#       <8 x i1>   %mask, i32 %scale)
#
# Naming convention: first letter = index width (`d`=i32, `q`=i64);
# second/third = result type (`pi`=int32, `pq`=int64, `pd`=float64).
#
# Lane k of result holds value loaded from `base[indices[k] * scale]`
# when mask[k] is set; takes from src[k] when mask[k] is clear. We pass
# src = SIMD[T, W](0) so masked-off lanes are zero. Callers passing the
# all-true mask never see passthrough lanes.
# =============================================================================


@always_inline
def _avx512_gather_dpi_x16[origin: Origin[mut=False]](
    src: SIMD[DType.uint32, 16],
    base_ptr: UnsafePointer[UInt32, origin],
    indices: SIMD[DType.int32, 16],
    mask: SIMD[DType.bool, 16],
) -> SIMD[DType.uint32, 16]:
    """AVX-512 W=16 UInt32 index-driven gather. x86_64 ONLY (caller must
    gate via `comptime if CompilationTarget.is_x86() and simd_width_of[uint32]() == 16`).

    Scale = 4 (4-byte UInt32 elements). One `vpgatherdd` instruction
    on Skylake-X (~5 cycle throughput).
    """
    return llvm_intrinsic[
        "llvm.x86.avx512.mask.gather.dpi.512",
        SIMD[DType.uint32, 16],
    ](
        src,
        base_ptr.bitcast[UInt8](),
        indices,
        mask,
        Int32(4),
    )


@always_inline
def _avx512_gather_qpq_x8[origin: Origin[mut=False]](
    src: SIMD[DType.int64, 8],
    base_ptr: UnsafePointer[Int64, origin],
    indices: SIMD[DType.int64, 8],
    mask: SIMD[DType.bool, 8],
) -> SIMD[DType.int64, 8]:
    """AVX-512 W=8 Int64 index-driven gather. x86_64 ONLY.

    Scale = 8 (8-byte Int64 elements). One `vpgatherqq` instruction.
    Same intrinsic handles UInt64 (LLVM doesn't distinguish signed/unsigned
    for gather memory ops).
    """
    return llvm_intrinsic[
        "llvm.x86.avx512.mask.gather.qpq.512",
        SIMD[DType.int64, 8],
    ](
        src,
        base_ptr.bitcast[UInt8](),
        indices,
        mask,
        Int32(8),
    )


@always_inline
def _avx512_gather_qpq_x8_u64[origin: Origin[mut=False]](
    src: SIMD[DType.uint64, 8],
    base_ptr: UnsafePointer[UInt64, origin],
    indices: SIMD[DType.int64, 8],
    mask: SIMD[DType.bool, 8],
) -> SIMD[DType.uint64, 8]:
    """AVX-512 W=8 UInt64 index-driven gather. x86_64 ONLY.

    Same `vpgatherqq` instruction as the i64 form (LLVM signed/unsigned
    are bitwise-identical at the gather instruction level). We declare
    the wrapper with `uint64` types for the public API's type-safety;
    the LLVM intrinsic itself is declared on `<8 x i64>` so we cast
    the src/result through `bitcast[DType.int64]` and back at the
    public-wrapper level.
    """
    return llvm_intrinsic[
        "llvm.x86.avx512.mask.gather.qpq.512",
        SIMD[DType.uint64, 8],
    ](
        src,
        base_ptr.bitcast[UInt8](),
        indices,
        mask,
        Int32(8),
    )


@always_inline
def _avx512_gather_qpd_x8[origin: Origin[mut=False]](
    src: SIMD[DType.float64, 8],
    base_ptr: UnsafePointer[Float64, origin],
    indices: SIMD[DType.int64, 8],
    mask: SIMD[DType.bool, 8],
) -> SIMD[DType.float64, 8]:
    """AVX-512 W=8 Float64 index-driven gather. x86_64 ONLY.

    Scale = 8 (8-byte Float64 elements). One `vgatherqpd` instruction.
    """
    return llvm_intrinsic[
        "llvm.x86.avx512.mask.gather.qpd.512",
        SIMD[DType.float64, 8],
    ](
        src,
        base_ptr.bitcast[UInt8](),
        indices,
        mask,
        Int32(8),
    )


# =============================================================================
# Public API — comptime-dispatched primitives.
# =============================================================================
#
# Four primitives, one per (T, W=native_avx512_width) shape:
#
#   gather_u32xW: Span[UInt32, _]  × SIMD[UInt32, W] -> SIMD[UInt32, W]
#   gather_u64xW: Span[UInt64, _]  × SIMD[UInt32, W] -> SIMD[UInt64, W]
#   gather_i64xW: Span[Int64, _]   × SIMD[UInt32, W] -> SIMD[Int64, W]
#   gather_f64xW: Span[Float64, _] × SIMD[UInt32, W] -> SIMD[Float64, W]
#
# W is INFERRED from the input SIMD types (parametric); on each call site
# Mojo derives W from the caller's `simd_width_of[T]()` choice. The
# AVX-512 intrinsic fires only when W matches the AVX-512 register
# width (16 for u32, 8 for i64/u64/f64). All other widths fall through
# to `_scalar_gather`, which is correct for any W.
#
# Encapsulation: public API is `Span[T, origin]` (safe view) — NO
# `UnsafePointer` crosses the module boundary.
# =============================================================================


@always_inline
def gather_u32xW[
    W: SIMDLength, origin: Origin[mut=False], //,
](
    base: Span[UInt32, origin],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.uint32, W]:
    """Index-driven gather for UInt32 lanes. Selection-vector consumer shape.

    Use case: in a `*_with_sel` kernel, after building a selection-vector
    chunk of survivor indices, load the corresponding column values:

        var values = gather_u32xW(col_span, sel_chunk)
        var keep = values >= threshold
        var r = compress_u32xW(keep, values)
        sink.append(r.compacted, Int(r.count))

    x86 AVX-512 (W=16): single `vpgatherdd` instruction (~5 cycle thpt
    on Skylake-X).
    NEON / AVX2 / scalar: `_scalar_gather`, one load per lane.

    Caller's contract: every `indices[k] < base.size()` (no bounds check).
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16 and W == 16:
        # SAFETY: `base.unsafe_ptr()` aliases the Span; pointer arithmetic
        # stays inside this module per encapsulation rule.
        var p = base.unsafe_ptr()
        var src = SIMD[DType.uint32, 16](0)
        var mask = SIMD[DType.bool, 16](fill=True)
        # AVX-512 dpi.512 wants <16 x i32> indices; UInt32 -> Int32 is
        # bit-preserving (free at codegen).
        var idx_i32 = rebind[SIMD[DType.int32, 16]](
            indices.cast[DType.int32]()
        )
        var result = _avx512_gather_dpi_x16[origin](
            src,
            p,
            idx_i32,
            mask,
        )
        return rebind[SIMD[DType.uint32, W]](result)
    else:
        return _scalar_gather(base, indices)


@always_inline
def gather_u64xW[
    W: SIMDLength, origin: Origin[mut=False], //,
](
    base: Span[UInt64, origin],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.uint64, W]:
    """Index-driven gather for UInt64 lanes.

    x86 AVX-512 (W=8): single `vpgatherqq` instruction.
    NEON / AVX2 / scalar: `_scalar_gather`, one load per lane.

    Caller's contract: every `indices[k] < base.size()` (no bounds check).
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.uint64]() == 8 and W == 8:
        var p = base.unsafe_ptr()
        var src = SIMD[DType.uint64, 8](0)
        var mask = SIMD[DType.bool, 8](fill=True)
        # AVX-512 qpq.512 wants <8 x i64> indices; widen UInt32 -> Int64
        # (one `vpmovzxdq` on AVX-512).
        var idx_i64 = rebind[SIMD[DType.int64, 8]](
            indices.cast[DType.int64]()
        )
        var result = _avx512_gather_qpq_x8_u64[origin](
            src,
            p,
            idx_i64,
            mask,
        )
        return rebind[SIMD[DType.uint64, W]](result)
    else:
        return _scalar_gather(base, indices)


@always_inline
def gather_i64xW[
    W: SIMDLength, origin: Origin[mut=False], //,
](
    base: Span[Int64, origin],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.int64, W]:
    """Index-driven gather for Int64 lanes.

    x86 AVX-512 (W=8): single `vpgatherqq` instruction (LLVM intrinsic
    `mask.gather.qpq.512` covers both signed and unsigned 64-bit integers).
    NEON / AVX2 / scalar: `_scalar_gather`, one load per lane.

    Caller's contract: every `indices[k] < base.size()` (no bounds check).
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.int64]() == 8 and W == 8:
        var p = base.unsafe_ptr()
        var src = SIMD[DType.int64, 8](0)
        var mask = SIMD[DType.bool, 8](fill=True)
        var idx_i64 = rebind[SIMD[DType.int64, 8]](
            indices.cast[DType.int64]()
        )
        var result = _avx512_gather_qpq_x8[origin](
            src,
            p,
            idx_i64,
            mask,
        )
        return rebind[SIMD[DType.int64, W]](result)
    else:
        return _scalar_gather(base, indices)


@always_inline
def gather_f64xW[
    W: SIMDLength, origin: Origin[mut=False], //,
](
    base: Span[Float64, origin],
    indices: SIMD[DType.uint32, W],
) -> SIMD[DType.float64, W]:
    """Index-driven gather for Float64 lanes.

    x86 AVX-512 (W=8): single `vgatherqpd` instruction.
    NEON / AVX2 / scalar: `_scalar_gather`, one load per lane.

    Caller's contract: every `indices[k] < base.size()` (no bounds check).
    """
    comptime if CompilationTarget.is_x86() and simd_width_of[DType.float64]() == 8 and W == 8:
        var p = base.unsafe_ptr()
        var src = SIMD[DType.float64, 8](0.0)
        var mask = SIMD[DType.bool, 8](fill=True)
        var idx_i64 = rebind[SIMD[DType.int64, 8]](
            indices.cast[DType.int64]()
        )
        var result = _avx512_gather_qpd_x8[origin](
            src,
            p,
            idx_i64,
            mask,
        )
        return rebind[SIMD[DType.float64, W]](result)
    else:
        return _scalar_gather(base, indices)
