# =============================================================================
# temporal_extract: the validity window of a SLICED input, the trunc-unit
# refusal, the IR-unit mirror and the floor-division assumption.
#
# A sliced `PrimitiveArray` keeps its validity bitmap indexed ABSOLUTELY:
# logical row i is bit `offset + i`. Every kernel here reads values through
# the offset-aware accessors, so the VALUES of a slice were always right; the
# output VALIDITY used to be a copy of the parent bitmap from bit 0, so the
# null rows landed on the wrong output rows and `null_count` counted the whole
# parent (komira issue 950, item 1). Each slice below starts at a
# non-byte-aligned offset with a NULL before the window, so a copy from bit 0
# moves the null and changes the count.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_plan_expr.expr import (
    EXTRACT_DAYOFWEEK,
    EXTRACT_ISODOW,
    EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK,
    EXTRACT_ISOYEAR,
    EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND,
    EXTRACT_MICROSECOND,
)
from komira_kernels.temporal_extract import (
    TRUNC_DAY,
    TRUNC_HOUR,
    TRUNC_MICROSECOND,
    date_trunc_date32,
    date_trunc_ts,
    extract_day_index_date32,
    extract_hour_ts,
    extract_iso_week_date32,
    extract_subsecond_ts,
    extract_year_date32,
)


def _jan1(i: Int) -> Int:
    """January 1 of 1970 + i, as a DATE32 day count."""
    var days: List[Int] = [0, 365, 730, 1096, 1461, 1826, 2191, 2557, 2922, 3287]
    return days[i]


def _nullable[dt: DType](
    values: List[Scalar[dt]], nulls: List[Int]
) raises -> PrimitiveArray[dt]:
    var n = len(values)
    var arr = PrimitiveArray[dt].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    arr.null_count = len(nulls)
    return arr^


def _date32_parent() raises -> PrimitiveArray[DType.int32]:
    """Ten January 1sts, NULL at rows 0 and 5."""
    var v = List[Int32]()
    for i in range(10):
        v.append(Int32(_jan1(i)))
    return _nullable[DType.int32](v, [0, 5])


def _ts_s_parent() raises -> PrimitiveArray[DType.int64]:
    """TIMESTAMP_S: January 1st of 1970 + i at hour i, NULL at rows 0 and 5."""
    var v = List[Int64]()
    for i in range(10):
        v.append(Int64(_jan1(i)) * 86400 + Int64(i) * 3600)
    return _nullable[DType.int64](v, [0, 5])


def _assert_window_validity[dt: DType](
    got: PrimitiveArray[dt], null_rows: List[Int], what: String
) raises:
    """`got` has exactly `null_rows` null, a count to match, and a bitmap
    exactly as long as the output."""
    assert_equal(got.null_count, len(null_rows), what + ": null_count")
    var has_validity = False
    if got.validity:
        has_validity = True
    assert_true(has_validity, what + ": validity kept")
    assert_equal(got.validity.value().length, got.length, what + ": bitmap length")
    for i in range(got.length):
        var want_null = False
        for k in range(len(null_rows)):
            if null_rows[k] == i:
                want_null = True
        assert_equal(got.is_null(i), want_null, what + ": row " + String(i))


def test_date32_extract_on_a_slice_keeps_the_window_validity() raises:
    """slice(3, 6) covers absolute rows 3..8; the only null in it is absolute
    row 5 = logical row 2. A copy from bit 0 reports two nulls (rows 0 and 5
    of the parent) at logical rows 0 and 5."""
    var s = _date32_parent().slice(3, 6)
    var y = extract_year_date32(s)
    _assert_window_validity(y, [2], "year(slice)")
    var want: List[Int64] = [1973, 1974, 0, 1976, 1977, 1978]
    for i in range(6):
        if i != 2:
            assert_equal(y.get(i), want[i], "year row " + String(i))


def test_date32_extract_on_a_slice_after_the_nulls() raises:
    """slice(6, 2): a window with no null after a parent row-0 null (the
    issue's own shape) must report null_count 0."""
    var s = _date32_parent().slice(6, 2)
    var y = extract_year_date32(s)
    _assert_window_validity(y, List[Int](), "year(slice 6,2)")
    assert_equal(y.get(0), 1976)
    assert_equal(y.get(1), 1977)


def test_date_trunc_date32_on_a_slice_keeps_the_window_validity() raises:
    """The i32 output helper: same window, same answer."""
    var s = _date32_parent().slice(3, 6)
    var t = date_trunc_date32(s, TRUNC_DAY)
    _assert_window_validity(t, [2], "date_trunc_date32(slice)")
    assert_equal(t.get(0), Int32(_jan1(3)))
    assert_equal(t.get(5), Int32(_jan1(8)))


def test_timestamp_kernels_on_a_slice_keep_the_window_validity() raises:
    """TIMESTAMP_* extract and date_trunc read the same window."""
    var s = _ts_s_parent().slice(3, 6)
    var h = extract_hour_ts(s, ArrowType.TIMESTAMP_S)
    _assert_window_validity(h, [2], "hour(slice)")
    assert_equal(h.get(0), 3)
    assert_equal(h.get(5), 8)
    var t = date_trunc_ts(s, ArrowType.TIMESTAMP_S, TRUNC_DAY)
    _assert_window_validity(t, [2], "date_trunc_ts(slice)")
    assert_equal(t.get(1), Int64(_jan1(4)) * 86400)


def test_date_trunc_refuses_an_unknown_unit() raises:
    """A unit past TRUNC_MICROSECOND raises in both kernels (issue 950,
    item 5); the documented DATE32 sub-day units stay no-ops."""
    var d = _date32_parent()
    var ts = _ts_s_parent()
    var unknown = TRUNC_MICROSECOND + 1
    var raised = False
    try:
        _ = date_trunc_ts(ts, ArrowType.TIMESTAMP_S, unknown)
    except e:
        raised = True
        assert_true("date_trunc_ts: unknown trunc unit 10" in String(e), String(e))
    assert_true(raised, "date_trunc_ts must refuse unit 10")
    raised = False
    try:
        _ = date_trunc_date32(d, UInt8(255))
    except e:
        raised = True
        assert_true("date_trunc_date32: unknown trunc unit 255" in String(e), String(e))
    assert_true(raised, "date_trunc_date32 must refuse unit 255")
    var same = date_trunc_date32(d, TRUNC_HOUR)
    for i in range(10):
        if i != 0 and i != 5:
            assert_equal(same.get(i), Int32(_jan1(i)), "hour trunc on DATE32 row " + String(i))


def test_date_trunc_accepts_the_last_unit_TRUNC_MICROSECOND() raises:
    """The refusal's accept edge: TRUNC_MICROSECOND (9), the largest valid
    unit, runs in both kernels. A refusal written as `>=` raises here.
    TIMESTAMP_NS rounds down to the microsecond (floor, so -1 ns is -1000);
    DATE32 keeps every day unchanged and keeps its NULL rows."""
    var ns = PrimitiveArray[DType.int64].from_list(
        [Int64(1_234_567_891), Int64(-1), Int64(5_000)]
    )
    var t = date_trunc_ts(ns, ArrowType.TIMESTAMP_NS, TRUNC_MICROSECOND)
    assert_equal(t.get(0), Int64(1_234_567_000))
    assert_equal(t.get(1), Int64(-1_000))
    assert_equal(t.get(2), Int64(5_000))
    var d = date_trunc_date32(_date32_parent(), TRUNC_MICROSECOND)
    assert_equal(d.null_count, 2)
    for i in range(10):
        if i != 0 and i != 5:
            assert_equal(d.get(i), Int32(_jan1(i)), "us trunc on DATE32 row " + String(i))


def test_day_index_kernel_unit_codes_mirror_the_plan_IR() raises:
    """Every unit the kernels restate (`_K_*`) is passed AS the plan IR's
    `EXTRACT_*` constant and answers its own field. A drifted local copy
    raises or answers another field. Rows: 2024-12-30 (Monday, ISO 2025-W01)
    and 1969-12-28 (Sunday, ISO 1969-W52)."""
    var d = PrimitiveArray[DType.int32].from_list([Int32(20087), Int32(-4)])
    var dow = extract_day_index_date32(d, EXTRACT_DAYOFWEEK)
    var isodow = extract_day_index_date32(d, EXTRACT_ISODOW)
    var doy = extract_day_index_date32(d, EXTRACT_DAYOFYEAR)
    assert_equal(dow.get(0), 1)
    assert_equal(dow.get(1), 0)
    assert_equal(isodow.get(0), 1)
    assert_equal(isodow.get(1), 7)
    assert_equal(doy.get(0), 365)
    assert_equal(doy.get(1), 362)
    var wk = extract_iso_week_date32(d, EXTRACT_WEEK)
    var iy = extract_iso_week_date32(d, EXTRACT_ISOYEAR)
    var yw = extract_iso_week_date32(d, EXTRACT_YEARWEEK)
    assert_equal(wk.get(0), 1)
    assert_equal(wk.get(1), 52)
    assert_equal(iy.get(0), 2025)
    assert_equal(iy.get(1), 1969)
    assert_equal(yw.get(0), 202501)
    assert_equal(yw.get(1), 196952)
    # TIMESTAMP_US 1.234567 s past the epoch: the seconds are part of both.
    var t = PrimitiveArray[DType.int64].from_list([Int64(1_234_567)])
    assert_equal(extract_subsecond_ts(t, ArrowType.TIMESTAMP_US, EXTRACT_MILLISECOND).get(0), 1234)
    assert_equal(extract_subsecond_ts(t, ArrowType.TIMESTAMP_US, EXTRACT_MICROSECOND).get(0), 1234567)


def test_mojo_integer_division_and_modulo_are_FLOOR_not_truncating() raises:
    """`_div_floor` / `_mod_floor` in temporal_extract are identities only
    because Mojo's `//` and `%` floor. Runtime operands, so nothing folds."""
    var xs = List[Int]()
    xs.append(-25505)
    xs.append(7)
    xs.append(-3)
    assert_equal(xs[0] // xs[1], -3644)
    assert_equal(xs[0] % xs[1], 3)
    assert_equal(xs[1] // xs[2], -3)
    assert_equal(xs[1] % xs[2], -2)
    var a = Int64(xs[0])
    var b = Int64(xs[1])
    assert_equal(a // b, Int64(-3644))
    assert_equal(a % b, Int64(3))
    var a32 = Int32(xs[0])
    var b32 = Int32(xs[1])
    assert_equal(a32 // b32, Int32(-3644))
    assert_equal(a32 % b32, Int32(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
