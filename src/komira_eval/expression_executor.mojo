# =============================================================================
# komira_eval.expression_executor — row-mode expression executor.
#
# The production runtime Expr walker over the `RuntimeExpr` POD tree,
# dispatching comptime-if arms on EXPR_* tags into `binary_select_col_lit` /
# `binary_select_col_col` from `sel_kernels`.
#
# `select_expression_adaptive(mut batch, mut fs)` flattens the root-AND chain
# into a list of predicate indices, evaluates them in the order returned by
# `fs.conjunction_state.adaptive.get_permutation()`, and drives
# `begin_filter()` / `end_filter()` around the loop so the AdaptiveFilter state
# machine converges on the lowest-mean ordering.
#
# Structure
# ---------
#   - `ExpressionState.temp_left_sel: RowSelectionVector` — per-node scratch
#     selection vector. AND nodes hold the LEFT child's surviving rows in it
#     while the RIGHT child is evaluated against them. Allocated at
#     `__init__` (2048 capacity), reused across `select_expression` calls.
#   - `ExpressionExecutor._temp_false_sel` — shared scratch for the false_sel
#     side of every comparison.
#   - `ExpressionExecutor._identity_sel` — pre-allocated buffer for the
#     initial input selection, filled with `[0, 1, ..., num_rows-1]` at the
#     top of `select_expression`.
#   - Walker body: recursive `_eval_bool` taking `idx`, `ref state`,
#     `ref input_sel`, `mut output_sel`. Dispatches on `pool[idx].kind` via
#     a comptime-if chain into:
#       * `binary_select_col_lit[T, op]` for Col-vs-Lit comparisons.
#       * `binary_select_col_col[T, op]` for Col-vs-Col comparisons.
#       * Recursive descent for `EXPR_AND` (left → state.temp_left_sel →
#         right → output_sel).
#   - Identity-sel-in fast path: when `input_sel.len() == col.length`, the
#     called sel_kernel takes the SIMD unit-stride path. The walker's entry
#     point ensures the FIRST conjunct's input_sel IS identity (sized to
#     batch.num_rows()).
#
# Why state ownership matters
# ---------------------------
# This executor takes ownership of the AST pool ONCE at construction and walks
# it from `root_idx` by tag dispatch on the hot path (`select_expression`).
# Per-call scratch sel vectors live on FilterState / as stack-locals; the
# identity sel comes from the static `IDENTITY_SELECTION` table. No per-node
# state tree is allocated.
#
# Destroy-recreate safety
# -----------------------
# The executor's heap-owning fields are `expression_pool: List[RuntimeExpr]`
# and the `List`-backed sidecar pools (`column_names`, `string_pool`,
# `decimal_pool`, `in_list_pool`). No byte-slab + wildcard cast, so there is
# no stale-pointer hazard across destroy and recreate.
# =============================================================================

from std.math import sqrt, sin, cos, asin, atan2, pi, ceil, floor

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import (
    decimal_add_i128,
    decimal_add_result_ps,
    decimal_div_i128,
    decimal_div_result_ps,
    decimal_mul_i128,
    decimal_mul_result_ps,
    decimal_sub_i128,
    pow10_i256,
    rescale_i256_half_up,
)
# The compiled
# Thompson-NFA / Pike-VM program is the SAME leaf the column oracle
# (`regexp_functions.eval_regexp_like` / `regexp_like_scalar`) uses. The
# per-cell EXPR_REGEXP walker arm reuses `regexp_like_scalar(text, prog)` so the
# row path is value-identical to the column oracle, NOT a reimplementation.
from komira_column_kernels.regexp_nfa import RegexProgram
from komira_column_kernels.regexp_functions import regexp_like_scalar
from komira_column_kernels.string_comparison import like_match_string
# ⛔ `EXPR_POW_F64` GOES THROUGH `libm_pow`, NEVER THROUGH `**`. Mojo's `**` on
# a binary64 pair is an approximate exp2/log2 kernel — measured ~196,000 ulps
# off libm, where DuckDB matches libm to the last bit. The three arms below and
# the column kernel in `komira_column_kernels.scalar_math` are FOUR evaluators
# of ONE SQL op, so they share one named kernel rather than four spellings that
# can drift; the full measurement lives on `libm_pow`.
from komira_column_kernels.scalar_math import libm_pow, _apply_unary
from komira_scalar_arithmetic.int_overflow import checked_add, checked_sub, checked_mul
from komira_kernels.runtime_expr import (
    EXPR_ADD_DECIMAL128,
    EXPR_ADD_F64,
    EXPR_ADD_I32,
    EXPR_ADD_I64,
    EXPR_AND,
    EXPR_COL,
    EXPR_COL_BOOL,
    EXPR_COL_DECIMAL128,
    EXPR_IN_LIST,
    EXPR_DIV_DECIMAL128,
    EXPR_DIV_F64,
    EXPR_DIV_I32,
    EXPR_DIV_I64,
    EXPR_EQ_DECIMAL128,
    EXPR_EQ_F64,
    EXPR_LT_F64_MIXED,
    EXPR_LE_F64_MIXED,
    EXPR_GT_F64_MIXED,
    EXPR_GE_F64_MIXED,
    EXPR_EQ_F64_MIXED,
    EXPR_EQ_I64,
    EXPR_GE_DECIMAL128,
    EXPR_GE_F64,
    EXPR_GE_I64,
    EXPR_GT_DECIMAL128,
    EXPR_GT_F64,
    EXPR_GT_I64,
    EXPR_LE_DECIMAL128,
    EXPR_LE_F64,
    EXPR_LE_I64,
    EXPR_LIT_BOOL,
    EXPR_LIT_DECIMAL128,
    EXPR_LIT_F64,
    EXPR_LIT_I32,
    EXPR_LIT_I64,
    EXPR_LT_DECIMAL128,
    EXPR_LT_F64,
    EXPR_LT_I64,
    EXPR_MUL_DECIMAL128,
    EXPR_MUL_F64,
    EXPR_MUL_I32,
    EXPR_MUL_I64,
    EXPR_NEQ_DECIMAL128,
    EXPR_NOT_BOOL,
    EXPR_COL_STRING,
    EXPR_COL_BINARY,
    EXPR_COL_DICTIONARY,
    EXPR_LIT_STRING,
    EXPR_EQ_STRING,
    EXPR_NEQ_STRING,
    EXPR_IS_NULL_STRING,
    EXPR_IS_NOT_NULL_STRING,
    EXPR_GT_STRING,
    EXPR_LT_STRING,
    EXPR_GE_STRING,
    EXPR_LE_STRING,
    EXPR_LIKE_STRING,
    EXPR_REGEXP,
    EXPR_F64_TO_I64,
    EXPR_OR,
    EXPR_SQRT_F64,
    EXPR_SIN_F64,
    EXPR_COS_F64,
    EXPR_ASIN_F64,
    EXPR_RADIANS_F64,
    EXPR_ATAN2_F64,
    EXPR_POW_F64,
    EXPR_MATH_UNARY_F64,
    EXPR_GT_U64,
    EXPR_GE_U64,
    EXPR_LT_U64,
    EXPR_LE_U64,
    EXPR_EQ_U64,
    EXPR_NE_I64,
    EXPR_NE_F64,
    EXPR_NE_U64,
    EXPR_IS_NULL_CELL,
    EXPR_IS_NOT_NULL_CELL,
    EXPR_CASE_I64,
    EXPR_CASE_F64,
    EXPR_NULL,
    EXPR_I64_TO_F64,
    EXPR_EXTRACT_I64,
    RT_EXTRACT_YEAR,
    RT_EXTRACT_QUARTER,
    RT_EXTRACT_MONTH,
    RT_EXTRACT_DAY,
    RT_EXTRACT_HOUR,
    RT_EXTRACT_MINUTE,
    RT_EXTRACT_SECOND,
    RT_EXTRACT_DAYOFWEEK,
    RT_EXTRACT_ISODOW,
    RT_EXTRACT_DAYOFYEAR,
    RT_EXTRACT_WEEK,
    RT_EXTRACT_ISOYEAR,
    RT_EXTRACT_YEARWEEK,
    RT_EXTRACT_MILLISECOND,
    RT_EXTRACT_MICROSECOND,
    EXPR_DATE_TRUNC_I64,
    RT_TRUNC_YEAR,
    RT_TRUNC_QUARTER,
    RT_TRUNC_MONTH,
    RT_TRUNC_WEEK,
    RT_TRUNC_DAY,
    RT_TRUNC_HOUR,
    RT_TRUNC_MINUTE,
    RT_TRUNC_SECOND,
    RT_TRUNC_MILLISECOND,
    RT_TRUNC_MICROSECOND,
    EXPR_SUB_DECIMAL128,
    EXPR_SUB_F64,
    EXPR_SUB_I32,
    EXPR_SUB_I64,
    RuntimeExpr,
)
# ★ THE ONE THING THE ROW TOWER DOES NOT RE-DERIVE. Every other calendar
# helper below is a deliberate local copy (see `_ee_civil_from_days`); this one
# is IMPORTED, because it is a PARITY RULE rather than arithmetic and a second
# copy of it would make a wrong `yearweek` ROUTE-DEPENDENT — the column kernel
# and the row tower answering different numbers for the same instant. It is
# `@always_inline`, so the per-cell walker pays nothing for the import.
from komira_kernels.temporal_extract import compose_yearweek
from komira_eval.filter_state import ConjunctionState, FilterState
from komira_kernels.sel_kernels import (
    BIN_OP_EQ,
    BIN_OP_GE,
    BIN_OP_GT,
    BIN_OP_LE,
    BIN_OP_LT,
    BIN_OP_NE,
    binary_select_col_col,
    binary_select_col_lit,
)
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_buffer.heap_region import HeapRegion
from komira_row_format.cell_source import CellSource


# -----------------------------------------------------------------------------
# EXTRACT — civil-date helpers (Howard Hinnant `civil_from_days`).
# -----------------------------------------------------------------------------
# Self-contained copy of the branch-free Hinnant algorithm (mirrors
# `komira_kernels.temporal_extract._civil_from_days` and the column-engine kernel
# reference). Kept local so the per-cell row walker has no cross-module call
# overhead — the row PROJECT walker invokes this per computed temporal cell.
# Same shape as the copies in the timestamp and JSON writer helpers.


@always_inline
def _ee_div_floor(a: Int, b: Int) -> Int:
    """Floor-division — matches Hinnant's era arithmetic.

    ⛔ THE PARENTHETICAL THAT USED TO BE HERE — "Mojo `//` truncates toward
    zero" — IS FALSE. Measured on Mojo 1.0.0: `-25505 // 7` =
    -3644 and `-25505 % 7` = 3, i.e. FLOOR and floor-mod, for `Int`, `Int64`,
    `Int32` and SIMD alike. This helper is therefore an identity; it is kept
    for the reasons `temporal_extract._div_floor` sets out, and the assumption
    is pinned by a test there rather than asserted in prose here.

    ⛔ `//` IS NOT `/`. Mojo's `/` on an integral type DOES truncate
    (`Scalar[int64](-7) / Scalar[int64](2)` = -3 while `-7 // 2` = -4), so the
    two are NOT interchangeable for a negative dividend."""
    var q = a // b
    var r = a - q * b
    if r != 0 and ((r < 0) != (b < 0)):
        q -= 1
    return q


@always_inline
def _ee_div_trunc[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Scalar[dt]:
    """Integer division that truncates toward zero: the plan's `BIN_DIV`
    (docs/design/query_semantics.md §5.1, DuckDB's `//`: `-7 // 2` is -3).
    Mojo's `//` floors (-4), so the floor quotient moves one step toward zero
    when the division is inexact and the operands' signs differ. The caller
    has refused a zero divisor."""
    var q = a // b
    if q * b != a and ((a < 0) != (b < 0)):
        q += 1
    return q


@always_inline
def _in_list_int_probe(
    x: Int64, vt: List[Int64], ki: Int, vf: List[Float64], kf: Int
) -> Bool:
    """Whether the integer `x` equals an integer entry of `vt`, or, compared
    as Float64, a float entry of `vf` (the IN-list probe of an INT64 or
    INT32 column)."""
    var j = 0
    while j < ki:
        if x == vt[j]:
            return True
        j = j + 1
    if kf > 0:
        var xf = x.cast[DType.float64]()
        j = 0
        while j < kf:
            if xf == vf[j]:
                return True
            j = j + 1
    return False


@always_inline
def _ee_civil_from_days(z: Int) -> Tuple[Int, Int, Int]:
    """Days-since-1970 -> (year, month[1..12], day[1..31]) in the proleptic
    Gregorian calendar. Branch-free scalar arithmetic; no floating point.
    Reference: http://howardhinnant.github.io/date_algorithms.html#civil_from_days
    """
    var z_adj = z + 719468
    var era = _ee_div_floor(z_adj, 146097)
    var doe = z_adj - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m: Int
    if mp < 10:
        m = mp + 3
    else:
        m = mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


@always_inline
def _ee_mod_floor(a: Int, b: Int) -> Int:
    """Floor-mod (matches Python `%`). Used by date_trunc(WEEK) — local copy of
    `temporal_extract._mod_floor` so the per-cell row walker has no cross-module
    call."""
    return a - _ee_div_floor(a, b) * b


@always_inline
def _ee_days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """INVERSE of `_ee_civil_from_days` — (year, month[1..12], day[1..31]) ->
    days-since-1970. Local copy of `temporal_extract._days_from_civil` for the
    date_trunc row walker (rebuild the truncated epoch from the period-start
    civil date)."""
    var y_adj: Int
    if m > 2:
        y_adj = y
    else:
        y_adj = y - 1
    # ⛔⛔ ONE FLOORING DIVIDE. This used to carry the C idiom
    # `(y_adj - 399) // 400`, which recovers a floor from a division that
    # TRUNCATES — and Mojo's `//` already floors, so the correction subtracted
    # a SECOND era and every BC day count came back one day short. Mirrors the
    # same fix in `temporal_extract._days_from_civil`, whose docstring carries
    # the measurement.
    var era = _ee_div_floor(y_adj, 400)
    var yoe = y_adj - era * 400
    var m_off: Int
    if m > 2:
        m_off = m - 3
    else:
        m_off = m + 9
    var doy = (153 * m_off + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


@always_inline
def _ee_quarter_first_month(month: Int) -> Int:
    """First calendar month [1,4,7,10] of the quarter containing `month`
    [1..12]. Mirror of `temporal_extract._quarter_first_month`."""
    return ((month - 1) // 3) * 3 + 1


# -----------------------------------------------------------------------------
# Internal helper — Decimal128 cross-scale-aware compare.
# -----------------------------------------------------------------------------
# Byte-wise lexicographic comparator. Mirrors `sort_lex.mojo:_str_lt`
# style: walks `as_bytes()` of each operand, returns memcmp-style
# Int (<0 / 0 / >0). For valid UTF-8 byte sequences, byte-wise
# lexicographic equals UTF-8 codepoint-lexicographic ordering — this
# is canonical DuckDB / Postgres ORDER BY semantics for non-collated
# String columns. Used by the 4 EXPR_*_STRING compare arms (GT / LT /
# GE / LE) in `_eval_bool_from_view`.
#
# Returns 0 if equal, <0 if a < b, >0 if a > b. Length tie-break:
# shorter prefix sorts first (matches sort_lex._str_lt and memcmp's
# behavior for unequal-length common-prefix sequences).
# -----------------------------------------------------------------------------

@always_inline
def _str_compare(imm a: String, imm b: String) -> Int:
    """Byte-wise lexicographic comparator. Returns 0 / <0 / >0 for
    equal / a<b / a>b. Length tie-break: shorter prefix sorts first.

    Used by the 4 EXPR_*_STRING compare arms in `_eval_bool_from_view`.
    Per-byte loop via `String.as_bytes()`; no reliance on stdlib
    `String.__lt__` / `__gt__`. Mirrors `sort_lex.mojo:_str_lt`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    var m = an if an < bn else bn
    var i = 0
    while i < m:
        var ca = ab[i]
        var cb = bb[i]
        if ca != cb:
            # Byte values differ — return signed difference.
            return Int(ca) - Int(cb)
        i += 1
    # Common prefix equal — shorter sorts first.
    return an - bn


# -----------------------------------------------------------------------------
# Internal helper — SQL LIKE pattern matcher.
# -----------------------------------------------------------------------------
# Iterative two-pointer matcher with backtrack-on-mismatch, mirroring the
# `_like_match` in `komira_eval.expr_x_conformers` for the LikeXString
# conformer, which is covered by unit tests for prefix / suffix / infix /
# exact / underscore / match-all / no-match patterns.
#
# Algorithm: maintain two pointers `vi` (value) + `pi` (pattern) and two
# backtrack pointers `star_v` + `star_p` (position of the last `%` in
# the pattern + the value position we last committed to). On literal /
# underscore match advance both pointers. On `%` mark the backtrack
# position and advance only the pattern pointer. On mismatch:
# (a) if we have a `%` to absorb one more char, backtrack and try; (b)
# else fail.
#
# Pattern semantics (PostgreSQL/MySQL/DuckDB compatible):
#   - `%` matches zero or more CHARACTERS.
#   - `_` matches exactly one CHARACTER (a UTF-8 code point). ⛔ Matching
#     one BYTE would be a wrong answer on every
#     multi-byte string (`'é' LIKE '_'`); see `_string_like_match`.
#   - Any other byte matches itself.
#
# Worst-case O(|value| × |pattern|); best-case O(|value| + |pattern|).
# In practice most real LIKE patterns are short (`%foo%`, `bar%`, `_b_`)
# so the runtime cost is acceptable. Profile-driven Boyer-Moore / KMP
# optimization for hot non-wildcard substring patterns is future work.
#
# Used by the EXPR_LIKE_STRING arm in `_eval_bool_from_view`.
# -----------------------------------------------------------------------------

@always_inline
def _string_like_match(imm text: String, imm pattern: String) -> Bool:
    """SQL LIKE: `%` any run of characters, `_` ONE CHARACTER (a UTF-8 code
    point), everything else literal.

    ⭐ DELEGATES to `komira_column_kernels.string_comparison.like_match_string`, the
    one matcher the columnar kernel also runs, so the row and
    columnar paths cannot disagree. A byte-at-a-time copy of that
    loop ("`_` (one byte)") would answer `'é' LIKE '_'` false over a
    ROW-format source's filter walker and the computed-project
    evaluator. Falsifier: `komira_eval.tests.test_like_underscore_is_one_character`.
    """
    return like_match_string(text, pattern)


# -----------------------------------------------------------------------------
#
# Same-scale
# fast path uses direct i128 compare. Cross-scale rescales the smaller-scale
# operand UP to match the larger scale (lossless when scaling UP — only an
# i128 multiplication by 10^diff). For very large scale differences the
# rescaled magnitude may overflow i128; we promote to i256 to compute the
# unambiguous result, then compare. Used by the 6 EXPR_*_DECIMAL128 compare
# arms in `_eval_bool_from_view`.

@always_inline
def _compare_decimal128(
    a: SIMD[DType.int128, 1], s1: Int,
    b: SIMD[DType.int128, 1], s2: Int,
    op_kind: Int,
) raises -> Bool:
    """Apply op_kind to (a at scale s1, b at scale s2). Returns the
    comparison result.

    Args:
        a: Left i128 unscaled.
        s1: Left scale.
        b: Right i128 unscaled.
        s2: Right scale.
        op_kind: One of EXPR_EQ_DECIMAL128, EXPR_NEQ_DECIMAL128,
                 EXPR_GT_DECIMAL128, EXPR_LT_DECIMAL128,
                 EXPR_GE_DECIMAL128, EXPR_LE_DECIMAL128.

    Returns:
        True if the comparison matches, False otherwise.
    """
    # Same-scale fast path — direct i128 compare.
    if s1 == s2:
        if op_kind == EXPR_EQ_DECIMAL128:
            return Bool(a == b)
        if op_kind == EXPR_NEQ_DECIMAL128:
            return Bool(a != b)
        if op_kind == EXPR_GT_DECIMAL128:
            return Bool(a > b)
        if op_kind == EXPR_LT_DECIMAL128:
            return Bool(a < b)
        if op_kind == EXPR_GE_DECIMAL128:
            return Bool(a >= b)
        return Bool(a <= b)
    # Cross-scale — rescale the smaller-scale side UP. Lossless multiplication
    # via i256 intermediate (covers s1+s2 up to 76 without overflow).
    var a256 = a.cast[DType.int256]()
    var b256 = b.cast[DType.int256]()
    if s1 < s2:
        a256 = a256 * pow10_i256(s2 - s1)
    else:
        b256 = b256 * pow10_i256(s1 - s2)
    if op_kind == EXPR_EQ_DECIMAL128:
        return Bool(a256 == b256)
    if op_kind == EXPR_NEQ_DECIMAL128:
        return Bool(a256 != b256)
    if op_kind == EXPR_GT_DECIMAL128:
        return Bool(a256 > b256)
    if op_kind == EXPR_LT_DECIMAL128:
        return Bool(a256 < b256)
    if op_kind == EXPR_GE_DECIMAL128:
        return Bool(a256 >= b256)
    return Bool(a256 <= b256)


# -----------------------------------------------------------------------------
# DecimalSpec — side-table entry for Decimal128 literals.
# -----------------------------------------------------------------------------
#
# A
# Decimal128 literal carries 3 pieces of metadata: the 128-bit unscaled
# value, the precision (1..38), and the scale (0..precision). The
# fixed-size RuntimeExpr POD has no slot wide enough for i128 storage
# (and adding precision/scale fields would widen POD for ALL nodes
# including non-Decimal ones — wasteful). The side-table on
# ExpressionExecutor (`decimal_pool: List[DecimalSpec]`) stores literals;
# the RuntimeExpr.col_idx is repurposed as the pool index for
# EXPR_LIT_DECIMAL128 (tag-disambiguated from EXPR_COL).
#
# slab-safety audit: DecimalSpec is pure POD (i128 + 2 Ints). No heap-owning
# fields. The List[DecimalSpec] on ExpressionExecutor is structurally
# identical to the existing column_names: List[String] and
# string_pool: List[String] — both of which are slab-safe today (sibling
# argument; the destroy-recreate stress test already exercises this shape).

@fieldwise_init
struct DecimalSpec(Copyable, Movable, ImplicitlyCopyable):
    """One Decimal128 literal: (unscaled value, precision, scale).

    Fields:
        value: 128-bit unscaled integer (logical value = value / 10^scale).
        precision: Total decimal digits (1..38).
        scale: Digits after decimal point (0..precision).
    """
    var value: SIMD[DType.int128, 1]
    var precision: Int
    var scale: Int


# -----------------------------------------------------------------------------
# ExpressionExecutor — row-mode runtime executor.
# -----------------------------------------------------------------------------
#
# Owns:
#   - `expression_pool: List[RuntimeExpr]` — the AoS-as-index-arena that
#     the expression factories produce. Children of binary nodes are
#     referenced by `left` / `right` slot indices into this pool.
#   - `root_idx: Int` — slot index of the root node in `expression_pool`.
#
# Construction is the load-bearing pre-allocation step (
# "Initialize allocates once; the hot path reuses"). After construction,
# `select_expression` is the hot path — it walks `expression_pool` from
# `root_idx` directly (tag-dispatched), allocating nothing on self.
#
# slab-safety audit: `expression_pool` is `List[RuntimeExpr]` where RuntimeExpr
# is a POD (no heap-owning fields); the sidecar pools are `List`-backed.
# No wildcard origins; no byte-slab + wildcard cast. Gap6-safe.

struct ExpressionExecutor(Movable, Deinitable):
    """Row-mode runtime expression executor.

    Owns the AST pool and root index. `select_expression` is the hot-path
    entry point — it walks `expression_pool` from `root_idx` directly via
    tag-dispatch, performing zero per-node heap allocation.

    Fields:
        expression_pool: AoS-as-index-arena from the expression
            factories. Children are referenced by `left` / `right`
            slot indices.
        root_idx: Slot index of the root RuntimeExpr.

    Per-call scratch buffers (identity_sel, temp_false, per-AND left_temp)
    are stack-locals in `select_expression`, not self-fields. Mojo
    1.0.0b1's aliasing detector disallows passing `self._field` as a
    `ref` argument when `self` is `mut` in the same call. The
    adaptive entry points keep their output selection on FilterState,
    where the aliasing concern is resolved differently.
    """

    var expression_pool: List[RuntimeExpr]
    var root_idx: Int
    # Sidecar list of column
    # NAMES referenced by EXPR_COL nodes in `expression_pool`. Indexed
    # by `RuntimeExpr.col_idx` (which is now a slot index into this
    # list, NOT a position in any schema). The walker resolves names
    # to runtime batch column positions via `batch.column_by_name(name)`
    # at evaluation time — robust to projection-pushdown column
    # reordering, which would otherwise misbind positional indices.
    #
    # Destroy-recreate safety: adding `List[String]` to ExpressionExecutor is
    # structurally identical to the existing `expression_pool:
    # List[RuntimeExpr]` field, which passes the destroy-recreate stress
    # today. ExpressionExecutor
    # is `Movable, Deinitable`; its move is bytewise (only
    # the List handle moves, the heap content stays at a stable address).
    # The 100-cycle stress test exercises this on every commit.
    var column_names: List[String]

    # NEW side-table holding interned String LITERAL text referenced by
    # EXPR_LIT_STRING nodes. Indexed by RuntimeExpr.col_idx (REPURPOSED
    # as string-pool index for EXPR_LIT_STRING nodes; tag-disambiguated
    # from EXPR_COL which also uses col_idx as column index). Empty
    # list is valid when the expression tree has no String literals.
    #
    # slab-safety audit (mirrors the existing column_names rationale on that
    # field): adding ONE more `List[String]` field to
    # ExpressionExecutor is structurally identical to column_names; the
    # struct is Movable+Deinitable (bytewise move of the
    # List handle; heap content at stable address). NOT stored inside
    # any byte-slab. slab-safe.
    var string_pool: List[String]

    # NEW side-table holding interned Decimal128 LITERAL (value, precision,
    # scale) referenced by EXPR_LIT_DECIMAL128 nodes. Indexed by
    # RuntimeExpr.col_idx (REPURPOSED — same field, different semantic
    # per kind discrimination — mirrors the EXPR_LIT_STRING pattern).
    # Empty list is valid when the expression tree has no Decimal128
    # literals.
    #
    # slab-safety audit (mirrors string_pool rationale): DecimalSpec is pure
    # POD (i128 + 2 Ints, no heap content); a List[DecimalSpec] on
    # ExpressionExecutor is structurally identical to column_names and
    # string_pool. The struct is Movable+Deinitable (bytewise
    # move of the List handle; heap content at stable address). NOT
    # stored inside any byte-slab. slab-safe.
    var decimal_pool: List[DecimalSpec]

    # Side-table holding the variable-sized `List[ScalarValue]` value
    # tables referenced by EXPR_IN_LIST nodes. Indexed by
    # `RuntimeExpr.col_idx` on EXPR_IN_LIST nodes (REPURPOSED — same
    # field, different semantic per kind discrimination — mirrors the
    # EXPR_LIT_STRING / EXPR_LIT_DECIMAL128 side-pool pattern). Empty
    # list is valid when the expression tree has no IN-list nodes.
    #
    # slab-safety audit (mirrors string_pool / decimal_pool rationale):
    # List[List[ScalarValue]] uses the same Movable handle layout as the
    # sibling pools; the inner List[ScalarValue] is itself slab-safe
    # (ScalarValue is Movable+ImplicitlyCopyable POD per
    # `komira_plan_expr.scalar_value`). The struct as a whole
    # remains Movable+Deinitable (bytewise move of the
    # outer List handle; heap content at stable address). NOT stored
    # inside any byte-slab. slab-safe.
    var in_list_pool: List[List[ScalarValue]]

    # CASE/WHEN — side-table
    # holding the variable-arity branch slot lists for EXPR_CASE_I64 /
    # EXPR_CASE_F64 nodes. Indexed by `RuntimeExpr.col_idx` on a CASE node
    # (REPURPOSED — same field, different semantic per kind discrimination —
    # mirrors the in_list_pool / string_pool side-pool pattern). Each entry is
    # the flattened `[cond0, then0, ..., condK-1, thenK-1, elseSlot]` list (all
    # entries are slot indices into `expression_pool`). Empty list is valid when
    # the expression tree has no CASE nodes.
    #
    # slab-safety audit (mirrors in_list_pool rationale): List[List[Int]] uses the same
    # Movable handle layout as the sibling pools; the inner List[Int] is pure POD.
    # The struct remains Movable+Deinitable; NOT stored inside any
    # byte-slab. slab-safe.
    var when_pool: List[List[Int]]

    # NEW
    # side-table holding the COMPILED `RegexProgram`s referenced by EXPR_REGEXP
    # nodes. Indexed by `RuntimeExpr.col_idx` on an EXPR_REGEXP node (REPURPOSED
    # — same field, different semantic per kind discrimination — mirrors the
    # string_pool / in_list_pool / when_pool side-pool pattern). The program is
    # COMPILED ONCE at segment/executor setup (the column oracle's same
    # "build the RegexProgram once per call" discipline), so the per-cell hot
    # loop only runs `is_match`. Empty list is valid when the expression tree has
    # no regex predicate.
    #
    # slab-safety audit (mirrors in_list_pool rationale): RegexProgram is Movable +
    # Copyable with `List[Inst]` / `List[ByteClass]` / `List[String]` fields —
    # the SAME heap-owning-element shape as `in_list_pool`'s inner
    # `List[ScalarValue]` (which carries a String). A `List[RegexProgram]` on
    # ExpressionExecutor uses the standard Movable List-handle layout (bytewise
    # move of the outer handle; heap content at a stable address). NOT stored
    # inside any byte-slab; the executor stays Movable + Deinitable.
    # slab-safe.
    var regex_pool: List[RegexProgram]

    def __init__(
        out self,
        var pool: List[RuntimeExpr],
        root_idx: Int,
        var column_names: List[String],
        var string_pool: List[String] = List[String](),
        var decimal_pool: List[DecimalSpec] = List[DecimalSpec](),
        var in_list_pool: List[List[ScalarValue]] = List[List[ScalarValue]](),
        var when_pool: List[List[Int]] = List[List[Int]](),
        var regex_pool: List[RegexProgram] = List[RegexProgram](),
    ):
        """Take ownership of the AST pool, root index, and sidecar pools.

        The hot path (`select_expression`) walks `pool` from `root_idx`
        directly via tag-dispatch — no per-node state tree is allocated.

        Bounds-asserted: `root_idx` must be in `[0, len(pool))`.

        Args:
            pool: The RuntimeExpr arena. Consumed take-once via `^`.
            root_idx: Slot index of the root node.
            column_names: Parallel list of column NAMES referenced by
                EXPR_COL nodes (indexed by RuntimeExpr.col_idx). Empty
                list is valid when the predicate has no column refs
                (e.g. literal-folded constants — should not appear in
                practice from the translator).
            string_pool: Side-table holding interned String LITERAL
                text referenced by EXPR_LIT_STRING nodes. Indexed by
                RuntimeExpr.col_idx (REPURPOSED — same field, different
                semantic per kind discrimination). Defaults empty for
                callers that don't carry String literals
                (preserves call-site compatibility with existing
                ExpressionExecutor.new(pool, root_idx, column_names)
                call sites; the translator's caller threads a populated
                string_pool only when the expr tree contains
                EXPR_LIT_STRING nodes).
        """
        debug_assert(
            root_idx >= 0 and root_idx < len(pool),
            "ExpressionExecutor.__init__: root_idx out of pool bounds",
        )
        self.expression_pool = pool^
        self.root_idx = root_idx
        self.column_names = column_names^
        self.string_pool = string_pool^
        self.decimal_pool = decimal_pool^
        self.in_list_pool = in_list_pool^
        self.when_pool = when_pool^
        self.regex_pool = regex_pool^

    def bare_col_name_at(self, expr_idx: Int) -> String:
        """Resolve the column NAME for a bare `EXPR_COL` node at pool slot
        `expr_idx`. Returns "" when `expr_idx` is out of pool bounds, the
        node is NOT a bare `EXPR_COL` leaf, or its `col_idx` falls outside
        `column_names`.

        The runtime-stage dynamic-join-filter
        adapter needs the PROBE join-key column NAME
        so the prepass can attach the filter to the right scan column. The
        fast single-i64 probe builds its key leaf via `make_col(idx)` (a
        bare `EXPR_COL` whose `col_idx` indexes `column_names`); this
        accessor encapsulates that pool walk so the executor's internal
        `expression_pool` / `column_names` lists stay private (no raw
        list/pointer crosses the module boundary).

        Returns "" rather than raising so the caller treats the unresolved
        case as "no filter" — consistent with the legacy op-walker's
        empty-key-name sentinel.
        """
        if expr_idx < 0 or expr_idx >= len(self.expression_pool):
            return String("")
        ref node = self.expression_pool[expr_idx]
        if node.kind != EXPR_COL:
            return String("")
        var ci = node.col_idx
        if ci < 0 or ci >= len(self.column_names):
            return String("")
        return String(self.column_names[ci])

    def select_expression(
        imm self, mut batch: RecordBatch, mut sel: RowSelectionVector
    ) raises -> Int:
        """Walk the AST + write surviving row indices into `sel`.

        Production runtime Expr walker. Reads the AoS-as-index-arena
        `self.expression_pool` from `self.root_idx`, dispatches comptime-
        if-arms on `RuntimeExpr.kind` tags into `binary_select_col_lit` /
        `binary_select_col_col` (sel_kernels) for comparisons, and into
        a recursive descent for `EXPR_AND` conjunctions.

        Contract:
          - The first comparison sees an identity `sel_in` of length
            `batch.num_rows()`, triggering the unit-stride SIMD path in
            sel_kernels. Subsequent conjuncts under an AND take the
            previous level's surviving `true_sel` as their `sel_in`,
            triggering the gather path.
          - The walker writes only the SURVIVING rows into `sel`;
            `_temp_false_sel` collects rejects (discarded).
          - Top-level expression MUST evaluate to Bool (comparison, AND,
            OR — though OR is not served by this walker). A top-level Lit/Col
            raises; that shape doesn't make sense for a filter.

        Identity-sel-in fast path:
          The first call into a comparison sees `sel_in.len() ==
          batch.num_rows()`. sel_kernels detects this and skips the
          gather, taking the unit-stride SIMD branch. Empirically
          measured at ~0.38 ns/row hand-fused / 1.17 ns/row composed on
          M3 Ultra.

        Args:
            batch: The input batch. `mut` so later stages can
                compose with gather_batch / OP_BARRIER_COLUMNARIZE.
            sel: Pre-allocated output selection vector. Caller is
                responsible for sizing it >= batch.num_rows(). The
                walker resets it before writing.

        Returns:
            Number of surviving rows = `sel.len()` after the call.

        Raises:
            Error if the root node has a kind that is not boolean-
            producing (e.g. a Lit or Col at the root), or if any
            comparison's Col operand is missing or has a DType
            inconsistent with the comparison tag.
        """
        var n = batch.num_rows()

        # Size selection vectors to `n` (batch row count).
        # The default `RowSelectionVector()` constructor allocates 2048
        # slots — silently overflows on large batches. The OpFilter
        # morsel-pipeline path is sized for ≤2048 rows per morsel by the
        # morsel sizing policy, so this code path was historically safe
        # in production; this defensive sizing matches the runtime-stage
        # walker's fix (`select_expression_from_view`).

        # Build the identity sel = [0, 1, ..., n-1] used as the input
        # selection for the root expression's first comparison.
        # Stack-local rather than a self-field — Mojo 1.0.0b1 disallows
        # passing `self._identity_sel` as a ref when `self` is also mut
        # in the same call (aliasing-detector trips). Each
        # `select_expression` call allocates one fresh identity sel; the
        # cost (~8 KB raw alloc + identity write loop) is dwarfed by the
        # per-comparison column-copy cost in _dispatch_comparison.
        var identity_sel = RowSelectionVector(n if n > 0 else 1)
        var i = 0
        while i < n:
            identity_sel.append(UInt32(i))
            i += 1

        # Stack-local false-sel scratch (same aliasing argument as above).
        # The conjunction loop doesn't preserve false-sel across
        # siblings; the adaptive entry points keep their state on
        # FilterState.
        var temp_false = RowSelectionVector(n if n > 0 else 1)

        return self._eval_bool(
            batch, self.root_idx, identity_sel, sel, temp_false
        )

    def select_expression_adaptive(
        imm self, mut batch: RecordBatch, mut fs: FilterState
    ) raises -> Int:
        """Adaptive-conjunction walker driven by AdaptiveFilter.

        Like `select_expression` but evaluates the root-AND conjunction in
        the order chosen by `fs.conjunction_state.adaptive.get_permutation()`.
        Drives `begin_filter()` / `end_filter()` around the conjunction
        loop so the AdaptiveFilter state machine converges on the lowest-
        mean predicate ordering for THIS worker.

        Scope:
          - Single root-level AND chain (Q6 shape). Nested ANDs under a
            conjunct fall back to the fixed-order recursive `_eval_bool`
            — nested ANDs could be promoted to their own
            ConjunctionState.
          - For a non-AND root, the AdaptiveFilter sees a single
            `begin_filter`/`end_filter` cycle (n_predicates=1 — no swaps
            possible, state machine is a cheap no-op).

        FilterState contract:
          - `fs.sel` is the output buffer (same as `sel` in
            `select_expression`). The walker writes surviving rows here.
          - `fs.conjunction_state` is always present (a FilterState
            field). For best convergence, callers should construct via
            `FilterState.with_conjunction(n_predicates, worker_id)` so
            the AdaptiveFilter is sized to the actual conjunct count.
            The default FilterState() carries an n_predicates=1 no-op
            ConjunctionState; the adaptive walker raises in that case
            if the flattened conjunct chain has >1 predicates (the
            walker can't reorder against a mismatched-size state
            machine).

        Args:
            batch: The input batch.
            fs: The per-worker FilterState. `sel` is the output buffer;
                `conjunction_state` drives the adaptive permutation.

        Returns:
            Number of surviving rows = `fs.sel.len()` after the call.

        Raises:
            Error on the same conditions as `select_expression`, plus an
            n_predicates mismatch between FilterState's ConjunctionState
            and the executor's flattened AND chain.
        """
        var n = batch.num_rows()

        # Size selection vectors to `n` (see matching fix in
        # `select_expression_from_view` for the root-cause narrative).
        var _cap = n if n > 0 else 1

        # Build the identity sel = [0, 1, ..., n-1].
        var identity_sel = RowSelectionVector(_cap)
        var i = 0
        while i < n:
            identity_sel.append(UInt32(i))
            i += 1

        # Stack-local scratch for inter-conjunct sel chaining.
        var temp_false = RowSelectionVector(_cap)

        # Ensure fs.sel has capacity >= n.
        if fs.sel.capacity() < n:
            fs.sel = RowSelectionVector(_cap)

        # Flatten the root AND chain into a list of predicate slot
        # indices. For a non-AND root, returns [self.root_idx].
        var predicate_indices = _flatten_and_chain(
            self.expression_pool, self.root_idx
        )

        # Borrow the ConjunctionState mutably for begin_filter / end_filter.
        # FilterState carries an OwnedPointer<ConjunctionState>; deref
        # through unsafe_ptr to reach the inner ConjunctionState.
        var cs_ptr = fs.conjunction_state.unsafe_ptr()

        # ---- Hot-path conjunction loop driven by AdaptiveFilter --------
        # The AdaptiveFilter is keyed to `predicate_indices.len()` (we
        # verify that match). begin_filter drives the EXPLORE-phase swap
        # before the loop reads the permutation; end_filter records the
        # measured duration and advances the state machine.
        if cs_ptr[].n_predicates != len(predicate_indices):
            raise Error(
                "ExpressionExecutor.select_expression_adaptive: conjunction"
                " state n_predicates="
                + String(cs_ptr[].n_predicates)
                + " does not match flattened chain length "
                + String(len(predicate_indices))
            )

        # AdaptiveFilter is inline on ConjunctionState; take a pointer
        # to the field for mutable begin/end calls.
        var af_ptr = UnsafePointer(to=cs_ptr[].adaptive)
        var start_ns = af_ptr[].begin_filter()

        # Read the permutation AFTER begin_filter so EXPLORE-phase swaps
        # are visible. The Span returned by get_permutation lives until
        # the next mutation of adaptive.permutation; we copy out the
        # ordered indices to avoid lifetime entanglement with the
        # subsequent end_filter call.
        var permutation = af_ptr[].get_permutation()
        var k_total = len(predicate_indices)
        var ordered = List[Int]()
        for k in range(k_total):
            ordered.append(predicate_indices[Int(permutation[k])])

        # Ping-pong sel-pair: input_sel <-> output_sel. The first conjunct
        # reads from identity_sel (unit-stride SIMD path); subsequent
        # conjuncts read from the prior level's true_sel (gather path).
        # The final survivor count comes back via fs.sel.
        if k_total == 1:
            # Single conjunct — write straight to fs.sel.
            var n_surv = self._eval_bool(
                batch, ordered[0], identity_sel, fs.sel, temp_false
            )
            af_ptr[].end_filter(start_ns)
            return n_surv

        # k_total >= 2: alternate two scratch sels, finishing in fs.sel.
        var scratch_a = RowSelectionVector(_cap)
        var scratch_b = RowSelectionVector(_cap)

        # First conjunct: identity → scratch_a.
        _ = self._eval_bool(
            batch, ordered[0], identity_sel, scratch_a, temp_false
        )

        # Middle conjuncts: alternate between scratch_a and scratch_b.
        # After conjunct j the survivors are in scratch_a if j is odd,
        # in scratch_b if j is even (j starts at 1 for the second
        # conjunct).
        for j in range(1, k_total - 1):
            if j % 2 == 1:
                # scratch_a -> scratch_b
                scratch_b.set_len(0)
                _ = self._eval_bool(
                    batch, ordered[j], scratch_a, scratch_b, temp_false
                )
            else:
                # scratch_b -> scratch_a
                scratch_a.set_len(0)
                _ = self._eval_bool(
                    batch, ordered[j], scratch_b, scratch_a, temp_false
                )

        # Final conjunct: read from whichever scratch holds the prior
        # survivors, write into fs.sel.
        if (k_total - 1) % 2 == 1:
            # After k_total-2 middle iters, the prior survivors are in:
            #   - scratch_a if (k_total-2) is even -> j=k_total-1 reads
            #     scratch_a
            #   - scratch_b if (k_total-2) is odd  -> j=k_total-1 reads
            #     scratch_b
            # For k_total >= 2 the chain is: conj0 -> scratch_a,
            # conj1 -> scratch_b, conj2 -> scratch_a, ...
            # Final conjunct index = k_total - 1. Reads from scratch_a
            # if (k_total-1) is odd (i.e. previous wrote to scratch_a if
            # (k_total-2) is even); reads scratch_b otherwise.
            # k_total=2 → final reads scratch_a (k_total-1=1 odd).
            # k_total=3 → final reads scratch_b (k_total-1=2 even).
            # k_total=4 → final reads scratch_a (k_total-1=3 odd).
            _ = self._eval_bool(
                batch, ordered[k_total - 1], scratch_a, fs.sel, temp_false
            )
        else:
            _ = self._eval_bool(
                batch, ordered[k_total - 1], scratch_b, fs.sel, temp_false
            )

        var n_surv = fs.sel.len()
        af_ptr[].end_filter(start_ns)
        return n_surv

    # =========================================================================
    # select_expression_from_view — BatchView input
    # =========================================================================
    #
    # `select_expression_from_view[bo]` mirrors `select_expression_adaptive`
    # verbatim except for the input parameter type: takes a `BatchView[bo]`
    # (read-only typed borrow) instead of `mut batch: RecordBatch`, for
    # the fused morsel operator's consumer shape.
    #
    # Why a sibling method and NOT a re-targeting of
    # select_expression_adaptive:
    #   - select_expression_adaptive's `mut batch: RecordBatch` is the
    #     stable surface that OpFilter consumes; changing it
    #     would cascade into 5+ callers (OpFilter, plan-compiler, the
    #     the existing executor tests).
    #   - The actual mutation of `batch` is NIL — every callee in
    #     _eval_bool / _dispatch_comparison invokes only read-self
    #     methods on RecordBatch (column_by_name, column_as_primitive_*).
    #   - A sibling method + sibling helpers (_eval_bool_from_view,
    #     _dispatch_comparison_from_view) gives the FusedMorselOp consumer
    #     the BatchView shape it needs without disturbing the existing
    #     row-mode path.
    #
    # The internal helpers (_eval_bool_from_view + _dispatch_comparison_from_view)
    # take a `ref [bo] RecordBatch` instead of `mut batch: RecordBatch`,
    # then call exactly the same read-only batch methods (column_by_name,
    # column_as_primitive_int64/float64/int32). The walker body is a
    # near-1:1 mirror; only the parameter type changes.
    #
    # Encapsulation: NO UnsafePointer in the public surface.
    # The BatchView's `bo: Origin[mut=False]` parameter is the only
    # origin tracked; the per-call deref to `ref [bo] RecordBatch` is
    # consumed locally inside the helper bodies and never escapes.
    # =========================================================================

    def select_expression_from_view[
        bo: Origin[mut=False],
    ](
        imm self, batch_view: BatchView[bo], mut fs: FilterState
    ) raises -> Int:
        """BatchView-borrow entry — adaptive conjunction walker.

        Identical contract + body shape to `select_expression_adaptive`,
        but takes a `BatchView[bo]` (read-only typed borrow) instead of
        a `mut batch: RecordBatch`. The consumer for the
        FusedMorselOp `process_batch[bo](batch: BatchView[bo])` surface
        (see `komira_engine_operators.fused_morsel_op`).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
                The `bo: Origin[mut=False]` parameter pins the source's
                lifetime to the caller's frame.
            fs: The per-worker FilterState. `sel` is the output buffer;
                `conjunction_state` drives the adaptive permutation.

        Returns:
            Number of surviving rows = `fs.sel.len()` after the call.

        Raises:
            Error on the same conditions as `select_expression_adaptive`.
        """
        # Deref the BatchView to a ref [bo] RecordBatch. The deref produces
        # a sub-origin ref consumed locally within this method body; no
        # escape, no lifetime widening.
        ref batch = batch_view._batch[]
        var n = batch.num_rows()

        # Size all selection vectors to `n` (batch row count). The default
        # `RowSelectionVector()` constructor allocates `STANDARD_VECTOR_SIZE
        # = 2048` slots which is insufficient for large post-Parquet-decode
        # batches (e.g. Q6 SF1 = 114,160 rows). The append() bounds-check
        # is debug_assert (elided in release), so overflows silently corrupt
        # adjacent stack memory — fs.sel.len() winds up at `n` but only the
        # first ~2304 entries hold valid indices, with subsequent indices
        # repeating from low values (the next morsel of the batch over-
        # writes the first morsel's stack pad). The runtime stage then
        # gathers DUPLICATE/WRONG rows, producing a wrong aggregate value.
        #
        # The legacy OpFilter on the morsel-pipeline path is sized for ≤2048
        # rows per morsel by the morsel sizing policy, so 2048-capacity sels
        # work there. The runtime-stage path receives the FULL post-concat
        # batch from `materialize_parquet_collect`, which can be far larger.
        # All sel buffers in this walker MUST be sized to `n`.
        #
        # Cost: 5 sels × n × 4 bytes ≈ 2.3 MB at Q6 SF1; cheap vs the
        # ~14 ms Parquet decode that produced the batch.

        # Build the identity sel = [0, 1, ..., n-1]. Stack-local rather
        # than a self-field — Mojo 1.0.0b1's aliasing detector disallows
        # passing `self._field` as a ref when `self` is also mut in the
        # same call.
        var identity_sel = RowSelectionVector(n)
        var i = 0
        while i < n:
            identity_sel.append(UInt32(i))
            i += 1

        # Stack-local scratch for inter-conjunct sel chaining.
        var temp_false = RowSelectionVector(n)

        # Ensure fs.sel has capacity >= n. Default FilterState() and
        # FilterState.with_conjunction() construct fs.sel via the default
        # RowSelectionVector() (capacity 2048). Rebind if too small.
        if fs.sel.capacity() < n:
            fs.sel = RowSelectionVector(n)

        # Flatten the root AND chain into a list of predicate slot indices.
        # For a non-AND root, returns [self.root_idx].
        var predicate_indices = _flatten_and_chain(
            self.expression_pool, self.root_idx
        )

        # Borrow the ConjunctionState mutably for begin_filter / end_filter.
        var cs_ptr = fs.conjunction_state.unsafe_ptr()

        if cs_ptr[].n_predicates != len(predicate_indices):
            raise Error(
                "ExpressionExecutor.select_expression_from_view: conjunction"
                " state n_predicates="
                + String(cs_ptr[].n_predicates)
                + " does not match flattened chain length "
                + String(len(predicate_indices))
            )

        var af_ptr = UnsafePointer(to=cs_ptr[].adaptive)
        var start_ns = af_ptr[].begin_filter()

        var permutation = af_ptr[].get_permutation()
        var k_total = len(predicate_indices)
        var ordered = List[Int]()
        for k in range(k_total):
            ordered.append(predicate_indices[Int(permutation[k])])

        if k_total == 1:
            var n_surv = self._eval_bool_from_view[bo](
                batch, ordered[0], identity_sel, fs.sel, temp_false
            )
            af_ptr[].end_filter(start_ns)
            return n_surv

        # k_total >= 2: alternate two scratch sels, finishing in fs.sel.
        var scratch_a = RowSelectionVector(n)
        var scratch_b = RowSelectionVector(n)

        # First conjunct: identity → scratch_a.
        _ = self._eval_bool_from_view[bo](
            batch, ordered[0], identity_sel, scratch_a, temp_false
        )

        # Middle conjuncts: alternate scratch_a <-> scratch_b.
        for j in range(1, k_total - 1):
            if j % 2 == 1:
                scratch_b.set_len(0)
                _ = self._eval_bool_from_view[bo](
                    batch, ordered[j], scratch_a, scratch_b, temp_false
                )
            else:
                scratch_a.set_len(0)
                _ = self._eval_bool_from_view[bo](
                    batch, ordered[j], scratch_b, scratch_a, temp_false
                )

        # Final conjunct: read from whichever scratch holds the prior
        # survivors, write into fs.sel.
        if (k_total - 1) % 2 == 1:
            _ = self._eval_bool_from_view[bo](
                batch, ordered[k_total - 1], scratch_a, fs.sel, temp_false
            )
        else:
            _ = self._eval_bool_from_view[bo](
                batch, ordered[k_total - 1], scratch_b, fs.sel, temp_false
            )

        var n_surv = fs.sel.len()
        af_ptr[].end_filter(start_ns)
        return n_surv

    def select_expression_from_view_range[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        mut fs: FilterState,
        start: Int,
        length: Int,
    ) raises -> Int:
        """Range-restricted sibling of `select_expression_from_view`.

        Identical conjunction-walker body, but the identity input sel is
        seeded with the half-open row range `[start, start+length)` instead
        of the full batch `[0, n)`. Survivors are reported in ABSOLUTE batch
        row coordinates (the walker only ever copies / filters indices it is
        handed, never re-derives them from 0). The walker is `read self`
        (immutable) — multiple workers may call it concurrently over disjoint
        ranges, each with its OWN FilterState `fs` (its own `sel` output
        buffer + conjunction adaptive state).

        FILTER-PARALLELISM fix (a): this is the per-morsel
        filter entry for the parallel stateless NONE-breaker driver.
        Each worker filters its
        own morsel range so the filter predicate evaluation parallelizes
        across the WorkerPool. Byte-identical to a serial full-batch filter:
        `select_expression_from_view(bv, fs)` ==
        `select_expression_from_view_range(bv, fs, 0, n)` for survivor
        membership + relative order (the walker preserves input-sel order).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            fs: The per-worker FilterState. `sel` is the output buffer;
                `conjunction_state` drives the adaptive permutation.
            start: First absolute row index in this worker's morsel.
            length: Number of rows in this worker's morsel.

        Returns:
            Number of surviving rows in `[start, start+length)` =
            `fs.sel.len()` after the call.
        """
        ref batch = batch_view._batch[]
        var n = batch.num_rows()

        # Clamp the range to the batch bounds defensively.
        var lo = start
        if lo < 0:
            lo = 0
        var hi = start + length
        if hi > n:
            hi = n
        var range_n = hi - lo
        if range_n < 0:
            range_n = 0

        # Identity sel = [lo, lo+1, ..., hi-1] (the morsel's absolute rows).
        # Scratch + output sels are sized to `range_n` (the morsel's row
        # count), NOT the whole batch `n`. The walker only ever filters the
        # indices it is handed; for a range filter that is at most `range_n`
        # identity indices, so every intermediate sel (temp_false / fs.sel /
        # scratch_a / scratch_b) holds at most `range_n` survivors. The
        # nested-AND `left_temp` inside `_eval_bool_from_view` is likewise
        # bounded by the input_sel it receives (<= range_n).
        #
        # FILTER-PARALLELISM fix (a'): sizing these to the whole
        # batch `n` was the regression. The parallel driver calls this ONCE
        # PER MORSEL (e.g. q13 = 1465 morsels over a 1.5M-row batch); n-sizing
        # allocated 2-4 full-batch (~6MB) RowSelectionVectors per call =
        # ~17GB of allocation churn across the run, which swamped the
        # predicate-parallelism win (the parallel filter was SLOWER than the
        # serial whole-batch filter). range_n-sizing makes each per-morsel
        # call allocate ~morsel-sized scratch (a few KB) — the allocation cost
        # is now proportional to the morsel, not the whole batch.
        var range_size = range_n if range_n > 0 else 1
        var identity_sel = RowSelectionVector(range_size)
        var ri = lo
        while ri < hi:
            identity_sel.append(UInt32(ri))
            ri += 1

        var temp_false = RowSelectionVector(range_size)

        if fs.sel.capacity() < range_size:
            fs.sel = RowSelectionVector(range_size)

        var predicate_indices = _flatten_and_chain(
            self.expression_pool, self.root_idx
        )

        var cs_ptr = fs.conjunction_state.unsafe_ptr()
        if cs_ptr[].n_predicates != len(predicate_indices):
            raise Error(
                "ExpressionExecutor.select_expression_from_view_range:"
                " conjunction state n_predicates="
                + String(cs_ptr[].n_predicates)
                + " does not match flattened chain length "
                + String(len(predicate_indices))
            )

        var af_ptr = UnsafePointer(to=cs_ptr[].adaptive)
        var start_ns = af_ptr[].begin_filter()

        var permutation = af_ptr[].get_permutation()
        var k_total = len(predicate_indices)
        var ordered = List[Int]()
        for k in range(k_total):
            ordered.append(predicate_indices[Int(permutation[k])])

        if k_total == 1:
            var n_surv = self._eval_bool_from_view[bo](
                batch, ordered[0], identity_sel, fs.sel, temp_false
            )
            af_ptr[].end_filter(start_ns)
            return n_surv

        var scratch_a = RowSelectionVector(range_size)
        var scratch_b = RowSelectionVector(range_size)

        _ = self._eval_bool_from_view[bo](
            batch, ordered[0], identity_sel, scratch_a, temp_false
        )

        for j in range(1, k_total - 1):
            if j % 2 == 1:
                scratch_b.set_len(0)
                _ = self._eval_bool_from_view[bo](
                    batch, ordered[j], scratch_a, scratch_b, temp_false
                )
            else:
                scratch_a.set_len(0)
                _ = self._eval_bool_from_view[bo](
                    batch, ordered[j], scratch_b, scratch_a, temp_false
                )

        if (k_total - 1) % 2 == 1:
            _ = self._eval_bool_from_view[bo](
                batch, ordered[k_total - 1], scratch_a, fs.sel, temp_false
            )
        else:
            _ = self._eval_bool_from_view[bo](
                batch, ordered[k_total - 1], scratch_b, fs.sel, temp_false
            )

        var n_surv = fs.sel.len()
        af_ptr[].end_filter(start_ns)
        return n_surv

    def _eval_bool_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
        mut temp_false: RowSelectionVector,
    ) raises -> Int:
        """BatchView-borrow sibling of `_eval_bool`.

        Identical recursive-walker shape; takes a `ref [bo] RecordBatch`
        instead of `mut batch: RecordBatch`. The recursive descent for
        EXPR_AND, the comparison dispatch table, and the unsupported-kind
        diagnostics all mirror `_eval_bool` verbatim.
        """
        var node = self.expression_pool[idx]
        var kind = node.kind

        if kind == EXPR_AND:
            var left_idx = node.left
            var right_idx = node.right
            # Size `left_temp` to the batch row count, NOT the default 2048.
            # The LEFT child's SIMD identity fast path
            # (`binary_select_col_lit` -> `_emit_lane_writes` ->
            # `append_vec_first_k`) writes up to `col.length == n_rows`
            # survivor indices. The append-overflow guard is a debug_assert
            # (elided in release), so a default-2048 `left_temp` silently
            # writes-after-free into freed+recycled tcmalloc memory once a
            # nested AND (e.g. `(A & B) | (C & D)` — the Q7 cross-pair
            # filter, whose OR root is NOT flattened by `_flatten_and_chain`,
            # so the nested AND is evaluated HERE) runs on a >2048-row batch.
            # Mirrors the same n-sizing the top-level walker already applies
            # to identity_sel / temp_false / scratch_a / scratch_b.
            var n_left = batch.num_rows()
            var left_temp = RowSelectionVector(n_left if n_left > 0 else 1)
            _ = self._eval_bool_from_view[bo](
                batch, left_idx, input_sel, left_temp, temp_false
            )
            return self._eval_bool_from_view[bo](
                batch, right_idx, left_temp, output_sel, temp_false
            )

        if kind == EXPR_GT_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_GT
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_GE_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_GE
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_LT_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_LT
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_EQ_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_EQ
            ](batch, node, idx, input_sel, output_sel, temp_false)
        # F2 numeric NE: EXPR_NE_I64 routes through the sel-kernel
        # BIN_OP_NE path (sibling of EXPR_EQ_I64).
        if kind == EXPR_NE_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_NE
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_GT_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_GT
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_GE_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_GE
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_LT_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_LT
            ](batch, node, idx, input_sel, output_sel, temp_false)
        if kind == EXPR_LE_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_LE
            ](batch, node, idx, input_sel, output_sel, temp_false)
        # sibling to EXPR_LE_F64 / EXPR_LT_I64. Routes to the existing
        # `_dispatch_comparison_from_view[..., DType.int64, BIN_OP_LE]`
        # helper (sel_kernels already cover BIN_OP_LE for every primitive
        # DType — only the expr-catalog leaf was missing).
        if kind == EXPR_LE_I64:
            return self._dispatch_comparison_from_view[
                bo, DType.int64, BIN_OP_LE
            ](batch, node, idx, input_sel, output_sel, temp_false)
        # sibling to EXPR_EQ_I64 / EXPR_LE_F64. Routes to the existing
        # `_dispatch_comparison_from_view[..., DType.float64, BIN_OP_EQ]`
        # helper. Unblocks Q15-shape `WHERE total_revenue = max_revenue`.
        if kind == EXPR_EQ_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_EQ
            ](batch, node, idx, input_sel, output_sel, temp_false)
        # F2 numeric NE: EXPR_NE_F64 routes through the sel-kernel
        # BIN_OP_NE path (sibling of EXPR_EQ_F64).
        if kind == EXPR_NE_F64:
            return self._dispatch_comparison_from_view[
                bo, DType.float64, BIN_OP_NE
            ](batch, node, idx, input_sel, output_sel, temp_false)

        # F64-vs-I64 implicit-widen compare.
        # Pre-eval both children via the F64 walker (which transparently
        # widens i64 columns / i64 literals to Float64 — see EXPR_COL
        # widening + EXPR_LIT_I64 widening in that walker) and
        # run scalar compare per row. Serves the
        # `part_value > __scalar_subq_0` shape where the optimizer
        # cannot insert EXPR_CAST (no such tag in the runtime walker).
        if (
            kind == EXPR_LT_F64_MIXED
            or kind == EXPR_LE_F64_MIXED
            or kind == EXPR_GT_F64_MIXED
            or kind == EXPR_GE_F64_MIXED
            or kind == EXPR_EQ_F64_MIXED
        ):
            var n_sel = input_sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            # `eval_to_list_f64_from_view` takes a BatchView; construct
            # one from the ref-batch parameter.
            var bv = batch_view_over(batch)
            self.eval_to_list_f64_from_view[bo](
                bv, node.left, input_sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                bv, node.right, input_sel, rhs_vals
            )
            output_sel.set_len(0)
            if len(lhs_vals) != n_sel or len(rhs_vals) != n_sel:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_*_F64_MIXED child row-count mismatch (lhs="
                    + String(len(lhs_vals))
                    + " rhs="
                    + String(len(rhs_vals))
                    + " sel="
                    + String(n_sel)
                    + ")"
                )
            # The F64 walker reads a NULL cell's stored value; a row whose
            # either operand is NULL is UNKNOWN and is not emitted.
            var null_at = List[Bool](length=n_sel, fill=False)
            self._mark_value_nulls_from_view[bo](
                batch, node.left, input_sel, null_at
            )
            self._mark_value_nulls_from_view[bo](
                batch, node.right, input_sel, null_at
            )
            var k = 0
            while k < n_sel:
                if null_at[k]:
                    k = k + 1
                    continue
                # Extract raw Float64 values from the Scalar[F64] wrappers
                # to guarantee a primitive Bool comparison result (avoid
                # the SIMD[bool, 1] mask path).
                var lv = Float64(lhs_vals[k])
                var rv = Float64(rhs_vals[k])
                var matched: Bool
                if kind == EXPR_LT_F64_MIXED:
                    matched = lv < rv
                elif kind == EXPR_LE_F64_MIXED:
                    matched = lv <= rv
                elif kind == EXPR_GT_F64_MIXED:
                    matched = lv > rv
                elif kind == EXPR_GE_F64_MIXED:
                    matched = lv >= rv
                else:  # EXPR_EQ_F64_MIXED
                    matched = lv == rv
                if matched:
                    output_sel.append(input_sel.get(k))
                k = k + 1
            return output_sel.len()

        # Bool column primitives. EXPR_COL_BOOL is a leaf that reads a
        # BooleanArray directly + emits the rows of `input_sel` whose cell is
        # present and true into `output_sel` (a NULL cell is UNKNOWN, whatever
        # bit it stores). EXPR_NOT_BOOL keeps the rows where its child is
        # FALSE under three-valued logic (`_eval_kleene_from_view`).
        # EXPR_LIT_BOOL at root passes all rows (if True) or none (if False).
        if kind == EXPR_COL_BOOL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var bool_arr = batch.column_as_boolean(runtime_idx)
            output_sel.set_len(0)
            var n_sel = input_sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(input_sel.get(k))
                if not bool_arr.is_null(row) and bool_arr.get(row):
                    output_sel.append(UInt32(row))
                k = k + 1
            return output_sel.len()

        if kind == EXPR_LIT_BOOL:
            # Literal True at root: pass all input rows through.
            # Literal False at root: pass zero rows.
            output_sel.set_len(0)
            if node.b:
                var n_sel = input_sel.len()
                var k = 0
                while k < n_sel:
                    output_sel.append(input_sel.get(k))
                    k = k + 1
            return output_sel.len()

        if kind == EXPR_NOT_BOOL:
            # SQL NOT keeps a row only where its child is FALSE: a row where
            # the child is UNKNOWN (a NULL operand) stays out under the
            # negation too. The child's three-valued value is computed per
            # `input_sel` position, so the selection's order does not matter.
            var n_sel = input_sel.len()
            var child = List[UInt8](capacity=n_sel)
            self._eval_kleene_from_view[bo](
                batch, node.left, input_sel, child, temp_false
            )
            output_sel.set_len(0)
            var k = 0
            while k < n_sel:
                if child[k] == _KLEENE_FALSE:
                    output_sel.append(input_sel.get(k))
                k = k + 1
            return output_sel.len()

        # String EQ / NEQ filter arms. Both children resolve to
        # EXPR_COL_STRING (read StringArray.get(row) per row) or
        # EXPR_LIT_STRING (read string_pool[col_idx] once, broadcast).
        # Per-row String comparison via Mojo stdlib `==` / `!=`
        # (byte-wise UTF-8 equality). v1 cost: per-row String copy
        # from StringArray.get(idx); a borrowed-span read would
        # remove the copy.
        if kind == EXPR_EQ_STRING or kind == EXPR_NEQ_STRING:
            var left_node = self.expression_pool[node.left]
            var right_node = self.expression_pool[node.right]
            # Resolve left side: either a column (read StringArray) or
            # a literal (read string_pool once).
            var left_is_col = left_node.kind == EXPR_COL_STRING
            var right_is_col = right_node.kind == EXPR_COL_STRING
            if not left_is_col and left_node.kind != EXPR_LIT_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_EQ_STRING/EXPR_NEQ_STRING left operand must be"
                    " EXPR_COL_STRING or EXPR_LIT_STRING (kind="
                    + String(left_node.kind) + ")"
                )
            if not right_is_col and right_node.kind != EXPR_LIT_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_EQ_STRING/EXPR_NEQ_STRING right operand must be"
                    " EXPR_COL_STRING or EXPR_LIT_STRING (kind="
                    + String(right_node.kind) + ")"
                )

            output_sel.set_len(0)
            var n_sel = input_sel.len()
            var is_eq = kind == EXPR_EQ_STRING

            # SQL WHERE three-valued logic: any row where either operand
            # is NULL produces "unknown" and is EXCLUDED from output_sel
            # (consistent with WHERE col == 'x' / col != 'x' in DuckDB
            # and Postgres). `StringArray.is_null(row)` short-circuits
            # via the all-valid fast path when validity bitmap is None.
            if left_is_col and right_is_col:
                # col == col / col != col — read both sides per row.
                var left_col_name = self.column_names[left_node.col_idx]
                var right_col_name = self.column_names[right_node.col_idx]
                var l_idx = batch.column_by_name(left_col_name)
                var r_idx = batch.column_by_name(right_col_name)
                var l_arr = batch.column_as_string(l_idx)
                var r_arr = batch.column_as_string(r_idx)
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if either side is NULL.
                    if l_arr.is_null(row) or r_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get(row)
                    var rv = r_arr.get(row)
                    var matched = lv == rv
                    if is_eq:
                        if matched:
                            output_sel.append(UInt32(row))
                    else:
                        if not matched:
                            output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif left_is_col and not right_is_col:
                # col == lit / col != lit — read col per row, lit once.
                var left_col_name = self.column_names[left_node.col_idx]
                var l_idx = batch.column_by_name(left_col_name)
                var l_arr = batch.column_as_string(l_idx)
                var lit = self.string_pool[right_node.col_idx]
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if col side is NULL (lit is never null).
                    if l_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get(row)
                    var matched = lv == lit
                    if is_eq:
                        if matched:
                            output_sel.append(UInt32(row))
                    else:
                        if not matched:
                            output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif not left_is_col and right_is_col:
                # lit == col / lit != col — read lit once, col per row.
                var right_col_name = self.column_names[right_node.col_idx]
                var r_idx = batch.column_by_name(right_col_name)
                var r_arr = batch.column_as_string(r_idx)
                var lit = self.string_pool[left_node.col_idx]
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if col side is NULL (lit is never null).
                    if r_arr.is_null(row):
                        k = k + 1
                        continue
                    var rv = r_arr.get(row)
                    var matched = lit == rv
                    if is_eq:
                        if matched:
                            output_sel.append(UInt32(row))
                    else:
                        if not matched:
                            output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            else:
                # lit == lit / lit != lit — broadcast (literals never null).
                var l_lit = self.string_pool[left_node.col_idx]
                var r_lit = self.string_pool[right_node.col_idx]
                var matched = l_lit == r_lit
                var emit_all = (is_eq and matched) or (not is_eq and not matched)
                if emit_all:
                    var k = 0
                    while k < n_sel:
                        output_sel.append(input_sel.get(k))
                        k = k + 1
                return output_sel.len()

        # IS NULL / IS NOT NULL on a String column. Child stored in
        # `node.col_idx` (LEAF-pattern shape), must resolve to
        # EXPR_COL_STRING. The walker reads `is_null(row)` from the
        # source StringArray and emits to output_sel.
        if kind == EXPR_IS_NULL_STRING or kind == EXPR_IS_NOT_NULL_STRING:
            var child_idx = node.col_idx
            var child_node = self.expression_pool[child_idx]
            if child_node.kind != EXPR_COL_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_IS_NULL_STRING/EXPR_IS_NOT_NULL_STRING child"
                    " must be EXPR_COL_STRING (kind="
                    + String(child_node.kind) + ")"
                )
            var col_name = self.column_names[child_node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_string(runtime_idx)
            var want_null = kind == EXPR_IS_NULL_STRING
            output_sel.set_len(0)
            var n_sel = input_sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(input_sel.get(k))
                var is_n = col.is_null(row)
                if want_null:
                    if is_n:
                        output_sel.append(UInt32(row))
                else:
                    if not is_n:
                        output_sel.append(UInt32(row))
                k = k + 1
            return output_sel.len()

        # Byte-wise lexicographic compare arms over String
        # operands: GT / LT / GE / LE. Both children resolve to
        # EXPR_COL_STRING (read StringArray.get(row) per row) or
        # EXPR_LIT_STRING (read string_pool[col_idx] once, broadcast).
        # The 4 ops share one body via `kind` as the op discriminator
        # (mirrors the Decimal128 compare arm pattern). Per-row
        # comparison via `_str_compare(a, b)` returning memcmp-style
        # Int (<0 / 0 / >0). Byte-wise lexicographic = UTF-8 codepoint-
        # lexicographic for valid UTF-8 byte sequences = canonical
        # DuckDB / Postgres ORDER BY semantics for non-collated columns.
        #
        # SQL WHERE 3VL: any row where either operand is NULL produces
        # "unknown" and is EXCLUDED from output_sel (mirror EQ_STRING /
        # NEQ_STRING null-skip behavior).
        # `StringArray.is_null(row)`
        # short-circuits via the all-valid fast path when validity
        # bitmap is None.
        if (
            kind == EXPR_GT_STRING
            or kind == EXPR_LT_STRING
            or kind == EXPR_GE_STRING
            or kind == EXPR_LE_STRING
        ):
            var left_node = self.expression_pool[node.left]
            var right_node = self.expression_pool[node.right]
            var left_is_col = left_node.kind == EXPR_COL_STRING
            var right_is_col = right_node.kind == EXPR_COL_STRING
            if not left_is_col and left_node.kind != EXPR_LIT_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_*_STRING (lexicographic compare) left operand"
                    " must be EXPR_COL_STRING or EXPR_LIT_STRING (kind="
                    + String(left_node.kind) + ")"
                )
            if not right_is_col and right_node.kind != EXPR_LIT_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_*_STRING (lexicographic compare) right operand"
                    " must be EXPR_COL_STRING or EXPR_LIT_STRING (kind="
                    + String(right_node.kind) + ")"
                )

            output_sel.set_len(0)
            var n_sel = input_sel.len()

            if left_is_col and right_is_col:
                # col cmp col — read both sides per row.
                var left_col_name = self.column_names[left_node.col_idx]
                var right_col_name = self.column_names[right_node.col_idx]
                var l_idx = batch.column_by_name(left_col_name)
                var r_idx = batch.column_by_name(right_col_name)
                var l_arr = batch.column_as_string(l_idx)
                var r_arr = batch.column_as_string(r_idx)
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if either side is NULL.
                    if l_arr.is_null(row) or r_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get(row)
                    var rv = r_arr.get(row)
                    var c = _str_compare(lv, rv)
                    var matched: Bool
                    if kind == EXPR_GT_STRING:
                        matched = c > 0
                    elif kind == EXPR_LT_STRING:
                        matched = c < 0
                    elif kind == EXPR_GE_STRING:
                        matched = c >= 0
                    else:
                        matched = c <= 0
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif left_is_col and not right_is_col:
                # col cmp lit — read col per row, lit once.
                var left_col_name = self.column_names[left_node.col_idx]
                var l_idx = batch.column_by_name(left_col_name)
                var l_arr = batch.column_as_string(l_idx)
                var lit = self.string_pool[right_node.col_idx]
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if col side is NULL (lit never null).
                    if l_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get(row)
                    var c = _str_compare(lv, lit)
                    var matched: Bool
                    if kind == EXPR_GT_STRING:
                        matched = c > 0
                    elif kind == EXPR_LT_STRING:
                        matched = c < 0
                    elif kind == EXPR_GE_STRING:
                        matched = c >= 0
                    else:
                        matched = c <= 0
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif not left_is_col and right_is_col:
                # lit cmp col — read lit once, col per row.
                var right_col_name = self.column_names[right_node.col_idx]
                var r_idx = batch.column_by_name(right_col_name)
                var r_arr = batch.column_as_string(r_idx)
                var lit = self.string_pool[left_node.col_idx]
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: skip row if col side is NULL (lit never null).
                    if r_arr.is_null(row):
                        k = k + 1
                        continue
                    var rv = r_arr.get(row)
                    var c = _str_compare(lit, rv)
                    var matched: Bool
                    if kind == EXPR_GT_STRING:
                        matched = c > 0
                    elif kind == EXPR_LT_STRING:
                        matched = c < 0
                    elif kind == EXPR_GE_STRING:
                        matched = c >= 0
                    else:
                        matched = c <= 0
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            else:
                # lit cmp lit — broadcast (literals never null).
                var l_lit = self.string_pool[left_node.col_idx]
                var r_lit = self.string_pool[right_node.col_idx]
                var c = _str_compare(l_lit, r_lit)
                var matched: Bool
                if kind == EXPR_GT_STRING:
                    matched = c > 0
                elif kind == EXPR_LT_STRING:
                    matched = c < 0
                elif kind == EXPR_GE_STRING:
                    matched = c >= 0
                else:
                    matched = c <= 0
                if matched:
                    var k = 0
                    while k < n_sel:
                        output_sel.append(input_sel.get(k))
                        k = k + 1
                return output_sel.len()

        # SQL LIKE
        # pattern match on a String column. Shape constraints:
        #   - left must resolve to EXPR_COL_STRING (the value column).
        #   - right must resolve to EXPR_LIT_STRING (the pattern; lit
        #     never null).
        # Walker reads the StringArray for the col, reads the pattern
        # ONCE from string_pool (caller-side interned at lower-time),
        # and per-row calls `_string_like_match(text, pattern) -> Bool`.
        # SQL WHERE 3VL: per-row `is_null(row)` short-circuit excludes
        # the row (mirror EQ_STRING / lexicographic precedent).
        #
        # col-vs-col LIKE is a degenerate SQL shape (no real workload
        # emits `col_a LIKE col_b`) — the walker raises if either
        # operand violates the (col, lit) expectation. The SDK lowering
        # at `_translate_string_op` is the only emitter and never
        # produces other shapes.
        if kind == EXPR_LIKE_STRING:
            var left_node = self.expression_pool[node.left]
            var right_node = self.expression_pool[node.right]
            if left_node.kind != EXPR_COL_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_LIKE_STRING left operand must be"
                    " EXPR_COL_STRING (kind="
                    + String(left_node.kind) + ")"
                )
            if right_node.kind != EXPR_LIT_STRING:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_LIKE_STRING right operand must be"
                    " EXPR_LIT_STRING (kind="
                    + String(right_node.kind) + ")"
                )

            var col_name = self.column_names[left_node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_string(runtime_idx)
            var pattern = self.string_pool[right_node.col_idx]

            output_sel.set_len(0)
            var n_sel = input_sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(input_sel.get(k))
                # 3VL: skip row if col side is NULL (lit never null).
                if col.is_null(row):
                    k = k + 1
                    continue
                var v = col.get(row)
                if _string_like_match(v, pattern):
                    output_sel.append(UInt32(row))
                k = k + 1
            return output_sel.len()

        # Decimal128 compare arms: EQ / NEQ / GT / LT / GE / LE. Both
        # children resolve to EXPR_COL_DECIMAL128 (read Decimal128Array
        # via batch.column_as_decimal128) or EXPR_LIT_DECIMAL128 (read
        # decimal_pool[col_idx] once). Same-scale fast path uses direct
        # i128 compare; cross-scale rescales the smaller-scale operand
        # UP via i128 * 10^(diff) (lossless when scaling up; we use a
        # i256 intermediate via decimal_arith.rescale_i256_half_up only
        # when needed). The 6 compare ops share one body via op_kind
        # discriminator at the comparison step.
        if (
            kind == EXPR_EQ_DECIMAL128
            or kind == EXPR_NEQ_DECIMAL128
            or kind == EXPR_GT_DECIMAL128
            or kind == EXPR_LT_DECIMAL128
            or kind == EXPR_GE_DECIMAL128
            or kind == EXPR_LE_DECIMAL128
        ):
            var left_node = self.expression_pool[node.left]
            var right_node = self.expression_pool[node.right]
            var left_is_col = left_node.kind == EXPR_COL_DECIMAL128
            var right_is_col = right_node.kind == EXPR_COL_DECIMAL128
            if not left_is_col and left_node.kind != EXPR_LIT_DECIMAL128:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_*_DECIMAL128 left operand must be"
                    " EXPR_COL_DECIMAL128 or EXPR_LIT_DECIMAL128 (kind="
                    + String(left_node.kind) + ")"
                )
            if not right_is_col and right_node.kind != EXPR_LIT_DECIMAL128:
                raise Error(
                    "ExpressionExecutor._eval_bool_from_view:"
                    " EXPR_*_DECIMAL128 right operand must be"
                    " EXPR_COL_DECIMAL128 or EXPR_LIT_DECIMAL128 (kind="
                    + String(right_node.kind) + ")"
                )

            # Resolve (i128_array OR i128_lit) + scale for each side.
            var l_scale: Int
            var r_scale: Int
            # Side carries either a Decimal128Array (if col) OR a single
            # i128 value (if lit) — we read on the fly inside the row loop.
            var n_sel = input_sel.len()
            output_sel.set_len(0)

            # Compute side metadata BEFORE the loop (column gather +
            # array (p, s) read, or pool lookup).
            # NOTE: we deliberately materialize the Decimal128Array
            # variable so the per-row get_i128 is a borrow against
            # this local — matches Q6 path's gather pattern.
            if left_is_col and right_is_col:
                var l_col_name = self.column_names[left_node.col_idx]
                var r_col_name = self.column_names[right_node.col_idx]
                var l_idx = batch.column_by_name(l_col_name)
                var r_idx = batch.column_by_name(r_col_name)
                var l_arr = batch.column_as_decimal128(l_idx)
                var r_arr = batch.column_as_decimal128(r_idx)
                l_scale = l_arr.scale
                r_scale = r_arr.scale
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: a NULL operand makes the row UNKNOWN.
                    if l_arr.is_null(row) or r_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get_i128(row)
                    var rv = r_arr.get_i128(row)
                    var matched = _compare_decimal128(
                        lv, l_scale, rv, r_scale, kind
                    )
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif left_is_col and not right_is_col:
                var l_col_name = self.column_names[left_node.col_idx]
                var l_idx = batch.column_by_name(l_col_name)
                var l_arr = batch.column_as_decimal128(l_idx)
                l_scale = l_arr.scale
                var lit_spec = self.decimal_pool[right_node.col_idx]
                var rv_lit = lit_spec.value
                r_scale = lit_spec.scale
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: a NULL column cell makes the row UNKNOWN.
                    if l_arr.is_null(row):
                        k = k + 1
                        continue
                    var lv = l_arr.get_i128(row)
                    var matched = _compare_decimal128(
                        lv, l_scale, rv_lit, r_scale, kind
                    )
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            elif not left_is_col and right_is_col:
                var r_col_name = self.column_names[right_node.col_idx]
                var r_idx = batch.column_by_name(r_col_name)
                var r_arr = batch.column_as_decimal128(r_idx)
                r_scale = r_arr.scale
                var lit_spec = self.decimal_pool[left_node.col_idx]
                var lv_lit = lit_spec.value
                l_scale = lit_spec.scale
                var k = 0
                while k < n_sel:
                    var row = Int(input_sel.get(k))
                    # 3VL: a NULL column cell makes the row UNKNOWN.
                    if r_arr.is_null(row):
                        k = k + 1
                        continue
                    var rv = r_arr.get_i128(row)
                    var matched = _compare_decimal128(
                        lv_lit, l_scale, rv, r_scale, kind
                    )
                    if matched:
                        output_sel.append(UInt32(row))
                    k = k + 1
                return output_sel.len()
            else:
                # lit op lit — broadcast.
                var l_spec = self.decimal_pool[left_node.col_idx]
                var r_spec = self.decimal_pool[right_node.col_idx]
                var matched = _compare_decimal128(
                    l_spec.value, l_spec.scale,
                    r_spec.value, r_spec.scale, kind
                )
                if matched:
                    var k = 0
                    while k < n_sel:
                        output_sel.append(input_sel.get(k))
                        k = k + 1
                return output_sel.len()

        # EXPR_IN_LIST: child column ref at `node.left`, value list at
        # `self.in_list_pool[node.col_idx]`. Resolves the column once
        # per call, then probes per surviving row against the K-element
        # value table. Per-DType dispatch is on the runtime column's
        # ArrowType (matches `compiler_eval_in_list._eval_in_list`'s
        # typed-kernel set). NULL rows are dropped (non-null-aware
        # probe → False on NULL → row excluded from output_sel, the
        # SQL-Kleene WHERE semantics the failing test cases assert).
        # K=0 short-circuits to all-false (matches the SDK
        # `Expr.in_list(...)` empty-fold + defends bypass routes).
        if kind == EXPR_IN_LIST:
            return self._eval_in_list_from_view[bo](
                batch, node, idx, input_sel, output_sel
            )

        # Disjunction combinator. Evaluate both children
        # separately against `input_sel`, then merge their true-sels
        # via a two-pointer union (both sels are sorted ascending —
        # the per-child filter kernels preserve input order, so a
        # linear-time merge suffices). Closes TPC-H Q7's nation-pair
        # filter `(n1='FRANCE' AND n2='GERMANY') OR
        # (n1='GERMANY' AND n2='FRANCE')`.
        if kind == EXPR_OR:
            var n_sel = input_sel.len()
            # Per-child true-sel scratch.
            var left_true = RowSelectionVector(n_sel if n_sel > 0 else 1)
            var right_true = RowSelectionVector(n_sel if n_sel > 0 else 1)
            _ = self._eval_bool_from_view[bo](
                batch, node.left, input_sel, left_true, temp_false
            )
            _ = self._eval_bool_from_view[bo](
                batch, node.right, input_sel, right_true, temp_false
            )
            # Two-pointer union. Both inputs are sorted ascending.
            output_sel.set_len(0)
            var i_l = 0
            var i_r = 0
            var n_l = left_true.len()
            var n_r = right_true.len()
            while i_l < n_l and i_r < n_r:
                var lv = left_true.get(i_l)
                var rv = right_true.get(i_r)
                if lv < rv:
                    output_sel.append(lv)
                    i_l = i_l + 1
                elif rv < lv:
                    output_sel.append(rv)
                    i_r = i_r + 1
                else:
                    # Equal — emit once, advance both.
                    output_sel.append(lv)
                    i_l = i_l + 1
                    i_r = i_r + 1
            while i_l < n_l:
                output_sel.append(left_true.get(i_l))
                i_l = i_l + 1
            while i_r < n_r:
                output_sel.append(right_true.get(i_r))
                i_r = i_r + 1
            return output_sel.len()
        raise Error(
            "ExpressionExecutor._eval_bool_from_view: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (top-level expression must evaluate to Bool)"
        )

    def _dispatch_comparison_from_view[
        bo: Origin[mut=False], T: DType, op: UInt8
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        node: RuntimeExpr,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
        mut temp_false: RowSelectionVector,
    ) raises -> Int:
        """Numeric column comparison over `input_sel`, NULL operands dropped.

        The sel kernels compare stored values and do not read validity, so
        when an operand column holds a NULL the rows whose operand is NULL
        (UNKNOWN under SQL) are removed from the selection before the
        comparison runs. A column with `null_count() == 0` skips that pass,
        leaving the kernels' identity fast path in place.
        """
        var left = self.expression_pool[node.left]
        var right = self.expression_pool[node.right]
        var may_be_null = False
        if left.kind == EXPR_COL:
            may_be_null = self._column_has_nulls_from_view[bo](
                batch, left.col_idx
            )
        if right.kind == EXPR_COL and not may_be_null:
            may_be_null = self._column_has_nulls_from_view[bo](
                batch, right.col_idx
            )
        if not may_be_null:
            return self._compare_present_from_view[bo, T, op](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        var n_sel = input_sel.len()
        var null_at = List[Bool](length=n_sel, fill=False)
        self._mark_value_nulls_from_view[bo](
            batch, node.left, input_sel, null_at
        )
        self._mark_value_nulls_from_view[bo](
            batch, node.right, input_sel, null_at
        )
        var present = RowSelectionVector(n_sel if n_sel > 0 else 1)
        for k in range(n_sel):
            if not null_at[k]:
                present.append(input_sel.get(k))
        return self._compare_present_from_view[bo, T, op](
            batch, node, idx, present, output_sel, temp_false
        )

    def _column_has_nulls_from_view[
        bo: Origin[mut=False],
    ](imm self, ref [bo] batch: RecordBatch, col_idx: Int) raises -> Bool:
        """True iff the batch column named by `column_names[col_idx]` holds
        at least one NULL."""
        var runtime_idx = batch.column_by_name(self.column_names[col_idx])
        return batch.column_at(runtime_idx).null_count() > 0

    def _compare_present_from_view[
        bo: Origin[mut=False], T: DType, op: UInt8
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        node: RuntimeExpr,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
        mut temp_false: RowSelectionVector,
    ) raises -> Int:
        """BatchView-borrow sibling of `_dispatch_comparison`: runs the
        sel kernel for `T` / `op`. Reads stored values only; the caller
        (`_dispatch_comparison_from_view`) has removed NULL-operand rows.

        Every batch method called here (`column_by_name`,
        `column_as_primitive_*`) is read-self, so the read-only borrow
        suffices. `T` is int64 or float64: the walker instantiates no
        other.
        """
        var left = self.expression_pool[node.left]
        var right = self.expression_pool[node.right]

        if left.kind != EXPR_COL:
            raise Error(
                "ExpressionExecutor: comparison at pool slot "
                + String(idx)
                + " expects EXPR_COL on the LEFT (literal-"
                "on-left is not normalized)"
            )

        if right.kind != EXPR_COL:
            _validate_lit_dtype[T](right, idx)

        var left_name = self.column_names[left.col_idx]
        var left_runtime_idx = batch.column_by_name(left_name)

        comptime if T == DType.int64:
            # The I64 compare
            # tag is emitted by lower_untyped whenever both sides are in the
            # I64 RUNTIME_DTYPE family (INT32 + DATE32 + INT64). The SOURCE
            # column may carry its OWN native dtype: a genuine INT32 column
            # (e.g. Parquet DATE column read as INT32) is NOT storage-
            # compatible with an int64 `as_primitive` reinterpret (4-byte
            # vs 8-byte → raises "column is int32 but requested int64").
            # Dispatch on the source arrow_type and route INT32 columns
            # through the int32 sub-arm with the literal narrowed; mirrors
            # the int-widening pattern in the I64 expr walker.
            # DATE32 is int32-storage-compatible per
            # column.as_primitive's storage-compat rule.
            var left_at = batch.column_arrow_type(left_runtime_idx)
            var left_is_i32 = (
                left_at == ArrowType.INT32 or left_at == ArrowType.DATE32
            )
            if left_is_i32:
                var left_col_i32 = batch.column_as_primitive_int32(left_runtime_idx)
                if right.kind == EXPR_COL:
                    var right_name = self.column_names[right.col_idx]
                    var right_runtime_idx = batch.column_by_name(right_name)
                    var right_at = batch.column_arrow_type(right_runtime_idx)
                    var right_is_i32 = (
                        right_at == ArrowType.INT32
                        or right_at == ArrowType.DATE32
                    )
                    if right_is_i32:
                        var right_col_i32 = batch.column_as_primitive_int32(
                            right_runtime_idx
                        )
                        return binary_select_col_col[DType.int32, op](
                            left_col_i32, right_col_i32, input_sel,
                            output_sel, temp_false,
                        )
                    # Mixed-width int32-vs-int64 col-vs-col not yet supported.
                    raise Error(
                        "ExpressionExecutor._dispatch_comparison_from_view:"
                        " mixed-width int32-vs-int64 column-vs-column compare"
                        " not yet supported (need explicit cast)"
                    )
                return binary_select_col_lit[DType.int32, op](
                    left_col_i32,
                    Scalar[DType.int32](Int32(right.i64)),
                    input_sel, output_sel, temp_false,
                )
            var left_col = batch.column_as_primitive_int64(left_runtime_idx)
            if right.kind == EXPR_COL:
                var right_name = self.column_names[right.col_idx]
                var right_runtime_idx = batch.column_by_name(right_name)
                var right_col = batch.column_as_primitive_int64(
                    right_runtime_idx
                )
                return binary_select_col_col[DType.int64, op](
                    left_col, right_col, input_sel,
                    output_sel, temp_false,
                )
            return binary_select_col_lit[DType.int64, op](
                left_col,
                Scalar[DType.int64](right.i64),
                input_sel, output_sel, temp_false,
            )
        else:
            comptime assert T == DType.float64, (
                "_compare_present_from_view: T is int64 or float64"
            )
            var left_col = batch.column_as_primitive_float64(left_runtime_idx)
            if right.kind == EXPR_COL:
                var right_name = self.column_names[right.col_idx]
                var right_runtime_idx = batch.column_by_name(right_name)
                var right_col = batch.column_as_primitive_float64(
                    right_runtime_idx
                )
                return binary_select_col_col[DType.float64, op](
                    left_col, right_col, input_sel,
                    output_sel, temp_false,
                )
            return binary_select_col_lit[DType.float64, op](
                left_col,
                Scalar[DType.float64](right.f64),
                input_sel, output_sel, temp_false,
            )

    # =========================================================================
    # SQL three-valued logic over a selection.
    # =========================================================================
    #
    # `_eval_bool_from_view` emits the rows where a predicate is TRUE, which is
    # all a WHERE needs except under NOT: there a FALSE row is kept and an
    # UNKNOWN row is not, so the walker needs to tell the two apart.
    # `_eval_kleene_from_view` gives one Kleene value per selection position;
    # the NULL masks below say which positions have a NULL operand.
    # =========================================================================

    def _eval_kleene_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[UInt8],
        mut temp_false: RowSelectionVector,
    ) raises:
        """Append, for each position of `sel`, the SQL three-valued value of
        the Bool sub-tree at `idx` (`_KLEENE_FALSE` / `_KLEENE_TRUE` /
        `_KLEENE_NULL`).

        AND / OR / NOT combine their children's values by Kleene's tables. A
        leaf is TRUE where `_eval_bool_from_view` emits its row, else UNKNOWN
        where `_mark_bool_leaf_nulls_from_view` finds a NULL operand, else
        FALSE. Membership is looked up by row number, so `sel` need not be
        ascending.
        """
        var node = self.expression_pool[idx]
        var kind = node.kind
        var n_sel = sel.len()

        if kind == EXPR_AND or kind == EXPR_OR:
            var l = List[UInt8](capacity=n_sel)
            var r = List[UInt8](capacity=n_sel)
            self._eval_kleene_from_view[bo](batch, node.left, sel, l, temp_false)
            self._eval_kleene_from_view[bo](
                batch, node.right, sel, r, temp_false
            )
            for k in range(n_sel):
                if kind == EXPR_AND:
                    out.append(_kleene_and(l[k], r[k]))
                else:
                    out.append(_kleene_or(l[k], r[k]))
            return
        if kind == EXPR_NOT_BOOL:
            var c = List[UInt8](capacity=n_sel)
            self._eval_kleene_from_view[bo](batch, node.left, sel, c, temp_false)
            for k in range(n_sel):
                out.append(_kleene_not(c[k]))
            return

        var n_rows = batch.num_rows()
        var cap = n_rows if n_rows > n_sel else n_sel
        var true_sel = RowSelectionVector(cap if cap > 0 else 1)
        _ = self._eval_bool_from_view[bo](batch, idx, sel, true_sel, temp_false)
        var is_true = List[Bool](length=n_rows, fill=False)
        for j in range(true_sel.len()):
            is_true[Int(true_sel.get(j))] = True
        var null_at = List[Bool](length=n_sel, fill=False)
        self._mark_bool_leaf_nulls_from_view[bo](batch, node, idx, sel, null_at)
        for k in range(n_sel):
            if is_true[Int(sel.get(k))]:
                out.append(_KLEENE_TRUE)
            elif null_at[k]:
                out.append(_KLEENE_NULL)
            else:
                out.append(_KLEENE_FALSE)

    def _mark_bool_leaf_nulls_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        node: RuntimeExpr,
        idx: Int,
        ref sel: RowSelectionVector,
        mut null_at: List[Bool],
    ) raises:
        """Set `null_at[k]` where the Bool leaf `node` (pool slot `idx`) is
        UNKNOWN unless it is TRUE: a comparison or LIKE with a NULL operand,
        a NULL Bool cell, or an IN-list whose probe value is NULL or whose
        list holds a NULL (`x IN (1, NULL)` is UNKNOWN for x = 2).
        IS NULL / IS NOT NULL and Bool literals are never UNKNOWN."""
        var kind = node.kind
        if _is_binary_bool_leaf(kind):
            self._mark_value_nulls_from_view[bo](batch, node.left, sel, null_at)
            self._mark_value_nulls_from_view[bo](
                batch, node.right, sel, null_at
            )
            return
        if kind == EXPR_COL_BOOL:
            self._mark_value_nulls_from_view[bo](batch, idx, sel, null_at)
            return
        if (
            kind == EXPR_LIT_BOOL
            or kind == EXPR_IS_NULL_STRING
            or kind == EXPR_IS_NOT_NULL_STRING
        ):
            return
        if kind == EXPR_IN_LIST:
            self._mark_value_nulls_from_view[bo](batch, node.left, sel, null_at)
            ref values = self.in_list_pool[node.col_idx]
            for i in range(len(values)):
                if values[i].is_null():
                    for k in range(sel.len()):
                        null_at[k] = True
                    return
            return
        raise Error(
            "ExpressionExecutor._mark_bool_leaf_nulls_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
        )

    def _mark_value_nulls_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        idx: Int,
        ref sel: RowSelectionVector,
        mut null_at: List[Bool],
    ) raises:
        """Set `null_at[k]` (sized `sel.len()`) where the value sub-tree at
        `idx` is SQL NULL for row `sel[k]`; other positions are left as they
        are.

        A column leaf is NULL where its cell is; EXPR_NULL everywhere; a
        literal nowhere. Arithmetic, casts and the math functions are NULL
        where an operand is. A CASE is NULL where the branch it takes is,
        chosen as `eval_to_list_{i64,f64}_from_view` choose it. Any other kind
        raises (the value walkers do not serve it either).
        """
        var node = self.expression_pool[idx]
        var kind = node.kind
        var n_sel = sel.len()
        if (
            kind == EXPR_COL
            or kind == EXPR_COL_STRING
            or kind == EXPR_COL_DECIMAL128
            or kind == EXPR_COL_BOOL
        ):
            var runtime_idx = batch.column_by_name(
                self.column_names[node.col_idx]
            )
            ref col = batch.column_at(runtime_idx)
            if col.null_count() == 0:
                return
            for k in range(n_sel):
                if col.is_null_at(Int(sel.get(k))):
                    null_at[k] = True
            return
        if kind == EXPR_NULL:
            for k in range(n_sel):
                null_at[k] = True
            return
        if (
            kind == EXPR_LIT_I64
            or kind == EXPR_LIT_F64
            or kind == EXPR_LIT_I32
            or kind == EXPR_LIT_STRING
            or kind == EXPR_LIT_DECIMAL128
            or kind == EXPR_LIT_BOOL
        ):
            return
        if (
            kind == EXPR_ADD_I64
            or kind == EXPR_SUB_I64
            or kind == EXPR_MUL_I64
            or kind == EXPR_DIV_I64
            or kind == EXPR_ADD_F64
            or kind == EXPR_SUB_F64
            or kind == EXPR_MUL_F64
            or kind == EXPR_DIV_F64
            or kind == EXPR_ADD_I32
            or kind == EXPR_SUB_I32
            or kind == EXPR_MUL_I32
            or kind == EXPR_DIV_I32
            or kind == EXPR_ATAN2_F64
            or kind == EXPR_POW_F64
        ):
            self._mark_value_nulls_from_view[bo](batch, node.left, sel, null_at)
            self._mark_value_nulls_from_view[bo](
                batch, node.right, sel, null_at
            )
            return
        if (
            kind == EXPR_F64_TO_I64
            or kind == EXPR_I64_TO_F64
            or kind == EXPR_SQRT_F64
            or kind == EXPR_SIN_F64
            or kind == EXPR_COS_F64
            or kind == EXPR_ASIN_F64
            or kind == EXPR_RADIANS_F64
            or kind == EXPR_MATH_UNARY_F64
        ):
            self._mark_value_nulls_from_view[bo](batch, node.left, sel, null_at)
            return
        if kind == EXPR_CASE_I64 or kind == EXPR_CASE_F64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            var n_rows = batch.num_rows()
            # `taken[k]` = the WHEN index whose condition first holds, or
            # `n_pairs` for the ELSE.
            var taken = List[Int](length=n_sel, fill=n_pairs)
            for c in range(n_pairs):
                var cond_mask = List[Scalar[DType.bool]](capacity=n_rows)
                for _r in range(n_rows):
                    cond_mask.append(Scalar[DType.bool](False))
                self._eval_case_cond_mask_from_view[bo](
                    batch, slots[2 * c], sel, cond_mask
                )
                for k in range(n_sel):
                    if taken[k] == n_pairs and Bool(
                        cond_mask[Int(sel.get(k))]
                    ):
                        taken[k] = c
            for b in range(n_pairs + 1):
                var slot = slots[2 * b + 1] if b < n_pairs else slots[
                    len(slots) - 1
                ]
                var branch_null = List[Bool](length=n_sel, fill=False)
                self._mark_value_nulls_from_view[bo](
                    batch, slot, sel, branch_null
                )
                for k in range(n_sel):
                    if taken[k] == b and branch_null[k]:
                        null_at[k] = True
            return
        raise Error(
            "ExpressionExecutor._mark_value_nulls_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
        )

    # =========================================================================
    # EXPR_IN_LIST per-row membership probe.
    # =========================================================================
    #
    # EXPR_IN_LIST walker arm shared by `_eval_bool` (mut-batch) and
    # `_eval_bool_from_view` (ref-batch). Reads the child column's
    # ArrowType + dispatches to a per-DType per-row probe loop. The
    # value table lives in `self.in_list_pool[node.col_idx]` (parallel
    # side-pool to string_pool / decimal_pool).
    #
    # Semantics (mirrors `compiler_eval_in_list._eval_in_list`):
    #   - K=0 → no row matches (the SDK factory normally folds this to
    #     `lit(False)`; the arm defends against any IR route that
    #     bypasses the fold).
    #   - NULL column rows → no row matches (the filter-context wrapper
    #     applies the standard `_collapse_nulls_to_false` semantics via
    #     the SQL-Kleene rule — NULL ∈ list is "unknown" → row dropped).
    #   - NULL list entries → ignored on the probe side (a non-null
    #     column value with NULL list entries probes only the non-null
    #     entries; the SQL semantic distinguishes "no match" from
    #     "unknown" but filter-context collapses both to dropped).
    #
    # Supported column DTypes (mirrors the legacy interpreter's typed
    # kernels at `compiler_eval_in_list.mojo`):
    #   - INT64 / INT32 / FLOAT64 / STRING / BOOL / DICTIONARY (string).
    # Unsupported DTypes raise a clear error.
    #
    # Per-row cost: K probes per surviving row. For K > ~16 a hashset
    # would amortize better; current kernels match the legacy
    # `_eval_in_list` shape (inline linear probe) — Q19-class workloads
    # observed K ≤ 8 in production plans.
    #
    # Encapsulation invariants:
    #   - NO UnsafePointer in public surface.
    #   - NO wildcard origins — `bo: Origin[mut=False]` in
    #     `_eval_in_list_from_view`; the mut-batch arm uses the same
    #     shape via `mut batch: RecordBatch`.
    #   - The two entry points share `_eval_in_list_typed` which only
    #     reads `self.in_list_pool` (no field mutation).
    # =========================================================================

    def _eval_in_list_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        node: RuntimeExpr,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
    ) raises -> Int:
        """ref-batch sibling of `_eval_in_list_impl`. Resolves the
        child column ref + dispatches to the per-DType probe.
        """
        var child = self.expression_pool[node.left]
        var col_name = self._in_list_child_col_name(child, idx)
        var runtime_idx = batch.column_by_name(col_name)
        var col_at = batch.column_arrow_type(runtime_idx)
        ref values = self.in_list_pool[node.col_idx]
        return self._eval_in_list_typed[bo](
            batch, runtime_idx, col_at, values, idx, input_sel, output_sel
        )

    @always_inline
    def _in_list_child_col_name(
        imm self,
        child: RuntimeExpr,
        idx: Int,
    ) raises -> String:
        """Resolve the child column's NAME from the runtime pool.
        The child must be a column-leaf (EXPR_COL / EXPR_COL_STRING /
        EXPR_COL_BOOL / EXPR_COL_DECIMAL128); other shapes raise.
        """
        if (
            child.kind != EXPR_COL
            and child.kind != EXPR_COL_STRING
            and child.kind != EXPR_COL_BOOL
            and child.kind != EXPR_COL_DECIMAL128
        ):
            raise Error(
                "ExpressionExecutor._eval_in_list: EXPR_IN_LIST child"
                " at pool slot "
                + String(idx)
                + " must be a column-leaf (EXPR_COL / EXPR_COL_STRING /"
                + " EXPR_COL_BOOL / EXPR_COL_DECIMAL128); got kind "
                + String(child.kind)
            )
        return self.column_names[child.col_idx]

    def _eval_in_list_typed[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        runtime_idx: Int,
        col_at: ArrowType,
        ref values: List[ScalarValue],
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
    ) raises -> Int:
        """Per-DType IN-list probe over the surviving rows. Walks
        `input_sel`, emits matching rows into `output_sel`.

        K=0 short-circuits the entire result to empty (no row matches).
        NULL rows are skipped (the typed `is_null(row)` check + the
        non-null-aware probe semantics combine to drop NULL rows,
        matching `_collapse_nulls_to_false` at the filter boundary).
        """
        output_sel.set_len(0)
        var k = len(values)
        if k == 0:
            # SQL `x IN ()` is FALSE for every row.
            return 0
        var n_sel = input_sel.len()

        if col_at == ArrowType.INT64:
            var arr = batch.column_as_primitive_int64(runtime_idx)
            # Pre-extract typed value table (avoid per-row ScalarValue field
            # access on the hot path).
            var vt = List[Int64](capacity=k)
            # Float entries: `x IN (v, ...)` is `x = v OR ...`, and an
            # integer compared with a float compares as Float64 (the
            # `*_F64_MIXED` compares), so a whole-number float such as 3.0
            # matches 3. A non-integral float matches no integer. NULL and
            # other-DType entries are skipped.
            var vf = List[Float64]()
            for i in range(k):
                if values[i].is_int():
                    vt.append(values[i].int_val)
                elif values[i].is_float():
                    vf.append(values[i].float_val)
            var ki = len(vt)
            var kf = len(vf)
            var i_sel = 0
            while i_sel < n_sel:
                var row = Int(input_sel.get(i_sel))
                if not arr.is_null(row):
                    var x = arr.get(row)
                    if _in_list_int_probe(x.cast[DType.int64](), vt, ki, vf, kf):
                        output_sel.append(UInt32(row))
                i_sel = i_sel + 1
            return output_sel.len()

        if col_at == ArrowType.INT32:
            var arr = batch.column_as_primitive_int32(runtime_idx)
            # Integer entries stay Int64 and the Int32 value is widened, so
            # an entry outside the Int32 range matches nothing rather than
            # wrapping onto one. Float entries as in the INT64 arm.
            var vt = List[Int64](capacity=k)
            var vf = List[Float64]()
            for i in range(k):
                if values[i].is_int():
                    vt.append(values[i].int_val)
                elif values[i].is_float():
                    vf.append(values[i].float_val)
            var ki = len(vt)
            var kf = len(vf)
            var i_sel = 0
            while i_sel < n_sel:
                var row = Int(input_sel.get(i_sel))
                if not arr.is_null(row):
                    var x = arr.get(row)
                    if _in_list_int_probe(x.cast[DType.int64](), vt, ki, vf, kf):
                        output_sel.append(UInt32(row))
                i_sel = i_sel + 1
            return output_sel.len()

        if col_at == ArrowType.FLOAT64:
            var arr = batch.column_as_primitive_float64(runtime_idx)
            var vt = List[Float64](capacity=k)
            for i in range(k):
                if values[i].is_float():
                    vt.append(values[i].float_val)
                elif values[i].is_int():
                    vt.append(Float64(Int(values[i].int_val)))
            var ki = len(vt)
            var i_sel = 0
            while i_sel < n_sel:
                var row = Int(input_sel.get(i_sel))
                if not arr.is_null(row):
                    var x = arr.get(row)
                    var j = 0
                    while j < ki:
                        if x == vt[j]:
                            output_sel.append(UInt32(row))
                            break
                        j = j + 1
                i_sel = i_sel + 1
            return output_sel.len()

        if col_at == ArrowType.STRING:
            var arr = batch.column_as_string(runtime_idx)
            # Per-row String reads. K is typically small (<= 8 for Q19);
            # the cost is dominated by the per-row UTF-8 byte-compare,
            # not the typed-table preallocate. We do NOT pre-extract the
            # ScalarValue.string_val list — `values[j].string_val` is
            # borrowed for the duration of the call (caller owns the
            # in_list_pool entry).
            var i_sel = 0
            while i_sel < n_sel:
                var row = Int(input_sel.get(i_sel))
                if not arr.is_null(row):
                    var x = arr.get(row)
                    var j = 0
                    while j < k:
                        if values[j].is_string():
                            if x == values[j].string_val:
                                output_sel.append(UInt32(row))
                                break
                        j = j + 1
                i_sel = i_sel + 1
            return output_sel.len()

        if col_at == ArrowType.BOOL:
            var arr = batch.column_as_boolean(runtime_idx)
            var has_true = False
            var has_false = False
            for i in range(k):
                if values[i].is_bool():
                    if values[i].bool_val:
                        has_true = True
                    else:
                        has_false = True
            var i_sel = 0
            while i_sel < n_sel:
                var row = Int(input_sel.get(i_sel))
                if not arr.is_null(row):
                    var v = arr.get(row)
                    if (v and has_true) or ((not v) and has_false):
                        output_sel.append(UInt32(row))
                i_sel = i_sel + 1
            return output_sel.len()

        raise Error(
            "ExpressionExecutor._eval_in_list: EXPR_IN_LIST at pool slot "
            + String(idx)
            + " has unsupported column ArrowType "
            + String(col_at)
            + " (supports INT64 / INT32 / FLOAT64 / STRING / BOOL today;"
            + " DICTIONARY is not supported). Mirrors"
            + " `compiler_eval_in_list._eval_in_list` typed-kernel set."
        )

    # =========================================================================
    # Per-DType project walker
    # =========================================================================
    #
    # `eval_to_list_i64_from_view[bo]` + `eval_to_list_f64_from_view[bo]` are
    # the RuntimeProgram project walker entry points. They evaluate a
    # non-bool top-level Expr — specifically an output
    # column projection — over a filter-narrowed `RowSelectionVector`,
    # appending typed scalar values into a per-DType output buffer.
    #
    # Leaf arms:
    #   - `EXPR_COL` (passthrough — gather one column from the batch).
    #   - `EXPR_LIT_I64` / `EXPR_LIT_F64` (literal broadcast).
    # Each per-DType walker below lists the further arms it serves.
    #
    # Not done: SIMD chunk + scalar tail (the per-row gather over `sel` is the
    # simplest correct shape; SIMD optimization is profile-driven).
    #
    # Encapsulation invariants:
    #   - NO UnsafePointer in public surface.
    #   - NO wildcard origins — `bo: Origin[mut=False]` is the only origin
    #     tracked; sub-origin deref to `ref [bo] RecordBatch` is local.
    #   - NO partial-move via UnsafePointer(to=struct.field).take_pointee().
    #
    # slab-safety audit: methods are read-only over `self.expression_pool` +
    # `self.column_names`. No new heap-owning fields on `ExpressionExecutor`.
    # The output `List[Scalar[T]]` is caller-owned.
    #
    # Performance note: per-row scalar reads via `col.load[1](row)[0]` are
    # the in-tree idiom (see `expr_x_conformers.mojo` / `:135`,
    # `sel_kernels.mojo`). The cost is dominated by the column-extract
    # via `batch.column_as_primitive_*` (one-time per call, ~tens of ns) +
    # the per-row gather (sub-ns per row in L1-resident batches).
    # =========================================================================

    # CASE/WHEN
    # support in the COLUMN view-walkers (`eval_to_list_{i64,f64}_from_view`).
    #
    # The per-cell `_eval_{i64,f64}_from_source` walkers already implement
    # EXPR_CASE_{I64,F64}, but the bridged typed-join ->
    # untyped agg tail (q8's `sum(CASE WHEN s_nationkey=2 THEN l_disc_price
    # ELSE 0)`) lowers through the COLUMN view-walkers, which raised on
    # EXPR_CASE_*. This helper produces, for one in-subset condition sub-tree,
    # a per-row Bool membership mask sized to `batch.num_rows()` (mask[row] is
    # True iff the condition holds for that row). The CASE arm in each column
    # value-walker then selects the first matching THEN branch (or the ELSE)
    # per position.
    #
    # Implementation: `_eval_bool_from_view` filters an input sel into an
    # output sel of surviving ROW indices. We seed it with the CASE's `sel`
    # (the rows the project walker is evaluating), then scatter the survivor
    # row indices into the mask. This is ordering-independent (we index by row,
    # not by position), so it is robust regardless of any survivor-ordering
    # assumption. The conditions are themselves in-subset Bool sub-trees
    # (comparisons / AND / OR), exactly the shapes `_eval_bool_from_view`
    # already serves.
    def _eval_case_cond_mask_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        ref [bo] batch: RecordBatch,
        cond_idx: Int,
        ref sel: RowSelectionVector,
        mut mask: List[Scalar[DType.bool]],
    ) raises:
        """Fill `mask[row]` (sized to `batch.num_rows()`) with True for every
        row in `sel` for which the Bool sub-tree at `cond_idx` holds."""
        var n_rows = batch.num_rows()
        var seed_n = sel.len()
        # Seed sel: a copy of the caller's `sel` (input to the condition).
        var seed = RowSelectionVector(seed_n if seed_n > 0 else 1)
        var s = 0
        while s < seed_n:
            seed.append(sel.get(s))
            s = s + 1
        var surv = RowSelectionVector(n_rows if n_rows > 0 else 1)
        var temp_false = RowSelectionVector(n_rows if n_rows > 0 else 1)
        _ = self._eval_bool_from_view[bo](
            batch, cond_idx, seed, surv, temp_false
        )
        var n_surv = surv.len()
        var j = 0
        while j < n_surv:
            mask[Int(surv.get(j))] = Scalar[DType.bool](True)
            j = j + 1

    def eval_to_list_i64_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Scalar[DType.int64]],
    ) raises:
        """Per-DType Int64 project walker.

        Evaluates the runtime Expr at `self.expression_pool[expr_idx]` over
        the rows in `sel`, appending one Int64 value per selected row to
        `out`. Output column shape matches `Path B` RuntimeProgram's per-
        batch project step.

        Leaf Expr kinds:
          - EXPR_COL — gather column `expression_pool[expr_idx].col_idx`
            (resolved through `self.column_names` against the batch via
            `column_by_name`) at each selected row.
          - EXPR_LIT_I64 — broadcast literal `expression_pool[expr_idx].i64`
            once per selected row.

        It also serves EXPR_LIT_F64, the computed-projection arms
        (EXPR_ADD_I64 / EXPR_SUB_I64 / EXPR_MUL_I64 / EXPR_DIV_I64),
        EXPR_F64_TO_I64 and EXPR_CASE_I64 (see the arms below).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors. Caller is responsible for sizing — for
                no-filter plans, supply an identity sel of length n_rows.
                For filtered plans, supply the output of
                `select_expression_from_view`.
            out: Output buffer. Method APPENDS `sel.len()` values (does
                not reset). Caller is responsible for clearing between
                batches.

        Raises:
            Error on unsupported Expr kind (any kind without an
            arm below).
            Error on Int64 DType mismatch when the EXPR_COL operand
            resolves to a non-Int64 column (surfaced from the typed
            accessor `column_as_primitive_int64`).
        """
        # Deref BatchView -> ref [bo] RecordBatch. Same sub-origin pattern as
        # `select_expression_from_view`.
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            # Passthrough: extract the source column, gather one scalar per
            # selected row.
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            # The I64-channel agg/project
            # path (group keys + RUNTIME_AGG_*_I64 vals) feeds through this
            # walker, but the SOURCE column carries its OWN native dtype. A
            # genuine INT32 column (`group_by(int32_col)`, `sum(int32_col)`) is
            # NOT storage-compatible with an int64 `as_primitive` reinterpret
            # (4-byte vs 8-byte → raises "column is int32 but requested
            # int64"). Dispatch on the source arrow_type and numerically WIDEN
            # int32→int64 here, mirroring the F64 walker's int-widening arm
            # below and the SQL widening contract. The int64-storage-compatible
            # types (DATE64 / TIME64 / DURATION / TIMESTAMP / INTERVAL_DAY_TIME)
            # carry int64 buffers and read directly through the int64 accessor.
            var src_at = batch.column_arrow_type(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            if src_at == ArrowType.INT32:
                var col = batch.column_as_primitive_int32(runtime_idx)
                while k < n_sel:
                    var row = Int(sel.get(k))
                    out.append(Scalar[DType.int64](Int(col.load[1](row)[0])))
                    k = k + 1
                return
            # `col.load[1](row)[0]` is the canonical per-row scalar read idiom
            # (precedent: expr_x_conformers.mojo, sel_kernels.mojo).
            # The width-1 SIMD load + lane extract folds to a single typed
            # scalar read at -O2.
            var col = batch.column_as_primitive_int64(runtime_idx)
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(col.load[1](row)[0])
                k = k + 1
            return

        if kind == EXPR_LIT_I64:
            # Literal broadcast: append `node.i64` once per selected row.
            var v = Scalar[DType.int64](node.i64)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        if kind == EXPR_LIT_F64:
            # COUNT(*) synthesizes an
            # EXPR_LIT_F64(0.0) val sentinel (lower_untyped.mojo) — the
            # COUNT kernel increments by 1 and IGNORES the literal value. When
            # COUNT routes to the I64-result substrate
            # (`feed_hash_agg_single_i64_key_i64_val`), that sentinel reaches
            # this I64 walker. Broadcast the float literal as int64 (truncated;
            # value is immaterial for the COUNT sentinel). Mirrors the F64
            # walker's EXPR_LIT_F64 arm.
            var v = Scalar[DType.int64](Int(node.f64))
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        # Arithmetic arms use
        # BATCHED recursive evaluation, NOT per-row scalar recursion.
        #
        # Bug history: the prior implementation called a per-row scalar
        # walker (`_eval_scalar_i64_from_view`, since removed) PER ROW
        # in a `while k < n_sel` loop. The EXPR_COL leaf of that scalar walker
        # calls `batch.column_as_primitive_int64(idx)` which COPIES THE ENTIRE
        # COLUMN via `OwnedAlignedBuffer` allocation + `memcpy` (see
        # `komira_arrow.column`). For TPC-H Q6 at SF1
        # (6M rows, ~114K survivors, 2 cols per binary op) this produces
        # ~10+ TB of allocations per `process_batch` call, triggering tcmalloc
        # freelist corruption and a ~200x perf regression.
        #
        # Fix: materialize LHS and RHS as `List[Scalar[I64]]` via recursive
        # batched evaluation BEFORE the per-row arithmetic loop. The EXPR_COL
        # leaf of `eval_to_list_i64_from_view` (above) copies the column ONCE,
        # then iterates `sel` filling the output list. Total allocations:
        # O(depth × cols) per call instead of O(rows × depth × cols).
        if kind == EXPR_ADD_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                # RAISES on overflow: DuckDB's sentence.
                out.append(checked_add[DType.int64](lhs_vals[k], rhs_vals[k]))
                k = k + 1
            return

        if kind == EXPR_SUB_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(checked_sub[DType.int64](lhs_vals[k], rhs_vals[k]))
                k = k + 1
            return

        if kind == EXPR_MUL_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(checked_mul[DType.int64](lhs_vals[k], rhs_vals[k]))
                k = k + 1
            return

        if kind == EXPR_DIV_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                # Div-by-zero raises (Int has no Inf representation; matches
                # DuckDB's integer-divide semantics).
                if rhs_vals[k] == Int64(0):
                    raise Error(
                        "ExpressionExecutor.eval_to_list_i64_from_view:"
                        " EXPR_DIV_I64 division by zero at sel index "
                        + String(k)
                    )
                # Truncates toward zero (-7 / 2 = -3), not Mojo's floor.
                out.append(_ee_div_trunc(lhs_vals[k], rhs_vals[k]))
                k = k + 1
            return

        # narrow an F64-channel integer-result agg column back to INT64.
        # The child is evaluated through the Float64 walker (which handles
        # EXPR_COL on a Float64 source column directly, and also numerically
        # widens INT64/INT32 sources), then each lane is truncated toward
        # zero. The values flowing through this node are whole numbers by
        # construction (a COUNT, or an Int64-input SUM/MIN/MAX accumulated
        # in the F64 channel), so the truncation is exact for inputs < 2^53.
        if kind == EXPR_F64_TO_I64:
            var n_sel = sel.len()
            var child_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, child_vals
            )
            var k = 0
            while k < n_sel:
                out.append(Scalar[DType.int64](child_vals[k]))
                k = k + 1
            return

        # Int64
        # CASE/WHEN. The `col_idx` field indexes the `when_pool` side-table;
        # the entry is the flattened slot list `[cond0, then0, ..., condK-1,
        # thenK-1, elseSlot]`. Per row (position k in `sel`) the result is the
        # first THEN whose condition holds, else the ELSE value. THEN/ELSE
        # branches are themselves Int64 value sub-trees evaluated through this
        # same walker; conditions are in-subset Bool sub-trees evaluated via
        # `_eval_case_cond_mask_from_view`. Mirrors the per-cell
        # `_eval_i64_from_source` EXPR_CASE_I64 arm's first-match semantics.
        if kind == EXPR_CASE_I64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            var n_sel = sel.len()
            var n_rows = batch.num_rows()
            # branch_vals[c] holds the THEN list for case c; the last entry is
            # the ELSE list. Each is one Int64 per position in `sel`.
            var then_lists = List[List[Scalar[DType.int64]]]()
            var masks = List[List[Scalar[DType.bool]]]()
            for c in range(n_pairs):
                var cond_mask = List[Scalar[DType.bool]](capacity=n_rows)
                for _r in range(n_rows):
                    cond_mask.append(Scalar[DType.bool](False))
                self._eval_case_cond_mask_from_view[bo](
                    batch, slots[2 * c], sel, cond_mask
                )
                masks.append(cond_mask^)
                var then_vals = List[Scalar[DType.int64]](capacity=n_sel)
                self.eval_to_list_i64_from_view[bo](
                    batch_view, slots[2 * c + 1], sel, then_vals
                )
                then_lists.append(then_vals^)
            var else_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, slots[len(slots) - 1], sel, else_vals
            )
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var picked = else_vals[k]
                for c in range(n_pairs):
                    if Bool(masks[c][row]):
                        picked = then_lists[c][k]
                        break
                out.append(picked)
                k = k + 1
            return

        # Unsupported kind.
        raise Error(
            "ExpressionExecutor.eval_to_list_i64_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL + EXPR_LIT_I64 + EXPR_{ADD,SUB,"
            "MUL,DIV}_I64 + EXPR_CASE_I64; EXPR_MOD_I64 is not supported)"
        )

    def eval_to_list_f64_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Scalar[DType.float64]],
    ) raises:
        """Per-DType Float64 project walker.

        Mirror of `eval_to_list_i64_from_view` with Float64 output type.
        Supports EXPR_COL (passthrough) + EXPR_LIT_F64 (literal
        broadcast).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.

        Raises:
            Error on unsupported Expr kind.
            Error on Float64 DType mismatch when the EXPR_COL operand
            resolves to a non-Float64 column.
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            # The F64-channel agg/project path
            # (COUNT/SUM/MIN/MAX/AVG → RUNTIME_AGG_*_F64) feeds its val-expr
            # through this walker, but the SOURCE column carries its OWN
            # native dtype — an INT64 / INT32 column (e.g. `count(int_col)`,
            # `min(int64_col)`) is NOT storage-compatible with a float64
            # `as_primitive` reinterpret (that raises "column is int64 but
            # requested float64"). Dispatch on the source column's arrow_type
            # and numerically WIDEN integer columns to float64 here, mirroring
            # the SQL widening contract (an aggregate accumulated in the F64
            # channel reads its integer input widened, never bit-reinterpreted).
            var src_at = batch.column_arrow_type(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            if src_at == ArrowType.INT64:
                var col = batch.column_as_primitive_int64(runtime_idx)
                while k < n_sel:
                    var row = Int(sel.get(k))
                    out.append(Scalar[DType.float64](col.load[1](row)[0]))
                    k = k + 1
                return
            if src_at == ArrowType.INT32:
                var col = batch.column_as_primitive_int32(runtime_idx)
                while k < n_sel:
                    var row = Int(sel.get(k))
                    out.append(Scalar[DType.float64](col.load[1](row)[0]))
                    k = k + 1
                return
            # Float64 (and float64-storage-compatible) source: direct read.
            var col = batch.column_as_primitive_float64(runtime_idx)
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(col.load[1](row)[0])
                k = k + 1
            return

        if kind == EXPR_LIT_F64:
            var v = Scalar[DType.float64](node.f64)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        # Arithmetic arms use
        # BATCHED recursive evaluation, NOT per-row scalar recursion. See
        # `eval_to_list_i64_from_view` arithmetic arms above for the full
        # diagnosis and fix rationale (same bug, same fix shape, Float64
        # variant).
        #
        # IEEE-754 default semantics — NaN / Inf propagate; div-by-zero
        # produces +Inf / -Inf / NaN with NO raise. Matches DuckDB DOUBLE +
        # Polars Float64 conventions.
        if kind == EXPR_ADD_F64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] + rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_SUB_F64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] - rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_MUL_F64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] * rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_DIV_F64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                # IEEE-754: div-by-zero produces ±Inf or NaN, no raise.
                out.append(lhs_vals[k] / rhs_vals[k])
                k = k + 1
            return

        # First arity-1 arm in the F64 column walker. Recurses on the
        # single child (`node.left`) and applies `math.sqrt` element-
        # wise. IEEE-754: sqrt(<0)=NaN, sqrt(NaN)=NaN, sqrt(+Inf)=+Inf,
        # sqrt(-0.0)=-0.0. No raise on any input — matches the same
        # IEEE-754-default convention used by EXPR_DIV_F64 above.
        if kind == EXPR_SQRT_F64:
            var n_sel = sel.len()
            var child_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, child_vals
            )
            var k = 0
            while k < n_sel:
                out.append(sqrt(child_vals[k]))
                k = k + 1
            return

        # Unary F64 math (sin/
        # cos/asin/radians) column walker. Same arity-1 shape as
        # EXPR_SQRT_F64: recurse on `node.left`, apply element-wise.
        if (
            kind == EXPR_SIN_F64
            or kind == EXPR_COS_F64
            or kind == EXPR_ASIN_F64
            or kind == EXPR_RADIANS_F64
        ):
            var n_sel = sel.len()
            var child_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, child_vals
            )
            var deg2rad = Scalar[DType.float64](pi / 180.0)
            var k = 0
            while k < n_sel:
                var x = child_vals[k]
                if kind == EXPR_SIN_F64:
                    out.append(sin(x))
                elif kind == EXPR_COS_F64:
                    out.append(cos(x))
                elif kind == EXPR_ASIN_F64:
                    out.append(asin(x))
                else:  # EXPR_RADIANS_F64
                    out.append(x * deg2rad)
                k = k + 1
            return

        # Binary F64 atan2(y, x)
        # column walker. Arity-2: recurse on left (=y) and right (=x).
        if kind == EXPR_ATAN2_F64:
            var n_sel = sel.len()
            var y_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, y_vals
            )
            var x_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, x_vals
            )
            var k = 0
            while k < n_sel:
                out.append(atan2(y_vals[k], x_vals[k]))
                k = k + 1
            return

        # Binary F64 pow(base, exponent) column
        # walker. Arity-2: recurse on left (=base) and right (=exponent).
        if kind == EXPR_POW_F64:
            var n_sel = sel.len()
            var base_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, base_vals
            )
            var exp_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, exp_vals
            )
            var k = 0
            while k < n_sel:
                out.append(libm_pow(base_vals[k], exp_vals[k]))
                k = k + 1
            return

        # THE GENERIC unary-math
        # column walker. `node.col_idx` carries the `KMATH_*` op code; the
        # ladder that knows the whole 24-op space is `scalar_math._apply_unary`
        # and this arm is one call into it, so a NEW `MATH_*` op needs a line
        # there and NOT a fourth walker arm here. The five specific tags above
        # (SIN/COS/ASIN/RADIANS, and SQRT) predate this one and still serve
        # their own five ops; both routes land on the same libm call.
        if kind == EXPR_MATH_UNARY_F64:
            var n_sel = sel.len()
            var mu_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, mu_vals
            )
            var mu_op = UInt8(node.col_idx)
            var k = 0
            while k < n_sel:
                out.append(
                    Scalar[DType.float64](
                        _apply_unary(mu_op, Float64(mu_vals[k]))
                    )
                )
                k = k + 1
            return

        # AGG_CORR's synthetic cross-terms (`v1*v2`, `v1*v1`,
        # `v2*v2`) lower via `_translate_binary` to EXPR_MUL_I64 (kind 17)
        # when the operands are i64 columns. The F64 channel agg substrate
        # (RUNTIME_AGG_*_F64) feeds val-exprs through this walker, so an i64
        # arithmetic root must transparently widen to F64. Mirrors the
        # EXPR_COL arm's INT64 -> F64 widening: recurse
        # into the F64 walker which auto-widens i64 column leaves, then apply
        # the op in F64. SQL widening contract for F64 aggregates over
        # integer inputs (matches DuckDB CORR(int64, int64), Polars
        # correlation, and the SUM(int)/AVG(int) widening rule).
        # EXPR_LIT_I64 widens via Float64(i64).
        if kind == EXPR_LIT_I64:
            var v = Scalar[DType.float64](Float64(node.i64))
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        if kind == EXPR_ADD_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] + rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_SUB_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] - rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_MUL_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                out.append(lhs_vals[k] * rhs_vals[k])
                k = k + 1
            return

        if kind == EXPR_DIV_I64:
            var n_sel = sel.len()
            var lhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            var rhs_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.left, sel, lhs_vals
            )
            self.eval_to_list_f64_from_view[bo](
                batch_view, node.right, sel, rhs_vals
            )
            var k = 0
            while k < n_sel:
                # Integer division truncates toward zero (query_semantics.md
                # §5.1), so the widened quotient is truncated: 7 / 2 is 3.0,
                # not 3.5. Exact while both operands are below 2^53. `+ 0.0`
                # turns the -0.0 of a truncated -0.35 into the integer 0's
                # +0.0. A zero divisor gives +-Inf or NaN here, no raise.
                var q = lhs_vals[k] / rhs_vals[k]
                if q >= 0.0:
                    q = floor(q)
                else:
                    q = ceil(q)
                out.append(q + 0.0)
                k = k + 1
            return

        # A bare
        # EXPR_NULL value leaf widens to 0.0 in the F64 channel (its nullity is
        # tracked separately by the project driver; in the bridged-agg tail a
        # `THEN NULL` branch is rare — `ELSE 0` is the q8 shape — but a CASE
        # branch may carry it, so the value-walker must not raise on it).
        if kind == EXPR_NULL:
            var v = Scalar[DType.float64](0.0)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        # CAST(i AS double): evaluate the child as Int64 and widen each lane.
        if kind == EXPR_I64_TO_F64:
            var n_sel = sel.len()
            var child_vals = List[Scalar[DType.int64]](capacity=n_sel)
            self.eval_to_list_i64_from_view[bo](
                batch_view, node.left, sel, child_vals
            )
            var k = 0
            while k < n_sel:
                out.append(Scalar[DType.float64](Float64(child_vals[k])))
                k = k + 1
            return

        # Float64
        # CASE/WHEN (mirror of the EXPR_CASE_I64 arm in
        # `eval_to_list_i64_from_view`). First matching THEN per row, else the
        # ELSE value; conditions via `_eval_case_cond_mask_from_view`,
        # THEN/ELSE branches via this same F64 walker (which auto-widens i64
        # leaves — so `ELSE 0` lowered as EXPR_LIT_I64 widens to 0.0). Unblocks
        # q8's `sum(CASE WHEN s_nationkey=2 THEN l_disc_price ELSE 0)` bridged
        # agg tail.
        if kind == EXPR_CASE_F64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            var n_sel = sel.len()
            var n_rows = batch.num_rows()
            var then_lists = List[List[Scalar[DType.float64]]]()
            var masks = List[List[Scalar[DType.bool]]]()
            for c in range(n_pairs):
                var cond_mask = List[Scalar[DType.bool]](capacity=n_rows)
                for _r in range(n_rows):
                    cond_mask.append(Scalar[DType.bool](False))
                self._eval_case_cond_mask_from_view[bo](
                    batch, slots[2 * c], sel, cond_mask
                )
                masks.append(cond_mask^)
                var then_vals = List[Scalar[DType.float64]](capacity=n_sel)
                self.eval_to_list_f64_from_view[bo](
                    batch_view, slots[2 * c + 1], sel, then_vals
                )
                then_lists.append(then_vals^)
            var else_vals = List[Scalar[DType.float64]](capacity=n_sel)
            self.eval_to_list_f64_from_view[bo](
                batch_view, slots[len(slots) - 1], sel, else_vals
            )
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var picked = else_vals[k]
                for c in range(n_pairs):
                    if Bool(masks[c][row]):
                        picked = then_lists[c][k]
                        break
                out.append(picked)
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_f64_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supported: EXPR_COL + EXPR_LIT_F64 + EXPR_{ADD,SUB,"
            "MUL,DIV}_F64 + EXPR_SQRT_F64 + EXPR_LIT_I64 + EXPR_{ADD,"
            "SUB,MUL,DIV}_I64 [widened to F64] + EXPR_NULL + EXPR_I64_TO_F64"
            " + EXPR_CASE_F64)"
        )

    # =========================================================================
    # Int32 + String walkers. Per-DType project walker entry points for
    # the remaining DTypes.
    #
    # Scope:
    #   - Int32:  EXPR_COL + EXPR_LIT_I32. Arithmetic not supported.
    #   - String: EXPR_COL only. EXPR_LIT_STRING deferred (RuntimeExpr POD
    #             would need an `s: String` field — POD widening).
    #
    # Not supported here:
    #   - eval_to_list_f32_from_view  — needs `column_as_primitive_float32`
    #     accessor on RecordBatch.
    #   - eval_to_list_bool_from_view — needs `column_as_boolean` accessor
    #     on RecordBatch.
    #   - EXPR_LIT_STRING + string-arithmetic-projection routing.
    #   - I32 arithmetic (EXPR_ADD_I32 / SUB / MUL / DIV).
    #
    # Encapsulation invariants:
    #   - NO UnsafePointer in public surface.
    #   - NO wildcard origins.
    #   - NO partial-move via UnsafePointer(to=struct.field).take_pointee().
    # =========================================================================

    def eval_to_list_i32_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Scalar[DType.int32]],
    ) raises:
        """Per-DType Int32 project walker.

        Supports two Expr kinds:
          - EXPR_COL — gather column `expression_pool[expr_idx].col_idx`
            (resolved through `self.column_names` against the batch via
            `column_by_name` + `column_as_primitive_int32`) at each
            selected row.
          - EXPR_LIT_I32 — broadcast literal once per selected row. The
            literal value is carried in `RuntimeExpr.i64` (the I32 value
            was widened at make_lit_i32; we narrow at append time).

        Arithmetic (EXPR_ADD_I32 / SUB / MUL / DIV) is not supported.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.

        Raises:
            Error on unsupported Expr kind.
            Error on Int32 DType mismatch when the EXPR_COL operand
            resolves to a non-Int32 column (surfaced from the typed
            accessor `column_as_primitive_int32`).
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_primitive_int32(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(col.load[1](row)[0])
                k = k + 1
            return

        if kind == EXPR_LIT_I32:
            # Narrow the i64-widened literal to Int32 at append time.
            var v = Scalar[DType.int32](Int32(node.i64))
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        # Int32
        # arithmetic arms. Mirror of EXPR_{ADD,SUB,MUL,DIV}_I64 arithmetic;
        # each arm recursively evaluates left + right
        # sub-Expr per row via `_eval_scalar_i32_from_view`, applies the
        # operator, and appends.
        if kind == EXPR_ADD_I32:
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var lhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.left, row
                )
                var rhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.right, row
                )
                # RAISES on overflow: DuckDB's sentence.
                out.append(checked_add[DType.int32](lhs, rhs))
                k = k + 1
            return

        if kind == EXPR_SUB_I32:
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var lhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.left, row
                )
                var rhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.right, row
                )
                out.append(checked_sub[DType.int32](lhs, rhs))
                k = k + 1
            return

        if kind == EXPR_MUL_I32:
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var lhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.left, row
                )
                var rhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.right, row
                )
                out.append(checked_mul[DType.int32](lhs, rhs))
                k = k + 1
            return

        if kind == EXPR_DIV_I32:
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                var lhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.left, row
                )
                var rhs = self._eval_scalar_i32_from_view[bo](
                    batch_view, node.right, row
                )
                # Div-by-zero raises (Int32 has no Inf representation;
                # matches I64 + DuckDB integer-divide semantics).
                if rhs == Int32(0):
                    raise Error(
                        "ExpressionExecutor.eval_to_list_i32_from_view:"
                        " EXPR_DIV_I32 division by zero at row "
                        + String(row)
                    )
                # Truncates toward zero (-7 / 2 = -3), not Mojo's floor.
                out.append(_ee_div_trunc(lhs, rhs))
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_i32_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL + EXPR_LIT_I32 + EXPR_{ADD,SUB,MUL,DIV}"
            "_I32; EXPR_MOD_I32 is not supported)"
        )

    # =========================================================================
    # Bool column walker. Mirror of `eval_to_list_f64_from_view` shape;
    # emits `List[Scalar[DType.bool]]`. Supports:
    #   - EXPR_COL_BOOL — gather Bool column via `column_as_boolean`
    #     (BooleanArray; 1-bit packed), append per-selected-row.
    #   - EXPR_LIT_BOOL — broadcast literal `node.b` per selected row.
    #   - EXPR_NOT_BOOL — recurse on `node.left`, negate each element.
    #
    # Used by Project Bool-output arm to gather Bool-typed projection
    # values. Future EXPR_AND_BOOL / EXPR_OR_BOOL / EXPR_EQ_BOOL
    # column-walker arms can join here if a future bench/test
    # surfaces them; for now the filter-walker's existing
    # EXPR_AND / EXPR_OR / comparison family covers the Bool-mask use
    # case, and Bool-typed PROJECTION is restricted to EXPR_COL_BOOL /
    # EXPR_LIT_BOOL / EXPR_NOT_BOOL.
    # =========================================================================

    def eval_to_list_bool_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Scalar[DType.bool]],
    ) raises:
        """Per-DType Bool project walker.

        Mirror of `eval_to_list_f64_from_view` with Bool output type.
        Supports EXPR_COL_BOOL (passthrough Bool column),
        EXPR_LIT_BOOL (literal broadcast), EXPR_NOT_BOOL (per-row
        negation).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.

        Raises:
            Error on unsupported Expr kind.
            Error on Bool DType mismatch when an EXPR_COL_BOOL operand
            resolves to a non-Bool column (surfaced from the typed
            accessor `column_as_boolean`).
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL_BOOL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var bool_arr = batch.column_as_boolean(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(Scalar[DType.bool](bool_arr.get(row)))
                k = k + 1
            return

        if kind == EXPR_LIT_BOOL:
            var v = Scalar[DType.bool](node.b)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        if kind == EXPR_NOT_BOOL:
            var n_sel = sel.len()
            var child_vals = List[Scalar[DType.bool]](capacity=n_sel)
            self.eval_to_list_bool_from_view[bo](
                batch_view, node.left, sel, child_vals
            )
            var k = 0
            while k < n_sel:
                # Negate via Mojo's logical-not on Bool scalar.
                out.append(Scalar[DType.bool](not Bool(child_vals[k])))
                k = k + 1
            return

        # EXPR_IN_LIST as a Bool-PRODUCING projection (the CSE pass hoists
        # the OR's common IN_LIST subtrees into a `_cse_*` BOOL projection).
        # The scalar filter path (`_eval_in_list_from_view`) already owns the
        # per-DType set-membership probe; here we reuse it to compute the
        # SUBSET of `sel` that matches, then emit one Bool per survivor row
        # (in `sel` order). Both `sel` and the probe's `output_sel` are in
        # ascending row order, so a two-pointer merge yields the per-row mask.
        if kind == EXPR_IN_LIST:
            var n_sel = sel.len()
            var matched = RowSelectionVector(n_sel if n_sel > 0 else 1)
            _ = self._eval_in_list_from_view[bo](
                batch, node, expr_idx, sel, matched
            )
            var i_m = 0
            var n_m = matched.len()
            var k = 0
            while k < n_sel:
                var row = sel.get(k)
                if i_m < n_m and matched.get(i_m) == row:
                    out.append(Scalar[DType.bool](True))
                    i_m = i_m + 1
                else:
                    out.append(Scalar[DType.bool](False))
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_bool_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL_BOOL + EXPR_LIT_BOOL + EXPR_NOT_BOOL +"
            " EXPR_IN_LIST)"
        )

    def _eval_scalar_i32_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        row: Int,
    ) raises -> Scalar[DType.int32]:
        """Single-row Int32 scalar evaluator for arithmetic sub-Exprs.

        Routes EXPR_COL through the typed column accessor; EXPR_LIT_I32 returns
        the carried literal narrowed to Int32; arithmetic arms recurse.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the sub-Expr node to evaluate.
            row: Row index (resolved from `sel.get(k)` by the caller).

        Returns:
            One Int32 scalar.

        Raises:
            Error on unsupported kind (supports EXPR_COL + EXPR_LIT_I32 +
            EXPR_{ADD,SUB,MUL,DIV}_I32).
            Error on EXPR_DIV_I32 division by zero.
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_primitive_int32(runtime_idx)
            return col.load[1](row)[0]

        if kind == EXPR_LIT_I32:
            return Scalar[DType.int32](Int32(node.i64))

        if kind == EXPR_ADD_I32:
            var lhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.left, row
            )
            var rhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.right, row
            )
            return checked_add[DType.int32](lhs, rhs)

        if kind == EXPR_SUB_I32:
            var lhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.left, row
            )
            var rhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.right, row
            )
            return checked_sub[DType.int32](lhs, rhs)

        if kind == EXPR_MUL_I32:
            var lhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.left, row
            )
            var rhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.right, row
            )
            return checked_mul[DType.int32](lhs, rhs)

        if kind == EXPR_DIV_I32:
            var lhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.left, row
            )
            var rhs = self._eval_scalar_i32_from_view[bo](
                batch_view, node.right, row
            )
            if rhs == Int32(0):
                raise Error(
                    "ExpressionExecutor._eval_scalar_i32_from_view:"
                    " EXPR_DIV_I32 division by zero at row "
                    + String(row)
                )
            return _ee_div_trunc(lhs, rhs)

        raise Error(
            "ExpressionExecutor._eval_scalar_i32_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
        )

    def eval_to_list_string_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[String],
    ) raises:
        """Per-DType String project walker — no-validity convenience overload.

        Convenience overload that drops null-mask propagation: a row that
        is NULL in the source column emits an empty String into `out`.
        Use the 5-arg overload (`out_validity` parameter) when null-mask
        propagation is required.

        Supports `EXPR_COL` (legacy untyped column ref —
        emitted by older lowering paths that did not disambiguate
        String columns), EXPR_COL_STRING + EXPR_LIT_STRING.
        Combinators (EQ_STRING / NEQ_STRING) ARE
        NOT supported here — those produce Bool results.
        """
        var _scratch_validity = List[Bool](capacity=sel.len())
        self.eval_to_list_string_from_view[bo](
            batch_view, expr_idx, sel, out, _scratch_validity
        )

    def eval_to_list_string_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[String],
        mut out_validity: List[Bool],
    ) raises:
        """Per-DType String project walker with null-mask propagation.

        Extends
        the no-validity walker to ALSO emit a parallel
        `out_validity: List[Bool]` — True per row means "valid" (the
        emitted String IS the column's content), False means "null"
        (the emitted String is `String("")` placeholder; downstream
        callers must consult `out_validity[k]` before reading `out[k]`
        semantically).

        For EXPR_COL_STRING the walker reads `is_null(row)` from the
        source StringArray and emits False when the bit is null,
        otherwise True. For EXPR_LIT_STRING the walker emits True
        unconditionally (literals are never null in this catalog).

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.
            out_validity: Output validity buffer; method APPENDS
                `sel.len()` Bool values, parallel to `out` (out[k] is
                valid iff out_validity[k] is True).

        Raises:
            Error on unsupported Expr kind.
            Error on String DType mismatch when an EXPR_COL / EXPR_COL_STRING
            operand resolves to a non-String column (surfaced from
            the typed accessor `column_as_string`).
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL or kind == EXPR_COL_STRING:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_string(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                # propagate per-row validity from the source column.
                # StringArray.is_null short-circuits to False when no
                # validity bitmap is present (all-valid fast path).
                var is_n = col.is_null(row)
                if is_n:
                    # Null cell: emit an empty placeholder; downstream
                    # caller must consult out_validity[k] before reading.
                    out.append(String(""))
                    out_validity.append(False)
                else:
                    out.append(col.get(row))
                    out_validity.append(True)
                k = k + 1
            return

        if kind == EXPR_LIT_STRING:
            # Resolve literal from the side-table
            # string_pool (col_idx field repurposed as
            # string-pool index for EXPR_LIT_STRING nodes). Literals
            # are never null in this catalog — emit True validity
            # unconditionally.
            var v = self.string_pool[node.col_idx]
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v.copy())
                out_validity.append(True)
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_string_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL + EXPR_COL_STRING + EXPR_LIT_STRING)"
        )

    # -------------------------------------------------------------------------
    # BINARY project
    # walker. BINARY is exactly STRING WITHOUT UTF-8 validation: a
    # var-length byte array (offsets + data buffer). This walker mirrors
    # `eval_to_list_string_from_view` precisely, emitting `List[List[UInt8]]`
    # (one byte-list per selected row) instead of `List[String]`. It is the
    # FEED-side extraction the typed-join build payload passthrough needs to
    # carry a BINARY column through a join (the downstream drain re-emits the
    # bytes byte-exact as a BinaryArray).
    #
    # Supports EXPR_COL (legacy untyped column ref) + EXPR_COL_BINARY. There
    # is no EXPR_LIT_BINARY combinator family — BINARY is extraction-only.
    # -------------------------------------------------------------------------
    def eval_to_list_binary_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[List[UInt8]],
    ) raises:
        """Per-DType BINARY project walker — no-validity convenience overload.

        Convenience overload that drops null-mask propagation: a row that
        is NULL in the source column emits an empty byte list into `out`.
        Use the 5-arg overload (`out_validity` parameter) when null-mask
        propagation is required.
        """
        var _scratch_validity = List[Bool](capacity=sel.len())
        self.eval_to_list_binary_from_view[bo](
            batch_view, expr_idx, sel, out, _scratch_validity
        )

    def eval_to_list_binary_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[List[UInt8]],
        mut out_validity: List[Bool],
    ) raises:
        """Per-DType BINARY project walker with null-mask propagation.

        Mirror of the
        String walker (`eval_to_list_string_from_view`) for BINARY columns:
        BINARY is STRING without UTF-8 validation, so the byte-extraction
        path is identical except the output element type is `List[UInt8]`
        (raw bytes, byte-exact) rather than `String`.

        For EXPR_COL_BINARY the walker reads `is_null(row)` from the source
        BinaryArray and emits False per null row (the placeholder byte list
        is empty), otherwise True with the exact bytes via `BinaryArray.get`.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` byte lists.
            out_validity: Output validity buffer; method APPENDS
                `sel.len()` Bool values, parallel to `out` (out[k] is
                valid iff out_validity[k] is True).

        Raises:
            Error on unsupported Expr kind.
            Error on BINARY DType mismatch when an EXPR_COL / EXPR_COL_BINARY
            operand resolves to a non-BINARY column (surfaced from the
            typed accessor `column_as_binary`).
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL or kind == EXPR_COL_BINARY:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_binary(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                # Propagate per-row validity from the source column.
                # BinaryArray.is_null short-circuits to False when no
                # validity bitmap is present (all-valid fast path).
                var is_n = col.is_null(row)
                if is_n:
                    # Null cell: emit an empty byte-list placeholder;
                    # downstream caller must consult out_validity[k] before
                    # reading.
                    out.append(List[UInt8]())
                    out_validity.append(False)
                else:
                    out.append(col.get(row))
                    out_validity.append(True)
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_binary_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL + EXPR_COL_BINARY)"
        )

    # -------------------------------------------------------------------------
    # Decimal128 project walker. Output is a List[SIMD[DType.int128, 1]] +
    # (out_precision, out_scale) tuple. Supports:
    #   - EXPR_COL_DECIMAL128 (gather; reads (p, s) from Decimal128Array)
    #   - EXPR_LIT_DECIMAL128 (broadcast; reads (p, s) from decimal_pool)
    #   - EXPR_ADD_DECIMAL128 / EXPR_SUB_DECIMAL128 (arithmetic via
    #     decimal_add_i128 / decimal_sub_i128; result (p, s) via
    #     decimal_add_result_ps which is shared between add and sub)
    #   - EXPR_MUL_DECIMAL128 (decimal_mul_i128 + decimal_mul_result_ps)
    #   - EXPR_DIV_DECIMAL128 (decimal_div_i128 + decimal_div_result_ps)
    # Per-row overflow detection comes from the underlying decimal_arith
    # helpers (they raise Error on Decimal128 overflow).
    #
    # The walker COMPUTES the output (p, s) per recursion; the caller
    # (stage_runtime_program Project arm) uses the returned (p, s) when
    # building the Decimal128Array.
    # -------------------------------------------------------------------------

    def eval_to_list_decimal128_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[SIMD[DType.int128, 1]],
    ) raises -> Tuple[Int, Int]:
        """Per-DType Decimal128 project walker.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` i128 values.

        Returns:
            (precision, scale) of the output column. Caller uses this
            when building the Decimal128Array.

        Raises:
            Error on unsupported Expr kind.
            Error on Decimal128 overflow (propagated from
            decimal_{add,sub,mul,div}_i128).
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL_DECIMAL128:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_decimal128(runtime_idx)
            var p = col.precision
            var s = col.scale
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(col.get_i128(row))
                k = k + 1
            return (p, s)

        if kind == EXPR_LIT_DECIMAL128:
            var spec = self.decimal_pool[node.col_idx]
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(spec.value)
                k = k + 1
            return (spec.precision, spec.scale)

        if (
            kind == EXPR_ADD_DECIMAL128
            or kind == EXPR_SUB_DECIMAL128
        ):
            # Evaluate both children into scratch lists, then per-row
            # apply decimal_{add,sub}_i128 to fill `out` at the result
            # scale.
            var lvals = List[SIMD[DType.int128, 1]]()
            var lps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.left, sel, lvals
            )
            var rvals = List[SIMD[DType.int128, 1]]()
            var rps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.right, sel, rvals
            )
            var p1 = lps[0]
            var s1 = lps[1]
            var p2 = rps[0]
            var s2 = rps[1]
            var rps_out = decimal_add_result_ps(p1, s1, p2, s2)
            var out_p = rps_out[0]
            var out_s = rps_out[1]
            var n = len(lvals)
            var k = 0
            while k < n:
                if kind == EXPR_ADD_DECIMAL128:
                    out.append(decimal_add_i128(lvals[k], s1, rvals[k], s2, out_s))
                else:
                    out.append(decimal_sub_i128(lvals[k], s1, rvals[k], s2, out_s))
                k = k + 1
            return (out_p, out_s)

        if kind == EXPR_MUL_DECIMAL128:
            var lvals = List[SIMD[DType.int128, 1]]()
            var lps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.left, sel, lvals
            )
            var rvals = List[SIMD[DType.int128, 1]]()
            var rps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.right, sel, rvals
            )
            var p1 = lps[0]
            var s1 = lps[1]
            var p2 = rps[0]
            var s2 = rps[1]
            var rps_out = decimal_mul_result_ps(p1, s1, p2, s2)
            var out_p = rps_out[0]
            var out_s = rps_out[1]
            # Mul result is at raw scale s1+s2; if out_s differs (clamp
            # case where raw_scale would exceed 38, which is already a
            # raise in decimal_mul_result_ps; otherwise out_s == s1+s2)
            # we use rescale path. In the common case s1+s2 == out_s.
            var n = len(lvals)
            var k = 0
            while k < n:
                var prod = decimal_mul_i128(lvals[k], rvals[k])
                # `decimal_mul_i128` produces the result at the natural
                # scale s1+s2 (per decimal_arith convention). When out_s
                # differs (rare clamp), rescale via i256 half-up.
                if out_s != s1 + s2:
                    var prod256 = prod.cast[DType.int256]()
                    var rescaled = rescale_i256_half_up(
                        prod256, s1 + s2, out_s
                    )
                    out.append(rescaled.cast[DType.int128]())
                else:
                    out.append(prod)
                k = k + 1
            return (out_p, out_s)

        if kind == EXPR_DIV_DECIMAL128:
            var lvals = List[SIMD[DType.int128, 1]]()
            var lps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.left, sel, lvals
            )
            var rvals = List[SIMD[DType.int128, 1]]()
            var rps = self.eval_to_list_decimal128_from_view[bo](
                batch_view, node.right, sel, rvals
            )
            var p1 = lps[0]
            var s1 = lps[1]
            var p2 = rps[0]
            var s2 = rps[1]
            var rps_out = decimal_div_result_ps(p1, s1, p2, s2)
            var out_p = rps_out[0]
            var out_s = rps_out[1]
            var n = len(lvals)
            var k = 0
            while k < n:
                out.append(decimal_div_i128(lvals[k], s1, rvals[k], s2, out_s))
                k = k + 1
            return (out_p, out_s)

        raise Error(
            "ExpressionExecutor.eval_to_list_decimal128_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL_DECIMAL128 + EXPR_LIT_DECIMAL128 +"
            + " EXPR_{ADD,SUB,MUL,DIV}_DECIMAL128)"
        )

    # -------------------------------------------------------------------------
    # Float32 project
    # walker. Mirrors the String walker's EXPR_COL-only shape.
    # F32 isn't on the TPC-H critical path so we ship
    # the minimum surface (passthrough). EXPR_LIT_F32 + F32-arithmetic
    # deferred (RuntimeExpr lacks an f32 field; broadening the POD or
    # narrowing f64 → f32 at append time would be needed to support it).
    # -------------------------------------------------------------------------

    def eval_to_list_f32_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Scalar[DType.float32]],
    ) raises:
        """Per-DType Float32 project walker.

        this supports ONE Expr kind:
          - EXPR_COL — gather column at each selected row via
            `column_as_primitive_float32`.

        EXPR_LIT_F32 + arithmetic (ADD/SUB/MUL/DIV) are not supported.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.

        Raises:
            Error on unsupported Expr kind.
            Error on Float32 DType mismatch when the EXPR_COL operand
            resolves to a non-Float32 column.
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_primitive_float32(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                out.append(col.load[1](row)[0])
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_f32_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL only; EXPR_LIT_F32 + F32-"
            "arithmetic are not supported)"
        )

    # -------------------------------------------------------------------------
    # Boolean project
    # walker. Mirrors the String walker's EXPR_COL shape; EXPR_LIT_BOOL is
    # supported here since the RuntimeExpr POD already carries a `b: Bool`
    # field (no widening needed). Boolean arithmetic (AND/OR/NOT) deferred —
    # those are typically filter-tree predicates, not projection expressions.
    # -------------------------------------------------------------------------

    def eval_to_list_bool_from_view[
        bo: Origin[mut=False],
    ](
        imm self,
        batch_view: BatchView[bo],
        expr_idx: Int,
        ref sel: RowSelectionVector,
        mut out: List[Bool],
    ) raises:
        """Per-DType Boolean project walker.

        this supports two Expr kinds:
          - EXPR_COL — gather column at each selected row via
            `column_as_boolean`.
          - EXPR_LIT_BOOL — broadcast literal once per selected row.
            The literal value is carried in `RuntimeExpr.b`.

        Boolean-tree arithmetic (EXPR_AND, EXPR_OR) is a FILTER-side concern
        and is handled by `select_expression_from_view`; not provided here.

        Args:
            batch_view: Read-only typed borrow over the source RecordBatch.
            expr_idx: Pool slot of the project expression's root node.
            sel: Filter survivors.
            out: Output buffer; method APPENDS `sel.len()` values.

        Raises:
            Error on unsupported Expr kind.
            Error on Boolean DType mismatch when the EXPR_COL operand
            resolves to a non-Boolean column.
        """
        ref batch = batch_view._batch[]
        var node = self.expression_pool[expr_idx]
        var kind = node.kind

        if kind == EXPR_COL:
            var col_name = self.column_names[node.col_idx]
            var runtime_idx = batch.column_by_name(col_name)
            var col = batch.column_as_boolean(runtime_idx)
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                var row = Int(sel.get(k))
                # BooleanArray.get(row) returns Bool (raises on out-of-range).
                out.append(col.get(row))
                k = k + 1
            return

        if kind == EXPR_LIT_BOOL:
            var v = node.b
            var n_sel = sel.len()
            var k = 0
            while k < n_sel:
                out.append(v)
                k = k + 1
            return

        # EXPR_IN_LIST as a Bool-PRODUCING projection. Sibling of the
        # `List[Scalar[DType.bool]]` overload above; emits `List[Bool]`.
        # Reuses the scalar filter probe `_eval_in_list_from_view` to compute
        # the matching subset of `sel`, then two-pointer merges (both
        # ascending) to emit one Bool per survivor row in `sel` order.
        if kind == EXPR_IN_LIST:
            var n_sel = sel.len()
            var matched = RowSelectionVector(n_sel if n_sel > 0 else 1)
            _ = self._eval_in_list_from_view[bo](
                batch, node, expr_idx, sel, matched
            )
            var i_m = 0
            var n_m = matched.len()
            var k = 0
            while k < n_sel:
                var row = sel.get(k)
                if i_m < n_m and matched.get(i_m) == row:
                    out.append(True)
                    i_m = i_m + 1
                else:
                    out.append(False)
                k = k + 1
            return

        raise Error(
            "ExpressionExecutor.eval_to_list_bool_from_view: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(expr_idx)
            + " (supports EXPR_COL + EXPR_LIT_BOOL + EXPR_IN_LIST;"
            " Boolean-tree arithmetic is a filter-side concern)"
        )

    def _eval_bool(
        imm self,
        mut batch: RecordBatch,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
        mut temp_false: RowSelectionVector,
    ) raises -> Int:
        """Recursive walker — evaluates a boolean-producing node into `output_sel`.

        Dispatches on `self.expression_pool[idx].kind` via a comptime-if
        chain. The DType of the comparison is encoded in the tag
        (EXPR_GT_I64 → DType.int64, EXPR_LT_F64 → DType.float64, etc.).

        Per-AND scratch allocation: each AND recursion stack-allocates a
        local RowSelectionVector for the LEFT-child's surviving rows.
        For deeply-nested AND (Q6's 4-conjunct shape, ~5 deep), this is
        4 buffer allocations per select_expression call (each 2048 * 4
        bytes = 8 KB raw + 64-byte alignment overhead). Compared to the
        4 column copies in `_dispatch_comparison`, this is negligible.
        They could be hoisted onto FilterState if profiling shows them.

        Args:
            idx: Pool slot index of the node to evaluate.
            input_sel: Selection vector that narrows the source rows to
                consider. Used as `sel_in` for sel_kernels.
            output_sel: Selection vector that receives the surviving
                rows. Reset by the kernel on entry (per sel_kernels'
                contract).

        Returns:
            Surviving row count = `output_sel.len()` after the call.

        Raises:
            Error on unknown node kind (including EXPR_OR, which this
            walker does not serve) or on Col/DType mismatches.
        """
        var node = self.expression_pool[idx]
        var kind = node.kind

        # ---- AND: recursive descent over the conjunction ----------------
        # Local scratch sel for the LEFT-child's surviving rows. The
        # RIGHT child uses it as its sel_in (gather-path narrowing
        # against left's true_sel). Children fire in literal AST
        # order (left-then-right); the adaptive entry points permute it.
        if kind == EXPR_AND:
            var left_idx = node.left
            var right_idx = node.right
            # Size `left_temp` to the batch row count, NOT the default 2048.
            # The LEFT child's SIMD identity fast path writes up to
            # `col.length == n_rows` survivor indices through
            # `append_vec_first_k`, whose overflow guard is a debug_assert
            # (elided in release). A default-2048 `left_temp` on a >2048-row
            # batch (e.g. a nested AND under an OR root that
            # `_flatten_and_chain` does not flatten) silently writes-after-
            # free into recycled tcmalloc memory. Mirror of the n-sizing in
            # the BatchView walker (`_eval_bool_from_view`).
            var n_left = batch.num_rows()
            var left_temp = RowSelectionVector(n_left if n_left > 0 else 1)
            _ = self._eval_bool(
                batch, left_idx, input_sel, left_temp, temp_false
            )
            return self._eval_bool(
                batch, right_idx, left_temp, output_sel, temp_false
            )

        # ---- Comparisons: leaf dispatch into sel_kernels ----------------
        # Per-DType + per-op fanout via comptime if chain. Each arm calls
        # `_dispatch_comparison[T, op]` which extracts the Col / Lit
        # operands and invokes `binary_select_col_lit` or
        # `binary_select_col_col`.
        if kind == EXPR_GT_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_GT](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_GE_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_GE](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_LT_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_LT](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_EQ_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_EQ](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_GT_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_GT](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_GE_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_GE](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_LT_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_LT](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_LE_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_LE](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        # sibling to EXPR_LE_F64 / EXPR_LT_I64 in the legacy mut-batch eval.
        if kind == EXPR_LE_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_LE](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        # sibling to EXPR_EQ_I64 / EXPR_LE_F64 in the legacy mut-batch eval.
        if kind == EXPR_EQ_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_EQ](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        # F2 numeric NE: EXPR_NE_I64 / EXPR_NE_F64 in the legacy
        # mut-batch walker too (sibling of the EQ arms), for any non-from_view
        # caller.
        if kind == EXPR_NE_I64:
            return self._dispatch_comparison[DType.int64, BIN_OP_NE](
                batch, node, idx, input_sel, output_sel, temp_false
            )
        if kind == EXPR_NE_F64:
            return self._dispatch_comparison[DType.float64, BIN_OP_NE](
                batch, node, idx, input_sel, output_sel, temp_false
            )

        # EXPR_IN_LIST is wired in `_eval_bool_from_view` (the
        # ref-batch sibling, which is what `select_expression_from_view`
        # -- the Stage filter path -- dispatches through). The legacy
        # mut-batch `_eval_bool` raises here as it does for any tag
        # outside its set, matching the EXPR_OR shape: production
        # plans go through the from_view path.
        if kind == EXPR_IN_LIST:
            raise Error(
                "ExpressionExecutor._eval_bool: EXPR_IN_LIST is wired"
                " in the ref-batch `_eval_bool_from_view` arm only"
                " (the production Stage filter path). Callers of the"
                " legacy mut-batch `select_expression` must route"
                " through `select_expression_from_view` to reach the"
                " IN-list arm."
            )

        # ---- Unsupported kinds -------------------------------------------
        # EXPR_OR is not supported in this walker (disjunction over
        # SelectionVectors).
        # Top-level EXPR_LIT_* / EXPR_COL is a programming error
        # (a non-boolean expression at the root of a filter).
        if kind == EXPR_OR:
            raise Error(
                "ExpressionExecutor._eval_bool: EXPR_OR not supported"
                " (disjunction over SelectionVectors is not implemented)"
            )
        raise Error(
            "ExpressionExecutor._eval_bool: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (top-level expression must evaluate to Bool)"
        )

    def _dispatch_comparison[
        T: DType, op: UInt8
    ](
        imm self,
        mut batch: RecordBatch,
        node: RuntimeExpr,
        idx: Int,
        ref input_sel: RowSelectionVector,
        mut output_sel: RowSelectionVector,
        mut temp_false: RowSelectionVector,
    ) raises -> Int:
        """Extract Col / Lit operands + dispatch to sel_kernels.

        Convention (matches the typed-AST `to_expr` shape from
        `expr_ast.mojo`):
          - LEFT operand is expected to be a Col (EXPR_COL).
          - RIGHT operand is expected to be a Lit (EXPR_LIT_*) — column-
            vs-literal is the dominant filter shape in TPC-H Q1/Q6.
          - LEFT=Col AND RIGHT=Col is also supported (col-vs-col compare).
          - LEFT=Lit AND RIGHT=Col is rejected (literal-on-left is
            not normalized; the typed-AST `to_expr` always produces
            Col-on-left because column operands chain via Col*.__cmp__
            with Lit on the right).

        Per-DType inlining (Mojo 1.0.0b1 constraint): `PrimitiveArray[T]`
        is NOT `ImplicitlyCopyable`, so a free `_load_column_typed[T]`
        helper can't return `PrimitiveArray[T]` via `rebind` (rebind
        requires the source to be ImplicitlyCopyable). The dispatch is
        therefore inlined per-DType: each `@parameter if` arm extracts
        the column directly via the matching RecordBatch accessor and
        calls the sel_kernel inline with the concrete DType.

        Args:
            batch: The input batch (read-only borrow). All `RecordBatch`
                typed column accessors (`column_as_primitive_int64`, etc.)
                are `read self` methods; no mutation of cached state
                occurs, so the executor evaluates over an immutable batch.
            node: The comparison RuntimeExpr (kind already validated by
                the caller).
            idx: The comparison node's pool slot (used in error messages).
            input_sel: Selection vector narrowing source rows.
            output_sel: Surviving rows.

        Returns:
            Surviving row count.
        """
        var left = self.expression_pool[node.left]
        var right = self.expression_pool[node.right]

        if left.kind != EXPR_COL:
            raise Error(
                "ExpressionExecutor: comparison at pool slot "
                + String(idx)
                + " expects EXPR_COL on the LEFT (literal-"
                "on-left is not normalized)"
            )

        # Validate that any literal operand matches `T` (early-fail with a
        # readable error; sel_kernels would otherwise surface a DType
        # mismatch deeper in the stack).
        if right.kind != EXPR_COL:
            _validate_lit_dtype[T](right, idx)

        # Per-DType inlining. Each arm extracts the LEFT column via the
        # matching `column_as_primitive_*` accessor, then either:
        #   - Calls `binary_select_col_col` if right is also a Col.
        #   - Reads the literal payload + calls `binary_select_col_lit`.
        # NOTE: column extraction COPIES the column buffer per
        # PrimitiveArray's ownership contract (Column.as_primitive[T]()).
        # Correct as is; this could become a zero-copy borrow once `column_at()` is extended with a typed
        # accessor.
        # Resolve column NAMES
        # to runtime batch positions via `batch.column_by_name`. The
        # `col_idx` field on the EXPR_COL RuntimeExpr is now a SLOT
        # INDEX into `self.column_names`, NOT a position in the
        # LogicalPlan child schema. This is robust to projection-
        # pushdown column reordering. Cost: O(k) per call where k = schema column count
        # (typically ≤ 10) — ~2μs/batch on Q6, negligible vs the per-
        # comparison column-copy cost.
        var left_name = self.column_names[left.col_idx]
        var left_runtime_idx = batch.column_by_name(left_name)

        comptime if T == DType.int64:
            var left_col = batch.column_as_primitive_int64(left_runtime_idx)
            if right.kind == EXPR_COL:
                var right_name = self.column_names[right.col_idx]
                var right_runtime_idx = batch.column_by_name(right_name)
                var right_col = batch.column_as_primitive_int64(right_runtime_idx)
                return binary_select_col_col[DType.int64, op](
                    left_col, right_col, input_sel,
                    output_sel, temp_false,
                )
            return binary_select_col_lit[DType.int64, op](
                left_col,
                Scalar[DType.int64](right.i64),
                input_sel, output_sel, temp_false,
            )
        elif T == DType.float64:
            var left_col = batch.column_as_primitive_float64(left_runtime_idx)
            if right.kind == EXPR_COL:
                var right_name = self.column_names[right.col_idx]
                var right_runtime_idx = batch.column_by_name(right_name)
                var right_col = batch.column_as_primitive_float64(
                    right_runtime_idx
                )
                return binary_select_col_col[DType.float64, op](
                    left_col, right_col, input_sel,
                    output_sel, temp_false,
                )
            return binary_select_col_lit[DType.float64, op](
                left_col,
                Scalar[DType.float64](right.f64),
                input_sel, output_sel, temp_false,
            )
        elif T == DType.int32:
            var left_col = batch.column_as_primitive_int32(left_runtime_idx)
            if right.kind == EXPR_COL:
                var right_name = self.column_names[right.col_idx]
                var right_runtime_idx = batch.column_by_name(right_name)
                var right_col = batch.column_as_primitive_int32(right_runtime_idx)
                return binary_select_col_col[DType.int32, op](
                    left_col, right_col, input_sel,
                    output_sel, temp_false,
                )
            # Int32 literals share the i64 payload (there is no I32 literal
            # factory; they narrow at construction time).
            return binary_select_col_lit[DType.int32, op](
                left_col,
                Scalar[DType.int32](Int32(right.i64)),
                input_sel, output_sel, temp_false,
            )
        else:
            raise Error(
                "ExpressionExecutor._dispatch_comparison: unsupported DType"
                + " (supports int64 / float64 / int32; there are no"
                " EXPR_*_F32 tags)"
            )

    # =========================================================================
    # CellSource-parametric PER-CELL walker (Path 4).
    #
    # Shape B: this is the orientation-AGNOSTIC scalar walker; the `CS`
    # conformer (ColumnCellSource or RowCellSource) is bound at the caller's
    # dispatch seam. It is SEPARATE from the column-vectorized `_*_from_view`
    # SIMD walker above:
    #
    #   - `_*_from_view`   : whole-column SIMD via `sel_kernels` — the Path-2
    #                        production hot path.
    #   - `_*_from_source` : per-cell scalar recursion via `CS.read_*()` — the
    #                        row-major per-cell walker. RowBlock is row-major,
    #                        so a column's cells are strided across rows and
    #                        cannot present a contiguous PrimitiveArray to the
    #                        SIMD kernels; the per-cell shape is the only one
    #                        that works for the row orientation.
    #
    # Per-EXPR_* tag logic is shared between the two orientations through
    # `CS`: ColumnCellSource proves the abstraction is orientation-uniform;
    # RowCellSource is what the row path binds. The Bool tags served per cell
    # are the comparisons over the I64 / U64 / F64 / mixed / DECIMAL128 /
    # STRING families, LIKE, REGEXP, IS [NOT] NULL, AND, OR and NOT; IN-list
    # is column-path only. On a nullable source `_eval_kleene_from_source`
    # applies SQL three-valued logic; `_eval_bool_present_from_source` is the
    # two-valued walker for rows whose operands are present.
    #
    # Encapsulation: NO UnsafePointer / wildcard in any signature; the `CS`
    # trait bound carries the orientation. The walker only calls `CS.read_*`
    # for cell access and recurses on `self.expression_pool`.
    # =========================================================================

    def select_filter_from_source[
        CS: CellSource
    ](imm self, src: CS) raises -> RowSelectionVector:
        """Evaluate the root Bool predicate per-row over `src`.

        Returns a RowSelectionVector of the row indices (0-based within
        `src`) for which the root expression evaluates TRUE. This is the
        per-cell analog of `select_expression` — the row-streaming stage's filter
        step calls it.

        The root expression must evaluate to Bool (a comparison or AND/OR
        combinator); a non-Bool root raises.

        SQL three-valued logic: a WHERE keeps a row only when its predicate is
        TRUE, never when it is UNKNOWN. On a source that carries a validity
        region (`src.has_validity()`) each row goes through
        `_eval_kleene_from_source`, which reads a predicate whose value operand
        is NULL as UNKNOWN and combines AND / OR / NOT by Kleene's tables. A
        non-nullable layout has no NULL cell, so it runs the two-valued
        `_eval_bool_present_from_source` and never consults validity.
        """
        var n = src.num_rows()
        var out = RowSelectionVector(n if n > 0 else 1)
        var nullable = src.has_validity()
        var row = 0
        while row < n:
            var keep: Bool
            if nullable:
                keep = (
                    self._eval_kleene_from_source[CS](src, self.root_idx, row)
                    == _KLEENE_TRUE
                )
            else:
                keep = self._eval_bool_present_from_source[CS](
                    src, self.root_idx, row
                )
            if keep:
                out.append(UInt32(row))
            row += 1
        return out^

    def _eval_bool_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Bool:
        """True iff the Bool sub-tree at `idx` is TRUE for `row` under SQL
        three-valued logic (FALSE and UNKNOWN both answer False). The CASE
        arms of the value walkers use it for their WHEN conditions.

        On a nullable source this is `_eval_kleene_from_source == TRUE`; on a
        non-nullable one every cell is present and the two-valued
        `_eval_bool_present_from_source` answers directly."""
        if src.has_validity():
            return (
                self._eval_kleene_from_source[CS](src, idx, row) == _KLEENE_TRUE
            )
        return self._eval_bool_present_from_source[CS](src, idx, row)

    def _eval_bool_present_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Bool:
        """Two-valued per-cell Bool walker: reads every operand cell as
        present. Mirrors `_eval_bool_from_view`'s tag dispatch, but reads ONE
        cell per leaf via `CS.read_*` and returns a scalar Bool for `row` (no
        selection vectors).

        Callers guarantee no operand it reads is NULL: either the source has
        no validity region, or `_eval_kleene_from_source` has checked the
        leaf's operands before asking for its value."""
        var node = self.expression_pool[idx]
        var kind = node.kind

        if kind == EXPR_AND:
            return self._eval_bool_present_from_source[CS](
                src, node.left, row
            ) and self._eval_bool_present_from_source[CS](src, node.right, row)

        if kind == EXPR_OR:
            return self._eval_bool_present_from_source[CS](
                src, node.left, row
            ) or self._eval_bool_present_from_source[CS](src, node.right, row)

        # Integer comparison family (I64 logical; ColumnCellSource /
        # RowCellSource widen i32 storage to i64 in read_i64).
        if (
            kind == EXPR_GT_I64
            or kind == EXPR_GE_I64
            or kind == EXPR_LT_I64
            or kind == EXPR_LE_I64
            or kind == EXPR_EQ_I64
            or kind == EXPR_NE_I64
        ):
            var lv = self._eval_i64_from_source[CS](src, node.left, row)
            var rv = self._eval_i64_from_source[CS](src, node.right, row)
            if kind == EXPR_GT_I64:
                return lv > rv
            if kind == EXPR_GE_I64:
                return lv >= rv
            if kind == EXPR_LT_I64:
                return lv < rv
            if kind == EXPR_LE_I64:
                return lv <= rv
            if kind == EXPR_NE_I64:  # F2 numeric NE
                return lv != rv
            return lv == rv  # EXPR_EQ_I64

        # UNSIGNED INT64 comparison family. A U64 column read as a
        # signed Int64 would wrap negative above Int64.MAX, silently
        # mis-ordering a range predicate — so each side is
        # read via `read_u64` and compared as native UInt64 (unsigned
        # ordering). EQ is bit-equality. Narrow unsigned (U8/U16/U32) do NOT
        # route here (their max fits positively in Int64 via read_i64).
        if (
            kind == EXPR_GT_U64
            or kind == EXPR_GE_U64
            or kind == EXPR_LT_U64
            or kind == EXPR_LE_U64
            or kind == EXPR_EQ_U64
            or kind == EXPR_NE_U64
        ):
            var lv = self._eval_u64_from_source[CS](src, node.left, row)
            var rv = self._eval_u64_from_source[CS](src, node.right, row)
            if kind == EXPR_GT_U64:
                return lv > rv
            if kind == EXPR_GE_U64:
                return lv >= rv
            if kind == EXPR_LT_U64:
                return lv < rv
            if kind == EXPR_LE_U64:
                return lv <= rv
            if kind == EXPR_NE_U64:  # F2 numeric NE (unsigned)
                return lv != rv
            return lv == rv  # EXPR_EQ_U64

        # Float comparison family (F64 logical; sources widen int / f32).
        # The *_F64_MIXED tags share this arm (children widen transparently).
        if (
            kind == EXPR_GT_F64
            or kind == EXPR_GE_F64
            or kind == EXPR_LT_F64
            or kind == EXPR_LE_F64
            or kind == EXPR_EQ_F64
            or kind == EXPR_NE_F64
            or kind == EXPR_GT_F64_MIXED
            or kind == EXPR_GE_F64_MIXED
            or kind == EXPR_LT_F64_MIXED
            or kind == EXPR_LE_F64_MIXED
            or kind == EXPR_EQ_F64_MIXED
        ):
            var lv = self._eval_f64_from_source[CS](src, node.left, row)
            var rv = self._eval_f64_from_source[CS](src, node.right, row)
            if kind == EXPR_GT_F64 or kind == EXPR_GT_F64_MIXED:
                return lv > rv
            if kind == EXPR_GE_F64 or kind == EXPR_GE_F64_MIXED:
                return lv >= rv
            if kind == EXPR_LT_F64 or kind == EXPR_LT_F64_MIXED:
                return lv < rv
            if kind == EXPR_LE_F64 or kind == EXPR_LE_F64_MIXED:
                return lv <= rv
            if kind == EXPR_NE_F64:  # F2 numeric NE (float)
                return lv != rv
            return lv == rv  # EXPR_EQ_F64 / EXPR_EQ_F64_MIXED

        # ── DECIMAL128 comparison family ───────────
        # EQ / NEQ / GT / LT / GE / LE over DECIMAL128 operands. Each side
        # resolves to EXPR_COL_DECIMAL128 (read the 16-byte cell's raw signed
        # Int128 via CS.read_i128) or EXPR_LIT_DECIMAL128 (the literal's i128
        # from decimal_pool). Reading only the LOW 8 bytes of the 16-byte cell
        # would be silently wrong, so this reads the full int128 width.
        # The walker is SCALE-AWARE — each operand's scale is
        # resolved (`_eval_decimal_scale_from_source`: column -> CS.decimal_scale_of
        # via the threaded col_scales table; literal -> decimal_pool.scale) and
        # passed to `_compare_decimal128`, which rescales the smaller-scale side
        # UP via an i256 intermediate (matching the column path it now replaces).
        # Same-scale comparisons read equal scales and hit the fast
        # path. Like every arm of this two-valued walker it reads its operand
        # cells as present; `_eval_kleene_from_source` handles a NULL operand.
        if (
            kind == EXPR_EQ_DECIMAL128
            or kind == EXPR_NEQ_DECIMAL128
            or kind == EXPR_GT_DECIMAL128
            or kind == EXPR_LT_DECIMAL128
            or kind == EXPR_GE_DECIMAL128
            or kind == EXPR_LE_DECIMAL128
        ):
            var lv = self._eval_i128_from_source[CS](src, node.left, row)
            var rv = self._eval_i128_from_source[CS](src, node.right, row)
            var ls = self._eval_decimal_scale_from_source[CS](src, node.left)
            var rs = self._eval_decimal_scale_from_source[CS](src, node.right)
            return _compare_decimal128(lv, ls, rv, rs, kind)

        # ── String comparison family ─────────────────
        # ==, != (EQ/NEQ) + lexicographic <, >, <=, >= over STRING operands.
        # Each side resolves to EXPR_COL_STRING (read via CS.read_string) or
        # EXPR_LIT_STRING (read from string_pool). Byte-wise lexicographic
        # `_str_compare` mirrors the column `_*_from_view` arm exactly. Operand
        # cells are read as present; `_eval_kleene_from_source` handles NULL.
        if (
            kind == EXPR_EQ_STRING
            or kind == EXPR_NEQ_STRING
            or kind == EXPR_GT_STRING
            or kind == EXPR_LT_STRING
            or kind == EXPR_GE_STRING
            or kind == EXPR_LE_STRING
        ):
            var lv = self._eval_string_from_source[CS](src, node.left, row)
            var rv = self._eval_string_from_source[CS](src, node.right, row)
            if kind == EXPR_EQ_STRING:
                return lv == rv
            if kind == EXPR_NEQ_STRING:
                return lv != rv
            var c = _str_compare(lv, rv)
            if kind == EXPR_GT_STRING:
                return c > 0
            if kind == EXPR_LT_STRING:
                return c < 0
            if kind == EXPR_GE_STRING:
                return c >= 0
            return c <= 0  # EXPR_LE_STRING

        # ── String LIKE (ROW-NATIVE LIKE) ──────────────────────────
        # SQL LIKE over a STRING value column + a string-literal pattern.
        # `node.left` resolves to EXPR_COL_STRING (read via CS.read_string);
        # `node.right` resolves to EXPR_LIT_STRING (the pattern from
        # string_pool). Reuses the field-tested `_string_like_match` (`%` =
        # zero-or-more bytes, `_` = exactly one byte). Mirrors the column-path
        # EXPR_LIKE_STRING arm in `_eval_bool_from_view`. Operand cells are
        # read as present; `_eval_kleene_from_source` handles NULL.
        if kind == EXPR_LIKE_STRING:
            var lv = self._eval_string_from_source[CS](src, node.left, row)
            var pattern = self._eval_string_from_source[CS](
                src, node.right, row
            )
            return _string_like_match(lv, pattern)

        # ── regexp_like(col, 'pat') (ROW-NATIVE) ─────
        # SQL `regexp_like` / `~` over a STRING value column + a compiled regex
        # program. `node.left` resolves to EXPR_COL_STRING (read via
        # CS.read_string); `node.col_idx` is REPURPOSED as the index into the
        # `regex_pool` side-table (the program is COMPILED ONCE at segment setup,
        # NOT per row). Reuses the column oracle's `regexp_like_scalar(text, prog)`
        # — the SAME Thompson-NFA / Pike-VM leaf the column path runs — so the
        # row path is value-identical to `eval_regexp_like`, NOT a reimpl. The
        # value cell is read as present; `_eval_kleene_from_source` reads a
        # NULL value as UNKNOWN.
        if kind == EXPR_REGEXP:
            var rv = self._eval_string_from_source[CS](src, node.left, row)
            return regexp_like_scalar(rv, self.regex_pool[node.col_idx])

        # ── F10 IS NULL / IS NOT NULL (generic per-cell validity) ───────────
        # EXPR_IS_NULL_CELL / EXPR_IS_NOT_NULL_CELL carry the operand's LOGICAL
        # column index in `col_idx` (arity-1 leaf-pattern). `CS.is_null` reads
        # the FORM-ii validity bitmap (RowCellSource) — a non-nullable layout
        # reports every cell present. These are 3VL-correct for the unary null
        # tests: IS NULL emits True on null rows, IS NOT NULL on present rows.
        if kind == EXPR_IS_NULL_CELL:
            return src.is_null(row, node.col_idx)
        if kind == EXPR_IS_NOT_NULL_CELL:
            return not src.is_null(row, node.col_idx)

        # ── NOT (unary boolean negation) ─────────────────────────────────
        # EXPR_NOT_BOOL carries the child bool sub-expr in `node.left`. With
        # every operand present the child is TRUE or FALSE, so NOT is the
        # two-valued negation. This also serves NOT LIKE: `col NOT LIKE 'pat'`
        # lowers to NOT(EXPR_LIKE_STRING).
        if kind == EXPR_NOT_BOOL:
            return not self._eval_bool_present_from_source[CS](
                src, node.left, row
            )

        raise Error(
            "ExpressionExecutor._eval_bool_present_from_source: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (the row-major per-cell walker supports the numeric"
            " comparison + AND/OR subset + STRING ==/!=/<,>,<=,>= + LIKE +"
            " REGEXP + NOT + DECIMAL128 comparisons; in-list arms are"
            " column-path only)"
        )

    def _eval_kleene_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> UInt8:
        """SQL three-valued value of the Bool sub-tree at `idx` for `row`:
        `_KLEENE_FALSE`, `_KLEENE_TRUE` or `_KLEENE_NULL` (UNKNOWN).

        AND / OR / NOT follow Kleene's tables (`FALSE AND UNKNOWN = FALSE`,
        `TRUE OR UNKNOWN = TRUE`, `NOT UNKNOWN = UNKNOWN`). AND stops at a
        FALSE left side and OR at a TRUE one, since the right side cannot
        change the answer. IS NULL / IS NOT NULL are never UNKNOWN. A
        comparison, LIKE or REGEXP leaf is UNKNOWN when one of its value
        operands is NULL (`_value_is_null_from_source`); otherwise its operands
        are present and `_eval_bool_present_from_source` gives its value. A
        leaf with a NULL operand is not evaluated, so arithmetic over a NULL
        cell's stored bytes (a zero divisor, say) never runs."""
        var node = self.expression_pool[idx]
        var kind = node.kind

        if kind == EXPR_AND:
            var l = self._eval_kleene_from_source[CS](src, node.left, row)
            if l == _KLEENE_FALSE:
                return _KLEENE_FALSE
            return _kleene_and(
                l, self._eval_kleene_from_source[CS](src, node.right, row)
            )
        if kind == EXPR_OR:
            var l = self._eval_kleene_from_source[CS](src, node.left, row)
            if l == _KLEENE_TRUE:
                return _KLEENE_TRUE
            return _kleene_or(
                l, self._eval_kleene_from_source[CS](src, node.right, row)
            )
        if kind == EXPR_NOT_BOOL:
            return _kleene_not(
                self._eval_kleene_from_source[CS](src, node.left, row)
            )

        if kind == EXPR_REGEXP:
            # The single value operand is `node.left`; `node.col_idx` indexes
            # the regex_pool and `node.right` is unused.
            if self._value_is_null_from_source[CS](src, node.left, row):
                return _KLEENE_NULL
        elif _is_binary_bool_leaf(kind):
            if self._value_is_null_from_source[CS](
                src, node.left, row
            ) or self._value_is_null_from_source[CS](src, node.right, row):
                return _KLEENE_NULL
        # IS NULL / IS NOT NULL read validity and are never UNKNOWN; any other
        # kind reaches `_eval_bool_present_from_source`, which raises on a kind
        # it does not serve.
        if self._eval_bool_present_from_source[CS](src, idx, row):
            return _KLEENE_TRUE
        return _KLEENE_FALSE

    def _value_is_null_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Bool:
        """True iff the value sub-tree at `idx` is SQL NULL for `row`.

        A column leaf (EXPR_COL / EXPR_COL_STRING / EXPR_COL_DECIMAL128) is
        NULL when its cell is; EXPR_NULL always is; a literal never is.
        Arithmetic, casts, EXTRACT, date_trunc and the math functions are NULL
        when an operand is. A CASE is NULL when the branch it takes is: the
        first WHEN that is TRUE (`_eval_bool_from_source`), else the ELSE.
        Kinds outside this list answer False; the value walkers raise on
        them."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if (
            kind == EXPR_COL
            or kind == EXPR_COL_STRING
            or kind == EXPR_COL_DECIMAL128
        ):
            return src.is_null(row, node.col_idx)
        if kind == EXPR_NULL:
            return True
        if (
            kind == EXPR_ADD_I64
            or kind == EXPR_SUB_I64
            or kind == EXPR_MUL_I64
            or kind == EXPR_DIV_I64
            or kind == EXPR_ADD_F64
            or kind == EXPR_SUB_F64
            or kind == EXPR_MUL_F64
            or kind == EXPR_DIV_F64
            or kind == EXPR_ATAN2_F64
            or kind == EXPR_POW_F64
        ):
            return self._value_is_null_from_source[CS](
                src, node.left, row
            ) or self._value_is_null_from_source[CS](src, node.right, row)
        if (
            kind == EXPR_F64_TO_I64
            or kind == EXPR_I64_TO_F64
            or kind == EXPR_EXTRACT_I64
            or kind == EXPR_DATE_TRUNC_I64
            or kind == EXPR_SQRT_F64
            or kind == EXPR_SIN_F64
            or kind == EXPR_COS_F64
            or kind == EXPR_ASIN_F64
            or kind == EXPR_RADIANS_F64
            or kind == EXPR_MATH_UNARY_F64
        ):
            return self._value_is_null_from_source[CS](src, node.left, row)
        if kind == EXPR_CASE_I64 or kind == EXPR_CASE_F64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            for c in range(n_pairs):
                if self._eval_bool_from_source[CS](src, slots[2 * c], row):
                    return self._value_is_null_from_source[CS](
                        src, slots[2 * c + 1], row
                    )
            return self._value_is_null_from_source[CS](
                src, slots[len(slots) - 1], row
            )
        return False

    def _eval_string_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> String:
        """Per-cell String evaluator. EXPR_COL_STRING
        reads via CS.read_string; EXPR_LIT_STRING returns the interned literal
        from `string_pool` (col_idx repurposed as the pool index)."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if kind == EXPR_COL_STRING:
            return src.read_string(row, node.col_idx)
        if kind == EXPR_LIT_STRING:
            return self.string_pool[node.col_idx].copy()
        raise Error(
            "ExpressionExecutor._eval_string_from_source: unsupported node"
            " kind " + String(kind) + " at pool slot " + String(idx)
            + " (string operand must be EXPR_COL_STRING / EXPR_LIT_STRING)"
        )

    def _eval_i64_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Int64:
        """Per-cell Int64 scalar evaluator. EXPR_COL reads via CS.read_i64;
        EXPR_LIT_I64 returns the carried literal; arithmetic recurses."""
        var node = self.expression_pool[idx]
        var kind = node.kind

        if kind == EXPR_COL:
            return src.read_i64(row, node.col_idx)
        if kind == EXPR_LIT_I64:
            return Scalar[DType.int64](node.i64)
        # A NULL-marker value leaf yields the dtype-zero sentinel (the
        # project walker emits its validity bit separately).
        if kind == EXPR_NULL:
            return Int64(0)
        # CAST(f AS bigint) — evaluate the child as Float64 and truncate
        # toward zero (Mojo Int64(f) semantics; exact for integral f).
        if kind == EXPR_F64_TO_I64:
            return Int64(self._eval_f64_from_source[CS](src, node.left, row))
        # EXTRACT(field FROM temporal) — read the child epoch as Int64, then
        # recover the civil date / clock field. `node.i64` carries ticks-per-day
        # for the child's temporal unit (1 for Date32-days, 86_400_000 for
        # Date64-ms, ...); `node.col_idx` carries the RT_EXTRACT_* field selector.
        if kind == EXPR_EXTRACT_I64:
            var epoch = self._eval_i64_from_source[CS](src, node.left, row)
            var tpd = node.i64
            # days-since-1970 = floor(epoch / ticks_per_day). Int(epoch) is exact
            # for the in-envelope temporal range; floor-div handles pre-1970.
            var days = _ee_div_floor(Int(epoch), Int(tpd))
            var unit = node.col_idx
            # `millisecond` / `microsecond`, WITH THE
            # SECONDS FOLDED IN. ⛔ NOT the fractional part: DuckDB v1.5.3
            # answers 30123 / 30123456 for `...:30.123456`, not 123 / 123456.
            #
            # ⚠ ANSWERED FROM THE RAW TICK COUNT, BEFORE `days` IS USED. The
            # residue modulo ONE MINUTE already means "seconds and fraction",
            # so nothing is recomposed and there is no sign boundary between a
            # second and its fraction to get wrong.
            #
            # ⚠ `tps` CANNOT BE ZERO HERE: `_extract_node_walkable` demotes a
            # DATE32 (tpd = 1) for these two units, so this arm only ever runs
            # over a real timestamp. Were that gate widened, this would divide
            # by zero rather than answer wrongly — the loud direction.
            if (
                unit == RT_EXTRACT_MILLISECOND
                or unit == RT_EXTRACT_MICROSECOND
            ):
                var tps_ss = tpd // Int64(86400)
                var sub_minute = _ee_mod_floor(
                    Int(epoch), Int(tps_ss) * 60
                )
                var micros = sub_minute * 1_000_000 // Int(tps_ss)
                if unit == RT_EXTRACT_MICROSECOND:
                    return Int64(micros)
                return Int64(micros // 1_000)
            if (
                unit == RT_EXTRACT_HOUR
                or unit == RT_EXTRACT_MINUTE
                or unit == RT_EXTRACT_SECOND
            ):
                # Clock field: within-day ticks -> seconds-of-day -> h/m/s.
                var day_start = Int64(days) * tpd
                var ticks_into_day = epoch - day_start
                # ticks_per_second = ticks_per_day / 86400 (>=1 for s/ms/us/ns).
                var tps = tpd // Int64(86400)
                var secs_of_day = Int(ticks_into_day // tps)
                if unit == RT_EXTRACT_HOUR:
                    return Int64(secs_of_day // 3600)
                if unit == RT_EXTRACT_MINUTE:
                    return Int64((secs_of_day // 60) % 60)
                return Int64(secs_of_day % 60)
            # The DAY-INDEX units.
            # ⚠ THESE ARE ANSWERED BEFORE `_ee_civil_from_days` RUNS, because
            # two of the three do not need a civil date at all: the weekday is
            # a property of the DAY COUNT (1970-01-01 was a Thursday), so
            # computing y/m/d first would be work thrown away. `dayofyear`
            # does need it and calls it itself.
            #
            # ⚠ FLOOR-MOD, because `days` is NEGATIVE before 1970 and a
            # TRUNCATING `%` would answer a negative weekday. ⛔ AN EARLIER
            # VERSION OF THIS COMMENT SAID MOJO's `%` IS THE TRUNCATING ONE;
            # it is not, so
            # `_ee_mod_floor` is an identity here. It is the same spelling the
            # RT_TRUNC_WEEK arm below already uses, and it names the
            # requirement at the site that has it.
            if unit == RT_EXTRACT_DAYOFWEEK:
                # DuckDB: Sunday = 0 … Saturday = 6 (measured v1.5.3).
                return Int64(_ee_mod_floor(days + 4, 7))
            if unit == RT_EXTRACT_ISODOW:
                # ISO-8601: Monday = 1 … Sunday = 7. NOT `dayofweek + 1`.
                return Int64(_ee_mod_floor(days + 3, 7) + 1)
            var ymd = _ee_civil_from_days(days)
            if unit == RT_EXTRACT_YEAR:
                return Int64(ymd[0])
            if unit == RT_EXTRACT_MONTH:
                return Int64(ymd[1])
            if unit == RT_EXTRACT_DAY:
                return Int64(ymd[2])
            if unit == RT_EXTRACT_QUARTER:
                return Int64((ymd[1] - 1) // 3 + 1)
            if unit == RT_EXTRACT_DAYOFYEAR:
                # 1-based (measured: `dayofyear(DATE '1970-01-01')` = 1), and
                # leap-aware for free — January 1st of the SAME civil year is
                # recovered rather than a 365-day constant subtracted.
                return Int64(days - _ee_days_from_civil(ymd[0], 1, 1) + 1)
            # The ISO WEEK-DATE units.
            #
            # ★ AN ISO WEEK BELONGS TO THE YEAR CONTAINING ITS **THURSDAY**.
            # That one sentence is all three formulas. ⛔ `ymd` above is the
            # CIVIL date of `days` and is NOT usable here: the ISO year is the
            # civil year of the THURSDAY, which can be the year before or the
            # year after. In DuckDB v1.5.3: `isoyear(DATE '1999-01-01')` = 1998
            # while `year()` = 1999; `isoyear(DATE '1996-12-30')` = 1997 while
            # `year()` = 1996.
            if (
                unit == RT_EXTRACT_WEEK
                or unit == RT_EXTRACT_ISOYEAR
                or unit == RT_EXTRACT_YEARWEEK
            ):
                var iso_dow = _ee_mod_floor(days + 3, 7) + 1
                var thursday = days - iso_dow + 4
                var t_ymd = _ee_civil_from_days(thursday)
                var iso_y = t_ymd[0]
                if unit == RT_EXTRACT_ISOYEAR:
                    return Int64(iso_y)
                # The Thursday is BY CONSTRUCTION inside `iso_y`, so this
                # difference is never negative and plain `//` is floor here.
                var wk = (thursday - _ee_days_from_civil(iso_y, 1, 1)) // 7 + 1
                if unit == RT_EXTRACT_WEEK:
                    return Int64(wk)
                # `yearweek` = ISO year * 100 ± week (e.g. 199853 for
                # 1999-01-01 — 1998, not 1999; -52 for 0000-12-31, where the
                # ISO year is 0 and the WEEK carries the whole sign).
                # ⛔ THE RULE IS IMPORTED, NOT RESTATED — see the note on the
                # `compose_yearweek` import at the top of this file.
                return Int64(compose_yearweek(iso_y, wk))
            raise Error(
                "ExpressionExecutor._eval_i64_from_source: EXPR_EXTRACT_I64"
                " unsupported unit " + String(unit)
            )
        # date_trunc(unit FROM temporal) — round the epoch DOWN to the period
        # start and return the truncated epoch (Int64). The output is the SAME
        # temporal dtype as the child (Date32->days, Date64/Timestamp->same
        # unit); the project walker writes it at the input cell width. Mirrors
        # `temporal_extract._date_trunc_{date32,ts}_range` exactly.
        if kind == EXPR_DATE_TRUNC_I64:
            var epoch = self._eval_i64_from_source[CS](src, node.left, row)
            var tpd = node.i64
            var unit = node.col_idx
            var ts_int = Int(epoch)
            # Calendar truncs (year/quarter/month/week/day): recover the
            # period-start days-since-1970, re-multiply by tpd. For Date32
            # (tpd=1) this leaves the value in raw days.
            if (
                unit == RT_TRUNC_YEAR
                or unit == RT_TRUNC_QUARTER
                or unit == RT_TRUNC_MONTH
                or unit == RT_TRUNC_WEEK
                or unit == RT_TRUNC_DAY
            ):
                var days = _ee_div_floor(ts_int, Int(tpd))
                var trunc_days: Int
                if unit == RT_TRUNC_YEAR:
                    var ymd = _ee_civil_from_days(days)
                    trunc_days = _ee_days_from_civil(ymd[0], 1, 1)
                elif unit == RT_TRUNC_QUARTER:
                    var ymd = _ee_civil_from_days(days)
                    var qm = _ee_quarter_first_month(ymd[1])
                    trunc_days = _ee_days_from_civil(ymd[0], qm, 1)
                elif unit == RT_TRUNC_MONTH:
                    var ymd = _ee_civil_from_days(days)
                    trunc_days = _ee_days_from_civil(ymd[0], ymd[1], 1)
                elif unit == RT_TRUNC_WEEK:
                    # ISO 8601: week starts Monday. 1970-01-01 was a Thursday
                    # (offset 3 from Monday). days_since_monday = (days+3) mod 7.
                    var dow_offset = _ee_mod_floor(days + 3, 7)
                    trunc_days = days - dow_offset
                else:  # RT_TRUNC_DAY
                    trunc_days = days
                return Int64(trunc_days) * tpd
            # Sub-day truncs (hour/minute/second/ms/us). On Date32 (tpd=1) these
            # are no-ops (no sub-day field) — return the epoch unchanged. For
            # Timestamp, floor-divide by the unit's tick count and re-multiply.
            # ticks_per_second = tpd/86400 (>=1 for s/ms/us/ns).
            var tps = tpd // Int64(86400)
            if unit == RT_TRUNC_HOUR:
                var tph = tps * Int64(3600)
                if tph == Int64(0):
                    return epoch
                return Int64(_ee_div_floor(ts_int, Int(tph))) * tph
            if unit == RT_TRUNC_MINUTE:
                var tpm = tps * Int64(60)
                if tpm == Int64(0):
                    return epoch
                return Int64(_ee_div_floor(ts_int, Int(tpm))) * tpm
            if unit == RT_TRUNC_SECOND:
                if tps == Int64(0):
                    return epoch
                return Int64(_ee_div_floor(ts_int, Int(tps))) * tps
            if unit == RT_TRUNC_MILLISECOND:
                # Only meaningful for sub-ms units (us=1e6/ns=1e9 tps); s/ms
                # are no-ops.
                if tps == Int64(1_000_000):
                    return Int64(_ee_div_floor(ts_int, 1_000)) * Int64(1_000)
                if tps == Int64(1_000_000_000):
                    return Int64(_ee_div_floor(ts_int, 1_000_000)) * Int64(
                        1_000_000
                    )
                return epoch
            if unit == RT_TRUNC_MICROSECOND:
                # Only meaningful for ns; others no-ops.
                if tps == Int64(1_000_000_000):
                    return Int64(_ee_div_floor(ts_int, 1_000)) * Int64(1_000)
                return epoch
            raise Error(
                "ExpressionExecutor._eval_i64_from_source: EXPR_DATE_TRUNC_I64"
                " unsupported unit " + String(unit)
            )
        # Int64 CASE — first matching THEN value, else the ELSE value.
        if kind == EXPR_CASE_I64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            for c in range(n_pairs):
                if self._eval_bool_from_source[CS](src, slots[2 * c], row):
                    return self._eval_i64_from_source[CS](
                        src, slots[2 * c + 1], row
                    )
            return self._eval_i64_from_source[CS](src, slots[len(slots) - 1], row)

        # RAISES on overflow — the row-format route's
        # arithmetic, same predicate and sentence as the column kernels.
        if kind == EXPR_ADD_I64:
            return checked_add[DType.int64](
                self._eval_i64_from_source[CS](src, node.left, row),
                self._eval_i64_from_source[CS](src, node.right, row),
            )
        if kind == EXPR_SUB_I64:
            return checked_sub[DType.int64](
                self._eval_i64_from_source[CS](src, node.left, row),
                self._eval_i64_from_source[CS](src, node.right, row),
            )
        if kind == EXPR_MUL_I64:
            return checked_mul[DType.int64](
                self._eval_i64_from_source[CS](src, node.left, row),
                self._eval_i64_from_source[CS](src, node.right, row),
            )
        if kind == EXPR_DIV_I64:
            var rhs = self._eval_i64_from_source[CS](src, node.right, row)
            if rhs == Int64(0):
                raise Error(
                    "ExpressionExecutor._eval_i64_from_source: EXPR_DIV_I64"
                    " division by zero at row " + String(row)
                )
            return _ee_div_trunc(
                self._eval_i64_from_source[CS](src, node.left, row), rhs
            )

        raise Error(
            "ExpressionExecutor._eval_i64_from_source: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
        )

    def _eval_u64_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> UInt64:
        """Per-cell UInt64 scalar evaluator. EXPR_COL reads via
        CS.read_u64 (zero-extends narrower unsigned storage, reads a U64 cell
        at full width); EXPR_LIT_I64 reinterprets the carried i64 literal as
        the unsigned bit pattern (the literal comparand for a U64 predicate is
        carried in the i64 field). Used by the walker's unsigned compare arm."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if kind == EXPR_COL:
            return src.read_u64(row, node.col_idx)
        if kind == EXPR_LIT_I64:
            return Scalar[DType.int64](node.i64).cast[DType.uint64]()
        raise Error(
            "ExpressionExecutor._eval_u64_from_source: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (U64 operand must be EXPR_COL / EXPR_LIT_I64)"
        )

    def _eval_i128_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> SIMD[DType.int128, 1]:
        """Per-cell DECIMAL128 scalar evaluator.
        EXPR_COL_DECIMAL128 reads the 16-byte cell's raw signed Int128 via
        CS.read_i128; EXPR_LIT_DECIMAL128 returns the literal's i128 from
        decimal_pool. Used by the walker's DECIMAL128 compare arm. This returns
        the raw UNSCALED int128; the compare arm pairs it with the operand's
        scale (`_eval_decimal_scale_from_source`) for the scale-aware compare."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if kind == EXPR_COL_DECIMAL128:
            return src.read_i128(row, node.col_idx)
        if kind == EXPR_LIT_DECIMAL128:
            return self.decimal_pool[node.col_idx].value
        raise Error(
            "ExpressionExecutor._eval_i128_from_source: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (DECIMAL128 operand must be EXPR_COL_DECIMAL128 /"
            + " EXPR_LIT_DECIMAL128)"
        )

    def _eval_decimal_scale_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int) raises -> Int:
        """The DECIMAL scale of a DECIMAL128 comparison operand.
        EXPR_COL_DECIMAL128 reads the column's scale via
        CS.decimal_scale_of (the threaded col_scales side-table); EXPR_LIT_DECIMAL128
        reads the literal's scale from decimal_pool. Paired with
        `_eval_i128_from_source` so the walker's DECIMAL128 arm runs the scale-
        aware `_compare_decimal128` (rescales the smaller-scale operand UP). The
        scale read does NOT depend on `row` (a column's scale is uniform across
        rows; a literal's scale is fixed)."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if kind == EXPR_COL_DECIMAL128:
            return src.decimal_scale_of(node.col_idx)
        if kind == EXPR_LIT_DECIMAL128:
            return self.decimal_pool[node.col_idx].scale
        raise Error(
            "ExpressionExecutor._eval_decimal_scale_from_source: unsupported"
            " node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
            + " (DECIMAL128 operand must be EXPR_COL_DECIMAL128 /"
            + " EXPR_LIT_DECIMAL128)"
        )

    def _eval_f64_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Float64:
        """Per-cell Float64 scalar evaluator. EXPR_COL reads via CS.read_f64
        (which widens int / f32 storage); EXPR_LIT_F64 / EXPR_LIT_I64 return
        the carried literal widened to f64; arithmetic recurses."""
        var node = self.expression_pool[idx]
        var kind = node.kind

        if kind == EXPR_COL:
            return src.read_f64(row, node.col_idx)
        if kind == EXPR_LIT_F64:
            return Scalar[DType.float64](node.f64)
        if kind == EXPR_LIT_I64:
            # An i64 literal compared against an f64 column widens to f64
            # (mirrors the column walker's EXPR_LIT_I64 widening in the F64
            # channel).
            return Float64(node.i64)
        # A NULL-marker value leaf yields 0.0 (validity emitted separately).
        if kind == EXPR_NULL:
            return Float64(0)
        # CAST(i AS double) — evaluate the child as Int64 and widen.
        if kind == EXPR_I64_TO_F64:
            return Float64(self._eval_i64_from_source[CS](src, node.left, row))
        # Float64 CASE — first matching THEN value, else the ELSE value.
        if kind == EXPR_CASE_F64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            for c in range(n_pairs):
                if self._eval_bool_from_source[CS](src, slots[2 * c], row):
                    return self._eval_f64_from_source[CS](
                        src, slots[2 * c + 1], row
                    )
            return self._eval_f64_from_source[CS](src, slots[len(slots) - 1], row)

        if kind == EXPR_ADD_F64:
            return self._eval_f64_from_source[CS](
                src, node.left, row
            ) + self._eval_f64_from_source[CS](src, node.right, row)
        if kind == EXPR_SUB_F64:
            return self._eval_f64_from_source[CS](
                src, node.left, row
            ) - self._eval_f64_from_source[CS](src, node.right, row)
        if kind == EXPR_MUL_F64:
            return self._eval_f64_from_source[CS](
                src, node.left, row
            ) * self._eval_f64_from_source[CS](src, node.right, row)
        if kind == EXPR_DIV_F64:
            # IEEE-754: div-by-zero yields +/-Inf or NaN, not a raise
            # (mirrors the EXPR_DIV_F64 arm of `eval_to_list_f64_from_view`).
            return self._eval_f64_from_source[CS](
                src, node.left, row
            ) / self._eval_f64_from_source[CS](src, node.right, row)

        # Math functions: the row
        # PROJECT walker per-cell mirror of the EXPR_MATH_FN(2) column arm
        # (`compiler_eval_column` -> `eval_math_unary/binary`). These EXPR_*_F64
        # nodes already had an arm in `eval_to_list_f64_from_view` (the
        # batch-view path); the `_from_source` (RowCellSource) path used by
        # `_apply_project_walker` was missing them, so a `col.sqrt()` projection
        # over a ROW source raised "unsupported node kind" deep in lowering.
        # The child resolves through the F64 channel (a numeric leaf widens via
        # CS.read_f64); the kernel matches the column oracle (IEEE-754 default —
        # sqrt(<0)=NaN, asin out-of-domain=NaN — no raise on any input).
        if kind == EXPR_SQRT_F64:
            return sqrt(self._eval_f64_from_source[CS](src, node.left, row))
        if kind == EXPR_SIN_F64:
            return sin(self._eval_f64_from_source[CS](src, node.left, row))
        if kind == EXPR_COS_F64:
            return cos(self._eval_f64_from_source[CS](src, node.left, row))
        if kind == EXPR_ASIN_F64:
            return asin(self._eval_f64_from_source[CS](src, node.left, row))
        if kind == EXPR_RADIANS_F64:
            return self._eval_f64_from_source[CS](
                src, node.left, row
            ) * Scalar[DType.float64](pi / 180.0)
        if kind == EXPR_ATAN2_F64:
            var yv = self._eval_f64_from_source[CS](src, node.left, row)
            var xv = self._eval_f64_from_source[CS](src, node.right, row)
            return atan2(yv, xv)
        if kind == EXPR_POW_F64:
            var bv = self._eval_f64_from_source[CS](src, node.left, row)
            var ev = self._eval_f64_from_source[CS](src, node.right, row)
            return libm_pow(bv, ev)
        if kind == EXPR_MATH_UNARY_F64:
            # RowCellSource mirror of
            # the generic column arm. `col_idx` is the KMATH_* op code.
            return Scalar[DType.float64](
                _apply_unary(
                    UInt8(node.col_idx),
                    Float64(self._eval_f64_from_source[CS](src, node.left, row)),
                )
            )

        raise Error(
            "ExpressionExecutor._eval_f64_from_source: unsupported node kind "
            + String(kind)
            + " at pool slot "
            + String(idx)
        )

    def _cell_is_null_from_source[
        CS: CellSource
    ](imm self, src: CS, idx: Int, row: Int) raises -> Bool:
        """True iff the computed project value at (`row`, root `idx`) is a
        SQL NULL (the project walker sets the output validity bit accordingly).

        A bare EXPR_NULL leaf is always null. For an EXPR_CASE_{I64,F64} root the
        selected branch (the first matching THEN, else the ELSE) determines
        nullity — its slot is null iff that branch node's kind is EXPR_NULL. For
        any other root (col / literal / arithmetic / cast) the computed cell is
        never null (matches the existing "computed numeric column is always
        non-null" rule). The CASE walk here mirrors the value evaluators' branch
        selection exactly so value + nullity always agree on the chosen branch."""
        var node = self.expression_pool[idx]
        var kind = node.kind
        if kind == EXPR_NULL:
            return True
        if kind == EXPR_CASE_I64 or kind == EXPR_CASE_F64:
            ref slots = self.when_pool[node.col_idx]
            var n_pairs = (len(slots) - 1) // 2
            for c in range(n_pairs):
                if self._eval_bool_from_source[CS](src, slots[2 * c], row):
                    return self._branch_is_null(slots[2 * c + 1])
            return self._branch_is_null(slots[len(slots) - 1])
        return False

    def _branch_is_null(imm self, slot: Int) -> Bool:
        """True iff the value sub-tree rooted at `slot` is a bare EXPR_NULL leaf
        (a CASE branch whose SQL value is the NULL literal). A non-NULL value
        branch (col / literal / arithmetic) is never null at this layer (matching
        the computed-column non-null rule); a value sub-tree that is ITSELF a
        nested CASE is conservatively treated as non-null here (nested CASE
        branches are outside batch-1 scope — the row gate declines them)."""
        return self.expression_pool[slot].kind == EXPR_NULL



# -----------------------------------------------------------------------------
# SQL three-valued logic (Kleene) values and tables.
# -----------------------------------------------------------------------------
#
# `_eval_kleene_from_source` and `_eval_kleene_from_view` return one of these
# per row. A WHERE keeps a row only when its predicate is `_KLEENE_TRUE`.

comptime _KLEENE_FALSE: UInt8 = 0
comptime _KLEENE_TRUE: UInt8 = 1
comptime _KLEENE_NULL: UInt8 = 2


@always_inline
def _kleene_and(a: UInt8, b: UInt8) -> UInt8:
    """FALSE if either side is FALSE, TRUE if both are TRUE, else UNKNOWN."""
    if a == _KLEENE_FALSE or b == _KLEENE_FALSE:
        return _KLEENE_FALSE
    if a == _KLEENE_TRUE and b == _KLEENE_TRUE:
        return _KLEENE_TRUE
    return _KLEENE_NULL


@always_inline
def _kleene_or(a: UInt8, b: UInt8) -> UInt8:
    """TRUE if either side is TRUE, FALSE if both are FALSE, else UNKNOWN."""
    if a == _KLEENE_TRUE or b == _KLEENE_TRUE:
        return _KLEENE_TRUE
    if a == _KLEENE_FALSE and b == _KLEENE_FALSE:
        return _KLEENE_FALSE
    return _KLEENE_NULL


@always_inline
def _kleene_not(a: UInt8) -> UInt8:
    """Swaps TRUE and FALSE; UNKNOWN stays UNKNOWN."""
    if a == _KLEENE_TRUE:
        return _KLEENE_FALSE
    if a == _KLEENE_FALSE:
        return _KLEENE_TRUE
    return _KLEENE_NULL


def _is_binary_bool_leaf(kind: Int) -> Bool:
    """True for the Bool leaves whose two value operands sit in `left` and
    `right`: the numeric, unsigned, mixed, DECIMAL128 and STRING comparisons
    and LIKE. Such a leaf is UNKNOWN when either operand is NULL."""
    return (
        kind == EXPR_GT_I64
        or kind == EXPR_GE_I64
        or kind == EXPR_LT_I64
        or kind == EXPR_LE_I64
        or kind == EXPR_EQ_I64
        or kind == EXPR_NE_I64
        or kind == EXPR_GT_U64
        or kind == EXPR_GE_U64
        or kind == EXPR_LT_U64
        or kind == EXPR_LE_U64
        or kind == EXPR_EQ_U64
        or kind == EXPR_NE_U64
        or kind == EXPR_GT_F64
        or kind == EXPR_GE_F64
        or kind == EXPR_LT_F64
        or kind == EXPR_LE_F64
        or kind == EXPR_EQ_F64
        or kind == EXPR_NE_F64
        or kind == EXPR_LT_F64_MIXED
        or kind == EXPR_LE_F64_MIXED
        or kind == EXPR_GT_F64_MIXED
        or kind == EXPR_GE_F64_MIXED
        or kind == EXPR_EQ_F64_MIXED
        or kind == EXPR_EQ_DECIMAL128
        or kind == EXPR_NEQ_DECIMAL128
        or kind == EXPR_GT_DECIMAL128
        or kind == EXPR_LT_DECIMAL128
        or kind == EXPR_GE_DECIMAL128
        or kind == EXPR_LE_DECIMAL128
        or kind == EXPR_EQ_STRING
        or kind == EXPR_NEQ_STRING
        or kind == EXPR_GT_STRING
        or kind == EXPR_LT_STRING
        or kind == EXPR_GE_STRING
        or kind == EXPR_LE_STRING
        or kind == EXPR_LIKE_STRING
    )


# -----------------------------------------------------------------------------
# Literal-payload validator — comptime-DType dispatch over the RuntimeExpr
# `kind` field.
# -----------------------------------------------------------------------------
#
# `RuntimeExpr` carries a union-style payload — `i64` is meaningful when
# `kind == EXPR_LIT_I64`, `f64` when `kind == EXPR_LIT_F64`, etc. This
# helper validates that the LITERAL node's kind matches `T`. Reading the
# payload is done inline in `_compare_present_from_view` (per-DType branch);
# this helper centralizes the kind-check + error reporting so the
# walker body stays readable.


def _validate_lit_dtype[
    T: DType
](lit_node: RuntimeExpr, idx: Int) raises:
    """Raise if `lit_node.kind` does not match `T`.

    `T` is int64 or float64 (the only instantiations). An Int64 comparison
    whose left column is stored as INT32 / DATE32 still carries an
    EXPR_LIT_I64 literal; `_compare_present_from_view` narrows it at read
    time.

    Args:
        lit_node: The literal-side RuntimeExpr.
        idx: The comparison node's pool slot (used in error messages).

    Raises:
        Error on kind / T mismatch.
    """
    comptime if T == DType.int64:
        if lit_node.kind != EXPR_LIT_I64:
            raise Error(
                "ExpressionExecutor: comparison at pool slot "
                + String(idx)
                + " expects EXPR_LIT_I64 (or EXPR_COL) on the RIGHT"
                " for an Int64/Int32 comparison; got kind "
                + String(lit_node.kind)
            )
    else:
        comptime assert T == DType.float64, (
            "_validate_lit_dtype: T is int64 or float64"
        )
        if lit_node.kind != EXPR_LIT_F64:
            raise Error(
                "ExpressionExecutor: comparison at pool slot "
                + String(idx)
                + " expects EXPR_LIT_F64 (or EXPR_COL) on the RIGHT"
                " for a Float64 comparison; got kind "
                + String(lit_node.kind)
            )


# -----------------------------------------------------------------------------
# AND-chain flattening helper.
# -----------------------------------------------------------------------------
#
# An AND tree in the RuntimeExpr pool is typically left-leaning from how
# the typed-AST `to_expr` shape and the factory chain produce it:
#
#     AND(AND(AND(p0, p1), p2), p3)
#
# To run conjuncts in the AdaptiveFilter's permuted order, we flatten the
# tree into a flat List[Int] of predicate slot indices, preserving the
# left-to-right AST order. Nested ANDs become consecutive entries in the
# returned list. Non-AND nodes are leaves of the flattening — they show
# up as a single entry pointing at their own pool slot.
#
# For a non-AND root: the returned list is `[root_idx]` (a single
# "conjunct"). The AdaptiveFilter wired to n_predicates=1 is a no-op
# state machine (no adjacent swaps possible), still cheap to call.


def _flatten_and_chain(ref pool: List[RuntimeExpr], root_idx: Int) -> List[Int]:
    """Flatten an AND chain rooted at `root_idx` into predicate slot indices.

    For a tree shape like `AND(AND(AND(p0, p1), p2), p3)` returns
    `[p0_idx, p1_idx, p2_idx, p3_idx]`. For a non-AND root, returns
    `[root_idx]`.

    Args:
        pool: The RuntimeExpr arena (read-only borrow).
        root_idx: Pool slot of the root node.

    Returns:
        A List[Int] of conjunct pool slot indices in left-to-right AST
        order.
    """
    var result = List[Int]()
    _flatten_and_chain_into(pool, root_idx, result)
    return result^


def _flatten_and_chain_into(
    ref pool: List[RuntimeExpr], idx: Int, mut out: List[Int]
):
    """Recursive helper for `_flatten_and_chain`. Appends conjunct slot
    indices into `out`.

    Visits AND nodes by descending left then right (left-to-right AST
    order). Non-AND nodes are leaves — the index of the leaf is appended.
    """
    var node = pool[idx]
    if node.kind == EXPR_AND:
        _flatten_and_chain_into(pool, node.left, out)
        _flatten_and_chain_into(pool, node.right, out)
        return
    out.append(idx)
