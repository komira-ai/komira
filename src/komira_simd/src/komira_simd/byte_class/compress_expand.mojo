# =============================================================================
# compress_expand.mojo — Highway Compress / Expand (mask-driven gather/scatter).
# =============================================================================
#
# Highway category: Compress / Expand.
#
#   - `Compress(vec, mask)` — gather lanes where mask is set to the LOW
#     part of the result.  Tail lanes hold the passthrough value.
#   - `Expand(vec, mask)`   — scatter packed source lanes to positions
#     where mask is set.
#
# Intrinsic support:
#   - compress u8x32: `llvm.experimental.vector.compress` accepts
#     uint8 × 32 lanes.
#   - compress u8x64: also accepts uint8 × 64 lanes (AVX-512 BW
#     `vpcompressb` lowering).
#   - expand: `llvm.experimental.vector.expand` does NOT exist in the
#     LLVM version Mojo bundles.
#
# So there is no `expand` SIMD primitive. `expand_via_shuffle_u8x32` is a
# COMPOSITE that builds expand semantics from `table_lookup_u8x32`
# (NEON tbl / AVX2 vpshufb) + a per-lane "where should source lane k
# go?" position table.  On AVX-512 BW the natural primitive would be
# `vpexpandb`.
#
# `komira_simd/compress.mojo` covers UInt32/8 + Int64/8 + Float64/8
# widths.  This module adds the UInt8 × 32 and UInt8 × 64 widths that CSV
# needs for byte-class scan compression.
#
# Encapsulation: SIMD-in / SIMD-out; no pointers.
# =============================================================================

from std.sys.info import CompilationTarget, simd_width_of
from std.sys.intrinsics import llvm_intrinsic

from komira_simd.byte_class.bitmask_to_positions import popcount_u32, popcount_u64
from komira_simd.byte_class.movemask import bool_vec_to_uint_u8x32, bool_vec_to_uint_u8x64
from komira_simd.byte_class.table_lookup import table_lookup_u8x32


# =============================================================================
# Public API — Compress (gather lanes where mask is set to low part).
# =============================================================================

@always_inline
def compress_u8x32(
    src: SIMD[DType.uint8, 32],
    mask: SIMD[DType.bool, 32],
    passthrough: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """32-lane mask-driven compress.  Highway `Compress(src, mask)`.

    Result lanes 0..popcount(mask)-1 hold src lanes where mask is set,
    in source order.  Result lanes popcount(mask)..31 hold `passthrough`
    values.

    Lowers via `llvm.experimental.vector.compress`:
      - AVX-512 BW: `vpcompressb` (1 cycle).
      - AVX2 / SSE: LLVM may scalarize to a per-bit `pext`-based loop;
        slower than AVX-512 native but still vectorized in many cases.
      - NEON: LLVM emits a scalar gather loop; for the byte-compress
        case this is ~3-5x slower than vpcompressb but functionally
        correct.

    Compiles and is semantically correct on aarch64 as well.
    """
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.uint8, 32],
    ](src, mask, passthrough)


@always_inline
def compress_u8x64(
    src: SIMD[DType.uint8, 64],
    mask: SIMD[DType.bool, 64],
    passthrough: SIMD[DType.uint8, 64],
) -> SIMD[DType.uint8, 64]:
    """64-lane mask-driven compress (AVX-512 BW shape)."""
    return llvm_intrinsic[
        "llvm.experimental.vector.compress",
        SIMD[DType.uint8, 64],
    ](src, mask, passthrough)


# =============================================================================
# Compress with popcount return — convenience for the typical CSV usage
# pattern where the caller wants both the compressed vector AND the
# number of valid lanes.
# =============================================================================

@always_inline
def compress_with_count_u8x32(
    src: SIMD[DType.uint8, 32],
    mask: SIMD[DType.bool, 32],
    passthrough: SIMD[DType.uint8, 32],
) -> Tuple[SIMD[DType.uint8, 32], Int]:
    """Compress + return (compressed_vec, valid_lane_count).

    Used by the CSV scan: "compact bytes that survived
    the byte-class filter, AND tell me how many" is the canonical
    consumer pattern.
    """
    var compacted = compress_u8x32(src, mask, passthrough)
    var bitmask = bool_vec_to_uint_u8x32(mask)
    var count = popcount_u32(bitmask)
    return Tuple[SIMD[DType.uint8, 32], Int](compacted, count)


@always_inline
def compress_with_count_u8x64(
    src: SIMD[DType.uint8, 64],
    mask: SIMD[DType.bool, 64],
    passthrough: SIMD[DType.uint8, 64],
) -> Tuple[SIMD[DType.uint8, 64], Int]:
    """Compress + return (compressed_vec, valid_lane_count) for 64-lane."""
    var compacted = compress_u8x64(src, mask, passthrough)
    var bitmask = bool_vec_to_uint_u8x64(mask)
    var count = Int(popcount_u64(bitmask))
    return Tuple[SIMD[DType.uint8, 64], Int](compacted, count)


# =============================================================================
# Expand — a SHUFFLE composite (no expand intrinsic).
# =============================================================================
#
# `llvm.experimental.vector.expand` does NOT exist in LLVM.  We
# provide a SHUFFLE-based composite that produces equivalent semantics.
#
# Algorithm: given `src` (packed source) and `mask` (positions to
# scatter into), build a per-lane "fetch index" vector via prefix-sum
# of the mask.  For lane k where mask[k] is set, fetch index = (number
# of preceding set bits).  Then `table_lookup(src, fetch_indices)`
# produces the expanded vector at those positions.  For unset positions
# the output is `passthrough[k]`.
#
# This is ~5-8 cycles on AVX2 (a prefix-sum is ~3 ops, then `vpshufb`
# is 1), and similar on NEON (`tbl` + a few ops for the prefix-sum).

@always_inline
def expand_via_shuffle_u8x32(
    src: SIMD[DType.uint8, 32],
    mask: SIMD[DType.bool, 32],
    passthrough: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """32-lane mask-driven expand via SHUFFLE composite.  Highway
    `Expand(src, mask)` semantics.

    `llvm.experimental.vector.expand` does NOT exist in LLVM, so this
    composite achieves
    equivalent semantics via per-lane prefix-sum-of-mask → fetch index
    → `table_lookup_u8x32`.

    Algorithm (per Highway docs `Expand`):
      For lane k where mask[k] is set: out[k] = src[number_of_set_bits_below_k]
      For lane k where mask[k] is unset: out[k] = passthrough[k]

    The fetch-index vector is built via a per-lane prefix-sum of the
    bool mask.  On AVX2 this is ~5 cycles (vpsadbw + vpshufb chain);
    on NEON ~6 cycles via vec-sum + tbl.

    This composite can be swapped for the AVX-512 BW `vpexpandb`
    intrinsic once LLVM exposes it.
    """
    # Per-lane fetch index: count of set bits in mask[0..k-1].
    var mask_u8 = mask.cast[DType.uint8]()  # 0 / 1 per lane
    var fetch_idx = SIMD[DType.uint8, 32](0)
    var running: UInt8 = 0
    comptime for k in range(32):
        fetch_idx[k] = running
        running = running + mask_u8[k]
    # Lookup src by fetch_idx; lanes where mask[k] == 0 yield indeterminate
    # but harmless values (they get overwritten by passthrough in select).
    var fetched = table_lookup_u8x32(src, fetch_idx)
    # Blend: where mask is set, use fetched; else passthrough.
    return mask.select(fetched, passthrough)
