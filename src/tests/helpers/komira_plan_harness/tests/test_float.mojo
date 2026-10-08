# Float cells: which hand-written decimals are accepted, which bit patterns
# a decimal may claim, and how two cells compare.
#
# Defects these catch: a parser that rounds a decimal-only cell (0.1)
# instead of refusing it; a full cell whose decimal disagrees with its bits
# being accepted; NaN or -0.0 compared by value (NaN != NaN, -0.0 == 0.0)
# instead of by bits; an ulps or rel tolerance applied wrongly.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field

from komira_plan_harness import (
    CanonPolicy,
    FloatCell,
    FloatTolerance,
    check_batch,
    float_cell_text,
    float_cells_match,
    parse_float_cell,
    render_batch,
    ulp_distance,
)
from komira_plan_harness.fixtures import BatchBuilder, all_valid, fixed_column


def _bits(text: String, width: Int) raises -> UInt64:
    var c = parse_float_cell(text, width)
    assert_false(c.is_null or c.any_nan)
    return c.bits


def test_exact_decimals_are_accepted() raises:
    assert_equal(_bits("0.5", 64), 0x3FE0000000000000)
    assert_equal(_bits("-0.0", 64), 0x8000000000000000)
    assert_equal(_bits("0", 64), 0)
    assert_equal(_bits("1e22", 64), 0x4480F0CF064DD592)
    assert_equal(_bits("-2.5e-1", 64), 0xBFD0000000000000)
    assert_equal(_bits("16777216", 32), 0x4B800000)
    assert_equal(_bits("16777217", 64), 0x4170000010000000)
    assert_equal(_bits("65504", 16), 0x7BFF)
    # float16's smallest subnormal, 2^-24, written out in full.
    assert_equal(_bits("0.000000059604644775390625", 16), 0x0001)
    assert_equal(_bits("inf", 64), 0x7FF0000000000000)
    assert_equal(_bits("-inf", 32), 0xFF800000)


def test_inexact_decimals_are_refused() raises:
    with assert_raises(contains="not exactly representable as float64"):
        _ = parse_float_cell("0.1", 64)
    with assert_raises(contains="not exactly representable as float64"):
        _ = parse_float_cell("1e23", 64)
    # Truncating instead of refusing would read 1.1 as 1.0 and 123.456 as 123.
    with assert_raises(contains="not exactly representable as float64"):
        _ = parse_float_cell("1.1", 64)
    with assert_raises(contains="not exactly representable as float64"):
        _ = parse_float_cell("123.456", 64)
    with assert_raises(contains="not exactly representable as float32"):
        _ = parse_float_cell("16777217", 32)
    with assert_raises(contains="not exactly representable as float64"):
        _ = parse_float_cell("5e-324", 64)
    with assert_raises(contains="out of range as float16"):
        _ = parse_float_cell("65536", 16)
    with assert_raises(contains="is not a decimal number"):
        _ = parse_float_cell("1.5x", 64)


def test_a_decimal_must_round_to_its_bits() raises:
    assert_equal(_bits("0.1|0x3FB999999999999A", 64), 0x3FB999999999999A)
    assert_equal(_bits("4.9406564584124654e-324|0x0000000000000001", 64), 1)
    assert_equal(_bits("0.1|0x3DCCCCCD", 32), 0x3DCCCCCD)
    # The neighbouring float is not what 0.1 rounds to.
    with assert_raises(contains="does not round to the bits"):
        _ = parse_float_cell("0.1|0x3FB9999999999999", 64)
    with assert_raises(contains="does not round to the bits"):
        _ = parse_float_cell("1.5|0x3FF0000000000000", 64)
    with assert_raises(contains="does not round to the bits"):
        _ = parse_float_cell("0.0|0x8000000000000000", 64)
    with assert_raises(contains="says NaN but the bits are not a NaN"):
        _ = parse_float_cell("NaN|0x3FF0000000000000", 64)
    with assert_raises(contains="gives a number but the bits are NaN or inf"):
        _ = parse_float_cell("1.0|0x7FF8000000000000", 64)
    with assert_raises(contains="hex digits"):
        _ = parse_float_cell("1.0|0x3FF0", 64)


def test_a_midpoint_rounds_to_the_even_mantissa() raises:
    # 65520 is half way from float16's largest finite (65504, 0x7BFF, odd
    # mantissa) to 65536: it rounds to the even side (infinity), so it does
    # not round to 0x7BFF.
    with assert_raises(contains="does not round to the bits"):
        _ = parse_float_cell("65520|0x7BFF", 16)
    assert_equal(_bits("65504|0x7BFF", 16), 0x7BFF)
    # 1 + 2^-53 is half way between 1.0 (even) and the next float (odd).
    var mid = String("1.00000000000000011102230246251565404236316680908203125")
    assert_equal(_bits(mid + "|0x3FF0000000000000", 64), 0x3FF0000000000000)
    with assert_raises(contains="does not round to the bits"):
        _ = parse_float_cell(mid + "|0x3FF0000000000001", 64)


def test_canonical_text() raises:
    assert_equal(float_cell_text(0x3FF8000000000000, 64), "1.5|0x3FF8000000000000")
    assert_equal(float_cell_text(0x8000000000000000, 64), "-0.0|0x8000000000000000")
    assert_equal(float_cell_text(0, 64), "0.0|0x0000000000000000")
    assert_equal(float_cell_text(0x7FF0000000000000, 64), "inf|0x7FF0000000000000")
    assert_equal(float_cell_text(0xFFF0000000000000, 64), "-inf|0xFFF0000000000000")
    assert_equal(float_cell_text(0x7FF8000000000001, 64), "NaN|0x7FF8000000000001")
    assert_equal(float_cell_text(0x3C00, 16), "1.0|0x3C00")
    # Every rendered cell parses back to its own bits: the decimal the
    # standard library prints rounds to the bits at that width.
    var samples: List[UInt64] = [
        0x3FB999999999999A, 0x0000000000000001, 0x7FEFFFFFFFFFFFFF,
        0x0010000000000000, 0x000FFFFFFFFFFFFF, 0xC09F400000000000,
        0x3FD5555555555555, 0x4340000000000001,
    ]
    for b in samples:
        assert_equal(_bits(float_cell_text(b, 64), 64), b)
    var s32: List[UInt64] = [0x3DCCCCCD, 0x00000001, 0x7F7FFFFF, 0x00800000, 0xBEAAAAAB]
    for b in s32:
        assert_equal(_bits(float_cell_text(b, 32), 32), b)
    var s16: List[UInt64] = [0x0001, 0x03FF, 0x0400, 0x7BFF, 0x3555, 0xB800]
    for b in s16:
        assert_equal(_bits(float_cell_text(b, 16), 16), b)


def _cell(bits: UInt64) -> FloatCell:
    return FloatCell(False, False, bits)


def test_nan_and_negative_zero_compare_by_bits() raises:
    var exact = FloatTolerance()
    var loose = FloatTolerance.parse("rel=0.5")
    var nan1 = _cell(0x7FF8000000000001)
    var nan0 = _cell(0x7FF8000000000000)
    # The same NaN matches itself (NaN != NaN as a value).
    assert_true(float_cells_match(nan1, nan1.copy(), exact, 64))
    # A NaN given with bits matches only those bits.
    assert_false(float_cells_match(nan1, nan0, exact, 64))
    # Bare NaN matches any NaN, and nothing else.
    var any_nan = FloatCell(False, True, 0)
    assert_true(float_cells_match(any_nan, nan0, exact, 64))
    assert_false(float_cells_match(any_nan, _cell(0x3FF0000000000000), exact, 64))
    # -0.0 is not 0.0, whatever the tolerance.
    var nz = _cell(0x8000000000000000)
    var pz = _cell(0)
    assert_false(float_cells_match(nz, pz, exact, 64))
    assert_false(float_cells_match(nz, pz, loose, 64))
    assert_true(float_cells_match(nz, nz.copy(), exact, 64))
    # Infinities only match themselves.
    assert_false(
        float_cells_match(_cell(0x7FF0000000000000), _cell(0x7FEFFFFFFFFFFFFF), loose, 64)
    )
    # NULL only matches NULL.
    var null = FloatCell(True, False, 0)
    assert_true(float_cells_match(null, null.copy(), exact, 64))
    assert_false(float_cells_match(null, pz, exact, 64))


def test_nan_and_negative_zero_through_a_result() raises:
    """The same rule end to end: expected text against a rendered batch."""
    var bb = BatchBuilder()
    var vals: List[UInt64] = [0x7FF8000000000001, 0x0000000000000000]
    bb.add(Field("x", ArrowType.FLOAT64, False), fixed_column(ArrowType.FLOAT64, 8, vals, all_valid(2)))
    var batch = bb.build()
    var head = String("#! komira-plan-conformance v1\n#  order: total\n#  float: rel=0.5\nx:float64\n")
    assert_true(check_batch(head + "NaN|0x7FF8000000000001\n0.0\n", batch).ok())
    var report = check_batch(head + "NaN|0x7FF8000000000000\n-0.0\n", batch)
    assert_equal(report.count(), 2)


def test_ulps_and_rel() raises:
    var one = _cell(0x3FF0000000000000)
    var next = _cell(0x3FF0000000000001)
    assert_false(float_cells_match(one, next, FloatTolerance(), 64))
    assert_true(float_cells_match(one, next, FloatTolerance.of_ulps(1), 64))
    assert_equal(ulp_distance(0x8000000000000001, 0x0000000000000001, 64), 2)
    assert_equal(ulp_distance(0x8000000000000000, 0x0000000000000000, 64), 0)
    var hundred = _cell(0x4059000000000000)  # 100.0
    var near = _cell(0x40590000006B5FCA)  # about 100.0000001
    assert_true(float_cells_match(hundred, near, FloatTolerance.parse("rel=1e-6"), 64))
    assert_false(float_cells_match(hundred, near, FloatTolerance.parse("rel=1e-12"), 64))
    with assert_raises(contains="neither ulps"):
        _ = FloatTolerance.parse("abs=1")
    with assert_raises(contains="negative tolerance"):
        _ = FloatTolerance.parse("rel=-1")


def test_rendered_float_columns() raises:
    var bb = BatchBuilder()
    var v32: List[UInt64] = [0x3DCCCCCD]
    var v16: List[UInt64] = [0x7E00]
    bb.add(Field("a", ArrowType.FLOAT32, False), fixed_column(ArrowType.FLOAT32, 4, v32, all_valid(1)))
    bb.add(Field("b", ArrowType.FLOAT16, False), fixed_column(ArrowType.FLOAT16, 2, v16, all_valid(1)))
    var got = render_batch(bb.build(), CanonPolicy.total())
    assert_true(got.rows[0][0].endswith("|0x3DCCCCCD"))
    assert_equal(got.rows[0][1], "NaN|0x7E00")
    assert_equal(got.float_widths[0], 32)
    assert_equal(got.float_widths[1], 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
