# =============================================================================
# scan_source/series_scan.mojo
#   The `komira.generate_series` scan kind: the rows of `generate_series` and
#   `range` in FROM, a source that reads no input. `SeriesSpec` is the whole
#   description (one column, its bounds and its step); the binding carries it
#   as parameters, so a plan that holds one serializes like any binding scan,
#   and the values are computed by `series_values` a batch at a time, so a long
#   series is never held at once.
# =============================================================================
#
# Semantics are DuckDB's table functions (v1.5.6, measured):
#
#   * `generate_series(start, stop, step)` stops AT `stop` (inclusive),
#     `range(start, stop, step)` stops BEFORE it (exclusive).
#   * A step that points away from `stop` gives no rows (`generate_series(5, 1)`
#     is empty), as does `range(x, x)`; `generate_series(x, x)` is the one row x.
#   * Integer values are BIGINT; a DATE or TIMESTAMP series is TIMESTAMP
#     (microseconds, no zone), a DATE bound being its midnight.
#   * A timestamp step is an interval. A day, week or sub-day step adds a fixed
#     number of microseconds. A month or year step adds calendar months to the
#     PREVIOUS value, the day clamped to the end of its month, so a clamped day
#     never comes back: from 31 Jan by one month the values are 31 Jan, 29 Feb,
#     29 Mar, 29 Apr (2024).
#
# A zero step, a NULL argument and the argument types are the binder's to
# answer (DuckDB refuses a zero step and answers no rows for a NULL); a spec
# built here holds exactly one non-zero step.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from scan_source.pushdown_gate import PushdownGate
from scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_NONE,
)
from scan_source.scan_params import ScanParams, param_hash_string
from scan_source.source_variant import SourceVariant, SOURCE_VARIANT_BINDING

comptime SERIES_SCAN_KIND_NAME: StaticString = "komira.generate_series"
"""The kind name of the binding a `generate_series` / `range` scan carries."""

comptime _P_COLUMN: StaticString = "column"
comptime _P_TIMESTAMP: StaticString = "timestamp"
comptime _P_START: StaticString = "start"
comptime _P_STOP: StaticString = "stop"
comptime _P_STEP: StaticString = "step"
comptime _P_STEP_MONTHS: StaticString = "step_months"
comptime _P_INCLUSIVE: StaticString = "inclusive"

comptime US_PER_DAY: Int64 = 86_400_000_000
"""Microseconds in a day: a DATE bound is `days * US_PER_DAY`."""

comptime _GREGORIAN_CYCLE_MONTHS: Int = 4800
comptime _MAX_DAY: Int64 = Int64.MAX // US_PER_DAY
"""The last day whose midnight is a TIMESTAMP; its negation is the first."""
comptime SERIES_TIMESTAMP_OVERFLOW: StaticString = (
    "generate_series: Overflow exception in date/time -> timestamp conversion"
    " (a value of the series is beyond the TIMESTAMP range)"
)
"""What a month-step series raises when a value it reaches, including the one
after the last in range, is beyond the TIMESTAMP range, as DuckDB raises."""
"""400 years: the days in a month repeat with this period of month indices."""


struct SeriesSpec(Copyable, Movable):
    """One generated column: its name, its type (BIGINT, or TIMESTAMP in
    microseconds when `timestamp`), the first value, the bound, and the step.

    `step` is the fixed step (an integer, or microseconds); `step_months` is a
    calendar step in months, for a timestamp series only. Exactly one of the
    two is non-zero. `inclusive` is True for `generate_series` (the bound is a
    value when the steps land on it) and False for `range`."""

    var column: String
    var timestamp: Bool
    var start: Int64
    var stop: Int64
    var step: Int64
    var step_months: Int64
    var inclusive: Bool

    def __init__(
        out self,
        var column: String,
        timestamp: Bool,
        start: Int64,
        stop: Int64,
        step: Int64,
        step_months: Int64,
        inclusive: Bool,
    ):
        self.column = column^
        self.timestamp = timestamp
        self.start = start
        self.stop = stop
        self.step = step
        self.step_months = step_months
        self.inclusive = inclusive

    @staticmethod
    def empty(var column: String, timestamp: Bool) -> SeriesSpec:
        """A series of no rows (what a NULL argument gives): `range(0, 0)`."""
        return SeriesSpec(column^, timestamp, 0, 0, 1, 0, False)

    def arrow_type(self) -> ArrowType:
        """BIGINT, or TIMESTAMP in microseconds."""
        if self.timestamp:
            return ArrowType.TIMESTAMP_US
        return ArrowType.INT64

    def schema(self) -> Schema:
        """The one column, never NULL."""
        var sb = SchemaBuilder()
        sb.add_field(Field(self.column, self.arrow_type(), False))
        return sb.build()

    def check(self) raises:
        """Raises unless exactly one step is non-zero and a month step is on a
        timestamp series."""
        if (self.step == 0) == (self.step_months == 0):
            raise Error(
                "generate_series: a series needs exactly one non-zero step"
                " (step " + String(self.step) + ", step_months "
                + String(self.step_months) + ")"
            )
        if self.step_months != 0 and not self.timestamp:
            raise Error(
                "generate_series: a month step needs a TIMESTAMP series"
            )

    def row_count(self) -> Optional[UInt64]:
        """The number of rows of a fixed-step series (saturating at the
        UInt64 maximum); None for a month step, whose count is not
        computed ahead."""
        if self.step_months != 0:
            return None
        return Optional(_fixed_count(self))


# =============================================================================
# The binding.
# =============================================================================


def series_scan_binding(spec: SeriesSpec, var name: String) -> ScanBinding:
    """The `komira.generate_series` binding of `spec`, named `name` (the
    function's name). Every field of the spec is a parameter, so two series
    differ in identity exactly when they differ in rows or column. Nothing is
    pushed into it: a filter stays an operator above the scan."""
    var params = ScanParams()
    params.put_str(String(_P_COLUMN), spec.column)
    params.put_bool(String(_P_TIMESTAMP), spec.timestamp)
    params.put_i64(String(_P_START), spec.start)
    params.put_i64(String(_P_STOP), spec.stop)
    params.put_i64(String(_P_STEP), spec.step)
    params.put_i64(String(_P_STEP_MONTHS), spec.step_months)
    params.put_bool(String(_P_INCLUSIVE), spec.inclusive)
    var kind = String(SERIES_SCAN_KIND_NAME)
    var fp = params.hash_into(
        param_hash_string(kind, UInt64(scan_kind_id(kind)))
    )
    return ScanBinding(
        kind_id=scan_kind_id(kind),
        kind_name=kind,
        name=name^,
        params=params^,
        schema=spec.schema(),
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_NONE,
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def is_series_binding(source: SourceVariant) -> Bool:
    """True iff `source` is a binding of the `komira.generate_series` kind."""
    if source.tag != SOURCE_VARIANT_BINDING:
        return False
    return source.binding_ref().kind_name == String(SERIES_SCAN_KIND_NAME)


def series_spec_of(binding: ScanBinding) raises -> SeriesSpec:
    """The spec a `komira.generate_series` binding carries.

    Raises:
        When the binding is of another kind, lacks a parameter, or holds a
        spec `SeriesSpec.check` refuses.
    """
    if binding.kind_name != String(SERIES_SCAN_KIND_NAME):
        raise Error(
            "generate_series: a binding of kind " + binding.kind_name
            + " is not a series"
        )
    ref p = binding.params
    var keys: List[String] = [
        String(_P_COLUMN), String(_P_TIMESTAMP), String(_P_START),
        String(_P_STOP), String(_P_STEP), String(_P_STEP_MONTHS),
        String(_P_INCLUSIVE),
    ]
    for i in range(len(keys)):
        if not p.has(keys[i]):
            raise Error(
                "generate_series: the binding has no '" + keys[i]
                + "' parameter"
            )
    var spec = SeriesSpec(
        p.get_str(String(_P_COLUMN)),
        p.get_bool(String(_P_TIMESTAMP)),
        p.get_i64(String(_P_START)),
        p.get_i64(String(_P_STOP)),
        p.get_i64(String(_P_STEP)),
        p.get_i64(String(_P_STEP_MONTHS)),
        p.get_bool(String(_P_INCLUSIVE)),
    )
    spec.check()
    return spec^


# =============================================================================
# The values.
# =============================================================================


def series_values(
    spec: SeriesSpec, first: UInt64, limit: Int
) raises -> List[Int64]:
    """The values of `spec` at row indices `first`, `first + 1`, ... : at most
    `limit` of them, fewer when the series ends inside that window, none when
    it ends at or before `first`. Each call costs O(limit) (a month step adds at
    most one 400-year cycle of month lengths to find the window's first day),
    whatever `first` is.

    Raises:
        `SERIES_TIMESTAMP_OVERFLOW` when a month step reaches a value beyond
        the TIMESTAMP range, the one after the last row included (DuckDB
        computes it too, and raises).
    """
    spec.check()
    var out = List[Int64]()
    if limit <= 0:
        return out^
    if spec.step_months == 0:
        var total = _fixed_count(spec)
        if first >= total:
            return out^
        var n = total - first
        if n > UInt64(limit):
            n = UInt64(limit)
        var step = UInt64(spec.step)
        var v = UInt64(spec.start) + first * step
        for _ in range(Int(n)):
            out.append(Int64(v))
            v += step
        return out^
    var at = _month_value_at(spec, first)
    if not at:
        return out^
    var v = at.value()
    while _within(spec, v):
        out.append(v)
        if len(out) == limit:
            break
        v = _add_months_clamped(v, spec.start, spec.step_months)
    return out^


def _fixed_count(spec: SeriesSpec) -> UInt64:
    """The rows of a fixed-step series, saturating at the UInt64 maximum.
    The distance is taken in unsigned arithmetic, so a series from the Int64
    minimum to its maximum counts without overflow."""
    var dist: UInt64
    var mag: UInt64
    if spec.step > 0:
        if spec.start > spec.stop:
            return 0
        dist = UInt64(spec.stop) - UInt64(spec.start)
        mag = UInt64(spec.step)
    else:
        if spec.start < spec.stop:
            return 0
        dist = UInt64(spec.start) - UInt64(spec.stop)
        mag = UInt64(0) - UInt64(spec.step)
    if spec.inclusive:
        var q = dist // mag
        if q == UInt64.MAX:
            return UInt64.MAX
        return q + 1
    if dist == 0:
        return 0
    return (dist - 1) // mag + 1


def _within(spec: SeriesSpec, v: Int64) -> Bool:
    """True when `v` is before the bound in the step's direction (or on it,
    for an inclusive series)."""
    if spec.step_months > 0:
        return v <= spec.stop if spec.inclusive else v < spec.stop
    return v >= spec.stop if spec.inclusive else v > spec.stop


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
    """Days since 1970-01-01 of a proleptic-Gregorian date (Hinnant)."""
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(days: Int) -> _Civil:
    """Inverse of `_days_from_civil` (Hinnant); `//` floors."""
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


def _split(micros: Int64) -> Tuple[Int, Int64]:
    """(days since the epoch, microseconds into that day), flooring."""
    var days = micros // US_PER_DAY
    return (Int(days), micros - days * US_PER_DAY)


def _month_index(micros: Int64) -> Int:
    """Months since year 0 of the timestamp's calendar month."""
    var c = _civil_from_days(_split(micros)[0])
    return c.y * 12 + c.m - 1


def _at_month(month_index: Int, day: Int, tod: Int64) raises -> Int64:
    """Day `day` (clamped to the month's length) of the month `month_index`
    at `tod` microseconds into the day.

    Raises:
        `SERIES_TIMESTAMP_OVERFLOW` when that instant is beyond the TIMESTAMP
        range, as DuckDB raises for the value after the last in range.
    """
    var y = month_index // 12
    var m = month_index - y * 12 + 1
    var d = day
    var dim = _days_in_month(y, m)
    if d > dim:
        d = dim
    var days = _days_from_civil(y, m, d)
    if days > Int(_MAX_DAY) or days < -Int(_MAX_DAY):
        raise Error(String(SERIES_TIMESTAMP_OVERFLOW))
    var midnight = Int64(days) * US_PER_DAY
    if midnight > Int64.MAX - tod:
        raise Error(String(SERIES_TIMESTAMP_OVERFLOW))
    return midnight + tod


def _add_months_clamped(
    prev: Int64, start: Int64, months: Int64
) raises -> Int64:
    """`prev + months` months, the day clamped to the end of the target month,
    the time of day kept (it is the start's, which every value shares)."""
    var tod = _split(start)[1]
    var c = _civil_from_days(_split(prev)[0])
    return _at_month(c.y * 12 + c.m - 1 + Int(months), c.d, tod)


def _month_value_at(spec: SeriesSpec, k: UInt64) raises -> Optional[Int64]:
    """The value at row `k` of a month-step series, or None when the series
    has ended by then. The k-th value's day is the start's day clamped by every
    month the series has passed through; a day of 28 or less never clamps, and
    month lengths repeat every 400 years, so at most one cycle is walked."""
    var parts = _split(spec.start)
    var c = _civil_from_days(parts[0])
    var base = c.y * 12 + c.m - 1
    var span = _month_index(spec.stop) - base
    var m = Int(spec.step_months)
    # Past the bound's month, the series has surely ended: compare month
    # counts first so the index arithmetic below never overflows.
    var steps_left = span // m if m > 0 else (-span) // (-m)
    if steps_left < 0 or k > UInt64(steps_left + 1):
        return None
    var kk = Int(k)
    var day = c.d
    var j = 1
    while j <= kk and j <= _GREGORIAN_CYCLE_MONTHS and day > 28:
        var mi = base + j * m
        var y = mi // 12
        var dim = _days_in_month(y, mi - y * 12 + 1)
        if dim < day:
            day = dim
        j += 1
    var v = _at_month(base + kk * m, day, parts[1])
    if not _within(spec, v):
        return None
    return Optional(v)
