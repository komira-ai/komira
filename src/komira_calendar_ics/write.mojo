# =============================================================================
# write.mojo -- calendar events to one iCalendar 2.0 file (RFC 5545).
# =============================================================================
#
# `write_ics(events, zones, stamp_utc)` returns an `IcsExport`: the text of
# a VCALENDAR (VERSION 2.0, a PRODID, CALSCALE GREGORIAN), a VTIMEZONE for
# each zone a written timed event uses other than `UTC` (vtimezone.mojo), in
# name order, then the events in order; and the series it skipped. Each
# event is checked first (`komira_calendar.check_event`), then each edit of
# a series it writes (`check_override`); one that breaks the model, or a
# written event naming a zone `zones` does not know, refuses the export.
#
# A series is one VEVENT:
#   UID (the event's uid, or its id when the uid is empty), DTSTAMP
#   (`stamp_utc`), DTSTART (`VALUE=DATE` all-day; `TZID=<zone>` timed;
#   UTC with `Z` when the zone is `UTC`), then DTEND (`VALUE=DATE`, all-day)
#   or DURATION (exact `PT..`, timed), SUMMARY, LOCATION, DESCRIPTION (each
#   only when not empty), STATUS:CANCELLED when cancelled, RRULE (UNTIL is
#   the event's last allowed start: a DATE all-day, else the UTC instant of
#   the until date at the start's time of day), EXDATE in the DTSTART form,
#   and one VALARM per reminder (ACTION:DISPLAY, the title as DESCRIPTION,
#   TRIGGER:-PT<n>M).
# An edit is one more VEVENT of the same UID with RECURRENCE-ID (the original
# start, in the DTSTART form). A cancelled occurrence has STATUS:CANCELLED
# and DTSTART at the original start; a kept one has every field the
# occurrence shows: the replacement where the edit has one (an empty
# SUMMARY, LOCATION or DESCRIPTION when the edit clears it), else the
# series' value.
# A recurring event whose start its rule does not pick is written with
# DTSTART (and an all-day DTEND) moved to the first day the rule picks
# (`first_occurrence`): RFC 5545 §3.8.5.3 leaves the set of an
# unsynchronized DTSTART undefined, and the model's series started there has
# the same occurrences. A series whose rule picks no day from its start to
# its until (`komira_calendar.check_event` accepts one) is left out with its
# edits and its uid listed in `IcsExport.skipped`: no VEVENT reads back as
# it (DTSTART must be an occurrence, and an UNTIL before DTSTART is refused),
# and the rest of the calendar is still written.
# Every TEXT value is escaped and every line folded at 75 octets
# (komira_content_line). Reading the file back gives the events written
# and a clean report, with four exceptions: a CR or CRLF in a TEXT value
# comes back as LF (TEXT has one escape, `\n`, for a line break); an event with no
# uid comes back with its id as the uid; an edit's replacement equal to
# the series' value is not kept (the occurrence shows the same), so an edit
# whose every replacement is such a value is reported as one that changes
# nothing; and a start its rule does not pick comes back as the first day
# the rule picks.
# =============================================================================

from komira_calendar import check_event, check_override, parse_local_date, parse_local_datetime
from komira_calendar_proto.calendar import Event, EventStatus, OccurrenceOverride
from komira_content_line import ContentLine, Param, escape_text, fold_line, format_content_line
from komira_datetime import FoldPolicy, GapPolicy

from .read_event import UNTITLED_REMINDER, IcsEvent
from .rrule import first_occurrence, format_rrule
from .values import (
    SECONDS_PER_DAY,
    format_ics_date,
    format_ics_datetime,
    format_ics_seconds,
)
from .vtimezone import prop_line, write_vtimezone
from .zones import ResolvedZone, ZoneResolver, ZoneSource

comptime LAST_DAY = 2932896
"""9999-12-31 in days since 1970-01-01: the last day of a series with no
until (a local date has four year digits)."""

comptime PRODID = "-//komira//komira_calendar_ics//EN"


def _line(name: String, var params: List[Param], value: String) raises -> String:
    return fold_line(format_content_line(ContentLine(String(), name.copy(), params^, value.copy())))


def _text(name: String, value: String) raises -> String:
    return _line(name, List[Param](), escape_text(value))


def _one(name: String, value: String) -> List[Param]:
    var values = List[String]()
    values.append(value.copy())
    var out = List[Param]()
    out.append(Param(name.copy(), values^))
    return out^


struct _Form(Copyable, Movable):
    """How an event's times are written: all-day, or timed in a zone."""

    var all_day: Bool
    var zone: Optional[ResolvedZone]

    def __init__(out self, all_day: Bool, var zone: Optional[ResolvedZone]):
        self.all_day = all_day
        self.zone = zone^

    def time(self, name: String, text: String, shift: Int = 0) raises -> String:
        """Property `name` holding the model's local start text `text`,
        `shift` days later."""
        if self.all_day:
            return _line(name, _one("VALUE", "DATE"), format_ics_date(parse_local_date(text) + shift))
        ref z = self.zone.value()
        var t = parse_local_datetime(text)
        var local = (t.days + shift) * SECONDS_PER_DAY + t.second_of_day
        if z.name == "UTC":
            return _line(name, List[Param](), format_ics_datetime(local, True))
        return _line(name, _one("TZID", z.name), format_ics_datetime(local, False))

    def start_utc(self, text: String) raises -> Int:
        var t = parse_local_datetime(text)
        return self.zone.value().zone.to_utc(
            t.days * SECONDS_PER_DAY + t.second_of_day, GapPolicy.SHIFT_FORWARD, FoldPolicy.EARLIER
        )


def _ending(form: _Form, start: String, days: Int, seconds: Int, shift: Int = 0) raises -> String:
    if form.all_day:
        return _line("DTEND", _one("VALUE", "DATE"), format_ics_date(parse_local_date(start) + shift + days))
    return _line("DURATION", List[Param](), format_ics_seconds(seconds))


def _until(form: _Form, event: Event) raises -> String:
    var until = event.recurrence.value().until.copy()
    if until.byte_length() == 0:
        return String()
    var day = parse_local_date(until)
    if form.all_day:
        return format_ics_date(day)
    var sod = parse_local_datetime(event.start).second_of_day
    var u = form.zone.value().zone.to_utc(day * SECONDS_PER_DAY + sod, GapPolicy.SHIFT_FORWARD, FoldPolicy.EARLIER)
    return format_ics_datetime(u, True)


def _texts(title: String, location: String, description: String) raises -> String:
    var out = String()
    if title.byte_length() > 0:
        out += _text("SUMMARY", title)
    if location.byte_length() > 0:
        out += _text("LOCATION", location)
    if description.byte_length() > 0:
        out += _text("DESCRIPTION", description)
    return out^


def _edit_text(name: String, replacement: Optional[String], series: String) raises -> String:
    """One TEXT property of a kept edit: the replacement when the edit has
    one, written even when empty (an edit that clears the field), else the
    series' value when it is not empty."""
    if replacement:
        return _text(name, replacement.value())
    if series.byte_length() > 0:
        return _text(name, series)
    return String()


def _series(event: Event, uid: String, stamp: String, form: _Form, shift: Int) raises -> String:
    """The series' VEVENT, its DTSTART `shift` days after the event's start
    (module header)."""
    var start = event.start_date.copy() if event.show_without_time else event.start.copy()
    var out = prop_line("BEGIN", "VEVENT")
    out += _text("UID", uid)
    out += prop_line("DTSTAMP", stamp)
    out += form.time("DTSTART", start, shift)
    out += _ending(form, start, Int(event.days), Int(event.duration_seconds), shift)
    out += _texts(event.title, event.location, event.description)
    if event.status.value == EventStatus.CANCELLED:
        out += prop_line("STATUS", "CANCELLED")
    if event.recurrence:
        out += prop_line("RRULE", format_rrule(event.recurrence.value(), _until(form, event)))
    for x in event.exdates:
        out += form.time("EXDATE", x)
    for r in event.reminders:
        out += prop_line("BEGIN", "VALARM")
        out += prop_line("ACTION", "DISPLAY")
        out += _text("DESCRIPTION", event.title if event.title.byte_length() > 0 else String(UNTITLED_REMINDER))
        out += prop_line("TRIGGER", "-PT" + String(r.minutes_before) + "M")
        out += prop_line("END", "VALARM")
    out += prop_line("END", "VEVENT")
    return out^


def _edit(event: Event, edit: OccurrenceOverride, uid: String, stamp: String, form: _Form) raises -> String:
    var out = prop_line("BEGIN", "VEVENT")
    out += _text("UID", uid)
    out += prop_line("DTSTAMP", stamp)
    out += form.time("RECURRENCE-ID", edit.original_start)
    if edit.cancelled:
        out += form.time("DTSTART", edit.original_start)
        out += prop_line("STATUS", "CANCELLED")
        out += prop_line("END", "VEVENT")
        return out^
    var start = edit.start.value().copy() if edit.start else edit.original_start.copy()
    out += form.time("DTSTART", start)
    var days = Int(edit.days.value()) if edit.days else Int(event.days)
    var seconds = Int(edit.duration_seconds.value()) if edit.duration_seconds else Int(event.duration_seconds)
    out += _ending(form, start, days, seconds)
    out += _edit_text("SUMMARY", edit.title, event.title)
    out += _edit_text("LOCATION", edit.location, event.location)
    out += _edit_text("DESCRIPTION", edit.description, event.description)
    out += prop_line("END", "VEVENT")
    return out^


struct IcsExport(Movable):
    """What `write_ics` wrote: the iCalendar `text`, and the uid (or id) of
    each series it `skipped`, in input order."""

    var text: String
    var skipped: List[String]

    def __init__(out self, var text: String, var skipped: List[String]):
        self.text = text^
        self.skipped = skipped^


def write_ics[Z: ZoneSource](events: List[IcsEvent], zones: Z, stamp_utc: Int) raises -> IcsExport:
    """`events` as one iCalendar file (module header). `stamp_utc` is the
    DTSTAMP of every VEVENT, in epoch seconds. A series whose rule picks no
    day from its start to its until is left out, its edits with it, and
    named in `skipped`."""
    var stamp = format_ics_datetime(stamp_utc, True)
    var zr = ZoneResolver()
    var names = List[String]()
    var firsts = List[Int]()
    var forms = List[_Form]()
    var shifts = List[Int]()
    var skips = List[Bool]()
    var skipped = List[String]()
    for ref ie in events:
        ref e = ie.event
        var uid = e.uid.copy() if e.uid.byte_length() > 0 else e.id.copy()
        if uid.byte_length() == 0:
            raise Error("ics export: an event has neither uid nor id")
        var r = check_event(e)
        if r:
            raise Error('ics export: event "' + uid + '": ' + String(r.value()))
        var shift = 0
        var skip = False
        if e.recurrence:
            ref rule = e.recurrence.value()
            var day = parse_local_date(e.start_date) if e.show_without_time else parse_local_datetime(e.start).days
            var until_day = parse_local_date(rule.until) if rule.until.byte_length() > 0 else LAST_DAY
            var first = first_occurrence(rule, day, until_day)
            if first:
                shift = first.value() - day
            else:
                skip = True
        shifts.append(shift)
        skips.append(skip)
        if skip:
            skipped.append(uid.copy())
            forms.append(_Form(True, None))
            continue
        for ref o in ie.overrides:
            var ro = check_override(o, e)
            if ro:
                raise Error('ics export: event "' + uid + '", occurrence ' + o.original_start + ": " + String(ro.value()))
        if e.show_without_time:
            forms.append(_Form(True, None))
            continue
        var z: ResolvedZone
        try:
            z = zr.resolve(e.time_zone, zones)
        except err:
            raise Error('ics export: event "' + uid + '": ' + String(err))
        var form = _Form(False, Optional[ResolvedZone](z.copy()))
        var first = form.start_utc(e.start)
        if e.time_zone != "UTC":
            var at = -1
            for k in range(len(names)):
                if names[k] == e.time_zone:
                    at = k
            if at < 0:
                names.append(e.time_zone.copy())
                firsts.append(first)
            elif first < firsts[at]:
                firsts[at] = first
        forms.append(form^)
    var out = prop_line("BEGIN", "VCALENDAR")
    out += prop_line("VERSION", "2.0")
    out += _text("PRODID", PRODID)
    out += prop_line("CALSCALE", "GREGORIAN")
    var ordered = names.copy()
    sort(ordered)
    for ref name in ordered:
        var first = 0
        for k in range(len(names)):
            if names[k] == name:
                first = firsts[k]
        out += write_vtimezone(name, zr.resolve(name, zones).zone, first)
    for i in range(len(events)):
        if skips[i]:
            continue
        ref ie = events[i]
        ref e = ie.event
        var uid = e.uid.copy() if e.uid.byte_length() > 0 else e.id.copy()
        out += _series(e, uid, stamp, forms[i], shifts[i])
        for ref o in ie.overrides:
            out += _edit(e, o, uid, stamp, forms[i])
    out += prop_line("END", "VCALENDAR")
    return IcsExport(out^, skipped^)
