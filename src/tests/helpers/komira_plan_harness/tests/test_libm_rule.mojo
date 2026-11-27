# The rule for an answer a transcendental function computes (libm_rule.mojo):
# which query texts call one, and the tolerance each gets on and off the
# oracle's platform.
#
# The numbers are the oracle's and macOS's answers for `cbrt` of two group sums
# of komira_decimal_compare_conformance's double sites: DuckDB on Linux gives
# -4306981.625529153 and 2642245.9496291336, macOS's libm the adjacent doubles
# -4306981.625529152 and 2642245.949629133 (each the correctly rounded root).

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_plan_harness import (
    OFF_ORACLE_HOST_ULPS,
    TRANSCENDENTAL_FUNCTIONS,
    FloatCell,
    calls_transcendental,
    float_cells_match,
    is_oracle_host,
    parse_float_cell,
    transcendental_tolerance,
    ulp_distance,
)

comptime _CBRT_SUM = "select k, cbrt(sum(v)) as x from pj group by k"
comptime _SUM = "select k, sum(v) * 1e0 as x from pj group by k"


def _cell(text: String) raises -> FloatCell:
    return parse_float_cell(text, 64)


def _bits_cell(bits: UInt64) -> FloatCell:
    return FloatCell(False, False, bits)


def test_every_transcendental_is_a_call() raises:
    var names = materialize[TRANSCENDENTAL_FUNCTIONS]()
    assert_equal(len(names), 23)
    for i in range(len(names)):
        assert_true(
            calls_transcendental("select " + names[i] + "(x) from t"),
            names[i],
        )


def test_a_call_is_found_in_any_case_and_spacing() raises:
    assert_true(calls_transcendental(_CBRT_SUM))
    assert_true(calls_transcendental("SELECT CBRT (s2) FROM pg"))
    assert_true(calls_transcendental("select Atan2\t(y, x) from t"))
    assert_true(calls_transcendental("select 1 + ln(\nx) from t"))
    assert_true(calls_transcendental("cbrt(x)"))


def test_a_name_that_is_not_a_call_is_not_one() raises:
    assert_false(calls_transcendental(_SUM))
    assert_false(calls_transcendental("select cbrt_x from t"))
    assert_false(calls_transcendental("select xcos(y) from t"))
    assert_false(calls_transcendental("select cos from t"))
    assert_false(calls_transcendental("select t.cos"))
    assert_false(calls_transcendental("select sqrt(x), floor(x), degrees(x)"))
    assert_false(calls_transcendental(""))


def test_the_oracle_host_is_bit_exact() raises:
    assert_equal(transcendental_tolerance(_CBRT_SUM, True).ulps, 0)
    assert_equal(transcendental_tolerance(_SUM, True).ulps, 0)


def test_off_the_oracle_host_only_a_transcendental_is_loosened() raises:
    var t = transcendental_tolerance(_CBRT_SUM, False)
    assert_false(t.is_rel)
    assert_equal(t.ulps, OFF_ORACLE_HOST_ULPS)
    assert_equal(t.text, "ulps=4")
    assert_equal(transcendental_tolerance(_SUM, False).ulps, 0)


def test_the_oracle_host_is_linux() raises:
    comptime if CompilationTarget.is_linux():
        assert_true(is_oracle_host())
    else:
        assert_false(is_oracle_host())


def test_macos_cbrt_answers_meet_the_oracle_off_its_host() raises:
    var off = transcendental_tolerance(_CBRT_SUM, False)
    var on = transcendental_tolerance(_CBRT_SUM, True)
    # (DuckDB on Linux, macOS) as bits: -4306981.625529153 and ...152,
    # 2642245.9496291336 and 2642245.949629133.
    var want = List[UInt64]()
    var got = List[UInt64]()
    want.append(0xC1506E096808AB6E)
    got.append(0xC1506E096808AB6D)
    want.append(0x414428A2F98D728C)
    got.append(0x414428A2F98D728B)
    for p in range(len(want)):
        var w = _bits_cell(want[p])
        var g = _bits_cell(got[p])
        assert_equal(ulp_distance(w.bits, g.bits, 64), 1)
        assert_true(float_cells_match(w, g, off, 64), String(p))
        assert_false(float_cells_match(w, g, on, 64), String(p))


def test_the_bound_is_exact() raises:
    var off = transcendental_tolerance(_CBRT_SUM, False)
    var want = _bits_cell(0x414428A2F98D728C)
    var b = UInt64(OFF_ORACLE_HOST_ULPS)
    assert_true(float_cells_match(want, _bits_cell(want.bits + b), off, 64))
    assert_true(float_cells_match(want, _bits_cell(want.bits - b), off, 64))
    assert_false(
        float_cells_match(want, _bits_cell(want.bits + b + 1), off, 64)
    )
    assert_false(
        float_cells_match(want, _bits_cell(want.bits - b - 1), off, 64)
    )


def test_nan_inf_and_signed_zero_stay_exact_off_the_host() raises:
    var off = transcendental_tolerance(_CBRT_SUM, False)
    assert_false(float_cells_match(_cell("1.0"), _cell("inf"), off, 64))
    assert_false(float_cells_match(_cell("inf"), _cell("-inf"), off, 64))
    assert_false(
        float_cells_match(_cell("1.0"), FloatCell(False, True, 0), off, 64)
    )
    assert_false(float_cells_match(_cell("0.0"), _cell("-0.0"), off, 64))
    # The smallest positive and negative subnormals are 2 ulp apart across
    # zero, so a sign change within the bound is accepted only through zero.
    assert_true(float_cells_match(_bits_cell(1), _bits_cell(1 << 63 | 1), off, 64))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
