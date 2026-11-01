"""Validation of a structured recurrence rule (`Recurrence`).

The rule is the subset a consumer calendar's "custom repeat" offers: a
frequency and an interval; for WEEKLY a set of weekdays; for MONTHLY one day
of the month or one ordinal weekday; an end by count, by date, or none.
Expansion is not here.
"""

from std.collections import Set

from komira_calendar_proto.calendar import Frequency, Recurrence, Weekday

from .limits import MAX_COUNT, MAX_INTERVAL
from .local_time import parse_local_date
from .refusal import Refusal, RefusalCode


def _refuse(code: String, field: String, message: String) -> Optional[Refusal]:
    return Optional[Refusal](Refusal(code, "recurrence." + field, message))


def _known_weekday(w: Weekday) -> Bool:
    return w.value >= Weekday.MONDAY and w.value <= Weekday.SUNDAY


def check_recurrence(rule: Recurrence, start_day: Int) -> Optional[Refusal]:
    """The first rule `rule` breaks, or None. `start_day` is the event's first
    local date as a day count since 1970-01-01 (an `until` before it is
    refused)."""
    var freq = rule.freq.value
    if freq == Frequency.FREQUENCY_UNSPECIFIED:
        return _refuse(
            RefusalCode.FREQUENCY_REQUIRED,
            "freq",
            "a recurrence needs freq: DAILY, WEEKLY, MONTHLY or YEARLY",
        )
    if freq < Frequency.DAILY or freq > Frequency.YEARLY:
        return _refuse(
            RefusalCode.FREQUENCY_UNKNOWN,
            "freq",
            "freq " + String(freq) + " is not DAILY, WEEKLY, MONTHLY or YEARLY",
        )
    if rule.interval < 1 or Int(rule.interval) > MAX_INTERVAL:
        return _refuse(
            RefusalCode.INTERVAL_OUT_OF_RANGE,
            "interval",
            "interval " + String(rule.interval) + " is outside 1.." + String(MAX_INTERVAL),
        )

    if len(rule.weekdays) > 0 and freq != Frequency.WEEKLY:
        return _refuse(
            RefusalCode.WEEKDAYS_NOT_WEEKLY,
            "weekdays",
            "weekdays apply to a WEEKLY rule only",
        )
    var seen = Set[Int]()
    for i in range(len(rule.weekdays)):
        var w = rule.weekdays[i]
        var at = "weekdays[" + String(i) + "]"
        if not _known_weekday(w):
            return _refuse(
                RefusalCode.WEEKDAY_UNKNOWN,
                at,
                "weekday " + String(w.value) + " is not MONDAY..SUNDAY",
            )
        if w.value in seen:
            return _refuse(
                RefusalCode.WEEKDAY_DUPLICATE,
                at,
                w.json_name() + " is named twice",
            )
        seen.add(w.value)

    var has_day = rule.month_day != 0
    var has_ordinal = rule.ordinal != 0 or rule.ordinal_weekday.value != 0
    if freq == Frequency.MONTHLY:
        if has_day and has_ordinal:
            return _refuse(
                RefusalCode.MONTHLY_RULE_AMBIGUOUS,
                "monthDay",
                "a MONTHLY rule names monthDay or ordinal with ordinalWeekday, not both",
            )
        if not has_day and not has_ordinal:
            return _refuse(
                RefusalCode.MONTHLY_RULE_REQUIRED,
                "monthDay",
                "a MONTHLY rule names monthDay, or ordinal with ordinalWeekday",
            )
        if has_day and rule.month_day > 31:
            return _refuse(
                RefusalCode.MONTH_DAY_OUT_OF_RANGE,
                "monthDay",
                "monthDay " + String(rule.month_day) + " is outside 1..31",
            )
        if has_ordinal:
            if rule.ordinal == 0:
                return _refuse(
                    RefusalCode.ORDINAL_REQUIRED,
                    "ordinal",
                    "ordinalWeekday needs an ordinal: 1 to 4, or -1 for the last",
                )
            if rule.ordinal != -1 and (rule.ordinal < 1 or rule.ordinal > 4):
                return _refuse(
                    RefusalCode.ORDINAL_OUT_OF_RANGE,
                    "ordinal",
                    "ordinal " + String(rule.ordinal) + " is not 1 to 4, or -1 for the last",
                )
            if rule.ordinal_weekday.value == Weekday.WEEKDAY_UNSPECIFIED:
                return _refuse(
                    RefusalCode.ORDINAL_WEEKDAY_REQUIRED,
                    "ordinalWeekday",
                    "an ordinal needs ordinalWeekday",
                )
            if not _known_weekday(rule.ordinal_weekday):
                return _refuse(
                    RefusalCode.WEEKDAY_UNKNOWN,
                    "ordinalWeekday",
                    "weekday " + String(rule.ordinal_weekday.value) + " is not MONDAY..SUNDAY",
                )
    elif has_day or has_ordinal:
        var which = "monthDay" if has_day else ("ordinal" if rule.ordinal != 0 else "ordinalWeekday")
        return _refuse(
            RefusalCode.MONTHLY_FIELDS_NOT_MONTHLY,
            which,
            which + " applies to a MONTHLY rule only",
        )

    var has_until = rule.until.byte_length() > 0
    if rule.count != 0 and has_until:
        return _refuse(
            RefusalCode.COUNT_WITH_UNTIL,
            "count",
            "a recurrence ends by count or by until, not both",
        )
    if Int(rule.count) > MAX_COUNT:
        return _refuse(
            RefusalCode.COUNT_OUT_OF_RANGE,
            "count",
            "count " + String(rule.count) + " is above " + String(MAX_COUNT),
        )
    if has_until:
        var until_day: Int
        try:
            until_day = parse_local_date(rule.until)
        except e:
            return _refuse(
                RefusalCode.UNTIL_MALFORMED,
                "until",
                "until is not a local date (YYYY-MM-DD): " + String(e),
            )
        if until_day < start_day:
            return _refuse(
                RefusalCode.UNTIL_BEFORE_START,
                "until",
                "until " + rule.until + " is before the event's first day",
            )
    return None
