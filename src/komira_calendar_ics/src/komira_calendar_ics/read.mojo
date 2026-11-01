# =============================================================================
# read.mojo -- an iCalendar file to the calendar model, with a report.
# =============================================================================
#
# `read_ics(bytes, zones)` reads one VCALENDAR (tree.mojo) and returns the
# events the subset holds and an `IcsReport` of everything else. The whole
# input is refused (raised) when it is not iCalendar this package reads:
#   - invalid UTF-8, an over-long input or line, a malformed content line,
#     unbalanced BEGIN/END, more than one VCALENDAR (tree.mojo);
#   - VERSION missing, repeated, or not 2.0;
#   - CALSCALE other than GREGORIAN;
#   - METHOD other than PUBLISH: a scheduling message (iTIP, RFC 5546) is
#     not a calendar to import.
# PRODID is read and not reported. Every other VCALENDAR property is
# reported dropped.
#
# In the VCALENDAR:
#   - VTIMEZONE is read for its TZID's X-LIC-LOCATION only (zones.mojo):
#     the rules come from the `ZoneSource`, never from the file.
#   - VEVENT without RECURRENCE-ID is a series (read_event.mojo). A series
#     is refused when it has no UID or the UID of an earlier series, when a
#     value is malformed or out of the subset (an RRULE that does not pick
#     its DTSTART among them), and when the event breaks the
#     calendar model (`komira_calendar.check_event`, whose code it carries).
#   - VEVENT with RECURRENCE-ID is an edit of the imported series of its
#     UID, read after every series. It is refused without such a recurring
#     series, when it edits an occurrence edited before, and when it breaks
#     `komira_calendar.check_override`. An edit that changes nothing is
#     reported dropped.
#   - Any other component (VTODO, VJOURNAL, VFREEBUSY, ...) is refused as
#     out of subset.
# =============================================================================

from std.collections import Dict

from komira_calendar import check_event, check_override

from .props import refusal, split_refusal, text_of
from .read_event import IcsEvent, read_edit, read_series
from .report import IcsCode, IcsReport
from .tree import IcsComponent, IcsLimits, read_components
from .zones import ZoneResolver, ZoneSource


struct IcsImport(Copyable, Movable):
    """What an import kept (`events`, in input order, each with its edits)
    and its report."""

    var events: List[IcsEvent]
    var report: IcsReport

    def __init__(out self, var events: List[IcsEvent], var report: IcsReport):
        self.events = events^
        self.report = report^


def _calendar_props(cal: IcsComponent, mut rep: IcsReport) raises:
    var version = -1
    for i in range(len(cal.properties)):
        ref p = cal.properties[i]
        ref name = p.line.name
        var at = "ics: line " + String(p.line_number) + ": "
        if name == "VERSION":
            if version >= 0:
                raise Error(at + "VERSION appears more than once")
            version = i
            if p.line.value != "2.0":
                raise Error(at + 'VERSION is "' + p.line.value + '"; only iCalendar 2.0 (RFC 5545) is read')
        elif name == "CALSCALE":
            if p.line.value.upper() != "GREGORIAN":
                raise Error(at + "CALSCALE:" + p.line.value + " is not read; only GREGORIAN is")
        elif name == "METHOD":
            if p.line.value.upper() != "PUBLISH":
                raise Error(
                    at + "METHOD:" + p.line.value
                    + " is a scheduling message (iTIP); only a published calendar is imported"
                )
        elif name != "PRODID":
            rep.drop("VCALENDAR", name, String(), p.line_number)
    if version < 0:
        raise Error("ics: the VCALENDAR of line " + String(cal.begin_line) + " has no VERSION")


def _uid_of(comp: IcsComponent) -> String:
    for i in range(len(comp.properties)):
        if comp.properties[i].line.name == "UID":
            return text_of(comp, i)
    return String()


def _has(comp: IcsComponent, name: String) -> Bool:
    for i in range(len(comp.properties)):
        if comp.properties[i].line.name == name:
            return True
    return False


def _model_refusal(field: String, code: String, message: String) -> Error:
    return refusal(code, "the event breaks the calendar model at " + field + ": " + message)


def read_ics[Z: ZoneSource](
    data: Span[UInt8, _], zones: Z, limits: IcsLimits = IcsLimits()
) raises -> IcsImport:
    """The events of the iCalendar `data` and the report of what was not
    kept (module header). Raises when the input as a whole is refused."""
    var comps = read_components(data, limits)
    var rep = IcsReport()
    _calendar_props(comps[0], rep)
    var zr = ZoneResolver()
    var edits = List[Int]()
    for c in comps[0].children:
        ref comp = comps[c]
        if comp.name == "VTIMEZONE":
            var tzid = String()
            var location = String()
            for i in range(len(comp.properties)):
                ref p = comp.properties[i]
                if p.line.name == "TZID" and tzid.byte_length() == 0:
                    tzid = p.line.value.copy()
                elif p.line.name == "X-LIC-LOCATION" and location.byte_length() == 0:
                    location = p.line.value.copy()
            if tzid.byte_length() > 0 and location.byte_length() > 0 and zr.location_of(tzid).byte_length() == 0:
                zr.add_location(tzid, location)

    var events = List[IcsEvent]()
    var uids = Dict[String, Int]()  # the UID of each imported series: its index in `events`
    var edited = Dict[String, Int]()  # series index, a space, original start: each kept edit
    for c in comps[0].children:
        ref comp = comps[c]
        if comp.name == "VTIMEZONE":
            continue
        if comp.name != "VEVENT":
            rep.refuse(
                IcsCode.COMPONENT_OUT_OF_SUBSET, comp.begin_line, _uid_of(comp),
                comp.name + " is outside the subset: only VEVENT (with VALARM) and VTIMEZONE are read",
            )
            continue
        if _has(comp, "RECURRENCE-ID"):
            edits.append(c)
            continue
        var local = IcsReport()
        var uid = _uid_of(comp)
        try:
            if uid.byte_length() > 0 and uid in uids:
                raise refusal(IcsCode.UID_DUPLICATE, 'an earlier VEVENT has UID "' + uid + '"')
            var event = read_series(comps, c, zr, zones, local)
            var r = check_event(event)
            if r:
                raise _model_refusal(r.value().field, r.value().code, r.value().message)
            uids[uid] = len(events)
            events.append(IcsEvent(event^))
            rep.merge(local)
        except e:
            var s = split_refusal(e)
            rep.refuse(s.code, comp.begin_line, uid, s.message)

    for c in edits:
        ref comp = comps[c]
        var local = IcsReport()
        var uid = _uid_of(comp)
        try:
            if uid.byte_length() == 0:
                raise refusal(IcsCode.UID_MISSING, "the VEVENT has no UID")
            var at = uids.get(uid).or_else(-1)
            if at < 0 or not events[at].event.recurrence:
                raise refusal(
                    IcsCode.OVERRIDE_WITHOUT_SERIES,
                    'RECURRENCE-ID edits an occurrence of UID "' + uid
                    + '", and no recurring event of that UID was imported',
                )
            var edit = read_edit(comps, c, events[at].event, zr, zones, local)
            if not edit:
                local.drop("VEVENT", "RECURRENCE-ID", "an occurrence edit that changes nothing", comp.begin_line)
            else:
                var key = String(at) + " " + edit.value().original_start
                if key in edited:
                    raise refusal(
                        IcsCode.OVERRIDE_DUPLICATE,
                        "the occurrence " + edit.value().original_start + " is edited twice",
                    )
                var r = check_override(edit.value(), events[at].event)
                if r:
                    raise _model_refusal(r.value().field, r.value().code, r.value().message)
                edited[key] = 1
                events[at].overrides.append(edit.take())
            rep.merge(local)
        except e:
            var s = split_refusal(e)
            rep.refuse(s.code, comp.begin_line, uid, s.message)
    return IcsImport(events^, rep^)
