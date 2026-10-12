# =============================================================================
# komira_sql/sql_bind_window_order.mojo
#   Window functions and ORDER BY.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_expr.null_order_policy import derived_nulls_first
from komira_plan_expr.partition_expr import (
    PF_AVG, PF_COUNT, PF_CUME_DIST, PF_DENSE_RANK, PF_FIRST_VALUE, PF_LAG,
    PF_LAST_VALUE, PF_LEAD, PF_MAX, PF_MIN, PF_NTH_VALUE, PF_NTILE, PF_PERCENT_RANK,
    PF_RANK, PF_ROW_NUMBER, PF_SUM, PartitionExpr, PartitionFrame,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    ExprArray, LogicalPlan,
)
from komira_sql.sql_ast import (
    SXWIN_AVG, SXWIN_COUNT, SXWIN_CUME_DIST, SXWIN_DENSE_RANK, SXWIN_FIRST_VALUE,
    SXWIN_LAG, SXWIN_LAST_VALUE, SXWIN_LEAD, SXWIN_MAX, SXWIN_MIN, SXWIN_NTH_VALUE,
    SXWIN_NTILE, SXWIN_PERCENT_RANK, SXWIN_RANK, SXWIN_ROW_NUMBER, SXWIN_SUM, SX_BOOL,
    SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT, SX_NULL, SX_STRING, SX_TIMESTAMP, SX_WINDOW,
    SelectStmt, SqlExpr, SqlWindowData,
)
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_names import _duckdb_expr_text
from komira_sql.sql_bind_ops import _sx_is_big_int
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, _schema_has_col, BindScope,
)
from komira_sql.sql_catalog import SqlCatalog


# =============================================================================
# Window functions: `f(...) OVER (PARTITION BY ... ORDER BY ... [frame])`
# =============================================================================
# A window function is lowered to a `LogicalPlan.partition_by`
# (PLAN_PARTITION_BY) node: the ranking functions {ROW_NUMBER, RANK,
# DENSE_RANK}, the distribution functions {PERCENT_RANK, CUME_DIST, NTILE},
# the aggregates {SUM, COUNT, AVG, MIN, MAX} over a running or bounded ROWS /
# RANGE frame, and the value functions {LAG, LEAD, FIRST_VALUE, LAST_VALUE,
# NTH_VALUE}. Each top-level SX_WINDOW SELECT item becomes one PartitionBy
# node appending its output column (row count is preserved); the final
# Project selects the pass-through columns and the window output columns.


def _map_win_func(func: UInt8) raises -> UInt8:
    """Map a SXWIN_* window-function code to its `PartitionExpr` PF_* code."""
    if func == SXWIN_ROW_NUMBER:
        return PF_ROW_NUMBER
    if func == SXWIN_RANK:
        return PF_RANK
    if func == SXWIN_DENSE_RANK:
        return PF_DENSE_RANK
    if func == SXWIN_SUM:
        return PF_SUM
    if func == SXWIN_COUNT:
        return PF_COUNT
    if func == SXWIN_MIN:
        return PF_MIN
    if func == SXWIN_MAX:
        return PF_MAX
    if func == SXWIN_AVG:
        return PF_AVG
    if func == SXWIN_LAG:
        return PF_LAG
    if func == SXWIN_LEAD:
        return PF_LEAD
    if func == SXWIN_FIRST_VALUE:
        return PF_FIRST_VALUE
    if func == SXWIN_LAST_VALUE:
        return PF_LAST_VALUE
    if func == SXWIN_NTH_VALUE:
        return PF_NTH_VALUE
    if func == SXWIN_PERCENT_RANK:
        return PF_PERCENT_RANK
    if func == SXWIN_CUME_DIST:
        return PF_CUME_DIST
    if func == SXWIN_NTILE:
        return PF_NTILE
    raise Error("SQL bind error: unsupported window function code " + String(Int(func)))


def _win_value_default(w: SqlWindowData) raises -> ScalarValue:
    """The LAG / LEAD DEFAULT literal as the `ScalarValue` the window carries.
    The window evaluation reads it by its own kind and refuses a pair it
    cannot answer faithfully (e.g. a FLOAT default over an INT64 column, where
    DuckDB v1.5.3 casts)."""
    if w.default_kind == SX_INT:
        return ScalarValue.from_int(Int(w.default_int))
    if w.default_kind == SX_FLOAT:
        return ScalarValue.from_float(w.default_float)
    if w.default_kind == SX_STRING:
        return ScalarValue.from_string(w.default_text)
    if w.default_kind == SX_DATE:
        return ScalarValue.date32(_date_to_days(w.default_text))
    raise Error(
        "SQL bind error: unsupported DEFAULT literal kind " + String(Int(w.default_kind))
    )


def _win_col_name(name: String, qual: String, scope: BindScope) raises -> String:
    """A window's argument / PARTITION BY / ORDER BY column, resolved the way an
    ordinary column reference is (`_resolve_col`): a QUALIFIED name through the
    scope (`Q.k` over `P JOIN Q` -> the right side's `k_right`), a bare one as
    written.

    So over `P(k=1,4,5,2) LEFT JOIN Q(k=2)`, `count(*) OVER (PARTITION BY
    Q.k)` partitions on Q's `k` (DuckDB v1.5.3: 3,3,3,1), not P's. The
    statement-level `ORDER BY M.k` resolves the same way (`_order_key_name`)."""
    if qual != "":
        return scope.resolve_qualified(qual, name)
    return String(name)


def _apply_window(sx: SqlExpr, schema: Schema, scope: BindScope, out_name: String, var child: LogicalPlan) raises -> LogicalPlan:
    """Lower ONE SX_WINDOW node to a `LogicalPlan.partition_by` node over `child`,
    naming the appended window column `out_name`. Validates the partition / order /
    argument columns against `schema` (the pre-window binding schema — a row-
    preserving window sees the input columns). The frame (if written) maps 1:1 to
    the IR `PartitionFrame` (the SXFRAME_* tags equal the FRAME_* tags); when it is
    NOT written the default is CONDITIONAL ON `ORDER BY` — whole partition without
    one, the RANGE running aggregate with one (see the `frame` block below) — and a
    ranking function ignores the frame either way, per SQL semantics."""
    ref w = sx._window.value()
    var pf = _map_win_func(w.func)
    # ⚠ THE DISTRIBUTION WINDOWS ARE RANKING-SHAPED — no argument column, and
    # the frame is ignored (a window's position in the ORDER is what they
    # read) — but their codes sit AFTER the value windows, so the range test
    # alone would file them as an aggregate window that needs an argument.
    var is_dist = (
        w.func == SXWIN_PERCENT_RANK or w.func == SXWIN_CUME_DIST
        or w.func == SXWIN_NTILE
    )
    var is_ranking = w.func <= SXWIN_DENSE_RANK or is_dist
    var is_value = w.func >= SXWIN_LAG and w.func <= SXWIN_NTH_VALUE

    # Aggregate window: validate the argument column. COUNT(*) OVER has no argument
    # column; every other aggregate window requires one.
    var col = _win_col_name(w.arg_col, w.arg_qual, scope) if w.arg_col != "" else String("")
    if not is_ranking:
        if col == "":
            if w.func != SXWIN_COUNT:
                raise Error(
                    "SQL bind error: window aggregate requires an argument column"
                    + " (only COUNT(*) OVER may omit it)"
                )
        elif not _schema_has_col(schema, col):
            if is_value:
                raise Error("SQL bind error: unknown window function column '" + col + "'")
            raise Error("SQL bind error: unknown window aggregate column '" + col + "'")

    var pkeys = List[String]()
    for k in range(len(w.partition_by)):
        var pk = _win_col_name(w.partition_by[k], w.partition_qual[k], scope)
        if not _schema_has_col(schema, pk):
            raise Error("SQL bind error: unknown PARTITION BY column '" + w.partition_by[k] + "'")
        pkeys.append(pk^)

    var okeys = List[String]()
    var desc = List[Bool]()
    for j in range(len(w.order_by)):
        var ok = _win_col_name(w.order_by[j], w.order_qual[j], scope)
        if not _schema_has_col(schema, ok):
            raise Error("SQL bind error: unknown ORDER BY column '" + w.order_by[j] + "' in OVER clause")
        okeys.append(ok^)
        desc.append(w.descending[j])

    var frame: PartitionFrame
    if w.has_frame:
        frame = PartitionFrame(
            w.frame_units, w.frame_start_tag, w.frame_start_offset, w.frame_end_tag, w.frame_end_offset
        )
    elif len(okeys) == 0:
        # The default frame is conditional on ORDER BY. SQL:2003 7.11: with no
        # ORDER BY the rows of a partition have no defined order, so the frame
        # is the whole partition (`ROWS BETWEEN UNBOUNDED PRECEDING AND
        # UNBOUNDED FOLLOWING`): `SUM(v) OVER (PARTITION BY g)` gives every row
        # its partition's total. DuckDB v1.5.3 agrees.
        frame = PartitionFrame.default_unordered()
    else:
        # An ORDER BY is present and no frame was written: the SQL default is
        # RANGE, not ROWS (SQL:2003 7.11: `RANGE BETWEEN UNBOUNDED PRECEDING
        # AND CURRENT ROW`, where CURRENT ROW under RANGE is the last row of
        # the current peer group, so rows tying on the order key get the same
        # value). DuckDB v1.5.3 agrees. RANGE and ROWS differ only where the
        # order key has ties.
        frame = PartitionFrame.running_range()

    # Value windows: LAG / LEAD carry their signed offset and an optional
    # non-NULL DEFAULT and ignore the frame (SQL); FIRST_VALUE / LAST_VALUE /
    # NTH_VALUE read the frame chosen above, and NTH_VALUE carries n in
    # `offset`.
    var offset = 0
    var dv = ScalarValue()
    var has_default = False
    if is_value:
        offset = Int(w.value_offset)
        if w.has_default:
            dv = _win_value_default(w)
            has_default = True
    elif w.func == SXWIN_NTILE:
        # NTILE's bucket count rides `offset`, as `PartitionExpr.ntile` builds it.
        offset = Int(w.value_offset)
    var pexpr = PartitionExpr(pf, col^, offset, dv^, has_default, frame^, String(out_name))
    var pexprs = List[PartitionExpr]()
    pexprs.append(pexpr^)
    return LogicalPlan.partition_by(pkeys^, okeys^, desc^, pexprs^, child^)


def _has_window(stmt: SelectStmt) -> Bool:
    """True iff any top-level SELECT item is a window function."""
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if not it.is_star and it.expr.tag == SX_WINDOW:
            return True
    return False


def _bind_window_projection(stmt: SelectStmt, schema: Schema, scope: BindScope, var child: LogicalPlan, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> LogicalPlan:
    """Bind a SELECT whose list contains window function(s). Each SX_WINDOW
    item builds a `PARTITION BY` node (chained onto `child`) whose output
    column is named by the item's alias (or a synthesized `_w<n>`); the item
    projects a col_ref to that output. Non-window items bind as ordinary
    scalars over the input schema (they pass through the row-preserving
    window nodes). The final Project emits the SELECT columns in order. The
    caller refuses window functions beside GROUP BY / aggregation."""
    var plan = child^
    var proj = ExprArray()
    var win_counter = 0
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            raise Error("SQL not supported: SELECT * alongside a window function")
        if item.expr.tag == SX_WINDOW:
            var out_name: String
            if item.out_alias:
                out_name = String(item.out_alias.value())
            else:
                out_name = String("_w") + String(win_counter)
            win_counter += 1
            # A window named like an input column: the PARTITION BY node
            # appends its column, so `max(v) OVER (PARTITION BY g) AS v` over
            # [k, g, v] would make [k, g, v, v] and the col_ref below would
            # resolve to the input `v`. Such a window is computed under an
            # internal name and aliased back.
            if _schema_has_col(schema, out_name):
                var internal = String("_w_shadow_") + String(i) + String("_") + out_name
                plan = _apply_window(item.expr, schema, scope, internal, plan^)
                proj.append(Expr.alias(Expr.col_ref(internal), out_name))
                continue
            plan = _apply_window(item.expr, schema, scope, out_name, plan^)
            proj.append(Expr.col_ref(out_name))
        else:
            var e = _bind_scalar(item.expr, schema, scope, catalog, cte_scope, prebound)
            if item.out_alias:
                e = Expr.alias(e^, item.out_alias.value())
            proj.append(e^)
    return LogicalPlan.project(proj^, plan^)


def _order_key_name(sx: SqlExpr, scope: BindScope) -> String:
    """The plan column an ORDER BY column key names.

    A qualified key resolves through the scope: `ORDER BY M.k` over
    `K LEFT JOIN M ON K.k = M.k` sorts by M's `k` (`k_right`), not K's, as
    DuckDB v1.5.3 does. A qualifier the scope does not know (an
    aggregate-output alias spelled with a table prefix, say) keeps the
    bare-name reading."""
    if sx.qualifier != "":
        try:
            return scope.resolve_qualified(sx.qualifier, sx.text)
        except:
            pass
    return String(sx.text)


# =============================================================================
# ORDER BY an ordinal / an expression
# =============================================================================
#
# DuckDB v1.5.3:
#
#   ORDER BY 2, 1            the 2nd then the 1st SELECT output column
#   ORDER BY 0 / 2 / -1      `Binder Error: ORDER term out of range - should be
#                             between 1 and N` (N = the SELECT list's width)
#   ORDER BY 1.5 / 'x'       `Binder Error: ORDER BY non-integer literal has no
#                             effect.`
#   ORDER BY -k, abs(a - 3)  an expression over the INPUT; an identifier in it
#                             is the input column even where an alias shares
#                             the name (`SELECT a AS k, k AS a ... ORDER BY -k`
#                             orders by input `k`), and a name only the SELECT
#                             list has (`ORDER BY b * 2`) is the alias
#   ORDER BY count(*) DESC   over GROUP BY: an aggregate, selected or not
#
# ⭐ AN EXPRESSION A SELECT ITEM ALREADY PRODUCES IS THAT ITEM — the same
# canonical text (`_duckdb_expr_text`), DuckDB's own matching — so it sorts by
# the item's output column and needs no hidden column. That is what serves
# `SELECT g, count(*) ... ORDER BY count(*) DESC` under DISTINCT / windows too.
#
# ⛔ NARROWINGS, EACH REFUSED BY NAME (DuckDB answers them):
#   * an ORDER BY expression no SELECT item produces, under SELECT DISTINCT or
#     beside a window function — a hidden column would widen the DISTINCT key /
#     the window path has no carry;
#   * an ORDER BY expression naming a SELECT ALIAS that is not an input column
#     (`ORDER BY b * 2`) — the alias would have to be substituted by its item.

comptime _OK_COLUMN: Int = 0  # a bare column key — `_order_key_name`
comptime _OK_OUTPUT: Int = 1  # an ordinal / a SELECT-matched expression — an OUTPUT column index
comptime _OK_CARRIED: Int = 2  # an expression carried as `__order_key_<i>`


def _classify_order_keys(
    stmt: SelectStmt,
    schema: Schema,
    has_window: Bool,
    mut order_kind: List[Int],
    mut order_out_idx: List[Int],
    mut order_expr_idx: List[Int],
    mut order_expr_names: List[String],
) raises:
    """One `_OK_*` per ORDER BY key (see the block above), plus the carried
    keys' indices and hidden names for the projection / aggregate binders."""
    for i in range(len(stmt.order_by)):
        ref kx = stmt.order_by[i].expr
        if kx.tag == SX_COLUMN:
            order_kind.append(_OK_COLUMN)
            order_out_idx.append(-1)
            continue
        if kx.tag == SX_INT:
            if _sx_is_big_int(kx):
                # `ORDER BY 18446744073709551617` would order by ordinal 1 (the
                # wrapped bits); DuckDB 1.5.3 raises.
                raise Error(
                    "SQL bind error: the ORDER BY ordinal " + kx.text
                    + " is out of range for BIGINT (DuckDB v1.5.3 raises a"
                    " Conversion Error: the value is out of range for the"
                    " destination type INT64)"
                )
            # An ORDINAL. Its range is checked against the SELECT output's
            # width once that is known (`_order_output_column`).
            order_kind.append(_OK_OUTPUT)
            order_out_idx.append(Int(kx.int_val) - 1)
            continue
        if (
            kx.tag == SX_FLOAT or kx.tag == SX_STRING or kx.tag == SX_BOOL
            or kx.tag == SX_DATE or kx.tag == SX_TIMESTAMP or kx.tag == SX_NULL
        ):
            raise Error(
                "SQL bind error: ORDER BY non-integer literal has no effect."
                " (DuckDB v1.5.3 refuses it with this sentence: only an INTEGER"
                " literal is an ordinal, and a constant key orders nothing.)"
            )
        var mj = _order_expr_select_match(stmt, kx)
        if mj >= 0:
            order_kind.append(_OK_OUTPUT)
            order_out_idx.append(mj)
            continue
        if stmt.distinct or has_window:
            raise Error(
                "SQL not supported: ORDER BY an expression that no SELECT item"
                " produces, under "
                + (String("SELECT DISTINCT") if stmt.distinct else String("a window function"))
                + ". The key would be a hidden column, which "
                + (
                    String("would widen the DISTINCT key and change the row count")
                    if stmt.distinct
                    else String("the window projection has no carry for")
                )
                + ". Select the expression (and ORDER BY its position or"
                " alias), or order by a column."
            )
        var alias_only = _order_expr_alias_ref(kx, stmt, schema)
        if alias_only.byte_length() > 0:
            raise Error(
                "SQL not supported: the ORDER BY expression names the SELECT"
                " alias `" + alias_only + "`, which is not an input column."
                " DuckDB substitutes the aliased expression; this binder does"
                " not yet. Repeat the aliased expression in ORDER BY, or order"
                " by the alias alone (`ORDER BY " + alias_only + "`)."
            )
        order_kind.append(_OK_CARRIED)
        order_out_idx.append(-1)
        order_expr_idx.append(i)
        order_expr_names.append(String("__order_key_") + String(i))


def _order_expr_select_match(stmt: SelectStmt, kx: SqlExpr) raises -> Int:
    """The index of the first SELECT item whose expression IS `kx` (same
    canonical text), or -1. A star and a window item never match."""
    var canon = _duckdb_expr_text(kx)
    for j in range(len(stmt.select_items)):
        ref it = stmt.select_items[j]
        if it.is_star or it.expr.tag == SX_WINDOW:
            continue
        if _duckdb_expr_text(it.expr) == canon:
            return j
    return -1


def _order_expr_alias_ref(sx: SqlExpr, stmt: SelectStmt, schema: Schema) -> String:
    """The first unqualified column name inside `sx` that is NOT an input
    column but IS a SELECT alias, or "" — see the block above."""
    if sx.tag == SX_COLUMN:
        if sx.qualifier == "" and not _schema_has_col(schema, sx.text):
            for j in range(len(stmt.select_items)):
                ref it = stmt.select_items[j]
                if it.out_alias and it.out_alias.value() == sx.text:
                    return String(sx.text)
        return String("")
    if sx._binary:
        var l = _order_expr_alias_ref(sx._binary.value().left[], stmt, schema)
        if l.byte_length() > 0:
            return l^
        return _order_expr_alias_ref(sx._binary.value().right[], stmt, schema)
    if sx._agg:
        return _order_expr_alias_ref(sx._agg.value().arg[], stmt, schema)
    if sx._call:
        ref cargs = sx._call.value().args
        for i in range(len(cargs)):
            var a = _order_expr_alias_ref(cargs[i], stmt, schema)
            if a.byte_length() > 0:
                return a^
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            var c = _order_expr_alias_ref(cd.conds[i], stmt, schema)
            if c.byte_length() > 0:
                return c^
            var r = _order_expr_alias_ref(cd.results[i], stmt, schema)
            if r.byte_length() > 0:
                return r^
        for i in range(len(cd.otherwise)):
            var o = _order_expr_alias_ref(cd.otherwise[i], stmt, schema)
            if o.byte_length() > 0:
                return o^
    return String("")


def _order_output_column(result_schema: Schema, idx: Int, n_result: Int) raises -> String:
    """The SELECT output column an ordinal / a matched expression names.

    ⛔ TWO OUTPUT COLUMNS OF ONE NAME ARE REFUSED, NOT GUESSED BETWEEN: the sort
    resolves its key BY NAME, so `SELECT K.k AS k, M.k AS k ... ORDER BY 2`
    would sort by the FIRST `k` — a silent wrong order."""
    if idx < 0 or idx >= n_result:
        raise Error(
            "SQL bind error: ORDER term out of range - should be between 1 and "
            + String(n_result)
        )
    var nm = String(result_schema.field_name(idx))
    for c in range(n_result):
        if c != idx and result_schema.field_name(c) == nm:
            raise Error(
                "SQL not supported: ORDER BY " + String(idx + 1) + " names the"
                " output column `" + nm + "`, and another SELECT item has the"
                " same name. The sort resolves its key by NAME, so it could"
                " order by the wrong one. Give the items distinct aliases."
            )
    return nm^


def _bind_order(stmt: SelectStmt, var child: LogicalPlan, scope: BindScope, sort_names: List[String]) raises -> LogicalPlan:
    var keys = List[String]()
    var desc = List[Bool]()
    # `NULLS FIRST | LAST`. The placement list is built only if some key asked,
    # and a key that did not ask gets `null_order_policy.derived_nulls_first`,
    # the default placement for its direction (`SortData.nulls_first` is
    # parallel to the key list). When no key asked, `None` is passed, which
    # leaves the sort on the default placement.
    var any_placement = False
    for i in range(len(stmt.order_by)):
        if stmt.order_by[i].nulls_first:
            any_placement = True
    var nulls_first = List[Bool]()
    for i in range(len(stmt.order_by)):
        ref ok = stmt.order_by[i]
        # `sort_names[i]` is the column the key resolved to: a column key's
        # own name, an ordinal's or a matching expression's SELECT output
        # column, or a carried expression's hidden name (`_classify_order_keys`).
        var key_name = String(sort_names[i])
        if not _schema_has_col(child.output_schema, key_name):
            raise Error("SQL bind error: unknown ORDER BY column '" + ok.expr.text + "'")
        keys.append(key_name^)
        desc.append(ok.descending)
        if any_placement:
            if ok.nulls_first:
                nulls_first.append(ok.nulls_first.value())
            else:
                nulls_first.append(derived_nulls_first(ok.descending))
    if any_placement:
        return LogicalPlan.sort(
            keys^, desc^, child^, Optional(nulls_first^)
        )
    return LogicalPlan.sort(keys^, desc^, child^)

