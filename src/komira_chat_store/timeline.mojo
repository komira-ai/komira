# =============================================================================
# komira_chat_store/timeline.mojo -- a channel's timeline: seq allocation,
#   send, edit, delete, paging, threads, mentions and read state.
# =============================================================================
#
# SEQ ALLOCATION. Every event takes the next seq of its channel: 1, 2, 3, ...
# There is no counter. An append reads the channel's head (the largest seq in
# chat_events, 0 when the channel has no event), then inserts the event at
# head + 1 with `create_if_absent_composite` on (channel_id, seq). If another
# writer took that seq first, the insert reports it lost, and the append reads
# the head again and retries. So:
#   * a failed or abandoned send allocates nothing, and leaves no hole;
#   * an event at seq s+1 can only be inserted by a writer that read a head of
#     s, that is after the event at s was committed. A reader that has seen
#     s+1 has therefore been able to see s.
# On SQLite and Postgres the insert is one `INSERT ... ON CONFLICT (channel_id,
# seq) DO NOTHING RETURNING` statement; on a document store it is a create of
# the document named after (channel_id, seq) that fails if it exists. No
# multi-statement transaction is opened.
#
# IDEMPOTENT SEND. A send with a non-empty `client_msg_id` first looks for the
# sender's MESSAGE event with that key in the channel and, if it finds one,
# returns it and writes its mention rows again (none if it has been deleted
# since, whose mention rows the delete removed). Two retries of one key that
# run at the same moment can both miss the lookup and both append, and a
# retry that read the message just before a delete removed its mention rows
# writes them back.
#
# MENTION ROWS are written after the event, one per (channel, seq, user), each
# with `create_if_absent_composite`, so writing them twice is harmless. A
# crash between the event and its mention rows leaves the message without
# them until the client retries the send.
#
# EDIT AND DELETE. An edit appends an EDIT event carrying the new body, then
# copies the body onto the MESSAGE row, guarded on `last_edit_seq` so a later
# edit is never overwritten by an earlier one. A delete overwrites the MESSAGE
# row's body and the bodies of all its EDIT events with the empty string
# (they are redacted, not hidden), deletes its mention rows, then appends the
# DELETE event, then redacts the EDIT bodies once more in case an edit was
# appended meanwhile. An edit that finds its message deleted after its own
# append redacts its own EDIT event.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbRows, DbValue, Pred

from .ops import (
    all_of,
    asc,
    chat_err,
    delete_all,
    desc,
    eq,
    event_key_cols,
    event_values,
    flag,
    i64,
    limit,
    no_limit,
    no_order,
    require_page_size,
    select,
    set_to,
    sets,
    txt,
    update,
    update_all,
)
from .probe import SendProbe
from .records import (
    ChatEvent,
    EventPage,
    MentionPage,
    MentionRef,
    ReadState,
    EVENT_DELETE,
    EVENT_EDIT,
    EVENT_MESSAGE,
    event_from,
)
from .schema import (
    T_CURSORS,
    T_EVENTS,
    T_MENTIONS,
    cursor_cols,
    event_cols,
    mention_cols,
)

# The attempts an append makes before it gives up on a channel whose head
# keeps moving.
comptime MAX_APPEND_ATTEMPTS: Int = 64
# Events read per query when read state counts what follows a cursor.
comptime READ_STATE_BATCH: Int = 256
# The longest `client_msg_id` a send accepts, in bytes.
comptime MAX_CLIENT_MSG_ID_BYTES: Int = 128


def _seq_cols() -> List[String]:
    var c = List[String]()
    c.append(String("seq"))
    return c^


def head_seq[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String) raises -> Int64:
    """The largest seq in the channel's timeline; 0 when it has no event."""
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        _seq_cols(),
        all_of(eq("channel_id", txt(channel_id))),
        desc("seq"),
        limit(1),
    )
    if rows.__len__() == 0:
        return Int64(0)
    return rows.row(0).get_int8(0)


def append_event[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    var ev: ChatEvent,
) raises -> ChatEvent:
    """Insert `ev` at the channel's next seq and return it with that seq."""
    for _ in range(MAX_APPEND_ATTEMPTS):
        var s = head_seq[RT, DB](db, reactor, ev.channel_id) + 1
        probe.before_insert(ev.channel_id, s)
        ev.seq = s
        if db.create_if_absent_composite[RT](
            reactor,
            String(T_EVENTS),
            event_key_cols(),
            event_cols(),
            event_values(ev, Int64(0)),
        ):
            return ev^
    raise chat_err(
        String("channel ")
        + ev.channel_id
        + String(": no free seq after ")
        + String(MAX_APPEND_ATTEMPTS)
        + String(" attempts")
    )


def event_at[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, seq: Int64
) raises -> Optional[ChatEvent]:
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        event_cols(),
        all_of(eq("channel_id", txt(channel_id)), eq("seq", i64(seq))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[ChatEvent]()
    return Optional[ChatEvent](event_from(rows, 0))


def message_at[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, seq: Int64
) raises -> ChatEvent:
    """The MESSAGE event at `seq`; raises when there is none."""
    var found = event_at[RT, DB](db, reactor, channel_id, seq)
    if not found or found.value().kind != EVENT_MESSAGE:
        raise chat_err(
            String("channel ")
            + channel_id
            + String(" has no message at seq ")
            + String(seq)
        )
    return found.take()


def write_mentions[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], ev: ChatEvent) raises:
    var key = List[String]()
    key.append(String("channel_id"))
    key.append(String("seq"))
    key.append(String("user_id"))
    for i in range(len(ev.mention_user_ids)):
        var vals = List[DbValue]()
        vals.append(txt(ev.channel_id))
        vals.append(i64(ev.seq))
        vals.append(txt(ev.mention_user_ids[i]))
        vals.append(i64(ev.created_at_ms))
        _ = db.create_if_absent_composite[RT](
            reactor, String(T_MENTIONS), key, mention_cols(), vals
        )


def find_by_client_msg_id[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    sender_user_id: String,
    client_msg_id: String,
) raises -> Optional[ChatEvent]:
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        event_cols(),
        all_of(
            eq("channel_id", txt(channel_id)),
            eq("sender_user_id", txt(sender_user_id)),
            eq("client_msg_id", txt(client_msg_id)),
            eq("kind", i64(Int64(EVENT_MESSAGE))),
        ),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[ChatEvent]()
    return Optional[ChatEvent](event_from(rows, 0))


def send_checked[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    var msg: ChatEvent,
) raises -> ChatEvent:
    """Append the MESSAGE `msg` (whose channel, membership, thread root and
    files the caller has checked), or return the sender's earlier event with
    the same non-empty `client_msg_id`. Writes its mention rows either way,
    unless the earlier event has been deleted."""
    if msg.client_msg_id.byte_length() > MAX_CLIENT_MSG_ID_BYTES:
        raise chat_err(
            String("client_msg_id is longer than ")
            + String(MAX_CLIENT_MSG_ID_BYTES)
            + String(" bytes")
        )
    if msg.client_msg_id.byte_length() > 0:
        var earlier = find_by_client_msg_id[RT, DB](
            db, reactor, msg.channel_id, msg.sender_user_id, msg.client_msg_id
        )
        if earlier:
            var ev = earlier.take()
            if not ev.deleted:
                write_mentions[RT, DB](db, reactor, ev)
            return ev^
    var ev = append_event[RT, DB, P](db, probe, reactor, msg^)
    write_mentions[RT, DB](db, reactor, ev)
    return ev^


def thread_root_check[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, root: Int64
) raises:
    """Raises unless `root` is a top-level MESSAGE of the channel that is not
    deleted: a reply never starts a thread of its own."""
    var found = event_at[RT, DB](db, reactor, channel_id, root)
    if (
        not found
        or found.value().kind != EVENT_MESSAGE
        or found.value().thread_root_seq != 0
        or found.value().deleted
    ):
        raise chat_err(
            String("thread root ")
            + String(root)
            + String(" is not a top-level message of channel ")
            + channel_id
        )


def _redact_edits[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, seq: Int64
) raises -> Int:
    return update_all[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(
            eq("channel_id", txt(channel_id)),
            eq("kind", i64(Int64(EVENT_EDIT))),
            eq("target_seq", i64(seq)),
            Pred.ne(String("body"), txt(String())),
        ),
        sets(set_to("body", txt(String()))),
    )


def edit_checked[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    seq: Int64,
    editor_user_id: String,
    body: String,
    now_ms: Int64,
) raises -> ChatEvent:
    """Edit the editor's own message at `seq`; returns the EDIT event."""
    var target = message_at[RT, DB](db, reactor, channel_id, seq)
    if target.deleted:
        raise chat_err(
            String("message ") + String(seq) + String(" is deleted")
        )
    if target.sender_user_id != editor_user_id:
        raise chat_err(
            editor_user_id + String(" did not send message ") + String(seq)
        )
    var ev = append_event[RT, DB, P](
        db,
        probe,
        reactor,
        ChatEvent(
            channel_id,
            Int64(0),
            EVENT_EDIT,
            editor_user_id,
            body,
            Int64(0),
            seq,
            String(),
            List[String](),
            False,
            List[String](),
            now_ms,
            False,
            False,
        ),
    )
    var changed = update[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(
            eq("channel_id", txt(channel_id)),
            eq("seq", i64(seq)),
            eq("deleted", flag(False)),
            Pred.lt(String("last_edit_seq"), i64(ev.seq)),
        ),
        sets(
            set_to("body", txt(body)),
            set_to("edited", flag(True)),
            set_to("last_edit_seq", i64(ev.seq)),
        ),
    )
    if changed == 0:
        var now = message_at[RT, DB](db, reactor, channel_id, seq)
        if now.deleted:
            _ = _redact_edits[RT, DB](db, reactor, channel_id, seq)
            ev.body = String()
    return ev^


def delete_checked[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    seq: Int64,
    by_user_id: String,
    any_sender: Bool,
    now_ms: Int64,
) raises -> ChatEvent:
    """Delete the message at `seq`: its sender's own, or any message when
    `any_sender`. Returns the DELETE event; deleting a deleted message
    returns the DELETE event already appended."""
    var target = message_at[RT, DB](db, reactor, channel_id, seq)
    if target.sender_user_id != by_user_id and not any_sender:
        raise chat_err(
            by_user_id + String(" did not send message ") + String(seq)
        )
    if target.deleted:
        var rows = select[RT, DB](
            db,
            reactor,
            T_EVENTS,
            event_cols(),
            all_of(
                eq("channel_id", txt(channel_id)),
                eq("kind", i64(Int64(EVENT_DELETE))),
                eq("target_seq", i64(seq)),
            ),
            no_order(),
            limit(1),
        )
        if rows.__len__() > 0:
            return event_from(rows, 0)
    _ = update[RT, DB](
        db,
        reactor,
        T_EVENTS,
        all_of(eq("channel_id", txt(channel_id)), eq("seq", i64(seq))),
        sets(set_to("body", txt(String())), set_to("deleted", flag(True))),
    )
    _ = _redact_edits[RT, DB](db, reactor, channel_id, seq)
    _ = delete_all[RT, DB](
        db,
        reactor,
        T_MENTIONS,
        all_of(eq("channel_id", txt(channel_id)), eq("seq", i64(seq))),
    )
    var ev = append_event[RT, DB, P](
        db,
        probe,
        reactor,
        ChatEvent(
            channel_id,
            Int64(0),
            EVENT_DELETE,
            by_user_id,
            String(),
            Int64(0),
            seq,
            String(),
            List[String](),
            False,
            List[String](),
            now_ms,
            False,
            False,
        ),
    )
    _ = _redact_edits[RT, DB](db, reactor, channel_id, seq)
    return ev^


def _events(rows: DbRows) raises -> List[ChatEvent]:
    var out = List[ChatEvent]()
    for i in range(rows.__len__()):
        out.append(event_from(rows, i))
    return out^


def page_after[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    since_seq: Int64,
    max_events: Int,
) raises -> EventPage:
    """Up to `max_events` events after `since_seq`, oldest first."""
    require_page_size(max_events, "max_events")
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        event_cols(),
        all_of(
            eq("channel_id", txt(channel_id)),
            Pred.gte(String("seq"), i64(since_seq + 1)),
        ),
        asc("seq"),
        limit(max_events + 1),
    )
    var evs = _events(rows)
    var more = len(evs) > max_events
    if more:
        _ = evs.pop()
    var head = head_seq[RT, DB](db, reactor, channel_id)
    return EventPage(evs^, head, more)


def page_before[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    before_seq: Int64,
    max_events: Int,
) raises -> EventPage:
    """Up to `max_events` of the newest events before `before_seq`, oldest
    first."""
    require_page_size(max_events, "max_events")
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        event_cols(),
        all_of(
            eq("channel_id", txt(channel_id)),
            Pred.lt(String("seq"), i64(before_seq)),
        ),
        desc("seq"),
        limit(max_events + 1),
    )
    var newest_first = _events(rows)
    var more = len(newest_first) > max_events
    if more:
        _ = newest_first.pop()
    var evs = List[ChatEvent]()
    var i = len(newest_first) - 1
    while i >= 0:
        evs.append(newest_first[i].copy())
        i -= 1
    var head = head_seq[RT, DB](db, reactor, channel_id)
    return EventPage(evs^, head, more)


def thread_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    root_seq: Int64,
    since_seq: Int64,
    max_events: Int,
) raises -> EventPage:
    """Up to `max_events` replies in the thread of `root_seq` after
    `since_seq`, oldest first."""
    require_page_size(max_events, "max_events")
    var rows = select[RT, DB](
        db,
        reactor,
        T_EVENTS,
        event_cols(),
        all_of(
            eq("channel_id", txt(channel_id)),
            eq("thread_root_seq", i64(root_seq)),
            Pred.gte(String("seq"), i64(since_seq + 1)),
        ),
        asc("seq"),
        limit(max_events + 1),
    )
    var evs = _events(rows)
    var more = len(evs) > max_events
    if more:
        _ = evs.pop()
    var head = head_seq[RT, DB](db, reactor, channel_id)
    return EventPage(evs^, head, more)


def _mention_before(a: MentionRef, b: MentionRef) -> Bool:
    """The mentions view's order: newest first, then by channel and seq."""
    if a.created_at_ms != b.created_at_ms:
        return a.created_at_ms > b.created_at_ms
    if a.channel_id != b.channel_id:
        return a.channel_id < b.channel_id
    return a.seq < b.seq


def _mention_refs(rows: DbRows) raises -> List[MentionRef]:
    """The rows as mentions, in the view's order."""
    var out = List[MentionRef]()
    var ci = rows.column_index(String("channel_id"))
    var si = rows.column_index(String("seq"))
    var ti = rows.column_index(String("created_at_ms"))
    for i in range(rows.__len__()):
        ref r = rows.row(i)
        var m = MentionRef(r.get_text(ci), r.get_int8(si), r.get_int8(ti))
        var j = len(out)
        out.append(m.copy())
        while j > 0 and _mention_before(m, out[j - 1]):
            out[j] = out[j - 1].copy()
            j -= 1
        out[j] = m^
    return out^


def mentions_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    user_id: String,
    before_ms: Int64,
    max_mentions: Int,
) raises -> MentionPage:
    """Mentions of `user_id` created before `before_ms`, newest first, then by
    channel and seq. A page never splits a millisecond: when a full page
    would end partway through one, that millisecond's mentions move to the
    next page; when one millisecond alone holds more than `max_mentions`,
    the page is all of that millisecond, longer than `max_mentions`."""
    require_page_size(max_mentions, "max_mentions")
    var out = _mention_refs(
        select[RT, DB](
            db,
            reactor,
            T_MENTIONS,
            mention_cols(),
            all_of(
                eq("user_id", txt(user_id)),
                Pred.lt(String("created_at_ms"), i64(before_ms)),
            ),
            desc("created_at_ms"),
            limit(max_mentions + 1),
        )
    )
    if len(out) <= max_mentions:
        return MentionPage(out^, Int64(0))
    var extra = out.pop()
    var last_ms = out[len(out) - 1].created_at_ms
    if extra.created_at_ms != last_ms:
        # The page holds every mention of its last millisecond.
        return MentionPage(out^, last_ms)
    var keep = len(out)
    while keep > 0 and out[keep - 1].created_at_ms == last_ms:
        keep -= 1
    if keep > 0:
        # Drop the partial last millisecond; the next page starts with it.
        while len(out) > keep:
            _ = out.pop()
        return MentionPage(out^, last_ms + 1)
    # One millisecond fills the page: return all of it. Two equalities need
    # no composite index on a document store.
    var group = _mention_refs(
        select[RT, DB](
            db,
            reactor,
            T_MENTIONS,
            mention_cols(),
            all_of(
                eq("user_id", txt(user_id)),
                eq("created_at_ms", i64(last_ms)),
            ),
            no_order(),
            no_limit(),
        )
    )
    var older = select[RT, DB](
        db,
        reactor,
        T_MENTIONS,
        mention_cols(),
        all_of(
            eq("user_id", txt(user_id)),
            Pred.lt(String("created_at_ms"), i64(last_ms)),
        ),
        desc("created_at_ms"),
        limit(1),
    )
    if older.__len__() == 0:
        return MentionPage(group^, Int64(0))
    return MentionPage(group^, last_ms)


def read_seq_of[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
) raises -> Int64:
    """The user's read cursor in the channel; 0 when it has none."""
    var cols = List[String]()
    cols.append(String("read_seq"))
    var rows = select[RT, DB](
        db,
        reactor,
        T_CURSORS,
        cols,
        all_of(eq("channel_id", txt(channel_id)), eq("user_id", txt(user_id))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Int64(0)
    return rows.row(0).get_int8(0)


def mark_read[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    user_id: String,
    seq: Int64,
) raises -> Int64:
    """Move the user's read cursor forward to `seq`, never backward; returns
    the cursor after the move."""
    var key = List[String]()
    key.append(String("channel_id"))
    key.append(String("user_id"))
    var vals = List[DbValue]()
    vals.append(txt(channel_id))
    vals.append(txt(user_id))
    vals.append(i64(seq))
    if db.create_if_absent_composite[RT](
        reactor, String(T_CURSORS), key, cursor_cols(), vals
    ):
        return seq
    _ = update[RT, DB](
        db,
        reactor,
        T_CURSORS,
        all_of(
            eq("channel_id", txt(channel_id)),
            eq("user_id", txt(user_id)),
            Pred.lt(String("read_seq"), i64(seq)),
        ),
        sets(set_to("read_seq", i64(seq))),
    )
    return read_seq_of[RT, DB](db, reactor, channel_id, user_id)


def read_state_of[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
) raises -> ReadState:
    var cursor = read_seq_of[RT, DB](db, reactor, channel_id, user_id)
    var unread = 0
    var mentions = 0
    var since = cursor
    while True:
        var page = page_after[RT, DB](
            db, reactor, channel_id, since, READ_STATE_BATCH
        )
        for i in range(len(page.events)):
            ref ev = page.events[i]
            since = ev.seq
            if (
                ev.kind != EVENT_MESSAGE
                or ev.deleted
                or ev.sender_user_id == user_id
            ):
                continue
            unread += 1
            var named = ev.mentions_channel
            for j in range(len(ev.mention_user_ids)):
                if ev.mention_user_ids[j] == user_id:
                    named = True
            if named:
                mentions += 1
        if not page.has_more:
            break
    return ReadState(channel_id, cursor, unread, mentions)
