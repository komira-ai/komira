# `komira_calendar_proto`

## Responsibility

The resources of a simple calendar service's JSON API, as protobuf messages
(`komira.calendar.v1`) and the Mojo structs generated from them. The API is
the proto3 JSON mapping of these messages.

- `Calendar`: a named calendar with a color and a default time zone.
- `Event`: all-day (`showWithoutTime`, `startDate`, `days`) or timed
  (`start` as a local date-time, `timeZone`, `durationSeconds`), with a
  status, an optional `Recurrence`, the removed occurrences (`exdates`) and
  up to five `Reminder`s.
- `Recurrence`: a structured rule, not RRULE text. `freq` is DAILY, WEEKLY,
  MONTHLY or YEARLY with an `interval`; WEEKLY may name `weekdays`; MONTHLY
  names a `monthDay`, or an `ordinal` (1 to 4, or -1 for the last) with an
  `ordinalWeekday`; the series ends by `count`, by `until`, or never.
- `OccurrenceOverride`: one occurrence of a recurring event, keyed by its
  original local start, cancelled or with some fields replaced.
- `ErrorResponse` and `ApiError`: the body of every refusal,
  `{"error":{"code":...,"message":...,"field":...}}`.
- Enums `EventStatus`, `Frequency` and `Weekday` (ISO numbering, Monday 1).

What a client may write is checked by
[`komira_calendar`](https://github.com/komira-ai/komira/blob/main/src/komira_calendar/README.md). The field numbers and
JSON names are the contract: `tests/test_calendar_field_numbers.mojo` pins
every number as wire bytes and every JSON key in a literal document.

## API

| name | file | what it is |
|---|---|---|
| `Calendar`, `Event`, `Recurrence`, `Reminder`, `OccurrenceOverride` | [calendar.proto](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_proto/komira/calendar/v1/calendar.proto) | the resources |
| `ApiError`, `ErrorResponse` | [calendar.proto](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_proto/komira/calendar/v1/calendar.proto) | the error envelope |
| `EventStatus`, `Frequency`, `Weekday` | [calendar.proto](https://github.com/komira-ai/komira/blob/main/src/komira_calendar_proto/komira/calendar/v1/calendar.proto) | the enums |

The Mojo module is `komira_calendar_proto.calendar`. Each message is a struct
whose constructor takes its fields in declaration order (a proto3 `optional`
field or a message field is an `Optional`, a `repeated` field a `List`), and
conforms to `komira_proto_codec`'s `Serializable`, so `encode_json` and
`decode_json` (and the binary pair) read and write it. The two `Timestamp`
fields are `komira_wkt`'s and read and write RFC 3339 in JSON.

## Example

Every example below runs as a test when the package is built.

A weekly event as a client sends it, read and written back:

```mojo
from komira_calendar_proto.calendar import Event, Frequency, Weekday
from komira_proto_codec import decode_json, encode_json
from std.testing import assert_equal

var body = String(
    '{"title":"Weekly sync","start":"2026-10-12T09:00:00","timeZone":"Europe/London",'
    + '"durationSeconds":1800,"recurrence":{"freq":"WEEKLY","interval":1,'
    + '"weekdays":["MONDAY","THURSDAY"],"count":10}}'
)
var event = decode_json[Event](body)
assert_equal(event.duration_seconds, UInt32(1800))
assert_equal(event.recurrence.value().freq.value, Frequency.WEEKLY)
assert_equal(event.recurrence.value().weekdays[1].value, Weekday.THURSDAY)
assert_equal(encode_json(event), body)
```

A one-occurrence edit has presence on its replacements: a field it does not
name keeps the event's value.

```mojo
from komira_calendar_proto.calendar import OccurrenceOverride
from komira_proto_codec import decode_json
from std.testing import assert_equal, assert_false

var moved = decode_json[OccurrenceOverride](
    '{"eventId":"evt-1","originalStart":"2026-10-15T09:00:00","start":"2026-10-15T10:00:00"}'
)
assert_equal(moved.start.value(), "2026-10-15T10:00:00")
assert_false(Bool(moved.title))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_calendar_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/komira_calendar_proto_generated/` and
compiled as the module `komira_calendar_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on 2 sibling packages, `komira_proto_codec`, `komira_wkt` (each `{ path = "../<name>", version = "0.1" }`), so the `.conda` of this package records `mojo-<name> >=0.1,<0.2` for each as its dependencies
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `komira_calendar_proto_generated_gen` writes the Mojo for them,
`komira_calendar_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/komira_calendar_proto:komira_calendar_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/komira_calendar_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:komira_calendar_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
