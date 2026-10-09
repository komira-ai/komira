# =============================================================================
# komira_sql/sql_bind_scope.mojo
#   The per-query CTE scope, FROM relation schemas and scans, and the
#   qualifier-aware column scope of one SELECT.
# =============================================================================

from komira_arrow.schema import (
    Schema, SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    ExprArray, LogicalPlan,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_sql.sql_ast import (
    FROM_LESS_RELATION, FromRelation, JK_ANTI, JK_SEMI, JoinClause, SX_COLUMN,
    SelectStmt, SqlExpr,
)
from komira_sql.sql_bind_names import (
    _group_has, _group_spelling,
)
from komira_sql.sql_bind_parquet import (
    ParquetFacts, is_parquet_tvf_kind,
)
from komira_sql.sql_catalog import (
    SqlCatalog, from_less_relation_scan, from_less_relation_schema,
)
from komira_sql.sql_tvf_bind import (
    tvf_relation_scan, tvf_relation_schema,
)


struct CteScope(Movable):
    """The per-query scope `bind_statement` builds: each `WITH` definition's
    (and each derived table's) name -> its already-bound `LogicalPlan`
    subtree, and the parquet facts read before binding. When a FROM relation
    names a CTE, the binder inlines a fresh `.copy()` of that subplan (a named
    derived relation); there is no materialization node.

    Bodies bind in order, each against the scope of the CTEs before it, so a
    later CTE may reference an earlier one (standard SQL WITH semantics). A CTE
    name shadows a same-named catalog table (checked before the catalog). The
    bound plans live in a `Slab[LogicalPlan]` (a move-only container), copied
    out per reference; names are stored lower-cased (case-insensitive
    resolution, matching `SqlCatalog`)."""

    var _names: List[String]
    var _plans: Slab[LogicalPlan]
    var parquet: ParquetFacts
    """The footer schemas and null counts `collect_parquet_facts` read."""

    def __init__(out self, var parquet: ParquetFacts):
        self._names = List[String]()
        self._plans = Slab[LogicalPlan]()
        self.parquet = parquet^

    def add(mut self, name: String, var plan: LogicalPlan):
        self._names.append(name.lower())
        self._plans.append(plan^)

    def find(self, name: String) -> Int:
        var target = name.lower()
        for i in range(len(self._names)):
            if self._names[i] == target:
                return i
        return -1

    def has(self, name: String) -> Bool:
        return self.find(name) >= 0

    def plan_copy(self, idx: Int) -> LogicalPlan:
        """A fresh deep copy of CTE #`idx`'s bound subplan: one independent
        subtree per FROM reference (so a CTE used twice inlines twice)."""
        return self._plans[idx].copy()

    def schema_copy(self, idx: Int) raises -> Schema:
        """A copy of CTE #`idx`'s output schema (the derived relation's schema,
        used for column resolution against the combined FROM schema)."""
        return self._plans[idx].output_schema.copy()


def _date_to_days(s: String) raises -> Int32:
    """Convert a `YYYY-MM-DD` date string to days-since-1970-01-01 (date32),
    by Howard Hinnant's `days_from_civil` algorithm. The day is checked against
    its own month (Gregorian leap rule), so `DATE '2021-02-30'` raises rather
    than normalising to March 2."""
    var b = s.as_bytes()
    if len(b) != 10 or b[4] != UInt8(ord("-")) or b[7] != UInt8(ord("-")):
        raise Error("SQL bind error: malformed date literal '" + s + "' (want YYYY-MM-DD)")
    var y: Int = 0
    for i in range(4):
        y = y * 10 + Int(b[i] - UInt8(ord("0")))
    var m: Int = (Int(b[5] - UInt8(ord("0"))) * 10) + Int(b[6] - UInt8(ord("0")))
    var d: Int = (Int(b[8] - UInt8(ord("0"))) * 10) + Int(b[9] - UInt8(ord("0")))
    if m < 1 or m > 12 or d < 1 or d > 31:
        raise Error("SQL bind error: date out of range '" + s + "'")
    var leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
    var dim = 31
    if m == 2:
        dim = 29 if leap else 28
    elif m == 4 or m == 6 or m == 9 or m == 11:
        dim = 30
    if d > dim:
        raise Error("SQL bind error: date out of range '" + s + "'")
    var yy = y - 1 if m <= 2 else y
    # era = the 400-year cycle index. Mojo's `//` floors, so this is the plain
    # flooring divide (the C idiom `(yy - 399) // 400` assumes a truncating
    # division and would subtract a second era here).
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    var days = era * 146097 + doe - 719468
    return Int32(days)


def _relation_schema(rel: FromRelation, catalog: SqlCatalog, cte_scope: CteScope) raises -> Schema:
    """The schema of one FROM relation: a `read_parquet('path')` TVF's footer
    schema (read before binding, `cte_scope.parquet`), a `read_csv` /
    `read_json` / `read_avro` TVF's inferred or header schema (`sql_tvf_bind`),
    the FROM-less relation's one column, a CTE / derived-relation schema (the
    name shadows the catalog), or a catalog lookup for a named table."""
    if rel.tvf_path:
        if not is_parquet_tvf_kind(rel.tvf_kind):
            return tvf_relation_schema(rel)
        return cte_scope.parquet.schema_of(rel.tvf_path.value())
    if rel.name == FROM_LESS_RELATION:
        return from_less_relation_schema()
    var cte_idx = cte_scope.find(rel.name)
    if cte_idx >= 0:
        return cte_scope.schema_copy(cte_idx)
    return catalog.schema_of(rel.name)


def _relation_scan(rel: FromRelation, catalog: SqlCatalog, cte_scope: CteScope) raises -> LogicalPlan:
    """The scan node for one FROM relation. A parquet TVF builds a
    `ParquetSource` scan over its footer schema, the same node
    `SqlCatalog.build_scan` builds for a registered parquet table; a CSV /
    JSONL / Avro TVF builds the lazy row-oriented leaf of `sql_tvf_bind`; the
    FROM-less relation is its one-row scan; a CTE reference inlines a fresh
    copy of the bound CTE subplan (the name shadows the catalog); otherwise a
    catalog scan."""
    if rel.tvf_path:
        if not is_parquet_tvf_kind(rel.tvf_kind):
            return tvf_relation_scan(rel)
        var path = rel.tvf_path.value()
        var schema = cte_scope.parquet.schema_of(path)
        var src = SourceVariant(ParquetSource(String(path), schema.copy(), None))
        return LogicalPlan.scan_from_source(src^, schema^)
    if rel.name == FROM_LESS_RELATION:
        return from_less_relation_scan()
    var cte_idx = cte_scope.find(rel.name)
    if cte_idx >= 0:
        return cte_scope.plan_copy(cte_idx)
    return catalog.build_scan(rel.name)


@always_inline
def _schema_has_col(schema: Schema, name: String) -> Bool:
    var target = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == target:
            return True
    return False


@always_inline
def _schema_col_spelling(schema: Schema, name: String) -> String:
    """The schema's OWN spelling of whichever column `name` names
    case-insensitively, or "" when it has none.

    Not `_schema_has_col` plus the caller's own string, because a keyed join
    speaks two name languages: identifier resolution is case-insensitive
    (`USING (k)` names a right column spelled `K`), while `LogicalPlan.join`'s
    collision rename is case-sensitive. Handing back the actual spelling lets
    a call site resolve a name without predicting a rename the join node does
    not perform.
    """
    var target = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == target:
            return String(schema.field_name(i))
    return String("")


# =============================================================================
# Qualifier-aware column resolution
# =============================================================================
# The join output schema renames a right-side column that collides with a left
# column to `name_right` (see `LogicalPlan.join`), so a qualified reference
# like `r.key` must resolve to `key_right`, not the left `key`. `BindScope`
# maps a `(qualifier, column)` reference to its output name. For single-table
# and disjoint-column FROMs every output name equals the original name.


struct _RelCols(Copyable, Movable):
    """One FROM relation's column set inside a `BindScope`: the qualifiers that
    name it, its columns' original (relation-schema) names, and their names in the
    combined join OUTPUT schema (`_right`-renamed on collision)."""

    var aliases: List[String]  # lower-cased qualifiers naming this relation
    var orig: List[String]  # column names as in the relation's own schema
    var out: List[String]  # column names in the combined/join OUTPUT schema

    def __init__(out self):
        self.aliases = List[String]()
        self.orig = List[String]()
        self.out = List[String]()


struct BindScope(Movable):
    """Qualifier-aware column-resolution scope for one SELECT's FROM, built
    once per `_bind_select` from the FROM relations in join order.

    `out_schema` is the combined binding schema: each relation's
    `_relation_schema` columns concatenated, renamed on collision
    (`name_right`) exactly as the join output. It is built from
    `_relation_schema` (the catalog / footer schema), not the scan plan's
    output schema, because a catalog table's declared column type
    (`SqlCatalog.schema_of`) and its scan's runtime type can differ (a string
    column may be flat in one and DICTIONARY in the other); only the names
    gain the rename."""

    var rels: List[_RelCols]
    var out_schema: Schema

    def __init__(out self, var rels: List[_RelCols], var out_schema: Schema):
        self.rels = rels^
        self.out_schema = out_schema^

    def resolve_qualified(self, qualifier: String, name: String) raises -> String:
        """Resolve `qualifier.name` to its OUTPUT column name. Raises cleanly if no
        relation named by `qualifier` has a column `name`."""
        var q = qualifier.lower()
        var nl = name.lower()
        for ri in range(len(self.rels)):
            ref r = self.rels[ri]
            var named = False
            for ai in range(len(r.aliases)):
                if r.aliases[ai] == q:
                    named = True
                    break
            if not named:
                continue
            for i in range(len(r.orig)):
                if r.orig[i].lower() == nl:
                    return String(r.out[i])
        raise Error("SQL bind error: unknown column '" + qualifier + "." + name + "'")

    def source_name_of(self, qualifier: String, name: String) -> String:
        """The SOURCE spelling of `qualifier.name` — the column's name in its
        own relation, which is the name DuckDB v1.5.3 gives it in a result
        (`SELECT M.k` is a column called `k`; over a column declared `"K"`,
        `SELECT U.k` is `K`). "" when it does not resolve (the caller keeps
        the plan's name; binding it has already raised)."""
        var q = qualifier.lower()
        var nl = name.lower()
        for ri in range(len(self.rels)):
            ref r = self.rels[ri]
            var named = False
            for ai in range(len(r.aliases)):
                if r.aliases[ai] == q:
                    named = True
                    break
            if not named:
                continue
            for i in range(len(r.orig)):
                if r.orig[i].lower() == nl:
                    return String(r.orig[i])
        return String("")

    def source_name_of_output(self, out_name: String) -> String:
        """The SOURCE spelling of join-output column `out_name` (`k_right` ->
        `k`), or `out_name` itself when no relation renamed it."""
        for ri in range(len(self.rels)):
            ref r = self.rels[ri]
            for i in range(len(r.out)):
                if r.out[i] == out_name:
                    return String(r.orig[i])
        return String(out_name)


def _build_bind_scope(
    from_tables: List[FromRelation],
    joins: Slab[JoinClause],
    catalog: SqlCatalog,
    cte_scope: CteScope,
) raises -> BindScope:
    """Build the FROM scope + its combined binding schema: each relation's columns
    mapped to their names in the combined join OUTPUT schema, applying the SAME
    right-collision `_right` rename that `LogicalPlan.join` applies (a right column
    collides when its name already appears among the accumulated LEFT output
    names). The schema fields carry the `_relation_schema` types (see BindScope).

    ⛔ `joins` IS NOT OPTIONAL CONTEXT — IT CHANGES THE COLUMN SET. A NATURAL /
    USING relation COALESCES its key columns: the join node still emits `k` and
    `k_right`, but `_bind_keyed_join` projects the `_right` copy away, so the
    scope this function returns must not claim a column that will not exist. A
    key column therefore maps ONTO the left's existing output name and adds NO
    field, which reproduces the projection exactly (left columns verbatim, then
    the right's NON-key columns) — MEASURED against duckdb v1.5.3, which keeps
    the LEFT order and does not hoist the key to the front:
    `SELECT * FROM P(a,k) NATURAL JOIN Q(z,k,b)` DESCRIBEs as a, k, z, b.

    ⛔ AND A SEMI / ANTI RELATION CONTRIBUTES **NOTHING** — no field, no `used`
    name, no qualifier. `JOIN_SEMI` / `JOIN_ANTI` emit the LEFT columns only, so
    a scope that listed the right relation's columns would be wider than the
    plan (a `SELECT *` would name columns that do not exist) and would let a
    later `_right` rename be predicted for a collision that never happens.
    DuckDB v1.5.3 agrees at the NAME level too (measured): after
    `t SEMI JOIN u USING (k)`, `SELECT u.y` is "Referenced table u not found"
    and a bare `y` is "Referenced column y not found". The ON condition is
    classified against the two SCHEMAS by `_bind_semi_anti_join`, never
    through this scope."""
    var rels = List[_RelCols]()
    var sb = SchemaBuilder()
    var used = List[String]()  # accumulated OUTPUT names (exact) — mirrors LogicalPlan.join
    for ti in range(len(from_tables)):
        ref rel = from_tables[ti]
        if ti >= 1 and ti - 1 < len(joins):
            ref sj = joins[ti - 1]
            if sj.kind == JK_SEMI or sj.kind == JK_ANTI:
                continue
        var sch = _relation_schema(rel, catalog, cte_scope)
        # ⚠ THE LEFT NAMES ARE SNAPSHOT BEFORE THIS RELATION ADDS ANY, because
        # `LogicalPlan.join` checks a right column against the LEFT output only
        # — never against the right relation's own earlier columns.
        var left_used = used.copy()
        var right_names = List[String]()
        for j in range(sch.num_columns()):
            right_names.append(String(sch.field_name(j)))
        # The keys this relation COALESCES onto the accumulated left, if any.
        # `joins` is parallel to `from_tables[1:]`, so relation 0 never has one.
        var coalesced = List[String]()
        if ti >= 1 and ti - 1 < len(joins):
            ref jc = joins[ti - 1]
            if jc.is_keyed():
                if jc.natural:
                    for j in range(sch.num_columns()):
                        var nn = String(sch.field_name(j))
                        if _group_has(used, nn):
                            coalesced.append(String(nn))
                else:
                    for c in range(len(jc.using_cols)):
                        coalesced.append(String(jc.using_cols[c]))
        var rc = _RelCols()
        if rel.rel_alias != "":
            rc.aliases.append(rel.rel_alias.lower())
        if rel.name != "":
            rc.aliases.append(rel.name.lower())
        for j in range(sch.num_columns()):
            var cn = String(sch.field_name(j))
            rc.orig.append(String(cn))
            var out_name = String(cn)
            var collides = _names_have_exact(left_used, cn)
            if _group_has(coalesced, cn):
                # A coalesced key: `M.k` and the bare `k` are the same output
                # column, so no new field and no new `used` entry (a second `k`
                # would make the scope one column wider than the plan).
                # This is not guarded by `collides`: that test is exact, as
                # `LogicalPlan.join` is, while a coalesced key is matched
                # case-insensitively (`K(k,a) NATURAL JOIN M("K",b)`).
                # The output name is the left's spelling: `_bind_keyed_join`
                # emits the left key column verbatim, so `M.K` resolves to `k`.
                rc.out.append(_group_spelling(used, cn))
                continue
            if collides:
                # `_join_out_name` is the ONE rule the plan side
                # (`_dedupe_join_right`) applies too: `cn_right`, or the first
                # free `cn_right_<n>` when a `cn_right` is already there.
                out_name = _join_out_name(cn, left_used, right_names)
            rc.out.append(String(out_name))
            used.append(String(out_name))
            var fld = sch.field_at_unchecked(j)
            if collides:
                fld.name = out_name
            sb.add_field(fld^)
        rels.append(rc^)
    return BindScope(rels^, sb.build())


# =============================================================================
# A right column whose `_right` name is already taken
# =============================================================================
# `LogicalPlan.join` renames a right column that collides with a left output
# name to `<name>_right`: one suffix, not a counter. A third relation carrying
# the same column would produce a second `k_right`, and in
# `SELECT * FROM K JOIN M ON K.k = M.k JOIN K AS K2 ON K2.k = M.k` both `K2.k`
# and `M.k` would resolve to `k_right`, making the ON `k_right = k_right`
# (true on every row: a cross product).
#
# So such a column is renamed before the join, by a Project over the right
# input, to the first free `<name>_right_<n>` (n = 2, 3, ...), and the join
# node sees no collision for it; `_build_bind_scope` computes the same name
# through `_join_out_name`, so the scope and the plan agree. A join whose
# `_right` names are all free (every 2-relation join) has no such Project.
# (A result's names are DuckDB's, restored at the top: see
# `_result_display_names`.)


def _names_have_exact(names: List[String], name: String) -> Bool:
    """EXACT (case-sensitive) membership — the comparison `LogicalPlan.join`
    makes, which is why this is not `_group_has` (case-insensitive)."""
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def _join_out_name(
    cn: String, left_names: List[String], right_names: List[String]
) -> String:
    """The join OUTPUT name of right column `cn` joined onto `left_names`: `cn`
    when it does not collide, else `cn_right` (the join node's own rename),
    else — `cn_right` already taken on either side — the first free
    `cn_right_<n>`, n >= 2. See the section header."""
    if not _names_have_exact(left_names, cn):
        return cn
    var r = cn + "_right"
    if not _names_have_exact(left_names, r) and not _names_have_exact(right_names, r):
        return r
    var n = 2
    while True:
        var u = cn + "_right_" + String(n)
        if not _names_have_exact(left_names, u) and not _names_have_exact(right_names, u):
            return u
        n += 1


def _dedupe_join_right(
    left_schema: Schema, var right: LogicalPlan, keys: List[String]
) -> LogicalPlan:
    """Rename every right column whose join output name is NOT the join node's
    own (`cn` or `cn_right`) to that name, by a Project over `right`; return
    `right` UNCHANGED when there is none. `keys` are a NATURAL / USING join's
    coalesced key columns, which are matched by name and never renamed."""
    var left_names = List[String]()
    for i in range(left_schema.num_columns()):
        left_names.append(String(left_schema.field_name(i)))
    var right_names = List[String]()
    for j in range(right.output_schema.num_columns()):
        right_names.append(String(right.output_schema.field_name(j)))
    var need = False
    var exprs = ExprArray()
    for j in range(len(right_names)):
        var rn = right_names[j]
        var out = rn
        if not _group_has(keys, rn):
            out = _join_out_name(rn, left_names, right_names)
        if out == rn or out == rn + "_right":
            exprs.append(Expr.col_ref(rn))
        else:
            need = True
            exprs.append(Expr.alias(Expr.col_ref(rn), out))
    if not need:
        return right^
    return LogicalPlan.project(exprs^, right^)


# =============================================================================
# The names a result carries
# =============================================================================
# The join node's `_right` rename is an engine name: it keeps column references
# unambiguous inside the plan. DuckDB v1.5.3 does not rename in a result: it
# names a column after its source and keeps duplicates. Over K(k,a), M(k,b):
#
#   SELECT * FROM K JOIN M ON K.k = M.k        k, a, k, b     (plan: k, a, k_right, b)
#   SELECT K.k, M.k FROM K JOIN M ON ...       k, k           (plan: k, k_right)
#   SELECT M.k FROM K JOIN M ON ...            k              (plan: k_right)
#
# So the top-level query's result, and only that, renames each column a `*`
# or a qualified reference produced back to its source name. Not a derived
# table, a CTE, a COPY or a CTAS: DuckDB de-duplicates those (`k`, `a`, `k_1`,
# `b`), a different rule this binder does not implement (they keep the engine
# names), and an outer query must still be able to name every column of a
# derived table unambiguously. An alias always wins, and an unqualified
# reference keeps the name the query wrote.


def _result_display_names(stmt: SelectStmt, scope: BindScope) -> List[String]:
    """Per result column (a `*` expanded over the FROM scope), the name DuckDB
    gives it — or "" where the plan's own name already is that name."""
    var out = List[String]()
    for i in range(len(stmt.select_items)):
        ref item = stmt.select_items[i]
        if item.is_star:
            for j in range(scope.out_schema.num_columns()):
                out.append(scope.source_name_of_output(String(scope.out_schema.field_name(j))))
        elif item.out_alias:
            out.append(String(""))
        elif item.expr.tag == SX_COLUMN and item.expr.qualifier != "":
            out.append(scope.source_name_of(item.expr.qualifier, item.expr.text))
        else:
            out.append(String(""))
    return out^


def _result_rename_exprs(plan_schema: Schema, display: List[String], ncols: Int) -> Optional[ExprArray]:
    """The Project expressions that rename result columns `0..ncols-1` of
    `plan_schema` to `display`, or None when no name changes (or the two do
    not line up, which leaves the plan's names — never a misaligned rename)."""
    if len(display) != ncols or ncols > plan_schema.num_columns():
        return None
    var any_change = False
    var exprs = ExprArray()
    for c in range(ncols):
        var pn = String(plan_schema.field_name(c))
        var dn = display[c]
        if dn.byte_length() > 0 and dn != pn:
            any_change = True
            exprs.append(Expr.alias(Expr.col_ref(pn), dn))
        else:
            exprs.append(Expr.col_ref(pn))
    if not any_change:
        return None
    return Optional(exprs^)


def _resolve_col(sx: SqlExpr, schema: Schema, scope: BindScope) raises -> String:
    """Resolve an SX_COLUMN reference to its name in the (join OUTPUT) `schema`.
    A qualified `q.c` resolves via the scope (mapping to the `_right`-renamed out
    name on a collision); an unqualified `c` binds by bare name (must exist in the
    output schema). Single-table / disjoint FROMs return the name unchanged."""
    if sx.qualifier != "":
        return scope.resolve_qualified(sx.qualifier, sx.text)
    if not _schema_has_col(schema, sx.text):
        raise Error("SQL bind error: unknown column '" + sx.text + "'")
    return String(sx.text)


