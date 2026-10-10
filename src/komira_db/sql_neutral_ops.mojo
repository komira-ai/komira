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
# The claim op (`sql_op_claim_rows`) lives in `sql_claim_ops.mojo` and is
# re-exported here, so drivers keep importing every `sql_op_*` from this module.
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
from komira_db.sql_claim_ops import sql_op_claim_rows, _unknown_kind
from komira_db.neutral_ops import (
    Pred,
    Filter,
    Order,
    DbColVal,
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
            # An EMPTY list matches no row. `col IN ()` is not SQL (pg refuses
            # it), so it renders the always-false `1 = 0` and binds nothing.
            if len(p.in_vals) == 0:
                out += String("1 = 0")
                continue
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
            # JobStore `list_jobs_by_config_key` bind order. pgstore's narrow
            # executor has neither spelling: its query-rows op strips these preds
            # and filters client-side, and every other op on pgstore refuses one
            # here (fail closed) rather than render SQL it cannot run.
            if dialect == String("pg"):
                out += (
                    p.col
                    + String(" ->> ")
                    + DB.placeholder(next_bind)
                    + String(" = ")
                    + DB.placeholder(next_bind + 1)
                )
            elif dialect == String("sqlite"):
                # sqlite: json_extract(config, '$.' || $k) = $v
                out += (
                    String("json_extract(")
                    + p.col
                    + String(", '$.' || ")
                    + DB.placeholder(next_bind)
                    + String(") = ")
                    + DB.placeholder(next_bind + 1)
                )
            else:
                raise Error(
                    String(
                        "render_where: PRED_JSON_KEY_EQ renders only for dialects"
                        " \"pg\" and \"sqlite\"; dialect \""
                    )
                    + dialect
                    + String("\" filters it client-side in query_rows only")
                )
            next_bind += 2
        elif p.op == PRED_ARRAY_CONTAINS:
            # `<ph> = ANY(<col>)` — the pg-only array-membership push-down, BYTE-
            # IDENTICAL to a hand-written `$1 = ANY(tags)` (placeholder on the
            # LEFT, `ANY(col)` on the RIGHT; binds `val`). ONLY the pg dialect
            # reaches this arm: sqlite / pgstore cannot parse `= ANY(col)`, so the
            # query-rows op STRIPS array_contains preds before rendering + evaluates
            # them client-side (`_is_client_side`). Any other op on those
            # dialects reaches here and is refused: fail closed, never a silent
            # drop.
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
        elif u.is_bind():
            sql += u.col + String(" = ") + DB.placeholder(bind)
            bind += 1
        else:
            # A kind with no SET-term shape binds no param in
            # sql_op_conditional_update, so a placeholder here would shift
            # every later bind onto the wrong value.
            raise Error(_unknown_kind(u))
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


# =============================================================================
# The client-side split of query_rows. Some predicates cannot be pushed into a
# dialect's SQL, so query_rows strips them from the pushed WHERE and evaluates
# them in Mojo over the decoded candidate rows ("load candidates, filter in
# Mojo"):
#   * PRED_ARRAY_CONTAINS: pg pushes `<val> = ANY(<col>)` (GIN, byte-identical);
#     sqlite / pgstore cannot parse `= ANY(col)`.
#   * PRED_JSON_KEY_EQ: pg / sqlite push `config ->> $k = $v` /
#     `json_extract(config,'$.'||$k)=$v` (byte-identical to JobStore); pgstore's
#     NARROW executor has neither. `config` is a proto-canonical `{"k":"v",...}`
#     object. A document backend (Firestore) does the same split in its own
#     `query_rows`.
# An AND filter pushes the rest and keeps a candidate only if every client-side
# predicate holds. An OR filter cannot be split that way: a row matching only a
# client-side predicate is not among the pushed candidates. So an OR filter made
# only of client-side predicates pushes no WHERE and keeps a row if any holds,
# and an OR filter mixing them with pushed predicates is refused.
# =============================================================================


def _is_client_side(p: Pred, dialect: String) -> Bool:
    """True iff `dialect` cannot push `p` into SQL (see the section header)."""
    if p.op == PRED_ARRAY_CONTAINS:
        return dialect != String("pg")
    if p.op == PRED_JSON_KEY_EQ:
        return dialect == String("pgstore")
    return False


def _row_matches_client_pred(row: DbRow, p: Pred) raises -> Bool:
    """Whether `row` satisfies the client-side predicate `p`, with the semantics
    the pg push-down computes server-side. An absent or NULL column never
    matches.
      * PRED_ARRAY_CONTAINS: the decoded TEXT[] column `p.col` holds `p.val`
        (compared by `as_text()`).
      * PRED_JSON_KEY_EQ: the decoded JSONB object in `p.col` carries `p.key`
        with a value equal to `p.val.as_text()`; a missing key never matches."""
    var ci = row.column_index(p.col)
    if ci < 0 or row.is_null(ci):
        return False
    var want = p.val.as_text()
    if p.op == PRED_JSON_KEY_EQ:
        var config = from_proto_json[Dict[String, String]](row.get_jsonb(ci))
        var got = config.get(p.key)
        return got.__bool__() and got.value() == want
    var elems = row.get_text_array(ci)
    for j in range(len(elems)):
        if elems[j] == want:
            return True
    return False


def _row_matches_client_preds(
    row: DbRow, client: List[Pred], combine: UInt8
) raises -> Bool:
    """Whether `row` passes the client-side half of a split filter: every
    predicate of `client` for COMBINE_AND, at least one for COMBINE_OR."""
    for i in range(len(client)):
        var hit = _row_matches_client_pred(row, client[i])
        if combine == COMBINE_OR and hit:
            return True
        if combine != COMBINE_OR and not hit:
            return False
    return combine != COMBINE_OR


def sql_op_query_rows[RT: Runtime, DB: SqlDatabase](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: String,
    cols: List[String],
    filter: Filter,
    order: List[Order],
    limit: Optional[UInt32],
) raises -> DbRows:
    var dialect = DB.dialect()
    var pushed_preds = List[Pred]()
    var client = List[Pred]()
    for i in range(len(filter.preds)):
        if _is_client_side(filter.preds[i], dialect):
            client.append(filter.preds[i].copy())
        else:
            pushed_preds.append(filter.preds[i].copy())
    if len(client) > 0:
        if filter.combine == COMBINE_OR and len(pushed_preds) > 0:
            raise Error(
                String("query_rows: an OR filter mixing array_contains /")
                + String(" json_key_eq predicates that dialect \"")
                + dialect
                + String("\" evaluates client-side with predicates pushed into")
                + String(" SQL cannot be split; use an AND filter or one query")
                + String(" per branch")
            )
        var pushed = Filter(pushed_preds^, filter.combine)
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
            if _row_matches_client_preds(r, client, filter.combine):
                out.append(r.copy())
        return DbRows(out^, cols.copy())
    # Every predicate pushes: the unchanged render + bind + query path.
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
