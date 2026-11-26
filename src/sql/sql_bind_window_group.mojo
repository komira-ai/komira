# =============================================================================
# sql/sql_bind_window_group.mojo
#   Window functions in a SELECT that aggregates: the windows run over the
#   groups.
# =============================================================================
#
# SQL evaluates FROM, WHERE, GROUP BY and HAVING before the window functions,
# so in
#
#   SELECT g, count(*) AS n, rank() OVER (ORDER BY count(*) DESC, g) AS rk
#   FROM t GROUP BY g
#
# the window sees one row per group, and `count(*)` in its ORDER BY is the
# group's count. DuckDB v1.5.6 answers that query; the binder builds it in two
# stages:
#
#   1. One aggregate (`_bind_aggregate`) over a rebuilt SELECT list:
#        * each SELECT item that is not a window, named by its alias (so a
#          HAVING that names the alias reads it, as without a window) or, with
#          no alias or an alias an earlier item already took, `__sel_<i>` (i
#          its position in the SELECT list);
#        * each column a window names (its argument, a PARTITION BY or an
#          ORDER BY column), once per distinct qualifier and name, named
#          `__wcol_<j>`;
#        * each computed window key (`SelectStmt.window_keys[n]`, such as
#          `count(*)`), named `__window_key_<n>`;
#        * when none of these is there (`SELECT row_number() OVER () ...
#          GROUP BY k`), a `count(*)` named `__group_rows`, so the aggregate
#          still has a column and one row per group;
#      with the statement's GROUP BY and HAVING. So a column a window names
#      must be a group key, as a SELECT item must, with the aggregate binder's
#      message when it is not.
#   2. The window projection (`_bind_window_projection`) over that output:
#      each window with its columns renamed to the hidden names, and each
#      other item a column of the aggregate under its output name (its alias,
#      or the name the aggregate binder would give it).
#
# The GROUP BY is the statement's, with its ordinals and SELECT aliases
# resolved here against the statement's own SELECT list (the rebuilt list has
# other positions and no user aliases): each becomes the ordinal of the
# rebuilt item, so the aggregate binder still treats it as an ordinal. An
# ordinal or alias naming a window item is refused as DuckDB refuses it.
# =============================================================================

from plan_ir.logical_plan import LogicalPlan
from plan_expr.expr import Expr

from sql.sql_ast import (
    SX_COLUMN, SX_INT, SX_WINDOW, SXAGG_COUNT, SelectItem, SelectStmt, SqlExpr,
    SqlWindowData,
)
from sql.sql_bind_aggregate import _bind_aggregate
from sql.sql_bind_names import _duckdb_expr_text, _group_has, _select_alias_index
from sql.sql_bind_ops import _sx_is_big_int
from sql.sql_bind_scope import (
    BindScope, CteScope, _schema_col_spelling, _schema_has_col,
)
from sql.sql_bind_window_order import _bind_window_projection
from sql.sql_catalog import SqlCatalog
from sql.sql_window_keys import _window_key_name

from arrow.schema import Schema


def _sel_names(stmt: SelectStmt) -> List[String]:
    """The aggregate's name for each SELECT item that is not a window ("" for
    a window): its alias, unless an earlier item has the same alias, and
    otherwise `__sel_<i>`. The first item of an alias keeps it because a
    HAVING reads an alias as its first item, as the aggregate binder does
    without a window (`_select_alias_index`)."""
    var out = List[String]()
    var aliases = List[String]()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.expr.tag == SX_WINDOW:
            out.append(String(""))
        elif item.out_alias and not _group_has(aliases, item.out_alias.value()):
            aliases.append(String(item.out_alias.value()))
            out.append(String(item.out_alias.value()))
        else:
            out.append(String("__sel_") + String(i))
    return out^


def _wcol_name(j: Int) -> String:
    """The aggregate's name for the `j`-th distinct column the windows name."""
    return String("__wcol_") + String(j)


struct _WindowColumns(Movable):
    """The distinct (qualifier, name) columns the windows of one SELECT name,
    in first-seen order; slot `j` is the aggregate's column `__wcol_<j>`."""

    var names: List[String]
    var quals: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.quals = List[String]()

    def slot(mut self, name: String, qual: String) -> Int:
        for j in range(len(self.names)):
            if self.names[j] == name and self.quals[j] == qual:
                return j
        self.names.append(name)
        self.quals.append(qual)
        return len(self.names) - 1


def _rename_window(w: SqlWindowData, mut cols: _WindowColumns) -> SqlWindowData:
    """`w` reading the aggregate's hidden columns: its argument and each
    column key `__wcol_<j>`, each computed key `__window_key_<n>`, every
    qualifier "" (the hidden names are unique in the aggregate's output)."""
    var out = w.copy()
    if out.arg_col != "":
        out.arg_col = _wcol_name(cols.slot(w.arg_col, w.arg_qual))
        out.arg_qual = String("")
    for k in range(len(out.partition_by)):
        var n = w.partition_key_expr[k]
        if n >= 0:
            out.partition_by[k] = _window_key_name(n)
        else:
            out.partition_by[k] = _wcol_name(
                cols.slot(w.partition_by[k], w.partition_qual[k])
            )
        out.partition_qual[k] = String("")
    for k in range(len(out.order_by)):
        var n = w.order_key_expr[k]
        if n >= 0:
            out.order_by[k] = _window_key_name(n)
        else:
            out.order_by[k] = _wcol_name(
                cols.slot(w.order_by[k], w.order_qual[k])
            )
        out.order_qual[k] = String("")
    return out^


def _rebuilt_position(stmt: SelectStmt, sel: Int) raises -> Int:
    """The 1-based position, in the rebuilt SELECT list, of SELECT item `sel`
    (a GROUP BY ordinal or alias names it). The rebuilt list starts with the
    items that are not windows, in order; a window item is refused."""
    if stmt.select_items[sel].expr.tag == SX_WINDOW:
        raise Error(
            "SQL bind error: GROUP BY clause cannot contain window functions"
        )
    var pos = 0
    for i in range(sel + 1):
        if stmt.select_items[i].expr.tag != SX_WINDOW:
            pos += 1
    return pos


def _group_key(stmt: SelectStmt, gsx: SqlExpr, schema: Schema) raises -> SqlExpr:
    """GROUP BY item `gsx` for the rebuilt SELECT list: an ordinal or a SELECT
    alias (a name no input column answers, as the aggregate binder reads it)
    becomes the ordinal of the item it names there; anything else is
    unchanged. An ordinal past BIGINT is left for the aggregate binder's own
    refusal."""
    var sel = -1
    if gsx.tag == SX_INT and not _sx_is_big_int(gsx):
        var n = Int(gsx.int_val)
        if n < 1 or n > len(stmt.select_items):
            raise Error(
                "SQL bind error: GROUP BY term out of range - should be"
                + " between 1 and " + String(len(stmt.select_items))
            )
        sel = n - 1
    elif (
        gsx.tag == SX_COLUMN
        and gsx.qualifier == ""
        and not _schema_has_col(schema, gsx.text)
    ):
        sel = _select_alias_index(stmt, gsx.text)
    if sel < 0:
        return gsx.copy()
    return SqlExpr.int_lit(Int64(_rebuilt_position(stmt, sel)))


def _item_name(item: SelectItem, schema: Schema, mut taken: List[String]) raises -> String:
    """The output name of a SELECT item that is not a window: its alias, or
    the name the aggregate binder gives it (a column as the input spells it,
    any other expression DuckDB's text of it), with `_1`, `_2`, ... after an
    unaliased name already taken."""
    var base: String
    if item.out_alias:
        base = String(item.out_alias.value())
        taken.append(base)
        return base^
    if item.expr.tag == SX_COLUMN:
        if item.expr.qualifier == "" and _schema_has_col(schema, item.expr.text):
            base = _schema_col_spelling(schema, item.expr.text)
        else:
            base = String(item.expr.text)
    else:
        base = _duckdb_expr_text(item.expr)
    var name = base.copy()
    var n = 1
    while _group_has(taken, name):
        name = base + "_" + String(n)
        n += 1
    taken.append(name)
    return name^


def _bind_grouped_windows(
    stmt: SelectStmt,
    schema: Schema,
    scope: BindScope,
    var child: LogicalPlan,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """Bind a SELECT that aggregates and has window functions: the aggregate
    over the rebuilt SELECT list, then the windows over its output and the
    projection of the SELECT list (see the header)."""
    for i in range(len(stmt.select_items)):
        if stmt.select_items[i].is_star:
            raise Error("SQL not supported: SELECT * alongside a window function")
    for n in range(len(stmt.window_keys)):
        if stmt.window_keys[n].tag == SX_WINDOW:
            raise Error(
                "SQL not supported: a window function as a window's PARTITION"
                " BY or ORDER BY key"
            )

    # Each window, reading the hidden columns; the columns they name.
    var cols = _WindowColumns()
    var windows = List[SqlWindowData]()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.expr.tag == SX_WINDOW:
            windows.append(_rename_window(item.expr._window.value(), cols))

    # 1. The aggregate.
    var sel = _sel_names(stmt)
    var inner = SelectStmt()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.expr.tag != SX_WINDOW:
            inner.select_items.append(
                SelectItem(item.expr.copy(), Optional[String](sel[i]), False)
            )
    for j in range(len(cols.names)):
        inner.select_items.append(
            SelectItem(
                SqlExpr.column(cols.names[j], cols.quals[j]),
                Optional[String](_wcol_name(j)),
                False,
            )
        )
    for n in range(len(stmt.window_keys)):
        inner.select_items.append(
            SelectItem(
                stmt.window_keys[n].copy(),
                Optional[String](_window_key_name(n)),
                False,
            )
        )
    if len(inner.select_items) == 0:
        inner.select_items.append(
            SelectItem(
                SqlExpr.agg(SXAGG_COUNT, SqlExpr.star(), False, String("count")),
                Optional[String](String("__group_rows")),
                False,
            )
        )
    for g in range(len(stmt.group_by)):
        inner.group_by.append(_group_key(stmt, stmt.group_by[g], schema))
    if stmt.having_pred:
        inner.having_pred = stmt.having_pred.value().copy()
    var no_names = List[String]()
    var no_carry = List[String]()
    var no_idx = List[Int]()
    var agg = _bind_aggregate(
        inner, schema, scope, child^, catalog, cte_scope, prebound, no_names,
        no_carry, no_idx, no_names,
    )

    # 2. The windows over the groups, and the SELECT list.
    var outer = SelectStmt()
    var taken = List[String]()
    var wi = 0
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.expr.tag == SX_WINDOW:
            outer.select_items.append(
                SelectItem(
                    SqlExpr.window(windows[wi].copy()), item.out_alias.copy(), False
                )
            )
            wi += 1
        else:
            # An item the aggregate already names as it is output needs no
            # alias above it.
            var out_name = _item_name(item, schema, taken)
            var renamed = Optional[String](None)
            if out_name != sel[i]:
                renamed = Optional[String](out_name^)
            outer.select_items.append(
                SelectItem(SqlExpr.column(sel[i]), renamed^, False)
            )
    var agg_schema = agg.output_schema.copy()
    return _bind_window_projection(
        outer, agg_schema, scope, agg^, catalog, cte_scope, prebound
    )
