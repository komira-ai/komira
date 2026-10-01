# =============================================================================
# Kleene 3VL helpers — SIMD chunk + byte-bitmap variants
# =============================================================================
#
# Kleene three-valued logic (3VL) propagation for the unified-engine
# filter path. Used by:
#   - RuntimeExprBool.run_filter_self (the runtime tree walker — LIVE)
#   - The whole-column comparison variants + the null-policy seam
#     (`comparison_kleene.mojo` — the companion file. This file
#     owns the per-SIMD-chunk + per-BYTE Kleene primitives; the
#     companion owns the bitmap/whole-column comparison surface and
#     the runtime `NullPolicy` seam, built on the SAME 3VL rule.)
#   - project / agg kernels that need validity threading
#
# The Kleene truth table — load-bearing:
#   FALSE AND NULL = FALSE      (left short-circuits, NULL absorbed)
#   TRUE  AND NULL = NULL
#   NULL  AND NULL = NULL
#   TRUE  OR  NULL = TRUE       (left short-circuits, NULL absorbed)
#   FALSE OR  NULL = NULL
#   NULL  OR  NULL = NULL
#   NOT NULL       = NULL       (preserves invalidity)
#
# Formula reference: `arithmetic.mojo` (canonical bitmap-byte form):
#   AND result_valid = (lv & ~ld) | (rv & ~rd) | (lv & rv)
#   OR  result_valid = (lv & ld) | (rv & rd) | (lv & rv)
#
# Where lv/rv = operand validity bytes; ld/rd = operand data bytes.
#
# This file ships TWO surface families:
#   1. Per-SIMD-W lane helpers operating on EvalBoolChunk[W]:
#      `_kleene_and_chunk` / `_or_chunk` / `_not_chunk`. Used by the
#      runtime-tree walker and the unified-engine
#      filter_apply kernel.
#   2. Per-byte bitmap helpers operating on (values_byte,
#      validity_byte) tuples: `_kleene_and_byte` / `_or_byte` /
#      `_not_byte`. Used by per-byte Arrow-bit-packed kernels and
#      whole-column kernels that already work in byte-bitmap shape.
#
# The two families are layered: the byte helpers can be derived from
# the chunk helpers at W=8 (one byte = 8 lanes). They are kept
# separate so callers reach for the SIMD shape that matches their
# inner loop without an extra layer of staging.
#
# Scope: the per-chunk + per-byte Kleene primitives. Consumed by the
# runtime walker (RuntimeExprBool, LIVE) and — via the SAME rule — by
# the whole-column comparison variants in `comparison_kleene.mojo`
#, which the columnar decimal
# predicate now routes through instead of ad-hoc per-row is_null gates.
# =============================================================================

from komira_eval.eval_chunks import EvalBoolChunk


# =============================================================================
# Per-SIMD-W chunk helpers — operate on EvalBoolChunk[W]
# =============================================================================


@always_inline
def _kleene_and_chunk[W: Int](
    l: EvalBoolChunk[W],
    r: EvalBoolChunk[W],
) -> EvalBoolChunk[W]:
    """Kleene AND on two EvalBoolChunk[W] operands.

    — adapted from arithmetic.mojo bitmap-byte
    form to SIMD lanes. Lane-wise:
      result_value = l.value & r.value
      result_valid = (l.valid & ~l.value) | (r.valid & ~r.value)
                      | (l.valid & r.valid)
    Reads: result is VALID if either operand is known-FALSE
    (short-circuit) OR if both operands are valid.
    """
    var values = l.values & r.values
    var validity = (
        (l.validity & ~l.values)
        | (r.validity & ~r.values)
        | (l.validity & r.validity)
    )
    return EvalBoolChunk[W](values=values, validity=validity)


@always_inline
def _kleene_or_chunk[W: Int](
    l: EvalBoolChunk[W],
    r: EvalBoolChunk[W],
) -> EvalBoolChunk[W]:
    """Kleene OR on two EvalBoolChunk[W] operands — dual of AND:
      result_value = l.value | r.value
      result_valid = (l.valid & l.value) | (r.valid & r.value)
                      | (l.valid & r.valid)
    Reads: result is VALID if either operand is known-TRUE
    (short-circuit) OR if both operands are valid.
    """
    var values = l.values | r.values
    var validity = (
        (l.validity & l.values)
        | (r.validity & r.values)
        | (l.validity & r.validity)
    )
    return EvalBoolChunk[W](values=values, validity=validity)


@always_inline
def _kleene_not_chunk[W: Int](
    x: EvalBoolChunk[W],
) -> EvalBoolChunk[W]:
    """Kleene NOT on one EvalBoolChunk[W] operand.

    Flips data on every lane; validity is preserved unchanged (NOT
    NULL = NULL). The data flip on invalid lanes is harmless — the
    validity bit guards consumers.
    """
    return EvalBoolChunk[W](values=~x.values, validity=x.validity)


# =============================================================================
# Per-byte bitmap helpers — operate on raw bitmap bytes
# =============================================================================
#
# Used by per-byte Arrow-bit-packed kernels
# and the whole-column comparison variants in `comparison_kleene.mojo`
# (which reuse `_cmp_result_validity_*`'s AND-of-validities rule at the
# bitmap grain). Formula is the same as the chunk form but specialized
# to 8 lanes per byte (UInt8 lane = bit-packed mask).
# =============================================================================


@always_inline
def _kleene_and_byte(
    lv: UInt8, ld: UInt8, rv: UInt8, rd: UInt8
) -> Tuple[UInt8, UInt8]:
    """Kleene AND on one bitmap byte from each operand.

    Args:
        lv: Left operand validity byte (1 bit per lane = valid).
        ld: Left operand data byte (1 bit per lane = TRUE).
        rv: Right operand validity byte.
        rd: Right operand data byte.

    Returns:
        Tuple (result_data, result_validity) — both UInt8 bit-packed
        per Arrow Columnar Format spec (LSB-first).

    Formula (verbatim from arithmetic.mojo):
        result_data  = ld & rd
        result_valid = (lv & ~ld) | (rv & ~rd) | (lv & rv)
    """
    var data = ld & rd
    var valid = (lv & ~ld) | (rv & ~rd) | (lv & rv)
    return Tuple(data, valid)


@always_inline
def _kleene_or_byte(
    lv: UInt8, ld: UInt8, rv: UInt8, rd: UInt8
) -> Tuple[UInt8, UInt8]:
    """Kleene OR on one bitmap byte from each operand.

    Formula (verbatim from arithmetic.mojo):
        result_data  = ld | rd
        result_valid = (lv & ld) | (rv & rd) | (lv & rv)
    """
    var data = ld | rd
    var valid = (lv & ld) | (rv & rd) | (lv & rv)
    return Tuple(data, valid)


@always_inline
def _kleene_not_byte(
    lv: UInt8, ld: UInt8
) -> Tuple[UInt8, UInt8]:
    """Kleene NOT on one bitmap byte.

    Returns:
        Tuple (result_data, result_validity).

    NOT preserves validity; data is bitwise inverted (NOT NULL = NULL
    is honored via the unchanged validity bit; the data flip on
    invalid lanes is harmless since consumers gate on validity).
    """
    return Tuple(~ld, lv)


# =============================================================================
# Comparison-result validity helper — AND of operand validities
# =============================================================================


@always_inline
def _cmp_result_validity_byte(lv: UInt8, rv: UInt8) -> UInt8:
    """Validity byte for a per-byte comparison result (lt / le / gt /
    ge / eq / ne).

    Comparisons propagate NULL through both operands: the result lane
    is VALID iff both operand lanes are VALID. Returns `lv & rv`.

    Used by `comparison_kleene.mojo`'s per-DType Kleene-aware
    eval_gt_kleene / eval_lt_kleene / etc. variants.
    """
    return lv & rv


@always_inline
def _cmp_result_validity_chunk[W: Int](
    lv: SIMD[DType.bool, W],
    rv: SIMD[DType.bool, W],
) -> SIMD[DType.bool, W]:
    """SIMD-W lane equivalent of `_cmp_result_validity_byte` — for the
    unified-engine per-W chunk comparison kernels."""
    return lv & rv
