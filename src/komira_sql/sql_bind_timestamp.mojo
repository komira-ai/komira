# =============================================================================
# komira_sql/sql_bind_timestamp.mojo
#   CAST target types, make_timestamp and TIMESTAMP literals.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_sql.sql_ast import SqlExpr
from komira_sql.sql_bind_expr import _bind_scalar
from komira_sql.sql_bind_scope import (
    CteScope, _date_to_days, BindScope,
)
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    DSG_MAKE_TS_MS, DSG_MAKE_TS_NS,
)


def _sql_cast_target_arrow(ty: String) raises -> ArrowType:
    """One written SQL type name -> the `ArrowType` this engine converts to.

    The table is the served set, not DuckDB's type system: INTEGER, BIGINT,
    REAL and DOUBLE (with their aliases). Every other type DuckDB names is
    refused by name, naming the type the query wrote, rather than cast to the
    nearest served type (`CAST(x AS DECIMAL(18,4))` lowered to DOUBLE would
    answer `0.30000000000000004` where DuckDB answers `0.3000`).

    `FLOAT` is four bytes: in DuckDB v1.5.3 `FLOAT` is an alias of `REAL` /
    `FLOAT4`, and `DOUBLE` is the 8-byte one (`CAST(1.1 AS FLOAT)` answers
    1.100000023841858 there).

    The name arrives lower-folded (`sql_token.tokenize` lower-folds every
    identifier), and a parameterised type arrives with its parameters
    (`decimal(18,4)`), which lets the refusal quote the query back.
    """
    if ty == "integer" or ty == "int" or ty == "int4" or ty == "int32" or ty == "signed":
        return ArrowType.INT32
    if ty == "bigint" or ty == "int8" or ty == "int64" or ty == "long":
        return ArrowType.INT64
    # FLOAT32 is served as a target because the cast set covers all twelve
    # ordered pairs over {INT32, INT64, FLOAT32, FLOAT64} plus
    # DECIMAL128 -> FLOAT32. A target is admitted only when every numeric
    # source reaches it.
    if ty == "real" or ty == "float4" or ty == "float32" or ty == "float":
        return ArrowType.FLOAT32
    if (
        ty == "double"
        or ty == "double precision"
        or ty == "float8"
        or ty == "float64"
    ):
        return ArrowType.FLOAT64
    # VARCHAR is never admitted here: this table cannot see the operand, and
    # number-to-text formatting is not graded against DuckDB cell for cell
    # (DuckDB v1.5.3 prints 1e308 as "1e+308"), so a float operand would risk
    # a text that differs. `_bind_cast` serves an INTEGER / BIGINT / VARCHAR
    # operand before calling this function, so every cast that reaches this
    # raise has some other operand.
    if ty == "varchar" or ty == "text" or ty == "string" or ty == "char":
        raise Error(
            "SQL not supported: CAST to " + ty.upper() + " from this operand."
            " Number-to-text FORMATTING has not been graded against DuckDB"
            " cell for cell (v1.5.3 prints 1e308 as \"1e+308\", a DECIMAL"
            " literal -0.0 as \"0.0\" but a DOUBLE -0.0 as \"-0.0\"), and a"
            " text column that differs from DuckDB in one cell is a wrong"
            " answer with a success code. CAST"
            " (not TRY_CAST) to VARCHAR IS served from an INTEGER / BIGINT /"
            " VARCHAR operand -- an integer-to-text CAST cannot fail, so for"
            " one TRY_CAST is the same answer. A FLOAT or DECIMAL operand can"
            " be cast to BIGINT first, which ROUNDS its fraction away (a"
            " different text). A narrower or unsigned integer, a BOOLEAN, a"
            " DATE or a TIMESTAMP operand has no remedy at this door: DuckDB"
            " refuses CAST(<date> AS BIGINT), and this engine's casts do not"
            " reach BIGINT from the others."
        )
    # DECIMAL / NUMERIC does not reach this raise from the CAST arm:
    # `_bind_cast` intercepts a decimal target before calling this function
    # and folds a literal argument exactly (`_bind_decimal_literal_cast`),
    # refusing a column argument itself.
    raise Error(
        "SQL not supported: CAST to " + ty.upper() + ". This engine converts"
        " to INTEGER / BIGINT / REAL / DOUBLE — the four targets its cast"
        " kernels reach from every numeric source — and refuses every other"
        " target BY NAME"
        " rather than approximating it with the nearest one: a CAST that"
        " answered a number of the wrong type would be a wrong answer with a"
        " success code."
    )


def _bind_make_timestamp_epoch(
    sx: SqlExpr,
    dsg: UInt8,
    schema: Schema,
    scope: BindScope,
    catalog: SqlCatalog,
    cte_scope: CteScope,
    prebound: List[Expr],
) raises -> Expr:
    """`make_timestamp(m)` / `make_timestamp_ms(m)` / `make_timestamp_ns(m)` —
    an INTEGER TICK COUNT SINCE 1970-01-01, labelled with the unit it is in.

    The argument is a tick count, not a year (DuckDB v1.5.5's catalog names
    the parameter `year`):

        make_timestamp(1)                -> 1970-01-01 00:00:00.000001
        make_timestamp(0)                -> 1970-01-01 00:00:00
        make_timestamp(-1)               -> 1969-12-31 23:59:59.999999
        make_timestamp(1700000000000000) -> 2023-11-14 22:13:20

    i.e. microseconds. A tick count is already a temporal quantity that only
    needs its unit label, which `Expr.cast_to_arrow` from INT64 to a
    TIMESTAMP type gives (no scaling).

    The three units differ: `make_timestamp` -> TIMESTAMP (microseconds),
    `make_timestamp_ns` -> TIMESTAMP_NS, but `make_timestamp_ms` ->
    TIMESTAMP, a millisecond input and a microsecond output. So `_ms` is
    labelled TIMESTAMP_MS and then cast to TIMESTAMP_US, which scales by 1000.
    """
    ref cargs = sx._call.value().args
    var n = len(cargs)
    var fname = String(sx.text)

    # ---- The component overload, refused by arity ---------------------------
    # The row is `FN_ARITY_OWN` because `make_timestamp` is both an epoch
    # constructor (arity 1) and a calendar constructor (arity 6) in DuckDB
    # v1.5.5, and the two need different primitives: relabelling the calendar
    # form would read its YEAR as microseconds.
    if n == 6 and fname == "make_timestamp":
        raise Error(
            "SQL not supported: the SIX-ARGUMENT `make_timestamp(year, month,"
            " day, hour, minute, seconds)` MINTS A TEMPORAL VALUE from CALENDAR"
            " COMPONENTS, and THE MISSING PRIMITIVE IS CIVIL-CALENDAR-TO-DAYS"
            " — month lengths and the Gregorian leap rule — which no `EXPR_*`"
            " tag or binder desugar in this engine computes. ⚠ THE ONE-ARGUMENT"
            " OVERLOAD OF THE SAME NAME IS SERVED, and the difference is not"
            " arity for its own sake: `make_timestamp(<n>)` is a MICROSECOND"
            " COUNT SINCE 1970-01-01 (measured DuckDB v1.5.5:"
            " `make_timestamp(1)` is `1970-01-01 00:00:00.000001`), i.e. a"
            " temporal quantity that only has to be LABELLED, while the"
            " six-argument form has to be COMPUTED. ⛔ DO NOT 'FIX' THIS BY"
            " LOWERING IT TO THE SAME RELABEL: that reinterprets the YEAR as a"
            " microsecond count and answers a wrong instant with a success"
            " code. Spell the instant as a microsecond count, or use a"
            " TIMESTAMP literal."
        )
    if n != 1:
        raise Error(
            "SQL bind error: `" + fname + "` takes exactly ONE argument here —"
            " an INTEGER tick count since 1970-01-01 — but got "
            + String(n) + ". (DuckDB v1.5.5 also gives `make_timestamp` a"
            " six-argument calendar overload; this engine refuses that one by"
            " name, because it needs civil-calendar arithmetic this engine does"
            " not have.)"
        )

    var child = _bind_scalar(cargs[0], schema, scope, catalog, cte_scope, prebound)

    # ---- The operand type, checked at bind ----------------------------------
    # The relabel needs an integer operand; any other type is refused here by
    # name. `walk_expr_field` types any expression, so a computed operand
    # (`make_timestamp(event_time * 1000000)`) is checked too; its `missing`
    # is discarded (an unresolved column has already raised in `_bind_scalar`).
    var missing = String("")
    var at = walk_expr_field[PlanColRefFields](child, schema, missing).arrow_type
    if at != ArrowType.INT64 and at != ArrowType.INT32:
        raise Error(
            "SQL not supported: `" + fname + "` takes an INTEGER tick count"
            " since 1970-01-01, but this argument is of type " + String(at)
            + ". ⛔ REFUSED RATHER THAN COERCED: the lowering LABELS the"
            " operand's own integer as a temporal unit, so a non-integer"
            " operand has no correct reading — a floating-point count would"
            " have to be rounded (and DuckDB's rounding model for that is not"
            " graded in this tree), and a string would have to be PARSED,"
            " which is the separate gap `strptime` is refused for. Cast the"
            " argument to BIGINT if that is what you meant."
        )

    # ⚠ AN INT32 OPERAND IS WIDENED, NOT RELABELLED. A 4-byte column relabelled
    # to an 8-byte timestamp would read two rows as one instant — a wrong
    # answer with a success code. DuckDB reaches the BIGINT overload by an
    # implicit widening cast, and `INT32 -> int64` is an existing arm of the
    # same ladder, so this reproduces its behaviour rather than approximating
    # it.
    var ticks = child^
    if at == ArrowType.INT32:
        ticks = Expr.cast_to_arrow(ticks^, ArrowType.INT64)

    if dsg == DSG_MAKE_TS_NS:
        return Expr.cast_to_arrow(ticks^, ArrowType.TIMESTAMP_NS)
    if dsg == DSG_MAKE_TS_MS:
        # MILLISECOND in, MICROSECOND out — see the docstring. The inner cast
        # states the unit the COUNT is in; the outer one is the ladder's
        # unit-conversion arm, which multiplies by 1000 and clones validity.
        return Expr.cast_to_arrow(
            Expr.cast_to_arrow(ticks^, ArrowType.TIMESTAMP_MS),
            ArrowType.TIMESTAMP_US,
        )
    return Expr.cast_to_arrow(ticks^, ArrowType.TIMESTAMP_US)


def _timestamp_literal_micros(text: String, aware: Bool) raises -> Int64:
    """`TIMESTAMP '...'` / `TIMESTAMPTZ '...'` -> microseconds since the epoch.

    The values match DuckDB v1.5.3's `epoch_us` of the same literal:

        epoch_us(TIMESTAMP   '2021-01-01 03:30:15.123456')    -> 1609471815123456
        epoch_us(TIMESTAMP   '2021-01-01T03:30:15')           -> 1609471815000000
        epoch_us(TIMESTAMP   '2021-01-01 03:30')              -> 1609471800000000
        epoch_us(TIMESTAMP   '2021-01-01')                    -> 1609459200000000
        epoch_us(TIMESTAMP   '2021-01-01 03:30:15.1234567')   -> 1609471815123456
        epoch_us(TIMESTAMP   '1969-12-31 23:59:59.999999')    -> -1
        epoch_us(TIMESTAMPTZ '2021-01-01 03:30:15.123456Z')   -> 1609471815123456
        epoch_us(TIMESTAMPTZ '2021-01-01 03:30:15.123456+02') -> 1609464615123456
        epoch_us(TIMESTAMPTZ '2021-01-01 03:30:15.123456-05:30') -> 1609491615123456

    so a sub-microsecond tail truncates (`.1234567` keeps 123456) and an
    offset is subtracted.

    Two shapes are refused by name, both about a session timezone this engine
    does not have:

      * `TIMESTAMPTZ '<no offset>'`: DuckDB reads the digits in the session's
        zone, and there is no session timezone here;
      * `TIMESTAMP '<with an offset>'`: DuckDB discards an offset the query
        wrote; refusing names it.

    The result carries no unit and no zone (`ScalarValue` has one timestamp
    member, in microseconds, and no tz field), so it is normalised to UTC
    micros: a zone-aware Arrow timestamp column stores UTC micros too. A naive
    literal against a zone-aware column is therefore read as UTC, where DuckDB
    would read it in the session zone."""
    var raw = text
    var b = raw.as_bytes()
    var lo = 0
    var hi = len(b)
    while lo < hi and (b[lo] == UInt8(32) or b[lo] == UInt8(9)):
        lo += 1
    while hi > lo and (b[hi - 1] == UInt8(32) or b[hi - 1] == UInt8(9)):
        hi -= 1
    if hi - lo < 10:
        raise Error(
            "SQL bind error: malformed timestamp literal '" + text + "' (want"
            " YYYY-MM-DD[ HH:MM[:SS[.ffffff]]])"
        )
    var days = _date_to_days(String(raw[byte=lo : lo + 10]))
    var micros = Int64(Int(days)) * Int64(86400000000)
    var i = lo + 10
    if i < hi:
        # The separator is a space or a `T`; both are accepted by the dialect.
        if b[i] != UInt8(32) and b[i] != UInt8(ord("T")) and b[i] != UInt8(ord("t")):
            raise Error(
                "SQL bind error: malformed timestamp literal '" + text + "':"
                " expected a space or 'T' after the date, got '"
                + String(raw[byte=i : i + 1]) + "'"
            )
        i += 1
        var parts = List[Int64](capacity=3)
        parts.append(Int64(0))
        parts.append(Int64(0))
        parts.append(Int64(0))
        var nparts = 0
        while nparts < 3:
            var digits = 0
            var acc = Int64(0)
            while i < hi and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
                acc = acc * Int64(10) + Int64(Int(b[i] - UInt8(ord("0"))))
                digits += 1
                i += 1
            if digits == 0:
                raise Error(
                    "SQL bind error: malformed timestamp literal '" + text
                    + "': expected HH:MM[:SS[.ffffff]] after the date"
                )
            parts[nparts] = acc
            nparts += 1
            if i < hi and b[i] == UInt8(ord(":")) and nparts < 3:
                i += 1
            else:
                break
        if parts[0] > 23 or parts[1] > 59 or parts[2] > 59:
            raise Error(
                "SQL bind error: timestamp literal '" + text + "' has a"
                " time-of-day field out of range"
            )
        micros += parts[0] * Int64(3600000000)
        micros += parts[1] * Int64(60000000)
        micros += parts[2] * Int64(1000000)
        if i < hi and b[i] == UInt8(ord(".")):
            i += 1
            var kept = 0
            var frac = Int64(0)
            var any_digit = False
            while i < hi and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
                any_digit = True
                if kept < 6:
                    frac = frac * Int64(10) + Int64(Int(b[i] - UInt8(ord("0"))))
                    kept += 1
                # ⚠ DIGIT SEVEN ONWARD IS DROPPED, NOT ROUNDED — measured
                # above: `.1234567` keeps 123456.
                i += 1
            if not any_digit:
                raise Error(
                    "SQL bind error: malformed timestamp literal '" + text
                    + "': a '.' with no fractional digits after it"
                )
            while kept < 6:
                frac = frac * Int64(10)
                kept += 1
            micros += frac
    # ---- the zone, which is where the two keywords part company -------------
    var has_offset = False
    var offset_us = Int64(0)
    if i < hi:
        var c = b[i]
        if c == UInt8(ord("Z")) or c == UInt8(ord("z")):
            has_offset = True
            i += 1
        elif c == UInt8(ord("+")) or c == UInt8(ord("-")):
            var neg = c == UInt8(ord("-"))
            i += 1
            var oh = Int64(0)
            var od = 0
            while i < hi and od < 2 and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
                oh = oh * Int64(10) + Int64(Int(b[i] - UInt8(ord("0"))))
                od += 1
                i += 1
            if od == 0:
                raise Error(
                    "SQL bind error: malformed timestamp literal '" + text
                    + "': a zone sign with no hours after it"
                )
            var om = Int64(0)
            if i < hi and b[i] == UInt8(ord(":")):
                i += 1
                var md = 0
                while i < hi and md < 2 and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
                    om = om * Int64(10) + Int64(Int(b[i] - UInt8(ord("0"))))
                    md += 1
                    i += 1
                if md == 0:
                    raise Error(
                        "SQL bind error: malformed timestamp literal '" + text
                        + "': a zone with a ':' and no minutes after it"
                    )
            if oh > 23 or om > 59:
                raise Error(
                    "SQL bind error: timestamp literal '" + text + "' has a"
                    " UTC offset out of range"
                )
            has_offset = True
            offset_us = oh * Int64(3600000000) + om * Int64(60000000)
            if neg:
                offset_us = -offset_us
    if i < hi:
        raise Error(
            "SQL bind error: malformed timestamp literal '" + text + "':"
            " unexpected trailing text '" + String(raw[byte=i:hi]) + "'"
        )
    if aware and not has_offset:
        raise Error(
            "SQL not supported: TIMESTAMPTZ '" + text + "' WITHOUT A UTC"
            " OFFSET. Its instant depends on a SESSION TIMEZONE, and this"
            " engine has none — `ScalarValue` carries no timezone field at all"
            " — so there is nothing here that could read the same digits the"
            " way DuckDB does (DuckDB v1.5.3 reads these digits with no offset"
            " in its session zone). Write the"
            " offset: TIMESTAMPTZ '" + text + "+00'."
        )
    if (not aware) and has_offset:
        raise Error(
            "SQL not supported: TIMESTAMP '" + text + "' WITH a UTC offset."
            " ⚠ DuckDB v1.5.3 accepts this and SILENTLY DISCARDS the offset"
            " (measured: TIMESTAMP '2021-01-01 03:30:15.123456+02' is the same"
            " instant as the same text with no offset). This engine refuses"
            " rather than reproducing that, because an offset that changes"
            " nothing changes which rows a WHERE clause returns with no"
            " diagnostic anywhere. Use TIMESTAMPTZ '" + text + "' to honour the"
            " offset, or drop the offset to mean a wall clock."
        )
    return micros - offset_us


