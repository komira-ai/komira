# =============================================================================
# temporal_extract — DATE32 / TIMESTAMP_* field-extraction kernels
# =============================================================================
#
# The temporal kernels:
# `year`, `month`, `day`, `hour`, `quarter`, `date_trunc(unit)` over DATE32
# (Int32 days since 1970-01-01) and TIMESTAMP_* (Int64 ticks since
# 1970-01-01 in `seconds|milliseconds|microseconds|nanoseconds`).
#
# These kernels gate DuckDB-parity perf on TPC-H Q3/Q5/Q7/Q14 in queries
# that arrive with `extract(year from ...)` / `date_trunc(...)`.
#
# ★★ THE FIELD EXTRACTS EMIT INT64. THAT IS NOT A STYLE CHOICE — THE TWO
# EXECUTORS MUST AGREE. The row-streaming value-node translator translates the
# SAME `EXPR_EXTRACT` node into `EXPR_EXTRACT_I64`, and `_value_expr_out_dtype`
# returns the 255 sentinel for a field extract so the resolver sizes the output
# cell in the default INT64 numeric family. A column path emitting INT32 would
# answer `year(d)` with a different type depending on whether the projection
# happened to be row-servable.
#
# DuckDB v1.5.3 settles it: `typeof(year(DATE '1998-03-15'))` is BIGINT, and so
# is every other member of this family (`duckdb_functions()` lists BIGINT as
# the sole return type for year / month / day / quarter / hour / minute /
# second / dayofweek / ...). Both executors emit Int64.
#
# ⛔ DO NOT "RESTORE SYMMETRY" BY NARROWING THESE BACK TO INT32. The width is
# not free choice: it is the type a SQL consumer's `year(d)` column is declared
# to have, and narrowing it re-opens the divergence in the direction that
# disagrees with both DuckDB and this engine's other executor.
#
# ⚠ `date_trunc` IS DELIBERATELY UNCHANGED and is NOT part of that fix: it
# returns its child's temporal type, both executors already agree on that, and
# it is a STATED difference from DuckDB rather than a divergence (see the
# date_trunc note below).
#
# Public surface (validity-preserving — null in -> null out):
#
#   extract_year_date32(arr: PrimitiveArray[int32])  -> PrimitiveArray[int64]
#   extract_month_date32(arr)                        -> PrimitiveArray[int64]  # 1..12
#   extract_day_date32(arr)                          -> PrimitiveArray[int64]  # 1..31
#   extract_quarter_date32(arr)                      -> PrimitiveArray[int64]  # 1..4
#   extract_subday_zero_date32(arr)                  -> PrimitiveArray[int64]  # all 0
#       hour / minute / second over a DATE32. DuckDB v1.5.3 answers 0 for all
#       three (measured); this used to be a REFUSAL.
#
#   extract_year_ts(arr, src_unit: ArrowType)        -> PrimitiveArray[int64]
#   extract_month_ts(arr, src_unit)                  -> PrimitiveArray[int64]  # 1..12
#   extract_day_ts(arr, src_unit)                    -> PrimitiveArray[int64]  # 1..31
#   extract_hour_ts(arr, src_unit)                   -> PrimitiveArray[int64]  # 0..23
#   extract_minute_ts(arr, src_unit)                 -> PrimitiveArray[int64]  # 0..59
#   extract_second_ts(arr, src_unit)                 -> PrimitiveArray[int64]  # 0..59
#   extract_quarter_ts(arr, src_unit)                -> PrimitiveArray[int64]  # 1..4
#
#   extract_day_index_date32(arr, unit)              -> PrimitiveArray[int64]
#   extract_day_index_ts(arr, src_unit, unit)        -> PrimitiveArray[int64]
#       `dayofweek` (Sunday=0),
#       `isodow` (Sunday=7) and `dayofyear` (1-based), selected by the plan
#       IR's own EXTRACT_* unit. ONE pair for three units — see the block
#       above them for why this family shares a body and the one above does
#       not.
#
#   extract_iso_week_date32(arr, unit)               -> PrimitiveArray[int64]
#   extract_iso_week_ts(arr, src_unit, unit)         -> PrimitiveArray[int64]
#
#   extract_subsecond_ts(arr, src_unit, unit)        -> PrimitiveArray[int64]
#       `millisecond` / `microsecond`
#       WITH THE SECONDS FOLDED IN (30123 / 30123456, not 123 / 123456). No
#       DATE32 form: that answer is 0 and `extract_subday_zero_date32` already
#       serves it.
#       `week` (ISO, 1..53),
#       `isoyear` and `yearweek` (= isoyear*100 ± week — the week half is
#       NEGATED for a non-positive ISO year; see `compose_yearweek`).
#       ⛔ `isoyear` is NOT
#       `year` — they differ on up to three days at each end of every year.
#
#   date_trunc_date32(arr, unit)                     -> PrimitiveArray[int32]
#       unit ∈ {year, quarter, month, week, day} — sub-day truncs are
#       no-ops on DATE32. A unit outside TRUNC_* (> 9) raises.
#       ⚠ THE TYPE IS A STATED DIFFERENCE FROM DuckDB, NOT PARITY. DuckDB
#       v1.5.3 has NO DATE-returning `date_trunc` overload at all — the DATE
#       is implicitly widened and `typeof(date_trunc('month', DATE
#       '1998-03-15'))` is TIMESTAMP. This kernel keeps DATE32,
#       which is the same instant in a narrower, lossless type and is what
#       BOTH of this engine's executors already produce; the difference is
#       recorded here rather than papered over, because changing it is a
#       semantic change to the DataFrame door, not a parity fix.
#   date_trunc_ts(arr, src_unit, trunc_unit)         -> PrimitiveArray[int64]
#       trunc_unit ∈ {year, quarter, month, week, day, hour, minute,
#       second, millisecond, microsecond}. The output stays in src_unit
#       ticks; only the value is rounded down to the period start. A unit
#       outside TRUNC_* (> 9) raises.
#
# Algorithm:
#   * `_civil_from_days(z: Int) -> Tuple[Int, Int, Int]` — Howard Hinnant's
#     civil_from_days. Branch-free, scalar per-row. Sister of the
#     `_days_from_civil` formula in
#     `komira_json.value_parsers.parse_date`.
#       Reference: http://howardhinnant.github.io/date_algorithms.html#civil_from_days
#   * Hour/min/sec on TIMESTAMP_* — pure arithmetic
#     `(ts // ticks_per_period) % cycle`.
#   * Quarter — derived from month: `((month - 1) // 3) + 1`.
#   * date_trunc — round-down to period start; for calendar units (year,
#     quarter, month, week) recompose via `_days_from_civil(y, m, 1)` and
#     re-multiply by ticks/day for TIMESTAMP_*.
#
# Parallelism — SERIAL BY DESIGN:
#   These kernels run PER-MORSEL inside the morsel executor's per-worker
#   loop (`op.execute(morsel)`). Cross-core parallelism is ALREADY supplied
#   by the morsel distribution — every worker calls these kernels on its own
#   disjoint morsel. An INTERNAL parallel layer here would be NESTED
#   (N² oversubscription) and harmful, and barely fires (morsels are far
#   below any useful threshold). So the kernels are deliberately serial: one
#   per-row scan over [0, n) per call. Per-morsel kernels
#   must NOT carry their own parallelism.
#
# Encapsulation:
#   - Public API: PrimitiveArray refs only; no UnsafePointer in signatures.
#   - Per-row scalar; the per-call [0, n) loop is the unit of work.
#   - No `parallelize` / `parallel_fork_join` / atomics / dispatch-boundary
#     unsafe pointers anywhere in this file.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# date_trunc unit constants
# =============================================================================

comptime TRUNC_YEAR: UInt8 = 0
comptime TRUNC_QUARTER: UInt8 = 1
comptime TRUNC_MONTH: UInt8 = 2
comptime TRUNC_WEEK: UInt8 = 3
comptime TRUNC_DAY: UInt8 = 4
comptime TRUNC_HOUR: UInt8 = 5
comptime TRUNC_MINUTE: UInt8 = 6
comptime TRUNC_SECOND: UInt8 = 7
comptime TRUNC_MILLISECOND: UInt8 = 8
comptime TRUNC_MICROSECOND: UInt8 = 9


def _check_trunc_unit(trunc_unit: UInt8, kernel: StaticString) raises:
    """Refuse a unit outside TRUNC_* before any row is read, so an unknown
    code is an error rather than an unchanged column."""
    if trunc_unit > TRUNC_MICROSECOND:
        raise Error(
            "temporal_extract."
            + String(kernel)
            + ": unknown trunc unit "
            + String(Int(trunc_unit))
        )


# =============================================================================
# DAY-INDEX field units — THE IR's OWN NUMBERS, NOT A LOCAL ENCODING
# =============================================================================
#
# ⚠ THESE THREE ARE NOT LIKE `TRUNC_*` ABOVE. `TRUNC_*` is a tight 0..9 kernel
# encoding that the caller MAPS onto from the IR's 16..25; these are the IR
# values themselves (`komira_plan_expr.expr.EXTRACT_DAYOFWEEK` = 7,
# `EXTRACT_ISODOW` = 8, `EXTRACT_DAYOFYEAR` = 9), restated here because this
# module deliberately does not import the plan IR — the same MIRROR convention
# `komira_kernels.runtime_expr` states for `RT_EXTRACT_*`.
#
# ⛔ A MIRROR THAT DRIFTS IS A WRONG FIELD, NOT A COMPILE ERROR. The value is
# pinned against the IR constant by
# `komira_kernels/tests/test_temporal_offset_and_units.mojo`
# (`test_day_index_kernel_unit_codes_mirror_the_plan_IR`), which drives every
# mirrored unit through its kernel AS the IR constant and checks the field —
# a drifted copy answers a different field or raises.
comptime _K_DAYOFWEEK: UInt8 = 7
comptime _K_ISODOW: UInt8 = 8
comptime _K_DAYOFYEAR: UInt8 = 9

# ISO WEEK-DATE field units. Same mirror rule; pinned by
# the same test. `komira_plan_expr.expr.EXTRACT_WEEK` = 10, `EXTRACT_ISOYEAR`
# = 11, `EXTRACT_YEARWEEK` = 12.
comptime _K_WEEK: UInt8 = 10
comptime _K_ISOYEAR: UInt8 = 11
comptime _K_YEARWEEK: UInt8 = 12

# SUB-SECOND field units . `EXTRACT_MILLISECOND` = 13,
# `EXTRACT_MICROSECOND` = 14.
comptime _K_MILLISECOND: UInt8 = 13
comptime _K_MICROSECOND: UInt8 = 14


# =============================================================================
# Calendar helpers — Hinnant civil_from_days / days_from_civil
# =============================================================================


@always_inline
def _div_floor(a: Int, b: Int) -> Int:
    """Floor-division for Int, matching Python `//` and Hinnant's algorithm
    assumption.

    ⛔⛔ THE SENTENCE THAT USED TO BE HERE WAS FALSE AND IT WAS THE REASON THIS
    FUNCTION EXISTS. It said: *"Mojo `//` is truncation-toward-zero; for
    negative `a` and positive `b`, that's NOT floor."* Measured on Mojo 1.0.0:

        -25505 // 7  = -3644   (FLOOR; truncation would be -3643)
        -25505 %  7  = 3       (FLOOR-MOD; C's `%` would be -4)
        7 // -3      = -3      7 % -3 = -2      (Python's sign rule, exactly)

    and the same for `Int64`, `Int32` and `SIMD[int64, N]`. **Mojo's `//` and
    `%` ARE Python's.** So this helper is an IDENTITY over the whole input
    domain, and so is `_mod_floor` below.

    ⚠ IT IS KEPT ANYWAY, AND NOT BECAUSE IT IS LOAD-BEARING TODAY. Three
    reasons, in order: (1) it NAMES the semantics Hinnant's `civil_from_days`
    requires, at the call sites that require them, where a bare `//` requires
    the reader to know a language rule; (2) if a future Mojo moved `//` to the
    C convention, every temporal kernel here would start answering NEGATIVE
    weekdays for pre-1970 rows — this helper is where that would be fixed
    once, and the alternative is fixing it at ~15 call sites; (3) the
    assumption is now PINNED, by
    `komira_kernels/tests/test_temporal_offset_and_units.mojo`'s
    `test_mojo_integer_division_and_modulo_are_FLOOR_not_truncating`, so the
    day Mojo changes it the repo goes RED instead of computing quietly.

    ⛔⛔ AND `//` IS NOT `/`. **Mojo's `/` on an INTEGRAL type TRUNCATES**
    (measured: `SIMD[int64](-25505) / SIMD[int64](7)` = -3643, and
    `Scalar[int64](-7) / Scalar[int64](2)` = -3), so the two operators differ
    for every negative dividend that is not an exact multiple. Do not treat
    them as interchangeable when reading a kernel; which one a line uses is a
    semantic choice, whether or not its author knew it.

    Hinnant's civil_from_days references `era = z >= 0 ? z/146097 : (z-146096)/146097`
    which is exactly floor-division for the (a, +b) case.
    """
    var q = a // b
    var r = a - q * b
    if r != 0 and ((r < 0) != (b < 0)):
        q -= 1
    return q


@always_inline
def _mod_floor(a: Int, b: Int) -> Int:
    """Floor-mod (matches Python `%` — and so does Mojo's
    own `%`; see `_div_floor` above for why this is kept regardless)."""
    var r = a - _div_floor(a, b) * b
    return r


@always_inline
def _civil_from_days(z: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant's `civil_from_days` — INVERSE of `_days_from_civil`.

    `@always_inline`:
    the per-row caller pattern in `extract_*` kernels invoked this 10M
    times per pass; the `call/ret` pair plus caller-saved register
    spills were ~30-50% of variant-A wall time. Inlining lets the
    compiler hoist `_div_floor` / `idiv->imul` strength reductions
    across the call boundary and eliminates the function-frame setup.

    Given `z` = days since 1970-01-01 (negative for earlier dates), return
    (year, month, day) in the proleptic Gregorian calendar.  Branch-free
    scalar arithmetic; no floating-point.

    Reference: http://howardhinnant.github.io/date_algorithms.html#civil_from_days

    Steps (per Hinnant):
      z       += 719468
      era      = floor(z / 146097)             # 400-year era number
      doe      = z - era*146097                # day-of-era [0, 146096]
      yoe      = (doe - doe/1460 + doe/36524 - doe/146096) / 365  # year-of-era [0, 399]
      y        = yoe + era*400
      doy      = doe - (365*yoe + yoe/4 - yoe/100)                # day-of-year [0, 365]
      mp       = (5*doy + 2) / 153                                # month proxy [0, 11]
      d        = doy - (153*mp + 2)/5 + 1                         # day [1, 31]
      m        = mp + (mp < 10 ? 3 : -9)                          # month [1, 12]
      y        += (m <= 2 ? 1 : 0)                                # Mar-Feb -> Jan-Dec
    """
    var z_adj = z + 719468
    var era = _div_floor(z_adj, 146097)
    var doe = z_adj - era * 146097
    # Note: Hinnant uses unsigned integer division semantics; with z_adj
    # adjusted so it's non-negative within an era (doe in [0, 146096]),
    # plain `//` is safe here.
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m: Int
    if mp < 10:
        m = mp + 3
    else:
        m = mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


@always_inline
def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Mirror of `parse_date._days_from_civil` — kept inline here so the
    `date_trunc` arms don't have to reach across the json module.

    ⛔⛔ THE ERA IS ONE FLOORING DIVIDE AND THE C IDIOM FOR IT IS A BUG HERE.
    This used to read `(y_adj - 399) // 400` on the negative branch — the
    standard trick for recovering a FLOOR from a division that TRUNCATES.
    Mojo's `//` already floors, so the
    trick SUBTRACTS A SECOND ERA: for y_adj = -2 it answers -2 where
    floor(-2/400) is -1, and `yoe` then leaves its [0, 399] domain and the
    leap-day term `yoe//4 - yoe//100` under-counts by exactly one day.

    MEASURED: the round trip `_days_from_civil(_civil_from_days(d))` failed
    for 11,453 of the 118,572 day counts sampled over [-800000, 30000) — EVERY
    ONE OF THEM BC — and for ZERO of the AD ones, which is why no fixture ever
    saw it. Against duckdb v1.5.3, `-0044-01-01` is day -735599 and this
    answered -735600. That one day propagated into `dayofyear` (76 for
    `-0044-03-15`, DuckDB 75), `week` / `yearweek` (the January-1st subtraction
    in `_isoweek_from_days`), and every calendar `date_trunc`.
    """
    var y_adj: Int
    if m > 2:
        y_adj = y
    else:
        y_adj = y - 1
    var era = _div_floor(y_adj, 400)
    var yoe = y_adj - era * 400
    var m_off: Int
    if m > 2:
        m_off = m - 3
    else:
        m_off = m + 9
    var doy = (153 * m_off + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


# =============================================================================
# Timestamp-unit ticks-per-second resolver
# =============================================================================


@always_inline
def _ticks_per_second(src_unit: ArrowType) raises -> Int64:
    """Return how many ticks make up one second for the given timestamp
    unit. `TIMESTAMP` is the legacy alias for `TIMESTAMP_US`.

    `@always_inline`:
    callers hoist tps/tpd outside the per-row loop, so the function is
    only invoked once per column. Inlining still helps remove the
    `raises`-induced out-of-line emit + landing-pad churn.
    """
    if src_unit == ArrowType.TIMESTAMP_S:
        return Int64(1)
    elif src_unit == ArrowType.TIMESTAMP_MS:
        return Int64(1_000)
    elif src_unit == ArrowType.TIMESTAMP_US or src_unit == ArrowType.TIMESTAMP:
        return Int64(1_000_000)
    elif src_unit == ArrowType.TIMESTAMP_NS:
        return Int64(1_000_000_000)
    raise Error(
        "temporal_extract: unsupported timestamp unit type_id="
        + String(Int(src_unit.type_id))
    )


@always_inline
def _ticks_per_day(tps: Int64) -> Int64:
    return tps * Int64(86400)


# =============================================================================
# Validity helpers — clone src bitmap if any (matches string_numeric_cast)
# =============================================================================


def _clone_validity_to_out_i32(
    src_length: Int,
    src_offset: Int,
    src_validity: Optional[Bitmap[HeapRegion]],
    mut out: PrimitiveArray[DType.int32],
) raises:
    """Copy the source's visible validity window onto the i32 output and
    recompute null_count. No-op when the source has no validity bitmap.

    A sliced `PrimitiveArray` keeps its bitmap indexed ABSOLUTELY (logical
    row i is bit `src_offset + i`), so the window copied is
    `[src_offset, src_offset + src_length)`, rebased to bit 0 of the output.
    """
    if not src_validity:
        return
    ref src_bm = src_validity.value()
    var cloned = Bitmap.copy_slice_from(src_bm, src_offset, src_length)
    out.null_count = cloned.null_count()
    out.validity = cloned^


def _clone_validity_to_out_i64(
    src_length: Int,
    src_offset: Int,
    src_validity: Optional[Bitmap[HeapRegion]],
    mut out: PrimitiveArray[DType.int64],
) raises:
    """The i64 twin of `_clone_validity_to_out_i32`."""
    if not src_validity:
        return
    ref src_bm = src_validity.value()
    var cloned = Bitmap.copy_slice_from(src_bm, src_offset, src_length)
    out.null_count = cloned.null_count()
    out.validity = cloned^


# =============================================================================
# Per-row kernel bodies (serial)
# =============================================================================
#
# Each body writes the range `out[start..end)` from a read-only scan of
# `arr[start..end)`. The public functions call these once over [0, n).
# NULL rows are written as 0; the validity bitmap is cloned afterward by
# `_clone_validity_to_out_*`, so the body never touches `out.null_count` /
# `out.validity`. The `start`/`end` parameters are retained so the leaf
# bodies stay range-scoped (cheap to re-slice if ever needed), but every
# caller passes the full [0, n) range.


@always_inline
def _quarter_first_month(month: Int) -> Int:
    """Q1=1, Q2=4, Q3=7, Q4=10."""
    return ((month - 1) // 3) * 3 + 1


# =============================================================================
# The DAY-INDEX scalar helpers
# =============================================================================
#
# All three take `days` = days since 1970-01-01 (NEGATIVE before it) and are
# defined for a DATE32 and a TIMESTAMP_* alike — the caller has already
# floor-divided the tick count down to a day, so there is ONE implementation
# per unit and not one per input type.
#
# ⚠ 1970-01-01 WAS A THURSDAY, AND THAT CONSTANT IS THE WHOLE OF BOTH WEEKDAY
# FORMULAS. It is already relied on three lines below in `_date_trunc_*_range`'s
# TRUNC_WEEK arm (`(days + 3) mod 7` = days since Monday), so the two spellings
# here are the same fact read out at two different origins and must not drift.


@always_inline
def _dayofweek_from_days(days: Int) -> Int:
    """DuckDB `dayofweek` / `weekday`: **Sunday = 0** … Saturday = 6.

    DuckDB v1.5.3: `dayofweek(DATE '1998-03-15')` (a Sunday) = 0 and
    `dayofweek(DATE '1998-03-16')` = 1. 1970-01-01 was a Thursday, so the
    Sunday-origin offset is +4: `(0 + 4) mod 7` = 4 = Thursday.

    ⚠ FLOOR-mod, because a pre-epoch `days` is NEGATIVE and a truncating `%`
    would answer a negative weekday. ⛔ AN EARLIER VERSION OF THIS LINE SAID
    "Mojo's `%` follows the truncating `//`" AND THAT IS FALSE — measured on
    Mojo 1.0.0, `%` is floor-mod (see `_div_floor`), so `_mod_floor` here is
    an identity and swapping it for `%` is an EQUIVALENT mutant. It was armed
    and every test stayed green, which is how the claim was
    caught. The spelling is kept because it names the requirement at the site
    that has it; the requirement is real even where the language already
    meets it."""
    return _mod_floor(days + 4, 7)


@always_inline
def _isodow_from_days(days: Int) -> Int:
    """ISO-8601 day of week: **Monday = 1** … **Sunday = 7**.

    ⛔ NOT `dayofweek + 1`, AND NOT `dayofweek` WITH SUNDAY REMAPPED BY THE
    CALLER. In DuckDB v1.5.3, on a Sunday: `dayofweek` = 0 and `isodow` =
    7; on the following Monday BOTH answer 1. The two agree on five of seven
    days, so the ONE witness that separates them is a Sunday row."""
    return _mod_floor(days + 3, 7) + 1


@always_inline
def _dayofyear_from_days(days: Int) -> Int:
    """DuckDB `dayofyear`: 1 on January 1st, 365/366 on December 31st.

    ONE-BASED (measured: `dayofyear(DATE '1970-01-01')` = 1, not 0), and
    leap-aware for free — the January 1st of the SAME civil year is recovered
    through `_days_from_civil`, so 2000-02-29 answers 60 without a leap-year
    branch anywhere."""
    var ymd = _civil_from_days(days)
    return days - _days_from_civil(ymd[0], 1, 1) + 1


@always_inline
def _day_index_field(days: Int, unit: UInt8) raises -> Int:
    """Dispatch the three DAY-INDEX units off one `days` value.

    ⚠ THE PARAMETER IS THE ENGINE'S OWN `EXTRACT_*` CONSTANT, PASSED THROUGH
    UNMAPPED. Every other unit family in this file (`TRUNC_*`) carries a local
    mirror of the IR's numbering and a mapping ladder in the caller; that
    mirror exists because the trunc range is 16..25 and a tight 0..9 kernel
    encoding predates it. A THIRD mirror for the field family would be a third
    place for the numbering to drift, so this one reads the IR values the
    caller already holds. It raises on anything else rather than defaulting,
    because a default here would answer the WRONG FIELD silently."""
    if unit == _K_DAYOFWEEK:
        return _dayofweek_from_days(days)
    if unit == _K_ISODOW:
        return _isodow_from_days(days)
    if unit == _K_DAYOFYEAR:
        return _dayofyear_from_days(days)
    raise Error(
        "temporal_extract: _day_index_field — not a day-index unit: "
        + String(Int(unit))
    )


# =============================================================================
# The ISO WEEK-DATE scalar helpers
# =============================================================================
#
# ★★ ALL THREE PIVOT ON ONE FACT AND IT IS THE ONLY THING WORTH REMEMBERING:
# **an ISO week belongs to the year containing its THURSDAY.** Every formula
# below is that sentence; none of them is a special case for January or
# December, and none of them needs a leap-year branch.
#
# ⛔ THIS IS NOT `year()` AND NOT `dayofyear() / 7`. DuckDB v1.5.3:
#     isoyear(DATE '1999-01-01') = 1998   (year() = 1999)
#     week   (DATE '1999-01-01') = 53     (a JANUARY date in week 53)
#     isoyear(DATE '1996-12-30') = 1997   (year() = 1996)
#     week   (DATE '1996-12-30') = 1      (a DECEMBER date in week 1)
# On ~99% of days `isoyear` and `year` are the same number, so an alias
# survives every fixture not authored to break it — those four rows are.


@always_inline
def _iso_thursday_days(days: Int) -> Int:
    """The day count of the THURSDAY of the ISO week containing `days`.

    `days - isodow + 4` walks back to Monday (`- (isodow - 1)`) and forward
    three (`+ 3`). Monday's own Thursday is `days + 3`; Sunday's is
    `days - 3`."""
    return days - _isodow_from_days(days) + 4


@always_inline
def _isoyear_from_days(days: Int) -> Int:
    """The ISO week-numbering year: the CIVIL year of this week's Thursday."""
    var ymd = _civil_from_days(_iso_thursday_days(days))
    return ymd[0]


@always_inline
def _isoweek_from_days(days: Int) -> Int:
    """ISO week number, 1..53.

    ⚠ THE DIVISION IS SAFE UNDER TRUNCATION AND THAT IS NOT AN ACCIDENT. The
    Thursday is BY CONSTRUCTION inside the ISO year whose January 1st is
    subtracted, so the difference is in [0, 371] and never negative — unlike
    the weekday formulas above, which are floor-mod precisely because their
    operand can be. Do not "fix" this one into `_div_floor`; do not relax the
    others into `//`."""
    var th = _iso_thursday_days(days)
    var ymd = _civil_from_days(th)
    return (th - _days_from_civil(ymd[0], 1, 1)) // 7 + 1


@always_inline
def compose_yearweek(iso_y: Int, wk: Int) -> Int:
    """Compose DuckDB's `yearweek` from an ISO year and an ISO week number.

    ⛔⛔ THE WEEK HALF IS NEGATED FOR A NON-POSITIVE ISO YEAR. MEASURED
    v1.5.3:

        isoyear   -45   -44    -1     0  |    1   2020   2026
        week       52    11    52    52  |    1     53     11
        yearweek -4552 -4411  -152   -52 |  101 202053 202611

    So it is `iso_y * 100 + (iso_y > 0 ? wk : -wk)`, NOT the unconditional
    `iso_y * 100 + wk`. The two agree on every AD row, so
    the defect is invisible to any fixture written after the epoch.

    ⚠ ISO YEAR **ZERO** IS THE ROW THAT CANNOT BE FAKED: `iso_y * 100` is 0
    there, so the week half carries the whole answer and the sign is the ONLY
    thing that distinguishes -52 from +52. A guard written `iso_y < 0` instead
    of `iso_y > 0` is green on every other BC row and wrong on that one.

    ⛔ THIS IS NOT A TWIN OF `century`'s TWO-BRANCH CASE AND MUST NOT BE
    "UNIFIED" WITH IT. `century`'s numbering SKIPS ZERO (… -2, -1, 1, 2 …) and
    needs two different FORMULAS; this is one formula with a sign applied to
    one of its two terms. `decade` is a plain truncating divide at every sign
    and is a third shape again. Each was measured separately; none of them
    implies either of the others.

    ★ SHARED ON PURPOSE, ACROSS A MODULE BOUNDARY. The row tower
    (`expression_executor._eval_i64_from_source`) keeps LOCAL copies of the
    calendar helpers to spare the per-cell walker a call, and re-deriving this
    rule there would have made a wrong answer ROUTE-DEPENDENT — worse than the
    original defect, because the two doors would disagree. `@always_inline`
    costs the row tower nothing, so the rule lives in one place."""
    if iso_y > 0:
        return iso_y * 100 + wk
    return iso_y * 100 - wk


@always_inline
def _iso_week_field(days: Int, unit: UInt8) raises -> Int:
    """Dispatch the three ISO week-date units off one `days` value.

    ⚠ A SEPARATE DISPATCHER FROM `_day_index_field`, NOT AN EXTENSION OF IT.
    Those three are one-line formulas on the raw day count; these three all
    run the Thursday pivot and two of them then run `_civil_from_days` on the
    RESULT rather than on the input. Folding them together would put a family
    with a different pivot behind a name (`day index`) that does not describe
    it, and `yearweek` is not a day index by any reading.

    ⛔ `yearweek` IS `isoyear * 100 + week`, WITH THE **ISO** YEAR. In DuckDB
    v1.5.3: `yearweek(DATE '1999-01-01')` = **199853** — 1998, not 1999, and
    week 53. Composing it from `year()` would answer 199953, a number in the
    right shape and the wrong year, on exactly the dates that matter.

    ⛔ AND THE SIGN OF THE WEEK HALF IS NOT THE SIGN OF THE SUM — see
    `compose_yearweek`, which owns that rule for this kernel AND for the row
    tower."""
    if unit == _K_WEEK:
        return _isoweek_from_days(days)
    if unit == _K_ISOYEAR:
        return _isoyear_from_days(days)
    if unit == _K_YEARWEEK:
        return compose_yearweek(
            _isoyear_from_days(days), _isoweek_from_days(days)
        )
    raise Error(
        "temporal_extract: _iso_week_field — not an ISO week-date unit: "
        + String(Int(unit))
    )


# =============================================================================
# The SUB-SECOND scalar helper
# =============================================================================


@always_inline
def _subsecond_field(ticks: Int, tps: Int, unit: UInt8) raises -> Int:
    """`millisecond` / `microsecond` from a raw TIMESTAMP_* tick count.

    `ticks` is the epoch tick count in the column's OWN unit and `tps` is that
    unit's ticks-per-second (1 / 1e3 / 1e6 / 1e9).

    ⛔⛔ THE SECONDS ARE PART OF THE ANSWER. MEASURED v1.5.3 for
    `...13:45:30.123456`: `millisecond` = 30123 and `microsecond` = 30123456,
    NOT 123 and 123456. This is the single most plausible wrong answer in the
    temporal family — right type, right nullability, off by 1000x — and it is
    why both names were refused BY NAME here rather than approximated.

    ★ ONE OPERATION, NOT A RECOMPOSITION. `floor_mod(ticks, 60 * tps)` is the
    tick offset into the current MINUTE, which already means "seconds and
    fraction"; scaling that to microseconds is the whole computation. A
    `second * 1_000_000 + fraction` spelling would need the second and the
    fraction to be derived consistently across a sign boundary, and that is
    where a pre-epoch row goes wrong.

    ⚠ FLOOR-MOD IS LOAD-BEARING HERE IN A WAY A POSITIVE TEST CANNOT SEE.
    `TIMESTAMP '1969-12-31 23:59:59.999999'` is tick **-1** in microseconds,
    and DuckDB answers `microsecond` = 59999999. Floor-mod gives
    `-1 mod 60_000_000` = 59999999. A C-convention `%` would give -1.
    (Mojo's `%` is already floor-mod, so `_mod_floor`
    is an identity; it is spelled out because the requirement is real.)

    ⚠ NO OVERFLOW. `floor_mod(ticks, 60*tps)` < 60*tps <= 6e10, and
    6e10 * 1e6 = 6e16 < 2^63. The multiply is done BEFORE the divide so the
    nanosecond case (tps = 1e9, scale-down by 1000) stays exact in integers."""
    var sub_minute = _mod_floor(ticks, 60 * tps)
    var micros = sub_minute * 1_000_000 // tps
    if unit == _K_MICROSECOND:
        return micros
    if unit == _K_MILLISECOND:
        return micros // 1_000
    raise Error(
        "temporal_extract: _subsecond_field — not a sub-second unit: "
        + String(Int(unit))
    )


def _extract_year_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_year_date32` over the row range
    [start, end). Disjoint write to `out[start..end)`. Read-only on
    `arr`. No mutation of `out.null_count` or `out.validity`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[0])))


def _extract_month_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_month_date32`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[1])))


def _extract_day_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_day_date32`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[2])))


def _extract_quarter_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_quarter_date32`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            var ymd = _civil_from_days(days)
            var q = ((ymd[1] - 1) // 3) + 1
            out.set(i, Scalar[DType.int64](Int64(q)))


@always_inline
def _ts_to_days(ts: Int64, ticks_per_day: Int64) -> Int:
    """Convert a TIMESTAMP_* tick count into a day-since-1970 integer
    using floor-division (so negative ticks map to the correct earlier
    day).
    """
    var a = Int(ts)
    var b = Int(ticks_per_day)
    return _div_floor(a, b)


def _extract_year_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_year_ts`. `tpd` (ticks-per-day) is
    resolved once-per-column on the driver and passed in."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var days = _ts_to_days(ts, tpd)
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[0])))


def _extract_month_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var days = _ts_to_days(ts, tpd)
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[1])))


def _extract_day_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var days = _ts_to_days(ts, tpd)
            var ymd = _civil_from_days(days)
            out.set(i, Scalar[DType.int64](Int64(ymd[2])))


def _extract_quarter_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var days = _ts_to_days(ts, tpd)
            var ymd = _civil_from_days(days)
            var q = ((ymd[1] - 1) // 3) + 1
            out.set(i, Scalar[DType.int64](Int64(q)))


def _extract_hour_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tph: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var hours_total = _div_floor(Int(ts), Int(tph))
            var h = _mod_floor(hours_total, 24)
            out.set(i, Scalar[DType.int64](Int64(h)))


def _extract_minute_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpm: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var mins_total = _div_floor(Int(ts), Int(tpm))
            var m = _mod_floor(mins_total, 60)
            out.set(i, Scalar[DType.int64](Int64(m)))


def _extract_second_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tps: Int64,
    start: Int,
    end: Int,
) raises:
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var ts = arr.get(i)
            var secs_total = _div_floor(Int(ts), Int(tps))
            var s = _mod_floor(secs_total, 60)
            out.set(i, Scalar[DType.int64](Int64(s)))


def _extract_day_index_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_day_index_date32` — dayofweek / isodow /
    dayofyear over a DATE32 column, whose value IS the day count."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            out.set(i, Scalar[DType.int64](Int64(_day_index_field(days, unit))))


def _extract_day_index_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_day_index_ts`. `_ts_to_days` floor-divides, so
    a pre-1970 tick count lands on the correct EARLIER day rather than being
    truncated toward zero onto the following one."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = _ts_to_days(arr.get(i), tpd)
            out.set(i, Scalar[DType.int64](Int64(_day_index_field(days, unit))))


def _extract_iso_week_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int64],
    unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_iso_week_date32`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = Int(arr.get(i))
            out.set(i, Scalar[DType.int64](Int64(_iso_week_field(days, unit))))


def _extract_iso_week_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tpd: Int64,
    unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_iso_week_ts`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            var days = _ts_to_days(arr.get(i), tpd)
            out.set(i, Scalar[DType.int64](Int64(_iso_week_field(days, unit))))


def _extract_subsecond_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tps: Int64,
    unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `extract_subsecond_ts`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](0))
        else:
            out.set(
                i,
                Scalar[DType.int64](
                    Int64(_subsecond_field(Int(arr.get(i)), Int(tps), unit))
                ),
            )


def _date_trunc_date32_range(
    arr: PrimitiveArray[DType.int32],
    mut out: PrimitiveArray[DType.int32],
    trunc_unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `date_trunc_date32`."""
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int32](0))
        else:
            var days = Int(arr.get(i))
            var trunc_days: Int
            if trunc_unit == TRUNC_YEAR:
                var ymd = _civil_from_days(days)
                trunc_days = _days_from_civil(ymd[0], 1, 1)
            elif trunc_unit == TRUNC_QUARTER:
                var ymd = _civil_from_days(days)
                var qm = _quarter_first_month(ymd[1])
                trunc_days = _days_from_civil(ymd[0], qm, 1)
            elif trunc_unit == TRUNC_MONTH:
                var ymd = _civil_from_days(days)
                trunc_days = _days_from_civil(ymd[0], ymd[1], 1)
            elif trunc_unit == TRUNC_WEEK:
                # ISO 8601: week starts Monday.  1970-01-01 was a
                # Thursday (offset 3 from Monday, or 4 if Sunday-start).
                # days_since_monday = (days + 3) mod 7 with floor mod.
                var dow_offset = _mod_floor(days + 3, 7)
                trunc_days = days - dow_offset
            elif trunc_unit == TRUNC_DAY:
                trunc_days = days
            else:
                # Sub-day truncs (hour/minute/...) on DATE32 — no-op. Units
                # past TRUNC_MICROSECOND never get here: `date_trunc_date32`
                # refuses them before the loop.
                trunc_days = days
            out.set(i, Scalar[DType.int32](Int32(trunc_days)))


def _date_trunc_ts_range(
    arr: PrimitiveArray[DType.int64],
    mut out: PrimitiveArray[DType.int64],
    tps: Int64,
    tpd: Int64,
    tph: Int64,
    tpm: Int64,
    trunc_unit: UInt8,
    start: Int,
    end: Int,
) raises:
    """Worker body for `date_trunc_ts`. The ticks-per-{second, day, hour,
    minute} are resolved once-per-column on the driver and passed in."""
    var us_per_sec = Int64(1_000_000)
    var ns_per_sec = Int64(1_000_000_000)
    for i in range(start, end):
        if arr.is_null(i):
            out.set(i, Scalar[DType.int64](Int64(0)))
        else:
            var ts = arr.get(i)
            var ts_int = Int(ts)
            var trunc: Int64 = ts
            if trunc_unit == TRUNC_YEAR:
                var days = _div_floor(ts_int, Int(tpd))
                var ymd = _civil_from_days(days)
                var trunc_days = _days_from_civil(ymd[0], 1, 1)
                trunc = Int64(trunc_days) * tpd
            elif trunc_unit == TRUNC_QUARTER:
                var days = _div_floor(ts_int, Int(tpd))
                var ymd = _civil_from_days(days)
                var qm = _quarter_first_month(ymd[1])
                var trunc_days = _days_from_civil(ymd[0], qm, 1)
                trunc = Int64(trunc_days) * tpd
            elif trunc_unit == TRUNC_MONTH:
                var days = _div_floor(ts_int, Int(tpd))
                var ymd = _civil_from_days(days)
                var trunc_days = _days_from_civil(ymd[0], ymd[1], 1)
                trunc = Int64(trunc_days) * tpd
            elif trunc_unit == TRUNC_WEEK:
                var days = _div_floor(ts_int, Int(tpd))
                var dow_offset = _mod_floor(days + 3, 7)
                var trunc_days = days - dow_offset
                trunc = Int64(trunc_days) * tpd
            elif trunc_unit == TRUNC_DAY:
                # Floor-div by tpd then multiply back.
                var days = _div_floor(ts_int, Int(tpd))
                trunc = Int64(days) * tpd
            elif trunc_unit == TRUNC_HOUR:
                var hours = _div_floor(ts_int, Int(tph))
                trunc = Int64(hours) * tph
            elif trunc_unit == TRUNC_MINUTE:
                var mins = _div_floor(ts_int, Int(tpm))
                trunc = Int64(mins) * tpm
            elif trunc_unit == TRUNC_SECOND:
                var secs = _div_floor(ts_int, Int(tps))
                trunc = Int64(secs) * tps
            elif trunc_unit == TRUNC_MILLISECOND:
                # Round down to the millisecond boundary.  Only meaningful
                # for sub-millisecond units (US/NS).  S/MS are no-ops.
                if tps == us_per_sec:
                    var ms = _div_floor(ts_int, 1_000)
                    trunc = Int64(ms) * Int64(1_000)
                elif tps == ns_per_sec:
                    var ms = _div_floor(ts_int, 1_000_000)
                    trunc = Int64(ms) * Int64(1_000_000)
                else:
                    trunc = ts
            elif trunc_unit == TRUNC_MICROSECOND:
                # Round down to the microsecond boundary.  Only meaningful
                # for nanosecond units; others are no-ops.
                if tps == ns_per_sec:
                    var us = _div_floor(ts_int, 1_000)
                    trunc = Int64(us) * Int64(1_000)
                else:
                    trunc = ts
            out.set(i, Scalar[DType.int64](trunc))

# =============================================================================
# DATE32 extract kernels — public surface
# =============================================================================


def extract_year_date32(arr: PrimitiveArray[DType.int32]) raises -> PrimitiveArray[DType.int64]:
    """Extract `year` from a DATE32 column (days since 1970-01-01).
    NULL rows preserved.

    Serial by design: this
    kernel runs per-morsel inside the morsel executor; cross-core
    parallelism is supplied by the morsel distribution, so the per-row
    scan is a single serial pass over [0, n). The validity bitmap is
    cloned afterward.
    """
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_year_date32_range(arr, out, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_month_date32(arr: PrimitiveArray[DType.int32]) raises -> PrimitiveArray[DType.int64]:
    """Extract `month` [1..12]."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_month_date32_range(arr, out, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_day_date32(arr: PrimitiveArray[DType.int32]) raises -> PrimitiveArray[DType.int64]:
    """Extract `day` [1..31]."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_day_date32_range(arr, out, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_quarter_date32(arr: PrimitiveArray[DType.int32]) raises -> PrimitiveArray[DType.int64]:
    """Extract `quarter` [1..4] from month."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_quarter_date32_range(arr, out, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_subday_zero_date32(
    arr: PrimitiveArray[DType.int32],
) raises -> PrimitiveArray[DType.int64]:
    """`hour` / `minute` / `second` over a DATE32 column — ALL ZERO, validity
    preserved.

    ★★ THIS IS A PARITY ANSWER AND IT REPLACED A REFUSAL. DuckDB
    v1.5.3 answers ZERO, not an error: `hour(DATE '1998-03-15')` = 0 ::
    BIGINT, and so do `minute` and `second`. Before this kernel the eval arm
    raised "EXPR_EXTRACT — DATE32 has no sub-day field", so `SELECT
    hour(order_date)` was a query DuckDB answers and this engine refused.

    ⚠ IT IS ONE KERNEL FOR THREE UNITS ON PURPOSE. The three answers are
    IDENTICAL — a DATE32 is a day count with no sub-day component at all — so
    three functions differing only in their name would be three chances to
    return a different constant from the other two. The eval arm names the
    unit; this names the fact.

    ⚠ NULL IN -> NULL OUT, WHICH IS NOT THE SAME AS ZERO. The data lane is
    zero for every row including the null ones (the family's convention: the
    body never touches `null_count`/`validity`), and the validity bitmap is
    then cloned — so a NULL date yields a NULL hour and not an hour of 0.
    DuckDB agrees: `hour(NULL::DATE)` is NULL.
    """
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        out.set(i, Scalar[DType.int64](0))
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# TIMESTAMP extract kernels — public surface
# =============================================================================


def extract_year_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    """Extract `year` from a TIMESTAMP_* column."""
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_year_ts_range(arr, out, tpd, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_month_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_month_ts_range(arr, out, tpd, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_day_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_day_ts_range(arr, out, tpd, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_quarter_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_quarter_ts_range(arr, out, tpd, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_hour_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    """Extract `hour` [0..23] from a TIMESTAMP_* column.

    Pure arithmetic via floor-mod:  hour = floor(ts / ticks_per_hour) % 24.
    Negative ticks (pre-1970) map correctly via the floor-mod helper.
    """
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tph = tps * Int64(3600)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_hour_ts_range(arr, out, tph, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_minute_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpm = tps * Int64(60)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_minute_ts_range(arr, out, tpm, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_second_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType) raises -> PrimitiveArray[DType.int64]:
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_second_ts_range(arr, out, tps, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# DAY-INDEX extract kernels — public surface (one pair, three units)
# =============================================================================
#
# ⚠ TWO FUNCTIONS FOR THREE UNITS, WHERE THE FIELD FAMILY ABOVE HAS ONE PER
# UNIT — a deliberate difference, not an inconsistency. `year`/`month`/`day`/
# `quarter` each need their OWN body (they read different slots of the
# `_civil_from_days` triple); these three share one body and differ only in a
# scalar formula, so a function apiece would be three wrappers around one loop
# and three chances for the validity-clone line to be written differently.


def extract_day_index_date32(
    arr: PrimitiveArray[DType.int32], unit: UInt8
) raises -> PrimitiveArray[DType.int64]:
    """`dayofweek` / `isodow` / `dayofyear` over a DATE32 column.

    `unit` is the plan IR's own `EXTRACT_DAYOFWEEK` / `EXTRACT_ISODOW` /
    `EXTRACT_DAYOFYEAR`; anything else RAISES rather than defaulting to a
    field the caller did not ask for.

    NULL in -> NULL out (the body writes 0 into the data lane for a null row
    and the validity bitmap is cloned afterward, this family's convention).
    MEASURED v1.5.3: `dayofweek(NULL::DATE)` is NULL."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_day_index_date32_range(arr, out, unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_day_index_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType, unit: UInt8
) raises -> PrimitiveArray[DType.int64]:
    """`dayofweek` / `isodow` / `dayofyear` over a TIMESTAMP_* column.

    ⚠ `src_unit` IS READ, NOT ASSUMED. The four TIMESTAMP_* units collapse
    into one INT64 storage family, so a kernel that hard-coded microseconds
    would answer a day 1000x away for a millisecond column — the same shape of
    defect as reading a column at a fixed byte stride."""
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_day_index_ts_range(arr, out, tpd, unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# ISO WEEK-DATE extract kernels — public surface (one pair, three units)
# =============================================================================


def extract_iso_week_date32(
    arr: PrimitiveArray[DType.int32], unit: UInt8
) raises -> PrimitiveArray[DType.int64]:
    """`week` / `isoyear` / `yearweek` over a DATE32 column.

    `unit` is the plan IR's `EXTRACT_WEEK` / `EXTRACT_ISOYEAR` /
    `EXTRACT_YEARWEEK`; anything else RAISES."""
    var n = arr.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_iso_week_date32_range(arr, out, unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


def extract_iso_week_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType, unit: UInt8
) raises -> PrimitiveArray[DType.int64]:
    """`week` / `isoyear` / `yearweek` over a TIMESTAMP_* column. `src_unit`
    is READ, not assumed — see `extract_calendar`'s note above."""
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_iso_week_ts_range(arr, out, tpd, unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# SUB-SECOND extract kernel — public surface (TIMESTAMP only, by design)
# =============================================================================
#
# ⚠ THERE IS NO `extract_subsecond_date32`, AND ITS ABSENCE IS DELIBERATE.
# `millisecond(DATE '1998-03-15')` and `microsecond(...)` are **0** in DuckDB
# v1.5.3 — the same answer `hour`/`minute`/`second` give over a
# DATE — so the caller routes a DATE32 to `extract_subday_zero_date32`, which
# already exists and already carries the reasoning for why a constant answer
# has ONE implementation and not five.


def extract_subsecond_ts(
    arr: PrimitiveArray[DType.int64], src_unit: ArrowType, unit: UInt8
) raises -> PrimitiveArray[DType.int64]:
    """`millisecond` / `microsecond` over a TIMESTAMP_* column, with the
    SECONDS FOLDED IN (30123 / 30123456 for `...:30.123456` — measured).

    ⚠ `src_unit` DECIDES THE ANSWER, NOT JUST THE SCALE. A TIMESTAMP_S column
    has no sub-second ticks at all, so `microsecond` there is `second * 1e6`
    exactly; a TIMESTAMP_NS column carries three digits this answer must
    DISCARD. Both fall out of the one formula, and neither survives a
    hard-coded microsecond assumption."""
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _extract_subsecond_ts_range(arr, out, tps, unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# date_trunc — DATE32
# =============================================================================
#
# DATE32 has no sub-day field; trunc unit ∈ {year, quarter, month, week,
# day}.  Sub-day units are no-ops on DATE32 (return arr.copy() shape).


def date_trunc_date32(arr: PrimitiveArray[DType.int32], trunc_unit: UInt8) raises -> PrimitiveArray[DType.int32]:
    """Round each row in `arr` down to the start of the period."""
    _check_trunc_unit(trunc_unit, "date_trunc_date32")
    var n = arr.length
    var out = PrimitiveArray[DType.int32].allocate(n)
    _date_trunc_date32_range(arr, out, trunc_unit, 0, n)
    _clone_validity_to_out_i32(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# date_trunc — TIMESTAMP_*
# =============================================================================
#
# Output stays in the same unit as input; only the value is rounded down
# to the period start.


def date_trunc_ts(arr: PrimitiveArray[DType.int64], src_unit: ArrowType, trunc_unit: UInt8) raises -> PrimitiveArray[DType.int64]:
    """Round each row down to the start of the period.  Output unit ==
    input unit (TIMESTAMP_* tick count)."""
    _check_trunc_unit(trunc_unit, "date_trunc_ts")
    var n = arr.length
    var tps = _ticks_per_second(src_unit)
    var tpd = _ticks_per_day(tps)
    var tph = tps * Int64(3600)
    var tpm = tps * Int64(60)
    var out = PrimitiveArray[DType.int64].allocate(n)
    _date_trunc_ts_range(arr, out, tps, tpd, tph, tpm, trunc_unit, 0, n)
    _clone_validity_to_out_i64(n, arr.offset, arr.validity, out)
    return out^


# =============================================================================
# String unit parser — for SDK / SQL surface
# =============================================================================


def parse_trunc_unit(unit: String) raises -> UInt8:
    """Map a SQL-style unit name to the TRUNC_* constant.

    Recognized names (lowercase): year, quarter, month, week, day, hour,
    minute, second, millisecond, microsecond.  Common aliases: 'yr' /
    'years', 'mo' / 'months', 'd' / 'days', 'hr' / 'hours', 'min' /
    'minutes', 'sec' / 'seconds', 'ms' / 'milliseconds', 'us' /
    'microseconds'.

    Raises on unrecognized.
    """
    var u = unit.lower()
    if u == "year" or u == "years" or u == "yr":
        return TRUNC_YEAR
    elif u == "quarter" or u == "quarters" or u == "q":
        return TRUNC_QUARTER
    elif u == "month" or u == "months" or u == "mo":
        return TRUNC_MONTH
    elif u == "week" or u == "weeks" or u == "w":
        return TRUNC_WEEK
    elif u == "day" or u == "days" or u == "d":
        return TRUNC_DAY
    elif u == "hour" or u == "hours" or u == "hr":
        return TRUNC_HOUR
    elif u == "minute" or u == "minutes" or u == "min":
        return TRUNC_MINUTE
    elif u == "second" or u == "seconds" or u == "sec":
        return TRUNC_SECOND
    elif u == "millisecond" or u == "milliseconds" or u == "ms":
        return TRUNC_MILLISECOND
    elif u == "microsecond" or u == "microseconds" or u == "us":
        return TRUNC_MICROSECOND
    raise Error("temporal_extract.parse_trunc_unit: unrecognized unit '" + unit + "'")
