# =============================================================================
# test_store_erasure.mojo -- ChatStore's erasure on komira_db_sqlite, the SQL
#   connection steps against a scripted SqlDatabase, and the row decoders'
#   refusal of a result missing a column.
# =============================================================================
#
# Each check would fail on the defect named.
#
#   erase_user     the user's message and edit bodies are redacted (3:
#                  two live messages and an edit; an earlier deleted
#                  message is not counted again) and their messages lose
#                  client_msg_id, the deleted one included; the mention rows
#                  of the user's messages and naming the user, the user's
#                  memberships, cursor, files, user and subject rows are
#                  deleted (7 rows) and the file ids returned; another
#                  user's message, file and mention list are kept; a second
#                  run finds nothing.
#   erased delete  deleting an erased message (deleted, with no DELETE
#                  event) appends its DELETE event.
#   erase_subject  by the subject row; with no subject row, every user row
#                  holding (iss, sub), each erased, their counts and file ids
#                  summed (a dropped file id, row count or redacted-body
#                  count of one user; the users redact 1 and 2 bodies, so
#                  counting users instead of bodies is caught).
#   sql steps      on SQLite, prepare_sql_connection runs `PRAGMA
#                  secure_delete=ON` and refuses an answer other than one
#                  row holding 1; finish_sql_erasure runs `PRAGMA
#                  wal_checkpoint(TRUNCATE)` and refuses an answer other
#                  than one row whose first column is 0 (a reader blocked
#                  it). On another dialect neither runs a statement.
#   decoders       a result without a column the decoder reads is refused
#                  with the column's name.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_db import (
    DbColVal,
    DbRow,
    DbRows,
    DbValue,
    Filter,
    MigrationRunner,
    Order,
    PodNameMinter,
    SqlDatabase,
)
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatStore,
    EVENT_DELETE,
    NoSendProbe,
    chat_migrations,
    finish_sql_erasure,
    prepare_sql_connection,
)
from komira_chat_store.records import (
    channel_from,
    event_from,
    file_from,
    member_from,
    user_from,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = ChatStore[SqliteDatabase, NoSendProbe]
comptime T0: Int64 = 1790000000000
comptime ISS: StaticString = "https://issuer.example"
comptime RETURNED: StaticString = "<the call returned>"
comptime E: StaticString = "komira_chat_store: "


def _rt() raises -> Rt:
    return Rt.new(NoopSink(_placeholder=UInt8(0)))


def _store() raises -> Store:
    var db = SqliteDatabase(String(":memory:"))
    var rt = _rt()
    ref reactor = rt.reactor()
    prepare_sql_connection[Rt, SqliteDatabase](db, reactor)
    var runner = MigrationRunner[SqliteDatabase](db^, String(CHAT_MIGRATION_LEDGER))
    _ = runner.run[Rt](reactor, chat_migrations())
    return Store(runner^.into_db(), NoSendProbe())


def _ids(*xs: StaticString) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _joined(xs: List[String]) -> String:
    var out = String("[")
    for i in range(len(xs)):
        if i > 0:
            out += String(",")
        out += xs[i]
    return out + String("]")


def _sql(mut s: Store, sql: StaticString) raises:
    _ = db_blocking_execute(s.db(), String(sql), List[DbValue]())


def _user(mut s: Store, id: StaticString, sub: StaticString) raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.ensure_user[Rt](
        reactor, String(id), String(ISS), String(sub), String("N"), String(""), T0
    )


def _send(
    mut s: Store,
    sender: StaticString,
    body: StaticString,
    key: StaticString,
    mentions: List[String],
) raises -> Int64:
    var rt = _rt()
    ref reactor = rt.reactor()
    var ev = s.send_message[Rt](
        reactor, String("c-a"), String(sender), String(body), Int64(0),
        String(key), mentions, False, List[String](), T0,
    )
    return ev.seq


def test_erase_user() raises:
    var s = _store()
    _user(s, "u-alice", "sub-alice")
    _user(s, "u-bob", "sub-bob")
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PUBLIC, String("a"), String(""),
        String("u-alice"), _ids("u-bob"), T0,
    )
    var none = List[String]()
    var m3 = _send(s, "u-alice", "early", "k-3", _ids("u-bob"))  # 3
    _ = s.delete_message[Rt](reactor, String("c-a"), m3, String("u-alice"), False, T0)  # 4
    var m1 = _send(s, "u-alice", "first", "k-1", _ids("u-bob"))  # 5
    var m2 = _send(s, "u-alice", "second", "", none)  # 6
    var ed = s.edit_message[Rt](reactor, String("c-a"), m2, String("u-alice"), String("second!"), T0)  # 7
    var b1 = _send(s, "u-bob", "to alice", "k-b", _ids("u-alice"))  # 8
    _ = s.create_file[Rt](
        reactor, String("f-a"), String("c-a"), String("a"), String("t"), Int64(1),
        String("u-alice"), T0,
    )
    _ = s.create_file[Rt](
        reactor, String("f-b"), String("c-a"), String("b"), String("t"), Int64(1),
        String("u-bob"), T0,
    )
    _ = s.mark_read[Rt](reactor, String("c-a"), String("u-alice"), Int64(5))
    _ = s.mark_read[Rt](reactor, String("c-a"), String("u-bob"), Int64(5))

    var c = s.erase_user[Rt](reactor, String("u-alice"))
    assert_equal(c.bodies_redacted, 3, "two messages and one edit")
    assert_equal(c.rows_erased, 7, "2 mentions, member, cursor, file, user, subject")
    assert_equal(_joined(c.file_ids), String("[f-a]"))

    var e1 = s.event[Rt](reactor, String("c-a"), m1)
    assert_equal(e1.value().body, String(""))
    assert_true(e1.value().deleted)
    assert_equal(e1.value().client_msg_id, String(""))
    assert_equal(_joined(e1.value().mention_user_ids), String("[u-bob]"), "kept")
    var e3 = s.event[Rt](reactor, String("c-a"), m3)
    assert_equal(e3.value().client_msg_id, String(""), "the deleted one's key too")
    var e7 = s.event[Rt](reactor, String("c-a"), ed.seq)
    assert_equal(e7.value().body, String(""))
    var e8 = s.event[Rt](reactor, String("c-a"), b1)
    assert_equal(e8.value().body, String("to alice"))
    assert_equal(e8.value().client_msg_id, String("k-b"))
    assert_false(e8.value().deleted)
    assert_equal(_joined(e8.value().mention_user_ids), String("[u-alice]"))
    assert_false(Bool(s.user[Rt](reactor, String("u-alice"))))
    assert_true(Bool(s.user[Rt](reactor, String("u-bob"))))
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-alice"))))
    assert_true(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-bob"))))
    assert_false(s.is_member[Rt](reactor, String("c-a"), String("u-alice")))
    assert_true(s.is_member[Rt](reactor, String("c-a"), String("u-bob")))
    assert_false(Bool(s.file[Rt](reactor, String("f-a"))))
    assert_true(Bool(s.file[Rt](reactor, String("f-b"))))
    assert_equal(len(s.mentions[Rt](reactor, String("u-bob"), T0 + 1, 10).mentions), 0)
    assert_equal(s.read_state[Rt](reactor, String("c-a"), String("u-alice")).read_seq, Int64(0))
    assert_equal(s.read_state[Rt](reactor, String("c-a"), String("u-bob")).read_seq, Int64(5))

    var again = s.erase_user[Rt](reactor, String("u-alice"))
    assert_equal(again.rows_erased, 0)
    assert_equal(again.bodies_redacted, 0)
    assert_equal(len(again.file_ids), 0)

    # The erased message has no DELETE event; deleting it appends one.
    var head = s.head_seq[Rt](reactor, String("c-a"))
    var d = s.delete_message[Rt](reactor, String("c-a"), m1, String("u-admin"), True, T0 + 9)
    assert_equal(d.kind, EVENT_DELETE)
    assert_equal(d.target_seq, m1)
    assert_equal(d.seq, head + 1)
    assert_equal(s.head_seq[Rt](reactor, String("c-a")), head + 1)


def test_erase_subject() raises:
    var s = _store()
    _user(s, "u-carol", "sub-c")
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PUBLIC, String("a"), String(""),
        String("u-carol"), List[String](), T0,
    )
    _ = _send(s, "u-carol", "hi", "", List[String]())
    _ = s.create_file[Rt](
        reactor, String("f-c"), String("c-a"), String("c"), String("t"), Int64(1),
        String("u-carol"), T0,
    )
    var by_subject = s.erase_subject[Rt](reactor, String(ISS), String("sub-c"))
    assert_equal(by_subject.rows_erased, 4, "member, file, user and subject rows")
    assert_equal(by_subject.bodies_redacted, 1)
    assert_equal(_joined(by_subject.file_ids), String("[f-c]"))
    assert_false(Bool(s.user[Rt](reactor, String("u-carol"))))
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-c"))))

    # No subject row: every user row holding (iss, sub) is erased, and only
    # those.
    _user(s, "u-dee", "sub-d")
    _user(s, "u-keep", "sub-k")
    _sql(s, "DELETE FROM chat_subjects WHERE user_id = 'u-dee'")
    _sql(
        s,
        "INSERT INTO chat_users VALUES ('u-dee2', 'https://issuer.example', 'sub-d',"
        " 'D', '', 0)",
    )
    _ = s.create_file[Rt](
        reactor, String("f-d"), String("c-a"), String("d"), String("t"), Int64(1),
        String("u-dee"), T0,
    )
    _ = s.create_file[Rt](
        reactor, String("f-d2"), String("c-a"), String("d"), String("t"), Int64(1),
        String("u-dee2"), T0,
    )
    _ = s.add_member[Rt](reactor, String("c-a"), String("u-dee"), T0)
    _ = s.add_member[Rt](reactor, String("c-a"), String("u-dee2"), T0)
    _ = _send(s, "u-dee", "d1", "", List[String]())
    _ = _send(s, "u-dee2", "d2", "", List[String]())
    _ = _send(s, "u-dee2", "d3", "", List[String]())
    var by_rows = s.erase_subject[Rt](reactor, String(ISS), String("sub-d"))
    assert_equal(
        by_rows.rows_erased, 6, "two user rows, their two memberships and two files"
    )
    assert_equal(
        by_rows.bodies_redacted, 3, "u-dee's message and u-dee2's two (not one per user)"
    )
    assert_equal(_joined(by_rows.file_ids), String("[f-d,f-d2]"), "both users' files")
    assert_false(Bool(s.user[Rt](reactor, String("u-dee"))))
    assert_false(Bool(s.user[Rt](reactor, String("u-dee2"))))
    assert_true(Bool(s.user[Rt](reactor, String("u-keep"))))
    var nothing = s.erase_subject[Rt](reactor, String(ISS), String("sub-none"))
    assert_equal(nothing.rows_erased, 0)


# ---- the SQL steps, against a scripted connection ---------------------------


struct ScriptedSql[DIALECT: StaticString](SqlDatabase):
    """A SqlDatabase whose `query` records its statement and answers with
    `rows` rows (0 or 1) holding `answer`. No other method is called."""

    var answer: Int64
    var rows: Int
    var statements: List[String]

    def __init__(out self, answer: Int64, rows: Int):
        self.answer = answer
        self.rows = rows
        self.statements = List[String]()

    def begin[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        raise Error("unused")

    def commit[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        raise Error("unused")

    def rollback[RT: Runtime](mut self, mut reactor: Reactor[RT.Sink]) raises:
        raise Error("unused")

    def get_by_key[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], key_col: String, key_val: DbValue
    ) raises -> Optional[DbRow]:
        raise Error("unused")

    def put[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], vals: List[DbValue]) raises -> UInt64:
        raise Error("unused")

    def delete_by_key[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, key_col: String, key_val: DbValue) raises -> UInt64:
        raise Error("unused")

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
        raise Error("unused")

    def query_rows_locked[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], table: String, cols: List[String], filter: Filter, order: List[Order]
    ) raises -> DbRows:
        raise Error("unused")

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
        raise Error("unused")

    def delete_where[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], table: String, filter: Filter) raises -> UInt64:
        raise Error("unused")

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
        raise Error("unused")

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
        raise Error("unused")

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
        raise Error("unused")

    def execute[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]) raises -> UInt64:
        raise Error("unused")

    def query[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]) raises -> DbRows:
        self.statements.append(sql)
        var names = List[String]()
        names.append(String("x"))
        var rows = List[DbRow]()
        for _ in range(self.rows):
            var v = List[DbValue]()
            v.append(DbValue.int8(self.answer))
            rows.append(DbRow.from_values(v, names))
        return DbRows(rows^, names^)

    def query_opt[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]) raises -> Optional[DbRow]:
        raise Error("unused")

    def query_one[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String, params: List[DbValue]) raises -> DbRow:
        raise Error("unused")

    @staticmethod
    def dialect() -> String:
        return String(Self.DIALECT)

    @staticmethod
    def placeholder(i: Int) -> String:
        return String("?") + String(i + 1)

    @staticmethod
    def now_expr() -> String:
        return String("0")

    def claim_pending[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        table: String,
        n: Int,
        pending: String,
        assigned: String,
        extra_set: String,
        params: List[DbValue],
        phase_col: String,
    ) raises -> DbRows:
        raise Error("unused")


comptime SqliteFake = ScriptedSql["sqlite"]
comptime PgFake = ScriptedSql["pg"]


def _prepare[D: SqlDatabase](mut db: D) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        prepare_sql_connection[Rt, D](db, reactor)
    except e:
        return String(e)
    return String(RETURNED)


def _finish[D: SqlDatabase](mut db: D) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        finish_sql_erasure[Rt, D](db, reactor)
    except e:
        return String(e)
    return String(RETURNED)


def test_sql_steps() raises:
    var took = SqliteFake(Int64(1), 1)
    assert_equal(_prepare(took), String(RETURNED))
    assert_equal(_joined(took.statements), String("[PRAGMA secure_delete=ON]"))
    var refused = String(E) + String("PRAGMA secure_delete=ON did not take")
    var zero = SqliteFake(Int64(0), 1)
    assert_equal(_prepare(zero), refused)
    var no_row = SqliteFake(Int64(1), 0)
    assert_equal(_prepare(no_row), refused)
    var pg = PgFake(Int64(0), 0)
    assert_equal(_prepare(pg), String(RETURNED))
    assert_equal(len(pg.statements), 0, "another dialect runs nothing")

    var done = SqliteFake(Int64(0), 1)
    assert_equal(_finish(done), String(RETURNED))
    assert_equal(_joined(done.statements), String("[PRAGMA wal_checkpoint(TRUNCATE)]"))
    var blocked_text = (
        String(E)
        + String("PRAGMA wal_checkpoint(TRUNCATE) was blocked; the erased")
        + String(" bytes may remain in the write-ahead log")
    )
    var blocked = SqliteFake(Int64(1), 1)
    assert_equal(_finish(blocked), blocked_text)
    var silent = SqliteFake(Int64(0), 0)
    assert_equal(_finish(silent), blocked_text)
    var pg2 = PgFake(Int64(1), 1)
    assert_equal(_finish(pg2), String(RETURNED))
    assert_equal(len(pg2.statements), 0)


# ---- the row decoders --------------------------------------------------------


def _rows_without(missing: StaticString) -> DbRows:
    """One row of every column the decoders read, except `missing`."""
    var names = _ids(
        "user_id", "iss", "sub", "display_name", "email", "created_at_ms",
        "channel_id", "kind", "name", "topic", "archived", "created_by",
        "dm_user_ids", "joined_at_ms", "seq", "sender_user_id", "body",
        "thread_root_seq", "target_seq", "client_msg_id", "mention_user_ids",
        "mentions_channel", "file_ids", "edited", "deleted", "file_id",
        "content_type", "size_bytes", "state", "uploader_user_id",
    )
    var all = List[String]()
    for i in range(len(names)):
        if names[i] != String(missing):
            all.append(names[i])
    var v = List[DbValue]()
    for _ in range(len(all)):
        v.append(DbValue.int8(Int64(1)))
    var rows = List[DbRow]()
    rows.append(DbRow.from_values(v, all))
    return DbRows(rows^, all^)


def test_decoders_name_a_missing_column() raises:
    var want = String(E) + String("result has no column ")
    var got = String(RETURNED)
    try:
        _ = user_from(_rows_without("email"), 0)
    except e:
        got = String(e)
    assert_equal(got, want + String("email"))
    got = String(RETURNED)
    try:
        _ = channel_from(_rows_without("dm_user_ids"), 0)
    except e:
        got = String(e)
    assert_equal(got, want + String("dm_user_ids"))
    got = String(RETURNED)
    try:
        _ = member_from(_rows_without("joined_at_ms"), 0)
    except e:
        got = String(e)
    assert_equal(got, want + String("joined_at_ms"))
    got = String(RETURNED)
    try:
        _ = event_from(_rows_without("deleted"), 0)
    except e:
        got = String(e)
    assert_equal(got, want + String("deleted"))
    got = String(RETURNED)
    try:
        _ = file_from(_rows_without("uploader_user_id"), 0)
    except e:
        got = String(e)
    assert_equal(got, want + String("uploader_user_id"))
    # With every column present each decodes.
    var full = _rows_without("none")
    assert_equal(member_from(full, 0).joined_at_ms, Int64(1))
    assert_equal(file_from(full, 0).size_bytes, Int64(1))


def main() raises:
    test_erase_user()
    test_erase_subject()
    test_sql_steps()
    test_decoders_name_a_missing_column()
    print("PASS komira_chat_store erasure")
