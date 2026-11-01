# =============================================================================
# komira_sql/sql_bind_interval.mojo
#   `INTERVAL '<n>' <unit>` at bind time: a constant DATE +/- a constant
#   INTERVAL folds to a DATE constant. There is no INTERVAL value in the bound
#   plan; the only legal home of an `SX_INTERVAL` node is the operand of that
#   one addition or subtraction.
# =============================================================================

from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_sql.sql_ast import (
    SXIVL_DAY, SXIVL_MONTH, SXIVL_WEEK, SXIVL_YEAR, SXOP_ADD, SXOP_SUB,
    SX_BINARY, SX_INTERVAL, SqlExpr,
)

comptime INTERVAL_STANDALONE_REFUSAL: String = (
    "SQL not supported: an INTERVAL value is only accepted as the right"
    " operand of `<constant DATE> + INTERVAL '<n>' <unit>` / `<constant DATE>"
    " - INTERVAL '<n>' <unit>` (or `INTERVAL ... + <constant DATE>`); it is"
    " folded into a DATE at bind time and the plan has no INTERVAL type"
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


def interval_date_fold(sx: SqlExpr, var date_side: Expr) raises -> Expr:
    """Fold `date_side +/- INTERVAL` (the `interval_operand_side` shapes) into
    a DATE literal. `date_side` is the bound non-INTERVAL operand: anything
    but a DATE literal is refused by name."""
    var which = interval_operand_side(sx)
    ref b = sx._binary.value()
    var n: Int
    var unit: UInt8
    if which == 2:
        n = Int(b.right[].int_val)
        unit = b.right[].op
    else:
        n = Int(b.left[].int_val)
        unit = b.left[].op
    if not date_side.is_literal() or not date_side.literal_value().is_date32():
        raise Error(
            "SQL not supported: DATE +/- INTERVAL needs a constant DATE"
            " (`DATE 'YYYY-MM-DD'`, possibly already shifted by another"
            " INTERVAL); a column or other non-constant operand is refused"
            " because the INTERVAL is folded at bind time"
        )
    var base = Int(date_side.literal_value().date32_val)
    if which == 2 and sx.op == SXOP_SUB:
        n = -n
    var out: Int
    if unit == SXIVL_YEAR:
        out = date_add_months(base, n * 12)
    elif unit == SXIVL_MONTH:
        out = date_add_months(base, n)
    elif unit == SXIVL_WEEK:
        out = date_add_days(base, n * 7)
    elif unit == SXIVL_DAY:
        out = date_add_days(base, n)
    else:
        raise Error(INTERVAL_STANDALONE_REFUSAL)
    return Expr.literal(ScalarValue.date32(Int32(out)))
