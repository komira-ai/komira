# =============================================================================
# komira_core.simd — SIMD utility primitives.
# =============================================================================
#
# Reusable SIMD building blocks that fix codegen traps the Mojo stdlib's
# generic SIMD operations fall into on specific lane types / widths /
# architectures. Each module here is a thin wrapper around an LLVM
# intrinsic with a comptime-dispatch fallback for portability.
#
# Members:
#   - horizontal_add: hadd_u8x16 / hadd_widening_u8x16 / hadd_u16x8 /
#     hadd_u32x4. Replaces stdlib `SIMD[uint8/16/32, *].reduce_add()` on
#     ARM64 with the direct NEON intrinsic. On x86_64 falls through to
#     stdlib `.reduce_add()`. The substitution speeds up byte-counting
#     loops such as a JSON key scan.
#   - compress: compress_u32xW / compress_f64xW / compress_i64xW +
#     CompressResult. Mask-driven SIMD compact-and-store for selection-
#     vector emission. On x86 AVX-512 expands to `vpcompressd` (u32x16)
#     / `vcompresspd` (f64x8) / `vpcompressq` (i64x8). On NEON / AVX2 /
#     scalar falls through to a comptime-unrolled scalar scatter. The
#     generic unrolled scatter lowers on AVX-512 to a long `kshiftrb` +
#     test/je/mov chain per chunk with no `vcompresspd`, which is why the
#     explicit intrinsic exists.
#   - gather: gather_u32xW / gather_u64xW / gather_i64xW / gather_f64xW.
#     Index-driven SIMD random-access load for selection-vector consumer
#     kernels (`*_with_sel` family) and JSON key scans.
#     Public API takes `Span[T, origin]` + `SIMD[UInt32, W]` indices
#     (NO raw `UnsafePointer` cross-module per encapsulation rule). On x86
#     AVX-512 expands to `vpgatherdd` (u32x16) / `vpgatherqq` (i64x8 or
#     u64x8) / `vgatherqpd` (f64x8). On NEON / AVX2 / scalar falls through
#     to stdlib `UnsafePointer.gather()` (which on NEON is W independent
#     scalar `ldr`s — no native gather, behavior-equivalent to a scalar
#     loop). The generic path emits no `vpgather*` on AVX-512 (one scalar
#     `vmovsd` per lane), which is why the explicit intrinsic exists.
#   - popcount: popcount_u8xW / popcount_u16xW / popcount_u32xW /
#     popcount_u64xW + popcount_mask. Per-lane and bool-mask population
#     count, routing through stdlib `std.bit.pop_count(SIMD[T, W])` which
#     lowers to NEON `cnt.16b` on ARM64 and `vpopcntb/w/d/q` on AVX-512
#     BITALG. Mask popcount via `mask.cast[uint8]().reduce_add()` for
#     selection-vector cardinality counters (AdaptiveFilter convergence,
#     ExpressionExecutor survivor count). Same lowering as
#     `bitmap.mojo:_simd_popcount_bytes`.
#   - blend: blend_u32xW / blend_u64xW / blend_i64xW / blend_f32xW /
#     blend_f64xW. Per-lane mask-driven blend (bitwise select) — lane k
#     of result is `true_v[k]` when `mask[k]` is True, else
#     `false_v[k]`. Routes through stdlib `SIMD[Bool, W].select(true_v,
#     false_v)` which lowers to NEON `bsl.16b` on ARM64 (3-op
#     bool-to-lane-mask widening + ONE `bsl.16b`) and
#     `vblendm{ps,pd,d,q}` on AVX-512. Consumers: CASE expressions,
#     AdaptiveFilter explore-arm result-merge, NULL-default coercion in the
#     Arrow validity scan, format-driven defaulting.
#   - pattern_copy: pattern_copy_extend. Cyclic byte-pattern extend
#     `out[out_pos+k] = out[out_pos-offset+k]` for k in [0, length).
#     LZ77-family back-reference shape (snappy, lz4, zstd, deflate
#     decompressors). On ARM64 NEON with `offset < 16` emits up to 4 ×
#     `tbl.16b` with comptime cyclic mask `[base+k mod period]`; with
#     `offset >= 16` emits `ld1`/`st1` 16-byte unrolled loop. On x86_64
#     falls through to scalar (an AVX-512 `vpermb` path is not
#     implemented). Byte-identical to a scalar reference copy.
# =============================================================================
