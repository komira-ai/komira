"""A structured recurrence rule resolved for expansion, and its periods.

A series is cut into periods: one day (DAILY), one Monday-to-Sunday week
(WEEKLY), one month (MONTHLY) or one year (YEARLY). Period `k` is the
`k * interval`-th period after the one holding the first day. Each period
holds the days the rule picks in it:

  DAILY    the period's day
  WEEKLY   the named weekdays of the week, else the first day's weekday
  MONTHLY  day `month_day` of the month, skipped when the month is shorter;
           or the `ordinal`-th `ordinal_weekday` (-1: the last one)
  YEARLY   the first day's month and day, skipped when the year has no such
           day (29 February in a common year)

A day before the series' first day is never picked. A series without
`until` ends on 9999-12-31 (LAST_DAY): a local date has four year digits.
All arithmetic is on local dates (days since 1970-01-01); no zone is consulted.
"""

from komira_calendar_proto.calendar import Frequency, Recurrence
from komira_datetime import civil_from_days, days_from_civil, days_in_month

from .local_time import parse_local_date


# 9999-12-31 as a day count since 1970-01-01.
comptime LAST_DAY = 2932896


@always_inline
def iso_weekday(day: Int) -> Int:
    """The ISO weekday of a day count: Monday is 1, Sunday 7 (1970-01-01 was
    a Thursday)."""
    return (day + 3) % 7 + 1


@fieldwise_init
struct ResolvedRule(Copyable, Movable, ImplicitlyCopyable):
    """A validated `Recurrence` with its text read and its anchors computed.
    `until_day` is the last day an occurrence may fall on: the `until` date,
    or LAST_DAY when the rule names none. `count` is 0 when it names none."""

    var freq: Int
    var interval: Int
    var first_day: Int
    # Bit `w` set: ISO weekday `w` (1..7) is picked by a WEEKLY rule.
    var weekday_mask: Int
    var month_day: Int
    var ordinal: Int
    var ordinal_weekday: Int
    var count: Int
    var until_day: Int
    # The first day's month as year * 12 + (month - 1).
    var first_month: Int
    var first_year: Int
    var first_month_of_year: Int
    var first_day_of_month: Int
    # The Monday of the first day's week.
    var first_monday: Int


def resolve_rule(rule: Recurrence, first_day: Int) raises -> ResolvedRule:
    """`rule`, already accepted by `check_recurrence`, resolved against the
    series' first day. Raises only when `until` is not a local date."""
    var mask = 0
    for i in range(len(rule.weekdays)):
        mask |= 1 << Int(rule.weekdays[i].value)
    if mask == 0:
        mask = 1 << iso_weekday(first_day)
    var until_day = LAST_DAY
    if rule.until.byte_length() > 0:
        until_day = parse_local_date(rule.until)
    var c = civil_from_days(first_day)
    return ResolvedRule(
        freq=Int(rule.freq.value),
        interval=Int(rule.interval),
        first_day=first_day,
        weekday_mask=mask,
        month_day=Int(rule.month_day),
        ordinal=Int(rule.ordinal),
        ordinal_weekday=Int(rule.ordinal_weekday.value),
        count=Int(rule.count),
        until_day=until_day,
        first_month=c.year * 12 + (c.month - 1),
        first_year=c.year,
        first_month_of_year=c.month,
        first_day_of_month=c.day,
        first_monday=first_day - (iso_weekday(first_day) - 1),
    )


def period_first_day(r: ResolvedRule, k: Int) -> Int:
    """The first day of period `k` (the period's day, Monday, 1st of the
    month, or 1 January)."""
    if r.freq == Frequency.DAILY:
        return r.first_day + k * r.interval
    if r.freq == Frequency.WEEKLY:
        return r.first_monday + 7 * k * r.interval
    if r.freq == Frequency.MONTHLY:
        var m = r.first_month + k * r.interval
        return days_from_civil(m // 12, m % 12 + 1, 1)
    return days_from_civil(r.first_year + k * r.interval, 1, 1)


def period_at(r: ResolvedRule, day: Int) -> Int:
    """The last period whose first day is on or before `day`, or 0 when
    `day` is before period 0. Every day a period before it picks is before
    `day`."""
    if day <= r.first_day:
        return 0
    if r.freq == Frequency.DAILY:
        return (day - r.first_day) // r.interval
    if r.freq == Frequency.WEEKLY:
        return (day - r.first_monday) // (7 * r.interval)
    var c = civil_from_days(day)
    if r.freq == Frequency.MONTHLY:
        return (c.year * 12 + (c.month - 1) - r.first_month) // r.interval
    return (c.year - r.first_year) // r.interval


def _nth_weekday(year: Int, month: Int, ordinal: Int, weekday: Int) -> Int:
    """The day count of the `ordinal`-th ISO `weekday` of the month, the last
    one when `ordinal` is -1. `ordinal` is 1 to 4 or -1, so the day exists."""
    if ordinal == -1:
        var last = days_from_civil(year, month, days_in_month(year, month))
        return last - (iso_weekday(last) - weekday + 7) % 7
    var first = days_from_civil(year, month, 1)
    return first + (weekday - iso_weekday(first) + 7) % 7 + (ordinal - 1) * 7


def period_days(r: ResolvedRule, k: Int, mut out: List[Int]):
    """Replace `out` with the days period `k` picks, ascending, none before
    the first day. `until_day` and `count` are the caller's to apply."""
    out.clear()
    if r.freq == Frequency.DAILY:
        out.append(r.first_day + k * r.interval)
    elif r.freq == Frequency.WEEKLY:
        var monday = r.first_monday + 7 * k * r.interval
        for w in range(1, 8):
            if r.weekday_mask & (1 << w) != 0:
                out.append(monday + w - 1)
    elif r.freq == Frequency.MONTHLY:
        var m = r.first_month + k * r.interval
        var year = m // 12
        var month = m % 12 + 1
        if r.month_day != 0:
            if r.month_day <= days_in_month(year, month):
                out.append(days_from_civil(year, month, r.month_day))
        else:
            out.append(_nth_weekday(year, month, r.ordinal, r.ordinal_weekday))
    else:
        var year = r.first_year + k * r.interval
        if r.first_day_of_month <= days_in_month(year, r.first_month_of_year):
            out.append(days_from_civil(year, r.first_month_of_year, r.first_day_of_month))
    var kept = 0
    for i in range(len(out)):
        if out[i] >= r.first_day:
            out[kept] = out[i]
            kept += 1
    while len(out) > kept:
        _ = out.pop()
