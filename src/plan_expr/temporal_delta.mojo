# =============================================================================
# temporal_delta — `date_diff(unit, a, b)` and `date_sub(unit, a, b)` built
# from the nodes the engine has (extract, date_trunc, casts, arithmetic,
# comparisons, CASE)
# =============================================================================
#
# DuckDB's two temporal deltas count different things:
#
#   date_diff  the unit BOUNDARIES crossed going from a to b: the difference
#              of the two values truncated to the unit (for 'week', the day
#              difference divided by 7, truncated toward zero);
#   date_sub   the COMPLETE units elapsed from a to b, truncated toward zero;
#              'month', 'quarter' and 'year' count calendar months, where a
#              b on the last day of its month completes a month that started
#              on a later day of the month (2024-01-31 -> 2024-02-29 is one
#              month).
#
# Both take two DATEs or two TIMESTAMPs (microseconds, no time zone); a DATE
# is midnight. The formulas below were checked against the pinned DuckDB
# (v1.5.6) over 62880 timestamp pairs, half of them within a day of each
# other, either side of the epoch and across the year range ±1300, with
# every unit, and over a sweep of month ends; the cases in
# src/tests/conformance/komira_sql_conformance/cases/scalar_fn hold the
# engine to it.
#
# ⚠ NO INTEGER DIVISION. The two executors disagree on it (the interpreter
# floors, the column path divides in Float64), so every count here is built
# from extracts and exact arithmetic. The two divisions that remain are of a
# Float64 by a constant: `_exact_quotient` divides a difference of two
# values truncated to the day by the microseconds of a day, which is an
# exact multiple, so the quotient is exact for every TIMESTAMP's range; and
# `_trunc_quotient` divides a day count by 7 and truncates, where the
# nearest float to n/7 is never on the other side of an integer for any day
# count a TIMESTAMP holds. Both end in a cast to BIGINT of an integral float.
#
# NULL: every expression is an extract, a cast or arithmetic of the operands,
# or a CASE whose conditions are NULL for a NULL operand, so it reaches the
# ELSE, which is the operand arithmetic again: a NULL operand answers NULL.
# =============================================================================

from plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV,
    BIN_EQ, BIN_LT, BIN_LE, BIN_GE,
    BIN_AND, BIN_OR,
    UN_NOT, UN_TRUNC,
    EXTRACT_YEAR, EXTRACT_QUARTER, EXTRACT_MONTH, EXTRACT_DAY,
    EXTRACT_HOUR, EXTRACT_MINUTE, EXTRACT_SECOND, EXTRACT_MILLISECOND,
    EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY, EXTRACT_TRUNC_HOUR,
    EXTRACT_TRUNC_MINUTE, EXTRACT_TRUNC_SECOND, EXTRACT_TRUNC_MILLISECOND,
    EXTRACT_TRUNC_MICROSECOND,
)
from plan_expr.scalar_desugar import days_in_month_of
from plan_expr.scalar_value import ScalarValue

comptime _US_PER_DAY: Int64 = 86_400_000_000


def _lit(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _ex(unit: UInt8, x: Expr) -> Expr:
    return Expr.extract(unit, x.copy())


def _i64(x: Expr) -> Expr:
    """A TIMESTAMP's microseconds from the epoch, a DATE's days."""
    return Expr.cast(x.copy(), DType.int64)


def _field_diff(unit: UInt8, a: Expr, b: Expr) -> Expr:
    """`extract(unit, b) - extract(unit, a)`."""
    return _bin(BIN_SUB, _ex(unit, b), _ex(unit, a))


def _exact_quotient(var x: Expr, d: Int64) -> Expr:
    """`x / d` for an `x` that is an exact multiple of `d`, as BIGINT."""
    var q = _bin(
        BIN_DIV,
        Expr.cast(x^, DType.float64),
        Expr.literal(ScalarValue.from_float(Float64(d))),
    )
    return Expr.cast(q^, DType.int64)


def _trunc_quotient(var x: Expr, d: Int64) -> Expr:
    """`x / d` truncated toward zero, for a small `d` and an `x` a day count."""
    var q = _bin(
        BIN_DIV,
        Expr.cast(x^, DType.float64),
        Expr.literal(ScalarValue.from_float(Float64(d))),
    )
    return Expr.cast(Expr.unary(UN_TRUNC, q^), DType.int64)


def _day_diff(a: Expr, b: Expr, is_date: Bool) -> Expr:
    """The days between the dates of `a` and `b` (boundaries crossed)."""
    if is_date:
        return _bin(BIN_SUB, _i64(b), _i64(a))
    var tb = _i64(Expr.date_trunc(EXTRACT_TRUNC_DAY, b.copy()))
    var ta = _i64(Expr.date_trunc(EXTRACT_TRUNC_DAY, a.copy()))
    return _exact_quotient(_bin(BIN_SUB, tb^, ta^), _US_PER_DAY)


def _scaled_plus(var base: Expr, k: Int64, unit: UInt8, a: Expr, b: Expr, is_date: Bool) -> Expr:
    """`base * k + (extract(unit, b) - extract(unit, a))`; a DATE has no
    field below the day, so over DATEs only `base * k`."""
    var scaled = _bin(BIN_MUL, base^, _lit(k))
    if is_date:
        return scaled^
    return _bin(BIN_ADD, scaled^, _field_diff(unit, a, b))


def _month_diff(a: Expr, b: Expr) -> Expr:
    return _bin(
        BIN_ADD,
        _bin(BIN_MUL, _field_diff(EXTRACT_YEAR, a, b), _lit(12)),
        _field_diff(EXTRACT_MONTH, a, b),
    )


def _quarter_diff(a: Expr, b: Expr) -> Expr:
    return _bin(
        BIN_ADD,
        _bin(BIN_MUL, _field_diff(EXTRACT_YEAR, a, b), _lit(4)),
        _field_diff(EXTRACT_QUARTER, a, b),
    )


def date_diff_of(unit: UInt8, a: Expr, b: Expr, is_date: Bool) raises -> Expr:
    """`date_diff(unit, a, b)`: the `unit` boundaries crossed from `a` to
    `b`. `unit` is an `EXTRACT_TRUNC_*` period; `is_date` says both operands
    are DATEs (else both are TIMESTAMPs in microseconds).

        year      year(b) - year(a)
        quarter   4 * (year diff) + quarter(b) - quarter(a)
        month     12 * (year diff) + month(b) - month(a)
        week      trunc(day / 7)
        day       the difference of the two days from the epoch
        hour      24 * day + hour(b) - hour(a)
        minute    60 * hour + minute(b) - minute(a)
        second    60 * minute + second(b) - second(a)
        ms        60000 * minute + millisecond(b) - millisecond(a)
        us        b - a in microseconds

    Raises:
        On a unit outside that list (the binder refuses those first).
    """
    if unit == EXTRACT_TRUNC_YEAR:
        return _field_diff(EXTRACT_YEAR, a, b)
    if unit == EXTRACT_TRUNC_QUARTER:
        return _quarter_diff(a, b)
    if unit == EXTRACT_TRUNC_MONTH:
        return _month_diff(a, b)
    var day = _day_diff(a, b, is_date)
    if unit == EXTRACT_TRUNC_MICROSECOND:
        if is_date:
            return _bin(BIN_MUL, day^, _lit(_US_PER_DAY))
        return _bin(BIN_SUB, _i64(b), _i64(a))
    if unit == EXTRACT_TRUNC_WEEK:
        return _trunc_quotient(day^, 7)
    if unit == EXTRACT_TRUNC_DAY:
        return day^
    var hour = _scaled_plus(day^, 24, EXTRACT_HOUR, a, b, is_date)
    if unit == EXTRACT_TRUNC_HOUR:
        return hour^
    var minute = _scaled_plus(hour^, 60, EXTRACT_MINUTE, a, b, is_date)
    if unit == EXTRACT_TRUNC_MINUTE:
        return minute^
    if unit == EXTRACT_TRUNC_SECOND:
        return _scaled_plus(minute^, 60, EXTRACT_SECOND, a, b, is_date)
    if unit == EXTRACT_TRUNC_MILLISECOND:
        # EXTRACT_MILLISECOND is DuckDB's: the second's milliseconds with
        # the seconds of the minute folded in (0 to 59999).
        return _scaled_plus(minute^, 60000, EXTRACT_MILLISECOND, a, b, is_date)
    raise Error("temporal_delta: date_diff has no unit " + String(Int(unit)))


def _rem(unit: UInt8, x: Expr) -> Expr:
    """Microseconds of TIMESTAMP `x` past its start of `unit`."""
    return _bin(BIN_SUB, _i64(x), _i64(Expr.date_trunc(unit, x.copy())))


def _forward(a: Expr, b: Expr, is_date: Bool) -> Expr:
    """`b >= a`."""
    return _bin(BIN_GE, _i64(b), _i64(a))


def _adjusted(var diff: Expr, var forward: Expr, var short_fwd: Expr, var short_back: Expr) -> Expr:
    """`diff - 1` when going forward a last unit is short, `diff + 1` when
    going back one is, else `diff`."""
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            _bin(BIN_AND, forward.copy(), short_fwd^),
            _bin(BIN_SUB, diff.copy(), _lit(1)),
        )
    )
    cases.append(
        WhenCaseData(
            _bin(BIN_AND, Expr.unary(UN_NOT, forward^), short_back^),
            _bin(BIN_ADD, diff.copy(), _lit(1)),
        )
    )
    return Expr.when(cases^, diff^)


def _complete(unit: UInt8, var diff: Expr, a: Expr, b: Expr) -> Expr:
    """The complete `unit`s from TIMESTAMP `a` to `b`, from the boundaries
    crossed (`diff`): one fewer going forward when `b` is less far into its
    unit than `a`, one more going back when `a` is less far than `b`."""
    var ra = _rem(unit, a)
    var rb = _rem(unit, b)
    return _adjusted(
        diff^,
        _forward(a, b, False),
        _bin(BIN_LT, rb.copy(), ra.copy()),
        _bin(BIN_LT, ra^, rb^),
    )


def _borrows_month(s: Expr, e: Expr, is_date: Bool) -> Expr:
    """From `s` forward to `e`, is the last calendar month short? Its day of
    the month (and then time of day) is before `s`'s, except that an `e` on
    the last day of its month completes the month for any later day of `s`:

        (day(e) < day(s) AND day(e) <> days_in_month(e))
        OR (day(e) <= day(s) AND tod(e) < tod(s))   -- TIMESTAMPs only
    """
    var de = _ex(EXTRACT_DAY, e)
    var ds = _ex(EXTRACT_DAY, s)
    var not_end = Expr.unary(UN_NOT, _bin(BIN_EQ, de.copy(), days_in_month_of(e.copy())))
    var earlier_day = _bin(BIN_AND, _bin(BIN_LT, de.copy(), ds.copy()), not_end^)
    if is_date:
        return earlier_day^
    var earlier_time = _bin(
        BIN_AND,
        _bin(BIN_LE, de^, ds^),
        _bin(BIN_LT, _rem(EXTRACT_TRUNC_DAY, e), _rem(EXTRACT_TRUNC_DAY, s)),
    )
    return _bin(BIN_OR, earlier_day^, earlier_time^)


def _place_short(var pe: Expr, var ps: Expr, s: Expr, e: Expr, is_date: Bool) -> Expr:
    """`pe < ps OR (pe = ps AND <the month from s to e is short>)`: the
    last period from `s` to `e` is short, given each one's place in it."""
    return _bin(
        BIN_OR,
        _bin(BIN_LT, pe.copy(), ps.copy()),
        _bin(BIN_AND, _bin(BIN_EQ, pe^, ps^), _borrows_month(s, e, is_date)),
    )


def _quarter_place(x: Expr) -> Expr:
    """The month's place in its quarter, 1 to 3: month - 3 * quarter + 3."""
    return _bin(
        BIN_ADD,
        _bin(
            BIN_SUB,
            _ex(EXTRACT_MONTH, x),
            _bin(BIN_MUL, _ex(EXTRACT_QUARTER, x), _lit(3)),
        ),
        _lit(3),
    )


def date_sub_of(unit: UInt8, a: Expr, b: Expr, is_date: Bool) raises -> Expr:
    """`date_sub(unit, a, b)`: the complete `unit`s from `a` to `b`,
    truncated toward zero. `unit` and `is_date` are as for `date_diff_of`.

        us .. day  the boundaries crossed (date_diff), one fewer going
                   forward when b is less far into its unit than a, one more
                   going back when a is less far than b; over DATEs, the
                   boundaries crossed
        week       trunc(complete days / 7)
        month      the months crossed, one fewer going forward when the last
                   month is short (_borrows_month), one more going back
        quarter    the quarters crossed, adjusted the same way on the
                   month's place in its quarter
        year       the years crossed, adjusted on the month

    Raises:
        On a unit outside that list (the binder refuses those first).
    """
    if unit == EXTRACT_TRUNC_MONTH:
        return _adjusted(
            _month_diff(a, b),
            _forward(a, b, is_date),
            _borrows_month(a, b, is_date),
            _borrows_month(b, a, is_date),
        )
    if unit == EXTRACT_TRUNC_QUARTER:
        return _adjusted(
            _quarter_diff(a, b),
            _forward(a, b, is_date),
            _place_short(_quarter_place(b), _quarter_place(a), a, b, is_date),
            _place_short(_quarter_place(a), _quarter_place(b), b, a, is_date),
        )
    if unit == EXTRACT_TRUNC_YEAR:
        return _adjusted(
            _field_diff(EXTRACT_YEAR, a, b),
            _forward(a, b, is_date),
            _place_short(_ex(EXTRACT_MONTH, b), _ex(EXTRACT_MONTH, a), a, b, is_date),
            _place_short(_ex(EXTRACT_MONTH, a), _ex(EXTRACT_MONTH, b), b, a, is_date),
        )
    if unit == EXTRACT_TRUNC_WEEK:
        var days = date_sub_of(EXTRACT_TRUNC_DAY, a, b, is_date)
        return _trunc_quotient(days^, 7)
    if not (
        unit == EXTRACT_TRUNC_DAY or unit == EXTRACT_TRUNC_HOUR
        or unit == EXTRACT_TRUNC_MINUTE or unit == EXTRACT_TRUNC_SECOND
        or unit == EXTRACT_TRUNC_MILLISECOND or unit == EXTRACT_TRUNC_MICROSECOND
    ):
        raise Error("temporal_delta: date_sub has no unit " + String(Int(unit)))
    var diff = date_diff_of(unit, a, b, is_date)
    if is_date or unit == EXTRACT_TRUNC_MICROSECOND:
        return diff^
    return _complete(unit, diff^, a, b)
