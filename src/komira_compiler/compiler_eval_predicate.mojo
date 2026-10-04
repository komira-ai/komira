# =============================================================================
# compiler_eval_predicate — predicate evaluation + predicate lowering
# =============================================================================
#
# Contains:
#   _eval_col_vs_col         — col-vs-col compare, same Arrow type
#   _eval_short_circuit_and  — selective 4-case AND
#   _eval_short_circuit_or   — 2-case OR
#   _eval_predicate          — THE predicate entry point (Expr -> BooleanArray)
#   lower_filter_predicate   — SDK Expr -> ExprPool ExprId (unfused-scan path)
#
# `_eval_col_vs_col_promoted` lives in compiler_eval_column.mojo (it pairs
# with the binary col-col arithmetic + promotion logic); it is called from
# `_eval_predicate` via a cross-module import.
# =============================================================================

from std.sys import simd_width_of

from komira_core.arrow.schema import RecordBatch
from komira_core.arrow.column import Column
from komira_core.arrow.dict_code_bounds import validate_dict_codes
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.large_string_array import LargeStringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap, read_bit_aligned_buffer
from komira_core.io.heap_region import HeapRegion
from komira_core.eval.comparison import (
    eval_gt, eval_lt, eval_eq,
    eval_ne, eval_le, eval_ge,
    eval_col_gt, eval_col_lt, eval_col_eq,
    eval_col_ne, eval_col_le, eval_col_ge,
    filter_to_indices,
)
from komira_core.eval.string_comparison import (
    eval_string_eq, eval_string_ne, eval_string_gt, eval_string_lt, eval_string_ge, eval_string_le,
    eval_string_contains, eval_string_starts_with, eval_string_ends_with, eval_string_like,
    eval_large_string_eq, eval_large_string_ne, eval_large_string_gt, eval_large_string_lt,
    eval_large_string_ge, eval_large_string_le,
    eval_large_string_contains, eval_large_string_starts_with, eval_large_string_ends_with,
    eval_large_string_like,
)
from komira_core.eval.arithmetic import eval_and, eval_or, eval_not
from komira_kernels.comparison_kleene import (
    NullPolicy,
    kleene_cmp_finalize,
    kleene_cmp_finalize_scalar,
    kleene_all_null_predicate,
    eval_col_gt_nullable, eval_col_lt_nullable, eval_col_eq_nullable,
    eval_col_ne_nullable, eval_col_le_nullable, eval_col_ge_nullable,
)
from komira_core.eval.cast_null import eval_cast
from komira_core.eval.dict_filter import (
    DictFilterOp,
    dict_filter_eval_bool_mask,
    dict_filter_eval_bool_mask_column,
)
from komira_kernels.match_fn import MatchFn
from komira_kernels.builtin_match_fns import (
    LtI64, LeI64, GtI64, GeI64, EqI64, NeI64,
    LtF64, LeF64, GtF64, GeF64, EqF64, NeF64,
)
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.eval.decimal_compare import (
    decimal_cmp_i128,
    DEC_CMP_LT, DEC_CMP_LE, DEC_CMP_GT, DEC_CMP_GE, DEC_CMP_EQ, DEC_CMP_NE,
)
from komira_core.eval.decimal_cast import decimal_rescale_i128, float_to_decimal_i128
from komira_core.plan.scalar_value import ScalarValue
from .expr_id import ExprId
from .expr_pool import ExprPool
from .compiler_eval_in_list import _eval_in_list
from .numeric_dict_lut_scan import numeric_dict_codes_to_mask
from komira_core.plan.literal_domain import int_literal_fits
from .temporal_literal_value import _temporal_literal_i64
from .integer_literal_value import (
    integer_literal_value,
    mirror_comparison,
    number_dtype_of,
    read_integer_literal_for_column,
)
from .literal_arm_domain import (
    check_literal_against_column,
    refuse_incomparable_literal,
)
from .compiler_eval_column import (
    _eval_column_expr,
    _eval_col_vs_col_promoted,
    # THE ONE col-vs-col null seam. It lives in `compiler_eval_column` (the
    # LOWER module — predicate imports column, not the reverse) so that
    # `_eval_col_vs_col` here and `_eval_col_vs_col_promoted` there route
    # through the SAME dispatch instead of growing a second convention.
    _col_cmp_nullable,
    # Lane G: `as_string`'s values without its copy where the column allows
    # it. Every string predicate below READS its input once and drops it.
    string_array_of,
)
from .compiler_eval_dict import _materialize_dict_to_string
from .arm_rows import batch_nulled_outside, undecided_rows
from komira_core.eval.int_overflow import is_int_overflow_error
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.regexp_functions import (
    eval_regexp_like,
    eval_regexp_full_match,
    compile_full_match_program,
    split_g_flag,
)
from komira_core.plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_AGG_FN,
    EXPR_IN_LIST,
    EXPR_REGEXP,
    REGEXP_LIKE,
    REGEXP_FULL_MATCH,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_NOT,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    STR_CONTAINS,
    STR_STARTS_WITH,
    STR_ENDS_WITH,
    STR_LIKE,
)
from komira_core.helpers.compiler_helpers import (
    resolve_col_index,
    expr_resolves_to_column,
    copy_column,
    broadcast_scalar,
    gather_batch,
)


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
    honouring `offset` on the values (see `compiler_eval_column.mojo`'s header on
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


# =============================================================================
# Numeric-dict predicate-over-codes LUT
# =============================================================================
#
# STRUCTURAL MIRROR of `dict_filter_eval_bool_mask` (the production STRING-dict
# filter-over-codes path, `komira_core/eval/dict_filter.mojo`). The string kernel:
#   Phase 1: evaluate the predicate against the D dictionary ENTRIES -> a
#            D-sized keep-bit buffer (`dict_match`).
#   Phase 2: scan the N per-row CODES against the keep-bit buffer, packing one
#            bit per row -> a non-nullable BooleanArray.
#
# This is the NUMERIC analogue. It KILLS the v1 densification band-aid
# (`resolve_numeric_dict_to_flat` + `_resolve_numeric_dict_cols_to_flat`) whose
# own docstring admits it "re-introduces the per-row gather AT FILTER TIME".
# Instead of materializing N flat values then comparing N times, we resolve the
# <= dict_size DISTINCT entries ONCE (`dict_value_i64` / `dict_value_f64`),
# compare each against the encoded literal to build a D-sized keep-bit LUT, then
# scan the N codes against the LUT. Cost: O(D) compares + O(N) int lookups.
#
# BYTE-IDENTICAL to `resolve_numeric_dict_to_flat` then dispatching the flat
# compare kernels (`eval_gt[int64]`, ...): same value resolution per code (the
# SAME `dict_value_*(dict_code_at(r))` gather the flat decode performs), the
# SAME threshold encoding (int dicts compare `lit_val.int_val`; float dicts
# compare `lit_val.float_val`; int32 truncates to the low 32 bits exactly as
# the flat write does), and the SAME non-nullable BooleanArray output shape
# (one data bit per row; the per-row null-collapse is applied separately by the
# caller via the dict column's row-validity bitmap — UNCHANGED).
#
# SILENT-WRONG GUARD (two-distinct-dict): this helper ONLY fires on the
# `col_ref OP literal` shape (the dispatcher's numeric-dict arm). A
# numeric-dict-col vs numeric-dict-col comparison routes to `_eval_col_vs_col`
# (both columns are arrow_type==DICTIONARY), which has NO DICTIONARY arm and
# RAISES — so a meaningless code-vs-code compare across DIFFERENT per-RG
# dictionaries is structurally impossible (it declines to the value domain
# upstream). Do NOT add a DICTIONARY arm to `_eval_col_vs_col`.
# =============================================================================


@always_inline
def _numeric_dict_keep_int(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Int64
) raises -> List[Bool]:
    """Phase 1 (INT dict): build the per-CODE keep-bit LUT by resolving each
    of the `dict_size` distinct entries to its Int64 value and comparing it
    against `threshold`. Index = dict code; value = does this entry pass."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_i64(code)
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for int dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_int32(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Int32
) raises -> List[Bool]:
    """Phase 1 (INT32 dict): as `_numeric_dict_keep_int`, but the entry value
    is truncated to the low 32 bits FIRST (byte-identical to the flat int32
    write `dict_value_i64(code) & 0xFFFFFFFF` then an Int32 compare)."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        # Mirror resolve_numeric_dict_to_flat int32 arm: low-32-bit truncation.
        var v = Int32(
            Int((col_ptr.dict_value_i64(code) & Int64(0xFFFFFFFF)))
        )
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for int32 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_f64(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Float64
) raises -> List[Bool]:
    """Phase 1 (FLOAT64 dict): build the keep-bit LUT comparing each entry's
    Float64 value against `threshold`."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_f64(code)
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for float64 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


@always_inline
def _numeric_dict_keep_f32(
    col_ptr: Column[HeapRegion], op: UInt8, threshold: Float64
) raises -> List[Bool]:
    """Phase 1 (FLOAT32 dict): build the keep-bit LUT comparing each entry's
    Float32 value (down-cast from the f64 accessor, byte-identical to the flat
    float32 write) against `threshold` — IN FLOAT64.

    ⛔ THE THRESHOLD IS NOT NARROWED. Arriving as
    `Float32(lit_val.float_val)` would round a Float64 threshold onto a
    Float32 neighbour and merge two distinct thresholds — the defect the FLAT
    float32 arm (`_eval_float32_col_vs_literal`) documents and avoids by
    widening the COLUMN: `dict<f32> [1.0, 1.0000001192092896]  v > 1.00000006`
    would answer `00` here and `01` on the flat arm; DuckDB compares FLOAT
    against DOUBLE in DOUBLE. Widening the entry
    back to Float64 is exact, so this is the Float32 value compared in the
    domain holding both operands."""
    var d = col_ptr.dict_size()
    var keep = List[Bool](capacity=d)
    for code in range(d):
        var v = col_ptr.dict_value_f64(code).cast[DType.float32]().cast[
            DType.float64
        ]()
        var pass_: Bool
        if op == BIN_GT:
            pass_ = v > threshold
        elif op == BIN_LT:
            pass_ = v < threshold
        elif op == BIN_EQ:
            pass_ = v == threshold
        elif op == BIN_NE:
            pass_ = v != threshold
        elif op == BIN_GE:
            pass_ = v >= threshold
        elif op == BIN_LE:
            pass_ = v <= threshold
        else:
            raise Error(
                "numeric-dict LUT: unsupported op for float32 dict: " + String(Int(op))
            )
        keep.append(pass_)
    return keep^


def numeric_dict_filter_bool_mask(
    col_ptr: Column[HeapRegion], op_in: UInt8, lit_in: ScalarValue
) raises -> BooleanArray:
    """Predicate-over-codes for a NUMERIC dictionary column.

    Mirrors `dict_filter_eval_bool_mask` (string path). Phase 1 builds a
    `dict_size`-element keep-bit LUT (one compare per DISTINCT entry); Phase 2
    scans the N per-row codes (`dict_code_at`) against the LUT, packing one bit
    per row into a non-nullable BooleanArray (the SAME output shape the flat
    compare kernels produce). Byte-identical to
    `resolve_numeric_dict_to_flat` + the flat dispatch.

    Precondition: `col_ptr.is_numeric_dict` is True (the dispatcher gates on
    it). Routes on `dict_value_dtype` for the four numeric value widths.

    ★ THE ONE RULE FIRST (`integer_literal_value.mojo`). The FLOAT arms below read
    `float_val` and the INT arms `int_val`, chosen by the DICTIONARY's value
    type — so an INTEGER literal against a FLOAT dictionary read a well-formed
    ZERO (`dict<f64> [0.5,3,10]  v > 3` answered 111), and a uint64 literal
    above Int64.MAX against an INT dictionary read negative. Both are now read
    by their TAG before any arm sees them. Idempotent, so the dispatcher having
    already applied it costs nothing but a copy.
    """
    var vdt = col_ptr.dict_value_dtype()
    var op = op_in
    var lit_val = lit_in.copy()
    read_integer_literal_for_column(vdt, lit_val, op)

    # Phase 1: resolve each distinct entry ONCE, compare vs the encoded literal.
    var keep: List[Bool]
    if vdt == DType.int64:
        keep = _numeric_dict_keep_int(col_ptr, op, lit_val.int_val)
    elif vdt == DType.int32:
        # an INT64 literal outside int32
        # range cannot be a threshold for the int32 LUT — narrowing it kept the
        # LOW 32 BITS. WIDEN instead: `_numeric_dict_keep_int` compares the
        # entry's own `dict_value_i64(code)` against the FULL-WIDTH literal, and
        # for a well-formed int32 dictionary that value IS the int32 entry
        # sign-extended, so this is the same comparison done in the wider
        # domain. (What it is NOT is a change to the ENTRY-side truncation
        # `_numeric_dict_keep_int32` performs to mirror
        # `resolve_numeric_dict_to_flat` — that is a data-side question about a
        # malformed dictionary and is deliberately untouched.)
        if int_literal_fits[DType.int32](lit_val.int_val):
            keep = _numeric_dict_keep_int32(
                col_ptr, op, lit_val.int_val.cast[DType.int32]()
            )
        else:
            keep = _numeric_dict_keep_int(col_ptr, op, lit_val.int_val)
    elif vdt == DType.float64:
        keep = _numeric_dict_keep_f64(col_ptr, op, lit_val.float_val)
    elif vdt == DType.float32:
        keep = _numeric_dict_keep_f32(col_ptr, op, lit_val.float_val)
    else:
        raise Error(
            "numeric-dict LUT: unsupported dict value dtype: " + String(vdt)
        )

    # Phase 2: scan the N codes against the keep-bit LUT, pack into a Bitmap.
    # A hoisted-width, branch-free byte-LUT scan (`numeric_dict_lut_scan`):
    # the per-row `dict_code_at` + `List[Bool]` loop it replaces was 19.3% of
    # ClickBench Q07's cycles. Same bits, same shape.
    return numeric_dict_codes_to_mask(col_ptr, keep)


def numeric_dict_filter_via_flat(
    col_ptr: Column[HeapRegion], op_in: UInt8, lit_in: ScalarValue
) raises -> BooleanArray:
    """The v1 densification path (RETAINED as the byte-verify oracle + the
    flag-OFF default): resolve the numeric-dict column to FLAT, then dispatch
    the same col-vs-literal compare kernels. This re-introduces the per-row
    gather AT FILTER TIME — the band-aid `numeric_dict_filter_bool_mask`
    replaces. Kept as the LUT's differential oracle.

    ★ THE SAME ONE RULE AS THE LUT, AND IT MUST BE: a literal read differently
    here would make the differential test red on the correct answer.
    """
    var op = op_in
    var lit_val = lit_in.copy()
    read_integer_literal_for_column(col_ptr.dict_value_dtype(), lit_val, op)
    var flat_col = col_ptr.resolve_numeric_dict_to_flat()
    var flat_at = flat_col.arrow_type
    if flat_at == ArrowType.INT64:
        var arr = flat_col.as_primitive[DType.int64]()
        var threshold = Scalar[DType.int64](lit_val.int_val)
        if op == BIN_GT:
            return eval_gt[DType.int64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.int64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.int64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.int64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.int64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.int64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict int64: " + String(Int(op)))
    elif flat_at == ArrowType.INT32:
        var arr = flat_col.as_primitive[DType.int32]()
        # this is the LUT's byte-verify
        # ORACLE, so it must widen on exactly the same condition the LUT does —
        # a fix that moved only one of the two would make `_VERIFY` mode red on
        # the correct answer. `_scalar_cmp_i32_widening` is the same seam the
        # flat INT32 predicate arm uses.
        #
        # ⚠ THE FLAT COLUMN IS NOT NULLABLE HERE. `resolve_numeric_dict_to_flat`
        # produces the value plane; row validity is carried by the CODES and
        # applied by the caller's null-collapse, which is why this function
        # returns a raw mask and does not finalize. Unchanged by this edit.
        return _scalar_cmp_i32_widening(arr, lit_val.int_val, op)
    elif flat_at == ArrowType.FLOAT64:
        var arr = flat_col.as_primitive[DType.float64]()
        var threshold = Scalar[DType.float64](lit_val.float_val)
        if op == BIN_GT:
            return eval_gt[DType.float64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.float64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.float64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.float64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.float64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.float64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict float64: " + String(Int(op)))
    else:
        # float32 — compared IN FLOAT64, exactly as the LUT above now does (see
        # `_numeric_dict_keep_f32`): widening the column is exact, narrowing
        # the threshold (`Float32(lit_val.float_val)`, the old spelling here)
        # merged two thresholds. This is the LUT's byte-verify oracle, so the
        # two must move together.
        var arr32 = flat_col.as_primitive[DType.float32]()
        var arr = eval_cast[DType.float32, DType.float64](arr32)
        var threshold = Scalar[DType.float64](lit_val.float_val)
        if op == BIN_GT:
            return eval_gt[DType.float64](arr, threshold)
        elif op == BIN_LT:
            return eval_lt[DType.float64](arr, threshold)
        elif op == BIN_EQ:
            return eval_eq[DType.float64](arr, threshold)
        elif op == BIN_NE:
            return eval_ne[DType.float64](arr, threshold)
        elif op == BIN_GE:
            return eval_ge[DType.float64](arr, threshold)
        elif op == BIN_LE:
            return eval_le[DType.float64](arr, threshold)
        else:
            raise Error("PipelineCompiler: unsupported op for numeric-dict float32: " + String(Int(op)))



def _numeric_dict_filter_dispatch(
    col_ptr: Column[HeapRegion], op: UInt8, lit_val: ScalarValue
) raises -> BooleanArray:
    """Route a numeric-dict `col OP literal` predicate.

    The compute-over-codes LUT `numeric_dict_filter_bool_mask` is the ONLY
    production route. `numeric_dict_filter_via_flat` is retained as the
    DIFFERENTIAL ORACLE: `tests/test_numeric_dict_filter_lut_p3.mojo` calls it
    directly and byte-compares the two.
    """
    return numeric_dict_filter_bool_mask(col_ptr, op, lit_val)


# =============================================================================
# Filter-predicate lowering -- SDK Expr -> ExprPool ExprId
# =============================================================================
#
# The unfused path needs the plan compiler to hand the source a
# stable ExprId that resolves to the filter predicate, rather than the
# legacy fused path which carried the Expr inline through the operator
# tree. The lowering is a one-liner today -- the SDK predicate IS an Expr
# and ExprPool stores Exprs -- but keeping this behind a named function
# localizes the contract so that future lowerings (e.g. rewriting
# col_ref -> col_idx after projection resolution, flattening AND chains
# into stages) have a single entry point.
# =============================================================================


def lower_filter_predicate(
    mut pool: ExprPool, var predicate: Expr
) -> ExprId:
    """Register `predicate` in `pool` and return its handle.

    The returned `ExprId` is what gets threaded through
    `LoweredSourceHooks.set_decode_filter` (as a single-stage list) into
    a `MorselSourceImpl` that supports late materialization. The source
    then calls `pool.resolve(id)` per row group and hands the stored
    `Expr` into `_eval_predicate` -- the same evaluator the legacy fused
    path uses, so lowered predicates behave identically at runtime.

    Scope: single-predicate lowering (one `DataFrame.filter`
    call). Multi-stage chains (AND/OR flattening, cross-operator
    pushdown) land in later phases.

    Args:
        pool: The ExprPool owned by the plan compiler / test harness.
            Mutated: `predicate` is appended.
        predicate: The filter Expr to register. Consumed.

    Returns:
        The `ExprId` assigned by the pool (stable for its lifetime).
    """
    return pool.register(predicate^)


# =============================================================================
# Inner-BinaryOp short-circuit AND/OR
#
# Short-circuit is wired per-BinaryOp at the Expr-evaluator layer — distinct
# from the top-level conjunction-narrowing path (`evaluate_conjunction_select`,
# already ported in `engine/conjunction.mojo`). The conjunction path only
# fires for top-level AND chains that `flatten_and_conjuncts` flattens; the
# inner short-circuit fires for AND/OR sub-trees that the flattener can't
# reach (e.g. `(A AND B) OR (C AND D)` — the OR opaque to flatten, but each
# AND sub-tree still benefits from selective evaluation).
#
# Four cases per AND:
#   1. left_true == 0          -> all-false; right not evaluated
#   2. left_true == num_rows   -> result == right alone (left implied true)
#   3. left_true < num_rows/2  -> selective: gather batch to survivors,
#                                  eval right on the smaller batch, scatter back
#   4. else                     -> non-selective: eval right on full batch,
#                                  bitwise AND with left
#
# OR mirrors with cases 1/2 inverted (left_true == num_rows -> short-circuit
# all-true; left_true == 0 -> result == right alone). OR does not include
# the selective-filter case because the OR distribution doesn't get the same
# row-reduction benefit (rows where left=true must always pass without right
# evaluation — but the rows where left=false are exactly the ones that need
# right evaluation, so filtering doesn't reduce work; it's still O(num_rows)).
#
# ── ⭐ EVERY ONE OF THEM IS GUARDED BY `not left_mask.validity` ─────────────
#
# THE MECHANISM IN ONE LINE: all five cases branch on `left_true`, which counts
# DATA BITS, and a data bit of 0 means FALSE **or** UNKNOWN. Each identity is
# sound over the first reading and WRONG over the second:
#
#     AND case 1  `FALSE AND r = FALSE`   but `UNKNOWN AND FALSE` is FALSE,
#                 and this returns the left mask, which says UNKNOWN
#     AND case 2  `TRUE AND r = r`        (reachable with unknowns only if the
#                 data-bit-0-on-unknown invariant is broken upstream)
#     AND case 3  gathers to the rows whose data bit is set and scatters into a
#                 fresh array, so every left-UNKNOWN row is reported as a
#                 definite FALSE. (Its RIGHT-side UNKNOWNs are a separate
#                 defect, fixed in the scatter itself: see case 3's body.)
#     OR  case 2  `FALSE OR r = r`        but `UNKNOWN OR FALSE` is UNKNOWN
#
# ⛔ AND THE DIFFERENCE IS INVISIBLE AT A FILTER BOUNDARY AND INVERTED BY A
# NEGATION, which is why it survived: FALSE and UNKNOWN both fail a `WHERE`, so
# nothing that only ever looks at a top-level row set can see it. Put a `NOT`
# around the same node and FALSE becomes a selected row while UNKNOWN stays
# dropped. MEASURED against DuckDB 1.5.3 without the guard, over a null-pattern
# sweep: `NOT (tag='y3' AND note='zzz')` was
# CORRECT at all 18 sweep lengths and `NOT (note='zzz' AND tag='y3')` — the
# same predicate, operands swapped — was WRONG at 17 of them, because only the
# second spelling puts the nullable column on the left.
#
# ⚠ THIS IS THE TWIN OF A GUARD THAT ALREADY EXISTED. `conjunction.
# _predicate_3vl` reproduces three of these four identities and guards each
# with the same `if not l.validity`, and the block above `_normalize_3vl` there
# states the reason. These were the un-guarded copies; the two funnels now
# agree.
#
# ⚠ IT IS NOT A PERF REGRESSION ON A NON-NULLABLE COLUMN. `_apply_validity` and
# `kleene_cmp_finalize_scalar` attach a validity bitmap only when the input
# column HAS one, so an all-valid column reaches this function with
# `left_mask.validity` empty and takes exactly the path it took before. What
# pays is a predicate whose left arm is a nullable column, and what it pays is
# one full-batch evaluation of the right arm — the correct answer's price.
# =============================================================================


def _eval_short_circuit_and(
    left: Expr, right: Expr, batch: RecordBatch
) raises -> BooleanArray:
    """Short-circuit AND evaluation.
    """
    var left_mask = _eval_predicate(left, batch)
    var num_rows = batch.num_rows()
    var left_true = left_mask.true_count()

    # ⭐ ALL THREE SHORT-CIRCUITS ARE FULLY-KNOWN-ONLY.
    # See the block above this function for the measurement; the one-line
    # reason is that each of them reads `left_true`, a count over DATA BITS,
    # and a data bit of 0 means FALSE *or* UNKNOWN. Every identity below is
    # sound over the first reading and wrong over the second. A left mask
    # carrying validity falls through to case 4, whose `eval_and` is Kleene.
    if not left_mask.validity:
        # Case 1: all-false on left -> short-circuit, right never evaluated.
        if left_true == 0:
            return left_mask^

        # Case 2: all-true on left -> result is right alone.
        if left_true == num_rows:
            return _eval_predicate(right, batch)

        # Case 3: selective left (<50% pass) -> gather to survivors,
        #         eval right on smaller batch, scatter back.
        # The row-filter form is `compute::filter_record_batch` + a scatter loop;
        # the Mojo equivalent is `filter_to_indices` -> `gather_batch` ->
        # eval -> bit-by-bit scatter into a fresh full-width BooleanArray.
        if left_true < (num_rows >> 1):
            var indices = filter_to_indices(left_mask)
            var sub_batch = gather_batch(batch, indices)
            var right_filtered = _eval_predicate(right, sub_batch)
            # Scatter back. A row left made FALSE stays FALSE: `FALSE AND r`
            # is FALSE even when r is UNKNOWN. A survivor takes the RIGHT's
            # value, `TRUE AND r = r`, and that INCLUDES an UNKNOWN r.
            #
            # ⛔ THE SCATTER USED TO COPY ONLY THE RIGHT'S DATA BITS into a
            # non-nullable array, so `TRUE AND UNKNOWN` came back FALSE and an
            # enclosing NOT turned it into a SELECTED row: `NOT (k < 3 AND
            # flag)` selected the rows where `flag` is NULL. The guard above
            # covers an UNKNOWN on the LEFT only. So the result is nullable
            # exactly when the right mask is (as `eval_and` in case 4 does),
            # and a fully-known right still yields a non-nullable result at no
            # extra cost. Falsifier: `test_and_case3_*` in
            # `komira_compiler/tests/test_short_circuit_inner_binop.mojo`.
            var right_nullable = Bool(right_filtered.validity)
            var result = BooleanArray.allocate_nullable(
                num_rows
            ) if right_nullable else BooleanArray.allocate(num_rows)
            var fi = 0
            for i in range(num_rows):
                if left_mask.data.test(i):
                    var right_known = (
                        not right_nullable
                        or right_filtered.validity.value().test(fi)
                    )
                    if not right_known:
                        # TRUE AND UNKNOWN = UNKNOWN. The data bit stays 0,
                        # this repo's encoding of an UNKNOWN row.
                        result._set_null(i)
                    elif right_filtered.data.test(fi):
                        result.data.set(i)
                    fi += 1
            return result^

    # Case 4: non-selective (or a left mask carrying UNKNOWN) -> eval right on
    # the full batch and combine with the Kleene AND. ⛔ Right is asked only of
    # the rows left has not already made FALSE if it OVERFLOWS
    # (`_eval_right_over_undecided`).
    var right_mask = _eval_right_over_undecided(right, batch, left_mask, False)
    return eval_and(left_mask, right_mask)


def _eval_short_circuit_or(
    left: Expr, right: Expr, batch: RecordBatch
) raises -> BooleanArray:
    """Short-circuit OR evaluation.
    """
    var left_mask = _eval_predicate(left, batch)
    var num_rows = batch.num_rows()
    var left_true = left_mask.true_count()

    # ⭐ FULLY-KNOWN-ONLY, same guard and same reason as the AND above. Case 2
    # is the one that is actually wrong without it: `UNKNOWN OR FALSE` is
    # UNKNOWN, not FALSE, so returning the right mask alone reports a definite
    # FALSE that an enclosing `NOT` then turns into a selected row. Case 1 is
    # sound today only because of an invariant this function does not own (a
    # data bit of 1 on an unknown row would make `left_true == num_rows`
    # reachable with unknowns present); it is guarded rather than left resting
    # on a property established elsewhere.
    if not left_mask.validity:
        # Case 1: all-true on left -> short-circuit, right never evaluated.
        if left_true == num_rows:
            return left_mask^

        # Case 2: all-false on left -> result is right alone.
        if left_true == 0:
            return _eval_predicate(right, batch)

    # Case 3 (no equivalent of AND's selective case here — see module
    # comment): eval right on full batch, Kleene OR.
    var right_mask = _eval_right_over_undecided(right, batch, left_mask, True)
    return eval_or(left_mask, right_mask)


def _eval_right_over_undecided(
    right: Expr, batch: RecordBatch, imm left_mask: BooleanArray, is_or: Bool
) raises -> BooleanArray:
    """The right side of an AND (`is_or=False`) / OR (`is_or=True`) over the
    whole batch — and, if THAT raises an integer OVERFLOW, over only the rows
    the left side has NOT decided (AND: left TRUE or UNKNOWN; OR: left FALSE or
    UNKNOWN), every other row NULL. DuckDB never evaluates the right side on a
    decided row, so `WHERE a < 100 AND a + b > 0` answers where `a + b`
    overflows only on a row `a < 100` rejects. The Kleene
    combine reads a NULL right only where left already decided the row: FALSE
    AND NULL is FALSE, TRUE OR NULL is TRUE. See `arm_rows.mojo`."""
    try:
        return _eval_predicate(right, batch)
    except err:
        if not is_int_overflow_error(String(err)):
            raise err^
    return _eval_predicate(
        right, batch_nulled_outside(batch, undecided_rows(left_mask, is_or))
    )


# =============================================================================
# comptime kernel-dispatch gate
# =============================================================================
#
# This gate decides whether routing the 12 cells (BIN_LT/LE/GT/GE/EQ/NE x
# INT64+FLOAT64) at `_eval_predicate` goes through the standalone `MatchFn`
# kernels instead of the existing path. The existing path (the
# `komira_core/eval/comparison.mojo` kernels) is ALREADY hand-staged SIMD
# compare-pack (`_eval_cmp_lt[si64]` emits `cmgt.2d` NEON SIMD, the same opcode
# as the MatchFn `LtI64` cell), so the gate exists to quantify the rewire's delta.
#
# Default OFF. Toggling the flag to True at experiment time activates the
# kernel path for the 12 cells; everything else (decimals, strings, NULL,
# IN_LIST, regex, etc.) stays on the existing path unchanged.
# =============================================================================


comptime USE_KERNEL_COMPTIME_FILTER: Bool = False


def _broadcast_to_array_int64(value: Int64, n: Int) -> PrimitiveArray[DType.int64]:
    """Allocate a length-N PrimitiveArray[Int64] filled with `value`.

    Used only when `USE_KERNEL_COMPTIME_FILTER=True` to construct a synthetic
    column-shaped RHS for MatchFn (which is col-vs-col by design). The
    allocate + fill loop is an inherent cost of routing col-vs-literal
    through a col-vs-col kernel; the existing scalar path avoids this.
    """
    var arr = PrimitiveArray[DType.int64].allocate(n)
    # Origin-tied via
    # the function-scope view_mut local; the view borrow is released
    # by NLL at last-use (the `ptr.store` loop tail) so the trailing
    # `return arr^` move compiles cleanly.
    var arr_view = arr.view_mut()
    var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    for i in range(n):
        ptr.store[width=1](i, value)
    return arr^


def _broadcast_to_array_float64(value: Float64, n: Int) -> PrimitiveArray[DType.float64]:
    """Float64 sibling of `_broadcast_to_array_int64`."""
    var arr = PrimitiveArray[DType.float64].allocate(n)
    # See sibling above.
    var arr_view = arr.view_mut()
    var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    for i in range(n):
        ptr.store[width=1](i, value)
    return arr^


# NOTE: Mojo 1.0.0b1 does NOT widen `F.T` to a concrete `DType` via
# `constrained[F.T == DType.int64]` at the call site — the kernel body
# still sees `PrimitiveArray[F.T]` and rejects a `PrimitiveArray[Int64]`
# passed in. Same compiler limitation as the sub-trait widening rejected
# through `@parameter if conforms_to(F, <sub-trait>)`.
# Workaround: inline the kernel call per cell instead of factoring
# through a `[F: MatchFn]`-parametric helper.
#
# Each kernel cell is a `Movable + Copyable` POD struct with one method
# `eval_chunk(self, lhs, rhs, mut out_mask) -> Int`. Direct call: avoids
# the F-widening problem entirely.


def _dispatch_int64_via_kernel(
    op: UInt8,
    lhs: PrimitiveArray[DType.int64],
    rhs: PrimitiveArray[DType.int64],
) raises -> BooleanArray:
    """Dispatch the 6 Int64 op cells through the matching `MatchFn`
    kernel from `builtin_match_fns`. Returns a packed `BooleanArray`.

    `op` is a runtime tag from `komira_core.plan.expr` (BIN_LT/LE/...).
    The per-op branch is a comptime-known dispatch at the matched
    arm — each arm invokes a distinct kernel monomorphization.
    """
    var n = lhs.length
    var mask = Bitmap.create(n)
    if op == BIN_LT:
        var f = LtI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_LE:
        var f = LeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GT:
        var f = GtI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GE:
        var f = GeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_EQ:
        var f = EqI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_NE:
        var f = NeI64()
        _ = f.eval_chunk(lhs, rhs, mask)
    else:
        raise Error("PipelineCompiler[KERNEL]: unsupported comparison op for int64: " + String(Int(op)))
    return BooleanArray.from_bitmap(mask^)


def _dispatch_float64_via_kernel(
    op: UInt8,
    lhs: PrimitiveArray[DType.float64],
    rhs: PrimitiveArray[DType.float64],
) raises -> BooleanArray:
    """Float64 sibling of `_dispatch_int64_via_kernel`."""
    var n = lhs.length
    var mask = Bitmap.create(n)
    if op == BIN_LT:
        var f = LtF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_LE:
        var f = LeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GT:
        var f = GtF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_GE:
        var f = GeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_EQ:
        var f = EqF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    elif op == BIN_NE:
        var f = NeF64()
        _ = f.eval_chunk(lhs, rhs, mask)
    else:
        raise Error("PipelineCompiler[KERNEL]: unsupported comparison op for float64: " + String(Int(op)))
    return BooleanArray.from_bitmap(mask^)


# =============================================================================
# Predicate evaluation — Expr tree -> BooleanArray
# =============================================================================


@always_inline
def _is_comparison_op(op: UInt8) -> Bool:
    """True iff `op` is one of the six SQL relational comparison operators
    (`<`, `<=`, `>`, `>=`, `=`, `<>`), i.e. an op whose result is a boolean
    mask. Guards the computed-LHS materialization path so a non-comparison
    binary op (e.g. arithmetic mistakenly reaching the predicate arm) falls
    through to the existing dispatch rather than into `_eval_col_vs_col_promoted`.
    """
    return (
        op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
        or op == BIN_EQ
        or op == BIN_NE
    )


# =============================================================================
# ⚠ THE DISPATCHER NULL CONTRACT — every DType arm below, no exceptions
# =============================================================================
#
# `_eval_predicate` is not a comparison
# implementation; it is the per-DType DISPATCHER that chooses one. It chose
# INCONSISTENTLY: the DECIMAL128 and temporal arms finalized
# through `kleene_cmp_finalize*`, while the INT64 / INT32 / FLOAT64 arms
# `return`ed the raw SIMD compare-pack kernel (`eval_lt[...]`, `eval_col_gt[...]`)
# — which reads the VALUE buffer and never the validity bitmap.
#
# THE CONTRACT, stated by `eval_not`'s header (`komira_core/eval/arithmetic.mojo`):
#
#     A row whose predicate value is UNKNOWN carries DATA BIT 0.
#     The validity bitmap says WHY it is 0 — unknown, not false.
#
# BOTH halves are load-bearing and they serve different consumers:
#   * data bit 0 — `SelectionVector.from_bool_mask` and `filter_to_indices`
#     walk the DATA bitmap 64 bits at a time and never read validity. Data bit
#     0 is the only reason they drop an UNKNOWN row.
#   * the validity bitmap — `residual_mask_eval._residual_pass_mask` asks
#     `ba.is_null(i)`. With no bitmap that question is unconditionally False,
#     so its NULL handling was unreachable code, not a bug it could hit.
#
# WHY THE VIOLATION SURVIVED: `conjunction._collapse_nulls_to_false` repairs
# the mask, at exactly TWO call sites (both in `evaluate_predicate_selected`).
# Every other `_eval_predicate` consumer — `StreamingFilterOp`, the streaming
# and columnar agg consumers, the parquet pushed-filter paths, CASE/WHEN,
# `residual_mask_eval` — got the raw mask. Measured through the production
# `StreamingFilterOp`: `a < 100` over a nullable INT64 column SELECTED the NULL
# row, and with a zero-filled null slot (what a zero-filling decoder leaves)
# `a = 0` returned ONLY the NULL row — a row that logically does not exist.
#
# HOW TO ADD AN ARM: compute the raw data bits on every lane, then finalize —
# `kleene_cmp_finalize_scalar(raw^, arr.validity, ...)` for col-vs-literal,
# `kleene_cmp_finalize(raw^, l.validity, r.validity, ...)` for col-vs-col (or
# the `_scalar_cmp` / `_col_cmp_nullable` helpers above, which pair them).
# Never `return` a bare kernel result.
#
# INSIDE THE CONTRACT: `_eval_col_vs_col_promoted` (`compiler_eval_column.mojo`) —
# the mixed-type / computed-operand path, reached from THIS function's
# computed-LHS arm, general-RHS arm, and INT-col-vs-FLOAT-literal promotion.
# All nine of its arms returned raw `eval_col_*`, and four of them destroyed
# the narrow operand's validity even earlier, in a hand-rolled widening loop
# with no `clone_array_validity`. It now widens through validity-preserving
# helpers and finalizes through `_col_cmp_nullable` — the SAME helper
# `_eval_col_vs_col` below uses, which is why that helper now LIVES in
# `compiler_eval_column` and is imported here.
#
# STILL OUTSIDE THIS CONTRACT (deliberately named, not silently omitted):
#   * `_numeric_dict_filter_dispatch` / `dict_filter_eval_bool_mask` — the
#     dict arms, whose comments assert the caller applies the row-validity
#     collapse. That is the same assumption that proved false for the int
#     arms; it has not been re-checked here.
#   * ~~`_eval_short_circuit_and` case 3 — scatters into a fresh
#     `BooleanArray.allocate`, so the merged result is data-correct (UNKNOWN
#     stays 0) but loses the WHY.~~ and
#     "loses the WHY" understated it: losing the why IS a wrong answer one
#     `NOT` away, and that is how it was found. Case 3 — and the other three
#     short-circuits — are now unreachable with a validity-bearing left mask.
#     ⚠ That closed the LEFT half only. The scatter still dropped an UNKNOWN
#     from the RIGHT side until (found by the batch-1 merge review,
#     after the bare-BOOLEAN arm made `NOT (p AND flag)` a new spelling of it);
#     it now carries the right mask's validity.
# =============================================================================


def _null_mask_of(
    ref col: Column[HeapRegion], num_rows: Int, want_null: Bool
) raises -> BooleanArray:
    """The `IS NULL` / `IS NOT NULL` mask of an ALREADY-MATERIALIZED column.

    `data[r] = 1` iff row `r` is null (`want_null=True`) or non-null
    (`want_null=False`); validity all-ones, because the answer to "is this
    null" is itself never unknown.

    ⚠ THE NO-VALIDITY-BITMAP CASE IS ASYMMETRIC and that is why the two
    polarities cannot be one body with a `~` toggled. Arrow's "no validity
    bitmap" means EVERY ROW IS VALID, so `IS NULL` is all-zero (which is what
    `allocate_nullable`'s zero-fill already gives) and `IS NOT NULL` is
    all-ONES (which it does not). Getting that backwards is a silent
    all-rows/no-rows answer, never an error.

    Extracted so the COL_REF fast path and the general-child
    fallback in `_eval_predicate`'s `EXPR_UNARY_OP` arm share one
    bit-twiddle. Module-internal: the raw pointers never leave this function.
    """
    var ba = BooleanArray.allocate_nullable(num_rows)
    var n_bytes = (num_rows + 7) >> 3
    var trailing = num_rows & 7
    # SAFETY: `d_view` / `v_view` are function-scope ByteView locals that pin
    # their buffers alive across the loop below; both pointers die here.
    var d_view = ba.data.buffer.view_mut()
    var d_ptr = d_view._unsafe_ptr()
    if col._validity:
        var v_view = col._validity.value().buffer.view_ro()
        var v_ptr = v_view._unsafe_ptr()
        if want_null:
            for b in range(n_bytes):
                (d_ptr + b)[] = ~(v_ptr + b)[]
        else:
            for b in range(n_bytes):
                (d_ptr + b)[] = (v_ptr + b)[]
    else:
        var fill = UInt8(0x00) if want_null else UInt8(0xFF)
        for b in range(n_bytes):
            (d_ptr + b)[] = fill
    # Clear the bits past `num_rows` in the last byte so they cannot read as
    # phantom set rows downstream.
    if trailing > 0 and n_bytes > 0:
        var mask = UInt8((1 << trailing) - 1)
        (d_ptr + n_bytes - 1)[] = (d_ptr + n_bytes - 1)[] & mask
    return ba^



def _u64_cmp_vs_float_literal(
    arr: PrimitiveArray[DType.uint64], lit: Float64, op: UInt8
) raises -> BooleanArray:
    """`uint64 column OP float literal`, decided EXACTLY, with the column left
    in the unsigned domain.

    ⛔ THE OBVIOUS SPELLING IS WRONG TWICE OVER. Casting the COLUMN to Float64
    (what the INT64/INT32 arm does) collapses every value above `2**53` onto a
    neighbour — `2**64-1` and `2**64-2` are one Float64 — and casting the
    LITERAL to UInt64 is undefined for a negative or `>= 2**64` argument and
    silently drops the fractional part, which changes the answer for four of
    the six operators.

    THE REDUCTION: a float threshold `f` splits the unsigned line at
    `floor(f)`, so each comparison becomes an INTEGER comparison against
    `u = floor(f)` — with the operator adjusted when `f` has a fraction, since
    no integer can sit strictly between `u` and `f`:

        f fractional:  v <  f  ==  v <= u        v >  f  ==  v >  u
                       v <= f  ==  v <= u        v >= f  ==  v >  u
                       v == f  ==  never         v != f  ==  always

    Out of range is answered on its own terms: every unsigned value is above a
    NEGATIVE threshold and below one at or past `2**64` (which includes `+inf`,
    and is where a float spelling of `18446744073709551615` lands — that
    literal IS `2**64` in Float64, so `= 18446744073709551615.0` is correctly
    EMPTY rather than the top row). NaN orders against nothing, so only `!=`
    holds.

    ⚠ EVERY CONSTANT ANSWER IS SPELLED AS A REAL COMPARE IN THE UNSIGNED
    DOMAIN (`v >= 0` / `v < 0`) rather than a synthesized mask, so the raw
    bits, the lane order and the offset handling stay the kernel's own and this
    file grows no second way to build a mask."""
    var all_rows = BIN_GE  # `v >= 0` — true for every row
    var no_rows = BIN_LT  # `v <  0` — true for none
    var zero = Scalar[DType.uint64](UInt64(0))

    if lit != lit:  # NaN
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if op == BIN_NE else no_rows
        )
    if lit < 0.0:
        var above = op == BIN_GT or op == BIN_GE or op == BIN_NE
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if above else no_rows
        )
    if lit >= 18446744073709551616.0:  # 2**64, and +inf
        var below = op == BIN_LT or op == BIN_LE or op == BIN_NE
        return _scalar_cmp[DType.uint64](
            arr, zero, all_rows if below else no_rows
        )

    # In range: truncation toward zero IS floor for a non-negative argument.
    var u = Scalar[DType.float64](lit).cast[DType.uint64]()
    var frac = u.cast[DType.float64]() != lit

    var kop = op
    if frac:
        if op == BIN_LT or op == BIN_LE:
            kop = BIN_LE
        elif op == BIN_GT or op == BIN_GE:
            kop = BIN_GT
        elif op == BIN_EQ:
            return _scalar_cmp[DType.uint64](arr, zero, no_rows)
        else:  # BIN_NE
            return _scalar_cmp[DType.uint64](arr, zero, all_rows)
    return _scalar_cmp[DType.uint64](arr, u, kop)


def _eval_string_op_on_column(
    col_ptr: Column[HeapRegion], str_op: UInt8, pattern: String
) raises -> BooleanArray:
    """The `EXPR_STRING_OP` pattern kernels over ONE string column — a scan
    column or a computed one (`_eval_predicate`'s EXPR_STRING_OP arm and the
    projection arm in `compiler_eval_column` both call it, so the two contexts
    cannot disagree about which rows match)."""
    var col_at = col_ptr.arrow_type
    if col_at != ArrowType.STRING and col_at != ArrowType.DICTIONARY and col_at != ArrowType.LARGE_STRING:
        raise Error("PipelineCompiler: string operations require STRING / LARGE_STRING / DICTIONARY column, got " + String(col_at))

    # LARGE_STRING
    # pattern-op parity.  Routes to the Int64-offset siblings of the
    # eval_string_* pattern kernels.  Same shared `@parameter
    # fn _string_*_kernel[OffsetType]` body; byte-identical results.
    if col_at == ArrowType.LARGE_STRING:
        var arr_l = col_ptr.as_large_string()
        if str_op == STR_CONTAINS:
            return eval_large_string_contains(arr_l, pattern)
        elif str_op == STR_STARTS_WITH:
            return eval_large_string_starts_with(arr_l, pattern)
        elif str_op == STR_ENDS_WITH:
            return eval_large_string_ends_with(arr_l, pattern)
        elif str_op == STR_LIKE:
            return eval_large_string_like(arr_l, pattern)
        else:
            raise Error("PipelineCompiler: unsupported string operation on LARGE_STRING: " + String(Int(str_op)))

    # For DICTIONARY columns, resolve to StringArray for string ops.
    # Dict-aware CONTAINS/STARTS_WITH/ENDS_WITH/LIKE is a future optimization.
    var arr: StringArray[HeapRegion]
    if col_at == ArrowType.DICTIONARY:
        arr = _materialize_dict_to_string(col_ptr)
    else:
        # Lane G L1: read in place, as the comparison arm above does.
        arr = string_array_of(col_ptr)
    if str_op == STR_CONTAINS:
        return eval_string_contains(arr, pattern)
    elif str_op == STR_STARTS_WITH:
        return eval_string_starts_with(arr, pattern)
    elif str_op == STR_ENDS_WITH:
        return eval_string_ends_with(arr, pattern)
    elif str_op == STR_LIKE:
        return eval_string_like(arr, pattern)
    else:
        raise Error("PipelineCompiler: unsupported string operation: " + String(Int(str_op)))


def _eval_predicate(expr: Expr, batch: RecordBatch) raises -> BooleanArray:
    """Evaluate an Expr predicate against a RecordBatch, producing a BooleanArray mask.

    Handles comparison operators (>, <, ==, !=, >=, <=) with literal RHS,
    and logical combinators (AND, OR, NOT).

    NULL CONTRACT: a row whose predicate value is UNKNOWN comes back with DATA
    BIT 0, and (when any operand was nullable) a cleared validity bit saying
    why. See the block above this function.

    Args:
        expr: The predicate expression.
        batch: The input RecordBatch.

    Returns:
        A BooleanArray where True indicates rows that pass the predicate.
    """
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()

        # Logical AND/OR: delegate to the short-circuit evaluators
        # implementations). PERF-CRITICAL: sub-trees of OR/NOT predicates that
        # the conjunction-flattener can't see still benefit from the four-case
        # selective evaluation (skip-right-when-left-all-false, etc.).
        if op == BIN_AND:
            return _eval_short_circuit_and(
                expr.binary_left_ref(), expr.binary_right_ref(), batch
            )

        if op == BIN_OR:
            return _eval_short_circuit_or(
                expr.binary_left_ref(), expr.binary_right_ref(), batch
            )

        # the LHS of a comparison
        # may itself be a compound expression, e.g. `a * b > 100` (the shared
        # `a * b` subtree the CSE demo produces when Axis-2 CSE does not fire
        # because the subtree is only depth-2). Gap C generalized
        # the *RHS* to accept an arbitrary Expr but left the LHS assuming a bare
        # column — so `resolve_col_index(binary_left_ref)` below raised
        # "cannot resolve column index from expression tag: 3" for any
        # non-column LHS. Mirror Gap C here for the LHS: when the left side does
        # NOT resolve to a column, materialize BOTH sides into columns and route
        # through `_eval_col_vs_col_promoted` (SQL-standard numeric promotion).
        # This is general for any comparison whose operands are arbitrary
        # arithmetic expressions, not just the N-conjunct-shared-subtree shape.
        if _is_comparison_op(op) and not expr_resolves_to_column(
            expr.binary_left_ref()
        ):
            # ★ A BARE INTEGER LITERAL ON THE **LEFT** (`3 < v`). It would be
            # materialized by `_eval_column_expr` -> `broadcast_scalar`, whose
            # arms test `dtype == int64 / float64 / int32 / float32` and turn
            # every OTHER integer tag into a column of INT64 ZEROS — measured
            # `f64 [0.5,3,10]  3 (uint8) < v  ->  011`, want 001. `lit OP v` is
            # `v MIRROR(OP) lit`, so the literal is read by THE ONE RULE at the
            # other side's type, exactly as the right-literal path below does,
            # and only then broadcast.
            ref lhs_lit_ref = expr.binary_left_ref()
            if lhs_lit_ref.is_literal():
                var llit = lhs_lit_ref.literal_value()
                if llit.is_any_integer():
                    var rcol = _eval_column_expr(expr.binary_right_ref(), batch)
                    var mop = mirror_comparison(op)
                    read_integer_literal_for_column(
                        number_dtype_of(rcol.arrow_type), llit, mop
                    )
                    var lcol = broadcast_scalar(llit, batch.num_rows())
                    return _eval_col_vs_col_promoted(
                        lcol^, rcol^, mirror_comparison(mop)
                    )
            var lhs_col = _eval_column_expr(expr.binary_left_ref(), batch)
            ref rhs_ref = expr.binary_right_ref()
            if rhs_ref.is_literal():
                var rhs_lit = rhs_ref.literal_value()
                # `<expr> OP NULL` is NULL for every row under SQL 3VL. Mirrors
                # the bare-column `col OP NULL` gate below — see it for why the
                # answer is ALL-NULL and not all-FALSE.
                if rhs_lit.is_null():
                    return kleene_all_null_predicate(
                        batch.num_rows(), NullPolicy.three_valued()
                    )
                # ★ A COMPUTED **STRING** LHS, WHICH `_eval_col_vs_col_promoted`
                # REFUSES BY NAME ("unsupported same-type pair: string"), so
                # without a computed-operand arm NO computed string
                # predicate was executable AT ALL — not `upper(name) = 'ACME'`,
                # and not `substring(c_phone, 1, 2) = '13'`, which has been
                # buildable and unrunnable in a WHERE ever
                # since. The promotion helper is about NUMERIC widening and has
                # no business growing a string arm; the right kernels already
                # exist one screen down, where a BARE string column meets a
                # string literal, and they carry the NULL contract
                # (`_apply_validity`) with them.
                #
                # ⚠ THE OPERAND ORDER IS NOT SYMMETRIC AND IS NOT CHECKED BY
                # THESE KERNELS. They are `column OP scalar`; the LHS here is
                # the computed column and the RHS the literal, which is the
                # order the caller already has, so `>` stays `>`. Reversing the
                # pair silently inverts every inequality.
                var lhs_at = lhs_col.arrow_type
                if lhs_at == ArrowType.STRING and rhs_lit.is_string():
                    var lhs_sa = string_array_of(lhs_col)
                    var rhs_str = rhs_lit.string_val
                    if op == BIN_EQ:
                        return eval_string_eq(lhs_sa, rhs_str)
                    elif op == BIN_NE:
                        return eval_string_ne(lhs_sa, rhs_str)
                    elif op == BIN_GT:
                        return eval_string_gt(lhs_sa, rhs_str)
                    elif op == BIN_LT:
                        return eval_string_lt(lhs_sa, rhs_str)
                    elif op == BIN_GE:
                        return eval_string_ge(lhs_sa, rhs_str)
                    elif op == BIN_LE:
                        return eval_string_le(lhs_sa, rhs_str)
                    else:
                        raise Error(
                            "PipelineCompiler: unsupported comparison op for a"
                            + " computed string LHS: " + String(Int(op))
                        )
                # ★ THE ONE RULE, at the COMPUTED column's type, BEFORE the
                # broadcast. `broadcast_scalar` knows int64/float64/int32/
                # float32 tags and makes every other integer tag an INT64 ZERO
                # (measured: `f64 (v + 0.0) > 3 (uint8)` answered 111, want
                # 001; `i64 (v + 0) > 2**64-1 (uint64)` answered 001, want
                # 000). After this call the literal is int64- or float64-tagged,
                # or its above-the-domain comparison has been rewritten.
                var cop = op
                read_integer_literal_for_column(
                    number_dtype_of(lhs_col.arrow_type), rhs_lit, cop
                )
                var rhs_col = broadcast_scalar(rhs_lit.copy(), batch.num_rows())
                return _eval_col_vs_col_promoted(lhs_col^, rhs_col^, cop)
            var rhs_expr_col = _eval_column_expr(rhs_ref, batch)
            return _eval_col_vs_col_promoted(lhs_col^, rhs_expr_col^, op)

        # Comparison: column op literal OR column op column OR column op <expr>
        # Resolve column index from left side
        var col_idx = resolve_col_index(expr.binary_left_ref(), batch.schema)
        ref col_ptr = batch.column_at(col_idx)
        var col_at = col_ptr.arrow_type

        # PERF-CRITICAL: column-vs-column comparison support.
        # Enables the decorrelation pattern (join-back + col-vs-col filter)
        # that eliminates correlated subqueries in Q17/Q20. Without this,
        # the engine must fall back to manual loops with double scans.
        # NOTE: same-type col-vs-col still fast-paths
        # through `_eval_col_vs_col`; mixed-type col-vs-col falls through
        # to the general RHS path below for promotion.
        if expr.binary_right_ref().tag == EXPR_COL_REF:
            var right_idx = resolve_col_index(expr.binary_right_ref(), batch.schema)
            ref right_col_ref = batch.column_at(right_idx)
            if col_at == ArrowType.DECIMAL128 and right_col_ref.arrow_type == ArrowType.DECIMAL128:
                # scale-aligned col-vs-col compare.
                return _eval_decimal_col_vs_col(batch, col_idx, right_idx, op)
            if right_col_ref.arrow_type == col_at:
                return _eval_col_vs_col(batch, col_idx, right_idx, col_at, op)
            # Mixed types — fall through to the general path with promotion.

        # General RHS path — accept arbitrary Expr on
        # the RHS (EXPR_BINARY_OP, EXPR_CAST, EXPR_UNARY_OP, …) by
        # materializing it through `_eval_column_expr`. Routes into
        # `_eval_col_vs_col_promoted`, which handles SQL-standard
        # numeric promotion (INT64 vs FLOAT64, INT32 vs INT64, …).
        # Pre-Gap-C this path raised "predicate RHS must be a literal
        # (got tag=3)" and forced bench-side `with_column` workarounds
        # for shapes like `col("ps_availqty") > col("qty_sum") * 0.5`.
        if not expr.binary_right_ref().is_literal():
            var rhs_col = _eval_column_expr(expr.binary_right_ref(), batch)
            return _eval_col_vs_col_promoted(
                copy_column(batch, col_idx), rhs_col^, op
            )

        var lit_val = expr.binary_right_ref().literal_value()

        # `col OP NULL` is
        # NULL for every row under SQL 3VL, so the predicate never holds ->
        # drop all rows. Without this gate the int/float arms below read
        # `lit_val.int_val` / `.float_val` (both 0 for a typed null) and
        # WRONGLY compared `col == 0` — e.g. `x = (SELECT max(y) FROM empty)`
        # (an empty scalar subquery resolves to a NULL literal) matched the
        # x=0 rows.
        #
        # ⛔ ALL-**NULL**, NOT ALL-FALSE (three-valued logic). A bare
        # `Bitmap.create(n)` with no validity is
        # the right ROW SET for a bare WHERE and the wrong VALUE for anything
        # that reads it: `NOT (x = NULL)` became TRUE on every row (DuckDB:
        # NULL, nothing selected), and the projection arm routes every
        # comparison against a literal through here, so `x = NULL` projected
        # FALSE. SQL's `x NOT IN (1, NULL)` desugars to exactly that NOT. The
        # decimal arm (`_eval_decimal_col_vs_literal`) already answered
        # `kleene_all_null_predicate`; now both do.
        # Falsifier: `komira_compiler/tests/test_null_literal_comparison_is_null.mojo`.
        if lit_val.is_null():
            return kleene_all_null_predicate(
                batch.num_rows(), NullPolicy.three_valued()
            )

        # route temporal comparisons to
        # the dedicated helper BEFORE the numeric arms. Fires when EITHER the
        # column is a temporal int-storage type (DATE32/DATE64/TIMESTAMP*/TIME*/
        # DURATION*) OR the literal is a temporal scalar (date32/timestamp) — the
        # latter catches the LIVE bug where a physically-INT32-stamped date column
        # + a date32 literal would otherwise hit the INT32 arm and read int_val==0
        # (all-false). A plain int column + int literal is NOT temporal on either
        # side, so it stays on the fast int arm below (no behavior change). See
        # `_eval_temporal_col_vs_literal` for the full root-cause narrative.
        var col_is_temporal_intlike = (
            col_at == ArrowType.DATE32
            or col_at == ArrowType.DATE64
            or col_at.is_timestamp()
            or col_at.is_time()
            or col_at.is_duration()
        )
        if (
            col_is_temporal_intlike
            or lit_val.is_date32()
            or lit_val.is_timestamp()
        ):
            return _eval_temporal_col_vs_literal(
                batch, col_idx, lit_val, op, col_at
            )

        # =====================================================================
        # ★★ EVAL_INCOMPARABLE_LITERAL — THE
        #    ARM LADDER BELOW SELECTS A `ScalarValue` FIELD FROM THE COLUMN'S
        #    TYPE ALONE, AND AN UNPOPULATED FIELD READS AS A WELL-FORMED ZERO.
        # =====================================================================
        #
        # MEASURED: `WHERE l_shipmode > 5` over a 210-row fixture answered
        # `count = 210` — the WHOLE TABLE. Not a dropped predicate: the STRING
        # arm 130 lines below read `lit_val.string_val`, which is `""` for a
        # literal built by `ScalarValue.from_int(5)`, and evaluated
        # `l_shipmode > ''` — true for every non-empty string. The same read
        # makes `l_shipmode < 5` answer ZERO rows. Both are silent wrong
        # answers, and under the rule "slower OK, wrong not" neither is
        # admissible.
        #
        # ⚠ IT GOES **AFTER** THE TEMPORAL DISPATCH ON PURPOSE. A temporal
        # column takes `_eval_temporal_col_vs_literal` on the strength of the
        # COLUMN alone and legitimately reads an INTEGER literal (a DATE32
        # column is int32 days-since-epoch); refusing before that routing would
        # delete a working query. See `plan_wire_values.
        # _temporal_column_reads_int_literal` for the measurement that made the
        # plan-wire door stop refusing that same pair.
        #
        # ⚠ THE REFUSAL IS THE EXECUTOR'S OWN AND ITS TOKEN IS NOT THE DOOR'S.
        # `plan_wire_values._refuse_if_incomparable` already refuses this pair
        # with `PLAN_WIRE_INCOMPARABLE_LITERAL` on the PLAN-WIRE ingress, which
        # is why the DataFrame spellings are graded CLEAR-ERROR and the SQL one
        # (`komira_sql_stream`, a different ingress with no such walk) was
        # not. See `literal_arm_domain.mojo`'s header.
        check_literal_against_column(
            col_at,
            lit_val,
            col_ptr.is_numeric_dict(),
            String("filter predicate"),
        )

        # =====================================================================
        # ★★ THE ONE RULE — AN INTEGER LITERAL'S VALUE IS READ BY ITS **TAG**
        #    (`integer_literal_value.mojo`; the semantics and the DuckDB
        #    measurements behind them are in that module's header).
        # =====================================================================
        #
        # Every arm below picks the `ScalarValue` field it reads from the
        # COLUMN. For an integer literal that was right only for the tags each
        # arm happened to expect. Without the decode:
        #   int64 col [-5,0,3,MAX]  v > 2**64-1 (uint64)  -> 0111, want 0000
        #   f64   col [0.5,3,10]    v > 3 (uint8)         -> 111,  want 001
        # — a uint64 above Int64.MAX read SIGNED, and the FLOAT64 promotion an
        # ALLOW-LIST over the literal's tag (int64/int32) with every other tag
        # falling through to `float_val`, a well-formed ZERO. After this call
        # an integer literal is, for the arm about to read it: a FLOAT literal
        # holding DuckDB's cast to the column's float type (FLOAT64/FLOAT32
        # and float dictionaries); an INT64-tagged literal of the same value
        # (every integer column but UINT64), with a value above the column's
        # whole domain rewritten to `v <= Int64.MAX` / `v > Int64.MAX`; or,
        # for UINT64, untouched — that arm decodes the tag itself below.
        #
        # ⚠ AFTER `check_literal_against_column`, so a pair with no arm is still
        # refused by that check's own token, and AFTER the temporal routing, so
        # a DATE32 column's int literal is still days-since-epoch.
        var lit_value_dt = number_dtype_of(col_at)
        if col_at == ArrowType.DICTIONARY and col_ptr.is_numeric_dict():
            lit_value_dt = col_ptr.dict_value_dtype()
        read_integer_literal_for_column(lit_value_dt, lit_val, op)

        # Implicit numeric promotion for INT-col vs
        # FLOAT-literal. Taking `lit_val.int_val` (which is 0
        # for a float literal) and silently produced wrong results. The
        # promotion casts the column once and routes into the float64
        # kernel.
        # ⚠ THE NARROW WIDTHS ARE DELIBERATELY **NOT** LISTED HERE. Their own arm
        # below handles a float literal itself (`_eval_narrow_int_col_vs_literal`
        # branches on `lit.is_float`), which keeps one type's answer in one
        # place; routing them through this promotion too would give the same
        # question two implementations.
        if (col_at == ArrowType.INT64 or col_at == ArrowType.INT32) and (
            lit_val.dtype == DType.float64 or lit_val.dtype == DType.float32
        ):
            var int_col_copy = copy_column(batch, col_idx)
            var rhs_col = broadcast_scalar(lit_val.copy(), batch.num_rows())
            return _eval_col_vs_col_promoted(int_col_copy^, rhs_col^, op)

        # (The symmetric FLOAT-col vs INT-literal case used to be a block here
        # that promoted an integer literal ONLY when it was tagged int64 or
        # int32 — an allow-list over the literal's tag, past which every other
        # integer tag was read as `float_val`, zero. It is gone because it is
        # unreachable: the one rule above has already turned every integer
        # literal against a FLOAT64 column into a float one.)

        if col_at == ArrowType.INT64:
            var arr = col_ptr.as_primitive[DType.int64]()
            var threshold = Scalar[DType.int64](lit_val.int_val)

            # comptime kernel
            # dispatch when the flag is True. Synthesizes a length-N RHS
            # column filled with the threshold and dispatches through the
            # MatchFn kernel. The broadcast cost is intrinsic
            # to routing col-vs-literal through a col-vs-col kernel surface.
            # It is a DATA-only kernel like `_scalar_cmp`, so it finalizes
            # through the same seam — the flag must not change null semantics.
            comptime if USE_KERNEL_COMPTIME_FILTER:
                var rhs = _broadcast_to_array_int64(lit_val.int_val, arr.length)
                var kraw = _dispatch_int64_via_kernel(op, arr, rhs^)
                return kleene_cmp_finalize_scalar(
                    kraw^, arr.validity, NullPolicy.three_valued(), arr.offset
                )

            var raw_i64 = _scalar_cmp[DType.int64](arr, threshold, op)
            return kleene_cmp_finalize_scalar(
                raw_i64^, arr.validity, NullPolicy.three_valued(), arr.offset
            )

        elif col_at == ArrowType.FLOAT64:
            var arr = col_ptr.as_primitive[DType.float64]()
            var threshold = Scalar[DType.float64](lit_val.float_val)

            # same shape as INT64 arm above.
            comptime if USE_KERNEL_COMPTIME_FILTER:
                var rhs = _broadcast_to_array_float64(lit_val.float_val, arr.length)
                var kraw_f = _dispatch_float64_via_kernel(op, arr, rhs^)
                return kleene_cmp_finalize_scalar(
                    kraw_f^, arr.validity, NullPolicy.three_valued(), arr.offset
                )

            var raw_f64 = _scalar_cmp[DType.float64](arr, threshold, op)
            return kleene_cmp_finalize_scalar(
                raw_f64^, arr.validity, NullPolicy.three_valued(), arr.offset
            )

        elif col_at == ArrowType.INT32:
            var arr = col_ptr.as_primitive[DType.int32]()
            # the literal is an Int64 and
            # this column is int32. `_scalar_cmp_i32_widening` compares in a
            # domain holding both; the pre-fix `Int32(Int(lit_val.int_val))`
            # kept the LOW 32 BITS and answered a different question.
            var raw_i32 = _scalar_cmp_i32_widening(arr, lit_val.int_val, op)
            return kleene_cmp_finalize_scalar(
                raw_i32^, arr.validity, NullPolicy.three_valued(), arr.offset
            )

        elif col_at == ArrowType.UINT64:
            # This arm did not exist: a predicate
            # over a UINT64 column fell to the ladder's `else` and raised
            # `unsupported column type for predicate: uint64` at a door that sends
            # the filter straight here. The other
            # three doors never saw the refusal, because the ROW GROUP was
            # pruned first (`rg_pruner`, fixed in the same change) and they
            # got ZERO ROWS instead — the same defect wearing two faces.
            #
            # ⚠ NO SINGLE INTEGER TYPE HOLDS BOTH OPERANDS, which is why this
            # is not `_scalar_cmp_i32_widening` with another width. The column
            # is UInt64; the literal is `ScalarValue.int_val`, an Int64.
            # Widening the column to Int64 is the bug (a value above
            # `Int64.MAX` reads negative); narrowing the literal wraps a
            # negative one onto a huge positive. So a NEGATIVE literal is
            # answered on its own terms below, and only a non-negative one is
            # converted — the sign of the literal's EXACT, TAG-decoded value
            # (`integer_literal_value`) is exactly that question.
            var arr_u64 = col_ptr.as_primitive[DType.uint64]()
            var raw_u64: BooleanArray
            if lit_val.is_float():
                # `int_val` is a well-formed ZERO
                # for a literal built by `ScalarValue.from_float`, so reading
                # it here answered `v > 0` for `v > 2.0` — the whole table.
                # This is not a corner case reachable only from SQL: a
                # spreadsheet formula has NO integer literal at all, so that
                # front end sends a float for EVERY numeric predicate.
                #
                # ⚠ AND IT IS **NOT** THE INT64 REPAIR WITH ANOTHER WIDTH. The
                # INT64/INT32 pair a few lines up promotes the COLUMN to
                # Float64; above 2**53 that is lossy in exactly the region a
                # UInt64 column exists to reach (`2**64-1` and `2**64-2` are
                # the same Float64), so the reduction below keeps the DATA in
                # the unsigned domain and moves the THRESHOLD instead.
                raw_u64 = _u64_cmp_vs_float_literal(
                    arr_u64, lit_val.float_val, op
                )
            else:
                # ★★ THE ONE RULE (`integer_literal_value.mojo`): the literal's
                # EXACT value, decoded by its TAG — the uint64 tag zero-extends
                # its bit pattern, every other tag sign-extends `int_val`.
                #
                # ⛔ A SILENT WRONG ANSWER WITHOUT IT.
                # `ScalarValue.from_uint64` stores the unsigned value as its
                # TWO'S-COMPLEMENT BIT PATTERN in `int_val`, and this arm read
                # `int_val` SIGNED: `2**64-1` arrived as `-1`, took the negative
                # branch below, and `v = 18446744073709551615` selected ZERO
                # ROWS. "fix(compiler): a UINT64 predicate reads an
                # UNSIGNED-TAGGED literal unsigned" repaired it here by asking
                # `is_uint` before the bits; the same misread lived in every OTHER arm
                # that meets an integer literal, which is why the tag is now
                # decoded in one function instead of per arm. Pinned by §6 of
                # `tests/test_predicate_over_uint64_column.mojo`.
                #
                # ⚠ THE DISCRIMINATOR IS THE TAG, NEVER THE SIGN OF THE BITS.
                # `int_val == -1` is `2**64-1` tagged uint64 and `-1` tagged
                # int64, and they want OPPOSITE answers. The decode separates
                # them; §3 of the same test is the control on the signed side.
                var lit_exact = integer_literal_value(lit_val)
                if lit_exact >= SIMD[DType.int128, 1](0):
                    raw_u64 = _scalar_cmp[DType.uint64](
                        arr_u64,
                        Scalar[DType.uint64](lit_exact.cast[DType.uint64]()),
                        op,
                    )
                else:
                    # A NEGATIVE literal — necessarily a signed tag, since the
                    # decode never makes an unsigned one negative. Every unsigned
                    # value is strictly above it, so `>`/`>=`/`!=` hold for
                    # every row and `<`/`<=`/`=` for none. Both are spelled as
                    # a REAL compare against 0 in the unsigned domain rather
                    # than a synthesized constant mask, so the raw bits, the
                    # lane order and the offset handling are the kernel's own
                    # and this arm adds no second way to build a mask.
                    var all_rows = (op == BIN_GT or op == BIN_GE or op == BIN_NE)
                    raw_u64 = _scalar_cmp[DType.uint64](
                        arr_u64,
                        Scalar[DType.uint64](UInt64(0)),
                        BIN_GE if all_rows else BIN_LT,
                    )
            return kleene_cmp_finalize_scalar(
                raw_u64^,
                arr_u64.validity,
                NullPolicy.three_valued(),
                arr_u64.offset,
            )

        elif col_at == ArrowType.INT8:
            # ★ THE FIVE NARROW INTEGER WIDTHS, one arm each because the storage
            # DType is a COMPTIME parameter of the widening. See
            # `_eval_narrow_int_arm`: an integer literal widens the COLUMN to
            # int64 (never narrows the literal), and a FLOAT literal widens it to
            # float64 — exact for these five widths, which is why this is NOT the
            # UINT64 threshold-move.
            return _eval_narrow_int_arm[DType.int8](
                col_ptr.as_primitive[DType.int8](), lit_val, op
            )

        elif col_at == ArrowType.INT16:
            return _eval_narrow_int_arm[DType.int16](
                col_ptr.as_primitive[DType.int16](), lit_val, op
            )

        elif col_at == ArrowType.UINT8:
            return _eval_narrow_int_arm[DType.uint8](
                col_ptr.as_primitive[DType.uint8](), lit_val, op
            )

        elif col_at == ArrowType.UINT16:
            return _eval_narrow_int_arm[DType.uint16](
                col_ptr.as_primitive[DType.uint16](), lit_val, op
            )

        elif col_at == ArrowType.UINT32:
            return _eval_narrow_int_arm[DType.uint32](
                col_ptr.as_primitive[DType.uint32](), lit_val, op
            )

        elif col_at == ArrowType.FLOAT32:
            # ★ FLOAT32 compares in FLOAT64, because the literal IS a Float64 and
            # rounding the threshold into float32 merges two distinct thresholds.
            return _eval_float32_col_vs_literal(
                col_ptr.as_primitive[DType.float32](), lit_val, op
            )

        elif col_at == ArrowType.BOOL:
            # ★ 40 of the 80 refused cross-surface units are this one cell. BOOL
            # is bit-packed, so it is ranked to int8 0/1 and compared there.
            return _eval_bool_col_vs_literal(col_ptr, lit_val, op)

        elif col_at == ArrowType.DECIMAL128:
            # scale-aligned col-vs-decimal-literal
            # compare (literal may be a decimal / int / float — promoted).
            return _eval_decimal_col_vs_literal(batch, col_idx, lit_val, op)

        elif col_at == ArrowType.DICTIONARY and col_ptr.is_numeric_dict():
            # NUMERIC dictionary
            # `col OP literal` predicate -> compute-over-codes LUT
            # (`numeric_dict_filter_bool_mask`), mirroring the production STRING
            # dict-filter LUT (`dict_filter_eval_bool_mask`, below). Resolve each
            # of the <= dict_size DISTINCT entries ONCE, build a keep-bit LUT,
            # then scan the N codes against it. This DELETES the v1
            # densification band-aid (`resolve_numeric_dict_to_flat` per-row
            # gather AT FILTER TIME). `_numeric_dict_filter_dispatch` runs the
            # LUT unconditionally (_VERIFY = also run the flat oracle and assert
            # byte-equal).
            #
            # Only the `col OP literal` shape reaches here. A numeric-dict-col vs
            # numeric-dict-col compare routes to `_eval_col_vs_col` (both cols
            # are DICTIONARY) which RAISES — code-vs-code across distinct per-RG
            # dicts is structurally declined to the value domain.
            return _numeric_dict_filter_dispatch(col_ptr, op, lit_val)

        elif col_at == ArrowType.DICTIONARY:
            # Dict-aware filter: evaluate predicate against D dictionary
            # entries instead of N rows. For low-cardinality strings (D=5,
            # N=1M), this is 200,000x fewer string comparisons.
            var str_val = lit_val.string_val
            var dict_op: DictFilterOp
            if op == BIN_EQ:
                dict_op = DictFilterOp.EQ
            elif op == BIN_NE:
                dict_op = DictFilterOp.NE
            elif op == BIN_GT:
                dict_op = DictFilterOp.GT
            elif op == BIN_LT:
                dict_op = DictFilterOp.LT
            elif op == BIN_GE:
                dict_op = DictFilterOp.GE
            elif op == BIN_LE:
                dict_op = DictFilterOp.LE
            else:
                raise Error("PipelineCompiler: unsupported comparison op for dictionary: " + String(Int(op)))
            if col_ptr._dict_index_byte_width == 4:
                # read the codes IN PLACE and build the
                # mask branch-free (`dict_filter_eval_bool_mask_column`) — no
                # `as_dictionary` copy of the whole code buffer per batch —
                # and apply the SAME null policy every other comparison arm in
                # this ladder applies (`kleene_cmp_finalize_scalar`): a NULL row
                # is NULL, never whatever its placeholder code happens to match.
                # The arm below it returned the raw code verdict for NULL rows.
                var raw_d = dict_filter_eval_bool_mask_column(
                    col_ptr, dict_op, str_val
                )
                return kleene_cmp_finalize_scalar(
                    raw_d^,
                    col_ptr._validity,
                    NullPolicy.three_valued(),
                    col_ptr._offset,
                )
            var dict_arr = col_ptr.as_dictionary()
            return dict_filter_eval_bool_mask(dict_arr, dict_op, str_val)

        elif col_at == ArrowType.STRING:
            # ⭐ READ IN PLACE. `as_string` copied the whole
            # column to feed a kernel that only reads it — cbq27's `url <> ''`
            # paid a full `url` copy per batch for it (C-pred, 7.1% of CPU).
            var arr = string_array_of(col_ptr)
            var str_val = lit_val.string_val
            if op == BIN_EQ:
                return eval_string_eq(arr, str_val)
            elif op == BIN_NE:
                return eval_string_ne(arr, str_val)
            elif op == BIN_GT:
                return eval_string_gt(arr, str_val)
            elif op == BIN_LT:
                return eval_string_lt(arr, str_val)
            elif op == BIN_GE:
                return eval_string_ge(arr, str_val)
            elif op == BIN_LE:
                return eval_string_le(arr, str_val)
            else:
                raise Error("PipelineCompiler: unsupported comparison op for string: " + String(Int(op)))

        elif col_at == ArrowType.LARGE_STRING:
            # LARGE_STRING
            # predicate parity.  Pre-fix, this branch fell into the else and
            # raised — making any predicate on a LARGE_STRING column impossible.
            # The Int64-offset kernels in komira_core.eval.string_comparison share
            # one `@parameter fn _string_*_kernel[OffsetType]` body with the
            # StringArray path; byte-identical semantics, only the offset
            # element width differs.
            var arr = col_ptr.as_large_string()
            var str_val = lit_val.string_val
            if op == BIN_EQ:
                return eval_large_string_eq(arr, str_val)
            elif op == BIN_NE:
                return eval_large_string_ne(arr, str_val)
            elif op == BIN_GT:
                return eval_large_string_gt(arr, str_val)
            elif op == BIN_LT:
                return eval_large_string_lt(arr, str_val)
            elif op == BIN_GE:
                return eval_large_string_ge(arr, str_val)
            elif op == BIN_LE:
                return eval_large_string_le(arr, str_val)
            else:
                raise Error("PipelineCompiler: unsupported comparison op for large string: " + String(Int(op)))

        else:
            raise Error("PipelineCompiler: unsupported column type for predicate: " + String(col_at))

    elif expr.tag == EXPR_ALIAS:
        # ★ AN ALIAS IS A NAME, NOT A VALUE. `_eval_column_expr` unwraps
        # `EXPR_ALIAS`; a ladder that refused it
        # with `unsupported predicate expression
        # not executable as a PROJECTION at all: the moment the projection arm
        # started delegating comparisons here, the plan-matrix cell
        # `proj_float_class/float64/{full,nanmix}` moved from
        # `unsupported float64 scalar binary op: 14` straight onto this wall.
        #
        # ⚠ IT IS NOT A THEORETICAL SHAPE, AND IT IS NOT AT THE TOP OF THE
        # EXPRESSION. `isfinite(v)` and `isnan(v)` in one SELECT share the
        # subtree `v > -inf AND v < inf`; CSE hoists it under an alias and
        # `merge_projects` inlines the aliased node back into its consumers, so
        # the surviving tree carries `NOT(Alias(AND(...), "<cse>"))` — an
        # ALIAS BELOW a `UN_NOT`, which the arm below hands straight back to
        # this function.
        #
        # The alias renames the OUTPUT COLUMN; in predicate position there is
        # no column to name, so the child's mask IS the answer. Same one-line
        # body `_eval_column_expr`'s `EXPR_ALIAS` arm has carried all along.
        return _eval_predicate(expr.alias_child_ref(), batch)

    elif expr.tag == EXPR_UNARY_OP:
        var op = expr.unary_op()
        if op == UN_NOT:
            var child_mask = _eval_predicate(expr.unary_child_ref(), batch)
            return eval_not(child_mask)
        elif op == UN_IS_NULL:
            # IS_NULL(col_ref) — emit a nullable BooleanArray where
            # data[r]=1 iff input row r is NULL, validity all-ones.
            # The COL_REF path is the fast one (no materialization); a
            # computed child takes the fallback immediately below.
            # ★ GENERAL-CHILD FALLBACK. The COL_REF
            # fast path below reads the resident column's validity bitmap with
            # no materialization; ANY OTHER child is materialized through
            # `_eval_column_expr` and its validity read the same way. This is
            # what makes `coalesce(...)`'s desugar reachable — the desugar
            # emits `<arg> IS NOT NULL` conditions and only its first argument
            # is ever a bare column, so a COL_REF-only arm would refuse
            # `coalesce(a, upper(b), 'z')` and every all-literal form
            # (`coalesce(NULL, NULL, 3)`) with a tag number.
            if expr.unary_child_ref().tag != EXPR_COL_REF:
                var gen_null = _eval_column_expr(expr.unary_child_ref(), batch)
                return _null_mask_of(gen_null, batch.num_rows(), True)
            var col_idx = resolve_col_index(expr.unary_child_ref(), batch.schema)
            ref col_ptr = batch.column_at(col_idx)
            var num_rows = batch.num_rows()
            var ba = BooleanArray.allocate_nullable(num_rows)
            # If the column has no validity bitmap, every row is non-null -> data stays all-zero.
            # Otherwise, set ba.data[r] = 1 where validity[r] = 0 (null).
            # Bytewise: data_byte = ~validity_byte (masked for trailing bits).
            if col_ptr._validity:
                var n_bytes = (num_rows + 7) >> 3
                # Origin-tied via function-scope view locals; the views
                # are bound on the same `if` arm so NLL releases the
                # borrows at last-use (the trailing-bit mask write) before
                # `return ba^` move-returns.
                var v_view = col_ptr._validity.value().buffer.view_ro()
                var d_view = ba.data.buffer.view_mut()
                var v_ptr = v_view._unsafe_ptr()
                var d_ptr = d_view._unsafe_ptr()
                for b in range(n_bytes):
                    (d_ptr + b)[] = ~(v_ptr + b)[]
                # Clear trailing bits in the last byte beyond `num_rows` bits
                # so they don't appear as phantom nulls.
                var trailing = num_rows & 7
                if trailing > 0 and n_bytes > 0:
                    var mask = UInt8((1 << trailing) - 1)
                    (d_ptr + n_bytes - 1)[] = (d_ptr + n_bytes - 1)[] & mask
            return ba^
        elif op == UN_IS_NOT_NULL:
            # =============================================================
            # ★ IS NOT NULL — THE POLARITY TWIN, AND IT DID NOT EXIST.
            # =============================================================
            #
            # `WHERE col IS NOT NULL` raised `PipelineCompiler: unsupported
            # unary predicate op: 3` — the arm directly above has served
            # `IS NULL` and its opposite fell into the `else`.
            #
            # ⚠ IT TOOK A FIX TO ANOTHER DEFECT TO MAKE THIS VISIBLE, which is
            # why it is landing here rather than having been found earlier.
            # `test_is_null_finds_exactly_the_missing_values` (S024) asserts
            # BOTH polarities in one body precisely because "the pair must
            # partition the six rows" — but its FIRST leg (`IS NULL`) returned
            # zero rows and failed at the row-count assertion, so the second
            # leg was never executed. The self-checking pair could not check
            # itself while its first half was broken. Both halves are green
            # now, and the partition is a real assertion for the first time.
            #
            # SEMANTICS: `data[r] = 1` iff row r is NOT null; validity
            # all-ones (the answer is never itself unknown). A computed child
            # takes the same materialize-then-read-validity fallback as
            # `IS NULL`; it is no longer refused.
            # ★ GENERAL-CHILD FALLBACK — see the `IS NULL` twin above. Same
            # materialize-then-read-validity shape, opposite polarity.
            if expr.unary_child_ref().tag != EXPR_COL_REF:
                var gen_nn = _eval_column_expr(expr.unary_child_ref(), batch)
                return _null_mask_of(gen_nn, batch.num_rows(), False)
            var nn_idx = resolve_col_index(
                expr.unary_child_ref(), batch.schema
            )
            ref nn_col = batch.column_at(nn_idx)
            var nn_rows = batch.num_rows()
            var nn_ba = BooleanArray.allocate_nullable(nn_rows)
            var nn_bytes = (nn_rows + 7) >> 3
            var nn_trailing = nn_rows & 7
            if nn_col._validity:
                # data_byte = validity_byte (NOT `~validity_byte` — that is
                # the arm above). Origin-tied views, same shape as `IS NULL`.
                var nv_view = nn_col._validity.value().buffer.view_ro()
                var nd_view = nn_ba.data.buffer.view_mut()
                var nv_ptr = nv_view._unsafe_ptr()
                var nd_ptr = nd_view._unsafe_ptr()
                for b in range(nn_bytes):
                    (nd_ptr + b)[] = (nv_ptr + b)[]
                if nn_trailing > 0 and nn_bytes > 0:
                    var nmask = UInt8((1 << nn_trailing) - 1)
                    (nd_ptr + nn_bytes - 1)[] = (
                        nd_ptr + nn_bytes - 1
                    )[] & nmask
            else:
                # ⚠ NO VALIDITY BITMAP MEANS EVERY ROW IS VALID, so every row
                # answers TRUE. `allocate_nullable` zero-fills the data, which
                # is the correct default for `IS NULL` and the WRONG one here
                # — the asymmetry is exactly why this cannot be spelled as
                # "the arm above with the `~` removed" and left at that.
                var nd_view2 = nn_ba.data.buffer.view_mut()
                var nd_ptr2 = nd_view2._unsafe_ptr()
                for b in range(nn_bytes):
                    (nd_ptr2 + b)[] = UInt8(0xFF)
                if nn_trailing > 0 and nn_bytes > 0:
                    var nmask2 = UInt8((1 << nn_trailing) - 1)
                    (nd_ptr2 + nn_bytes - 1)[] = (
                        nd_ptr2 + nn_bytes - 1
                    )[] & nmask2
            return nn_ba^
        else:
            raise Error("PipelineCompiler: unsupported unary predicate op: " + String(Int(op)))

    elif expr.tag == EXPR_IN_LIST:
        # set-membership predicate. Dispatch
        # to the typed kernel in `compiler_eval_in_list.mojo`. Single
        # batch sweep + inline value-table probe per row.
        return _eval_in_list(expr, batch)

    elif expr.tag == EXPR_STRING_OP:
        # String operations: CONTAINS, STARTS_WITH, ENDS_WITH, LIKE
        # ★ A COMPUTED OPERAND — `lower(s) LIKE 'a%'`,
        # `starts_with(trim(s), 'x')` — is MATERIALIZED first, the way the
        # computed-LHS arm above materializes `a * b > 100`. Without this every
        # such predicate raised `cannot resolve column index from expression
        # tag: 24` (through the SQL door, where DuckDB
        # v1.5.3 answers all of them), and SQL `ILIKE` — which IS
        # `lower(x) LIKE lower(p)` in DuckDB — could not run at all.
        if not expr_resolves_to_column(expr.string_op_child_ref()):
            var computed = _eval_column_expr(expr.string_op_child_ref(), batch)
            return _eval_string_op_on_column(
                computed, expr.string_op_type(), expr.string_op_pattern()
            )
        var col_idx = resolve_col_index(expr.string_op_child_ref(), batch.schema)
        return _eval_string_op_on_column(
            batch.column_at(col_idx), expr.string_op_type(), expr.string_op_pattern()
        )


    elif expr.tag == EXPR_REGEXP:
        # regexp_like / regexp_matches / `~` and
        # regexp_full_match are Bool-producing and so usable as a
        # filter predicate.  Every other regexp op (regexp_extract / match /
        # split_to_array / extract_all / replace / count / instr / substr)
        # produces a non-boolean value -> can't be a predicate.
        var rop = expr.regexp_op()
        if rop != REGEXP_LIKE and rop != REGEXP_FULL_MATCH:
            raise Error("PipelineCompiler: regexp_extract / regexp_match / regexp_split_to_array / regexp_extract_all / regexp_replace / regexp_count / regexp_instr / regexp_substr produce non-boolean values; cannot be used as a predicate (use them in a projection)")
        var col_idx = resolve_col_index(expr.regexp_child_ref(), batch.schema)
        ref col_ptr = batch.column_at(col_idx)
        var col_at = col_ptr.arrow_type
        if col_at != ArrowType.STRING and col_at != ArrowType.DICTIONARY:
            raise Error("PipelineCompiler: regexp_like / regexp_full_match require a STRING or DICTIONARY column, got " + String(col_at))
        var arr: StringArray[HeapRegion]
        if col_at == ArrowType.DICTIONARY:
            arr = _materialize_dict_to_string(col_ptr)
        else:
            # Lane G L1: read in place, as the comparison arm above does.
            arr = string_array_of(col_ptr)
        # `g` (replace-all) is not a pattern flag — strip it (harmless here).
        var gsplit = split_g_flag(expr.regexp_flags())
        var pattern_flags = gsplit[0]
        if rop == REGEXP_FULL_MATCH:
            var fm_prog = compile_full_match_program(expr.regexp_pattern(), pattern_flags)
            return eval_regexp_full_match(arr, fm_prog)
        var prog = RegexProgram.compile(expr.regexp_pattern(), pattern_flags)
        return eval_regexp_like(arr, prog)

    elif expr.tag == EXPR_LITERAL:
        # Literal boolean: broadcast to all rows
        var lit_val = expr.literal_value()
        var num_rows = batch.num_rows()
        var bm = Bitmap.create(num_rows)
        if lit_val.bool_val:
            for i in range(num_rows):
                bm.set(i)
        # else: all bits already clear (False)
        return BooleanArray.from_bitmap(bm^)

    elif expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX:
        # =====================================================================
        # ★ `WHERE flag` — A BARE BOOLEAN COLUMN IS ITSELF A PREDICATE.
        # =====================================================================
        #
        # This ladder had no arm for a bare column reference, so the plainest
        # boolean filter in SQL died at the receiver with
        # `unsupported predicate expression tag: 0` (tag 1, `EXPR_COL_IDX`, for
        # the bound twin the optimizer substitutes). MEASURED through the real
        # binary from a TypeScript e2e chain as
        # PLAN_ENDPOINT_EXECUTION_FAILED(20): `lf.filter(col("flag"))` and
        # `lf.filter(col("flag").not)` both reported tag 0 — the second
        # because `UN_NOT` recurses into this function on its child and hit the
        # same wall one frame down. ONE arm therefore fixes BOTH spellings.
        #
        # ⛔ IT BELONGS HERE, NOT IN A FRONTEND DESUGAR. Every skin that can
        # build a plan — the TypeScript SDK, the SQL binder, the Mojo
        # DataFrame API, the plan wire — lands on this one evaluator. A
        # `col -> col = TRUE` rewrite at admission would fix the door it was
        # written in and leave the other three encoding the same dead plan;
        # an arm here is reached by all of them, and by anything that reaches
        # `_eval_predicate` through the optimizer after a rewrite has already
        # run (which is precisely where an admission-time desugar is no longer
        # in the path).
        #
        # SEMANTICS: `WHERE flag` is `flag = TRUE` under SQL three-valued
        # logic — TRUE passes, FALSE fails, NULL is UNKNOWN and is dropped —
        # so this delegates to the ONE bool arm rather than re-reading the
        # bits. `_eval_bool_col_vs_literal` is offset-aware (a sliced BOOL
        # column post-join / post-concat) and imposes 3VL through the single
        # `kleene_cmp_finalize_scalar` seam; a second hand-rolled bitmap copy
        # here would be a second place for that to drift.
        #
        # ⛔ A NON-BOOL COLUMN STAYS A REFUSAL. There is no implicit
        # int-to-bool truthiness here and inventing one would turn a loud
        # refusal into a silent wrong answer; what changes is that the message
        # now names the COLUMN and its TYPE instead of an opaque tag number.
        var bare_idx = resolve_col_index(expr, batch.schema)
        ref bare_col = batch.column_at(bare_idx)
        var bare_at = bare_col.arrow_type
        if bare_at != ArrowType.BOOL:
            raise Error(
                "PipelineCompiler: a column used directly as a predicate"
                " requires a BOOL column; '"
                + batch.schema.field_name(bare_idx)
                + "' is "
                + String(bare_at)
                + " (write an explicit comparison, e.g. `col != 0`)"
            )
        return _eval_bool_col_vs_literal(
            bare_col, ScalarValue.from_bool(True), BIN_EQ
        )

    elif expr.tag == EXPR_AGG_FN:
        # EXPR_AGG_FN is a placeholder consumed by
        # the optimizer's `optimizer_scalar_broadcast` rule before eval
        # ever sees it. Reaching here means the rule did NOT fire (the
        # `Filter(<EXPR_AGG_FN>) over Aggregate` shape requirement was
        # not met) — surfacing loudly so the diagnostic is immediate.
        raise Error(
            "agg-fn outside filter-over-aggregate context — Pattern B"
            " requires Filter directly above Aggregate. For"
            " `.with_column(...)` / `.agg(...)` use cases use the"
            " existing `agg.max(col(\"x\"))` factory instead."
        )

    else:
        raise Error("PipelineCompiler: unsupported predicate expression tag: " + String(Int(expr.tag)))


# =============================================================================
# numeric-dict-aware FUSED filter+count.
# =============================================================================
#
# Root cause: a
# numeric (INT32/INT64) PLAIN_DICTIONARY column on the count_only + filter
# path was always (a) gathered to a flat per-row value array, (b) SIMD-
# compared in `_eval_predicate`'s INT64 arm, and (c) popcounted in a separate
# `mask.true_count` pass. For cb02 (`count(*) WHERE good_event=1` over 100M
# rows) that is a ~800MB int64 materialize + two full passes over 100M values.
#
# DuckDB builds a boolean LUT over the FEW distinct dict ENTRIES once
# (evaluate the predicate `dict_size` times), then counts code-matches over
# the narrow int32 codes — never materializing the per-row values.
#
# `count_numeric_dict_predicate` does exactly that and FUSES the predicate
# evaluation with the count into ONE pass over the codes (no intermediate
# BooleanArray mask, no separate popcount). It takes plain primitives (codes
# array + the entry set + op + threshold) rather than the parquet-side
# `NumericDictCodes` struct so this module stays free of any parquet import.


@always_inline
def _eval_int64_cmp(op: UInt8, value: Int64, threshold: Int64) -> Bool:
    """Scalar comparison matching the INT64 predicate arm semantics."""
    if op == BIN_EQ:
        return value == threshold
    if op == BIN_NE:
        return value != threshold
    if op == BIN_LT:
        return value < threshold
    if op == BIN_LE:
        return value <= threshold
    if op == BIN_GT:
        return value > threshold
    # BIN_GE (the comparison ops admitted by the fast-path detector are
    # exactly these six; the caller gates on `_op_is_numeric_comparison`).
    return value >= threshold


@always_inline
def _op_is_numeric_comparison(op: UInt8) -> Bool:
    """True for the six scalar comparison ops the LUT-count path supports."""
    return (
        op == BIN_EQ
        or op == BIN_NE
        or op == BIN_LT
        or op == BIN_LE
        or op == BIN_GT
        or op == BIN_GE
    )


def count_numeric_dict_predicate(
    codes: PrimitiveArray[DType.int32],
    dict_values: List[Int64],
    op: UInt8,
    threshold: Int64,
) raises -> Int:
    """Count the rows whose dict-resolved value satisfies `value <op> threshold`,
    WITHOUT materializing the per-row values.

    Builds a small boolean LUT over `dict_values` (one comparison per distinct
    dict entry), then counts `lut[codes[r]]` over every code in ONE pass — the
    fused replacement for gather + SIMD-compare + popcount.

    `op` MUST be one of the six numeric comparison ops (the caller gates this
    via the fast-path detector).

    Every code must be a dictionary index in `[0, len(dict_values))`. That is
    NOT something the Parquet file can be trusted to have got right — it is
    checked here, once, before the LUT gather. See the gate below.

    Returns the surviving row count.

    Raises:
        Error if `op` is not a comparison, or if any code is out of range for
        `dict_values`.
    """
    if not _op_is_numeric_comparison(op):
        raise Error(
            "count_numeric_dict_predicate: unsupported op "
            + String(Int(op))
        )

    var dict_size = len(dict_values)

    # ROBUSTNESS GATE.
    #
    # ⚠ THIS IS THE SITE A `resolve_*`-ONLY FIX MISSES, and it is the
    # worst of the family. The gather below is `lut[code]` where `lut` is
    # ONE BYTE PER DISTINCT DICT ENTRY — for the cb02 shape (`good_event`)
    # that is a 2-byte heap allocation. A code is a full Int32 off the wire,
    # so essentially ANY corrupt code reads far outside it. `List.__getitem__`
    # guards with `debug_assert`, which is inert at ASSERT=none, so nothing
    # stood between an attacker-authored page and this read.
    #
    # This path exists PRECISELY to avoid `resolve_int32` — it counts over the
    # narrow codes instead of gathering values — so the gate that landed in
    # `dictionary.mojo:resolve_*` can never run on it. The comment here used
    # to read "code in [0, dict_size) by the Parquet dict contract"; the
    # contract is a claim made BY THE FILE BEING PARSED.
    #
    # One bulk min/max pass over the codes, before the LUT is even built —
    # NOT a per-lane branch inside the gather loop, which is the hot loop
    # this whole fused path exists to keep tight.
    validate_dict_codes[DType.int32](
        codes.view_ro(),
        codes.length,
        dict_size,
        "count_numeric_dict_predicate",
    )

    # Build the per-entry LUT (UInt8 0/1). dict_size is the dictionary
    # cardinality — tiny relative to the row count.
    var lut = List[UInt8](capacity=dict_size)
    for e in range(dict_size):
        if _eval_int64_cmp(op, dict_values[e], threshold):
            lut.append(UInt8(1))
        else:
            lut.append(UInt8(0))

    var n = codes.length
    if n == 0:
        return 0

    # One pass over the codes, gathering lut[code] into a SIMD accumulator.
    # codes are int32 dictionary indices; the LUT gather is L1-resident
    # (dict_size tiny). No intermediate mask, no separate popcount.
    var idx_view = codes.view_ro()
    var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    comptime W: Int = simd_width_of[DType.int64]()
    var total: Int = 0
    var i = 0

    comptime if W >= 4:
        var acc = SIMD[DType.int64, W](0)
        var simd_end = (n // W) * W
        while i < simd_end:
            var lanes = SIMD[DType.int64, W](0)

            comptime for k in range(W):
                var code_k = Int((idx_ptr + i + k)[])
                # SAFETY: code in [0, dict_size) — ENFORCED by the
                # `validate_dict_codes` pass at the top of this function.
                # This used to read "by the Parquet dict contract", which
                # was a claim made BY THE FILE BEING PARSED.
                lanes[k] = Int64(Int(lut[code_k]))
            acc += lanes
            i += W
        total = Int(acc.reduce_add())

    # Scalar tail (also the whole loop when W < 4 via comptime DCE).
    while i < n:
        var code = Int((idx_ptr + i)[])
        total += Int(lut[code])
        i += 1

    # Hold the view borrow across the loop.
    _ = idx_view
    return total


def survivors_numeric_dict_predicate(
    codes: PrimitiveArray[DType.int32],
    dict_values: List[Int64],
    op: UInt8,
    threshold: Int64,
) raises -> List[Int]:
    """Late materialization: evaluate `value <op> threshold` over a
    numeric-dict column's CODES, producing the survivor ROW-INDEX list WITHOUT
    materializing the per-row values.

    The survivor-index sibling of `count_numeric_dict_predicate`: builds the
    same per-dict-entry boolean LUT (one comparison per distinct entry), then
    appends `r` for every row where `lut[codes[r]]` in one pass. `codes` MUST be
    row-aligned 1:1 with the output rows (the caller gates on `codes.length ==
    rg.num_rows`, i.e. the column has NO nulls in this RG — a NULL row would
    compact out of `codes` and break the alignment). Resolving
    `dict_values[codes[r]]` reproduces the flat decode of the column
    byte-for-byte, so the returned indices are EXACTLY
    `filter_to_indices(_eval_predicate(col <op> threshold, flat_batch))` — the
    correctness contract verified by test_parquet_dict_code_survivors_byte_equiv.

    Returning primitives (`List[Int]`) keeps the reader-trait method that wraps
    this free of any arrow type dependency. `op` is one of the six numeric
    comparison ops (BIN_EQ..BIN_GE).

    Every code must be a dict index in `[0, len(dict_values))`. That is NOT
    something the Parquet file can be trusted to have got right — it is
    checked here, once, before the LUT gather.

    Raises:
        Error if `op` is not a comparison, or if any code is out of range for
        `dict_values`.
    """
    if not _op_is_numeric_comparison(op):
        raise Error(
            "survivors_numeric_dict_predicate: unsupported op "
            + String(Int(op))
        )

    var dict_size = len(dict_values)

    # ROBUSTNESS GATE.
    #
    # ⚠ FOUND BY GREPPING FOR THE SHAPE, not by reading this file. This is the
    # survivor-index twin of `count_numeric_dict_predicate` — same `lut[code]`
    # gather over a one-byte-per-entry List, same "SAFETY: code in
    # [0, dict_size) by the Parquet dict contract" comment that the file being
    # parsed is under no obligation to honour, same `debug_assert`-only
    # `List.__getitem__` underneath. Fixing only the one someone happened to
    # report is how this defect class has survived three passes.
    validate_dict_codes[DType.int32](
        codes.view_ro(),
        codes.length,
        dict_size,
        "survivors_numeric_dict_predicate",
    )

    var lut = List[UInt8](capacity=dict_size)
    for e in range(dict_size):
        if _eval_int64_cmp(op, dict_values[e], threshold):
            lut.append(UInt8(1))
        else:
            lut.append(UInt8(0))

    var n = codes.length
    var out = List[Int]()
    if n > 0:
        var idx_view = codes.view_ro()
        var idx_ptr = idx_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var r = 0
        while r < n:
            var code = Int((idx_ptr + r)[])
            # SAFETY: code in [0, dict_size) — ENFORCED by the
            # `validate_dict_codes` pass at the top of this function. This
            # used to read "by the Parquet dict contract", which was a claim
            # made BY THE FILE BEING PARSED.
            if lut[code] == UInt8(1):
                out.append(r)
            r += 1
        _ = idx_view
    return out^
