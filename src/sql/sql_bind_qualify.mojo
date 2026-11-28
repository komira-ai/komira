# =============================================================================
# sql/sql_bind_qualify.mojo
#   The QUALIFY clause: a filter over the window results of a SELECT.
# =============================================================================
#
# DuckDB v1.5.3 evaluates QUALIFY after the window functions and before
# DISTINCT, ORDER BY and LIMIT. Its predicate may name:
#
#   * a window function written inline (`QUALIFY row_number() OVER (...) = 1`);
#   * the alias of a SELECT item (`QUALIFY rn = 1`, the item a window or not);
#   * any input column, selected or not.
#
# An identifier that IS an input column is that column even where a SELECT
# alias shares its name (DuckDB: `SELECT id, row_number() OVER (ORDER BY id)
# AS o FROM t QUALIFY o = 1` filters on the input `o`), as in ORDER BY
# expressions (`sql_bind_window_order`).
#
# The window binder (`_bind_window_projection`) puts the filter between the
# last PARTITION BY node and the Project, where every input column and every
# window output is still a column. This module rewrites the predicate for that
# position: each inline window becomes a reference to a hidden column
# `__qualify_w<n>` (computed by its own PARTITION BY node and never projected),
# and each alias of a non-window item becomes the item's expression.
#
# A QUALIFY with no window function in the SELECT list or in its own
# predicate is DuckDB's Binder Error, raised here in DuckDB's words.

from containers.slab import Slab

from arrow.schema import Schema
from sql.sql_ast import (
    SX_COLUMN, SX_WINDOW, SelectStmt, SqlAggData, SqlBinaryData, SqlCallData,
    SqlCaseData, SqlExpr,
)
from sql.sql_bind_scope import _schema_has_col


# DuckDB v1.5.3's Binder Error for a QUALIFY with no window function.
comptime QUALIFY_NEEDS_A_WINDOW = (
    "SQL bind error: at least one window function must appear in the SELECT"
    " column or QUALIFY clause"
)


def _sx_has_window(sx: SqlExpr) -> Bool:
    """True iff `sx` or any expression inside it is a window function."""
    if sx.tag == SX_WINDOW:
        return True
    if sx._binary:
        if _sx_has_window(sx._binary.value().left[]):
            return True
        return _sx_has_window(sx._binary.value().right[])
    if sx._agg:
        return _sx_has_window(sx._agg.value().arg[])
    if sx._call:
        ref cargs = sx._call.value().args
        for i in range(len(cargs)):
            if _sx_has_window(cargs[i]):
                return True
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            if _sx_has_window(cd.conds[i]) or _sx_has_window(cd.results[i]):
                return True
        for i in range(len(cd.otherwise)):
            if _sx_has_window(cd.otherwise[i]):
                return True
    return False


def _qualify_has_window(stmt: SelectStmt) -> Bool:
    """True iff the statement's QUALIFY predicate holds a window function."""
    if not stmt.qualify_pred:
        return False
    return _sx_has_window(stmt.qualify_pred.value())


def _qualify_window_name(n: Int) -> String:
    """The hidden column of the QUALIFY predicate's `n`-th inline window."""
    return String("__qualify_w") + String(n)


def _rewrite_slab(
    src: Slab[SqlExpr], stmt: SelectStmt, schema: Schema, mut windows: Slab[SqlExpr]
) raises -> Slab[SqlExpr]:
    var out = Slab[SqlExpr]()
    for i in range(len(src)):
        out.append(_qualify_rewrite(src[i], stmt, schema, windows))
    return out^


def _qualify_rewrite(
    sx: SqlExpr, stmt: SelectStmt, schema: Schema, mut windows: Slab[SqlExpr]
) raises -> SqlExpr:
    """`sx` with every inline window replaced by a reference to its hidden
    column (the window itself appended to `windows`, in the order met, so the
    `n`-th one is `_qualify_window_name(n)`) and every unqualified name that
    is not an input column of `schema` but is a SELECT alias (matched
    case-insensitively, as DuckDB matches names) replaced by that
    item: a window item by its output column (named by the alias), any other
    item by a copy of its expression."""
    if sx.tag == SX_WINDOW:
        var name = _qualify_window_name(len(windows))
        windows.append(sx.copy())
        return SqlExpr.column(name)
    if sx.tag == SX_COLUMN:
        if sx.qualifier == "" and not _schema_has_col(schema, sx.text):
            for j in range(len(stmt.select_items)):
                ref it = stmt.select_items[j]
                if it.is_star or not it.out_alias:
                    continue
                if it.out_alias.value().lower() != sx.text.lower():
                    continue
                if it.expr.tag == SX_WINDOW:
                    return SqlExpr.column(sx.text)
                return it.expr.copy()
        return sx.copy()
    var e = sx.copy()
    if sx._binary:
        e._binary = SqlBinaryData(
            _qualify_rewrite(sx._binary.value().left[], stmt, schema, windows),
            _qualify_rewrite(sx._binary.value().right[], stmt, schema, windows),
        )
    if sx._agg:
        e._agg = SqlAggData(
            _qualify_rewrite(sx._agg.value().arg[], stmt, schema, windows)
        )
    if sx._call:
        e._call = SqlCallData(
            _rewrite_slab(sx._call.value().args, stmt, schema, windows)
        )
    if sx._case:
        ref cd = sx._case.value()
        var conds = _rewrite_slab(cd.conds, stmt, schema, windows)
        var results = _rewrite_slab(cd.results, stmt, schema, windows)
        var otherwise = _rewrite_slab(cd.otherwise, stmt, schema, windows)
        e._case = SqlCaseData(conds^, results^, otherwise^)
    return e^
