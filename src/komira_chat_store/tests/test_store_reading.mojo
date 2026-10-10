# =============================================================================
# test_store_reading.mojo -- ChatStore's pages, threads, mentions, read
#   cursors and read state on komira_db_sqlite, from the library's own tests.
# =============================================================================
#
# One in-memory SQLite database per check. Each would fail on the defect
# named.
#
#   paging    events_after and events_before return the right seqs, oldest
#             first, with `has_more` set only when a row lies beyond the
#             page and the channel's head; a page size of 0 or 10001 is
#             refused and 10000 is taken.
#   threads   a reply needs a top-level, live MESSAGE as its root (a reply,
#             a JOIN, a missing seq and a deleted message are refused); the
#             thread page holds the replies only, paged.
#   mentions  the order is newest first, then channel, then seq; a page
#             never splits a millisecond: a page whose next row is of
#             another millisecond ends there, a partial last millisecond
#             moves to the next page, and a millisecond larger than the page
#             is returned whole (with and without older mentions after it).
#   cursor    mark_read moves forward only; read state counts other users'
#             live MESSAGE events after the cursor, and of those the ones
#             naming the user or the channel. 300 unread messages need two
#             batches of 256.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import MigrationRunner
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatEvent,
    ChatStore,
    MentionPage,
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


def _seqs(evs: List[ChatEvent]) -> String:
    var out = String("[")
    for i in range(len(evs)):
        if i > 0:
            out += String(",")
        out += String(evs[i].seq)
    return out + String("]")


def _channel(mut s: Store, id: StaticString) raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String(id), CHANNEL_PUBLIC, String("n"), String(""),
        String("u-alice"), _ids("u-bob"), T0,
    )


def _post(
    mut s: Store,
    channel_id: StaticString,
    sender: StaticString,
    root: Int64,
    mentions: List[String],
    everyone: Bool,
    now_ms: Int64,
) raises -> Int64:
    var rt = _rt()
    ref reactor = rt.reactor()
    var ev = s.send_message[Rt](
        reactor, String(channel_id), String(sender), String("m"), root,
        String(), mentions, everyone, List[String](), now_ms,
    )
    return ev.seq


def _post_err(mut s: Store, root: Int64) -> String:
    try:
        _ = _post(s, "c-a", "u-bob", root, List[String](), False, T0)
    except e:
        return String(e)
    return String(RETURNED)


def _after_err(mut s: Store, n: Int) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.events_after[Rt](reactor, String("c-a"), Int64(0), n)
    except e:
        return String(e)
    return String(RETURNED)


def test_paging() raises:
    var s = _store()
    _channel(s, "c-a")
    for i in range(4):
        _ = _post(s, "c-a", "u-bob", Int64(0), List[String](), False, T0 + Int64(i))
    var rt = _rt()
    ref reactor = rt.reactor()
    # Seqs 1..6: two JOINs, four messages.
    var a = s.events_after[Rt](reactor, String("c-a"), Int64(0), 2)
    assert_equal(_seqs(a.events), String("[1,2]"))
    assert_true(a.has_more)
    assert_equal(a.head_seq, Int64(6))
    var a2 = s.events_after[Rt](reactor, String("c-a"), Int64(4), 2)
    assert_equal(_seqs(a2.events), String("[5,6]"))
    assert_false(a2.has_more, "the page is exactly the rest")
    var a3 = s.events_after[Rt](reactor, String("c-a"), Int64(3), 5)
    assert_equal(_seqs(a3.events), String("[4,5,6]"))
    assert_false(a3.has_more)
    var b = s.events_before[Rt](reactor, String("c-a"), Int64(7), 2)
    assert_equal(_seqs(b.events), String("[5,6]"), "the newest, oldest first")
    assert_true(b.has_more)
    assert_equal(b.head_seq, Int64(6))
    var b2 = s.events_before[Rt](reactor, String("c-a"), Int64(3), 2)
    assert_equal(_seqs(b2.events), String("[1,2]"))
    assert_false(b2.has_more)
    var b3 = s.events_before[Rt](reactor, String("c-a"), Int64(4), 5)
    assert_equal(_seqs(b3.events), String("[1,2,3]"))
    assert_false(b3.has_more)
    var empty = s.events_after[Rt](reactor, String("c-none"), Int64(0), 5)
    assert_equal(len(empty.events), 0)
    assert_equal(empty.head_seq, Int64(0))

    assert_equal(_after_err(s, 0), String(E) + String("max_events must be at least 1, got 0"))
    assert_equal(
        _after_err(s, 10001),
        String(E) + String("max_events must be at most 10000, got 10001"),
    )
    assert_equal(_after_err(s, 10000), String(RETURNED))
    assert_equal(_after_err(s, 1), String(RETURNED))
    var err = String(RETURNED)
    try:
        _ = s.events_before[Rt](reactor, String("c-a"), Int64(3), 0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("max_events must be at least 1, got 0"))
    err = String(RETURNED)
    try:
        _ = s.users[Rt](reactor, String(""), 0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("max_ids must be at least 1, got 0"))
    err = String(RETURNED)
    try:
        _ = s.mentions[Rt](reactor, String("u-alice"), T0, 10001)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("max_mentions must be at most 10000, got 10001"))


def test_threads() raises:
    var s = _store()
    _channel(s, "c-a")
    var root = _post(s, "c-a", "u-alice", Int64(0), List[String](), False, T0)
    var r1 = _post(s, "c-a", "u-bob", root, List[String](), False, T0 + 1)
    _ = _post(s, "c-a", "u-alice", Int64(0), List[String](), False, T0 + 2)
    var r2 = _post(s, "c-a", "u-alice", root, List[String](), False, T0 + 3)
    var r3 = _post(s, "c-a", "u-bob", root, List[String](), False, T0 + 4)
    var rt = _rt()
    ref reactor = rt.reactor()
    var reply = s.event[Rt](reactor, String("c-a"), r1)
    assert_equal(reply.value().thread_root_seq, root)
    var t = s.thread[Rt](reactor, String("c-a"), root, Int64(0), 10)
    assert_equal(_seqs(t.events), String("[4,6,7]"))
    assert_false(t.has_more)
    assert_equal(t.head_seq, Int64(7))
    var t1 = s.thread[Rt](reactor, String("c-a"), root, Int64(0), 2)
    assert_equal(_seqs(t1.events), String("[4,6]"))
    assert_true(t1.has_more)
    var t2 = s.thread[Rt](reactor, String("c-a"), root, r2, 2)
    assert_equal(_seqs(t2.events), String("[7]"))
    assert_false(t2.has_more)
    _ = r3
    var bad = String("komira_chat_store: thread root ")
    assert_equal(_post_err(s, r1), bad + String("4 is not a top-level message of channel c-a"))
    assert_equal(_post_err(s, Int64(1)), bad + String("1 is not a top-level message of channel c-a"))
    assert_equal(_post_err(s, Int64(99)), bad + String("99 is not a top-level message of channel c-a"))
    var other = _post(s, "c-a", "u-bob", Int64(0), List[String](), False, T0)
    _ = s.delete_message[Rt](reactor, String("c-a"), other, String("u-bob"), False, T0)
    assert_equal(
        _post_err(s, other),
        bad + String(other) + String(" is not a top-level message of channel c-a"),
    )


def _refs(p: MentionPage) -> String:
    var out = String("[")
    for i in range(len(p.mentions)):
        if i > 0:
            out += String(",")
        out += p.mentions[i].channel_id + String(":") + String(p.mentions[i].seq)
        out += String("@") + String(p.mentions[i].created_at_ms - T0)
    return out + String("]")


def test_mention_order() raises:
    var s = _store()
    _channel(s, "c-a")
    _channel(s, "c-b")
    var al = _ids("u-alice")
    # One millisecond across two channels, sent in an order the view is not.
    _ = _post(s, "c-b", "u-bob", Int64(0), al, False, T0 + 5)  # c-b:3
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 9)  # c-a:3
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 5)  # c-a:4
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 5)  # c-a:5
    _ = _post(s, "c-b", "u-bob", Int64(0), al, False, T0 + 1)  # c-b:4
    var rt = _rt()
    ref reactor = rt.reactor()
    var p = s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 10)
    assert_equal(_refs(p), String("[c-a:3@9,c-a:4@5,c-a:5@5,c-b:3@5,c-b:4@1]"))
    assert_equal(p.next_before_ms, Int64(0))
    var before = s.mentions[Rt](reactor, String("u-alice"), T0 + 5, 10)
    assert_equal(_refs(before), String("[c-b:4@1]"), "strictly before")
    var bob = s.mentions[Rt](reactor, String("u-bob"), T0 + 100, 10)
    assert_equal(len(bob.mentions), 0)


def test_mention_pages() raises:
    var s = _store()
    _channel(s, "c-a")
    var al = _ids("u-alice")
    var rt = _rt()
    ref reactor = rt.reactor()
    # ms 30, 20, 10: a page of 2 ends at 20, whose mentions it holds all of.
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 10)  # 3
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 20)  # 4
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 30)  # 5
    var p = s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 2)
    assert_equal(_refs(p), String("[c-a:5@30,c-a:4@20]"))
    assert_equal(p.next_before_ms, T0 + 20)
    var q = s.mentions[Rt](reactor, String("u-alice"), p.next_before_ms, 2)
    assert_equal(_refs(q), String("[c-a:3@10]"))
    assert_equal(q.next_before_ms, Int64(0))
    var exact = s.mentions[Rt](reactor, String("u-alice"), T0 + 25, 2)
    assert_equal(_refs(exact), String("[c-a:4@20,c-a:3@10]"))
    assert_equal(exact.next_before_ms, Int64(0), "exactly a page")

    # A second mention at 20: the page of 2 would split 20, so it ends at 30.
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 20)  # 6
    var r = s.mentions[Rt](reactor, String("u-alice"), T0 + 100, 2)
    assert_equal(_refs(r), String("[c-a:5@30]"))
    assert_equal(r.next_before_ms, T0 + 21)
    var r2 = s.mentions[Rt](reactor, String("u-alice"), r.next_before_ms, 2)
    assert_equal(_refs(r2), String("[c-a:4@20,c-a:6@20]"))
    assert_equal(r2.next_before_ms, T0 + 20)

    # A third at 20: one millisecond fills the page and is returned whole,
    # with older mentions still to come.
    _ = _post(s, "c-a", "u-bob", Int64(0), al, False, T0 + 20)  # 7
    var w = s.mentions[Rt](reactor, String("u-alice"), T0 + 21, 2)
    assert_equal(_refs(w), String("[c-a:4@20,c-a:6@20,c-a:7@20]"))
    assert_equal(w.next_before_ms, T0 + 20)
    var w2 = s.mentions[Rt](reactor, String("u-alice"), w.next_before_ms, 2)
    assert_equal(_refs(w2), String("[c-a:3@10]"))
    # ... and with none older: the last page.
    var u = s.mentions[Rt](reactor, String("u-bob"), T0 + 100, 1)
    assert_equal(len(u.mentions), 0)
    _ = _post(s, "c-a", "u-alice", Int64(0), _ids("u-bob"), False, T0 + 40)  # 8
    _ = _post(s, "c-a", "u-alice", Int64(0), _ids("u-bob"), False, T0 + 40)  # 9
    var v = s.mentions[Rt](reactor, String("u-bob"), T0 + 100, 1)
    assert_equal(_refs(v), String("[c-a:8@40,c-a:9@40]"))
    assert_equal(v.next_before_ms, Int64(0))


def test_cursor_and_read_state() raises:
    var s = _store()
    _channel(s, "c-a")
    _channel(s, "c-b")
    var rt = _rt()
    ref reactor = rt.reactor()
    var none = List[String]()
    var fresh = s.read_state[Rt](reactor, String("c-a"), String("u-alice"))
    assert_equal(fresh.read_seq, Int64(0))
    assert_equal(fresh.unread_count, 0, "JOINs are not unread")
    assert_equal(fresh.channel_id, String("c-a"))
    assert_equal(s.mark_read[Rt](reactor, String("c-a"), String("u-alice"), Int64(2)), Int64(2))
    _ = _post(s, "c-a", "u-bob", Int64(0), none, False, T0)  # 3 unread
    _ = _post(s, "c-a", "u-alice", Int64(0), none, False, T0)  # 4 her own
    var gone = _post(s, "c-a", "u-bob", Int64(0), _ids("u-alice"), False, T0)  # 5
    _ = s.delete_message[Rt](reactor, String("c-a"), gone, String("u-bob"), False, T0)  # 6
    _ = _post(s, "c-a", "u-bob", Int64(0), _ids("u-carol", "u-alice"), False, T0)  # 7
    _ = _post(s, "c-a", "u-bob", Int64(0), none, True, T0)  # 8 @channel
    _ = _post(s, "c-a", "u-bob", Int64(0), _ids("u-carol"), False, T0)  # 9
    var rs = s.read_state[Rt](reactor, String("c-a"), String("u-alice"))
    assert_equal(rs.read_seq, Int64(2))
    assert_equal(rs.unread_count, 4, "3, 7, 8, 9")
    assert_equal(rs.mention_count, 2, "7 names her, 8 the channel")
    var other = s.read_state[Rt](reactor, String("c-b"), String("u-alice"))
    assert_equal(other.unread_count, 0, "per channel")
    assert_equal(other.read_seq, Int64(0), "per channel")

    assert_equal(s.mark_read[Rt](reactor, String("c-a"), String("u-alice"), Int64(7)), Int64(7))
    assert_equal(
        s.mark_read[Rt](reactor, String("c-a"), String("u-alice"), Int64(3)),
        Int64(7),
        "never backward",
    )
    assert_equal(s.mark_read[Rt](reactor, String("c-a"), String("u-bob"), Int64(1)), Int64(1))
    var after = s.read_state[Rt](reactor, String("c-a"), String("u-alice"))
    assert_equal(after.read_seq, Int64(7))
    assert_equal(after.unread_count, 2)
    assert_equal(after.mention_count, 1)


def test_read_state_batches() raises:
    var s = _store()
    _channel(s, "c-a")
    var rt = _rt()
    ref reactor = rt.reactor()
    for i in range(300):
        var m = List[String]()
        if i == 299:
            m.append(String("u-alice"))
        _ = _post(s, "c-a", "u-bob", Int64(0), m, False, T0 + Int64(i))
    var rs = s.read_state[Rt](reactor, String("c-a"), String("u-alice"))
    assert_equal(rs.unread_count, 300, "past the first batch of 256")
    assert_equal(rs.mention_count, 1, "the last, in the second batch")


def main() raises:
    test_paging()
    test_threads()
    test_mention_order()
    test_mention_pages()
    test_cursor_and_read_state()
    test_read_state_batches()
    print("PASS komira_chat_store reading")
