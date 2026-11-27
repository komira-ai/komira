# =============================================================================
# sql_bind_unnest -- `SELECT ..., unnest(list) [AS name], ... FROM ...`
# =============================================================================
# `unnest(x)` as a whole SELECT item gives one row per element of the list
# `x`, the other items repeated, as DuckDB v1.5.3 does in the SELECT list: a
# row whose list is empty or NULL gives no row. It binds as three nodes:
#
#   Project(<every input column>, __unnest := x)   the list as a column
#   Unnest(__unnest, keep_empty = False)            one row per element
#   Project(<the SELECT items>)                     the unnest item is
#                                                   ColRef(__unnest), named by
#                                                   its alias or `unnest(x)`
#
# The other items bind over the input schema: the Unnest repeats every input
# column, so they read the same columns above it. Refused by name, each with
# its sentence below: unnest nested in an expression or used outside the
# SELECT list (`sql_bind_call.UNNEST_NOT_A_SELECT_ITEM`), two unnest
# items, an argument count other than one, an argument that is not a list,
# `*` beside unnest, an ORDER BY expression no item produces, and unnest
# beside an aggregate, GROUP BY or a window function (`sql_binder._bind_select`).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan
from sql.sql_ast import SX_CALL, SelectStmt, SqlExpr
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_names import _duckdb_expr_text
from sql.sql_bind_scope import CteScope, _schema_has_col, BindScope
from sql.sql_catalog import SqlCatalog


comptime UNNEST_COLUMN = "__unnest"
"""The column the list is projected into, below the Unnest."""

comptime UNNEST_BESIDE_AGGREGATE = (
    "SQL not supported: unnest(...) beside an aggregate, GROUP BY or a window"
    " function in the same SELECT; unnest in a subquery and aggregate over it"
)

comptime UNNEST_ORDER_EXPRESSION = (
    "SQL not supported: ORDER BY an expression that no SELECT item produces,"
    " beside unnest(...); select the expression and order by its alias or"
    " position, or order by a selected column"
)

comptime UNNEST_TWICE = (
    "SQL not supported: two unnest(...) items in one SELECT (DuckDB pairs"
    " their elements row by row); unnest one list per SELECT"
)

comptime UNNEST_BESIDE_STAR = (
    "SQL not supported: SELECT * beside unnest(...); name the columns to keep"
)


def _is_unnest_call(sx: SqlExpr) -> Bool:
    return sx.tag == SX_CALL and sx.text == "unnest"


def _has_unnest(stmt: SelectStmt) -> Bool:
    """True iff a SELECT item is, as a whole, a call of `unnest`."""
    for i in range(len(stmt.select_items)):
        ref it = stmt.select_items[i]
        if not it.is_star and _is_unnest_call(it.expr):
            return True
    return False


def _bind_unnest_projection(
    stmt: SelectStmt,
    schema: Schema,
    scope: BindScope,
    var child: LogicalPlan,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """Bind a SELECT one of whose items is `unnest(x)` (see the module header).
    The caller refuses unnest beside an aggregate, GROUP BY or a window."""
    var at = -1
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            raise Error(UNNEST_BESIDE_STAR)
        if _is_unnest_call(item.expr):
            if at >= 0:
                raise Error(UNNEST_TWICE)
            at = i
    ref call = stmt.select_items[at].expr
    ref args = call._call.value().args
    if len(args) != 1:
        raise Error(
            "SQL bind error: unnest takes one argument, a list; `"
            + _duckdb_expr_text(call)
            + "` has "
            + String(len(args))
        )
    if _schema_has_col(schema, UNNEST_COLUMN):
        raise Error(
            "SQL not supported: unnest(...) over an input that has a column"
            " named `" + String(UNNEST_COLUMN) + "`, the name it binds its"
            " list to; rename that column"
        )
    # Every input column, then the list.
    var below = ExprArray()
    for c in range(schema.num_columns()):
        below.append(Expr.col_ref(schema.field_name(c)))
    var arg = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
    below.append(Expr.alias(arg^, String(UNNEST_COLUMN)))
    var listed = LogicalPlan.project(below^, child^)
    var list_type = listed.output_schema.field_arrow_type(schema.num_columns())
    if list_type != ArrowType.LIST:
        raise Error(
            "SQL bind error: unnest(...) takes a list, and the argument of `"
            + _duckdb_expr_text(call)
            + "` is "
            + String(list_type)
        )
    var plan = LogicalPlan.unnest(listed^, String(UNNEST_COLUMN), False)
    var proj = ExprArray()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if i == at:
            var name: String
            if item.out_alias:
                name = String(item.out_alias.value())
            else:
                name = _duckdb_expr_text(item.expr)
            proj.append(Expr.alias(Expr.col_ref(String(UNNEST_COLUMN)), name))
            continue
        var e = _bind_scalar(item.expr, schema, scope, catalog, cte_scope, prebound)
        if item.out_alias:
            e = Expr.alias(e^, item.out_alias.value())
        proj.append(e^)
    return LogicalPlan.project(proj^, plan^)
