# =============================================================================
# komira_sql/sql_binder.mojo
#   The binder's entry: a parsed `SqlStatement` to a `BoundStatement` holding
#   a `LogicalPlan`.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    ExprArray, JOIN_CROSS, LogicalPlan,
)
from komira_sql.sql_ast import (
    FROM_LESS_RELATION, JK_ANTI, JK_CROSS, JK_FULL, JK_LEFT, JK_RIGHT, JK_SEMI,
    STMT_COPY, STMT_CREATE_TABLE_AS, STMT_QUERY, SUBQ_DERIVED, SUBQ_NOT_IN, SUBQ_SCALAR,
    SUBQ_UNION_ALL, SX_COLUMN, SelectStmt, SqlStatement,
)
from komira_sql.sql_bind_aggregate import (
    _bind_aggregate, _bind_projection,
)
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_join import (
    _outer_join_kw, _bind_outer_join, _bind_keyed_join, _bind_semi_anti_join,
)
from komira_sql.sql_bind_parquet import (
    collect_parquet_facts, SqlParquetFooters,
)
from komira_sql.sql_bind_scope import (
    CteScope, _relation_scan, _build_bind_scope, _dedupe_join_right,
    _result_display_names, _result_rename_exprs, _visible_qualifiers,
)
from komira_sql.sql_bind_subquery import (
    _bind_scalar_subquery_body, _bind_correlated_subquery_body,
    _not_in_lhs_is_null_free, _in_lhs_output_name,
)
from komira_sql.sql_bind_window_order import (
    _has_window, _bind_window_projection, _order_key_name, _OK_COLUMN, _OK_OUTPUT,
    _classify_order_keys, _order_output_column, _bind_order,
)
from komira_sql.sql_catalog import SqlCatalog
from std.memory import OwnedPointer


struct BoundStatement(Movable):
    """The bound result of a top-level statement: the source/query
    `LogicalPlan` plus what the caller does with it.

      - STMT_QUERY            -> run the plan and return its rows.
      - STMT_COPY             -> run the plan and write it to `dest_path` in
                                 format `fmt` with compression `codec`.
      - STMT_CREATE_TABLE_AS  -> run the plan and register its rows under
                                 `register_as`.

    Fields:
        kind        - the STMT_* code.
        _plan       - the source/query `LogicalPlan`, moved out by `take_plan()`
                      (held in an `Optional` so the move-out is
                      `Optional.take()`).
        dest_path   - the STMT_COPY destination path ("" otherwise).
        fmt         - the WFMT_* write format (STMT_COPY).
        codec       - the WCOMP_* write compression (STMT_COPY).
        register_as - the STMT_CREATE_TABLE_AS table name ("" otherwise).

    Move-only (it holds a move-only `LogicalPlan`)."""

    var kind: UInt8
    var _plan: Optional[LogicalPlan]
    var dest_path: String
    var fmt: UInt8
    var codec: UInt8
    var register_as: String

    def __init__(
        out self,
        kind: UInt8,
        var plan: LogicalPlan,
        dest_path: String,
        fmt: UInt8,
        codec: UInt8,
        register_as: String,
    ):
        self.kind = kind
        self._plan = Optional[LogicalPlan](plan^)
        self.dest_path = dest_path
        self.fmt = fmt
        self.codec = codec
        self.register_as = register_as

    def take_plan(mut self) -> LogicalPlan:
        """Move the source/query `LogicalPlan` out (leaving `_plan` empty)."""
        return self._plan.take()


def bind_statement[P: SqlParquetFooters](
    stmt: SqlStatement, catalog: SqlCatalog, footers: P
) raises -> BoundStatement:
    """Bind a parsed top-level `SqlStatement` against `catalog` -> a
    `BoundStatement`. The parquet facts the statement needs are read first,
    through `footers` (`collect_parquet_facts`); binding itself opens no
    parquet file (a `read_csv`, `read_json` or `read_avro` relation reads its
    file through `sql_tvf_bind` while it binds).
    Every kind binds its query through the same path, so a COPY / CTAS source
    takes the whole SELECT grammar.

    A COPY with no destination, or a CTAS with no target name, is a bind error
    (the parser already refuses both)."""
    var cte_scope = CteScope(collect_parquet_facts(stmt, catalog, footers))
    # Only a query's result carries DuckDB's duplicate-keeping names
    # (`_result_display_names`); a COPY / CTAS writes a table, whose columns
    # DuckDB de-duplicates instead, so those keep the plan's own names.
    var plan = _bind_query(
        stmt.query, catalog, cte_scope, stmt.kind == STMT_QUERY
    )
    if stmt.kind == STMT_COPY:
        if stmt.dest_path == "":
            raise Error("SQL bind error: COPY ... TO requires a destination path")
        return BoundStatement(
            STMT_COPY, plan^, stmt.dest_path, stmt.fmt, stmt.codec, String("")
        )
    if stmt.kind == STMT_CREATE_TABLE_AS:
        if stmt.target_table == "":
            raise Error("SQL bind error: CREATE TABLE AS requires a target table name")
        return BoundStatement(
            STMT_CREATE_TABLE_AS, plan^, String(""), stmt.fmt, stmt.codec,
            stmt.target_table,
        )
    return BoundStatement(STMT_QUERY, plan^, String(""), stmt.fmt, stmt.codec, String(""))


def _bind_query(
    stmt: SelectStmt,
    catalog: SqlCatalog,
    mut cte_scope: CteScope,
    result_names: Bool,
) raises -> LogicalPlan:
    """Bind a parsed `SelectStmt` (its `WITH` CTEs, its subqueries and the
    final SELECT) against `catalog` -> a `LogicalPlan`.

    Each `WITH` definition is bound in order into `cte_scope` (each against the
    CTEs before it), then the final SELECT is bound with that scope in hand: a
    FROM relation naming a CTE inlines a copy of its bound subplan."""
    # Scalar subqueries are pre-bound here, before any expression binding,
    # into a flat `prebound` list that `_bind_scalar` looks up by index.
    # Binding a subquery body from inside `_bind_scalar` would make
    # `_bind_scalar` and `_bind_select` mutually recursive, a shape the Mojo
    # compiler hangs on. The flat `stmt.subqueries` table is in
    # inner-before-outer parse order, so index-order pre-binding binds a nested
    # subquery (lower index) before the outer one that references it.
    var prebound = List[Expr]()

    # CTE bodies bind first (into the CTE scope), against the CTEs before them.
    # They bind with the still-empty `prebound`: a scalar subquery inside a CTE
    # body names an index `prebound` does not hold yet, and raises instead of
    # mis-binding.
    for i in range(len(stmt.ctes)):
        ref cte = stmt.ctes[i]
        if cte_scope.has(cte.name):
            raise Error("SQL bind error: duplicate CTE name '" + cte.name + "'")
        var body_plan = _bind_select(cte.body, catalog, cte_scope, prebound)
        cte_scope.add(cte.name, body_plan^)

    # Pre-bind every subquery body in index order (inner-before-outer), each
    # dispatching on its `SubqueryDef.kind`. Each entry pushes exactly one slot
    # into `prebound` so the list stays INDEX-ALIGNED with `stmt.subqueries` (an
    # `SX_SUBQUERY` node looks the Expr up by that index). A DERIVED table pushes
    # an unreferenced placeholder (its result is a subplan registered in the CTE
    # scope, not an Expr). Each may reference the CTE scope + the already-bound
    # lower-index subqueries (a nested subquery has a lower index than the outer
    # one that contains it — the parser appends inner-before-outer).
    for i in range(len(stmt.subqueries)):
        ref sd = stmt.subqueries[i]
        if sd.kind == SUBQ_DERIVED:
            # `derived_alias` is the relation key `<alias>#<index>`
            # (`_Parser._parse_derived_table`): unique per derived table and
            # never a CTE or catalog name, so registering it hides nothing.
            var dplan = _bind_select(sd.body, catalog, cte_scope, prebound)
            # Column-list rename `(SELECT ...) d (c1, c2, ...)` (TPC-H q13 shape):
            # positionally rename the derived body's output columns to the given
            # names via a projection of `col_ref(orig) AS new`. The list length
            # MUST equal the body's output column count (standard SQL). Registered
            # under the key so downstream FROM references resolve the new names.
            if len(sd.col_names) > 0:
                var ncols = dplan.output_schema.num_columns()
                if len(sd.col_names) != ncols:
                    var hash_at = sd.derived_alias.find("#")
                    raise Error(
                        "SQL bind error: derived-table '"
                        + String(sd.derived_alias[byte=0:hash_at])
                        + "' column list has " + String(len(sd.col_names))
                        + " names but its SELECT produces " + String(ncols)
                        + " columns"
                    )
                var rename = ExprArray()
                for ci in range(ncols):
                    var orig = String(dplan.output_schema.field_name(ci))
                    rename.append(Expr.alias(Expr.col_ref(orig), sd.col_names[ci]))
                dplan = LogicalPlan.project(rename^, dplan^)
            cte_scope.add(sd.derived_alias, dplan^)
            prebound.append(Expr.literal(ScalarValue.from_int64(0)))  # placeholder
        elif sd.kind == SUBQ_UNION_ALL:
            # ★ SQL-UNION-ALL: a BRANCH, not an operand. It binds to a PLAN,
            # which no `prebound` slot can hold, so it pushes the same
            # unreferenced placeholder SUBQ_DERIVED does and is bound below —
            # AFTER the left-hand SELECT, so both branches see the same CTE
            # scope and the same already-bound lower-index subqueries.
            #
            # ⚠ THE PLACEHOLDER IS NOT OPTIONAL: `prebound` must stay
            # INDEX-ALIGNED with `stmt.subqueries`, and an `SX_SUBQUERY` node
            # anywhere in the query looks its Expr up by that index.
            prebound.append(Expr.literal(ScalarValue.from_int64(0)))  # placeholder
        elif sd.kind == SUBQ_SCALAR:
            var sq = _bind_scalar_subquery_body(sd.body, catalog, cte_scope, prebound)
            prebound.append(sq^)
        else:
            # `in_lhs` is "" for EXISTS / NOT EXISTS (no left column).
            var in_lhs = _in_lhs_output_name(stmt, i, catalog, cte_scope)
            var lhs_null_free = False
            if sd.kind == SUBQ_NOT_IN:
                lhs_null_free = _not_in_lhs_is_null_free(
                    stmt, i, in_lhs, catalog, cte_scope
                )
            var pred = _bind_correlated_subquery_body(
                sd.body, sd.kind, in_lhs, catalog, cte_scope, prebound,
                lhs_null_free,
            )
            prebound.append(pred^)

    var head = _bind_select(stmt, catalog, cte_scope, prebound, result_names)
    if stmt.union_all_idx < 0:
        return head^
    return _bind_union_all_chain(
        head^, stmt, stmt.union_all_idx, catalog, cte_scope, prebound
    )


def _union_branch_schema_check(lhs: Schema, rhs: Schema, branch: Int) raises:
    """Every UNION ALL branch must advertise the leading branch's schema.

    `LogicalPlan.union` leaves that to its caller (it does not coerce), so
    this check is the contract. DuckDB v1.5.3 coerces branches to a common
    type (`SELECT 1 UNION ALL SELECT 1.5` is DOUBLE there); this refuses,
    because the alternative is two branches of different physical width under
    one schema. Cast the branches to a common type explicitly.
    """
    if lhs.num_columns() != rhs.num_columns():
        raise Error(
            "SQL bind error: UNION ALL branch " + String(branch) + " produces "
            + String(rhs.num_columns()) + " column(s) but the first branch"
            " produces " + String(lhs.num_columns())
            + ". Every branch of a UNION ALL must produce the same number of"
            " columns, in the same order."
        )
    for i in range(lhs.num_columns()):
        if lhs.field_arrow_type(i) != rhs.field_arrow_type(i):
            raise Error(
                "SQL not supported: UNION ALL over branches whose column "
                + String(i + 1) + " differs in TYPE — the first branch has "
                + String(lhs.field_arrow_type(i)) + " and branch "
                + String(branch) + " has " + String(rhs.field_arrow_type(i))
                + ". ⚠ DuckDB v1.5.3 COERCES the branches to a common type"
                " here; this engine's PLAN_UNION node does not coerce (it"
                " concatenates batches that must already share a schema), so"
                " admitting the query would hand the executor two different"
                " physical layouts under one advertised schema and return"
                " reinterpreted bytes rather than an error. CAST both branches"
                " to the same type explicitly."
            )


def _bind_union_all_chain(
    var head: LogicalPlan,
    stmt: SelectStmt,
    first_idx: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """`<select> UNION ALL <select> [UNION ALL ...]` -> one `PLAN_UNION`.

    N branches make one node with N children, not a left-deep tree of
    two-branch unions.

    Iterative: the branch bodies live in the top-level statement's
    `subqueries` table, so the chain is a linked list of indices into one
    table, walked with a loop. Recursing through each branch body would
    re-enter `_bind_select` from inside itself, a shape the Mojo compiler
    hangs on.

    The output schema is the first branch's, names included, which is
    DuckDB's rule: `SELECT a FROM t UNION ALL SELECT b FROM u` is a column
    called `a`. Every later branch is checked against it by
    `_union_branch_schema_check`.
    """
    var children = List[OwnedPointer[LogicalPlan]]()
    var out_schema = head.output_schema.copy()
    children.append(OwnedPointer(head^))
    var idx = first_idx
    var branch = 2
    while idx >= 0:
        ref sd = stmt.subqueries[idx]
        var plan = _bind_select(sd.body, catalog, cte_scope, prebound)
        _union_branch_schema_check(out_schema, plan.output_schema, branch)
        var next_idx = sd.body.union_all_idx
        children.append(OwnedPointer(plan^))
        idx = next_idx
        branch += 1
    return LogicalPlan.union(children^, out_schema^)


def _bind_select(stmt: SelectStmt, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr], result_names: Bool = False) raises -> LogicalPlan:
    """Bind one SELECT body against `catalog`, the `cte_scope` and the
    top-level `prebound` -> a `LogicalPlan`. Used for every CTE body, the final
    SELECT, every subquery body and every UNION ALL branch (`stmt.ctes` is
    ignored here: `_bind_query` binds the WITH clause)."""
    if len(stmt.from_tables) == 0:
        raise Error("SQL bind error: FROM clause has no tables")
    # A FROM-less SELECT's `*`: the one-row relation has no column a query
    # wrote, so there is nothing to expand. DuckDB v1.5.3:
    # `Binder Error: * expression without FROM clause!`.
    if (
        len(stmt.from_tables) == 1
        and not stmt.from_tables[0].tvf_path
        and stmt.from_tables[0].name == FROM_LESS_RELATION
    ):
        for si in range(len(stmt.select_items)):
            if stmt.select_items[si].is_star:
                raise Error(
                    "SQL bind error: * expression without FROM clause (a"
                    " FROM-less SELECT has no columns to expand)"
                )
    # 1. FROM -> a left-deep join tree over N relations. Comma / CROSS / INNER
    # relations (JK_CROSS) build a `JOIN_CROSS`, their ON folded into WHERE by
    # the parser; a JK_LEFT / JK_RIGHT / JK_FULL relation builds a real outer
    # join from its ON so unmatched rows null-extend. A NATURAL / USING relation
    # (`jc.is_keyed()`) builds a JOIN_INNER / JOIN_LEFT from the key names and
    # then coalesces them (`_bind_keyed_join`). Column refs resolve against the
    # built plan's output schema (with the `_right` collision rename) and the
    # qualifier-aware `scope`.
    var scope = _build_bind_scope(stmt.from_tables, stmt.joins, catalog, cte_scope)
    var plan = _relation_scan(stmt.from_tables[0], catalog, cte_scope)
    var left_aliases = _visible_qualifiers(stmt.from_tables[0])
    for i in range(1, len(stmt.from_tables)):
        var right = _relation_scan(stmt.from_tables[i], catalog, cte_scope)
        ref jc = stmt.joins[i - 1]
        if jc.kind != JK_SEMI and jc.kind != JK_ANTI:
            # A third relation's `k` must not become a SECOND `k_right` — see
            # `_dedupe_join_right`. A NATURAL / USING key is coalesced by name,
            # so it is never renamed.
            var dkeys = List[String]()
            if jc.is_keyed():
                if jc.natural:
                    for kj in range(right.output_schema.num_columns()):
                        dkeys.append(String(right.output_schema.field_name(kj)))
                else:
                    for kj in range(len(jc.using_cols)):
                        dkeys.append(String(jc.using_cols[kj]))
            right = _dedupe_join_right(plan.output_schema, right^, dkeys)
        if jc.kind == JK_SEMI or jc.kind == JK_ANTI:
            # SEMI / ANTI: see `_bind_semi_anti_join`. The relation's
            # qualifiers are not accumulated into `left_aliases` below (hence
            # the `continue`): a SEMI / ANTI right side emits no column, so no
            # later ON may classify a column against it (`_build_bind_scope`
            # omits it for the same reason).
            plan = _bind_semi_anti_join(
                plan^, right^, jc, stmt.from_tables[i], left_aliases, scope,
                catalog, cte_scope, prebound,
            )
            continue
        if jc.is_keyed() and (jc.kind == JK_RIGHT or jc.kind == JK_FULL):
            # NATURAL / USING at a RIGHT / FULL kind is refused by name.
            # `_bind_keyed_join` coalesces each shared key by projecting the
            # left column verbatim, which is correct only while every emitted
            # row carries a left key; RIGHT / FULL emit rows that do not, so the
            # key column would come back NULL. This arm must precede the one
            # below: a keyed clause carries no `on_pred`, so falling through
            # would raise "missing its ON condition", which is false about
            # `NATURAL RIGHT JOIN` (it may not have one).
            raise Error(
                "SQL not supported: NATURAL / USING at a "
                + _outer_join_kw(jc.kind) + " OUTER JOIN — the shared key must be"
                + " emitted as COALESCE(left.k, right.k) and this binder projects"
                + " the left key column verbatim, which is NULL on every row only"
                + " the right side contributed. Spell the same join as `"
                + _outer_join_kw(jc.kind) + " JOIN ... ON l.k = r.k`, which is"
                + " served and emits both key columns."
            )
        elif jc.is_keyed() and (jc.kind == JK_CROSS or jc.kind == JK_LEFT):
            # NATURAL / USING: the keys come from the schemas, not a predicate,
            # and the shared columns are coalesced. This arm must precede the
            # JK_CROSS one: a NATURAL clause carries kind JK_CROSS (there is no
            # separate inner code), and falling through would build a
            # JOIN_CROSS with no predicate.
            plan = _bind_keyed_join(
                plan^, right^, jc.natural, jc.using_cols, jc.kind
            )
        elif jc.kind == JK_CROSS:
            var left_on = List[String]()
            var right_on = List[String]()
            plan = LogicalPlan.join(plan^, right^, left_on^, right_on^, JOIN_CROSS)
        elif jc.kind == JK_LEFT or jc.kind == JK_RIGHT or jc.kind == JK_FULL:
            # The three outer kinds share one arm; `_bind_outer_join` narrows
            # what it admits and refuses the rest by name (see its docstring).
            if not jc.on_pred:
                raise Error(
                    "SQL bind error: " + _outer_join_kw(jc.kind) + " JOIN is"
                    + " missing its ON condition"
                )
            var left_schema = plan.output_schema.copy()
            var right_schema = right.output_schema.copy()
            var right_aliases = _visible_qualifiers(stmt.from_tables[i])
            plan = _bind_outer_join(
                plan^, right^, left_schema, right_schema, left_aliases, right_aliases,
                jc.on_pred.value(), jc.kind, scope, catalog, cte_scope, prebound,
            )
        else:
            # Unreachable over the parser's `JK_*` set: the arms above cover
            # JK_CROSS / JK_LEFT / JK_RIGHT / JK_FULL, and JK_SEMI / JK_ANTI
            # are taken before them. A new kind must state its own lowering
            # here; until it does the query is refused rather than answered as
            # a cross join.
            raise Error(
                "SQL not supported: join kind " + String(Int(jc.kind))
                + " has no lowering in _bind_select — this is a binder gap, not a"
                + " query error. Every JK_* kind must name its arm."
            )
        # Accumulate the just-joined relation's qualifiers into the LEFT alias set
        # (so a later LEFT join can classify a column against ANY prior relation).
        var ra = _visible_qualifiers(stmt.from_tables[i])
        for k in range(len(ra)):
            left_aliases.append(String(ra[k]))

    # Column refs resolve against the scope's combined binding schema (relation
    # types, renamed on collision) and the qualifier-aware scope, not the scan
    # plan's runtime output schema (whose string encoding can differ).
    var schema = scope.out_schema.copy()

    # 2. WHERE -> filter. A scalar subquery operand in the predicate binds
    # through `prebound` (`_bind_scalar`).
    if stmt.where_pred:
        var pred = _bind_scalar(stmt.where_pred.value(), schema, scope, catalog, cte_scope, prebound)
        plan = LogicalPlan.filter(pred^, plan^)

    # 3. aggregate vs window vs projection.
    var has_agg = False
    for i in range(len(stmt.select_items)):
        if (not stmt.select_items[i].is_star) and stmt.select_items[i].expr.contains_aggregate():
            has_agg = True
    var group_present = len(stmt.group_by) > 0
    var has_window = _has_window(stmt)

    # ORDER BY keys that may need carrying through the projection. Only bare
    # column keys are collected here; `_classify_order_keys` handles the rest.
    #
    # Nothing is carried under `SELECT DISTINCT`: DISTINCT de-duplicates over
    # the emitted columns, so widening the projection would widen the distinct
    # key and change the row count. DuckDB v1.5.3 accepts
    # `SELECT DISTINCT k FROM t ORDER BY v` with a nondeterministic order;
    # PostgreSQL refuses it, and so does this binder.
    var order_names = List[String]()
    if not stmt.distinct:
        for i in range(len(stmt.order_by)):
            ref okx = stmt.order_by[i]
            if okx.expr.tag == SX_COLUMN:
                order_names.append(_order_key_name(okx.expr, scope))
    var order_carry = List[String]()
    # Every ORDER BY key is classified: a column (above), an ordinal or an
    # expression a SELECT item already produces (the item's output column), or
    # an expression carried as a hidden column. See `_classify_order_keys`.
    var order_kind = List[Int]()
    var order_out_idx = List[Int]()
    var order_expr_idx = List[Int]()
    var order_expr_names = List[String]()
    _classify_order_keys(
        stmt, schema, has_window, order_kind, order_out_idx, order_expr_idx,
        order_expr_names,
    )

    if has_window:
        # Window functions build PARTITION BY node(s) then a Project. They are
        # refused beside GROUP BY / aggregation in the same SELECT (a window
        # over an aggregate needs a two-stage plan this binder does not build).
        if has_agg or group_present:
            raise Error(
                "SQL not supported: a window function combined with GROUP BY /"
                + " aggregation in the same SELECT"
            )
        plan = _bind_window_projection(stmt, schema, scope, plan^, catalog, cte_scope, prebound)
    elif has_agg or group_present:
        plan = _bind_aggregate(stmt, schema, scope, plan^, catalog, cte_scope, prebound, order_names, order_carry, order_expr_idx, order_expr_names)
    else:
        plan = _bind_projection(stmt, schema, scope, plan^, catalog, cte_scope, prebound, order_names, order_carry, order_expr_idx, order_expr_names)

    # 3a. The result's names (top-level query only; see
    # `_result_display_names`), computed here where the select list and the
    # scope are in hand. Where the rename goes matters, because a plan with two
    # columns of one name must reach no node that resolves a column by name:
    #   * DISTINCT resolves by name, so the rename goes above DISTINCT and
    #     ORDER BY: at the root, or
    #   * directly under the LIMIT when there is one, so the LIMIT (and an
    #     OFFSET's range limit) stays the plan's root;
    #   * with an ORDER BY carry, inside the step-6 prune, which already sits
    #     at the root and names every kept column (from unique engine names).
    #   One shape keeps the engine names: a bare `SELECT *` under a LIMIT with
    #   no ORDER BY / DISTINCT, the one spelling there that has no Project, so
    #   no Project is added between the LIMIT and its input.
    var display = List[String]()
    if result_names:
        display = _result_display_names(stmt, scope)
    var n_result = plan.output_schema.num_columns() - len(order_carry)
    var star_passthrough = (
        len(stmt.select_items) == 1
        and stmt.select_items[0].is_star
        and not has_agg
        and not group_present
        and not has_window
    )
    var bare_limit = (
        Bool(stmt.limit) and len(stmt.order_by) == 0 and not stmt.distinct
    )

    # 3b. SELECT DISTINCT -> a row-level distinct over the projected output.
    # Applied after the projection (so it de-dups the emitted columns) and
    # before ORDER BY / LIMIT. `None` columns = distinct over all columns.
    if stmt.distinct:
        # DISTINCT resolves its columns by name, so two SELECT items written
        # with one name (`SELECT DISTINCT K.k AS k, M.k AS k ...`) would reach
        # it as one column twice and answer the second with the first's
        # values; refused by name. (Names only the result duplicates, as in
        # `SELECT DISTINCT *` over a join, are renamed above the distinct from
        # unique engine names; see step 3a.)
        for c in range(plan.output_schema.num_columns()):
            for c2 in range(c + 1, plan.output_schema.num_columns()):
                if plan.output_schema.field_name(c) == plan.output_schema.field_name(c2):
                    raise Error(
                        "SQL not supported: SELECT DISTINCT over two items both"
                        " named `" + plan.output_schema.field_name(c) + "`. The"
                        " distinct resolves its columns by NAME, so the second"
                        " would be answered with the first's values. Give the"
                        " two items distinct aliases."
                    )
        var distinct_cols: Optional[List[String]] = None
        plan = LogicalPlan.distinct(distinct_cols^, plan^)

    # 4. ORDER BY -> sort, over the column each key RESOLVED to.
    if len(stmt.order_by) > 0:
        var sort_names = List[String]()
        for i in range(len(stmt.order_by)):
            if order_kind[i] == _OK_COLUMN:
                sort_names.append(_order_key_name(stmt.order_by[i].expr, scope))
            elif order_kind[i] == _OK_OUTPUT:
                sort_names.append(
                    _order_output_column(plan.output_schema, order_out_idx[i], n_result)
                )
            else:
                sort_names.append(String("__order_key_") + String(i))
        plan = _bind_order(stmt, plan^, scope, sort_names)

    # 5. LIMIT / OFFSET -> one limit node (a range limit when OFFSET > 0).
    #
    # The plan's row window is a single `PLAN_LIMIT` carrying `(n, offset)`,
    # so `LIMIT n OFFSET m` binds to `limit(n, child, offset=m)`. Step 5 runs
    # after project -> distinct -> sort, so that node is the plan's root (or
    # sits directly under the step-6 prune).
    #
    # `OFFSET m` with no `LIMIT` is refused by name. DuckDB accepts it; this
    # plan has no unbounded row count to put in `n`, and dropping the OFFSET
    # would return every row.
    var range_offset = 0
    if stmt.offset:
        range_offset = stmt.offset.value()
    if (
        result_names
        and len(order_carry) == 0
        and Bool(stmt.limit)
        and not (star_passthrough and bare_limit)
    ):
        # The result rename, directly UNDER the LIMIT (see 3a).
        var rx = _result_rename_exprs(plan.output_schema, display, n_result)
        if rx:
            plan = LogicalPlan.project(rx.take(), plan^)
    if stmt.limit:
        plan = LogicalPlan.limit(
            stmt.limit.value(), plan^, offset=range_offset
        )
    elif range_offset > 0:
        raise Error(
            "SQL not supported: OFFSET without LIMIT — this dialect honours an"
            " OFFSET only as part of a row window, so write"
            " `LIMIT <n> OFFSET " + String(range_offset) + "` with an explicit"
            " row count. (Refused rather than ignored: silently dropping the"
            " OFFSET would return every row.)"
        )

    # 6. Prune the columns step 3 carried only so the sort could name them.
    # The prune sits above the LIMIT, at the plan's root, so the columns the
    # caller gets are exactly the SELECT list's, and the sort and the limit
    # stay adjacent.
    if len(order_carry) > 0:
        var keep = plan.output_schema.num_columns() - len(order_carry)
        # Two kept columns of one name cannot be pruned by name: the prune
        # names each kept column, so `SELECT K.k AS k, M.k AS k ... ORDER BY a`
        # would prune `k` twice, both resolving to the first. Refused by name.
        # (A name only the result duplicates, `SELECT K.k, M.k ... ORDER BY a`,
        # is renamed inside this prune from unique engine names, below.)
        for c in range(keep):
            for c2 in range(c + 1, keep):
                if plan.output_schema.field_name(c) == plan.output_schema.field_name(c2):
                    raise Error(
                        "SQL not supported: two SELECT items are both named `"
                        + plan.output_schema.field_name(c) + "` and ORDER BY"
                        " sorts by a column the SELECT list does not produce."
                        " The sort's extra column is pruned by NAME, which"
                        " cannot tell the two apart, so the second would be"
                        " answered with the first's values. Give the two items"
                        " distinct aliases, or ORDER BY a selected column."
                    )
        if keep > 0:
            var prune = ExprArray()
            # The prune IS the result rename when there is one (the same
            # Project, so no second node sits above the limit).
            var rx = Optional[ExprArray](None)
            if result_names:
                rx = _result_rename_exprs(plan.output_schema, display, keep)
            if rx:
                prune = rx.take()
            else:
                for c in range(keep):
                    prune.append(Expr.col_ref(plan.output_schema.field_name(c)))
            plan = LogicalPlan.project(prune^, plan^)
    elif result_names and not stmt.limit:
        # The result rename at the ROOT — above DISTINCT and ORDER BY (see 3a).
        var rx = _result_rename_exprs(plan.output_schema, display, n_result)
        if rx:
            plan = LogicalPlan.project(rx.take(), plan^)

    return plan^

