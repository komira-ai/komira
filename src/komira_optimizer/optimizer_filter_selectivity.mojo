# =============================================================================
# Optimizer filter selectivity — predicate-aware narrowing estimates
# =============================================================================
#
# The cost-model in
# `optimizer_tdom_card.mojo` is structurally correct, but the INPUT
# `JoinRelation.cardinality` for filtered scans was wrong. The old
# `estimate_cardinality` in `optimizer_stats.mojo` used a flat 50%
# default for any filter, which under-narrows e.g. Q9's
# `part.p_name LIKE '%green%'` (DuckDB: 200K → 40K = 20%, ours: 200K → 100K).
#
# This module implements DuckDB-style predicate-aware selectivity matching
# `relation_statistics_helper.cpp` defaults:
#
#   - Equality (col == lit)    : 1 / NDV(col) when known, else 10%
#   - Not-equal (col != lit)   : 1 - 1/NDV(col) when known, else 90%
#   - Range (col <, <=, >, >=) : 30%   (no histogram available)
#   - IN-list (col IN [...])   : min(1.0, |list| / NDV(col)) or |list| * 10%
#   - LIKE / CONTAINS / regex  : 20%
#   - IS NULL                  : 5%
#   - IS NOT NULL              : 95%
#   - NOT child                : 1 - selectivity(child)
#   - AND child1 child2        : selectivity(c1) * selectivity(c2) (independence)
#   - OR  child1 child2        : sel(c1) + sel(c2) - sel(c1)*sel(c2)
#   - Literal True / False     : 1.0 / 0.0
#   - Unrecognized             : 50% (legacy fallback for unmodeled shapes)
#
# Sources:
#   - DuckDB v1.5.2 `src/optimizer/join_order/relation_statistics_helper.cpp`
#   - DuckDB v1.5.2 `src/optimizer/filter_combiner.cpp`
#
# DESIGN NOTE: this is selectivity (Float64 in [0.0, 1.0]). Callers
# multiply by child cardinality. Returned values are clamped to
# `[MIN_SELECTIVITY, 1.0]` so downstream `Int(card * sel)` never floors
# to zero — a relation that survives any filter must have at least one
# estimated row to keep the cost model non-degenerate.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_STRING_OP,
    EXPR_IN_LIST,
    EXPR_REGEXP,
    EXPR_BETWEEN,
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
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats, ColumnStats


# =============================================================================
# Selectivity constants (DuckDB defaults)
# =============================================================================

# Floor on returned selectivity: any filter keeps at least
# MIN_SELECTIVITY * child_card rows. Prevents Int(card * sel) flooring
# to 0 for very-selective predicates over small relations.
comptime MIN_SELECTIVITY: Float64 = 1.0e-6

# Equality / IN-list: 1/NDV when NDV is known. Default 10% (DuckDB
# `relation_statistics_helper.cpp:~155` — "1.0 / 10.0" const).
comptime DEFAULT_EQUALITY_SELECTIVITY: Float64 = 0.1

# Range comparisons: 30% (DuckDB `filter_combiner.cpp::CONSTANT_EXPRESSION`
# returns ~0.3 when no histogram is available).
comptime DEFAULT_RANGE_SELECTIVITY: Float64 = 0.3

# String pattern matching: 20% (DuckDB `relation_statistics_helper.cpp:~165`
# uses 0.2 for LIKE / CONTAINS / regex / similar). This is the fallback
# (contains-shape / unknown) — prefix / suffix shapes use the constants
# below for shape differentiation.
comptime DEFAULT_STRING_PATTERN_SELECTIVITY: Float64 = 0.2

# LIKE-pattern-shape-aware differentiation. DuckDB's
# `relation_statistics_helper.cpp:~165` treats prefix and suffix patterns
# as tighter than contains:
#   `LIKE 'pat%'` (prefix anchored) - 10%, matches DEFAULT_EQUALITY shape
#   `LIKE '%pat'` (suffix anchored) - 15%, between equality and contains
#   `LIKE '%pat%'` (contains)       - 20%, the legacy default
# The selectivity reflects the average fraction of strings that satisfy
# the pattern — prefix is the most selective (most strings won't start
# with a given prefix), suffix less so, contains the least selective
# of the three. STR_STARTS_WITH / STR_ENDS_WITH bind to prefix / suffix
# at construction time; STR_LIKE inspects the pattern's leading/trailing
# `%` placement at selectivity-compute time.
comptime PREFIX_PATTERN_SELECTIVITY: Float64 = 0.1
comptime SUFFIX_PATTERN_SELECTIVITY: Float64 = 0.15

# IS NULL: 5% (small fraction; nullable columns are typically dense).
comptime DEFAULT_IS_NULL_SELECTIVITY: Float64 = 0.05

# IS NOT NULL: complement of IS NULL.
comptime DEFAULT_IS_NOT_NULL_SELECTIVITY: Float64 = 0.95

# Unmodeled predicates: 50% (legacy behavior; matches old
# `DEFAULT_FILTER_SELECTIVITY_NUM/DEN`).
comptime DEFAULT_UNKNOWN_SELECTIVITY: Float64 = 0.5

# BETWEEN x AND y: range-like, slightly tighter than open range (DuckDB
# treats BETWEEN as the conjunction of two range predicates; we use a
# single 25% constant, a little below the 30% of one open range).
comptime DEFAULT_BETWEEN_SELECTIVITY: Float64 = 0.25


# =============================================================================
# Public API — compute_selectivity
# =============================================================================


def compute_selectivity(predicate: Expr, table_stats: Optional[TableStats]) -> Float64:
    """Estimate the fraction of rows that satisfy `predicate`.

    Pattern-matches on the predicate's Expr tag and dispatches to
    DuckDB-style per-op defaults. Returns a value in
    `[MIN_SELECTIVITY, 1.0]`.

    `table_stats` carries per-column NDV when available (Parquet
    metadata). Equality predicates use `1/NDV(col)` when the predicate
    is `col == literal` and the column's NDV is known via
    `table_stats.column_distinct_count(col_name)`.

    Conjunction (AND) uses the independence assumption: product of
    child selectivities. Disjunction (OR) uses inclusion-exclusion
    for two children: `a + b - a*b`. Both match DuckDB's
    `filter_combiner.cpp` conjunction/disjunction treatment.

    Unknown / unmodeled predicate shapes return
    `DEFAULT_UNKNOWN_SELECTIVITY` (50%) — matching the old hard-coded
    default so we never under-narrow more than the legacy
    code did.
    """
    var sel = _selectivity_of(predicate, table_stats)
    if sel < MIN_SELECTIVITY:
        sel = MIN_SELECTIVITY
    if sel > 1.0:
        sel = 1.0
    return sel


def _selectivity_of(predicate: Expr, table_stats: Optional[TableStats]) -> Float64:
    """Internal recursive helper. Returns a raw Float64; the outer
    `compute_selectivity` is responsible for the
    `[MIN_SELECTIVITY, 1.0]` clamp."""
    var tag = predicate.tag

    # ---- Literal ----
    # A boolean literal acts as a constant gate: `WHERE true` keeps
    # everything, `WHERE false` drops everything. Other literals are
    # not legal predicate-position but we degrade gracefully.
    if tag == EXPR_LITERAL:
        var lit = predicate.literal_value()
        if lit.is_bool():
            if lit.bool_val:
                return 1.0
            return 0.0
        return DEFAULT_UNKNOWN_SELECTIVITY

    # ---- Binary operator ----
    if tag == EXPR_BINARY_OP:
        var op = predicate.binary_op()

        # Conjunction: independence-assumption product.
        if op == BIN_AND:
            var sl = _selectivity_of(predicate.binary_left_ref(), table_stats)
            var sr = _selectivity_of(predicate.binary_right_ref(), table_stats)
            return sl * sr

        # Disjunction: inclusion-exclusion.
        if op == BIN_OR:
            var sl = _selectivity_of(predicate.binary_left_ref(), table_stats)
            var sr = _selectivity_of(predicate.binary_right_ref(), table_stats)
            return sl + sr - (sl * sr)

        # Equality / inequality: NDV-driven when known.
        if op == BIN_EQ:
            return _equality_selectivity(predicate, table_stats)
        if op == BIN_NE:
            var s_eq = _equality_selectivity(predicate, table_stats)
            return 1.0 - s_eq

        # Range predicates: flat default.
        if op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE:
            return DEFAULT_RANGE_SELECTIVITY

        # Arithmetic / other binary ops in predicate position: unknown.
        return DEFAULT_UNKNOWN_SELECTIVITY

    # ---- Unary operator (NOT / IS NULL / IS NOT NULL) ----
    if tag == EXPR_UNARY_OP:
        var op = predicate.unary_op()
        if op == UN_NOT:
            var s = _selectivity_of(predicate.unary_child_ref(), table_stats)
            return 1.0 - s
        if op == UN_IS_NULL:
            return DEFAULT_IS_NULL_SELECTIVITY
        if op == UN_IS_NOT_NULL:
            return DEFAULT_IS_NOT_NULL_SELECTIVITY
        return DEFAULT_UNKNOWN_SELECTIVITY

    # ---- String pattern op (LIKE / CONTAINS / STARTS_WITH / ENDS_WITH) ----
    if tag == EXPR_STRING_OP:
        # Pattern-shape-aware differentiation:
        #   STR_STARTS_WITH (anchored prefix): 10%
        #   STR_ENDS_WITH   (anchored suffix): 15%
        #   STR_CONTAINS    (unanchored)       : 20%
        #   STR_LIKE        : inspect pattern's leading/trailing '%'
        #     pat%  -> prefix shape  -> 10%
        #     %pat  -> suffix shape  -> 15%
        #     %pat% -> contains shape -> 20% (default)
        #     other -> fall back to 20% (default)
        var op = predicate.string_op_type()
        if op == STR_STARTS_WITH:
            return PREFIX_PATTERN_SELECTIVITY
        if op == STR_ENDS_WITH:
            return SUFFIX_PATTERN_SELECTIVITY
        if op == STR_CONTAINS:
            return DEFAULT_STRING_PATTERN_SELECTIVITY
        # STR_LIKE: classify by pattern shape.
        return _like_pattern_selectivity(predicate.string_op_pattern())

    # ---- Regexp ----
    if tag == EXPR_REGEXP:
        # REGEXP_LIKE and the Bool-returning regex variants behave
        # like LIKE for selectivity purposes.
        return DEFAULT_STRING_PATTERN_SELECTIVITY

    # ---- IN-list (col IN [v1, v2, ...]) ----
    if tag == EXPR_IN_LIST:
        # min(|list| * 1/NDV, 1.0) when NDV known; else |list| * 10%,
        # also capped at 1.0.
        var n_values = predicate.in_list_len()
        ref child = predicate.in_list_child_ref()
        var per_value_sel = _equality_selectivity_for_col(child, table_stats)
        var sel = Float64(n_values) * per_value_sel
        if sel > 1.0:
            sel = 1.0
        return sel

    # ---- BETWEEN ----
    if tag == EXPR_BETWEEN:
        return DEFAULT_BETWEEN_SELECTIVITY

    # ---- Bare column reference used as a boolean predicate ----
    # `WHERE bool_col` — treat as IS NOT NULL-ish (95% default).
    if tag == EXPR_COL_REF or tag == EXPR_COL_IDX:
        return DEFAULT_IS_NOT_NULL_SELECTIVITY

    # ---- Anything else: legacy 50% fallback ----
    return DEFAULT_UNKNOWN_SELECTIVITY


@always_inline
def _like_pattern_selectivity(pattern: String) -> Float64:
    """Classify a LIKE pattern's selectivity by leading/trailing `%`.

    DuckDB's `relation_statistics_helper.cpp` treats:
      - `pat%`  (prefix anchored): tighter than contains -> 10%
      - `%pat`  (suffix anchored): less tight than prefix -> 15%
      - `%pat%` (contains)        : the legacy default    -> 20%
      - other shapes              : 20% (default fallback)

    The classifier inspects only the first and last byte of the pattern
    (the `%` wildcard is a single ASCII byte at the boundary; non-ASCII
    leading bytes are ipso facto not `%`). Empty pattern is treated as
    contains (no anchor signal).

    `%` is the SQL multi-char wildcard; we don't differentiate `_`
    (single-char wildcard) here — DuckDB doesn't either at this layer.
    """
    var n = pattern.byte_length()
    if n == 0:
        return DEFAULT_STRING_PATTERN_SELECTIVITY
    var p = pattern.unsafe_ptr()
    # SAFETY: `pattern` is a non-empty String; `p[0]` and `p[n-1]` are
    # in-bounds reads from the String's owned byte storage. The reads
    # are byte-level (UInt8), so any leading multi-byte UTF-8 prefix
    # is harmless — `%` is a single ASCII byte (0x25) that cannot appear
    # in the middle of a multi-byte UTF-8 sequence.
    var leading_pct = p[0] == UInt8(ord("%"))
    var trailing_pct = p[n - 1] == UInt8(ord("%"))
    if leading_pct and trailing_pct:
        # `%pat%` (contains).
        return DEFAULT_STRING_PATTERN_SELECTIVITY
    if trailing_pct and not leading_pct:
        # `pat%` (prefix anchored).
        return PREFIX_PATTERN_SELECTIVITY
    if leading_pct and not trailing_pct:
        # `%pat` (suffix anchored).
        return SUFFIX_PATTERN_SELECTIVITY
    # No wildcards / unusual shapes: default to contains (matches
    # legacy 20% behavior — we don't want to under-estimate further).
    return DEFAULT_STRING_PATTERN_SELECTIVITY


@always_inline
def _equality_selectivity(
    predicate: Expr, table_stats: Optional[TableStats]
) -> Float64:
    """Selectivity for `col == lit` (or `lit == col`).

    Detects the col-ref side of the equality and returns `1/NDV(col)`
    when the column's distinct count is known. Falls back to the
    DuckDB-default 10% otherwise.

    Two col-refs on either side (`col_a == col_b`) is a join condition
    that should never reach a Filter predicate at chain-extract time
    (the join optimizer extracts equi-keys before estimate). For
    safety we still return the 10% default.
    """
    # Detect which side is a column reference.
    ref lhs = predicate.binary_left_ref()
    ref rhs = predicate.binary_right_ref()
    var col_side_known = False
    var col_name = String("")

    if lhs.tag == EXPR_COL_REF and rhs.tag == EXPR_LITERAL:
        col_name = lhs.col_ref_name()
        col_side_known = True
    elif rhs.tag == EXPR_COL_REF and lhs.tag == EXPR_LITERAL:
        col_name = rhs.col_ref_name()
        col_side_known = True

    if not col_side_known:
        return DEFAULT_EQUALITY_SELECTIVITY

    if not table_stats:
        return DEFAULT_EQUALITY_SELECTIVITY
    ref ts = table_stats.value()
    var ndv_opt = ts.column_distinct_count(col_name)
    if not ndv_opt:
        return DEFAULT_EQUALITY_SELECTIVITY
    var ndv = ndv_opt.value()
    if ndv < 1:
        return DEFAULT_EQUALITY_SELECTIVITY
    return 1.0 / Float64(ndv)


@always_inline
def _equality_selectivity_for_col(
    child: Expr, table_stats: Optional[TableStats]
) -> Float64:
    """Selectivity for a single (col == v_i) probe used by IN-list
    decomposition. Returns `1/NDV(col)` when known, else 10%."""
    if child.tag != EXPR_COL_REF:
        return DEFAULT_EQUALITY_SELECTIVITY
    if not table_stats:
        return DEFAULT_EQUALITY_SELECTIVITY
    ref ts = table_stats.value()
    var ndv_opt = ts.column_distinct_count(child.col_ref_name())
    if not ndv_opt:
        return DEFAULT_EQUALITY_SELECTIVITY
    var ndv = ndv_opt.value()
    if ndv < 1:
        return DEFAULT_EQUALITY_SELECTIVITY
    return 1.0 / Float64(ndv)


# =============================================================================
# scale_table_stats_for_selectivity — column NDV cap after filter
# =============================================================================


def scale_table_stats_for_selectivity(
    var stats: TableStats, post_filter_card: Int
) -> TableStats:
    """Cap each column's `distinct_count` at `min(orig_ndv, post_filter_card)`
    after a filter has shrunk the relation.

    DuckDB equivalent: `relation_statistics_helper.cpp` applies the
    filter's selectivity to BOTH the relation cardinality AND the
    column NDV ceiling — a column cannot have more distinct values
    than there are surviving rows. This is load-bearing for the
    composite-NDV graph: under a 40K post-filter `part` fixture,
    `part.p_partkey` NDV must be 40K (not 200K), so the per-bucket
    denominator scales correctly.

    Consumes `stats` and returns a new TableStats. Other fields
    (`row_count`, `source`, `min_value`, `max_value`, `null_count`,
    `hll_registers`) are preserved unchanged — only `distinct_count`
    is capped.

    `row_count` is preserved (not overwritten) because it reflects the
    UNDERLYING parquet footer; the post-filter cardinality lives on
    `JoinRelation.cardinality`, which is what the cost model reads.
    The Tier-1 NDV cap is what propagates the filter signal into the
    composite-NDV graph.
    """
    if post_filter_card < 1:
        # Degenerate: keep stats unchanged (caller's contract says
        # post_filter_card >= 1 — defensive only).
        return stats^

    var new_column_stats = List[ColumnStats]()
    for i in range(len(stats.column_stats)):
        ref cs = stats.column_stats[i]
        var new_dc = cs.distinct_count
        if new_dc:
            var dc = new_dc.value()
            if dc > post_filter_card:
                new_dc = Optional[Int](post_filter_card)
        # Copy min/max/null_count/hll_registers verbatim.
        var new_min = Optional[ScalarValue]()
        if cs.min_value:
            new_min = Optional[ScalarValue](cs.min_value.value().copy())
        var new_max = Optional[ScalarValue]()
        if cs.max_value:
            new_max = Optional[ScalarValue](cs.max_value.value().copy())
        var new_null = Optional[Int]()
        if cs.null_count:
            new_null = Optional[Int](cs.null_count.value())
        var new_hll = Optional[List[UInt8]]()
        if cs.hll_registers:
            ref src = cs.hll_registers.value()
            var dst = List[UInt8]()
            for j in range(len(src)):
                dst.append(src[j])
            new_hll = Optional[List[UInt8]](dst^)
        new_column_stats.append(
            ColumnStats(new_dc, new_min^, new_max^, new_null, new_hll^)
        )

    var new_names = List[String]()
    for i in range(len(stats.column_names)):
        new_names.append(stats.column_names[i])

    return TableStats(stats.row_count, new_names^, new_column_stats^, stats.source)


