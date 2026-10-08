# =============================================================================
# comparison_kleene — whole-column 3VL comparison variants + the null-policy seam
# =============================================================================
#
# Whole-column 3VL comparison validity, the companion of `kleene.mojo`.
#
# WHY THIS FILE EXISTS
# --------------------
# `kleene.mojo` owns the per-SIMD-chunk and per-bitmap-BYTE Kleene primitives
# (`_kleene_and_*` / `_cmp_result_validity_*`) consumed by the runtime bool
# walker (`runtime_expr_bool`). But the *whole-column* columnar predicate
# surface (`komira_compiler.compiler_eval_predicate`) implemented its
# comparison null semantics with AD-HOC PER-ROW `is_null(i)` GATES in the
# DECIMAL128 helpers (`_eval_decimal_col_vs_literal` / `_eval_decimal_col_vs_col`).
# That would be a divergent re-implementation of the exact same 3VL rule the
# chunk walker already rides. This file is the ONE canonical mechanism the
# columnar decimal predicate uses — a bitmap-shaped sibling of
# `kleene.mojo`'s `_cmp_result_validity_chunk`, over the SAME rule:
#
#   SQL/Arrow 3VL comparison: `x <op> y` is NULL whenever EITHER operand is
#   NULL. So `result_validity = left_validity & right_validity` (a comparison
#   has no value-dependent short-circuit, unlike Kleene AND/OR). A scalar
#   (always-valid) RHS reduces to `result_validity = left_validity`.
#
# THE NULL-POLICY SEAM
# ----------------------------------------------------------
# The null policy enters as a RUNTIME parameter (`NullPolicy`, a UInt8-wrapping
# POD), NOT a comptime one. This is deliberate and load-bearing:
#   * A comptime `[P: Profile]` kernel parameter would monomorphize every
#     comparison entry point ONCE PER PROFILE — a comptime explosion. A
#     runtime policy byte adds ZERO monomorphs.
#   * The policy is consulted ONCE per call (a single predictable branch in
#     `merge_cmp_validity`, hoisted outside the per-byte loop), so the 3VL fast
#     path pays nothing for the seam.
# It defaults to 3VL-absorb (`NULL_POLICY_THREE_VALUED`). Another policy plugs
# a new code into `merge_cmp_validity` WITHOUT re-forking any comparison entry
# point — that is the point of the seam.
#
# BEHAVIOR CONTRACT: `current semantics == the SQL-3VL base profile`. The
# differential test `test_comparison_kleene_convergence.mojo` pins the result over
# nullable fixtures (all-null / none-null / scattered / empty).
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.comparison import (
    eval_col_gt, eval_col_lt, eval_col_eq,
    eval_col_ne, eval_col_le, eval_col_ge,
)


# =============================================================================
# The null-policy seam — a RUNTIME parameter, never a comptime one
# =============================================================================

comptime NULL_POLICY_THREE_VALUED: UInt8 = 0
"""SQL/Arrow three-valued-logic absorb (the default, and the only policy
implemented). Another code plugs into `merge_cmp_validity` without re-forking
any entry point."""


struct NullPolicy(Copyable, Movable, ImplicitlyCopyable):
    """Runtime selector for how a comparison propagates operand NULLs.

    A plain UInt8-wrapping POD (never a comptime parameter). See the module
    header for why this is runtime, not comptime (the row-path monomorphization
    constraint). Constructed via `NullPolicy.three_valued()` (or the no-arg
    ctor, which is 3VL) so the intent reads at the call site.
    """

    var code: UInt8

    def __init__(out self):
        """Default: SQL 3VL-absorb."""
        self.code = NULL_POLICY_THREE_VALUED

    def __init__(out self, code: UInt8):
        self.code = code

    @staticmethod
    def three_valued() -> Self:
        """The SQL/Arrow 3VL-absorb policy (the default)."""
        return Self(NULL_POLICY_THREE_VALUED)

    @always_inline
    def is_three_valued(self) -> Bool:
        return self.code == NULL_POLICY_THREE_VALUED


# =============================================================================
# The one mechanism — operand-validity merge for a comparison result
# =============================================================================


# =============================================================================
# ⚠ THE OPERAND OFFSET IS PART OF THE OPERAND
# =============================================================================
#
# A SLICED Arrow array keeps BOTH planes in ABSOLUTE coordinates: logical row
# `i` is data element `offset + i` and validity BIT `offset + i`
# (`PrimitiveArray.is_null` is written exactly that way). The comparison data
# kernels honour that — `eval_col_gt` and friends read `left.load[W](i)`, which
# is offset-aware — and hand back a result REBASED to row 0.
#
# A mechanism that reads the operand bitmaps from BIT 0 and never sees the
# offset misaligns the two planes of a sliced operand by exactly `offset` bits.
# For example (offset-2 views of length-5 buffers, logical
# `a = [NULL(100), 5, 200]` vs `b = [1, 50, 1]`, `a > b`):
#
#     row 0, the UNKNOWN row        -> data=1, valid   => SELECTED as a TRUE
#     row 2, genuinely TRUE (200>1) -> data=0, NULL    => DROPPED as UNKNOWN
#
# Wrong in BOTH directions in ONE call: a row that logically does not exist is
# returned, and a row that logically does is not. Falsifier:
# `test_comparison_kleene_offset_validity.mojo` (the offset-0 / no-bitmap cases
# are CONTROLS).
#
# ⚠ A test that drives `StreamingFilterOp -> _eval_predicate` CANNOT see this:
# every route from there into this seam passes through `Column.as_primitive`,
# whose copy path REBASES the value window to `offset == 0` AND the validity
# bitmap to bit 0. It measures a route that normalises the property under test.
#
# THE OFFSET IS A PARAMETER of the mechanism, defaulting to 0. Every entry
# point that HAS an array threads `arr.offset` (the six `eval_col_*_nullable`
# kernels below; the `_eval_predicate` col-vs-literal arms). A caller holding
# only a bitmap — the DECIMAL128 helpers, whose `Decimal128Array` has no offset
# field because `Column.as_decimal128` always rebases — keeps the default and is
# correct by construction.
#
# ⚠ WHAT THIS DOES **NOT** CLOSE. `column.mojo` cites THREE offset-blind readers
# as the reason `COL_VIEW_ELIM_ENABLED` and `can_share_as_primitive` must refuse
# a NULLABLE column: `merge_cmp_validity` (this one — offset-aware),
# `clone_array_validity`, and `merge_binary_arith_validity`. The other two are
# read from bit 0. Those gates therefore still hold, and this offset
# awareness is NOT licence to widen them.
#
# The per-row `validity.test(i)` walks in join / binary-fn (three sites, in
# `binary_fn_op` and `decode_helpers`) are unreachable through a share because
# of the nullable gates. `COL_VIEW_ELIM_ENABLED` is ON, and its NON-NULLABLE
# gate is precisely what keeps that true. Widening any of these gates re-arms
# all three.
# =============================================================================


@always_inline
def _validity_byte(
    opt: Optional[Bitmap[HeapRegion]], byte_idx: Int, bit_offset: Int = 0
) raises -> UInt8:
    """Read the validity byte covering logical bits `[byte_idx*8, +8)`.

    Returns 0xFF (all-valid) when the operand carries no bitmap.

    Logical bit `j` of the operand is ABSOLUTE bit
    `bit_offset + j`, so the byte handed back is assembled from the one or two
    source bytes straddling that shift. `bit_offset == 0` reduces to a single
    `read_u8_at` with no extra work — the shape every production caller has
    today, so the common path is unchanged instruction-for-instruction.

    Bits past the operand's logical length may be garbage; `merge_cmp_validity`
    masks the final byte's trailing bits to canonical 0.

    Mirrors `komira_column_kernels.comparison._read_validity_byte_pa` but reads
    off a raw `Optional[Bitmap]` so this mechanism is DType-free (serves the
    decimal helpers, the primitive helpers, and any future surface identically).
    """
    if not opt:
        return UInt8(0xFF)
    ref bm = opt.value()
    var abs_bit = bit_offset + (byte_idx << 3)
    var lo_byte = abs_bit >> 3
    var shift = abs_bit & 7
    var lo = bm.buffer.read_u8_at(lo_byte)
    if shift == 0:
        return lo
    # Straddles two source bytes. The high half only exists if the bitmap
    # actually has another byte; past-the-end lanes are masked by the caller.
    var src_bytes = bytes_for_bits(bm.length)
    var hi = UInt8(0)
    if lo_byte + 1 < src_bytes:
        hi = bm.buffer.read_u8_at(lo_byte + 1)
    return (lo >> UInt8(shift)) | (hi << UInt8(8 - shift))


def merge_cmp_validity(
    left_validity: Optional[Bitmap[HeapRegion]],
    right_validity: Optional[Bitmap[HeapRegion]],
    length: Int,
    policy: NullPolicy = NullPolicy.three_valued(),
    left_offset: Int = 0,
    right_offset: Int = 0,
) raises -> Optional[Bitmap[HeapRegion]]:
    """Merge two operand validity bitmaps into the comparison-result validity.

    THE canonical null mechanism. For a scalar (always-valid) RHS, pass
    `right_validity = None` — it merges as all-valid, so the result validity is
    the left operand's validity.

    `left_offset` / `right_offset` are the operands' Arrow SLICE offsets: bit
    `j` of operand X is absolute bit `x_offset + j` of its bitmap, matching
    `PrimitiveArray.is_null`. They default to 0 for a caller whose operand type
    carries no offset. The two may DIFFER — columns can be sliced from different
    sources — so each side is shifted independently. See the block above for the
    defect this parameter closes and for what it does NOT close.

    Returns:
        None  — both operands are all-valid (no bitmap) -> the caller may leave
                the result non-nullable (or, for an always-nullable caller,
                keep its pre-existing all-valid bitmap).
        Some  — the merged validity bitmap, REBASED to bit 0 (matching the
                comparison kernels, which rebase their data plane the same way).
                Trailing bits past `length` in the final byte are masked to
                canonical 0 (load-bearing: `Bitmap.popcount`/`null_count` span
                whole bytes, so a stray trailing 1 would corrupt the null count).

    The policy branch is evaluated ONCE here (outside the per-byte loop) — the
    runtime seam. Only 3VL-absorb is implemented; any other code
    raises loud (fail-fast), which is where a future profile slots in.
    """
    if not policy.is_three_valued():
        raise Error(
            "comparison_kleene.merge_cmp_validity: null policy "
            + String(Int(policy.code))
            + " not implemented (only 3VL-absorb is implemented)"
        )

    # 3VL fast path: both operands all-valid -> no validity to attach.
    if not left_validity and not right_validity:
        return Optional[Bitmap[HeapRegion]](None)

    var num_bytes = bytes_for_bits(length)
    var vbm = Bitmap.create(length)
    for b in range(num_bytes):
        var lv = _validity_byte(left_validity, b, left_offset)
        var rv = _validity_byte(right_validity, b, right_offset)
        # Comparison-result validity = AND of operand validities.
        vbm.buffer.write_u8_at(b, lv & rv)
    vbm.buffer.set_length(num_bytes)

    # Mask trailing bits in the final byte to canonical 0.
    if num_bytes > 0:
        var trailing = length & 7
        if trailing > 0:
            var tmask = UInt8((1 << trailing) - 1)
            var v = vbm.buffer.read_u8_at(num_bytes - 1)
            vbm.buffer.write_u8_at(num_bytes - 1, v & tmask)

    return Optional[Bitmap[HeapRegion]](vbm^)


# =============================================================================
# Predicate finalize — attach merged validity + mask data by validity
# =============================================================================


def kleene_cmp_finalize(
    var result: BooleanArray,
    left_validity: Optional[Bitmap[HeapRegion]],
    right_validity: Optional[Bitmap[HeapRegion]],
    policy: NullPolicy = NullPolicy.three_valued(),
    left_offset: Int = 0,
    right_offset: Int = 0,
) raises -> BooleanArray:
    """Finalize a comparison PREDICATE result under the null policy.

    `result` is REBASED (its row 0 is the operands' logical row 0), so an
    operand that is an Arrow SLICE must say so: pass its `arr.offset` as
    `left_offset` / `right_offset`. Omitting it on a sliced operand misaligns
    the two planes by exactly `offset` bits — see the block above
    `_validity_byte` for the measurement.

    `result` must already carry the raw comparison data bits on ALL lanes
    (null lanes may hold garbage — they are masked here). This function:
      1. merges the operand validities (`merge_cmp_validity`),
      2. masks the result data by the merged validity so NULL lanes read as
         FALSE in the data plane. This step is REQUIRED, not cosmetic: the
         filter consumer (`filter_to_indices`) reads DATA bits and ignores
         validity, so a NULL row MUST have data=0 to be correctly dropped
         (`WHERE x <op> NULL` is NULL, i.e. not-TRUE, i.e. row dropped),
      3. attaches the merged validity + null_count.

    When both operands are all-valid (`merge_cmp_validity` -> None) the result
    is returned UNCHANGED — preserving whatever nullability shape the caller
    built (non-nullable for the primitive kernels; always-nullable for a
    caller that used `allocate_nullable`).
    """
    var mopt = merge_cmp_validity(
        left_validity,
        right_validity,
        result.length,
        policy,
        left_offset,
        right_offset,
    )
    if mopt:
        var mv = mopt.take()
        var masked = result.data.and_(mv)
        result.data = masked^
        result.null_count = mv.null_count()
        result.validity = Optional[Bitmap[HeapRegion]](mv^)
    return result^


@always_inline
def kleene_cmp_finalize_scalar(
    var result: BooleanArray,
    operand_validity: Optional[Bitmap[HeapRegion]],
    policy: NullPolicy = NullPolicy.three_valued(),
    operand_offset: Int = 0,
) raises -> BooleanArray:
    """Finalize a column-vs-scalar comparison predicate (RHS always valid).

    Convenience over `kleene_cmp_finalize` with the right operand treated as
    all-valid: `result_validity = operand_validity`.

    `operand_offset` is the column's Arrow SLICE offset (`arr.offset`), for the
    same reason `kleene_cmp_finalize` takes two: a scalar RHS removes one
    operand from the merge, not the offset from the surviving one.
    """
    return kleene_cmp_finalize(
        result^,
        operand_validity,
        Optional[Bitmap[HeapRegion]](None),
        policy,
        operand_offset,
        0,
    )


def kleene_all_null_predicate(
    length: Int, policy: NullPolicy = NullPolicy.three_valued()
) raises -> BooleanArray:
    """The result of a comparison whose scalar operand is NULL.

    `col <op> NULL` is NULL for every row under SQL 3VL, so the predicate never
    holds -> every row drops. Produces a nullable BooleanArray with all data
    bits 0 and all validity bits CLEARED (all-null), null_count == length —
    byte-identical to the pre-convergence decimal null-literal arm.
    """
    _ = policy  # 3VL: an all-NULL operand yields an all-NULL result regardless.
    var out = BooleanArray.allocate_nullable(length)
    if out.validity:
        for i in range(length):
            out.validity.value().clear(i)
    out.null_count = length
    return out^


# =============================================================================
# The six comparison-kernel 3VL variants over nullable primitive columns
# =============================================================================
#
# The `eq / ne / lt / le / gt / ge over nullable columns -> Kleene bool with
# validity` surface the `kleene.mojo` header promised. Each routes the DATA
# through the existing hand-staged SIMD compare-pack kernel (`eval_col_*`) and
# the VALIDITY through the one mechanism above. They mask data by validity
# (filter-safe), so they are strictly more correct than `comparison.mojo`'s
# earlier partial `eval_col_{gt,lt,eq}_kleene` (which attached validity but
# left null-lane data unmasked, and covered only 3 of the 6 ops).
#
# No live caller wires these yet — they complete the canonical mechanism so a
# future SQL binder binds straight onto ONE surface. Exercised by the
# differential test.
# =============================================================================


def eval_col_gt_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `>` over nullable columns."""
    var result = eval_col_gt[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )


def eval_col_lt_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `<` over nullable columns."""
    var result = eval_col_lt[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )


def eval_col_eq_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `==` over nullable columns."""
    var result = eval_col_eq[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )


def eval_col_ne_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `!=` over nullable columns."""
    var result = eval_col_ne[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )


def eval_col_le_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `<=` over nullable columns."""
    var result = eval_col_le[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )


def eval_col_ge_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype],
    right: PrimitiveArray[dtype],
    policy: NullPolicy = NullPolicy.three_valued(),
) raises -> BooleanArray:
    """Kleene-correct, filter-safe column-vs-column `>=` over nullable columns."""
    var result = eval_col_ge[dtype](left, right)
    # The kernel above read the DATA at `offset + i`; the offsets go through so
    # the VALIDITY is read at the same coordinates.
    return kleene_cmp_finalize(
        result^, left.validity, right.validity, policy,
        left.offset, right.offset,
    )
