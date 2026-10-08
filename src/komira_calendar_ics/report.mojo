# =============================================================================
# report.mojo -- what an import refused and what it dropped.
# =============================================================================
#
# An import keeps what the calendar model can hold and reports the rest, so
# nothing is lost without a line in the report:
#   - `refused`: a component that was not imported (an event, an occurrence
#     edit, or a component outside the subset), with a stable code, the line
#     of its BEGIN, its UID when it has one, and a sentence;
#   - `dropped`: a property, parameter or value that was not kept on an
#     imported event, counted per (component, name, detail) with the first
#     line it was seen on. Past `MAX_DROPPED_KINDS` distinct kinds, every
#     further kind is counted in one more entry, `* *` with the detail
#     `OVERFLOW_DETAIL`, so a file of many distinct property names cannot
#     make the report as large as the file.
# A refused event's own properties are not reported as dropped.
# Recording a drop is one dictionary lookup, and merging adds counts, so a
# report costs time in proportion to what is recorded.
# =============================================================================

from std.collections import Dict

comptime MAX_DROPPED_KINDS = 256
"""The distinct (component, name, detail) entries a report itemises."""

comptime OVERFLOW_DETAIL = "past the first 256 kinds of dropped item, not itemised"
"""The detail of the entry that counts every kind past `MAX_DROPPED_KINDS`."""


struct IcsCode:
    """The refusal codes of the import. A refused event that breaks the
    calendar model carries `komira_calendar`'s `RefusalCode` instead."""

    comptime COMPONENT_OUT_OF_SUBSET = "COMPONENT_OUT_OF_SUBSET"
    comptime UID_MISSING = "UID_MISSING"
    comptime UID_DUPLICATE = "UID_DUPLICATE"
    comptime PROPERTY_REPEATED = "PROPERTY_REPEATED"
    comptime DTSTART_MISSING = "DTSTART_MISSING"
    comptime VALUE_MALFORMED = "VALUE_MALFORMED"
    comptime FLOATING_TIME = "FLOATING_TIME"
    comptime UNKNOWN_TZID = "UNKNOWN_TZID"
    comptime END_AND_DURATION = "END_AND_DURATION"
    comptime FORM_MISMATCH = "FORM_MISMATCH"
    comptime NOT_AFTER_START = "NOT_AFTER_START"
    comptime RRULE_OUT_OF_SUBSET = "RRULE_OUT_OF_SUBSET"
    comptime RRULE_MALFORMED = "RRULE_MALFORMED"
    comptime RANGE_OUT_OF_SUBSET = "RANGE_OUT_OF_SUBSET"
    comptime OVERRIDE_WITHOUT_SERIES = "OVERRIDE_WITHOUT_SERIES"
    comptime OVERRIDE_DUPLICATE = "OVERRIDE_DUPLICATE"


@fieldwise_init
struct IcsRefusal(Copyable, Movable, Writable):
    """A component the import did not keep: `code`, the line of its BEGIN,
    its UID (empty when it has none) and why."""

    var code: String
    var line: Int
    var uid: String
    var message: String

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.code, " at line ", self.line, ' (UID "', self.uid, '"): ', self.message)


@fieldwise_init
struct IcsDropped(Copyable, Movable, Writable):
    """Something an imported event did not keep: the component it was in
    (`VCALENDAR`, `VEVENT`, `VALARM`), its name (a property, or
    `PROPERTY;PARAMETER`), a detail when only part of it was lost (empty
    when all of it was), how many times, and the first line."""

    var component: String
    var name: String
    var detail: String
    var count: Int
    var first_line: Int

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.component, " ", self.name)
        if self.detail.byte_length() > 0:
            writer.write(" (", self.detail, ")")
        writer.write(" x", self.count, " from line ", self.first_line)


struct IcsReport(Copyable, Movable):
    """The refusals and the dropped items of one import, in input order."""

    var refused: List[IcsRefusal]
    var dropped: List[IcsDropped]
    var _index: Dict[String, Int]

    def __init__(out self):
        self.refused = List[IcsRefusal]()
        self.dropped = List[IcsDropped]()
        self._index = Dict[String, Int]()

    def refuse(mut self, code: String, line: Int, uid: String, message: String):
        """Records a refused component."""
        self.refused.append(IcsRefusal(code.copy(), line, uid.copy(), message.copy()))

    def drop(mut self, component: String, name: String, detail: String, line: Int):
        """Records one dropped item, counted with the earlier ones of the same
        component, name and detail (module header)."""
        self._add(component, name, detail, 1, line)

    def _add(mut self, component: String, name: String, detail: String, count: Int, line: Int):
        var key = _key(component, name, detail)
        var at = self._index.get(key)
        if not at and len(self.dropped) >= MAX_DROPPED_KINDS:
            key = _key("*", "*", OVERFLOW_DETAIL)
            at = self._index.get(key)
            if not at:
                self._index[key] = len(self.dropped)
                self.dropped.append(IcsDropped("*", "*", OVERFLOW_DETAIL, count, line))
                return
        if at:
            ref d = self.dropped[at.value()]
            d.count += count
            if line < d.first_line:
                d.first_line = line
            return
        self._index[key] = len(self.dropped)
        self.dropped.append(IcsDropped(component.copy(), name.copy(), detail.copy(), count, line))

    def merge(mut self, other: IcsReport):
        """Adds `other`'s items to this report, each dropped entry's count at
        once."""
        for i in range(len(other.refused)):
            self.refused.append(other.refused[i].copy())
        for i in range(len(other.dropped)):
            ref d = other.dropped[i]
            self._add(d.component, d.name, d.detail, d.count, d.first_line)

    def is_clean(self) -> Bool:
        """True when nothing was refused or dropped."""
        return len(self.refused) == 0 and len(self.dropped) == 0


def _key(component: String, name: String, detail: String) -> String:
    """One dictionary key for (component, name, detail): each part with its
    length first, so no two triples share a key."""
    return (
        String(component.byte_length()) + ":" + component + String(name.byte_length()) + ":" + name + detail
    )
