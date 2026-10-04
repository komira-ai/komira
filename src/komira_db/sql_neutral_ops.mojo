# =============================================================================
# komira_db/sql_neutral_ops.mojo — the SQL implementation of the 9 neutral ops.
# =============================================================================
#
# The SHARED, SINGLE-PLACE SQL
# rendering + execution for the 9 `Database` structured ops, `[RT, DB:
# SqlDatabase]`-parametric so each SQL driver's neutral-op conformance is a
# 1-line delegation to the matching `sql_op_*` here. Written ONCE; identical
# across pg / sqlite / pgstore (each backend supplies its dialect tokens via
# `DB.placeholder(i)` / `DB.now_expr()` / `DB.dialect()`, and its own
# `execute` / `query` / `claim_pending`).
#
# THE BYTE-IDENTICAL CONTRACT: every SQL string built here matches the
# corresponding hand-written SQL of a typed store (e.g. `komira_job_store`), so
# the wire behavior does not depend on which surface a caller uses. The
# `render_*` helpers (pure String math, no DB) expose the exact rendered SQL so
# a golden-SQL test can assert byte-identity. If a neutral op would render even
# subtly-different SQL (a changed COALESCE, a dropped ORDER tiebreaker,
# different placeholder numbering), such a golden test FAILS.
#
# This module imports `SqlDatabase` from `database.mojo` (it sits ABOVE it in the
# import graph). `database.mojo` imports ONLY the value types from
# `neutral_ops.mojo` (which has no `Database` dependency), so there is no cycle:
#   neutral_ops (value types)  <-  database (traits, 9 op sigs)  <-  sql_neutral_ops (SQL impl)
#
# Encapsulation: String / List[DbValue] / structured value types in,
# DbRows / DbRow / UInt64 / Bool out. ZERO UnsafePointer crosses any boundary.
# =============================================================================

from std.collections.dict import Dict

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db.database import SqlDatabase
from komira_db.db_value import DbValue
from komira_db.db_row import DbRow, DbRows
from komira_db.proto_json import from_proto_json
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
    PodNameMinter,
    POD_NAME_ID_TAIL_LEN,
    PRED_EQ,
    PRED_LT,
    PRED_LE,
    PRED_GTE,
    PRED_IS_NULL,
    PRED_IS_NOT_NULL,
    PRED_JSON_KEY_EQ,
    PRED_IN,
    PRED_ARRAY_CONTAINS,
    PRED_NE,
    COMBINE_AND,
    COMBINE_OR,
)


# =============================================================================
# 1 — pure SQL RENDERERS (no DB) — byte-identical to the hand-written
#      JobStore SQL.
# =============================================================================


def _col_list(cols: List[String]) -> String:
    """A comma-joined column projection: `a, b, c`. (JobStore's `_all_cols`
    shape — a `, `-joined field list.)"""
    var out = String()
    for i in range(len(cols)):
        if i > 0:
            out += String(", ")
        out += cols[i]
    return out^


def render_where[DB: SqlDatabase](
    filter: Filter, dialect: String, mut next_bind: Int
) raises -> String:
    """Render the WHERE-clause body (without the leading " WHERE ") for `filter`,
    advancing `next_bind` past each positional bind it consumes. Returns "" for
    an empty filter (the caller then omits the WHERE entirely). The caller MUST
    append the SAME predicates' bind values to its params list in the SAME order.

    Placeholder numbering starts at `next_bind` (0-based) so a WHERE that follows
    a SET clause (conditional_update) or a LIMIT bind numbers correctly. Each
    dialect renders `DB.placeholder(i)`; PRED_JSON_KEY_EQ renders per-dialect
    (pg `config ->> $k`, sqlite `json_extract(config, '$.' || $k)`)."""
    if len(filter.preds) == 0:
        return String("")
    var joiner = String(" OR ") if filter.combine == COMBINE_OR else String(
        " AND "
    )
    var out = String()
    for i in range(len(filter.preds)):
        ref p = filter.preds[i]
        if i > 0:
            out += joiner
        if p.op == PRED_IS_NULL:
            out += p.col + String(" IS NULL")
        elif p.op == PRED_IS_NOT_NULL:
            out += p.col + String(" IS NOT NULL")
        elif p.op == PRED_NE and p.val.is_null:
            # `IS DISTINCT FROM NULL` IS `IS NOT NULL`, and it must be spelled
            # that way: `(col IS NULL OR col <> NULL)` collapses to `col IS NULL`
            # — the exact INVERSE of what was asked. Binds nothing.
            out += p.col + String(" IS NOT NULL")
        elif p.op == PRED_NE:
            # `IS DISTINCT FROM` — "the stored value is NOT $n", INCLUDING a row
            # whose column is NULL. A bare `<> $n` is three-valued and DROPS the
            # NULL row, which is the exact case this predicate exists to reach
            # (see PRED_NE in neutral_ops.mojo). Renders as the portable
            # `(<col> IS NULL OR <col> <> $n)` — pg and libsqlite3 both parse it —
            # and binds the value EXACTLY ONCE, so the positional bind order is
            # unchanged from any other single-value pred.
            out += (
                String("(")
                + p.col
                + String(" IS NULL OR ")
                + p.col
                + String(" <> ")
                + DB.placeholder(next_bind)
                + String(")")
            )
            next_bind += 1
        elif p.op == PRED_LT:
            out += p.col + String(" < ") + DB.placeholder(next_bind)
            next_bind += 1
        elif p.op == PRED_LE:
            out += p.col + String(" <= ") + DB.placeholder(next_bind)
            next_bind += 1
        elif p.op == PRED_GTE:
            out += p.col + String(" >= ") + DB.placeholder(next_bind)
            next_bind += 1
        elif p.op == PRED_IN:
            # `<col> IN (...)`. Two arms, both byte-identical to the hand SQL:
            #   * literal mode — inline each value's as_text() as a trusted SQL
            #     literal (`status IN (0, 1)`); binds NOTHING.
            #   * bound mode   — one placeholder per value (`col IN ($n, $n+1)`),
            #     each consuming a positional bind.
            out += p.col + String(" IN (")
            for j in range(len(p.in_vals)):
                if j > 0:
                    out += String(", ")
                if p.in_inline:
                    out += p.in_vals[j].as_text()
                else:
                    out += DB.placeholder(next_bind)
                    next_bind += 1
            out += String(")")
        elif p.op == PRED_JSON_KEY_EQ:
            # The JSON map-key predicate (config->>key = value), per dialect.
            # Both bind the KEY first ($k), then the VALUE ($v) — matching the
            # JobStore `list_jobs_by_config_key` bind order.
            if dialect == String("pg"):
                out += (
                    p.col
                    + String(" ->> ")
                    + DB.placeholder(next_bind)
                    + String(" = ")
                    + DB.placeholder(next_bind + 1)
                )
            else:
                # sqlite: json_extract(config, '$.' || $k) = $v
                out += (
                    String("json_extract(")
                    + p.col
                    + String(", '$.' || ")
                    + DB.placeholder(next_bind)
                    + String(") = ")
                    + DB.placeholder(next_bind + 1)
                )
            next_bind += 2
        elif p.op == PRED_ARRAY_CONTAINS:
            # `<ph> = ANY(<col>)` — the pg-only array-membership push-down, BYTE-
            # IDENTICAL to a hand-written `$1 = ANY(tags)` (placeholder on the
            # LEFT, `ANY(col)` on the RIGHT; binds `val`). ONLY the pg dialect
            # reaches this arm: sqlite / pgstore cannot parse `= ANY(col)`, so the
            # query-rows op STRIPS array_contains preds before rendering + evaluates
            # them client-side (`filter_without_array_contains`). If a non-pg dialect
            # reaches here it is a wiring bug — fail closed, never a silent drop.
            if dialect != String("pg"):
                raise Error(
                    String(
                        "render_where: PRED_ARRAY_CONTAINS is pg-only in SQL; the"
                        " query-rows op must strip it for dialect \""
                    )
                    + dialect
                    + String("\" and filter client-side")
                )
            out += DB.placeholder(next_bind) + String(" = ANY(") + p.col + String(
                ")"
            )
            next_bind += 1
        else:  # PRED_EQ
            out += p.col + String(" = ") + DB.placeholder(next_bind)
            next_bind += 1
    return out^


def render_order(order: List[Order]) -> String:
    """Render the ORDER BY body (without the leading " ORDER BY ") for `order`.
    Returns "" for an empty list. `col DESC` for a descending term; ascending is
    a BARE `col` (no explicit `ASC`) to match JobStore.list_jobs' `ORDER BY
    created_at DESC` and the bare-ascending shape. A caller that needs an
    explicit `ASC` (JobStore.list_jobs_by_config_key's `ORDER BY created_at ASC,
    id ASC`) uses Order.asc_explicit (a distinct render marker)."""
    var out = String()
    for i in range(len(order)):
        ref o = order[i]
        if i > 0:
            out += String(", ")
        out += o.col
        if o.desc:
            out += String(" DESC")
        elif o.explicit_asc:
            out += String(" ASC")
    return out^


def render_get_by_key[DB: SqlDatabase](
    table: String, cols: List[String], key_col: String
) raises -> String:
    """`SELECT <cols> FROM <table> WHERE <key_col> = $0` — byte-identical to
    JobStore.get_job's `"SELECT " + _all_cols() + " FROM jobs WHERE id = " +
    placeholder(0)`."""
    return (
        String("SELECT ")
        + _col_list(cols)
        + String(" FROM ")
        + table
        + String(" WHERE ")
        + key_col
        + String(" = ")
        + DB.placeholder(0)
    )


def render_put[DB: SqlDatabase](
    table: String, cols: List[String]
) raises -> String:
    """`INSERT INTO <table> (<cols>) VALUES (<ph(0), ph(1), ...>)` — the plain
    positional insert (JobStore's idempotency-row INSERT / `insert_sql` shape)."""
    var sql = (
        String("INSERT INTO ")
        + table
        + String(" (")
        + _col_list(cols)
        + String(") VALUES (")
    )
    for i in range(len(cols)):
        if i > 0:
            sql += String(", ")
        sql += DB.placeholder(i)
    sql += String(")")
    return sql^


def render_delete_by_key[DB: SqlDatabase](
    table: String, key_col: String
) raises -> String:
    """`DELETE FROM <table> WHERE <key_col> = $0` — the Store.delete_sql_for
    shape."""
    return (
        String("DELETE FROM ")
        + table
        + String(" WHERE ")
        + key_col
        + String(" = ")
        + DB.placeholder(0)
    )


def render_query_rows[DB: SqlDatabase](
    table: String,
    cols: List[String],
    filter: Filter,
    order: List[Order],
    has_limit: Bool,
    mut next_bind: Int,
) raises -> String:
    """`SELECT <cols> FROM <table> [WHERE <filter>] [ORDER BY <order>] [LIMIT
    $n]` — the list_jobs / find_stale_jobs / find_jobs_by_phase read shape.
    Advances `next_bind` past the filter binds; the LIMIT bind (if `has_limit`)
    is the FINAL param, numbered `next_bind` after the filter."""
    var sql = String("SELECT ") + _col_list(cols) + String(" FROM ") + table
    var where = render_where[DB](filter, DB.dialect(), next_bind)
    if where.byte_length() > 0:
        sql += String(" WHERE ") + where
    var ord_body = render_order(order)
    if ord_body.byte_length() > 0:
        sql += String(" ORDER BY ") + ord_body
    if has_limit:
        sql += String(" LIMIT ") + DB.placeholder(next_bind)
        next_bind += 1
    return sql^


def render_query_rows_locked[DB: SqlDatabase](
    table: String,
    cols: List[String],
    filter: Filter,
    order: List[Order],
    mut next_bind: Int,
) raises -> String:
    """`SELECT <cols> FROM <table> [WHERE <filter>] [ORDER BY <order>]
    [FOR UPDATE SKIP LOCKED]` — the concurrent-SCAN read shape (list_by_status /
    list_due). Identical to render_query_rows (NO limit) PLUS the pg-only
    `FOR UPDATE SKIP LOCKED` row-lock hint appended after the ORDER BY.

    THE BACKEND-DIVERGENT ROW-LOCK (the same shape as claim_pending's SKIP-LOCKED,
    but for a plain read): FULL Postgres (`dialect() == "pg"`) renders the
    `FOR UPDATE SKIP LOCKED` multi-replica defense-in-depth clause; sqlite +
    pgstore OMIT it (no row-level SKIP LOCKED; a single scheduler tick-owner
    is the single writer there). This is byte-identical to a hand-written
    `if pg: sql += " FOR UPDATE SKIP LOCKED"` arm."""
    var sql = String("SELECT ") + _col_list(cols) + String(" FROM ") + table
    var where = render_where[DB](filter, DB.dialect(), next_bind)
    if where.byte_length() > 0:
        sql += String(" WHERE ") + where
    var ord_body = render_order(order)
    if ord_body.byte_length() > 0:
        sql += String(" ORDER BY ") + ord_body
    if DB.dialect() == String("pg"):
        sql += String(" FOR UPDATE SKIP LOCKED")
    return sql^


def _n_update_binds(updates: List[DbColVal]) -> Int:
    """How many positional binds the `updates` SET terms consume (BIND +
    COALESCE bind one each; RAW_EXPR binds nothing)."""
    var n = 0
    for i in range(len(updates)):
        if updates[i].binds_a_param():
            n += 1
    return n


def render_conditional_update[DB: SqlDatabase](
    table: String,
    guard: Filter,
    updates: List[DbColVal],
    coalesce: Bool,
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> String:
    """`UPDATE <table> SET <sets> WHERE <guard>` — the transition_job /
    cancel_job / request_teardown CAS shape. The SET clause renders each
    `updates` term by its PER-COLUMN kind (so a MIXED clause like
    `phase = $1, progress = COALESCE($2, progress), ...` is expressible):
      * COLVAL_BIND     -> `col = $n`               (binds; index consumed)
      * COLVAL_COALESCE -> `col = COALESCE($n, col)` (binds; index consumed)
      * COLVAL_RAW_EXPR -> `col = <expr>`            (NO bind)
    The `coalesce` param is the DEFAULT applied to a plain COLVAL_BIND term when
    the CALLER wants the whole update to be partial (it upgrades BIND->COALESCE);
    a term explicitly built via DbColVal.bind / .coalesce / .raw_expr keeps its
    own kind. Then:
      * `version = version + 1` (when `bump_version_col`), NO bind.
      * each `now_cols` col — `col = <now_expr()>`, NO bind.
    The guard renders starting at the bind index the SET binds consumed. This is
    EXACTLY JobStore.transition_job's
    `SET phase=$1, version=version+1, progress=COALESCE($2,progress), ...,
    updated_at=NOW() WHERE id=$7 AND phase=$8 AND version=$9` — BUT JobStore
    interleaves version+1 right after phase, so the caller controls SET order by
    passing `version` as a RAW_EXPR term in `updates` (kept order-faithful)."""
    var sql = String("UPDATE ") + table + String(" SET ")
    var bind = 0
    var first = True
    for i in range(len(updates)):
        ref u = updates[i]
        if not first:
            sql += String(", ")
        first = False
        if u.is_raw_expr():
            sql += u.col + String(" = ") + u.val.as_text()
        elif u.is_coalesce() or (u.is_bind() and coalesce):
            sql += (
                u.col
                + String(" = COALESCE(")
                + DB.placeholder(bind)
                + String(", ")
                + u.col
                + String(")")
            )
            bind += 1
        else:  # plain bind
            sql += u.col + String(" = ") + DB.placeholder(bind)
            bind += 1
    if bump_version_col:
        var vc = bump_version_col.value()
        if not first:
            sql += String(", ")
        first = False
        sql += vc + String(" = ") + vc + String(" + 1")
    for i in range(len(now_cols)):
        if not first:
            sql += String(", ")
        first = False
        sql += now_cols[i] + String(" = ") + DB.now_expr()
    # The guard binds start after the SET's bound update terms.
    var guard_bind = bind
    var where = render_where[DB](guard, DB.dialect(), guard_bind)
    if where.byte_length() > 0:
        sql += String(" WHERE ") + where
    return sql^


def render_delete_where[DB: SqlDatabase](
    table: String, filter: Filter, mut next_bind: Int
) raises -> String:
    """`DELETE FROM <table> WHERE <filter>` — the cleanup_idempotency_keys /
    range-DELETE shape (`DELETE FROM idempotency_keys WHERE created_at < $0`)."""
    var sql = String("DELETE FROM ") + table
    var where = render_where[DB](filter, DB.dialect(), next_bind)
    if where.byte_length() > 0:
        sql += String(" WHERE ") + where
    return sql^


# =============================================================================
# 2 — the DB-touching op IMPLEMENTATIONS (each driver's conformance delegates
#      here). `[RT, DB: SqlDatabase]`-parametric; call the backend's own
#      execute / query / query_opt / claim_pending + placeholder / now_expr.
# =============================================================================


def sql_op_get_by_key[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    cols: List[String],
    key_col: String,
    key_val: DbValue,
) raises -> Optional[DbRow]:
    var sql = render_get_by_key[DB](table, cols, key_col)
    var params = List[DbValue]()
    params.append(key_val.copy())
    return db.query_opt[RT](reactor, sql, params)


def sql_op_put[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    cols: List[String],
    vals: List[DbValue],
) raises -> UInt64:
    var sql = render_put[DB](table, cols)
    return db.execute[RT](reactor, sql, vals.copy())


def sql_op_delete_by_key[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    key_col: String,
    key_val: DbValue,
) raises -> UInt64:
    var sql = render_delete_by_key[DB](table, key_col)
    var params = List[DbValue]()
    params.append(key_val.copy())
    return db.execute[RT](reactor, sql, params)


def _filter_has_array_contains(filter: Filter) -> Bool:
    """True iff `filter` carries any PRED_ARRAY_CONTAINS predicate."""
    for i in range(len(filter.preds)):
        if filter.preds[i].op == PRED_ARRAY_CONTAINS:
            return True
    return False


def filter_without_array_contains(filter: Filter) raises -> Filter:
    """A copy of `filter` with every PRED_ARRAY_CONTAINS predicate REMOVED — the
    pushed-down part for the sqlite / pgstore arms (whose executors cannot parse
    `= ANY(col)`). The removed preds are evaluated CLIENT-SIDE by
    `_row_matches_array_contains`. Preserves the combine mode + the order of the
    remaining preds. When there are no array_contains preds this is a value-equal
    copy of `filter`."""
    var kept = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op != PRED_ARRAY_CONTAINS:
            kept.append(filter.preds[i].copy())
    return Filter(kept^, filter.combine)


def _array_contains_preds_of(filter: Filter) raises -> List[Pred]:
    """The PRED_ARRAY_CONTAINS predicates of `filter` (evaluated CLIENT-SIDE by
    `_row_matches_array_contains` on sqlite / pgstore). Empty when the filter has
    none."""
    var out = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op == PRED_ARRAY_CONTAINS:
            out.append(filter.preds[i].copy())
    return out^


def _row_matches_array_contains(row: DbRow, ac_preds: List[Pred]) raises -> Bool:
    """True iff `row` satisfies EVERY array_contains predicate: the row's decoded
    TEXT[] column (`p.col`) contains the scalar `p.val` (compared by `as_text()`).
    An absent / NULL array column never matches. Empty `ac_preds` -> True. The
    load-and-filter Mojo-side membership test for the sqlite / pgstore arms (which
    cannot push `= ANY(col)` into SQL) — the SAME semantics the pg push-down
    computes server-side."""
    for i in range(len(ac_preds)):
        ref p = ac_preds[i]
        var ci = row.column_index(p.col)
        if ci < 0 or row.is_null(ci):
            return False  # absent / NULL array column never contains anything
        var want = p.val.as_text()
        var elems = row.get_text_array(ci)
        var found = False
        for j in range(len(elems)):
            if elems[j] == want:
                found = True
                break
        if not found:
            return False
    return True


# =============================================================================
# JSON-key-EQ split (PRED_JSON_KEY_EQ) — pgstore CANNOT push `config ->> $k = $v`
# (its NARROW executor has NEITHER pg `->>` NOR sqlite `json_extract`), so the
# query-rows op DROPS the json_key_eq preds from the pushed WHERE and evaluates
# them CLIENT-SIDE in Mojo over the decoded JSONB column (`config` is a proto-
# canonical `{"k":"v",...}` object). The SAME load-and-filter split shape as
# PRED_ARRAY_CONTAINS. pg / sqlite still push `config ->> $k = $v` /
# `json_extract(config,'$.'||$k)=$v` (byte-identical to JobStore, GIN/expr-index
# accelerated). A document backend (Firestore) does the same client-side split in
# its own `query_rows` (config is a serialized JSONB stringValue there too).
# =============================================================================


def _filter_has_json_key_eq(filter: Filter) -> Bool:
    """True iff `filter` carries any PRED_JSON_KEY_EQ predicate."""
    for i in range(len(filter.preds)):
        if filter.preds[i].op == PRED_JSON_KEY_EQ:
            return True
    return False


def filter_without_json_key_eq(filter: Filter) raises -> Filter:
    """A copy of `filter` with every PRED_JSON_KEY_EQ predicate REMOVED — the
    pushed-down part for the pgstore arm (whose NARROW executor cannot parse a
    JSON-extract predicate). The removed preds are evaluated CLIENT-SIDE by
    `_row_matches_json_key_eq`. Preserves the combine mode + remaining-pred
    order. When there are no json_key_eq preds this is a value-equal copy."""
    var kept = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op != PRED_JSON_KEY_EQ:
            kept.append(filter.preds[i].copy())
    return Filter(kept^, filter.combine)


def _json_key_eq_preds_of(filter: Filter) raises -> List[Pred]:
    """The PRED_JSON_KEY_EQ predicates of `filter` (evaluated CLIENT-SIDE by
    `_row_matches_json_key_eq` on the pgstore arm). Empty when the filter has
    none."""
    var out = List[Pred]()
    for i in range(len(filter.preds)):
        if filter.preds[i].op == PRED_JSON_KEY_EQ:
            out.append(filter.preds[i].copy())
    return out^


def _row_matches_json_key_eq(row: DbRow, jk_preds: List[Pred]) raises -> Bool:
    """True iff `row` satisfies EVERY json_key_eq predicate: the row's decoded
    JSONB column (`p.col`, a proto-canonical `{"k":"v",...}` object) carries
    `p.key` with a value equal to `p.val` (compared by `as_text()`). An absent /
    NULL JSON column, or a missing key, never matches. Empty `jk_preds` -> True.
    The load-and-filter Mojo-side membership test for the pgstore arm (which
    cannot push `config ->> $k = $v` into SQL) — the SAME semantics the pg / sqlite
    push-down computes server-side."""
    for i in range(len(jk_preds)):
        ref p = jk_preds[i]
        var ci = row.column_index(p.col)
        if ci < 0 or row.is_null(ci):
            return False  # absent / NULL JSON column carries no key
        var config = from_proto_json[Dict[String, String]](row.get_jsonb(ci))
        var got = config.get(p.key)
        if not got or got.value() != p.val.as_text():
            return False
    return True


def sql_op_query_rows[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    cols: List[String],
    filter: Filter,
    order: List[Order],
    limit: Optional[UInt32],
) raises -> DbRows:
    # CLIENT-SIDE-SPLIT preds — the ones THIS dialect cannot push into SQL, so
    # `query_rows` STRIPS them from the pushed WHERE + evaluates them in Mojo over
    # the decoded rows (the "load candidates, filter in Mojo" split):
    #   * PRED_ARRAY_CONTAINS — pg pushes `<val> = ANY(<col>)` (GIN, byte-identical);
    #     sqlite / pgstore cannot parse `= ANY(col)` -> client-side membership.
    #   * PRED_JSON_KEY_EQ — pg / sqlite push `config ->> $k = $v` /
    #     `json_extract(config,'$.'||$k)=$v` (byte-identical); ONLY pgstore (whose
    #     NARROW executor has neither) needs the client-side key filter.
    # When neither split applies the pushed filter IS the full filter.
    var is_pg = DB.dialect() == String("pg")
    var is_pgstore = DB.dialect() == String("pgstore")
    var split_array = (not is_pg) and _filter_has_array_contains(filter)
    var split_jsonkey = is_pgstore and _filter_has_json_key_eq(filter)
    if split_array or split_jsonkey:
        var ac_preds = _array_contains_preds_of(
            filter
        ) if split_array else List[Pred]()
        var jk_preds = _json_key_eq_preds_of(
            filter
        ) if split_jsonkey else List[Pred]()
        # Strip whichever splits apply from the pushed WHERE (order preserved).
        var pushed = filter.copy()
        if split_array:
            pushed = filter_without_array_contains(pushed)
        if split_jsonkey:
            pushed = filter_without_json_key_eq(pushed)
        # A client-side filter can drop rows, so the SQL LIMIT would be applied
        # BEFORE the Mojo check (wrong count). Drop the SQL LIMIT here + cap AFTER.
        var pushed_params = List[DbValue]()
        _append_filter_binds(pushed, pushed_params)
        var pbind = 0
        var pushed_sql = render_query_rows[DB](
            table, cols, pushed, order, False, pbind
        )
        var candidates = db.query[RT](reactor, pushed_sql, pushed_params)
        var lim = Int(limit.value()) if limit else -1
        var out = List[DbRow]()
        for i in range(candidates.__len__()):
            if lim >= 0 and len(out) >= lim:
                break
            ref r = candidates.row(i)
            if split_array and not _row_matches_array_contains(r, ac_preds):
                continue
            if split_jsonkey and not _row_matches_json_key_eq(r, jk_preds):
                continue
            out.append(r.copy())
        return DbRows(out^, cols.copy())
    # pg / sqlite (push the JSON-extract + `= ANY` where they can) OR any dialect
    # without a client-side-only pred: the unchanged render + bind + query path.
    var params = List[DbValue]()
    _append_filter_binds(filter, params)
    var bind = 0
    var sql = render_query_rows[DB](
        table, cols, filter, order, limit.__bool__(), bind
    )
    if limit:
        params.append(DbValue.int8(Int64(Int(limit.value()))))
    return db.query[RT](reactor, sql, params)


def sql_op_query_rows_locked[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    cols: List[String],
    filter: Filter,
    order: List[Order],
) raises -> DbRows:
    """The SQL impl of the concurrent-SCAN read (`query_rows_locked`): render the
    SELECT + the pg-only `FOR UPDATE SKIP LOCKED` row-lock hint and run it. The
    `list_by_status` / `list_due` reads route here — byte-identical to the
    equivalent hand-written raw SQL."""
    var params = List[DbValue]()
    _append_filter_binds(filter, params)
    var bind = 0
    var sql = render_query_rows_locked[DB](table, cols, filter, order, bind)
    return db.query[RT](reactor, sql, params)


def sql_op_conditional_update[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    guard: Filter,
    updates: List[DbColVal],
    coalesce: Bool,
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> UInt64:
    var sql = render_conditional_update[DB](
        table, guard, updates, coalesce, bump_version_col, now_cols
    )
    var params = List[DbValue]()
    # SET binds first (in update order — only the value-binding terms; RAW_EXPR
    # terms bind nothing), then the guard binds.
    for i in range(len(updates)):
        if updates[i].binds_a_param():
            params.append(updates[i].val.copy())
    _append_filter_binds(guard, params)
    return db.execute[RT](reactor, sql, params)


def sql_op_delete_where[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    filter: Filter,
) raises -> UInt64:
    var params = List[DbValue]()
    _append_filter_binds(filter, params)
    var bind = 0
    var sql = render_delete_where[DB](table, filter, bind)
    return db.execute[RT](reactor, sql, params)


def sql_op_create_if_absent[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    unique_col: String,
    unique_val: DbValue,
    cols: List[String],
    vals: List[DbValue],
) raises -> Bool:
    """Insert (`cols`/`vals`) IFF no row with `unique_col == unique_val` exists.
    Returns True iff WE won the key. Dialect arms:
      * pg:  `INSERT INTO <table> (<cols>) VALUES (<ph>) ON CONFLICT
             (<unique_col>) DO NOTHING RETURNING <unique_col>` — a returned row
             ⇒ we won; no row ⇒ a concurrent writer already claimed it. This is
             JobStore.create_job's idempotency ON CONFLICT arm.
      * sqlite: same ON CONFLICT ... DO NOTHING RETURNING (sqlite supports it).
      * pgstore: a native-OCC check-then-insert (SELECT the key; if absent,
             plain INSERT; the first-committer-wins WAL arbitrates). Mirrors
             JobStore._create_job_pgstore_dedup's snapshot-read + plain-INSERT."""
    if DB.dialect() == String("pgstore"):
        return _create_if_absent_pgstore[RT, DB](
            db, reactor, table, unique_col, unique_val, cols, vals
        )
    # pg / sqlite: ON CONFLICT DO NOTHING RETURNING <unique_col>.
    var sql = (
        render_put[DB](table, cols)
        + String(" ON CONFLICT (")
        + unique_col
        + String(") DO NOTHING RETURNING ")
        + unique_col
    )
    var won = db.query_opt[RT](reactor, sql, vals.copy())
    return won.__bool__()


def _create_if_absent_pgstore[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    unique_col: String,
    unique_val: DbValue,
    cols: List[String],
    vals: List[DbValue],
) raises -> Bool:
    """The pgstore-SAFE conditional-create: snapshot-read the key; if visible,
    lose (a prior submit won); else plain INSERT + let the first-committer-wins
    WAL arbitrate. Mirrors JobStore._create_job_pgstore_dedup (minus the second
    jobs-row INSERT — that stays JobStore-level; this op inserts ONE row)."""
    var sel_sql = (
        String("SELECT ")
        + unique_col
        + String(" FROM ")
        + table
        + String(" WHERE ")
        + unique_col
        + String(" = ")
        + DB.placeholder(0)
    )
    var sel_params = List[DbValue]()
    sel_params.append(unique_val.copy())
    var pre = db.query_opt[RT](reactor, sel_sql, sel_params)
    if pre:
        return False  # already claimed at this snapshot
    var ins_sql = render_put[DB](table, cols)
    _ = db.execute[RT](reactor, ins_sql, vals.copy())
    return True


def _conflict_col_list(conflict_cols: List[String]) -> String:
    """A comma-joined conflict-target list: `c1, c2, c3` (for `ON CONFLICT (...)`).
    """
    var out = String()
    for i in range(len(conflict_cols)):
        if i > 0:
            out += String(", ")
        out += conflict_cols[i]
    return out^


def _values_for_conflict_cols(
    conflict_cols: List[String], cols: List[String], vals: List[DbValue]
) raises -> List[DbValue]:
    """Extract the row's value for each `conflict_cols[i]` by matching against
    `cols` (positional). Used for the pgstore snapshot-read predicate. Raises if a
    conflict column is not present in `cols`."""
    var out = List[DbValue]()
    for i in range(len(conflict_cols)):
        var found = False
        for j in range(len(cols)):
            if cols[j] == conflict_cols[i]:
                out.append(vals[j].copy())
                found = True
                break
        if not found:
            raise Error(
                String("create_if_absent_composite: conflict column \"")
                + conflict_cols[i]
                + String("\" is not in the inserted cols")
            )
    return out^


def render_create_if_absent_composite[DB: SqlDatabase](
    table: String, conflict_cols: List[String], cols: List[String]
) raises -> String:
    """`INSERT INTO <table> (<cols>) VALUES (<ph...>) ON CONFLICT (<c1, c2, ...>)
    DO NOTHING RETURNING <c1>` — the composite-key idempotency INSERT. The
    RETURNING col is the FIRST conflict column (a returned row ⇒ we won; no row ⇒
    a concurrent writer claimed the composite key). Byte-identical to a caller's
    hand-written composite ON CONFLICT (e.g. `(mailbox_id, content_hash)`)."""
    return (
        render_put[DB](table, cols)
        + String(" ON CONFLICT (")
        + _conflict_col_list(conflict_cols)
        + String(") DO NOTHING RETURNING ")
        + conflict_cols[0]
    )


def sql_op_create_if_absent_composite[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    conflict_cols: List[String],
    cols: List[String],
    vals: List[DbValue],
) raises -> Bool:
    """Insert (`cols`/`vals`) IFF no row exists with the SAME tuple of
    `conflict_cols` values. Returns True iff WE won the composite key. The
    single-column `sql_op_create_if_absent` is unchanged; this is the composite
    generalization for keys like `(mailbox_id, content_hash)`, which otherwise
    take INSERT + catch + re-read. Dialect arms:
      * pg / sqlite: `... ON CONFLICT (c1, c2, ...) DO NOTHING RETURNING c1`.
      * pgstore: a native-OCC snapshot-read on `c1=$0 AND c2=$1 AND ...`; if
                 absent, plain INSERT (first-committer-wins WAL arbitrates)."""
    if len(conflict_cols) == 0:
        raise Error("create_if_absent_composite: empty conflict_cols")
    if DB.dialect() == String("pgstore"):
        return _create_if_absent_composite_pgstore[RT, DB](
            db, reactor, table, conflict_cols, cols, vals
        )
    var sql = render_create_if_absent_composite[DB](table, conflict_cols, cols)
    var won = db.query_opt[RT](reactor, sql, vals.copy())
    return won.__bool__()


def _create_if_absent_composite_pgstore[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    conflict_cols: List[String],
    cols: List[String],
    vals: List[DbValue],
) raises -> Bool:
    """The pgstore-SAFE composite conditional-create: snapshot-read the composite
    key (`WHERE c1=$0 AND c2=$1 AND ...`); if visible, lose; else plain INSERT +
    let the first-committer-wins WAL arbitrate."""
    var sel_sql = (
        String("SELECT ") + conflict_cols[0] + String(" FROM ") + table
    )
    var key_vals = _values_for_conflict_cols(conflict_cols, cols, vals)
    var where = String("")
    for i in range(len(conflict_cols)):
        if i > 0:
            where += String(" AND ")
        where += conflict_cols[i] + String(" = ") + DB.placeholder(i)
    sel_sql += String(" WHERE ") + where
    var pre = db.query_opt[RT](reactor, sel_sql, key_vals.copy())
    if pre:
        return False  # the composite key is already present at this snapshot
    var ins_sql = render_put[DB](table, cols)
    _ = db.execute[RT](reactor, ins_sql, vals.copy())
    return True


def sql_op_claim_rows[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    n: Int,
    filter: Filter,
    order: List[Order],
    phase_col: String,
    from_phase: String,
    to_phase: String,
    extra: List[DbColVal],
    per_row_mint: PodNameMinter,
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> DbRows:
    """The neutral claim over the driver's native `claim_pending`. Builds the
    `extra_set` string (the per-row pod_name mint + the `extra` SET terms + the
    `version = version + 1` bump + each `now_cols` `= <now_expr>` stamp) and
    the bind params, then hands to `claim_pending`. The pod_name term binds
    NOTHING (see `_render_pod_name_term`); the `extra` terms
    own every placeholder from the first. `filter` / `order` are
    accepted for surface generality but the concurrent claim's pending/order is
    owned by `claim_pending` (WHERE <phase_col>=<from> ORDER BY created_at) — the
    JobStore claim uses exactly that fixed shape, so we thread the phase COLUMN
    NAME (`phase_col`), from/to phase, and the extra_set. A caller whose queue
    column is named `"phase"` (JobStore, an outbound queue) gets the default
    shape; a caller with a different column name
    threads it here and it lands in `claim_pending`'s WHERE + SET."""
    _ = filter
    _ = order
    var extra_set = _render_claim_extra_set[DB](
        per_row_mint, extra, bump_version_col, now_cols
    )
    var claim_params = List[DbValue]()
    # ⭐ THE MINT BINDS NOTHING. `pod_name` is a pure function of the
    # row's own `id`, rendered entirely server-side, so the extra terms own
    # every placeholder from the first. RAW-EXPR extra terms (`version =
    # version + 1`, `updated_at = <now_expr>`) bind NOTHING either.
    for i in range(len(extra)):
        if not extra[i].is_raw_expr():
            claim_params.append(extra[i].val.copy())
    return db.claim_pending[RT](
        reactor, table, n, from_phase, to_phase, extra_set, claim_params, phase_col
    )


# =============================================================================
# 3 — private render/bind helpers.
# =============================================================================


def _append_filter_binds(filter: Filter, mut params: List[DbValue]):
    """Append each predicate's positional bind(s) to `params` in render order:
    JSON_KEY_EQ binds the KEY then the VALUE; EQ / LT / LE bind the value; a
    bound-mode IN binds each `in_vals` value in order; ARRAY_CONTAINS binds its
    `val` (the pg `<val> = ANY(<col>)` push-down — ONLY reaches here on pg, since
    the query-rows op strips it for the other dialects); IS NULL / IS NOT NULL /
    literal-mode IN bind nothing. MUST match render_where's placeholder
    consumption."""
    for i in range(len(filter.preds)):
        ref p = filter.preds[i]
        if p.op == PRED_JSON_KEY_EQ:
            params.append(DbValue.text(p.key))
            params.append(p.val.copy())
        elif p.op == PRED_IN:
            if not p.in_inline:
                # Bound-mode IN: one bind per value, render order.
                for j in range(len(p.in_vals)):
                    params.append(p.in_vals[j].copy())
            # Literal-mode IN binds nothing (values inlined by render_where).
        elif p.op == PRED_ARRAY_CONTAINS:
            # `<val> = ANY(<col>)`: binds the scalar `val` (pg push-down only).
            params.append(p.val.copy())
        elif p.op == PRED_NE and p.val.is_null:
            # `IS DISTINCT FROM NULL` renders as `IS NOT NULL` — no placeholder,
            # so no bind. (`binds_a_param()` is a per-OP coarse flag and cannot
            # see the value; this arm is what keeps the bind order in step with
            # render_where's placeholder consumption.)
            pass
        elif p.binds_a_param():
            params.append(p.val.copy())


def _render_claim_extra_set[DB: SqlDatabase](
    mint: PodNameMinter,
    extra: List[DbColVal],
    bump_version_col: Optional[String],
    now_cols: List[String],
) raises -> String:
    """Render the claim's `extra_set` clause: the per-row pod_name mint (if
    active) + each `extra` SET term (`col = $n` binds / `col = <expr>` raw) +
    the `version = version + 1` bump (`bump_version_col`) + each `now_cols`
    `= <now_expr>` stamp.

    The pod_name mint is the server-side spelling of `derive_pod_name`:
      * pgstore: `pod_name = pgstore_pod_name('<prefix>')`
      * pg:  `pod_name = CONCAT('<prefix>', '-', RIGHT(id::text, 12))`
      * sqlite: `pod_name = ('<prefix>' || '-' || lower(substr(hex(id), 21,
             12)))`
    then `, ` + each `extra` term, then `, version = version + 1` (when
    `bump_version_col`), then `, <col> = <now_expr>` per `now_cols`. The version
    bump + now-stamp are FIRST-CLASS params (not raw-expr `extra` terms) so the
    NEUTRAL caller (JobStore on the `Database` bound) never needs `now_expr()` —
    the renderer supplies the dialect now-expr here. The FULL extra_set matches
    JobStore's `pod_name = <expr>, version = version + 1, updated_at =
    <now_expr>`."""
    var out = String()
    var first = True
    # ⭐ EXTRA BINDS START AT placeholder(0). The mint binds nothing, so no
    # placeholder is reserved for it — whether the mint is active or not, the
    # rendered placeholders and the params `claim_rows` binds stay in step.
    var bind = 0
    if mint.is_active():
        out += _render_pod_name_term[DB](mint.prefix)
        first = False
    for i in range(len(extra)):
        ref e = extra[i]
        if not first:
            out += String(", ")
        first = False
        if e.is_raw_expr():
            # A raw-SQL expression term (`version = version + 1`, `updated_at =
            # <now_expr>`) — NO bind; render the literal expression.
            out += e.col + String(" = ") + e.val.as_text()
        else:
            # A bound value term: `col = $bind`.
            out += e.col + String(" = ") + DB.placeholder(bind)
            bind += 1
    if bump_version_col:
        var vc = bump_version_col.value()
        if not first:
            out += String(", ")
        first = False
        out += vc + String(" = ") + vc + String(" + 1")
    for i in range(len(now_cols)):
        if not first:
            out += String(", ")
        first = False
        out += now_cols[i] + String(" = ") + DB.now_expr()
    return out^


def _render_pod_name_term[DB: SqlDatabase](prefix: String) raises -> String:
    """Render ONLY the `pod_name = <expr>` term of the claim extra_set: the
    server-side spelling of `derive_pod_name(prefix, id_text)` —
    `<prefix>-<last POD_NAME_ID_TAIL_LEN chars of the id text, lowercased>`.

    ⛔⛔ IT BINDS NOTHING, AND THAT IS THE POINT. A bound CSPRNG suffix would
    make the placement name unrecomputable from the job id — so a job manager
    that crashed between the `pod_name` write and the `create` could never
    address the unit that create may have left behind. Every term below is a
    pure function of the row's own `id`. Do NOT add a bind here: a parameter is, by
    construction, something the recovery path does not have.

    ⚠ THE THREE DIALECTS MUST AGREE WITH `derive_pod_name` BYTE FOR BYTE, which
    is what `lower(...)` is doing on the sqlite arm: `hex()` answers in
    UPPERCASE where pg's `id::text` is lowercase, so without it the same job id
    would produce two different names on two backends (and an uppercase character is
    illegal in a Cloud Run resource name). The 12-character tail is the
    hyphenated id's FINAL group, the one slice carrying no hyphen — which is why
    a raw `RIGHT(id::text, N)` and a raw `substr(hex(id), k, N)` can be equal at
    all."""
    if DB.dialect() == String("pgstore"):
        return (
            String("pod_name = pgstore_pod_name('") + prefix + String("')")
        )
    if DB.placeholder(0) == String("$1"):
        # pg dialect. `id::text` is the lowercase hyphenated form; its last 12
        # characters are the final `8-4-4-4-12` group.
        return (
            String("pod_name = CONCAT('")
            + prefix
            + String("', '-', RIGHT(id::text, ")
            + String(POD_NAME_ID_TAIL_LEN)
            + String("))")
        )
    # sqlite dialect. `id` is a 16-byte BLOB, so `hex(id)` is 32 UPPERCASE hex
    # characters with no hyphens: the final group starts at 1-based char
    # 32 - 12 + 1 = 21.
    return (
        String("pod_name = ('")
        + prefix
        + String("' || '-' || lower(substr(hex(id), ")
        + String(32 - POD_NAME_ID_TAIL_LEN + 1)
        + String(", ")
        + String(POD_NAME_ID_TAIL_LEN)
        + String(")))")
    )
