# =============================================================================
# sql/sql_bind_corr_scalar.mojo
#   A correlated scalar subquery body, bound grouped by its correlation keys.
# =============================================================================
#
# A scalar subquery whose WHERE names a column of the statement around it,
#
#     (SELECT f(a1, ..., am) FROM R WHERE p AND r1 = o1 AND ... AND rn = on)
#
# with each `ri` a column of R, each `oi` a column of the enclosing FROM, `p`
# the conjuncts that name no outer column and `f` an expression over the
# aggregates `aj`, has for one outer row the value `f` takes over the
# aggregates of the rows of R where `p` holds and `(r1..rn) = (o1..on)`. That
# is the group `(o1..on)` of
#
#     SELECT r1 AS __corr<i>_k0, ..., a1 AS __corr<i>_a0, ...
#     FROM R WHERE p GROUP BY r1, ..., rn
#
# or, when no group has that key, the aggregates of no row: every count is 0
# and every other aggregate NULL. A NULL outer key matches no group, as
# `ri = NULL` holds for no row. The body binds to
#
#     Project([f' AS __corr<i>_v],
#             Filter(__corr<i>_k0 = <outer o1> AND ..., <the grouped body>))
#
# inside a CORR_KIND_SCALAR subquery whose outer refs are o1..on (each marked
# COL_SIDE_LEFT, as a predicate subquery's are). `f'` is `f` over the
# aggregate columns with every count `c` written `coalesce(c, 0)`: over a
# group it is `f` (a count is never NULL there), and over a row of NULL
# aggregate columns it is `f` over no row. The optimizer's
# `flatten_dependent_joins` lifts the Filter's equalities into the keys of a
# LEFT join of the outer rows with the grouped body, which pads an outer row
# with no group with NULLs, and evaluates `f'` above that join.
#
# `<i>` is the subquery's index in the statement's side table, so the columns
# of two correlated scalars never share a name.
#
# Refused by name (`SQL not supported: a correlated scalar subquery ...`): a
# body with GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET, a JOIN
# other than a comma or CROSS join, a SELECT list that is not one expression
# holding an aggregate (a plain column could be several rows), an aggregate
# other than sum / count / min / max / avg, an outer column in the SELECT
# list, and an outer column in any WHERE conjunct that is not
# `inner_column = outer_column`.
# =============================================================================

from plan_expr.corr_subquery_data import CORR_KIND_SCALAR
from plan_expr.expr import BIN_AND, BIN_EQ, Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan
from sql.sql_ast import (
    JK_CROSS, JoinClause, SelectItem, SelectStmt, SqlExpr, SXAGG_COUNT, SXOP_AND,
    SXOP_EQ, SX_AGG, SX_BINARY, SX_CALL, SX_COLUMN, SX_SUBQUERY, SX_WINDOW,
    sql_call_is_aggregate,
)
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_scope import (
    BindScope, CteScope, _RelCols, _build_bind_scope, _schema_col_spelling,
    _schema_has_col,
)
from sql.sql_bind_subquery import (
    _CorrOuter, _corr_outer_of, _dedup_names, _sx_contains_subquery,
)
from sql.sql_binder import _bind_select
from sql.sql_catalog import SqlCatalog
from containers.slab import Slab
from std.collections import Optional


comptime CORR_SCALAR_REFUSAL = "SQL not supported: a correlated scalar subquery"


def _corr_prefix(idx: Int) -> String:
    """The prefix of every column the body of subquery `idx` adds."""
    return "__corr" + String(idx) + "_"


def corr_scalar_value_name(idx: Int) -> String:
    """The name the value of correlated scalar subquery `idx` is projected
    under inside its body."""
    return _corr_prefix(idx) + "v"


def _select_list_holds(s: SelectStmt, idx: Int) -> Bool:
    """Whether a SELECT item of `s` holds subquery `idx` under its AND / OR /
    comparison / NOT nodes (`_sx_contains_subquery`)."""
    for i in range(len(s.select_items)):
        ref it = s.select_items[i]
        if not it.is_star and _sx_contains_subquery(it.expr, idx):
            return True
    return False


def _is_grouped(s: SelectStmt) -> Bool:
    """Whether `s` aggregates: a GROUP BY, a HAVING or an aggregate in its
    SELECT list."""
    if len(s.group_by) > 0 or s.having_pred:
        return True
    for i in range(len(s.select_items)):
        ref it = s.select_items[i]
        if not it.is_star and it.expr.contains_aggregate():
            return True
    return False


def scalar_outer_of(
    stmt: SelectStmt, idx: Int, catalog: SqlCatalog, cte_scope: CteScope
) raises -> _CorrOuter:
    """The FROM scope a scalar subquery's outer columns bind in: that of the
    statement whose WHERE holds subquery `idx` (`_corr_outer_of`), else that
    of the ungrouped statement whose SELECT list holds it (the top statement
    or another subquery's body), else none (a scalar in a HAVING, in the
    SELECT list of a grouped query, or under a CASE or a function call)."""
    var where = _corr_outer_of(stmt, idx, catalog, cte_scope)
    if where.known:
        return where^
    if _select_list_holds(stmt, idx):
        if _is_grouped(stmt):
            return where^
        return _CorrOuter(
            _build_bind_scope(stmt.from_tables, stmt.joins, catalog, cte_scope), True
        )
    for j in range(len(stmt.subqueries)):
        ref b = stmt.subqueries[j].body
        if _select_list_holds(b, idx):
            if _is_grouped(b):
                return where^
            return _CorrOuter(
                _build_bind_scope(b.from_tables, b.joins, catalog, cte_scope), True
            )
    return where^


def _refuse_if_grouped_holder(
    holder: SelectStmt, body: SelectStmt, idx: Int, catalog: SqlCatalog,
    cte_scope: CteScope,
) raises -> Bool:
    """Whether `holder` holds scalar subquery `idx` in its HAVING or in a
    grouped SELECT list; raises when it does and `body` names a column of
    `holder`'s FROM that its own FROM lacks."""
    var held = Bool(holder.having_pred) and _sx_contains_subquery(
        holder.having_pred.value(), idx
    )
    if not held:
        held = _is_grouped(holder) and _select_list_holds(holder, idx)
    if not held:
        return False
    var scope = _CorrOuter(
        _build_bind_scope(holder.from_tables, holder.joins, catalog, cte_scope),
        True,
    )
    if scalar_body_is_correlated(body, scope, catalog, cte_scope):
        raise _refuse("in a HAVING clause or in the SELECT list of a grouped query")
    return True


def refuse_grouped_correlated_scalar(
    stmt: SelectStmt, idx: Int, catalog: SqlCatalog, cte_scope: CteScope
) raises:
    """Raise when scalar subquery `idx` sits in a HAVING, or in the SELECT
    list of a grouped statement, and names a column of that statement's FROM
    its own FROM lacks: such a correlation reads the outer row of a group,
    which this binder does not build. A body naming no such column binds as
    an uncorrelated one."""
    ref body = stmt.subqueries[idx].body
    if _refuse_if_grouped_holder(stmt, body, idx, catalog, cte_scope):
        return
    for h in range(len(stmt.subqueries)):
        if _refuse_if_grouped_holder(
            stmt.subqueries[h].body, body, idx, catalog, cte_scope
        ):
            return


def _col_is_inner(sx: SqlExpr, inner: BindScope, outer: _CorrOuter) -> Bool:
    """Whether column `sx` binds in the subquery's own FROM. The inner scope
    shadows the outer one, as in DuckDB: a qualified `q.c` is inner when an
    inner relation answering to `q` has `c`, or when `q` names an inner
    relation and no outer one (then it is an unknown column, which the inner
    binder reports); an unqualified `c` is inner when the inner FROM has it."""
    if sx.qualifier != "":
        if inner.has_qualified(sx.qualifier, sx.text):
            return True
        return inner.answers_to(sx.qualifier) and not outer.scope.answers_to(
            sx.qualifier
        )
    return _schema_has_col(inner.out_schema, sx.text)


def _names_outer(sx: SqlExpr, inner: BindScope, outer: _CorrOuter) -> Bool:
    """Whether `sx` names a column that does not bind in the inner FROM. A
    nested subquery's body is its own scope and is not looked into."""
    if sx.tag == SX_COLUMN:
        return not _col_is_inner(sx, inner, outer)
    if sx.tag == SX_SUBQUERY:
        return False
    if sx._binary:
        if _names_outer(sx._binary.value().left[], inner, outer):
            return True
        if _names_outer(sx._binary.value().right[], inner, outer):
            return True
    if sx._agg:
        if _names_outer(sx._agg.value().arg[], inner, outer):
            return True
    if sx._call:
        ref args = sx._call.value().args
        for i in range(len(args)):
            if _names_outer(args[i], inner, outer):
                return True
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            if _names_outer(cd.conds[i], inner, outer):
                return True
        for i in range(len(cd.results)):
            if _names_outer(cd.results[i], inner, outer):
                return True
        for i in range(len(cd.otherwise)):
            if _names_outer(cd.otherwise[i], inner, outer):
                return True
    return False


def scalar_body_is_correlated(
    body: SelectStmt, outer: _CorrOuter, catalog: SqlCatalog, cte_scope: CteScope
) raises -> Bool:
    """Whether a scalar subquery body names a column of `outer` in its WHERE
    or its SELECT list. False when `outer` is not known: such a body binds as
    an uncorrelated one, which reports a name it cannot resolve."""
    if not outer.known:
        return False
    var inner = _build_bind_scope(body.from_tables, body.joins, catalog, cte_scope)
    if body.where_pred and _names_outer(body.where_pred.value(), inner, outer):
        return True
    for i in range(len(body.select_items)):
        ref it = body.select_items[i]
        if not it.is_star and _names_outer(it.expr, inner, outer):
            return True
    return False


def _split_and(sx: SqlExpr, mut out: Slab[SqlExpr]):
    """The conjuncts of `sx` (its AND tree flattened), in order."""
    if sx.tag == SX_BINARY and sx.op == SXOP_AND:
        _split_and(sx._binary.value().left[], out)
        _split_and(sx._binary.value().right[], out)
        return
    out.append(sx.copy())


def _outer_name(sx: SqlExpr, outer: _CorrOuter) raises -> String:
    """The outer FROM's output name of outer column `sx`."""
    if sx.qualifier != "":
        return outer.scope.resolve_qualified(sx.qualifier, sx.text)
    if not _schema_has_col(outer.scope.out_schema, sx.text):
        raise Error("SQL bind error: unknown column '" + sx.text + "'")
    return _schema_col_spelling(outer.scope.out_schema, sx.text)


def _has_other_aggregate(sx: SqlExpr) -> Bool:
    """Whether `sx` holds an aggregate written as a function call (median,
    stddev, ...) or a window function."""
    if sx.tag == SX_WINDOW:
        return True
    if sx.tag == SX_CALL and sql_call_is_aggregate(sx.text):
        return True
    if sx.tag == SX_AGG:
        return False
    if sx._binary:
        if _has_other_aggregate(sx._binary.value().left[]):
            return True
        if _has_other_aggregate(sx._binary.value().right[]):
            return True
    if sx._agg and _has_other_aggregate(sx._agg.value().arg[]):
        return True
    if sx._call:
        ref args = sx._call.value().args
        for i in range(len(args)):
            if _has_other_aggregate(args[i]):
                return True
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            if _has_other_aggregate(cd.conds[i]):
                return True
        for i in range(len(cd.results)):
            if _has_other_aggregate(cd.results[i]):
                return True
        for i in range(len(cd.otherwise)):
            if _has_other_aggregate(cd.otherwise[i]):
                return True
    return False


def _extract_aggs(sx: SqlExpr, prefix: String, mut aggs: Slab[SqlExpr]) -> SqlExpr:
    """`sx` with each aggregate replaced, in pre-order, by the column
    `<prefix>a<j>` (a count by `coalesce(<prefix>a<j>, 0)`); each aggregate
    replaced is appended to `aggs`, so its index is its `j`."""
    if sx.tag == SX_AGG:
        var name = prefix + "a" + String(len(aggs))
        var is_count = sx.op == SXAGG_COUNT
        aggs.append(sx.copy())
        if not is_count:
            return SqlExpr.column(name)
        var args = Slab[SqlExpr]()
        args.append(SqlExpr.column(name))
        args.append(SqlExpr.int_lit(0))
        return SqlExpr.call(String("coalesce"), args^)
    var out = sx.copy()
    if sx._binary:
        out._binary.value().left[] = _extract_aggs(sx._binary.value().left[], prefix, aggs)
        out._binary.value().right[] = _extract_aggs(sx._binary.value().right[], prefix, aggs)
    if sx._agg:
        out._agg.value().arg[] = _extract_aggs(sx._agg.value().arg[], prefix, aggs)
    if sx._call:
        ref args = sx._call.value().args
        for i in range(len(args)):
            out._call.value().args[i] = _extract_aggs(args[i], prefix, aggs)
    if sx._case:
        ref cd = sx._case.value()
        for i in range(len(cd.conds)):
            out._case.value().conds[i] = _extract_aggs(cd.conds[i], prefix, aggs)
        for i in range(len(cd.results)):
            out._case.value().results[i] = _extract_aggs(cd.results[i], prefix, aggs)
        for i in range(len(cd.otherwise)):
            out._case.value().otherwise[i] = _extract_aggs(cd.otherwise[i], prefix, aggs)
    return out^


def _refuse(what: String) -> Error:
    return Error(String(CORR_SCALAR_REFUSAL) + " " + what)


def bind_correlated_scalar_body(
    body: SelectStmt,
    idx: Int,
    outer: _CorrOuter,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind the body of correlated scalar subquery `idx` (one that
    `scalar_body_is_correlated` holds) to the CORR_KIND_SCALAR subquery the
    header describes, or raise naming the shape it does not serve."""
    if (
        len(body.group_by) > 0 or body.having_pred or body.distinct
        or len(body.order_by) > 0 or body.limit or body.offset
    ):
        raise _refuse(
            "with GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET in its body"
        )
    if len(body.distinct_on) > 0 or body.qualify_pred:
        raise _refuse("with DISTINCT ON or QUALIFY in its body")
    for i in range(len(body.joins)):
        if body.joins[i].kind != JK_CROSS or body.joins[i].is_keyed():
            raise _refuse("whose FROM has a JOIN other than a comma or CROSS join")
    if len(body.select_items) != 1 or body.select_items[0].is_star:
        raise Error(
            "SQL bind error: a scalar subquery must project exactly one column"
        )
    ref item = body.select_items[0].expr
    if not item.contains_aggregate():
        raise _refuse(
            "whose SELECT list holds no aggregate (its value could be several rows)"
        )
    if _has_other_aggregate(item):
        raise _refuse(
            "with an aggregate other than sum, count, min, max or avg, or a window"
        )
    var inner = _build_bind_scope(body.from_tables, body.joins, catalog, cte_scope)
    if _names_outer(item, inner, outer):
        raise _refuse("with an outer column in its SELECT list")

    # The WHERE: correlation equalities apart from the inner-only conjuncts.
    var prefix = _corr_prefix(idx)
    var conjuncts = Slab[SqlExpr]()
    if body.where_pred:
        _split_and(body.where_pred.value(), conjuncts)
    var kept: Optional[SqlExpr] = None
    var key_cols = Slab[SqlExpr]()
    var outer_names = List[String]()
    for i in range(len(conjuncts)):
        ref c = conjuncts[i]
        if not _names_outer(c, inner, outer):
            if kept:
                kept = Optional(SqlExpr.binary(SXOP_AND, kept.take(), c.copy()))
            else:
                kept = Optional(c.copy())
            continue
        var is_key = False
        if c.tag == SX_BINARY and c.op == SXOP_EQ:
            var l = c._binary.value().left[].copy()
            var r = c._binary.value().right[].copy()
            if l.tag == SX_COLUMN and r.tag == SX_COLUMN:
                var l_in = _col_is_inner(l, inner, outer)
                var r_in = _col_is_inner(r, inner, outer)
                if l_in and not r_in:
                    outer_names.append(_outer_name(r, outer))
                    key_cols.append(l^)
                    is_key = True
                elif r_in and not l_in:
                    outer_names.append(_outer_name(l, outer))
                    key_cols.append(r^)
                    is_key = True
        if not is_key:
            raise _refuse(
                "whose WHERE names an outer column other than in an"
                " `inner_column = outer_column` conjunct"
            )

    # The grouped body: the keys, then the aggregates, grouped by the keys.
    var aggs = Slab[SqlExpr]()
    var value_sx = _extract_aggs(item, prefix, aggs)
    var grouped = SelectStmt()
    for i in range(len(body.from_tables)):
        grouped.from_tables.append(body.from_tables[i].copy())
    for _ in range(len(body.joins)):
        grouped.joins.append(JoinClause(JK_CROSS, None))
    grouped.where_pred = kept^
    for i in range(len(key_cols)):
        grouped.group_by.append(key_cols[i].copy())
        grouped.select_items.append(
            SelectItem(key_cols[i].copy(), Optional(prefix + "k" + String(i)), False)
        )
    for j in range(len(aggs)):
        grouped.select_items.append(
            SelectItem(aggs[j].copy(), Optional(prefix + "a" + String(j)), False)
        )
    var grouped_plan = _bind_select(grouped, catalog, cte_scope, prebound)

    # The value over the aggregate columns, and the correlation Filter.
    var schema = grouped_plan.output_schema.copy()
    var agg_scope = BindScope(List[_RelCols](), schema.copy())
    var value = _bind_scalar(value_sx, schema, agg_scope, catalog, cte_scope, prebound)
    var corr: Optional[Expr] = None
    for i in range(len(outer_names)):
        var eq = Expr.binary(
            BIN_EQ, Expr.col_ref(prefix + "k" + String(i)), Expr.left(outer_names[i])
        )
        if corr:
            corr = Optional(Expr.binary(BIN_AND, corr.take(), eq^))
        else:
            corr = Optional(eq^)
    var filtered = LogicalPlan.filter(corr.take(), grouped_plan^)
    var exprs = ExprArray()
    exprs.append(Expr.alias(value^, corr_scalar_value_name(idx)))
    var inner_plan = LogicalPlan.project(exprs^, filtered^)
    var refs = _dedup_names(outer_names)
    return Expr.correlated_subquery(inner_plan^, refs^, CORR_KIND_SCALAR)
