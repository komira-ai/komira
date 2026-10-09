"""An event's occurrences in local time: `expand` lists those overlapping a
window, `series_span` bounds them all.

Times here are LOCAL SECONDS: seconds since 1970-01-01T00:00:00 on the
event's wall clock, zone not applied (`LocalDateTime.seconds()`). An
occurrence starts at a picked day (see series.mojo) at the event's time of
day (00:00:00 for an all-day event) and lasts `duration_seconds`, or `days`
whole days. Because the rule is expanded on the wall clock, a weekly 09:00
event is at 09:00 local on every occurrence; turning local seconds into UTC
instants is a zone's work and is not done here.

`count` counts the rule's occurrences before `exdates` remove any (an
excluded occurrence still uses its place); `until` is a local date and an
occurrence on that day is kept. The status (CONFIRMED or CANCELLED) is not
consulted.
"""

from std.collections import Set

from komira_calendar_proto.calendar import Event

from .local_time import parse_local_date, parse_local_datetime
from .series import ResolvedRule, period_at, period_days, period_first_day, resolve_rule
from .validate import check_event


comptime SECONDS_PER_DAY = 86400

# The value `series_span` gives as `last_end` for a series with neither
# `count` nor `until`: Int64.MAX, so a stored span is a plain range and a
# window query is `first_start < to AND last_end > from`.
comptime OPEN_END: Int = 9223372036854775807

# The most occurrences one `expand` call returns; a window holding more is
# refused, never cut short.
comptime MAX_WINDOW_OCCURRENCES = 10000


@fieldwise_init
struct Occurrence(Copyable, Movable, ImplicitlyCopyable, Equatable, Writable):
    """One occurrence: `start` and `end` (exclusive) in local seconds."""

    var start: Int
    var end: Int

    def __eq__(self, other: Self) -> Bool:
        return self.start == other.start and self.end == other.end

    def write_to[W: Writer](self, mut writer: W):
        writer.write("[", self.start, ", ", self.end, ")")


@fieldwise_init
struct SeriesSpan(Copyable, Movable, ImplicitlyCopyable, Equatable, Writable):
    """From the first occurrence's start to the last occurrence's end, in
    local seconds; `last_end` is OPEN_END for a series without an end."""

    var first_start: Int
    var last_end: Int

    def __eq__(self, other: Self) -> Bool:
        return self.first_start == other.first_start and self.last_end == other.last_end

    def write_to[W: Writer](self, mut writer: W):
        writer.write("[", self.first_start, ", ", self.last_end, ")")


struct _Timing(Copyable, Movable, ImplicitlyCopyable):
    """The first day, the time of day and the length of an event."""

    var first_day: Int
    var second_of_day: Int
    var length: Int

    def __init__(out self, event: Event) raises:
        if event.show_without_time:
            self.first_day = parse_local_date(event.start_date)
            self.second_of_day = 0
            self.length = Int(event.days) * SECONDS_PER_DAY
        else:
            var start = parse_local_datetime(event.start)
            self.first_day = start.days
            self.second_of_day = start.second_of_day
            self.length = Int(event.duration_seconds)

    @always_inline
    def start_of(self, day: Int) -> Int:
        return day * SECONDS_PER_DAY + self.second_of_day


def _checked(event: Event) raises -> _Timing:
    var refusal = check_event(event)
    if refusal:
        raise Error("the event is refused: " + String(refusal.value()))
    return _Timing(event)


def _excluded(event: Event) raises -> Set[Int]:
    """The exdates as local seconds (an all-day exdate is a date)."""
    var out = Set[Int]()
    for i in range(len(event.exdates)):
        if event.show_without_time:
            out.add(parse_local_date(event.exdates[i]) * SECONDS_PER_DAY)
        else:
            out.add(parse_local_datetime(event.exdates[i]).seconds())
    return out^


def expand(event: Event, window_start: Int, window_end: Int) raises -> List[Occurrence]:
    """The occurrences of `event` that overlap [window_start, window_end)
    (local seconds), ascending, without those its `exdates` remove. An
    occurrence overlaps when it starts before `window_end` and ends after
    `window_start`.

    Raises when `check_event` refuses the event ("the event is refused: "
    and the refusal), when the window is empty, or when it holds more than
    MAX_WINDOW_OCCURRENCES occurrences."""
    var t = _checked(event)
    if window_end <= window_start:
        raise Error("the window is empty: its end is not after its start")
    var out = List[Occurrence]()
    if not event.recurrence:
        var s = t.start_of(t.first_day)
        if s < window_end and s + t.length > window_start:
            out.append(Occurrence(s, s + t.length))
        return out^

    var r = resolve_rule(event.recurrence.value(), t.first_day)
    var excluded = _excluded(event)
    # Without a count, skip the periods that end before the window: no
    # occurrence starting before this day can reach `window_start`.
    var k = 0
    if r.count == 0:
        k = period_at(r, window_start // SECONDS_PER_DAY - t.length // SECONDS_PER_DAY - 2)
    var produced = 0
    var days = List[Int]()
    while True:
        var first = period_first_day(r, k)
        if first > r.until_day or t.start_of(first) >= window_end:
            return out^
        period_days(r, k, days)
        for i in range(len(days)):
            if days[i] > r.until_day:
                return out^
            produced += 1
            var s = t.start_of(days[i])
            if s < window_end and s + t.length > window_start and s not in excluded:
                if len(out) == MAX_WINDOW_OCCURRENCES:
                    raise Error(
                        "the window holds more than " + String(MAX_WINDOW_OCCURRENCES) + " occurrences; narrow it"
                    )
                out.append(Occurrence(s, s + t.length))
            if r.count != 0 and produced == r.count:
                return out^
        k += 1


def _last_day(r: ResolvedRule) -> Optional[Int]:
    """The last day the rule picks, given it ends by `count` or `until` and
    picks a day on or before `until_day` (series_span finds that day first).
    The count search gives None only when it picks no such day, which
    series_span rules out before it calls this."""
    var days = List[Int]()
    if r.count != 0:
        var produced = 0
        var last = Optional[Int](None)
        var k = 0
        while period_first_day(r, k) <= r.until_day:
            period_days(r, k, days)
            for i in range(len(days)):
                if days[i] > r.until_day:
                    return last
                last = days[i]
                produced += 1
                if produced == r.count:
                    return last
            k += 1
        return last
    # Back from the period holding until_day. The search stops at the latest
    # in the period of series_span's first day: that period picks a day on
    # or before until_day, so it starts on or before it, so it is not after
    # period_at's (the last period that does). k never goes below it.
    var k = period_at(r, r.until_day)
    while True:
        period_days(r, k, days)
        var i = len(days) - 1
        while i >= 0:
            if days[i] <= r.until_day:
                return days[i]
            i -= 1
        k -= 1


def series_span(event: Event) raises -> Optional[SeriesSpan]:
    """The local-seconds range from the first occurrence's start to the last
    occurrence's end; `last_end` is OPEN_END when the rule has neither
    `count` nor `until`. None when the rule picks no day (an `until` before
    the first day it would pick). `exdates` are not applied: the span holds
    every occurrence, so a window query over it misses none.

    Raises when `check_event` refuses the event."""
    var t = _checked(event)
    if not event.recurrence:
        var s = t.start_of(t.first_day)
        return SeriesSpan(s, s + t.length)
    var r = resolve_rule(event.recurrence.value(), t.first_day)
    var days = List[Int]()
    var first = Optional[Int](None)
    var k = 0
    while period_first_day(r, k) <= r.until_day:
        period_days(r, k, days)
        if len(days) > 0:
            if days[0] <= r.until_day:
                first = days[0]
            break
        k += 1
    if not first:
        return None
    if r.count == 0 and event.recurrence.value().until.byte_length() == 0:
        return SeriesSpan(t.start_of(first.value()), OPEN_END)
    var last = _last_day(r)
    return SeriesSpan(t.start_of(first.value()), t.start_of(last.value()) + t.length)
