# =============================================================================
# komira_calendar_store/span.mojo -- the UTC range an event's occurrences can
#   fall in, stored so a time-window query is one indexed conjunction.
# =============================================================================
#
# `utc_span` gives (first_start_utc, last_end_utc): every occurrence of the
# event, edited ones included, starts at or after the first and ends at or
# before the last, in UTC epoch seconds. A window query is then
# `first_start_utc < to AND last_end_utc > from`; the caller expands the
# events it returns. The range may be wider than the occurrences, never
# narrower.
#
#   timed     komira_calendar.series_span gives the local range; its ends go
#             through the event's zone. A local time the clock skipped (a gap)
#             or showed twice (a fold) has two candidate instants: the start
#             takes the earlier, the end the later.
#   all-day   a date has no zone; it is a different instant in every zone. The
#             local range is widened by ALL_DAY_SLACK_SECONDS on each side,
#             which no zone offset exceeds, so the event is found from any
#             zone.
#   open      a series with neither `count` nor `until` ends at OPEN_END
#             (Int64.MAX), never NULL or 0, so the query stays a conjunction.
#   none      a rule that picks no day gives NO_START and NO_END, which no
#             window matches.
#   overrides each one-occurrence edit widens the range to its own start
#             and length, since an edit may move an occurrence outside the
#             series (a cancelled one has neither, and stays inside it).
#
# Using the first occurrence for the start relies on two facts: every
# occurrence after the first starts at least a day later on the wall clock,
# and no zone moves its clock by more than a day at once.
# =============================================================================

from komira_calendar import OPEN_END, parse_local_date, parse_local_datetime, series_span
from komira_calendar_proto.calendar import Event, OccurrenceOverride
from komira_datetime import Zone

comptime SECONDS_PER_DAY = 86400

# The TZif reader refuses an offset beyond 26 hours, so an all-day event is
# widened by this much each way.
comptime ALL_DAY_SLACK_SECONDS = 26 * 3600

# The span of an event with no occurrence: no window matches it.
comptime NO_START: Int = OPEN_END
comptime NO_END: Int = -OPEN_END - 1


@fieldwise_init
struct UtcSpan(Copyable, Movable, ImplicitlyCopyable, Equatable, Writable):
    """The UTC range of an event's occurrences (module header)."""

    var first_start_utc: Int
    var last_end_utc: Int

    def __eq__(self, other: Self) -> Bool:
        return self.first_start_utc == other.first_start_utc and self.last_end_utc == other.last_end_utc

    def write_to[W: Writer](self, mut writer: W):
        writer.write("[", self.first_start_utc, ", ", self.last_end_utc, ")")


def _length(event: Event) -> Int:
    if event.show_without_time:
        return Int(event.days) * SECONDS_PER_DAY
    return Int(event.duration_seconds)


def _local(text: String, all_day: Bool) raises -> Int:
    if all_day:
        return parse_local_date(text) * SECONDS_PER_DAY
    return parse_local_datetime(text).seconds()


def _earliest(local: Int, zone: Optional[Zone]) raises -> Int:
    """The earliest instant a local start can be."""
    if not zone:
        return local - ALL_DAY_SLACK_SECONDS
    return zone.value().resolve(local).earlier


def _latest(local: Int, zone: Optional[Zone]) raises -> Int:
    """The latest instant a local start can be."""
    if not zone:
        return local + ALL_DAY_SLACK_SECONDS
    return zone.value().resolve(local).later


def utc_span(event: Event, overrides: List[OccurrenceOverride], zone: Optional[Zone]) raises -> UtcSpan:
    """The UTC range of `event` and its `overrides` (module header). `zone`
    is the event's zone for a timed event and None for an all-day one.
    Raises when `check_event` refuses the event."""
    var length = _length(event)
    var first = NO_START
    var last = NO_END
    var local = series_span(event)
    if local:
        var s = local.value()
        first = _earliest(s.first_start, zone)
        if s.last_end == OPEN_END:
            last = OPEN_END
        else:
            last = _latest(s.last_end - length, zone) + length
    for i in range(len(overrides)):
        ref o = overrides[i]
        var start_text = o.original_start.copy()
        if o.start:
            start_text = o.start.value().copy()
        var start = _local(start_text, event.show_without_time)
        var len_o = length
        if o.duration_seconds:
            len_o = Int(o.duration_seconds.value())
        if o.days:
            len_o = Int(o.days.value()) * SECONDS_PER_DAY
        first = min(first, _earliest(start, zone))
        last = max(last, _latest(start, zone) + len_o)
    return UtcSpan(first, last)
