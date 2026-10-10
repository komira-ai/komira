# `komira_calendar_store`

## Responsibility

The store of a simple calendar service: calendars, events with their
structured recurrence rules, one-occurrence edits, the change feed and
erasure, on any `komira_db` `Database`. The messages are
[`komira_calendar_proto`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_proto/README.md)'s;
[`komira_calendar`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/README.md)
checks them and expands their rules; time zones come from a
[`komira_calendar_ics`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_ics/README.md)
`ZoneSource`.

- `CalendarStore[DB]` uses only the backend-neutral `Database` operations, so
  the same store runs on SQLite, Postgres and Firestore. It checks what it
  writes, including that a named time zone exists; it does not decide who may
  call it (the caller asks its authorization port first).
- Every event and override write is a compare-and-set on the version the
  client names (If-Match): a stale one is refused with
  `calendar: version conflict`. An event's `uid` is unique among the live
  events of its calendar.
- An event row stores the UTC range its occurrences can fall in
  (`utc_span`): `first_start_utc` and `last_end_utc`, with `Int64.MAX` for a
  series that never ends. A time window is then one indexed conjunction,
  `first_start_utc < to AND last_end_utc > from`; the caller expands the
  events it returns. An all-day event is widened by 26 hours each way, so it
  is found from any zone; an edit that moves an occurrence widens its event.
- The change feed: every write to an event or its edits gets the calendar's
  next change number, a deleted event stays as a tombstone, and
  `changes(since)` lists the events written after a cursor, each once.
- A document store has no transaction over two documents, so a write is held
  on its calendar's row while it is applied, and the calendar's change number
  moves only after the write's rows have: a feed reader never passes a write
  that has not landed. A second write to the same calendar in that time is
  refused with `calendar: another write to this calendar came first; retry`.
  A writer that stops after its claim leaves the write held, and the next
  write to the calendar finishes it. See `store.mojo`.
- `erase_owner` deletes every row of every table in `CALENDAR_TABLES` whose
  `owner` is the subject; running it again deletes nothing.
- `calendar_migrations()` is the SQL schema; `CALENDAR_DOCUMENT_INDEXES` the
  composite indexes a document store needs.

Reminders (their fire times and the claim loop) are not here.

The store's contract is checked against SQLite and Firestore (over
`MockFirestore`) by
[`komira_calendar_store_conformance`](https://github.com/komira-ai/komira/blob/main/src/tests/conformance/komira_calendar_store_conformance/BUCK).
Postgres is not run.

## API

| name | file | what it is |
|---|---|---|
| `CalendarStore`, `EventChange`, `EventChanges`, `EraseCounts` | [store.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_store/store.mojo) | the store over a `Database` |
| `utc_span`, `UtcSpan`, `ALL_DAY_SLACK_SECONDS`, `NO_START`, `NO_END` | [span.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_store/span.mojo) | the stored UTC range of an event |
| `CALENDAR_TABLES`, `calendar_tables`, `CALENDAR_DOCUMENT_INDEXES`, `OWNER_COL`, `T_CALENDARS`, `T_EVENTS`, `T_OVERRIDES`, `override_key` | [schema.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_store/schema.mojo) | the tables |
| `calendar_migrations`, `migrate`, `CALENDAR_MIGRATION_LEDGER` | [migrations.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_store/migrations.mojo) | the SQL schema |
| `ERR_NOT_FOUND`, `ERR_VERSION_CONFLICT`, `ERR_UID_TAKEN`, `ERR_BUSY`, `ERR_INVALID`, `TIME_ZONE_UNKNOWN`, `NO_SUCH_OCCURRENCE`, `UID_CHANGED`, `WINDOW_EMPTY` | [errors.mojo](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_store/errors.mojo) | the refusal texts and codes |

## Example

Every example below runs as a test when the package is built.

An all-day event has no zone, so its stored range is widened to cover every
zone:

```mojo
from komira_calendar_store import ALL_DAY_SLACK_SECONDS, utc_span
from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_proto_codec import decode_json
from std.testing import assert_equal

var day = decode_json[Event]('{"title":"Holiday","showWithoutTime":true,"startDate":"2026-12-25","days":1}')
var span = utc_span(day, List[OccurrenceOverride](), None)
# 2026-12-25T00:00:00 is 1798156800 seconds after the epoch.
assert_equal(span.first_start_utc, 1798156800 - ALL_DAY_SLACK_SECONDS)
assert_equal(span.last_end_utc, 1798156800 + 86400 + ALL_DAY_SLACK_SECONDS)
```
