# =============================================================================
# komira_calendar_store/migrations.mojo -- the SQL migration chain.
# =============================================================================
#
# The tables of schema.mojo for a SQL backend (SQLite or Postgres), one
# statement per step (SQLite prepares only the first statement of a string),
# numbered from 1. Every integer and flag column is BIGINT; the DDL is TEXT,
# BIGINT, PRIMARY KEY and plain indexes only. A document store needs none of
# this: it is bound to `SqlDatabase`, which a document store does not
# implement, and only a SQL backend's caller runs it.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db import Migration, MigrationRunner, SqlDatabase

# The ledger table of the calendar migration chain.
comptime CALENDAR_MIGRATION_LEDGER: StaticString = "_komira_calendar_migrations"


def _step(mut out: List[Migration], var sql: String, name: StaticString):
    out.append(Migration(len(out) + 1, sql^, String(name)))


def calendar_migrations() -> List[Migration]:
    """The calendar schema for a SQL backend, one statement per step."""
    var out = List[Migration]()
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS calendar_calendars (id TEXT PRIMARY KEY,"
            " owner TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL,"
            " time_zone TEXT NOT NULL, version BIGINT NOT NULL,"
            " created_ms BIGINT NOT NULL, updated_ms BIGINT NOT NULL,"
            " modseq BIGINT NOT NULL, pending_seq BIGINT NOT NULL,"
            " pending_kind BIGINT NOT NULL, pending_id TEXT NOT NULL,"
            " pending_body TEXT NOT NULL, pending_deleted BIGINT NOT NULL,"
            " pending_first BIGINT NOT NULL, pending_last BIGINT NOT NULL)"
        ),
        "calendar_v1_calendars",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS calendar_events (id TEXT PRIMARY KEY,"
            " owner TEXT NOT NULL, calendar_id TEXT NOT NULL, uid TEXT NOT NULL,"
            " deleted BIGINT NOT NULL, version BIGINT NOT NULL,"
            " modseq BIGINT NOT NULL, first_start_utc BIGINT NOT NULL,"
            " last_end_utc BIGINT NOT NULL, body TEXT NOT NULL)"
        ),
        "calendar_v1_events",
    )
    _step(
        out,
        String(
            "CREATE TABLE IF NOT EXISTS calendar_overrides (id TEXT PRIMARY KEY,"
            " owner TEXT NOT NULL, calendar_id TEXT NOT NULL,"
            " event_id TEXT NOT NULL, original_start TEXT NOT NULL,"
            " deleted BIGINT NOT NULL, version BIGINT NOT NULL,"
            " modseq BIGINT NOT NULL, body TEXT NOT NULL)"
        ),
        "calendar_v1_overrides",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_calendars_owner ON calendar_calendars (owner)"),
        "calendar_v1_calendars_owner_idx",
    )
    _step(
        out,
        String(
            "CREATE INDEX IF NOT EXISTS calendar_events_window ON calendar_events"
            " (calendar_id, deleted, first_start_utc, last_end_utc)"
        ),
        "calendar_v1_events_window_idx",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_events_modseq ON calendar_events (calendar_id, modseq)"),
        "calendar_v1_events_modseq_idx",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_events_uid ON calendar_events (calendar_id, uid)"),
        "calendar_v1_events_uid_idx",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_events_owner ON calendar_events (owner)"),
        "calendar_v1_events_owner_idx",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_overrides_event ON calendar_overrides (event_id)"),
        "calendar_v1_overrides_event_idx",
    )
    _step(
        out,
        String("CREATE INDEX IF NOT EXISTS calendar_overrides_owner ON calendar_overrides (owner)"),
        "calendar_v1_overrides_owner_idx",
    )
    return out^


def migrate[RT: Runtime, DB: SqlDatabase](var db: DB, mut reactor: Reactor[RT.Sink]) raises -> DB:
    """Apply `calendar_migrations()` to `db`, recording them in
    CALENDAR_MIGRATION_LEDGER, and hand `db` back. A re-run applies
    nothing."""
    var runner = MigrationRunner[DB](db^, String(CALENDAR_MIGRATION_LEDGER))
    _ = runner.run[RT](reactor, calendar_migrations())
    return runner^.into_db()
