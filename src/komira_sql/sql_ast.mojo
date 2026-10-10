# =============================================================================
# komira_sql/sql_ast.mojo
#   The parsed AST for the analytical SQL frontend.
# =============================================================================
#
# The parser produces this AST; the binder (`sql_binder.mojo`) lowers it to a
# `LogicalPlan`. The AST is DISTINCT from the IR `Expr` because it must
# represent aggregate calls INLINE in the expression tree — the IR keeps
# `AggExpr` as a separate top-level type by design (agg_expr.mojo). The binder
# is where the agg/scalar split happens.
#
# `SqlExpr` is recursive via `Optional[OwnedPointer[SqlExpr]]` (mirroring the
# IR `Expr`/`LogicalPlan` heap-child shape). It is MOVE-ONLY; AST containers
# are move-only `Slab`s. No UnsafePointer, no wildcard origins.
# =============================================================================

from std.memory import OwnedPointer

from komira_collections.slab import Slab


# --- SqlExpr node tags -------------------------------------------------------
comptime SX_COLUMN: UInt8 = 0  # a column reference (name in `text`)
comptime SX_INT: UInt8 = 1  # integer literal (int_val)
comptime SX_FLOAT: UInt8 = 2  # float literal (float_val)
comptime SX_STRING: UInt8 = 3  # string literal (text)
comptime SX_BINARY: UInt8 = 4  # binary op (op in `op`; children in _left/_right)
comptime SX_AGG: UInt8 = 5  # aggregate call (func in `op`; arg in _agg_arg)
comptime SX_STAR: UInt8 = 6  # '*' (only valid as COUNT(*) arg or SELECT *)
comptime SX_DATE: UInt8 = 7  # date literal `date 'YYYY-MM-DD'` (raw string in `text`)
comptime SX_LIKE: UInt8 = 8  # `child [NOT] LIKE 'pat'` (child in _agg; pat in text; negate in like_negate)
comptime SX_CALL: UInt8 = 9  # scalar fn call `name(args...)` (name in `text`; args in _call)
comptime SX_SUBQUERY: UInt8 = 10  # subquery reference by index (int_val -> SelectStmt.subqueries): the GENERIC subquery-operand node. Scalar `(SELECT ...)` AND the predicate subqueries — `[NOT] EXISTS (...)`, `x [NOT] IN (...)` — all use this node. The referenced `SubqueryDef.kind` (scalar / exists / not-exists / in / not-in) drives how `_bind_query` pre-binds it; the outer binder just looks up `prebound[idx]` regardless of kind (a scalar Expr for SCALAR, a boolean predicate Expr for EXISTS/IN).
comptime SX_CASE: UInt8 = 11  # `CASE [operand] WHEN cond THEN res ... [ELSE default] END`. Children in `_case`: parallel WHEN-condition / THEN-result Slabs + a 0/1-entry ELSE Slab. A SIMPLE case (`CASE x WHEN v THEN ...`) is DESUGARED at parse time into a searched CASE (each condition becomes `x = v`), so the binder + AST only ever see the searched form. Binds to an `EXPR_WHEN` IR node (`_bind_case`); an omitted ELSE binds to a NULL literal (SQL default). The q8 market-share `sum(CASE WHEN ... THEN ... ELSE 0 END)` routes its CASE through the aggregate-argument binder (`_bind_agg_from_sx` -> `_bind_scalar`).
comptime SX_WINDOW: UInt8 = 12  # `f(...) OVER (PARTITION BY ... ORDER BY ... [ROWS/RANGE frame])` window function. Metadata in `_window` (a `SqlWindowData`): the SXWIN_* function, the aggregate ARG column (empty for ranking fns), the partition/order column lists + descending flags, and the frame bounds. `SqlWindowData` holds NO nested `SqlExpr` (arg + partition/order are plain column NAMES, per the corpus), so the AST stays ACYCLIC through this node (no new recursion cycle / no AOT-wedge risk). Binds to a `LogicalPlan.partition_by` (PLAN_PARTITION_BY) node — the existing engine window operator, no new executor.
comptime SX_UNARY: UInt8 = 13  # `NOT child` / `child IS [NOT] NULL` — a UNARY predicate. The SXUN_* code is in `op`; the child lives in the `_agg` slot, exactly as SX_LIKE's does. ⚠ THE `_agg` REUSE IS DELIBERATE, NOT A SHORTCUT: a new `Optional[SqlAggData]`-shaped FIELD would add another self-referential storage path for Mojo's AOT whole-program synthesis to walk, and this frontend has already paid for one of those (see SX_SUBQUERY's note on the `_bind_scalar <-> _bind_select` cycle that deadlocks the compiler). One-child nodes share one slot.
comptime SX_BOOL: UInt8 = 14  # `TRUE` / `FALSE`, value in `int_val` (0/1). ⚠ NOT folded into SX_INT: `flag = 1` and `flag = true` are different queries, only the second type-checks against a BOOL column, and binding a bool literal as an integer would push the type error down into a comparison kernel instead of raising in the binder.

# ★ TEMPORAL LITERALS (2026-09-21). `timestamp 'YYYY-MM-DD HH:MM:SS[.f]'` /
# `timestamptz '... +HH:MM'` — the raw string in `text`, the AWARENESS in `op`
# (`TSLIT_NAIVE` / `TSLIT_AWARE`).
#
# ⛔ NOT FOLDED INTO `SX_DATE` WITH A UNIT FLAG, and the reason is the
# awareness rather than the unit: `TIMESTAMP '...'` and `TIMESTAMPTZ '...'` are
# DIFFERENT QUESTIONS about the same digits, not two formats of one value.
# MEASURED, DuckDB v1.5.3, 2026-09-21:
#
#   epoch_us(TIMESTAMPTZ '2026-10-01 03:30:15.123456+02') -> 1790818215123456
#   epoch_us(TIMESTAMP   '2026-10-01 03:30:15.123456+02') -> 1790825415123456
#
# i.e. the SAME text is two instants two hours apart depending on the keyword,
# because the naive reading DISCARDS the offset. A single node carrying "it is
# temporal" would have to re-derive which reading applied from the text, and
# the text is identical.
comptime SX_TIMESTAMP: UInt8 = 15

# ★ THE NULL LITERAL (2026-09-24). Until
# this node a bare `null` fell through `_parse_primary`'s identifier arm and
# bound as a COLUMN called `null`, so `k IN (1, NULL)`, `k = NULL` and
# `NOT NULL` all refused under a WRONG name ("unknown column 'null'") where
# DuckDB answers NULL. The binder serves it where the other operand gives it a
# place — a COMPARISON operand, which is also every IN-list member (the parser
# desugars `IN` to `=`s) — and REFUSES it by name everywhere else: this IR has
# no untyped NULL value to project.
comptime SX_NULL: UInt8 = 16

# `SX_TIMESTAMP.op` — which keyword introduced the literal.
comptime TSLIT_NAIVE: UInt8 = 0  # `TIMESTAMP '...'`   — wall clock, no zone
comptime TSLIT_AWARE: UInt8 = 1  # `TIMESTAMPTZ '...'` — an instant, zone REQUIRED

# --- Window function codes (in `SqlWindowData.func` for SX_WINDOW) ------------
comptime SXWIN_ROW_NUMBER: UInt8 = 0  # ROW_NUMBER() — ranking, no arg
comptime SXWIN_RANK: UInt8 = 1  # RANK() — ranking, no arg
comptime SXWIN_DENSE_RANK: UInt8 = 2  # DENSE_RANK() — ranking, no arg
comptime SXWIN_SUM: UInt8 = 3  # SUM(col) OVER — aggregate window
comptime SXWIN_COUNT: UInt8 = 4  # COUNT(col|*) OVER — aggregate window
comptime SXWIN_MIN: UInt8 = 5  # MIN(col) OVER — aggregate window
comptime SXWIN_MAX: UInt8 = 6  # MAX(col) OVER — aggregate window
comptime SXWIN_AVG: UInt8 = 7  # AVG(col) OVER — aggregate window
# VALUE windows (2026-09-24): `f(col [, k [, default]])
# OVER (...)` — they copy the cell at another row of the partition. Reachable
# ONLY with an OVER clause (`sql_win_value_over_follows`); `lag(x)` with no
# OVER stays a scalar call that `sql_fn_table` refuses by its family reason.
comptime SXWIN_LAG: UInt8 = 8  # LAG(col [, offset [, default]]) OVER
comptime SXWIN_LEAD: UInt8 = 9  # LEAD(col [, offset [, default]]) OVER
comptime SXWIN_FIRST_VALUE: UInt8 = 10  # FIRST_VALUE(col) OVER — reads the frame
comptime SXWIN_LAST_VALUE: UInt8 = 11  # LAST_VALUE(col) OVER — reads the frame
comptime SXWIN_NTH_VALUE: UInt8 = 12  # NTH_VALUE(col, n) OVER — reads the frame
# ★ The DISTRIBUTION windows (2026-09-24). The
# engine's window operator has computed all three since `PartitionExpr` grew
# PF_PERCENT_RANK / PF_CUME_DIST / PF_NTILE (the Mojo `PartitionExpr` door
# serves them, graded by the cross-surface `win_dist_*` elements); the SQL door
# answered "expected keyword 'from'" because no SXWIN_* member named them. Like
# the ranking functions they read no column; `ntile` carries its bucket count
# in `SqlWindowData.value_offset`, where NTH_VALUE carries its n.
comptime SXWIN_PERCENT_RANK: UInt8 = 13  # PERCENT_RANK() OVER — (rank-1)/(n-1), 0 for a 1-row partition
comptime SXWIN_CUME_DIST: UInt8 = 14  # CUME_DIST() OVER — rows <= current (peers included) / n
comptime SXWIN_NTILE: UInt8 = 15  # NTILE(k) OVER — bucket 1..k, earlier buckets one larger

# --- Window frame units + bound tags (mirror partition_expr.mojo FRAME_*) -----
# Kept as local AST constants (the parser fills them; the binder maps 1:1 to the
# IR `PartitionFrame` FRAME_UNITS_* / FRAME_BOUND_* — same numeric values).
comptime SXFRAME_ROWS: UInt8 = 0
comptime SXFRAME_RANGE: UInt8 = 1
comptime SXFRAME_UNBOUNDED_PRECEDING: UInt8 = 0
comptime SXFRAME_PRECEDING: UInt8 = 1
comptime SXFRAME_CURRENT_ROW: UInt8 = 2
comptime SXFRAME_FOLLOWING: UInt8 = 3
comptime SXFRAME_UNBOUNDED_FOLLOWING: UInt8 = 4

# --- Subquery-kind codes (on `SubqueryDef.kind` in the side-table) ------------
comptime SUBQ_SCALAR: UInt8 = 0  # `(SELECT ...)` scalar operand
comptime SUBQ_EXISTS: UInt8 = 1  # `EXISTS (SELECT ...)` -> CORR_KIND_EXISTS (SEMI)
comptime SUBQ_NOT_EXISTS: UInt8 = 2  # `NOT EXISTS (SELECT ...)` -> CORR_KIND_NOT_EXISTS (ANTI)
comptime SUBQ_IN: UInt8 = 3  # `x IN (SELECT ...)` -> EXISTS with the synthesized `inner_col = x` equi (SEMI)
comptime SUBQ_NOT_IN: UInt8 = 4  # `x NOT IN (SELECT ...)` -> NULL-AWARE: the synthesized-equi ANTI join AND "no NULL y" AND "x IS NOT NULL or S empty" (`sql_bind_subquery._bind_null_aware_not_in`, 2026-09-25). It was the bare ANTI join, which answered rows DuckDB does not whenever a NULL was involved.
comptime SUBQ_DERIVED: UInt8 = 5  # `FROM (SELECT ...) alias` derived table (bound to a subplan, inlined via the CTE scope under `alias#<index>`)
# ★ UNION ALL (2026-09-21). The RIGHT-HAND BRANCH of `<select> UNION ALL
# <select>`, parked in the SAME flat side-table every other nested SELECT uses.
#
# ⭐ IT REUSES THE SIDE-TABLE RATHER THAN ADDING A `SelectStmt` FIELD, and that
# is a compile-time constraint and not a style choice. `SelectStmt` holding a
# second `SelectStmt`-shaped field is a new self-referential storage path for
# Mojo's AOT whole-program synthesis to walk, and this frontend has already
# paid for one of those (SX_SUBQUERY's note on the `_bind_scalar <->
# _bind_select` cycle that DEADLOCKS the compiler). The side-table is
# byte-backed `Slab[SubqueryDef]`, i.e. the cycle is already broken there, so a
# branch costs one `Int` index on `SelectStmt` and nothing structural.
#
# ⛔ IT IS NOT A `SUBQUERY` IN THE OPERAND SENSE. Every other kind here binds
# to an `Expr` that `prebound[idx]` hands back; this one binds to a PLAN and
# pushes an unreferenced placeholder into `prebound`, exactly as SUBQ_DERIVED
# does. `SX_SUBQUERY` never points at one.
comptime SUBQ_UNION_ALL: UInt8 = 6

# --- FROM join-kind codes (on `JoinClause.kind`, one per FROM relation after the
# first) ---------------------------------------------------------------------
# JK_CROSS covers comma-joins, `CROSS JOIN`, and plain/`INNER JOIN` — for all of
# these the binder builds a `JOIN_CROSS` node and the ON predicate (if any) is
# ANDed into `where_pred` at parse time (the optimizer's `eliminate_cross_join`
# folds equi-conjuncts into inner joins). JK_LEFT/RIGHT/FULL are the OUTER
# joins: the ON predicate STAYS ON the join (never folded to WHERE — folding would
# collapse the null-extension into inner-join semantics) and the binder emits a
# real `JOIN_LEFT`/etc. node so unmatched rows null-extend the opposite side.
comptime JK_CROSS: UInt8 = 0  # comma / CROSS JOIN / [INNER] JOIN (ON -> WHERE)
comptime JK_LEFT: UInt8 = 1   # LEFT [OUTER] JOIN ... ON ...  -> JOIN_LEFT
comptime JK_RIGHT: UInt8 = 2  # RIGHT [OUTER] JOIN ... ON ... -> JOIN_RIGHT (engine gap)
comptime JK_FULL: UInt8 = 3   # FULL [OUTER] JOIN ... ON ...  -> JOIN_FULL (engine gap)
# ★ SEMI / ANTI (2026-09-23) — DuckDB's `[NATURAL] SEMI|ANTI JOIN r (ON <equi> |
# USING (...))`. Like the OUTER kinds, the ON STAYS ON THE CLAUSE: folding it
# into WHERE would turn a SEMI into an INNER join (fan-out + the right side's
# columns), which is exactly the wrong answer these two codes exist to remove —
# before them `semi` / `anti` were eaten as the LEFT table's implicit alias and
# `t SEMI JOIN u ON ...` bound as `t AS semi JOIN u`. The right relation
# contributes NO output column and NO name to the enclosing scope.
comptime JK_SEMI: UInt8 = 4   # SEMI JOIN ... -> JOIN_SEMI (left rows WITH a match)
comptime JK_ANTI: UInt8 = 5   # ANTI JOIN ... -> JOIN_ANTI (left rows with NO match)

# --- SQL binary operator codes (mapped to BIN_* by the binder) ---------------
comptime SXOP_EQ: UInt8 = 0
comptime SXOP_NE: UInt8 = 1
comptime SXOP_LT: UInt8 = 2
comptime SXOP_LE: UInt8 = 3
comptime SXOP_GT: UInt8 = 4
comptime SXOP_GE: UInt8 = 5
comptime SXOP_AND: UInt8 = 6
comptime SXOP_OR: UInt8 = 7
comptime SXOP_ADD: UInt8 = 8
comptime SXOP_SUB: UInt8 = 9
comptime SXOP_MUL: UInt8 = 10
comptime SXOP_DIV: UInt8 = 11  # `/`  — DuckDB's TRUE division (DOUBLE over integers)
comptime SXOP_IDIV: UInt8 = 12  # `//` — DuckDB's INTEGER division = `divide()`
comptime SXOP_MOD: UInt8 = 13  # `%`  — DuckDB's modulo = `mod()`
# ★ Operator spellings (2026-09-24). Each
# names an operation a SQL FUNCTION already serves; the operator is a second
# SPELLING, kept as its own code (not rewritten to the call at parse time) so
# the unaliased result column is named the way DuckDB names it — `(a ^ 2)`,
# not `pow(a, 2)` (`sql_bind_names._sxop_text`).
comptime SXOP_POW: UInt8 = 14  # `^`  — power = `pow()`: DOUBLE, left-assoc, tighter than `*`
comptime SXOP_CONCAT: UInt8 = 15  # `||` — NULL-PROPAGATING concatenation (NOT `concat()`, which SKIPS a NULL)
comptime SXOP_STARTS_WITH: UInt8 = 16  # `^@` — `starts_with()`

# --- SQL unary operator codes (in `SqlExpr.op` for SX_UNARY; mapped to UN_* by
# the binder's `_map_unop`, which RAISES on a code it does not know rather than
# defaulting — a silent default here would bind `IS NOT NULL` as `IS NULL` and
# invert a user's answer) ------------------------------------------------------
comptime SXUN_NOT: UInt8 = 0  # `NOT x`
comptime SXUN_IS_NULL: UInt8 = 1  # `x IS NULL`
comptime SXUN_IS_NOT_NULL: UInt8 = 2  # `x IS NOT NULL`
# ★ The two PREFIX arithmetic operators (2026-09-24). ⭐ Unary minus
# on a LITERAL is still folded into the literal by the parser (so `-3` stays the
# constant DuckDB prints as `-3`); these two are the operator over an
# EXPRESSION, which used to be refused ("unary minus on a non-literal") or did
# not lex at all (`@`).
comptime SXUN_NEGATE: UInt8 = 3  # `-x`  -> UN_NEGATE (type-preserving)
comptime SXUN_ABS: UInt8 = 4  # `@x`  -> UN_ABS (type-preserving) = `abs()`

# --- SX_LIKE flavours (in `SqlExpr.op` for SX_LIKE) ----------------------------
comptime SXLIKE_LIKE: UInt8 = 0  # `x [NOT] LIKE 'p'`
comptime SXLIKE_ILIKE: UInt8 = 1  # `x [NOT] ILIKE 'p'` — case-insensitive (DuckDB `~~*` / `!~~*`)

# --- SQL aggregate function codes (in `SqlExpr.op` for SX_AGG) ---------------
comptime SXAGG_SUM: UInt8 = 0
comptime SXAGG_COUNT: UInt8 = 1
comptime SXAGG_MIN: UInt8 = 2
comptime SXAGG_MAX: UInt8 = 3
comptime SXAGG_AVG: UInt8 = 4

# --- Statement kinds (on `SqlStatement.kind`) -----------------
# The top-level statement dispatch beyond a bare SELECT. A `SqlStatement` always
# carries a source/query `SelectStmt` (`query`); the WRITE kinds additionally
# carry a destination + format. `plan_from_sql` serves STMT_QUERY only; the write
# kinds bind via `bind_statement` -> a `BoundStatement` the exec layer dispatches
# to the EXISTING `write_record_batch_to_parquet` sink (`sql_exec.run_sql`).
comptime STMT_QUERY: UInt8 = 0            # SELECT ... / WITH ... SELECT ...
comptime STMT_COPY: UInt8 = 1             # COPY <src> TO '<path>' [(FORMAT parquet, COMPRESSION ...)]
comptime STMT_CREATE_TABLE_AS: UInt8 = 2  # CREATE [OR REPLACE] TABLE <name> AS <select>

# --- Write formats + write compression codes -- ⛔ NO LONGER DECLARED HERE ----
#
# `WFMT_*`, `WCOMP_*`, `write_format_name`, `write_codec_name` and
# `write_target_supported` MOVED to `komira_arrow/write_target.mojo`,
# and the move is LOAD-BEARING rather than tidying.
#
# They became a WIRE VOCABULARY when `komira.plan.v1.WirePlanEnvelope` gained
# its `write_target` field. `scripts/lint_plan_wire_space_coverage.py` ARM 1
# derives the set of vocabularies it can see from the transitive import
# closure of `plan_wire_codec.mojo` — and `komira_sdk` is not in that
# closure and structurally cannot be, because the codec sits BELOW the engine.
# Declared here, a write vocabulary is one the completeness gate CANNOT SEE.
#
# ⚠ THIS IMPORT IS NOT A RE-EXPORT, AND THE DIFFERENCE MATTERS. Only the two
# constants THIS file's own `SqlStatement.__init__` defaults name are pulled in.
# `sql_parser`, `sql_binder` and `sql_exec` import the rest STRAIGHT FROM THE
# NEW HOME — one name, one place to look. A convenience re-export here would be
# a second import path for one declaration, which is how "where is this
# declared" stops having an answer.
from komira_arrow.write_target import WFMT_PARQUET, WCOMP_SNAPPY


@always_inline
def sql_call_is_aggregate(name: String) -> Bool:
    """True iff the (lower-folded) scalar-call function name is actually a
    statistical AGGREGATE that rides on the general `SX_CALL fn(args)` grammar
    rather than the `_agg_code` fast-path. `median`/`stddev`/
    `var_samp` are unary; `corr` is bivariate. Kept as a free function so BOTH
    the AST's `contains_aggregate()` and the binder's `_extract_and_bind_post_agg`
    agree on the exact set. `sum`/`count`/`min`/`max`/`avg` are NOT here — the
    parser already routes those through `_agg_code` -> SX_AGG.

    ⛔⛔ THIS IS **HALF** THE AGGREGATE VOCABULARY, AND READING IT AS THE WHOLE
    ONE SHIPPED A DEFECT. `sql_agg_code`'s six (`sum` `count` `min` `max`
    `avg` `mean`) are the other half; the two sets are disjoint BY CONSTRUCTION,
    because the parser routes those six to `SX_AGG` before the general call
    branch and these ride the call branch to the binder. Any door meaning "is
    this name an aggregate" must ask BOTH — call
    `sql_name_claimed_by_grammar`, which does. The UDF declare door called only
    this function and admitted all five of the others (measured 2026-09-05).

    ⚠ THIS SET AND `_bind_agg_from_sx_call`'s LADDER MUST AGREE, and nothing
    checks that they do. A name admitted here with no arm in the binder binds
    to the ladder's trailing `raise` — a parse that reaches an "unsupported
    statistical aggregate" error instead of the "aggregate not allowed" one,
    which reads like an engine gap rather than the two-place edit it is. Add to
    BOTH or NEITHER.

    `var_samp` / `variance` join the
    set. The plan tag `AGG_VAR_SAMP` and every arm below it already existed —
    `logical_plan.agg_func_base_name`, `_infer_agg_field`'s always-FLOAT64
    branch, the untyped column driver (`agg_node_exec`), the row-streaming
    runtime and `row_capability`'s admission gate all carried it. ONLY the two
    front doors could not spell it, so this is a vocabulary edit and not a
    kernel one. `variance` is the alias BOTH PostgreSQL and DuckDB give
    `var_samp` (ddof=1), so it is a spelling and not a second statistic.

    ★★ (2026-09-14):
    the ELEVEN BIVARIATE names join the set — `covar_pop` `covar_samp` and the
    nine `regr_*`. They are NOT eleven new kernels: `CorrelationState` already
    carries `[n | mean_x | mean_y | C | Sx | Sy]`, the complete sufficient
    statistics for all of them, and `AGG_CORR` has folded and Chan-merged it
    since before this change. Each new name is one FINALIZE over those six numbers.

    ⛔ AND EACH ONE HAD ITS `FNK_REFUSED` ROW IN `sql_fn_table.mojo` DELETED IN
    THE SAME COMMIT. A name in BOTH tables breaks the disjointness
    `_bind_scalar_call`'s hoisted aggregate check depends on — asserted by
    `test_the_aggregate_set_and_the_scalar_table_are_disjoint`
    (`tests/test_sql_frontend_date_diff_e2e.mojo`).

    ⚠ ALL ELEVEN ARE BIVARIATE, so `_bind_agg_from_sx_call` binds TWO args for
    them — and SWAPS the pair, because SQL spells `regr_slope(y, x)` with the
    DEPENDENT variable first while the engine state's `x` is slot 0. Read that
    arm before adding a twelfth."""
    return (
        name == "median"
        or name == "stddev"
        or name == "stddev_samp"
        or name == "corr"
        or name == "var_samp"
        or name == "variance"
        or name == "covar_pop"
        or name == "covar_samp"
        or name == "regr_avgx"
        or name == "regr_avgy"
        or name == "regr_count"
        or name == "regr_intercept"
        or name == "regr_r2"
        or name == "regr_slope"
        or name == "regr_sxx"
        or name == "regr_sxy"
        or name == "regr_syy"
        # ★★ (2026-09-14):
        # the POPULATION-FINALIZE
        # family. UNIVARIATE, unlike the eleven above — `_bind_agg_from_sx_call`
        # binds ONE argument for them and there is no swap to get wrong. They
        # are three FINALIZES over the `WelfordState` `stddev_samp` has folded
        # since before this change, differing from it only in the divisor.
        # ⛔ EACH ONE HAD ITS `FNK_REFUSED` ROW DELETED IN THE SAME COMMIT.
        or name == "var_pop"
        or name == "stddev_pop"
        or name == "sem"
        # ★★ (2026-09-14):
        # the MONOID-FOLD family plus
        # the one pure COUNT SPELLING. UNIVARIATE like the population trio.
        #
        # ⚠ `count_star` IS THE ODD ONE AND TAKES **ZERO** ARGUMENTS. The
        # binder's arm for it builds `AggExpr(AGG_COUNT, <no child>)` — the
        # SAME node `COUNT(*)` has always produced — so it costs no tag, no
        # accumulator and no finalize. It is here rather than in
        # `sql_agg_code` on purpose: adding it there would take the name away
        # from the general call branch AND make it undeclarable as a user
        # UDF (`sql_name_claimed_by_grammar` reads that table), and the
        # SX_CALL route additionally deparses an unaliased call as
        # `count_star()`, which is exactly DuckDB v1.5.3's own output name.
        or name == "count_star"
        or name == "count_if"
        or name == "countif"
        or name == "bool_and"
        or name == "bool_or"
        or name == "product"
        # ★★ (2026-09-14):
        # the ARRIVAL-ORDER PICK family.
        # UNIVARIATE like the two families above.
        #
        # ⛔⛔ FOUR NAMES, **THREE** TAGS. `arbitrary` is DuckDB's OWN recorded
        # alias of `first` (`duckdb_functions().alias_of`), so those two share
        # `AGG_FIRST`; `last` is `AGG_LAST`; and `any_value` is `AGG_ANY_VALUE`
        # — a SEPARATE tag, because MEASURED v1.5.3 over x = {NULL, 4.0}
        # `any_value` = 4.0 while `first` = `arbitrary` = NULL. Folding it onto
        # `AGG_FIRST` here is a one-token edit that BINDS, RUNS and answers
        # wrongly on every leading-NULL group.
        or name == "any_value"
        or name == "arbitrary"
        or name == "first"
        or name == "last"
        # ★★ (2026-09-15) — the COMPENSATED sums and the
        # HIGHER-MOMENT trio. UNIVARIATE like every family above.
        #
        # ⛔⛔ `fsum` / `kahan_sum` / `sumkahan` ARE ONE TAG AND `favg` IS
        # ANOTHER, AND NEITHER IS `sum` / `avg`. The falsifying fixture is the
        # one recorded a few lines up for `mean` (which IS a true alias of
        # `avg`): over {1e16, 1, 1, 1, -1e16}, `avg` and `mean` are
        # bit-identical at 0 while `fsum` = 4.0 and `favg` = 0.8. Routing any
        # of these four onto the naive kernel BINDS, RUNS and answers wrongly.
        or name == "fsum"
        or name == "kahan_sum"
        or name == "sumkahan"
        or name == "favg"
        # ⛔ `kurtosis` and `kurtosis_pop` are DIFFERENT STATISTICS with
        # DIFFERENT NULL RULES — MEASURED v1.5.3 over {1,2,3,4},
        # -1.200000000000001 vs -1.36, and over a 2-row group NULL vs -2.0.
        or name == "skewness"
        or name == "kurtosis"
        or name == "kurtosis_pop"
    )


# =============================================================================
# ★★ THE NAMES THE GRAMMAR CLAIMS — every namespace that can take an identifier
#    away from the general `name(args...)` call branch, in ONE place.
# =============================================================================
#
# ⛔ WHY THESE MOVED HERE FROM `sql_parser`, AND IT IS NOT TIDYING. They were
# private methods on `_Parser` (`_agg_code`, `_win_ranking_code`), so the ONLY
# component that could ask "does the grammar already claim this name" was the
# parser itself. `sql_udf_catalog.refuse_undeclarable_udf_name` — the door that
# decides whether a user may declare a UDF under a name — could not reach
# them and so consulted the SCALAR function table plus `sql_call_is_aggregate`
# and nothing else.
#
# MEASURED 2026-09-05: `sum` `count` `min` `max` `avg` were therefore ACCEPTED
# as UDF names and then SILENTLY REPLACED by the built-in aggregate at every
# call site — the exact mirror of the 114-name over-refusal fixed the day
# before, and the same root cause both times: ONE DOOR ASKING ONE OF SEVERAL
# NAMESPACES.
#
# ⚠ THEY LIVE IN `sql_ast` AND NOT IN `sql_parser` FOR A BUILD REASON AS WELL
# AS A DESIGN ONE. `sql_udf_catalog`'s dependency closure is exactly
# `sql_ast` + `sql_fn_table`, and it must not import `sql_parser`.
# `sql_ast` is already in that
# closure, and it is where `sql_call_is_aggregate` already lives for the
# identical "both sides must agree on the exact set" reason.


@always_inline
def sql_agg_code(name: String) -> Int:
    """SXAGG_* code for a (lower-folded) FAST-PATH aggregate name, or -1.

    ★ THE FIVE CORE SQL AGGREGATES, PLUS ONE DECLARED ALIAS. The parser routes
    these to `SX_AGG` BEFORE the general call branch, which is why
    `sql_call_is_aggregate` deliberately does not name them — the two sets are
    disjoint halves of one vocabulary and ANY door that means "is this name an
    aggregate" has to ask BOTH.

    ⛔ THE PARSER NO LONGER SPELLS THIS SET. `_Parser._agg_code` delegates
    here, so this is the single writer — and one line here reaches BOTH front
    doors at once, because `<agg>(x) OVER (...)` takes the same branch.

    ⭐ `mean` -> `avg` (2026-09-08). `duckdb_functions()` declares
    `alias_of = 'avg'` on every one of `mean`'s eleven overloads, and the
    return type is preserved PER SIGNATURE exactly as `avg`'s is (INTEGER ->
    DOUBLE, DOUBLE -> DOUBLE, DECIMAL -> DECIMAL, INTERVAL -> INTERVAL,
    TIMESTAMP -> TIMESTAMP, ...). FALSIFIED as a true alias by execution over a
    COLUMN on v1.5.3, on the three fixtures that could have separated them:

      * catastrophic cancellation `{1e16, 1, 1, 1, -1e16}` — avg = 0 AND
        mean = 0, bit-identical. ⇒ `mean` is NOT Kahan-compensated; had it
        been, it would answer 0.8 and be a DIFFERENT STATISTIC rather than a
        spelling. (This is exactly how `fsum` / `favg` / `sumkahan` were
        REJECTED from this campaign — they answer 4 and 0.8 on that fixture.)
      * an ALL-NULL group — both NULL.
      * `{-0.0, +0.0}` — both `+0.0`, asserted through `1.0/x` (`-0.0 == 0.0`
        is TRUE, so the equality itself cannot see the sign).

    ⛔ AND IT IS NOT A ONE-LINE CHANGE, WHICH `sql_bind_names._sxagg_text` SAID IN
    ADVANCE: DuckDB names an unaliased aggregate column after the token you
    WROTE (`mean(v)` -> `mean(v)`, `avg(v)` -> `avg(v)`), so the source token
    is now carried on the `SX_AGG` node's `text` field by `SqlExpr.agg` instead
    of being re-derived from `op`. Adding another alias here means passing its
    spelling the same way — nothing more, because the deparse reads the token."""
    if name == "sum":
        return Int(SXAGG_SUM)
    if name == "count":
        return Int(SXAGG_COUNT)
    if name == "min":
        return Int(SXAGG_MIN)
    if name == "max":
        return Int(SXAGG_MAX)
    if name == "avg":
        return Int(SXAGG_AVG)
    if name == "mean":
        return Int(SXAGG_AVG)
    return -1


@always_inline
def sql_win_ranking_code(name: String) -> Int:
    """SXWIN_* code for a RANKING window-function name, or -1.

    These take no argument and are valid only with `OVER`. The aggregate window
    functions are NOT here — they ride `sql_agg_code` and gain `OVER` after
    their argument list.

    ⛔ Single writer, as above: `_Parser._win_ranking_code` delegates here.

    ⭐⭐ `rank_dense` IS A SYNONYM OF `dense_rank` THAT NO ALIAS CENSUS CAN SEE,
    AND THAT IS THE FINDING, NOT THE FUNCTION. `duckdb_functions()` carries a
    first-class `alias_of` column and the campaign's stated method is to run it
    — necessary, and MEASURED NOT SUFFICIENT. On DuckDB v1.5.3 `alias_of` is
    **NULL for BOTH rows**, so the column says the two names are unrelated
    functions. Executing them says otherwise, on the fixture that can tell:

    MEASURED v1.5.3, transcribed verbatim, `OVER (PARTITION BY p ORDER BY v)`:

        p   v     dense_rank  rank_dense  rank
        x   10        1           1         1
        x   10        1           1         1
        x   20        2           2         3  <- rank GAPS, the dense pair does not
        x   30        3           3         4
        x   30        3           3         4
        y    1        1           1         1  <- and the partition RESETS
        y    5        2           2         2
        y    5        2           2         2
        y  NULL       3           3         4  <- NULLs sort last, still identical

    The same run under `ORDER BY v DESC` also agrees on every row. `dense_rank`
    and `rank_dense` are identical across TIES, across PARTITIONS, under DESC
    and over a NULL, while `rank` diverges at the first tie. Both declare
    `BIGINT` over zero parameters. ⇒ an alias census that trusts `alias_of`
    alone misses this whole class; only EXECUTION finds it.

    ⚠ NO OUTPUT-NAME WORK IS OWED HERE, and that is a MEASURED asymmetry with
    `sql_agg_code`'s `mean`, not an oversight. DuckDB names an unaliased window
    item after the token you wrote (`rank_dense() OVER (PARTITION BY p ORDER BY
    v)`); `_bind_window_projection` (`sql_bind_window_order.mojo`) names an UNALIASED
    window item `_w<n>` whatever the function — an `AS` alias is used verbatim
    when present — so `rank_dense` inherits `dense_rank`'s naming exactly and
    adds no divergence that was not already there for all eight window
    spellings. The
    aggregate door DOES deparse from the op code, which is why `mean` had to
    carry its source token and this does not."""
    if name == "rank":
        return Int(SXWIN_RANK)
    if name == "row_number":
        return Int(SXWIN_ROW_NUMBER)
    if name == "dense_rank":
        return Int(SXWIN_DENSE_RANK)
    if name == "rank_dense":
        return Int(SXWIN_DENSE_RANK)
    return -1


@always_inline
def sql_win_dist_code(name: String) -> Int:
    """SXWIN_* code for a DISTRIBUTION window-function name, or -1.

    `percent_rank` `cume_dist` `ntile` (2026-09-24). ⚠ THE SAME
    LOOKAHEAD RULE AS `sql_win_value_code`: a name here is a window ONLY when
    `OVER` follows its argument list, so `ntile(x)` without one stays the
    ordinary scalar call the `_R_AGGWINVALUE` row refuses — and these names are
    NOT claimed by the grammar in the `<name>(<one arg>)` shape
    `sql_name_claimed_by_grammar` answers for."""
    if name == "percent_rank":
        return Int(SXWIN_PERCENT_RANK)
    if name == "cume_dist":
        return Int(SXWIN_CUME_DIST)
    if name == "ntile":
        return Int(SXWIN_NTILE)
    return -1


def sql_win_value_code(name: String) -> Int:
    """SXWIN_* code for a VALUE window-function name, or -1.

    `lag` `lead` `first_value` `last_value` `nth_value` — each copies the cell
    at another row of its partition (`partition_value_fns.mojo`). ⚠ A NAME HERE
    IS A WINDOW ONLY WHEN `OVER` FOLLOWS ITS ARGUMENT LIST: the parser looks
    ahead for it and otherwise leaves `lag(x)` an ordinary scalar call, which
    `sql_fn_table` refuses with the `_R_AGGWINVALUE` family reason. So these
    names are NOT claimed by the grammar in the `<name>(<one arg>)` shape
    `sql_name_claimed_by_grammar` answers for."""
    if name == "lag":
        return Int(SXWIN_LAG)
    if name == "lead":
        return Int(SXWIN_LEAD)
    if name == "first_value":
        return Int(SXWIN_FIRST_VALUE)
    if name == "last_value":
        return Int(SXWIN_LAST_VALUE)
    if name == "nth_value":
        return Int(SXWIN_NTH_VALUE)
    return -1


# --- what a claim MEANS, so a refusal can say which one it is ---------------
comptime SQLNAME_FREE: UInt8 = 0
"""The grammar leaves `name(args...)` as an ordinary scalar call."""
comptime SQLNAME_AGG_FASTPATH: UInt8 = 1
"""`sum` `count` `min` `max` `avg` `mean` -> SX_AGG. SILENT REPLACEMENT."""
comptime SQLNAME_AGG_STATISTICAL: UInt8 = 2
"""`median` `stddev` ... -> SX_CALL the binder refuses in scalar position."""
comptime SQLNAME_WINDOW_RANKING: UInt8 = 3
"""`rank` `row_number` `dense_rank` `rank_dense` -> SX_WINDOW; `()` + OVER."""
comptime SQLNAME_GRAMMAR_FORM: UInt8 = 4
"""`case` / `extract` — not functions at all; a distinct grammar production."""
comptime SQLNAME_RESERVED_WORD: UInt8 = 5
"""`not` `exists` `distinct` — read as KEYWORDS before a function name exists.
⚠ ONE of the three is `SQLNAME_AGG_FASTPATH` severity rather than the
syntax-error severity of `case` / `extract`: `not(x)` becomes the NOT operator
and returns a wrong answer with NO diagnostic. `distinct(x)` becomes a
DIFFERENT QUERY (`SELECT DISTINCT (x)`) and `exists(x)` a syntax error — both
surface something, neither surfaces the user's function."""


@always_inline
def sql_name_claimed_by_grammar(name: String) -> UInt8:
    """★★ DOES THE SQL GRAMMAR TAKE THIS (lower-folded) NAME AWAY FROM A CALL?

    Returns `SQLNAME_FREE`, or WHICH namespace claims it. The question is asked
    for the shape `<name>(<one arg>)` — the only shape a declared scalar UDF is
    ever called in — so an identifier the parser claims ONLY under a different
    following token is deliberately NOT claimed here:

      * `date`  — claimed only by `date '<literal>'`, i.e. a following STRING.
                  `date(x)` is an ordinary call.
      * `timestamp` / `timestamptz` — the same rule
                  (2026-09-21): claimed only by a following STRING, so
                  `timestamp(x)` is an ordinary call and a COLUMN called
                  `timestamp` still resolves.
      * `true` / `false` — the boolean-literal arm explicitly stands down when
                  the next token is `(`, so `true(x)` is an ordinary call.

    ⛔ AND IT IS NOT ONLY ABOUT FUNCTION-SHAPED NAMESPACES. `not`, `exists` and
    `distinct` are ordinary RESERVED WORDS — no code table, no `(`-conditional
    arm, nothing that looks like a function — and they were admitted for three
    days because every previous fix asked "which FUNCTION namespaces are there".
    The question this predicate answers is the wider one: does the grammar read
    this identifier as anything at all before a call can be recognised.

    ⚠ THIS IS THE ONE PLACE. `refuse_undeclarable_udf_name` calls it, and the
    falsifier in `tests/sdk/test_scalar_udf_spelling_e2e.mojo` checks its
    answer against the PARSER ITSELF, by parsing `SELECT <name>(a) FROM t`.

    ⛔ AND THE SCOPE OF THAT COVER IS STATED, BECAUSE THE UNQUALIFIED VERSION OF
    THIS SENTENCE WAS FALSE AND SHIPPED THREE ADMITTED NAMES UNDER IT. It used
    to end "so a namespace added to the grammar and forgotten here goes RED
    without anybody having to remember that UDF declaration exists". The ORACLE
    was the grammar, but the falsifier's CORPUS was derived from
    `sql_fn_table` — a different namespace, which names none of the claimants —
    so a grammar arm that table did not know about was invisible to it. `not`,
    `exists` and `distinct` sat inside a gate written to catch exactly them.

    The corpus is now every literal `sql_parser.mojo` + THIS FILE compare an
    IDENTIFIER against (`//src/komira:sql_grammar_vocab_blob`), so the sentence
    holds for a name the grammar claims by COMPARING TEXT — which is how every
    claim in this parser is currently made. It does NOT hold for a claim made on
    a TOKEN KIND, or for a vocabulary moved into a third file that blob does not
    carry. Those two are the residual; adding a path to the genrule closes the
    second.
    """
    if sql_agg_code(name) >= 0:
        return SQLNAME_AGG_FASTPATH
    if sql_call_is_aggregate(name):
        return SQLNAME_AGG_STATISTICAL
    if sql_win_ranking_code(name) >= 0:
        return SQLNAME_WINDOW_RANKING
    if (
        name == "case"
        or name == "extract"
        or name == "cast"
        or name == "try_cast"
    ):
        # ⚠ ALL FOUR ARE CLAIMED ON A FOLLOWING `(` — `case(x)` is parsed as a
        # CASE expression and `extract(x)` as EXTRACT(<field> FROM ...).
        # Neither has a `sql_fn_table` row and neither is an aggregate, so
        # before this line existed both walked through every arm of the declare
        # door.
        #
        # ⭐⭐ `cast` / `try_cast` JOINED THEM 2026-09-16, AND THEY ARRIVED THE
        # SAME WAY THE OTHER FIVE NAMESPACES DID: a grammar arm landed and this
        # predicate was not consulted. The cast grammar (2026-09-14) added
        # `CAST(<expr> AS <type>)` to `_parse_primary`
        # (`sql_parser.mojo:~1522`), which fires on the NAME + `(` and rewrites
        # the call to an internal desugar name — so `cast(a)` is never an
        # ordinary call to `cast`, a UDF declared under that name can never be
        # reached, and the declare door ADMITTED it for two days.
        # `test_the_declare_door_AGREES_WITH_THE_PARSER_over_every_table_name`
        # named both, by execution, because its corpus is derived from the
        # parser's own vocabulary rather than from a list somebody maintains.
        #
        # ⛔ THIS DOES NOT MAKE A LEGITIMATE NAME UNSPELLABLE. The ONLY caller
        # is `refuse_undeclarable_udf_name` (`sql_udf_catalog.mojo`), so the
        # single consequence is that a scalar UDF may not be DECLARED under
        # these four names. A COLUMN called `cast` is untouched — the parser's
        # arm itself fires on a following `(` only, which is the same guard the
        # `true`/`false` arm states — and `CAST(x AS BIGINT)` keeps working.
        return SQLNAME_GRAMMAR_FORM
    if name == "not" or name == "exists" or name == "distinct":
        # ⛔⛔ THE FIFTH NAMESPACE, MEASURED 2026-09-05 — and the reason it was
        # missed is the reason every one of the previous four was: the door that
        # found the others asked the namespaces somebody had thought of.
        #
        # These are RESERVED WORDS the parser reads before a function name can
        # exist, and each takes `<name>(a)` somewhere different:
        #
        #   `not(a)`      -> `_parse_not` consumes NOT and parses `(a)` as a
        #                    PARENTHESISED operand: the expression becomes
        #                    `SXUN_NOT(a)`. ⛔ NO ERROR — the user's
        #                    function is replaced by the NOT operator and the
        #                    query returns a boolean negation of their column.
        #   `distinct(a)` -> `_parse_select_stmt` takes DISTINCT off the front
        #                    of the SELECT LIST, so `SELECT distinct(a) AS y`
        #                    is `SELECT DISTINCT (a) AS y` — a DIFFERENT QUERY.
        #                    ⚠ MEASURED, rather than assumed to be silent: that
        #                    plan is DISTINCT -> PROJECT -> SCAN, which
        #                    `distinct_node_exec` declines today, so what comes
        #                    back is an error ABOUT DISTINCT for a query in
        #                    which the user wrote no DISTINCT.
        #   `exists(a)`   -> `_parse_cmp` routes to `_parse_exists_subquery`,
        #                    which demands `( SELECT ...` — a syntax error about
        #                    a subquery the user never wrote.
        #
        # ⚠ THIS LIST IS A RESTATEMENT OF THE PARSER'S VOCABULARY AND CANNOT BE
        # ANYTHING ELSE HERE. `sql_udf_catalog`'s dependency closure is exactly
        # `sql_ast` + `sql_fn_table`, so it cannot import `sql_parser` to ASK
        # it. What keeps
        # the restatement honest is not this comment: it is
        # `test_the_declare_door_AGREES_WITH_THE_PARSER_over_every_table_name`,
        # whose corpus is now EVERY LITERAL THE PARSER COMPARES AN IDENTIFIER
        # AGAINST, read out of the real `sql_parser.mojo` + this file. A word
        # added to the grammar tomorrow and forgotten here goes red there with
        # nobody having to remember that UDF declaration exists — which is what
        # the old corpus (derived from `sql_fn_table`, a table that names none of
        # these three) could not do, under a docstring that claimed it did.
        return SQLNAME_RESERVED_WORD
    return SQLNAME_FREE


# The recursive children live in SEPARATE Data structs (each holding an
# `OwnedPointer[SqlExpr]`), and `SqlExpr` holds those by value via `Optional`.
# This mirrors the IR `Expr` shape (Expr -> Optional[BinaryOpData] ->
# OwnedPointer[Expr]) — Mojo rejects a struct that holds `OwnedPointer[Self]`
# DIRECTLY, but allows the recursion when it is broken by a second struct.


struct SqlBinaryData(Movable):
    """Binary-op children of a SX_BINARY node."""

    var left: OwnedPointer[SqlExpr]
    var right: OwnedPointer[SqlExpr]

    def __init__(out self, var left: SqlExpr, var right: SqlExpr):
        self.left = OwnedPointer(left^)
        self.right = OwnedPointer(right^)


struct SqlAggData(Movable):
    """The argument of a SX_AGG node. COUNT(*) carries a SX_STAR sentinel arg
    (so the in-cycle `OwnedPointer[SqlExpr]` edge stays BARE — an
    `Optional[OwnedPointer[Self]]` in-cycle edge trips Mojo's recursion check;
    only the OUT-of-cycle edge may be Optional-wrapped, per the IR
    `CorrelatedSubqueryData` note in expr.mojo)."""

    var arg: OwnedPointer[SqlExpr]

    def __init__(out self, var arg: SqlExpr):
        self.arg = OwnedPointer(arg^)


struct SqlCallData(Movable):
    """The argument list of a SX_CALL scalar function-call node. Args live in a
    heap-backed `Slab[SqlExpr]` (its byte-backed `List[UInt8]` storage carries
    no direct `SqlExpr` FIELD, so it breaks the SqlExpr -> SqlCallData ->
    SqlExpr recursion cycle exactly like the `OwnedPointer[SqlExpr]` edges do)."""

    var args: Slab[SqlExpr]

    def __init__(out self, var args: Slab[SqlExpr]):
        self.args = args^


struct SqlCaseData(Movable):
    """The branches of a SX_CASE node. `conds`/`results` are PARALLEL Slabs (one
    WHEN condition + one THEN result per branch, `len(conds) == len(results)`);
    `otherwise` holds the ELSE default in a 0-or-1-entry Slab (empty => omitted =>
    the binder supplies a NULL literal, per SQL default semantics).

    A SIMPLE case (`CASE x WHEN v THEN ...`) is desugared at PARSE time — each
    branch's condition is the synthesized `x = v` comparison — so this struct only
    ever carries the SEARCHED form; the binder needs no operand slot.

    All three fields are byte-backed `Slab[SqlExpr]` (their inner `List[UInt8]`
    storage carries no direct `SqlExpr` FIELD), which breaks the `SqlExpr ->
    SqlCaseData -> SqlExpr` recursion cycle exactly like `SqlCallData`'s
    `Slab[SqlExpr]` does — so no in-cycle `Optional[OwnedPointer[SqlExpr]]` edge is
    introduced (which would trip Mojo's recursion check)."""

    var conds: Slab[SqlExpr]  # WHEN conditions (searched form)
    var results: Slab[SqlExpr]  # THEN results (parallel to conds)
    var otherwise: Slab[SqlExpr]  # ELSE default (0 or 1 entries)

    def __init__(out self, var conds: Slab[SqlExpr], var results: Slab[SqlExpr], var otherwise: Slab[SqlExpr]):
        self.conds = conds^
        self.results = results^
        self.otherwise = otherwise^


struct SqlWindowData(Copyable, Movable):
    """The metadata of a SX_WINDOW node — `f(...) OVER (PARTITION BY ... ORDER BY
    ... [frame])`. Holds ONLY plain column NAMES + scalar frame parameters,
    NO nested `SqlExpr` — so it introduces no `SqlExpr -> SqlWindowData -> SqlExpr`
    recursion cycle (the AST stays acyclic through the window node, keeping it
    clear of the Mojo AOT recursive-destructor wedge).

    Fields:
        func           — SXWIN_* window function.
        arg_col        — the aggregate argument column ("" for ranking fns / for
                         `COUNT(*)`).
        partition_by   — PARTITION BY column names (may be empty = global window).
        order_by       — ORDER BY column names (parallel to `descending`).
        descending     — per-order-key DESC flag (parallel to `order_by`).
        has_frame      — True iff an explicit `ROWS/RANGE ...` frame was written.
        frame_*        — the frame units + start/end bound tags & offsets (1:1 with
                         the IR `PartitionFrame`); only meaningful when `has_frame`.
        value_offset   — VALUE windows only: LAG / LEAD's offset (1 when not
                         written; SIGNED — `LAG(x, -1)` is `LEAD(x, 1)`) and
                         NTH_VALUE's n. 0 for every other function.
        has_default    — LAG / LEAD only: a NON-NULL third argument was written
                         (`LAG(x, 1, NULL)` is `LAG(x, 1)` in SQL, so a NULL
                         default leaves this False).
        default_*      — that literal: `default_kind` is SX_INT / SX_FLOAT /
                         SX_STRING / SX_DATE (the DATE's text in `default_text`),
                         the value in the matching member."""

    var func: UInt8
    var arg_col: String
    var partition_by: List[String]
    var order_by: List[String]
    var descending: List[Bool]
    var has_frame: Bool
    var frame_units: UInt8
    var frame_start_tag: UInt8
    var frame_start_offset: Int64
    var frame_end_tag: UInt8
    var frame_end_offset: Int64
    var value_offset: Int64
    var has_default: Bool
    var default_kind: UInt8
    var default_int: Int64
    var default_float: Float64
    var default_text: String
    # ⛔ THE QUALIFIER OF EACH COLUMN NAME ABOVE, "" WHEN NONE WAS WRITTEN
    # (2026-09-24). These were DROPPED at parse, so over
    # `P LEFT JOIN Q ON P.k = Q.k` a `PARTITION BY Q.k` / `ORDER BY Q.k` /
    # `sum(Q.k)` / `lag(Q.k)` read the LEFT `k` — MEASURED: `count(*) OVER
    # (PARTITION BY Q.k)` answered 1,1,1,1 where DuckDB v1.5.3 answers
    # 3,3,3,1, silently. The binder resolves a qualified name through its
    # `BindScope` exactly as an ordinary column reference does
    # (`sql_bind_scope._resolve_col`). Still plain `String`s — the AST stays
    # acyclic through the window node.
    var arg_qual: String
    var partition_qual: List[String]  # parallel to `partition_by`
    var order_qual: List[String]  # parallel to `order_by`

    def __init__(
        out self,
        func: UInt8,
        arg_col: String,
        var partition_by: List[String],
        var order_by: List[String],
        var descending: List[Bool],
    ):
        self.func = func
        self.arg_col = arg_col
        self.arg_qual = String("")
        self.partition_qual = List[String]()
        for _ in range(len(partition_by)):
            self.partition_qual.append(String(""))
        self.order_qual = List[String]()
        for _ in range(len(order_by)):
            self.order_qual.append(String(""))
        self.partition_by = partition_by^
        self.order_by = order_by^
        self.descending = descending^
        self.has_frame = False
        self.frame_units = SXFRAME_ROWS
        self.frame_start_tag = SXFRAME_UNBOUNDED_PRECEDING
        self.frame_start_offset = 0
        self.frame_end_tag = SXFRAME_CURRENT_ROW
        self.frame_end_offset = 0
        self.value_offset = 0
        self.has_default = False
        self.default_kind = SX_INT
        self.default_int = 0
        self.default_float = 0.0
        self.default_text = String("")

    def set_frame(
        mut self,
        units: UInt8,
        start_tag: UInt8,
        start_offset: Int64,
        end_tag: UInt8,
        end_offset: Int64,
    ):
        self.has_frame = True
        self.frame_units = units
        self.frame_start_tag = start_tag
        self.frame_start_offset = start_offset
        self.frame_end_tag = end_tag
        self.frame_end_offset = end_offset


struct SqlExpr(Movable):
    """A parsed SQL scalar/aggregate expression tree node.

    Fields:
        tag: UInt8            — one of SX_*.
        op: UInt8             — SXOP_* (SX_BINARY) or SXAGG_* (SX_AGG).
        text: String         — column name (SX_COLUMN) / string literal (SX_STRING)
                               / the SOURCE TOKEN of an aggregate (SX_AGG: `avg`
                               vs `mean`, both SXAGG_AVG — see `SqlExpr.agg`).
        int_val: Int64       — SX_INT.
        float_val: Float64   — SX_FLOAT.
        _binary              — binary-op children (SX_BINARY).
        _agg                 — aggregate argument (SX_AGG).
    """

    var tag: UInt8
    var op: UInt8
    var text: String
    var qualifier: String  # SX_COLUMN only: the table qualifier of `t.col` ("" if unqualified). `_bind_corr_scalar` uses it to split inner vs outer columns; `_resolve_col` resolves a qualified column through the FROM scope to its output name.
    var int_val: Int64
    var float_val: Float64
    var agg_distinct: Bool  # SX_AGG only: True for COUNT(DISTINCT col)
    var like_negate: Bool  # SX_LIKE only: True for NOT LIKE
    var _binary: Optional[SqlBinaryData]
    var _agg: Optional[SqlAggData]
    var _call: Optional[SqlCallData]  # SX_CALL: scalar fn-call arguments
    var _case: Optional[SqlCaseData]  # SX_CASE: CASE WHEN branches
    var _window: Optional[SqlWindowData]  # SX_WINDOW: OVER-clause metadata

    def __init__(out self, tag: UInt8):
        self.tag = tag
        self.op = 0
        self.text = String("")
        self.qualifier = String("")
        self.int_val = 0
        self.float_val = 0.0
        self.agg_distinct = False
        self.like_negate = False
        self._binary = None
        self._agg = None
        self._call = None
        self._case = None
        self._window = None

    @staticmethod
    def column(name: String, qualifier: String = String("")) -> SqlExpr:
        var e = SqlExpr(SX_COLUMN)
        e.text = name
        e.qualifier = qualifier
        return e^

    @staticmethod
    def int_lit(v: Int64) -> SqlExpr:
        var e = SqlExpr(SX_INT)
        e.int_val = v
        return e^

    @staticmethod
    def float_lit(v: Float64) -> SqlExpr:
        var e = SqlExpr(SX_FLOAT)
        e.float_val = v
        return e^

    @staticmethod
    def string_lit(v: String) -> SqlExpr:
        var e = SqlExpr(SX_STRING)
        e.text = v
        return e^

    @staticmethod
    def date_lit(v: String) -> SqlExpr:
        """`date 'YYYY-MM-DD'` — the raw date string; the binder converts it to
        a date32 (days-since-epoch) ScalarValue."""
        var e = SqlExpr(SX_DATE)
        e.text = v
        return e^

    @staticmethod
    def timestamp_lit(v: String, aware: Bool) -> SqlExpr:
        """`timestamp '...'` / `timestamptz '...'` — the raw string; the binder
        converts it to a microseconds-since-epoch ScalarValue.

        `aware` is `TIMESTAMPTZ`, which is a DIFFERENT INSTANT for the same
        digits (see `SX_TIMESTAMP`), so it rides the node rather than being
        re-derived downstream."""
        var e = SqlExpr(SX_TIMESTAMP)
        e.text = v
        e.op = TSLIT_AWARE if aware else TSLIT_NAIVE
        return e^

    @staticmethod
    def star() -> SqlExpr:
        return SqlExpr(SX_STAR)

    @staticmethod
    def binary(op: UInt8, var left: SqlExpr, var right: SqlExpr) -> SqlExpr:
        var e = SqlExpr(SX_BINARY)
        e.op = op
        e._binary = SqlBinaryData(left^, right^)
        return e^

    @staticmethod
    def agg(
        func: UInt8,
        var arg: SqlExpr,
        distinct: Bool = False,
        spelling: String = String(""),
    ) -> SqlExpr:
        """`arg` is the aggregate argument; COUNT(*) passes a SX_STAR sentinel.
        `distinct` marks COUNT(DISTINCT col).

        ⭐ `spelling` IS THE SOURCE TOKEN, AND IT IS LOAD-BEARING FROM THE DAY
        `sql_agg_code` GREW ITS FIRST ALIAS. `SXAGG_*` is a code, so several
        NAMES can map to one — `avg` and `mean` both reach `SXAGG_AVG`. DuckDB
        names an unaliased aggregate output column after the token the user
        WROTE (MEASURED v1.5.3: `avg(v)` -> `avg(v)`, `mean(v)` -> `mean(v)`,
        `MEAN(v)` -> `mean(v)`), and `sql_bind_names._unaliased_agg_out_name`
        implements that convention. Re-deriving the name from `op` would answer
        `avg(v)` for a query that says `mean(v)` — a WRONG COLUMN NAME, which
        on this surface is a wrong ANSWER, because a caller reads a result by
        name.

        ⚠ EMPTY MEANS "ASK THE OP", not "no name". Every SX_AGG the PARSER
        builds carries its token; a node built anywhere else falls back to the
        canonical spelling, which is what `_sxagg_text` has always returned."""
        var e = SqlExpr(SX_AGG)
        e.op = func
        e.text = spelling
        e.agg_distinct = distinct
        e._agg = SqlAggData(arg^)
        return e^

    @staticmethod
    def call(name: String, var args: Slab[SqlExpr]) -> SqlExpr:
        """A scalar function call `name(args...)` — e.g.
        `date_diff('day', date '2026-09-01', date '2026-09-15')`. The (lower-
        folded) function name is in `text`; the argument expressions live in the
        `_call` slot. The binder (`_bind_scalar_call`) dispatches on the name."""
        var e = SqlExpr(SX_CALL)
        e.text = name
        e._call = SqlCallData(args^)
        return e^

    @staticmethod
    def subquery(idx: Int) -> SqlExpr:
        """A parenthesized scalar subquery `(SELECT ...)`. To keep
        `SqlExpr`'s type graph FREE of a `SelectStmt` cycle (an owning
        `SqlExpr -> SelectStmt -> SqlExpr` cycle deadlocks whole-program
        destructor synthesis in the Mojo AOT compiler), the subquery BODY lives
        in the enclosing statement's `SelectStmt.subqueries` side-table; this
        node stores only its INDEX (in `int_val`). The binder
        (`_bind_scalar_subquery`) resolves the index against the threaded
        subquery table and lowers the body to an `EXPR_CORRELATED_SUBQUERY` of
        kind `CORR_KIND_SCALAR` with EMPTY outer refs (uncorrelated), which the
        optimizer's Phase-0.44 `scalar_subquery_decorrelate` turns into a
        broadcast `JOIN_CROSS`."""
        var e = SqlExpr(SX_SUBQUERY)
        e.int_val = Int64(idx)
        return e^

    @always_inline
    def subquery_index(self) -> Int:
        """The index of this SX_SUBQUERY node's body in the enclosing statement's
        `SelectStmt.subqueries` side-table."""
        return Int(self.int_val)

    @staticmethod
    def like(
        var child: SqlExpr, pattern: String, negate: Bool, flavour: UInt8 = SXLIKE_LIKE
    ) -> SqlExpr:
        """`child [NOT] LIKE 'pattern'`. The child lives in the `_agg` slot; the
        pattern is the raw SQL LIKE string in `text`; `negate` marks NOT LIKE.
        `flavour` (in `op`) is SXLIKE_LIKE or SXLIKE_ILIKE (case-insensitive)."""
        var e = SqlExpr(SX_LIKE)
        e.op = flavour
        e.text = pattern
        e.like_negate = negate
        e._agg = SqlAggData(child^)
        return e^

    @staticmethod
    def unary(op: UInt8, var child: SqlExpr) -> SqlExpr:
        """`NOT child` / `child IS [NOT] NULL`. `op` is the IR's own `UN_*` code
        (UN_NOT / UN_IS_NULL / UN_IS_NOT_NULL) — carried through unmapped, so
        there is no second vocabulary for the binder to translate and get wrong.
        The child shares SX_LIKE's `_agg` slot; see SX_UNARY's declaration."""
        var e = SqlExpr(SX_UNARY)
        e.op = op
        e._agg = SqlAggData(child^)
        return e^

    @staticmethod
    def bool_lit(v: Bool) -> SqlExpr:
        """`TRUE` / `FALSE`, stored 0/1 in `int_val`."""
        var e = SqlExpr(SX_BOOL)
        e.int_val = Int64(1) if v else Int64(0)
        return e^

    @staticmethod
    def null_lit() -> SqlExpr:
        """`NULL` — see `SX_NULL`."""
        return SqlExpr(SX_NULL)

    @staticmethod
    def case(var conds: Slab[SqlExpr], var results: Slab[SqlExpr], var otherwise: Slab[SqlExpr]) -> SqlExpr:
        """`CASE WHEN c0 THEN r0 [WHEN c1 THEN r1 ...] [ELSE d] END`. `conds`
        and `results` are parallel (one WHEN/THEN pair per branch); `otherwise`
        carries the ELSE default in a 0-or-1-entry Slab (empty => the binder
        supplies a NULL literal). A simple `CASE x WHEN v ...` is already desugared
        into the searched form by the parser (each condition is `x = v`)."""
        var e = SqlExpr(SX_CASE)
        e._case = SqlCaseData(conds^, results^, otherwise^)
        return e^

    @staticmethod
    def window(var w: SqlWindowData) -> SqlExpr:
        """A window-function node `f(...) OVER (...)`. The OVER-clause
        metadata (function, arg column, partition/order keys, frame) lives in the
        `_window` slot; the binder (`_bind_window_projection` -> `_apply_window`)
        lowers it to a `LogicalPlan.partition_by` node."""
        var e = SqlExpr(SX_WINDOW)
        e._window = w^
        return e^

    @always_inline
    def is_window(self) -> Bool:
        """True iff this node is a window function `f(...) OVER (...)`."""
        return self.tag == SX_WINDOW

    def copy(self) -> SqlExpr:
        """Deep-copy this expression tree (needed to reuse a left operand across
        the N disjuncts of a desugared `IN (v1, ..., vN)`)."""
        var e = SqlExpr(self.tag)
        e.op = self.op
        e.text = self.text
        e.qualifier = self.qualifier
        e.int_val = self.int_val
        e.float_val = self.float_val
        e.agg_distinct = self.agg_distinct
        e.like_negate = self.like_negate
        if self._binary:
            e._binary = SqlBinaryData(
                self._binary.value().left[].copy(),
                self._binary.value().right[].copy(),
            )
        if self._agg:
            e._agg = SqlAggData(self._agg.value().arg[].copy())
        if self._call:
            var na = Slab[SqlExpr]()
            ref oa = self._call.value().args
            for i in range(len(oa)):
                na.append(oa[i].copy())
            e._call = SqlCallData(na^)
        if self._case:
            ref cd = self._case.value()
            var nc = Slab[SqlExpr]()
            for i in range(len(cd.conds)):
                nc.append(cd.conds[i].copy())
            var nr = Slab[SqlExpr]()
            for i in range(len(cd.results)):
                nr.append(cd.results[i].copy())
            var no = Slab[SqlExpr]()
            for i in range(len(cd.otherwise)):
                no.append(cd.otherwise[i].copy())
            e._case = SqlCaseData(nc^, nr^, no^)
        if self._window:
            # SqlWindowData is Copyable (plain names + scalars, no SqlExpr), so an
            # explicit copy of the Optional is a full deep copy.
            e._window = self._window.copy()
        # SX_SUBQUERY carries only its side-table INDEX (copied via `int_val`
        # in the header above), so it needs no special handling here.
        return e^

    @always_inline
    def is_aggregate(self) -> Bool:
        """True iff this node is an aggregate call at the top level."""
        return self.tag == SX_AGG

    def contains_aggregate(self) -> Bool:
        """True iff this expression tree contains an aggregate call ANYWHERE
        (top-level or nested in arithmetic / a LIKE child) — the detector
        that routes `100.0*sum(x)/sum(y)` and `max(v1)-min(v2)` through the
        aggregate binder instead of the scalar binder."""
        if self.tag == SX_AGG:
            return True
        # A statistical aggregate riding on the `SX_CALL fn(args)` grammar
        # (median / stddev / corr). `pow(corr(...), 2)` is NOT
        # caught here (pow is scalar) but its `corr` arg IS, via the `_call`
        # arg walk below.
        if self.tag == SX_CALL and sql_call_is_aggregate(self.text):
            return True
        if self._binary:
            if self._binary.value().left[].contains_aggregate():
                return True
            if self._binary.value().right[].contains_aggregate():
                return True
        # ⚠ SX_UNARY IS NAMED HERE ALONGSIDE SX_LIKE, and forgetting it would be
        # silent: both park their child in `_agg`, and an SX_AGG's own arg must
        # NOT count (a node that IS an aggregate is caught by the tag test at
        # the top), so this cannot be written as a bare `if self._agg`.
        # `sum(x) IS NULL` in a HAVING clause is the shape that would otherwise
        # bind as a non-aggregate and resolve against the wrong schema.
        if (self.tag == SX_LIKE or self.tag == SX_UNARY) and self._agg:
            if self._agg.value().arg[].contains_aggregate():
                return True
        if self._call:
            ref ca = self._call.value().args
            for i in range(len(ca)):
                if ca[i].contains_aggregate():
                    return True
        if self._case:
            ref cd = self._case.value()
            for i in range(len(cd.conds)):
                if cd.conds[i].contains_aggregate():
                    return True
            for i in range(len(cd.results)):
                if cd.results[i].contains_aggregate():
                    return True
            for i in range(len(cd.otherwise)):
                if cd.otherwise[i].contains_aggregate():
                    return True
        return False

    @always_inline
    def agg_has_arg(self) -> Bool:
        """True iff this SX_AGG node has a real argument (False for COUNT(*))."""
        return self.tag == SX_AGG and self._agg and self._agg.value().arg[].tag != SX_STAR

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


# =============================================================================
# Table-valued-function KINDS + their per-call options
# =============================================================================
# `read_parquet` binds off the file's own FOOTER, so it needs nothing from the
# SQL text. `read_csv` / `read_json` have no footer: the ONLY schema a CSV file
# carries is its header LINE, and a JSONL file carries none at all. Both are
# therefore bound by INFERENCE over a bounded prefix — and inference is steered
# by the very options DuckDB's own `read_csv(...)` call spells, so the options
# have to reach the binder rather than being dropped at the parser.
#
# ⚠ THE OPTION SET IS AN ALLOWLIST AND UNKNOWN OPTIONS RAISE. An option that is
# SILENTLY IGNORED is the worst outcome available here: `all_varchar=true` alone
# is the difference between 16 VARCHAR columns and 6 typed ones, so ignoring it
# would return the right ROW COUNT with the wrong TYPES — and a cross-engine
# comparison that only counts rows is exactly the vacuity `value_gate.py` was
# built to end. Raising names the gap; ignoring manufactures a false green.

# ★ THE FROM-LESS SELECT (2026-09-25). `SELECT 7/2` (no FROM at all)
# reads ONE row with no columns in DuckDB. The parser records it as a FROM
# relation of THIS name and the binder reads it as a one-row, one-column
# in-memory relation (`sql_catalog.from_less_relation_scan`). ⚠ THE SPACE IS
# LOAD-BEARING: no tokenizer produces an identifier with a space, so no CTE,
# catalog table or `FROM x` can collide with it (the `CAST_DESUGAR_NAME` trick).
comptime FROM_LESS_RELATION: String = "from-less select"

comptime TVF_NONE: UInt8 = 0
comptime TVF_PARQUET: UInt8 = 1
comptime TVF_CSV: UInt8 = 2
comptime TVF_JSON: UInt8 = 3
# `read_avro` (2026-09-14). AVRO IS THE THIRD SCHEMA-CARRYING SHAPE and it sits
# on the PARQUET side of the split this module's note draws, not the CSV/JSON
# side: an OCF carries its writer schema as JSON in the CONTAINER HEADER, so the
# bind reads the file rather than inferring over a prefix, and `TvfOptions` is
# left at its defaults for this kind — there is no dialect to steer. It is
# nonetheless routed through `sql_tvf_bind` and not through the parquet arm,
# because the leaf it builds is `SOURCE_KIND_ROW` (`komira.avro` DECLARES
# `orientation = ROW`), i.e. the same footerless-TVF lowering CSV and JSONL get.
#
# ⛔ THE TYPE ENVELOPE IS NARROWER THAN THE FORMAT, AND THAT IS NOT A PARSER
# BUG. An Avro TIMESTAMP_*/DATE64/narrow-int column is unreadable through the
# SDK leaf today, and today's bench fixtures never present one. READ OFF THE
# FIXTURE'S OWN OCF HEADER, 2026-09-14 -- all 21 fields of
# `bench/data/omni/avro/lineitem_*.avro` are `["null", long|double|string]`:
# no logical type, no `int`, no decimal, and the three date columns
# (`l_shipdate`/`l_commitdate`/`l_receiptdate`) are plain `long`.
#   ⚠ THE USUAL TELLING OF THIS IS WRONG IN A WAY THAT MATTERS.
# `bench/data/gen_omni_lineitem.sh:543-547` does carry a
# date/timestamp/decimal -> Avro `string` coercion, but it is NOT what produced
# these files: a coerced date would be `string`, and these are `long`, i.e. the
# source columns were ALREADY integral. So the coercion is a standing hazard for
# a FUTURE fixture, not the reason this one is readable. Either way the envelope
# is UNTESTED by the corpus: a `read_avro` over a file that really does carry a
# logical type raises at bind or decodes wrong, and nothing here would catch it.
comptime TVF_AVRO: UInt8 = 4


struct TvfOptions(Copyable, Movable):
    """The SEMANTICS-BEARING options of a `read_csv` / `read_json` TVF call.

    Only options that change WHAT THE RESULT IS live here. An option that
    changes only HOW the result is computed (`parallel`, `auto_detect=true`)
    is accepted by the parser and carries no field — it cannot alter a value,
    so honoring it is not a correctness matter. Every OTHER option raises at
    parse time (see the module note above).

    Fields:
        all_varchar:  DuckDB `all_varchar=true` — every column is VARCHAR, type
                      inference is skipped entirely. Honored by the binder,
                      which stamps an all-STRING schema on the scan leaf; the
                      row reader parses each cell per the leaf's DECLARED dtype,
                      so no reader change is needed for this to be real.
        has_header:   DuckDB `header=` (CSV). Default True — which is also
                      `CsvReadOptions`' default, and what every corpus fixture
                      is written with.
        delimiter:    DuckDB `delim=`/`sep=` (CSV), one byte. Default ','.
    """

    var all_varchar: Bool
    var has_header: Bool
    var delimiter: UInt8

    def __init__(out self):
        self.all_varchar = False
        self.has_header = True
        self.delimiter = UInt8(ord(","))


struct FromRelation(Copyable, Movable):
    """One FROM relation. Either a CATALOG table (resolved by `name` against the
    `SqlCatalog`) or a `read_parquet('path')` / `read_csv('path', ...)` /
    `read_json('path', ...)` table-valued function (the file at `tvf_path` is
    bound directly — no catalog entry needed). `tvf_path` is `Some(path)` iff
    this is a TVF, and `tvf_kind` says WHICH reader binds it.

    A `FROM (SELECT ...) d` derived table is parked in the enclosing
    statement's `subqueries` side-table (kind `SUBQ_DERIVED`); the parser emits a
    `named("d#<subquery index>", "d")` relation for it, and `_bind_query`
    pre-binds the derived body into the per-query CTE scope under that key — so a
    derived table resolves through the SAME named-derived-relation path a CTE
    does, and only through the FROM entry that declares it.

    `rel_alias` is the AS alias (`t AS a` / `t a`), or `""` (a derived table
    always has one: its alias or `unnamed_subquery[N]`). A qualified `q.col`
    resolves against the alias when there is one, and against `name` only when
    there is not (`_visible_qualifiers`: an alias hides the table name). That
    one set is what `BindScope`, a join side and a correlated subquery's inner
    relation match a qualifier against."""

    var name: String  # catalog/CTE/derived table name; "" when a pure TVF
    var tvf_path: Optional[String]  # Some(path) => a read_* TVF
    var tvf_kind: UInt8  # TVF_{NONE,PARQUET,CSV,JSON,AVRO}
    var tvf_opts: TvfOptions  # the TVF call's semantics-bearing options
    var rel_alias: String  # AS alias ("" if none) — `alias` is a reserved word

    def __init__(
        out self,
        name: String,
        var tvf_path: Optional[String],
        rel_alias: String = String(""),
        tvf_kind: UInt8 = TVF_NONE,
        var tvf_opts: TvfOptions = TvfOptions(),
    ):
        self.name = name
        self.tvf_path = tvf_path^
        self.tvf_kind = tvf_kind
        self.tvf_opts = tvf_opts^
        self.rel_alias = rel_alias

    @staticmethod
    def named(name: String, rel_alias: String = String("")) -> FromRelation:
        return FromRelation(name, None, rel_alias)

    @staticmethod
    def tvf_of(
        path: String, kind: UInt8, var opts: TvfOptions,
        rel_alias: String = String(""),
    ) -> FromRelation:
        """A `read_*` TVF carrying its parsed options. EVERY kind comes through
        here, parquet included.

        ⛔ THERE WAS A SECOND CONSTRUCTOR AND IT WAS A SILENT WRONG ANSWER.
        `FromRelation.tvf(path, alias)` built a PARQUET relation with a default
        `TvfOptions`, and `sql_parser._parse_table_ref` called it on the parquet
        arm AFTER parsing the option list — so every option the user wrote was
        parsed and then discarded. `read_parquet('f.parquet', header=false,
        delim='|')` parsed clean and ignored both. Deleted 2026-09-15 rather
        than fixed in place: a constructor that cannot carry options is an
        invitation to drop them, and with one call site there was nothing to
        weigh against removing it.

        The AVRO arm always passes a DEFAULT `TvfOptions` — the parser rejects
        an option list on that kind outright rather than recording one
        (`sql_parser._parse_table_ref`, 2026-09-14). The PARQUET arm likewise
        always passes a default, because every dialect option is now refused by
        name for that kind (`_refuse_option_for_kind`); it is routed through
        here anyway so that the next option added without a guard is
        MIS-HONORED rather than silently dropped. A wrong value is findable; a
        drop is not."""
        return FromRelation(
            String(""), Optional(String(path)), rel_alias, kind, opts^,
        )


struct SelectItem(Movable):
    """One item in the SELECT list: `expr [AS out_alias]`, or `*`."""

    var expr: SqlExpr
    var out_alias: Optional[String]
    var is_star: Bool

    def __init__(out self, var expr: SqlExpr, var out_alias: Optional[String], is_star: Bool):
        self.expr = expr^
        self.out_alias = out_alias^
        self.is_star = is_star


struct OrderKey(Movable):
    """One ORDER BY key: `expr [ASC|DESC] [NULLS FIRST|NULLS LAST]`. v1 requires
    `expr` to resolve to an output column name.

    ★ `nulls_first` IS AN `Optional[Bool]`, AND THE EMPTY STATE IS LOAD-BEARING
    (2026-09-22). `None` means the
    query said nothing, and the plan then DERIVES `nulls_first = not
    descending` exactly as it did before this clause existed
    (`logical_plan_variants._resolve_nulls_first`). A `Bool` cannot encode that
    third state, and without it every query in the corpus would start
    asserting a placement it never asked for.
    """

    var expr: SqlExpr
    var descending: Bool
    var nulls_first: Optional[Bool]

    def __init__(
        out self,
        var expr: SqlExpr,
        descending: Bool,
        var nulls_first: Optional[Bool] = None,
    ):
        self.expr = expr^
        self.descending = descending
        self.nulls_first = nulls_first^


struct SelectStmt(Movable):
    """The parsed analytical SELECT statement (v1 + join grammar + CTEs).

    `from_tables` holds every FROM relation — comma-separated (implicit join)
    AND `JOIN` targets (explicit). Explicit `JOIN .. ON <pred>` conditions are
    ANDed into `where_pred` at parse time, so the binder builds a CROSS join of
    all `from_tables` + a FILTER of the full predicate; the optimizer's
    `eliminate_cross_join` folds the equi-conjuncts into real inner joins.

    `ctes` holds any `WITH name AS (<select>)[, ...]` definitions that precede
    the SELECT. Each CTE body is a full `SelectStmt`; the binder builds a
    per-query CTE scope and INLINES a CTE's bound subplan wherever a FROM
    relation references its name (a named derived relation, not a materialized
    node). Only the TOP-LEVEL statement carries `ctes` — a CTE body's own
    `ctes` is always empty in v1 (no nested WITH).

    `subqueries` is the flat side-table of every parenthesized subquery body
    parsed anywhere in the query tree — scalar `(SELECT ...)` operands AND
    the predicate subqueries (`[NOT] EXISTS`, `x [NOT] IN`) AND the derived
    tables (`FROM (SELECT ...) alias`). Each entry is a `SubqueryDef` carrying the
    body PLUS its `kind` (SUBQ_*) and any extra metadata (the IN LHS column /
    the derived alias). An `SX_SUBQUERY` `SqlExpr` node stores only its INDEX into
    this table (in `int_val`), NOT the body — this keeps `SqlExpr`'s type graph
    free of a `SqlExpr -> SelectStmt -> SqlExpr` owning cycle (that cycle
    deadlocks the Mojo AOT compiler's whole-program destructor synthesis). Only
    the TOP-LEVEL statement's `subqueries` is populated (the parser accumulates
    all subquery bodies flat, inner-before-outer, and attaches them here); the
    binder threads this table down. `Slab[SubqueryDef]` is byte-backed, so the
    `SelectStmt -> Slab[SubqueryDef] -> SubqueryDef -> SelectStmt` self-cycle is
    broken exactly as `Slab[CteDef]` breaks the `ctes` cycle.

    `distinct` marks `SELECT DISTINCT ...` — the binder wraps the SELECT
    output in a `PLAN_DISTINCT` node (before ORDER BY / LIMIT).

    `joins` is the per-relation join descriptor, one entry PARALLEL to each
    `from_tables[i]` for i >= 1 (so `len(joins) == len(from_tables) - 1`, and
    `joins[i-1]` describes how `from_tables[i]` attaches to the accumulated left).
    A JK_CROSS entry (comma / CROSS / INNER) carries no ON (it was folded into
    `where_pred`); a JK_LEFT/RIGHT/FULL entry carries the ON predicate that stays
    on the OUTER-join node so unmatched rows null-extend."""

    var select_items: Slab[SelectItem]
    var from_tables: List[FromRelation]
    var joins: Slab[JoinClause]
    var where_pred: Optional[SqlExpr]
    var group_by: Slab[SqlExpr]
    var having_pred: Optional[SqlExpr]
    var order_by: Slab[OrderKey]
    var limit: Optional[Int]
    # `OFFSET m` — the row-window START. `None` = the clause was absent, which
    # is NOT the same as `Some(0)`: the binder refuses a positive offset that
    # carries no LIMIT rather than dropping it, and only a distinguishable
    # "absent" lets it tell those apart. Bound onto the SAME `PLAN_LIMIT` node
    # as `limit` (`LimitData.offset`, the engine's RANGE primitive), never a
    # node of its own.
    var offset: Optional[Int]
    var ctes: Slab[CteDef]
    var subqueries: Slab[SubqueryDef]
    var distinct: Bool  # SELECT DISTINCT
    # ★ UNION ALL: index into the TOP-LEVEL statement's `subqueries`
    # side-table of this SELECT's `UNION ALL` right-hand branch, or -1.
    #
    # ⚠ THE INDEX IS INTO THE **TOP-LEVEL** TABLE, NOT THIS STATEMENT'S OWN.
    # `_finalize` moves every parsed subquery onto the top-level `SelectStmt`,
    # so a branch's own `subqueries` is EMPTY and its `union_all_idx` still
    # indexes the root's table. A chain (`A UNION ALL B UNION ALL C`) is
    # therefore walked ITERATIVELY from the root's table rather than
    # recursively through each branch — see `_union_all_branch_chain`.
    var union_all_idx: Int

    def __init__(out self):
        self.select_items = Slab[SelectItem]()
        self.from_tables = List[FromRelation]()
        self.joins = Slab[JoinClause]()
        self.where_pred = None
        self.group_by = Slab[SqlExpr]()
        self.having_pred = None
        self.order_by = Slab[OrderKey]()
        self.limit = None
        self.offset = None
        self.ctes = Slab[CteDef]()
        self.subqueries = Slab[SubqueryDef]()
        self.distinct = False
        self.union_all_idx = -1


struct CteDef(Movable):
    """One `WITH name AS (<select>)` common-table-expression definition: a name
    plus its parsed body `SelectStmt`. Move-only; stored in `SelectStmt.ctes`.

    The `Slab[CteDef]` storage on `SelectStmt` is byte-backed (its inner
    `List[UInt8]` carries no direct `CteDef` FIELD), which breaks the
    `SelectStmt -> Slab[CteDef] -> CteDef -> SelectStmt` recursion cycle — the
    same mechanism `SqlCallData`'s `Slab[SqlExpr]` uses for the expression
    recursion. So `CteDef` may hold its `SelectStmt` body BY VALUE (mirroring
    how `SqlBinaryData` is declared textually before `SqlExpr` yet references
    it — forward references across the module are resolved in a second pass)."""

    var name: String  # the CTE name as written (binder resolves case-insensitively)
    var body: SelectStmt

    def __init__(out self, name: String, var body: SelectStmt):
        self.name = name
        self.body = body^


struct SubqueryDef(Movable):
    """One parked subquery body (scalar + predicate/derived) in the
    top-level `SelectStmt.subqueries` side-table. Move-only.

    `kind` (SUBQ_*) tells `_bind_query`'s pre-bind loop HOW to lower the body:
      - SUBQ_SCALAR      -> an `EXPR_CORRELATED_SUBQUERY` of kind CORR_KIND_SCALAR
                            (uncorrelated, empty outer refs) -> broadcast cross-join.
      - SUBQ_EXISTS       / SUBQ_NOT_EXISTS -> a correlated subquery Expr of kind
                            CORR_KIND_EXISTS / CORR_KIND_NOT_EXISTS (SEMI / ANTI).
      - SUBQ_IN / SUBQ_NOT_IN -> the same EXISTS / NOT_EXISTS Expr with a
                            SYNTHESIZED `inner_projected_col = in_lhs_col` equi
                            conjunct folded into the inner WHERE (so `x IN (subq)`
                            == `EXISTS (subq WHERE proj = x)`). ⛔ `x NOT IN`
                            is NOT just `NOT EXISTS (...)`: it is NULL-aware and
                            `sql_bind_subquery._bind_null_aware_not_in` ANDs two more
                            facts onto that ANTI join. `in_lhs_col` carries the
                            outer LHS column base name and `in_lhs_qualifier`
                            its table qualifier ("" when unqualified).
      - SUBQ_DERIVED     -> the body is bound to a subplan and registered in the
                            per-query CTE scope under `alias` (a named derived
                            relation); no `prebound` Expr is referenced for it.

    The `Slab[SubqueryDef]` storage on `SelectStmt` is byte-backed (its inner
    `List[UInt8]` carries no direct `SubqueryDef` FIELD), which breaks the
    `SelectStmt -> Slab[SubqueryDef] -> SubqueryDef -> SelectStmt` recursion cycle
    — the same mechanism `Slab[CteDef]` uses. So `SubqueryDef` may hold its
    `SelectStmt` body BY VALUE."""

    var body: SelectStmt
    var kind: UInt8  # SUBQ_* code
    var in_lhs_col: String  # SUBQ_IN / SUBQ_NOT_IN: the outer LHS column base name
    var in_lhs_qualifier: String  # SUBQ_IN / SUBQ_NOT_IN: the LHS's `q` in `q.x` ("" if unqualified)
    var derived_alias: String  # SUBQ_DERIVED: its relation key `<alias>#<subquery index>`
    # SUBQ_DERIVED: the optional column-list rename `(SELECT ...) d (c1, c2, ...)`.
    # Empty means no rename (the derived body's own output column names are kept);
    # when non-empty its length MUST equal the body's output column count and the
    # binder positionally renames the derived relation's output columns to these.
    var col_names: List[String]

    def __init__(out self, var body: SelectStmt, kind: UInt8, in_lhs_col: String = String(""), derived_alias: String = String(""), in_lhs_qualifier: String = String("")):
        self.body = body^
        self.kind = kind
        self.in_lhs_col = in_lhs_col
        self.in_lhs_qualifier = in_lhs_qualifier
        self.derived_alias = derived_alias
        self.col_names = List[String]()

    def __init__(out self, var body: SelectStmt, kind: UInt8, in_lhs_col: String, derived_alias: String, var col_names: List[String]):
        self.body = body^
        self.kind = kind
        self.in_lhs_col = in_lhs_col
        self.in_lhs_qualifier = String("")
        self.derived_alias = derived_alias
        self.col_names = col_names^


struct JoinClause(Movable):
    """One FROM join descriptor, parallel to `SelectStmt.from_tables[i]` for
    i >= 1. `kind` is a JK_* code. For JK_CROSS the ON predicate was already ANDed
    into `where_pred` at parse time (`on_pred` is None); for JK_LEFT/RIGHT/FULL the
    ON predicate is kept HERE (never folded to WHERE — folding an outer-join ON
    into WHERE collapses null-extension into inner-join semantics) so the binder
    decomposes it into the OUTER-join node's equi-keys + residual. JK_SEMI /
    JK_ANTI keep their ON here too, for the same reason one step further: folded
    into WHERE it would become an INNER join's predicate.

    Move-only (holds `Optional[SqlExpr]`); stored in the byte-backed
    `Slab[JoinClause]` on `SelectStmt` (the same move-only-container pattern as
    `select_items` / `group_by` / `order_by`)."""

    var kind: UInt8  # JK_* code
    var on_pred: Optional[SqlExpr]  # ON condition for JK_LEFT/RIGHT/FULL/SEMI/ANTI; None for JK_CROSS
    # --- NATURAL / USING (2026-09-20) -------------------------------------
    # `natural` -- the join columns are EVERY name the two relations share,
    # resolved by the binder from the two schemas (the parser cannot know them).
    # `using_cols` -- the explicit `USING (c, ...)` list, verbatim.
    #
    # ⛔ THESE ARE NOT ON-SUGAR AND MUST NOT BE FOLDED INTO `where_pred`. Both
    # spellings COALESCE the shared key: the output carries ONE `k`, where an
    # equivalent `ON l.k = r.k` carries `k` AND `k_right`. That is a PROJECTION
    # decision, so the clause records the INTENT and the binder derives both the
    # equi-keys and the coalescing projection from the schemas. A `natural` /
    # non-empty `using_cols` clause therefore has `on_pred = None` AT EVERY KIND
    # -- including JK_LEFT, where an ON is otherwise mandatory.
    var natural: Bool
    var using_cols: List[String]

    def __init__(out self, kind: UInt8, var on_pred: Optional[SqlExpr]):
        self.kind = kind
        self.on_pred = on_pred^
        self.natural = False
        self.using_cols = List[String]()

    def __init__(
        out self,
        kind: UInt8,
        var on_pred: Optional[SqlExpr],
        natural: Bool,
        var using_cols: List[String],
    ):
        self.kind = kind
        self.on_pred = on_pred^
        self.natural = natural
        self.using_cols = using_cols^

    def is_keyed(self) -> Bool:
        """True for a NATURAL or USING join -- one that carries KEY NAMES rather
        than a predicate, and whose shared columns the binder must coalesce."""
        return self.natural or len(self.using_cols) > 0


struct SqlStatement(Movable):
    """The parsed top-level statement. The parser's `parse()`
    dispatches on the first keyword into one of the `STMT_*` kinds, but every
    kind is a THIN wrapper over a source/query `SelectStmt` (`query`) plus optional
    write metadata — so the entire SELECT grammar (joins / GROUP BY / CTEs /
    subqueries / window / …) is reused verbatim as the source of a COPY or CTAS.

    Fields:
        kind          — STMT_QUERY / STMT_COPY / STMT_CREATE_TABLE_AS.
        query         — the source/query `SelectStmt` (ALWAYS populated). For
                        STMT_QUERY it is the query itself; for STMT_COPY it is the
                        source (a `(SELECT …)` subquery, or a synthesized
                        `SELECT * FROM <table>` for a bare-table COPY); for
                        STMT_CREATE_TABLE_AS it is the `AS <select>` body. The
                        parser attaches the flat subquery side-table to
                        `query.subqueries`, so `_bind_query(query, …)` threads
                        it as it does for a top-level SELECT.
        dest_path     — STMT_COPY: the `TO '<path>'` file path ("" otherwise).
        target_table  — STMT_CREATE_TABLE_AS: the table name to register ("" otherwise).
        fmt           — WFMT_* write format (STMT_COPY: parquet / csv / json).
        codec         — WCOMP_* write compression (STMT_COPY). The (fmt, codec)
                        pair is validated at parse time against
                        `write_target_supported`.
        replace       — STMT_CREATE_TABLE_AS: True for `CREATE OR REPLACE TABLE`.

    Move-only (holds a move-only `SelectStmt`)."""

    var kind: UInt8
    var query: SelectStmt
    var dest_path: String
    var target_table: String
    var fmt: UInt8
    var codec: UInt8
    var replace: Bool

    def __init__(
        out self,
        kind: UInt8,
        var query: SelectStmt,
        dest_path: String = String(""),
        target_table: String = String(""),
        fmt: UInt8 = WFMT_PARQUET,
        codec: UInt8 = WCOMP_SNAPPY,
        replace: Bool = False,
    ):
        self.kind = kind
        self.query = query^
        self.dest_path = dest_path
        self.target_table = target_table
        self.fmt = fmt
        self.codec = codec
        self.replace = replace
