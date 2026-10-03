# =============================================================================
# byte_mask_ops.mojo — bitwise ops on byte-masks (0xFF/0x00 lane shape).
# =============================================================================
#
# Highway category: Logical/Bitwise (And / Or / Xor / AndNot).
#
# A "byte mask" is a `SIMD[uint8, W]` where each lane is 0xFF (set) or 0x00
# (unset).  This is the canonical output shape of a `_byte_eq_*` comparison
# on NEON (single `cmeq.16b`); the same shape is what `movemask` consumes.
# Highway exposes these as `And` / `Or` / `Xor` / `AndNot` on the
# `Mask<T>` type — for byte-class scan we work in the 8-bit-per-lane
# byte-mask shape directly (the bitmask compression to UInt16/32/64 is
# the `movemask_*` family one level up).
#
# Each function is ~1 SIMD instruction on every supported target:
#   - x86_64: `vandnq.16b` for AndNot, `vorq` / `vandq` / `veorq` for the
#             rest (AVX2 widths are equivalent ymm-extensions).
#   - aarch64: `and.16b` / `orr.16b` / `eor.16b` / `bic.16b` (AndNot;
#             "BIt-Clear").
#
# PUBLIC API (Highway "Logical/Bitwise" category):
#   * `bytemask_and[W]` / `bytemask_or[W]` / `bytemask_xor[W]` /
#     `bytemask_andnot[W]` — parametric on lane count W (16 / 32 / 64).
#
# Per-DType note: byte masks are uint8-shape; the parametric W absorbs the
# AVX2 32-lane and AVX-512 BW 64-lane widenings via Mojo's native SIMD
# parametricity — no per-W intrinsic dispatch is needed for boolean-bitwise
# ops (LLVM already lowers `SIMD[uint8, 32] & SIMD[uint8, 32]` to a single
# `vpand` ymm instruction; same for arm64 / Apple Silicon NEON).
# =============================================================================

from std.sys.info import simd_width_of


# =============================================================================
# Public API — bytemask_and / _or / _xor / _andnot
# =============================================================================

@always_inline
def bytemask_and[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.uint8, W]:
    """Lane-parallel bitwise AND on two byte-masks (each lane 0xFF or 0x00).

    Result lane k = `a[k] & b[k]`.  For 0xFF/0x00 inputs this is the
    Highway `And` operation on `Mask<T>`.

    Lowers to a single `and.16b` (NEON) / `vpand` (AVX2/AVX-512 BW) per
    register-width chunk.  The Mojo SIMD `&` operator handles ymm/zmm
    widths natively when `W` matches `simd_width_of[uint8]()` on the
    target architecture; smaller widths use the smaller register form.
    """
    return a & b


@always_inline
def bytemask_or[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.uint8, W]:
    """Lane-parallel bitwise OR on two byte-masks.

    Result lane k = `a[k] | b[k]`.  Highway `Or` on `Mask<T>`.

    Single `orr.16b` (NEON) / `vpor` (AVX2/AVX-512 BW).

    """
    return a | b


@always_inline
def bytemask_xor[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.uint8, W]:
    """Lane-parallel bitwise XOR on two byte-masks.

    Result lane k = `a[k] ^ b[k]`.  Highway `Xor` on `Mask<T>`.

    Single `eor.16b` (NEON) / `vpxor` (AVX2/AVX-512 BW).
    """
    return a ^ b


@always_inline
def bytemask_andnot[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.uint8, W]:
    """Lane-parallel bitwise AND-NOT on two byte-masks.

    Result lane k = `a[k] & ~b[k]` — i.e. "lanes set in a but NOT in b".

    Highway `AndNot(a, b)` semantics.  Single `bic.16b` (NEON, "BIt
    Clear" — note: NEON `bic` is `Vd = Vn AND NOT Vm` matching the
    Highway argument order) / `vpandn` (AVX2/AVX-512 BW; note Intel
    operand order is reversed, but the wrapper above absorbs that).

    Common use in byte-class scan: `mask & ~escaped_mask` to filter out
    bytes inside an escape-quoted region.
    """
    # `~b` is bitwise-not on SIMD[uint8, W] — lowers to `mvn.16b` on
    # NEON / `vpxor` (with all-ones) on x86. Then `a & ~b` is one more
    # `and.16b` / `vpand`. Some LLVM versions fuse this pair into `bic`
    # / `vpandn` on the target; both are 1-cycle equivalents to the
    # Highway primitive.
    return a & ~b


# =============================================================================
# Bit-bucket / nibble-mask helpers — used by byte_find_any_of + nibble-LUT
# byte-class scans (Highway TableLookupBytes + AndNot composition).
# =============================================================================

@always_inline
def bytemask_not[W: Int](
    a: SIMD[DType.uint8, W]
) -> SIMD[DType.uint8, W]:
    """Lane-parallel bitwise NOT on a byte-mask.

    Result lane k = `~a[k]`.  For 0xFF/0x00 inputs this flips set-ness
    of every lane.  Highway `Not(mask)`.

    Single `mvn.16b` (NEON) / `vpternlogd zmm, 0x55` (AVX-512); on AVX2
    LLVM lowers to a constant load + `vpxor`.
    """
    return ~a


@always_inline
def bytemask_is_zero[W: Int](a: SIMD[DType.uint8, W]) -> Bool:
    """Returns True iff every lane of `a` is 0x00 (i.e. mask is empty).

    Highway `AllFalse(mask)`.  Lowers to a horizontal-or reduction
    + compare-zero: `addv` + `cmp` on NEON, `vptestnmb` on AVX-512 BW,
    `vpor` + `vmovmskb` + `cmp` on AVX2.
    """
    return a.reduce_or() == UInt8(0)


@always_inline
def bytemask_any_set[W: Int](a: SIMD[DType.uint8, W]) -> Bool:
    """Returns True iff at least one lane of `a` is non-zero.

    Highway `AnyTrue(mask)`.  Inverse of `bytemask_is_zero`.
    """
    return a.reduce_or() != UInt8(0)
