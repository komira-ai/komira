# =============================================================================
# komira_chat_store/records.mojo -- the values the store returns, and the
#   numbers of the kinds and states it stores.
# =============================================================================
#
# The numbers are those of `komira.chat.v1`'s enums (komira_chat_proto), so a
# service copies them onto the wire unchanged. Field names follow the same
# messages. Each record is a plain value: Strings, integers and Lists of
# Strings.
# =============================================================================

from komira_db import DbRow, DbRows

from .keys import split_ids

# ChannelKind
comptime CHANNEL_PUBLIC: Int = 1
comptime CHANNEL_PRIVATE: Int = 2
comptime CHANNEL_DM: Int = 3

# EventKind
comptime EVENT_MESSAGE: Int = 1
comptime EVENT_EDIT: Int = 2
comptime EVENT_DELETE: Int = 3
comptime EVENT_JOIN: Int = 4
comptime EVENT_LEAVE: Int = 5

# FileState
comptime FILE_PENDING: Int = 1
comptime FILE_COMPLETE: Int = 2


@fieldwise_init
struct ChatUser(Copyable, Movable):
    var user_id: String
    var iss: String
    var sub: String
    var display_name: String
    var email: String
    var created_at_ms: Int64


@fieldwise_init
struct ChatChannel(Copyable, Movable):
    var channel_id: String
    var kind: Int
    var name: String
    var topic: String
    var archived: Bool
    var created_at_ms: Int64
    var created_by_user_id: String
    # A DM's users, sorted; empty for any other kind.
    var dm_user_ids: List[String]


@fieldwise_init
struct ChatMember(Copyable, Movable):
    var channel_id: String
    var user_id: String
    var joined_at_ms: Int64


@fieldwise_init
struct ChatEvent(Copyable, Movable):
    """One event of a channel's timeline. A MESSAGE event carries the
    message's current state: the latest edit's body and `edited`, or an empty
    body and `deleted`."""

    var channel_id: String
    var seq: Int64
    var kind: Int
    var sender_user_id: String
    var body: String
    var thread_root_seq: Int64
    var target_seq: Int64
    var client_msg_id: String
    var mention_user_ids: List[String]
    var mentions_channel: Bool
    var file_ids: List[String]
    var created_at_ms: Int64
    var edited: Bool
    var deleted: Bool


@fieldwise_init
struct EventPage(Copyable, Movable):
    """Events in ascending seq order, the channel's head when the page was
    read, and whether more events lie in the paging direction."""

    var events: List[ChatEvent]
    var head_seq: Int64
    var has_more: Bool


@fieldwise_init
struct ChatFile(Copyable, Movable):
    var file_id: String
    var channel_id: String
    var name: String
    var content_type: String
    var size_bytes: Int64
    var state: Int
    var uploader_user_id: String
    var created_at_ms: Int64


@fieldwise_init
struct ReadState(Copyable, Movable):
    """A user's read cursor in one channel and what lies after it: MESSAGE
    events by other users that are not deleted, and of those the ones that
    mention the user or the channel."""

    var channel_id: String
    var read_seq: Int64
    var unread_count: Int
    var mention_count: Int


@fieldwise_init
struct MentionRef(Copyable, Movable):
    var channel_id: String
    var seq: Int64
    var created_at_ms: Int64


@fieldwise_init
struct MentionPage(Copyable, Movable):
    """Mentions newest first, then by channel and seq. `next_before_ms` is 0
    on the last page, otherwise the `before_ms` of the next page: following
    it returns every mention once (a page never splits a millisecond)."""

    var mentions: List[MentionRef]
    var next_before_ms: Int64


@fieldwise_init
struct IdPage(Copyable, Movable):
    """Ids in ascending order. `next_from` is empty on the last page,
    otherwise the first id of the next page."""

    var ids: List[String]
    var next_from: String


@fieldwise_init
struct EraseCounts(Copyable, Movable):
    """What `erase_user` removed. `rows_erased` counts deleted rows;
    `bodies_redacted` counts message and edit bodies overwritten in place;
    `file_ids` are the user's uploads whose rows were deleted, so the caller
    deletes their objects."""

    var rows_erased: Int
    var bodies_redacted: Int
    var file_ids: List[String]


# ---- row decoding ----------------------------------------------------------


def _col(rows: DbRows, name: StaticString) raises -> Int:
    var i = rows.column_index(String(name))
    if i < 0:
        raise Error(String("komira_chat_store: result has no column ") + name)
    return i


def user_from(rows: DbRows, i: Int) raises -> ChatUser:
    ref r = rows.row(i)
    return ChatUser(
        r.get_text(_col(rows, "user_id")),
        r.get_text(_col(rows, "iss")),
        r.get_text(_col(rows, "sub")),
        r.get_text(_col(rows, "display_name")),
        r.get_text(_col(rows, "email")),
        r.get_int8(_col(rows, "created_at_ms")),
    )


def channel_from(rows: DbRows, i: Int) raises -> ChatChannel:
    ref r = rows.row(i)
    return ChatChannel(
        r.get_text(_col(rows, "channel_id")),
        Int(r.get_int8(_col(rows, "kind"))),
        r.get_text(_col(rows, "name")),
        r.get_text(_col(rows, "topic")),
        r.get_int8(_col(rows, "archived")) != 0,
        r.get_int8(_col(rows, "created_at_ms")),
        r.get_text(_col(rows, "created_by")),
        split_ids(r.get_text(_col(rows, "dm_user_ids"))),
    )


def member_from(rows: DbRows, i: Int) raises -> ChatMember:
    ref r = rows.row(i)
    return ChatMember(
        r.get_text(_col(rows, "channel_id")),
        r.get_text(_col(rows, "user_id")),
        r.get_int8(_col(rows, "joined_at_ms")),
    )


def event_from(rows: DbRows, i: Int) raises -> ChatEvent:
    ref r = rows.row(i)
    return ChatEvent(
        r.get_text(_col(rows, "channel_id")),
        r.get_int8(_col(rows, "seq")),
        Int(r.get_int8(_col(rows, "kind"))),
        r.get_text(_col(rows, "sender_user_id")),
        r.get_text(_col(rows, "body")),
        r.get_int8(_col(rows, "thread_root_seq")),
        r.get_int8(_col(rows, "target_seq")),
        r.get_text(_col(rows, "client_msg_id")),
        split_ids(r.get_text(_col(rows, "mention_user_ids"))),
        r.get_int8(_col(rows, "mentions_channel")) != 0,
        split_ids(r.get_text(_col(rows, "file_ids"))),
        r.get_int8(_col(rows, "created_at_ms")),
        r.get_int8(_col(rows, "edited")) != 0,
        r.get_int8(_col(rows, "deleted")) != 0,
    )


def file_from(rows: DbRows, i: Int) raises -> ChatFile:
    ref r = rows.row(i)
    return ChatFile(
        r.get_text(_col(rows, "file_id")),
        r.get_text(_col(rows, "channel_id")),
        r.get_text(_col(rows, "name")),
        r.get_text(_col(rows, "content_type")),
        r.get_int8(_col(rows, "size_bytes")),
        Int(r.get_int8(_col(rows, "state"))),
        r.get_text(_col(rows, "uploader_user_id")),
        r.get_int8(_col(rows, "created_at_ms")),
    )
