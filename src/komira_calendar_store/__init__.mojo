"""The store of a simple calendar service: calendars, events with their
structured recurrence rules, one-occurrence edits, the change feed and
erasure, on any komira_db `Database` (SQLite, Postgres, Firestore). The
messages are `komira_calendar_proto`'s; `komira_calendar` checks them and
expands their rules; time zones come from a `komira_calendar_ics.ZoneSource`.

  store.mojo       CalendarStore[DB]; EventChange, EventChanges, EraseCounts
  events.mojo      the event and override writes and reads
  protocol.mojo    the write protocol: a write held on its calendar's row
  span.mojo        utc_span, the stored UTC range of an event's occurrences
  schema.mojo      the tables, CALENDAR_TABLES, the document-store indexes
  migrations.mojo  the SQL migration chain (SQL backends only)
  rows.mojo        row forms and small builders (not exported)
  errors.mojo      the refusal texts
"""

from .errors import (
    ERR_BUSY,
    ERR_INVALID,
    ERR_NOT_FOUND,
    ERR_UID_TAKEN,
    ERR_VERSION_CONFLICT,
    NO_SUCH_OCCURRENCE,
    TIME_ZONE_UNKNOWN,
    UID_CHANGED,
    WINDOW_EMPTY,
)
from .migrations import CALENDAR_MIGRATION_LEDGER, calendar_migrations, migrate
from .schema import (
    CALENDAR_DOCUMENT_INDEXES,
    CALENDAR_TABLES,
    OWNER_COL,
    T_CALENDARS,
    T_EVENTS,
    T_OVERRIDES,
    calendar_tables,
    override_key,
)
from .span import ALL_DAY_SLACK_SECONDS, NO_END, NO_START, UtcSpan, utc_span
from .store import CalendarStore, EraseCounts, EventChange, EventChanges
