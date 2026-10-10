# =============================================================================
# komira_sql/sql_bind_join.mojo
#   Outer, keyed (NATURAL / USING), semi and anti joins.
# =============================================================================

from komira_arrow.schema import (
    Schema, SchemaBuilder,
)
from komira_plan_expr.expr import (
    BIN_AND, Expr,
)
from komira_plan_expr.expr_walk import (
    ordered_name_sink, walk_expr_column_refs,
)
from komira_plan_ir.logical_plan import (
    ExprArray, JOIN_ANTI, JOIN_FULL, JOIN_INNER, JOIN_LEFT, JOIN_RIGHT, JOIN_SEMI,
    LogicalPlan,
)
from komira_sql.sql_ast import (
    FromRelation, JK_FULL, JK_LEFT, JK_RIGHT, JK_SEMI, JoinClause, SXOP_AND, SXOP_EQ,
    SX_BINARY, SX_COLUMN, SqlExpr,
)
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_names import _group_has
from komira_sql.sql_bind_scope import (
    CteScope, _schema_has_col, _schema_col_spelling, _RelCols, BindScope, _resolve_col,
    _AMBIGUOUS_QUALIFIER_PREFIX, _ambiguous_qualifier_error, _visible_qualifiers,
)
from komira_sql.sql_bind_subquery import _alias_in
from komira_sql.sql_catalog import SqlCatalog
from std.memory import OwnedPointer


# =============================================================================
# Outer joins: a real outer-join node with null-extension
# =============================================================================
# An outer clause's ON predicate is decomposed into the join's equi-keys
# (`left = right`) plus a residual (the non-equi part, e.g.
# `o_comment NOT LIKE ...`). The residual is carried on the JOIN node, not
# lifted into a post-join WHERE, so that a left row whose right match fails the
# residual null-extends rather than being dropped: the defining LEFT JOIN ON
# semantics.
#
# LEFT, RIGHT and FULL are bound. Refused by name:
#   * RIGHT / FULL with a non-equi ON residual (LEFT with a residual is bound);
#   * an outer join with zero equi-keys (a pure range outer join);
#   * RIGHT / FULL spelled NATURAL / USING: the coalescing projection
#     `_bind_keyed_join` emits takes the left key column verbatim, which is
#     NULL on a row only the right side contributed.


def _join_out_schema(left_schema: Schema, right_schema: Schema) raises -> Schema:
    """The join OUTPUT schema: left columns verbatim, then right columns with a
    `_right` suffix on any name collision — mirroring `LogicalPlan.join` EXACTLY so
    a residual column ref (e.g. a colliding right key) resolves to the same name."""
    var sb = SchemaBuilder()
    for i in range(left_schema.num_columns()):
        sb.add_field(left_schema.field_at_unchecked(i))
    for i in range(right_schema.num_columns()):
        var rname = right_schema.field_name(i)
        var collide = False
        for j in range(left_schema.num_columns()):
            if left_schema.field_name(j) == rname:
                collide = True
                break
        var rf = right_schema.field_at_unchecked(i)
        if collide:
            rf.name = rname + "_right"
        sb.add_field(rf^)
    return sb.build()


def _classify_side(
    sx: SqlExpr,
    left_schema: Schema,
    right_schema: Schema,
    left_aliases: List[String],
    right_aliases: List[String],
    left_scope: BindScope,
    right_scope: BindScope,
) raises -> Int:
    """Classify an SX_COLUMN ON-operand as belonging to the RIGHT relation (1),
    the accumulated LEFT plan (0), or ambiguous/unknown (-1). A qualified ref uses
    its qualifier against the alias sets; an unqualified ref uses which side's
    schema uniquely contains the column.

    A qualifier BOTH sides answer to (`a AS z JOIN b AS z`, `kk AS mm JOIN
    mm`) is decided by the column, as DuckDB v1.5.3 binds it: the side whose
    relation named by it has the column, and an ambiguity error when both
    do. `left_scope` / `right_scope` hold the two sides' relations."""
    if sx.qualifier != "":
        var q = sx.qualifier.lower()
        var in_r = _alias_in(right_aliases, q)
        var in_l = _alias_in(left_aliases, q)
        if in_r and in_l:
            var has_r = right_scope.has_qualified(q, sx.text)
            var has_l = left_scope.has_qualified(q, sx.text)
            if has_r and has_l:
                raise Error(_ambiguous_qualifier_error(q, sx.text.lower()))
            if has_r:
                return 1
            if has_l:
                return 0
            return -1
        if in_r:
            return 1
        if in_l:
            return 0
        return -1
    var inl = _schema_has_col(left_schema, sx.text)
    var inr = _schema_has_col(right_schema, sx.text)
    if inr and not inl:
        return 1
    if inl and not inr:
        return 0
    return -1


def _process_on_pred(
    sx: SqlExpr,
    left_schema: Schema,
    right_schema: Schema,
    left_aliases: List[String],
    right_aliases: List[String],
    out_schema: Schema,
    scope: BindScope,
    left_scope: BindScope,
    right_scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    mut left_on: List[String],
    mut right_on: List[String],
    mut residual: Optional[Expr],
) raises:
    """Walk an OUTER-JOIN ON predicate, splitting AND-conjuncts. A `left = right`
    equi conjunct (one column each side) contributes a parallel key pair
    (`left_on` = the LEFT column's output name, `right_on` = the RIGHT column's own
    schema name — `LogicalPlan.join` matches `right_on` pre-rename). Every other
    conjunct is bound (qualifier-aware, against the join OUTPUT schema) and ANDed
    into `residual`. `scope` holds the join's two inputs' relations only, and
    `left_scope` / `right_scope` each side's (`_classify_side`)."""
    if sx.tag == SX_BINARY and sx.op == SXOP_AND:
        _process_on_pred(
            sx._binary.value().left[], left_schema, right_schema, left_aliases, right_aliases,
            out_schema, scope, left_scope, right_scope, catalog, cte_scope, prebound,
            left_on, right_on, residual,
        )
        _process_on_pred(
            sx._binary.value().right[], left_schema, right_schema, left_aliases, right_aliases,
            out_schema, scope, left_scope, right_scope, catalog, cte_scope, prebound,
            left_on, right_on, residual,
        )
        return
    if sx.tag == SX_BINARY and sx.op == SXOP_EQ:
        ref l = sx._binary.value().left[]
        ref r = sx._binary.value().right[]
        if l.tag == SX_COLUMN and r.tag == SX_COLUMN:
            var ls = _classify_side(
                l, left_schema, right_schema, left_aliases, right_aliases, left_scope, right_scope
            )
            var rs = _classify_side(
                r, left_schema, right_schema, left_aliases, right_aliases, left_scope, right_scope
            )
            if ls == 0 and rs == 1:
                left_on.append(_resolve_col(l, left_schema, scope))
                right_on.append(String(r.text))
                return
            if ls == 1 and rs == 0:
                left_on.append(_resolve_col(r, left_schema, scope))
                right_on.append(String(l.text))
                return
    # Non-equi (or same-side) conjunct -> residual, bound against the join output.
    var e = _bind_scalar(sx, out_schema, scope, catalog, cte_scope, prebound)
    if residual:
        residual = Optional(Expr.binary(BIN_AND, residual.take(), e^))
    else:
        residual = Optional(e^)


def _outer_join_type(jkind: UInt8) raises -> UInt8:
    """`JK_LEFT` / `JK_RIGHT` / `JK_FULL` -> the IR join type.

    ⛔ RAISES ON ANYTHING ELSE rather than defaulting to `JOIN_LEFT`. A default
    here would silently execute a kind the caller did not ask for, which is the
    class of defect this whole file's join work has been closing (a NATURAL
    clause that bound as a CROSS returned 9 rows for 2 and nothing was red)."""
    if jkind == JK_LEFT:
        return JOIN_LEFT
    if jkind == JK_RIGHT:
        return JOIN_RIGHT
    if jkind == JK_FULL:
        return JOIN_FULL
    raise Error(
        "SQL bind error: _outer_join_type was handed join kind "
        + String(Int(jkind)) + ", which is not LEFT / RIGHT / FULL"
    )


def _outer_join_kw(jkind: UInt8) -> String:
    """The SQL keyword for a JK_* outer kind — for refusal messages, so a
    refusal names the kind the user actually wrote."""
    if jkind == JK_RIGHT:
        return String("RIGHT")
    if jkind == JK_FULL:
        return String("FULL")
    return String("LEFT")


def _bind_outer_join(
    var left_plan: LogicalPlan,
    var right_plan: LogicalPlan,
    left_schema: Schema,
    right_schema: Schema,
    left_aliases: List[String],
    right_aliases: List[String],
    on_sx: SqlExpr,
    jkind: UInt8,
    scope: BindScope,
    right_idx: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """Bind a `LEFT | RIGHT | FULL [OUTER] JOIN right ON on_sx` -> a
    `JOIN_LEFT` / `JOIN_RIGHT` / `JOIN_FULL` node with the ON decomposed into
    equi-keys + an optional residual carried on the join.

    One function serves three kinds because the ON decomposition is the same
    operation: `_process_on_pred` classifies each conjunct by side, and which
    side is null-extended is a property of the join node, not of the
    predicate walk.

    The residual is where the kinds diverge: LEFT with a residual is bound (a
    left row whose equi-matches all fail the residual re-appears
    NULL-extended); RIGHT / FULL with a residual is refused by name. Folding
    the residual into a post-join WHERE is not an alternative for any outer
    kind: it collapses the null-extension to an INNER join.

    `scope` is the statement's FROM scope and `right_idx` the right
    relation's FROM position: the ON binds against FROM positions
    `0..right_idx` only (`BindScope.slice`)."""
    var out_schema = _join_out_schema(left_schema, right_schema)
    var left_on = List[String]()
    var right_on = List[String]()
    var residual: Optional[Expr] = None
    _process_on_pred(
        on_sx, left_schema, right_schema, left_aliases, right_aliases,
        out_schema, scope.slice(0, right_idx + 1), scope.slice(0, right_idx),
        scope.slice(right_idx, right_idx + 1), catalog, cte_scope, prebound,
        left_on, right_on, residual,
    )
    if len(left_on) == 0:
        raise Error(
            "SQL not supported: a " + _outer_join_kw(jkind) + " JOIN ON needs at"
            + " least one `left = right` equi-key (a pure non-equi outer join is"
            + " not served by this path)"
        )
    if residual and (jkind == JK_RIGHT or jkind == JK_FULL):
        raise Error(
            "SQL not supported: a " + _outer_join_kw(jkind) + " OUTER JOIN whose"
            + " ON carries a non-equi residual — the equi-keys are served but the"
            + " residual is not (this binder carries a non-equi ON residual on a"
            + " LEFT join only). The equi-only form of this join"
            + " (`ON <equi conjuncts>` with the residual moved to a WHERE) is"
            + " served, but note that a WHERE does NOT preserve the outer rows a"
            + " residual ON would."
        )
    # LEFT with a non-equi ON residual (`... ON c_custkey = o_custkey AND
    # o_comment NOT LIKE ...`): the residual is carried on the join node
    # (already bound against the join output schema by `_process_on_pred`, so
    # its col_refs resolve by name), never folded into a post-join WHERE, which
    # would collapse the null-extension to an INNER join. By the guard above,
    # `residual` is non-empty here only for JK_LEFT.
    var res_ptr: Optional[OwnedPointer[Expr]] = None
    if residual:
        res_ptr = Optional(OwnedPointer(residual.take()))
    return LogicalPlan.join(
        left_plan^, right_plan^, left_on^, right_on^, _outer_join_type(jkind),
        residual=res_ptr^,
    )


# =============================================================================
# NATURAL JOIN / JOIN ... USING (...): the keyed join
# =============================================================================
# One function serves both spellings because they are one operation: NATURAL
# is USING over every name the two relations share. Only the key derivation
# differs; the equi-keys, the join kind and the coalescing projection are the
# same.
#
# The coalesce is a projection. `LogicalPlan.join` emits left ++ right with a
# `_right` suffix on a collision, so an INNER join on `k` emits
# `k, a, k_right, b`; ANSI (and DuckDB) emit one `k`. This function projects
# the left columns verbatim, then the right's non-key columns. That is DuckDB
# v1.5.3's order: over `P(a,k)` and `Q(z,k,b)`,
# `DESCRIBE SELECT * FROM P NATURAL JOIN Q` answers a, k, z, b (left order
# preserved, the key not hoisted to the front), and `P JOIN Q USING (k)`
# answers the same.
#
# The coalesced value is the left column, which is correct only for INNER and
# LEFT: an emitted row always carries the left key there (a LEFT join
# null-extends the right side), so `left.k` is `COALESCE(l.k, r.k)`. RIGHT /
# FULL would need a real coalesce, and `_bind_select` refuses them by name
# before reaching here.


def _keyed_join_keys(
    left_schema: Schema,
    right_schema: Schema,
    natural: Bool,
    using_cols: List[String],
    mut left_keys: List[String],
    mut right_keys: List[String],
) raises:
    """Resolve a NATURAL / USING clause's key NAMES against the two schemas,
    each in that side's OWN spelling. Shared by `_bind_keyed_join` (INNER /
    LEFT, which then coalesces the keys) and `_bind_semi_anti_join` (SEMI /
    ANTI, which emits no right column and so coalesces nothing) — ONE
    derivation, so the two can never disagree about which columns a USING
    list names."""
    # ⛔ TWO KEY LISTS, NOT ONE, BECAUSE `left_on` AND `right_on` ARE READ
    # AGAINST DIFFERENT SCHEMAS. Identifier resolution is case-INSENSITIVE, so
    # `USING (k)` legitimately names a right column spelled `K` — and a single
    # shared list would then put a name on the side that does not carry it.
    # MEASURED duckdb v1.5.3: over K(k,a) and MA2("K",b),
    # `DESCRIBE SELECT * FROM K JOIN MA2 USING(k)` answers k, a, b (it
    # resolves), and `K NATURAL JOIN MA("K","A")` answers k, a — BOTH
    # case-differing pairs coalesce.
    if natural:
        for j in range(right_schema.num_columns()):
            var rn = String(right_schema.field_name(j))
            var lsp = _schema_col_spelling(left_schema, rn)
            if lsp != "":
                left_keys.append(lsp)
                right_keys.append(String(rn))
        if len(left_keys) == 0:
            # ⛔ REFUSED, NOT DEGENERATED TO A CROSS JOIN. ANSI says a NATURAL
            # JOIN with no shared name IS a cross join; duckdb v1.5.3 refuses it
            # ("No columns found to join on in NATURAL JOIN. Use CROSS JOIN if
            # you intended for this to be a cross-product.") and so does this
            # binder — silently answering n*m rows for a query that asked to
            # match is the exact failure this whole function exists to remove.
            raise Error(
                "SQL bind error: NATURAL JOIN has no column name in common"
                + " between the two relations — there is nothing to join on."
                + " Use CROSS JOIN if a cross-product is what was intended."
            )
    else:
        for c in range(len(using_cols)):
            var cn = String(using_cols[c])
            if not _schema_has_col(left_schema, cn):
                raise Error(
                    "SQL bind error: USING column '" + cn + "' is not a column"
                    + " of the left side of the join"
                )
            if not _schema_has_col(right_schema, cn):
                raise Error(
                    "SQL bind error: USING column '" + cn + "' is not a column"
                    + " of the right side of the join"
                )
            if _group_has(right_keys, cn):
                raise Error(
                    "SQL bind error: USING column '" + cn + "' is named twice"
                )
            left_keys.append(_schema_col_spelling(left_schema, cn))
            right_keys.append(_schema_col_spelling(right_schema, cn))


def _bind_keyed_join(
    var left_plan: LogicalPlan,
    var right_plan: LogicalPlan,
    natural: Bool,
    using_cols: List[String],
    jkind: UInt8,
) raises -> LogicalPlan:
    """Bind `NATURAL [kind] JOIN r` / `[kind] JOIN r USING (c, ...)` -> a real
    equi-join on the resolved key names, followed by the projection that
    coalesces each shared key to ONE output column."""
    var left_schema = left_plan.output_schema.copy()
    var right_schema = right_plan.output_schema.copy()

    var left_keys = List[String]()
    var right_keys = List[String]()
    _keyed_join_keys(
        left_schema, right_schema, natural, using_cols, left_keys, right_keys
    )

    var jt = JOIN_INNER
    if jkind == JK_LEFT:
        jt = JOIN_LEFT
    var left_on = List[String]()
    var right_on = List[String]()
    for c in range(len(left_keys)):
        left_on.append(String(left_keys[c]))
        right_on.append(String(right_keys[c]))
    var joined = LogicalPlan.join(left_plan^, right_plan^, left_on^, right_on^, jt)

    # The coalescing projection — see the ⭐/⚠ block above.
    var exprs = ExprArray()
    for i in range(left_schema.num_columns()):
        exprs.append(Expr.col_ref(String(left_schema.field_name(i))))
    for j in range(right_schema.num_columns()):
        var pn = String(right_schema.field_name(j))
        if _group_has(right_keys, pn):
            continue
        # A NON-key right column can still collide (e.g. `K(k,a) JOIN M(k,a,b)
        # USING (k)`), and `LogicalPlan.join` renamed it. Reference the RENAMED
        # name, mirroring that rule exactly — a bare `pn` would resolve to the
        # LEFT column and silently emit it twice.
        #
        # DuckDB v1.5.3 emits `k, a, a, b` on that shape (both `a` columns
        # under one name); this binder emits `k, a, a_right, b`: same count,
        # same order, a different name for the duplicate.
        #
        # ⛔ AND THIS TEST IS CASE-SENSITIVE BECAUSE `LogicalPlan.join`'s IS —
        # it compares `left.output_schema.field_name(j) == rname` with `==`. A
        # case-INSENSITIVE test here predicts a rename the join node did NOT
        # perform and emits a col_ref to a column that does not exist. MEASURED
        # duckdb v1.5.3: over K(k,a) and MA3(k,"A"),
        # `DESCRIBE SELECT * FROM K JOIN MA3 USING(k)` answers k, a, A — the
        # right `A` keeps its own spelling, so this engine must reference `A`.
        var out_name = String(pn)
        for li in range(left_schema.num_columns()):
            if left_schema.field_name(li) == pn:
                out_name = pn + "_right"
                break
        exprs.append(Expr.col_ref(out_name))
    return LogicalPlan.project(exprs^, joined^)


# =============================================================================
# SEMI JOIN / ANTI JOIN: DuckDB's join-keyword spelling of `WHERE [NOT] EXISTS`
# =============================================================================
# `JOIN_SEMI` / `JOIN_ANTI` are the nodes a correlated `[NOT] EXISTS` binds
# to. The binder admits the shapes that map onto the node's key lists:
#   * `USING (c, ...)` and `NATURAL`: the same key derivation INNER / LEFT use
#     (`_keyed_join_keys`), with no coalescing projection (a SEMI / ANTI emits
#     no right column, so there is nothing to coalesce);
#   * `ON` whose every AND-conjunct is `left_col = right_col`;
#   * a conjunct that reads one side only, applied as a filter on that side's
#     input, which is exact: a right-only conjunct (`AND r.v > 250`) is
#     `L SEMI|ANTI JOIN (R WHERE r.v > 250)`, since a right row failing it (or
#     answering UNKNOWN) can match nothing under either kind; a left-only
#     conjunct is `(L WHERE ...) SEMI JOIN R` for SEMI only. An ANTI keeps the
#     left rows that conjunct rejects, so it cannot be a filter there and is
#     refused.
#
# Any other ON conjunct is refused by name: a conjunct reading both sides that
# is not an equi-key (`l.a > r.b`), an OR across the sides, an ON with no
# equi-key at all, an unqualified column both sides have. Each would need a
# residual on the join node, and a condition the node did not apply would
# answer the equi-only join (for ANTI, a strictly smaller set).
# `WHERE [NOT] EXISTS (SELECT 1 FROM r WHERE ...)` is the equivalent spelling,
# and the refusal names it.
#
# ⚠ THE RIGHT SIDE IS NAMED BY WHAT IS **VISIBLE** (`_visible_qualifiers`).
# An aliased relation is not reachable by its table name (DuckDB:
# `SELECT t.k FROM t AS x` -> "Referenced table t not found"), and in a
# self-join that distinction decides the answer: in
# `L SEMI JOIN L y ON L.lk = y.lk` the qualifier `L` names the LEFT L. Had it
# classified as the right side (by the right relation's table name), the
# conjunct would be `y.lk = y.lk`, one-sided — refused here, and an every-row
# answer in any binder that carried it.


def _qualified_text(sx: SqlExpr) -> String:
    """`q.col` as written, or `col` when unqualified — for messages."""
    if sx.qualifier != "":
        return sx.qualifier + "." + sx.text
    return String(sx.text)


def _append_semi_anti_key(
    lc: SqlExpr,
    rc: SqlExpr,
    left_schema: Schema,
    right_schema: Schema,
    scope: BindScope,
    kw: String,
    mut left_on: List[String],
    mut right_on: List[String],
) raises:
    """Append ONE equi-key pair: `lc` is the LEFT-side column (named as the
    left plan's OUTPUT names it — a qualified ref goes through the scope, which
    applies the `_right` collision rename), `rc` the RIGHT-side column (named in
    the right relation's own schema spelling)."""
    var lname: String
    if lc.qualifier != "":
        lname = scope.resolve_qualified(lc.qualifier, lc.text)
    else:
        lname = _schema_col_spelling(left_schema, lc.text)
    var rname = _schema_col_spelling(right_schema, rc.text)
    if lname == "" or rname == "":
        raise Error(
            "SQL bind error: unknown column '"
            + (_qualified_text(lc) if lname == "" else _qualified_text(rc))
            + "' in the " + kw + " JOIN's ON condition"
        )
    left_on.append(lname^)
    right_on.append(rname^)


def _single_relation_scope(rel: FromRelation, schema: Schema) -> BindScope:
    """A `BindScope` over ONE relation, named ONLY by what is visible in the
    query text (`_visible_qualifiers`), its columns unrenamed. It binds a
    SEMI / ANTI ON conjunct against the RIGHT relation alone — the statement
    scope deliberately does not contain that relation (`_build_bind_scope`)."""
    var rc = _RelCols()
    rc.aliases = _visible_qualifiers(rel)
    for i in range(schema.num_columns()):
        rc.orig.append(String(schema.field_name(i)))
        rc.out.append(String(schema.field_name(i)))
    var rels = List[_RelCols]()
    rels.append(rc^)
    return BindScope(rels^, schema.copy())


def _col_refs_within(e: Expr, schema: Schema) -> Bool:
    """True when every column `e` reads is a column of `schema`: a conjunct is
    filed on a side only when everything it reads is in that side's input."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(e, sink)
    for i in range(len(names)):
        if not _schema_has_col(schema, names[i]):
            return False
    return True


def _a_join_kw(kw: String) -> String:
    """`a SEMI` / `an ANTI` — the article a refusal sentence needs in front of
    the join keyword (the three SEMI / ANTI refusals below printed `a ANTI
    JOIN`)."""
    if kw == "ANTI":
        return String("an ") + kw
    return String("a ") + kw


def _bind_one_sided_conjunct(
    sx: SqlExpr,
    left_schema: Schema,
    right_schema: Schema,
    scope: BindScope,
    right_scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    kw: String,
    mut left_pred: Optional[Expr],
    mut right_pred: Optional[Expr],
) raises:
    """Bind ONE non-key conjunct of a SEMI / ANTI ON to the side it reads, or
    raise. It is bound against EACH side alone: it belongs to a side iff it
    binds there and not on the other.

    * RIGHT only (or no column at all, e.g. `1 = 1`) -> ANDed into
      `right_pred`, a filter on the right input. EXACT for SEMI and ANTI.
    * LEFT only -> `left_pred`, a filter on the left input — SEMI only.
    * Both -> an unqualified column both relations have, or a qualifier both
      sides answer to with the column on both: ambiguous (DuckDB v1.5.3
      refuses the first, measured: "Ambiguous reference to column name", and
      the second in `BindContext::GetBinding`: "Ambiguous reference to
      table").
    * Neither -> it reads both sides (or names nothing): refused."""
    var r_ok = False
    var r_expr: Optional[Expr] = None
    try:
        var e = _bind_scalar(sx, right_schema, right_scope, catalog, cte_scope, prebound)
        if _col_refs_within(e, right_schema):
            r_expr = Optional(e^)
            r_ok = True
    except:
        pass
    var l_ok = False
    var l_expr: Optional[Expr] = None
    try:
        var e = _bind_scalar(sx, left_schema, scope, catalog, cte_scope, prebound)
        if _col_refs_within(e, left_schema):
            l_expr = Optional(e^)
            l_ok = True
    except e:
        # A qualifier two LEFT relations answer to, both with the column, is
        # an error of the query, not "does not bind on this side": swallowed,
        # the conjunct would be filed on the right side when the right
        # relation has that column too.
        var msg = String(e)
        if msg.startswith(_AMBIGUOUS_QUALIFIER_PREFIX):
            raise Error(msg)
    if r_ok and l_ok:
        # A conjunct naming no column binds on both sides and belongs on the
        # right input (exact for both kinds); anything else here is ambiguous.
        var names = List[String]()
        var sink = ordered_name_sink(names)
        walk_expr_column_refs(r_expr.value(), sink)
        if len(names) > 0:
            raise Error(
                "SQL not supported: " + _a_join_kw(kw) + " JOIN ON conjunct is ambiguous"
                + " — a column it reads, unqualified or qualified by a name both"
                + " sides answer to, exists on BOTH sides. Qualify it with the"
                + " table name or a distinct alias of the side it belongs to."
            )
        l_ok = False
    if r_ok:
        if right_pred:
            right_pred = Optional(Expr.binary(BIN_AND, right_pred.take(), r_expr.take()))
        else:
            right_pred = r_expr^
        return
    if l_ok:
        if kw != "SEMI":
            raise Error(
                "SQL not supported: an " + kw + " JOIN whose ON condition carries"
                + " a conjunct on the LEFT side only. An ANTI join KEEPS the left"
                + " rows that conjunct rejects (they match nothing), so it cannot"
                + " be applied as a filter, and this door has no ANTI-join"
                + " residual. The equivalent spelling is `WHERE NOT EXISTS"
                + " (SELECT 1 FROM <right> WHERE <the whole ON condition>)`."
            )
        if left_pred:
            left_pred = Optional(Expr.binary(BIN_AND, left_pred.take(), l_expr.take()))
        else:
            left_pred = l_expr^
        return
    var exists_kw = String("EXISTS") if kw == "SEMI" else String("NOT EXISTS")
    raise Error(
        "SQL not supported: " + _a_join_kw(kw) + " JOIN whose ON condition carries a"
        + " conjunct that reads BOTH sides and is not a `left_column ="
        + " right_column` equi-key (a non-equality across the sides, an OR, or"
        + " an expression). Equi-keys, and conjuncts that read one side only,"
        + " are served on this join; a cross-side condition the join node did"
        + " not apply would silently answer the equi-only join. The equivalent"
        + " spelling is `WHERE " + exists_kw + " (SELECT 1 FROM <right> WHERE"
        + " <the whole ON condition>)`."
    )


def _semi_anti_on_keys(
    sx: SqlExpr,
    left_schema: Schema,
    right_schema: Schema,
    left_aliases: List[String],
    right_aliases: List[String],
    scope: BindScope,
    right_scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
    kw: String,
    mut left_on: List[String],
    mut right_on: List[String],
    mut left_pred: Optional[Expr],
    mut right_pred: Optional[Expr],
) raises:
    """Walk a SEMI / ANTI ON condition's AND-conjuncts: a `left_col =
    right_col` conjunct becomes a parallel equi-key pair — `left_on` in the
    LEFT plan's output names, `right_on` in the right relation's OWN schema
    spelling (`LogicalPlan.join` matches it pre-rename); any other conjunct
    goes to `_bind_one_sided_conjunct`, which files it as a filter on the one
    side it reads or raises."""
    if sx.tag == SX_BINARY and sx.op == SXOP_AND:
        _semi_anti_on_keys(
            sx._binary.value().left[], left_schema, right_schema, left_aliases,
            right_aliases, scope, right_scope, catalog, cte_scope, prebound, kw,
            left_on, right_on, left_pred, right_pred,
        )
        _semi_anti_on_keys(
            sx._binary.value().right[], left_schema, right_schema, left_aliases,
            right_aliases, scope, right_scope, catalog, cte_scope, prebound, kw,
            left_on, right_on, left_pred, right_pred,
        )
        return
    if sx.tag == SX_BINARY and sx.op == SXOP_EQ:
        ref l = sx._binary.value().left[]
        ref r = sx._binary.value().right[]
        if l.tag == SX_COLUMN and r.tag == SX_COLUMN:
            var ls = _classify_side(
                l, left_schema, right_schema, left_aliases, right_aliases, scope, right_scope
            )
            var rs = _classify_side(
                r, left_schema, right_schema, left_aliases, right_aliases, scope, right_scope
            )
            if ls == -1 or rs == -1:
                var shown: String
                if ls == -1:
                    shown = _qualified_text(l)
                else:
                    shown = _qualified_text(r)
                raise Error(
                    "SQL bind error: column '" + shown + "' in the " + kw
                    + " JOIN's ON condition is ambiguous or names neither side"
                    + " of the join — qualify it with the table name or alias"
                    + " of the side it belongs to"
                )
            if ls != rs:
                if ls == 0:
                    _append_semi_anti_key(
                        l, r, left_schema, right_schema, scope, kw, left_on, right_on
                    )
                else:
                    _append_semi_anti_key(
                        r, l, left_schema, right_schema, scope, kw, left_on, right_on
                    )
                return
    _bind_one_sided_conjunct(
        sx, left_schema, right_schema, scope, right_scope, catalog, cte_scope,
        prebound, kw, left_pred, right_pred,
    )


def _bind_semi_anti_join(
    var left_plan: LogicalPlan,
    var right_plan: LogicalPlan,
    jc: JoinClause,
    right_rel: FromRelation,
    left_aliases: List[String],
    scope: BindScope,
    right_idx: Int,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> LogicalPlan:
    """Bind `[NATURAL] SEMI|ANTI JOIN r (ON <equi-keys [AND one-sided
    conjuncts]> | USING (c, ...))` -> a `JOIN_SEMI` / `JOIN_ANTI` node whose
    output is the LEFT columns only, with any one-sided conjunct applied as a
    FILTER on its side's input. See the section note above for what is
    admitted and what is refused.

    `scope` is the statement's FROM scope and `right_idx` the right
    relation's FROM position: the left side of the ON binds against the
    relations before it only (`BindScope.slice`)."""
    var kw = String("SEMI") if jc.kind == JK_SEMI else String("ANTI")
    var left_schema = left_plan.output_schema.copy()
    var right_schema = right_plan.output_schema.copy()
    var left_on = List[String]()
    var right_on = List[String]()
    var left_pred: Optional[Expr] = None
    var right_pred: Optional[Expr] = None
    if jc.is_keyed():
        _keyed_join_keys(
            left_schema, right_schema, jc.natural, jc.using_cols, left_on, right_on
        )
    elif jc.on_pred:
        var right_scope = _single_relation_scope(right_rel, right_schema)
        _semi_anti_on_keys(
            jc.on_pred.value(), left_schema, right_schema, left_aliases,
            _visible_qualifiers(right_rel), scope.slice(0, right_idx), right_scope,
            catalog, cte_scope, prebound, kw, left_on, right_on, left_pred, right_pred,
        )
    else:
        raise Error(
            "SQL bind error: " + kw + " JOIN has neither an ON condition nor a"
            + " USING list"
        )
    if len(left_on) == 0:
        # ⛔ NO EQUI-KEY AT ALL (`ON r.v > 550`, `ON l.a = l.b`): the node
        # would be keyless. Refused rather than lowered to a cross product.
        var exists_kw = String("EXISTS") if kw == "SEMI" else String("NOT EXISTS")
        raise Error(
            "SQL not supported: " + _a_join_kw(kw) + " JOIN whose ON condition has no"
            + " `left_column = right_column` equi-key. The equivalent spelling"
            + " is `WHERE " + exists_kw + " (SELECT 1 FROM <right> WHERE <the"
            + " ON condition>)`."
        )
    if left_pred:
        left_plan = LogicalPlan.filter(left_pred.take(), left_plan^)
    if right_pred:
        right_plan = LogicalPlan.filter(right_pred.take(), right_plan^)
    var jt = JOIN_SEMI if jc.kind == JK_SEMI else JOIN_ANTI
    return LogicalPlan.join(left_plan^, right_plan^, left_on^, right_on^, jt)


