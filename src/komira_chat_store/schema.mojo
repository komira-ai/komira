# =============================================================================
# komira_chat_store/schema.mojo -- the chat tables: names, columns, the SQL
#   migration chain, and the Firestore keys and composite indexes.
# =============================================================================
#
# One deployment holds one chat space, so no table has a tenancy column.
#
#   chat_subjects      subject_key (PK) -> user_id. The key of a token's
#                      (iss, sub) pair; `ensure_user` claims it first.
#   chat_users         user_id (PK), iss, sub, display_name, email,
#                      created_at_ms.
#   chat_channels      channel_id (PK), kind, name, topic, archived,
#                      created_at_ms, created_by, dm_user_ids. There is no
#                      sequence counter: a channel's head is the largest seq
#                      in chat_events.
#   chat_members       (channel_id, user_id) unique, joined_at_ms.
#   chat_events        (channel_id, seq) unique: the timeline. One row per
#                      event; a MESSAGE row carries the message's current
#                      state (body, edited, deleted, last_edit_seq).
#   chat_mentions      (channel_id, seq, user_id) unique, created_at_ms: the
#                      index behind a user's mentions view.
#   chat_read_cursors  (channel_id, user_id) unique, read_seq.
#   chat_files         file_id (PK), channel_id, name, content_type,
#                      size_bytes, state, uploader_user_id, created_at_ms.
#
# Every integer and flag column is BIGINT (a flag holds 0 or 1). The DDL is
# portable between SQLite and Postgres: TEXT, BIGINT, PRIMARY KEY, UNIQUE and
# plain indexes only. One statement per migration (SQLite prepares only the
# first statement of a string).
#
# The (channel_id, seq) UNIQUE constraint is what `send` allocates against:
# `INSERT ... ON CONFLICT (channel_id, seq) DO NOTHING` needs it to exist.
# =============================================================================

from komira_db import Migration

comptime T_SUBJECTS: StaticString = "chat_subjects"
comptime T_USERS: StaticString = "chat_users"
comptime T_CHANNELS: StaticString = "chat_channels"
comptime T_MEMBERS: StaticString = "chat_members"
comptime T_EVENTS: StaticString = "chat_events"
comptime T_MENTIONS: StaticString = "chat_mentions"
comptime T_CURSORS: StaticString = "chat_read_cursors"
comptime T_FILES: StaticString = "chat_files"

# The ledger table name of the chat migration chain.
comptime CHAT_MIGRATION_LEDGER: StaticString = "_komira_chat_migrations"


def _cols(*names: StaticString) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(String(n))
    return out^


def subject_cols() -> List[String]:
    return _cols("subject_key", "user_id")


def user_cols() -> List[String]:
    return _cols("user_id", "iss", "sub", "display_name", "email", "created_at_ms")


def channel_cols() -> List[String]:
    return _cols(
        "channel_id",
        "kind",
        "name",
        "topic",
        "archived",
        "created_at_ms",
        "created_by",
        "dm_user_ids",
    )


def member_cols() -> List[String]:
    return _cols("channel_id", "user_id", "joined_at_ms")


def event_cols() -> List[String]:
    return _cols(
        "channel_id",
        "seq",
        "kind",
        "sender_user_id",
        "body",
        "thread_root_seq",
        "target_seq",
        "client_msg_id",
        "mention_user_ids",
        "mentions_channel",
        "file_ids",
        "created_at_ms",
        "edited",
        "deleted",
        "last_edit_seq",
    )


def mention_cols() -> List[String]:
    return _cols("channel_id", "seq", "user_id", "created_at_ms")


def cursor_cols() -> List[String]:
    return _cols("channel_id", "user_id", "read_seq")


def file_cols() -> List[String]:
    return _cols(
        "file_id",
        "channel_id",
        "name",
        "content_type",
        "size_bytes",
        "state",
        "uploader_user_id",
        "created_at_ms",
    )


def _step(mut out: List[Migration], var sql: String, name: StaticString):
    out.append(Migration(len(out) + 1, sql^, String(name)))


def chat_migrations() -> List[Migration]:
    """The chat schema for a SQL backend (SQLite or Postgres), one statement
    per step, numbered from 1. Run it with `MigrationRunner(db,
    CHAT_MIGRATION_LEDGER)`; a re-run applies nothing."""
    var out = List[Migration]()
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_subjects (subject_key TEXT PRIMARY"
            " KEY, user_id TEXT NOT NULL)"
        ),
        "chat_v1_subjects",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_users (user_id TEXT PRIMARY KEY,"
            " iss TEXT NOT NULL, sub TEXT NOT NULL, display_name TEXT NOT NULL,"
            " email TEXT NOT NULL, created_at_ms BIGINT NOT NULL)"
        ),
        "chat_v1_users",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_channels (channel_id TEXT PRIMARY"
            " KEY, kind BIGINT NOT NULL, name TEXT NOT NULL, topic TEXT NOT"
            " NULL, archived BIGINT NOT NULL, created_at_ms BIGINT NOT NULL,"
            " created_by TEXT NOT NULL, dm_user_ids TEXT NOT NULL)"
        ),
        "chat_v1_channels",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_members (channel_id TEXT NOT NULL,"
            " user_id TEXT NOT NULL, joined_at_ms BIGINT NOT NULL,"
            " UNIQUE (channel_id, user_id))"
        ),
        "chat_v1_members",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_events (channel_id TEXT NOT NULL,"
            " seq BIGINT NOT NULL, kind BIGINT NOT NULL, sender_user_id TEXT"
            " NOT NULL, body TEXT NOT NULL, thread_root_seq BIGINT NOT NULL,"
            " target_seq BIGINT NOT NULL, client_msg_id TEXT NOT NULL,"
            " mention_user_ids TEXT NOT NULL, mentions_channel BIGINT NOT NULL,"
            " file_ids TEXT NOT NULL, created_at_ms BIGINT NOT NULL, edited"
            " BIGINT NOT NULL, deleted BIGINT NOT NULL, last_edit_seq BIGINT"
            " NOT NULL, UNIQUE (channel_id, seq))"
        ),
        "chat_v1_events",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_mentions (channel_id TEXT NOT"
            " NULL, seq BIGINT NOT NULL, user_id TEXT NOT NULL, created_at_ms"
            " BIGINT NOT NULL, UNIQUE (channel_id, seq, user_id))"
        ),
        "chat_v1_mentions",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_read_cursors (channel_id TEXT NOT"
            " NULL, user_id TEXT NOT NULL, read_seq BIGINT NOT NULL,"
            " UNIQUE (channel_id, user_id))"
        ),
        "chat_v1_read_cursors",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS chat_files (file_id TEXT PRIMARY KEY,"
            " channel_id TEXT NOT NULL, name TEXT NOT NULL, content_type TEXT"
            " NOT NULL, size_bytes BIGINT NOT NULL, state BIGINT NOT NULL,"
            " uploader_user_id TEXT NOT NULL, created_at_ms BIGINT NOT NULL)"
        ),
        "chat_v1_files",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_events_sender ON chat_events"
            " (sender_user_id)"
        ),
        "chat_v1_events_sender_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_events_thread ON chat_events"
            " (channel_id, thread_root_seq, seq)"
        ),
        "chat_v1_events_thread_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_events_target ON chat_events"
            " (channel_id, target_seq)"
        ),
        "chat_v1_events_target_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_members_user ON chat_members"
            " (user_id, channel_id)"
        ),
        "chat_v1_members_user_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_mentions_user ON chat_mentions"
            " (user_id, created_at_ms)"
        ),
        "chat_v1_mentions_user_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_cursors_user ON chat_read_cursors"
            " (user_id)"
        ),
        "chat_v1_cursors_user_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_files_uploader ON chat_files"
            " (uploader_user_id)"
        ),
        "chat_v1_files_uploader_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS chat_channels_kind ON chat_channels"
            " (kind, archived, channel_id)"
        ),
        "chat_v1_channels_kind_idx",
    )
    return out^


# The key column of each table whose documents a document store names by a
# column other than `id`, one `table|column` per line. The tables keyed on a
# tuple (members, events, mentions, cursors) are written only through
# `create_if_absent_composite`, which names a document after its tuple.
comptime CHAT_DOCUMENT_KEYS: StaticString = """chat_subjects|subject_key
chat_users|user_id
chat_channels|channel_id
chat_files|file_id
"""

# The composite indexes the store's queries need on a document store, in the
# `collection|col:MODE|...` form of komira_gcp_firestore_db's
# `DeclaredIndexSet.parse_table` (A ascending, D descending). Each line names
# the store method that issues the query.
comptime CHAT_DOCUMENT_INDEXES: StaticString = """# head_seq, page_before: channel_id == ?, seq < ?, ORDER BY seq DESC
chat_events|channel_id:A|seq:D
# page_after: channel_id == ?, seq >= ?, ORDER BY seq ASC
chat_events|channel_id:A|seq:A
# thread: channel_id == ?, thread_root_seq == ?, seq >= ?, ORDER BY seq ASC
chat_events|channel_id:A|thread_root_seq:A|seq:A
# members_page: channel_id == ?, user_id >= ?, ORDER BY user_id
chat_members|channel_id:A|user_id:A
# channels_of: user_id == ?, channel_id >= ?, ORDER BY channel_id
chat_members|user_id:A|channel_id:A
# mentions_of: user_id == ?, created_at_ms < ?, ORDER BY created_at_ms DESC
chat_mentions|user_id:A|created_at_ms:D
# browse_channels: kind == ?, archived == ?, channel_id >= ?, ORDER BY channel_id
chat_channels|kind:A|archived:A|channel_id:A
# browse_channels with archived ones: kind == ?, channel_id >= ?, ORDER BY channel_id
chat_channels|kind:A|channel_id:A
"""
