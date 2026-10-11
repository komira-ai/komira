# =============================================================================
# komira_chat_store_conformance/checks_directory.mojo -- users, channels,
#   members, DMs, read state, mentions, files and erasure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor
from komira_db import Database, DbValue, Filter, Pred

from komira_chat_store import (
    CHANNEL_DM,
    CHANNEL_PRIVATE,
    CHANNEL_PUBLIC,
    EVENT_JOIN,
    EVENT_LEAVE,
    FILE_COMPLETE,
    FILE_PENDING,
    ChatStore,
    MentionPage,
    NoSendProbe,
    T_SUBJECTS,
    T_USERS,
    dm_channel_id,
)

from .targets import (
    ChatTarget,
    Rt,
    T0,
    assert_contiguous,
    assert_err,
    bodies_of,
    ids,
    joined,
    new_rt,
    no_ids,
    returned,
    seqs_of,
)

comptime ISS: StaticString = "https://issuer.example"


def check_users[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var a = s.ensure_user[Rt](
        reactor, String("u-1"), String(ISS), String("sub-alice"),
        String("Alice"), String("alice@example.com"), T0,
    )
    assert_equal(a.user_id, String("u-1"))
    # A second first request of the same subject, with another candidate id,
    # gets the same user; the display claims are refreshed.
    var again = s.ensure_user[Rt](
        reactor, String("u-9"), String(ISS), String("sub-alice"),
        String("Alice B."), String("ab@example.com"), T0 + 1,
    )
    assert_equal(again.user_id, String("u-1"))
    assert_equal(again.display_name, String("Alice B."))
    assert_equal(again.email, String("ab@example.com"))
    assert_equal(again.created_at_ms, T0)
    # The same sub at another issuer is another user.
    var other = s.ensure_user[Rt](
        reactor, String("u-2"), String("https://other.example"), String("sub-alice"),
        String("A"), String(""), T0,
    )
    assert_equal(other.user_id, String("u-2"))
    var found = s.user_for_subject[Rt](reactor, String(ISS), String("sub-alice"))
    assert_equal(found.value().user_id, String("u-1"))
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("nobody"))))
    _ = s.ensure_user[Rt](
        reactor, String("u-3"), String(ISS), String("sub-c"), String("C"), String(""), T0
    )
    var p1 = s.users[Rt](reactor, String(""), 2)
    assert_equal(joined(p1.ids), String("[u-1,u-2]"))
    assert_equal(p1.next_from, String("u-3"))
    var p2 = s.users[Rt](reactor, p1.next_from, 2)
    assert_equal(joined(p2.ids), String("[u-3]"))
    assert_equal(p2.next_from, String(""))
    var err = returned()
    try:
        _ = s.ensure_user[Rt](
            reactor, String("u/4"), String(ISS), String("s"), String(""), String(""), T0
        )
    except e:
        err = String(e)
    assert_err(err, String('komira_chat_store: invalid user id "u/4"'), "a malformed id")


def check_channels_and_members[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var ch = s.create_channel[Rt](
        reactor, String("c-eng"), CHANNEL_PRIVATE, String("eng"), String("t"),
        String("u-alice"), ids("u-bob"), T0,
    )
    assert_equal(ch.kind, CHANNEL_PRIVATE)
    var err = returned()
    try:
        _ = s.create_channel[Rt](
            reactor, String("c-eng"), CHANNEL_PUBLIC, String("again"), String(""),
            String("u-bob"), no_ids(), T0,
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: channel c-eng already exists"), "a taken id")
    assert_true(s.is_member[Rt](reactor, String("c-eng"), String("u-bob")))
    assert_false(s.is_member[Rt](reactor, String("c-eng"), String("u-carol")))
    assert_true(s.add_member[Rt](reactor, String("c-eng"), String("u-carol"), T0 + 1))
    assert_false(
        s.add_member[Rt](reactor, String("c-eng"), String("u-carol"), T0 + 2),
        "adding a member twice",
    )
    assert_true(s.remove_member[Rt](reactor, String("c-eng"), String("u-bob"), T0 + 3))
    assert_false(s.remove_member[Rt](reactor, String("c-eng"), String("u-bob"), T0 + 4))
    var tl = s.events_after[Rt](reactor, String("c-eng"), Int64(0), 100)
    assert_contiguous(tl, String("membership events"))
    assert_equal(tl.events[2].kind, EVENT_JOIN)
    assert_equal(tl.events[2].sender_user_id, String("u-carol"))
    assert_equal(tl.events[3].kind, EVENT_LEAVE)
    assert_equal(tl.events[3].sender_user_id, String("u-bob"))
    assert_equal(len(tl.events), 4, "a repeated add or remove appends nothing")
    err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String("c-eng"), String("u-bob"), String("x"), Int64(0),
            String(), no_ids(), False, no_ids(), T0 + 5,
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: u-bob is not a member of channel c-eng"), "a former member")
    var m = s.members[Rt](reactor, String("c-eng"), String(""), 10)
    assert_equal(joined(m.ids), String("[u-alice,u-carol]"))
    # Lists of channels.
    _ = s.create_channel[Rt](
        reactor, String("c-pub"), CHANNEL_PUBLIC, String("pub"), String(""),
        String("u-carol"), no_ids(), T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-old"), CHANNEL_PUBLIC, String("old"), String(""),
        String("u-carol"), no_ids(), T0,
    )
    var archived = s.update_channel[Rt](
        reactor, String("c-old"), Optional[String](), Optional[String](String("")),
        Optional[Bool](True),
    )
    assert_true(archived.archived)
    assert_equal(archived.topic, String(""))
    assert_equal(archived.name, String("old"), "an absent field is unchanged")
    assert_equal(
        joined(s.browse_channels[Rt](reactor, String(""), 10, False).ids),
        String("[c-pub]"),
        "browse lists public, unarchived channels",
    )
    assert_equal(
        joined(s.browse_channels[Rt](reactor, String(""), 10, True).ids),
        String("[c-old,c-pub]"),
    )
    var mine = s.channels_of[Rt](reactor, String("u-carol"), String(""), 2)
    assert_equal(joined(mine.ids), String("[c-eng,c-old]"))
    assert_equal(mine.next_from, String("c-pub"))
    err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String("c-old"), String("u-carol"), String("x"), Int64(0),
            String(), no_ids(), False, no_ids(), T0 + 5,
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: channel c-old is archived"), "send to an archived channel")
    err = returned()
    try:
        _ = s.add_member[Rt](reactor, String("c-old"), String("u-bob"), T0 + 5)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: channel c-old is archived"), "join an archived channel")


def check_dms[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    var dm = s.open_dm[Rt](reactor, String("u-bob"), ids("u-alice"), T0)
    assert_equal(dm.channel_id, dm_channel_id(ids("u-alice", "u-bob")))
    assert_equal(dm.kind, CHANNEL_DM)
    assert_equal(joined(dm.dm_user_ids), String("[u-alice,u-bob]"))
    var again = s.open_dm[Rt](reactor, String("u-alice"), ids("u-bob"), T0 + 1)
    assert_equal(again.channel_id, dm.channel_id, "one pair, one DM")
    assert_equal(s.head_seq[Rt](reactor, dm.channel_id), Int64(2), "reopening appends nothing")
    var err = returned()
    try:
        _ = s.add_member[Rt](reactor, dm.channel_id, String("u-carol"), T0)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: a DM's members are fixed"), "add to a DM")
    err = returned()
    try:
        _ = s.remove_member[Rt](reactor, dm.channel_id, String("u-bob"), T0)
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: a DM's members are fixed"), "remove from a DM")
    assert_true(s.is_member[Rt](reactor, dm.channel_id, String("u-bob")), "still a member")
    assert_equal(s.head_seq[Rt](reactor, dm.channel_id), Int64(2), "no LEAVE appended")
    err = returned()
    try:
        _ = s.create_channel[Rt](
            reactor, dm.channel_id, CHANNEL_PUBLIC, String("dm"), String(""),
            String("u-carol"), no_ids(), T0,
        )
    except e:
        err = String(e)
    assert_err(
        err,
        String("komira_chat_store: invalid channel id \"dm-u-alice.u-bob\""),
        "no channel takes a DM's id",
    )
    err = returned()
    try:
        _ = s.update_channel[Rt](
            reactor, dm.channel_id, Optional[String](String("x")), Optional[String](),
            Optional[Bool](),
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: a DM has no name, topic or archive state"), "rename a DM")
    var group = s.open_dm[Rt](reactor, String("u-carol"), ids("u-alice", "u-bob"), T0)
    assert_true(group.channel_id != dm.channel_id, "another set, another DM")
    assert_true(s.is_member[Rt](reactor, group.channel_id, String("u-carol")))


def check_read_state_and_mentions[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-x"), CHANNEL_PUBLIC, String("x"), String(""),
        String("u-alice"), ids("u-bob"), T0,
    )
    # seq 3: alice, no mention; 4: alice @bob; 5: alice @channel;
    # 6: bob's own; 7: alice @bob, then deleted.
    _ = s.send_message[Rt](reactor, String("c-x"), String("u-alice"), String("a"), Int64(0), String(), no_ids(), False, no_ids(), T0 + 10)
    _ = s.send_message[Rt](reactor, String("c-x"), String("u-alice"), String("@bob"), Int64(0), String(), ids("u-bob"), False, no_ids(), T0 + 20)
    _ = s.send_message[Rt](reactor, String("c-x"), String("u-alice"), String("@channel"), Int64(0), String(), no_ids(), True, no_ids(), T0 + 30)
    _ = s.send_message[Rt](reactor, String("c-x"), String("u-bob"), String("mine"), Int64(0), String(), ids("u-bob"), False, no_ids(), T0 + 40)
    var gone = s.send_message[Rt](reactor, String("c-x"), String("u-alice"), String("@bob again"), Int64(0), String(), ids("u-bob"), False, no_ids(), T0 + 50)
    _ = s.delete_message[Rt](reactor, String("c-x"), gone.seq, String("u-alice"), False, T0 + 60)
    var st = s.read_state[Rt](reactor, String("c-x"), String("u-bob"))
    assert_equal(st.read_seq, Int64(0))
    assert_equal(st.unread_count, 3, "alice's three live messages")
    assert_equal(st.mention_count, 2, "@bob and @channel")
    assert_equal(s.mark_read[Rt](reactor, String("c-x"), String("u-bob"), Int64(4)), Int64(4))
    assert_equal(
        s.mark_read[Rt](reactor, String("c-x"), String("u-bob"), Int64(2)),
        Int64(4),
        "a cursor never moves back",
    )
    var st2 = s.read_state[Rt](reactor, String("c-x"), String("u-bob"))
    assert_equal(st2.read_seq, Int64(4))
    assert_equal(st2.unread_count, 1)
    assert_equal(st2.mention_count, 1)
    # The mentions view: newest first; the deleted message's row is gone.
    var mp = s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, 10)
    assert_equal(len(mp.mentions), 2)
    assert_equal(mp.mentions[0].seq, Int64(6))
    assert_equal(mp.mentions[1].seq, Int64(4))
    assert_equal(mp.next_before_ms, Int64(0))
    var first = s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, 1)
    assert_equal(len(first.mentions), 1)
    assert_equal(first.next_before_ms, T0 + 40)
    var rest = s.mentions[Rt](reactor, String("u-bob"), first.next_before_ms, 1)
    assert_equal(rest.mentions[0].seq, Int64(4))


def _page_seqs(page: MentionPage) -> String:
    var out = String("[")
    for i in range(len(page.mentions)):
        if i > 0:
            out += String(",")
        out += String(page.mentions[i].seq)
    return out + String("]")


def _page_refs(page: MentionPage) -> String:
    var out = String("[")
    for i in range(len(page.mentions)):
        if i > 0:
            out += String(",")
        out += page.mentions[i].channel_id + String(":") + String(page.mentions[i].seq)
    return out + String("]")


def check_mention_paging[T: ChatTarget](mut t: T) raises:
    """Following `next_before_ms` from page to page returns every mention
    exactly once, when a page ends inside a millisecond and when one
    millisecond holds more mentions than a page (the last page included),
    and orders one millisecond's mentions by channel, then seq."""
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-m"), CHANNEL_PUBLIC, String("m"), String(""),
        String("u-alice"), ids("u-bob"), T0,
    )
    # seqs 3..14 mention bob at ms +40, +30, +30, +20, +10, +10, +10, +5,
    # +5, +5, +5, +1.
    var at = List[Int64]()
    at.append(T0 + 40)
    at.append(T0 + 30)
    at.append(T0 + 30)
    at.append(T0 + 20)
    at.append(T0 + 10)
    at.append(T0 + 10)
    at.append(T0 + 10)
    for _ in range(4):
        at.append(T0 + 5)
    at.append(T0 + 1)
    for i in range(len(at)):
        _ = s.send_message[Rt](reactor, String("c-m"), String("u-alice"), String("@bob"), Int64(0), String(), ids("u-bob"), False, no_ids(), at[i])
    # [40, 30, 30]: the page ends inside ms 30, so the 30s move on together.
    var p1 = s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, 2)
    assert_equal(_page_seqs(p1), String("[3]"), "page 1")
    assert_equal(p1.next_before_ms, T0 + 31, "page 1 next")
    # [30, 30, 20]: the page holds all of ms 30.
    var p2 = s.mentions[Rt](reactor, String("u-bob"), p1.next_before_ms, 2)
    assert_equal(_page_seqs(p2), String("[4,5]"), "page 2")
    assert_equal(p2.next_before_ms, T0 + 30, "page 2 next")
    # [20, 10, 10]
    var p3 = s.mentions[Rt](reactor, String("u-bob"), p2.next_before_ms, 2)
    assert_equal(_page_seqs(p3), String("[6]"), "page 3")
    assert_equal(p3.next_before_ms, T0 + 11, "page 3 next")
    # [10, 10, 10]: one millisecond fills the page; all of it is returned,
    # and the mentions at +5 and +1 remain.
    var p4 = s.mentions[Rt](reactor, String("u-bob"), p3.next_before_ms, 2)
    assert_equal(_page_seqs(p4), String("[7,8,9]"), "page 4: the whole millisecond")
    assert_equal(p4.next_before_ms, T0 + 10, "page 4 next")
    # [5, 5, 5, 5]: a millisecond of two more than a page; a read of the
    # millisecond capped at a page and one would lose seq 13.
    var p5 = s.mentions[Rt](reactor, String("u-bob"), p4.next_before_ms, 2)
    assert_equal(_page_seqs(p5), String("[10,11,12,13]"), "page 5: the whole millisecond")
    assert_equal(p5.next_before_ms, T0 + 5, "page 5 next")
    var p6 = s.mentions[Rt](reactor, String("u-bob"), p5.next_before_ms, 2)
    assert_equal(_page_seqs(p6), String("[14]"), "page 6")
    assert_equal(p6.next_before_ms, Int64(0), "page 6 is the last")
    # One page holding every mention: the 3-mention and 4-mention
    # milliseconds come back in seq order whatever order the backend
    # returns ties in (a sort that moves a row at most one place fails).
    var whole = s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, 50)
    assert_equal(_page_seqs(whole), String("[3,4,5,6,7,8,9,10,11,12,13,14]"), "one page of every mention")
    assert_equal(whole.next_before_ms, Int64(0), "one page is the last")
    # The oldest millisecond holds more than two pages: the page is all of
    # it, and it is the last page.
    _ = s.create_channel[Rt](
        reactor, String("c-d"), CHANNEL_PUBLIC, String("d"), String(""),
        String("u-alice"), ids("u-dee"), T0,
    )
    for _ in range(5):
        _ = s.send_message[Rt](reactor, String("c-d"), String("u-alice"), String("@dee"), Int64(0), String(), ids("u-dee"), False, no_ids(), T0 + 3)
    # Bob is mentioned in the same millisecond: dee's whole-millisecond
    # read must still hold only dee's mentions.
    _ = s.send_message[Rt](reactor, String("c-m"), String("u-alice"), String("@bob"), Int64(0), String(), ids("u-bob"), False, no_ids(), T0 + 3)
    var last = s.mentions[Rt](reactor, String("u-dee"), T0 + 1000, 2)
    assert_equal(_page_refs(last), String("[c-d:3,c-d:4,c-d:5,c-d:6,c-d:7]"), "the oldest millisecond, whole")
    assert_equal(last.next_before_ms, Int64(0), "the oldest millisecond is the last page")
    var bob_old = s.mentions[Rt](reactor, String("u-bob"), T0 + 4, 10)
    assert_equal(_page_refs(bob_old), String("[c-m:15,c-m:14]"), "bob's mention at +3 is there")
    # One page of 1 over ms 30: both 30s, and older mentions remain.
    var one = s.mentions[Rt](reactor, String("u-bob"), T0 + 31, 1)
    assert_equal(_page_seqs(one), String("[4,5]"), "a millisecond is never split")
    assert_equal(one.next_before_ms, T0 + 30, "older mentions remain")
    # Within a millisecond, channel ids order before seqs: c-tb is created
    # first and its mention has the lower seq, yet c-ta's comes first.
    _ = s.create_channel[Rt](
        reactor, String("c-tb"), CHANNEL_PUBLIC, String("tb"), String(""),
        String("u-alice"), ids("u-cy"), T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-ta"), CHANNEL_PUBLIC, String("ta"), String(""),
        String("u-alice"), ids("u-cy"), T0,
    )
    _ = s.send_message[Rt](reactor, String("c-ta"), String("u-alice"), String("no mention"), Int64(0), String(), no_ids(), False, no_ids(), T0 + 6)
    var in_b = s.send_message[Rt](reactor, String("c-tb"), String("u-alice"), String("@cy"), Int64(0), String(), ids("u-cy"), False, no_ids(), T0 + 7)
    var in_a = s.send_message[Rt](reactor, String("c-ta"), String("u-alice"), String("@cy"), Int64(0), String(), ids("u-cy"), False, no_ids(), T0 + 7)
    assert_true(in_a.seq > in_b.seq, "c-ta's mention has the higher seq")
    var tie = s.mentions[Rt](reactor, String("u-cy"), T0 + 1000, 10)
    assert_equal(_page_refs(tie), String("[c-ta:") + String(in_a.seq) + String(",c-tb:") + String(in_b.seq) + String("]"), "channel before seq")


def check_files[T: ChatTarget](mut t: T) raises:
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-f"), CHANNEL_PUBLIC, String("f"), String(""),
        String("u-alice"), no_ids(), T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-g"), CHANNEL_PUBLIC, String("g"), String(""),
        String("u-alice"), no_ids(), T0,
    )
    var f = s.create_file[Rt](
        reactor, String("f-1"), String("c-f"), String("a.png"), String("image/png"),
        Int64(100), String("u-alice"), T0,
    )
    assert_equal(f.state, FILE_PENDING)
    var err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String("c-f"), String("u-alice"), String("see"), Int64(0),
            String(), no_ids(), False, ids("f-1"), T0,
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: file f-1 is not a complete file of channel c-f"), "a pending file")
    var done = s.complete_file[Rt](reactor, String("f-1"), Int64(98))
    assert_equal(done.state, FILE_COMPLETE)
    assert_equal(done.size_bytes, Int64(98))
    var twice = s.complete_file[Rt](reactor, String("f-1"), Int64(5))
    assert_equal(twice.size_bytes, Int64(98), "completing twice changes nothing")
    err = returned()
    try:
        _ = s.send_message[Rt](
            reactor, String("c-g"), String("u-alice"), String("see"), Int64(0),
            String(), no_ids(), False, ids("f-1"), T0,
        )
    except e:
        err = String(e)
    assert_err(err, String("komira_chat_store: file f-1 is not a complete file of channel c-g"), "another channel's file")
    var m = s.send_message[Rt](
        reactor, String("c-f"), String("u-alice"), String("see"), Int64(0),
        String(), no_ids(), False, ids("f-1"), T0,
    )
    assert_equal(joined(m.file_ids), String("[f-1]"))
    assert_true(s.delete_file[Rt](reactor, String("f-1")))
    assert_false(Bool(s.file[Rt](reactor, String("f-1"))))


def check_erasure[T: ChatTarget](mut t: T) raises:
    """Logical erasure on any backend: the user's bodies are overwritten in
    place (seqs stay contiguous), and every row about the user is gone;
    other users' rows are untouched; a second erasure finds nothing."""
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    _ = s.ensure_user[Rt](reactor, String("u-alice"), String(ISS), String("sub-alice"), String("Alice"), String("a@example.com"), T0)
    _ = s.ensure_user[Rt](reactor, String("u-bob"), String(ISS), String("sub-bob"), String("Bob"), String(""), T0)
    _ = s.create_channel[Rt](
        reactor, String("c-e"), CHANNEL_PUBLIC, String("e"), String(""),
        String("u-alice"), ids("u-bob"), T0,
    )
    var a1 = s.send_message[Rt](reactor, String("c-e"), String("u-alice"), String("alice one"), Int64(0), String("k-a"), ids("u-bob"), False, no_ids(), T0 + 10)
    _ = s.edit_message[Rt](reactor, String("c-e"), a1.seq, String("u-alice"), String("alice one edited"), T0 + 20)
    _ = s.send_message[Rt](reactor, String("c-e"), String("u-bob"), String("bob @alice"), Int64(0), String(), ids("u-alice"), False, no_ids(), T0 + 30)
    _ = s.mark_read[Rt](reactor, String("c-e"), String("u-alice"), Int64(3))
    _ = s.create_file[Rt](reactor, String("f-a"), String("c-e"), String("x"), String("text/plain"), Int64(1), String("u-alice"), T0)
    var before = s.events_after[Rt](reactor, String("c-e"), Int64(0), 100)
    var counts = s.erase_user[Rt](reactor, String("u-alice"))
    assert_equal(counts.bodies_redacted, 2, "alice's message and her edit")
    assert_equal(joined(counts.file_ids), String("[f-a]"))
    # mention of bob in alice's message, mention of alice, membership,
    # cursor, file, user, subject
    assert_equal(counts.rows_erased, 7)
    var after = s.events_after[Rt](reactor, String("c-e"), Int64(0), 100)
    assert_contiguous(after, String("after erasure"))
    assert_equal(len(after.events), len(before.events), "no event row is deleted")
    assert_equal(bodies_of(after.events), String("[||||bob @alice]"))
    assert_true(after.events[2].deleted)
    assert_equal(after.events[2].client_msg_id, String(""))
    assert_false(Bool(s.user[Rt](reactor, String("u-alice"))))
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-alice"))))
    assert_false(s.is_member[Rt](reactor, String("c-e"), String("u-alice")))
    assert_equal(s.read_state[Rt](reactor, String("c-e"), String("u-alice")).read_seq, Int64(0))
    assert_equal(len(s.mentions[Rt](reactor, String("u-alice"), T0 + 1000, 10).mentions), 0)
    assert_equal(len(s.mentions[Rt](reactor, String("u-bob"), T0 + 1000, 10).mentions), 0, "mentions in alice's messages")
    assert_false(Bool(s.file[Rt](reactor, String("f-a"))))
    assert_true(Bool(s.user[Rt](reactor, String("u-bob"))))
    assert_true(s.is_member[Rt](reactor, String("c-e"), String("u-bob")))
    var again = s.erase_subject[Rt](reactor, String(ISS), String("sub-alice"))
    assert_equal(again.rows_erased + again.bodies_redacted, 0, "a second erasure finds nothing")
    var by_subject = s.erase_subject[Rt](reactor, String(ISS), String("sub-bob"))
    assert_equal(by_subject.bodies_redacted, 1)
    assert_false(Bool(s.user[Rt](reactor, String("u-bob"))))


def _delete_rows_of[
    DB: Database
](mut s: ChatStore[DB, NoSendProbe], mut reactor: Reactor[Rt.Sink], table: StaticString, user: StaticString) raises -> Int:
    return Int(
        s.db().delete_where[Rt](
            reactor,
            String(table),
            Filter.just(Pred.eq(String("user_id"), DbValue.text(String(user)))),
        )
    )


def check_erasure_retry[T: ChatTarget](mut t: T) raises:
    """An erasure that stopped between its last two deletes (user row
    gone, subject row kept) finishes when it is run again, by user id or by
    subject; and erasing by subject finds a user whose subject row is
    missing (deleted out of band, left by a run that deleted the subject
    row first, or racing a first `ensure_user`)."""
    var s = ChatStore[T.DB, NoSendProbe](t.fresh(), NoSendProbe())
    var rt = new_rt()
    ref reactor = rt.reactor()
    # The subject row is missing and the user row is kept: erasing by
    # subject finds the user row by (iss, sub).
    _ = s.ensure_user[Rt](reactor, String("u-carol"), String(ISS), String("sub-carol"), String("Carol"), String("c@example.com"), T0)
    assert_equal(_delete_rows_of(s, reactor, T_SUBJECTS, "u-carol"), 1)
    var c = s.erase_subject[Rt](reactor, String(ISS), String("sub-carol"))
    assert_equal(c.rows_erased, 1, "the user row")
    assert_false(Bool(s.user[Rt](reactor, String("u-carol"))), "erased by subject without its subject row")
    # Stopped after the user row, before the subject row: erasing by user id
    # finds the subject row by its user_id.
    _ = s.ensure_user[Rt](reactor, String("u-dave"), String(ISS), String("sub-dave"), String("Dave"), String(""), T0)
    assert_equal(_delete_rows_of(s, reactor, T_USERS, "u-dave"), 1)
    var d = s.erase_user[Rt](reactor, String("u-dave"))
    assert_equal(d.rows_erased, 1, "the subject row")
    assert_equal(_delete_rows_of(s, reactor, T_SUBJECTS, "u-dave"), 0, "no subject row is left")
    # The same stopped state, rerun by subject: the subject row names the
    # user, and both deletes of it find the one row.
    _ = s.ensure_user[Rt](reactor, String("u-erin"), String(ISS), String("sub-erin"), String("Erin"), String(""), T0)
    assert_equal(_delete_rows_of(s, reactor, T_USERS, "u-erin"), 1)
    var e = s.erase_subject[Rt](reactor, String(ISS), String("sub-erin"))
    assert_equal(e.rows_erased, 1, "the subject row")
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-erin"))), "no subject row maps sub-erin")
    assert_equal(_delete_rows_of(s, reactor, T_SUBJECTS, "u-erin"), 0, "no subject row is left")
