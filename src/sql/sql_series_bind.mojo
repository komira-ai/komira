# =============================================================================
# sql/sql_series_bind.mojo
#   Binds `generate_series(...)` / `range(...)` in FROM: the parsed call
#   (`SeriesCall`) becomes a `SeriesSpec` and the scan of the
#   `komira.generate_series` source, matching DuckDB v1.5.6.
# =============================================================================
#
# Overloads, as DuckDB resolves them:
#
#   * integers: `f(stop)` (from 0), `f(start, stop)`, `f(start, stop, step)`,
#     BIGINT out. The step defaults to 1.
#   * temporal: `f(start, stop, step)` with DATE or TIMESTAMP bounds (mixing
#     allowed) and an INTERVAL step, TIMESTAMP out. A DATE is its midnight.
#
# `generate_series` includes `stop`, `range` excludes it. A step pointing away
# from `stop` is no rows. A NULL argument is no rows (even with a zero step),
# typed by the overload the other arguments pick; all-NULL arguments type
# BIGINT. A zero step is refused, as DuckDB's `interval cannot be 0!`.
#
# Refused by name: every shape DuckDB has no overload for (two bounds that are
# DATE / TIMESTAMP, an integer step with temporal bounds, an interval step with
# integer bounds, strings, decimals, other arities), an argument that is not a
# literal or NULL (a column reference is a LATERAL argument), TIMESTAMPTZ, and
# an interval step beyond 64 bits of microseconds.

from arrow.schema import Schema
from plan_ir.logical_plan import LogicalPlan
from scan_source.series_scan import (
    SeriesSpec, US_PER_DAY, series_scan_binding,
)
from scan_source.source_variant import SourceVariant
from sql.sql_ast import (
    FromRelation, SXIVL_DAY, SXIVL_HOUR, SXIVL_MINUTE, SXIVL_MONTH,
    SXIVL_SECOND, SXIVL_WEEK, SXIVL_YEAR,
)
from sql.sql_bind_scope import _date_to_days
from sql.sql_bind_timestamp import _timestamp_literal_micros
from sql.sql_series_ast import (
    SERIES_ARG_COLUMN, SERIES_ARG_DATE, SERIES_ARG_DECIMAL, SERIES_ARG_INT,
    SERIES_ARG_INTERVAL, SERIES_ARG_NULL, SERIES_ARG_OTHER, SERIES_ARG_STRING,
    SERIES_ARG_TIMESTAMP, SERIES_ARG_TIMESTAMPTZ, SeriesArg, SeriesCall,
)

comptime _US_PER_SECOND: Int64 = 1_000_000


def _refuse_arg(fn_name: String, pos: Int, arg: SeriesArg) raises:
    """Raises, by name, for an argument that cannot be part of any series."""
    var which = String(pos + 1)
    if arg.kind == SERIES_ARG_COLUMN:
        raise Error(
            "SQL not supported: " + fn_name + "() with the column `" + arg.text
            + "` as argument " + which + " (a column-valued, LATERAL, table"
            " function argument); the arguments must be literals or NULL"
        )
    if arg.kind == SERIES_ARG_OTHER:
        raise Error(
            "SQL not supported: " + fn_name + "() argument " + which
            + " is not a literal; only integer, DATE, TIMESTAMP and INTERVAL"
            " literals and NULL are accepted"
        )
    if arg.kind == SERIES_ARG_STRING:
        raise Error(
            "SQL bind error: no function matches " + fn_name + "() with a"
            " string as argument " + which + " (integer, DATE, TIMESTAMP and"
            " INTERVAL arguments only)"
        )
    if arg.kind == SERIES_ARG_DECIMAL:
        raise Error(
            "SQL bind error: no function matches " + fn_name + "() with a"
            " decimal as argument " + which + " (integer, DATE, TIMESTAMP and"
            " INTERVAL arguments only)"
        )
    if arg.kind == SERIES_ARG_TIMESTAMPTZ:
        raise Error(
            "SQL not supported: " + fn_name + "() over TIMESTAMPTZ (a series"
            " of TIMESTAMP WITH TIME ZONE); use DATE or TIMESTAMP"
        )


def _interval_step(arg: SeriesArg) raises -> Tuple[Int64, Int64]:
    """(microseconds, months) of an INTERVAL literal: exactly one is non-zero.
    A week, day or sub-day unit is microseconds, refused when the product
    leaves 64 bits; a month or year unit is months. A zero count is refused."""
    if arg.int_val == 0:
        raise Error("SQL bind error: interval cannot be 0!")
    var unit = arg.unit
    if unit == SXIVL_YEAR:
        return (Int64(0), arg.int_val * 12)
    if unit == SXIVL_MONTH:
        return (Int64(0), arg.int_val)
    var per: Int64
    if unit == SXIVL_WEEK:
        per = 7 * US_PER_DAY
    elif unit == SXIVL_DAY:
        per = US_PER_DAY
    elif unit == SXIVL_HOUR:
        per = 3600 * _US_PER_SECOND
    elif unit == SXIVL_MINUTE:
        per = 60 * _US_PER_SECOND
    else:
        per = _US_PER_SECOND
    var limit = Int64.MAX // per
    if arg.int_val > limit or arg.int_val < -limit:
        raise Error(
            "SQL not supported: the INTERVAL step " + String(arg.int_val)
            + " of a series is beyond 64 bits of microseconds"
        )
    return (arg.int_val * per, Int64(0))


def _bound_micros(arg: SeriesArg) raises -> Int64:
    if arg.kind == SERIES_ARG_DATE:
        return Int64(Int(_date_to_days(arg.text))) * US_PER_DAY
    return _timestamp_literal_micros(arg.text, False)


def _is_temporal_bound(arg: SeriesArg) -> Bool:
    return arg.kind == SERIES_ARG_DATE or arg.kind == SERIES_ARG_TIMESTAMP


def _no_match(call: SeriesCall) -> Error:
    var shapes = String("")
    for i in range(len(call.args)):
        if i > 0:
            shapes += ", "
        var k = call.args[i].kind
        if k == SERIES_ARG_INT:
            shapes += "INTEGER"
        elif k == SERIES_ARG_NULL:
            shapes += "NULL"
        elif k == SERIES_ARG_DATE:
            shapes += "DATE"
        elif k == SERIES_ARG_TIMESTAMP:
            shapes += "TIMESTAMP"
        else:
            shapes += "INTERVAL"
    return Error(
        "SQL bind error: no function matches " + call.fn_name + "(" + shapes
        + "); the forms are (INTEGER [, INTEGER [, INTEGER]]) and (DATE |"
        " TIMESTAMP, DATE | TIMESTAMP, INTERVAL)"
    )


def series_spec_of_call(call: SeriesCall) raises -> SeriesSpec:
    """The `SeriesSpec` of a series call (the rules of this file's header)."""
    var n = len(call.args)
    var inclusive = call.fn_name == "generate_series"
    var column = call.fn_name
    if len(call.column_names) > 0:
        column = call.column_names[0]
    if n < 1 or n > 3:
        raise Error(
            "SQL bind error: no function matches " + call.fn_name + "() with "
            + String(n) + " arguments (1 to 3 are taken)"
        )
    var any_null = False
    var temporal = False
    var has_int = False
    for i in range(n):
        _refuse_arg(call.fn_name, i, call.args[i])
        var k = call.args[i].kind
        if k == SERIES_ARG_NULL:
            any_null = True
        elif k == SERIES_ARG_INT:
            has_int = True
        else:
            temporal = True
    if temporal:
        # (DATE|TIMESTAMP|NULL, DATE|TIMESTAMP|NULL, INTERVAL|NULL), no integer.
        if (
            n != 3
            or has_int
            or call.args[0].kind == SERIES_ARG_INTERVAL
            or call.args[1].kind == SERIES_ARG_INTERVAL
            or _is_temporal_bound(call.args[2])
        ):
            raise _no_match(call)
        if any_null:
            return SeriesSpec.empty(column^, True)
        var start = _bound_micros(call.args[0])
        var stop = _bound_micros(call.args[1])
        var step_pair = _interval_step(call.args[2])
        var spec = SeriesSpec(
            column^, True, start, stop, step_pair[0], step_pair[1], inclusive
        )
        spec.check()
        return spec^
    # Integers and NULLs.
    if any_null:
        return SeriesSpec.empty(column^, False)
    var first: Int64 = 0
    var stop: Int64
    var step: Int64 = 1
    if n == 1:
        stop = call.args[0].int_val
    else:
        first = call.args[0].int_val
        stop = call.args[1].int_val
        if n == 3:
            step = call.args[2].int_val
    if step == 0:
        raise Error("SQL bind error: interval cannot be 0!")
    var spec = SeriesSpec(column^, False, first, stop, step, 0, inclusive)
    spec.check()
    return spec^


def series_relation_schema(rel: FromRelation) raises -> Schema:
    """The one-column schema of a series relation."""
    return series_spec_of_call(rel.series.value()).schema()


def series_relation_scan(rel: FromRelation) raises -> LogicalPlan:
    """The scan of a series relation: the `komira.generate_series` binding of
    its spec, with the row count when the step is fixed and the count fits."""
    ref call = rel.series.value()
    var spec = series_spec_of_call(call)
    var schema = spec.schema()
    var rows: Optional[Int] = None
    var counted = spec.row_count()
    if counted and counted.value() <= UInt64(Int.MAX):
        rows = Int(counted.value())
    var src = SourceVariant.from_binding(
        series_scan_binding(spec, call.fn_name)
    )
    return LogicalPlan.scan_from_source(src^, schema^, row_count=rows^)
