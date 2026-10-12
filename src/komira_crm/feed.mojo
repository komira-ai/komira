# =============================================================================
# komira_crm/feed.mojo -- the change feed, and the erasure of a principal.
# =============================================================================
#
# THE FEED. Every account, deal, activity, pipeline and custom-field
# definition write takes its own number from the one feed counter
# (core.mojo), so the dataset has one ordered feed. `changes(since, limit)`
# returns the rows whose number is above `since`, lowest first, at most
# `limit` of them, each at its latest write; the cursor for the next call is
# the highest number returned, or `since` when nothing is.
#
# Why no change is skipped: the counter is read FIRST, and only rows numbered
# up to it are read. On SQLite (and Postgres) a write takes its number and
# commits its rows in one transaction that holds the counter row, so every
# number at or below the counter value read was committed before that read,
# and every row numbered above the returned cursor and at or below that
# value is still there for the next call. A write that commits during the
# call has a number above that value and above the cursor. The feed is not
# claimed on a backend where each operation commits alone (Firestore).
#
# Each table is read in number order, `limit` live rows at a time (a row a
# key does not name is skipped, core.mojo), then the tables are merged.
#
# ERASURE. `erase_subject(issuer, subject)` rewrites every row naming the
# principal: accounts and deals it owns become unowned (both owner columns
# empty) and activities it wrote get the actor ("", "erased"). Each rewrite
# is a write like any other, in its own transaction: it bumps the row's
# version and takes its own feed number. The rows are found by the owner or
# actor columns the rewrite clears, so a call stopped part way is finished
# by the next, and a second call rewrites nothing. Orphan rows (a create
# stopped between its row and its key) are rewritten too.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbRow, Filter, Order, Pred

from komira_crm_proto.crm import ChangesResponse, EntityKind, EraseSubjectResponse, FeedEntry

from komira_crm.accounts import external_id_live
from komira_crm.core import feed_counter, key_holder, next_modseq, no_limit, order_of, padded
from komira_crm.errors import invalid
from komira_crm.rows import int8, text
from komira_crm.schema import ACCOUNTS, ACTIVITIES, DEALS, FIELD_DEFS, FIELD_KEYS, PIPELINES, strs

comptime MAX_PAGE = 1000
comptime ERASED_SUBJECT: StaticString = "erased"


def _live[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], kind: Int, row: DbRow) raises -> Bool:
    """Whether a feed row (id, modseq, then its key columns) is live."""
    if kind == EntityKind.ACCOUNT or kind == EntityKind.DEAL:
        return external_id_live[DB, RT](db, reactor, kind, row.get_text(2), row.get_text(0))
    if kind == EntityKind.CUSTOM_FIELD_DEF:
        var holder = key_holder[DB, RT](
            db, reactor, FIELD_KEYS, "entity_kind", row.get_text(2), "field_key", row.get_text(3), "def_id"
        )
        return holder == row.get_text(0)
    return True


def _collect[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    kind: Int,
    var cols: List[String],
    since: UInt64,
    top: UInt64,
    limit: Int,
    mut out: List[FeedEntry],
) raises:
    """Append the first `limit` live rows of `table` numbered in (since, top]."""
    var after = since
    var taken = 0
    while True:
        var preds = List[Pred]()
        preds.append(Pred.gte(String("modseq"), int8(after + 1)))
        preds.append(Pred.le(String("modseq"), int8(top)))
        var order = List[Order]()
        order.append(Order.asc(String("modseq")))
        var rows = db.query_rows[RT](
            reactor, String(table), cols.copy(), Filter.all_of(preds^), order^, Optional[UInt32](UInt32(limit))
        )
        for i in range(rows.__len__()):
            ref r = rows.row(i)
            after = UInt64(r.get_int8(1))
            if taken < limit and _live[DB, RT](db, reactor, kind, r):
                out.append(FeedEntry(kind=EntityKind(kind), id=r.get_text(0), modseq=after))
                taken += 1
        if rows.__len__() < limit or taken >= limit:
            return


def changes[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], since: UInt64, limit: Int) raises -> ChangesResponse:
    """The rows written after feed number `since`, lowest number first, at
    most `limit` (1 to 1000)."""
    if limit < 1 or limit > MAX_PAGE:
        raise invalid("limit", "must be 1 to 1000")
    var top = feed_counter[DB, RT](db, reactor)
    var found = List[FeedEntry]()
    if since < top:
        _collect[DB, RT](db, reactor, ACCOUNTS, EntityKind.ACCOUNT, strs("id", "modseq", "external_id"), since, top, limit, found)
        _collect[DB, RT](db, reactor, DEALS, EntityKind.DEAL, strs("id", "modseq", "external_id"), since, top, limit, found)
        _collect[DB, RT](db, reactor, ACTIVITIES, EntityKind.ACTIVITY, strs("id", "modseq"), since, top, limit, found)
        _collect[DB, RT](db, reactor, PIPELINES, EntityKind.PIPELINE, strs("id", "modseq"), since, top, limit, found)
        _collect[DB, RT](
            db,
            reactor,
            FIELD_DEFS,
            EntityKind.CUSTOM_FIELD_DEF,
            strs("id", "modseq", "entity_kind", "field_key"),
            since,
            top,
            limit,
            found,
        )
    var keys = List[String]()
    for e in found:
        keys.append(padded(e.modseq))
    var sorted = order_of(keys)
    var page = List[FeedEntry]()
    var cursor = since
    for i in range(min(limit, len(sorted))):
        page.append(found[sorted[i]].copy())
        cursor = found[sorted[i]].modseq
    return ChangesResponse(changes=page^, modseq=cursor)


def _erase_rows[
    DB: Database, RT: Runtime
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    iss_col: StaticString,
    sub_col: StaticString,
    issuer: String,
    subject: String,
    new_sub: StaticString,
) raises -> UInt32:
    """Rewrite (iss_col, sub_col) from (issuer, subject) to ("", new_sub) on
    every row of `table`, one transaction per row; the rows rewritten."""
    var owned = List[Pred]()
    owned.append(Pred.eq(String(iss_col), text(issuer)))
    owned.append(Pred.eq(String(sub_col), text(subject)))
    var rows = db.query_rows[RT](reactor, String(table), strs("id"), Filter.all_of(owned^), List[Order](), no_limit())
    var count = UInt32(0)
    for i in range(rows.__len__()):
        var id = rows.row(i).get_text(0)
        db.begin[RT](reactor)
        try:
            var guard = List[Pred]()
            guard.append(Pred.eq(String("id"), text(id)))
            guard.append(Pred.eq(String(iss_col), text(issuer)))
            guard.append(Pred.eq(String(sub_col), text(subject)))
            var updates = List[DbColVal]()
            updates.append(DbColVal.bind(String(iss_col), text(String())))
            updates.append(DbColVal.bind(String(sub_col), text(String(new_sub))))
            updates.append(DbColVal.bind(String("modseq"), int8(next_modseq[DB, RT](db, reactor))))
            var n = db.conditional_update[RT](
                reactor,
                String(table),
                Filter.all_of(guard^),
                updates^,
                False,
                Optional[String](String("version")),
                List[String](),
            )
            db.commit[RT](reactor)
            count += UInt32(n)
        except e:
            db.rollback[RT](reactor)
            raise e^
    return count


def erase_subject[
    DB: Database, RT: Runtime
](mut db: DB, mut reactor: Reactor[RT.Sink], issuer: String, subject: String) raises -> EraseSubjectResponse:
    """Remove the principal (issuer, subject) from every CRM row: see the
    module header. Idempotent."""
    if issuer.byte_length() == 0 or subject.byte_length() == 0:
        raise invalid("subject", "issuer and subject are both required")
    var accounts = _erase_rows[DB, RT](db, reactor, ACCOUNTS, "owner_iss", "owner_sub", issuer, subject, "")
    var deals = _erase_rows[DB, RT](db, reactor, DEALS, "owner_iss", "owner_sub", issuer, subject, "")
    var activities = _erase_rows[DB, RT](
        db, reactor, ACTIVITIES, "actor_iss", "actor_sub", issuer, subject, ERASED_SUBJECT
    )
    return EraseSubjectResponse(accounts=accounts, deals=deals, activities=activities)
