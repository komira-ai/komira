# =============================================================================
# komira_sql/sql_interval_parse.mojo
#   The INTERVAL literal grammar: `INTERVAL '<n>' <unit>` and
#   `INTERVAL [+|-]<n> <unit>`. See `SX_INTERVAL` in sql_ast.
# =============================================================================

from komira_sql.sql_ast import (
    SXIVL_DAY, SXIVL_MONTH, SXIVL_WEEK, SXIVL_YEAR, SqlExpr,
)
from komira_sql.sql_token import (
    TK_IDENT, TK_INT, TK_MINUS, TK_PLUS, TK_STRING, Token,
)


def _is_unit_word(w: String) -> Bool:
    """Every word the grammar reads as an INTERVAL unit, accepted or refused,
    so `interval -3 hour` is refused by the unit and not read as a column."""
    if (
        w == "year" or w == "years" or w == "month" or w == "months"
        or w == "week" or w == "weeks" or w == "day" or w == "days"
    ):
        return True
    return (
        w == "quarter" or w == "quarters" or w == "hour" or w == "hours"
        or w == "minute" or w == "minutes" or w == "second" or w == "seconds"
        or w == "millisecond" or w == "milliseconds" or w == "microsecond"
        or w == "microseconds" or w == "decade" or w == "decades"
        or w == "century" or w == "centuries" or w == "millennium"
        or w == "millennia"
    )


def interval_literal_starts(tokens: List[Token], pos: Int) -> Bool:
    """True when the token at `pos` is `interval` and what follows is an
    INTERVAL literal rather than a column named `interval`: a string, an
    integer, or a sign then an integer then a unit word (`interval -3 day`;
    without the unit word `interval - 3` is a column minus 3)."""
    if pos + 1 >= len(tokens):
        return False
    if tokens[pos].kind != TK_IDENT or tokens[pos].text != "interval":
        return False
    var k = tokens[pos + 1].kind
    if k == TK_STRING or k == TK_INT:
        return True
    if (k == TK_MINUS or k == TK_PLUS) and pos + 3 < len(tokens):
        return (
            tokens[pos + 2].kind == TK_INT
            and tokens[pos + 3].kind == TK_IDENT
            and _is_unit_word(tokens[pos + 3].text)
        )
    return False


def parse_interval_literal(tokens: List[Token], mut pos: Int) raises -> SqlExpr:
    """`INTERVAL '<n>' <unit>` or `INTERVAL [+|-]<n> <unit>` with `pos` on
    `interval`; leaves `pos` after the unit. The count is an optionally signed
    decimal integer, quoted or bare, of magnitude at most 10^9. Units accepted:
    YEAR, MONTH, WEEK, DAY (and plurals). Refused by name: every other unit, a
    unit written inside the string (`'3 month'`), a non-integer count, a count
    beyond 10^9 and a missing unit."""
    pos += 1  # 'interval'
    var count: Int64 = 0
    if tokens[pos].kind == TK_STRING:
        var raw = String(tokens[pos].text)
        var b = raw.as_bytes()
        var neg = False
        var start = 0
        if len(b) > 0 and (b[0] == UInt8(ord("-")) or b[0] == UInt8(ord("+"))):
            neg = b[0] == UInt8(ord("-"))
            start = 1
        var ok = start < len(b) and len(b) - start <= 10
        for k in range(start, len(b)):
            if b[k] < UInt8(ord("0")) or b[k] > UInt8(ord("9")):
                ok = False
        if not ok:
            raise Error(
                "SQL not supported: INTERVAL '" + raw + "' is not a plain"
                " integer count; write INTERVAL '<n>' <unit> with the unit"
                " outside the quotes (units YEAR, MONTH, WEEK, DAY)"
            )
        for k in range(start, len(b)):
            count = count * 10 + Int64(Int(b[k] - UInt8(ord("0"))))
        if neg:
            count = -count
    else:
        var neg = False
        if tokens[pos].kind == TK_MINUS or tokens[pos].kind == TK_PLUS:
            neg = tokens[pos].kind == TK_MINUS
            pos += 1
        if tokens[pos].text.byte_length() > 0:
            raise Error("SQL not supported: INTERVAL count beyond 10^9")
        count = tokens[pos].int_val
        if neg:
            count = -count
    if count > 1000000000 or count < -1000000000:
        raise Error(
            "SQL not supported: INTERVAL count " + String(count)
            + " is beyond +/-10^9"
        )
    pos += 1  # the count
    if pos >= len(tokens) or tokens[pos].kind != TK_IDENT:
        raise Error(
            "SQL syntax error: INTERVAL needs a unit after the count"
            " (YEAR, MONTH, WEEK or DAY)"
        )
    var u = String(tokens[pos].text)
    var unit: UInt8
    if u == "year" or u == "years":
        unit = SXIVL_YEAR
    elif u == "month" or u == "months":
        unit = SXIVL_MONTH
    elif u == "week" or u == "weeks":
        unit = SXIVL_WEEK
    elif u == "day" or u == "days":
        unit = SXIVL_DAY
    else:
        raise Error(
            "SQL not supported: INTERVAL unit '" + u + "' (only YEAR,"
            " MONTH, WEEK and DAY are accepted; QUARTER, HOUR, MINUTE,"
            " SECOND and the sub-second and multi-year units are refused)"
        )
    pos += 1  # the unit
    return SqlExpr.interval_lit(count, unit)
