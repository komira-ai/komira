# =============================================================================
# predicate_compare: column comparison kernels for the predicate evaluator
# =============================================================================
#
# DECIMAL128 comparisons, the scalar comparison loops, the narrow-integer,
# FLOAT32, BOOLEAN and temporal column-vs-literal arms, and `_eval_col_vs_col`
# for two columns of the same Arrow type.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import read_bit_aligned_buffer
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.cast_null import eval_cast
from komira_column_kernels.comparison import (
    eval_eq,
    eval_ge,
    eval_gt,
    eval_le,
    eval_lt,
    eval_ne,
)
from komira_kernels.comparison_kleene import (
    NullPolicy,
    kleene_all_null_predicate,
    kleene_cmp_finalize,
    kleene_cmp_finalize_scalar,
)
from komira_plan_expr.expr import (
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
)
from komira_plan_expr.literal_domain import int_literal_fits
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_cast import decimal_rescale_i128, float_to_decimal_i128
from komira_scalar_arithmetic.decimal_compare import (
    DEC_CMP_EQ,
    DEC_CMP_GE,
    DEC_CMP_GT,
    DEC_CMP_LE,
    DEC_CMP_LT,
    DEC_CMP_NE,
    decimal_cmp_i128,
)

from .column_compare import _col_cmp_nullable
from .integer_literal_value import integer_literal_value
from .literal_arm_domain import refuse_incomparable_literal
from .temporal_literal_value import _temporal_literal_i64


# =============================================================================
# DECIMAL128 comparison helpers
# =============================================================================


def _bin_op_to_dec_cmp(op: UInt8) raises -> UInt8:
    if op == BIN_LT:
        return DEC_CMP_LT
    elif op == BIN_LE:
        return DEC_CMP_LE
    elif op == BIN_GT:
        return DEC_CMP_GT
    elif op == BIN_GE:
        return DEC_CMP_GE
    elif op == BIN_EQ:
        return DEC_CMP_EQ
    elif op == BIN_NE:
        return DEC_CMP_NE
    else:
        raise Error("Decimal128 compare: unsupported op " + String(Int(op)))


def _col_decimal_ps(batch: RecordBatch, col_idx: Int) -> Tuple[Int, Int]:
    ref c = batch.column_at(col_idx)
    if c.decimal_precision() > 0:
        return (c.decimal_precision(), c.decimal_scale())
    return (batch.schema.field_decimal_precision(col_idx), batch.schema.field_decimal_scale(col_idx))


def _eval_decimal_col_vs_literal(batch: RecordBatch, col_idx: Int, lit: ScalarValue, op: UInt8) raises -> BooleanArray:
    """DECIMAL128 column compared to a literal (decimal / int / float)."""
    var ps = _col_decimal_ps(batch, col_idx)
    var cp = ps[0]
    var cs = ps[1]
    if cp < 1:
        raise Error("Decimal128 predicate: column has no (precision, scale)")
    ref col_ref = batch.column_at(col_idx)
    var arr = col_ref.as_decimal128()
    var n = arr.length
    var dec_op = _bin_op_to_dec_cmp(op)
    # Materialize the RHS as (i128 value, scale).  A NULL literal -> all-NULL.
    var rhs_v: SIMD[DType.int128, 1]
    var rhs_s: Int
    if lit.is_null():
        # `col <op> NULL` is NULL for every row -> the
        # canonical all-null predicate (byte-identical to the prior inline
        # allocate-nullable + per-row clear loop).
        return kleene_all_null_predicate(n, NullPolicy.three_valued())
    elif lit.is_decimal128():
        rhs_v = lit.decimal_value_i128()
        rhs_s = lit.dec128_scale
        if rhs_s == 0 and lit.dec128_precision == 0:
            # Untyped decimal literal — treat its scale as the column's.
            rhs_s = cs
    elif lit.is_any_integer():
        # ★ THE ONE RULE (`integer_literal_value.mojo`): the literal's EXACT
        # value, read by its TAG, is what gets scale-aligned. This used to be
        # `lit.is_int` + `int_to_decimal_i128(lit.int_val, ...)`, which
        # REFUSED six of the eight integer tags ("unsupported literal type")
        # although `literal_arm_domain` admits `is_any_integer` against a
        # decimal column — and reading `int_val` would have turned a uint64
        # above Int64.MAX negative. `decimal_rescale_i128` from scale 0 is the
        # same multiply-and-check `int_to_decimal_i128` performs (and raises on
        # a literal wider than the column's precision exactly as it did).
        rhs_v = decimal_rescale_i128(integer_literal_value(lit), 0, cp, cs)
        rhs_s = cs
    elif lit.is_float():
        # Promote: build the decimal at the column's scale.  (NaN/Inf -> the
        # comparison is always false; mimic SQL by raising for now — rare.)
        var ov = float_to_decimal_i128(lit.float_val, cp, cs)
        if not ov:
            raise Error("Decimal128 predicate: float literal is NaN/Inf or out of range")
        rhs_v = ov.value()
        rhs_s = cs
    else:
        raise Error("Decimal128 predicate: unsupported literal type")
    # Compute the compare data on every lane, then delegate the 3VL
    # null policy to the ONE mechanism in comparison_kleene: it merges the
    # column's validity in (RHS literal is non-null here), masks null lanes
    # to data=0 (filter-safe), and sets null_count. Byte-identical output.
    var out = BooleanArray.allocate_nullable(n)
    for i in range(n):
        out.set(i, decimal_cmp_i128(arr.get_i128(i), cs, rhs_v, rhs_s, dec_op))
    return kleene_cmp_finalize_scalar(
        out^, arr.validity, NullPolicy.three_valued()
    )


def _eval_decimal_col_vs_col(batch: RecordBatch, lcol_idx: Int, rcol_idx: Int, op: UInt8) raises -> BooleanArray:
    """DECIMAL128 column vs DECIMAL128 column (scale-aligned compare)."""
    var lps = _col_decimal_ps(batch, lcol_idx)
    var rps = _col_decimal_ps(batch, rcol_idx)
    var ls = lps[1]
    var rs = rps[1]
    ref lref = batch.column_at(lcol_idx)
    ref rref = batch.column_at(rcol_idx)
    var larr = lref.as_decimal128()
    var rarr = rref.as_decimal128()
    var n = larr.length
    if rarr.length != n:
        raise Error("Decimal128 col-vs-col: length mismatch")
    var dec_op = _bin_op_to_dec_cmp(op)
    # Compute the compare data on every lane,
    # then delegate the 3VL null policy to the ONE mechanism: it merges BOTH
    # operands' validities (`result valid iff both valid`), masks null lanes to
    # data=0, and sets null_count. Byte-identical output.
    var out = BooleanArray.allocate_nullable(n)
    for i in range(n):
        out.set(i, decimal_cmp_i128(larr.get_i128(i), ls, rarr.get_i128(i), rs, dec_op))
    return kleene_cmp_finalize(
        out^, larr.validity, rarr.validity, NullPolicy.three_valued()
    )


# =============================================================================
# Temporal (DATE32 / TIMESTAMP* / TIME* / DURATION*) column-vs-literal compare
# =============================================================================
#
# Two bugs share ONE root cause and
# are fixed together here:
#
#   (a) SILENT-WRONG (the Q16-class bug): a temporal literal carries its value
#       in a DEDICATED ScalarValue field (`date32_val` for date32, `ts_micros`
#       for timestamp), NOT `int_val`. A date column is physically stamped
#       INT32 (Arrow DATE32 storage == int32; `Column.from_primitive` /
#       `RecordBatchBuilder.build` keep the physical stamp), so `col_ref(date)
#       < date '1995-03-15'` reached the INT32 arm below, which read
#       `lit_val.int_val` == 0 and evaluated `date_days(~9200) < 0` -> ALL-FALSE
#       -> every row silently dropped. Same shape for an INT64-stamped column vs
#       a timestamp literal (int_val == 0).
#
#   (b) LOUD-RAISE: a temporally-STAMPED column (DATE32 via `CAST(x AS DATE)`,
#       or any TIMESTAMP*/TIME*/DURATION* column) had no arm in `_eval_predicate`
#       at all and fell through to the else -> "unsupported column type".
#
# Fix: route BOTH shapes to one helper that (1) reads the column by its physical
# int width (int32 for DATE32/TIME32*, int64 otherwise), (2) derives the
# threshold from the RIGHT literal field, and (3) finalizes through the ONE
# converged kleene 3VL mechanism (`kleene_cmp_finalize_scalar`) so NULL lanes
# absorb correctly (nullable-safe; the plain int arms drop validity
# divergence #1). Covers all six comparison ops.
#
# SCOPE: col-vs-LITERAL only (the silent-wrong class). Temporal col-vs-col still
# loud-RAISES in `_eval_col_vs_col` (a separate, non-silent gap — follow-up).
# Timestamp literals are canonical micros; a micros literal vs a TIMESTAMP_S /
# TIMESTAMP_MS column needs lossy unit alignment and RAISES loudly (follow-up)
# rather than compare at the wrong unit.
# =============================================================================


@always_inline
def _scalar_cmp[
    dtype: DType
](
    arr: PrimitiveArray[dtype], thr: Scalar[dtype], op: UInt8
) raises -> BooleanArray:
    """Column-vs-scalar comparison over a primitive column -> raw data bits on
    ALL lanes (null lanes masked later by `kleene_cmp_finalize_scalar`).

    THE RAW HALF ONLY. Every caller MUST finalize through
    `kleene_cmp_finalize_scalar` — this returns what the SIMD compare-pack
    kernel computed over the value buffer, which does not read validity. See
    the DISPATCHER NULL CONTRACT block above `_eval_predicate`.
    """
    if op == BIN_GT:
        return eval_gt[dtype](arr, thr)
    elif op == BIN_LT:
        return eval_lt[dtype](arr, thr)
    elif op == BIN_EQ:
        return eval_eq[dtype](arr, thr)
    elif op == BIN_NE:
        return eval_ne[dtype](arr, thr)
    elif op == BIN_GE:
        return eval_ge[dtype](arr, thr)
    elif op == BIN_LE:
        return eval_le[dtype](arr, thr)
    else:
        raise Error(
            "predicate: unsupported comparison op "
            + String(Int(op))
            + " for column dtype "
            + String(dtype)
        )


@always_inline
def _scalar_cmp_i32_widening(
    arr: PrimitiveArray[DType.int32], thr64: Int64, op: UInt8
) raises -> BooleanArray:
    """THE INT32 COLUMN vs INT64 LITERAL raw compare, evaluated in a domain that
    CONTAINS BOTH OPERANDS.

    Every caller of this used
    to spell `Scalar[DType.int32](Int32(Int(thr64)))`, which is not a range
    check — it KEEPS THE LOW 32 BITS. `x = 4294967296` executed as `x = 0`,
    selected the wrong rows and raised nothing. The literal arrives as an Int64
    (`ScalarValue.int_val`) and the column is int32, so the two operands live in
    different domains; the comparison must be done in the one that holds both.

    IN RANGE -> the int32 kernel, byte-identical to the pre-fix path and with no
    added allocation (`int_literal_fits` compiles to one compare pair).
    OUT OF RANGE -> WIDEN THE COLUMN, never narrow the literal. Widening cannot
    change an answer; narrowing already did.

    ⚠ RAW BITS ONLY, on BOTH arms. The caller finalizes through
    `kleene_cmp_finalize_scalar` with the ORIGINAL array's validity and offset —
    NOT the widened copy's. `eval_cast` clones the input bitmap from BIT 0 while
    honouring `offset` on the values (see `eval_column.mojo`'s header on
    the offset-blind validity readers), so the widened copy's own validity is not
    a thing to trust on a sliced column. Its VALUES are, and its values are all
    this needs: `eval_cast` reads through `col.view_ro`, which starts at
    `arr.offset`, so lane i of the raw mask is logical row i on both arms.
    """
    if int_literal_fits[DType.int32](thr64):
        return _scalar_cmp[DType.int32](
            arr, Scalar[DType.int32](thr64.cast[DType.int32]()), op
        )
    var widened = eval_cast[DType.int32, DType.int64](arr)
    return _scalar_cmp[DType.int64](widened, Scalar[DType.int64](thr64), op)


# =============================================================================
# ★★ THE NARROW / UNSIGNED-NARROW / FLOAT32 / BOOL COLUMN ARMS
# =============================================================================
#
# ⛔ WHAT WAS WRONG: the ladder in `_eval_predicate` had arms for INT64, INT32,
# UINT64, FLOAT64, DECIMAL128, DICTIONARY, STRING and LARGE_STRING and NOTHING
# ELSE, so `WHERE v > 0` over an `int8` / `int16` / `uint8` / `uint16` /
# `uint32` / `float32` column, or `WHERE v = TRUE` over a `bool` one, fell to the
# `else` and raised `unsupported column type for predicate: <t>`. MEASURED on the
# cross-surface matrix: 80 units over 18 cells, and DuckDB
# v1.5.3 answers every one of those 18 (`cross_surface_duckdb_oracle.tsv`).
#
# ⛔⛔ AND THE HALF THAT GETS SKIPPED IS THE **FLOAT LITERAL**. Each arm is
# selected by the COLUMN's type and then reads ONE `ScalarValue` field; an
# unpopulated field is a WELL-FORMED ZERO. A UINT64 arm reading `int_val` answers
# a float literal as 0 (`5 rows, want 3`), and a float literal is not exotic:
# a front end that has no integer literal at all (a spreadsheet formula, say)
# folds every number with `ScalarValue.from_float`. `literal_arm_domain` does
# not stop it: `col_at.is_numeric`
# up, and a new integer arm inherits the admission without the promotion. So both
# helpers below exist, and the ladder picks between them on `lit.is_float`.
#
# ⚠ THE REPAIR FOR A NARROW INTEGER IS **NOT** THE ONE UINT64 NEEDED.
# `_u64_cmp_vs_float_literal` moves the THRESHOLD because a Float64 cannot hold
# every UInt64 (`2**64-1` and `2**64-2` are ONE Float64). Every value of int8,
# int16, int32, uint8, uint16 and uint32 IS exactly representable in Float64, so
# for these widths promoting the COLUMN is exact and is the simpler, already-
# established INT-col vs float-literal promotion shape. The distinction is the whole reason the two are
# separate functions rather than one parameterised one.


def _eval_narrow_int_arm[
    dtype: DType
](
    var arr: PrimitiveArray[dtype], lit: ScalarValue, op: UInt8
) raises -> BooleanArray:
    """INT8 / INT16 / UINT8 / UINT16 / UINT32 column vs an int OR float literal.

    ⛔ WIDEN THE COLUMN, NEVER NARROW THE LITERAL — the int32 literal-domain rule
 at four more widths. `Int8(128)` is `-128`, so a narrowing
    cast answers `v > 128` as `v > -128`: TRUE for five of six rows instead of
    NONE. All five widths fit in int64 losslessly, so the widened comparison
    answers exactly the question the narrow one would.

    ⛔⛔ AND THE FLOAT BRANCH IS THE HALF THAT GETS SKIPPED. An unpopulated
    `ScalarValue` field is a WELL-FORMED ZERO, so an arm reading `int_val` on a
    `from_float` literal evaluates `v > 0` for `v > 0.5` — and a
    spreadsheet-formula front end sends a float for EVERY numeric predicate
    (a formula has no integer literal at all).
    `literal_arm_domain` does NOT catch it: `col_at.is_numeric` deliberately
    admits a float literal so the INT64/INT32 promotion can pick it up, and a new
    integer arm inherits the admission without the promotion: a UINT64 arm
    without it answers `5 rows, want 3`.

    ⚠ FLOAT64 IS THE RIGHT DOMAIN **HERE** AND THE WRONG ONE FOR UINT64. Every
    value of int8/int16/uint8/uint16/uint32 is exactly representable in Float64,
    so promoting the column is lossless. `2**64-1` and `2**64-2` are ONE Float64,
    which is why `_u64_cmp_vs_float_literal` moves the THRESHOLD instead. That
    distinction is the reason these are two functions.

    ⚠ VALIDITY AND OFFSET COME FROM THE **SOURCE** ARRAY, not the widened copy —
    `eval_cast` clones the bitmap from BIT 0 while honouring `offset` on the
    values, so the copy's own bitmap is not a thing to trust on a sliced column.
    Its VALUES are, and that is all this needs. Same contract as
    `_scalar_cmp_i32_widening`."""
    var raw: BooleanArray
    if lit.is_float():
        var fcol = eval_cast[dtype, DType.float64](arr)
        raw = _scalar_cmp[DType.float64](
            fcol, Scalar[DType.float64](lit.float_val), op
        )
    else:
        var icol = eval_cast[dtype, DType.int64](arr)
        raw = _scalar_cmp[DType.int64](
            icol, Scalar[DType.int64](lit.int_val), op
        )
    return kleene_cmp_finalize_scalar(
        raw^, arr.validity, NullPolicy.three_valued(), arr.offset
    )


def _eval_float32_col_vs_literal(
    var arr32: PrimitiveArray[DType.float32], lit: ScalarValue, op: UInt8
) raises -> BooleanArray:
    """FLOAT32 column vs a float OR int literal, COMPARED IN FLOAT64.

    ⛔⛔ THE DOMAIN IS THE POINT AND ROUNDING THE THRESHOLD IS THE BUG.
    `ScalarValue.float_val` is a Float64 and the column is float32, so the two
    operands live in different domains and the comparison must happen in the one
    that CONTAINS BOTH. `Float32(1.00000006)` is exactly `1.0000001192092896`, so
    narrowing the threshold answers `v >= 1.00000006` as `v >= 1.0000001192…` and
    ADMITS the `1.0` row that is strictly BELOW the real threshold — silently, one
    row wrong. Float32 -> Float64 is exact (24-bit significand into 53, 8-bit
    exponent into 11), so widening the COLUMN cannot change an answer.

    ⚠ AN INTEGER LITERAL NEVER REACHES THIS FUNCTION. The SQL door spells
    `v > 3` with `ScalarValue.from_int`, whose `float_val` is a well-formed
    ZERO; `_eval_predicate` hands every integer literal, of every tag, to
    `read_integer_literal_for_column` first, which turns it into DuckDB's
    `CAST(<integer> AS FLOAT)` — a FLOAT threshold, so this compare in Float64
    is the FLOAT compare DuckDB performs (`f32 = 16777217` selects the
    16777216.0 row there). It used to read `Float64(int_val)` here, EXACTLY,
    which DuckDB does not do and which read a uint64 above Int64.MAX as a
    negative number. Anything else arriving here is REFUSED, never read as the
    zero its `float_val` holds."""
    if not lit.is_float():
        raise Error(
            "PipelineCompiler: the FLOAT32 arm was handed the non-float literal "
            + String(lit)
            + "; an integer literal must be read by"
            " `read_integer_literal_for_column` before it reaches an arm"
        )
    var wide = eval_cast[DType.float32, DType.float64](arr32)
    var raw = _scalar_cmp[DType.float64](
        wide, Scalar[DType.float64](lit.float_val), op
    )
    return kleene_cmp_finalize_scalar(
        raw^, arr32.validity, NullPolicy.three_valued(), arr32.offset
    )


def _eval_bool_col_vs_literal(
    col_ptr: Column[HeapRegion], lit: ScalarValue, op: UInt8
) raises -> BooleanArray:
    """BOOL column vs a BOOL literal — the corpus's `eq_only` cell, and 40 of the
    80 refused cross-surface units.

    ⚠ BOOL IS BIT-PACKED, so none of the `_scalar_cmp` primitive kernels can read
    it: there is no fixed per-element byte width to load. The column is
    materialised as an int8 `0`/`1` rank and compared there, which also gives
    `FALSE < TRUE` for the ordered operators for free — DuckDB answers
    `false < true`, and refusing `>` over a bool while answering `=` would be an
    operator-shaped hole inside a type we claim to serve.

    ⛔ IT READS THE BITS ITSELF RATHER THAN CALLING `Column.as_boolean`, AND
    THAT IS DELIBERATE: `as_boolean` copies both bitmaps FROM BIT 0 and sets
    `length = _length`, i.e. it is OFFSET-BLIND, so a sliced BOOL column (post
    join, post concat) would come back shifted. `read_bit_aligned_buffer` is the
    shared scalar bit read with the index `_offset + row` in BIT space — never
    scaled by an element width — which is exactly the primitive a sliced BOOL
    column needs, and the validity bitmap is indexed the same way. Same shape as
    `sort_multi`'s BOOL sort arm and the join gather arms.

    ⛔ THE RANK IS NOT THE VALIDITY. The rank is rebased to logical row 0 AND
    carries its own copy of the source's validity window, so 3VL is imposed by
    the ONE `kleene_cmp_finalize_scalar` seam exactly as every other arm does it:
    a NULL row is UNKNOWN and `filter` drops it, whatever its data bit holds."""
    if not lit.is_bool():
        # Unreachable through `_eval_predicate` — `literal_arm_domain` already
        # refuses a non-bool literal against a BOOL column with the
        # `EVAL_INCOMPARABLE_LITERAL` message. Stated so this helper is safe to
        # call from anywhere.
        refuse_incomparable_literal(
            ArrowType.BOOL, lit, String("bool predicate")
        )
    var n = col_ptr._length
    var bit_base = col_ptr._offset
    var has_validity = col_ptr._validity.__bool__()
    var rank = PrimitiveArray[DType.int8].allocate_nullable(
        n
    ) if has_validity else PrimitiveArray[DType.int8].allocate(n)
    for r in range(n):
        if read_bit_aligned_buffer(col_ptr._data, bit_base + r):
            rank.set(r, Int8(1))
        # else: `allocate` / `allocate_nullable` zero-init, so FALSE is already 0.
    if has_validity:
        ref bm = col_ptr._validity.value()
        for r in range(n):
            if not bm.test(bit_base + r):
                rank._set_null(r)
    var thr = Int8(1) if lit.bool_val else Int8(0)
    var raw = _scalar_cmp[DType.int8](rank, Scalar[DType.int8](thr), op)
    # `rank` is rebased to logical row 0 and owns the window's validity, so the
    # finalize offset is `rank.offset` (zero), not the source column's.
    return kleene_cmp_finalize_scalar(
        raw^, rank.validity, NullPolicy.three_valued(), rank.offset
    )


def _eval_temporal_col_vs_literal(
    batch: RecordBatch, col_idx: Int, lit: ScalarValue, op: UInt8, col_at: ArrowType
) raises -> BooleanArray:
    """DATE32 / DATE64 / TIME* / TIMESTAMP* / DURATION* (or an int32/int64-
    physically-stamped temporal) column compared to a temporal/int literal.

    Reads the column by its physical int width, derives the threshold from the
    literal's correct field, runs the raw scalar compare, and finalizes through
    the ONE kleene 3VL mechanism (NULL lanes absorb to data=0)."""
    ref col_ref = batch.column_at(col_idx)
    var thr64 = _temporal_literal_i64(lit, col_at)
    # int32-physical: DATE32 / TIME32_* (and a plain INT32-stamped date column).
    var use_i32 = (
        col_at == ArrowType.DATE32
        or col_at == ArrowType.TIME32_S
        or col_at == ArrowType.TIME32_MS
        or col_at == ArrowType.INT32
    )
    if use_i32:
        var arr = col_ref.as_primitive[DType.int32]()
        # a DATE32 / TIME32_* / INT32-stamped temporal
        # column against a literal outside int32 range widens instead of
        # truncating. Reached from the SQL corpus via
        # `_temporal_column_reads_int_literal`, which correctly
        # let a temporal column admit an integer literal and thereby put a
        # second column type onto this arm.
        var raw = _scalar_cmp_i32_widening(arr, thr64, op)
        return kleene_cmp_finalize_scalar(
            raw^, arr.validity, NullPolicy.three_valued()
        )
    else:
        var arr = col_ref.as_primitive[DType.int64]()
        var raw = _scalar_cmp[DType.int64](arr, Scalar[DType.int64](thr64), op)
        return kleene_cmp_finalize_scalar(
            raw^, arr.validity, NullPolicy.three_valued()
        )


# =============================================================================
# Column-vs-column comparison helper
# =============================================================================


def _eval_col_vs_col(
    batch: RecordBatch,
    left_idx: Int,
    right_idx: Int,
    col_type: ArrowType,
    op: UInt8,
) raises -> BooleanArray:
    """Evaluate a comparison between two columns of the same type.

    Supports GT, LT, EQ, NE, GE, LE for INT64, INT32, FLOAT64 and FLOAT32
    columns.

    NULL CONTRACT: finalizes through the ONE
    kleene mechanism, exactly as the DECIMAL128 sibling
    (`_eval_decimal_col_vs_col`) already did. Pre-fix these three arms returned
    the raw `eval_col_*` kernel — a NON-nullable mask computed off the value
    buffers alone — so `a > b` selected rows where either operand was NULL.

    Args:
        batch: The RecordBatch containing both columns.
        left_idx: Column index for the left operand.
        right_idx: Column index for the right operand.
        col_type: ArrowType of the left column (right must match or be coerced).
        op: Comparison operator tag.

    Returns:
        BooleanArray with comparison result. Nullable iff either operand is.
    """
    # SAFETY: left_idx and right_idx are valid indices into batch._columns,
    # resolved by _resolve_col_index from column names in the predicate.
    ref left_col = batch.column_at(left_idx)
    ref right_col = batch.column_at(right_idx)

    if col_type == ArrowType.FLOAT64:
        return _col_cmp_nullable[DType.float64](
            left_col.as_primitive[DType.float64](),
            right_col.as_primitive[DType.float64](),
            op,
        )

    elif col_type == ArrowType.INT64:
        return _col_cmp_nullable[DType.int64](
            left_col.as_primitive[DType.int64](),
            right_col.as_primitive[DType.int64](),
            op,
        )

    elif col_type == ArrowType.INT32:
        return _col_cmp_nullable[DType.int32](
            left_col.as_primitive[DType.int32](),
            right_col.as_primitive[DType.int32](),
            op,
        )

    elif col_type == ArrowType.FLOAT32:
        # ★ FLOAT32.
        # THE SECOND OF THE TWO column-vs-column sites, and the one that made
        # the defect a MISSING TYPE rather than a promotion gap: two float32
        # columns of IDENTICAL declared type — nothing to widen — refused here
        # ("unsupported column type: float32") without ever reaching
        # `_eval_col_vs_col_promoted`. A same-type pair compares IN float32;
        # widening would be lossless and order-preserving but buys nothing.
        # ⚠ THE MIXED PAIRS ARE NOT THIS FUNCTION'S: they go to
        # `_eval_col_vs_col_promoted`, where the promotion DIRECTION is the
        # whole question (float32 ⊕ float64 widens, float32 ⊕ integer narrows —
        # DuckDB v1.5.3, measured; see the block above that function).
        return _col_cmp_nullable[DType.float32](
            left_col.as_primitive[DType.float32](),
            right_col.as_primitive[DType.float32](),
            op,
        )

    else:
        raise Error("_eval_col_vs_col: unsupported column type: " + String(col_type))
