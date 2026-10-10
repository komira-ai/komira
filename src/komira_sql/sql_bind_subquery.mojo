# =============================================================================
# komira_sql/sql_bind_subquery.mojo
#   Scalar, EXISTS, IN and NOT IN subquery bodies.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.agg_expr import (
    AGG_COUNT, AggExpr,
)
from komira_plan_expr.corr_subquery_data import (
    CORR_KIND_EXISTS, CORR_KIND_NOT_EXISTS, CORR_KIND_SCALAR,
)
from komira_plan_expr.expr import (
    BIN_AND, BIN_EQ, BIN_OR, BIN_SUB, COL_SIDE_LEFT, EXPR_BINARY_OP, EXPR_COL_REF, Expr,
    UN_IS_NOT_NULL, UN_IS_NULL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan,
)
from komira_scan_source.source_variant import SOURCE_VARIANT_PARQUET
from komira_sql.sql_ast import (
    FromRelation, JK_FULL, JK_LEFT, JK_RIGHT, SUBQ_EXISTS, SUBQ_IN, SUBQ_NOT_IN,
    SXOP_AND, SX_AGG, SX_BINARY, SX_BOOL, SX_CALL, SX_COLUMN, SX_DATE, SX_FLOAT, SX_INT,
    SX_LIKE, SX_NULL, SX_STAR, SX_STRING, SX_SUBQUERY, SX_TIMESTAMP, SX_UNARY,
    SelectStmt, SqlExpr, TSLIT_AWARE,
)
from komira_sql.sql_bind_fn_args import _date_diff_days
from komira_sql.sql_bind_ops import (
    _map_unop, _bind_sql_operator, _bind_like, _BARE_NULL_REFUSAL, _sx_is_big_int,
    _big_int_literal_refusal, _big_int_cmp_serves, _bind_big_int_uint64,
    _is_null_comparison, _null_comparison,
)
from komira_sql.sql_bind_parquet import (
    path_has_glob, is_parquet_tvf_kind,
)
from komira_sql.sql_bind_scope import (
    CteScope, _build_bind_scope, _date_to_days, _relation_schema, _relation_scan,
    _schema_has_col,
)
from komira_sql.sql_bind_timestamp import _timestamp_literal_micros
from komira_sql.sql_binder import _bind_select
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    DSG_DATE_DIFF, FNK_DESUGAR, sql_scalar_fn_spec,
)


def _bind_scalar_subquery_body(body: SelectStmt, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """Bind one parked scalar-subquery body (SX_SUBQUERY) -> an
    `EXPR_CORRELATED_SUBQUERY` Expr of kind `CORR_KIND_SCALAR` with empty outer
    refs. Called only from `_bind_query`'s pre-bind loop, never from
    `_bind_scalar` (that back-edge would make the two mutually recursive). The
    body binds against the same catalog, CTE scope and already-bound
    lower-index subqueries (`prebound`), so `(SELECT max(x) FROM a_cte)`
    resolves the CTE and a nested subquery resolves its own (lower) index. It
    must project exactly one column.

    The body is uncorrelated: it references only its own FROM relations, never
    an outer column, which the empty `outer_refs` records."""
    var inner = _bind_select(body, catalog, cte_scope, prebound)
    if inner.output_schema.num_columns() != 1:
        raise Error(
            "SQL bind error: a scalar subquery must project exactly one column"
            + " (got " + String(inner.output_schema.num_columns()) + ")"
        )
    var empty_refs = List[String]()
    return Expr.correlated_subquery(inner^, empty_refs^, CORR_KIND_SCALAR)


# =============================================================================
# Predicate subqueries: EXISTS / NOT EXISTS / IN / NOT IN -> SEMI / ANTI
# =============================================================================


def _inner_alias_set(rel: FromRelation) -> List[String]:
    """The set of qualifiers (lower-cased) that name a correlated subquery's OWN
    single FROM relation — its AS alias and/or its base/CTE name. A `t.col` whose
    qualifier is in this set is an INNER column; any other qualifier is an outer
    reference."""
    var out = List[String]()
    if rel.rel_alias != "":
        out.append(rel.rel_alias.lower())
    if rel.name != "":
        out.append(rel.name.lower())
    return out^


@always_inline
def _alias_in(aliases: List[String], q: String) -> Bool:
    var t = q.lower()
    for i in range(len(aliases)):
        if aliases[i] == t:
            return True
    return False


def _dedup_names(names: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(names)):
        var seen = False
        for j in range(len(out)):
            if out[j] == names[i]:
                seen = True
                break
        if not seen:
            out.append(String(names[i]))
    return out^


def _bind_corr_scalar(
    sx: SqlExpr,
    inner_schema: Schema,
    inner_aliases: List[String],
    mut outer_refs: List[String],
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """Bind a correlated subquery's inner predicate. A column is inner (a plain
    col_ref, schema-checked against `inner_schema`) when its qualifier names
    the inner relation or, unqualified, it resolves in the inner schema;
    otherwise it is an outer reference: recorded in `outer_refs` and emitted
    as a bare col_ref that the optimizer's `flatten_dependent_joins` hoists
    into the SEMI / ANTI join keys (it is never resolved against the inner
    scan). Outer refs are not schema-checked here. Self-recursive only (it
    never calls `_bind_select`), so it adds no binder call cycle."""
    if sx.tag == SX_COLUMN:
        var is_inner: Bool
        if sx.qualifier != "":
            is_inner = _alias_in(inner_aliases, sx.qualifier)
        else:
            is_inner = _schema_has_col(inner_schema, sx.text)
        if is_inner:
            if not _schema_has_col(inner_schema, sx.text):
                raise Error("SQL bind error: unknown column '" + sx.text + "' in correlated subquery")
            return Expr.col_ref(sx.text)
        # OUTER reference: mark with the COL_SIDE_LEFT qualifier so the
        # optimizer's `flatten_dependent_joins` can tell it apart from an inner
        # column that shares its NAME (a self-correlated subquery — TPC-H Q21's
        # `l3.l_suppkey <> l1.l_suppkey`, where both refs are `l_suppkey`).
        # The flatten pass HOISTS every conjunct carrying a COL_SIDE_LEFT ref
        # out of the inner residual (EQ correlations become equi-keys, non-equi
        # correlations become the join residual); it is never resolved against
        # the inner scan.
        outer_refs.append(String(sx.text))
        return Expr.left(sx.text)
    if sx.tag == SX_INT:
        if _sx_is_big_int(sx):
            raise Error(_big_int_literal_refusal(sx))
        return Expr.literal(ScalarValue.from_int64(sx.int_val))
    if sx.tag == SX_FLOAT:
        return Expr.literal(ScalarValue.from_float(sx.float_val))
    if sx.tag == SX_STRING:
        return Expr.literal(ScalarValue.from_string(String(sx.text)))
    if sx.tag == SX_DATE:
        return Expr.literal(ScalarValue.date32(_date_to_days(sx.text)))
    if sx.tag == SX_TIMESTAMP:
        return Expr.literal(
            ScalarValue.timestamp_micros(
                _timestamp_literal_micros(String(sx.text), sx.op == TSLIT_AWARE)
            )
        )
    if sx.tag == SX_NULL:
        raise Error(_BARE_NULL_REFUSAL)
    if sx.tag == SX_BINARY:
        if _is_null_comparison(sx):
            if sx._binary.value().left[].tag != SX_NULL:
                return _null_comparison(sx.op, _bind_corr_scalar(sx._binary.value().left[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound))
            if sx._binary.value().right[].tag != SX_NULL:
                return _null_comparison(sx.op, _bind_corr_scalar(sx._binary.value().right[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound))
            raise Error(_BARE_NULL_REFUSAL)
        var big_cmp = _big_int_cmp_serves(sx)
        var lhs = _bind_big_int_uint64(sx._binary.value().left[]) if (
            big_cmp and _sx_is_big_int(sx._binary.value().left[])
        ) else _bind_corr_scalar(sx._binary.value().left[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound)
        var rhs = _bind_big_int_uint64(sx._binary.value().right[]) if (
            big_cmp and _sx_is_big_int(sx._binary.value().right[])
        ) else _bind_corr_scalar(sx._binary.value().right[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound)
        # An OUTER reference types as unknown against `inner_schema`, so `/`
        # falls back to the untyped door's own rule.
        return _bind_sql_operator(sx.op, lhs^, rhs^, inner_schema)
    if sx.tag == SX_BOOL:
        return Expr.literal(ScalarValue.from_bool(sx.int_val != Int64(0)))
    if sx.tag == SX_UNARY:
        return Expr.unary(
            _map_unop(sx.op),
            _bind_corr_scalar(sx._agg.value().arg[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound),
        )
    if sx.tag == SX_LIKE:
        var child = _bind_corr_scalar(sx._agg.value().arg[], inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound)
        return _bind_like(sx, child^)
    if sx.tag == SX_CALL:
        # Inside a correlated-subquery predicate the only supported call is the
        # constant-folded `date_diff` (there is no BindScope here to bind call
        # arguments against). The name is looked up in the function table, so
        # every alias of the row reaches this arm.
        var cs_spec = sql_scalar_fn_spec(sx.text)
        if cs_spec.kind == FNK_DESUGAR and cs_spec.op == DSG_DATE_DIFF:
            return Expr.literal(ScalarValue.from_int64(_date_diff_days(sx)))
        raise Error(
            "SQL not supported: scalar function '" + sx.text
            + "' inside a correlated subquery predicate"
        )
    if sx.tag == SX_SUBQUERY:
        var idx = sx.subquery_index()
        if idx < 0 or idx >= len(prebound):
            raise Error("SQL bind error: dangling subquery index in correlated subquery")
        return prebound[idx].copy()
    if sx.tag == SX_AGG:
        raise Error("SQL not supported: aggregate inside a correlated subquery predicate")
    if sx.tag == SX_STAR:
        raise Error("SQL bind error: '*' not allowed in a correlated subquery predicate")
    raise Error("SQL bind error: unsupported expression in correlated subquery")


def _single_projected_column(body: SelectStmt) raises -> String:
    """The single column an `IN`-subquery projects (its `in_rhs_col`). The
    subquery must SELECT exactly one bare column."""
    if len(body.select_items) != 1:
        raise Error("SQL bind error: an IN subquery must project exactly one column")
    ref it = body.select_items[0]
    if it.is_star or it.expr.tag != SX_COLUMN:
        raise Error("SQL bind error: an IN subquery must project a single bare column")
    return String(it.expr.text)


def _bind_correlated_subquery_body(
    body: SelectStmt,
    kind: UInt8,
    in_lhs_col: String,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    lhs_null_free: Bool = False,
) raises -> Expr:
    """Bind one parked predicate-subquery body (EXISTS / NOT EXISTS / IN /
    NOT IN) -> a correlated-subquery `Expr` (CORR_KIND_EXISTS -> SEMI /
    CORR_KIND_NOT_EXISTS -> ANTI). Called only from `_bind_query`'s pre-bind
    loop, never from `_bind_scalar` (that back-edge would make `_bind_scalar`
    and `_bind_select` mutually recursive). Builds the inner plan directly
    (not via `_bind_select`) so the inner WHERE binds qualifier-aware,
    splitting inner from outer columns; `_bind_select` would reject the outer
    refs.

    IN is unified onto EXISTS by synthesizing the membership equi
    `inner_projected_col = in_lhs_col` and folding it into the inner WHERE
    (`x IN (SELECT y FROM t WHERE p)` == `EXISTS (SELECT 1 FROM t WHERE p AND
    y = x)`); the optimizer's `flatten_dependent_joins` then hoists that equi
    into the semi join key. NOT IN is not that ANTI join alone: it is
    NULL-aware, and `_bind_null_aware_not_in` builds it.

    Restrictions: a single-table inner FROM; no GROUP BY / HAVING / ORDER BY /
    LIMIT / OFFSET / DISTINCT in the subquery body. Anything else raises."""
    if len(body.from_tables) != 1:
        raise Error("SQL not supported: a predicate subquery must have a single-table FROM")
    # `body.offset` is refused with `body.limit`: without it,
    # `x IN (SELECT y FROM t OFFSET 3)` would bind with the offset dropped.
    if (
        len(body.group_by) > 0 or body.having_pred or len(body.order_by) > 0
        or body.limit or body.offset or body.distinct
    ):
        raise Error("SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery")

    if kind == SUBQ_NOT_IN:
        return _bind_null_aware_not_in(
            body, in_lhs_col, catalog, cte_scope, prebound, lhs_null_free
        )

    ref rel = body.from_tables[0]
    var inner_schema = _relation_schema(rel, catalog, cte_scope)
    var inner_aliases = _inner_alias_set(rel)
    var scan = _relation_scan(rel, catalog, cte_scope)

    var outer_refs = List[String]()
    var where_expr: Optional[Expr] = None
    if body.where_pred:
        where_expr = _bind_corr_scalar(
            body.where_pred.value(), inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound
        )

    # IN / NOT IN: synthesize the membership equi `inner_proj = in_lhs_col`.
    # `in_lhs_col` is an OUTER column (the LHS of `x IN (...)`), so mark it
    # COL_SIDE_LEFT (consistent with `_bind_corr_scalar`'s outer refs) — the
    # flatten pass lifts this equi into the semi/anti join key.
    if kind == SUBQ_IN or kind == SUBQ_NOT_IN:
        var proj_col = _single_projected_column(body)
        var equi = Expr.binary(BIN_EQ, Expr.col_ref(proj_col), Expr.left(in_lhs_col))
        outer_refs.append(String(in_lhs_col))
        if where_expr:
            where_expr = Optional(Expr.binary(BIN_AND, where_expr.take(), equi^))
        else:
            where_expr = Optional(equi^)

    var inner_plan: LogicalPlan
    if where_expr:
        inner_plan = LogicalPlan.filter(where_expr.take(), scan^)
    else:
        inner_plan = scan^

    var uniq_refs = _dedup_names(outer_refs)
    var corr_kind: UInt8
    if kind == SUBQ_EXISTS or kind == SUBQ_IN:
        corr_kind = CORR_KIND_EXISTS
    else:
        corr_kind = CORR_KIND_NOT_EXISTS
    return Expr.correlated_subquery(inner_plan^, uniq_refs^, corr_kind)


# =============================================================================
# `x NOT IN (SELECT y ...)` is NULL-aware
# =============================================================================
#
# DuckDB v1.5.3, L(lk) = [1, 2, 4, NULL], R(rk) = [2, 3, NULL], N(nk) = [2, 3]:
#
#   lk NOT IN (SELECT rk FROM R)                        []           (a NULL rk)
#   lk NOT IN (SELECT rk FROM R WHERE rk IS NOT NULL)   [1, 4]       (NULL lk dropped)
#   lk NOT IN (SELECT nk FROM N)                        [1, 4]
#   lk NOT IN (SELECT rk FROM R WHERE rk > 100)         [1, 2, 4, NULL]  (empty: all)
#
# The bare ANTI join of `NOT EXISTS (... y = x)` would answer [1, 4, NULL] for
# the first three. Three-valued logic, stated per outer row:
#
#   x NOT IN S  is  TRUE   when S is empty, or x is not NULL and no y = x and
#                          no y is NULL;
#               is  FALSE  when some y = x;
#               is  NULL   otherwise, and a WHERE keeps only TRUE.
#
# => keep  <=>  NOT EXISTS (S: y = x)  and  S has no NULL y  and
#              (x IS NOT NULL or S is empty)
#
# Two lowerings of "S has no NULL y" / "S is empty":
#
#   Uncorrelated S: the two facts are constants for the query, so they are two
#     global-aggregate scalar subqueries compared with 0: `count(*) - count(y)`
#     (the NULL ys) and `count(*)` (the rows). An uncorrelated
#     `NOT EXISTS (SELECT 1 FROM R WHERE rk IS NULL)` would be a join with no
#     equi key.
#   Correlated S (its WHERE names an outer column): the facts vary per outer
#     row, so they are two more NOT EXISTS over the same correlated body
#     (`S AND y IS NULL` and `S AND x IS NULL`), each an ANTI join keyed on the
#     body's own equi correlation. A body correlated only by a non-equi
#     predicate (`R.rv > L.lv`) has no key for those two joins and is refused
#     by name (`_NOT_IN_NON_EQUI_REFUSAL`).
#
# When the facts are known before binding (`_rel_col_null_free`: the parquet
# null counts say y, or x, holds no NULL), the matching check is left out.
#
# `x` is the LHS column's bare name (`SubqueryDef.in_lhs_col`; the parser
# keeps no qualifier), as the membership equi uses it.


def _not_in_inner_plan(
    body: SelectStmt,
    var extra: Optional[Expr],
    mut outer_refs: List[String],
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """A FRESH `Filter(body.where AND extra, scan(body.from))` for one of the
    NOT IN lowering's sub-plans. Each call binds its own copy — plan nodes are
    move-only — and appends the body's outer references to `outer_refs`."""
    ref rel = body.from_tables[0]
    var inner_schema = _relation_schema(rel, catalog, cte_scope)
    var inner_aliases = _inner_alias_set(rel)
    var scan = _relation_scan(rel, catalog, cte_scope)
    var where_expr: Optional[Expr] = None
    if body.where_pred:
        where_expr = _bind_corr_scalar(
            body.where_pred.value(), inner_schema, inner_aliases, outer_refs, catalog, cte_scope, prebound
        )
    if extra:
        if where_expr:
            where_expr = Optional(Expr.binary(BIN_AND, where_expr.take(), extra.take()))
        else:
            where_expr = Optional(extra.take())
    if where_expr:
        return LogicalPlan.filter(where_expr.take(), scan^)
    return scan^


comptime _NOT_IN_NON_EQUI_REFUSAL = (
    "SQL not supported: `x NOT IN (SELECT y ...)` whose subquery is correlated"
    " only by a NON-EQUALITY predicate (e.g. `R.rv > L.lv`). NOT IN is"
    " NULL-aware — a NULL y, or a NULL x, changes the answer for that outer row"
    " — and this engine checks both per row with anti joins keyed on an"
    " EQUALITY correlation (`R.a = L.b`), which this subquery does not have."
    " Add one, or — if neither column can hold a NULL — write"
    " `NOT EXISTS (SELECT 1 FROM ... WHERE ... AND y = x)`, which is the same"
    " query exactly when there are no NULLs (NOT EXISTS is not NULL-aware)."
)


def _rel_col_null_free(
    rel: FromRelation, col: String, catalog: SqlCatalog, cte_scope: CteScope
) -> Bool:
    """True iff `col` of FROM relation `rel` provably holds no NULL: `rel` is a
    parquet relation (a `read_parquet('path')` TVF or a catalog parquet table,
    not a CTE / derived table) and the null count recorded before binding
    (`cte_scope.parquet`) is 0 for the column in every one of its files.
    Anything else (no recorded count, a glob, another source kind, an error)
    answers False, which only costs the NOT IN lowering its run-time NULL
    checks, never a wrong answer.

    A file-level fact: a row subset of the file (the subquery's own WHERE)
    holds no NULL if the file holds none."""
    var paths = List[String]()
    try:
        if rel.tvf_path:
            if not is_parquet_tvf_kind(rel.tvf_kind):
                return False
            paths.append(String(rel.tvf_path.value()))
        else:
            if cte_scope.find(rel.name) >= 0 or not catalog.has(rel.name):
                return False
            var t = catalog.table_of(rel.name)
            if t.source.tag != SOURCE_VARIANT_PARQUET:
                return False
            ref ps = t.source._parquet.value()
            for i in range(len(ps.paths)):
                paths.append(String(ps.paths[i]))
        if len(paths) == 0:
            return False
        var schema = _relation_schema(rel, catalog, cte_scope)
        var file_col = String("")
        for i in range(schema.num_columns()):
            if schema.field_name(i).lower() == col.lower():
                file_col = String(schema.field_name(i))
        if file_col.byte_length() == 0:
            return False
        for i in range(len(paths)):
            if path_has_glob(paths[i]):
                return False
            var nc = cte_scope.parquet.null_count(paths[i], file_col)
            if not nc or nc.value() != 0:
                return False
        return True
    except:
        return False


def _where_top_conjunct_is_subquery(e: SqlExpr, idx: Int) -> Bool:
    """`e`'s AND chain carries `SX_SUBQUERY(idx)` as a TOP-LEVEL conjunct."""
    if e.tag == SX_SUBQUERY:
        return e.subquery_index() == idx
    if e.tag == SX_BINARY and e.op == SXOP_AND:
        return _where_top_conjunct_is_subquery(
            e._binary.value().left[], idx
        ) or _where_top_conjunct_is_subquery(e._binary.value().right[], idx)
    return False


def _not_in_lhs_is_null_free(
    stmt: SelectStmt, idx: Int, col: String, catalog: SqlCatalog, cte_scope: CteScope
) -> Bool:
    """`_bind_query`'s proof that the LHS column of NOT IN subquery `idx` holds no
    NULL in the rows the WHERE sees. Only when the proof is airtight:

      * the NOT IN is a TOP-LEVEL conjunct of the statement's OWN WHERE (so its
        outer relation is `stmt.from_tables`, not a CTE / derived / nested body);
      * no OUTER join in that FROM (a null-extended side manufactures NULLs no
        file statistic records);
      * exactly ONE relation of the statement's FROM scope (`_build_bind_scope`,
        the scope the outer WHERE binds against) has an OUTPUT column named
        `col`, and that relation's SOURCE column (`k` for a join-renamed
        `k_right`) passes `_rel_col_null_free`. A relation a SEMI / ANTI join
        adds is not in that scope: its columns are not in the WHERE's input."""
    if not stmt.where_pred:
        return False
    if not _where_top_conjunct_is_subquery(stmt.where_pred.value(), idx):
        return False
    for i in range(len(stmt.joins)):
        var k = stmt.joins[i].kind
        if k == JK_LEFT or k == JK_RIGHT or k == JK_FULL:
            return False
    var owner = -1
    var src_col = String("")
    try:
        var scope = _build_bind_scope(stmt.from_tables, stmt.joins, catalog, cte_scope)
        for ri in range(len(scope.rels)):
            ref r = scope.rels[ri]
            for c in range(len(r.out)):
                if r.out[c].lower() == col.lower():
                    if owner >= 0:
                        return False
                    owner = r.rel_idx
                    src_col = String(r.orig[c])
    except:
        return False
    if owner < 0:
        return False
    return _rel_col_null_free(stmt.from_tables[owner], src_col, catalog, cte_scope)


def _expr_is_equi_correlation(e: Expr) -> Bool:
    """`e` is `<inner col> = <outer col>` (either order) — the conjunct shape
    `flatten_dependent_joins` lifts into a join KEY."""
    if e.tag != EXPR_BINARY_OP or e.binary_op() != BIN_EQ:
        return False
    ref l = e.binary_left_ref()
    ref r = e.binary_right_ref()
    if l.tag != EXPR_COL_REF or r.tag != EXPR_COL_REF:
        return False
    var ls = l.col_ref_side()
    var rs = r.col_ref_side()
    return (ls == COL_SIDE_LEFT) != (rs == COL_SIDE_LEFT)


def _conjuncts_have_equi_correlation(e: Expr) -> Bool:
    if e.tag == EXPR_BINARY_OP and e.binary_op() == BIN_AND:
        return _conjuncts_have_equi_correlation(
            e.binary_left_ref()
        ) or _conjuncts_have_equi_correlation(e.binary_right_ref())
    return _expr_is_equi_correlation(e)


def _body_has_equi_correlation(
    body: SelectStmt, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]
) raises -> Bool:
    """Does the subquery's own WHERE carry a top-level `inner = outer` conjunct?"""
    if not body.where_pred:
        return False
    ref rel = body.from_tables[0]
    var inner_schema = _relation_schema(rel, catalog, cte_scope)
    var inner_aliases = _inner_alias_set(rel)
    var refs = List[String]()
    var w = _bind_corr_scalar(
        body.where_pred.value(), inner_schema, inner_aliases, refs, catalog, cte_scope, prebound
    )
    return _conjuncts_have_equi_correlation(w)


def _count_star_scalar(var inner: LogicalPlan, out_name: String) -> Expr:
    """`(SELECT count(*) FROM <inner>)` as an UNCORRELATED scalar subquery — a
    global aggregate, so `scalar_subquery_decorrelate` proves it one row."""
    var aggs = AggExprArray()
    var none_arg: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_arg^, Optional[String](String(out_name))))
    var agg_plan = LogicalPlan.aggregate(ExprArray(), aggs^, inner^)
    var no_refs = List[String]()
    return Expr.correlated_subquery(agg_plan^, no_refs^, CORR_KIND_SCALAR)


def _null_count_scalar(var inner: LogicalPlan, col: String) -> Expr:
    """`(SELECT count(*) - count(col) FROM <inner>)` — the number of NULLs in
    `col` — as an UNCORRELATED scalar subquery.

    Counted, not filtered: the difference of two counts over one scan states
    the fact with no extra predicate on the subquery's input."""
    var aggs = AggExprArray()
    var none_arg: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_arg^, Optional[String](String("__not_in_rows"))))
    aggs.append(AggExpr(AGG_COUNT, Optional(Expr.col_ref(col)), Optional[String](String("__not_in_ys"))))
    var agg_plan = LogicalPlan.aggregate(ExprArray(), aggs^, inner^)
    var diff = ExprArray()
    diff.append(
        Expr.alias(
            Expr.binary(BIN_SUB, Expr.col_ref("__not_in_rows"), Expr.col_ref("__not_in_ys")),
            String("__not_in_null_rows"),
        )
    )
    var proj = LogicalPlan.project(diff^, agg_plan^)
    var no_refs = List[String]()
    return Expr.correlated_subquery(proj^, no_refs^, CORR_KIND_SCALAR)


def _bind_null_aware_not_in(
    body: SelectStmt,
    in_lhs_col: String,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    lhs_null_free: Bool,
) raises -> Expr:
    """`x NOT IN (SELECT y FROM r [WHERE p])` -> DuckDB's three-valued answer as
    a WHERE conjunct. See the section header for the rule and the two
    lowerings. `lhs_null_free` is `_bind_query`'s proof that x holds no NULL
    (see `_not_in_lhs_is_null_free`); y's proof is taken here."""
    var proj_col = _single_projected_column(body)
    # A fact the parquet null counts already prove is not checked at run time:
    # each check adds joins to the plan, not just a scan.
    var y_null_free = _rel_col_null_free(
        body.from_tables[0], proj_col, catalog, cte_scope
    )

    # (1) The membership ANTI join.
    var member_refs = List[String]()
    var member = _not_in_inner_plan(
        body,
        Optional(Expr.binary(BIN_EQ, Expr.col_ref(proj_col), Expr.left(in_lhs_col))),
        member_refs, catalog, cte_scope, prebound,
    )
    # `_bind_corr_scalar` appended the BODY's outer references only (the
    # synthesized equi is built here, not bound), so this is the correlation
    # test.
    var correlated = len(member_refs) > 0
    member_refs.append(String(in_lhs_col))
    var anti = Expr.correlated_subquery(
        member^, _dedup_names(member_refs), CORR_KIND_NOT_EXISTS
    )

    if y_null_free and lhs_null_free:
        # No NULL on either side: NOT IN IS the anti join, exactly.
        return anti^

    if correlated:
        # ⛔ (2) and (3) are ANTI joins with NO membership equi of their own, so
        # their only key is the body's own EQUALITY correlation. Without one
        # the engine refuses them at execution with its join-envelope text;
        # refuse BY NAME here instead, where the reason can be said.
        if not _body_has_equi_correlation(body, catalog, cte_scope, prebound):
            raise Error(_NOT_IN_NON_EQUI_REFUSAL)
        # (2) no NULL y in S(row):  NOT EXISTS (S AND y IS NULL)
        var null_refs = List[String]()
        var null_rows = _not_in_inner_plan(
            body, Optional(Expr.unary(UN_IS_NULL, Expr.col_ref(proj_col))),
            null_refs, catalog, cte_scope, prebound,
        )
        var no_null_y = Expr.correlated_subquery(
            null_rows^, _dedup_names(null_refs), CORR_KIND_NOT_EXISTS
        )
        # (3) x IS NOT NULL or S(row) is empty:  NOT EXISTS (S AND x IS NULL)
        var lhs_refs = List[String]()
        var lhs_null = _not_in_inner_plan(
            body, Optional(Expr.unary(UN_IS_NULL, Expr.left(in_lhs_col))),
            lhs_refs, catalog, cte_scope, prebound,
        )
        lhs_refs.append(String(in_lhs_col))
        var lhs_ok = Expr.correlated_subquery(
            lhs_null^, _dedup_names(lhs_refs), CORR_KIND_NOT_EXISTS
        )
        if y_null_free:
            _ = no_null_y^
            return Expr.binary(BIN_AND, anti^, lhs_ok^)
        if lhs_null_free:
            _ = lhs_ok^
            return Expr.binary(BIN_AND, anti^, no_null_y^)
        return Expr.binary(
            BIN_AND, anti^, Expr.binary(BIN_AND, no_null_y^, lhs_ok^)
        )

    # UNCORRELATED: the two facts are query-wide constants.
    var r_null = List[String]()
    var none_extra: Optional[Expr] = None
    var null_rows = _not_in_inner_plan(
        body, none_extra^, r_null, catalog, cte_scope, prebound,
    )
    var r_all = List[String]()
    var none_extra2: Optional[Expr] = None
    var all_rows = _not_in_inner_plan(
        body, none_extra2^, r_all, catalog, cte_scope, prebound,
    )
    var no_null_y = Expr.binary(
        BIN_EQ,
        _null_count_scalar(null_rows^, proj_col),
        Expr.literal(ScalarValue.from_int64(0)),
    )
    var s_empty = Expr.binary(
        BIN_EQ,
        _count_star_scalar(all_rows^, String("__not_in_rows")),
        Expr.literal(ScalarValue.from_int64(0)),
    )
    var lhs_ok = Expr.binary(
        BIN_OR, Expr.unary(UN_IS_NOT_NULL, Expr.col_ref(in_lhs_col)), s_empty^
    )
    if y_null_free:
        _ = no_null_y^
        return Expr.binary(BIN_AND, anti^, lhs_ok^)
    if lhs_null_free:
        _ = lhs_ok^
        return Expr.binary(BIN_AND, anti^, no_null_y^)
    return Expr.binary(BIN_AND, anti^, Expr.binary(BIN_AND, no_null_y^, lhs_ok^))


