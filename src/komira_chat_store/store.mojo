# =============================================================================
# komira_chat_store/store.mojo -- ChatStore[DB, P], the chat storage over
#   komira_db's backend-neutral `Database`.
# =============================================================================
#
# The store owns one database handle and renders no SQL: every call is one of
# the neutral structured ops. It is run against SQLite, and against a
# document store only through komira_gcp_firestore_db's in-process mock; the
# Postgres path is written (the SQL schema, the dialect check) but has not
# been run. On a SQL backend, create the schema with `chat_migrations()` and
# pass the handle through `prepare_sql_connection` first; the mock is run with
# `CHAT_DOCUMENT_KEYS` and `CHAT_DOCUMENT_INDEXES` (schema.mojo) declared.
#
# What the store checks, so that no caller can break the timeline: that ids
# have the id shape, a send or edit or delete goes to an existing, unarchived
# channel the sender belongs to, a thread root is a top-level message of the
# channel, an attached file is a COMPLETE file of the channel, and an edit is
# of the editor's own message. Who may call what (a non-member reading a
# channel, an admin deleting another's message) is the service's to decide.
#
# The seq allocation, idempotent send, edit and delete are described in
# timeline.mojo; users, channels and members in directory.mojo; erasure in
# erasure.mojo.
#
# `P` is the test seam of `probe.mojo`; leave it at `NoSendProbe`.
# Every method takes the caller's reactor: Postgres parks its I/O on it, and
# SQLite ignores it.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Database

from .directory import (
    add_member_row,
    attachable_check,
    browse_page,
    channel_by_id,
    channels_page,
    complete_file_row,
    create_channel_rows,
    create_file_row,
    ensure_user as ensure_user_rows,
    file_by_id,
    is_member_of,
    members_page,
    open_dm_rows,
    remove_member_row,
    update_channel_row,
    user_by_id,
    user_id_for_subject,
    users_page,
    writable_channel,
)
from .erasure import erase_user_rows, user_ids_with_subject
from .keys import require_id, subject_key
from .ops import all_of, chat_err, delete_all, eq, txt
from .probe import NoSendProbe, SendProbe
from .records import (
    ChatChannel,
    ChatEvent,
    ChatFile,
    ChatUser,
    EraseCounts,
    EventPage,
    IdPage,
    MentionPage,
    ReadState,
    CHANNEL_PRIVATE,
    CHANNEL_PUBLIC,
    EVENT_MESSAGE,
)
from .schema import T_FILES, T_SUBJECTS
from .timeline import (
    delete_checked,
    edit_checked,
    event_at,
    head_seq as head_seq_of,
    mark_read as mark_read_row,
    mentions_page,
    page_after,
    page_before,
    read_state_of,
    send_checked,
    thread_page,
    thread_root_check,
)


struct ChatStore[DB: Database, P: SendProbe = NoSendProbe](Movable):
    var _db: Self.DB
    var _probe: Self.P

    def __init__(out self, var db: Self.DB, var probe: Self.P):
        self._db = db^
        self._probe = probe^

    @always_inline
    def db(ref self) -> ref [self._db] Self.DB:
        """The database handle (to run the SQL erasure step on it, or for a
        test to read the rows)."""
        return self._db

    @always_inline
    def probe(ref self) -> ref [self._probe] Self.P:
        return self._probe

    def into_db(deinit self) -> Self.DB:
        return self._db^

    def _member_check[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
    ) raises:
        if not is_member_of[RT, Self.DB](self._db, reactor, channel_id, user_id):
            raise chat_err(
                user_id + String(" is not a member of channel ") + channel_id
            )

    # ---- users ---------------------------------------------------------------

    def ensure_user[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        new_user_id: String,
        iss: String,
        sub: String,
        display_name: String,
        email: String,
        now_ms: Int64,
    ) raises -> ChatUser:
        """The user of a token's (iss, sub), created with `new_user_id` the
        first time the subject is seen; its display name and email are set
        to the given ones."""
        return ensure_user_rows[RT, Self.DB](
            self._db, reactor, new_user_id, iss, sub, display_name, email, now_ms
        )

    def user[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], user_id: String) raises -> Optional[
        ChatUser
    ]:
        return user_by_id[RT, Self.DB](self._db, reactor, user_id)

    def user_for_subject[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], iss: String, sub: String
    ) raises -> Optional[ChatUser]:
        var id = user_id_for_subject[RT, Self.DB](self._db, reactor, iss, sub)
        if not id:
            return Optional[ChatUser]()
        return user_by_id[RT, Self.DB](self._db, reactor, id.value())

    def users[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], from_user_id: String, max_ids: Int
    ) raises -> IdPage:
        return users_page[RT, Self.DB](self._db, reactor, from_user_id, max_ids)

    # ---- channels and members --------------------------------------------------

    def create_channel[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        kind: Int,
        name: String,
        topic: String,
        creator_user_id: String,
        member_user_ids: List[String],
        now_ms: Int64,
    ) raises -> ChatChannel:
        """A new PUBLIC or PRIVATE channel with the creator and the given
        users as members, each with a JOIN event."""
        return create_channel_rows[RT, Self.DB, Self.P](
            self._db,
            self._probe,
            reactor,
            channel_id,
            kind,
            name,
            topic,
            creator_user_id,
            member_user_ids,
            now_ms,
        )

    def open_dm[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        opener_user_id: String,
        user_ids: List[String],
        now_ms: Int64,
    ) raises -> ChatChannel:
        """The DM between the opener and `user_ids`, created if new."""
        return open_dm_rows[RT, Self.DB, Self.P](
            self._db, self._probe, reactor, opener_user_id, user_ids, now_ms
        )

    def channel[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], channel_id: String
    ) raises -> Optional[ChatChannel]:
        return channel_by_id[RT, Self.DB](self._db, reactor, channel_id)

    def update_channel[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        name: Optional[String],
        topic: Optional[String],
        archived: Optional[Bool],
    ) raises -> ChatChannel:
        return update_channel_row[RT, Self.DB](
            self._db, reactor, channel_id, name, topic, archived
        )

    def browse_channels[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        from_channel_id: String,
        max_ids: Int,
        include_archived: Bool,
    ) raises -> IdPage:
        return browse_page[RT, Self.DB](
            self._db, reactor, from_channel_id, max_ids, include_archived
        )

    def channels_of[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        user_id: String,
        from_channel_id: String,
        max_ids: Int,
    ) raises -> IdPage:
        return channels_page[RT, Self.DB](
            self._db, reactor, user_id, from_channel_id, max_ids
        )

    def is_member[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
    ) raises -> Bool:
        return is_member_of[RT, Self.DB](self._db, reactor, channel_id, user_id)

    def members[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        from_user_id: String,
        max_ids: Int,
    ) raises -> IdPage:
        return members_page[RT, Self.DB](
            self._db, reactor, channel_id, from_user_id, max_ids
        )

    def add_member[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        user_id: String,
        now_ms: Int64,
    ) raises -> Bool:
        """Add a member to an unarchived PUBLIC or PRIVATE channel and append
        its JOIN event; False if it was a member already."""
        var ch = writable_channel[RT, Self.DB](self._db, reactor, channel_id)
        if ch.kind != CHANNEL_PUBLIC and ch.kind != CHANNEL_PRIVATE:
            raise chat_err(String("a DM's members are fixed"))
        return add_member_row[RT, Self.DB, Self.P](
            self._db, self._probe, reactor, channel_id, user_id, now_ms
        )

    def remove_member[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        user_id: String,
        now_ms: Int64,
    ) raises -> Bool:
        """Remove a member and append its LEAVE event; False if it was not
        a member."""
        var ch = writable_channel[RT, Self.DB](self._db, reactor, channel_id)
        if ch.kind != CHANNEL_PUBLIC and ch.kind != CHANNEL_PRIVATE:
            raise chat_err(String("a DM's members are fixed"))
        return remove_member_row[RT, Self.DB, Self.P](
            self._db, self._probe, reactor, channel_id, user_id, now_ms
        )

    # ---- the timeline ----------------------------------------------------------

    def head_seq[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], channel_id: String) raises -> Int64:
        return head_seq_of[RT, Self.DB](self._db, reactor, channel_id)

    def send_message[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        sender_user_id: String,
        body: String,
        thread_root_seq: Int64,
        client_msg_id: String,
        mention_user_ids: List[String],
        mentions_channel: Bool,
        file_ids: List[String],
        now_ms: Int64,
    ) raises -> ChatEvent:
        """Append a MESSAGE event, or return the sender's earlier one with
        the same non-empty `client_msg_id` (see timeline.mojo)."""
        _ = writable_channel[RT, Self.DB](self._db, reactor, channel_id)
        self._member_check[RT](reactor, channel_id, sender_user_id)
        for i in range(len(mention_user_ids)):
            require_id(mention_user_ids[i], "user id")
        if thread_root_seq != 0:
            thread_root_check[RT, Self.DB](
                self._db, reactor, channel_id, thread_root_seq
            )
        attachable_check[RT, Self.DB](self._db, reactor, channel_id, file_ids)
        var msg = ChatEvent(
            channel_id,
            Int64(0),
            EVENT_MESSAGE,
            sender_user_id,
            body,
            thread_root_seq,
            Int64(0),
            client_msg_id,
            mention_user_ids.copy(),
            mentions_channel,
            file_ids.copy(),
            now_ms,
            False,
            False,
        )
        return send_checked[RT, Self.DB, Self.P](
            self._db, self._probe, reactor, msg^
        )

    def edit_message[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        seq: Int64,
        editor_user_id: String,
        body: String,
        now_ms: Int64,
    ) raises -> ChatEvent:
        """Edit the editor's own message; returns the EDIT event."""
        _ = writable_channel[RT, Self.DB](self._db, reactor, channel_id)
        self._member_check[RT](reactor, channel_id, editor_user_id)
        return edit_checked[RT, Self.DB, Self.P](
            self._db, self._probe, reactor, channel_id, seq, editor_user_id, body, now_ms
        )

    def delete_message[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        seq: Int64,
        by_user_id: String,
        any_sender: Bool,
        now_ms: Int64,
    ) raises -> ChatEvent:
        """Delete a message (the caller's own, or any when `any_sender`):
        its body and its edits' bodies are overwritten. Returns the DELETE
        event."""
        _ = writable_channel[RT, Self.DB](self._db, reactor, channel_id)
        if not any_sender:
            self._member_check[RT](reactor, channel_id, by_user_id)
        return delete_checked[RT, Self.DB, Self.P](
            self._db,
            self._probe,
            reactor,
            channel_id,
            seq,
            by_user_id,
            any_sender,
            now_ms,
        )

    def event[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], channel_id: String, seq: Int64
    ) raises -> Optional[ChatEvent]:
        """The event at `seq`; for a MESSAGE, its current body (empty once
        deleted or erased)."""
        return event_at[RT, Self.DB](self._db, reactor, channel_id, seq)

    def events_after[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        since_seq: Int64,
        max_events: Int,
    ) raises -> EventPage:
        return page_after[RT, Self.DB](
            self._db, reactor, channel_id, since_seq, max_events
        )

    def events_before[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        before_seq: Int64,
        max_events: Int,
    ) raises -> EventPage:
        return page_before[RT, Self.DB](
            self._db, reactor, channel_id, before_seq, max_events
        )

    def thread[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        root_seq: Int64,
        since_seq: Int64,
        max_events: Int,
    ) raises -> EventPage:
        return thread_page[RT, Self.DB](
            self._db, reactor, channel_id, root_seq, since_seq, max_events
        )

    def mentions[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        user_id: String,
        before_ms: Int64,
        max_mentions: Int,
    ) raises -> MentionPage:
        return mentions_page[RT, Self.DB](
            self._db, reactor, user_id, before_ms, max_mentions
        )

    def mark_read[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        channel_id: String,
        user_id: String,
        seq: Int64,
    ) raises -> Int64:
        """Move the user's read cursor forward to `seq` (never backward)."""
        return mark_read_row[RT, Self.DB](self._db, reactor, channel_id, user_id, seq)

    def read_state[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], channel_id: String, user_id: String
    ) raises -> ReadState:
        return read_state_of[RT, Self.DB](self._db, reactor, channel_id, user_id)

    # ---- files -----------------------------------------------------------------

    def create_file[
        RT: Runtime
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        file_id: String,
        channel_id: String,
        name: String,
        content_type: String,
        declared_size: Int64,
        uploader_user_id: String,
        now_ms: Int64,
    ) raises -> ChatFile:
        """A PENDING file of the channel."""
        return create_file_row[RT, Self.DB](
            self._db,
            reactor,
            file_id,
            channel_id,
            name,
            content_type,
            declared_size,
            uploader_user_id,
            now_ms,
        )

    def complete_file[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], file_id: String, size_bytes: Int64
    ) raises -> ChatFile:
        return complete_file_row[RT, Self.DB](self._db, reactor, file_id, size_bytes)

    def file[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], file_id: String) raises -> Optional[
        ChatFile
    ]:
        return file_by_id[RT, Self.DB](self._db, reactor, file_id)

    def delete_file[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], file_id: String) raises -> Bool:
        return (
            delete_all[RT, Self.DB](
                self._db, reactor, T_FILES, all_of(eq("file_id", txt(file_id)))
            )
            > 0
        )

    # ---- erasure ---------------------------------------------------------------

    def erase_user[
        RT: Runtime
    ](mut self, mut reactor: Reactor[RT.Sink], user_id: String) raises -> EraseCounts:
        """Erase one user (see erasure.mojo). On SQLite, follow it with
        `finish_sql_erasure` on `db()`."""
        return erase_user_rows[RT, Self.DB](self._db, reactor, user_id)

    def erase_subject[
        RT: Runtime
    ](
        mut self, mut reactor: Reactor[RT.Sink], iss: String, sub: String
    ) raises -> EraseCounts:
        """Erase the user of (iss, sub), if any, and the subject row. The
        user is the subject row's; without a subject row, every user row
        that holds (iss, sub)."""
        var targets = List[String]()
        var id = user_id_for_subject[RT, Self.DB](self._db, reactor, iss, sub)
        if id:
            targets.append(id.take())
        else:
            targets = user_ids_with_subject[RT, Self.DB](
                self._db, reactor, iss, sub
            )
        var counts = EraseCounts(0, 0, List[String]())
        for i in range(len(targets)):
            var one = erase_user_rows[RT, Self.DB](
                self._db, reactor, targets[i]
            )
            counts.rows_erased += one.rows_erased
            counts.bodies_redacted += one.bodies_redacted
            for j in range(len(one.file_ids)):
                counts.file_ids.append(one.file_ids[j])
        counts.rows_erased += delete_all[RT, Self.DB](
            self._db,
            reactor,
            T_SUBJECTS,
            all_of(eq("subject_key", txt(subject_key(iss, sub)))),
        )
        return counts^
