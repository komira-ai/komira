# =============================================================================
# komira_chat_store_conformance/checks_timeline.mojo -- seq allocation,
#   idempotent send, paging, threads, edit and delete.
# =============================================================================
#
# Every check starts from `_general`: channel c-general created by u-alice
# with u-bob and u-carol, so its JOIN events hold seqs 1, 2 and 3.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor
from komira_db import Database, Filter, Pred, DbValue

from komira_chat_store import (
    CHANNEL_PUBLIC,
    EVENT_DELETE,
    EVENT_EDIT,
    EVENT_JOIN,
    EVENT_MESSAGE,
    MAX_PAGE_SIZE,
    ChatEvent,
    ChatStore,
    NoSendProbe,
    SendProbe,
    T_MENTIONS,
)

from .probes import (
    CRASH_TEXT,
    INTERLEAVED_BODY,
    CrashProbe,
    DeleteDuringEditProbe,
    InterleaveProbe,
)
from .targets import (
    ChatTarget,
    Rt,
    T0,
    assert_contiguous,
    assert_err,
    bodies_of,
    ids,
    new_rt,
    no_ids,
    returned,
    seqs_of,
)

comptime GENERAL: StaticString = "c-general"
comptime FIRST_BODY: StaticString = "sent by the first connection"


def _general[
    DB: Database, P: SendProbe
](mut s: ChatStore[DB, P], mut reactor: Reactor[Rt.Sink]) raises:
    _ = s.create_channel[Rt](
        reactor,
        String(GENERAL),
        CHANNEL_PUBLIC,
        String("general"),
        String("everyone"),
        String("u-alice"),
        ids("u-bob", "u-carol"),
        T0,
    )


def _send[
    DB: Database, P: SendProbe
](
    mut s: ChatStore[DB, P],
    mut reactor: Reactor[Rt.Sink],
    sender: StaticString,
    body: StaticString,
) raises -> ChatEvent:
    return s.send_message[Rt](
        reactor,
        String(GENERAL),
        String(sender),
        String(body),
        Int64(0),
        String(),
        no_ids(),
        False,
        no_ids(),
        T0 + 100,
    )


def check_seq_interleaving[T: ChatTarget](mut t: T) raises:
    """Plan test (a). Inside A's send, after A read head 3, B sends to
    completion through a second connection and a reader pages after seq 3.
    The reader must still see A's message on its next page."""
    var db_a = t.fresh()
    var db_b = t.second()
    var probe = InterleaveProbe[T.DB](
        ChatStore[T.DB, NoSendProbe](db_b^, NoSendProbe()),
        String(GENERAL),
        String("u-bob"),
    )
    var a = ChatStore[T.DB, InterleaveProbe[T.DB]](db_a^, probe^)
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(a, reactor)
    a.probe().armed = True
    var mine = _send(a, reactor, "u-alice", FIRST_BODY)
    ref p = a.probe()
    var cursor = Int64(3)
    if len(p.seen) > 0:
        cursor = p.seen[len(p.seen) - 1].seq
    var later = a.events_after[Rt](reactor, String(GENERAL), cursor, 100)
    var saw = bodies_of(p.seen) + bodies_of(later.events)
    if saw.find(String(FIRST_BODY)) < 0:
        raise Error(
            String("a reader paging from its cursor never saw the first")
            + String(" sender's message (seq ")
            + String(mine.seq)
            + String("): inside the window it saw ")
            + seqs_of(p.seen)
            + String(", then after seq ")
            + String(cursor)
            + String(" it saw ")
            + seqs_of(later.events)
        )
    assert_equal(p.fired_with_seq, Int64(4), "A's first attempt was at head + 1")
    assert_equal(p.other_seq, Int64(4), "B took seq 4")
    assert_equal(mine.seq, Int64(5), "A retried at seq 5")
    var whole = a.events_after[Rt](reactor, String(GENERAL), Int64(0), 100)
    assert_contiguous(whole, String("after the interleaving"))
    assert_equal(whole.events[3].body, String(INTERLEAVED_BODY))
    assert_equal(whole.events[4].body, String(FIRST_BODY))


def check_abandoned_send_leaves_no_hole[T: ChatTarget](mut t: T) raises:
    """Plan test (b). A send that dies between reading the head and
    inserting allocates nothing: the next send takes the next seq."""
    var a = ChatStore[T.DB, CrashProbe](t.fresh(), CrashProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(a, reactor)
    a.probe().armed = True
    var err = returned()
    try:
        _ = _send(a, reactor, "u-alice", "never stored")
    except e:
        err = String(e)
    assert_err(err, String(CRASH_TEXT), "the probe's raise ends the send")
    var next = _send(a, reactor, "u-alice", "stored")
    assert_equal(next.seq, Int64(4), "the abandoned send took no seq")
    var whole = a.events_after[Rt](reactor, String(GENERAL), Int64(0), 100)
    assert_contiguous(whole, String("after an abandoned send"))
    assert_equal(bodies_of(whole.events), String("[|||stored]"))


def _mentions_of[
    DB: Database, P: SendProbe
](mut s: ChatStore[DB, P], mut reactor: Reactor[Rt.Sink], user: StaticString) raises -> String:
    var page = s.mentions[Rt](reactor, String(user), T0 + 1000000, 50)
    var out = String("[")
    for i in range(len(page.mentions)):
        if i > 0:
            out += String(",")
        out += page.mentions[i].channel_id + String("#") + String(page.mentions[i].seq)
    return out + String("]")


def check_idempotent_send[T: ChatTarget](mut t: T) raises:
    """Plan test (d). A retried send with the same client_msg_id returns the
    first event, appends nothing, and writes back mention rows a crash
    lost."""
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(s, reactor)
    var first = s.send_message[Rt](
        reactor, String(GENERAL), String("u-alice"), String("hi @carol"),
        Int64(0), String("k-1"), ids("u-carol"), False, no_ids(), T0 + 100,
    )
    assert_equal(first.seq, Int64(4))
    assert_equal(_mentions_of(s, reactor, "u-carol"), String("[c-general#4]"))
    # A crash after the event and before its mention rows: delete them.
    _ = s.db().delete_where[Rt](
        reactor,
        String(T_MENTIONS),
        Filter.just(Pred.eq(String("user_id"), DbValue.text(String("u-carol")))),
    )
    assert_equal(_mentions_of(s, reactor, "u-carol"), String("[]"))
    var again = s.send_message[Rt](
        reactor, String(GENERAL), String("u-alice"), String("hi @carol"),
        Int64(0), String("k-1"), ids("u-carol"), False, no_ids(), T0 + 200,
    )
    assert_equal(again.seq, Int64(4), "the retry returns the first event")
    assert_equal(again.created_at_ms, T0 + 100, "and not a new one")
    assert_equal(s.head_seq[Rt](reactor, String(GENERAL)), Int64(4), "nothing appended")
    assert_equal(
        _mentions_of(s, reactor, "u-carol"),
        String("[c-general#4]"),
        "the retry wrote the lost mention row back",
    )
    # The key is the sender's: another sender's equal key is another send.
    var bob = s.send_message[Rt](
        reactor, String(GENERAL), String("u-bob"), String("me too"),
        Int64(0), String("k-1"), no_ids(), False, no_ids(), T0 + 300,
    )
    assert_equal(bob.seq, Int64(5))
    # A retry of a send whose message was deleted since writes no mention.
    var gone = s.send_message[Rt](
        reactor, String(GENERAL), String("u-alice"), String("bye @carol"),
        Int64(0), String("k-2"), ids("u-carol"), False, no_ids(), T0 + 400,
    )
    _ = s.delete_message[Rt](reactor, String(GENERAL), gone.seq, String("u-alice"), False, T0 + 500)
    assert_equal(_mentions_of(s, reactor, "u-carol"), String("[c-general#4]"))
    var late = s.send_message[Rt](
        reactor, String(GENERAL), String("u-alice"), String("bye @carol"),
        Int64(0), String("k-2"), ids("u-carol"), False, no_ids(), T0 + 600,
    )
    assert_equal(late.seq, gone.seq, "the retry returns the deleted event")
    assert_true(late.deleted)
    assert_equal(
        _mentions_of(s, reactor, "u-carol"),
        String("[c-general#4]"),
        "a retry of a deleted send writes no mention row",
    )


def check_paging[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    assert_equal(s.head_seq[Rt](reactor, String(GENERAL)), Int64(0), "no channel, no events")
    _general(s, reactor)
    for _ in range(5):
        _ = _send(s, reactor, "u-bob", "m")
    var p1 = s.events_after[Rt](reactor, String(GENERAL), Int64(0), 3)
    assert_equal(seqs_of(p1.events), String("[1,2,3]"))
    assert_true(p1.has_more)
    assert_equal(p1.head_seq, Int64(8))
    assert_equal(p1.events[0].kind, EVENT_JOIN)
    assert_equal(p1.events[0].sender_user_id, String("u-alice"))
    var p2 = s.events_after[Rt](reactor, String(GENERAL), Int64(6), 3)
    assert_equal(seqs_of(p2.events), String("[7,8]"))
    assert_false(p2.has_more)
    var back = s.events_before[Rt](reactor, String(GENERAL), Int64(8), 3)
    assert_equal(seqs_of(back.events), String("[5,6,7]"), "newest before 8, oldest first")
    assert_true(back.has_more)
    var start = s.events_before[Rt](reactor, String(GENERAL), Int64(3), 5)
    assert_equal(seqs_of(start.events), String("[1,2]"))
    assert_false(start.has_more)


def check_threads[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(s, reactor)
    var root = _send(s, reactor, "u-alice", "root")
    _ = _send(s, reactor, "u-bob", "top level")
    var r1 = s.send_message[Rt](
        reactor, String(GENERAL), String("u-bob"), String("reply 1"),
        root.seq, String(), no_ids(), False, no_ids(), T0 + 100,
    )
    var r2 = s.send_message[Rt](
        reactor, String(GENERAL), String("u-carol"), String("reply 2"),
        root.seq, String(), no_ids(), False, no_ids(), T0 + 100,
    )
    var th = s.thread[Rt](reactor, String(GENERAL), root.seq, Int64(0), 10)
    assert_equal(bodies_of(th.events), String("[reply 1|reply 2]"))
    assert_equal(r1.thread_root_seq, root.seq)
    var tail = s.thread[Rt](reactor, String(GENERAL), root.seq, r1.seq, 10)
    assert_equal(seqs_of(tail.events), String("[") + String(r2.seq) + String("]"))
    var err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String(GENERAL), String("u-alice"), String("nested"),
            r1.seq, String(), no_ids(), False, no_ids(), T0 + 100,
        )
    except e:
        err = String(e)
    assert_err(
        err,
        String("komira_chat_store: thread root 6 is not a top-level message of channel c-general"),
        "a reply cannot start a thread",
    )
    err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String(GENERAL), String("u-alice"), String("to a join"),
            Int64(1), String(), no_ids(), False, no_ids(), T0 + 100,
        )
    except e:
        err = String(e)
    assert_err(
        err,
        String("komira_chat_store: thread root 1 is not a top-level message of channel c-general"),
        "a JOIN event is not a thread root",
    )


def check_edit_and_delete[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(s, reactor)
    var m = _send(s, reactor, "u-bob", "first words")
    var err = returned()
    try:
        _ = s.edit_message[Rt](reactor, String(GENERAL), m.seq, String("u-carol"), String("x"), T0 + 200)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: u-carol did not send message 4"), "edit of another's message")
    var e1 = s.edit_message[Rt](reactor, String(GENERAL), m.seq, String("u-bob"), String("second words"), T0 + 200)
    assert_equal(e1.kind, EVENT_EDIT)
    assert_equal(e1.target_seq, m.seq)
    assert_equal(e1.seq, Int64(5))
    var now = s.event[Rt](reactor, String(GENERAL), m.seq).value().copy()
    assert_equal(now.body, String("second words"), "the message carries its latest edit")
    assert_true(now.edited)
    err = returned()
    try:
        _ = s.delete_message[Rt](reactor, String(GENERAL), m.seq, String("u-carol"), False, T0 + 300)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: u-carol did not send message 4"), "delete of another's message")
    var d = s.delete_message[Rt](reactor, String(GENERAL), m.seq, String("u-bob"), False, T0 + 300)
    assert_equal(d.kind, EVENT_DELETE)
    assert_equal(d.seq, Int64(6))
    assert_equal(d.target_seq, m.seq)
    var gone = s.event[Rt](reactor, String(GENERAL), m.seq).value().copy()
    assert_true(gone.deleted)
    assert_equal(gone.body, String(""), "a delete overwrites the body")
    var edit_ev = s.event[Rt](reactor, String(GENERAL), e1.seq).value().copy()
    assert_equal(edit_ev.body, String(""), "and the bodies of its edits")
    var d2 = s.delete_message[Rt](reactor, String(GENERAL), m.seq, String("u-bob"), False, T0 + 400)
    assert_equal(d2.seq, d.seq, "deleting again returns the first DELETE event")
    assert_equal(s.head_seq[Rt](reactor, String(GENERAL)), Int64(6))
    err = returned()
    try:
        _ = s.edit_message[Rt](reactor, String(GENERAL), m.seq, String("u-bob"), String("y"), T0 + 500)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: message 4 is deleted"), "edit after delete")
    err = returned()
    try:
        _ = s.edit_message[Rt](reactor, String(GENERAL), Int64(1), String("u-alice"), String("y"), T0 + 500)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: channel c-general has no message at seq 1"), "a JOIN is not a message")
    # An admin may delete anyone's message.
    var c = _send(s, reactor, "u-carol", "carol's")
    var by_admin = s.delete_message[Rt](reactor, String(GENERAL), c.seq, String("u-admin"), True, T0 + 600)
    assert_equal(by_admin.sender_user_id, String("u-admin"))
    assert_true(s.event[Rt](reactor, String(GENERAL), c.seq).value().deleted)
    var whole = s.events_after[Rt](reactor, String(GENERAL), Int64(0), 100)
    assert_contiguous(whole, String("after edits and deletes"))
    assert_equal(whole.events[3].kind, EVENT_MESSAGE)


def check_edit_racing_delete[T: ChatTarget](mut t: T) raises:
    """An edit that read its message live, but whose EDIT event lands after
    a delete of the message (here the delete runs through a second
    connection inside the edit's window), redacts its own EDIT event: no
    body survives a delete."""
    var db_a = t.fresh()
    var db_b = t.second()
    var probe = DeleteDuringEditProbe[T.DB](
        ChatStore[T.DB, NoSendProbe](db_b^, NoSendProbe()),
        String(GENERAL),
        Int64(4),
        String("u-bob"),
    )
    var a = ChatStore[T.DB, DeleteDuringEditProbe[T.DB]](db_a^, probe^)
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(a, reactor)
    var m = _send(a, reactor, "u-bob", "before the race")
    assert_equal(m.seq, Int64(4))
    a.probe().armed = True
    var e = a.edit_message[Rt](
        reactor, String(GENERAL), m.seq, String("u-bob"), String("lost to the delete"), T0 + 80
    )
    assert_equal(e.seq, Int64(6), "the DELETE took 5; the EDIT retried at 6")
    assert_equal(e.body, String(""), "the edit reports its body redacted")
    var stored = a.event[Rt](reactor, String(GENERAL), e.seq).value().copy()
    assert_equal(stored.kind, EVENT_EDIT)
    assert_equal(stored.body, String(""), "the stored EDIT event keeps no body")
    var msg = a.event[Rt](reactor, String(GENERAL), m.seq).value().copy()
    assert_true(msg.deleted)
    assert_equal(msg.body, String(""))


def _pager_err[
    DB: Database
](
    mut s: ChatStore[DB, NoSendProbe], mut reactor: Reactor[Rt.Sink], which: Int, n: Int
) raises -> String:
    """What pager `which` raised for a page size of `n`."""
    try:
        if which == 0:
            _ = s.users[Rt](reactor, String(""), n)
        elif which == 1:
            _ = s.browse_channels[Rt](reactor, String(""), n, True)
        elif which == 2:
            _ = s.channels_of[Rt](reactor, String("u-bob"), String(""), n)
        elif which == 3:
            _ = s.members[Rt](reactor, String(GENERAL), String(""), n)
        elif which == 4:
            _ = s.events_after[Rt](reactor, String(GENERAL), Int64(0), n)
        elif which == 5:
            _ = s.events_before[Rt](reactor, String(GENERAL), Int64(100), n)
        elif which == 6:
            _ = s.thread[Rt](reactor, String(GENERAL), Int64(4), Int64(0), n)
        else:
            _ = s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, n)
    except e:
        return String(e)
    return returned()


def check_page_size_refused[T: ChatTarget](mut t: T) raises:
    """Every pager refuses, by name, a page size below 1 (such a page holds
    nothing, and the mentions pager would index past an empty page) or above
    MAX_PAGE_SIZE (the row limit would wrap), and accepts MAX_PAGE_SIZE."""
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _general(s, reactor)
    _ = s.ensure_user[Rt](reactor, String("u-bob"), String("https://issuer.example"), String("sub-bob"), String("Bob"), String(""), T0)
    # seq 4 mentions bob; seq 5 replies to it, so every pager has a row.
    _ = s.send_message[Rt](reactor, String(GENERAL), String("u-alice"), String("@bob"), Int64(0), String(), ids("u-bob"), False, no_ids(), T0 + 10)
    _ = s.send_message[Rt](reactor, String(GENERAL), String("u-bob"), String("re"), Int64(4), String(), no_ids(), False, no_ids(), T0 + 20)
    var names = List[String]()
    for _ in range(4):
        names.append(String("max_ids"))
    for _ in range(3):
        names.append(String("max_events"))
    names.append(String("max_mentions"))
    for which in range(len(names)):
        for n in range(-1, 1):
            assert_err(
                _pager_err(s, reactor, which, n),
                String("komira_chat_store: ") + names[which] + String(" must be at least 1, got ") + String(n),
                String("pager ") + String(which) + String(", size ") + String(n),
            )
        # Above the cap: a pager reads one more row than its page through a
        # UInt32 limit, so a size of Int.MAX or 2^32 - 1 would read 0 rows and
        # 2^32 would read 1, each a short page reported as the last.
        var big = List[Int]()
        big.append(MAX_PAGE_SIZE + 1)
        big.append(4294967295)
        big.append(4294967296)
        big.append(Int.MAX)
        for k in range(len(big)):
            assert_err(
                _pager_err(s, reactor, which, big[k]),
                String("komira_chat_store: ") + names[which] + String(" must be at most ") + String(MAX_PAGE_SIZE) + String(", got ") + String(big[k]),
                String("pager ") + String(which) + String(", size ") + String(big[k]),
            )
        assert_equal(
            _pager_err(s, reactor, which, MAX_PAGE_SIZE),
            returned(),
            String("pager ") + String(which) + String(" at the cap"),
        )
