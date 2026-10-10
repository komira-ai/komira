# =============================================================================
# test_store_races.mojo -- ChatStore when a peer writes between its read and
#   its write.
# =============================================================================
#
# One store on one SQLite connection never interleaves, so `RacingDb` plays
# the peer: it delegates every call to an in-memory SqliteDatabase and, once
# armed, applies the peer's write at the moment its comment names. Each
# check would fail on the defect named.
#
#   subject_vanished  ensure_user's subject claim loses to a peer, whose row
#                     is erased before the store reads it: refused, and no
#                     user row is written. Catches reading a claim that is
#                     not there.
#   user_vanished     the user row is erased right after ensure_user wrote
#                     it: refused with the user's id. Catches returning a
#                     user that is not stored.
#   seq_taken         a peer takes the seq a send is about to insert at, 63
#                     times: the send lands at the 64th attempt, after the
#                     peer's events, and the probe saw every attempt; 64
#                     times: refused, and the peer's events are the only
#                     ones. Catches an attempt bound off by one either way,
#                     and an append that overwrites or skips a taken seq.
#   edit_vs_delete    a peer deletes the message just before an edit's EDIT
#                     event goes in: the edit returns its EDIT event with an
#                     empty body and the stored EDIT body is empty. Catches
#                     an edit that leaves its body readable on a deleted
#                     message.
#   edit_overtaken    a peer's later edit is copied onto the message just
#                     before this edit's EDIT event goes in: the message
#                     keeps the later body and this EDIT event keeps its own.
#                     Catches a copy that ignores last_edit_seq, and a
#                     redaction of a live message's edit.
#   edit_vs_late_del  a peer's EDIT row takes the seq a delete's DELETE event
#                     is about to take (its editor stops before copying it
#                     onto the message): the DELETE lands at the next seq
#                     and the peer's EDIT body is empty. Catches a delete
#                     that redacts its edits only before appending.
#   subject_reclaimed while erase_subject erases the users holding (iss,
#                     sub) (there is no subject row), a peer's first request
#                     claims the subject: the claim is erased too.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_db import (
    Database,
    DbColVal,
    DbRow,
    DbRows,
    DbValue,
    Filter,
    MigrationRunner,
    Order,
    PodNameMinter,
    Pred,
)
from komira_db.blocking import db_blocking_query
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatStore,
    EVENT_DELETE,
    EVENT_EDIT,
    SendProbe,
    T_EVENTS,
    T_SUBJECTS,
    T_USERS,
    chat_migrations,
    prepare_sql_connection,
    subject_key,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime T0: Int64 = 1790000000000
comptime ISS: StaticString = "https://issuer.example"
comptime RETURNED: StaticString = "<the call returned>"
comptime E: StaticString = "komira_chat_store: "

comptime NO_RACE = 0
comptime SUBJECT_VANISHED = 1
comptime USER_VANISHED = 2
comptime SEQ_TAKEN = 3
comptime DELETED_BEFORE_EDIT = 4
comptime EDITED_BEFORE_EDIT = 5
comptime SUBJECT_RECLAIMED = 6
comptime EDITED_BEFORE_DELETE = 7


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _text(col: StaticString, v: String) -> Filter:
    return Filter.just(Pred.eq(String(col), DbValue.text(v)))


def _message(channel_id: String, seq: Int64) -> Filter:
    var ps = List[Pred]()
    ps.append(Pred.eq(String("channel_id"), DbValue.text(channel_id)))
    ps.append(Pred.eq(String("seq"), DbValue.int8(seq)))
    return Filter.all_of(ps^)


struct RacingDb(Database, Movable, Deinitable):
    """SQLite, plus one armed peer write (`race`), applied at its moment."""

    var inner: SqliteDatabase
    var race: Int
    # SEQ_TAKEN: how many more inserts the peer takes first.
    var times: Int
    # The subject key, or the channel and seq of the message, raced on.
    var key: String
    var seq: Int64

    def __init__(out self, var inner: SqliteDatabase):
        self.inner = inner^
        self.race = NO_RACE
        self.times = 0
        self.key = String()
        self.seq = Int64(0)

    def arm(mut self, race: Int, key: String, seq: Int64, times: Int):
        self.race = race
        self.key = key
        self.seq = seq
        self.times = times

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.begin[RT](reactor)

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.commit[RT](reactor)

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        self.inner.rollback[RT](reactor)

    def get_by_key[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], key_col: String, key_val: DbValue
    ) raises -> Optional[DbRow]:
        return self.inner.get_by_key[RT](reactor, table, cols, key_col, key_val)

    def put[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], vals: List[DbValue]) raises -> UInt64:
        return self.inner.put[RT](reactor, table, cols, vals)

    def delete_by_key[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, key_col: String, key_val: DbValue) raises -> UInt64:
        return self.inner.delete_by_key[RT](reactor, table, key_col, key_val)

    def query_rows[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        cols: List[String],
        filter: Filter,
        order: List[Order],
        limit: Optional[UInt32],
    ) raises -> DbRows:
        return self.inner.query_rows[RT](reactor, table, cols, filter, order, limit)

    def query_rows_locked[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], filter: Filter, order: List[Order]
    ) raises -> DbRows:
        return self.inner.query_rows_locked[RT](reactor, table, cols, filter, order)

    def conditional_update[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        guard: Filter,
        updates: List[DbColVal],
        coalesce: Bool,
        bump_version_col: Optional[String],
        now_cols: List[String],
    ) raises -> UInt64:
        return self.inner.conditional_update[RT](
            reactor, table, guard, updates, coalesce, bump_version_col, now_cols
        )

    def delete_where[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter) raises -> UInt64:
        var n = self.inner.delete_where[RT](reactor, table, filter)
        if self.race == SUBJECT_RECLAIMED and table == String(T_USERS) and n > 0:
            # A first request of the subject claims it while the erasure runs.
            self.race = NO_RACE
            var vals = List[DbValue]()
            vals.append(DbValue.text(self.key))
            vals.append(DbValue.text(String("u-peer")))
            _ = self.inner.create_if_absent[RT](
                reactor, String(T_SUBJECTS), String("subject_key"),
                DbValue.text(self.key), _subject_cols(), vals,
            )
        return n

    def create_if_absent[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        unique_col: String,
        unique_val: DbValue,
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        if self.race == SUBJECT_VANISHED and table == String(T_SUBJECTS):
            # The peer's claim goes in first, the store's loses to it, and
            # an erasure removes the peer's before the store reads it.
            self.race = NO_RACE
            var peer = List[DbValue]()
            peer.append(DbValue.text(self.key))
            peer.append(DbValue.text(String("u-peer")))
            _ = self.inner.create_if_absent[RT](
                reactor, table, unique_col, unique_val, cols, peer
            )
            var won = self.inner.create_if_absent[RT](
                reactor, table, unique_col, unique_val, cols, vals
            )
            _ = self.inner.delete_where[RT](reactor, table, _text("subject_key", self.key))
            return won
        var won = self.inner.create_if_absent[RT](
            reactor, table, unique_col, unique_val, cols, vals
        )
        if self.race == USER_VANISHED and table == String(T_USERS):
            # The new user row is erased before the store reads it back.
            self.race = NO_RACE
            _ = self.inner.delete_where[RT](reactor, table, _text("user_id", self.key))
        return won

    def create_if_absent_composite[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        conflict_cols: List[String],
        cols: List[String],
        vals: List[DbValue],
    ) raises -> Bool:
        if table == String(T_EVENTS):
            if self.race == SEQ_TAKEN and self.times > 0:
                # The peer's own event takes the seq first.
                self.times -= 1
                var peer = vals.copy()
                peer[3] = DbValue.text(String("u-peer"))
                _ = self.inner.create_if_absent_composite[RT](
                    reactor, table, conflict_cols, cols, peer
                )
            elif self.race == DELETED_BEFORE_EDIT:
                self.race = NO_RACE
                var upd = List[DbColVal]()
                upd.append(DbColVal.bind(String("body"), DbValue.text(String())))
                upd.append(DbColVal.bind(String("deleted"), DbValue.int8(Int64(1))))
                _ = self.inner.conditional_update[RT](
                    reactor, table, _message(self.key, self.seq), upd,
                    False, Optional[String](), List[String](),
                )
            elif (
                self.race == EDITED_BEFORE_DELETE
                and vals[2].as_text() == String(EVENT_DELETE)
            ):
                # An editor whose EDIT row goes in at the seq the DELETE is
                # about to take, and who stops before copying it onto the
                # message: the DELETE retries at the next seq.
                self.race = NO_RACE
                var peer = vals.copy()
                peer[2] = DbValue.int8(Int64(EVENT_EDIT))
                peer[3] = DbValue.text(String("u-peer"))
                peer[4] = DbValue.text(String("late"))
                _ = self.inner.create_if_absent_composite[RT](
                    reactor, table, conflict_cols, cols, peer
                )
            elif self.race == EDITED_BEFORE_EDIT:
                self.race = NO_RACE
                var upd = List[DbColVal]()
                upd.append(DbColVal.bind(String("body"), DbValue.text(String("later"))))
                upd.append(DbColVal.bind(String("edited"), DbValue.int8(Int64(1))))
                upd.append(DbColVal.bind(String("last_edit_seq"), DbValue.int8(Int64(1000))))
                _ = self.inner.conditional_update[RT](
                    reactor, table, _message(self.key, self.seq), upd,
                    False, Optional[String](), List[String](),
                )
        return self.inner.create_if_absent_composite[RT](
            reactor, table, conflict_cols, cols, vals
        )

    def claim_rows[
        RT: Runtime,
    ](
        mut self,
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
        return self.inner.claim_rows[RT](
            reactor, table, n, filter, order, phase_col, from_phase, to_phase,
            extra, per_row_mint, bump_version_col, now_cols,
        )


def _subject_cols() -> List[String]:
    var c = List[String]()
    c.append(String("subject_key"))
    c.append(String("user_id"))
    return c^


struct CountingProbe(SendProbe):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def before_insert(mut self, channel_id: String, seq: Int64) raises:
        self.calls += 1


comptime Store = ChatStore[RacingDb, CountingProbe]


def _store() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var rt = _rt()
    ref reactor = rt.reactor()
    prepare_sql_connection[Rt, SqliteDatabase](db, reactor)
    var runner = MigrationRunner[SqliteDatabase](db^, String(CHAT_MIGRATION_LEDGER))
    _ = runner.run[Rt](reactor, chat_migrations())
    return Store(RacingDb(runner^.into_db()), CountingProbe())


def _channel(mut s: Store) raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var bob = List[String]()
    bob.append(String("u-bob"))
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PUBLIC, String("a"), String(""),
        String("u-alice"), bob, T0,
    )


def _ensure_err(mut s: Store, id: StaticString, sub: StaticString) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.ensure_user[Rt](
            reactor, String(id), String(ISS), String(sub), String("N"), String(""), T0
        )
    except e:
        return String(e)
    return String(RETURNED)


def _send(mut s: Store, body: StaticString) -> String:
    """The seq the send took, or the error it raised."""
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        var ev = s.send_message[Rt](
            reactor, String("c-a"), String("u-bob"), String(body), Int64(0),
            String(), List[String](), False, List[String](), T0,
        )
        return String(ev.seq)
    except e:
        return String(e)


def _count(mut s: Store, sql: StaticString) raises -> Int64:
    var rows = db_blocking_query(s.db().inner, String(sql), List[DbValue]())
    return rows.row(0).get_int8(0)


def test_subject_and_user_vanished() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    s.db().arm(SUBJECT_VANISHED, subject_key(String(ISS), String("sub-a")), Int64(0), 0)
    assert_equal(
        _ensure_err(s, "u-a", "sub-a"),
        String(E) + String("the subject row vanished while it was read"),
    )
    assert_false(Bool(s.user[Rt](reactor, String("u-a"))), "no user row written")
    assert_equal(_count(s, "SELECT COUNT(*) FROM chat_users"), Int64(0))

    s.db().arm(USER_VANISHED, String("u-b"), Int64(0), 0)
    assert_equal(_ensure_err(s, "u-b", "sub-b"), String(E) + String("user u-b vanished"))
    # Unarmed, the same request completes.
    var b = s.ensure_user[Rt](
        reactor, String("u-b2"), String(ISS), String("sub-b"), String("B"), String(""), T0
    )
    assert_equal(b.user_id, String("u-b"), "the subject row stayed")


def test_seq_taken() raises:
    var s = _store()
    _channel(s)
    var calls0 = s.probe().calls
    s.db().arm(SEQ_TAKEN, String(), Int64(0), 63)
    assert_equal(_send(s, "late"), String("66"), "the 64th attempt, after 2 JOINs and 63 peers")
    assert_equal(s.probe().calls - calls0, 64)
    assert_equal(
        _count(s, "SELECT COUNT(*) FROM chat_events WHERE sender_user_id = 'u-peer'"),
        Int64(63),
    )
    assert_equal(
        _count(s, "SELECT COUNT(*) FROM chat_events WHERE sender_user_id = 'u-bob' AND body = 'late'"), Int64(1)
    )
    s.db().arm(SEQ_TAKEN, String(), Int64(0), 64)
    assert_equal(
        _send(s, "lost"),
        String(E) + String("channel c-a: no free seq after 64 attempts"),
    )
    assert_equal(
        _count(s, "SELECT COUNT(*) FROM chat_events WHERE sender_user_id = 'u-bob' AND body = 'lost'"), Int64(0)
    )
    assert_equal(_count(s, "SELECT MAX(seq) FROM chat_events"), Int64(130))
    assert_equal(_count(s, "SELECT COUNT(*) FROM chat_events"), Int64(130), "no gap")


def test_edit_races() raises:
    var s = _store()
    _channel(s)
    var rt = _rt()
    ref reactor = rt.reactor()
    var m = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("v1"), Int64(0),
        String(), List[String](), False, List[String](), T0,
    )
    s.db().arm(DELETED_BEFORE_EDIT, String("c-a"), m.seq, 0)
    var ed = s.edit_message[Rt](
        reactor, String("c-a"), m.seq, String("u-bob"), String("v2"), T0 + 1
    )
    assert_equal(ed.body, String(""), "the returned EDIT is redacted")
    var stored = s.event[Rt](reactor, String("c-a"), ed.seq)
    assert_equal(stored.value().body, String(""), "the stored EDIT is redacted")
    var msg = s.event[Rt](reactor, String("c-a"), m.seq)
    assert_equal(msg.value().body, String(""))
    assert_false(msg.value().edited)

    var n = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("w1"), Int64(0),
        String(), List[String](), False, List[String](), T0,
    )
    s.db().arm(EDITED_BEFORE_EDIT, String("c-a"), n.seq, 0)
    var ed2 = s.edit_message[Rt](
        reactor, String("c-a"), n.seq, String("u-bob"), String("w2"), T0 + 1
    )
    assert_equal(ed2.body, String("w2"))
    var stored2 = s.event[Rt](reactor, String("c-a"), ed2.seq)
    assert_equal(stored2.value().body, String("w2"), "a live message's edit is kept")
    var msg2 = s.event[Rt](reactor, String("c-a"), n.seq)
    assert_equal(msg2.value().body, String("later"), "the later edit stays")


def test_edit_before_delete() raises:
    var s = _store()
    _channel(s)
    var rt = _rt()
    ref reactor = rt.reactor()
    var m = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("v1"), Int64(0),
        String(), List[String](), False, List[String](), T0,
    )
    s.db().arm(EDITED_BEFORE_DELETE, String("c-a"), m.seq, 0)
    var d = s.delete_message[Rt](
        reactor, String("c-a"), m.seq, String("u-bob"), False, T0 + 1
    )
    assert_equal(d.seq, m.seq + 2, "the DELETE retried past the peer's EDIT")
    var peer = s.event[Rt](reactor, String("c-a"), m.seq + 1)
    assert_equal(peer.value().kind, EVENT_EDIT)
    assert_equal(peer.value().sender_user_id, String("u-peer"))
    assert_equal(peer.value().target_seq, m.seq)
    assert_equal(peer.value().body, String(""), "the late EDIT is redacted")
    assert_equal(
        _count(s, "SELECT COUNT(*) FROM chat_events WHERE body = 'late'"), Int64(0)
    )
    var msg = s.event[Rt](reactor, String("c-a"), m.seq)
    assert_true(msg.value().deleted)
    assert_equal(msg.value().body, String(""))


def test_subject_reclaimed() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.ensure_user[Rt](
        reactor, String("u-d"), String(ISS), String("sub-d"), String("D"), String(""), T0
    )
    _ = s.db().inner.delete_where[Rt](
        reactor, String(T_SUBJECTS), _text("user_id", String("u-d"))
    )
    s.db().arm(SUBJECT_RECLAIMED, subject_key(String(ISS), String("sub-d")), Int64(0), 0)
    var c = s.erase_subject[Rt](reactor, String(ISS), String("sub-d"))
    assert_equal(c.rows_erased, 2, "the user row and the reclaimed subject row")
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-d"))))
    assert_equal(_count(s, "SELECT COUNT(*) FROM chat_subjects"), Int64(0))
    var db = s^.into_db()
    var left = db_blocking_query(db.inner, String("SELECT COUNT(*) FROM chat_users"), List[DbValue]())
    assert_equal(left.row(0).get_int8(0), Int64(0), "the handle the store gives back")


def main() raises:
    test_subject_and_user_vanished()
    test_seq_taken()
    test_edit_races()
    test_edit_before_delete()
    test_subject_reclaimed()
    print("PASS komira_chat_store races")
