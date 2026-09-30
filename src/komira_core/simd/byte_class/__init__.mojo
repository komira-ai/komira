# =============================================================================
# komira_core.simd.byte_class — Highway-style SIMD byte-class library.
# =============================================================================
#
# A multi-architecture (x86 AVX-512 + ARM NEON + scalar) SIMD primitive
# library patterned after Google Highway's `quick_reference.md` taxonomy,
# sized for the byte-class scan kernels that drive CSV (movemask scan +
# tag-bit extraction + quote-region masks), JSON, and other format- and
# eval-side kernels.
#
# Members:
#
#   1. movemask          — `_byte_eq_u8x16_to_bytemask` + `movemask_to_uint_*`
#                          across W=16/32/64 lanes (NEON, AVX2 and AVX-512
#                          widths).
#   2. byte_mask_ops     — AND / OR / XOR / AndNot on byte-masks
#                          (0xFF/0x00 lanes).
#   3. byte_find_any_of  — find-first-of-N-needles in a 16/32/64-byte chunk
#                          (the CSV byte-class scan primitive).
#   4. bitmask_to_positions — extract 0..N set-bit indices into a small
#                          `List[Int]` via BMI2 PEXT (x86) / NEON LUT (ARM)
#                          / ctz iteration (scalar fallback).
#   5. quote_region_mask — PCLMULQDQ (x86) + PMULL64 (ARM) carry-less
#                          multiply for the simdcsv-style quote-region scan.
#   6. prefix_xor        — comptime-unrolled cumulative XOR (carry-threaded)
#                          over u16/u32/u64.
#   7. table_lookup      — TBL1/TBL2 (ARM) / PSHUFB (x86 SSSE3) / VPSHUFB
#                          (AVX2) wrappers.
#   8. horizontal_reduce — wraps `SIMD.reduce_*` family per Highway category.
#   9. conditional_select— IfThenElse / IfThenElseZero / IfThenZeroElse on
#                          bool-mask + value SIMD.
#  10. compress_expand   — `llvm.experimental.vector.compress` wrappers for
#                          uint8 x 32 + x 64 (the W shapes
#                          `komira_core.simd.compress` does not cover).
#                          `expand` is a SHUFFLE composite (see below).
#  11. broadcast_iota    — `Set` / `Iota` / `Broadcast` constructors.
#  12. type_cast         — PromoteTo / DemoteTo wrappers over `SIMD.cast[]`.
#  13. masked_memory     — `masked_load_*` / `masked_store_*` via a SCALAR
#                          fallback (see below).
#  14. byte_equal        — `bytes_equal(Span, Span)`: are two byte SPANS
#                          equal.  A different kernel from
#                          `comparisons.byte_eq`, which answers the per-LANE
#                          question.  Bulk `simd_width_of[uint8]()` loop plus
#                          ONE overlapping tail block anchored at the END of
#                          the span (overlap, not masking, removes the tail
#                          off-by-one).  Replaces `external_call["memcmp"]
#                          == 0`, which LLVM rewrites to `bcmp`; a toolchain
#                          that links compiler_rt's `bcmp` gets a
#                          byte-at-a-time loop (several instructions per
#                          byte) instead of libc's vectorized one.  x86:
#                          `vpxor` + `vptest`, 4 instructions per 32 bytes.
#                          ARM64: `reduce_max` over the XOR (`eor` + `umaxv`,
#                          the `vmaxvq_u8` idiom) — `vptest` has no NEON
#                          equivalent.
#
# Per-architecture dispatch follows the pattern in
# `komira_core/simd/horizontal_add.mojo` and `compress.mojo`: `comptime if
# CompilationTarget.is_x86()` chooses the x86 path; the `else` arm holds
# the NEON / scalar fallback.  Per-DType coverage spans UInt8/16/32/64 +
# Int8/16/32/64 + Float32/64 per Highway taxonomy.
#
# Encapsulation: every public function below takes SIMD values,
# `Span[T, origin]`, or explicit references with concrete origins.  No
# wildcard origins, no raw pointer arguments in cross-module signatures.
# Internal LLVM intrinsic calls live behind the comptime dispatch only.
#
# Design notes:
#   * `compress_expand`'s expand half is NOT a primitive intrinsic
#     (`llvm.experimental.vector.expand` does NOT exist in LLVM);
#     `expand_via_shuffle_u8x32` is the supported composite.
#   * `masked_memory` uses a scalar fallback because Mojo's
#     `llvm_intrinsic[]` wrapper passes the LLVM `align` parameter as a
#     runtime SSA value but the `llvm.masked.load.*` family requires
#     `align` to be `immarg` (compile-time constant). It can switch to the
#     intrinsic once the wrapper supports immarg promotion.
#
# Sources:
#   - Highway quick reference:
#     https://github.com/google/highway/blob/master/g3doc/quick_reference.md
# =============================================================================
