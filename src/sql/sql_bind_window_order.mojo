# =============================================================================
# sql/sql_bind_window_order.mojo
#   Window functions and ORDER BY.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema, SchemaBuilder
from plan_expr.expr import Expr
from plan_expr.null_order_policy import derived_nulls_first
from plan_expr.partition_expr import (
    PF_AVG, PF_COUNT, PF_CUME_DIST, PF_DENSE_RANK, PF_FIRST_VALUE, PF_LAG,
    PF_LAST_VALUE, PF_LEAD, PF_MAX, PF_MIN, PF_NTH_VALUE, PF_NTILE, PF_PERCENT_RANK,
    PF_RANK, PF_ROW_NUMBER, PF_SUM, PartitionExpr, PartitionFrame,
    FRAME_UNITS_RANGE, FRAME_BOUND_UNBOUNDED_PRECEDING, FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW, FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    ExprArray, LogicalPlan,
)
from sql.sql_ast import (
    SXWIN_AVG, SXWIN_COUNT, SXWIN_CUME_DIST, SXWIN_DENSE_RANK, SXWIN_FIRST_VALUE,
    SXWIN_LAG, SXWIN_LAST_VALUE, SXWIN_LEAD, SXWIN_MAX, SXWIN_MIN, SXWIN_NTH_VALUE,
    SXWIN_NTILE, SXWIN_PERCENT_RANK, SXWIN_RANK, SXWIN_ROW_NUMBER, SXWIN_SUM, SX_AGG,
    SX_BOOL, SX_CALL, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT, SX_NULL, SX_STRING,
    SX_TIMESTAMP, SX_WINDOW, SelectItem, SelectStmt, SqlExpr, SqlWindowData,
    sql_call_is_aggregate,
)
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_names import _duckdb_expr_text, _group_has
from sql.sql_bind_ops import _sx_is_big_int
from sql.sql_bind_scope import (
    CteScope, _date_to_days, _schema_has_col, BindScope,
)
from sql.sql_catalog import SqlCatalog
from sql.sql_window_text import window_hidden_name


# =============================================================================
# Window functions: `f(...) OVER (PARTITION BY ... ORDER BY ... [frame])`
# =============================================================================
# A window function is lowered to a `LogicalPlan.partition_by`
# (PLAN_PARTITION_BY) node: the ranking functions {ROW_NUMBER, RANK,
# DENSE_RANK}, the distribution functions {PERCENT_RANK, CUME_DIST, NTILE},
# the aggregates {SUM, COUNT, AVG, MIN, MAX} over a running or bounded ROWS /
# RANGE frame, and the value functions {LAG, LEAD, FIRST_VALUE, LAST_VALUE,
# NTH_VALUE}. Each window becomes one PartitionBy node appending its output
# column (row count is preserved). A window may stand where DuckDB allows one:
# as a SELECT item, nested in a SELECT item's expression, or in an ORDER BY
# key; a nested one is computed under a hidden name and read by the
# expression (`_bind_window_projection`). The final Project selects the
# SELECT list. A window in WHERE, ON, GROUP BY, HAVING or an aggregate's
# argument is refused with DuckDB's reason (`_refuse_misplaced_windows`).


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


def _check_written_frame(
    frame: PartitionFrame, okeys: List[String], desc: List[Bool], schema: Schema
) raises:
    """Raise DuckDB's error for a written frame DuckDB refuses, whatever the
    function (a ranking function ignores its frame, and DuckDB still checks
    it). Measured on DuckDB v1.5.6:

      `ROWS BETWEEN UNBOUNDED FOLLOWING AND ...`  frame start cannot be
                                                  UNBOUNDED FOLLOWING
      `... AND UNBOUNDED PRECEDING`               frame end cannot be
                                                  UNBOUNDED PRECEDING
      `1 FOLLOWING AND 1 PRECEDING`,              frame starting from following
      `1 FOLLOWING AND CURRENT ROW`               row cannot have preceding rows
      `CURRENT ROW AND 1 PRECEDING`               frame starting from current
                                                  row cannot have preceding rows
      `RANGE 1 PRECEDING` with no ORDER BY, or    Binder Error: RANGE frames
      with two ORDER BY keys                      must have only one ORDER BY
                                                  expression
      `RANGE 1 PRECEDING` over a VARCHAR or       Binder Error: no `-` for
      BOOLEAN key                                 (VARCHAR, INTEGER_LITERAL)

    The shape errors are DuckDB parser errors, hence `SQL syntax error`. The
    shorthand `ROWS 1 FOLLOWING` gets the sentence of the BETWEEN form it
    stands for; DuckDB words that one "cannot end with current row", and the
    parsed window does not record which spelling was written.

    The operator DuckDB names is the one its first bound with an offset
    applies to the key: `n PRECEDING` subtracts and `n FOLLOWING` adds, the
    other way round under DESC."""
    var shape = String("")
    if frame.start_tag == FRAME_BOUND_UNBOUNDED_FOLLOWING:
        shape = "frame start cannot be UNBOUNDED FOLLOWING"
    elif frame.end_tag == FRAME_BOUND_UNBOUNDED_PRECEDING:
        shape = "frame end cannot be UNBOUNDED PRECEDING"
    elif frame.start_tag == FRAME_BOUND_FOLLOWING and (
        frame.end_tag == FRAME_BOUND_PRECEDING or frame.end_tag == FRAME_BOUND_CURRENT_ROW
    ):
        shape = "frame starting from following row cannot have preceding rows"
    elif frame.start_tag == FRAME_BOUND_CURRENT_ROW and frame.end_tag == FRAME_BOUND_PRECEDING:
        shape = "frame starting from current row cannot have preceding rows"
    if shape != "":
        raise Error("SQL syntax error: " + shape)
    if frame.units != FRAME_UNITS_RANGE:
        return
    var has_offset = (
        frame.start_tag == FRAME_BOUND_PRECEDING
        or frame.start_tag == FRAME_BOUND_FOLLOWING
        or frame.end_tag == FRAME_BOUND_PRECEDING
        or frame.end_tag == FRAME_BOUND_FOLLOWING
    )
    if not has_offset:
        return
    if len(okeys) != 1:
        raise Error(
            "SQL bind error: RANGE frames must have only one ORDER BY expression"
        )
    var t = schema.field_arrow_type(schema.column_index(okeys[0]))
    var sql_type = String("")
    if t == ArrowType.STRING:
        sql_type = "VARCHAR"
    elif t == ArrowType.BOOL:
        sql_type = "BOOLEAN"
    if sql_type != "":
        var tag = frame.start_tag
        if tag != FRAME_BOUND_PRECEDING and tag != FRAME_BOUND_FOLLOWING:
            tag = frame.end_tag
        var adds = (tag == FRAME_BOUND_FOLLOWING) != desc[0]
        var op = String("+") if adds else String("-")
        var verb = String("adds the offset to") if adds else String("subtracts the offset from")
        raise Error(
            "SQL bind error: a RANGE frame with an offset " + verb + " the"
            " ORDER BY key, and '" + okeys[0] + "' is " + sql_type
            + ", which has no `" + op + "` (DuckDB: no function matches '" + op
            + "(" + sql_type + ", INTEGER_LITERAL)')"
        )


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
    # THE DISTRIBUTION WINDOWS ARE RANKING-SHAPED — no argument column, and
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
    var nulls_first = List[Bool]()
    var any_placement = False
    for j in range(len(w.order_by)):
        var ok = _win_col_name(w.order_by[j], w.order_qual[j], scope)
        if not _schema_has_col(schema, ok):
            raise Error("SQL bind error: unknown ORDER BY column '" + w.order_by[j] + "' in OVER clause")
        okeys.append(ok^)
        desc.append(w.descending[j])
        # A written NULLS FIRST/LAST pins the placement; an unwritten one is
        # the derived default. The plan is told of a placement only when some
        # key wrote one, so a window without it plans and encodes as before.
        if w.nulls_first[j]:
            any_placement = True
            nulls_first.append(w.nulls_first[j].value())
        else:
            nulls_first.append(derived_nulls_first(w.descending[j]))

    var frame: PartitionFrame
    if w.has_frame:
        frame = PartitionFrame(
            w.frame_units, w.frame_start_tag, w.frame_start_offset, w.frame_end_tag, w.frame_end_offset
        )
        _check_written_frame(frame, okeys, desc, schema)
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
    if any_placement:
        return LogicalPlan.partition_by(
            pkeys^, okeys^, desc^, pexprs^, child^, Optional(nulls_first^)
        )
    return LogicalPlan.partition_by(pkeys^, okeys^, desc^, pexprs^, child^)


def _has_window(stmt: SelectStmt) -> Bool:
    """True iff a window function stands anywhere in the SELECT list or in an
    ORDER BY key: a top-level item, nested in an item's expression, or in an
    ORDER BY expression. Such a SELECT binds through
    `_bind_window_projection`."""
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if not it.is_star and it.expr.contains_window():
            return True
    for i in range(len(stmt.order_by)):
        if stmt.order_by[i].expr.contains_window():
            return True
    return False


def _aggregate_wraps_window(sx: SqlExpr) -> Bool:
    """True iff an aggregate call in `sx` has a window in its argument
    (`sum(rank() OVER (...))`)."""
    if sx.tag == SX_AGG:
        return sx._agg.value().arg[].contains_window()
    if sx.tag == SX_CALL and sql_call_is_aggregate(sx.text):
        return sx.contains_window()
    if sx._binary:
        if _aggregate_wraps_window(sx._binary.value().left[]):
            return True
        if _aggregate_wraps_window(sx._binary.value().right[]):
            return True
    if sx._agg:
        if _aggregate_wraps_window(sx._agg.value().arg[]):
            return True
    if sx._call:
        ref ca = sx._call.value().args
        for i in range(len(ca)):
            if _aggregate_wraps_window(ca[i]):
                return True
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            if _aggregate_wraps_window(cd.conds[i]):
                return True
        for i in range(len(cd.results)):
            if _aggregate_wraps_window(cd.results[i]):
                return True
        for i in range(len(cd.otherwise)):
            if _aggregate_wraps_window(cd.otherwise[i]):
                return True
    return False


def _refuse_misplaced_windows(stmt: SelectStmt) raises:
    """Refuse a window function in a clause that cannot hold one, with
    DuckDB's reason (DuckDB v1.5.5 Binder Errors). A window is computed over
    the rows the WHERE, GROUP BY and HAVING clauses produce, so none of them
    can read one. A join's ON is a WHERE to DuckDB:

      WHERE / JOIN ... ON   WHERE clause cannot contain window functions!
      GROUP BY              GROUP BY clause cannot contain window functions!
      HAVING                HAVING clause cannot contain window functions!
      sum(rank() OVER ())   aggregate function calls cannot contain window
                            function calls
    """
    var in_where = Bool(stmt.where_pred) and stmt.where_pred.value().contains_window()
    for i in range(len(stmt.joins)):
        ref jc = stmt.joins[i]
        if Bool(jc.on_pred) and jc.on_pred.value().contains_window():
            in_where = True
    if in_where:
        raise Error("SQL bind error: WHERE clause cannot contain window functions")
    for i in range(len(stmt.group_by)):
        if stmt.group_by[i].contains_window():
            raise Error("SQL bind error: GROUP BY clause cannot contain window functions")
    if Bool(stmt.having_pred) and stmt.having_pred.value().contains_window():
        raise Error("SQL bind error: HAVING clause cannot contain window functions")
    var wrapped = False
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if not it.is_star and _aggregate_wraps_window(it.expr):
            wrapped = True
    for i in range(len(stmt.order_by)):
        if _aggregate_wraps_window(stmt.order_by[i].expr):
            wrapped = True
    if wrapped:
        raise Error(
            "SQL bind error: aggregate function calls cannot contain window"
            " function calls"
        )


def _collect_windows(sx: SqlExpr, mut names: List[String], mut windows: List[SqlWindowData]):
    """Append each window in `sx` not already listed, with its hidden name
    (`window_hidden_name`), in the order the expression is written."""
    if sx.tag == SX_WINDOW:
        var name = window_hidden_name(sx)
        for i in range(len(names)):
            if names[i] == name:
                return
        names.append(name^)
        windows.append(sx._window.value().copy())
        return
    if sx._binary:
        _collect_windows(sx._binary.value().left[], names, windows)
        _collect_windows(sx._binary.value().right[], names, windows)
    if sx._agg:
        _collect_windows(sx._agg.value().arg[], names, windows)
    if sx._call:
        ref ca = sx._call.value().args
        for i in range(len(ca)):
            _collect_windows(ca[i], names, windows)
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            _collect_windows(cd.conds[i], names, windows)
        for i in range(len(cd.results)):
            _collect_windows(cd.results[i], names, windows)
        for i in range(len(cd.otherwise)):
            _collect_windows(cd.otherwise[i], names, windows)


def _top_window_name(item: SelectItem, win_counter: Int) -> String:
    """The output name of a top-level window item: its alias, or `_w<n>`
    for the n-th top-level window of the SELECT list."""
    if item.out_alias:
        return String(item.out_alias.value())
    return String("_w") + String(win_counter)


def _bind_window_projection(stmt: SelectStmt, schema: Schema, scope: BindScope, var child: LogicalPlan, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr], order_names: List[String], mut order_carry: List[String], order_expr_idx: List[Int], order_expr_names: List[String]) raises -> LogicalPlan:
    """Bind a SELECT that holds window function(s) (`_has_window`).

    Each window builds a `PARTITION BY` node chained onto `child`; a window
    preserves the rows and appends one column. A TOP-LEVEL window item
    names its column by its alias (or `_w<n>`) and projects it. A window
    NESTED in an expression (`v * 100.0 / sum(v) OVER (PARTITION BY g)`,
    `CASE WHEN rank() OVER (...) = 1 ...`, `abs(v - avg(v) OVER ())`, an
    ORDER BY key) is computed under its hidden name (`window_hidden_name`;
    one window written twice is computed once), and the expression binds
    over the input columns plus those hidden ones, where `_bind_scalar`
    reads the window as that column. The final Project names only the
    SELECT list, so the hidden columns go no further.

    `*` expands to the FROM's columns and `q.*` to the relation `q`'s
    (`BindScope.star_out_names`), in place, so `SELECT *, sum(n) OVER (...)
    AS tot` is the table's columns, then `tot`, as in DuckDB. An unaliased
    item holding a nested window is named as DuckDB names it
    (`_duckdb_expr_text`: `((n * 100.0) / sum(n) OVER (PARTITION BY g))`).

    The ORDER BY carry is `_bind_projection`'s: a column key the list does
    not produce, and an expression no item produces (a window in it
    included), are appended as hidden columns the SELECT binder prunes after
    the sort. The caller refuses window functions beside GROUP BY /
    aggregation."""
    var plan = child^
    # Pass 1: every window, in SELECT-list order, then those of the carried
    # ORDER BY expressions.
    var win_counter = 0
    var hidden = List[String]()
    var nested = List[SqlWindowData]()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            continue
        if item.expr.tag == SX_WINDOW:
            var out_name = _top_window_name(item, win_counter)
            win_counter += 1
            # A window named like an input column: the PARTITION BY node
            # appends its column, so `max(v) OVER (PARTITION BY g) AS v` over
            # [k, g, v] would make [k, g, v, v] and a col_ref would resolve to
            # the input `v`. Such a window is computed under an internal name
            # and aliased back in pass 2.
            if _schema_has_col(schema, out_name):
                out_name = String("_w_shadow_") + String(i) + String("_") + out_name
            plan = _apply_window(item.expr, schema, scope, out_name, plan^)
        else:
            _collect_windows(item.expr, hidden, nested)
    for t in range(len(order_expr_idx)):
        _collect_windows(stmt.order_by[order_expr_idx[t]].expr, hidden, nested)
    for w in range(len(nested)):
        plan = _apply_window(
            SqlExpr.window(nested[w].copy()), schema, scope, hidden[w], plan^
        )
    # The schema the expressions bind over: the input columns, then the hidden
    # window columns with the types their PARTITION BY nodes gave them.
    var sb = SchemaBuilder()
    for c in range(schema.num_columns()):
        sb.add_field(schema.field_at_unchecked(c))
    for w in range(len(hidden)):
        sb.add_field(
            plan.output_schema.field_at_unchecked(plan.output_schema.column_index(hidden[w]))
        )
    var bind_schema = sb.build()

    # Pass 2: the projection, in SELECT-list order.
    var proj = ExprArray()
    var out_names = List[String]()
    win_counter = 0
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            var cols = scope.star_out_names(item.expr.qualifier)
            for c in range(len(cols)):
                proj.append(Expr.col_ref(cols[c]))
                out_names.append(cols[c])
            continue
        if item.expr.tag == SX_WINDOW:
            var out_name = _top_window_name(item, win_counter)
            win_counter += 1
            if _schema_has_col(schema, out_name):
                var internal = String("_w_shadow_") + String(i) + String("_") + out_name
                proj.append(Expr.alias(Expr.col_ref(internal), out_name))
            else:
                proj.append(Expr.col_ref(out_name))
            out_names.append(out_name^)
            continue
        var e = _bind_scalar(item.expr, bind_schema, scope, catalog, cte_scope, prebound)
        if item.out_alias:
            e = Expr.alias(e^, item.out_alias.value())
            out_names.append(String(item.out_alias.value()))
        elif item.expr.tag == SX_COLUMN:
            out_names.append(String(item.expr.text))
        elif item.expr.contains_window():
            var nm = _duckdb_expr_text(item.expr)
            e = Expr.alias(e^, nm)
            out_names.append(nm^)
        else:
            out_names.append(_duckdb_expr_text(item.expr))
        proj.append(e^)

    # The ORDER BY carry, as in `_bind_projection`.
    for n in range(len(order_names)):
        ref onm = order_names[n]
        if _group_has(out_names, onm) or _group_has(order_carry, onm):
            continue
        if not _schema_has_col(schema, onm):
            continue
        proj.append(Expr.col_ref(onm))
        out_names.append(String(onm))
        order_carry.append(String(onm))
    for t in range(len(order_expr_idx)):
        var oe = _bind_scalar(
            stmt.order_by[order_expr_idx[t]].expr, bind_schema, scope, catalog,
            cte_scope, prebound,
        )
        proj.append(Expr.alias(oe^, order_expr_names[t]))
        out_names.append(String(order_expr_names[t]))
        order_carry.append(String(order_expr_names[t]))
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
#   ORDER BY sum(v) OVER (PARTITION BY g) DESC
#                            a window (v1.5.5), computed under its hidden name
#                            like a window nested in a SELECT item
#
# AN EXPRESSION A SELECT ITEM ALREADY PRODUCES IS THAT ITEM — the same
# canonical text (`_duckdb_expr_text`), DuckDB's own matching — so it sorts by
# the item's output column and needs no hidden column. That is what serves
# `SELECT g, count(*) ... ORDER BY count(*) DESC` under DISTINCT / windows too.
#
# NARROWINGS, EACH REFUSED BY NAME (DuckDB answers them):
#   * an ORDER BY expression no SELECT item produces, under SELECT DISTINCT —
#     a hidden column would widen the DISTINCT key;
#   * an ORDER BY expression naming a SELECT ALIAS that is not an input column
#     (`ORDER BY b * 2`) — the alias would have to be substituted by its item.

comptime _OK_COLUMN: Int = 0  # a bare column key — `_order_key_name`
comptime _OK_OUTPUT: Int = 1  # an ordinal / a SELECT-matched expression — an OUTPUT column index
comptime _OK_CARRIED: Int = 2  # an expression carried as `__order_key_<i>`


def _classify_order_keys(
    stmt: SelectStmt,
    schema: Schema,
    scope: BindScope,
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
            order_out_idx.append(_item_output_index(stmt, mj, scope))
            continue
        if stmt.distinct:
            raise Error(
                "SQL not supported: ORDER BY an expression that no SELECT item"
                " produces, under SELECT DISTINCT. The key would be a hidden"
                " column, which would widen the DISTINCT key and change the row"
                " count. Select the expression (and ORDER BY its position or"
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


def _item_output_index(stmt: SelectStmt, item: Int, scope: BindScope) raises -> Int:
    """The output column SELECT item `item` lands in: a `*` or `q.*` before it
    stands for every column it expands to, so in `SELECT *, k + 1 AS kp FROM
    t(k, g)` item 1 is output column 2."""
    var out = 0
    for j in range(item):
        ref it = stmt.select_items[j]
        if it.is_star:
            out += len(scope.star_out_names(it.expr.qualifier))
        else:
            out += 1
    return out


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

    TWO OUTPUT COLUMNS OF ONE NAME ARE REFUSED, NOT GUESSED BETWEEN: the sort
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

