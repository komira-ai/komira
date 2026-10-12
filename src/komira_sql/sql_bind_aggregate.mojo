# =============================================================================
# komira_sql/sql_bind_aggregate.mojo
#   The aggregate and the plain projection of one SELECT.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    AggExprArray, ExprArray, LogicalPlan,
)
from komira_sql.sql_ast import (
    SX_CALL, SX_COLUMN, SX_INT, SX_WINDOW, SelectStmt, sql_call_is_aggregate,
)
from komira_sql.sql_bind_agg_expr import (
    _bind_agg_from_sx, _bind_agg_from_sx_call, _extract_and_bind_post_agg,
)
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_names import (
    _group_has, _duckdb_expr_text, _unaliased_agg_out_name, _select_alias_index,
    _canon_index, _gb_const_canon,
)
from komira_sql.sql_bind_ops import _sx_is_big_int
from komira_sql.sql_bind_scope import (
    CteScope, _schema_has_col, BindScope, _resolve_col,
)
from komira_sql.sql_catalog import SqlCatalog


def _bind_aggregate(stmt: SelectStmt, schema: Schema, scope: BindScope, var child: LogicalPlan, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr], order_names: List[String], mut order_carry: List[String], order_expr_idx: List[Int], order_expr_names: List[String]) raises -> LogicalPlan:
    """Build AGGREGATE(group_by, aggs) then a reorder Project that emits the
    columns in SELECT order / names, so aggregates may appear in any position
    in the SELECT list and GROUP BY columns need not all be selected."""
    # =======================================================================
    # GROUP BY resolution: one question with four spellings.
    # =======================================================================
    #
    # A GROUP BY item may be an ordinal (`GROUP BY 1`), a SELECT alias
    # (`k AS kk ... GROUP BY kk`), a plain column, or an arbitrary expression
    # (`GROUP BY client_ip - 1`). The first two reduce to the last two: each
    # resolves to a SELECT item's expression and then takes the path that
    # expression would have taken.
    #
    # Precedence: an input column beats a SELECT alias. DuckDB v1.5.3 and
    # PostgreSQL agree ("in case of ambiguity, a GROUP BY name will be
    # interpreted as an input-column name rather than an output column name"):
    #
    #     SELECT k AS g, sum(v) FROM t GROUP BY g      -- `t` has a column `g`
    #     Binder Error: column "k" must appear in the GROUP BY clause ...
    #
    # So the alias table is consulted only for a name no input column answers.
    #
    # An integer literal is an ordinal, and only a bare one is: `GROUP BY 1+1`
    # is an expression (DuckDB groups by the constant 2), so the test is on the
    # tag `SX_INT`. `-1` also arrives as `SX_INT` (the parser folds unary minus
    # into the literal), which is why the range check covers the negative side.
    #
    # A group key reaches the aggregate as a bare `col_ref`: a computed key is
    # materialised by a Project spliced below the aggregate and the key becomes
    # a `col_ref` to that synthetic column. The Project is spliced only when
    # something needs it (`len(derived) > 0`), so a plain grouped aggregate
    # stays directly over its input.
    #
    # Constant group-key elision: a group key that is a literal constant
    # partitions nothing (every row carries the same value), so it is removed
    # from the grouping. DuckDB v1.5.3 over `t(k,v,g,o)`:
    #
    #     SELECT k, count(*) FROM t GROUP BY k, 'x' ORDER BY k; -> (1,2)(2,1)(3,1)
    #
    # is the same as `GROUP BY k`. Removing the key also keeps a computed
    # constant out of the plan (`SELECT 1, URL, COUNT(*) ... GROUP BY 1, URL`
    # groups by URL alone).
    #
    # The all-constant case is not a zero-key aggregate, which is why this is
    # guarded by `n_other > 0`. DuckDB v1.5.3:
    #
    #     SELECT 1 AS lit, count(*) AS c FROM t WHERE k > 999 GROUP BY 1; -> 0 rows
    #     SELECT count(*) AS c FROM t WHERE k > 999;                      -> 1 row (0)
    #
    # An empty input has no groups, so a GROUP BY emits nothing, where a 0-key
    # aggregate emits one row. So the elision fires only when a non-constant
    # key survives, and `group_by` is then non-empty (constants `continue`
    # before step (3), so they never enter `group_canon`).
    #
    # An elided key that a SELECT item names is re-projected, not dropped (the
    # `const_canon` arm in the SELECT-list loop below): `SELECT 1, url,
    # count(*)` still emits that literal as column 0 named `1`, as
    # `DESCRIBE SELECT 1, k, count(*) AS c FROM t GROUP BY 1, k` does in DuckDB.
    var const_canon = List[String]()   # elided constant keys, by canonical form
    var const_is_col = List[Bool]()    # always False — a constant is never a column name
    var n_const = 0
    var n_other = 0
    for i in range(len(stmt.group_by)):
        if _gb_const_canon(stmt, stmt.group_by[i], schema).byte_length() > 0:
            n_const += 1
        else:
            n_other += 1
    var elide_constants = n_const > 0 and n_other > 0

    var group_by = ExprArray()
    var group_names = List[String]()   # the AGGREGATE's own output name per key
    var group_canon = List[String]()   # the key's canonical source form, for SELECT matching
    var group_is_col = List[Bool]()    # True: `group_canon[i]` is a column name
    var derived = ExprArray()          # computed keys, aliased to their synthetic names

    for i in range(len(stmt.group_by)):
        ref gsx = stmt.group_by[i]

        # (0) A literal constant key is elided (see above). Recorded by
        # canonical form so the SELECT-list loop can still answer an item that
        # names it, and deduped as step (3) dedups.
        if elide_constants:
            var ccanon = _gb_const_canon(stmt, gsx, schema)
            if ccanon.byte_length() > 0:
                if _canon_index(const_canon, const_is_col, ccanon, False) < 0:
                    const_canon.append(ccanon^)
                    const_is_col.append(False)
                continue

        # (1) ORDINAL / ALIAS -> a SELECT item index, if this item is one.
        var sel = -1
        if gsx.tag == SX_INT:
            if _sx_is_big_int(gsx):
                # `GROUP BY 18446744073709551617` would group by ordinal 1
                # (the wrapped bits); DuckDB 1.5.3 raises.
                raise Error(
                    "SQL bind error: the GROUP BY ordinal " + gsx.text
                    + " is out of range for BIGINT (DuckDB v1.5.3 raises a"
                    " Conversion Error: the value is out of range for the"
                    " destination type INT64)"
                )
            var ordn = Int(gsx.int_val)
            if ordn < 1 or ordn > len(stmt.select_items):
                raise Error(
                    "SQL bind error: GROUP BY term out of range - should be"
                    + " between 1 and " + String(len(stmt.select_items))
                )
            sel = ordn - 1
        elif gsx.tag == SX_COLUMN and gsx.qualifier == "" and not _schema_has_col(schema, gsx.text):
            sel = _select_alias_index(stmt, gsx.text)
            # sel == -1 here means neither an input column nor an alias; the
            # plain-column arm below then raises the ordinary unknown-column
            # error, which is the diagnostic that names the actual problem.

        # (2) Take the effective expression's own path.
        var gname: String
        var gcanon: String
        var gis_col: Bool
        if sel >= 0:
            ref it = stmt.select_items[sel]
            if it.is_star:
                raise Error("SQL bind error: GROUP BY term names a '*' SELECT item")
            if it.expr.contains_aggregate():
                # DuckDB: `GROUP BY clause cannot contain aggregates!` (the
                # group keys would depend on the groups).
                raise Error("SQL bind error: GROUP BY clause cannot contain aggregates")
            if it.expr.tag == SX_WINDOW:
                raise Error("SQL bind error: GROUP BY clause cannot contain window functions")
            if it.expr.tag == SX_COLUMN:
                gname = _resolve_col(it.expr, schema, scope)
                gcanon = String(gname)
                gis_col = True
            else:
                gname = String("__grp_key_") + String(len(derived))
                gcanon = _duckdb_expr_text(it.expr)
                gis_col = False
                var ge = _bind_scalar(it.expr, schema, scope, catalog, cte_scope, prebound)
                derived.append(Expr.alias(ge^, gname))
        elif gsx.tag == SX_COLUMN:
            gname = _resolve_col(gsx, schema, scope)
            gcanon = String(gname)
            gis_col = True
        else:
            if gsx.contains_aggregate():
                raise Error("SQL bind error: GROUP BY clause cannot contain aggregates")
            if gsx.tag == SX_WINDOW:
                raise Error("SQL bind error: GROUP BY clause cannot contain window functions")
            gname = String("__grp_key_") + String(len(derived))
            gcanon = _duckdb_expr_text(gsx)
            gis_col = False
            var ge2 = _bind_scalar(gsx, schema, scope, catalog, cte_scope, prebound)
            derived.append(Expr.alias(ge2^, gname))

        # (3) A repeated key is one key: DuckDB accepts `GROUP BY 1, 1` and
        # `GROUP BY k, k` and groups once. Emitting the key twice would put
        # two identically named columns in the aggregate's output schema.
        if _canon_index(group_canon, group_is_col, gcanon, gis_col) >= 0:
            continue
        group_by.append(Expr.col_ref(gname))
        group_names.append(String(gname))
        group_canon.append(gcanon^)
        group_is_col.append(gis_col)

    # Aggregates (in SELECT order among aggs), each forced to a unique output
    # name; plus the final post-aggregate projection (in SELECT order). A
    # SELECT item may be a bare aggregate call, a bare GROUP BY column, or a
    # scalar expression that contains aggregates (`100.0*sum(a)/sum(b)`,
    # `max(v1)-min(v2)`).
    var agg_exprs = AggExprArray()
    var proj = ExprArray()
    var proj_names = List[String]()  # output name of each `proj` entry, in order
    var agg_out_names = List[String]()  # bare-agg output aliases (for HAVING refs)
    var no_agg_refs = List[String]()  # SELECT items can't reference sibling aliases
    var agg_counter = 0
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            raise Error("SQL not supported: SELECT * with aggregation")
        # A bare aggregate SELECT item, on either grammar: `is_aggregate()` is
        # `tag == SX_AGG` (true for `sum(q)`), while `median(q)` is an
        # `SX_CALL`. Both name their output column by the DuckDB deparse
        # (`_unaliased_agg_out_name`). Nested aggregates (`sqrt(var_samp(q))`,
        # `sum(a) > 10`) take the arm below and hoist under hidden names.
        var item_is_call_agg = (
            item.expr.tag == SX_CALL and sql_call_is_aggregate(item.expr.text)
        )
        if item.expr.is_aggregate() or item_is_call_agg:
            # Bare aggregate call — name it by its alias (or a positional name)
            # and project a col_ref to it.
            var nm: String
            if item.out_alias:
                nm = String(item.out_alias.value())
            else:
                nm = _unaliased_agg_out_name(item.expr, group_names, agg_out_names)
            # An aggregate aliased with a group key's name: the AGGREGATE
            # node's output is [keys..., aggs...], so `SELECT g AS gg, count(*)
            # AS g ... GROUP BY g` would make [g, g] and the col_ref below
            # would resolve to the key. Such an aggregate is computed under an
            # internal name and aliased back at the reorder Project (the window
            # path's rule for the same collision). DuckDB's binding of the name
            # is matched: `HAVING g` and `ORDER BY g + 0` read the group column,
            # `ORDER BY g` the output alias.
            var agg_nm = String(nm)
            if _group_has(group_names, nm):
                agg_nm = String("_agg_as_") + String(i) + String("_") + nm
            if item_is_call_agg:
                agg_exprs.append(_bind_agg_from_sx_call(item.expr, schema, scope, agg_nm, catalog, cte_scope, prebound))
            else:
                agg_exprs.append(_bind_agg_from_sx(item.expr, schema, scope, agg_nm, catalog, cte_scope, prebound))
            agg_out_names.append(String(agg_nm))
            if agg_nm == nm:
                proj.append(Expr.col_ref(nm))
            else:
                proj.append(Expr.alias(Expr.col_ref(agg_nm), nm))
            proj_names.append(String(nm))
        elif item.expr.contains_aggregate():
            # Scalar expression containing aggregate(s): extract the aggregates
            # into hidden agg outputs and build the residual arithmetic Project.
            var e = _extract_and_bind_post_agg(
                item.expr, schema, scope, group_names, no_agg_refs, agg_exprs, agg_counter, catalog, cte_scope, prebound
            )
            if item.out_alias:
                proj_names.append(String(item.out_alias.value()))
                e = Expr.alias(e^, item.out_alias.value())
            else:
                proj_names.append(_duckdb_expr_text(item.expr))
            proj.append(e^)
        else:
            # Bare non-aggregate SELECT item — must name a GROUP BY key.
            # Ask "is this item one of the group keys?" first, the same way
            # for every tag (a plain column is the case where the canonical
            # form is a name). The group-key match runs first, the trial bind
            # second and the GROUP BY refusal last, so an unresolvable name is
            # reported as itself rather than told to join GROUP BY.
            var item_canon: String
            var item_is_col: Bool
            if item.expr.tag == SX_COLUMN:
                item_canon = _resolve_col(item.expr, schema, scope) if item.expr.qualifier != "" else String(item.expr.text)
                item_is_col = True
            else:
                item_canon = _duckdb_expr_text(item.expr)
                item_is_col = False
            var gi = _canon_index(group_canon, group_is_col, item_canon, item_is_col)

            # An elided constant key is answered by the literal itself: the key
            # left the grouping (step (0)) because it partitions nothing, but
            # the SELECT list still emits it in place (`SELECT 1, url,
            # count(*)` keeps column 0, named `1`), bound through the same
            # `_bind_scalar` over the same node, with its alias honoured.
            # `not item_is_col`: `const_canon` holds expression canonical
            # forms, compared case-sensitively (a string literal's case is
            # data); a column item is never matched against them.
            if gi < 0 and not item_is_col:
                if _canon_index(const_canon, const_is_col, item_canon, False) >= 0:
                    var cout: String
                    if item.out_alias:
                        cout = String(item.out_alias.value())
                    else:
                        cout = item_canon.copy()
                    var clit = _bind_scalar(
                        item.expr, schema, scope, catalog, cte_scope, prebound
                    )
                    proj_names.append(String(cout))
                    proj.append(Expr.alias(clit^, cout))
                    continue

            if gi < 0:
                if item.expr.tag != SX_COLUMN:
                    # Ask whether the item can be bound at all before naming
                    # GROUP BY: an unresolvable call (`nosuchfn(v)`, a refused
                    # function, `covar_pop(a, b)` declined by every table) is
                    # not an aggregate and lands here, and its own error is the
                    # true one. The trial bind uses the one resolver that knows
                    # every namespace (builtins, refusal rows, declared UDFs).
                    # A bind that succeeds (`a + 1`, `sqrt(x)`, a literal)
                    # falls through to the GROUP BY refusal. A top-level window
                    # item cannot reach here: `_bind_select` routes those to
                    # `_bind_window_projection`.
                    var _probe = _bind_scalar(item.expr, schema, scope, catalog, cte_scope, prebound)
                    _ = _probe^
                    raise Error("SQL not supported: non-aggregate SELECT item must be a GROUP BY column")
                raise Error(
                    "SQL bind error: SELECT column '" + item_canon
                    + "' must appear in GROUP BY"
                )

            # The output name is the item's (its alias), not the key's:
            # `SELECT k AS kk, count(*) FROM t GROUP BY k` returns `kk`.
            var outn: String
            if item.out_alias:
                outn = String(item.out_alias.value())
            else:
                outn = item_canon.copy()
            proj_names.append(String(outn))
            if outn == group_names[gi]:
                # An alias to the name the column already has is a no-op the
                # plan text would still print. Emitting the bare `col_ref` keeps
                # every pre-existing plan byte-identical.
                proj.append(Expr.col_ref(group_names[gi]))
            else:
                proj.append(Expr.alias(Expr.col_ref(group_names[gi]), outn))

    # HAVING: a FILTER over the aggregate output (group cols + agg outputs). An
    # aggregate call appearing only in HAVING (`HAVING count(*) > 100`) is
    # extracted into a hidden aggregate (added to `agg_exprs`, omitted from the
    # reorder Project) so it filters without surfacing.
    var having_expr: Optional[Expr] = None
    if stmt.having_pred:
        having_expr = _extract_and_bind_post_agg(
            stmt.having_pred.value(), schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
        )

    # ORDER BY a group key that is not selected: DuckDB v1.5.3 accepts
    # `SELECT k, sum(v) FROM t GROUP BY k, g ORDER BY g` and orders by `g`.
    # The reorder Project drops `g`, so it is carried here and pruned again
    # above the LIMIT by `_bind_select`. Only a group key may be carried: the
    # rows reaching the sort are groups, and an ungrouped column has no value
    # there (DuckDB refuses `... GROUP BY k ORDER BY v`, and so does this:
    # the key is not found, and `_bind_order` reports the unknown column).
    for n in range(len(order_names)):
        ref onm = order_names[n]
        if _group_has(proj_names, onm):
            continue
        if _group_has(order_carry, onm):
            continue
        var ki = _canon_index(group_canon, group_is_col, onm, True)
        if ki < 0:
            continue
        proj.append(Expr.col_ref(group_names[ki]))
        proj_names.append(String(onm))
        order_carry.append(String(onm))

    # An ORDER BY expression (`ORDER BY count(*) DESC`, `ORDER BY sum(a) + 1`)
    # that no SELECT item answers: bound through the post-aggregate extractor,
    # so an aggregate inside it is hoisted into a hidden output as a HAVING
    # term's is (DuckDB v1.5.3 orders `SELECT g FROM t GROUP BY g ORDER BY
    # count(*) DESC, g` by the unselected count), then carried and pruned like
    # a group key.
    for t in range(len(order_expr_idx)):
        var oe = _extract_and_bind_post_agg(
            stmt.order_by[order_expr_idx[t]].expr, schema, scope, group_names, agg_out_names, agg_exprs, agg_counter, catalog, cte_scope, prebound
        )
        proj.append(Expr.alias(oe^, order_expr_names[t]))
        proj_names.append(String(order_expr_names[t]))
        order_carry.append(String(order_expr_names[t]))

    # Splice the materialize-Project for computed group keys. Passthroughs carry
    # every input column, because the aggregates' own inputs still resolve by
    # name against this Project's output.
    if len(derived) > 0:
        var pass_names = List[String]()
        for c in range(child.output_schema.num_columns()):
            pass_names.append(String(child.output_schema.field_name(c)))
        var pexprs = ExprArray()
        for c in range(len(pass_names)):
            pexprs.append(Expr.col_ref(pass_names[c]))
        for d in range(len(derived)):
            pexprs.append(derived[d].copy())
        child = LogicalPlan.project(pexprs^, child^)

    var agg_plan = LogicalPlan.aggregate(group_by^, agg_exprs^, child^)

    # HAVING filter applied BELOW the reorder Project so it filters the breaker
    # directly (the hidden HAVING agg is present here, dropped by the Project).
    var after_having: LogicalPlan
    if having_expr:
        after_having = LogicalPlan.filter(having_expr.take(), agg_plan^)
    else:
        after_having = agg_plan^

    return LogicalPlan.project(proj^, after_having^)


def _bind_projection(stmt: SelectStmt, schema: Schema, scope: BindScope, var child: LogicalPlan, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr], order_names: List[String], mut order_carry: List[String], order_expr_idx: List[Int], order_expr_names: List[String]) raises -> LogicalPlan:
    """The SELECT list as a Project, WIDENED by any ORDER BY column the list
    does not already produce.

    Widen, sort, prune (the prune is `_bind_select`'s): `LogicalPlan.sort`
    takes key names, so a key must be a column of the sort's input, which
    after this Project is the SELECT list. `SELECT v FROM t ORDER BY k`
    therefore carries `k` down to the sort; carried columns are appended at
    the end, so the prune drops the last `len(order_carry)` columns.

    An alias the projection already answers is not widened for: DuckDB v1.5.3
    orders `SELECT v AS k FROM t ORDER BY k DESC` by the alias, not by the
    table column `k`, which the `_group_has(out_names, onm)` test keeps.
    """
    # SELECT * -> pass the child through unchanged. Every input column is
    # present, so no ORDER BY COLUMN key can be missing and nothing is carried.
    # ⚠ An ORDER BY EXPRESSION (`SELECT * FROM t ORDER BY -k`) is the one
    # thing a star still has to widen for: every column, then the hidden key.
    if len(stmt.select_items) == 1 and stmt.select_items[0].is_star:
        if len(order_expr_idx) == 0:
            return child^
        var sexprs = ExprArray()
        for c in range(child.output_schema.num_columns()):
            sexprs.append(Expr.col_ref(child.output_schema.field_name(c)))
        for t in range(len(order_expr_idx)):
            var se = _bind_scalar(stmt.order_by[order_expr_idx[t]].expr, schema, scope, catalog, cte_scope, prebound)
            sexprs.append(Expr.alias(se^, order_expr_names[t]))
            order_carry.append(String(order_expr_names[t]))
        return LogicalPlan.project(sexprs^, child^)
    var exprs = ExprArray()
    var out_names = List[String]()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            raise Error("SQL not supported: '*' mixed with other SELECT items")
        var e = _bind_scalar(item.expr, schema, scope, catalog, cte_scope, prebound)
        if item.out_alias:
            out_names.append(String(item.out_alias.value()))
            e = Expr.alias(e^, item.out_alias.value())
        elif item.expr.tag == SX_COLUMN:
            out_names.append(String(item.expr.text))
        else:
            # A deparsed expression name can never collide with a bare column
            # name an ORDER BY key could spell, so an approximate answer here is
            # still an exact answer to the only question asked of it.
            out_names.append(_duckdb_expr_text(item.expr))
        exprs.append(e^)

    for n in range(len(order_names)):
        ref onm = order_names[n]
        if _group_has(out_names, onm):
            continue
        if _group_has(order_carry, onm):
            continue
        if not _schema_has_col(schema, onm):
            # Not an input column either — leave it to `_bind_order`, whose
            # "unknown ORDER BY column" names the actual problem.
            continue
        exprs.append(Expr.col_ref(onm))
        out_names.append(String(onm))
        order_carry.append(String(onm))

    # An ORDER BY expression no SELECT item answers: computed over the input,
    # carried as a hidden column, pruned by `_bind_select` step 6. In DuckDB
    # v1.5.3 an identifier inside an ORDER BY expression is the input column
    # even where a SELECT alias shares its name (`SELECT a AS k, k AS a FROM t
    # ORDER BY -k` orders by the input `k`, while a bare `ORDER BY k` names the
    # alias), which is what binding over `schema` does. An alias-only name is
    # refused before this (`_order_expr_alias_ref`).
    for t in range(len(order_expr_idx)):
        var oe = _bind_scalar(stmt.order_by[order_expr_idx[t]].expr, schema, scope, catalog, cte_scope, prebound)
        exprs.append(Expr.alias(oe^, order_expr_names[t]))
        out_names.append(String(order_expr_names[t]))
        order_carry.append(String(order_expr_names[t]))

    return LogicalPlan.project(exprs^, child^)


