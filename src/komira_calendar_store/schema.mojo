# =============================================================================
# komira_calendar_store/schema.mojo -- the store's tables as every backend
#   sees them, and the document-store keys and indexes.
# =============================================================================
#
# The store writes only through the backend-neutral `komira_db.Database`
# operations, so the same tables are SQL tables (migrations.mojo creates them)
# and document collections (nothing to create; one collection per table,
# every document keyed on its `id`).
#
#   calendar_calendars  one row per calendar
#     id, owner (the owner's subject), name, color, time_zone, version (the
#     calendar's ETag), created_ms, updated_ms; modseq (the change number
#     the change feed is read up to); the write in progress: pending_seq
#     (0: none), pending_kind, pending_id, pending_body, pending_deleted,
#     pending_first, pending_last (store.mojo, THE WRITE PROTOCOL)
#   calendar_events     one row per event, kept as a tombstone on delete
#     id, owner, calendar_id, uid, deleted (0 or 1), version (the event's
#     ETag), modseq (the change number of its last write), first_start_utc,
#     last_end_utc (span.mojo), body (the event's proto3 JSON; empty on a
#     tombstone)
#   calendar_overrides  one row per edited occurrence, kept as a tombstone
#     id (`<event id>@<original start>`), owner, calendar_id, event_id,
#     original_start, deleted, version, modseq, body (the override's proto3
#     JSON; empty on a tombstone)
#
# No table has a column scoping a row to a customer: one deployment holds one
# dataset. Every table has an `owner` column, and erasure deletes by it.
# =============================================================================

comptime T_CALENDARS: StaticString = "calendar_calendars"
comptime T_EVENTS: StaticString = "calendar_events"
comptime T_OVERRIDES: StaticString = "calendar_overrides"

# Every table the store writes, one per line, calendars first (erasure deletes
# in this order). Each has an `owner` column.
comptime CALENDAR_TABLES: StaticString = """calendar_calendars
calendar_events
calendar_overrides
"""

# The column every table carries: the subject owning the row's calendar.
comptime OWNER_COL: StaticString = "owner"

# The composite indexes the store's queries need on a document store, in the
# `collection|col:MODE|...` form of komira_gcp_firestore_db's
# `DeclaredIndexSet.parse_table` (A ascending). Each comment names the query.
# Every other query is equalities only.
comptime CALENDAR_DOCUMENT_INDEXES: StaticString = """# events_in_window: calendar_id == ?, deleted == ?, first_start_utc < ?, last_end_utc >= ?
calendar_events|calendar_id:A|deleted:A|first_start_utc:A|last_end_utc:A
# changes: calendar_id == ?, modseq >= ?, modseq <= ?, ORDER BY modseq
calendar_events|calendar_id:A|modseq:A
"""


def strs(*items: StaticString) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(String(s))
    return out^


def calendar_tables() -> List[String]:
    """CALENDAR_TABLES as a list, in order."""
    var out = List[String]()
    for line in String(CALENDAR_TABLES).split(String("\n")):
        var row = String(line)
        if row.byte_length() > 0:
            out.append(row^)
    return out^


def calendar_cols() -> List[String]:
    return strs(
        "id",
        "owner",
        "name",
        "color",
        "time_zone",
        "version",
        "created_ms",
        "updated_ms",
        "modseq",
        "pending_seq",
        "pending_kind",
        "pending_id",
        "pending_body",
        "pending_deleted",
        "pending_first",
        "pending_last",
    )


def event_cols() -> List[String]:
    return strs(
        "id",
        "owner",
        "calendar_id",
        "uid",
        "deleted",
        "version",
        "modseq",
        "first_start_utc",
        "last_end_utc",
        "body",
    )


def override_cols() -> List[String]:
    return strs(
        "id",
        "owner",
        "calendar_id",
        "event_id",
        "original_start",
        "deleted",
        "version",
        "modseq",
        "body",
    )


def override_key(event_id: String, original_start: String) -> String:
    """The id of an override row: `<event id>@<original start>`."""
    return event_id + String("@") + original_start
