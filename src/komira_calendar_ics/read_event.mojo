# =============================================================================
# read_event.mojo -- one VEVENT to the calendar model: a series (an event,
# recurring or not) or a one-occurrence edit of one.
# =============================================================================
#
# Timing (RFC 5545 §3.6.1, §3.8.2):
#   - DTSTART a DATE: an all-day event of DTEND - DTSTART days (DTEND a
#     DATE), of DURATION's days (whole days only), or of one day when
#     neither is given.
#   - DTSTART a DATE-TIME: a timed event in the zone of its TZID, or in
#     `UTC` when it ends in `Z`. A floating time (neither) is refused: the
#     model has no floating times. The duration is the exact time from the
#     start instant to the end instant: DTEND in its own zone, or DURATION
#     (its days on the start's wall clock, then its exact part). With neither,
#     the event would last no time, and is refused.
#   - DTEND and DURATION together are refused (the RFC forbids it); an end
#     not after the start is refused.
#   - A local time the clock skipped or showed twice is read as RFC 5545
#     §3.3.5 says: in the offset before the gap, and as the first of the two.
# Times in another zone (EXDATE, RECURRENCE-ID, an edit's DTSTART) are read
# as instants and shown on the event's wall clock; a floating one is read on
# the event's wall clock. A DATE where the event has a DATE-TIME, or the
# reverse, is refused.
#
# UNTIL becomes the model's local date (inclusive): a DATE as written; a UTC
# DATE-TIME U as the last local date whose occurrence at the start's time of
# day starts at or before U; a local DATE-TIME as the last date whose
# occurrence time is at or before it. On an all-day event a DATE-TIME UNTIL
# gives its date.
#
# VALARM: a TRIGGER relative to the start, at or before it, in whole minutes
# up to the model's bound, becomes a reminder (`minutes_before`; a day in the
# TRIGGER counts 1440 minutes). An alarm's
# ACTION other than DISPLAY, its DESCRIPTION unless it is the event's title
# (what the reminder shows) or, for an event with no title, the word
# `UNTITLED_REMINDER` an export writes there, and every other alarm property
# are reported
# dropped; so is an alarm whose trigger cannot be a reminder, one repeating
# an earlier reminder, and one past the model's count.
#
# An edit (a VEVENT with RECURRENCE-ID) keeps what differs from its series:
# a replacement title, location, description, start, or length; a property
# it leaves out keeps the series' value. STATUS:CANCELLED cancels the
# occurrence; its other properties (but a DTSTART at the original start)
# and its VALARMs are then reported dropped "on a cancelled occurrence", and
# any other child is refused. RANGE (this and later occurrences) is refused.
# The edit's RRULE, EXDATE and VALARM are reported dropped: an occurrence has
# none of its own.
# =============================================================================

from std.collections import Dict

from komira_calendar import (
    MAX_DURATION_SECONDS,
    MAX_REMINDER_MINUTES,
    MAX_REMINDERS,
    RefusalCode,
)
from komira_calendar_proto.calendar import (
    Event,
    EventStatus,
    OccurrenceOverride,
    Recurrence,
    Reminder,
)
from komira_content_line import unescape_text
from komira_datetime import format_iso_date
from komira_datetime import FoldPolicy, GapPolicy, format_local

from .props import (
    EventProps,
    param_value,
    refusal,
    report_others,
    report_params,
    sort_props,
    text_of,
    time_of,
)
from .report import IcsCode, IcsReport
from .rrule import parse_rrule
from .tree import IcsComponent, IcsProperty
from .values import (
    SECONDS_PER_DAY,
    IcsTime,
    parse_ics_duration,
    parse_ics_time,
)
from .zones import ResolvedZone, ZoneResolver, ZoneSource


comptime UNTITLED_REMINDER = "Reminder"
"""The DESCRIPTION an export writes on the VALARM of an event with no title
(RFC 5545 §3.6.6 requires one on a DISPLAY alarm)."""


struct IcsEvent(Copyable, Movable):
    """An event and its one-occurrence edits. The edits' `event_id` is empty:
    the store that keeps the event assigns it."""

    var event: Event
    var overrides: List[OccurrenceOverride]

    def __init__(out self, var event: Event, var overrides: List[OccurrenceOverride] = List[OccurrenceOverride]()):
        self.event = event^
        self.overrides = overrides^


def new_event() -> Event:
    """An event with every field at its zero value."""
    return Event(
        String(), String(), String(), String(), String(), String(),
        False, String(), UInt32(0), String(), String(), UInt32(0),
        EventStatus(EventStatus.CONFIRMED), None, List[String](), List[Reminder](),
        UInt64(0), None, None,
    )


def _to_utc(z: ResolvedZone, local: Int) raises -> Int:
    return z.zone.to_utc(local, GapPolicy.SHIFT_FORWARD, FoldPolicy.EARLIER)


def _zone_of[Z: ZoneSource](t: IcsTime, mut zr: ZoneResolver, zones: Z) raises -> ResolvedZone:
    try:
        if t.is_utc:
            return zr.resolve("UTC", zones)
        return zr.resolve(t.tzid, zones)
    except e:
        raise refusal(IcsCode.UNKNOWN_TZID, String(e))


def _instant[Z: ZoneSource](t: IcsTime, home: ResolvedZone, mut zr: ZoneResolver, zones: Z) raises -> Int:
    """The UTC instant of DATE-TIME `t`; a floating `t` is read in `home`."""
    if t.is_utc:
        return t.local
    if t.tzid.byte_length() == 0 or t.tzid == home.tzid:
        return _to_utc(home, t.local)
    return _to_utc(_zone_of(t, zr, zones), t.local)


def _wall[Z: ZoneSource](t: IcsTime, home: ResolvedZone, mut zr: ZoneResolver, zones: Z) raises -> Int:
    """DATE-TIME `t` on `home`'s wall clock (module header)."""
    if t.tzid.byte_length() == 0 and not t.is_utc:
        return t.local
    if t.tzid == home.tzid and not t.is_utc:
        return t.local
    return home.zone.to_local(_instant(t, home, zr, zones))


def _form_mismatch(name: String, all_day: Bool) -> Error:
    if all_day:
        return refusal(IcsCode.FORM_MISMATCH, name + " is a DATE-TIME but the event's DTSTART is a DATE")
    return refusal(IcsCode.FORM_MISMATCH, name + " is a DATE but the event's DTSTART is a DATE-TIME")


@fieldwise_init
struct Timing(Copyable, Movable):
    """When an event or an edit happens: all-day or not, its start on the
    wall clock (an all-day start is its midnight), its zone (empty when
    all-day) and its length (days when all-day, else seconds). `has_end`
    is False when neither DTEND nor DURATION was given."""

    var all_day: Bool
    var start_local: Int
    var zone: Optional[ResolvedZone]
    var length: Int
    var has_end: Bool


def _length[Z: ZoneSource](
    comp: IcsComponent, props: EventProps, all_day: Bool, start_local: Int,
    home: Optional[ResolvedZone], mut zr: ZoneResolver, zones: Z,
) raises -> Optional[Int]:
    """The length from DTEND or DURATION, or None when neither is there."""
    if props.dtend >= 0 and props.duration >= 0:
        raise refusal(IcsCode.END_AND_DURATION, "DTEND and DURATION are both given; RFC 5545 allows one")
    if props.dtend >= 0:
        var e = time_of(comp.properties[props.dtend])
        if e.is_date != all_day:
            raise _form_mismatch("DTEND", all_day)
        if all_day:
            return Optional[Int](e.day() - start_local // SECONDS_PER_DAY)
        if e.is_floating():
            raise refusal(IcsCode.FLOATING_TIME, "DTEND is a floating time (no TZID, no Z)")
        var h = home.value().copy()
        return Optional[Int](_instant(e, h, zr, zones) - _to_utc(h, start_local))
    if props.duration >= 0:
        ref p = comp.properties[props.duration]
        var d = parse_ics_duration(p.line.value)
        if d.negative:
            raise refusal(IcsCode.NOT_AFTER_START, 'DURATION "' + p.line.value + '" is negative')
        if all_day:
            if d.seconds != 0:
                raise refusal(IcsCode.FORM_MISMATCH, 'DURATION "' + p.line.value + '" of an all-day event is not whole days')
            return Optional[Int](d.days)
        var h = home.value().copy()
        return Optional[Int](_to_utc(h, start_local + d.days * SECONDS_PER_DAY) + d.seconds - _to_utc(h, start_local))
    return None


def read_timing[Z: ZoneSource](
    comp: IcsComponent, props: EventProps, mut zr: ZoneResolver, zones: Z
) raises -> Timing:
    """The timing of a series VEVENT (module header)."""
    if props.dtstart < 0:
        raise refusal(IcsCode.DTSTART_MISSING, "the VEVENT has no DTSTART")
    var t = time_of(comp.properties[props.dtstart])
    if t.is_date:
        var given = _length(comp, props, True, t.local, None, zr, zones)
        if not given:
            return Timing(True, t.local, None, 1, False)
        var days = given.value()
        if days <= 0:
            raise refusal(IcsCode.NOT_AFTER_START, "the event's end is not after its start")
        return Timing(True, t.local, None, days, True)
    if t.is_floating():
        raise refusal(
            IcsCode.FLOATING_TIME,
            'DTSTART "' + comp.properties[props.dtstart].line.value
            + '" is a floating time (no TZID, no Z); the calendar keeps zoned times only',
        )
    var home = _zone_of(t, zr, zones)
    var timed_end = _length(comp, props, False, t.local, Optional[ResolvedZone](home.copy()), zr, zones)
    if not timed_end:
        raise refusal(
            IcsCode.NOT_AFTER_START,
            "a timed event with neither DTEND nor DURATION lasts no time; the calendar needs at least one second",
        )
    var seconds = timed_end.value()
    if seconds <= 0:
        raise refusal(IcsCode.NOT_AFTER_START, "the event's end is not after its start")
    if seconds > MAX_DURATION_SECONDS:
        raise refusal(
            RefusalCode.DURATION_TOO_LONG,
            "the event lasts " + String(seconds) + " seconds; at most " + String(MAX_DURATION_SECONDS) + " are allowed",
        )
    return Timing(False, t.local, Optional[ResolvedZone](home^), seconds, True)


def _start_text(timing: Timing) raises -> String:
    if timing.all_day:
        return format_iso_date(timing.start_local // SECONDS_PER_DAY)
    return format_local(timing.start_local)


def _until[Z: ZoneSource](text: String, timing: Timing, mut zr: ZoneResolver, zones: Z) raises -> String:
    """The model's `until` for RRULE UNTIL `text` (module header)."""
    var u: IcsTime
    try:
        u = parse_ics_time(text, String(), String())
    except e:
        raise refusal(IcsCode.RRULE_MALFORMED, "RRULE UNTIL " + String(e))
    if u.is_date or timing.all_day:
        return format_iso_date(u.day())
    var sod = timing.start_local % SECONDS_PER_DAY
    if not u.is_utc:
        var day = u.day()
        if u.second_of_day() < sod:
            day -= 1
        return format_iso_date(day)
    var home = timing.zone.value().copy()
    var day = home.zone.to_local(u.local) // SECONDS_PER_DAY
    if _to_utc(home, day * SECONDS_PER_DAY + sod) > u.local:
        day -= 1
    return format_iso_date(day)


def _exdates[Z: ZoneSource](
    comp: IcsComponent, props: EventProps, timing: Timing, mut zr: ZoneResolver, zones: Z
) raises -> List[String]:
    var out = List[String]()
    var seen = Dict[String, Int]()
    for i in props.exdates:
        ref p = comp.properties[i]
        for item in p.line.value.split(","):
            var one = IcsProperty(p.line.copy(), p.line_number)
            one.line.value = String(item)
            var t = time_of(one)
            if t.is_date != timing.all_day:
                raise _form_mismatch("EXDATE", timing.all_day)
            var text: String
            if timing.all_day:
                text = format_iso_date(t.day())
            else:
                text = format_local(_wall(t, timing.zone.value(), zr, zones))
            if text not in seen:
                seen[text] = 1
                out.append(text^)
    return out^


def _status(comp: IcsComponent, props: EventProps, mut rep: IcsReport) -> Bool:
    """True when STATUS is CANCELLED; any value but CONFIRMED and CANCELLED
    is reported as read as CONFIRMED."""
    if props.status < 0:
        return False
    ref p = comp.properties[props.status]
    var v = p.line.value.upper()
    if v == "CANCELLED":
        return True
    if v != "CONFIRMED":
        rep.drop(comp.name, "STATUS", v + " is read as CONFIRMED", p.line_number)
    return False


def _alarm_minutes(alarm: IcsComponent, title: String, mut rep: IcsReport) -> Int:
    """The reminder an alarm gives, in minutes before the start, or -1 (and
    the reason reported)."""
    var trigger = -1
    for i in range(len(alarm.properties)):
        ref p = alarm.properties[i]
        ref name = p.line.name
        if name == "TRIGGER" and trigger < 0:
            trigger = i
        elif name == "ACTION":
            var v = p.line.value.upper()
            if v != "DISPLAY":
                rep.drop("VALARM", "ACTION", v + ", read as a reminder to the owner", p.line_number)
        elif name == "DESCRIPTION":
            var shown = unescape_text(p.line.value)
            if shown != title and not (title.byte_length() == 0 and shown == UNTITLED_REMINDER):
                rep.drop("VALARM", "DESCRIPTION", String(), p.line_number)
        else:
            rep.drop("VALARM", name, String(), p.line_number)
    for k in range(len(alarm.children)):
        _ = k
        rep.drop("VALARM", "a component inside VALARM", String(), alarm.begin_line)
    if trigger < 0:
        rep.drop("VALARM", "VALARM", "no TRIGGER", alarm.begin_line)
        return -1
    ref p = alarm.properties[trigger]
    var related = param_value(p, "RELATED").upper()
    var vtype = param_value(p, "VALUE").upper()
    if vtype.byte_length() > 0 and vtype != "DURATION":
        rep.drop("VALARM", "TRIGGER", "an absolute time", p.line_number)
        return -1
    if related == "END":
        rep.drop("VALARM", "TRIGGER", "relative to the end", p.line_number)
        return -1
    try:
        var d = parse_ics_duration(p.line.value)
        var seconds = d.days * SECONDS_PER_DAY + d.seconds
        if seconds == 0:
            return 0
        if not d.negative:
            rep.drop("VALARM", "TRIGGER", "after the start", p.line_number)
            return -1
        if seconds % 60 != 0:
            rep.drop("VALARM", "TRIGGER", "not whole minutes", p.line_number)
            return -1
        if seconds // 60 > MAX_REMINDER_MINUTES:
            rep.drop("VALARM", "TRIGGER", "more than " + String(MAX_REMINDER_MINUTES) + " minutes before", p.line_number)
            return -1
        return seconds // 60
    except:
        rep.drop("VALARM", "TRIGGER", "not a DURATION", p.line_number)
        return -1


def _children(
    comps: List[IcsComponent], comp: IcsComponent, title: String, edit: Bool, mut rep: IcsReport
) -> List[Reminder]:
    """The reminders of a series' VALARMs; another child is refused."""
    var out = List[Reminder]()
    for c in comp.children:
        ref child = comps[c]
        if child.name != "VALARM":
            rep.refuse(
                IcsCode.COMPONENT_OUT_OF_SUBSET, child.begin_line, String(),
                child.name + " inside a VEVENT is outside the subset (only VALARM is read there)",
            )
            continue
        if edit:
            rep.drop("VEVENT", "VALARM", "on an occurrence edit, which keeps its series' reminders", child.begin_line)
            continue
        var m = _alarm_minutes(child, title, rep)
        if m < 0:
            continue
        var seen = False
        for r in out:
            if Int(r.minutes_before) == m:
                seen = True
        if seen:
            rep.drop("VALARM", "VALARM", "repeats an earlier reminder", child.begin_line)
        elif len(out) >= MAX_REMINDERS:
            rep.drop("VALARM", "VALARM", "past the " + String(MAX_REMINDERS) + " reminders an event keeps", child.begin_line)
        else:
            out.append(Reminder(UInt32(m)))
    return out^


def _report_cancelled[Z: ZoneSource](
    comps: List[IcsComponent], comp: IcsComponent, props: EventProps, all_day: Bool,
    original_local: Int, home: Optional[ResolvedZone], mut zr: ZoneResolver, zones: Z, mut rep: IcsReport,
):
    """Reports what a cancelled occurrence edit carries besides UID,
    DTSTAMP, RECURRENCE-ID, STATUS and a DTSTART at the original start: each
    such property and VALARM is dropped "on a cancelled occurrence"; any
    other child is refused as in a series."""
    comptime CANCELLED = "on a cancelled occurrence"
    var none = List[String]()
    report_params(comp, props.uid, none, comp.name, rep)
    report_params(comp, props.recurrence_id, _rid_params(), comp.name, rep)
    report_params(comp, props.status, none, comp.name, rep)
    for i in range(len(comp.properties)):
        ref p = comp.properties[i]
        ref name = p.line.name
        if i == props.uid or i == props.recurrence_id or i == props.status or name == "DTSTAMP":
            continue
        if i == props.dtstart:
            var same = False
            try:
                var t = time_of(p)
                if t.is_date == all_day:
                    var local = t.local if all_day else _wall(t, home.value(), zr, zones)
                    same = local == original_local
            except:
                same = False
            if same:
                report_params(comp, i, _time_params(), comp.name, rep)
                continue
        rep.drop(comp.name, name, CANCELLED, p.line_number)
    for c in comp.children:
        ref child = comps[c]
        if child.name == "VALARM":
            rep.drop(comp.name, "VALARM", CANCELLED, child.begin_line)
        else:
            rep.refuse(
                IcsCode.COMPONENT_OUT_OF_SUBSET, child.begin_line, String(),
                child.name + " inside a VEVENT is outside the subset (only VALARM is read there)",
            )


def _time_params() -> List[String]:
    return ["VALUE", "TZID"]


def _rid_params() -> List[String]:
    return ["VALUE", "TZID", "RANGE"]


def _report_read_params(comp: IcsComponent, props: EventProps, mut rep: IcsReport):
    var none = List[String]()
    report_params(comp, props.dtstart, _time_params(), comp.name, rep)
    report_params(comp, props.dtend, _time_params(), comp.name, rep)
    report_params(comp, props.recurrence_id, _rid_params(), comp.name, rep)
    for i in props.exdates:
        report_params(comp, i, _time_params(), comp.name, rep)
    report_params(comp, props.uid, none, comp.name, rep)
    report_params(comp, props.duration, none, comp.name, rep)
    report_params(comp, props.summary, none, comp.name, rep)
    report_params(comp, props.description, none, comp.name, rep)
    report_params(comp, props.location, none, comp.name, rep)
    report_params(comp, props.status, none, comp.name, rep)
    for i in props.rrules:
        report_params(comp, i, none, comp.name, rep)


def read_series[Z: ZoneSource](
    comps: List[IcsComponent], index: Int, mut zr: ZoneResolver, zones: Z, mut rep: IcsReport
) raises -> Event:
    """The event a series VEVENT gives (module header). Raises a refusal;
    what it drops goes to `rep`."""
    ref comp = comps[index]
    var props = sort_props(comp)
    if props.uid < 0:
        raise refusal(IcsCode.UID_MISSING, "the VEVENT has no UID")
    var timing = read_timing(comp, props, zr, zones)
    var e = new_event()
    e.uid = text_of(comp, props.uid)
    e.title = text_of(comp, props.summary)
    e.description = text_of(comp, props.description)
    e.location = text_of(comp, props.location)
    if timing.all_day:
        e.show_without_time = True
        e.start_date = _start_text(timing)
        e.days = UInt32(timing.length)
    else:
        e.start = _start_text(timing)
        e.time_zone = timing.zone.value().name.copy()
        e.duration_seconds = UInt32(timing.length)
    if _status(comp, props, rep):
        e.status = EventStatus(EventStatus.CANCELLED)
    if len(props.rrules) > 1:
        raise refusal(IcsCode.RRULE_OUT_OF_SUBSET, "the VEVENT has " + String(len(props.rrules)) + " RRULEs; the subset keeps one")
    if len(props.rrules) == 1:
        var r = parse_rrule(comp.properties[props.rrules[0]].line.value, timing.start_local // SECONDS_PER_DAY)
        if not r.ok():
            raise refusal(r.code, r.message)
        var rule = r.rule.copy()
        if r.until.byte_length() > 0:
            rule.until = _until(r.until, timing, zr, zones)
        e.recurrence = Optional[Recurrence](rule^)
    if len(props.exdates) > 0:
        if not e.recurrence:
            for i in props.exdates:
                rep.drop(comp.name, "EXDATE", "on an event that does not recur", comp.properties[i].line_number)
        else:
            e.exdates = _exdates(comp, props, timing, zr, zones)
    e.reminders = _children(comps, comp, e.title, False, rep)
    _report_read_params(comp, props, rep)
    report_others(comp, props, rep)
    return e^


def read_edit[Z: ZoneSource](
    comps: List[IcsComponent], index: Int, series: Event, mut zr: ZoneResolver, zones: Z, mut rep: IcsReport
) raises -> Optional[OccurrenceOverride]:
    """The one-occurrence edit a VEVENT with RECURRENCE-ID gives against its
    `series` (module header), or None when it changes nothing. Raises a
    refusal; what it drops goes to `rep`."""
    ref comp = comps[index]
    var props = sort_props(comp)
    ref rid_p = comp.properties[props.recurrence_id]
    var range_v = param_value(rid_p, "RANGE")
    if range_v.byte_length() > 0:
        raise refusal(
            IcsCode.RANGE_OUT_OF_SUBSET,
            "RECURRENCE-ID;RANGE=" + range_v + " edits this and later occurrences; only one occurrence is edited here",
        )
    var all_day = series.show_without_time
    var home: Optional[ResolvedZone] = None
    if not all_day:
        home = zr.resolve(series.time_zone, zones)
    var rid = time_of(rid_p)
    if rid.is_date != all_day:
        raise _form_mismatch("RECURRENCE-ID", all_day)
    var edit = OccurrenceOverride(
        String(), String(), False, None, None, None, None, None, None, UInt64(0)
    )
    var original_local: Int
    if all_day:
        original_local = rid.local
        edit.original_start = format_iso_date(rid.day())
    else:
        original_local = _wall(rid, home.value(), zr, zones)
        edit.original_start = format_local(original_local)
    if _status(comp, props, rep):
        edit.cancelled = True
        _report_cancelled(comps, comp, props, all_day, original_local, home, zr, zones, rep)
        return edit^
    var start_local = original_local
    if props.dtstart >= 0:
        var t = time_of(comp.properties[props.dtstart])
        if t.is_date != all_day:
            raise _form_mismatch("DTSTART", all_day)
        start_local = t.local if all_day else _wall(t, home.value(), zr, zones)
    var given = _length(comp, props, all_day, start_local, home, zr, zones)
    var length = given.value() if given else 0
    if given and length <= 0:
        raise refusal(IcsCode.NOT_AFTER_START, "the occurrence's end is not after its start")
    var changed = False
    if start_local != original_local:
        var start_text = format_iso_date(start_local // SECONDS_PER_DAY) if all_day else format_local(start_local)
        edit.start = Optional[String](start_text^)
        changed = True
    if all_day and given and length != Int(series.days):
        edit.days = Optional[UInt32](UInt32(length))
        changed = True
    if not all_day and given and length != Int(series.duration_seconds):
        if length > MAX_DURATION_SECONDS:
            raise refusal(
                RefusalCode.DURATION_TOO_LONG,
                "the occurrence lasts " + String(length) + " seconds; at most " + String(MAX_DURATION_SECONDS) + " are allowed",
            )
        edit.duration_seconds = Optional[UInt32](UInt32(length))
        changed = True
    if props.summary >= 0 and text_of(comp, props.summary) != series.title:
        edit.title = Optional[String](text_of(comp, props.summary))
        changed = True
    if props.location >= 0 and text_of(comp, props.location) != series.location:
        edit.location = Optional[String](text_of(comp, props.location))
        changed = True
    if props.description >= 0 and text_of(comp, props.description) != series.description:
        edit.description = Optional[String](text_of(comp, props.description))
        changed = True
    for i in props.rrules:
        rep.drop(comp.name, "RRULE", "on an occurrence edit", comp.properties[i].line_number)
    for i in props.exdates:
        rep.drop(comp.name, "EXDATE", "on an occurrence edit", comp.properties[i].line_number)
    _ = _children(comps, comp, series.title, True, rep)
    _report_read_params(comp, props, rep)
    report_others(comp, props, rep)
    if not changed:
        return None
    return edit^
