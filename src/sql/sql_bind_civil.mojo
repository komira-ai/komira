# =============================================================================
# sql/sql_bind_civil.mojo
#   make_date(y, m, d), last_day(x) and the six-argument
#   make_timestamp(y, m, d, h, mi, s): calendar parts to a day count, built as
#   trees of the expression nodes the engine already has.
# =============================================================================
#
# THE DAY COUNT. `days_from_civil` is the Gregorian count of days from
# 1970-01-01 (H. Hinnant's formula, the one `_date_to_days` folds a DATE
# literal with). `BIN_DIV` truncates toward zero, and the formula needs a floor
# for a negative year, so the year is first shifted by 14700 eras of 400 years
# (5880000 years, which a 400-year era leaves on the same weekday and leap
# pattern): every year DuckDB's DATE holds (-5877641 .. 5881580) is then
# positive, every division is a floor, and the shift is taken off the result
# as 14700 * 146097 days. Every intermediate value stays below 2^33.
#
# VALIDITY IS DuckDB's `Date::IsValid`, `Time::IsValidTime` and
# `Timestamp::TryFromDatetime`, checked on the arguments as written: month
# 1..12, day 1..the month's length, year between -5877641-06-25 and
# 5881580-07-10; hour 0..23 (or 24:00:00.000000), minute 0..59, whole seconds
# 0..60 and a rounded microsecond 0..1000000; a timestamp whose microsecond
# count fits in INT64 and is not DuckDB's infinity.
#
# THE ARGUMENTS ARE CLAMPED BEFORE THE ARITHMETIC, each on its own: a year
# outside DATE's years, a month outside 1..12, a day outside 1..31, an hour
# outside 0..24, a minute outside 0..59 or seconds that cannot be valid enter
# the arithmetic as NULL, so no operator overflows on an invalid row (a month of
# 9e18, a year past the range), and a NULL argument stays NULL. The validity
# test of the whole date is not part of the clamp: it is used once, in the
# guard below, so one call copies each argument a fixed number of times and
# its tree grows linearly with the size of the arguments (a call nested in
# another's argument is copied that many times again).
#
# AN INVALID ROW RAISES, NAMING THE FUNCTION. The engine has no expression that
# raises a message of its own, and a CASE arm is evaluated over every row of a
# batch (`batch_eval/eval_case.mojo`), so the raise cannot sit in a CASE arm.
# It sits OUTSIDE one: a CASE whose arms are string literals only yields '0'
# for a valid or NULL row and the message for an invalid one, and a strict
# `CAST(... AS BIGINT)` of that string adds 0 to the result, or raises on the
# message (`kernels/cast_to_varchar_kernels.i64_from_str`), with the text
# `i64_from_str: no digits in 'make_date: Date out of range'`. The message is
# not DuckDB's (`Conversion Error: Date out of range: 2024-13-1`): the values
# are not in it. A NULL argument wins: such a row is NULL and does not raise,
# as in DuckDB, which skips a row with a NULL argument.
#
# CONSTANT ARGUMENTS FOLD AT BIND. When every argument is an integer (or, for
# the seconds, a number) literal, the value is computed here: a valid call
# becomes a DATE or TIMESTAMP literal, and an invalid one is refused at bind
# with DuckDB v1.5.6's own message, in DuckDB's order (the date before the
# time, and of the arguments cast to INTEGER the LAST one out of range).
# =============================================================================

from std.math import floor

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from plan_expr.expr import (
    BIN_ADD, BIN_AND, BIN_DIV, BIN_EQ, BIN_GE, BIN_GT, BIN_LE, BIN_LT,
    BIN_MOD, BIN_MUL, BIN_OR, BIN_SUB, EXPR_CAST, EXPR_LITERAL,
    EXPR_UNARY_OP,
    EXTRACT_MONTH, EXTRACT_YEAR, Expr, MATH_FLOOR, UN_IS_NULL, UN_NEGATE,
    UN_NOT, UN_ROUND,
    WhenCaseData,
)
from plan_expr.expr_walk import PlanColRefFields, walk_expr_field
from plan_expr.scalar_desugar import days_in_month_of_parts
from plan_expr.scalar_value import ScalarValue
from sql.sql_ast import SX_NULL, SqlExpr
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_scope import BindScope, CteScope
from sql.sql_catalog import SqlCatalog


# ---- DuckDB v1.5.6's DATE and TIMESTAMP ranges ------------------------------
comptime _MIN_YEAR: Int64 = -5877641
comptime _MIN_MONTH: Int64 = 6
comptime _MIN_DAY: Int64 = 25
comptime _MAX_YEAR: Int64 = 5881580
comptime _MAX_MONTH: Int64 = 7
comptime _MAX_DAY: Int64 = 10
# DuckDB's DATE infinity is the day count +-2147483647 and its TIMESTAMP
# infinity the microsecond count +-9223372036854775807.
comptime _DATE_INFINITY: Int64 = 2147483647
comptime _TS_INFINITY: Int64 = 9223372036854775807
# The last day whose midnight fits in INT64 microseconds, and on that day the
# last microsecond of the day that is not DuckDB's infinity.
comptime _TS_MAX_DAYS: Int64 = 106751991
comptime _TS_LAST_DAY_MAX_MICROS: Int64 = 14454775806
comptime _MICROS_PER_DAY: Int64 = 86400000000
# The year shift of `days_from_civil`: 14700 eras of 400 years.
comptime _SHIFT_ERAS: Int64 = 14700
comptime _SHIFT_YEARS: Int64 = 5880000
comptime _INT32_MIN: Int64 = -2147483648
comptime _INT32_MAX: Int64 = 2147483647

# The messages an invalid row of a column raises with (see the header).
comptime MAKE_DATE_RANGE_MSG = "make_date: Date out of range"
comptime LAST_DAY_RANGE_MSG = "last_day: Date out of range"
comptime MAKE_TS_DATE_MSG = "make_timestamp: Date out of range"
comptime MAKE_TS_TIME_MSG = "make_timestamp: Time out of range"
comptime MAKE_TS_RANGE_MSG = "make_timestamp: Date and time not in timestamp range"


# =============================================================================
# Expression helpers
# =============================================================================


def _int(v: Int64) -> Expr:
    return Expr.literal(ScalarValue.from_int64(v))


def _flt(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _str(s: String) -> Expr:
    return Expr.literal(ScalarValue.from_string(s))


def _bin(op: UInt8, a: Expr, b: Expr) -> Expr:
    return Expr.binary(op, a.copy(), b.copy())


def _and(a: Expr, b: Expr) -> Expr:
    return _bin(BIN_AND, a, b)


def _or(a: Expr, b: Expr) -> Expr:
    return _bin(BIN_OR, a, b)


def _is_null(a: Expr) -> Expr:
    return Expr.unary(UN_IS_NULL, a.copy())


def _when1(cond: Expr, then: Expr, otherwise: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(cond.copy(), then.copy()))
    return Expr.when(cases^, otherwise.copy())


def _clamp_int(value: Expr, ok: Expr) -> Expr:
    """`CASE WHEN ok THEN value ELSE NULL END`, INT64."""
    return _when1(ok, value, Expr.literal(ScalarValue.null(DType.int64)))


def _clamp_float(value: Expr, ok: Expr) -> Expr:
    """`CASE WHEN ok THEN value ELSE NULL END`, FLOAT64."""
    return _when1(ok, value, Expr.literal(ScalarValue.null(DType.float64)))


def _any_null(parts: List[Expr]) -> Expr:
    var acc = _is_null(parts[0])
    for i in range(1, len(parts)):
        acc = _or(acc, _is_null(parts[i]))
    return acc^


def _guard(var cases: List[WhenCaseData], otherwise: String) -> Expr:
    """`CAST(CASE <cases> ELSE '<otherwise>' END AS BIGINT)`: 0 for a row whose
    arm is '0', a raise on the message of any other arm (see the header).
    Every arm is a string literal, so evaluating them over every row raises
    nothing; the cast raises only on the rows that take a message."""
    return Expr.cast(Expr.when(cases^, _str(otherwise)), DType.int64)


# =============================================================================
# The calendar as expressions
# =============================================================================


def days_from_civil_expr(y: Expr, m: Expr, d: Expr) -> Expr:
    """Days from 1970-01-01 of the date y-m-d (INT64 expressions with the year
    in DATE's range, the month 1..12 and the day 1..31: the caller clamps). See
    the header for the year shift. `y` is copied four times, `m` twice."""
    var yy = _when1(
        _bin(BIN_LE, m, _int(2)),
        _bin(BIN_ADD, y, _int(_SHIFT_YEARS - 1)),
        _bin(BIN_ADD, y, _int(_SHIFT_YEARS)),
    )
    var era = _bin(BIN_DIV, yy, _int(400))
    # yy is positive, so the truncated remainder is the year of the era
    var yoe = _bin(BIN_MOD, yy, _int(400))
    var mp = _bin(BIN_MOD, _bin(BIN_ADD, m, _int(9)), _int(12))
    var doy = _bin(
        BIN_SUB,
        _bin(
            BIN_ADD,
            _bin(BIN_DIV, _bin(BIN_ADD, _bin(BIN_MUL, mp, _int(153)), _int(2)), _int(5)),
            d,
        ),
        _int(1),
    )
    var doe = _bin(
        BIN_ADD,
        _bin(
            BIN_SUB,
            _bin(
                BIN_ADD,
                _bin(BIN_MUL, yoe, _int(365)),
                _bin(BIN_DIV, yoe, _int(4)),
            ),
            _bin(BIN_DIV, yoe, _int(100)),
        ),
        doy,
    )
    return _bin(
        BIN_SUB,
        _bin(BIN_ADD, _bin(BIN_MUL, era, _int(146097)), doe),
        _int(_SHIFT_ERAS * 146097 + 719468),
    )


def _on_or_after(
    y: Expr, m: Expr, d: Expr, ly: Int64, lm: Int64, ld: Int64
) -> Expr:
    """y-m-d >= ly-lm-ld, compared part by part (no arithmetic)."""
    return _or(
        _bin(BIN_GT, y, _int(ly)),
        _and(
            _bin(BIN_EQ, y, _int(ly)),
            _or(
                _bin(BIN_GT, m, _int(lm)),
                _and(_bin(BIN_EQ, m, _int(lm)), _bin(BIN_GE, d, _int(ld))),
            ),
        ),
    )


def _on_or_before(
    y: Expr, m: Expr, d: Expr, hy: Int64, hm: Int64, hd: Int64
) -> Expr:
    """y-m-d <= hy-hm-hd, compared part by part (no arithmetic)."""
    return _or(
        _bin(BIN_LT, y, _int(hy)),
        _and(
            _bin(BIN_EQ, y, _int(hy)),
            _or(
                _bin(BIN_LT, m, _int(hm)),
                _and(_bin(BIN_EQ, m, _int(hm)), _bin(BIN_LE, d, _int(hd))),
            ),
        ),
    )


def date_in_range_expr(y: Expr, m: Expr, d: Expr) -> Expr:
    """y-m-d lies between DuckDB's first and last DATE, -5877641-06-25 and
    5881580-07-10."""
    return _and(
        _on_or_after(y, m, d, _MIN_YEAR, _MIN_MONTH, _MIN_DAY),
        _on_or_before(y, m, d, _MAX_YEAR, _MAX_MONTH, _MAX_DAY),
    )


def date_is_valid_expr(y: Expr, m: Expr, d: Expr) -> Expr:
    """DuckDB's `Date::IsValid(y, m, d)` as a BOOL expression. It is never
    TRUE for an invalid date; with a NULL part it is NULL or FALSE."""
    var month_ok = _and(_bin(BIN_GE, m, _int(1)), _bin(BIN_LE, m, _int(12)))
    var day_ok = _and(
        _bin(BIN_GE, d, _int(1)),
        _bin(BIN_LE, d, days_in_month_of_parts(y.copy(), m.copy())),
    )
    return _and(_and(month_ok, date_in_range_expr(y, m, d)), day_ok)


def _between_or_null(v: Expr, lo: Int64, hi: Int64) -> Expr:
    """`CASE WHEN lo <= v AND v <= hi THEN v ELSE NULL END`, INT64: a part
    clamped to where the day and time arithmetic cannot overflow."""
    return _clamp_int(
        v, _and(_bin(BIN_GE, v, _int(lo)), _bin(BIN_LE, v, _int(hi)))
    )


def _as_date32(days: Expr) -> Expr:
    """An INT64 day count in DATE's range -> DATE."""
    return Expr.cast_to_arrow(Expr.cast(days.copy(), DType.int32), ArrowType.DATE32)


def _clamped_days(y: Expr, m: Expr, d: Expr) -> Expr:
    """`days_from_civil_expr` of the parts clamped one by one (NULL outside
    the year range, a month 1..12, a day 1..31): never overflows, and is the
    right day count whenever the date is valid."""
    return days_from_civil_expr(
        _between_or_null(y, _MIN_YEAR, _MAX_YEAR),
        _between_or_null(m, 1, 12),
        _between_or_null(d, 1, 31),
    )


def make_date_expr(y: Expr, m: Expr, d: Expr) -> Expr:
    """`make_date(y, m, d)` over INT64 expressions -> DATE."""
    var parts = List[Expr]()
    parts.append(y.copy())
    parts.append(m.copy())
    parts.append(d.copy())
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_any_null(parts), _str("0")))
    cases.append(WhenCaseData(date_is_valid_expr(y, m, d), _str("0")))
    return _as_date32(
        _bin(BIN_ADD, _clamped_days(y, m, d), _guard(cases^, MAKE_DATE_RANGE_MSG))
    )


def last_day_expr(x: Expr, infinity: Int64) -> Expr:
    """`last_day(x)` -> DATE, for a DATE or TIMESTAMP `x` whose stored
    infinity is `+-infinity`. DuckDB's operator: the first day of the next
    month (`y + m / 12`, `m % 12 + 1`, 1) less one day, so the only invalid
    input is a date in the range's last month, July 5881580; an infinite `x`
    answers NULL. The year of any stored value is within a year of DATE's
    range and the month is 1..12, so the arithmetic needs no clamp."""
    var raw = Expr.cast(x.copy(), DType.int64)
    var infinite = _or(
        _bin(BIN_EQ, raw, _int(infinity)), _bin(BIN_EQ, raw, _int(-infinity))
    )
    var y = Expr.extract(EXTRACT_YEAR, x.copy())
    var m = Expr.extract(EXTRACT_MONTH, x.copy())
    var ny = _bin(BIN_ADD, y, _bin(BIN_DIV, m, _int(12)))
    var nm = _bin(BIN_ADD, _bin(BIN_MOD, m, _int(12)), _int(1))
    var days = _bin(BIN_SUB, days_from_civil_expr(ny, nm, _int(1)), _int(1))
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_is_null(x), _str("0")))
    cases.append(WhenCaseData(infinite.copy(), _str("0")))
    cases.append(WhenCaseData(date_in_range_expr(ny, nm, _int(1)), _str("0")))
    return _as_date32(
        _bin(
            BIN_ADD,
            _when1(infinite, Expr.literal(ScalarValue.null(DType.int64)), days),
            _guard(cases^, LAST_DAY_RANGE_MSG),
        )
    )


def _seconds_ok_expr(s: Expr) -> Expr:
    """The seconds `s` (FLOAT64) pass `Time::IsValidTime` after DuckDB's
    rounding: whole seconds 0..60 and a rounded microsecond 0..1000000. For
    0 <= s <= 60 that always holds; 60 < s <= 60.5 rounds (half to even) to 60
    whole seconds; s < 0 rounds to 0 whole seconds and leaves `round(s * 1e6)`
    microseconds, which is 0 only when s * 1e6 > -0.5; NaN fails both
    comparisons."""
    return _and(
        _bin(BIN_GT, _bin(BIN_MUL, s, _flt(1000000.0)), _flt(-0.5)),
        _bin(BIN_LE, s, _flt(60.5)),
    )


def make_timestamp_expr(
    y: Expr, m: Expr, d: Expr, h: Expr, mi: Expr, s: Expr
) -> Expr:
    """`make_timestamp(y, m, d, h, mi, s)` over five INT64 expressions and a
    FLOAT64 seconds -> TIMESTAMP (microseconds)."""
    # The seconds, NULL where they cannot be valid; then DuckDB's whole
    # seconds (0 below zero, else the floor, which is also the half-to-even
    # rounding of 60 < s <= 60.5) and its `std::round` of the rest.
    var sc = _clamp_float(s, _seconds_ok_expr(s))
    var whole = _when1(
        _bin(BIN_LT, sc, _flt(0.0)), _flt(0.0), Expr.math_fn(MATH_FLOOR, sc.copy())
    )
    var micros = Expr.unary(
        UN_ROUND, _bin(BIN_MUL, _bin(BIN_SUB, sc, whole), _flt(1000000.0))
    )
    var minutes = _bin(
        BIN_ADD,
        _bin(BIN_MUL, _between_or_null(h, 0, 24), _int(60)),
        _between_or_null(mi, 0, 59),
    )
    var t = _bin(
        BIN_ADD,
        _bin(
            BIN_MUL,
            _bin(BIN_ADD, _bin(BIN_MUL, minutes, _int(60)), Expr.cast(whole^, DType.int64)),
            _int(1000000),
        ),
        Expr.cast(micros^, DType.int64),
    )
    var date_ok = date_is_valid_expr(y, m, d)
    var in_day = _and(
        _and(
            _and(_bin(BIN_GE, h, _int(0)), _bin(BIN_LT, h, _int(24))),
            _and(_bin(BIN_GE, mi, _int(0)), _bin(BIN_LT, mi, _int(60))),
        ),
        _seconds_ok_expr(s),
    )
    var s_micros = _bin(BIN_MUL, s, _flt(1000000.0))
    var midnight = _and(
        _and(_bin(BIN_EQ, h, _int(24)), _bin(BIN_EQ, mi, _int(0))),
        _and(_bin(BIN_GT, s_micros, _flt(-0.5)), _bin(BIN_LT, s_micros, _flt(0.5))),
    )
    var time_ok = _or(in_day, midnight)
    # The days whose midnight fits in INT64 microseconds run from
    # -290308-12-22 to 294247-01-10; on the last one, the time of day may not
    # reach DuckDB's infinity.
    var range_ok = _and(
        _on_or_after(y, m, d, -290308, 12, 22),
        _or(
            _on_or_before(y, m, d, 294247, 1, 9),
            _and(
                _on_or_before(y, m, d, 294247, 1, 10),
                _bin(BIN_LE, t, _int(_TS_LAST_DAY_MAX_MICROS)),
            ),
        ),
    )
    var parts = List[Expr]()
    parts.append(y.copy())
    parts.append(m.copy())
    parts.append(d.copy())
    parts.append(h.copy())
    parts.append(mi.copy())
    parts.append(s.copy())
    # With no NULL part every test below is TRUE or FALSE, so each arm names
    # the first check that fails, in DuckDB's order.
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_any_null(parts), _str("0")))
    cases.append(
        WhenCaseData(Expr.unary(UN_NOT, date_ok.copy()), _str(MAKE_TS_DATE_MSG))
    )
    cases.append(
        WhenCaseData(Expr.unary(UN_NOT, time_ok.copy()), _str(MAKE_TS_TIME_MSG))
    )
    cases.append(
        WhenCaseData(Expr.unary(UN_NOT, range_ok.copy()), _str(MAKE_TS_RANGE_MSG))
    )
    var days = _clamp_int(_clamped_days(y, m, d), range_ok)
    var micros_total = _bin(
        BIN_ADD, _bin(BIN_MUL, days, _int(_MICROS_PER_DAY)), t
    )
    return Expr.cast_to_arrow(
        _bin(BIN_ADD, micros_total, _guard(cases^, "0")),
        ArrowType.TIMESTAMP_US,
    )


# =============================================================================
# The calendar at bind time: constant arguments, DuckDB's messages
# =============================================================================


def _is_leap(y: Int64) -> Bool:
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def _month_days(y: Int64, m: Int64) -> Int64:
    var lengths: List[Int64] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if m == 2 and _is_leap(y):
        return 29
    return lengths[Int(m - 1)]


def date_is_valid(y: Int64, m: Int64, d: Int64) -> Bool:
    """DuckDB's `Date::IsValid`."""
    if m < 1 or m > 12 or d < 1:
        return False
    if y < _MIN_YEAR or y > _MAX_YEAR:
        return False
    if y == _MIN_YEAR and (m < _MIN_MONTH or (m == _MIN_MONTH and d < _MIN_DAY)):
        return False
    if y == _MAX_YEAR and (m > _MAX_MONTH or (m == _MAX_MONTH and d > _MAX_DAY)):
        return False
    return d <= _month_days(y, m)


def days_from_civil(y: Int64, m: Int64, d: Int64) -> Int64:
    """`days_from_civil_expr` on values, for a valid date."""
    var yy = y + _SHIFT_YEARS - (Int64(1) if m <= 2 else Int64(0))
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - (_SHIFT_ERAS * 146097 + 719468)


def _to_int32(v: Int64) raises -> Int64:
    """DuckDB's cast of a BIGINT argument to INTEGER."""
    if v < _INT32_MIN or v > _INT32_MAX:
        raise Error(
            "Invalid Input Error: Type INT64 with value " + String(v)
            + " can't be cast because the value is out of range for the"
            " destination type INT32"
        )
    return v


def fold_make_date(y: Int64, m: Int64, d: Int64) raises -> Int64:
    """DuckDB's `make_date` on constants: the day count, or its error. The
    arguments are cast to INTEGER last first, as DuckDB's call does."""
    var d32 = _to_int32(d)
    var m32 = _to_int32(m)
    var y32 = _to_int32(y)
    if not date_is_valid(y32, m32, d32):
        raise Error(
            "Conversion Error: Date out of range: " + String(y32) + "-"
            + String(m32) + "-" + String(d32)
        )
    return days_from_civil(y32, m32, d32)


def _round_half_even(x: Float64) -> Float64:
    var r = floor(x)
    var diff = x - r
    if diff > 0.5:
        return r + 1.0
    if diff < 0.5:
        return r
    return r if r % 2.0 == 0.0 else r + 1.0


def _round_half_away(x: Float64) -> Float64:
    if x < 0.0:
        return -_round_half_away(-x)
    var r = floor(x)
    return r + 1.0 if x - r >= 0.5 else r


def _lossy_int32(x: Float64) -> Int64:
    """A DOUBLE truncated to INTEGER the way DuckDB's lossy cast does on this
    hardware: INTEGER's minimum for NaN or a value outside INTEGER (which
    `make_timestamp(..., 'nan')` and `(..., 2147483647.6)` show in their
    messages)."""
    if not (x >= -2147483648.0 and x < 2147483648.0):
        return _INT32_MIN
    return Int64(x)


def _float_text(v: Float64) -> String:
    """A DOUBLE as DuckDB's cast error writes it: the shortest round-trip
    text, with `.0` on a whole number (`10000000000.0`, `inf`)."""
    return String(v)


def fold_make_timestamp(
    y: Int64, m: Int64, d: Int64, h: Int64, mi: Int64, s: Float64
) raises -> Int64:
    """DuckDB's six-argument `make_timestamp` on constants: the microsecond
    count, or its error, checked in DuckDB's order (the date, then the hour,
    the minute and the seconds, then the time, then the timestamp range).
    The whole seconds are the truncation of `s` for 0 <= s <= 60, else `s`
    rounded half to even, and the microseconds `(s - whole) * 1000000`
    rounded half away from zero (DuckDB's `MakeTimeOperator`)."""
    var days = fold_make_date(y, m, d)
    var h32 = _to_int32(h)
    var mi32 = _to_int32(mi)
    var whole: Float64
    if s < 0.0 or s > 60.0:
        if not (s >= -2147483648.0 and s < 2147483648.0):
            raise Error(
                "Invalid Input Error: Type DOUBLE with value "
                + _float_text(s) + " can't be cast because the value is"
                " out of range for the destination type INT32"
            )
        whole = _round_half_even(s)
    else:
        whole = s
    var ss = _lossy_int32(whole)
    var micros = _lossy_int32(_round_half_away((s - Float64(ss)) * 1000000.0))
    var in_day = (
        h32 >= 0 and h32 < 24 and mi32 >= 0 and mi32 < 60
        and ss >= 0 and ss <= 60 and micros >= 0 and micros <= 1000000
    )
    var midnight = h32 == 24 and mi32 == 0 and ss == 0 and micros == 0
    if not (in_day or midnight):
        raise Error(
            "Conversion Error: Time out of range: " + String(h32) + ":"
            + String(mi32) + ":" + String(ss) + "." + String(micros)
        )
    var t = ((h32 * 60 + mi32) * 60 + ss) * 1000000 + micros
    if (
        days < -_TS_MAX_DAYS
        or days > _TS_MAX_DAYS
        or (days == _TS_MAX_DAYS and t > _TS_LAST_DAY_MAX_MICROS)
    ):
        raise Error("Conversion Error: Date and time not in timestamp range")
    return days * _MICROS_PER_DAY + t


# =============================================================================
# The binders
# =============================================================================


def _type_of(e: Expr, schema: Schema) -> ArrowType:
    var missing = String("")
    return walk_expr_field[PlanColRefFields](e, schema, missing).arrow_type


def _is_int_type(at: ArrowType) -> Bool:
    """The integer types DuckDB casts to BIGINT implicitly."""
    return (
        at == ArrowType.INT64 or at == ArrowType.INT32 or at == ArrowType.INT16
        or at == ArrowType.INT8 or at == ArrowType.UINT8
        or at == ArrowType.UINT16 or at == ArrowType.UINT32
    )


def _const_int(e: Expr) -> Optional[Int64]:
    """The value of an integer literal, or of a negated one, seen through the
    cast to BIGINT that `_bind_int_part` puts on it."""
    if e.tag == EXPR_LITERAL:
        var v = e.literal_value()
        if v.is_int():
            return v.int_val
        return None
    if e.tag == EXPR_CAST and e.cast_target() == DType.int64:
        return _const_int(e.cast_child_ref())
    if e.tag == EXPR_UNARY_OP and e.unary_op() == UN_NEGATE:
        var inner = _const_int(e.unary_child_ref())
        if inner:
            return -inner.value()
    return None


def _const_num(e: Expr) -> Optional[Float64]:
    """The value of a number literal (integer or float), or of a negated one."""
    if e.tag == EXPR_LITERAL:
        var v = e.literal_value()
        if v.is_int():
            return Float64(v.int_val)
        if v.is_float():
            return v.float_val
        return None
    if e.tag == EXPR_CAST and e.cast_target() == DType.float64:
        return _const_num(e.cast_child_ref())
    if e.tag == EXPR_UNARY_OP and e.unary_op() == UN_NEGATE:
        var inner = _const_num(e.unary_child_ref())
        if inner:
            return -inner.value()
    return None


def _bind_int_part(
    fname: String,
    pos: Int,
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """An integer argument as INT64: a NULL literal is a typed NULL, a
    narrower integer is widened, anything else is refused by name."""
    if sx.tag == SX_NULL:
        return Expr.literal(ScalarValue.null(DType.int64))
    var e = _bind_scalar(sx, schema, scope, catalog, cte_scope, prebound)
    var at = _type_of(e, schema)
    if at == ArrowType.INT64 and e.tag == EXPR_LITERAL:
        return e^
    # Every other integer is cast, an INT64 one too: an expression such as
    # `13 + k` over an INTEGER column is typed BIGINT here and computed as
    # INTEGER, and the CASE arms it enters must all be BIGINT.
    if _is_int_type(at):
        return Expr.cast(e^, DType.int64)
    raise Error(
        "SQL not supported: `" + fname + "` takes integer arguments (DuckDB's"
        " BIGINT overload), but argument " + String(pos) + " is of type "
        + String(at) + ". DuckDB refuses a DOUBLE or DECIMAL argument too;"
        " cast the argument to BIGINT."
    )


def _bind_seconds_part(
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`make_timestamp`'s seconds as FLOAT64 (DuckDB's DOUBLE parameter): a
    NULL literal is a typed NULL, an integer, FLOAT or DECIMAL is cast."""
    if sx.tag == SX_NULL:
        return Expr.literal(ScalarValue.null(DType.float64))
    var e = _bind_scalar(sx, schema, scope, catalog, cte_scope, prebound)
    var at = _type_of(e, schema)
    if at == ArrowType.FLOAT64:
        return e^
    if (
        _is_int_type(at) or at == ArrowType.UINT64 or at == ArrowType.FLOAT32
        or at == ArrowType.DECIMAL128
    ):
        return Expr.cast(e^, DType.float64)
    raise Error(
        "SQL not supported: `make_timestamp` takes its seconds as a DOUBLE,"
        " but argument 6 is of type " + String(at) + "; cast it to DOUBLE."
    )


def _bind_make_date(
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`make_date(y, m, d)` -> DATE, equal to DuckDB's BIGINT overload: folded
    to a DATE literal (or refused with DuckDB's message) when all three
    arguments are integer literals, else `make_date_expr`. DuckDB's
    one-argument (INTEGER day count) and STRUCT overloads are refused."""
    ref args = sx._call.value().args
    if len(args) != 3:
        raise Error(
            "SQL not supported: `make_date` is served as make_date(year,"
            " month, day), three integer arguments; got "
            + String(len(args)) + ". DuckDB's one-argument overloads (an"
            " INTEGER day count, a STRUCT of the three parts) are not served."
        )
    var y = _bind_int_part("make_date", 1, args[0], schema, scope, catalog, cte_scope, prebound)
    var m = _bind_int_part("make_date", 2, args[1], schema, scope, catalog, cte_scope, prebound)
    var d = _bind_int_part("make_date", 3, args[2], schema, scope, catalog, cte_scope, prebound)
    var cy = _const_int(y)
    var cm = _const_int(m)
    var cd = _const_int(d)
    if cy and cm and cd:
        var days = fold_make_date(cy.value(), cm.value(), cd.value())
        return Expr.literal(ScalarValue.date32(Int32(days)))
    return make_date_expr(y, m, d)


def _bind_last_day(
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`last_day(x)` -> DATE for a DATE or zone-less TIMESTAMP `x`
    (`last_day_expr`). A TIMESTAMP WITH TIME ZONE is refused: DuckDB reads it
    in the session's time zone, which this engine does not have."""
    ref args = sx._call.value().args
    if len(args) != 1:
        raise Error(
            "SQL bind error: last_day() expects exactly 1 argument (a DATE or"
            " TIMESTAMP expression) — got " + String(len(args))
        )
    var x = _bind_scalar(args[0], schema, scope, catalog, cte_scope, prebound)
    var missing = String("")
    var f = walk_expr_field[PlanColRefFields](x, schema, missing)
    if f.arrow_type == ArrowType.DATE32:
        return last_day_expr(x, _DATE_INFINITY)
    if f.arrow_type.is_timestamp() and f.timezone() == "":
        return last_day_expr(x, _TS_INFINITY)
    raise Error(
        "SQL not supported: `last_day` takes a DATE or a TIMESTAMP without a"
        " time zone, but its argument is of type " + String(f.arrow_type)
        + (" with time zone " + f.timezone() if f.timezone() != "" else "")
        + "."
    )


def bind_make_timestamp_parts(
    sx: SqlExpr,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """The six-argument `make_timestamp(y, m, d, h, mi, s)` -> TIMESTAMP:
    folded to a TIMESTAMP literal (or refused with DuckDB's message) when all
    six arguments are number literals, else `make_timestamp_expr`."""
    ref args = sx._call.value().args
    var fname = String("make_timestamp")
    var y = _bind_int_part(fname, 1, args[0], schema, scope, catalog, cte_scope, prebound)
    var m = _bind_int_part(fname, 2, args[1], schema, scope, catalog, cte_scope, prebound)
    var d = _bind_int_part(fname, 3, args[2], schema, scope, catalog, cte_scope, prebound)
    var h = _bind_int_part(fname, 4, args[3], schema, scope, catalog, cte_scope, prebound)
    var mi = _bind_int_part(fname, 5, args[4], schema, scope, catalog, cte_scope, prebound)
    var s = _bind_seconds_part(args[5], schema, scope, catalog, cte_scope, prebound)
    var cy = _const_int(y)
    var cm = _const_int(m)
    var cd = _const_int(d)
    var ch = _const_int(h)
    var cmi = _const_int(mi)
    var cs = _const_num(s)
    if cy and cm and cd and ch and cmi and cs:
        var micros = fold_make_timestamp(
            cy.value(), cm.value(), cd.value(), ch.value(), cmi.value(), cs.value()
        )
        return Expr.literal(ScalarValue.timestamp_micros(micros))
    return make_timestamp_expr(y, m, d, h, mi, s)
