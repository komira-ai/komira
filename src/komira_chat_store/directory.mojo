# =============================================================================
# komira_chat_store/directory.mojo -- users, channels, members and files.
# =============================================================================
#
# USERS. A user is created the first time a token's (iss, sub) is seen. The
# subject row is claimed first (`create_if_absent` on its key), so two first
# requests of one subject agree on one user_id; the user row follows. A
# claim that finds the subject already taken uses the user_id stored there
# and creates the user row if a crash left it missing.
#
# MEMBERSHIP. Adding a member writes the (channel_id, user_id) row with
# `create_if_absent_composite`, then appends a JOIN event; removing deletes
# the row, then appends a LEAVE event. Only the call that wrote or deleted
# the row appends the event, so a repeated add or remove appends nothing.
#
# DMs. A DM's id is derived from its sorted users (keys.dm_channel_id), so
# opening the DM of a set of users that already has one returns it, and
# re-adds any member a crash left out.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database, DbColVal, DbValue, Filter, Pred

from .keys import (
    dm_channel_id,
    dm_users,
    join_ids,
    require_id,
    subject_key,
)
from .ops import (
    all_of,
    asc,
    chat_err,
    delete_all,
    eq,
    flag,
    i64,
    limit,
    no_order,
    require_page_size,
    select,
    set_to,
    sets,
    txt,
    update,
)
from .probe import SendProbe
from .records import (
    ChatChannel,
    ChatEvent,
    ChatFile,
    ChatUser,
    IdPage,
    CHANNEL_DM,
    CHANNEL_PRIVATE,
    CHANNEL_PUBLIC,
    EVENT_JOIN,
    EVENT_LEAVE,
    FILE_COMPLETE,
    FILE_PENDING,
    channel_from,
    file_from,
    user_from,
)
from .schema import (
    T_CHANNELS,
    T_FILES,
    T_MEMBERS,
    T_SUBJECTS,
    T_USERS,
    channel_cols,
    file_cols,
    member_cols,
    subject_cols,
    user_cols,
)
from .timeline import append_event


# ---- users -----------------------------------------------------------------


def user_by_id[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], user_id: String) raises -> Optional[
    ChatUser
]:
    var rows = select[RT, DB](
        db,
        reactor,
        T_USERS,
        user_cols(),
        all_of(eq("user_id", txt(user_id))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[ChatUser]()
    return Optional[ChatUser](user_from(rows, 0))


def user_id_for_subject[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], iss: String, sub: String
) raises -> Optional[String]:
    var cols = List[String]()
    cols.append(String("user_id"))
    var rows = select[RT, DB](
        db,
        reactor,
        T_SUBJECTS,
        cols,
        all_of(eq("subject_key", txt(subject_key(iss, sub)))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[String]()
    return Optional[String](rows.row(0).get_text(0))


def ensure_user[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    new_user_id: String,
    iss: String,
    sub: String,
    display_name: String,
    email: String,
    now_ms: Int64,
) raises -> ChatUser:
    """The user of (iss, sub), created with `new_user_id` if the subject is
    new. The display name and email are updated to the given ones."""
    require_id(new_user_id, "user id")
    if iss.byte_length() == 0 or sub.byte_length() == 0:
        raise chat_err(String("a subject needs a non-empty iss and sub"))
    var key = subject_key(iss, sub)
    var sv = List[DbValue]()
    sv.append(txt(key))
    sv.append(txt(new_user_id))
    var user_id = new_user_id
    if not db.create_if_absent[RT](
        reactor, String(T_SUBJECTS), String("subject_key"), txt(key), subject_cols(), sv
    ):
        var claimed = user_id_for_subject[RT, DB](db, reactor, iss, sub)
        if not claimed:
            raise chat_err(String("the subject row vanished while it was read"))
        user_id = claimed.take()
    var uv = List[DbValue]()
    uv.append(txt(user_id))
    uv.append(txt(iss))
    uv.append(txt(sub))
    uv.append(txt(display_name))
    uv.append(txt(email))
    uv.append(i64(now_ms))
    if not db.create_if_absent[RT](
        reactor, String(T_USERS), String("user_id"), txt(user_id), user_cols(), uv
    ):
        _ = update[RT, DB](
            db,
            reactor,
            T_USERS,
            all_of(eq("user_id", txt(user_id))),
            sets(
                set_to("display_name", txt(display_name)),
                set_to("email", txt(email)),
            ),
        )
    var got = user_by_id[RT, DB](db, reactor, user_id)
    if not got:
        raise chat_err(String("user ") + user_id + String(" vanished"))
    return got.take()


def _page_of(rows_ids: List[String], max_ids: Int) -> IdPage:
    var ids = rows_ids.copy()
    var next = String()
    if len(ids) > max_ids:
        next = ids.pop()
    return IdPage(ids^, next^)


def _ids_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    table: StaticString,
    id_col: StaticString,
    var preds: List[Pred],
    from_id: String,
    max_ids: Int,
) raises -> IdPage:
    require_page_size(max_ids, "max_ids")
    preds.append(Pred.gte(String(id_col), txt(from_id)))
    var cols = List[String]()
    cols.append(String(id_col))
    var rows = select[RT, DB](
        db,
        reactor,
        table,
        cols,
        Filter.all_of(preds^),
        asc(id_col),
        limit(max_ids + 1),
    )
    var ids = List[String]()
    for i in range(rows.__len__()):
        ids.append(rows.row(i).get_text(0))
    return _page_of(ids, max_ids)


def users_page[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], from_user_id: String, max_ids: Int
) raises -> IdPage:
    """User ids from `from_user_id` (inclusive; empty for the first page)."""
    return _ids_page[RT, DB](
        db, reactor, T_USERS, "user_id", List[Pred](), from_user_id, max_ids
    )


# ---- channels --------------------------------------------------------------


def channel_by_id[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String
) raises -> Optional[ChatChannel]:
    var rows = select[RT, DB](
        db,
        reactor,
        T_CHANNELS,
        channel_cols(),
        all_of(eq("channel_id", txt(channel_id))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[ChatChannel]()
    return Optional[ChatChannel](channel_from(rows, 0))


def existing_channel[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String
) raises -> ChatChannel:
    var found = channel_by_id[RT, DB](db, reactor, channel_id)
    if not found:
        raise chat_err(String("no channel ") + channel_id)
    return found.take()


def writable_channel[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String
) raises -> ChatChannel:
    """The channel; raises when it does not exist or is archived."""
    var ch = existing_channel[RT, DB](db, reactor, channel_id)
    if ch.archived:
        raise chat_err(String("channel ") + channel_id + String(" is archived"))
    return ch^


def _channel_values(ch: ChatChannel) -> List[DbValue]:
    var v = List[DbValue]()
    v.append(txt(ch.channel_id))
    v.append(i64(Int64(ch.kind)))
    v.append(txt(ch.name))
    v.append(txt(ch.topic))
    v.append(flag(ch.archived))
    v.append(i64(ch.created_at_ms))
    v.append(txt(ch.created_by_user_id))
    v.append(txt(join_ids(ch.dm_user_ids)))
    return v^


def is_member_of[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
) raises -> Bool:
    var cols = List[String]()
    cols.append(String("user_id"))
    var rows = select[RT, DB](
        db,
        reactor,
        T_MEMBERS,
        cols,
        all_of(eq("channel_id", txt(channel_id)), eq("user_id", txt(user_id))),
        no_order(),
        limit(1),
    )
    return rows.__len__() > 0


def _membership_event(
    channel_id: String, user_id: String, kind: Int, now_ms: Int64
) -> ChatEvent:
    return ChatEvent(
        channel_id,
        Int64(0),
        kind,
        user_id,
        String(),
        Int64(0),
        Int64(0),
        String(),
        List[String](),
        False,
        List[String](),
        now_ms,
        False,
        False,
    )


def add_member_row[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    user_id: String,
    now_ms: Int64,
) raises -> Bool:
    """Write the membership and its JOIN event; False if it already
    existed (and nothing was appended)."""
    require_id(user_id, "user id")
    var key = List[String]()
    key.append(String("channel_id"))
    key.append(String("user_id"))
    var vals = List[DbValue]()
    vals.append(txt(channel_id))
    vals.append(txt(user_id))
    vals.append(i64(now_ms))
    if not db.create_if_absent_composite[RT](
        reactor, String(T_MEMBERS), key, member_cols(), vals
    ):
        return False
    _ = append_event[RT, DB, P](
        db, probe, reactor, _membership_event(channel_id, user_id, EVENT_JOIN, now_ms)
    )
    return True


def remove_member_row[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    user_id: String,
    now_ms: Int64,
) raises -> Bool:
    """Delete the membership and append its LEAVE event; False if there was
    none."""
    var n = delete_all[RT, DB](
        db,
        reactor,
        T_MEMBERS,
        all_of(eq("channel_id", txt(channel_id)), eq("user_id", txt(user_id))),
    )
    if n == 0:
        return False
    _ = append_event[RT, DB, P](
        db, probe, reactor, _membership_event(channel_id, user_id, EVENT_LEAVE, now_ms)
    )
    return True


def create_channel_rows[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    kind: Int,
    name: String,
    topic: String,
    creator_user_id: String,
    member_user_ids: List[String],
    now_ms: Int64,
) raises -> ChatChannel:
    require_id(channel_id, "channel id")
    require_id(creator_user_id, "user id")
    if kind != CHANNEL_PUBLIC and kind != CHANNEL_PRIVATE:
        raise chat_err(
            String("create_channel makes a PUBLIC or PRIVATE channel, not kind ")
            + String(kind)
        )
    if name.byte_length() == 0:
        raise chat_err(String("a channel needs a name"))
    for i in range(len(member_user_ids)):
        require_id(member_user_ids[i], "user id")
    var ch = ChatChannel(
        channel_id,
        kind,
        name,
        topic,
        False,
        now_ms,
        creator_user_id,
        List[String](),
    )
    if not db.create_if_absent[RT](
        reactor,
        String(T_CHANNELS),
        String("channel_id"),
        txt(channel_id),
        channel_cols(),
        _channel_values(ch),
    ):
        raise chat_err(String("channel ") + channel_id + String(" already exists"))
    _ = add_member_row[RT, DB, P](db, probe, reactor, channel_id, creator_user_id, now_ms)
    for i in range(len(member_user_ids)):
        _ = add_member_row[RT, DB, P](
            db, probe, reactor, channel_id, member_user_ids[i], now_ms
        )
    return ch^


def open_dm_rows[
    RT: Runtime, DB: Database, P: SendProbe
](
    mut db: DB,
    mut probe: P,
    mut reactor: Reactor[RT.Sink],
    opener_user_id: String,
    user_ids: List[String],
    now_ms: Int64,
) raises -> ChatChannel:
    var all = user_ids.copy()
    all.append(opener_user_id)
    var users = dm_users(all)
    var id = dm_channel_id(users)
    var ch = ChatChannel(
        id,
        CHANNEL_DM,
        String(),
        String(),
        False,
        now_ms,
        opener_user_id,
        users.copy(),
    )
    if not db.create_if_absent[RT](
        reactor,
        String(T_CHANNELS),
        String("channel_id"),
        txt(id),
        channel_cols(),
        _channel_values(ch),
    ):
        ch = existing_channel[RT, DB](db, reactor, id)
        if ch.kind != CHANNEL_DM or join_ids(ch.dm_user_ids) != join_ids(users):
            raise chat_err(
                String("channel ") + id + String(" is not the DM of these users")
            )
    for i in range(len(users)):
        _ = add_member_row[RT, DB, P](db, probe, reactor, id, users[i], now_ms)
    return ch^


def update_channel_row[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    name: Optional[String],
    topic: Optional[String],
    archived: Optional[Bool],
) raises -> ChatChannel:
    """Change the fields that are present; returns the channel after."""
    var ch = existing_channel[RT, DB](db, reactor, channel_id)
    if ch.kind == CHANNEL_DM and (name or topic or archived):
        raise chat_err(String("a DM has no name, topic or archive state"))
    var upd = List[DbColVal]()
    if name:
        if name.value().byte_length() == 0:
            raise chat_err(String("a channel needs a name"))
        upd.append(set_to("name", txt(name.value())))
    if topic:
        upd.append(set_to("topic", txt(topic.value())))
    if archived:
        upd.append(set_to("archived", flag(archived.value())))
    if len(upd) > 0:
        _ = update[RT, DB](
            db, reactor, T_CHANNELS, all_of(eq("channel_id", txt(channel_id))), upd
        )
    return existing_channel[RT, DB](db, reactor, channel_id)


def browse_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    from_channel_id: String,
    max_ids: Int,
    include_archived: Bool,
) raises -> IdPage:
    """Public channel ids from `from_channel_id` (inclusive)."""
    var preds = List[Pred]()
    preds.append(eq("kind", i64(Int64(CHANNEL_PUBLIC))))
    if not include_archived:
        preds.append(eq("archived", flag(False)))
    return _ids_page[RT, DB](
        db, reactor, T_CHANNELS, "channel_id", preds^, from_channel_id, max_ids
    )


def channels_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    user_id: String,
    from_channel_id: String,
    max_ids: Int,
) raises -> IdPage:
    """Ids of the channels `user_id` is a member of, DMs included."""
    var preds = List[Pred]()
    preds.append(eq("user_id", txt(user_id)))
    return _ids_page[RT, DB](
        db, reactor, T_MEMBERS, "channel_id", preds^, from_channel_id, max_ids
    )


def members_page[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    from_user_id: String,
    max_ids: Int,
) raises -> IdPage:
    var preds = List[Pred]()
    preds.append(eq("channel_id", txt(channel_id)))
    return _ids_page[RT, DB](
        db, reactor, T_MEMBERS, "user_id", preds^, from_user_id, max_ids
    )


# ---- files -----------------------------------------------------------------


def file_by_id[
    RT: Runtime, DB: Database
](mut db: DB, mut reactor: Reactor[RT.Sink], file_id: String) raises -> Optional[
    ChatFile
]:
    var rows = select[RT, DB](
        db,
        reactor,
        T_FILES,
        file_cols(),
        all_of(eq("file_id", txt(file_id))),
        no_order(),
        limit(1),
    )
    if rows.__len__() == 0:
        return Optional[ChatFile]()
    return Optional[ChatFile](file_from(rows, 0))


def create_file_row[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    file_id: String,
    channel_id: String,
    name: String,
    content_type: String,
    declared_size: Int64,
    uploader_user_id: String,
    now_ms: Int64,
) raises -> ChatFile:
    require_id(file_id, "file id")
    require_id(uploader_user_id, "user id")
    _ = existing_channel[RT, DB](db, reactor, channel_id)
    var f = ChatFile(
        file_id,
        channel_id,
        name,
        content_type,
        declared_size,
        FILE_PENDING,
        uploader_user_id,
        now_ms,
    )
    var v = List[DbValue]()
    v.append(txt(f.file_id))
    v.append(txt(f.channel_id))
    v.append(txt(f.name))
    v.append(txt(f.content_type))
    v.append(i64(f.size_bytes))
    v.append(i64(Int64(f.state)))
    v.append(txt(f.uploader_user_id))
    v.append(i64(f.created_at_ms))
    if not db.create_if_absent[RT](
        reactor, String(T_FILES), String("file_id"), txt(file_id), file_cols(), v
    ):
        raise chat_err(String("file ") + file_id + String(" already exists"))
    return f^


def complete_file_row[
    RT: Runtime, DB: Database
](
    mut db: DB, mut reactor: Reactor[RT.Sink], file_id: String, size_bytes: Int64
) raises -> ChatFile:
    """Mark a PENDING file COMPLETE with the size found; completing a
    COMPLETE file returns it unchanged."""
    _ = update[RT, DB](
        db,
        reactor,
        T_FILES,
        all_of(
            eq("file_id", txt(file_id)), eq("state", i64(Int64(FILE_PENDING)))
        ),
        sets(
            set_to("state", i64(Int64(FILE_COMPLETE))),
            set_to("size_bytes", i64(size_bytes)),
        ),
    )
    var f = file_by_id[RT, DB](db, reactor, file_id)
    if not f:
        raise chat_err(String("no file ") + file_id)
    return f.take()


def attachable_check[
    RT: Runtime, DB: Database
](
    mut db: DB,
    mut reactor: Reactor[RT.Sink],
    channel_id: String,
    file_ids: List[String],
) raises:
    """Raises unless each file is a COMPLETE file of the channel."""
    for i in range(len(file_ids)):
        require_id(file_ids[i], "file id")
        var f = file_by_id[RT, DB](db, reactor, file_ids[i])
        if (
            not f
            or f.value().channel_id != channel_id
            or f.value().state != FILE_COMPLETE
        ):
            raise chat_err(
                String("file ")
                + file_ids[i]
                + String(" is not a complete file of channel ")
                + channel_id
            )
