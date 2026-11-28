# =============================================================================
# sql/sql_bind_interval.mojo
#   `INTERVAL '<n>' <unit>` at bind time. The interval is a constant pair of
#   calendar months and days (`IntervalConst`); there is no INTERVAL value or
#   type in the bound plan, and the only legal home of an `SX_INTERVAL` node is
#   the operand of one addition or subtraction with a DATE:
#     - a constant DATE +/- INTERVAL folds to a DATE constant;
#     - a DATE-typed expression +/- INTERVAL binds to a DATE32 `DateAdd` node
#       cast to TIMESTAMP (DuckDB answers `DATE +/- INTERVAL` as a TIMESTAMP at
#       midnight, whatever the unit), a chain of intervals nesting one
#       `DateAdd` per interval under that one cast;
#     - `date_add(date, INTERVAL ...)` shares that lowering (`bind_date_add_interval`).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue
from sql.sql_ast import (
    SXIVL_DAY, SXIVL_MONTH, SXIVL_WEEK, SXIVL_YEAR, SXOP_ADD, SXOP_SUB,
    SX_BINARY, SX_INTERVAL, SqlExpr,
)
from sql.sql_bind_ops import _operand_type

comptime INTERVAL_STANDALONE_REFUSAL: String = (
    "SQL not supported: an INTERVAL value is only accepted as the other"
    " operand of `<DATE> + INTERVAL '<n>' <unit>` / `<DATE> - INTERVAL '<n>'"
    " <unit>` / `INTERVAL '<n>' <unit> + <DATE>`, or as the second argument"
    " of `date_add(<DATE>, INTERVAL '<n>' <unit>)`; it is folded into the"
    " DATE shift at bind time and the plan has no INTERVAL type"
)

comptime _MIN_YEAR: Int = 1
comptime _MAX_YEAR: Int = 9999


struct _Civil(Copyable, Movable):
    var y: Int
    var m: Int
    var d: Int

    def __init__(out self, y: Int, m: Int, d: Int):
        self.y = y
        self.m = m
        self.d = d


def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        var leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
        return 29 if leap else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 of a valid proleptic-Gregorian date (Hinnant)."""
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(days: Int) -> _Civil:
    """Inverse of `_days_from_civil` (Hinnant). `//` floors, so the era
    split needs no negative-number correction."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return _Civil(y, m, d)


def date_add_months(days: Int, months: Int) raises -> Int:
    """`date32` days of `date + months` months, the day clamped to the end of
    the target month (PostgreSQL and DuckDB: 31 Jan + 1 month = 28 Feb, or 29
    in a leap year; 29 Feb + 1 year = 28 Feb). Raises when the result year
    leaves 1..9999."""
    var c = _civil_from_days(days)
    var total = c.y * 12 + (c.m - 1) + months
    var ny = total // 12
    var nm = total - ny * 12 + 1
    if ny < _MIN_YEAR or ny > _MAX_YEAR:
        raise Error(
            "SQL bind error: DATE +/- INTERVAL result is out of range (year "
            + String(ny) + " is outside 1..9999)"
        )
    var dim = _days_in_month(ny, nm)
    var nd = c.d if c.d <= dim else dim
    return _days_from_civil(ny, nm, nd)


def date_add_days(days: Int, delta: Int) raises -> Int:
    var out = days + delta
    var c = _civil_from_days(out)
    if c.y < _MIN_YEAR or c.y > _MAX_YEAR:
        raise Error(
            "SQL bind error: DATE +/- INTERVAL result is out of range (year "
            + String(c.y) + " is outside 1..9999)"
        )
    return out


def interval_operand_side(sx: SqlExpr) -> Int:
    """For a binary node: 2 when the RIGHT operand is an INTERVAL literal and
    the operator is `+` or `-` (the date is the left operand), 1 when the LEFT
    operand is an INTERVAL and the operator is `+` (`INTERVAL ... + date`), 0
    otherwise. Any other placement of an INTERVAL reaches the binder's
    `SX_INTERVAL` arm and is refused there by name."""
    if sx.tag != SX_BINARY:
        return 0
    ref b = sx._binary.value()
    if b.right[].tag == SX_INTERVAL and (sx.op == SXOP_ADD or sx.op == SXOP_SUB):
        return 2
    if b.left[].tag == SX_INTERVAL and sx.op == SXOP_ADD:
        return 1
    return 0

struct IntervalConst(Copyable, Movable):
    """An `INTERVAL '<n>' <unit>` as the bind-time constant pair a DATE is
    shifted by: calendar `months` (YEAR is 12 months), then `days` (WEEK is 7
    days). Each fits Int32, the width of a `DateAdd` payload."""

    var months: Int
    var days: Int

    def __init__(out self, months: Int, days: Int):
        self.months = months
        self.days = days


def interval_const(node: SqlExpr, negate: Bool) raises -> IntervalConst:
    """The months and days of the `SX_INTERVAL` `node`, negated when `negate`
    (`DATE - INTERVAL`). Raises by name when either count does not fit Int32,
    so no valid DATE could be shifted by it."""
    var n = Int(node.int_val)
    if negate:
        n = -n
    var unit = node.op
    var months = 0
    var days = 0
    var name: String
    if unit == SXIVL_YEAR:
        months = n * 12
        name = "YEAR"
    elif unit == SXIVL_MONTH:
        months = n
        name = "MONTH"
    elif unit == SXIVL_WEEK:
        days = n * 7
        name = "WEEK"
    else:
        days = n
        name = "DAY"
    if months < -2147483648 or months > 2147483647 or days < -2147483648 or days > 2147483647:
        raise Error(
            "SQL not supported: INTERVAL '" + String(Int(node.int_val)) + "' "
            + name + " is beyond the range of a DATE shift (" + String(months)
            + " months and " + String(days) + " days must each fit 32 bits)"
        )
    return IntervalConst(months, days)


def _interval_operand_refusal(t: ArrowType) -> String:
    return (
        "SQL not supported: `+/- INTERVAL` needs a DATE operand but this one"
        " is " + String(t) + " (a TIMESTAMP, string or number plus an"
        " INTERVAL is not served; cast it to DATE or write the shift on a"
        " DATE column)"
    )


def date_shift_by_interval(
    var date_side: Expr, c: IntervalConst, typing: Schema
) raises -> Expr:
    """`date_side` shifted by the constant interval `c`, as DuckDB answers
    `DATE +/- INTERVAL`: a TIMESTAMP at midnight, always. A DATE-typed
    `date_side` becomes `CAST(DateAdd(months, days, date_side) AS TIMESTAMP)`.
    A `date_side` that is already such a cast (a chain `d + INTERVAL .. +
    INTERVAL ..`) gets one more `DateAdd` under the same cast. Any other type
    is refused by name."""
    if (
        date_side.is_cast()
        and date_side.cast_target_arrow() == ArrowType.TIMESTAMP_US
        and date_side.cast_child_ref().is_date_add()
    ):
        return Expr.cast_to_arrow(
            Expr.date_add(
                Int32(c.months), Int32(c.days), date_side.cast_child_ref().copy()
            ),
            ArrowType.TIMESTAMP_US,
        )
    var t = _operand_type(date_side, typing)
    if t != ArrowType.DATE32:
        raise Error(_interval_operand_refusal(t))
    return Expr.cast_to_arrow(
        Expr.date_add(Int32(c.months), Int32(c.days), date_side^),
        ArrowType.TIMESTAMP_US,
    )


def interval_date_fold(
    sx: SqlExpr, var date_side: Expr, typing: Schema
) raises -> Expr:
    """Bind `date_side +/- INTERVAL` (the `interval_operand_side` shapes).
    `date_side` is the bound non-INTERVAL operand. A DATE literal folds to a
    DATE literal; any other operand goes to `date_shift_by_interval`, typed
    over `typing`."""
    var negate = interval_operand_side(sx) == 2 and sx.op == SXOP_SUB
    if interval_operand_side(sx) == 2:
        return bind_date_shift(sx._binary.value().right[], negate, date_side^, typing)
    return bind_date_shift(sx._binary.value().left[], negate, date_side^, typing)


def bind_date_shift(
    node: SqlExpr, negate: Bool, var date_side: Expr, typing: Schema
) raises -> Expr:
    if not date_side.is_literal() or not date_side.literal_value().is_date32():
        return date_shift_by_interval(
            date_side^, interval_const(node, negate), typing
        )
    var n = Int(node.int_val)
    var unit = node.op
    var base = Int(date_side.literal_value().date32_val)
    if negate:
        n = -n
    var out: Int
    if unit == SXIVL_YEAR:
        out = date_add_months(base, n * 12)
    elif unit == SXIVL_MONTH:
        out = date_add_months(base, n)
    elif unit == SXIVL_WEEK:
        out = date_add_days(base, n * 7)
    else:
        out = date_add_days(base, n)
    return Expr.literal(ScalarValue.date32(Int32(out)))
