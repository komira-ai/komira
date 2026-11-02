# =============================================================================
# column_compare: column-vs-column comparison under SQL numeric promotion
# =============================================================================
#
# The widening and narrowing helpers the comparison arms share, the mixed
# DECIMAL128 comparison, and `_eval_col_vs_col_promoted`, which the predicate
# evaluator calls for `col OP col` when the two sides differ in type.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.cast_null import eval_cast
from komira_column_kernels.compiler_helpers import int64_to_float64
from komira_kernels.comparison_kleene import (
    NullPolicy,
    eval_col_eq_nullable,
    eval_col_ge_nullable,
    eval_col_gt_nullable,
    eval_col_le_nullable,
    eval_col_lt_nullable,
    eval_col_ne_nullable,
    kleene_cmp_finalize,
)
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
)
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_float64, int_to_decimal_i128
from komira_scalar_arithmetic.decimal_compare import (
    DEC_CMP_EQ,
    DEC_CMP_GE,
    DEC_CMP_GT,
    DEC_CMP_LE,
    DEC_CMP_LT,
    DEC_CMP_NE,
    decimal_cmp_i128,
)


def _column_to_float64(
    col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.float64]:
    """Coerce a numeric Column to a FLOAT64 PrimitiveArray (validity-preserving).

    The EXPR_MATH_FN(2) kernels operate on
    FLOAT64. Accepts FLOAT64 (zero-copy as_primitive), INT64, or INT32
    inputs and widens via the existing validity-preserving cast helpers; a
    DECIMAL128 becomes the DOUBLE `unscaled / 10^scale`.
    Non-numeric input raises a clear plan-time-style error.
    """
    var at = col.arrow_type
    if at == ArrowType.FLOAT64:
        return col.as_primitive[DType.float64]()
    elif at == ArrowType.INT64:
        return int64_to_float64(col.as_primitive[DType.int64]())
    elif at == ArrowType.INT32:
        # INT32 -> INT64 -> FLOAT64 (both steps validity-preserving).
        var i64 = eval_cast[DType.int32, DType.int64](col.as_primitive[DType.int32]())
        return int64_to_float64(i64)
    elif at == ArrowType.DECIMAL128 and col.decimal_precision() > 0:
        # The DOUBLE a DuckDB math function answers over a DECIMAL (an integer
        # `sum()` is DECIMAL(38, 0)): the unscaled value over 10^scale.
        var arr = col.as_decimal128()
        var s = col.decimal_scale()
        var n = col.length()
        var out = PrimitiveArray[DType.float64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_float64(arr.get_i128(i), s))
        out.null_count = nulls
        return out^
    else:
        raise Error(
            "PipelineCompiler: scalar math function requires a numeric"
            " (FLOAT64 / INT64 / INT32 / DECIMAL128) input, got type_id="
            + String(Int(at.type_id))
        )


# =============================================================================
# Type-promoting column-vs-column comparison
# =============================================================================
#
# `_eval_col_vs_col` requires both sides to share an Arrow type. The
# canonical Q20 predicate `col("ps_availqty") > col("qty_sum") * 0.5`
# produces an INT64 LHS and a FLOAT64 RHS (FLOAT64 because the literal
# 0.5 is FLOAT64); the same shape arises whenever a user filters an INT
# column against a float-arithmetic-derived expression.
#
# This helper applies SQL-standard implicit numeric promotion across the
# two operands: pick the wider of the two types (FLOAT64 > INT64 > INT32
# in the numeric lattice), cast the narrower side once via a
# VALIDITY-PRESERVING helper, then dispatch through `_col_cmp_nullable`.
#
# Promotion is numeric-only by design: STRING vs numeric must remain a
# hard error so silent type-coercion bugs (DataFusion-style "Utf8 == 0
# returns NULL") cannot enter the predicate path.
#
# ---------------------------------------------------------------------------
# ⚠ THIS IS PART OF THE PREDICATE DISPATCHER, AND IT OWES THE DISPATCHER'S
#   NULL CONTRACT
# ---------------------------------------------------------------------------
#
# `_eval_col_vs_col_promoted` is NOT a separate feature. It is reached from
# THREE sites inside `eval_predicate._eval_predicate`:
#   1. the computed-LHS arm     (`a * 2 > 100`)
#   2. the general-RHS arm      (`a > b * 1`, and `a > b` at MIXED types)
#   3. INT-col vs FLOAT-literal (`a < 100.5`)
# so it owes the contract that dispatcher's header block states:
#
#     A row whose predicate value is UNKNOWN carries DATA BIT 0.
#     The validity bitmap says WHY it is 0 — unknown, not false.
#
# PRE-FIX IT VIOLATED THAT ON ALL NINE ARMS, in two distinct ways:
#   * every arm `return`ed a raw `eval_col_*` kernel — the hand-staged SIMD
#     compare-pack, which reads the VALUE buffer and never the validity
#     bitmap, so the mask came back NON-NULLABLE with the null lane's data
#     bit set to whatever the dead bytes compared to; and
#   * the four arms that WIDEN a narrow operand (INT32<>INT64 ×2,
#     INT32<>FLOAT64 ×2) did it with an inline `PrimitiveArray.allocate` +
#     raw store loop and NO `clone_array_validity`, destroying that
#     operand's null mask BEFORE the kernel ran. `clone_array_validity`'s
#     own docstring names this exact failure: a nullable cast that "comes
#     back claiming all-valid (silent-wrong bug)".
#
# MEASURED through the production `StreamingFilterOp` (an UNREPAIRED
# `_eval_predicate` consumer — no `_collapse_nulls_to_false`), 29 of 41
# assertions RED pre-fix: `a < 100.5` over a nullable INT64 column SELECTED
# the NULL row, and `a = 0.0` over a zero-filled null slot returned EXACTLY
# ONE ROW — the NULL row, a row that logically does not exist.
#
# THE MASK IS AN OPERAND, NOT JUST AN ANSWER — the reason a non-nullable mask
# is not merely a lost annotation. `eval_and` / `eval_or` derive their Kleene
# validity FROM the operand data bits, so a 1 sitting on an UNKNOWN row feeds
# the merge and changes the RESULT: pre-fix `(a = 0.0) OR (b > 0)` selected a
# row where the OR is UNKNOWN, and `(a < 100.5) AND (b > 0)` did the same, in
# BOTH operand orders. Both cells are pinned, as are the two that were already
# right (`UNKNOWN OR TRUE` = TRUE survives; `UNKNOWN AND FALSE` = FALSE).
#
# THE FIX IS THE SAME SEAM, NOT A SECOND CONVENTION: every arm now widens
# through a validity-preserving helper (`_column_to_float64` /
# `eval_cast[int32, int64]`, both of which clone the bitmap) and finalizes
# through `_col_cmp_nullable`, which is the SAME helper
# `eval_predicate._eval_col_vs_col` uses. It lives here rather than
# there because predicate imports column and not the reverse.
#
# ⛔ THE SLICED / OFFSET INPUT.
# ---------------------------------------------------------------------------
# A FILTER ROUTE CANNOT SEE IT: `StreamingFilterOp -> _eval_predicate` gives
# the right answer on a sliced column. WHY: every route from this file into the
# seam reaches its operands through `Column.as_primitive` (directly, via
# `copy_column`, or via `_column_to_int64` / `_column_to_float64`), and
# `as_primitive`'s copy path REBASES BOTH PLANES — the value window to
# `offset == 0` and the validity bitmap from `_offset` to bit 0. The four tests
# drove a route that NORMALISES the property under test, so they could not have
# seen the defect.
#
# THE SEAM CONTRACT: `merge_cmp_validity` — the ONE mechanism
# `_col_cmp_nullable` finalizes through — reads the operand bitmaps at
# `arr.offset`, as the data kernels read `load[W](i)` at `offset + i`. Reading
# them from BIT 0 instead, with offset-2 operands fed STRAIGHT
# to `eval_col_gt_nullable`, logical `a = [NULL(100), 5, 200]` vs `b = [1,50,1]`:
# row 0 (UNKNOWN) comes back data=1/valid — SELECTED as a TRUE — and row 2
# (genuinely 200>1) comes back data=0/NULL — DROPPED as UNKNOWN. Wrong in BOTH
# directions in one call. The mechanism lives in `komira_kernels/comparison_kleene.mojo`
# (the offset block above `_validity_byte`), with its own offset-validity test.
# The offset is a PARAMETER of the mechanism, so
# `_col_cmp_nullable` is offset-correct for BOTH dispatchers without this file
# rebasing anything itself.
#
# ⚠ STILL TRUE, AND STILL LOAD-BEARING: `as_primitive` rebases, and the two
# OTHER offset-blind readers `column.mojo` names — `clone_array_validity` and
# `merge_binary_arith_validity` — are UNCHANGED. `COL_VIEW_ELIM_ENABLED` and
# `can_share_as_primitive` must still refuse a NULLABLE column.
#
# HOW TO ADD AN ARM: convert both operands with a helper that preserves
# validity, then `return _col_cmp_nullable[dtype](l, r, op)`. Never `return`
# a bare `eval_col_*`, and never hand-roll a widening loop. ⚠ AND DECIDE WHICH
# DOMAIN THE PAIR COMPARES IN BEFORE YOU PICK THE HELPER — it is not always the
# wider type; see the float32 block below `_column_to_int64`.
# =============================================================================


@always_inline
def _col_cmp_nullable[
    dtype: DType
](
    left: PrimitiveArray[dtype], right: PrimitiveArray[dtype], op: UInt8
) raises -> BooleanArray:
    """Column-vs-column comparison that HONOURS both operands' validity.

    THE ONE col-vs-col null seam. Both `eval_predicate.
    _eval_col_vs_col` (same-type) and `_eval_col_vs_col_promoted` (mixed-type
    / computed-operand) route through it, so there is one policy and one
    place to change it.

    Routes the DATA through the same hand-staged SIMD compare-pack kernel and
    the VALIDITY through the ONE mechanism (`kleene_cmp_finalize`, which
    merges `left & right`, masks null-lane data to 0, and sets `null_count`).
    A column with NO validity bitmap short-circuits inside
    `merge_cmp_validity` and pays literally nothing.
    """
    if op == BIN_GT:
        return eval_col_gt_nullable[dtype](left, right)
    elif op == BIN_LT:
        return eval_col_lt_nullable[dtype](left, right)
    elif op == BIN_EQ:
        return eval_col_eq_nullable[dtype](left, right)
    elif op == BIN_NE:
        return eval_col_ne_nullable[dtype](left, right)
    elif op == BIN_GE:
        return eval_col_ge_nullable[dtype](left, right)
    elif op == BIN_LE:
        return eval_col_le_nullable[dtype](left, right)
    else:
        raise Error(
            "col-vs-col comparison: unsupported op "
            + String(Int(op))
            + " for column dtype "
            + String(dtype)
        )


@always_inline
def _column_to_int64(
    col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.int64]:
    """Coerce an INT64 / INT32 Column to an INT64 array, VALIDITY-PRESERVING.

    Replaces the four hand-rolled `PrimitiveArray.allocate` + store widening
    loops this file used to carry — none of which called
    `clone_array_validity`, so each one silently produced an all-valid array
    from a nullable one. `eval_cast` clones the bitmap and recomputes
    `null_count` (its own docstring: "cast(nullable_col AS ...) keeps the
    null mask").
    """
    var at = col.arrow_type
    if at == ArrowType.INT64:
        return col.as_primitive[DType.int64]()
    elif at == ArrowType.INT32:
        return eval_cast[DType.int32, DType.int64](
            col.as_primitive[DType.int32]()
        )
    else:
        raise Error(
            "_eval_col_vs_col_promoted: expected an INT64/INT32 column, got "
            + String(at)
        )


# =============================================================================
# ★★ FLOAT32 AT A COMPARISON SITE
# =============================================================================
#
# float32 had NO arm at EITHER column-vs-column site, so a float32 column could
# not appear in a comparison at all: the SAME-TYPE pair refused in
# `eval_predicate._eval_col_vs_col` ("unsupported column type:
# float32") and every MIXED pair refused at the `l_numeric`/`r_numeric` guard
# below ("unsupported column type pair: float32 vs float64"), in BOTH operand
# orders, under all three operators. A customer met it as "my filter does
# nothing on this column".
#
# ⛔⛔ THE PROMOTION GOES IN **TWO DIFFERENT DIRECTIONS** AND ONE UNIFORM RULE
# IS WRONG. MEASURED against DuckDB v1.5.3 (the parity target), over COLUMNS,
# with `16777217 = 2**24 + 1` — inexact in float32, exact in float64 and in
# both integer widths:
#
#   FLOAT ⊕ DOUBLE        -> compare in DOUBLE.  `16777216.0f  = 16777217.0d`
#                            is FALSE, `16777216.0f < 16777217.0d` is TRUE.
#                            ⇒ the float32 side WIDENS; lossless.
#   FLOAT ⊕ BIGINT/INTEGER-> compare in FLOAT.   `16777216.0f  = 16777217`
#                            is TRUE.
#                            ⇒ the INTEGER side NARROWS; LOSSY, on purpose.
#
# The second row is the counter-intuitive one and it is not an accident of
# constant folding — it was measured on real BIGINT and INTEGER columns. A
# "promote everything to float64" implementation gets the first family right
# and the second family WRONG, and no fixture whose float32 values are exact
# can tell the two apart. The regression corpus carries a discriminating
# precision row for exactly this.
#
# ⚠ NaN IS **NOT** CLOSED BY THIS. DuckDB answers `NaN = NaN` TRUE (it
# quotients all NaNs to one value); `_col_cmp_nullable` is IEEE and answers
# FALSE, for float32 exactly as it already did for float64. That is a KNOWN,
# separately scheduled divergence, with the comparison operators LAST — so the
# float32 arms deliberately inherit the float64 arm's
# NaN behaviour rather than forking it. ±0.0 needs nothing: IEEE and DuckDB
# both call `-0.0 = +0.0` TRUE.
#
# ⚠ NOT CLOSED EITHER: a float32 column against a LITERAL. That is the
# `col OP literal` ladder in `eval_predicate._eval_predicate`, whose
# terminal `else` refuses bool/int8/int16/uint8/float32 alike
# ("unsupported column type for predicate: float32") — a different site and a
# different class.
# =============================================================================


@always_inline
def _cmp_widen_to_float64(
    col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.float64]:
    """FLOAT32 / FLOAT64 / INT64 / INT32 -> float64, VALIDITY-PRESERVING.

    ⚠ DELIBERATELY NOT AN ARM ON `_column_to_float64`. That helper is the
    scalar-math coercion (`EXPR_MATH_FN`), and whether float32 is a scalar-math
    INPUT is a different question. Widening it here would change that answer as
    a side effect of a comparison fix.
    """
    if col.arrow_type == ArrowType.FLOAT32:
        return eval_cast[DType.float32, DType.float64](
            col.as_primitive[DType.float32]()
        )
    return _column_to_float64(col)


@always_inline
def _cmp_narrow_to_float32(
    col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.float32]:
    """FLOAT32 / INT64 / INT32 -> float32, VALIDITY-PRESERVING.

    ⛔ THE NARROWING IS THE POINT AND IT IS LOSSY BY DESIGN. DuckDB v1.5.3
    compares `FLOAT` against an integer IN FLOAT, so `16777216.0f = 16777217`
    is TRUE there; widening both sides to float64 instead answers FALSE and
    diverges. Reached ONLY from the float32-⊕-integer arm of
    `_eval_col_vs_col_promoted`; a pair with a FLOAT64 on it takes
    `_cmp_widen_to_float64` and never comes here.
    """
    var at = col.arrow_type
    if at == ArrowType.FLOAT32:
        return col.as_primitive[DType.float32]()
    elif at == ArrowType.INT64:
        return eval_cast[DType.int64, DType.float32](
            col.as_primitive[DType.int64]()
        )
    elif at == ArrowType.INT32:
        return eval_cast[DType.int32, DType.float32](
            col.as_primitive[DType.int32]()
        )
    else:
        raise Error(
            "_eval_col_vs_col_promoted: expected a FLOAT32/INT64/INT32 column"
            " for the float32 comparison domain, got "
            + String(at)
        )


def _dec_cmp_code(op: UInt8) raises -> UInt8:
    """BIN_* comparison -> `decimal_compare`'s DEC_CMP_* code."""
    if op == BIN_LT:
        return DEC_CMP_LT
    if op == BIN_LE:
        return DEC_CMP_LE
    if op == BIN_GT:
        return DEC_CMP_GT
    if op == BIN_GE:
        return DEC_CMP_GE
    if op == BIN_EQ:
        return DEC_CMP_EQ
    if op == BIN_NE:
        return DEC_CMP_NE
    raise Error("DECIMAL compare: unsupported op " + String(Int(op)))


def _cmp_decimal_mixed(
    var left_col: Column[HeapRegion],
    var right_col: Column[HeapRegion],
    op: UInt8,
) raises -> BooleanArray:
    """A comparison with a DECIMAL128 operand and a DECIMAL / INTEGER / FLOAT
    one.

    ⛔ WHY: `_eval_col_vs_col_promoted` had no DECIMAL arm, so every
    column-vs-column comparison touching a DECIMAL fell to its "unsupported
    column type pair" raise -- MEASURED at @sql: `SELECT k, 5 < dc` (the
    literal broadcast on the LEFT), `WHERE dc > nn` (an INT64 column) and a
    decimal compared with a computed decimal refused with that engine text,
    while `dc > 5` answered through the scalar arm. DuckDB 1.5.3 answers all
    of them. Rules (DuckDB's): DECIMAL vs DECIMAL compares exactly, scale-
    aligned (`decimal_cmp_i128`); DECIMAL vs INTEGER compares exactly with the
    integer at the decimal's scale (an integer past DECIMAL(38) orders by its
    sign); DECIMAL vs FLOAT is REFUSED BY NAME (an
    IEEE DOUBLE comparison is none of DuckDB's, pandas' or polars' rule --
    see the arm). NULL on either side is NULL
    (`kleene_cmp_finalize`, three-valued).
    ⚠ A DECIMAL column that carries no (precision, scale) is REFUSED BY NAME
    rather than read at scale 0."""
    var l_dec = left_col.arrow_type == ArrowType.DECIMAL128
    var r_dec = right_col.arrow_type == ArrowType.DECIMAL128
    if l_dec and left_col.decimal_precision() <= 0:
        raise Error(
            "DECIMAL compare: the left DECIMAL operand carries no (precision,"
            " scale), so its values cannot be aligned"
        )
    if r_dec and right_col.decimal_precision() <= 0:
        raise Error(
            "DECIMAL compare: the right DECIMAL operand carries no (precision,"
            " scale), so its values cannot be aligned"
        )
    var n = left_col.length()
    if right_col.length() != n:
        raise Error("DECIMAL compare: column length mismatch")
    var dec_op = _dec_cmp_code(op)
    var out = BooleanArray.allocate_nullable(n)
    if l_dec and r_dec:
        var la = left_col.as_decimal128()
        var ra = right_col.as_decimal128()
        var ls = left_col.decimal_scale()
        var rs = right_col.decimal_scale()
        for i in range(n):
            out.set(i, decimal_cmp_i128(la.get_i128(i), ls, ra.get_i128(i), rs, dec_op))
        return kleene_cmp_finalize(out^, la.validity, ra.validity, NullPolicy.three_valued())
    var lt_name = String(left_col.arrow_type)
    var rt_name = String(right_col.arrow_type)
    var dcol: Column[HeapRegion]
    var ocol: Column[HeapRegion]
    if l_dec:
        dcol = left_col^
        ocol = right_col^
    else:
        dcol = right_col^
        ocol = left_col^
    var ot = ocol.arrow_type
    var da = dcol.as_decimal128()
    var ds = dcol.decimal_scale()
    if ot == ArrowType.INT64 or ot == ArrowType.INT32:
        var ia = _column_to_int64(ocol)
        for i in range(n):
            var dv = da.get_i128(i)
            var iv = ia.get(i)
            var r: Bool
            try:
                var ivd = int_to_decimal_i128(iv, 38, ds)
                # decimal (op) integer, written in the ORIGINAL operand order.
                if l_dec:
                    r = decimal_cmp_i128(dv, ds, ivd, ds, dec_op)
                else:
                    r = decimal_cmp_i128(ivd, ds, dv, ds, dec_op)
            except e:
                _ = e
                # |integer| * 10^scale is past DECIMAL(38): the integer is
                # larger in magnitude than any value of the decimal, so the
                # order is its sign's. Compare two stand-ins with that order.
                var big = I128(1) if iv > 0 else I128(-1)
                var small = I128(0)
                if l_dec:
                    r = decimal_cmp_i128(small, 0, big, 0, dec_op)
                else:
                    r = decimal_cmp_i128(big, 0, small, 0, dec_op)
            out.set(i, r)
        if l_dec:
            return kleene_cmp_finalize(out^, da.validity, ia.validity, NullPolicy.three_valued())
        return kleene_cmp_finalize(out^, ia.validity, da.validity, NullPolicy.three_valued())
    if ot == ArrowType.FLOAT64 or ot == ArrowType.FLOAT32:
        # ⛔ REFUSED BY NAME, NOT an IEEE DOUBLE comparison. Answering `dec <op> x`
        # as `Float64(dec) <op> x` under IEEE, which is NONE of the references'
        # rules: DuckDB 1.5.3 compares in the FLOAT
        # operand's OWN width (a DECIMAL(12,2) 0.10 EQUALS a FLOAT 0.1; here
        # FALSE) under its total order (`0.0 < NaN` TRUE; here FALSE); pandas
        # 3.0.6 compares a Decimal and a float EXACTLY (`0.10 < 0.1` TRUE; here
        # FALSE) and RAISES `InvalidOperation` for `x < dec` over a NaN; polars
        # 1.44.2 compares as Float64 with NaN largest. One engine arm cannot
        # answer three rules, so the combination stays a refusal, by name, until a
        # door-aware rule lands.
        raise Error(
            "DECIMAL compare: a DECIMAL compared with a "
            + String(ot)
            + " column is refused -- DuckDB 1.5.3 compares in the float's own"
            + " width under its total order (NaN above +inf), pandas 3.0.6"
            + " compares a Decimal and a float exactly, polars 1.44.2 as"
            + " Float64 with NaN largest, and this engine has no one rule that"
            + " answers all three. A DECIMAL compared"
            + " with an INTEGER or DECIMAL column is served."
        )
    raise Error(
        "_eval_col_vs_col_promoted: unsupported column type pair: "
        + lt_name + " vs " + rt_name
    )


def _eval_col_vs_col_promoted(
    var left_col: Column[HeapRegion],
    var right_col: Column[HeapRegion],
    op: UInt8,
) raises -> BooleanArray:
    """Compare two Columns under SQL-standard numeric promotion.

    Promotion rules:
      - FLOAT64 ⊕ INT64    → FLOAT64 (cast int64 → float64)
      - FLOAT64 ⊕ INT32    → FLOAT64 (cast int32 → int64 → float64)
      - FLOAT64 ⊕ FLOAT32  → FLOAT64 (cast float32 → float64; LOSSLESS)
      - FLOAT32 ⊕ INT64    → FLOAT32 (cast int64 → float32; LOSSY, and that is
                                      DuckDB v1.5.3's answer — see the block
                                      above `_cmp_widen_to_float64`)
      - FLOAT32 ⊕ INT32    → FLOAT32 (cast int32 → float32; LOSSY, same rule)
      - INT64   ⊕ INT32    → INT64   (cast int32 → int64)
      - same-type ⊕ same-type → no cast; delegate directly
      - any numeric ⊕ STRING (or other) → Error

    ⛔ THE TWO FLOAT DIRECTIONS ARE NOT ONE RULE. A pair with a FLOAT64 on it
    WIDENS; a float32-against-integer pair NARROWS. Collapsing them into
    "promote to the widest type" is a silent wrong answer on any integer past
    2**24 and no fixture of float32-exact values can see it.

    NULL CONTRACT: a row where EITHER operand is NULL comes back with DATA
    BIT 0 and a cleared validity bit saying why. See the block above.
    """
    var lt = left_col.arrow_type
    var rt = right_col.arrow_type

    # Same-type fast path — no cast, direct dispatch into the typed kernels.
    if lt == rt:
        if lt == ArrowType.FLOAT64:
            return _col_cmp_nullable[DType.float64](
                left_col.as_primitive[DType.float64](),
                right_col.as_primitive[DType.float64](),
                op,
            )
        elif lt == ArrowType.INT64:
            return _col_cmp_nullable[DType.int64](
                left_col.as_primitive[DType.int64](),
                right_col.as_primitive[DType.int64](),
                op,
            )
        elif lt == ArrowType.INT32:
            return _col_cmp_nullable[DType.int32](
                left_col.as_primitive[DType.int32](),
                right_col.as_primitive[DType.int32](),
                op,
            )
        elif lt == ArrowType.FLOAT32:
            # ⚠ COMPARED IN float32, NOT WIDENED. For a same-type pair the two
            # are equivalent (float32 -> float64 is lossless and strictly
            # order-preserving), so this arm is about cost, not semantics —
            # and it keeps the same-type path identical in shape to the three
            # above it.
            return _col_cmp_nullable[DType.float32](
                left_col.as_primitive[DType.float32](),
                right_col.as_primitive[DType.float32](),
                op,
            )
        elif lt == ArrowType.DECIMAL128:
            # A computed DECIMAL against another DECIMAL (`dec >= dec * 2`):
            # scale-aligned and exact, see `_cmp_decimal_mixed`.
            return _cmp_decimal_mixed(left_col^, right_col^, op)
        else:
            raise Error(
                "_eval_col_vs_col_promoted: unsupported same-type pair: "
                + String(lt)
            )

    var l_is_int = lt == ArrowType.INT64 or lt == ArrowType.INT32
    var r_is_int = rt == ArrowType.INT64 or rt == ArrowType.INT32
    var l_is_f32 = lt == ArrowType.FLOAT32
    var r_is_f32 = rt == ArrowType.FLOAT32
    var l_numeric = l_is_int or lt == ArrowType.FLOAT64 or l_is_f32
    var r_numeric = r_is_int or rt == ArrowType.FLOAT64 or r_is_f32

    if lt == ArrowType.DECIMAL128 or rt == ArrowType.DECIMAL128:
        return _cmp_decimal_mixed(left_col^, right_col^, op)

    if not (l_numeric and r_numeric):
        raise Error(
            "_eval_col_vs_col_promoted: unsupported column type pair: "
            + String(lt) + " vs " + String(rt)
        )

    # INT32 ⊕ INT64 — widen the int32 side to int64. Stays in the integer
    # domain (no float rounding), so this pair is NOT folded into the
    # float64 arm below.
    if l_is_int and r_is_int:
        return _col_cmp_nullable[DType.int64](
            _column_to_int64(left_col), _column_to_int64(right_col), op
        )

    # FLOAT32 ⊕ INT64 / INT32, in both orders — compared in FLOAT32, because
    # that is what DuckDB v1.5.3 does (see the block above this function; the
    # integer side NARROWS and the narrowing is observable). ⛔ THIS ARM MUST
    # STAY ABOVE THE float64 FALL-THROUGH: a float32-⊕-integer pair reaching
    # the widening arm below is a silent WRONG ANSWER on any integer past
    # 2**24, not an error.
    if (l_is_f32 and r_is_int) or (r_is_f32 and l_is_int):
        return _col_cmp_nullable[DType.float32](
            _cmp_narrow_to_float32(left_col),
            _cmp_narrow_to_float32(right_col),
            op,
        )

    # Any surviving mixed pair has a FLOAT64 on one side: FLOAT64 ⊕ INT64,
    # FLOAT64 ⊕ INT32 and FLOAT64 ⊕ FLOAT32, in both orders.
    # `_cmp_widen_to_float64` is validity-preserving on all four input types
    # and is a zero-copy `as_primitive` when the side is already FLOAT64.
    return _col_cmp_nullable[DType.float64](
        _cmp_widen_to_float64(left_col), _cmp_widen_to_float64(right_col), op
    )
