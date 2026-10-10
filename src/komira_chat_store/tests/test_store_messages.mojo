# =============================================================================
# test_store_messages.mojo -- ChatStore's files, sends, edits and deletes on
#   komira_db_sqlite, from the library's own tests.
# =============================================================================
#
# One in-memory SQLite database per check. Each would fail on the defect
# named.
#
#   files     a new file is PENDING with every field read back; completing
#             sets COMPLETE and the size once (a second completion changes
#             nothing); each refusal (malformed file or uploader id, no such
#             channel, a taken id, completing a file that does not exist);
#             delete reports whether it removed a row.
#   attach    a send may attach only a COMPLETE file of its channel: a
#             PENDING file, another channel's file, a missing file and a
#             malformed id are each refused.
#   send      every field of the MESSAGE event read back; a non-member and
#             a malformed mention are refused; a client_msg_id of 128 bytes
#             is taken and of 129 refused; a retry with the key returns the
#             first event and writes its mention rows again, unless it has
#             been deleted since; another sender's key is not deduplicated.
#   edit      the EDIT event and the MESSAGE row's new body; a later edit
#             wins; editing another's, a deleted, a missing message or a
#             JOIN is refused.
#   delete    redacts the message and its edits' bodies and drops its
#             mention rows; another's message needs `any_sender`, which
#             also skips the membership check; a second delete returns the
#             first DELETE event and appends nothing.
#   head      the head of a channel with no event is 0.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbValue, MigrationRunner
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatStore,
    EVENT_DELETE,
    EVENT_EDIT,
    EVENT_MESSAGE,
    FILE_COMPLETE,
    FILE_PENDING,
    NoSendProbe,
    chat_migrations,
    prepare_sql_connection,
)

comptime Rt = BlockingRuntime[NoopSink]
comptime Store = ChatStore[SqliteDatabase, NoSendProbe]
comptime T0: Int64 = 1790000000000
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


def _two_channels(mut s: Store) raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PUBLIC, String("a"), String(""),
        String("u-alice"), _ids("u-bob"), T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-b"), CHANNEL_PUBLIC, String("b"), String(""),
        String("u-alice"), List[String](), T0,
    )


def _send(
    mut s: Store,
    channel_id: StaticString,
    sender: StaticString,
    body: StaticString,
    key: String,
    mentions: List[String],
    files: List[String],
    now_ms: Int64,
) raises -> Int64:
    var rt = _rt()
    ref reactor = rt.reactor()
    var ev = s.send_message[Rt](
        reactor, String(channel_id), String(sender), String(body), Int64(0),
        key, mentions, False, files, now_ms,
    )
    return ev.seq


def _send_err(
    mut s: Store,
    channel_id: StaticString,
    sender: StaticString,
    key: String,
    mentions: List[String],
    files: List[String],
) -> String:
    try:
        _ = _send(s, channel_id, sender, "x", key, mentions, files, T0)
    except e:
        return String(e)
    return String(RETURNED)


def _file_err(
    mut s: Store, file_id: StaticString, channel_id: StaticString, uploader: StaticString
) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.create_file[Rt](
            reactor, String(file_id), String(channel_id), String("n"), String("t"),
            Int64(1), String(uploader), T0,
        )
    except e:
        return String(e)
    return String(RETURNED)


def test_files_and_attachments() raises:
    var s = _store()
    _two_channels(s)
    var rt = _rt()
    ref reactor = rt.reactor()
    var f = s.create_file[Rt](
        reactor, String("f-1"), String("c-a"), String("a.png"), String("image/png"),
        Int64(10), String("u-alice"), T0 + 1,
    )
    assert_equal(f.state, FILE_PENDING)
    var back = s.file[Rt](reactor, String("f-1"))
    ref b = back.value()
    assert_equal(b.file_id, String("f-1"))
    assert_equal(b.channel_id, String("c-a"))
    assert_equal(b.name, String("a.png"))
    assert_equal(b.content_type, String("image/png"))
    assert_equal(b.size_bytes, Int64(10))
    assert_equal(b.state, FILE_PENDING)
    assert_equal(b.uploader_user_id, String("u-alice"))
    assert_equal(b.created_at_ms, T0 + 1)
    assert_false(Bool(s.file[Rt](reactor, String("f-none"))))

    assert_equal(_file_err(s, "f.2", "c-a", "u-alice"), String(E) + String('invalid file id "f.2"'))
    assert_equal(_file_err(s, "f-2", "c-a", "u/a"), String(E) + String('invalid user id "u/a"'))
    assert_equal(_file_err(s, "f-2", "c-none", "u-alice"), String(E) + String("no channel c-none"))
    assert_equal(_file_err(s, "f-1", "c-b", "u-alice"), String(E) + String("file f-1 already exists"))
    assert_false(Bool(s.file[Rt](reactor, String("f-2"))), "refusals write nothing")

    # A PENDING file cannot be attached.
    assert_equal(
        _send_err(s, "c-a", "u-alice", String(), List[String](), _ids("f-1")),
        String(E) + String("file f-1 is not a complete file of channel c-a"),
    )
    var done = s.complete_file[Rt](reactor, String("f-1"), Int64(12))
    assert_equal(done.state, FILE_COMPLETE)
    assert_equal(done.size_bytes, Int64(12))
    var twice = s.complete_file[Rt](reactor, String("f-1"), Int64(99))
    assert_equal(twice.size_bytes, Int64(12), "a COMPLETE file is left as it is")
    var err = String(RETURNED)
    try:
        _ = s.complete_file[Rt](reactor, String("f-none"), Int64(1))
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("no file f-none"))

    _ = s.create_file[Rt](
        reactor, String("f-b"), String("c-b"), String("b"), String("t"),
        Int64(1), String("u-alice"), T0,
    )
    _ = s.complete_file[Rt](reactor, String("f-b"), Int64(1))
    assert_equal(
        _send_err(s, "c-a", "u-alice", String(), List[String](), _ids("f-1", "f-b")),
        String(E) + String("file f-b is not a complete file of channel c-a"),
    )
    assert_equal(
        _send_err(s, "c-a", "u-alice", String(), List[String](), _ids("f-gone")),
        String(E) + String("file f-gone is not a complete file of channel c-a"),
    )
    assert_equal(
        _send_err(s, "c-a", "u-alice", String(), List[String](), _ids("f,1")),
        String(E) + String('invalid file id "f,1"'),
    )
    var seq = _send(s, "c-a", "u-alice", "see", String(), List[String](), _ids("f-1"), T0)
    var ev = s.event[Rt](reactor, String("c-a"), seq)
    assert_equal(_joined(ev.value().file_ids), String("[f-1]"))

    assert_true(s.delete_file[Rt](reactor, String("f-b")))
    assert_false(s.delete_file[Rt](reactor, String("f-b")))
    assert_false(Bool(s.file[Rt](reactor, String("f-b"))))
    assert_true(Bool(s.file[Rt](reactor, String("f-1"))), "only that file")


def test_send() raises:
    var s = _store()
    _two_channels(s)
    var rt = _rt()
    ref reactor = rt.reactor()
    assert_equal(s.head_seq[Rt](reactor, String("c-none")), Int64(0))
    var ev = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("hello"), Int64(0),
        String("k-1"), _ids("u-alice"), True, List[String](), T0 + 7,
    )
    assert_equal(ev.seq, Int64(3), "after the two JOINs")
    var back = s.event[Rt](reactor, String("c-a"), Int64(3))
    ref m = back.value()
    assert_equal(m.channel_id, String("c-a"))
    assert_equal(m.seq, Int64(3))
    assert_equal(m.kind, EVENT_MESSAGE)
    assert_equal(m.sender_user_id, String("u-bob"))
    assert_equal(m.body, String("hello"))
    assert_equal(m.thread_root_seq, Int64(0))
    assert_equal(m.target_seq, Int64(0))
    assert_equal(m.client_msg_id, String("k-1"))
    assert_equal(_joined(m.mention_user_ids), String("[u-alice]"))
    assert_true(m.mentions_channel)
    assert_equal(len(m.file_ids), 0)
    assert_equal(m.created_at_ms, T0 + 7)
    assert_false(m.edited)
    assert_false(m.deleted)
    assert_false(Bool(s.event[Rt](reactor, String("c-a"), Int64(4))))
    assert_equal(s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 10).mentions[0].seq, Int64(3))

    assert_equal(
        _send_err(s, "c-a", "u-carol", String(), List[String](), List[String]()),
        String(E) + String("u-carol is not a member of channel c-a"),
    )
    assert_equal(
        _send_err(s, "c-a", "u-bob", String(), _ids("u-alice", "u.x"), List[String]()),
        String(E) + String('invalid user id "u.x"'),
    )
    assert_equal(
        _send_err(s, "c-none", "u-bob", String(), List[String](), List[String]()),
        String(E) + String("no channel c-none"),
    )
    var k128 = String()
    for _ in range(128):
        k128 += String("k")
    var long_seq = _send(s, "c-a", "u-bob", "x", k128, List[String](), List[String](), T0)
    assert_equal(long_seq, Int64(4), "a key of 128 bytes is taken")
    assert_equal(
        _send_err(s, "c-a", "u-bob", k128 + String("k"), List[String](), List[String]()),
        String(E) + String("client_msg_id is longer than 128 bytes"),
    )
    assert_equal(s.head_seq[Rt](reactor, String("c-a")), Int64(4), "refusals append nothing")

    # A retry of k-1 returns the first event and writes its mention rows again.
    _sql(s, "DELETE FROM chat_mentions")
    var retry = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("hello again"), Int64(0),
        String("k-1"), _ids("u-carol"), False, List[String](), T0 + 50,
    )
    assert_equal(retry.seq, Int64(3))
    assert_equal(retry.body, String("hello"))
    assert_equal(s.head_seq[Rt](reactor, String("c-a")), Int64(4), "nothing appended")
    var again = s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 10)
    assert_equal(len(again.mentions), 1, "the first event's mention row is back")
    assert_equal(again.mentions[0].created_at_ms, T0 + 7)
    assert_equal(len(s.mentions[Rt](reactor, String("u-carol"), T0 + 100, 10).mentions), 0)
    # The same key from another sender is another message.
    var alice_k1 = _send(s, "c-a", "u-alice", "mine", String("k-1"), List[String](), List[String](), T0)
    assert_equal(alice_k1, Int64(5))
    # An empty key never deduplicates.
    var e1 = _send(s, "c-a", "u-alice", "a", String(), List[String](), List[String](), T0)
    var e2 = _send(s, "c-a", "u-alice", "a", String(), List[String](), List[String](), T0)
    assert_equal(e2, e1 + 1)

    # Once deleted, a retry returns the deleted event and writes no mention.
    _ = s.delete_message[Rt](reactor, String("c-a"), Int64(3), String("u-bob"), False, T0 + 60)
    var gone = s.send_message[Rt](
        reactor, String("c-a"), String("u-bob"), String("hello"), Int64(0),
        String("k-1"), _ids("u-alice"), False, List[String](), T0 + 70,
    )
    assert_equal(gone.seq, Int64(3))
    assert_true(gone.deleted)
    assert_equal(len(s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 10).mentions), 0)


def _edit_err(mut s: Store, seq: Int64, editor: StaticString) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.edit_message[Rt](reactor, String("c-a"), seq, String(editor), String("e"), T0)
    except e:
        return String(e)
    return String(RETURNED)


def _delete_err(mut s: Store, seq: Int64, by: StaticString, any_sender: Bool) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.delete_message[Rt](reactor, String("c-a"), seq, String(by), any_sender, T0)
    except e:
        return String(e)
    return String(RETURNED)


def test_edit_and_delete() raises:
    var s = _store()
    _two_channels(s)
    var rt = _rt()
    ref reactor = rt.reactor()
    var m = _send(s, "c-a", "u-bob", "v1", String(), _ids("u-alice"), List[String](), T0 + 1)
    var e1 = s.edit_message[Rt](reactor, String("c-a"), m, String("u-bob"), String("v2"), T0 + 2)
    assert_equal(e1.kind, EVENT_EDIT)
    assert_equal(e1.seq, m + 1)
    assert_equal(e1.target_seq, m)
    assert_equal(e1.body, String("v2"))
    assert_equal(e1.sender_user_id, String("u-bob"))
    assert_equal(e1.created_at_ms, T0 + 2)
    var now = s.event[Rt](reactor, String("c-a"), m)
    assert_equal(now.value().body, String("v2"))
    assert_true(now.value().edited)
    var e2 = s.edit_message[Rt](reactor, String("c-a"), m, String("u-bob"), String("v3"), T0 + 3)
    assert_equal(e2.body, String("v3"))
    now = s.event[Rt](reactor, String("c-a"), m)
    assert_equal(now.value().body, String("v3"), "the later edit wins")

    assert_equal(_edit_err(s, m, "u-alice"), String("komira_chat_store: u-alice did not send message 3"))
    assert_equal(_edit_err(s, Int64(1), "u-alice"), String(E) + String("channel c-a has no message at seq 1"))
    assert_equal(_edit_err(s, Int64(99), "u-alice"), String(E) + String("channel c-a has no message at seq 99"))
    assert_equal(_edit_err(s, m, "u-carol"), String(E) + String("u-carol is not a member of channel c-a"))
    assert_equal(_delete_err(s, m, "u-alice", False), String(E) + String("u-alice did not send message 3"))
    assert_equal(_delete_err(s, m, "u-carol", False), String(E) + String("u-carol is not a member of channel c-a"))
    assert_equal(_delete_err(s, Int64(2), "u-bob", True), String(E) + String("channel c-a has no message at seq 2"))
    assert_equal(s.head_seq[Rt](reactor, String("c-a")), m + 2, "refusals append nothing")

    # A non-member admin deletes it with any_sender.
    var d = s.delete_message[Rt](reactor, String("c-a"), m, String("u-admin"), True, T0 + 4)
    assert_equal(d.kind, EVENT_DELETE)
    assert_equal(d.seq, m + 3)
    assert_equal(d.target_seq, m)
    assert_equal(d.sender_user_id, String("u-admin"))
    assert_equal(d.created_at_ms, T0 + 4)
    var msg = s.event[Rt](reactor, String("c-a"), m)
    assert_true(msg.value().deleted)
    assert_equal(msg.value().body, String(""))
    var ed1 = s.event[Rt](reactor, String("c-a"), m + 1)
    var ed2 = s.event[Rt](reactor, String("c-a"), m + 2)
    assert_equal(ed1.value().body, String(""), "an edit's body is redacted")
    assert_equal(ed2.value().body, String(""))
    assert_equal(len(s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 10).mentions), 0)
    var d2 = s.delete_message[Rt](reactor, String("c-a"), m, String("u-bob"), False, T0 + 5)
    assert_equal(d2.seq, d.seq, "the first DELETE event")
    assert_equal(d2.sender_user_id, String("u-admin"))
    assert_equal(s.head_seq[Rt](reactor, String("c-a")), d.seq, "nothing appended")
    assert_equal(_edit_err(s, m, "u-bob"), String(E) + String("message 3 is deleted"))

    # The sender deletes their own message without any_sender; other
    # messages keep their bodies.
    var keep = _send(s, "c-a", "u-alice", "keep", String(), List[String](), List[String](), T0)
    var own = _send(s, "c-a", "u-bob", "own", String(), List[String](), List[String](), T0)
    _ = s.edit_message[Rt](reactor, String("c-a"), keep, String("u-alice"), String("kept"), T0)
    var d3 = s.delete_message[Rt](reactor, String("c-a"), own, String("u-bob"), False, T0)
    assert_equal(d3.target_seq, own)
    var kept = s.event[Rt](reactor, String("c-a"), keep)
    assert_equal(kept.value().body, String("kept"))
    var kept_edit = s.event[Rt](reactor, String("c-a"), own + 1)
    assert_equal(kept_edit.value().body, String("kept"), "another message's edit")


def main() raises:
    test_files_and_attachments()
    test_send()
    test_edit_and_delete()
    print("PASS komira_chat_store messages")
