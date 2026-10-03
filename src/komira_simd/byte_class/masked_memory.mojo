# =============================================================================
# masked_memory.mojo — Highway MaskedLoad / MaskedStore (scalar fallback).
# =============================================================================
#
# Highway category: Memory operations.
#
#   - `MaskedLoad(mask, ptr, fallback)`  — load lanes from `ptr`; for
#     lanes where mask is False, the load is SUPPRESSED (no fault) and
#     `fallback[k]` is used.
#   - `MaskedStore(mask, vec, ptr)`      — store lanes to `ptr`; for
#     lanes where mask is False, the store is SUPPRESSED.
#
# CSV use: the "tail of file" handler.  When the
# file size is not a multiple of the SIMD chunk width (32 / 64 bytes),
# the last partial chunk must be loaded WITHOUT touching past-end
# memory (which may be on an unmapped page → SIGBUS).  MaskedLoad with
# a "lanes 0..N-1 valid" mask handles this correctly.
#
# WHY SCALAR:
# The LLVM `llvm.masked.load.v32i8.p0` / `llvm.masked.store.v32i8.p0`
# require the `align` parameter to be `immarg` (compile-time constant
# stored in the MLIR op attribute list).  Mojo's
# `llvm_intrinsic[]` wrapper passes `Int32(1)` as a runtime SSA value,
# so the call signature does NOT match any LLVM overload — "call
# intrinsic signature ... does not match any of the overloads".
#
# WORKAROUND: scalar fallback.  Per-lane test of mask
# + conditional load/store.  Always correct; expected ~3-5x slower
# than the SIMD masked intrinsic on AVX-512 BW, but the use case is
# "last 0..31 bytes per CSV file" — negligible amortized cost over a
# multi-MB file.
#
# Once the wrapper supports immarg promotion, the scalar fallback can be
# swapped for the SIMD masked intrinsic.
#
# Encapsulation: uses `Span[UInt8, origin]` rather than raw
# UnsafePointer to keep the public API origin-clean.
# =============================================================================



# =============================================================================
# Public API — scalar fallback.
# =============================================================================

@always_inline
def masked_load_u8x32[o: Origin[mut=False]](
    src: Span[UInt8, o],
    mask: SIMD[DType.bool, 32],
    passthrough: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """Scalar masked load: per-lane test mask, load from `src[k]` if
    True, else use `passthrough[k]`.

    Highway `MaskedLoad(mask, ptr, fallback)` semantics.

    Scalar fallback because Mojo's `llvm_intrinsic[]` wrapper cannot
    satisfy LLVM's `align: immarg` requirement for
    `llvm.masked.load.v32i8.p0`.

    SAFETY: caller guarantees that for every lane k where mask[k] is
    True, `src[k]` is a valid readable byte (i.e. k < len(src)).
    The wrapper does NOT bounds-check — that's the caller's contract.
    Use `passthrough` for lanes outside the valid range.
    """
    var out = passthrough
    comptime for k in range(32):
        if mask[k]:
            out[k] = src[k]
    return out


@always_inline
def masked_load_u8x64[o: Origin[mut=False]](
    src: Span[UInt8, o],
    mask: SIMD[DType.bool, 64],
    passthrough: SIMD[DType.uint8, 64],
) -> SIMD[DType.uint8, 64]:
    """Scalar masked load, 64-lane (see masked_load_u8x32)."""
    var out = passthrough
    comptime for k in range(64):
        if mask[k]:
            out[k] = src[k]
    return out


@always_inline
def masked_store_u8x32[o: Origin[mut=True]](
    mut dst: Span[UInt8, o],
    vec: SIMD[DType.uint8, 32],
    mask: SIMD[DType.bool, 32],
) -> None:
    """Scalar masked store: per-lane test mask, store `vec[k]` to
    `dst[k]` if True, else leave `dst[k]` unchanged.

    Highway `MaskedStore(mask, vec, ptr)` semantics.

    SAFETY: caller guarantees that for every lane k where mask[k] is
    True, `dst[k]` is a valid writable byte (i.e. k < len(dst)).
    """
    comptime for k in range(32):
        if mask[k]:
            dst[k] = vec[k]


@always_inline
def masked_store_u8x64[o: Origin[mut=True]](
    mut dst: Span[UInt8, o],
    vec: SIMD[DType.uint8, 64],
    mask: SIMD[DType.bool, 64],
) -> None:
    """Scalar masked store, 64-lane (see masked_store_u8x32)."""
    comptime for k in range(64):
        if mask[k]:
            dst[k] = vec[k]


# =============================================================================
# "Tail mask" helpers — common CSV use case constructor.
# =============================================================================
#
# For the "last partial chunk" of a CSV file, the caller knows the
# number of remaining valid bytes (1..31 typically).  The tail-mask
# helpers construct the bool mask "lanes 0..n-1 set, lanes n..W-1 unset".

@always_inline
def tail_mask_u8x32(n_valid: Int) -> SIMD[DType.bool, 32]:
    """Construct a 32-lane bool mask where lanes 0..n_valid-1 are True
    and lanes n_valid..31 are False.

    Used for the CSV "last partial chunk" masked load.  `n_valid` is
    typically 1..31 (a full chunk uses the regular non-masked load);
    `n_valid = 0` produces an all-False mask, `n_valid >= 32` produces
    an all-True mask.
    """
    var m = SIMD[DType.bool, 32](fill=False)
    # Note: the comptime-for here loops over the 32 lane positions, but
    # we test against a RUNTIME `n_valid`.  Each lane test is one
    # `compare + csel` on NEON — total ~64 cycles, but this runs only
    # once per file's tail, so amortized cost is negligible.
    for k in range(32):
        if k < n_valid:
            m[k] = True
    return m


@always_inline
def tail_mask_u8x64(n_valid: Int) -> SIMD[DType.bool, 64]:
    """Construct a 64-lane bool mask where lanes 0..n_valid-1 are True."""
    var m = SIMD[DType.bool, 64](fill=False)
    for k in range(64):
        if k < n_valid:
            m[k] = True
    return m
