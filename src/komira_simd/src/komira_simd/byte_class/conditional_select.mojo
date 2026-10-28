# =============================================================================
# conditional_select.mojo — Highway Conditional Select category.
# =============================================================================
#
# Highway category: Conditional Select.  Per-lane choice between two
# vectors based on a mask vector.
#
# Highway operations:
#   - `IfThenElse(mask, yes, no)` — result lane k = mask[k] ? yes[k] : no[k].
#   - `IfThenElseZero(mask, yes)` — result lane k = mask[k] ? yes[k] : 0.
#   - `IfThenZeroElse(mask, no)`  — result lane k = mask[k] ? 0 : no[k].
#   - `IfNegativeThenElse`        — same but mask is "lane sign bit set".
#
# Mojo native form: `SIMD[bool, W].select(if_true, if_false)`.  This is
# a 1-cycle `bsl.16b` on NEON / `vpblendvb` on AVX2 / `vpternlogd` on
# AVX-512.
#
# Encapsulation: SIMD-in / SIMD-out; no pointers.
# =============================================================================


# =============================================================================
# IfThenElse — full ternary select.
# =============================================================================

@always_inline
def if_then_else[T: DType, W: Int](
    mask: SIMD[DType.bool, W],
    yes: SIMD[T, W],
    no: SIMD[T, W],
) -> SIMD[T, W]:
    """Per-lane: `mask[k] ? yes[k] : no[k]`.  Highway `IfThenElse(mask, yes, no)`.

    NEON: `bsl.16b` (1 cycle).
    AVX2: `vpblendvb` / `vblendvps` / `vblendvpd` (1-2 cycles).
    AVX-512: `vpblendmb {k1} zmm, zmm, zmm` (1 cycle, mask register).
    """
    return mask.select(yes, no)


# =============================================================================
# IfThenElseZero — select between vec and zero.
# =============================================================================

@always_inline
def if_then_else_zero[T: DType, W: Int](
    mask: SIMD[DType.bool, W],
    yes: SIMD[T, W],
) -> SIMD[T, W]:
    """Per-lane: `mask[k] ? yes[k] : 0`.  Highway `IfThenElseZero(mask, yes)`.

    On AVX-512 with mask registers: `vmovdqa32 zmm {k1}{z}, zmm` —
    zero-masking move, single instruction.  On NEON / AVX2: a normal
    `select(yes, zeros)`."""
    return mask.select(yes, SIMD[T, W](0))


# =============================================================================
# IfThenZeroElse — select between zero and vec.
# =============================================================================

@always_inline
def if_then_zero_else[T: DType, W: Int](
    mask: SIMD[DType.bool, W],
    no: SIMD[T, W],
) -> SIMD[T, W]:
    """Per-lane: `mask[k] ? 0 : no[k]`.  Highway `IfThenZeroElse(mask, no)`."""
    return mask.select(SIMD[T, W](0), no)


# =============================================================================
# IfNegativeThenElse — select based on sign bit.
# =============================================================================
#
# For signed integer / float lanes, select based on whether the sign
# bit is set.  Useful for masking out "invalid" entries that are marked
# by negative values (common in tag-encoded streams).

@always_inline
def if_negative_then_else[T: DType, W: Int](
    cond: SIMD[T, W],
    yes: SIMD[T, W],
    no: SIMD[T, W],
) -> SIMD[T, W]:
    """Per-lane: `(cond[k] < 0) ? yes[k] : no[k]`.  Highway
    `IfNegativeThenElse(cond, yes, no)`.

    Equivalent to:
      `mask = (cond < 0)`; `mask.select(yes, no)`.

    Compiles to a sign-bit test + select on every target."""
    var zero_v = SIMD[T, W](0)
    var mask = SIMD.lt(cond, zero_v)
    return mask.select(yes, no)


# =============================================================================
# Byte-mask-driven select (the 0xFF/0x00 byte-mask shape).
# =============================================================================
#
# When the "mask" is already in 0xFF/0x00 byte-mask shape (e.g. coming
# out of `byte_eq_to_bytemask_*`), the Highway-shape select is
# `mask & yes | ~mask & no`.  This is one extra instruction vs the
# bool-mask path (which gets a single `bsl` on NEON), but it avoids
# the mask materialization round-trip.

@always_inline
def byte_mask_select_u8[W: Int](
    byte_mask: SIMD[DType.uint8, W],
    yes: SIMD[DType.uint8, W],
    no: SIMD[DType.uint8, W],
) -> SIMD[DType.uint8, W]:
    """0xFF/0x00 byte-mask driven select: `(byte_mask & yes) | (~byte_mask & no)`.

    Equivalent to `if_then_else(byte_mask == 0xFF, yes, no)` but skips
    the bool materialization."""
    return (byte_mask & yes) | (~byte_mask & no)
