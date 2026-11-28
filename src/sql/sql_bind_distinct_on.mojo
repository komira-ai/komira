# =============================================================================
# sql/sql_bind_distinct_on.mojo
#   SELECT DISTINCT ON (k, ...): one row per key, the first under ORDER BY.
# =============================================================================
#
# DuckDB v1.5.3 keeps, for each distinct value of the DISTINCT ON keys, the
# first row in the order of the query's WHOLE ORDER BY; the ORDER BY need not
# begin with the keys (`SELECT DISTINCT ON (name) id, name FROM t ORDER BY id
# DESC` keeps the highest id of each name, then sorts the kept rows by id).
# With no ORDER BY the kept row is any row of its key, in DuckDB as here. NULL
# keys are one key, as in GROUP BY.
#
# THE PLAN. A plan's Distinct node cannot choose which row of a key survives
# (its sink is a hash aggregate, and a plan has no row order), so DISTINCT ON
# binds to the shape the window path already serves, over the SELECT output:
#
#   Project(the output columns)                -- drops the row number
#     Filter(__distinct_on_rn = 1)
#       PartitionBy(partition = the keys, order = the ORDER BY keys,
#                   ROW_NUMBER AS __distinct_on_rn)
#         <the SELECT output, ORDER BY columns carried>
#
# then ORDER BY and LIMIT as for any SELECT. The ORDER BY keys are the columns
# the statement binder resolved them to (`sort_names`), with their direction
# and NULL placement, so the first row of each key is the one the ORDER BY puts
# first.
#
# A KEY is resolved to a column of the SELECT output, in this order: an
# ordinal (`DISTINCT ON (2)`); an ORDER BY key written the same way (its
# resolved column, carried if not selected); a bare column, which is a SELECT
# alias or output column of that name, or an input column the statement binder
# carried (`_distinct_on_carry_names`); an expression a SELECT item produces.
# Any other key is refused by name.

from plan_expr.expr import BIN_EQ, Expr
from plan_expr.null_order_policy import derived_nulls_first
from plan_expr.partition_expr import PF_ROW_NUMBER, PartitionExpr, PartitionFrame
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import ExprArray, LogicalPlan
from sql.sql_ast import SX_COLUMN, SX_INT, SelectStmt, SqlExpr
from sql.sql_bind_names import _duckdb_expr_text, _group_has
from sql.sql_bind_ops import _sx_is_big_int
from sql.sql_bind_scope import BindScope, _schema_has_col
from sql.sql_bind_window_order import (
    _order_expr_select_match, _order_key_name, _order_output_column,
)


comptime DISTINCT_ON_ROW = "__distinct_on_rn"


def _distinct_on_carry_names(stmt: SelectStmt, scope: BindScope) -> List[String]:
    """The bare-column DISTINCT ON keys, resolved as ORDER BY column keys are:
    the projection carries any the SELECT list does not produce, so the
    partition can name it."""
    var names = List[String]()
    for i in range(len(stmt.distinct_on)):
        ref kx = stmt.distinct_on[i]
        if kx.tag == SX_COLUMN:
            names.append(_order_key_name(kx, scope))
    return names^


def _distinct_on_key_column(
    stmt: SelectStmt,
    kx: SqlExpr,
    child: LogicalPlan,
    scope: BindScope,
    sort_names: List[String],
    n_result: Int,
) raises -> String:
    """The column of `child` (the SELECT output) that DISTINCT ON key `kx`
    names; see the module header for the order of the readings."""
    if kx.tag == SX_INT:
        if _sx_is_big_int(kx):
            raise Error(
                "SQL bind error: the DISTINCT ON ordinal " + kx.text
                + " is out of range for BIGINT"
            )
        return _order_output_column(child.output_schema, Int(kx.int_val) - 1, n_result)
    var canon = _duckdb_expr_text(kx)
    for j in range(len(sort_names)):
        if _duckdb_expr_text(stmt.order_by[j].expr) == canon:
            return String(sort_names[j])
    if kx.tag == SX_COLUMN:
        var name = _order_key_name(kx, scope)
        if _schema_has_col(child.output_schema, name):
            return name^
    else:
        var mj = _order_expr_select_match(stmt, kx)
        if mj >= 0:
            return _order_output_column(child.output_schema, mj, n_result)
    raise Error(
        "SQL not supported: the DISTINCT ON key `" + canon + "` is neither a"
        " SELECT item, an ORDER BY key nor an input column this SELECT can"
        " carry. Select it or ORDER BY it."
    )


def _bind_distinct_on(
    stmt: SelectStmt,
    var child: LogicalPlan,
    scope: BindScope,
    sort_names: List[String],
    n_result: Int,
) raises -> LogicalPlan:
    """Keep the first row of each DISTINCT ON key of `child` (the SELECT
    output, with ORDER BY columns carried) under the ORDER BY whose keys
    resolved to `sort_names`; see the module header. The output columns are
    `child`'s."""
    # The partition, the sort and the final Project name their columns, so
    # two output columns of one name would be one column to all three.
    var width = child.output_schema.num_columns()
    for c in range(width):
        for c2 in range(c + 1, width):
            if child.output_schema.field_name(c) == child.output_schema.field_name(c2):
                raise Error(
                    "SQL not supported: SELECT DISTINCT ON over two items both"
                    " named `" + child.output_schema.field_name(c) + "`. The"
                    " rows are partitioned and kept by column NAME, so the"
                    " second would be answered with the first's values. Give"
                    " the two items distinct aliases."
                )
    var pkeys = List[String]()
    for i in range(len(stmt.distinct_on)):
        var name = _distinct_on_key_column(
            stmt, stmt.distinct_on[i], child, scope, sort_names, n_result
        )
        if not _group_has(pkeys, name):
            pkeys.append(name^)
    var okeys = List[String]()
    var desc = List[Bool]()
    var nulls_first = List[Bool]()
    var any_placement = False
    for j in range(len(sort_names)):
        ref ok = stmt.order_by[j]
        okeys.append(String(sort_names[j]))
        desc.append(ok.descending)
        if ok.nulls_first:
            any_placement = True
            nulls_first.append(ok.nulls_first.value())
        else:
            nulls_first.append(derived_nulls_first(ok.descending))
    var keep = ExprArray()
    for c in range(width):
        keep.append(Expr.col_ref(child.output_schema.field_name(c)))
    var frame = (
        PartitionFrame.default_unordered() if len(okeys) == 0 else PartitionFrame.running_range()
    )
    var pexprs = List[PartitionExpr]()
    pexprs.append(
        PartitionExpr(
            PF_ROW_NUMBER, String(""), 0, ScalarValue(), False, frame^,
            String(DISTINCT_ON_ROW),
        )
    )
    var plan: LogicalPlan
    if any_placement:
        plan = LogicalPlan.partition_by(
            pkeys^, okeys^, desc^, pexprs^, child^, Optional(nulls_first^)
        )
    else:
        plan = LogicalPlan.partition_by(pkeys^, okeys^, desc^, pexprs^, child^)
    plan = LogicalPlan.filter(
        Expr.binary(
            BIN_EQ,
            Expr.col_ref(String(DISTINCT_ON_ROW)),
            Expr.literal(ScalarValue.from_int(1)),
        ),
        plan^,
    )
    return LogicalPlan.project(keep^, plan^)
