# =============================================================================
# tree.mojo -- an iCalendar stream to its components (RFC 5545 §3.4, §3.6).
# =============================================================================
#
# `read_components` unfolds and lexes the input (`komira_content_line`: the
# input and line limits, UTF-8 validation, RFC 6868 parameter values), then
# pairs BEGIN with END. Component names are case-insensitive and kept upper
# case. The input is exactly one VCALENDAR: anything before its BEGIN, after
# its END, an END that closes nothing or the wrong component, a BEGIN with no
# END, nesting deeper than `MAX_DEPTH`, and component number
# `max_components + 1` are refused with the line they are on. Components
# are returned in BEGIN order; index 0 is the VCALENDAR.
# =============================================================================

from komira_content_line import (
    ContentLimits,
    ContentLine,
    DEFAULT_MAX_INPUT_OCTETS,
    DEFAULT_MAX_LINE_OCTETS,
    parse_content_line,
    unfold,
)

# VCALENDAR > VEVENT > VALARM is three deep, VCALENDAR > VTIMEZONE > STANDARD
# is three; a component outside the subset may nest a little deeper.
comptime MAX_DEPTH = 8
comptime DEFAULT_MAX_COMPONENTS = 50000


struct IcsLimits(Copyable, Movable):
    """Bounds on one import: input octets, unfolded line octets, and the
    number of components (each VEVENT, VALARM, VTIMEZONE and observance
    counts one)."""

    var max_input_octets: Int
    var max_line_octets: Int
    var max_components: Int

    def __init__(
        out self,
        *,
        max_input_octets: Int = DEFAULT_MAX_INPUT_OCTETS,
        max_line_octets: Int = DEFAULT_MAX_LINE_OCTETS,
        max_components: Int = DEFAULT_MAX_COMPONENTS,
    ):
        self.max_input_octets = max_input_octets
        self.max_line_octets = max_line_octets
        self.max_components = max_components


struct IcsProperty(Copyable, Movable):
    """One property line of a component, lexed, and its first physical line."""

    var line: ContentLine
    var line_number: Int

    def __init__(out self, var line: ContentLine, line_number: Int):
        self.line = line^
        self.line_number = line_number


struct IcsComponent(Copyable, Movable):
    """One component: its name, the line of its BEGIN, its properties in
    order, and the indexes of its child components."""

    var name: String
    var begin_line: Int
    var properties: List[IcsProperty]
    var children: List[Int]

    def __init__(out self, var name: String, begin_line: Int):
        self.name = name^
        self.begin_line = begin_line
        self.properties = List[IcsProperty]()
        self.children = List[Int]()


def _at(n: Int) -> String:
    return "ics: line " + String(n) + ": "


def read_components(data: Span[UInt8, _], limits: IcsLimits) raises -> List[IcsComponent]:
    """The components of `data` (module header)."""
    var lines = unfold(
        data,
        ContentLimits(max_input_octets=limits.max_input_octets, max_line_octets=limits.max_line_octets),
    )
    var comps = List[IcsComponent]()
    var stack = List[Int]()
    for k in range(len(lines)):
        var n = lines[k].line_number
        var cl = parse_content_line(lines[k].text, n)
        if cl.name == "BEGIN":
            var name = cl.value.upper()
            if len(stack) == 0:
                if len(comps) > 0:
                    raise Error(_at(n) + "BEGIN:" + name + " after the END of the VCALENDAR; an input holds one VCALENDAR")
                if name != "VCALENDAR":
                    raise Error(_at(n) + "the input starts with BEGIN:" + name + ", not BEGIN:VCALENDAR")
            if len(stack) >= MAX_DEPTH:
                raise Error(_at(n) + "BEGIN:" + name + " nests deeper than " + String(MAX_DEPTH) + " components")
            if len(comps) >= limits.max_components:
                raise Error(_at(n) + "more than " + String(limits.max_components) + " components")
            var index = len(comps)
            if len(stack) > 0:
                comps[stack[len(stack) - 1]].children.append(index)
            comps.append(IcsComponent(name^, n))
            stack.append(index)
        elif cl.name == "END":
            var name = cl.value.upper()
            if len(stack) == 0:
                raise Error(_at(n) + "END:" + name + " closes no component")
            var top = stack[len(stack) - 1]
            if comps[top].name != name:
                raise Error(
                    _at(n) + "END:" + name + " closes BEGIN:" + comps[top].name
                    + " of line " + String(comps[top].begin_line)
                )
            _ = stack.pop()
        else:
            if len(stack) == 0:
                if len(comps) == 0:
                    raise Error(_at(n) + "property " + cl.name + " before BEGIN:VCALENDAR")
                raise Error(_at(n) + "property " + cl.name + " after the END of the VCALENDAR")
            comps[stack[len(stack) - 1]].properties.append(IcsProperty(cl^, n))
    if len(stack) > 0:
        var top = stack[len(stack) - 1]
        raise Error(
            "ics: BEGIN:" + comps[top].name + " of line " + String(comps[top].begin_line)
            + " has no END:" + comps[top].name
        )
    if len(comps) == 0:
        raise Error("ics: the input holds no BEGIN:VCALENDAR")
    return comps^
