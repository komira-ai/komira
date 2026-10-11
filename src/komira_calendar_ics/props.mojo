# =============================================================================
# props.mojo -- the properties of one VEVENT, sorted into the ones the
# subset reads and the ones it drops; and the refusal an event read raises.
# =============================================================================
#
# A refusal inside the event reader is raised as an Error whose text is the
# code, a TAB and the message (`refusal`), so the reader's helpers can stop
# at the first problem; `split_refusal` turns it back into the two parts. An
# error from elsewhere (no TAB) is a VALUE_MALFORMED refusal.
#
# The properties the subset reads may appear once (RFC 5545 §3.6.1 allows
# no more), except RRULE (more than one is out of subset) and EXDATE. DTSTAMP
# is when the file was written, not a fact about the event: it is read and
# not reported. Every other property is reported as dropped when the event
# is imported, and so is every parameter a read property carries other than
# the ones it is read with (VALUE and TZID on a time; RANGE on
# RECURRENCE-ID).
# =============================================================================

from komira_content_line import unescape_text

from .report import IcsCode, IcsReport
from .tree import IcsComponent, IcsProperty
from .values import IcsTime, parse_ics_time


def refusal(code: String, message: String) -> Error:
    """An Error carrying a refusal (module header)."""
    return Error(code + "\t" + message)


@fieldwise_init
struct SplitRefusal(Copyable, Movable):
    var code: String
    var message: String


def split_refusal(e: Error) -> SplitRefusal:
    """The code and message of an Error `refusal` made, or VALUE_MALFORMED
    and the whole text for any other Error."""
    var s = String(e)
    var tab = s.find("\t")
    if tab < 0:
        return SplitRefusal(IcsCode.VALUE_MALFORMED, s^)
    return SplitRefusal(String(s[byte=0:tab]), String(s[byte = tab + 1 : s.byte_length()]))


struct EventProps(Copyable, Movable):
    """Where each read property of one VEVENT is (an index into its
    properties, or -1), the RRULE and EXDATE lines, and the rest."""

    var uid: Int
    var dtstart: Int
    var dtend: Int
    var duration: Int
    var summary: Int
    var description: Int
    var location: Int
    var status: Int
    var recurrence_id: Int
    var rrules: List[Int]
    var exdates: List[Int]
    var others: List[Int]

    def __init__(out self):
        self.uid = -1
        self.dtstart = -1
        self.dtend = -1
        self.duration = -1
        self.summary = -1
        self.description = -1
        self.location = -1
        self.status = -1
        self.recurrence_id = -1
        self.rrules = List[Int]()
        self.exdates = List[Int]()
        self.others = List[Int]()


def _once(mut slot: Int, i: Int, name: String) raises:
    if slot >= 0:
        raise refusal(IcsCode.PROPERTY_REPEATED, name + " appears more than once")
    slot = i


def sort_props(comp: IcsComponent) raises -> EventProps:
    """The properties of the VEVENT `comp`, sorted (module header)."""
    var p = EventProps()
    for i in range(len(comp.properties)):
        ref name = comp.properties[i].line.name
        if name == "UID":
            _once(p.uid, i, name)
        elif name == "DTSTART":
            _once(p.dtstart, i, name)
        elif name == "DTEND":
            _once(p.dtend, i, name)
        elif name == "DURATION":
            _once(p.duration, i, name)
        elif name == "SUMMARY":
            _once(p.summary, i, name)
        elif name == "DESCRIPTION":
            _once(p.description, i, name)
        elif name == "LOCATION":
            _once(p.location, i, name)
        elif name == "STATUS":
            _once(p.status, i, name)
        elif name == "RECURRENCE-ID":
            _once(p.recurrence_id, i, name)
        elif name == "RRULE":
            p.rrules.append(i)
        elif name == "EXDATE":
            p.exdates.append(i)
        elif name != "DTSTAMP":
            p.others.append(i)
    return p^


def param_value(p: IcsProperty, name: String) -> String:
    """The first value of parameter `name` on `p`, or empty."""
    var got = p.line.param(name)
    if not got or len(got.value().values) == 0:
        return String()
    return got.value().values[0].copy()


def time_of(p: IcsProperty) raises -> IcsTime:
    """The DATE or DATE-TIME value of `p`, read with its VALUE and TZID."""
    try:
        return parse_ics_time(p.line.value, param_value(p, "VALUE").upper(), param_value(p, "TZID"))
    except e:
        raise refusal(IcsCode.VALUE_MALFORMED, p.line.name + " " + String(e))


def text_of(comp: IcsComponent, index: Int) -> String:
    """The unescaped TEXT value of property `index`, or empty for -1."""
    if index < 0:
        return String()
    return unescape_text(comp.properties[index].line.value)


def report_params(comp: IcsComponent, index: Int, allowed: List[String], what: String, mut rep: IcsReport):
    """Reports each parameter of property `index` not in `allowed` as
    dropped, named `PROPERTY;PARAMETER`, in component `what`."""
    if index < 0:
        return
    ref p = comp.properties[index]
    for k in range(len(p.line.params)):
        ref name = p.line.params[k].name
        var keep = False
        for a in allowed:
            if a == name:
                keep = True
        if not keep:
            rep.drop(what, p.line.name + ";" + name, String(), p.line_number)


def report_others(comp: IcsComponent, props: EventProps, mut rep: IcsReport):
    """Reports every property the subset does not read as dropped."""
    for i in props.others:
        ref p = comp.properties[i]
        rep.drop(comp.name, p.line.name, String(), p.line_number)
