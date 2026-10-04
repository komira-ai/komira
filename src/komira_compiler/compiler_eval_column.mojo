# =============================================================================
# compiler_eval_column — column / projection / arithmetic / cast evaluation
# =============================================================================
#
# Split out of compiler_eval.mojo.
# Contains:
#   _eval_col_vs_col_promoted — col-vs-col compare under SQL numeric promotion
#                               (predicate-producer; called from
#                               compiler_eval_predicate._eval_predicate)
#   _eval_binary_col_scalar   — col {op} literal-scalar via SIMD scalar kernels
#   _eval_column_expr         — Expr -> Column projection entry point
#
# This is the file that will grow with future kernel-gap work (EXPR_CAST
# string↔numeric/temporal, EXPR_EXTRACT, EXPR_COALESCE/NULLIF, Decimal128
# arith dispatch).
# =============================================================================

from std.sys import simd_width_of
from std.ffi import external_call
from komira_core.eval.int_overflow import is_int_overflow_error

from komira_core.arrow.schema import RecordBatch
from komira_core.instr.rxcensus import (
    RXC_PROG_COMPILES,
    RXC_ARM_CALLS,
    RXC_ARM_DICT,
    rxcensus_add,
)
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.arrow_types import ArrowType
# NOTE: the RAW `eval_col_*` kernels are deliberately NOT imported here. This
# file's only col-vs-col comparison is `_col_cmp_nullable`, which is the
# validity-honouring entry point; importing the raw ones back would re-open the
# arm-by-arm choice that closed.
from komira_kernels.comparison_kleene import (
    eval_col_gt_nullable, eval_col_lt_nullable, eval_col_eq_nullable,
    eval_col_ne_nullable, eval_col_le_nullable, eval_col_ge_nullable,
    kleene_cmp_finalize, NullPolicy,
)
from komira_core.eval.decimal_compare import (
    decimal_cmp_i128, DEC_CMP_LT, DEC_CMP_LE, DEC_CMP_GT, DEC_CMP_GE,
    DEC_CMP_EQ, DEC_CMP_NE,
)
from komira_core.eval.arithmetic import eval_add, eval_sub, eval_mul, eval_div, eval_not, eval_add_scalar, eval_sub_scalar, eval_rsub_scalar, eval_mul_scalar, eval_div_scalar
from komira_core.eval.cast_null import (
    eval_cast, eval_cast_float_to_int, eval_cast_f64_to_f32_checked,
)
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
# INTERVAL_MDN componentwise
# add/sub at the BINARY_OP eval site.  Equality (BIN_EQ) is reachable for
# free via the eq kernel; only ADD/SUB need a column-level allocator.
from komira_core.arrow import IntervalMonthDayNanoArray
from komira_core.eval import (
    add_interval_mdn,
    sub_interval_mdn,
    eval_eq_interval_mdn,
)
from komira_core.eval.decimal_arith import (
    I128,
    decimal_add_i128, decimal_sub_i128, decimal_mul_i128, decimal_div_i128,
    decimal_add_result_ps, decimal_mul_result_ps, decimal_div_result_ps,
)
from komira_core.eval.decimal_cast import (
    int_to_decimal_i128, float_to_decimal_i128, decimal_to_float64,
    decimal_to_int64, decimal_rescale_i128, decimal_to_string,
    string_to_decimal_i128,
)
# The string <-> numeric cast kernels.
from komira_kernels.cast_to_varchar_kernels import (
    cast_string_to_int64,
    cast_string_to_int32,
    cast_string_to_float64,
    cast_string_to_float32,
    cast_int64_to_string,
    cast_int32_to_string,
    cast_float64_to_string,
    cast_float32_to_string,
)
# Temporal extract (year/month/day/...).
from komira_kernels.temporal_extract import (
    extract_year_date32,
    extract_month_date32,
    extract_day_date32,
    extract_quarter_date32,
    extract_subday_zero_date32,
    extract_year_ts,
    extract_month_ts,
    extract_day_ts,
    extract_quarter_ts,
    extract_hour_ts,
    extract_minute_ts,
    extract_second_ts,
    extract_day_index_date32,
    extract_day_index_ts,
    extract_iso_week_date32,
    extract_iso_week_ts,
    extract_subsecond_ts,
    date_trunc_date32,
    date_trunc_ts,
    TRUNC_YEAR,
    TRUNC_QUARTER,
    TRUNC_MONTH,
    TRUNC_WEEK,
    TRUNC_DAY,
    TRUNC_HOUR,
    TRUNC_MINUTE,
    TRUNC_SECOND,
    TRUNC_MILLISECOND,
    TRUNC_MICROSECOND,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.agg_expr import (
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_core.eval.regexp_nfa import RegexProgram
from komira_core.eval.digest_functions import (
    md5_hex_bytes,
    sha1_hex_bytes,
    sha256_hex_bytes,
)
from komira_core.eval.regexp_functions import (
    eval_regexp_like,
    eval_regexp_extract,
    eval_regexp_match,
    eval_regexp_split_to_array,
    eval_regexp_extract_all,
    eval_regexp_replace,
    eval_regexp_count,
    eval_regexp_instr,
    eval_regexp_substr,
    eval_regexp_full_match,
    compile_full_match_program,
    split_g_flag,
    regexp_escape_bytes,
)
from .compiler_eval_dict import _materialize_dict_to_string
# ⚠ NOT `.unicode_case` ANY MORE. The Unicode simple case
# mapping moved DOWN into `komira_core.eval` so a package that may not
# depend on `komira_compiler` can fold a literal with the SAME mapping
# this kernel applies to the column — for example a spreadsheet-style text
# `=` that folds BOTH sides:
# an operand folded by a DIFFERENT mapping than `STRFN_LOWER` below is a
# comparison that silently matches nothing. Sharing one definition is what
# makes them agree by construction rather than by review.
from komira_core.eval.unicode_case import (
    unicode_lower_bytes, unicode_upper_bytes,
)
from .compiler_eval_in_list import _eval_in_list
from komira_core.plan.literal_domain import int_literal_fits
from komira_jsonl.json_extract_kernel import extract_column as json_extract_column
from komira_core.plan.expr_udf_sites import udf_call_column_key
from komira_core.plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    # the projection arm for
    # EXPR_UNARY_OP. See the arm's own comment for why it was missing.
    EXPR_UNARY_OP,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    # the four TYPE-PRESERVING numeric members.
    UN_ABS,
    UN_SIGN,
    UN_TRUNC,
    UN_ROUND,
    UN_BIT_COUNT,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_WHEN,
    EXPR_IN_LIST,
    # the projection arm for the four fixed-pattern
    # string PREDICATES, which `walk_expr_field` typed BOOL long before this
    # ladder could evaluate one.
    EXPR_STRING_OP,
    EXPR_AGG_FN,
    EXPR_REGEXP,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    STRFN_UPPER,
    STRFN_LOWER,
    STRFN_TRIM,
    STRFN_LTRIM,
    STRFN_RTRIM,
    STRFN_LENGTH,
    STRFN_REVERSE,
    STRFN_ASCII,
    STRFN_UNICODE,
    STRFN_STRLEN,
    STRFN_BIT_LENGTH,
    STRFN_HEX,
    STRFN_BIN,
    STRFN_URL_ENCODE,
    STRFN_URL_DECODE,
    STRFN_REGEXP_ESCAPE,
    STRFN_MD5,
    STRFN_SHA1,
    STRFN_SHA256,
    string_fn_returns_int,
    EXPR_STRING_FN_N,
    STRFNN_CONCAT,
    STRFNN_CONCAT_WS,
    STRFNN_REPLACE,
    STRFNN_LPAD,
    STRFNN_RPAD,
    STRFNN_REPEAT,
    STRFNN_STRPOS,
    STRFNN_LEVENSHTEIN,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
    STRFNN_TRANSLATE,
    STRFNN_JARO,
    STRFNN_JARO_WINKLER,
    STRFNN_JACCARD,
    STRING_FN_N_REPEAT_MAX_BYTES,
    string_fn_n_returns_int,
    string_fn_n_returns_float,
    string_fn_n_arity_ok,
    string_fn_n_arity,
    string_fn_n_name,
    EXPR_UDF_CALL,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXTRACT_YEAR,
    EXTRACT_QUARTER,
    EXTRACT_MONTH,
    EXTRACT_DAY,
    EXTRACT_HOUR,
    EXTRACT_MINUTE,
    EXTRACT_SECOND,
    EXTRACT_DAYOFWEEK,
    EXTRACT_ISODOW,
    EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK,
    EXTRACT_ISOYEAR,
    EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND,
    EXTRACT_MICROSECOND,
    EXTRACT_TRUNC_YEAR,
    EXTRACT_TRUNC_QUARTER,
    EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK,
    EXTRACT_TRUNC_DAY,
    EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MINUTE,
    EXTRACT_TRUNC_SECOND,
    EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MICROSECOND,
    _is_trunc_unit,
    REGEXP_LIKE,
    REGEXP_EXTRACT,
    REGEXP_MATCH,
    REGEXP_REPLACE,
    REGEXP_SPLIT_TO_ARRAY,
    REGEXP_EXTRACT_ALL,
    REGEXP_COUNT,
    REGEXP_INSTR,
    REGEXP_SUBSTR,
    REGEXP_FULL_MATCH,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    BIN_DIV,
    BIN_MOD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
    BIN_OR,
)
from komira_core.helpers.compiler_helpers import (
    resolve_col_index,
    expr_resolves_to_column,
    project_column_share_eligible,
    copy_column,
    broadcast_scalar,
    int64_to_float64,
    clone_array_validity,
    merge_binary_arith_validity,
)

from komira_core.eval.scalar_math import (
    eval_math_unary,
    eval_math_binary,
)

from komira_core.eval.numeric_unary import (
    numeric_unary_kernel_tag,
    eval_numeric_unary_float,
    eval_numeric_unary_int,
    eval_sign_float,
    eval_sign_int,
    eval_bit_count_int,
)

from .compiler_eval_case import _eval_when_expr

# ⚠ A CYCLE, AND A PRE-EXISTING ONE. `compiler_eval_predicate` imports
# `_eval_column_expr` from THIS module and `compiler_eval_case` imports both;
# column <-> case was already mutually recursive before this edge existed. The
# alternative — re-implementing the four pattern kernels here — is the
# duplicate-ladder defect this file's own docstring is about.
from .compiler_eval_predicate import (
    _eval_predicate, _is_comparison_op, _eval_string_op_on_column,
)


def _column_to_float64(
    col: Column[HeapRegion],
) raises -> PrimitiveArray[DType.float64]:
    """Coerce a numeric Column to a FLOAT64 PrimitiveArray (validity-preserving).

    The EXPR_MATH_FN(2) kernels operate on
    FLOAT64. Accepts FLOAT64 (zero-copy as_primitive), INT64, or INT32
    inputs and widens via the existing validity-preserving cast helpers.
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
    else:
        raise Error(
            "PipelineCompiler: scalar math function requires a numeric"
            " (FLOAT64 / INT64 / INT32) input, got type_id="
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
# THREE sites inside `compiler_eval_predicate._eval_predicate`:
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
# `compiler_eval_predicate._eval_col_vs_col` uses. It lives here rather than
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

    THE ONE col-vs-col null seam. Both `compiler_eval_predicate.
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
# `compiler_eval_predicate._eval_col_vs_col` ("unsupported column type:
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
# `col OP literal` ladder in `compiler_eval_predicate._eval_predicate`, whose
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


# =============================================================================
# Column expression evaluation — Expr -> Column
# =============================================================================


# =============================================================================
# ★★ BIN_MOD AS AN OUTPUT COLUMN — THE LAST BINARY OP WITH NO
#    PROJECTION ARM.
# =============================================================================
#
# `BIN_MOD` (op 4) had an interpreter kernel (`komira_kernels/expr_interpreter`)
# and two generated kernel templates (IDs 64/65) and NO arm here, so `mod(a,b)`
# BOUND and could not RUN: `unsupported int64 scalar binary op: 4` on the
# col-vs-literal ladder and `unsupported int64 binary op: 4` on the col-vs-col
# one. It was held out as `F21-binop-not-executable-as-a-projection` and it was
# the only binary op in that state — every comparison was closed
# by delegating to the predicate ladder, which a remainder cannot do because a
# remainder is not a mask.
#
# ⛔ THERE IS NO `eval_mod` KERNEL AND THESE TWO FUNCTIONS DO NOT WRITE ONE.
# The remainder is composed out of `eval_div` / `eval_mul` / `eval_sub`, which
# is not a shortcut but the ONLY way to inherit three behaviours that are
# already written down once:
#
#   1. `eval_div` / `eval_div_scalar` are TOTAL over the integers. A ZERO
#      DIVISOR yields a NULL row with NOTHING handed to the
#      machine's divide instruction. A hand-written `%` kernel would have had
#      to re-derive that, and the failure mode it protects against is a SIGFPE
#      that takes the process down — measured, on this exact op family.
#   2. `clone_array_validity` MERGES rather than overwrites, so the
#      divide-by-zero mask survives into the remainder.
#   3. The INT64 / INT32 / FLOAT64 width rules and the literal-promotion rules
#      stay in ONE place (`_eval_binary_col_scalar`), which is what this file's
#      own header asks for.
#
# ⛔⛔ AND IT IS `a - trunc(a/b)*b`, NOT `a % b`. MEASURED, IN BOTH DIRECTIONS:
#   * DuckDB v1.5.3 `-17 % 5` = **-2** — TRUNCATED, remainder takes the sign of
#     the DIVIDEND (C's rule).
#   * Mojo's `%` is **FLOOR-mod** — and written down in
#     `komira_kernels/temporal_extract._dayofweek_from_days`, where the same fact
#     is load-bearing in the OPPOSITE direction. `-17 % 5` there is **3**.
# So the language's own operator is the WRONG answer here by 5, and the two
# conventions agree on every non-negative dividend — which is exactly why the
# regression corpus carries `m = -17` and `m = 17, n = -5`. This engine's
# integral `BIN_DIV` truncates toward zero (SIMD `/` lowers to the hardware
# divide), so the identity below IS the truncated remainder.
#
# ⚠ `fmod` IS A DIFFERENT FUNCTION AND MUST NOT BE ROUTED HERE. Measured
# v1.5.3 at (-17, 5): `mod` = -2, `fmod` = **3.0** — FLOORED. `fmod` already
# has its own binder desugar (`sql_binder`, `x - y*floor(x/y)`) and making the
# two agree would be wrong on one of them.
#
# ⚠ `mod(INT64_MIN, -1)` RAISES here because `eval_div`'s MIN/-1 overflow guard
# fires on the quotient — and that AGREES with the oracle. This paragraph used to
# call it a residual ("0 in DuckDB"); RE-DuckDB 1.5.3
# raises `Out of Range Error: Overflow in division of -9223372036854775808 / -1`
# for `mod`, `%` and `//` alike (`numeric_domain_oracle.tsv` i64_mod@k4 is an
# ERROR cell). polars / numpy answer 0 — the skins' business, not this kernel's.
#
# ⛔ THE FLOAT ARM IS NOT THIS IDENTITY. See `_fmod_cc`.



@always_inline
def _fmod_f64(a: Float64, b: Float64) -> Float64:
    """C `fmod` — exact, sign of the dividend, NaN for a zero divisor / an
    infinite dividend, the dividend itself for an infinite divisor."""
    return external_call["fmod", Float64](a, b)


def _fmod_cc[
    dt: DType
](la: PrimitiveArray[dt], ra: PrimitiveArray[dt]) -> PrimitiveArray[dt]:
    """Row-wise `fmod(la, ra)` over a FLOATING dtype. A float32 operand widens
    to float64 exactly, and `fmod`'s exact result narrows back exactly. The
    result carries no validity; the caller merges the operands'."""
    var n = la.length
    var out = PrimitiveArray[dt].allocate(n)
    # SAFETY: origin-tied views held in function scope keep all three buffers
    # alive across the loop; the typed pointers never leave this function.
    var lv = la.view_ro()
    var rv = ra.view_ro()
    var ov = out.view_mut()
    var lp = lv._unsafe_ptr().bitcast[Scalar[dt]]()
    var rp = rv._unsafe_ptr().bitcast[Scalar[dt]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dt]]()
    for i in range(n):
        var r = _fmod_f64(
            lp.load[width=1](i).cast[DType.float64](),
            rp.load[width=1](i).cast[DType.float64](),
        )
        op_.store[width=1](i, r.cast[dt]())
    return out^


def _fmod_cs[
    dt: DType
](arr: PrimitiveArray[dt], scalar: Scalar[dt]) -> PrimitiveArray[dt]:
    """`fmod(arr, scalar)` — the col-vs-LITERAL twin of `_fmod_cc`."""
    var n = arr.length
    var out = PrimitiveArray[dt].allocate(n)
    # SAFETY: as `_fmod_cc`.
    var av = arr.view_ro()
    var ov = out.view_mut()
    var ap = av._unsafe_ptr().bitcast[Scalar[dt]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dt]]()
    var b = scalar.cast[DType.float64]()
    for i in range(n):
        var r = _fmod_f64(ap.load[width=1](i).cast[DType.float64](), b)
        op_.store[width=1](i, r.cast[dt]())
    return out^


def _mod_trunc_cc[
    dt: DType
](la: PrimitiveArray[dt], ra: PrimitiveArray[dt]) raises -> PrimitiveArray[dt]:
    """`la - trunc(la / ra) * ra` — the TRUNCATED remainder, column vs column.

    The integral arm needs no `trunc`: this engine's integral divide already
    truncates toward zero. The floating arm is NOT this identity — it is libm
    `fmod` (`_fmod_cc`), because the identity rounds.
    """

    comptime if dt.is_floating_point():
        # ⛔ NOT `la - trunc(la / ra) * ra` OVER FLOATS. That
        # identity ROUNDS three times: `mod(1.7976931348623157e308, 10.0)`
        # answered 0.0 (DuckDB 8.0 — the quotient has no bits left for the
        # remainder at that magnitude) and `mod(-0.0, 1.0)` answered +0.0
        # (DuckDB -0.0 — `-0.0 - (-0.0 * 1.0)` is +0.0). DuckDB 1.5.3's float
        # `%` IS C `fmod` — MEASURED bit for bit over a 156-pair edge grid
        # (signed zeros, +-inf, NaN, subnormals, DBL_MAX, zero divisors) — and
        # `fmod` is EXACT, so this is libm's.
        return _fmod_cc[dt](la, ra)
    else:
        var q = eval_div[dt](la, ra)
        var pr = eval_mul[dt](q, ra)
        var rem = eval_sub[dt](la, pr)
        # ⛔ LOAD-BEARING: `q`'s NULL rows are the ZERO-DIVISOR rows, and their
        # data slot is an allocated 0 — so `rem` holds `la` there and would
        # come back VALID and WRONG without this. `clone_array_validity`
        # merges, so the caller's own operand merge cannot undo it either.
        clone_array_validity[dt, dt](q, rem)
        return rem^


def _mod_trunc_cs[
    dt: DType
](arr: PrimitiveArray[dt], scalar: Scalar[dt]) raises -> PrimitiveArray[dt]:
    """`arr - trunc(arr / scalar) * scalar` — the col-vs-LITERAL twin.

    Kept as a separate spelling rather than broadcasting the literal into a
    column because that is what every other op on this ladder does: the whole
    point of `_eval_binary_col_scalar` is to avoid materialising N copies of a
    constant, and a MOD that silently did would be the one op on the ladder
    with a different cost model.
    """

    comptime if dt.is_floating_point():
        # libm `fmod`, as `_mod_trunc_cc` (the float identity rounded).
        return _fmod_cs[dt](arr, scalar)
    else:
        # `eval_div_scalar` answers an ALL-NULL column for a zero literal
        # divisor without dividing anything; the merge below carries that.
        var q = eval_div_scalar[dt](arr, scalar)
        var pr = eval_mul_scalar[dt](q, scalar)
        var rem = eval_sub[dt](arr, pr)
        clone_array_validity[dt, dt](q, rem)
        return rem^


def _eval_binary_col_scalar(
    col: Column[HeapRegion], op: UInt8, sv: ScalarValue, scalar_left: Bool = False
) raises -> Column[HeapRegion]:
    """Evaluate column {op} scalar using SIMD scalar kernels.

    `scalar_left=True` evaluates `scalar - column` (BIN_SUB only) through
    `eval_rsub_scalar` — NOT as `-(column - scalar)`, which raised a false
    INT64 overflow at `-1 - MAX` and answered -0.0 for `1.0 - 1.0` (see
    `eval_rsub_scalar`).

    Avoids materializing the scalar into a full N-element array.
    Uses eval_mul_scalar, eval_add_scalar, etc. which broadcast
    the scalar in SIMD registers — zero allocation overhead.
    """
    # NOTE: the `eval_*_scalar` SIMD kernels
    # allocate a fresh result array with no validity; a literal scalar is
    # never NULL, so the result's validity == the column's validity. We copy
    # it onto `result` before wrapping so a `nullable_col + lit` keeps its
    # null mask (was silently coming back all-valid).
    if col.arrow_type == ArrowType.FLOAT64:
        var arr = col.as_primitive[DType.float64]()
        # symmetric to the INT-col vs FLOAT-lit fix
        # below — a FLOAT-col vs INT-literal carries its value in
        # `int_val`, NOT `float_val` (which is 0 for an int literal). Read
        # the scalar via its REAL dtype: float literal -> `float_val`,
        # int literal -> widen `int_val` to f64. Output stays f64.
        var sval: Float64
        if sv.is_int():
            sval = Float64(Int(sv.int_val))
        else:
            sval = sv.float_val
        var scalar = Scalar[DType.float64](sval)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add_scalar[DType.float64](arr, scalar)
        elif op == BIN_SUB and scalar_left:
            result = eval_rsub_scalar[DType.float64](scalar, arr)
        elif op == BIN_SUB:
            result = eval_sub_scalar[DType.float64](arr, scalar)
        elif op == BIN_MUL:
            result = eval_mul_scalar[DType.float64](arr, scalar)
        elif op == BIN_DIV:
            result = eval_div_scalar[DType.float64](arr, scalar)
        elif op == BIN_MOD:
            result = _mod_trunc_cs[DType.float64](arr, scalar)
        else:
            raise Error("unsupported float64 scalar binary op: " + String(Int(op)))
        clone_array_validity[DType.float64, DType.float64](arr, result)
        return Column.from_primitive[DType.float64](result)

    elif col.arrow_type == ArrowType.INT64 or col.arrow_type == ArrowType.INT32:
        # SQL numeric promotion for INT-col {op}
        # FLOAT-literal. The scalar's value lives in `float_val`, NOT
        # `int_val` (ScalarValue.from_float sets int_val=0). Pre-fix the
        # INT arms read `sv.int_val` blindly -> `int_col + 0.5` added 0
        # (silent-wrong). Dispatch on the scalar's REAL dtype: when the
        # literal is FLOAT, promote the int column to f64 (matching the
        # per-node col-col promotion at line ~1307 and the row path) and
        # run the float kernel; output f64. ALL arms (+,-,*,/) affected.
        if sv.is_float():
            var f_arr = _column_to_float64(col)
            var f_scalar = Scalar[DType.float64](sv.float_val)
            var f_result: PrimitiveArray[DType.float64]
            if op == BIN_ADD:
                f_result = eval_add_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_SUB and scalar_left:
                f_result = eval_rsub_scalar[DType.float64](f_scalar, f_arr)
            elif op == BIN_SUB:
                f_result = eval_sub_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_MUL:
                f_result = eval_mul_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_DIV:
                f_result = eval_div_scalar[DType.float64](f_arr, f_scalar)
            elif op == BIN_MOD:
                f_result = _mod_trunc_cs[DType.float64](f_arr, f_scalar)
            else:
                raise Error("unsupported int-col vs float-literal scalar binary op: " + String(Int(op)))
            # `_column_to_float64` is validity-preserving on the column
            # side; the scalar is never NULL, so the f64 result's null
            # mask already matches the source column.
            clone_array_validity[DType.float64, DType.float64](f_arr, f_result)
            return Column.from_primitive[DType.float64](f_result)

        # THE SIXTH SITE, and
        # the one a composition ran through. The INT32 arm below used to build
        # its operand as `Scalar[DType.int32](Int32(Int(sv.int_val)))`, keeping
        # the LOW 32 BITS of the literal. For `+ - *` that was a silent wrong
        # value; for `/` it was worse, because `4294967296` truncates to ZERO
        # and the (correct) divide-by-zero guard then answered NULL for every row:
        # `SELECT q32 / 4294967296` -> NULL, where DuckDB v1.5.3 `//` -> 0. Before the
        # guard the same query was a PROCESS KILL — so the composition is fixed
        # HERE, at the truncation, and NOT by relaxing the guard.
        #
        # SQL numeric promotion is the rule, not an int32-specific patch: an
        # INT32 column against a literal outside int32 range promotes to INT64,
        # the same INT64 ⊕ INT32 → INT64 row `_eval_col_vs_col_promoted`'s table
        # already states, and the same result type DuckDB gives
        # (`typeof(i32 + 4294967296)` = BIGINT, ).
        var int_lit_needs_widening = (
            col.arrow_type == ArrowType.INT32
            and not int_literal_fits[DType.int32](sv.int_val)
        )

        if col.arrow_type == ArrowType.INT64 or int_lit_needs_widening:
            # `_column_to_int64` is the VALIDITY-PRESERVING widen (INT64 passes
            # through zero-copy); never a hand-rolled loop — see this file's
            # col-vs-col header.
            var arr = _column_to_int64(col)
            var scalar = Scalar[DType.int64](sv.int_val)
            var result: PrimitiveArray[DType.int64]
            if op == BIN_ADD:
                result = eval_add_scalar[DType.int64](arr, scalar)
            elif op == BIN_SUB and scalar_left:
                result = eval_rsub_scalar[DType.int64](scalar, arr)
            elif op == BIN_SUB:
                result = eval_sub_scalar[DType.int64](arr, scalar)
            elif op == BIN_MUL:
                result = eval_mul_scalar[DType.int64](arr, scalar)
            elif op == BIN_DIV:
                result = eval_div_scalar[DType.int64](arr, scalar)
            elif op == BIN_MOD:
                result = _mod_trunc_cs[DType.int64](arr, scalar)
            else:
                raise Error("unsupported int64 scalar binary op: " + String(Int(op)))
            clone_array_validity[DType.int64, DType.int64](arr, result)
            return Column.from_primitive[DType.int64](result)

        else:  # ArrowType.INT32, with a literal that PROVABLY fits it
            var arr = col.as_primitive[DType.int32]()
            # Reached only when `int_literal_fits[DType.int32]` said yes, so
            # this cast is LOSSLESS by the branch above. Spelled `.cast[]`
            # rather than the old `Int32(Int(...))` so no future reader has to
            # re-derive whether the truncating form was intentional here.
            var scalar = Scalar[DType.int32](sv.int_val.cast[DType.int32]())
            var result: PrimitiveArray[DType.int32]
            if op == BIN_ADD:
                result = eval_add_scalar[DType.int32](arr, scalar)
            elif op == BIN_SUB and scalar_left:
                result = eval_rsub_scalar[DType.int32](scalar, arr)
            elif op == BIN_SUB:
                result = eval_sub_scalar[DType.int32](arr, scalar)
            elif op == BIN_MUL:
                result = eval_mul_scalar[DType.int32](arr, scalar)
            elif op == BIN_DIV:
                result = eval_div_scalar[DType.int32](arr, scalar)
            elif op == BIN_MOD:
                result = _mod_trunc_cs[DType.int32](arr, scalar)
            else:
                raise Error("unsupported int32 scalar binary op: " + String(Int(op)))
            clone_array_validity[DType.int32, DType.int32](arr, result)
            return Column.from_primitive[DType.int32](result)

    # Fallback: broadcast scalar to column and use column-column path
    from komira_core.helpers.compiler_helpers import broadcast_scalar
    var right_col = broadcast_scalar(sv, col.length())
    raise Error("_eval_binary_col_scalar: unsupported type " + String(Int(col.arrow_type.type_id)))


# =============================================================================
# DECIMAL128 — column binary arithmetic + casts
# =============================================================================
#
# Scalar per-row loops over native
# int128 — perf is explicitly not the goal here.  The result Column carries
# the result (precision, scale).  Validity = AND(left, right) (the correct
# behavior — net-new code, no validity-drop legacy bug).


def _resolve_decimal_ps(col: Column[HeapRegion], batch: RecordBatch, name_hint: String) raises -> Tuple[Int, Int]:
    """(precision, scale) for a DECIMAL128 column — prefers the column's own
    metadata, else looks the field up in the batch schema by name."""
    if col.decimal_precision() > 0:
        return (col.decimal_precision(), col.decimal_scale())
    # Fall back to the batch schema.
    try:
        var idx = batch.schema.column_index(name_hint)
        return (batch.schema.field_decimal_precision(idx), batch.schema.field_decimal_scale(idx))
    except e:
        raise Error("Decimal128: column carries no (precision, scale) and not found in schema")


def _resolve_temporal_arrow_type(
    col: Column[HeapRegion], batch: RecordBatch, name_hint: String
) -> ArrowType:
    """The TEMPORAL type of `col` — from the column's own stamp if it has one,
    else from the batch SCHEMA's field of that name. `ArrowType.NULL` when
    neither says temporal.

    ★★ THIS EXISTS BECAUSE THE PARQUET READER DOES NOT STAMP THE COLUMN, AND
    THAT IS THE LIVE PRODUCTION SHAPE — not an edge case. A DATE32 is
    physically int32 days and a TIMESTAMP_* is physically int64 ticks, and the
    decode path hands back a Column whose `arrow_type` is the PHYSICAL one
    while the FIELD in `batch.schema` carries the logical temporal type
    (`komira_parquet/decode_helpers.mojo` builds a tz-carrying Timestamp Field;
    `test_date32_predicate_filter` calls the INT32-stamped date column "the
    LIVE production shape" in as many words).

    ⛔ AND IT IS THE REASON THIS HELPER IS NOT A TIDY-UP:
    `SELECT year(d) FROM read_parquet(...)` over a DATE32 column failed with
    `PipelineCompiler: EXPR_EXTRACT child must be DATE32 or TIMESTAMP_*, got
    type_id=4` — type_id 4 is INT32. So `EXPR_EXTRACT` had NEVER been reachable
    over a parquet scan, through ANY door: the whole temporal family works in
    the unit suites only because those hand-stamp an in-memory batch. A
    capability can be fully implemented, wired end to end, and reachable from
    nothing.

    ⚠ THE SCHEMA IS CONSULTED, NOT GUESSED, AND THE DIFFERENCE IS THE WHOLE
    SAFETY ARGUMENT. Reading "int32 means DATE32, int64 means TIMESTAMP" off
    the BUFFER WIDTH would make `year(some_bigint_column)` answer a plausible
    year instead of refusing — a silent wrong answer on a column that is not a
    date at all. This only ever promotes a column whose own schema field SAYS
    it is temporal; anything else falls through to the caller's refusal.

    ★ THE SHAPE IS `_resolve_decimal_ps`'s, deliberately. DECIMAL128 has the
    identical problem (precision/scale live on the field, not always on the
    column) and solved it this way; a second, differently-shaped answer to the
    same question is how two paths drift.
    """
    var own = col.arrow_type
    if (
        own == ArrowType.DATE32
        or own == ArrowType.TIMESTAMP
        or own == ArrowType.TIMESTAMP_S
        or own == ArrowType.TIMESTAMP_MS
        or own == ArrowType.TIMESTAMP_US
        or own == ArrowType.TIMESTAMP_NS
    ):
        return own
    # An unstamped column can only be promoted from its PHYSICAL width, and
    # only when the schema agrees: int32 <- DATE32, int64 <- TIMESTAMP_*.
    if own != ArrowType.INT32 and own != ArrowType.INT64:
        return ArrowType.NULL
    if name_hint.byte_length() == 0:
        return ArrowType.NULL
    try:
        var idx = batch.schema.column_index(name_hint)
        var declared = batch.schema.field_arrow_type(idx)
        if own == ArrowType.INT32 and declared == ArrowType.DATE32:
            return declared
        if own == ArrowType.INT64 and (
            declared == ArrowType.TIMESTAMP
            or declared == ArrowType.TIMESTAMP_S
            or declared == ArrowType.TIMESTAMP_MS
            or declared == ArrowType.TIMESTAMP_US
            or declared == ArrowType.TIMESTAMP_NS
        ):
            return declared
        return ArrowType.NULL
    except e:
        # Not a named column of this batch (a computed child), so there is no
        # declaration to promote from. Refusing is correct.
        return ArrowType.NULL


def _decimal_col_to_i128(col: Column[HeapRegion]) raises -> List[I128]:
    """Materialize a DECIMAL128 column's values as native int128s."""
    var n = col.length()
    var out = List[I128]()
    var arr = col.as_decimal128()
    for i in range(n):
        out.append(arr.get_i128(i))
    return out^



def _eval_decimal_binary_pair(
    left_col: Column[HeapRegion],
    right_col: Column[HeapRegion],
    op: UInt8,
    batch: RecordBatch,
    l_name: String,
    r_name: String,
) raises -> Column[HeapRegion]:
    """`left <op> right` where AT LEAST ONE side is DECIMAL128 -- the ONE
    decimal arithmetic arm. The column-column path calls it, and so does the
    scalar fast path once it has broadcast the literal (a decimal column
    against a literal, or a DECIMAL literal against any column), so a literal
    operand cannot take a different rule from a column one."""
    # decimal {+,-,*,/} decimal (with scale
    # alignment).  Mixed decimal/int -> promote the int to a decimal
    # at the decimal's scale.  Mixed decimal/float -> promote the
    # decimal to float64 and do float arithmetic (decimal "loses" to
    # float in the SQL coercion lattice — matches DuckDB/DataFusion).
    if left_col.arrow_type == ArrowType.DECIMAL128 and right_col.arrow_type == ArrowType.DECIMAL128:
        if op == BIN_DIV:
            # ⛔ DECIMAL / DECIMAL IS DOUBLE. Dividing in DECIMAL at the
            # Hive scale s1 + 4 gives `dc / dp` = decimal(18,6)
            # 29.285714 where DuckDB 1.5.3 answers DOUBLE 29.28571428571429 (a
            # VALUE divergence, not type-only), and a zero divisor RAISED
            # `Decimal128 division by zero` where DuckDB answers inf / nan.
            # DuckDB converts both sides to DOUBLE and divides (IEEE), as the
            # decimal / BIGINT arm below already does; `walk_expr_field`
            # declares FLOAT64 for it.
            var lq = _promote_to_float64(left_col, batch, l_name)
            var rq = _promote_to_float64(right_col, batch, r_name)
            var q = eval_div[DType.float64](lq, rq)
            merge_binary_arith_validity[DType.float64](left_col, right_col, q)
            return Column.from_primitive[DType.float64](q)
        return _decimal_binary_col(left_col, right_col, op, batch, l_name, r_name)
    elif left_col.arrow_type == ArrowType.FLOAT64 or right_col.arrow_type == ArrowType.FLOAT64:
        # Promote the decimal side to float64; fall through to a fresh
        # float64-float64 eval.
        var lf = _promote_to_float64(left_col, batch, l_name)
        var rf = _promote_to_float64(right_col, batch, r_name)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add[DType.float64](lf, rf)
        elif op == BIN_SUB:
            result = eval_sub[DType.float64](lf, rf)
        elif op == BIN_MUL:
            result = eval_mul[DType.float64](lf, rf)
        elif op == BIN_DIV:
            result = eval_div[DType.float64](lf, rf)
        else:
            raise Error("PipelineCompiler: unsupported decimal/float binary op: " + String(Int(op)))
        # ⛔ THE ONE ARITHMETIC ARM THAT MUST NOT SKIP THE VALIDITY MERGE:
        # without it a NULL decimal
        # row came back VALID, holding whatever the kernel computed
        # over its payload -- `120.0 / NULL` answered `inf` at the
        # untyped Mojo and typed doors where DuckDB answers NULL.
        merge_binary_arith_validity[DType.float64](left_col, right_col, result)
        return Column.from_primitive[DType.float64](result)
    elif left_col.arrow_type == ArrowType.INT64 or right_col.arrow_type == ArrowType.INT64:
        # ⛔ DECIMAL (op) INTEGER COLUMN.
        # This arm promoted the int to a DECIMAL AT THE DECIMAL'S SCALE for
        # EVERY op and ran the decimal kernel, while `walk_expr_field`
        # declared the DECIMAL side's (p, s) -- and the batch is stamped
        # with the DECLARED type. MEASURED at the SQL door, dc
        # decimal(12,2) = 10.25, nn int64 = 1: `dc * nn` came back
        # 1025.00 (the product at scale 4, relabelled scale 2: x100) and
        # `dc / nn` 102500.00 (the quotient at scale s+4: x10^4); `nn /
        # dc` and `120 / dc` likewise, silently. DuckDB 1.5.3:
        #   `/`  -> DOUBLE (IEEE: x / 0 = inf, 0 / 0 = nan)
        #   `*`  -> the int is DECIMAL(19, 0): result scale s1 + 0
        #   `+ -`-> aligned at the decimal's scale (what this arm did)
        # and `walk_expr_field` now declares the same (FLOAT64 for `/`).
        if op == BIN_DIV:
            var lq = _promote_to_float64(left_col, batch, l_name)
            var rq = _promote_to_float64(right_col, batch, r_name)
            var q = eval_div[DType.float64](lq, rq)
            merge_binary_arith_validity[DType.float64](left_col, right_col, q)
            return Column.from_primitive[DType.float64](q)
        if op == BIN_MUL:
            var lm = _promote_int_to_decimal_scale0(left_col)
            var rm = _promote_int_to_decimal_scale0(right_col)
            return _decimal_binary_col(lm, rm, op, batch, l_name, r_name)
        # Promote the int side to a DECIMAL128 at the decimal's scale.
        var ld = _promote_to_decimal(left_col, right_col, batch, l_name, r_name)
        var rd = _promote_to_decimal(right_col, left_col, batch, r_name, l_name)
        return _decimal_binary_col(ld, rd, op, batch, l_name, r_name)
    else:
        raise Error(
            "PipelineCompiler: unsupported decimal binary-op operand combination: "
            + String(left_col.arrow_type) + " and " + String(right_col.arrow_type)
        )


def _decimal_binary_col(left_col: Column[HeapRegion], right_col: Column[HeapRegion], op: UInt8, batch: RecordBatch, left_name: String, right_name: String) raises -> Column[HeapRegion]:
    """col {+,-,*,/} col for DECIMAL128 columns (with scale alignment)."""
    var ps1 = _resolve_decimal_ps(left_col, batch, left_name)
    var ps2 = _resolve_decimal_ps(right_col, batch, right_name)
    var p1 = ps1[0]
    var s1 = ps1[1]
    var p2 = ps2[0]
    var s2 = ps2[1]
    var n = left_col.length()
    if right_col.length() != n:
        raise Error("Decimal128 binary op: column length mismatch")
    var lv = _decimal_col_to_i128(left_col)
    var rv = _decimal_col_to_i128(right_col)
    # Result (p, s).
    var rp: Int
    var rs: Int
    if op == BIN_ADD or op == BIN_SUB:
        var ps = decimal_add_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    elif op == BIN_MUL:
        var ps = decimal_mul_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    elif op == BIN_DIV:
        var ps = decimal_div_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    else:
        raise Error("Decimal128: unsupported binary op " + String(Int(op)))
    # validity = AND(left, right).
    var has_a = Bool(left_col._validity)
    var has_b = Bool(right_col._validity)
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if has_a or has_b:
        var bm = Bitmap.create_all_valid(n)
        for i in range(n):
            var valid = True
            if has_a:
                if not left_col._validity.value().test(left_col._offset + i):
                    valid = False
            if valid and has_b:
                if not right_col._validity.value().test(right_col._offset + i):
                    valid = False
            if not valid:
                bm.clear(i)
                nulls += 1
        validity = bm^
    var out = Decimal128Array.allocate(n, rp, rs)
    for i in range(n):
        # Skip computing for null slots (value bytes are zero-filled;
        # division by a null operand value would otherwise be div-by-zero).
        if validity:
            if not validity.value().test(i):
                out.set_i128(i, I128(0))
                continue
        var rval: I128
        if op == BIN_ADD:
            rval = decimal_add_i128(lv[i], s1, rv[i], s2, rs)
        elif op == BIN_SUB:
            rval = decimal_sub_i128(lv[i], s1, rv[i], s2, rs)
        elif op == BIN_MUL:
            rval = decimal_mul_i128(lv[i], rv[i])
        else:  # BIN_DIV
            rval = decimal_div_i128(lv[i], s1, rv[i], s2, rs)
        out.set_i128(i, rval)
    var col = Column.from_decimal128(out)
    col._validity = validity^
    col._null_count = nulls
    return col^


def _expr_name_hint(expr: Expr) -> String:
    """Best-effort column name for a (possibly aliased) column-ref Expr.
    Returns "" if it's not a plain column reference."""
    if expr.tag == EXPR_COL_REF:
        return expr.col_ref_name()
    elif expr.tag == EXPR_ALIAS:
        return _expr_name_hint(expr.alias_child_ref())
    return ""


def _promote_to_float64(col: Column[HeapRegion], batch: RecordBatch, name_hint: String) raises -> PrimitiveArray[DType.float64]:
    """Cast a DECIMAL128 / INT64 / FLOAT64 column to a float64 PrimitiveArray."""
    if col.arrow_type == ArrowType.FLOAT64:
        return col.as_primitive[DType.float64]()
    if col.arrow_type == ArrowType.INT64:
        return int64_to_float64(col.as_primitive[DType.int64]())
    if col.arrow_type == ArrowType.DECIMAL128:
        var ps = _resolve_decimal_ps(col, batch, name_hint)
        var s = ps[1]
        var n = col.length()
        var arr = col.as_decimal128()
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
    raise Error("_promote_to_float64: unsupported source type " + String(col.arrow_type))


def _promote_int_to_decimal_scale0(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """A DECIMAL128 column is copied; an INT64 column becomes DECIMAL(19, 0) --
    DuckDB's own type for a BIGINT operand of a decimal `*` (so the product's
    scale is the decimal side's scale plus 0)."""
    if col.arrow_type == ArrowType.DECIMAL128:
        return Column.from_decimal128(col.as_decimal128())
    if col.arrow_type == ArrowType.INT64:
        var n = col.length()
        var src = col.as_primitive[DType.int64]()
        var out = Decimal128Array.allocate_nullable(n, 19, 0)
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, I128(Int(src.get(i))))
        return Column.from_decimal128(out)
    raise Error(
        "_promote_int_to_decimal_scale0: unsupported source type "
        + String(col.arrow_type)
    )


def _promote_to_decimal(col: Column[HeapRegion], other: Column[HeapRegion], batch: RecordBatch, name_hint: String, other_hint: String) raises -> Column[HeapRegion]:
    """If `col` is DECIMAL128, return a copy.  If INT64, promote to a
    DECIMAL128 at `other`'s scale (with enough precision; capped at 38)."""
    if col.arrow_type == ArrowType.DECIMAL128:
        return Column.from_decimal128(col.as_decimal128())
    if col.arrow_type == ArrowType.INT64:
        var ps = _resolve_decimal_ps(other, batch, other_hint)
        var s = ps[1]
        # An Int64 has <= 19 digits; promote to D(min(38, 19+s), s).
        var p = 19 + s
        if p > 38:
            p = 38
        var n = col.length()
        var src = col.as_primitive[DType.int64]()
        var out = Decimal128Array.allocate_nullable(n, p, s)
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(src.get(i), p, s))
        return Column.from_decimal128(out)
    raise Error("_promote_to_decimal: unsupported source type " + String(col.arrow_type))


@always_inline
def _ts_unit_factor(src: ArrowType, dst: ArrowType) -> Int64:
    """Return the unit scale factor mapping `src` timestamp unit to `dst`.

    Convention:
    - Returns 0 if `src == dst` (no scale).
    - Returns +factor (positive) if `dst` is FINER than `src` (multiply).
    - Returns -factor (negative; caller negates) if `dst` is COARSER than
      `src` (divide).

    Units: TIMESTAMP_S = 0, TIMESTAMP_MS = 1, TIMESTAMP_US = 2,
    TIMESTAMP_NS = 3. Each step is ×1000. Legacy `TIMESTAMP` (no unit) is
    treated as TIMESTAMP_US (microseconds; matches the legacy default).
    """
    var s = _ts_unit_rank(src)
    var d = _ts_unit_rank(dst)
    if s == d:
        return Int64(0)
    var diff = d - s
    # ×1000 per step. Pre-compute via a small switch on |diff|.
    var abs_diff = diff if diff > 0 else -diff
    var factor: Int64
    if abs_diff == 1:
        factor = Int64(1000)
    elif abs_diff == 2:
        factor = Int64(1_000_000)
    elif abs_diff == 3:
        factor = Int64(1_000_000_000)
    else:
        factor = Int64(1)
    if diff > 0:
        return factor
    else:
        return -factor


@always_inline
def _ts_unit_rank(at: ArrowType) -> Int:
    """Rank a TIMESTAMP_* unit on the [0..3] scale: s=0, ms=1, us=2, ns=3.

    Legacy unitless `TIMESTAMP` maps to us (rank 2) by default.
    """
    if at == ArrowType.TIMESTAMP_S:
        return 0
    elif at == ArrowType.TIMESTAMP_MS:
        return 1
    elif at == ArrowType.TIMESTAMP_NS:
        return 3
    else:
        # TIMESTAMP_US and legacy TIMESTAMP both rank as us (2).
        return 2


def _eval_cast_to_decimal128(child_col: Column[HeapRegion], p: Int, s: Int, batch: RecordBatch, name_hint: String) raises -> Column[HeapRegion]:
    """CAST(child AS DECIMAL(p, s)) — child is int/float/decimal/string."""
    var n = child_col.length()
    var src_at = child_col.arrow_type
    var out = Decimal128Array.allocate_nullable(n, p, s)
    if src_at == ArrowType.INT64:
        var src = child_col.as_primitive[DType.int64]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(src.get(i), p, s))
    elif src_at == ArrowType.INT32:
        var src = child_col.as_primitive[DType.int32]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(Int64(Int(src.get(i))), p, s))
    elif src_at == ArrowType.FLOAT64:
        var src = child_col.as_primitive[DType.float64]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                var ov = float_to_decimal_i128(Float64(src.get(i)), p, s)
                if ov:
                    out.set_i128(i, ov.value())
                else:
                    out.set_null(i)
    elif src_at == ArrowType.DECIMAL128:
        var ps = _resolve_decimal_ps(child_col, batch, name_hint)
        var from_s = ps[1]
        var arr = child_col.as_decimal128()
        for i in range(n):
            if arr.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, decimal_rescale_i128(arr.get_i128(i), from_s, p, s))
    elif src_at == ArrowType.STRING:
        var src = child_col.as_string()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, string_to_decimal_i128(src.get(i), p, s))
    else:
        raise Error("CAST to DECIMAL128: unsupported source type " + String(src_at))
    return Column.from_decimal128(out)


def _eval_cast_from_decimal128(child_col: Column[HeapRegion], target: DType, target_arrow: ArrowType, batch: RecordBatch, name_hint: String) raises -> Column[HeapRegion]:
    """CAST(decimal AS int/float/string)."""
    var n = child_col.length()
    var ps = _resolve_decimal_ps(child_col, batch, name_hint)
    var s = ps[1]
    var arr = child_col.as_decimal128()
    if target == DType.float64 or target_arrow == ArrowType.FLOAT64:
        var out = PrimitiveArray[DType.float64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_float64(arr.get_i128(i), s))
        out.null_count = nulls
        return Column.from_primitive[DType.float64](out)
    elif target == DType.int64 or target_arrow == ArrowType.INT64:
        var out = PrimitiveArray[DType.int64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_int64(arr.get_i128(i), s))
        out.null_count = nulls
        return Column.from_primitive[DType.int64](out)
    elif target == DType.int32 or target_arrow == ArrowType.INT32:
        var out = PrimitiveArray[DType.int32].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                var v64 = decimal_to_int64(arr.get_i128(i), s)
                if v64 > Int64(2147483647) or v64 < Int64(-2147483648):
                    raise Error("CAST DECIMAL128 -> INT32: value out of range")
                out.set(i, Int32(Int(v64)))
        out.null_count = nulls
        return Column.from_primitive[DType.int32](out)
    elif target == DType.float32 or target_arrow == ArrowType.FLOAT32:
        # ⭐ ADDED WITH THE RE-ADMISSION OF `REAL` AS A SQL CAST
        # TARGET. Without it `CAST(<decimal> AS REAL)` would have been the ONE
        # numeric source/target pair that still raised, and a target that works
        # for most operands and reports an internal error for one is worse than
        # one refused uniformly — the exact argument that withdrew REAL a day
        # earlier. ⚠ VIA FLOAT64 ON PURPOSE: `decimal_to_float64` is the single
        # decimal->binary-float conversion, and narrowing its correctly-rounded
        # result is what DuckDB does for `DECIMAL -> FLOAT` too.
        var out = PrimitiveArray[DType.float32].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, Float32(decimal_to_float64(arr.get_i128(i), s)))
        out.null_count = nulls
        return Column.from_primitive[DType.float32](out)
    elif target_arrow == ArrowType.STRING:
        # decimal -> string: build a StringArray of formatted values (NULL
        # rows -> empty string; the Column's validity bitmap carries NULLs).
        var values = List[String]()
        var bm = Bitmap.create_all_valid(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                values.append(String(""))
                bm.clear(i)
                nulls += 1
            else:
                values.append(decimal_to_string(arr.get_i128(i), s))
        var sa = StringArray.from_strings(values)
        var col = Column.from_string(sa)
        if nulls > 0:
            col._validity = bm^
            col._null_count = nulls
        return col^
    else:
        raise Error("CAST DECIMAL128 -> " + String(target_arrow) + ": unsupported target")


def _reduce_agg_scalar(col: Column[HeapRegion], op: UInt8) raises -> ScalarValue:
    """Reduce a fully-resident numeric Column to a single agg ScalarValue.

    The tag-12 / `EXPR_AGG_FN` typed-frame lowering of the post-agg
    scalar-broadcast shape `col == col.max` (TPC-H Q15). The caller has ALREADY
    materialized the FULL agg-breaker output into
    one resident batch (`materialize_subplan`'s POST-BREAKER FILTER arm decodes
    the breaker to a single RecordBatch BEFORE applying the predicate), so a
    reduction over `col` here is a correct GLOBAL aggregate across every group —
    mirroring the generic `DataFrame[O]` path's `optimizer_scalar_broadcast`
    eager-fold, but WITHOUT the double base-scan (the scalar is folded once over
    the resident column, not by re-executing an ungrouped Aggregate sub-plan).

    Semantics BYTE-MATCH `agg_scalar_fold.fold_scalar_agg_over_batch` (the
    monolith-free 0-key fold): a SERIAL single-accumulator reduction over the
    NON-NULL rows (value-stable — SUM matches the serial reducer bit-for-bit),
    the narrow-signed widen-fold (int-family -> I64 accumulator), and the exact
    `_agg_output_arrow` output-dtype map — int-family SUM/MIN/MAX -> INT64,
    float-family SUM/MIN/MAX -> FLOAT64, MEAN -> FLOAT64, COUNT -> INT64.

    NULL/empty contract (SQL + the generic broadcast rewrite's `scalar(batch)`):
      * COUNT (with a child) counts the NON-NULL rows -> INT64 (0 when empty).
      * SUM/MIN/MAX/MEAN over zero contributing (non-null) rows -> typed NULL
        (the empty-subquery identity; `col == NULL` then collapses every row to
        FALSE under Arrow null-compare — matching DuckDB's empty-agg semantics).

    Only the SUM/COUNT/MIN/MAX/MEAN ops over the fixed-width INT/FLOAT families
    are in-envelope. Any other op or a non-numeric input RAISES a clear error
    (this is the RAISING projection-eval path — the caller's
    `_inmem_filter_predicate_supported` gate keeps out-of-envelope predicates
    from ever reaching here)."""
    if (
        op != AGG_SUM
        and op != AGG_COUNT
        and op != AGG_MIN
        and op != AGG_MAX
        and op != AGG_MEAN
    ):
        raise Error(
            "PipelineCompiler: scalar-broadcast EXPR_AGG_FN supports only"
            " SUM/COUNT/MIN/MAX/MEAN (got op=" + String(Int(op)) + ")"
        )

    var at = col.arrow_type
    var n = col.length()

    # --- INT family (widen-fold into an I64 accumulator). ----------------------
    if (
        at == ArrowType.INT64
        or at == ArrowType.INT32
        or at == ArrowType.INT16
        or at == ArrowType.INT8
    ):
        var acc: Int64 = 0
        var count: Int = 0
        var have = False
        if at == ArrowType.INT64:
            var arr = col.as_primitive[DType.int64]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = arr.get(r)
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        else:
            # INT32 / narrow signed — widen each value to I64.
            var arr = col.as_primitive[DType.int32]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = Int64(arr.get(r))
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        if op == AGG_COUNT:
            return ScalarValue.from_int64(Int64(count))
        if count == 0:
            # Empty / all-null aggregate — typed NULL (SUM/MIN/MAX/MEAN).
            if op == AGG_MEAN:
                return ScalarValue.null(DType.float64)
            return ScalarValue.null(DType.int64)
        if op == AGG_MEAN:
            return ScalarValue.from_float(Float64(acc) / Float64(count))
        return ScalarValue.from_int64(acc)

    # --- FLOAT family (fold into an F64 accumulator). --------------------------
    elif at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32:
        var acc: Float64 = 0.0
        var count: Int = 0
        var have = False
        if at == ArrowType.FLOAT64:
            var arr = col.as_primitive[DType.float64]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = arr.get(r)
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        else:
            var arr = col.as_primitive[DType.float32]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = Float64(arr.get(r))
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        if op == AGG_COUNT:
            return ScalarValue.from_int64(Int64(count))
        if count == 0:
            if op == AGG_COUNT:
                return ScalarValue.from_int64(Int64(0))
            return ScalarValue.null(DType.float64)
        if op == AGG_MEAN:
            return ScalarValue.from_float(acc / Float64(count))
        return ScalarValue.from_float(acc)

    raise Error(
        "PipelineCompiler: scalar-broadcast EXPR_AGG_FN requires a fixed-width"
        " numeric (INT/FLOAT-family) input column, got type_id="
        + String(Int(at.type_id))
    )


def _trim_space_bytes(s: String, strip_left: Bool, strip_right: Bool) -> List[UInt8]:
    """`trim` / `ltrim` / `rtrim` — strip the SPACE character (0x20) only.

    ⛔ SPACE, NOT "WHITESPACE", AND THAT IS MEASURED. DuckDB v1.5.3's
    one-argument `trim` leaves tabs and newlines ON the string:
    `trim(e'\t  hi  \t')` comes back with both tabs. A kernel written against
    an `isspace` intuition would strip them and disagree with DuckDB on every
    value carrying one — a divergence no ASCII-letters fixture would show.

    Byte-wise is exact here for a reason `upper`/`lower` do NOT get to use
    (`unicode_case.mojo` has to decode): 0x20 can never occur inside a
    multi-byte UTF-8 sequence, whose bytes are all >= 0x80, so a byte-wise
    test for it cannot fire in the middle of a character.
    """
    var b = s.as_bytes()
    var n = len(b)
    var lo = 0
    var hi = n
    if strip_left:
        while lo < hi and b[lo] == 0x20:
            lo += 1
    if strip_right:
        while hi > lo and b[hi - 1] == 0x20:
            hi -= 1
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(b[i])
    return out^


def _utf8_char_count(b: Span[UInt8, _]) -> Int:
    """`length(s)` — the CODEPOINT count, which is what DuckDB's `length`
    returns (measured: `length('héllo')` = 5 while `strlen('héllo')` = 6).

    Counts every byte that is NOT a UTF-8 continuation byte (`0b10xxxxxx`,
    i.e. `0x80..0xBF`). That is exact for well-formed UTF-8 and needs no
    decode, no table and no allocation — so unlike `upper`/`lower` this
    member has NO divergence from DuckDB to state.

    ⭐ TAKES A BORROWED `Span[UInt8]`, NOT A `String`. Callers hand it
    `StringArray.get_span(i)` — a zero-copy view over the Arrow data buffer.
    Taking a `String` forced every caller through `StringArray.get(i)`, which
    materialises an OWNING `String` per row (a `List[UInt8]` heap allocation,
    a byte-at-a-time `ByteView.copy_to`, a second heap allocation + memcpy in
    the `String` ctor, then two frees). On ClickBench Q27
    (`avg(length(url))`) that per-row materialisation was 1420 ms of a 3555 ms
    query — 40% of the wall — for an algorithm that reads each byte once.
    DuckDB never copies a string byte at all: its `string_t` points straight
    into the decompressed Parquet page
    (`extension/parquet/reader/string_column_reader.cpp:69-77`).

    ⚠ The algorithm itself is byte-for-byte DuckDB's
    (`src/include/duckdb/function/scalar/string_common.hpp:25-34`:
    `length += IsCharacter(c)` where `IsCharacter(c) = (c & 0xc0) != 0x80`),
    so the gap this signature closes was never the arithmetic.
    """
    var n = len(b)
    var count = 0
    var i = 0
    # ⭐ THE COUNT IS A BRANCHLESS SIMD REDUCTION, NOT A PER-BYTE `if`.
    # DuckDB writes the same arithmetic as `length += IsCharacter(c)` — an
    # unconditional ADD of a 0/1 predicate (`string_common.hpp:25-34`), which
    # clang auto-vectorises. The Mojo spelling `if (b[i] & 0xC0) != 0x80:
    # count += 1` is a BRANCH, and the compiler does not turn it back into a
    # reduction — so this kernel walked 7.43 GB of `url` one scalar byte at a
    # time on ClickBench Q27. The vector form is the same predicate
    # (`(c & 0xC0) != 0x80`) reduced `simd_width_of[uint8]` bytes at a time;
    # the scalar tail below is the identical expression, so the two halves
    # cannot disagree about what a character is.
    #
    # ⚠ THE `reduce_add` ACCUMULATOR IS `uint8` AND THAT IS SAFE ONLY BECAUSE
    # THE VECTOR IS NARROWER THAN 256 LANES. Each lane contributes 0 or 1, so
    # the lane sum is at most `W`; `simd_width_of[uint8]` is 16 on arm64 and
    # 32/64 on x86 AVX2/AVX-512, all far below the 255 an unsigned byte holds.
    # A hypothetical 256-lane target would need a wider accumulator.
    comptime W = simd_width_of[DType.uint8]()
    var simd_end = (n // W) * W
    if simd_end > 0:
        # SAFETY: `b` is a borrowed `Span[UInt8]` whose origin the signature
        # carries, so the pointer cannot outlive the data buffer; every load
        # is inside `[0, simd_end)` and `simd_end <= n == len(b)`. No pointer
        # escapes this function (module-internal SIMD
        # with a concrete origin).
        var p = b.unsafe_ptr()
        var cont = SIMD[DType.uint8, W](0x80)
        var mask_c0 = SIMD[DType.uint8, W](0xC0)
        while i < simd_end:
            var v = p.load[width=W](i)
            count += Int((v & mask_c0).ne(cont).cast[DType.uint8]().reduce_add())
            i += W
    while i < n:
        if (b[i] & 0xC0) != 0x80:
            count += 1
        i += 1
    return count


def _levenshtein_bytes(a: String, b: String) -> Int:
    """`levenshtein(a, b)` — insert/delete/substitute edit distance over BYTES.

    ⛔ BYTES, NOT CHARACTERS, AND THAT IS MEASURED. DuckDB v1.5.3:
    `levenshtein('é','')` = 2 (one CHARACTER, two bytes) and
    `levenshtein('😀','x')` = 4. Every textbook writes this over characters and
    a character kernel is right on all of ASCII.

    Two rolling rows, so the working set is O(min-ish) rather than O(n*m) —
    the DP itself is the classic one and there is nothing clever in it.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0:
        return m
    if m == 0:
        return n
    var prev = List[Int](capacity=m + 1)
    var cur = List[Int](capacity=m + 1)
    for j in range(m + 1):
        prev.append(j)
        cur.append(0)
    for i in range(1, n + 1):
        cur[0] = i
        for j in range(1, m + 1):
            var sub = prev[j - 1]
            if ab[i - 1] != bb[j - 1]:
                sub += 1
            var best = prev[j] + 1
            if cur[j - 1] + 1 < best:
                best = cur[j - 1] + 1
            if sub < best:
                best = sub
            cur[j] = best
        for j in range(m + 1):
            prev[j] = cur[j]
    return prev[m]


def _damerau_levenshtein_bytes(a: String, b: String) -> Int:
    """`damerau_levenshtein(a, b)` — UNRESTRICTED Damerau-Levenshtein, BYTES.

    ⛔⛔ NOT THE OPTIMAL STRING ALIGNMENT DISTANCE, AND DuckDB SETTLES IT.
    MEASURED on v1.5.3: `damerau_levenshtein('ca','abc')` = **2**. OSA — the
    two-row variant that merely adds a transposition arm to the Levenshtein
    recurrence — answers **3** there, because it forbids editing a substring
    it has already transposed. The two agree on `('ab','ba')` = 1, on
    `('kitten','sitting')` = 3 and on most short inputs, so `('ca','abc')` is
    the smallest witness and it is in this file's fixture for that reason.

    The unrestricted algorithm needs a LAST-OCCURRENCE table over the alphabet
    (`da` below) and a full (n+2) x (m+2) matrix with a sentinel row/column
    holding `INF`. Because this kernel is BYTE-based the alphabet is closed at
    256, so `da` is a fixed array and not a hash map — the byte reading is the
    cheap implementation as well as the correct one.

    Reference: Damerau (1964) / Lowrance-Wagner (1975). `d[i+1][j+1]` is the
    distance between the first `i` bytes of `a` and the first `j` of `b`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0:
        return m
    if m == 0:
        return n
    var inf = n + m
    # `da[c]` = the largest i such that a[i-1] == c, so far. 0 = "not seen".
    var da = List[Int](capacity=256)
    for _c in range(256):
        da.append(0)
    # Row-major (n+2) x (m+2), flattened.
    var w = m + 2
    var d = List[Int](capacity=(n + 2) * w)
    for _e in range((n + 2) * w):
        d.append(0)
    d[0 * w + 0] = inf
    for i in range(0, n + 1):
        d[(i + 1) * w + 0] = inf
        d[(i + 1) * w + 1] = i
    for j in range(0, m + 1):
        d[0 * w + (j + 1)] = inf
        d[1 * w + (j + 1)] = j
    for i in range(1, n + 1):
        var db = 0
        for j in range(1, m + 1):
            # ⚠ `k` INDEXES ON `b[j-1]`, NOT ON `a[i-1]`. The two lines
            # below are the pair the Lowrance-Wagner recurrence is easiest to
            # transcribe backwards: `k` is where THIS COLUMN'S character last
            # occurred in `a`, `l` is where THIS ROW'S character last matched
            # in `b`. Swapping them still returns a plausible small integer.
            var k = da[Int(bb[j - 1])]
            var l = db
            var cost = 1
            if ab[i - 1] == bb[j - 1]:
                cost = 0
                db = j
            var best = d[i * w + j] + cost
            var ins = d[(i + 1) * w + j] + 1
            if ins < best:
                best = ins
            var dele = d[i * w + (j + 1)] + 1
            if dele < best:
                best = dele
            # THE TRANSPOSITION ARM — the whole difference from OSA. `k` is
            # where `b[j-1]` last occurred in `a`, `l` is where `a[i-1]` last
            # matched in `b`; the block between them is jumped in one edit
            # plus the cost of skipping what lies inside it.
            var trans = d[k * w + l] + (i - k - 1) + 1 + (j - l - 1)
            if trans < best:
                best = trans
            d[(i + 1) * w + (j + 1)] = best
        da[Int(ab[i - 1])] = i
    return d[(n + 1) * w + (m + 1)]


def _hamming_bytes(a: String, b: String) raises -> Int:
    """`hamming(a, b)` — the number of BYTE positions at which they differ.

    ⛔ IT RAISES ON TWO INPUTS THE REST OF THIS FAMILY ACCEPTS, and both
    messages mirror DuckDB v1.5.3 verbatim:
      * UNEQUAL LENGTHS — `hamming('abc','abcd')`. The comparison is on BYTES,
        so `hamming('é','e')` raises there too, even though both operands are
        exactly one CHARACTER.
      * TWO EMPTY STRINGS — `hamming('','')`. This is the surprising one:
        `levenshtein('','')` is 0 and "count the differing positions" of two
        empty sequences is naturally 0, so a kernel that answered 0 would look
        right AND would accept a call the parity target rejects.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    if n != len(bb):
        raise Error(
            "PipelineCompiler: hamming() — Strings must be of equal length!"
        )
    if n == 0:
        raise Error(
            "PipelineCompiler: hamming() — Strings must be of length > 0!"
        )
    var diff = 0
    for i in range(n):
        if ab[i] != bb[i]:
            diff += 1
    return diff


def _jaro_bytes(a: String, b: String) -> Float64:
    """`jaro_similarity(a, b)` — the Jaro similarity over BYTES, in [0, 1].

    ⛔ BYTES, NOT CHARACTERS, AND IT IS MEASURED. DuckDB v1.5.3:
    `jaro_similarity('Ünïcodé','Unicode')` = 0.65714285714285714. `'Ünïcodé'`
    is SEVEN characters and TEN bytes; the byte reading finds 4 matches over
    (10, 7) and answers (4/10 + 4/7 + 4/4)/3 = 0.65714..., while a character
    kernel finds 4 over (7, 7) and answers 0.71428... — right on all of ASCII,
    wrong on the first row that is not, this repo's standing defect shape.

    ⚠ AN EMPTY OPERAND ANSWERS 0 AND DOES NOT RAISE, unlike `_hamming_bytes`
    and unlike `_jaccard_bytes` below. MEASURED: `jaro_similarity('','')` = 0
    and `jaro_similarity('abc','')` = 0. "Two empty strings are identical, so
    1" is the plausible wrong reading and this is the row that refutes it.

    The matching window is `max(n, m) // 2 - 1`, floored at 0, and a
    TRANSPOSITION is a pair of matched bytes whose match ORDER differs; `t` is
    half that count, which is why the third term is `(m - t) / m`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab)
    var m = len(bb)
    if n == 0 or m == 0:
        return Float64(0.0)
    var window = (max(n, m) // 2) - 1
    if window < 0:
        window = 0
    var a_hit = List[Bool](capacity=n)
    for _ in range(n):
        a_hit.append(False)
    var b_hit = List[Bool](capacity=m)
    for _ in range(m):
        b_hit.append(False)
    var matches = 0
    for i in range(n):
        var lo = i - window
        if lo < 0:
            lo = 0
        var hi = i + window + 1
        if hi > m:
            hi = m
        for j in range(lo, hi):
            if b_hit[j]:
                continue
            if ab[i] != bb[j]:
                continue
            a_hit[i] = True
            b_hit[j] = True
            matches += 1
            break
    if matches == 0:
        return Float64(0.0)
    # HALF-TRANSPOSITIONS: walk the two matched subsequences in parallel and
    # count the positions where they disagree. `t` is that count // 2.
    var half = 0
    var k = 0
    for i in range(n):
        if not a_hit[i]:
            continue
        while not b_hit[k]:
            k += 1
        if ab[i] != bb[k]:
            half += 1
        k += 1
    var mm = Float64(matches)
    var t = Float64(half // 2)
    return (mm / Float64(n) + mm / Float64(m) + (mm - t) / mm) / Float64(3.0)


def _jaro_winkler_bytes(a: String, b: String) -> Float64:
    """`jaro_winkler_similarity(a, b)` — `_jaro_bytes` plus Winkler's prefix
    boost, over BYTES.

    ⛔⛔ TWO CONSTANTS HERE ARE MEASURED AND A KERNEL THAT GETS EITHER WRONG IS
    RIGHT ON EVERY TEXTBOOK EXAMPLE:

      * **THE PREFIX LENGTH IS CAPPED AT 4.** v1.5.3:
        `jaro_similarity('abcdefgh','abcdeXXX')` = 0.75 and
        `jaro_winkler_similarity` of that pair = 0.84999999999999998. The
        common prefix is FIVE bytes; 0.75 + 4*0.1*0.25 = 0.85, and an uncapped
        L answers 0.875.
      * **THE BOOST IS GATED ON `j > 0.7`.** v1.5.3:
        `jaro_similarity('abcde','abzzzzzzz')` = 0.54074074074074074 and
        `jaro_winkler_similarity` of the SAME pair = 0.54074074074074074 —
        no boost at all despite a two-byte common prefix. Ungated it answers
        0.6326.... The neighbouring pair `('abcde','abcxx')` DOES get the
        boost (0.73333333333333339 -> 0.81333333333333335, a delta of exactly
        3 * 0.1 * (1 - j)), so the two rows pin the gate from both sides.

    ⚠ The prefix is counted in BYTES, like the matching.
    """
    var j = _jaro_bytes(a, b)
    if j <= Float64(0.7):
        return j
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var lim = min(min(len(ab), len(bb)), 4)
    var pref = 0
    for i in range(lim):
        if ab[i] != bb[i]:
            break
        pref += 1
    return j + Float64(pref) * Float64(0.1) * (Float64(1.0) - j)


def _jaccard_bytes(a: String, b: String) raises -> Float64:
    """`jaccard(a, b)` — the Jaccard index of the two operands' BYTE SETS.

    ⛔⛔ A SET OF SINGLE BYTES, NOT A SET OF BIGRAMS, AND THAT IS THE ONE THING
    A "jaccard over strings" IMPLEMENTATION USUALLY GETS OTHERWISE. MEASURED
    v1.5.3: `jaccard('martha','marhta')` = **1** — the two share every
    character and differ only in ORDER — and `jaccard('abc','cba')` = **1** for
    the same reason. A bigram kernel answers 0.2 and 0 there. `jaccard('aab',
    'ab')` = 1 (a SET ignores multiplicity) and `jaccard('abcd','ab')` = 0.5 =
    |{a,b}| / |{a,b,c,d}|.

    ⛔ IT RAISES ON AN EMPTY OPERAND WHERE `_jaro_bytes` ANSWERS 0, and the
    message mirrors v1.5.3 verbatim: `jaccard('abc','')` ->
    `Invalid Input Error: Jaccard Function: An argument too short!`. Answering
    0 — or 1, on "two empty sets are equal" — accepts a call the parity target
    REJECTS, the divergence that looks like extra capability.

    ⚠ CASE-SENSITIVE: `jaccard('ABC','abc')` = 0. The set is over raw bytes and
    nothing is folded.

    ⚠ 256 FLAGS AND NOT A HASH SET, precisely BECAUSE the unit is the BYTE —
    the alphabet is 0..255 and is closed, the same reason
    `_damerau_levenshtein_bytes` carries a 256-entry last-occurrence table.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) == 0 or len(bb) == 0:
        raise Error(
            "PipelineCompiler: jaccard() — An argument too short!"
        )
    var in_a = List[Bool](capacity=256)
    var in_b = List[Bool](capacity=256)
    for _ in range(256):
        in_a.append(False)
        in_b.append(False)
    for i in range(len(ab)):
        in_a[Int(ab[i])] = True
    for i in range(len(bb)):
        in_b[Int(bb[i])] = True
    var inter = 0
    var union = 0
    for v in range(256):
        if in_a[v] and in_b[v]:
            inter += 1
        if in_a[v] or in_b[v]:
            union += 1
    # ⚠ `union` CANNOT BE ZERO HERE — both operands are non-empty, so each
    # contributes at least one byte. The refusal above is what establishes it.
    return Float64(inter) / Float64(union)


def _utf8_first_codepoint(b: Span[UInt8, _], empty: Int) -> Int:
    """`ascii(s)` / `unicode(s)` — the SCALAR VALUE of the first character.

    ⭐ TAKES A BORROWED `Span[UInt8]` for the same reason `_utf8_char_count`
    above does — see that docstring for the measurement.

    ⛔ IT DECODES, IT DOES NOT READ A BYTE. MEASURED on DuckDB v1.5.3:
    `ascii('é')` = 233 and `ascii('😀')` = 128512, i.e. the full Unicode scalar
    value however many UTF-8 bytes it occupies. Returning `b[0]` would answer
    195 and 240 — plausible small integers, and CORRECT FOR ALL OF ASCII, so
    an ASCII-only fixture cannot tell the two implementations apart.

    ⚠ `empty` IS A PARAMETER BECAUSE THE TWO CALLERS DISAGREE THERE AND
    NOWHERE ELSE. MEASURED: `ascii('')` = 0 and `unicode('')` = `ord('')` =
    -1. Every non-empty input gives both the same number, so folding them into
    one op would be right on every test that has no empty string in it.

    Malformed input is decoded permissively rather than raised on: a
    continuation byte in the lead position contributes its own low bits and a
    truncated sequence stops at the end of the buffer. This kernel's job is
    not UTF-8 validation, and a raise here would turn a data-quality problem in
    one row into a failed query.
    """
    var n = len(b)
    if n == 0:
        return empty
    var b0 = Int(b[0])
    if b0 < 0x80:
        return b0
    # Lead-byte length and initial payload bits.
    var extra = 0
    var cp = 0
    if (b0 & 0xE0) == 0xC0:
        extra = 1
        cp = b0 & 0x1F
    elif (b0 & 0xF0) == 0xE0:
        extra = 2
        cp = b0 & 0x0F
    elif (b0 & 0xF8) == 0xF0:
        extra = 3
        cp = b0 & 0x07
    else:
        # Not a valid lead byte (a stray continuation byte, or 0xF8..0xFF).
        return b0 & 0x3F
    for i in range(1, extra + 1):
        if i >= n:
            break
        cp = (cp << 6) | (Int(b[i]) & 0x3F)
    return cp


# ---------------------------------------------------------------------------
# the five BYTE-TRANSFORM string kernels.
# ---------------------------------------------------------------------------
#
# ⭐ ALL FIVE ARE EXACT AGAINST DuckDB v1.5.3 OVER EVERY INPUT, ASCII OR NOT,
# and that is WHY these five were chosen over the rest of the string bucket.
# They operate on the UTF-8 BYTES themselves, which is exactly what DuckDB's
# own implementations do — so there is no mapping to be missing. MEASURED:
#     hex('é')          = 'C3A9'          (the two UTF-8 bytes)
#     bin('é')          = '1100001110101001'
#     url_encode('é')   = '%C3%A9'
#     regexp_escape('é.b') = 'é\.b'       (bytes >= 0x80 are NOT escaped)
#
# ⚠ THE SELECTION ARGUMENT THAT PICKED THESE FIVE HAS SINCE BEEN SETTLED THE
# OTHER WAY, and the note is kept because it is how the string bucket is
# ordered. These were chosen ahead of `upper`/`lower` because those two
# "carry a stated Unicode divergence"; that divergence was a SILENT WRONG
# ANSWER (`upper('Ünïcodé')` = `'ÜNïCODé'`) and was closed by
# `unicode_case.mojo`, which decodes and applies DuckDB's own simple case
# mapping. `reverse` is still codepoint-defined and byte-exact here.
#
# ⚠ EVERY ONE RETURNS `List[UInt8]`, NEVER A `String`, for the reason written
# in `unicode_case.mojo`: `chr(Int(byte))` is a CODEPOINT constructor and
# doubles every byte >= 0x80. These pair with `StringArray.from_byte_lists`.


@always_inline
def _hex_digit_upper(v: Int) -> UInt8:
    """One UPPERCASE hex digit. MEASURED: DuckDB's `hex` emits `C3A9`, not
    `c3a9`, while `md5`/`sha256` emit LOWERCASE — two conventions in one
    engine, so this is not a shared helper by accident."""
    if v < 10:
        return UInt8(48 + v)      # '0'
    return UInt8(65 + (v - 10))   # 'A'


@always_inline
def _hex_digit_value(c: UInt8) -> Int:
    """The value of one hex digit, or -1. BOTH CASES ACCEPTED — measured:
    `url_decode('%c3%a9')` = 'é' in v1.5.3, so a decoder that took only
    uppercase would leave a lowercase escape as literal text."""
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 97 + 10
    if c >= 65 and c <= 70:
        return Int(c) - 65 + 10
    return -1


def _hex_string_bytes(s: String) -> List[UInt8]:
    """`hex(s)` / `to_hex(s)` — two UPPERCASE hex digits per UTF-8 byte.

    MEASURED v1.5.3: `hex('abc')` = '616263', `hex('')` = '', `hex('é')` =
    'C3A9', `hex('😀')` = 'F09F9880'. `to_hex` over a VARCHAR is the SAME
    function (both '616263' for 'abc'), which is why they share this op.

    ⛔ `to_hex` OVER AN INTEGER IS A DIFFERENT FUNCTION and this op is NOT it:
    `to_hex(255)` is 'FF' there, while `hex('255')` is '323535'. This engine
    binds only the VARCHAR overload; an integer argument reaches the arm's
    STRING-column check and is refused BY NAME."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=2 * n)
    for i in range(n):
        var v = Int(b[i])
        out.append(_hex_digit_upper((v >> 4) & 0xF))
        out.append(_hex_digit_upper(v & 0xF))
    return out^


def _bin_string_bytes(s: String) -> List[UInt8]:
    """`bin(s)` — EIGHT binary digits per UTF-8 byte, no separator and NO
    leading-zero strip.

    MEASURED v1.5.3: `bin('abc')` = '011000010110001001100011' (24 digits for
    3 bytes — the leading zero of 'a' = 0x61 is KEPT), `bin('')` = '',
    `bin('é')` = '1100001110101001'.

    ⛔ `bin` OVER AN INTEGER **DOES** STRIP LEADING ZEROS (`bin(5)` = '101')
    and is a different overload this engine does not bind. A kernel that
    stripped here would be right for the integer form and wrong for every
    string."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=8 * n)
    for i in range(n):
        var v = Int(b[i])
        for k in range(7, -1, -1):
            out.append(UInt8(48 + ((v >> k) & 1)))
    return out^


@always_inline
def _url_unreserved(c: UInt8) -> Bool:
    """RFC 3986 unreserved: A-Z a-z 0-9 `-` `.` `_` `~`.

    ⚠ THE SET IS MEASURED, NOT QUOTED FROM THE RFC. Enumerating every printable
    ASCII byte through v1.5.3's `url_encode` and keeping the ones that came back
    unchanged gives EXACTLY `-.0-9A-Z_a-z~`. In particular `+` is ENCODED
    (`url_encode('a+b')` = 'a%2Bb'), which the form-encoding convention would
    not do."""
    return (
        (c >= 65 and c <= 90)     # A-Z
        or (c >= 97 and c <= 122)  # a-z
        or (c >= 48 and c <= 57)   # 0-9
        or c == 45                 # -
        or c == 46                 # .
        or c == 95                 # _
        or c == 126                # ~
    )


def _url_encode_bytes(s: String) -> List[UInt8]:
    """`url_encode(s)` — percent-encode every byte outside the unreserved set,
    with UPPERCASE hex digits.

    MEASURED v1.5.3: `url_encode('a b/c?d=é')` = 'a%20b%2Fc%3Fd%3D%C3%A9' —
    a space is `%20` and NOT `+`, and a non-ASCII character is encoded as its
    UTF-8 BYTES one `%XX` each, which is why this is a byte kernel."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = b[i]
        if _url_unreserved(c):
            out.append(c)
        else:
            out.append(37)  # '%'
            out.append(_hex_digit_upper((Int(c) >> 4) & 0xF))
            out.append(_hex_digit_upper(Int(c) & 0xF))
    return out^


def _bytes_are_valid_utf8(b: List[UInt8]) -> Bool:
    """Strict UTF-8 validation: shortest form, no surrogates, max U+10FFFF.

    ⚠ LOCAL RATHER THAN IMPORTED ON PURPOSE. Four `_is_valid_utf8` helpers
    exist in this repo (`komira_git`, `komira_ivp`, `komira_aws_lambda_http`)
    and every one of them lives in a package `komira_compiler` does not and
    should not depend on. Twenty-five lines here is cheaper than an edge from
    the expression evaluator to an HTTP package."""
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        var need: Int
        var cp: Int
        if c >= 0xC2 and c <= 0xDF:
            need = 1
            cp = c & 0x1F
        elif c >= 0xE0 and c <= 0xEF:
            need = 2
            cp = c & 0x0F
        elif c >= 0xF0 and c <= 0xF4:
            need = 3
            cp = c & 0x07
        else:
            # 0x80-0xC1 (continuation or overlong two-byte lead) and 0xF5-0xFF.
            return False
        if i + need > n - 1:
            return False
        for k in range(1, need + 1):
            var cc = Int(b[i + k])
            if cc < 0x80 or cc > 0xBF:
                return False
            cp = (cp << 6) | (cc & 0x3F)
        if need == 2 and cp < 0x800:
            return False
        if need == 3 and cp < 0x10000:
            return False
        if cp > 0x10FFFF:
            return False
        if cp >= 0xD800 and cp <= 0xDFFF:
            return False
        i += need + 1
    return True


def _url_decode_bytes(s: String) raises -> List[UInt8]:
    """`url_decode(s)` — decode `%XX` escapes, leave everything else verbatim.

    ⛔ THREE MEASURED FACTS THAT ARE EACH THE OPPOSITE OF THE OBVIOUS GUESS,
    v1.5.3:
      * `+` IS NOT A SPACE. `url_decode('a+b')` = 'a+b'. This is URI decoding,
        not `application/x-www-form-urlencoded` decoding, and a decoder that
        mapped `+` would be wrong on every query string that carries one.
      * A MALFORMED ESCAPE IS LEFT ALONE, NOT AN ERROR. `url_decode('a%zz')` =
        'a%zz', `url_decode('a%2')` = 'a%2', `url_decode('100%')` = '100%'.
      * AN ESCAPE THAT DECODES TO INVALID UTF-8 **RAISES**:
        `url_decode('%FF')` is `Invalid Input Error: ... decoded value is
        invalid UTF8`. That is why this helper is `raises` and why
        `_bytes_are_valid_utf8` exists — emitting the bytes anyway would put an
        invalid-UTF-8 value into a STRING column, which every downstream reader
        (Arrow C-ABI export included) is entitled to reject."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        if b[i] == 37 and i + 2 < n:  # '%' with two bytes after it
            var hi = _hex_digit_value(b[i + 1])
            var lo = _hex_digit_value(b[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        out.append(b[i])
        i += 1
    if not _bytes_are_valid_utf8(out):
        raise Error(
            "url_decode: decoded value is invalid UTF8 (DuckDB v1.5.3 raises"
            " here too: `Invalid Input Error: Failed to decode string using"
            " URL decoding - decoded value is invalid UTF8`)"
        )
    return out^


def _reverse_codepoints_bytes(s: String) -> List[UInt8]:
    """`reverse(s)` — reverse CODEPOINT order, keeping each codepoint's own
    bytes in their original order.

    ⛔ NOT A BYTE REVERSE. Measured on DuckDB v1.5.3: `reverse('héllo')` is
    `olléh` — the two bytes of `é` stay in sequence. A byte-wise reverse would
    emit the continuation byte first and turn a valid input into INVALID
    UTF-8, which is worse than a wrong answer because the consumer cannot
    decode it at all.

    Walks the input finding codepoint STARTS (any byte outside 0x80..0xBF),
    then copies whole codepoints back-to-front. Exact against DuckDB.
    """
    var b = s.as_bytes()
    var n = len(b)
    # Codepoint start offsets, in order.
    var starts = List[Int]()
    for i in range(n):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    var out = List[UInt8](capacity=n)
    for k in range(len(starts) - 1, -1, -1):
        var begin = starts[k]
        var end = starts[k + 1] if k + 1 < len(starts) else n
        for j in range(begin, end):
            out.append(b[j])
    return out^


def _sql_substring_bytes(s: String, start: Int, length: Int) -> List[UInt8]:
    """SQL `substring(s, start, length)` — 1-based `start`, `length`
    CHARACTERS, returning the selected bytes VERBATIM.

    ⛔ THIS REPLACED A KERNEL WITH THREE SEPARATE WRONG ANSWERS, ALL OF THEM
    SILENT, ALL MEASURED AGAINST DuckDB v1.5.3. Do not "simplify" any of the
    three back:

    1. **A NEGATIVE `start` COUNTS FROM THE END OF THE STRING**, it is not
       "counted against `length`". The old kernel's own docstring claimed the
       PostgreSQL rule and claimed it MATCHED DuckDB; it does not.
       `substring('hello', -1)` is `o` in DuckDB and was `hello` here;
       `substring('hello', -1, 4)` is `o` there and was `he` here. The rule is
       `begin0 = nchars + start` for `start < 0` and `begin0 = start - 1`
       otherwise — which keeps `start == 0` on the "counted against length"
       branch, where DuckDB does put it (`substring('hello',0,2)` = `h`,
       `substring('hello',0)` = `hello`). Two rules in one function, and the
       boundary between them is at 0, not at 1.

    2. **INDICES ARE CHARACTERS, NOT BYTES.** `substring('héllo', 2, 2)` is
       `él` in DuckDB; byte indexing answers `é` alone (the two bytes of one
       codepoint). Every fixture in the TPC-H corpus is single-byte, which is
       why this survived — and `Straße` is in the plan-matrix text zoo, which
       is where it stops surviving.

    3. **`chr(Int(byte))` IS A CODEPOINT CONSTRUCTOR AND THE OLD LOOP USED
       IT.** `out += chr(Int(b[j]))` re-encodes every byte >= 0x80 as its own
       two-byte UTF-8 sequence, so slicing non-ASCII text did not merely
       mis-index it, it CORRUPTED and lengthened it. Returning `List[UInt8]`
       and pairing with `StringArray.from_byte_lists` is the byte-faithful
       companion — the same pairing the `EXPR_STRING_FN` arm already uses and
       documents.

    ⚠ `length < 0` IS AN INTERNAL SENTINEL **FAMILY** AND IS **NOT** DuckDB'S
    NEGATIVE-LENGTH SEMANTICS. `-1` means "to end of string"; `-k` for k >= 2
    means "to end, dropping k-1 trailing CHARACTERS", which is what
    `left(s, NEGATIVE)` desugars to (see the `end0` branch below for the
    arithmetic and the reason). DuckDB reads a negative length as a window
    extending BACKWARD from `start` (`substring('hello',3,-1)` = `e`), which is
    a DIFFERENT function of the same field. The SQL binder REFUSES a negative
    length literal by name, so no user spelling reaches this branch; a binder
    that ever stops refusing must supply the backward-window rule first, under
    a spelling that is not this one.
    """
    var b = s.as_bytes()
    var nbytes = len(b)

    # Codepoint START offsets, plus a sentinel at `nbytes` so the exclusive
    # end of the LAST character is addressable without a special case. A
    # continuation byte is `0b10xxxxxx` (0x80..0xBF); anything else starts a
    # character. Same test as `_utf8_char_count`, so the two cannot disagree
    # about how many characters a string has.
    var starts = List[Int](capacity=nbytes + 1)
    for i in range(nbytes):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    var nchars = len(starts)
    starts.append(nbytes)

    var begin0: Int
    if start >= 0:
        begin0 = start - 1
    else:
        begin0 = nchars + start
    var end0: Int
    if length < 0:
        # ⛔ THE NEGATIVE-`length` SENTINEL IS A **FAMILY**, NOT A SINGLE
        # VALUE, AND THE ARITHMETIC IS EXACT AT EVERY MEMBER.
        #
        #     length == -1  ->  end0 = nchars          "to end of string"
        #     length == -2  ->  end0 = nchars - 1      "to end, drop 1 char"
        #     length == -k  ->  end0 = nchars - (k-1)
        #
        # `nchars + length + 1` is one expression covering all of them, and at
        # `length == -1` it is `nchars` — BYTE-IDENTICAL to what this line did
        # before, so no existing two-argument `substring(s, start)` moves.
        #
        # ⭐ WHY THE FAMILY EXISTS: `left(s, -n)`. DuckDB
        # v1.5.3's `left('abc', -1)` is `'ab'` — "all but the LAST |n|
        # characters" — which is `substring(s, 1, nchars - n)`, a RUNTIME
        # length the plan-time `length` field cannot carry as a positive
        # number. It can carry the SHORTFALL, and `nchars` is right here. That
        # is the missing primitive the old binder refusal named, supplied at
        # the one place that knows `nchars`. `right(s, -n)` never needed it —
        # "all but the first |n|" is `substring(s, 1 - n)`, a constant START —
        # which is exactly why the pair was asymmetric.
        #
        # ⛔⛔ THIS IS STILL **NOT** DuckDB'S NEGATIVE-LENGTH SEMANTICS, AND THE
        # SQL BINDER MUST KEEP REFUSING A NEGATIVE `length` LITERAL. DuckDB
        # reads `substring('hello',3,-1)` as a window extending BACKWARD from
        # `start` and answers `'e'`; this encoding would answer `'he'`. The
        # only producers of `length < -1` are the `left(s, NEGATIVE)` desugar
        # in `sql_binder._bind_left_right` and a plan decoded off the wire that
        # one built. A binder that ever stops refusing the literal must supply
        # the backward-window rule FIRST — and must then give it a spelling
        # that is not this one.
        end0 = nchars + length + 1
    else:
        end0 = begin0 + length
    var from_c = begin0 if begin0 > 0 else 0
    if end0 > nchars:
        end0 = nchars
    if from_c > nchars:
        from_c = nchars
    var out = List[UInt8]()
    if end0 <= from_c:
        return out^
    var b0 = starts[from_c]
    var b1 = starts[end0]
    for j in range(b0, b1):
        out.append(b[j])
    return out^


# =============================================================================
# the MULTI-ARGUMENT string kernels
# =============================================================================
#
# ⛔ EVERY KERNEL HERE RETURNS `List[UInt8]`, NOT `String`, AND THE CALLER
# PAIRS IT WITH `StringArray.from_byte_lists`. `chr(Int(byte))` is a CODEPOINT
# constructor: a byte >= 0x80 comes back as its two-byte UTF-8 ENCODING, so
# every non-ASCII value is silently corrupted AND doubled in length.
# `StringArray.from_strings` routes through `String` and inherits it. That trap
# has bitten TWICE in this file — `upper` and `substring`, the second one
# with the `upper` kernel's warning about it ONE
# SCREEN UP. It does not get a third. (That warning now lives in
# `unicode_case.mojo`, where the `upper`/`lower` kernels moved .)
#
# ⚠ AND THE ORACLE HALF OF THE SAME TRAP: do NOT validate any of these against
# a Python `str` method. Python, this engine and DuckDB give three different
# answers on `Straße`, and the Python one stays green over an ASCII fixture
# while being wrong. The corpus cells use the non-ASCII fixture variant.


def _find_bytes(hay: Span[UInt8, _], needle: Span[UInt8, _], from_byte: Int) -> Int:
    """Byte offset of the first occurrence of `needle` in `hay` at or after
    `from_byte`, or `-1`.

    ⭐ BYTE-WISE SEARCH IS EXACT OVER UTF-8, and that is a property of the
    encoding rather than an approximation: every byte of a multi-byte sequence
    is >= 0x80 and every continuation byte is 0x80..0xBF, so a WELL-FORMED
    needle cannot match starting inside a codepoint. No decode is needed, and
    a decode would be slower and no more correct.

    An EMPTY needle answers `from_byte` — "found, at the current position" —
    which is what makes `strpos(s,'')` = 1. Callers that would loop on that
    (`replace`) must special-case an empty needle BEFORE calling.
    """
    var hn = len(hay)
    var nn = len(needle)
    if nn == 0:
        return from_byte if from_byte <= hn else hn
    if nn > hn:
        return -1
    var last = hn - nn
    for i in range(from_byte, last + 1):
        var ok = True
        for j in range(nn):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return i
    return -1


def _replace_bytes(s: String, source: String, target: String) -> List[UInt8]:
    """`replace(s, source, target)` — DuckDB v1.5.3 semantics, measured.

    ⚠ NON-OVERLAPPING, LEFT TO RIGHT: the scan resumes AFTER the bytes a match
    consumed. `replace('aaa','aa','b')` = `'ba'`, which is neither `'b'` nor
    `'bb'` — the two answers a greedy or a restart-at-i+1 loop produce.

    ⚠ AN EMPTY `source` MATCHES NOTHING and the input comes back unchanged
    (`replace('abc','','X')` = `'abc'`). Without this guard `_find_bytes`
    answers "found here" at every position and the loop either never advances
    or emits `'XaXbXcX'`.

    Byte-wise, which is EXACT rather than approximate — see `_find_bytes`.
    Measured: `replace('Straße','ß','ss')` = `'Strasse'`.
    """
    var b = s.as_bytes()
    var src = source.as_bytes()
    var tgt = target.as_bytes()
    var out = List[UInt8]()
    if len(src) == 0:
        for i in range(len(b)):
            out.append(b[i])
        return out^
    var i = 0
    var n = len(b)
    while i < n:
        var hit = _find_bytes(b, src, i)
        if hit < 0:
            break
        for j in range(i, hit):
            out.append(b[j])
        for j in range(len(tgt)):
            out.append(tgt[j])
        i = hit + len(src)
    for j in range(i, n):
        out.append(b[j])
    return out^


def _utf8_char_starts(b: Span[UInt8, _]) -> List[Int]:
    """Byte offsets of every codepoint START in `b`, plus a `len(b)` sentinel.

    The sentinel makes the exclusive end of the LAST character addressable
    with no special case, exactly as `_sql_substring_bytes` does it — and it
    uses the SAME continuation-byte test (`(byte & 0xC0) != 0x80`) as
    `_utf8_char_count`, so the two can never disagree about how many
    characters a string has.
    """
    var n = len(b)
    var starts = List[Int](capacity=n + 1)
    for i in range(n):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    starts.append(n)
    return starts^


def _pad_bytes(
    s: String, count: Int, pad: String, on_left: Bool
) raises -> List[UInt8]:
    """`lpad` / `rpad` — DuckDB v1.5.3 semantics, all four corners measured.

    ⛔ CHARACTERS, NOT BYTES, ON BOTH SIDES. `lpad('é',4,'ß')` = `'ßßßé'`: four
    CHARACTERS out of a 2-byte input and a 2-byte pad. A byte-wise version
    returns a different string and can split a codepoint, turning valid input
    into invalid UTF-8.

    ⚠ IT TRUNCATES. `count` below the input's length is not a no-op — it takes
    the FIRST `count` characters, for BOTH `lpad` and `rpad`
    (`rpad('abc',2,'x')` = `'ab'`, NOT `'bc'`). `count <= 0` gives `''`.

    ⛔⛔ AND THE CONDITIONAL RAISE, WHICH IS THE PART THAT IS WRONG IN BOTH
    DIRECTIONS IF GUESSED. An empty `pad` RAISES — DuckDB says `Invalid Input
    Error: Insufficient padding in LPAD.` — but ONLY when padding is actually
    needed. Measured:
        lpad('abc',4,'')  RAISES     lpad('abc',3,'')  = 'abc'
        lpad('abc',2,'')  = 'ab'     lpad('',0,'')     = ''
    So the guard is `count > nchars and pad is empty`, never `pad is empty`
    alone (which would refuse three working calls) and never nothing at all
    (which would return the input unpadded, silently disagreeing).

    The pad CYCLES from its own first character: `lpad('abc',6,'xy')` =
    `'xyxabc'` — x, y, x.
    """
    var b = s.as_bytes()
    var starts = _utf8_char_starts(b)
    var nchars = len(starts) - 1

    if count <= 0:
        return List[UInt8]()

    if count <= nchars:
        # TRUNCATION — the first `count` characters, both directions.
        var cut = List[UInt8](capacity=starts[count])
        for j in range(starts[count]):
            cut.append(b[j])
        return cut^

    var pb = pad.as_bytes()
    if len(pb) == 0:
        raise Error(
            "Invalid Input Error: Insufficient padding in "
            + (String("LPAD") if on_left else String("RPAD"))
            + "."
        )
    var pstarts = _utf8_char_starts(pb)
    var pchars = len(pstarts) - 1

    var need = count - nchars
    var fill = List[UInt8]()
    for k in range(need):
        var c = k % pchars
        for j in range(pstarts[c], pstarts[c + 1]):
            fill.append(pb[j])

    var out = List[UInt8](capacity=len(fill) + len(b))
    if on_left:
        for j in range(len(fill)):
            out.append(fill[j])
        for j in range(len(b)):
            out.append(b[j])
    else:
        for j in range(len(b)):
            out.append(b[j])
        for j in range(len(fill)):
            out.append(fill[j])
    return out^


def _repeat_bytes(s: String, count: Int, max_bytes: Int) raises -> List[UInt8]:
    """`repeat(s, count)` — `count <= 0` gives `''` (measured at 0 and -1).

    ⚠ THE ONE MEMBER WHOSE OUTPUT SIZE IS SET BY A DATA VALUE. DuckDB types
    `count` as BIGINT, so `repeat('ab', 2147483647)` is a legal call asking for
    4 GB, and this runs inside a morsel worker where an OOM takes the PROCESS
    and a raise takes one query. The ceiling is checked BEFORE any allocation
    and is a REFUSAL, not a clamp — a clamp returns a string that differs from
    DuckDB with nothing saying so.
    """
    if count <= 0:
        return List[UInt8]()
    var b = s.as_bytes()
    var unit = len(b)
    if unit == 0:
        return List[UInt8]()
    if count > max_bytes // unit:
        raise Error(
            "PipelineCompiler: repeat() would produce "
            + String(count * unit)
            + " bytes for one row, over the "
            + String(max_bytes)
            + "-byte per-row ceiling (STRING_FN_N_REPEAT_MAX_BYTES)"
        )
    var out = List[UInt8](capacity=unit * count)
    for _ in range(count):
        for j in range(unit):
            out.append(b[j])
    return out^


def _codepoint_starts(b: Span[UInt8, _]) -> List[Int]:
    """Byte offsets at which each CODEPOINT of `b` begins, in order.

    A UTF-8 continuation byte is `10xxxxxx`, so a codepoint STARTS at any byte
    whose top two bits are not `10` — the same test `_reverse_codepoints_bytes`
    uses. Shared by the character-based members of the string families."""
    var starts = List[Int]()
    for i in range(len(b)):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    return starts^


def _translate_chars(
    subject: String, from_set: String, to_set: String
) -> List[UInt8]:
    """`translate(s, from, to)` — per-CHARACTER substitution.

    ⛔⛔ CHARACTERS, NOT BYTES, AND THIS IS THE ONLY MEMBER OF ITS TAG THAT IS.
    `_levenshtein_bytes`, `_damerau_levenshtein_bytes` and `_hamming_bytes` are
    byte-based on the same `EXPR_STRING_FN_N`. MEASURED on DuckDB v1.5.3:
    `translate('héllo','é','e')` = 'hello'. A byte-wise kernel would match the
    lead byte C3 of `é` against nothing useful and could strand the trailing
    A9 — emitting INVALID UTF-8 into a STRING column, which the Arrow C-ABI
    export is entitled to reject. That is worse than a wrong answer.

    The four measured rules, each the opposite of a plausible guess:
      * a SHORTER `to` DELETES: `translate('abcd','abc','xy')` = 'xyd'
      * a LONGER `to` ignores the extra: `translate('abc','a','xyz')` = 'xbc'
      * a DUPLICATE in `from` takes the FIRST: `translate('abc','aa','xy')` =
        'xbc'
      * the pairing is per CODEPOINT on BOTH sides:
        `translate('Straße','ß','ss')` = 'Strase' — the two-character `to`
        contributes only its first character to the one-character `from`

    An empty `from` is the identity; an empty `to` deletes every matched
    character. Both measured."""
    var sb = subject.as_bytes()
    var fb = from_set.as_bytes()
    var tb = to_set.as_bytes()
    var f_starts = _codepoint_starts(fb)
    var t_starts = _codepoint_starts(tb)
    var s_starts = _codepoint_starts(sb)

    var out = List[UInt8](capacity=len(sb))
    for si in range(len(s_starts)):
        var s_begin = s_starts[si]
        var s_end = len(sb) if si + 1 == len(s_starts) else s_starts[si + 1]
        var s_len = s_end - s_begin

        # ⚠ FIRST match wins — that is the duplicate rule, not an optimization.
        var hit = -1
        for fi in range(len(f_starts)):
            var f_begin = f_starts[fi]
            var f_end = (
                len(fb) if fi + 1 == len(f_starts) else f_starts[fi + 1]
            )
            if f_end - f_begin != s_len:
                continue
            var same = True
            for k in range(s_len):
                if sb[s_begin + k] != fb[f_begin + k]:
                    same = False
                    break
            if same:
                hit = fi
                break

        if hit < 0:
            # Not in `from` — copy the whole codepoint through verbatim.
            for k in range(s_len):
                out.append(sb[s_begin + k])
            continue
        if hit >= len(t_starts):
            # ⛔ NO PARTNER IN `to` -> DELETE. Padding with a space or with the
            # last character of `to` are both plausible and both wrong.
            continue
        var t_begin = t_starts[hit]
        var t_end = (
            len(tb) if hit + 1 == len(t_starts) else t_starts[hit + 1]
        )
        for k in range(t_begin, t_end):
            out.append(tb[k])
    return out^


def _strpos_chars(hay: String, needle: String) -> Int:
    """`strpos(hay, needle)` — 1-BASED CHARACTER position, `0` if absent.

    ⛔ NOT AN INDEX AND NOT A BYTE OFFSET. Measured on DuckDB v1.5.3:
    `strpos('Straße','e')` = **6**, where the byte offset is 7 — so the search
    may be byte-wise (it is, and exactly so: see `_find_bytes`) but the RESULT
    must be converted to a character count.

    `strpos('abc','z')` = 0, `strpos('','a')` = 0, and an EMPTY needle is found
    at 1 even in an empty haystack (`strpos('','')` = 1) — which falls out of
    `_find_bytes` answering `from_byte` for an empty needle rather than being a
    special case here.
    """
    var b = hay.as_bytes()
    var nd = needle.as_bytes()
    var hit = _find_bytes(b, nd, 0)
    if hit < 0:
        return 0
    var chars = 0
    for i in range(hit):
        if (b[i] & 0xC0) != 0x80:
            chars += 1
    return chars + 1


def string_array_of(col: Column[HeapRegion]) raises -> StringArray[HeapRegion]:
    """`col.as_string`'s VALUES, without its copy when the column allows it.

    `Column.as_string` memcpy's the offsets, data and validity buffers into
    a fresh `StringArray`; `Column.share_as_string` Arc-shares them instead
    and reads byte-identically wherever `can_share_as_string` holds (plain
    STRING, offsets present, `_offset == 0` — the case `as_string` itself
    reads correctly, since it ignores `_offset`). Anywhere else this IS
    `as_string`.

    WHY: on ClickBench `cbq27` every string predicate and string function
    copied the whole `url` column just to hand a read-only kernel something to
    walk — two of the five full `url` copies that dominated the query's CPU.

    ## THE ALIASING ARGUMENT (stated, because it is NOT `from_string_shared`'s)

    `from_string_shared` is sound because it CONSUMES its input: no second
    handle survives the call. This function borrows `col`, so the batch column
    and the returned array are two live handles on the same bytes. That is
    sound only if NO holder of the returned array can write through it, and
    `StringArray` having no `mut self` method is NOT enough on its own: its
    public `offsets` / `data` / `validity` fields are `SharedAlignedBuffer` /
    `Bitmap`, which DO have writers (`write_*_at`, `set_typed`, `zero`,
    `view_mut`, `Bitmap.set` / `clear`). The argument is therefore
    per-consumer, and every consumer is enumerated:

      * WHO HOLDS IT MUTABLY: only the caller's own `var`. Every caller in
        `compiler_eval_column` / `compiler_eval_predicate` does exactly one
        thing to it besides passing it on — `try_share_string_col_ref`
        REPLACES its own `validity` handle with `None` (drops a share; writes
        no byte).
      * WHO READS IT: the kernels it is passed to all take it by `read`
        (`eval_string_{eq,ne,gt,lt,ge,le,contains,starts_with,ends_with,like}`,
        `eval_regexp_*`, `cast_string_to_{int64,int32,float64,float32}`), or
        the caller reads it through `is_null` / `get` / `get_span` /
        `get_length`. Every buffer writer needs a MUTABLE borrow of the buffer
        (`mut self`, or `ref [origin] self` with `mut=True`), which a `read`
        borrow cannot supply, and `as_view` is origin-parametric, so a view
        taken through `read` is immutable. `StringArray` is not `Copyable`,
        and no consumer re-`share`s a field, so no consumer can mint a
        mutable handle either.
      * WHAT ESCAPES: nothing that aliases. Every kernel builds its output
        fresh (`from_strings` / builders / `Bitmap.create*`), and
        `_apply_validity` COPIES the input bitmap into a new one.
      * LIFETIME: Arc-managed, not scoped. The returned array holds its own
        refcount on every buffer (and the `_mmap_keepalive` cookie), so it is
        valid however long a caller keeps it; the batch column may drop first.
      * LENGTHS: the shared `data` buffer may be LONGER than `offsets[length]`
        where `as_string`'s copy is exactly that long. No consumer reads a
        buffer's own length: they bound by `data_length` (set identically by
        both paths) or by per-row offsets.

    A new call site must re-run this enumeration for ITS consumers. Anywhere
    that cannot be shown read-only keeps calling `as_string`.
    """
    if col.can_share_as_string():
        return col.share_as_string()
    return col.as_string()


def try_share_string_col_ref(
    child: Expr, batch: RecordBatch
) raises -> Optional[StringArray[HeapRegion]]:
    """A zero-copy `StringArray` over the batch column a string-valued CHILD
    names, or `None`, in which case the caller keeps its copying path.

    It stands in for `_eval_column_expr(child).as_string`, which for a column
    reference is `copy_column(...)` then `as_string`: TWO full copies of the
    column (cbq27's C-colref and C-strfn, 7.4% + 6.2% of its CPU).

    It answers only where that pair is provably equal to one Arc share:

      * `child` is a bare column reference (`expr_resolves_to_column`);
      * the column is plain STRING and `can_share_as_string` holds;
      * `project_column_share_eligible` holds (`_offset == 0`,
        `_length == batch.num_rows`, `offsets[0] == 0`), the gate under
        which `copy_column` is a straight copy, not a rebase or a truncation.

    ⚠ ONE NORMALISATION IS MIRRORED, NOT SKIPPED. `copy_column` DROPS an
    all-valid bitmap (`_null_count == 0`, its Path 2), and the string kernels
    branch on the PRESENCE of a bitmap (`EXPR_STRING_FN`'s INT arm allocates a
    nullable output when one is there). The share keeps the source's bitmap,
    so it is dropped here on the same `null_count == 0` test `copy_column`
    trusts. Without this the values would agree and the output's validity
    LAYOUT would not.

    A DICTIONARY child is not served here: `_materialize_dict_to_string`
    builds a fresh array either way, so there is no copy to remove.

    ALIASING: the result is a borrowed-column share and carries
    `string_array_of`'s obligation (see its enumerated argument). The callers
    — `_sfnn_string_arg`'s consumers and the SUBSTRING / STRING_FN arms — read
    it through `is_null` / `get` / `get_span` / `get_length` only.
    """
    if not expr_resolves_to_column(child):
        return None
    var ci = resolve_col_index(child, batch.schema)
    ref col = batch.column_at(ci)
    if col.arrow_type != ArrowType.STRING or not col.can_share_as_string():
        return None
    if not project_column_share_eligible(batch, ci):
        return None
    var sa = col.share_as_string()
    if sa.null_count == 0:
        sa.validity = None
    return sa^


def _sfnn_string_arg(
    expr: Expr, i: Int, batch: RecordBatch
) raises -> StringArray[HeapRegion]:
    """Evaluate argument `i` of an `EXPR_STRING_FN_N` node to a `StringArray`.

    The DICTIONARY -> STRING materialization is here rather than repeated at
    each of the four call sites, and it is the same
    `_materialize_dict_to_string` fallback the `EXPR_STRING_FN` arm uses — a
    dictionary-encoded column reaching a string kernel is the ordinary case
    for a low-cardinality parquet column, not an exception.

    ⚠ FORWARD-DECLARED AGAINST `_eval_column_expr`, WHICH IS DEFINED BELOW AND
    CALLS BACK INTO THIS. That mutual recursion is how a nested argument
    (`concat(upper(a), b)`) works at all; it is the same shape the CASE and
    predicate evaluators already have with this module.
    """
    var shared = try_share_string_col_ref(expr.string_fn_n_arg_ref(i), batch)
    if shared:
        return shared.take()
    var col = _eval_column_expr(expr.string_fn_n_arg_ref(i), batch)
    var at = col.arrow_type
    if at == ArrowType.DICTIONARY:
        return _materialize_dict_to_string(col)
    if at != ArrowType.STRING:
        raise Error(
            "PipelineCompiler: "
            + string_fn_n_name(expr.string_fn_n_op())
            + "() argument " + String(i + 1)
            + " must be a STRING or DICTIONARY column, got " + String(at)
        )
    return string_array_of(col)


def _sfnn_count_arg(
    expr: Expr, i: Int, op: UInt8, batch: RecordBatch
) raises -> PrimitiveArray[DType.int64]:
    """Evaluate argument `i` of an `EXPR_STRING_FN_N` node to an INT64 count.

    ⚠ INT32 IS WIDENED THROUGH `eval_cast`, WHICH IS VALIDITY-PRESERVING. A
    hand-written widen loop drops the null mask and the count then reads as
    whatever the dead bytes held — `clone_array_validity`'s docstring names
    that exact failure, and this file already carries four arms that had it.

    Anything that is not INT32/INT64 is REFUSED BY NAME. DuckDB would coerce a
    DECIMAL here; this engine does not, and a refusal is never a wrong value.
    """
    var col = _eval_column_expr(expr.string_fn_n_arg_ref(i), batch)
    var at = col.arrow_type
    if at == ArrowType.INT64:
        return col.as_primitive[DType.int64]()
    if at == ArrowType.INT32:
        return eval_cast[DType.int32, DType.int64](
            col.as_primitive[DType.int32]()
        )
    raise Error(
        "PipelineCompiler: "
        + string_fn_n_name(op)
        + "() argument " + String(i + 1)
        + " must be an INT32/INT64 count, got " + String(at)
    )


def _eval_column_expr(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """Evaluate an Expr to produce a Column[HeapRegion] for projection.

    Handles ColRef (copy column), Literal (broadcast), BinaryOp (arithmetic),
    UnaryOp, Alias (evaluate child, rename), and Cast.

    ⚠ THIS IS THE THIRD LADDER OVER THE `EXPR_*` TAG UNIVERSE, and it is in
    the same defect class as the two that `komira_core/plan/expr_walk.mojo`
    replaced. `MapOp.execute` pairs THIS function (the column's DATA) with
    `walk_expr_field` (the column's TYPE); a tag armed in one and not the
    other is either an unexportable `null` column or a raise, and it has
    happened here twice already — EXPR_IN_LIST ("had a
    predicate-context arm but was missing from the projection-context
    dispatch") and EXPR_UNARY_OP. A new tag must arm both walkers.

    ⛔ THIS LADDER RAISES WHERE IT HAS NO ARM, WHICH IS WHY IT IS THE LEAST
    DANGEROUS OF THE THREE — but a tag it lacks that `walk_expr_field` HAS is
    still a plan the optimizer will happily build and the executor will
    refuse. `EXPR_STRING_OP` WAS exactly that (typed BOOL, unevaluable here);
    both directions of the cross-ladder comparison are pinned now, so the
    next one cannot arrive unmeasured.

    # DERIVED FACTS — re-derive with the gate, never hand-count.
    # arms: 22
    # unwalked: EXPR_BETWEEN EXPR_COL_IDX EXPR_CORRELATED_SUBQUERY EXPR_SORT_KEY EXPR_WINDOW_FN

    `EXPR_COL_IDX` is handled inside the EXPR_COL_REF arm via
    `resolve_col_index`; `EXPR_SORT_KEY` / `EXPR_BETWEEN` carry no payload;
    `EXPR_WINDOW_FN` / `EXPR_CORRELATED_SUBQUERY` are lowered away by the
    optimizer before a projection sees them.

    Args:
        expr: The expression to evaluate.
        batch: The input RecordBatch.

    Returns:
        A Column containing the evaluated result.
    """
    if expr.tag == EXPR_COL_REF:
        var col_idx = resolve_col_index(expr, batch.schema)
        return copy_column(batch, col_idx)

    elif expr.tag == EXPR_STRUCT_FIELD:
        # STRUCT field — by-name variant.
        # Evaluate the parent (must yield a STRUCT Column), then extract
        # the named child by linear-scanning `_field_names`. Returns a
        # deep-copy of the child Column so the result is independent of
        # the parent's storage lifetime. Column is Movable-not-Copyable,
        # so deep_copy is the only safe shape here (no share/ArcPointer
        # path exists). The cost is one buffer copy per projection per
        # batch; for typical morsel sizes (~64K rows) this is negligible.
        # The typed-DF surface emits EXPR_STRUCT_FIELD_IDX (below) to skip
        # this scan when the schema is known at comptime.
        var parent_col = _eval_column_expr(expr.struct_field_parent_ref(), batch)
        if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRUCT.type_id):
            raise Error(
                "PipelineCompiler: EXPR_STRUCT_FIELD parent must be STRUCT, got type_id="
                + String(Int(parent_col.arrow_type.type_id))
            )
        var field_name = expr.struct_field_name()
        var n_children = parent_col.num_children()
        for i in range(n_children):
            if parent_col.field_name(i) == field_name:
                return parent_col.child_at(i).deep_copy()
        raise Error(
            "PipelineCompiler: STRUCT has no field named '" + field_name + "'"
        )

    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        # STRUCT field — by-idx variant.
        # The typed DF chain method `df.field[parent, name]` has already
        # resolved `field_idx` at COMPTIME via the typed schema, so the
        # eval arm just type-checks the parent + range-checks the idx and
        # indexes `_children` directly — no `_field_names` scan. Mirrors
        # the EXPR_COL_REF -> EXPR_COL_IDX bound-twin pattern.
        var parent_col = _eval_column_expr(expr.struct_field_idx_parent_ref(), batch)
        if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRUCT.type_id):
            raise Error(
                "PipelineCompiler: EXPR_STRUCT_FIELD_IDX parent must be STRUCT, got type_id="
                + String(Int(parent_col.arrow_type.type_id))
            )
        var field_idx = expr.struct_field_index()
        var n_children = parent_col.num_children()
        if field_idx < 0 or field_idx >= n_children:
            raise Error(
                "PipelineCompiler: EXPR_STRUCT_FIELD_IDX field_idx="
                + String(field_idx) + " out of range (STRUCT has "
                + String(n_children) + " children)"
            )
        return parent_col.child_at(field_idx).deep_copy()

    elif expr.tag == EXPR_MAP_GET:
        # MAP[key] lookup.
        #
        # Arrow MAP layout: `list<entries: struct<key, value>>`. The parent
        # column has:
        #   - `_offsets`: N+1 Int32 offsets (offsets[i]..offsets[i+1] is the
        #     range of entries for row i).
        #   - `_children[0]`: the entries STRUCT column with two children
        #     (`_children[0]._children[0]` = key column, `_children[0]._children[1]`
        #     = value column).
        #   - `_keys_sorted`: trust the producer (no runtime validation in
        #     this arm — binary search is a later opt-in if a profile demands).
        #
        # Eval: per row r of the parent, scan its entries [start..end) for
        # the entry whose key equals the row's key value (from the key
        # expression, broadcast or per-row); emit the matching value, or
        # NULL on miss / parent-null.
        #
        # X1b SCOPE: supports STRING keys with STRING or INT64 values
        # (the canonical JSON-shape Map usage).  Other types raise a clear
        # "not yet supported" error — follow-on work covers numeric keys
        # + value types beyond STRING/INT64.  Output column null-marks
        # rows where the key isn't present or the parent row is null.
        var parent_col = _eval_column_expr(expr.map_get_parent_ref(), batch)
        if Int(parent_col.arrow_type.type_id) != Int(ArrowType.MAP.type_id):
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET parent must be MAP, got type_id="
                + String(Int(parent_col.arrow_type.type_id))
            )
        if parent_col.num_children() != 1:
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET MAP column must have exactly"
                " 1 child (entries struct), got "
                + String(parent_col.num_children())
            )
        var key_col = _eval_column_expr(expr.map_get_key_ref(), batch)
        # The entries STRUCT child of MAP carries keys + values as its 2
        # sub-children (Arrow spec).  Audit confirms `MapArray.to_column`
        # always lays this out (`map_array.mojo:336-345`).
        ref entries_col = parent_col.child_at(0)
        if entries_col.num_children() != 2:
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET MAP entries struct must have"
                " 2 children (key, value), got "
                + String(entries_col.num_children())
            )
        ref entry_keys = entries_col.child_at(0)
        ref entry_values = entries_col.child_at(1)
        # Currently support: STRING keys.  Other keys raise.
        if Int(entry_keys.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET only supports STRING keys in"
                " v0.4 X1b (got key type_id="
                + String(Int(entry_keys.arrow_type.type_id))
                + "); follow-on work covers numeric keys"
            )
        if Int(key_col.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET key expression must produce a"
                " STRING column (got type_id="
                + String(Int(key_col.arrow_type.type_id)) + ")"
            )
        # Now scan per-row: linear scan (no binary search on
        # `_keys_sorted=True` yet).
        var n_rows = parent_col.length()
        var keys_sa = entry_keys.as_string()
        var probe_sa = key_col.as_string()
        # Output type comes from the value child.  Two paths: STRING values
        # and INT64 values, the two canonical Map value types.
        var value_type_id = Int(entry_values.arrow_type.type_id)
        if value_type_id == Int(ArrowType.STRING.type_id):
            # String-value output: build a List[String] + validity bitmap.
            var vals_sa = entry_values.as_string()
            var out_strs = List[String](capacity=n_rows)
            var validity = Bitmap.create_all_valid(n_rows)
            var null_count = 0
            for i in range(n_rows):
                if parent_col._validity:
                    if not parent_col._validity.value().test(i):
                        out_strs.append(String(""))
                        validity.clear(i)
                        null_count += 1
                        continue
                var start = Int(parent_col._offsets.value().get_typed[Int32](i))
                var end = Int(parent_col._offsets.value().get_typed[Int32](i + 1))
                var probe = probe_sa.get(i)
                var found = False
                for e in range(start, end):
                    if keys_sa.get(e) == probe:
                        out_strs.append(vals_sa.get(e))
                        found = True
                        break
                if not found:
                    out_strs.append(String(""))
                    validity.clear(i)
                    null_count += 1
            var out_sa = StringArray.from_strings(out_strs)
            # Attach validity if any nulls.
            if null_count > 0:
                out_sa.validity = validity^
                out_sa.null_count = null_count
            return Column.from_string(out_sa^)
        elif value_type_id == Int(ArrowType.INT64.type_id):
            # Int64-value output: per-row scan, build a PrimitiveArray[int64]
            # + validity bitmap.
            var vals_pa = entry_values.as_primitive[DType.int64]()
            var out_ints = List[Scalar[DType.int64]](capacity=n_rows)
            var validity = Bitmap.create_all_valid(n_rows)
            var null_count = 0
            for i in range(n_rows):
                if parent_col._validity:
                    if not parent_col._validity.value().test(i):
                        out_ints.append(Scalar[DType.int64](0))
                        validity.clear(i)
                        null_count += 1
                        continue
                var start = Int(parent_col._offsets.value().get_typed[Int32](i))
                var end = Int(parent_col._offsets.value().get_typed[Int32](i + 1))
                var probe = probe_sa.get(i)
                var found = False
                for e in range(start, end):
                    if keys_sa.get(e) == probe:
                        out_ints.append(vals_pa.get(e))
                        found = True
                        break
                if not found:
                    out_ints.append(Scalar[DType.int64](0))
                    validity.clear(i)
                    null_count += 1
            var out_pa = PrimitiveArray[DType.int64].from_list(out_ints)
            if null_count > 0:
                out_pa.validity = validity^
                out_pa.null_count = null_count
            return Column.from_primitive[DType.int64](out_pa^)
        else:
            raise Error(
                "PipelineCompiler: EXPR_MAP_GET only supports STRING or INT64"
                " value types in v0.4 X1b (got value type_id="
                + String(value_type_id) + ")"
            )

    elif expr.tag == EXPR_JSON_EXTRACT:
        # json_extract + SQL `->` / `->>`.
        # Evaluate the parent (must yield a STRING Column of JSON text),
        # then dispatch to the stage-2-skip walker in
        # komira_jsonl/json_extract_kernel.mojo (a path-aware fast path).
        # The kernel ships bytes-correct output; the extension-metadata
        # attachment for `->` (`ARROW:extension:name = "komira.ext.json"`)
        # lives at the Field level — here the bit is surfaced on the Column
        # via the kernel's `preserve_extension_metadata` flag, and Field-level
        # kv-metadata round-trip is the SDK layer's job. The byte content of the
        # two operators is identical for non-string scalars; the diff
        # `->` returns raw JSON text including quotes).
        #
        # ⚠ WITH ONE EXCEPTION: the JSON LITERAL `null`. "Identical for
        # non-string scalars" holds for numbers and for
        # `true`/`false`; for `null` the two operators DIVERGE — `->`
        # keeps the three-byte JSON text and `->>` returns **SQL NULL**,
        # because a JSON null has no VARCHAR form. DuckDB v1.5.3 and
        # Postgres `jsonb ->>` both do this. The kernel's scalar arm makes the distinction;
        # nothing here changes.
        var parent_col = _eval_column_expr(expr.json_extract_parent_ref(), batch)
        if Int(parent_col.arrow_type.type_id) != Int(ArrowType.STRING.type_id):
            raise Error(
                "PipelineCompiler: EXPR_JSON_EXTRACT parent must be STRING,"
                " got type_id=" + String(Int(parent_col.arrow_type.type_id))
            )
        var path_segs = expr.json_extract_path_segments()
        var out_type = expr.json_extract_output_type()
        var preserve = expr.json_extract_preserve_extension_metadata()
        return json_extract_column(parent_col, path_segs^, out_type, preserve)

    elif expr.tag == EXPR_EXTRACT:
        # temporal field
        # extraction (year / month / day / hour / minute / second /
        # quarter) and date_trunc(unit).  Dispatch on (unit, child_arrow_type).
        var child_col = _eval_column_expr(expr.extract_child_ref(), batch)
        var unit = expr.extract_unit()
        # ⚠ THE TYPE COMES FROM `_resolve_temporal_arrow_type`, NOT FROM
        # `child_col.arrow_type`, AND THAT ONE LINE IS WHAT MAKES THIS NODE
        # REACHABLE OVER A PARQUET SCAN AT ALL. The reader hands back a
        # PHYSICALLY-stamped column (INT32 for a DATE32, INT64 for a
        # TIMESTAMP_*) and carries the logical type on the schema FIELD; the
        # bare stamp read here before refused every one of them.
        var src_at = _resolve_temporal_arrow_type(
            child_col, batch, _expr_name_hint(expr.extract_child_ref())
        )
        var is_date32 = src_at == ArrowType.DATE32
        var is_ts = (
            src_at == ArrowType.TIMESTAMP
            or src_at == ArrowType.TIMESTAMP_S
            or src_at == ArrowType.TIMESTAMP_MS
            or src_at == ArrowType.TIMESTAMP_US
            or src_at == ArrowType.TIMESTAMP_NS
        )
        if not (is_date32 or is_ts):
            raise Error(
                "PipelineCompiler: EXPR_EXTRACT child must be DATE32 or"
                " TIMESTAMP_*, got type_id="
                + String(Int(child_col.arrow_type.type_id))
                + " and the batch schema does not declare it temporal either"
            )
        # --- date_trunc family ---
        if _is_trunc_unit(unit):
            # Map the IR EXTRACT_TRUNC_* tag onto the kernel TRUNC_* tag.
            # Kernel uses a tight 0..9 encoding (TRUNC_YEAR=0 ...
            # TRUNC_MICROSECOND=9); IR uses 16..25.
            var k_unit: UInt8 = TRUNC_YEAR
            if unit == EXTRACT_TRUNC_YEAR:
                k_unit = TRUNC_YEAR
            elif unit == EXTRACT_TRUNC_QUARTER:
                k_unit = TRUNC_QUARTER
            elif unit == EXTRACT_TRUNC_MONTH:
                k_unit = TRUNC_MONTH
            elif unit == EXTRACT_TRUNC_WEEK:
                k_unit = TRUNC_WEEK
            elif unit == EXTRACT_TRUNC_DAY:
                k_unit = TRUNC_DAY
            elif unit == EXTRACT_TRUNC_HOUR:
                k_unit = TRUNC_HOUR
            elif unit == EXTRACT_TRUNC_MINUTE:
                k_unit = TRUNC_MINUTE
            elif unit == EXTRACT_TRUNC_SECOND:
                k_unit = TRUNC_SECOND
            elif unit == EXTRACT_TRUNC_MILLISECOND:
                k_unit = TRUNC_MILLISECOND
            elif unit == EXTRACT_TRUNC_MICROSECOND:
                k_unit = TRUNC_MICROSECOND
            if is_date32:
                var arr32 = child_col.as_primitive[DType.int32]()
                var out32 = date_trunc_date32(arr32, k_unit)
                var col_out = Column.from_primitive[DType.int32](out32)
                col_out.arrow_type = ArrowType.DATE32
                return col_out^
            # TIMESTAMP_* input — output keeps the same unit (kernel
            # value stays in src ticks).
            var arr64 = child_col.as_primitive[DType.int64]()
            var out64 = date_trunc_ts(arr64, src_at, k_unit)
            var col_out_ts = Column.from_primitive[DType.int64](out64)
            col_out_ts.arrow_type = src_at
            return col_out_ts^
        # --- Field extracts (output INT64) ---
        #
        # ★★ INT64, NOT INT32, AND THE CHANGE CLOSED A DIVERGENCE
        # BETWEEN THIS EXECUTOR AND THE ROW ONE. `row_streaming_segment`
        # translates the same EXPR_EXTRACT into `EXPR_EXTRACT_I64` and sizes
        # its output cell in the default INT64 family, so before this line the
        # SAME PLAN answered `year(d)` as INT32 here and INT64 there —
        # decided by whether the projection happened to be row-servable.
        # DuckDB v1.5.3 answers BIGINT (measured over `duckdb_functions` and
        # by evaluation), which is the row path, so this path moved.
        if is_date32:
            var arr32 = child_col.as_primitive[DType.int32]()
            if unit == EXTRACT_YEAR:
                return Column.from_primitive[DType.int64](extract_year_date32(arr32))
            elif unit == EXTRACT_MONTH:
                return Column.from_primitive[DType.int64](extract_month_date32(arr32))
            elif unit == EXTRACT_DAY:
                return Column.from_primitive[DType.int64](extract_day_date32(arr32))
            elif unit == EXTRACT_QUARTER:
                return Column.from_primitive[DType.int64](extract_quarter_date32(arr32))
            elif (
                unit == EXTRACT_HOUR
                or unit == EXTRACT_MINUTE
                or unit == EXTRACT_SECOND
                # `millisecond(DATE ...)` and
                # `microsecond(DATE ...)` are 0 too (measured v1.5.3) — the
                # SAME constant, so they join this arm rather than getting a
                # kernel of their own to disagree with it.
                or unit == EXTRACT_MILLISECOND
                or unit == EXTRACT_MICROSECOND
            ):
                # ★★ ZERO, AND IT USED TO BE A REFUSAL. A DATE32
                # has no sub-day component, and the question is what to ANSWER
                # rather than whether one exists. DuckDB v1.5.3 answers 0 for
                # all three (`hour` = 0 :: BIGINT,
                # measured), so `SELECT hour(order_date)` was a query DuckDB
                # answers and this engine raised on. NULL still propagates —
                # the kernel clones validity, so a NULL date is a NULL hour
                # and not an hour of zero.
                #
                # ⚠ THE ROW EXECUTOR DEMOTES THIS COMBINATION RATHER THAN
                # DUPLICATING IT (`row_streaming_segment._translate_value_node`
                # returns -1 for DATE32 + HOUR/MINUTE/SECOND), so a plan in
                # that shape falls back HERE and gets this same answer. Do not
                # "complete" the row path by adding a second zero-filling site;
                # two implementations of a constant is two chances to disagree.
                return Column.from_primitive[DType.int64](
                    extract_subday_zero_date32(arr32)
                )
            elif (
                unit == EXTRACT_DAYOFWEEK
                or unit == EXTRACT_ISODOW
                or unit == EXTRACT_DAYOFYEAR
            ):
                # A DATE32 IS the day
                # count, so all three are defined on it with no widening — and
                # unlike hour/minute/second there is no "no sub-day component"
                # question to answer. MEASURED v1.5.3: `dayofweek(DATE
                # '')` = 0 (a Sunday), `isodow` = 7, `dayofyear` = 74.
                return Column.from_primitive[DType.int64](
                    extract_day_index_date32(arr32, unit)
                )
            elif (
                unit == EXTRACT_WEEK
                or unit == EXTRACT_ISOYEAR
                or unit == EXTRACT_YEARWEEK
            ):
                # ⛔ `isoyear` here is
                # NOT the DATE32's civil year: `isoyear(DATE '2021-01-01')` =
                # 2020 (measured v1.5.3), because that Friday is in ISO week 53
                # of 2020. Routing it to `extract_year_date32` would be right on
                # ~362 days a year.
                return Column.from_primitive[DType.int64](
                    extract_iso_week_date32(arr32, unit)
                )
            else:
                raise Error(
                    "PipelineCompiler: EXPR_EXTRACT — unsupported unit on DATE32: "
                    + String(Int(unit))
                )
        # TIMESTAMP_* path
        var arr64 = child_col.as_primitive[DType.int64]()
        if unit == EXTRACT_YEAR:
            return Column.from_primitive[DType.int64](extract_year_ts(arr64, src_at))
        elif unit == EXTRACT_MONTH:
            return Column.from_primitive[DType.int64](extract_month_ts(arr64, src_at))
        elif unit == EXTRACT_DAY:
            return Column.from_primitive[DType.int64](extract_day_ts(arr64, src_at))
        elif unit == EXTRACT_QUARTER:
            return Column.from_primitive[DType.int64](extract_quarter_ts(arr64, src_at))
        elif unit == EXTRACT_HOUR:
            return Column.from_primitive[DType.int64](extract_hour_ts(arr64, src_at))
        elif unit == EXTRACT_MINUTE:
            return Column.from_primitive[DType.int64](extract_minute_ts(arr64, src_at))
        elif unit == EXTRACT_SECOND:
            return Column.from_primitive[DType.int64](extract_second_ts(arr64, src_at))
        elif (
            unit == EXTRACT_DAYOFWEEK
            or unit == EXTRACT_ISODOW
            or unit == EXTRACT_DAYOFYEAR
        ):
            # ⚠ `src_at`, NOT A CONSTANT. The kernel floor-divides the tick
            # count by THIS unit's ticks-per-day to recover the civil day; the
            # four TIMESTAMP_* units share one INT64 storage family, so a
            # hard-coded microsecond assumption answers a day 1000x away over a
            # millisecond column and is green on every fixture written in one
            # unit.
            return Column.from_primitive[DType.int64](
                extract_day_index_ts(arr64, src_at, unit)
            )
        elif (
            unit == EXTRACT_WEEK
            or unit == EXTRACT_ISOYEAR
            or unit == EXTRACT_YEARWEEK
        ):
            return Column.from_primitive[DType.int64](
                extract_iso_week_ts(arr64, src_at, unit)
            )
        elif unit == EXTRACT_MILLISECOND or unit == EXTRACT_MICROSECOND:
            # the seconds are FOLDED IN (30123 / 30123456 for
            # `...:30.123456`, measured). ⛔ This is NOT the fractional part.
            return Column.from_primitive[DType.int64](
                extract_subsecond_ts(arr64, src_at, unit)
            )
        raise Error(
            "PipelineCompiler: EXPR_EXTRACT — unsupported unit on TIMESTAMP_*: "
            + String(Int(unit))
        )

    elif expr.tag == EXPR_MATH_FN:
        # unary scalar math
        # (sin / cos / sqrt / asin / radians).  Coerce the child to FLOAT64,
        # apply element-wise, emit a FLOAT64 column.  Null in -> null out.
        var math_child = _eval_column_expr(expr.math_fn_child_ref(), batch)
        var farr = _column_to_float64(math_child)
        var out = eval_math_unary(expr.math_fn_op(), farr)
        return Column.from_primitive[DType.float64](out)

    elif expr.tag == EXPR_MATH_FN2:
        # binary scalar math
        # (atan2).  Coerce both children to FLOAT64, apply element-wise,
        # emit FLOAT64.  A row is null if EITHER operand is null.
        var math_left = _eval_column_expr(expr.math_fn2_left_ref(), batch)
        var math_right = _eval_column_expr(expr.math_fn2_right_ref(), batch)
        var l_arr = _column_to_float64(math_left)
        var r_arr = _column_to_float64(math_right)
        var out2 = eval_math_binary(expr.math_fn2_op(), l_arr, r_arr)
        return Column.from_primitive[DType.float64](out2)

    elif expr.tag == EXPR_ALIAS:
        # Evaluate the child expression; the alias name is handled by the schema
        return _eval_column_expr(expr.alias_child_ref(), batch)

    elif expr.tag == EXPR_LITERAL:
        var lit_val = expr.literal_value()
        return broadcast_scalar(lit_val, batch.num_rows())

    elif expr.tag == EXPR_AGG_FN:
        # The typed-frame lowering for `col == col.agg`.
        # An EXPR_AGG_FN reaching the projection evaluator is the post-agg
        # scalar-broadcast shape (TPC-H Q15 `total_revenue == total_revenue
        # .max`): the generic `DataFrame[O]` path resolves it
        # via the optimizer's eager-fold (`optimizer_scalar_broadcast`), but the
        # typed frame path does NOT run that rewrite, so the `EXPR_AGG_FN` node
        # survives to here. Reduce the aggregated CHILD column over the WHOLE
        # resident batch to a single scalar and BROADCAST it to a length-N column
        # (the enclosing `col CMP <this>` comparison then runs col-vs-col). The
        # resident batch is the full agg-breaker output (the walker's POST-BREAKER
        # FILTER arm decoded it before evaluating the predicate), so the reduction
        # is a correct GLOBAL aggregate across all groups — byte-equiv to the
        # generic path's folded literal, minus the double base-scan.
        var agg_child_col = _eval_column_expr(expr.agg_fn_child_ref(), batch)
        var agg_scalar = _reduce_agg_scalar(agg_child_col, expr.agg_fn_op())
        return broadcast_scalar(agg_scalar, batch.num_rows())

    elif expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()

        # ★★ BOOLEAN-VALUED BINARY OPS AS AN OUTPUT COLUMN.
        #
        # Everything below this block is an ARITHMETIC ladder: it dispatches
        # ADD/SUB/MUL/DIV per operand-type pair and raises on anything else.
        # So a comparison was executable as a FILTER PREDICATE and NOT as a
        # projection — `SELECT a > b` / `SELECT isfinite(v)` came back
        #
        #     unsupported float64 scalar binary op: 14     (BIN_GT, literal RHS)
        #     PipelineCompiler: unsupported float64 binary op: 14   (col-col)
        #
        # ⚠ THIS IS THE SAME DEFECT CLASS THE `EXPR_UNARY_OP` AND
        # `EXPR_IN_LIST` ARMS BELOW EACH CARRY A NOTE ABOUT: predicate-context
        # and projection-context dispatch are two ladders over one tag
        # universe, and `walk_expr_field` has typed every comparison and
        # AND/OR as BOOL "whatever their operands" since the two field-inference
        # copies converged. The TYPE half was armed; only the DATA half was not.
        #
        # ⛔ IT IS NOT A SECOND IMPLEMENTATION OF FLOAT COMPARISON, and it must
        # not become one. `_eval_predicate` reaches the same
        # `_col_cmp_nullable` / `kleene_cmp_finalize_scalar` seam the filter
        # path uses, which is the ONLY reason the NULL contract comes for free:
        # a row with a NULL operand comes back DATA BIT 0 with its validity bit
        # cleared, i.e. NULL rather than FALSE. DuckDB v1.5.3 propagates NULL
        # through `isfinite`/`isinf`/`isnan`, and a hand-rolled arm here would
        # have had to re-derive that.
        #
        # AND / OR first, and unconditionally: no arm anywhere below evaluates
        # a Bool ⊗ Bool pair, so this cannot take work away from one.
        if op == BIN_AND or op == BIN_OR:
            var logical_ba = _eval_predicate(expr, batch)
            return Column.from_boolean(logical_ba^)

        # --- Scalar-aware fast path ---
        # Detect when one operand is a literal to avoid materializing a full
        # N-element array for a constant value. Routes to SIMD scalar kernels
        # (eval_mul_scalar, eval_add_scalar, etc.) that broadcast the scalar
        # in registers — zero allocation, no memory bandwidth waste.
        var right_is_scalar = expr.binary_right_ref().tag == EXPR_LITERAL
        var left_is_scalar = expr.binary_left_ref().tag == EXPR_LITERAL

        # A comparison against a LITERAL — the shape `isfinite`/`isinf`/`isnan`
        # desugar to (`x > -inf`, `x < inf`, `x = inf`). Routed BEFORE the
        # arithmetic fast path because `_eval_binary_col_scalar` has no arm for
        # it; an INTERVAL_MDN operand cannot reach here (there is no interval
        # literal), so the eq/ne arm further down keeps its only caller.
        if _is_comparison_op(op) and (right_is_scalar or left_is_scalar):
            var cmp_lit_ba = _eval_predicate(expr, batch)
            return Column.from_boolean(cmp_lit_ba^)

        if right_is_scalar:
            var left_col = _eval_column_expr(expr.binary_left_ref(), batch)
            var sv = expr.binary_right_ref().literal_value()
            if left_col.arrow_type == ArrowType.DECIMAL128 or sv.is_decimal128():
                # ⭐ A DECIMAL ON EITHER SIDE OF A LITERAL:
                # `_eval_binary_col_scalar` has no decimal arm (`dc * 2` failed
                # with engine text `unsupported type 18`) and read a DECIMAL
                # literal through the wrong union member (`v + CAST(1 AS
                # DECIMAL(18,0))` answered 368934881474191032330). Broadcast the
                # literal and take the ONE decimal arm the column path takes.
                var rlit = broadcast_scalar(sv, left_col.length())
                return _eval_decimal_binary_pair(
                    left_col, rlit, op, batch,
                    _expr_name_hint(expr.binary_left_ref()), String(""),
                )
            return _eval_binary_col_scalar(left_col, op, sv)

        if left_is_scalar:
            var sv = expr.binary_left_ref().literal_value()
            var right_col = _eval_column_expr(expr.binary_right_ref(), batch)
            if right_col.arrow_type == ArrowType.DECIMAL128 or sv.is_decimal128():
                # The mirror of the arm above (`120 / dc`, `1 - dp`).
                var llit = broadcast_scalar(sv, right_col.length())
                return _eval_decimal_binary_pair(
                    llit, right_col, op, batch,
                    String(""), _expr_name_hint(expr.binary_right_ref()),
                )
            # For commutative ops, swap to col-scalar. For non-commutative, negate.
            if op == BIN_ADD or op == BIN_MUL:
                return _eval_binary_col_scalar(right_col, op, sv)
            elif op == BIN_SUB:
                # scalar - col, evaluated AS `scalar - col` (`eval_rsub_scalar`).
                #
                # ⛔ IT WAS `-(col - scalar)`, a negation by `eval_mul_scalar(-1)`,
                # and that rewrite was wrong three ways. (1) The fresh product
                # carried NO validity, so `100 - v` over a NULL row answered the
                # LITERAL (`proj_reflected_arith`;
                # `test_scalar_left_sub_keeps_nulls` pins it). (2) Once INT64
                # arithmetic RAISES on overflow, `-1 - MAX`
                # — whose answer MIN exists — raised, because `MAX - (-1)` does
                # not. (3) `1.0 - 1.0` answered -0.0. `_eval_binary_col_scalar`
                # clones the column's validity onto the result, as for every op.
                return _eval_binary_col_scalar(right_col, BIN_SUB, sv, True)
            # Fallthrough for scalar / col — use broadcast path below

        # --- Column-column path (both sides are column expressions) ---
        var left_col = _eval_column_expr(expr.binary_left_ref(), batch)
        var right_col = _eval_column_expr(expr.binary_right_ref(), batch)

        # The col-col half of the boolean-op block above. `_eval_col_vs_col_
        # promoted` is the SAME entry point `_eval_predicate`'s computed-operand
        # path uses, so the operands are consumed once and the promotion rules
        # (FLOAT64 ⊕ INT64 → FLOAT64, INT64 ⊕ INT32 → INT64) are stated in one
        # place. Calling `_eval_predicate` here instead would evaluate both
        # subtrees a SECOND time.
        #
        # ⚠ THE INTERVAL_MDN PAIR IS EXCLUDED BY NAME and must stay excluded:
        # its `BIN_EQ`/`BIN_NE` arm below is the only thing that serves it
        # (`_eval_col_vs_col_promoted` refuses the type), and
        # `test_arrow_nested_compute_x4_interval_mdn_engine` T9 drives exactly
        # that shape through THIS function.
        if _is_comparison_op(op) and not (
            left_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
            or right_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
        ):
            var cmp_cc_ba = _eval_col_vs_col_promoted(
                left_col^, right_col^, op
            )
            return Column.from_boolean(cmp_cc_ba^)

        # Determine type and perform arithmetic.
        # NOTE: the SIMD arithmetic kernels
        # are pure compute (no validity touch) — they allocate a fresh
        # result with no null mask. Nullable arithmetic must produce NULL
        # wherever either input is NULL, so we merge AND(left.validity,
        # right.validity) onto `result` and recompute null_count before
        # wrapping. `merge_binary_arith_validity` is a no-op when neither
        # input has validity (the common case — zero cost on the hot path).
        if left_col.arrow_type == ArrowType.INT64 and right_col.arrow_type == ArrowType.INT64:
            var left_arr = left_col.as_primitive[DType.int64]()
            var right_arr = right_col.as_primitive[DType.int64]()
            var result: PrimitiveArray[DType.int64]
            if op == BIN_ADD:
                result = eval_add[DType.int64](left_arr, right_arr)
            elif op == BIN_SUB:
                result = eval_sub[DType.int64](left_arr, right_arr)
            elif op == BIN_MUL:
                result = eval_mul[DType.int64](left_arr, right_arr)
            elif op == BIN_DIV:
                result = eval_div[DType.int64](left_arr, right_arr)
            elif op == BIN_MOD:
                result = _mod_trunc_cc[DType.int64](left_arr, right_arr)
            else:
                raise Error("PipelineCompiler: unsupported int64 binary op: " + String(Int(op)))
            merge_binary_arith_validity[DType.int64](left_col, right_col, result)
            return Column.from_primitive[DType.int64](result)

        elif left_col.arrow_type == ArrowType.FLOAT64 and right_col.arrow_type == ArrowType.FLOAT64:
            var left_arr = left_col.as_primitive[DType.float64]()
            var right_arr = right_col.as_primitive[DType.float64]()
            var result: PrimitiveArray[DType.float64]
            if op == BIN_ADD:
                result = eval_add[DType.float64](left_arr, right_arr)
            elif op == BIN_SUB:
                result = eval_sub[DType.float64](left_arr, right_arr)
            elif op == BIN_MUL:
                result = eval_mul[DType.float64](left_arr, right_arr)
            elif op == BIN_DIV:
                result = eval_div[DType.float64](left_arr, right_arr)
            elif op == BIN_MOD:
                result = _mod_trunc_cc[DType.float64](left_arr, right_arr)
            else:
                raise Error("PipelineCompiler: unsupported float64 binary op: " + String(Int(op)))
            merge_binary_arith_validity[DType.float64](left_col, right_col, result)
            return Column.from_primitive[DType.float64](result)

        elif left_col.arrow_type == ArrowType.INT64 and right_col.arrow_type == ArrowType.FLOAT64:
            # Promote left int64 to float64
            var left_arr = left_col.as_primitive[DType.int64]()
            var right_arr = right_col.as_primitive[DType.float64]()
            # Cast left to float64
            var left_f64 = int64_to_float64(left_arr)
            var result: PrimitiveArray[DType.float64]
            if op == BIN_ADD:
                result = eval_add[DType.float64](left_f64, right_arr)
            elif op == BIN_SUB:
                result = eval_sub[DType.float64](left_f64, right_arr)
            elif op == BIN_MUL:
                result = eval_mul[DType.float64](left_f64, right_arr)
            elif op == BIN_DIV:
                result = eval_div[DType.float64](left_f64, right_arr)
            elif op == BIN_MOD:
                result = _mod_trunc_cc[DType.float64](left_f64, right_arr)
            else:
                raise Error("PipelineCompiler: unsupported mixed binary op: " + String(Int(op)))
            merge_binary_arith_validity[DType.float64](left_col, right_col, result)
            return Column.from_primitive[DType.float64](result)

        elif left_col.arrow_type == ArrowType.FLOAT64 and right_col.arrow_type == ArrowType.INT64:
            # Promote right int64 to float64
            var left_arr = left_col.as_primitive[DType.float64]()
            var right_arr = right_col.as_primitive[DType.int64]()
            var right_f64 = int64_to_float64(right_arr)
            var result: PrimitiveArray[DType.float64]
            if op == BIN_ADD:
                result = eval_add[DType.float64](left_arr, right_f64)
            elif op == BIN_SUB:
                result = eval_sub[DType.float64](left_arr, right_f64)
            elif op == BIN_MUL:
                result = eval_mul[DType.float64](left_arr, right_f64)
            elif op == BIN_DIV:
                result = eval_div[DType.float64](left_arr, right_f64)
            elif op == BIN_MOD:
                result = _mod_trunc_cc[DType.float64](left_arr, right_f64)
            else:
                raise Error("PipelineCompiler: unsupported mixed binary op: " + String(Int(op)))
            merge_binary_arith_validity[DType.float64](left_col, right_col, result)
            return Column.from_primitive[DType.float64](result)

        elif left_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO and right_col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO:
            # INTERVAL_MONTH_DAY_NANO componentwise
            # add/sub.  Per Arrow spec (Schema.fbs IntervalUnit::MONTH_DAY_NANO),
            # each field is independent; result Column carries
            # ArrowType.INTERVAL_MONTH_DAY_NANO.  Validity AND'd by the kernel.
            var l_arr = left_col.as_interval_mdn()
            var r_arr = right_col.as_interval_mdn()
            if op == BIN_ADD:
                var result = add_interval_mdn(l_arr, r_arr)
                return Column.from_interval_mdn(result^)
            elif op == BIN_SUB:
                var result = sub_interval_mdn(l_arr, r_arr)
                return Column.from_interval_mdn(result^)
            elif op == BIN_EQ:
                var bm = eval_eq_interval_mdn(l_arr, r_arr)
                # Wrap Bitmap into a BooleanArray-backed column.
                var ba = BooleanArray.from_bitmap(bm^)
                return Column.from_boolean(ba^)
            elif op == BIN_NE:
                var bm = eval_eq_interval_mdn(l_arr, r_arr)
                var ba = BooleanArray.from_bitmap(bm^)
                return Column.from_boolean(eval_not(ba))
            else:
                raise Error(
                    "PipelineCompiler: INTERVAL_MONTH_DAY_NANO supports only"
                    " add/sub/eq/ne; Arrow spec does not define ordering on"
                    " this type (got op=" + String(Int(op)) + ")"
                )

        elif left_col.arrow_type == ArrowType.DECIMAL128 or right_col.arrow_type == ArrowType.DECIMAL128:
            return _eval_decimal_binary_pair(
                left_col,
                right_col,
                op,
                batch,
                _expr_name_hint(expr.binary_left_ref()),
                _expr_name_hint(expr.binary_right_ref()),
            )

        else:
            raise Error(
                "PipelineCompiler: unsupported column types for binary op: "
                + String(left_col.arrow_type) + " and " + String(right_col.arrow_type)
            )

    elif expr.tag == EXPR_UNARY_OP:
        # ★ THE PROJECTION ARM FOR `NOT x` / `-x`. `EXPR_UNARY_OP` has a
        # PREDICATE arm (`compiler_eval_predicate._eval_predicate`); without a
        # PROJECTION arm, `SELECT NOT flag` / `SELECT -x` raised
        # "unsupported projection expression tag: 4" — and BOTH output-field
        # inference copies were also unarmed, so even once the data existed
        # the column would have exported as Arrow type `null`.
        #
        # ⚠ THIS IS THE SAME DEFECT CLASS IN A THIRD LADDER, and it has bitten
        # here before: the EXPR_IN_LIST arm below carries the identical story
        # ("had a predicate-context arm ... but was missing from the
        # projection-context dispatch"). Predicate-context and
        # projection-context dispatch are two ladders over one tag universe;
        # a tag armed in one is not armed in the other.
        var uop = expr.unary_op()
        if uop == UN_NOT:
            # Element-wise logical NOT over a BOOL column. The child must
            # evaluate to a Bool COLUMN — `NOT (a > b)` is a comparison in
            # projection context, which this ladder does not evaluate
            # (arithmetic only), and raises in the child call with its own
            # message rather than silently here.
            var child_col = _eval_column_expr(expr.unary_child_ref(), batch)
            var child_ba = child_col.as_boolean()
            return Column.from_boolean(eval_not(child_ba))
        elif uop == UN_NEGATE:
            # `-x` is `x * -1` — routed through the SAME tested scalar path
            # the BIN_SUB scalar-swap above uses, so it inherits that path's
            # validity preservation (`clone_array_validity`) and its INT32 /
            # INT64 / FLOAT64 width rules for free. Deliberately NOT a
            # hand-rolled negate loop: a second implementation of a width
            # rule is how the widths drift apart.
            #
            # ⛔ `-MIN` OVERFLOWS: the checked `* -1`
            # raises, and the raise is re-worded to DuckDB 1.5.3's own sentence
            # for a NEGATION (`Out of Range Error: Overflow in negation of
            # numeric value!`, measured) rather than the multiplication this arm
            # happens to be spelled as.
            var neg_child = _eval_column_expr(expr.unary_child_ref(), batch)
            try:
                return _eval_binary_col_scalar(
                    neg_child, BIN_MUL, ScalarValue.from_int(-1)
                )
            except err:
                if is_int_overflow_error(String(err)):
                    raise Error(
                        "Out of Range Error: Overflow in negation of numeric value!"
                    )
                raise err^
        elif (
            uop == UN_ABS or uop == UN_SIGN
            or uop == UN_TRUNC or uop == UN_ROUND
            or uop == UN_BIT_COUNT
        ):
            # `abs` / `sign` / `trunc` / `round`.
            #
            # THE OUTPUT WIDTH IS THE INPUT WIDTH (except `sign`, which is
            # INT8 always), and this dispatch is the DATA half of a pair whose
            # TYPE half is `walk_expr_field`'s EXPR_UNARY_OP arm. The two must
            # agree column by column — `test_projection_type_matches_data` is
            # what says so, and it is the reason a widening "just promote to
            # FLOAT64 and be done" arm is NOT written here: that would compute
            # a correct VALUE under a schema that declares a different TYPE,
            # which is the shape the Arrow C-ABI export refuses.
            var num_child = _eval_column_expr(expr.unary_child_ref(), batch)
            var knum = numeric_unary_kernel_tag(uop)
            var nat = num_child.arrow_type
            if uop == UN_BIT_COUNT:
                # INT8 out for every width, like
                # `sign` — but the VALUE depends on the operand's width, so
                # each width goes to the kernel instantiated at THAT width.
                #
                # ⛔ NO FLOAT ARM, AND THAT IS THE POINT. DuckDB v1.5.3 has
                # FIVE integer overloads of `bit_count` and NO floating one:
                # `SELECT bit_count(1.5)` is a BINDER ERROR there. Casting a
                # FLOAT column to an integer here would
                # answer a number for an expression the oracle refuses to run,
                # which is worse than the raise below — so a FLOAT operand
                # falls through to the error and names the cast the caller has
                # to write themselves.
                if nat == ArrowType.INT64:
                    return Column.from_primitive[DType.int8](
                        eval_bit_count_int[DType.int64](
                            num_child.as_primitive[DType.int64]()
                        )
                    )
                elif nat == ArrowType.INT32:
                    return Column.from_primitive[DType.int8](
                        eval_bit_count_int[DType.int32](
                            num_child.as_primitive[DType.int32]()
                        )
                    )
                elif nat == ArrowType.INT16:
                    return Column.from_primitive[DType.int8](
                        eval_bit_count_int[DType.int16](
                            num_child.as_primitive[DType.int16]()
                        )
                    )
                elif nat == ArrowType.INT8:
                    return Column.from_primitive[DType.int8](
                        eval_bit_count_int[DType.int8](
                            num_child.as_primitive[DType.int8]()
                        )
                    )
                raise Error(
                    "PipelineCompiler: bit_count() supports INT8 / INT16 /"
                    " INT32 / INT64 columns; got arrow type "
                    + String(Int(nat.type_id))
                    + ". DuckDB v1.5.3 has NO floating or decimal overload of"
                    " bit_count -- bit_count(1.5) is a bind error there -- so"
                    " this engine refuses rather than casting. CAST the column"
                    " to BIGINT if a popcount over its integer value is what"
                    " you want; the answer then counts 64 bits, not the"
                    " column's original width."
                )
            if uop == UN_SIGN:
                if nat == ArrowType.FLOAT64:
                    return Column.from_primitive[DType.int8](
                        eval_sign_float[DType.float64](
                            num_child.as_primitive[DType.float64]()
                        )
                    )
                elif nat == ArrowType.FLOAT32:
                    return Column.from_primitive[DType.int8](
                        eval_sign_float[DType.float32](
                            num_child.as_primitive[DType.float32]()
                        )
                    )
                elif nat == ArrowType.INT64:
                    return Column.from_primitive[DType.int8](
                        eval_sign_int[DType.int64](
                            num_child.as_primitive[DType.int64]()
                        )
                    )
                elif nat == ArrowType.INT32:
                    return Column.from_primitive[DType.int8](
                        eval_sign_int[DType.int32](
                            num_child.as_primitive[DType.int32]()
                        )
                    )
                elif nat == ArrowType.INT16:
                    return Column.from_primitive[DType.int8](
                        eval_sign_int[DType.int16](
                            num_child.as_primitive[DType.int16]()
                        )
                    )
                elif nat == ArrowType.INT8:
                    return Column.from_primitive[DType.int8](
                        eval_sign_int[DType.int8](
                            num_child.as_primitive[DType.int8]()
                        )
                    )
                raise Error(
                    "PipelineCompiler: sign() supports INT8 / INT16 / INT32 /"
                    " INT64 / FLOAT32 / FLOAT64 columns; got arrow type "
                    + String(Int(nat.type_id))
                    + ". DECIMAL128 has its own arithmetic module and no"
                    " sign kernel yet — CAST to DOUBLE to get DuckDB's value,"
                    " which is TINYINT either way."
                )
            if nat == ArrowType.FLOAT64:
                return Column.from_primitive[DType.float64](
                    eval_numeric_unary_float[DType.float64](
                        knum, num_child.as_primitive[DType.float64]()
                    )
                )
            elif nat == ArrowType.FLOAT32:
                return Column.from_primitive[DType.float32](
                    eval_numeric_unary_float[DType.float32](
                        knum, num_child.as_primitive[DType.float32]()
                    )
                )
            elif nat == ArrowType.INT64:
                return Column.from_primitive[DType.int64](
                    eval_numeric_unary_int[DType.int64](
                        knum, num_child.as_primitive[DType.int64]()
                    )
                )
            elif nat == ArrowType.INT32:
                return Column.from_primitive[DType.int32](
                    eval_numeric_unary_int[DType.int32](
                        knum, num_child.as_primitive[DType.int32]()
                    )
                )
            elif nat == ArrowType.INT16:
                return Column.from_primitive[DType.int16](
                    eval_numeric_unary_int[DType.int16](
                        knum, num_child.as_primitive[DType.int16]()
                    )
                )
            elif nat == ArrowType.INT8:
                return Column.from_primitive[DType.int8](
                    eval_numeric_unary_int[DType.int8](
                        knum, num_child.as_primitive[DType.int8]()
                    )
                )
            # ⛔ A NAMED REFUSAL, NOT A PROMOTION. Promoting a DECIMAL128 to
            # FLOAT64 here would answer a query DuckDB answers in DECIMAL, and
            # `walk_expr_field` has already declared DECIMAL128 for it — so
            # the promotion would be a schema/data disagreement on top of a
            # precision loss. The user's fix is one CAST and it is stated.
            raise Error(
                "PipelineCompiler: abs() / trunc() / round() support INT8 /"
                " INT16 / INT32 / INT64 / FLOAT32 / FLOAT64 columns; got"
                " arrow type " + String(Int(nat.type_id))
                + ". These are TYPE-PRESERVING functions, so a DECIMAL128"
                " operand needs a DECIMAL128 kernel (not yet written) rather"
                " than a promotion — CAST to DOUBLE if a DOUBLE answer is"
                " acceptable."
            )

        elif uop == UN_IS_NULL or uop == UN_IS_NOT_NULL:
            # ★★ `SELECT x IS NULL AS is_missing`. The kernel is reached
            # through `from .compiler_eval_predicate import _eval_predicate,
            # _is_comparison_op` at the top of this file — the same import the
            # `EXPR_BINARY_OP` arm delegates AND/OR and the six comparisons
            # through — so there is no cycle to defend and no reason to refuse
            # `x IS NULL` in a SELECT list.
            #
            # ⛔ STILL NOT A SECOND COPY, AND THAT IS THE WHOLE POINT. The
            # validity-bitmap -> BooleanArray conversion is intricate (a
            # bytewise `~validity`, a trailing-bit mask so the slack bits of the
            # last byte are not phantom nulls, and a separate general-child
            # fallback that materialises a computed child) and it lives in ONE
            # place. `_eval_predicate` is handed THIS node, unchanged, so both
            # polarities and the COL_REF fast path come across intact.
            #
            # ⚠ THE DECLARED TYPE ALREADY AGREED: `walk_expr_field`'s
            # EXPR_UNARY_OP arm has typed these BOOL (and NON-nullable — `x IS
            # NULL` is total). The TYPE half was armed and only
            # the DATA half was not, which is this file's recurring shape: a
            # predicate-context ladder and a projection-context ladder over one
            # tag universe.
            var null_ba = _eval_predicate(expr, batch)
            return Column.from_boolean(null_ba^)
        else:
            raise Error(
                "PipelineCompiler: unknown unary op in projection: "
                + String(Int(uop))
            )

    elif expr.tag == EXPR_CAST:
        var child_col = _eval_column_expr(expr.cast_child_ref(), batch)
        var target = expr.cast_target()
        var target_arrow = expr.cast_target_arrow()
        var src_at = child_col.arrow_type
        # --- DECIMAL128 casts ---
        if target_arrow == ArrowType.DECIMAL128:
            return _eval_cast_to_decimal128(child_col, expr.cast_decimal_precision(), expr.cast_decimal_scale(), batch, _expr_name_hint(expr.cast_child_ref()))
        if src_at == ArrowType.DECIMAL128:
            return _eval_cast_from_decimal128(child_col, target, target_arrow, batch, _expr_name_hint(expr.cast_child_ref()))
        # =====================================================================
        # THE NUMERIC CAST MATRIX — {I32, I64, F32, F64}, ALL 12 ORDERED PAIRS
        # =====================================================================
        #
        # ⭐ COMPLETE ON PURPOSE, AND THE GAPS ARE WHY. This ladder used to hold
        # SIX of the twelve edges. The diagonal fell through to the no-op arm at
        # the bottom, and the other SIX raised
        #
        #     PipelineCompiler: unsupported EXPR_CAST from <a> to <b>
        #
        # — an internal component name reaching a customer who wrote ordinary
        # SQL. `_sql_cast_target_arrow` had already withdrawn REAL as a TARGET
        # for exactly this, but a TARGET table cannot see a SOURCE:
        # `CAST(f32 AS BIGINT)` names only served types (BIGINT is served) and
        # still died here. ⛔ So do not "tidy" this back into
        # the six that had callers — the missing six ARE the defect, and every
        # kernel each one needs already existed (`_cmp_narrow_to_float32` above
        # has been calling `eval_cast[int64, float32]` all along).
        #
        # ⛔⛔ FLOAT -> INTEGER IS **NOT** `eval_cast`, AND THAT IS THE OTHER HALF
        # OF THIS BLOCK'S REWRITE. `eval_cast`'s SIMD `.cast[int]` truncates
        # toward zero; DuckDB v1.5.3 rounds HALF TO EVEN. The four float->int
        # edges therefore go through `eval_cast_float_to_int`, which is the only
        # spelling of that rule. See `komira_core/eval/cast_null.mojo`.
        #
        # ⭐ AND IT ALSO CARRIES THE OVERFLOW GUARD, WHICH IS
        # WHY THESE FOUR ARMS PASS `expr.cast_is_try` AND THE OTHER EIGHT DO
        # NOT. A float source is the only side of this matrix whose value can be
        # unrepresentable in the target: before the guard, all four of
        # `CAST(1e308 AS BIGINT)`, `CAST(-1e308 AS BIGINT)`, `CAST(nan AS BIGINT)`
        # and `CAST(1e30::FLOAT AS BIGINT)` ANSWERED -9223372036854775808 with a
        # success code where DuckDB v1.5.3 raises. TRY nulls the row instead,
        # which is the same `_try` forwarding the STRING arms below carry.
        #
        # ⚠ THE INT64 -> INT32 ARM BELOW IS THE SAME DEFECT CLASS AND IS **NOT**
        # FIXED HERE — `eval_cast[int64, int32]` still truncates the high bits,
        # so `CAST(9223372036854775807 AS INTEGER)` answers -1 where DuckDB
        # raises. It is REFUSED BY NAME rather than half-done: `eval_cast` is a
        # SHARED kernel that the implicit-promotion paths (`_cmp_narrow_to_float32`
        # and friends) also call, so a raise added inside it would change
        # comparison behaviour that no cast oracle grades. Closing it needs its
        # own guarded narrowing kernel, the way the float side got one.
        # It is a registered, known refusal.
        #
        # ⭐ AND F64 -> F32 IS CHECKED :
        # a FINITE double whose float rounding is +-inf RAISES DuckDB's
        # `Conversion Error ... destination type FLOAT` (TRY: NULL) instead of
        # answering inf. `eval_cast_f64_to_f32_checked` in `cast_null.mojo`.
        #
        #          target ->    I32        I64        F32        F64
        #   source I32          no-op      eval_cast  eval_cast  eval_cast
        #          I64          eval_cast  no-op      eval_cast  int64_to_float64
        #          F32          ROUND      ROUND      no-op      eval_cast
        #          F64          ROUND      ROUND      CHECKED    no-op
        #
        # --- INT64 source ---
        if src_at == ArrowType.INT64 and target == DType.float64:
            var arr = child_col.as_primitive[DType.int64]()
            var result = int64_to_float64(arr)
            return Column.from_primitive[DType.float64](result)
        elif src_at == ArrowType.INT64 and target == DType.int32:
            var arr = child_col.as_primitive[DType.int64]()
            var result = eval_cast[DType.int64, DType.int32](arr)
            return Column.from_primitive[DType.int32](result)
        elif src_at == ArrowType.INT64 and target == DType.float32:
            var arr = child_col.as_primitive[DType.int64]()
            var result = eval_cast[DType.int64, DType.float32](arr)
            return Column.from_primitive[DType.float32](result)
        # --- INT32 source ---
        elif src_at == ArrowType.INT32 and target == DType.int64:
            var arr = child_col.as_primitive[DType.int32]()
            var result = eval_cast[DType.int32, DType.int64](arr)
            return Column.from_primitive[DType.int64](result)
        elif src_at == ArrowType.INT32 and target == DType.float64:
            var arr = child_col.as_primitive[DType.int32]()
            var result = eval_cast[DType.int32, DType.float64](arr)
            return Column.from_primitive[DType.float64](result)
        elif src_at == ArrowType.INT32 and target == DType.float32:
            var arr = child_col.as_primitive[DType.int32]()
            var result = eval_cast[DType.int32, DType.float32](arr)
            return Column.from_primitive[DType.float32](result)
        # --- FLOAT64 source. The two integer targets ROUND HALF TO EVEN. ---
        elif src_at == ArrowType.FLOAT64 and target == DType.int64:
            var arr = child_col.as_primitive[DType.float64]()
            var result = eval_cast_float_to_int[DType.float64, DType.int64](arr, expr.cast_is_try())
            return Column.from_primitive[DType.int64](result)
        elif src_at == ArrowType.FLOAT64 and target == DType.int32:
            var arr = child_col.as_primitive[DType.float64]()
            var result = eval_cast_float_to_int[DType.float64, DType.int32](arr, expr.cast_is_try())
            return Column.from_primitive[DType.int32](result)
        elif src_at == ArrowType.FLOAT64 and target == DType.float32:
            var arr = child_col.as_primitive[DType.float64]()
            var result = eval_cast_f64_to_f32_checked(arr, expr.cast_is_try())
            return Column.from_primitive[DType.float32](result)
        # --- FLOAT32 source. Same rounding rule; a SEPARATE instantiation, so a
        #     fix confined to the 64-bit source cannot be read as covering it.
        elif src_at == ArrowType.FLOAT32 and target == DType.int64:
            var arr = child_col.as_primitive[DType.float32]()
            var result = eval_cast_float_to_int[DType.float32, DType.int64](arr, expr.cast_is_try())
            return Column.from_primitive[DType.int64](result)
        elif src_at == ArrowType.FLOAT32 and target == DType.int32:
            var arr = child_col.as_primitive[DType.float32]()
            var result = eval_cast_float_to_int[DType.float32, DType.int32](arr, expr.cast_is_try())
            return Column.from_primitive[DType.int32](result)
        elif src_at == ArrowType.FLOAT32 and target == DType.float64:
            var arr = child_col.as_primitive[DType.float32]()
            var result = eval_cast[DType.float32, DType.float64](arr)
            return Column.from_primitive[DType.float64](result)
        # --- Temporal bit-reinterpret casts ---
        # date32 is physically int32, timestamp[*] is physically int64. A
        # cast between the temporal type and its underlying integer is a
        # pure reinterpret (same buffer, same null mask, only the logical
        # ArrowType tag changes) — no compute, no allocation. Relabel in
        # place.
        #
        # the reverse
        # direction (`cast(int AS date32/timestamp)`) and the timestamp-unit
        # scale conversions (`ts[ms] -> ts[us]`) wired up by using
        # `target_arrow` (the Arrow logical type carrier added by
        # `target_arrow` (the Arrow logical type carrier). Same SIMD shape as the forward
        # direction (relabel) + an `eval_mul_scalar` / `eval_div_scalar`
        # for the unit conversion.
        elif src_at == ArrowType.DATE32 and target == DType.int32:
            # forward: DATE32 -> INT32 (relabel only)
            var c = child_col^
            c.arrow_type = ArrowType.INT32
            return c^
        elif src_at == ArrowType.DATE32 and target == DType.int64:
            # ★★ DATE32 -> INT64, THE WIDENING FORWARD CAST.
            #
            # ⛔ IT IS NOT A CONVENIENCE OVER THE RELABEL ABOVE, AND THE REASON
            # IS THAT A DATE COLUMN ARRIVES HERE UNDER TWO DIFFERENT STAMPS.
            # `_resolve_temporal_arrow_type`'s docstring states the live one:
            # the parquet reader hands back a Column stamped INT32 (the
            # PHYSICAL type) while the batch SCHEMA field carries DATE32; an
            # in-memory batch, or a `CAST(x AS DATE)`, is stamped DATE32. A
            # producer that emitted `CAST(<date> AS INT32)` would therefore hit
            # the relabel above for ONE of those two shapes and fall off the
            # end of this ladder for the other — the same lowering raising on
            # half its inputs, chosen by a stamp the producer cannot see.
            #
            # Targeting INT64 makes the pair symmetric: the INT32-stamped
            # column takes the `INT32 -> int64` widen a few arms up, the
            # DATE32-stamped one takes this arm, and both answer the same
            # INT64 column. `date_diff('day', a, b)` / `date_sub` lower to
            # exactly that subtraction (`sql_binder._date_delta_days_over_
            # columns`).
            #
            # ⚠ `as_primitive[int32]` ADMITS A DATE32-STAMPED COLUMN — a DATE32
            # IS an int32 of days (`column.mojo` storage
            # compatibility) — so this is the ordinary widen, not a
            # reinterpret, and `eval_cast` PRESERVES VALIDITY. That is where
            # `date_diff(<NULL date>, x) IS NULL` comes from.
            var d64_arr = child_col.as_primitive[DType.int32]()
            var d64 = eval_cast[DType.int32, DType.int64](d64_arr)
            return Column.from_primitive[DType.int64](d64)
        elif src_at.is_timestamp() and target == DType.int64 and not target_arrow.is_timestamp():
            # forward: TIMESTAMP_* -> INT64 (relabel only). Guard:
            # target_arrow being a timestamp means a same-physical-type
            # SCALE conversion (handled below by the dedicated arm) — do
            # not pick this arm for `cast(ts[ms] AS ts[us])`.
            var c = child_col^
            c.arrow_type = ArrowType.INT64
            return c^
        elif src_at == ArrowType.INT32 and target_arrow == ArrowType.DATE32:
            # reverse: INT32 -> DATE32 (relabel only)
            var c = child_col^
            c.arrow_type = ArrowType.DATE32
            return c^
        elif src_at == ArrowType.INT64 and target_arrow.is_timestamp():
            # reverse: INT64 -> TIMESTAMP_* (relabel only — values are
            # assumed to be in the target unit; no scale).
            var c = child_col^
            c.arrow_type = target_arrow
            return c^
        elif src_at.is_timestamp() and target_arrow.is_timestamp():
            # SCALE conversion between timestamp units. Source unit from
            # src_at; target unit from target_arrow. Same-unit is a no-op.
            #
            # Validity preservation: eval_mul_scalar / eval_div_scalar return
            # non-nullable PrimitiveArray (validity not propagated by the
            # SIMD kernel). Use `clone_array_validity` to carry the input
            # null mask onto the output. Same shape as int64_to_float64 in
            # compiler_helpers.
            var factor = _ts_unit_factor(src_at, target_arrow)
            if factor == 0:
                # same-unit no-op
                var c = child_col^
                c.arrow_type = target_arrow
                return c^
            var arr = child_col.as_primitive[DType.int64]()
            if factor > 0:
                # source unit < target unit (coarser -> finer): multiply.
                var scaled = eval_mul_scalar[DType.int64](arr, Scalar[DType.int64](factor))
                clone_array_validity[DType.int64, DType.int64](arr, scaled)
                var out = Column.from_primitive[DType.int64](scaled)
                out.arrow_type = target_arrow
                return out^
            else:
                # source unit > target unit (finer -> coarser): divide.
                # Truncation toward zero (same as DuckDB).
                var scaled = eval_div_scalar[DType.int64](arr, Scalar[DType.int64](-factor))
                clone_array_validity[DType.int64, DType.int64](arr, scaled)
                var out = Column.from_primitive[DType.int64](scaled)
                out.arrow_type = target_arrow
                return out^
        # --- STRING <-> numeric ---
        # `_try` forwards the TRY_CAST flag so an
        # unparseable row yields NULL (try) vs RAISES (strict CAST).
        elif src_at == ArrowType.STRING and target == DType.int64:
            var sa = string_array_of(child_col)
            var arr = cast_string_to_int64(sa, expr.cast_is_try())
            return Column.from_primitive[DType.int64](arr)
        elif src_at == ArrowType.STRING and target == DType.int32:
            var sa = string_array_of(child_col)
            var arr = cast_string_to_int32(sa, expr.cast_is_try())
            return Column.from_primitive[DType.int32](arr)
        elif src_at == ArrowType.STRING and target == DType.float64:
            var sa = string_array_of(child_col)
            var arr = cast_string_to_float64(sa, expr.cast_is_try())
            return Column.from_primitive[DType.float64](arr)
        elif src_at == ArrowType.STRING and target == DType.float32:
            var sa = string_array_of(child_col)
            var arr = cast_string_to_float32(sa, expr.cast_is_try())
            return Column.from_primitive[DType.float32](arr)
        elif src_at == ArrowType.INT64 and target_arrow == ArrowType.STRING:
            var pa = child_col.as_primitive[DType.int64]()
            var sa = cast_int64_to_string(pa)
            return Column.from_string(sa)
        elif src_at == ArrowType.INT32 and target_arrow == ArrowType.STRING:
            var pa = child_col.as_primitive[DType.int32]()
            var sa = cast_int32_to_string(pa)
            return Column.from_string(sa)
        elif src_at == ArrowType.FLOAT64 and target_arrow == ArrowType.STRING:
            var pa = child_col.as_primitive[DType.float64]()
            var sa = cast_float64_to_string(pa)
            return Column.from_string(sa)
        elif src_at == ArrowType.FLOAT32 and target_arrow == ArrowType.STRING:
            var pa = child_col.as_primitive[DType.float32]()
            var sa = cast_float32_to_string(pa)
            return Column.from_string(sa)
        elif ArrowType.from_dtype(target) == src_at:
            # No-op cast (target physical type == source type)
            return child_col^
        else:
            raise Error(
                "PipelineCompiler: unsupported EXPR_CAST from "
                + String(src_at) + " to " + String(ArrowType.from_dtype(target))
            )

    elif expr.tag == EXPR_WHEN:
        # CASE WHEN ... THEN ... ELSE ... END
        # Scalar evaluation: for each row, evaluate conditions in order.
        # Return the value of the first matching condition (or otherwise).
        #
        # This is per-row branching. SIMD CASE/WHEN is a future
        # optimization.
        return _eval_when_expr(expr, batch)

    elif expr.tag == EXPR_IN_LIST:
        # IN-list projection arm. EXPR_IN_LIST has a predicate-context arm
        # in `compiler_eval_predicate._eval_predicate` and needs this
        # projection-context one too
        # dispatch — when the optimizer hoists an IN-list predicate into
        # a `with_column`/projection (or when the SDK's `_eval_column_expr`
        # is reached via `_eval_short_circuit_and`/`_eval_short_circuit_or`
        # while materializing an OR-tree containing IN-list branches),
        # the projection path raised "unsupported projection expression
        # tag: 9". This arm delegates to the same typed kernel as the
        # predicate path (`_eval_in_list`) and boxes the resulting
        # BooleanArray as a Bool Column. Identical semantics to the
        # predicate-context call site; cost is one extra BooleanArray ->
        # Column wrapping (zero-copy, just a Column header construction).
        var ba = _eval_in_list(expr, batch)

        # ⛔ THE NULL CONTRACT LIVES IN `_eval_in_list`, NOT HERE. Re-imposing
        # the child's validity on a copy of the answer here, on the
        # argument that the FILTER context does not need it — "`NULL IN (...)` is
        # UNKNOWN, which does not select" — is false twice: a NULL row would
        # answer a definite FALSE there, which `NOT` selects (`WHERE NOT (k IN
        # (1, 2))`: DuckDB 1 row), and a NULL row whose raw payload
        # equalled a member would answer TRUE (`WHERE k IN (0, 1)` over the parquet
        # decode's 0-filled slot). One mechanism, at the one dispatcher both
        # contexts call; it also answers a NULL MEMBER (`x IN (1, NULL)`).
        # Falsifier: `tests/test_in_list_null_contract.mojo`.
        return Column.from_boolean(ba^)

    elif expr.tag == EXPR_STRING_OP:
        # ★ `contains` / `starts_with` / `ends_with` / `like` IN PROJECTION
        # CONTEXT.
        #
        # ⚠ THIS IS NOT A THEORETICAL SHAPE. It is reached (a) whenever CSE
        # hoists a duplicated `LIKE` / `starts_with` subtree into a synthetic
        # projection — the same route that made `EXPR_IN_LIST` need this arm
        # in — and (b) by any `SELECT starts_with(s, 'x')`, which
        # the SQL binder can now write.
        #
        # Delegates to the SAME kernel the predicate context uses, so the two
        # cannot disagree about which rows MATCH.
        #
        # ★ A COMPUTED OPERAND (`lower(s) LIKE 'a%'`, SQL `ILIKE`;
        # is materialized ONCE here and both the match bits and the
        # validity below are read off that one column — calling
        # `_eval_predicate` and then re-deriving the validity would evaluate
        # the operand twice.
        if not expr_resolves_to_column(expr.string_op_child_ref()):
            var sop_computed = _eval_column_expr(expr.string_op_child_ref(), batch)
            var sop_cba = _eval_string_op_on_column(
                sop_computed, expr.string_op_type(), expr.string_op_pattern()
            )
            if sop_computed._validity:
                for r in range(batch.num_rows()):
                    if not sop_computed._validity.value().test(r):
                        sop_cba._set_null(r)
            return Column.from_boolean(sop_cba^)
        var sop_ba = _eval_predicate(expr, batch)

        # ⛔ BUT THE TWO CONTEXTS DISAGREE ABOUT NULL, AND ONLY ONE OF THEM IS
        # ALLOWED TO. The pattern kernels take `(length, offsets, data)` and
        # never see a validity bitmap, so a NULL row is matched as the EMPTY
        # STRING — which answers FALSE for `starts_with(NULL,'he')` and TRUE
        # for `starts_with(NULL,'')`.
        #
        # In a PREDICATE that is right: under SQL 3VL an UNKNOWN does not
        # select, so false-for-null is the correct row set either way. In a
        # PROJECTION it is a WRONG ANSWER — DuckDB v1.5.3 returns NULL for
        # both (measured: `starts_with('hello',NULL)` and
        # `starts_with(NULL,'he')` are both NULL) — and `starts_with(NULL,'')`
        # is the case where the divergence flips the value rather than merely
        # narrowing it.
        #
        # So the projection arm re-imposes the child's validity. This is not a
        # second kernel and cannot drift from the first: the DATA bits are
        # whatever `_eval_predicate` produced, and only the VALIDITY is added.
        var sop_idx = resolve_col_index(expr.string_op_child_ref(), batch.schema)
        ref sop_col = batch.column_at(sop_idx)
        if sop_col._validity:
            var sop_rows = batch.num_rows()
            for r in range(sop_rows):
                if not sop_col._validity.value().test(r):
                    sop_ba._set_null(r)
        return Column.from_boolean(sop_ba^)

    elif expr.tag == EXPR_REGEXP:
        # regexp_like (-> Bool column) /
        # regexp_extract (-> Utf8 column) / regexp_match /
        # regexp_split_to_array / regexp_extract_all (-> List<Utf8> column).
        # regexp_replace has its own arm.  The pattern is a plan-literal; we
        # compile the NFA once here per batch (once per plan is a later step —
        # see the breadcrumb in regexp_functions.mojo).  The child resolves
        # to a STRING / DICTIONARY column via `resolve_col_index` (handles
        # both EXPR_COL_REF and EXPR_COL_IDX — same dance as the
        # EXPR_STRING_OP predicate arm).
        var rop = expr.regexp_op()
        var col_idx = resolve_col_index(expr.regexp_child_ref(), batch.schema)
        ref col_ptr = batch.column_at(col_idx)
        var src_at = col_ptr.arrow_type
        # RXCENSUS: per-BATCH, not per-row. What was
        # never written down is HOW MANY batches this arm sees, which is the
        # denominator of both "compile once per plan" and "widen the memo".
        rxcensus_add(RXC_ARM_CALLS, 1)
        if src_at == ArrowType.DICTIONARY:
            rxcensus_add(RXC_ARM_DICT, 1)
        if src_at != ArrowType.STRING and src_at != ArrowType.DICTIONARY:
            raise Error("PipelineCompiler: regexp_* require a STRING or DICTIONARY column, got " + String(src_at))
        var sarr: StringArray[HeapRegion]
        if src_at == ArrowType.DICTIONARY:
            sarr = _materialize_dict_to_string(col_ptr)
        else:
            # Lane G: `as_string`'s values, Arc-shared where it can be.
            sarr = string_array_of(col_ptr)
        # `g` (replace-all) is not a pattern flag — split it out before
        # compiling.  It is only meaningful for regexp_replace; for the other
        # ops it is harmless to strip (and `RegexProgram.compile` would accept
        # it anyway).
        var gsplit = split_g_flag(expr.regexp_flags())
        var pattern_flags = gsplit[0]
        var replace_all = gsplit[1]
        # `regexp_full_match` wraps the user pattern in `\A(?:...)\z` (the RE2
        # `FullMatch` desugaring); every other op compiles the pattern as-is.
        var prog: RegexProgram
        rxcensus_add(RXC_PROG_COMPILES, 1)
        if rop == REGEXP_FULL_MATCH:
            prog = compile_full_match_program(expr.regexp_pattern(), pattern_flags)
        else:
            prog = RegexProgram.compile(expr.regexp_pattern(), pattern_flags)
        if rop == REGEXP_LIKE:
            return Column.from_boolean(eval_regexp_like(sarr, prog))
        elif rop == REGEXP_FULL_MATCH:
            return Column.from_boolean(eval_regexp_full_match(sarr, prog))
        elif rop == REGEXP_EXTRACT:
            # By-name extract: `regexp_extract(s, pattern, group="name")` — the
            # pattern is only compiled here (execution time), so the name→index
            # resolution happens now.  An unknown name is a hard error (matches
            # DuckDB rejecting a bad named-group reference).
            var gname = expr.regexp_group_name()
            if gname.byte_length() > 0:
                var gidx = prog.group_index_for_name(gname)
                if gidx < 0:
                    raise Error("PipelineCompiler: regexp_extract: no named capture group '" + gname + "' in pattern \"" + expr.regexp_pattern() + "\"")
                return Column.from_string(eval_regexp_extract(sarr, prog, gidx))
            return Column.from_string(eval_regexp_extract(sarr, prog, expr.regexp_group()))
        elif rop == REGEXP_SUBSTR:
            return Column.from_string(eval_regexp_substr(sarr, prog))
        elif rop == REGEXP_REPLACE:
            return Column.from_string(eval_regexp_replace(sarr, prog, expr.regexp_replacement(), replace_all))
        elif rop == REGEXP_COUNT:
            return Column.from_primitive[DType.int64](eval_regexp_count(sarr, prog))
        elif rop == REGEXP_INSTR:
            return Column.from_primitive[DType.int64](eval_regexp_instr(sarr, prog))
        elif rop == REGEXP_MATCH:
            return Column.from_list(eval_regexp_match(sarr, prog))
        elif rop == REGEXP_SPLIT_TO_ARRAY:
            return Column.from_list(eval_regexp_split_to_array(sarr, prog))
        elif rop == REGEXP_EXTRACT_ALL:
            return Column.from_list(eval_regexp_extract_all(sarr, prog, expr.regexp_group()))
        else:
            raise Error("PipelineCompiler: unsupported regexp op " + String(Int(rop)))

    elif expr.tag == EXPR_SUBSTRING:
        # Substring: `substring(s, start, length)` over a
        # STRING / DICTIONARY child -> a STRING column. The child is evaluated
        # recursively (so a bare col-ref OR a nested string expr both work), then
        # each row's value is sliced per SQL semantics; NULL input -> NULL output.
        # Lane G L2: a column-reference child is read in place (see the
        # `EXPR_STRING_FN` arm below and `try_share_string_col_ref`).
        var sarr: StringArray[HeapRegion]
        var sub_shared = try_share_string_col_ref(expr.substring_child_ref(), batch)
        if sub_shared:
            sarr = sub_shared.take()
        else:
            var child_col = _eval_column_expr(expr.substring_child_ref(), batch)
            var src_at = child_col.arrow_type
            if src_at != ArrowType.STRING and src_at != ArrowType.DICTIONARY:
                raise Error("PipelineCompiler: substring() requires a STRING or DICTIONARY column, got " + String(src_at))
            if src_at == ArrowType.DICTIONARY:
                sarr = _materialize_dict_to_string(child_col)
            else:
                sarr = string_array_of(child_col)
        var start = expr.substring_start()
        var length = expr.substring_length()
        var n = batch.num_rows()
        # ⚠ `List[List[UInt8]]` + `from_byte_lists`, NOT `List[String]` +
        # `from_strings`. This arm USED the latter and that is one of the
        # three defects `_sql_substring_bytes` fixes: the round trip through
        # `String` re-encodes every byte >= 0x80. See that kernel's docstring.
        var out_bytes = List[List[UInt8]](capacity=n)
        var validity = Bitmap.create_all_valid(n)
        var null_count = 0
        for i in range(n):
            if sarr.is_null(i):
                # A NULL ROW STILL APPENDS A SLOT — the offset buffer is built
                # from this list, so skipping the append shifts every later
                # row. The validity bit is what makes the row null.
                out_bytes.append(List[UInt8]())
                validity.clear(i)
                null_count += 1
                continue
            out_bytes.append(_sql_substring_bytes(sarr.get(i), start, length))
        var out_sa = StringArray.from_byte_lists(out_bytes)
        if null_count > 0:
            out_sa.validity = validity^
            out_sa.null_count = null_count
        return Column.from_string(out_sa^)

    elif expr.tag == EXPR_STRING_FN:
        # the unary scalar string functions over a
        # STRING / DICTIONARY child. The child is evaluated recursively (so a
        # bare col-ref OR a nested string expr both work); NULL in -> NULL out,
        # which is DuckDB's answer for every member of this family.
        #
        # ⭐ A COLUMN-REFERENCE CHILD IS READ IN PLACE. The child
        # used to go through `_eval_column_expr` -> `copy_column` and then
        # `as_string` — two full copies of `url` on cbq27 to feed a kernel
        # that only reads it. `try_share_string_col_ref` returns an Arc share
        # of the batch column exactly where that pair is provably equal to one
        # (its docstring lists the gate); anything else takes the old path.
        var sfn_sa: StringArray[HeapRegion]
        var sfn_shared = try_share_string_col_ref(
            expr.string_fn_child_ref(), batch
        )
        if sfn_shared:
            sfn_sa = sfn_shared.take()
        else:
            var sfn_child = _eval_column_expr(expr.string_fn_child_ref(), batch)
            var sfn_at = sfn_child.arrow_type
            if sfn_at != ArrowType.STRING and sfn_at != ArrowType.DICTIONARY:
                raise Error(
                    "PipelineCompiler: string function requires a STRING or"
                    + " DICTIONARY column, got " + String(sfn_at)
                )
            if sfn_at == ArrowType.DICTIONARY:
                sfn_sa = _materialize_dict_to_string(sfn_child)
            else:
                sfn_sa = string_array_of(sfn_child)
        var sfn_op = expr.string_fn_op()
        var sfn_n = batch.num_rows()

        # ★ THE INT64-RETURNING MEMBERS LEAVE HERE, BEFORE THE BYTE BUILDER.
        # `string_fn_returns_int` is the single place that answers "what type
        # does this op emit" (`expr.mojo`), and it is read HERE, in
        # `_infer_expr_field`, in `compiler_helpers.field_for_expr` and in
        # `compute_project._is_string_fn_output`. Branching on the OP rather
        # than assuming the family's Utf8 default is what lets `length` ride
        # this tag at all; assuming it would emit a STRING column holding a
        # decimal rendering of the count, which is a wrong ANSWER and a wrong
        # TYPE at once.
        if string_fn_returns_int(sfn_op):
            # ⚠ FIVE MEMBERS, AND THE THREE LENGTH-SHAPED ONES ARE THREE
            # DIFFERENT FUNCTIONS. MEASURED on DuckDB v1.5.3 over `'héllo'`:
            # `length` = 5 (CHARACTERS), `strlen` = 6 (BYTES), `bit_length` =
            # 48 (bytes * 8). All three agree on every ASCII input, so the
            # arms below are only distinguishable by a non-ASCII fixture.
            if (
                sfn_op != STRFN_LENGTH
                and sfn_op != STRFN_ASCII
                and sfn_op != STRFN_UNICODE
                and sfn_op != STRFN_STRLEN
                and sfn_op != STRFN_BIT_LENGTH
            ):
                raise Error(
                    "PipelineCompiler: string function op "
                    + String(Int(sfn_op))
                    + " is declared INT64-returning by string_fn_returns_int"
                    + " but has no kernel arm"
                )
            # ⭐ THE VALIDITY DECISION IS MADE ONCE, NOT ONCE PER ROW, AND
            # A NON-NULLABLE INPUT PRODUCES A COLUMN WITH NO BITMAP AT ALL.
            # This is the same contract the `EXPR_SUBSTRING` arm 40 lines
            # above already keeps (`if null_count > 0: out_sa.validity = ...`)
            # — an output carries a validity buffer only when a null actually
            # reached it. The INT64 arm did not, and the cost was FOUR
            # separate whole-column memory passes per chunk for a column that
            # can never hold a null:
            #
            #   1. `allocate_nullable` -> `buf.zero` over 8 * rows bytes
            #      (a dead store: the loop below writes every element), plus
            #      `Bitmap.create_all_valid` over rows/8 bytes;
            #   2. per row, `sfn_sa.is_null(i)` -- an `Optional[Bitmap]` test
            #      and a bitmap read;
            #   3. per row, `PrimitiveArray.set` -> `if self.validity` ->
            #      `is_null(index)` (a SECOND bitmap read) -> `_set_valid`
            #      (a bitmap read-MODIFY-WRITE) -- setting a bit that
            #      `create_all_valid` had already set;
            #   4. `Column.from_primitive`, which MEMCPYS the whole 8 * rows
            #      data buffer and the bitmap into fresh buffers.
            #
            # MEASURED on ClickBench Q27 (`avg(length(url))` over
            # 99,929,734 rows, `sample` profile): `PrimitiveArray::_set_valid` alone carried
            # 2,352 of ~33,000 non-idle samples -- 7.1% of every working
            # CPU-second the query spends -- and `_eval_column_expr` (which
            # inlines the two `is_null`s and the row loop) carried 10,693,
            # the largest working symbol in the profile by 1.6x.
            #
            # ⚠ THE GATE IS THE PRESENCE OF A BITMAP, NOT `null_count == 0`.
            # A stale `null_count` on an input that does carry cleared bits
            # would silently turn SQL NULLs into values; `Bool(validity)` can
            # only ever cost us the fast path, never correctness. Parquet's
            # dense BYTE_ARRAY decode attaches no bitmap at all when
            # `all_pages_all_valid` (`column_decoder.mojo:2107`), which is why
            # this gate fires on a zero-null OPTIONAL column.
            var sfn_in_nullable = Bool(sfn_sa.validity)
            var len_arr: PrimitiveArray[DType.int64]
            if sfn_in_nullable:
                len_arr = PrimitiveArray[DType.int64].allocate_nullable(sfn_n)
            else:
                # Every branch of every op ladder below writes element `i`
                # unconditionally when the input is non-nullable, so the fill
                # is total and `allocate_uninitialized`'s contract holds.
                len_arr = PrimitiveArray[
                    DType.int64
                ].allocate_uninitialized(sfn_n)
            var len_nulls = 0
            # ⭐ THE OP DISPATCH IS HOISTED OUT OF THE ROW LOOP, AND NO ARM
            # BUILDS A `String`. Both halves matter and the second is the one
            # that was worth 40% of ClickBench Q27:
            #
            #   * `sfn_sa.get(i)` returns an OWNING `String` — per row, a
            #     `List[UInt8]` heap allocation, a byte-at-a-time
            #     `ByteView.copy_to`, a null terminator, a SECOND heap
            #     allocation + memcpy inside `String(unsafe_from_utf8_ptr=)`,
            #     then two frees. Over 99,929,734 rows of `url` (7.43 GB
            #     uncompressed) that copies the whole column TWICE to read each
            #     byte once.
            #   * `sfn_sa.get_span(i)` is the zero-copy companion
            #     (`string_array.mojo`): a BORROWED `Span[UInt8]` over the
            #     Arrow data buffer, compiler-tracked origin, no allocation.
            #     It is the same move the `regexp_*` kernels and the mixed agg
            #     fold make.
            #
            # Over the 100M-row ClickBench hits fixture, `sum(strlen(url))` minus
            # `count(*) WHERE url <> ''` — the String construction with the
            # arithmetic controlled away, since `strlen` is O(1) once the
            # `String` exists — cost about 1.4 s; DuckDB's same delta is a few
            # ms, because its `string_t` points into the Parquet page it
            # already decompressed and is never copied.
            if sfn_op == STRFN_STRLEN or sfn_op == STRFN_BIT_LENGTH:
                # ⛔ THE BYTE COUNT, NEVER `_utf8_char_count`. The whole point
                # of these two members is that they are BYTES where `length`
                # is CHARACTERS (measured on DuckDB v1.5.3: `strlen('héllo')`
                # = 6, `length('héllo')` = 5, `bit_length('héllo')` = 48).
                # They agree on every ASCII input, so a fixture without a
                # multi-byte codepoint cannot separate the implementations.
                #
                # ⭐ AND THE BYTE COUNT IS `offsets[i+1] - offsets[i]`, so
                # `get_length` answers it WITHOUT TOUCHING THE DATA BUFFER AT
                # ALL — no span, no read, no cache line. This arm is now pure
                # offset arithmetic.
                var bl_scale = Int64(1)
                if sfn_op == STRFN_BIT_LENGTH:
                    bl_scale = Int64(8)
                for i in range(sfn_n):
                    if sfn_in_nullable and sfn_sa.is_null(i):
                        len_arr.validity.value().clear(i)
                        len_nulls += 1
                    else:
                        len_arr.set(
                            i, bl_scale * Int64(sfn_sa.get_length(i))
                        )
            elif sfn_op == STRFN_LENGTH:
                for i in range(sfn_n):
                    if sfn_in_nullable and sfn_sa.is_null(i):
                        len_arr.validity.value().clear(i)
                        len_nulls += 1
                    else:
                        len_arr.set(
                            i, Int64(_utf8_char_count(sfn_sa.get_span(i)))
                        )
            elif sfn_op == STRFN_ASCII or sfn_op == STRFN_UNICODE:
                # ⚠ THE TWO DISAGREE ON THE EMPTY STRING AND NOWHERE ELSE.
                # MEASURED: `ascii('')` = 0, `unicode('')` = -1. Folding them
                # into one arm is correct precisely because that one value is
                # the entire difference, and it is passed in.
                var cp_empty = 0
                if sfn_op == STRFN_UNICODE:
                    cp_empty = -1
                for i in range(sfn_n):
                    if sfn_in_nullable and sfn_sa.is_null(i):
                        len_arr.validity.value().clear(i)
                        len_nulls += 1
                    else:
                        len_arr.set(
                            i,
                            Int64(
                                _utf8_first_codepoint(
                                    sfn_sa.get_span(i), cp_empty
                                )
                            ),
                        )
            else:
                # ⚠ UNREACHABLE — the membership guard above already refused
                # any other op by name. Restated here so the hoisted ladder is
                # exhaustive on its own terms rather than by reading upward.
                raise Error(
                    "PipelineCompiler: string function op "
                    + String(Int(sfn_op))
                    + " is declared INT64-returning by string_fn_returns_int"
                    + " but has no kernel arm"
                )
            len_arr.null_count = len_nulls
            # ⭐ `_shared` CONSUMES `len_arr` AND ARC-SHARES ITS BUFFERS; the
            # borrowing `from_primitive` MEMCPYS them. `len_arr` is a fresh
            # local built three lines up and never read again, which is
            # exactly the caller shape `from_primitive_shared` documents. Over
            # cbq27's 99,929,734 rows that copy is 800 MB of pointless DRAM
            # traffic per pass (read + write), on top of the `buf.zero` the
            # `allocate_uninitialized` above already retires.
            return Column.from_primitive_shared[DType.int64](len_arr^)
        # ⚠ `List[List[UInt8]]`, NOT `List[String]`. `StringArray.from_strings`
        # round-trips every value through a `String` and expands any byte
        # >= 0x80 into a multi-byte UTF-8 sequence; `from_byte_lists` is the
        # byte-faithful companion. The SUBSTRING arm above was the standing
        # counter-example when this comment was written — it used
        # `from_strings` and corrupted non-ASCII — and it was converted to
        # this same pairing so both arms agree now.
        var sfn_out = List[List[UInt8]](capacity=sfn_n)
        var sfn_validity = Bitmap.create_all_valid(sfn_n)
        var sfn_nulls = 0
        for i in range(sfn_n):
            if sfn_sa.is_null(i):
                # ⚠ A NULL ROW STILL APPENDS A VALUE. `StringArray.from_strings`
                # builds the offset buffer from this list, so skipping the
                # append would shift every later row's offsets by one and
                # produce a column whose NON-null values are wrong — the
                # validity bit is what makes the row NULL, not the absence of
                # a slot. Same shape as the SUBSTRING arm above.
                sfn_out.append(List[UInt8]())
                sfn_validity.clear(i)
                sfn_nulls += 1
                continue
            if sfn_op == STRFN_UPPER:
                sfn_out.append(unicode_upper_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_LOWER:
                sfn_out.append(unicode_lower_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_TRIM:
                sfn_out.append(
                    _trim_space_bytes(sfn_sa.get(i), True, True)
                )
            elif sfn_op == STRFN_LTRIM:
                sfn_out.append(
                    _trim_space_bytes(sfn_sa.get(i), True, False)
                )
            elif sfn_op == STRFN_RTRIM:
                sfn_out.append(
                    _trim_space_bytes(sfn_sa.get(i), False, True)
                )
            elif sfn_op == STRFN_REVERSE:
                sfn_out.append(_reverse_codepoints_bytes(sfn_sa.get(i)))
            # -- The byte-transform members.
            # ⚠ EXACT against DuckDB v1.5.3 on non-ASCII too, unlike the four
            # case/whitespace members above, because DuckDB defines these on
            # the UTF-8 BYTES as well. See the kernels for the measurements.
            elif sfn_op == STRFN_HEX:
                sfn_out.append(_hex_string_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_BIN:
                sfn_out.append(_bin_string_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_URL_ENCODE:
                sfn_out.append(_url_encode_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_URL_DECODE:
                # ⚠ THE ONLY RAISING KERNEL IN THIS LADDER. DuckDB raises on a
                # decode that yields invalid UTF-8 and so does this; emitting
                # the bytes anyway would put an unexportable value in a STRING
                # column.
                sfn_out.append(_url_decode_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_REGEXP_ESCAPE:
                sfn_out.append(regexp_escape_bytes(sfn_sa.get(i)))
            # -- Digests: LOWERCASE hex over the UTF-8 BYTES.
            # ⛔ LOWERCASE, where `STRFN_HEX` five lines up is UPPERCASE — the
            # two families share this ladder and nothing else. The three
            # widths (32 / 40 / 64 characters) differ, so a mis-dispatch here
            # cannot produce a plausible value of the right shape.
            elif sfn_op == STRFN_MD5:
                sfn_out.append(md5_hex_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_SHA1:
                sfn_out.append(sha1_hex_bytes(sfn_sa.get(i)))
            elif sfn_op == STRFN_SHA256:
                sfn_out.append(sha256_hex_bytes(sfn_sa.get(i)))
            else:
                # ⚠ REFUSED BY NAME, never defaulted to a neighbour. An op
                # that reaches here is one `string_fn_returns_int` classified
                # as Utf8-returning and that has no kernel — a wiring gap, and
                # the only safe answer is to say so.
                raise Error(
                    "PipelineCompiler: unsupported string function op "
                    + String(Int(sfn_op))
                )
        var sfn_arr = StringArray.from_byte_lists(sfn_out)
        if sfn_nulls > 0:
            sfn_arr.validity = sfn_validity^
            sfn_arr.null_count = sfn_nulls
        return Column.from_string(sfn_arr^)

    elif expr.tag == EXPR_STRING_FN_N:
        # the MULTI-ARGUMENT string functions.
        # Every argument is an ordinary expression evaluated to a full column,
        # so `concat(upper(a), lit('-'), b)` composes with no special case.
        #
        # ⛔ THE THREE NULL RULES ARE NOT SHARED. `concat` SKIPS nulls and
        # never returns one; `concat_ws` propagates a null SEPARATOR and skips
        # null VALUES; everything else propagates any null. Each is applied in
        # its own block below — do not hoist a common "any arg null -> null"
        # pre-pass over this arm, which is the refactor that would silently
        # make `concat('a',NULL)` NULL instead of `'a'`.
        var sfnn_op = expr.string_fn_n_op()
        var sfnn_nargs = expr.string_fn_n_num_args()
        if not string_fn_n_arity_ok(sfnn_op, sfnn_nargs):
            # ⚠ REFUSED AGAINST `string_fn_n_arity`, THE ONE TABLE, rather
            # than against a count written here. The binder, the SDK surface
            # and the wire decoder all check the same table; this is the
            # backstop that makes a node any of them mis-built LOUD.
            raise Error(
                "PipelineCompiler: "
                + string_fn_n_name(sfnn_op)
                + "() got " + String(sfnn_nargs)
                + " argument(s); string_fn_n_arity says "
                + String(string_fn_n_arity(sfnn_op))
                + " (negative = variadic floor, 0 = unknown op)"
            )
        var sfnn_rows = batch.num_rows()

        # ---- LPAD / RPAD / REPEAT: slot 1 is a COUNT, not a string --------
        #
        # ⚠ THE THREE ARE SPLIT INTO TWO BLOCKS BY ARITY, NOT MERGED BEHIND A
        # `has_pad` FLAG. Merging needs a placeholder `StringArray` for the
        # pad `repeat` does not have, and constructing an empty one is a
        # raising call that exists only to be ignored — a value carried solely
        # so a branch can avoid being written.
        if sfnn_op == STRFNN_REPEAT:
            var rp_subj = _sfnn_string_arg(expr, 0, batch)
            var rp_cnt = _sfnn_count_arg(expr, 1, sfnn_op, batch)
            var rp_out = List[List[UInt8]](capacity=sfnn_rows)
            var rp_validity = Bitmap.create_all_valid(sfnn_rows)
            var rp_nulls = 0
            for i in range(sfnn_rows):
                if rp_subj.is_null(i) or rp_cnt.is_null(i):
                    # ⚠ A NULL ROW STILL APPENDS A VALUE — the offset buffer
                    # is built from this list, so skipping the append shifts
                    # every later row's offsets and corrupts the NON-null
                    # values. The validity bit is what makes a row NULL.
                    rp_out.append(List[UInt8]())
                    rp_validity.clear(i)
                    rp_nulls += 1
                    continue
                rp_out.append(
                    _repeat_bytes(
                        rp_subj.get(i),
                        Int(rp_cnt.get(i)),
                        STRING_FN_N_REPEAT_MAX_BYTES,
                    )
                )
            var rp_arr = StringArray.from_byte_lists(rp_out)
            if rp_nulls > 0:
                rp_arr.validity = rp_validity^
                rp_arr.null_count = rp_nulls
            return Column.from_string(rp_arr^)

        if sfnn_op == STRFNN_LPAD or sfnn_op == STRFNN_RPAD:
            var pd_subj = _sfnn_string_arg(expr, 0, batch)
            var pd_cnt = _sfnn_count_arg(expr, 1, sfnn_op, batch)
            var pd_pad = _sfnn_string_arg(expr, 2, batch)
            var pd_out = List[List[UInt8]](capacity=sfnn_rows)
            var pd_validity = Bitmap.create_all_valid(sfnn_rows)
            var pd_nulls = 0
            for i in range(sfnn_rows):
                if (
                    pd_subj.is_null(i)
                    or pd_cnt.is_null(i)
                    or pd_pad.is_null(i)
                ):
                    pd_out.append(List[UInt8]())
                    pd_validity.clear(i)
                    pd_nulls += 1
                    continue
                # ⛔ `_pad_bytes` RAISES on an empty pad that is actually
                # NEEDED, which is DuckDB's `Insufficient padding in LPAD.`
                # verbatim. It is a REFUSAL and not a pass-through; see the
                # kernel's four measured corners.
                pd_out.append(
                    _pad_bytes(
                        pd_subj.get(i),
                        Int(pd_cnt.get(i)),
                        pd_pad.get(i),
                        sfnn_op == STRFNN_LPAD,
                    )
                )
            var pd_arr = StringArray.from_byte_lists(pd_out)
            if pd_nulls > 0:
                pd_arr.validity = pd_validity^
                pd_arr.null_count = pd_nulls
            return Column.from_string(pd_arr^)

        # ---- Everything else: every argument is a STRING -------------------
        var sfnn_args = List[StringArray[HeapRegion]](capacity=sfnn_nargs)
        for ai in range(sfnn_nargs):
            sfnn_args.append(_sfnn_string_arg(expr, ai, batch))

        if string_fn_n_returns_float(sfnn_op):
            # THE FLOAT64-RETURNING MEMBERS LEAVE
            # HERE, the exact shape of the INT64 arm directly below.
            #
            # ⛔ THIS ARM IS FIRST, AND THAT IS DELIBERATE RATHER THAN
            # ARBITRARY: `walk_expr_field` asks `returns_int` first and
            # `returns_float` second, so if the two ever disagreed about an op
            # the SCHEMA and the DATA would pick different types. They cannot —
            # `string_fn_n_type_is_coherent` says no op is named by both, and
            # `test_string_fn_n_float_family.mojo` asserts it over the whole
            # declared range — but putting the arms in the OPPOSITE order here
            # is what makes a violation loud (a declared-vs-actual type
            # mismatch the projection test catches) instead of quiet (both
            # sites happening to agree on int).
            #
            # ⚠ A MEMBER DECLARED FLOAT64 AND GIVEN NO ARM IS REFUSED BY NAME,
            # never dropped into the byte builder — the same rule the INT64 arm
            # states: a wrong TYPE is worse than a failed query.
            if (
                sfnn_op != STRFNN_JARO
                and sfnn_op != STRFNN_JARO_WINKLER
                and sfnn_op != STRFNN_JACCARD
            ):
                raise Error(
                    "PipelineCompiler: "
                    + string_fn_n_name(sfnn_op)
                    + "() is declared FLOAT64-returning by"
                    + " string_fn_n_returns_float but has no kernel arm"
                )
            var sim_arr = PrimitiveArray[DType.float64].allocate_nullable(
                sfnn_rows
            )
            var sim_nulls = 0
            for i in range(sfnn_rows):
                if sfnn_args[0].is_null(i) or sfnn_args[1].is_null(i):
                    # ⚠ THE NULL ROW IS NOT LENGTH-CHECKED, and that matters
                    # for `jaccard` alone — it RAISES on an empty operand, and
                    # a row with nothing to compare has no length to be too
                    # short. Checking first would turn `jaccard(v, NULL)` into
                    # a failed query where DuckDB answers NULL (measured).
                    sim_arr.validity.value().clear(i)
                    sim_nulls += 1
                elif sfnn_op == STRFNN_JARO:
                    sim_arr.set(
                        i,
                        _jaro_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        ),
                    )
                elif sfnn_op == STRFNN_JARO_WINKLER:
                    sim_arr.set(
                        i,
                        _jaro_winkler_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        ),
                    )
                else:
                    sim_arr.set(
                        i,
                        _jaccard_bytes(
                            sfnn_args[0].get(i), sfnn_args[1].get(i)
                        ),
                    )
            # ⚠ `null_count` IS SET UNCONDITIONALLY AND THE VALIDITY BITMAP IS
            # KEPT EVEN AT ZERO NULLS — byte-for-byte the INT64 arm's
            # convention below. A "drop the bitmap when nothing is null"
            # optimisation here would be a SECOND opinion about what an
            # all-valid nullable column looks like, in the one family where two
            # arms build the same shape.
            sim_arr.null_count = sim_nulls
            return Column.from_primitive[DType.float64](sim_arr)

        if string_fn_n_returns_int(sfnn_op):
            # ★ THE INT64-RETURNING MEMBERS LEAVE HERE, BEFORE THE BYTE
            # BUILDER — the `STRFN_LENGTH` shape one family up.
            #
            # ⚠ FOUR MEMBERS NOW, NOT ONE, AND THE BRANCH IS ON
            # `string_fn_n_returns_int` RATHER THAN ON `== STRFNN_STRPOS`.
            # That is the same single-source-of-truth the unary family uses:
            # a member declared INT64-returning and given no arm here must be
            # REFUSED BY NAME rather than fall through into the byte builder,
            # which would hand the caller a Utf8 column where the schema
            # promised an INT64 — a wrong TYPE, not merely a wrong value.
            if (
                sfnn_op != STRFNN_STRPOS
                and sfnn_op != STRFNN_LEVENSHTEIN
                and sfnn_op != STRFNN_DAMERAU_LEVENSHTEIN
                and sfnn_op != STRFNN_HAMMING
            ):
                raise Error(
                    "PipelineCompiler: "
                    + string_fn_n_name(sfnn_op)
                    + "() is declared INT64-returning by"
                    + " string_fn_n_returns_int but has no kernel arm"
                )
            var sp_arr = PrimitiveArray[DType.int64].allocate_nullable(
                sfnn_rows
            )
            var sp_nulls = 0
            for i in range(sfnn_rows):
                if sfnn_args[0].is_null(i) or sfnn_args[1].is_null(i):
                    # ⚠ A NULL ROW IS NOT LENGTH-CHECKED, and that matters for
                    # `hamming` alone: it RAISES on unequal lengths, and a row
                    # with nothing to compare has no length to disagree about.
                    # Checking first would turn `hamming(v, NULL)` into a
                    # failed query where DuckDB answers NULL.
                    sp_arr.validity.value().clear(i)
                    sp_nulls += 1
                elif sfnn_op == STRFNN_STRPOS:
                    sp_arr.set(
                        i,
                        Int64(
                            _strpos_chars(
                                sfnn_args[0].get(i), sfnn_args[1].get(i)
                            )
                        ),
                    )
                elif sfnn_op == STRFNN_LEVENSHTEIN:
                    sp_arr.set(
                        i,
                        Int64(
                            _levenshtein_bytes(
                                sfnn_args[0].get(i), sfnn_args[1].get(i)
                            )
                        ),
                    )
                elif sfnn_op == STRFNN_DAMERAU_LEVENSHTEIN:
                    sp_arr.set(
                        i,
                        Int64(
                            _damerau_levenshtein_bytes(
                                sfnn_args[0].get(i), sfnn_args[1].get(i)
                            )
                        ),
                    )
                else:  # STRFNN_HAMMING — the only member that can RAISE
                    sp_arr.set(
                        i,
                        Int64(
                            _hamming_bytes(
                                sfnn_args[0].get(i), sfnn_args[1].get(i)
                            )
                        ),
                    )
            sp_arr.null_count = sp_nulls
            return Column.from_primitive[DType.int64](sp_arr)

        var sfnn_out = List[List[UInt8]](capacity=sfnn_rows)
        var sfnn_validity = Bitmap.create_all_valid(sfnn_rows)
        var sfnn_nulls = 0
        for i in range(sfnn_rows):
            if sfnn_op == STRFNN_CONCAT:
                # ⛔ NO NULL CHECK, AND THAT IS THE SEMANTICS. Measured on
                # DuckDB v1.5.3: `concat('a',NULL,'c')` = 'ac' and
                # `concat(NULL,NULL)` = '' — the EMPTY STRING, not NULL. A
                # null argument contributes nothing and the row stays valid.
                var cc = List[UInt8]()
                for ai in range(sfnn_nargs):
                    if sfnn_args[ai].is_null(i):
                        continue
                    var piece = sfnn_args[ai].get(i).as_bytes()
                    for j in range(len(piece)):
                        cc.append(piece[j])
                sfnn_out.append(cc^)
                continue

            if sfnn_op == STRFNN_CONCAT_WS:
                # TWO rules in one function: a NULL SEPARATOR nulls the row,
                # a NULL VALUE is skipped ALONG WITH ITS SEPARATOR — measured
                # `concat_ws('-','a',NULL,'c')` = 'a-c' (ONE dash).
                if sfnn_args[0].is_null(i):
                    sfnn_out.append(List[UInt8]())
                    sfnn_validity.clear(i)
                    sfnn_nulls += 1
                    continue
                var sep = sfnn_args[0].get(i).as_bytes()
                var cw = List[UInt8]()
                var wrote = False
                for ai in range(1, sfnn_nargs):
                    if sfnn_args[ai].is_null(i):
                        continue
                    if wrote:
                        for j in range(len(sep)):
                            cw.append(sep[j])
                    var piece2 = sfnn_args[ai].get(i).as_bytes()
                    for j in range(len(piece2)):
                        cw.append(piece2[j])
                    wrote = True
                sfnn_out.append(cw^)
                continue

            # REPLACE — and every future member whose rule is "any null in,
            # null out". The check is written here rather than hoisted so the
            # two blocks above keep their own, different, rules.
            var any_null = False
            for ai in range(sfnn_nargs):
                if sfnn_args[ai].is_null(i):
                    any_null = True
                    break
            if any_null:
                sfnn_out.append(List[UInt8]())
                sfnn_validity.clear(i)
                sfnn_nulls += 1
                continue
            if sfnn_op == STRFNN_REPLACE:
                sfnn_out.append(
                    _replace_bytes(
                        sfnn_args[0].get(i),
                        sfnn_args[1].get(i),
                        sfnn_args[2].get(i),
                    )
                )
            elif sfnn_op == STRFNN_TRANSLATE:
                # ⛔ CHARACTER-based, unlike `replace` one line up, which is
                # byte-based. Both are 3-ary and both take the null rule
                # above; they agree on nothing else.
                sfnn_out.append(
                    _translate_chars(
                        sfnn_args[0].get(i),
                        sfnn_args[1].get(i),
                        sfnn_args[2].get(i),
                    )
                )
            else:
                # ⚠ REFUSED BY NAME, never defaulted onto a neighbour. An op
                # reaching here is one `string_fn_n_returns_int` classified as
                # Utf8-returning that has no kernel — a wiring gap, and saying
                # so is the only safe answer.
                raise Error(
                    "PipelineCompiler: unsupported multi-argument string"
                    + " function op " + String(Int(sfnn_op))
                    + " (" + string_fn_n_name(sfnn_op) + ")"
                )
        var sfnn_arr = StringArray.from_byte_lists(sfnn_out)
        if sfnn_nulls > 0:
            sfnn_arr.validity = sfnn_validity^
            sfnn_arr.null_count = sfnn_nulls
        return Column.from_string(sfnn_arr^)

    elif expr.tag == EXPR_UDF_CALL:
        # READ the UDF's output, which the SDK has
        # already materialized onto this batch. This arm calls no thunk and
        # touches no registry.
        #
        # ★ WHY THE EVALUATOR DOES NOT RUN THE UDF ITSELF. The thunk lives in
        # `UdfRegistry` (`komira_engine_operators`), and that package DEPENDS
        # on this one — so reaching it from here is a package CYCLE, measured
        # off the build graph. The SDK, which can see both, runs every
        # UDF call in the tree and appends its output under a name BOTH sides
        # derive from `udf_call_column_key`. Neither side spells the name.
        #
        # ⛔ A MISSING COLUMN IS A REFUSAL, NEVER A FALLBACK. If the producer
        # missed this node the lookup fails here and says so. That is the whole
        # reason the producer is allowed to be a hand-written walk: its
        # incompleteness surfaces as a loud error, not a wrong value. Do NOT
        # "fix" this arm by evaluating the child and passing it through — the
        # UDF would silently become the identity function.
        var udf_key = udf_call_column_key(expr)
        var udf_found = -1
        for ui in range(batch.schema.num_columns()):
            if batch.schema.field_name(ui) == udf_key:
                udf_found = ui
                break
        if udf_found < 0:
            raise Error(
                "PipelineCompiler: the UDF `"
                + expr.udf_call_name()
                + "` was not materialized onto this batch. ⛔ This means the"
                + " plan reached an evaluator through a route that does not"
                + " run the SDK's UDF pre-pass"
                + " (`udf_expr_execution.materialize_udf_columns`) — NOT that"
                + " the UDF is wrong. Every route that can carry an"
                + " EXPR_UDF_CALL must run it first"
            )
        return copy_column(batch, udf_found)

    else:
        raise Error("PipelineCompiler: unsupported projection expression tag: " + String(Int(expr.tag)))
