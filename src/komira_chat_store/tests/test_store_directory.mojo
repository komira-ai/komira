# =============================================================================
# test_store_directory.mojo -- ChatStore's users, channels, members and DMs
#   on komira_db_sqlite, from the library's own tests.
# =============================================================================
#
# The store's full contract, on SQLite and the Firestore mock, is
# //src/tests/conformance/komira_chat_store_conformance. These checks run the
# directory calls on an in-memory SQLite database (`test_deps`), so this
# package measures its own lines. Each would fail on the defect named.
#
#   users     every field of a new user read back (a column decoded from the
#             wrong place); a second first request of a subject keeps the
#             first id and refreshes name and email (the subject claim or
#             the user update dropped); the same sub at another issuer is
#             another user; the id pager's next id; a malformed id and an
#             empty iss or sub are refused (either half of the check gone).
#   channels  every field read back; each create refusal (malformed id,
#             malformed creator, a DM kind, kind 0, an empty name, a
#             malformed member, a taken id); add and remove report whether
#             they changed anything and append JOIN and LEAVE only then;
#             update sets only the fields given; an archived channel takes
#             no member and no message; browse leaves archived channels out
#             unless asked, and leaves PRIVATE channels out always.
#   dms       one set of users has one DM whoever opens it (the existing
#             row is returned, not the opener's); a member a crash left out
#             is re-added; a DM's members and name are fixed; a channel row
#             under a DM id that is not that DM (wrong kind, or other users)
#             is refused.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_db import DbValue, MigrationRunner
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHANNEL_DM,
    CHANNEL_PRIVATE,
    CHANNEL_PUBLIC,
    CHAT_MIGRATION_LEDGER,
    ChatStore,
    EVENT_JOIN,
    EVENT_LEAVE,
    NoSendProbe,
    chat_migrations,
    prepare_sql_connection,
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


def _create_err(
    mut s: Store,
    channel_id: StaticString,
    kind: Int,
    name: StaticString,
    creator: StaticString,
    members: List[String],
) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.create_channel[Rt](
            reactor, String(channel_id), kind, String(name), String(""),
            String(creator), members, T0,
        )
    except e:
        return String(e)
    return String(RETURNED)


def _ensure_err(
    mut s: Store, id: StaticString, iss: StaticString, sub: StaticString
) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.ensure_user[Rt](
            reactor, String(id), String(iss), String(sub), String(""), String(""), T0
        )
    except e:
        return String(e)
    return String(RETURNED)


def test_users() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var a = s.ensure_user[Rt](
        reactor, String("u-1"), String(ISS), String("sub-a"),
        String("Alice"), String("alice@example.com"), T0,
    )
    assert_equal(a.user_id, String("u-1"))
    var got = s.user[Rt](reactor, String("u-1"))
    assert_equal(got.value().user_id, String("u-1"))
    assert_equal(got.value().iss, String(ISS))
    assert_equal(got.value().sub, String("sub-a"))
    assert_equal(got.value().display_name, String("Alice"))
    assert_equal(got.value().email, String("alice@example.com"))
    assert_equal(got.value().created_at_ms, T0)
    assert_false(Bool(s.user[Rt](reactor, String("u-none"))), "no such user")

    var again = s.ensure_user[Rt](
        reactor, String("u-9"), String(ISS), String("sub-a"),
        String("Alice B."), String("ab@example.com"), T0 + 5,
    )
    assert_equal(again.user_id, String("u-1"), "the subject keeps its first id")
    assert_equal(again.display_name, String("Alice B."))
    assert_equal(again.email, String("ab@example.com"))
    assert_equal(again.created_at_ms, T0)
    assert_false(Bool(s.user[Rt](reactor, String("u-9"))), "no row for the loser")

    var other = s.ensure_user[Rt](
        reactor, String("u-2"), String("https://other.example"), String("sub-a"),
        String("A"), String(""), T0,
    )
    assert_equal(other.user_id, String("u-2"), "another issuer, another user")
    var found = s.user_for_subject[Rt](reactor, String(ISS), String("sub-a"))
    assert_equal(found.value().user_id, String("u-1"))
    assert_equal(found.value().display_name, String("Alice B."))
    assert_false(Bool(s.user_for_subject[Rt](reactor, String(ISS), String("sub-x"))))

    _ = s.ensure_user[Rt](
        reactor, String("u-3"), String(ISS), String("sub-c"), String("C"), String(""), T0
    )
    var p1 = s.users[Rt](reactor, String(""), 2)
    assert_equal(_joined(p1.ids), String("[u-1,u-2]"))
    assert_equal(p1.next_from, String("u-3"))
    var p2 = s.users[Rt](reactor, p1.next_from, 2)
    assert_equal(_joined(p2.ids), String("[u-3]"))
    assert_equal(p2.next_from, String(""))
    var p3 = s.users[Rt](reactor, String(""), 3)
    assert_equal(_joined(p3.ids), String("[u-1,u-2,u-3]"), "exactly a page")
    assert_equal(p3.next_from, String(""))

    assert_equal(
        _ensure_err(s, "u/4", ISS, "s"), String(E) + String('invalid user id "u/4"')
    )
    assert_equal(
        _ensure_err(s, "u-4", "", "s"),
        String(E) + String("a subject needs a non-empty iss and sub"),
    )
    assert_equal(
        _ensure_err(s, "u-4", ISS, ""),
        String(E) + String("a subject needs a non-empty iss and sub"),
    )
    assert_false(Bool(s.user[Rt](reactor, String("u-4"))), "a refusal writes nothing")


def test_channel_create() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var ch = s.create_channel[Rt](
        reactor, String("c-eng"), CHANNEL_PRIVATE, String("eng"), String("the topic"),
        String("u-alice"), _ids("u-bob"), T0,
    )
    assert_equal(ch.channel_id, String("c-eng"))
    var back = s.channel[Rt](reactor, String("c-eng"))
    ref c = back.value()
    assert_equal(c.channel_id, String("c-eng"))
    assert_equal(c.kind, CHANNEL_PRIVATE)
    assert_equal(c.name, String("eng"))
    assert_equal(c.topic, String("the topic"))
    assert_false(c.archived)
    assert_equal(c.created_at_ms, T0)
    assert_equal(c.created_by_user_id, String("u-alice"))
    assert_equal(len(c.dm_user_ids), 0)
    assert_false(Bool(s.channel[Rt](reactor, String("c-none"))))
    var tl = s.events_after[Rt](reactor, String("c-eng"), Int64(0), 10)
    assert_equal(len(tl.events), 2, "a JOIN for the creator and for u-bob")
    assert_equal(tl.events[0].kind, EVENT_JOIN)
    assert_equal(tl.events[0].sender_user_id, String("u-alice"))
    assert_equal(tl.events[1].sender_user_id, String("u-bob"))
    assert_equal(tl.events[1].created_at_ms, T0)

    var none = List[String]()
    assert_equal(
        _create_err(s, "c.x", CHANNEL_PUBLIC, "x", "u-alice", none),
        String(E) + String('invalid channel id "c.x"'),
    )
    assert_equal(
        _create_err(s, "c-x", CHANNEL_PUBLIC, "x", "u alice", none),
        String(E) + String('invalid user id "u alice"'),
    )
    assert_equal(
        _create_err(s, "c-x", CHANNEL_DM, "x", "u-alice", none),
        String(E) + String("create_channel makes a PUBLIC or PRIVATE channel, not kind 3"),
    )
    assert_equal(
        _create_err(s, "c-x", 0, "x", "u-alice", none),
        String(E) + String("create_channel makes a PUBLIC or PRIVATE channel, not kind 0"),
    )
    assert_equal(
        _create_err(s, "c-x", CHANNEL_PUBLIC, "", "u-alice", none),
        String(E) + String("a channel needs a name"),
    )
    assert_equal(
        _create_err(s, "c-x", CHANNEL_PUBLIC, "x", "u-alice", _ids("u-bob", "u,c")),
        String(E) + String('invalid user id "u,c"'),
    )
    assert_false(Bool(s.channel[Rt](reactor, String("c-x"))), "refusals write nothing")
    assert_equal(
        _create_err(s, "c-eng", CHANNEL_PUBLIC, "again", "u-bob", none),
        String(E) + String("channel c-eng already exists"),
    )
    var kept = s.channel[Rt](reactor, String("c-eng"))
    assert_equal(kept.value().name, String("eng"), "a taken id leaves the row")
    var pub = s.create_channel[Rt](
        reactor, String("c-pub"), CHANNEL_PUBLIC, String("pub"), String(""),
        String("u-carol"), none, T0,
    )
    assert_equal(pub.kind, CHANNEL_PUBLIC)


def test_members() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = s.create_channel[Rt](
        reactor, String("c-eng"), CHANNEL_PUBLIC, String("eng"), String(""),
        String("u-alice"), _ids("u-bob"), T0,
    )
    assert_true(s.is_member[Rt](reactor, String("c-eng"), String("u-bob")))
    assert_false(s.is_member[Rt](reactor, String("c-eng"), String("u-carol")))
    assert_false(s.is_member[Rt](reactor, String("c-other"), String("u-bob")))
    assert_true(s.add_member[Rt](reactor, String("c-eng"), String("u-carol"), T0 + 1))
    assert_false(s.add_member[Rt](reactor, String("c-eng"), String("u-carol"), T0 + 2))
    assert_true(s.remove_member[Rt](reactor, String("c-eng"), String("u-bob"), T0 + 3))
    assert_false(s.remove_member[Rt](reactor, String("c-eng"), String("u-bob"), T0 + 4))
    assert_false(s.is_member[Rt](reactor, String("c-eng"), String("u-bob")))
    var tl = s.events_after[Rt](reactor, String("c-eng"), Int64(0), 10)
    assert_equal(len(tl.events), 4, "a repeated add or remove appends nothing")
    assert_equal(tl.events[2].kind, EVENT_JOIN)
    assert_equal(tl.events[2].sender_user_id, String("u-carol"))
    assert_equal(tl.events[2].created_at_ms, T0 + 1)
    assert_equal(tl.events[3].kind, EVENT_LEAVE)
    assert_equal(tl.events[3].sender_user_id, String("u-bob"))
    assert_equal(tl.events[3].created_at_ms, T0 + 3)
    var err = String(RETURNED)
    try:
        _ = s.add_member[Rt](reactor, String("c-eng"), String("u/d"), T0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String('invalid user id "u/d"'))
    err = String(RETURNED)
    try:
        _ = s.add_member[Rt](reactor, String("c-none"), String("u-d"), T0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("no channel c-none"))
    var m = s.members[Rt](reactor, String("c-eng"), String(""), 10)
    assert_equal(_joined(m.ids), String("[u-alice,u-carol]"))
    var m1 = s.members[Rt](reactor, String("c-eng"), String(""), 1)
    assert_equal(_joined(m1.ids), String("[u-alice]"))
    assert_equal(m1.next_from, String("u-carol"))
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PRIVATE, String("a"), String(""),
        String("u-carol"), List[String](), T0,
    )
    var mine = s.channels_of[Rt](reactor, String("u-carol"), String(""), 10)
    assert_equal(_joined(mine.ids), String("[c-a,c-eng]"))
    var mine2 = s.channels_of[Rt](reactor, String("u-carol"), String("c-b"), 10)
    assert_equal(_joined(mine2.ids), String("[c-eng]"), "from is inclusive and ordered")


def test_update_and_browse() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var none = List[String]()
    _ = s.create_channel[Rt](
        reactor, String("c-a"), CHANNEL_PUBLIC, String("a"), String("ta"),
        String("u-alice"), none, T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-b"), CHANNEL_PUBLIC, String("b"), String("tb"),
        String("u-alice"), none, T0,
    )
    _ = s.create_channel[Rt](
        reactor, String("c-p"), CHANNEL_PRIVATE, String("p"), String(""),
        String("u-alice"), none, T0,
    )
    var n = s.update_channel[Rt](
        reactor, String("c-a"), Optional[String](String("a2")), Optional[String](),
        Optional[Bool](),
    )
    assert_equal(n.name, String("a2"))
    assert_equal(n.topic, String("ta"), "an absent topic is left")
    var t = s.update_channel[Rt](
        reactor, String("c-a"), Optional[String](), Optional[String](String("t2")),
        Optional[Bool](),
    )
    assert_equal(t.name, String("a2"), "an absent name is left")
    assert_equal(t.topic, String("t2"))
    assert_false(t.archived)
    var same = s.update_channel[Rt](
        reactor, String("c-a"), Optional[String](), Optional[String](), Optional[Bool]()
    )
    assert_equal(same.name, String("a2"))
    assert_equal(same.topic, String("t2"))
    var ar = s.update_channel[Rt](
        reactor, String("c-b"), Optional[String](), Optional[String](),
        Optional[Bool](True),
    )
    assert_true(ar.archived)
    assert_equal(ar.name, String("b"))
    var err = String(RETURNED)
    try:
        _ = s.update_channel[Rt](
            reactor, String("c-a"), Optional[String](String("")), Optional[String](),
            Optional[Bool](),
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a channel needs a name"))
    err = String(RETURNED)
    try:
        _ = s.update_channel[Rt](
            reactor, String("c-none"), Optional[String](), Optional[String](),
            Optional[Bool](),
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("no channel c-none"))

    err = String(RETURNED)
    try:
        _ = s.add_member[Rt](reactor, String("c-b"), String("u-bob"), T0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("channel c-b is archived"))
    err = String(RETURNED)
    try:
        _ = s.send_message[Rt](
            reactor, String("c-b"), String("u-alice"), String("x"), Int64(0),
            String(), none, False, none, T0,
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("channel c-b is archived"))

    var live = s.browse_channels[Rt](reactor, String(""), 10, False)
    assert_equal(_joined(live.ids), String("[c-a]"), "archived and private left out")
    var all = s.browse_channels[Rt](reactor, String(""), 10, True)
    assert_equal(_joined(all.ids), String("[c-a,c-b]"), "private left out")
    var one = s.browse_channels[Rt](reactor, String(""), 1, True)
    assert_equal(_joined(one.ids), String("[c-a]"))
    assert_equal(one.next_from, String("c-b"))
    var rest = s.browse_channels[Rt](reactor, one.next_from, 1, True)
    assert_equal(_joined(rest.ids), String("[c-b]"))
    assert_equal(rest.next_from, String(""))
    var unarchived = s.update_channel[Rt](
        reactor, String("c-b"), Optional[String](), Optional[String](),
        Optional[Bool](False),
    )
    assert_false(unarchived.archived)
    live = s.browse_channels[Rt](reactor, String(""), 10, False)
    assert_equal(_joined(live.ids), String("[c-a,c-b]"))


def _dm_err(mut s: Store, opener: StaticString, users: List[String]) -> String:
    try:
        var rt = _rt()
        ref reactor = rt.reactor()
        _ = s.open_dm[Rt](reactor, String(opener), users, T0)
    except e:
        return String(e)
    return String(RETURNED)


def test_dms() raises:
    var s = _store()
    var rt = _rt()
    ref reactor = rt.reactor()
    var dm = s.open_dm[Rt](reactor, String("u-bob"), _ids("u-alice"), T0)
    assert_equal(dm.channel_id, String("dm-u-alice.u-bob"))
    assert_equal(dm.kind, CHANNEL_DM)
    assert_equal(_joined(dm.dm_user_ids), String("[u-alice,u-bob]"))
    assert_equal(dm.created_by_user_id, String("u-bob"))
    var back = s.channel[Rt](reactor, String("dm-u-alice.u-bob"))
    assert_equal(_joined(back.value().dm_user_ids), String("[u-alice,u-bob]"))
    assert_equal(back.value().kind, CHANNEL_DM)
    assert_true(s.is_member[Rt](reactor, dm.channel_id, String("u-alice")))
    assert_true(s.is_member[Rt](reactor, dm.channel_id, String("u-bob")))

    # A member a crash left out is re-added; the existing row is returned.
    _sql(s, "DELETE FROM chat_members WHERE user_id = 'u-alice'")
    var again = s.open_dm[Rt](reactor, String("u-alice"), _ids("u-bob"), T0 + 9)
    assert_equal(again.channel_id, dm.channel_id)
    assert_equal(again.created_by_user_id, String("u-bob"), "the stored row")
    assert_equal(again.created_at_ms, T0)
    assert_true(s.is_member[Rt](reactor, dm.channel_id, String("u-alice")))
    assert_equal(s.head_seq[Rt](reactor, dm.channel_id), Int64(3), "one JOIN more")

    var err = String(RETURNED)
    try:
        _ = s.add_member[Rt](reactor, dm.channel_id, String("u-carol"), T0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a DM's members are fixed"))
    err = String(RETURNED)
    try:
        _ = s.remove_member[Rt](reactor, dm.channel_id, String("u-bob"), T0)
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a DM's members are fixed"))
    assert_true(s.is_member[Rt](reactor, dm.channel_id, String("u-bob")))
    err = String(RETURNED)
    try:
        _ = s.update_channel[Rt](
            reactor, dm.channel_id, Optional[String](), Optional[String](String("t")),
            Optional[Bool](),
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a DM has no name, topic or archive state"))
    err = String(RETURNED)
    try:
        _ = s.update_channel[Rt](
            reactor, dm.channel_id, Optional[String](), Optional[String](),
            Optional[Bool](True),
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a DM has no name, topic or archive state"))
    err = String(RETURNED)
    try:
        _ = s.update_channel[Rt](
            reactor, dm.channel_id, Optional[String](String("n")), Optional[String](),
            Optional[Bool](),
        )
    except e:
        err = String(e)
    assert_equal(err, String(E) + String("a DM has no name, topic or archive state"))
    var unchanged = s.update_channel[Rt](
        reactor, dm.channel_id, Optional[String](), Optional[String](), Optional[Bool]()
    )
    assert_equal(unchanged.kind, CHANNEL_DM)

    # A row under a DM id that is not that DM.
    _sql(
        s,
        "INSERT INTO chat_channels VALUES ('dm-u-carol.u-dee', 1, 'n', '', 0, 0,"
        " 'u-carol', '')",
    )
    assert_equal(
        _dm_err(s, "u-carol", _ids("u-dee")),
        String(E) + String("channel dm-u-carol.u-dee is not the DM of these users"),
    )
    _sql(
        s,
        "INSERT INTO chat_channels VALUES ('dm-u-eve.u-fay', 3, '', '', 0, 0,"
        " 'u-eve', 'u-eve,u-zed')",
    )
    assert_equal(
        _dm_err(s, "u-eve", _ids("u-fay")),
        String(E) + String("channel dm-u-eve.u-fay is not the DM of these users"),
    )
    assert_false(s.is_member[Rt](reactor, String("dm-u-eve.u-fay"), String("u-eve")))
    assert_equal(
        _dm_err(s, "u-eve", _ids("u-eve")),
        String(E) + String("a DM holds 2 to 9 distinct users, not 1"),
    )


def main() raises:
    test_users()
    test_channel_create()
    test_members()
    test_update_and_browse()
    test_dms()
    print("PASS komira_chat_store directory")
