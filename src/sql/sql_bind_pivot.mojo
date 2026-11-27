# =============================================================================
# sql/sql_bind_pivot.mojo
#   `FROM <relation> PIVOT (...)` and `FROM <relation> UNPIVOT (...)`, lowered
#   onto the nodes a GROUP BY and a UNION ALL already bind to.
# =============================================================================
#
# DuckDB's PIVOT and UNPIVOT clauses (its "Pivot" and "Unpivot" statements'
# SQL-standard forms), with DuckDB's answers:
#
#   SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))
#     ==  SELECT <every other column>,
#                sum(CASE WHEN product = 'pen' THEN amount END) AS pen,
#                sum(CASE WHEN product = 'ink' THEN amount END) AS ink
#         FROM sales GROUP BY <every other column>
#
#   "Every other column" is each column of the relation that neither the FOR
#   column nor the aggregate names, in the relation's order; with none, the
#   aggregate is over the whole relation and gives one row. A group with no
#   row for a value has NULL in that value's column (count: 0, as in DuckDB,
#   whose count of no rows is 0); a value of the FOR column the IN list does
#   not name adds no column, and its rows still form their group. An output
#   column is named by the value (`AS n` renames it) and, when the aggregate
#   has an alias, `<value>_<alias>`.
#
#   SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, q2))
#     ==  SELECT <every other column>, 'q1' AS quarter, q1 AS score
#           FROM scores WHERE q1 IS NOT NULL
#         UNION ALL
#         SELECT <every other column>, 'q2', q2 FROM scores WHERE q2 IS NOT NULL
#
#   INCLUDE NULLS drops the WHERE. An unpivoted column `c AS l` writes `l`.
#
# Refused by name rather than approximated:
#   * a PIVOT value whose type is neither BIGINT nor DOUBLE (a string, a date,
#     a decimal, a narrower integer): an empty cell is a NULL of the value's
#     type, and the typed NULLs the plan carries are INT64 and FLOAT64
#     (`sql_bind_expr._bind_case`). count is served over any type;
#   * an aggregate other than sum, count, min, max and avg;
#   * UNPIVOT columns of different types (DuckDB casts some pairs to a common
#     type; this binder takes one type);
#   * an output column named like another output column (DuckDB renames the
#     second `<name>_1`).
#
# The relation is bound once, as `SELECT * FROM <relation>`, and registered in
# the CTE scope under `<relation key>#source`; the statements built here read
# it from there. `#` cannot occur in a lower-folded identifier, so no query can
# name that key.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from plan_expr.expr import EXPR_LITERAL, Expr
from plan_expr.expr_walk import PlanColRefFields, walk_expr_field
from plan_ir.logical_plan import LogicalPlan
from sql.sql_ast import (
    FromRelation, SelectItem, SelectStmt, SqlExpr, SubqueryDef,
    SX_AGG, SX_CALL, SX_COLUMN, SX_STAR, SXAGG_COUNT, SXOP_AND, SXOP_EQ,
    SXUN_IS_NOT_NULL, sql_call_is_aggregate,
)
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_join import _single_relation_scope
from sql.sql_bind_scope import CteScope, _schema_col_spelling
from sql.sql_bind_set_op import _union_all_of
from sql.sql_bind_union import _union_type_name
from sql.sql_binder import _bind_select
from sql.sql_catalog import SqlCatalog
from sql.sql_pivot_spec import PivotSpec
from containers.slab import Slab
from std.memory import OwnedPointer


comptime _SOURCE_SUFFIX: String = "#source"


def bind_pivot(
    sd: SubqueryDef,
    catalog: SqlCatalog,
    mut cte_scope: CteScope,
    prebound: List[Expr],
    is_unpivot: Bool,
) raises -> LogicalPlan:
    """The plan of the SUBQ_PIVOT / SUBQ_UNPIVOT entry `sd` (module header).
    Registers the relation it reshapes under `sd.derived_alias + "#source"`;
    the caller registers the returned plan under `sd.derived_alias`."""
    var source = SelectStmt()
    source.select_items.append(SelectItem(SqlExpr.star(), Optional[String](), True))
    source.from_tables.append(sd.body.from_tables[0].copy())
    var source_plan = _bind_select(source, catalog, cte_scope, prebound)
    var schema = source_plan.output_schema.copy()
    var key = sd.derived_alias + _SOURCE_SUFFIX
    cte_scope.add(key, source_plan^)
    if is_unpivot:
        return _bind_unpivot(sd, key, schema, catalog, cte_scope, prebound)
    return _bind_pivot(sd, key, schema, catalog, cte_scope, prebound)


def _column_of(schema: Schema, name: String, kw: String) raises -> String:
    """The relation's spelling of the column `name` names (case-insensitive),
    or a bind error naming it and the relation's columns."""
    var spelled = _schema_col_spelling(schema, name)
    if spelled == "":
        var cols = String("")
        for i in range(schema.num_columns()):
            if i > 0:
                cols += ", "
            cols += schema.field_name(i)
        raise Error(
            "SQL bind error: " + kw + " names the column `" + name + "`, which"
            " the relation it reshapes does not have (its columns: " + cols
            + ")"
        )
    return spelled


def _sx_columns(sx: SqlExpr, mut names: List[String]) raises:
    """Append the lower-cased name of every column `sx` reads; a qualified
    one (`s.amount`) is refused, as in DuckDB."""
    if sx.tag == SX_COLUMN:
        if sx.qualifier != "":
            raise Error(
                "SQL bind error: a PIVOT aggregate names the qualified column `"
                + sx.qualifier + "." + sx.text + "`; name the column without"
                " its table, as the PIVOT reads one relation"
            )
        names.append(sx.text.lower())
    if sx._binary:
        _sx_columns(sx._binary.value().left[], names)
        _sx_columns(sx._binary.value().right[], names)
    if sx._agg:
        _sx_columns(sx._agg.value().arg[], names)
    if sx._call:
        ref args = sx._call.value().args
        for i in range(len(args)):
            _sx_columns(args[i], names)
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            _sx_columns(cd.conds[i], names)
            _sx_columns(cd.results[i], names)
        for i in range(len(cd.otherwise)):
            _sx_columns(cd.otherwise[i], names)


def _has_name(names: List[String], name: String) -> Bool:
    var target = name.lower()
    for i in range(len(names)):
        if names[i].lower() == target:
            return True
    return False


def _refuse_duplicate_outputs(names: List[String], kw: String) raises:
    """Refuse two output columns of one name (compared case-insensitively, as
    a column reference resolves)."""
    for i in range(len(names)):
        for j in range(i):
            if names[i].lower() == names[j].lower():
                raise Error(
                    "SQL not supported: " + kw + " gives two output columns"
                    " named `" + names[i] + "` (DuckDB renames the second `"
                    + names[i] + "_1`). Give the value or column an AS name"
                    " that no other output column has."
                )


def _value_is_served(e: Expr, schema: Schema) -> Bool:
    """The bound PIVOT value `e` is a BIGINT or a DOUBLE: the types whose NULL
    an empty cell can be."""
    if e.tag == EXPR_LITERAL:
        var lv = e.literal_value()
        return (lv.is_int() or lv.is_float()) and not lv.is_null()
    var missing = String("")
    var t = walk_expr_field[PlanColRefFields](e, schema, missing).arrow_type
    return missing.byte_length() == 0 and (
        t == ArrowType.INT64 or t == ArrowType.FLOAT64
    )


def _source_rel(key: String) -> FromRelation:
    return FromRelation.named(key, String("__unnamed_pivot"))


def _bind_pivot(
    sd: SubqueryDef,
    key: String,
    schema: Schema,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    ref spec = sd.pivot
    ref item = sd.body.select_items[0]
    ref agg = item.expr
    if agg.tag != SX_AGG:
        if agg.tag == SX_CALL and sql_call_is_aggregate(agg.text):
            raise Error(
                "SQL not supported: PIVOT over the aggregate `" + agg.text
                + "`. A PIVOT is served over sum, count, min, max and avg."
            )
        raise Error(
            "SQL bind error: a PIVOT value must be one aggregate call, such as"
            " `sum(x)` or `count(*)`"
        )
    ref arg = agg._agg.value().arg[]
    var pivot_col = _column_of(schema, spec.name_col, String("PIVOT"))

    # The columns the clause names; every other column is a group key.
    var named = List[String]()
    named.append(pivot_col.lower())
    _sx_columns(arg, named)
    var group_cols = List[String]()
    for i in range(schema.num_columns()):
        if not _has_name(named, String(schema.field_name(i))):
            group_cols.append(String(schema.field_name(i)))

    # count counts the rows of its value, so its argument is `1` and its type
    # does not matter; every other aggregate reads the value itself, whose
    # empty cell is a NULL of its type.
    var counts_rows = agg.op == SXAGG_COUNT and not agg.agg_distinct
    if not counts_rows:
        var scope = _single_relation_scope(_source_rel(key), schema)
        var bound = _bind_scalar(arg, schema, scope, catalog, cte_scope, prebound)
        if not _value_is_served(bound, schema):
            raise Error(
                "SQL not supported: PIVOT over a value that is neither BIGINT"
                " nor DOUBLE (a string, a date, a boolean, a decimal or a"
                " narrower integer). A combination with no row is a NULL of the"
                " value's type, and the typed NULL values this engine's plan"
                " can carry are BIGINT and DOUBLE only. count(*) and count(x)"
                " are served over a value of any type."
            )

    var out_names = List[String]()
    for i in range(len(group_cols)):
        out_names.append(group_cols[i])
    for v in range(len(spec.values)):
        for w in range(v):
            if (
                spec.values[v] == spec.values[w]
                and spec.value_is_string[v] == spec.value_is_string[w]
            ):
                raise Error(
                    "SQL bind error: the value " + _value_text(spec, v)
                    + " is listed more than once in the PIVOT IN list"
                )
        var name = spec.labels[v]
        if item.out_alias:
            name += "_" + item.out_alias.value()
        out_names.append(name)
    _refuse_duplicate_outputs(out_names, String("PIVOT"))

    var stmt = SelectStmt()
    stmt.from_tables.append(_source_rel(key))
    for i in range(len(group_cols)):
        stmt.select_items.append(
            SelectItem(SqlExpr.column(group_cols[i]), Optional[String](), False)
        )
        stmt.group_by.append(SqlExpr.column(group_cols[i]))
    for v in range(len(spec.values)):
        var value: SqlExpr
        if spec.value_is_string[v]:
            value = SqlExpr.string_lit(spec.values[v])
        else:
            value = SqlExpr.int_lit(Int64(atol(spec.values[v])))
        var cond = SqlExpr.binary(SXOP_EQ, SqlExpr.column(pivot_col), value^)
        var result: SqlExpr
        if counts_rows:
            if arg.tag != SX_STAR:
                cond = SqlExpr.binary(
                    SXOP_AND, cond^, SqlExpr.unary(SXUN_IS_NOT_NULL, arg.copy())
                )
            result = SqlExpr.int_lit(1)
        else:
            result = arg.copy()
        var conds = Slab[SqlExpr]()
        conds.append(cond^)
        var results = Slab[SqlExpr]()
        results.append(result^)
        var cell = SqlExpr.case(conds^, results^, Slab[SqlExpr]())
        var call = SqlExpr.agg(agg.op, cell^, agg.agg_distinct, agg.text)
        stmt.select_items.append(
            SelectItem(call^, Optional[String](out_names[len(group_cols) + v]), False)
        )
    return _bind_select(stmt, catalog, cte_scope, prebound)


def _value_text(spec: PivotSpec, v: Int) -> String:
    """Value `v` of a PIVOT IN list as written: a string quoted, an integer
    bare."""
    if spec.value_is_string[v]:
        return "'" + spec.values[v] + "'"
    return spec.values[v]


def _same_type(schema: Schema, a: Int, b: Int) -> Bool:
    """Columns `a` and `b` have one type (a decimal: one precision and
    scale)."""
    if schema.field_arrow_type(a) != schema.field_arrow_type(b):
        return False
    if schema.field_arrow_type(a) == ArrowType.DECIMAL128:
        return (
            schema.field_decimal_precision(a) == schema.field_decimal_precision(b)
            and schema.field_decimal_scale(a) == schema.field_decimal_scale(b)
        )
    return True


def _column_index(schema: Schema, spelled: String) -> Int:
    for i in range(schema.num_columns()):
        if String(schema.field_name(i)) == spelled:
            return i
    return -1


def _bind_unpivot(
    sd: SubqueryDef,
    key: String,
    schema: Schema,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    ref spec = sd.pivot
    var cols = List[String]()
    for i in range(len(spec.values)):
        cols.append(_column_of(schema, spec.values[i], String("UNPIVOT")))
    var first = _column_index(schema, cols[0])
    for i in range(1, len(cols)):
        var at = _column_index(schema, cols[i])
        if not _same_type(schema, first, at):
            raise Error(
                "SQL not supported: UNPIVOT over columns of different types (`"
                + cols[0] + "` " + _union_type_name(schema, first) + ", `" + cols[i]
                + "` " + _union_type_name(schema, at) + "). The value column has one"
                " type; CAST the columns to one type in a derived table first."
            )

    var kept = List[String]()
    for i in range(schema.num_columns()):
        if not _has_name(cols, String(schema.field_name(i))):
            kept.append(String(schema.field_name(i)))
    var out_names = kept.copy()
    out_names.append(spec.name_col)
    out_names.append(spec.value_col)
    _refuse_duplicate_outputs(out_names, String("UNPIVOT"))

    var branches = List[OwnedPointer[LogicalPlan]]()
    var firsts = List[Int]()
    var ops = List[String]()
    for c in range(len(cols)):
        var stmt = SelectStmt()
        stmt.from_tables.append(_source_rel(key))
        for i in range(len(kept)):
            stmt.select_items.append(
                SelectItem(SqlExpr.column(kept[i]), Optional[String](), False)
            )
        stmt.select_items.append(
            SelectItem(
                SqlExpr.string_lit(spec.labels[c]),
                Optional[String](spec.name_col),
                False,
            )
        )
        stmt.select_items.append(
            SelectItem(
                SqlExpr.column(cols[c]), Optional[String](spec.value_col), False
            )
        )
        if not spec.include_nulls:
            stmt.where_pred = SqlExpr.unary(
                SXUN_IS_NOT_NULL, SqlExpr.column(cols[c])
            )
        branches.append(OwnedPointer(_bind_select(stmt, catalog, cte_scope, prebound)))
        firsts.append(c + 1)
        ops.append(String("UNION ALL"))
    return _union_all_of(branches^, firsts, ops)

