# =============================================================================
# rrule.mojo -- RRULE text (RFC 5545 §3.3.10) to the calendar's structured
# recurrence rule and back, for the subset the model holds.
# =============================================================================
#
# The subset, in RRULE terms (anything else is refused as out of subset, and
# text that breaks the RFC grammar as malformed):
#   FREQ        DAILY, WEEKLY, MONTHLY or YEARLY
#   INTERVAL    1..999 (absent: 1)
#   COUNT       1..10000, or UNTIL; not both
#   WEEKLY      BYDAY of plain weekdays (no ordinal); absent: the start's
#               weekday. A day named twice counts once.
#   MONTHLY     one of: BYMONTHDAY of one day 1..31; BYDAY of one weekday
#               with ordinal 1..4 or -1 (`2TU`, `-1FR`); BYDAY of one plain
#               weekday with BYSETPOS of one value 1..4 or -1 (the same
#               rule, as some writers spell it); nothing (the start's day
#               of the month).
#   YEARLY      nothing, or BYMONTH of the start's month, optionally with
#               BYMONTHDAY of the start's day (the same rule spelled out)
#   WKST        any weekday; read only where it changes the rule: a WEEKLY
#               rule with INTERVAL above 1 whose days, the start's weekday
#               among them, a week starting on WKST groups differently from
#               a week starting on Monday (the model's weeks start on
#               Monday) is out of subset
# A rule that does not pick the event's first day is out of subset: RFC
# 5545 §3.8.5.3 leaves the recurrence set of a DTSTART "not synchronized
# with the recurrence rule" undefined (§3.3.10 counts DTSTART as the first
# occurrence; the model counts the first day only when the rule picks it).
# The check runs after every other one, so a rule refused for its shape
# carries that reason. `start_is_occurrence` is the same test on the model's
# rule, and `first_occurrence` the first day the model's rule picks, both
# for the export.
# UNTIL is returned as written: its reading needs the event's time zone.
# =============================================================================

from komira_calendar import MAX_COUNT, MAX_INTERVAL
from komira_calendar_proto.calendar import Frequency, Recurrence, Weekday
from komira_datetime import civil_from_days, days_from_civil, days_in_month, weekday_from_days

from .report import IcsCode


struct RuleRead(Copyable, Movable):
    """The result of reading an RRULE: the rule (with `until` empty) and the
    UNTIL text, or a refusal `code` (empty when the rule was read) and
    `message`."""

    var rule: Recurrence
    var until: String
    var code: String
    var message: String

    def __init__(out self, var rule: Recurrence, var until: String):
        self.rule = rule^
        self.until = until^
        self.code = String()
        self.message = String()

    def __init__(out self, *, var code: String, var message: String):
        self.rule = empty_recurrence()
        self.until = String()
        self.code = code^
        self.message = message^

    def ok(self) -> Bool:
        """True when the rule was read."""
        return self.code.byte_length() == 0


def empty_recurrence() -> Recurrence:
    """A recurrence with every field at its zero value."""
    return Recurrence(
        Frequency(Frequency.FREQUENCY_UNSPECIFIED),
        UInt32(0),
        List[Weekday](),
        UInt32(0),
        Int32(0),
        Weekday(Weekday.WEEKDAY_UNSPECIFIED),
        UInt32(0),
        String(),
    )


def _weekday_names() -> List[String]:
    return ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


def _weekday_index(name: String) -> Int:
    """MO..SU to 1..7 (the model's numbering), or 0."""
    var names = _weekday_names()
    for i in range(7):
        if names[i] == name:
            return i + 1
    return 0


def weekday_name(w: Int) -> String:
    """1..7 to MO..SU; empty outside 1..7."""
    if w < 1 or w > 7:
        return String()
    return _weekday_names()[w - 1].copy()


def _number(text: String) -> Int:
    """A run of 1 to 6 ASCII digits as a number, or -1."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 6:
        return -1
    var v = 0
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            return -1
        v = v * 10 + Int(b[i]) - 0x30
    return v


def _signed(text: String) -> Int:
    """An optionally signed number; -1000000 when it is not one."""
    var sign = 1
    var skip = 0
    if text.startswith("+"):
        skip = 1
    elif text.startswith("-"):
        skip = 1
        sign = -1
    var v = _number(String(text[byte = skip : text.byte_length()]))
    if v < 0:
        return -1000000
    return sign * v


@fieldwise_init
struct _ByDay(Copyable, Movable, ImplicitlyCopyable):
    var ordinal: Int  # 0 when none
    var weekday: Int  # 1..7


def _read_byday(item: String) raises -> _ByDay:
    var n = item.byte_length()
    if n < 2:
        raise Error('BYDAY item "' + item + '" is not [+/-][n]weekday')
    var wd = _weekday_index(String(item[byte = n - 2 : n]))
    if wd == 0:
        raise Error('BYDAY item "' + item + '" does not end in MO, TU, WE, TH, FR, SA or SU')
    if n == 2:
        return _ByDay(0, wd)
    var ord = _signed(String(item[byte = 0 : n - 2]))
    if ord == -1000000 or ord == 0 or ord < -53 or ord > 53:
        raise Error('BYDAY item "' + item + '" has an ordinal outside -53..-1 and 1..53')
    return _ByDay(ord, wd)


def _out(message: String) -> RuleRead:
    return RuleRead(code=IcsCode.RRULE_OUT_OF_SUBSET, message=message)


def _bad(message: String) -> RuleRead:
    return RuleRead(code=IcsCode.RRULE_MALFORMED, message=message)


def _monday_index(w: Int) -> Int:
    """1..7 (Monday first) to 0..6 counted from Monday."""
    return w - 1


def _wkst_regroups(days: List[Int], wkst: Int) -> Bool:
    """True when weeks starting on `wkst` group `days` differently from weeks
    starting on Monday: some day falls before `wkst` in a Monday week and
    another on or after it."""
    if wkst == 1:
        return False
    var before = False
    var after = False
    for d in days:
        if _monday_index(d) < _monday_index(wkst):
            before = True
        else:
            after = True
    return before and after


def parse_rrule(text: String, start_day: Int) -> RuleRead:
    """The RRULE `text` of an event whose first local date is `start_day`
    (days since 1970-01-01), read into the subset (module header)."""
    var names = List[String]()
    var values = List[String]()
    for part in text.split(";"):
        var p = String(part)
        if p.byte_length() == 0:
            continue
        var eq = p.find("=")
        if eq <= 0:
            return _bad('RRULE part "' + p + '" is not NAME=VALUE')
        var name = String(p[byte=0:eq]).upper()
        for k in range(len(names)):
            if names[k] == name:
                return _bad("RRULE names " + name + " twice")
        names.append(name)
        values.append(String(p[byte = eq + 1 : p.byte_length()]))

    var freq = Frequency.FREQUENCY_UNSPECIFIED
    var interval = 1
    var count = 0
    var until = String()
    var byday = List[_ByDay]()
    var bymonthday = List[Int]()
    var bymonth = List[Int]()
    var bysetpos = List[Int]()
    var wkst = 1
    for k in range(len(names)):
        ref name = names[k]
        var value = values[k].upper()
        if name == "FREQ":
            if value == "DAILY":
                freq = Frequency.DAILY
            elif value == "WEEKLY":
                freq = Frequency.WEEKLY
            elif value == "MONTHLY":
                freq = Frequency.MONTHLY
            elif value == "YEARLY":
                freq = Frequency.YEARLY
            elif value == "SECONDLY" or value == "MINUTELY" or value == "HOURLY":
                return _out("RRULE FREQ=" + value + " is outside the subset (DAILY, WEEKLY, MONTHLY, YEARLY)")
            else:
                return _bad("RRULE FREQ=" + value + " is not a frequency")
        elif name == "INTERVAL":
            interval = _number(value)
            if interval < 1:
                return _bad("RRULE INTERVAL=" + value + " is not a positive number")
            if interval > MAX_INTERVAL:
                return _out("RRULE INTERVAL=" + value + " is above " + String(MAX_INTERVAL))
        elif name == "COUNT":
            count = _number(value)
            if count < 1:
                return _bad("RRULE COUNT=" + value + " is not a positive number")
            if count > MAX_COUNT:
                return _out("RRULE COUNT=" + value + " is above " + String(MAX_COUNT))
        elif name == "UNTIL":
            until = values[k].copy()
        elif name == "BYDAY":
            for item in value.split(","):
                try:
                    byday.append(_read_byday(String(item)))
                except e:
                    return _bad("RRULE " + String(e))
        elif name == "BYMONTHDAY" or name == "BYMONTH" or name == "BYSETPOS":
            for item in value.split(","):
                var v = _signed(String(item))
                if v == -1000000 or v == 0:
                    return _bad("RRULE " + name + "=" + value + " is not a list of non-zero numbers")
                if name == "BYMONTHDAY":
                    bymonthday.append(v)
                elif name == "BYMONTH":
                    bymonth.append(v)
                else:
                    bysetpos.append(v)
        elif name == "WKST":
            wkst = _weekday_index(value)
            if wkst == 0:
                return _bad("RRULE WKST=" + value + " is not a weekday")
        else:
            return _out("RRULE part " + name + " is outside the subset (FREQ, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, WKST)")

    if freq == Frequency.FREQUENCY_UNSPECIFIED:
        return _bad("RRULE has no FREQ")
    if count > 0 and until.byte_length() > 0:
        return _bad("RRULE has both COUNT and UNTIL")
    var fname = Frequency(freq).json_name()
    var rule = empty_recurrence()
    rule.freq = Frequency(freq)
    rule.interval = UInt32(interval)
    rule.count = UInt32(count)
    var start = civil_from_days(start_day)

    if freq != Frequency.MONTHLY and len(bysetpos) > 0:
        return _out("RRULE BYSETPOS on a " + fname + " rule is outside the subset")
    if freq == Frequency.DAILY:
        if len(byday) > 0 or len(bymonthday) > 0 or len(bymonth) > 0:
            return _out("RRULE BYDAY, BYMONTHDAY or BYMONTH on a DAILY rule is outside the subset")
    elif freq == Frequency.WEEKLY:
        if len(bymonthday) > 0 or len(bymonth) > 0:
            return _out("RRULE BYMONTHDAY or BYMONTH on a WEEKLY rule is outside the subset")
        var days = List[Int]()
        for d in byday:
            if d.ordinal != 0:
                return _bad("RRULE BYDAY on a WEEKLY rule has an ordinal")
            if d.weekday not in days:
                days.append(d.weekday)
        var start_weekday = _model_weekday(start_day)
        if start_weekday not in days:
            days.append(start_weekday)
        if interval > 1 and _wkst_regroups(days, wkst):
            return _out(
                "RRULE WKST=" + weekday_name(wkst)
                + " groups this rule's days into other weeks than a week starting on Monday"
            )
        for d in byday:
            var w = Weekday(d.weekday)
            var seen = False
            for x in rule.weekdays:
                if x.value == w.value:
                    seen = True
            if not seen:
                rule.weekdays.append(w)
    elif freq == Frequency.MONTHLY:
        if len(bymonth) > 0:
            return _out("RRULE BYMONTH on a MONTHLY rule is outside the subset")
        if len(bymonthday) > 0 and len(byday) > 0:
            return _out("RRULE BYMONTHDAY with BYDAY on a MONTHLY rule is outside the subset")
        if len(bymonthday) > 0:
            if len(bymonthday) > 1 or bymonthday[0] < 1 or bymonthday[0] > 31:
                return _out("RRULE BYMONTHDAY on a MONTHLY rule is one day 1..31 in the subset")
            if len(bysetpos) > 0:
                return _out("RRULE BYSETPOS with BYMONTHDAY is outside the subset")
            rule.month_day = UInt32(bymonthday[0])
        elif len(byday) > 0:
            if len(byday) > 1:
                return _out("RRULE BYDAY on a MONTHLY rule is one weekday in the subset")
            var ord = byday[0].ordinal
            if len(bysetpos) > 0:
                if ord != 0 or len(bysetpos) > 1:
                    return _out("RRULE BYSETPOS on a MONTHLY rule is one position for one plain weekday in the subset")
                ord = bysetpos[0]
            elif ord == 0:
                return _out("RRULE BYDAY on a MONTHLY rule needs an ordinal (1..4 or -1) in the subset")
            if ord != -1 and (ord < 1 or ord > 4):
                return _out("RRULE ordinal " + String(ord) + " is outside 1..4 and -1")
            rule.ordinal = Int32(ord)
            rule.ordinal_weekday = Weekday(byday[0].weekday)
        else:
            if len(bysetpos) > 0:
                return _out("RRULE BYSETPOS without BYDAY is outside the subset")
            rule.month_day = UInt32(start.day)
    else:
        if len(byday) > 0:
            return _out("RRULE BYDAY on a YEARLY rule is outside the subset")
        if len(bymonth) > 1 or (len(bymonth) == 1 and bymonth[0] != start.month):
            return _out("RRULE BYMONTH on a YEARLY rule is the start's month in the subset")
        if len(bymonthday) > 1 or (len(bymonthday) == 1 and (bymonthday[0] != start.day or len(bymonth) == 0)):
            return _out("RRULE BYMONTHDAY on a YEARLY rule is the start's day, with BYMONTH, in the subset")
    if not start_is_occurrence(rule, start_day):
        return _out(NOT_AN_OCCURRENCE)
    return RuleRead(rule^, until^)


comptime NOT_AN_OCCURRENCE = "DTSTART is not an occurrence of its RRULE; RFC 5545 leaves such a recurrence set undefined"
"""The refusal of a rule that does not pick its event's first day."""


def _model_weekday(day: Int) -> Int:
    """The weekday of `day` (days since 1970-01-01) as 1..7, Monday first."""
    return (weekday_from_days(day) + 6) % 7 + 1


def start_is_occurrence(rule: Recurrence, start_day: Int) -> Bool:
    """True when the model's `rule` picks `start_day`, the event's first
    local date (days since 1970-01-01): every DAILY and YEARLY rule (a
    YEARLY rule is the start's month and day); a WEEKLY rule naming the
    start's weekday, or naming none; a MONTHLY rule on the start's day of
    the month, or on the ordinal weekday the start is."""
    var weekday = _model_weekday(start_day)
    var f = rule.freq.value
    if f == Frequency.WEEKLY:
        if len(rule.weekdays) == 0:
            return True
        for w in rule.weekdays:
            if Int(w.value) == weekday:
                return True
        return False
    if f != Frequency.MONTHLY:
        return True
    var c = civil_from_days(start_day)
    if rule.ordinal == 0:
        return rule.month_day == 0 or Int(rule.month_day) == c.day
    if Int(rule.ordinal_weekday.value) != weekday:
        return False
    if rule.ordinal < 0:
        return c.day + 7 * Int(-rule.ordinal) > days_in_month(c.year, c.month) and c.day + 7 * (Int(-rule.ordinal) - 1) <= days_in_month(c.year, c.month)
    return (c.day - 1) // 7 + 1 == Int(rule.ordinal)


def _monthly_pick(rule: Recurrence, year: Int, month: Int) -> Optional[Int]:
    """The day (days since 1970-01-01) a MONTHLY `rule` picks in `month` of
    `year`; none when the month is shorter than its day of the month."""
    var dim = days_in_month(year, month)
    if rule.ordinal == 0:
        if Int(rule.month_day) > dim:
            return None
        return days_from_civil(year, month, Int(rule.month_day))
    var w = Int(rule.ordinal_weekday.value)
    if rule.ordinal < 0:
        var last = days_from_civil(year, month, dim)
        return last - (_model_weekday(last) - w + 7) % 7
    var first = days_from_civil(year, month, 1)
    return first + (w - _model_weekday(first) + 7) % 7 + 7 * (Int(rule.ordinal) - 1)


def first_occurrence(rule: Recurrence, start_day: Int, until_day: Int) -> Optional[Int]:
    """The first day on or after `start_day` and on or before `until_day`
    that the model's `rule` picks, or none. Days count from 1970-01-01 and
    are negative before it. The model (komira_calendar) cuts a series into
    Monday weeks or months, counts every `interval`-th one from the one
    holding `start_day`, and never picks a day before `start_day`; so a
    series started on the day this returns has the same occurrences as one
    started on `start_day`."""
    if start_is_occurrence(rule, start_day):
        if start_day <= until_day:
            return start_day
        return None
    var f = rule.freq.value
    var step = Int(rule.interval)
    if f == Frequency.WEEKLY:
        var weekday = _model_weekday(start_day)
        var later = 8
        var earliest = 8
        for w in rule.weekdays:
            var d = Int(w.value)
            if d < earliest:
                earliest = d
            if d > weekday and d < later:
                later = d
        var monday = start_day - (weekday - 1)
        var day = monday + later - 1 if later < 8 else monday + 7 * step + earliest - 1
        if day <= until_day:
            return day
        return None
    # MONTHLY: start_is_occurrence holds for every DAILY and YEARLY rule.
    var c = civil_from_days(start_day)
    var month = c.year * 12 + c.month - 1
    while True:
        var y = month // 12
        var m = month % 12 + 1
        # A rule that picks no day in any month it reaches (the 30th, every
        # 12 months from a February) ends here.
        if days_from_civil(y, m, 1) > until_day:
            return None
        var pick = _monthly_pick(rule, y, m)
        if pick:
            var day = pick.value()
            if day > until_day:
                return None
            if day >= start_day:
                return day
        month += step


def format_rrule(rule: Recurrence, until: String) -> String:
    """The RRULE text of `rule`, which `komira_calendar.check_recurrence`
    accepts; `until` is the UNTIL value already in iCalendar form (or
    empty). INTERVAL is written when above 1."""
    var out = "FREQ=" + rule.freq.json_name()
    if rule.interval > 1:
        out += ";INTERVAL=" + String(rule.interval)
    if len(rule.weekdays) > 0:
        out += ";BYDAY="
        for i in range(len(rule.weekdays)):
            if i > 0:
                out += ","
            out += weekday_name(rule.weekdays[i].value)
    if rule.month_day > 0:
        out += ";BYMONTHDAY=" + String(rule.month_day)
    if rule.ordinal != 0:
        out += ";BYDAY=" + String(rule.ordinal) + weekday_name(rule.ordinal_weekday.value)
    if rule.count > 0:
        out += ";COUNT=" + String(rule.count)
    if until.byte_length() > 0:
        out += ";UNTIL=" + until
    return out^
