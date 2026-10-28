# =============================================================================
# test_proto_codec_json_float32_parse_edges.mojo — `parse_decimal_f32` on text
# longer than its 120 digit buffer, and on the spellings around the exponent.
# =============================================================================
#
# The reader keeps the first 120 significant digits and remembers whether a
# non-zero digit was dropped after them, because a decimal exactly halfway
# between two float32 values must round up when any digit follows the tie.
#
#   P1  digits past the 120th, in the integer part and in the fraction, change
#       the value only when one of them is non-zero: zeros leave an exact
#       tie a tie (ties to even), a non-zero digit pushes it up.
#       Catches: a dropped digit that is ignored (an above-tie value read as a
#       tie and rounded to even), a dropped zero that counts as a digit.
#   P2  the exponent marker is `e` or `E`; text left over after the number
#       (after the integer part, the fraction, or the exponent digits) is not
#       a number. Catches: a reader that stops at the first unexpected byte
#       and returns what it had.
#   P3  the smallest normal float32, 2^-126, is written as its shortest
#       decimal and reads back to the same float. Catches: a writer that
#       takes the lower neighbour's spacing for a power of two at the bottom
#       of the normal range.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    parse_decimal_f32,
    write_proto3_json_f32,
)


def _zeros(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += "0"
    return s^


def _text(v: Float32) -> String:
    var buf = List[UInt8]()
    write_proto3_json_f32(buf, v)
    return String(unsafe_from_utf8=Span(buf))


def _refusal(text: String) -> String:
    try:
        _ = parse_decimal_f32(text)
    except e:
        return String(e)
    return String("")


# 1 + 2^-24: exactly halfway between 1.0 and the next float32, 1 + 2^-23.
comptime TIE = "1.000000059604644775390625"
comptime NEXT = "1.00000011920928955078125"


def test_p1_digits_past_the_buffer() raises:
    var one = parse_decimal_f32("1")
    var next = parse_decimal_f32(NEXT)
    assert_true(next > one, "the neighbour above 1.0")
    assert_equal(parse_decimal_f32(TIE), one, "an exact tie rounds to even")

    # Fraction: 120+ more digits after the tie.
    assert_equal(
        parse_decimal_f32(String(TIE) + _zeros(130)),
        one,
        "zeros after the tie leave it a tie",
    )
    assert_equal(
        parse_decimal_f32(String(TIE) + _zeros(130) + "1"),
        next,
        "a non-zero digit past the buffer pushes the tie up",
    )
    # Integer part: 2^24 + 1 is a tie between 2^24 and 2^24 + 2; the same
    # number with 130 more integer digits is far above the range, so scale it
    # back with the exponent.
    var big_zeros = String("16777217") + _zeros(130) + "e-130"
    var big_tail = String("16777217") + _zeros(129) + "1e-130"
    assert_equal(
        parse_decimal_f32(big_zeros),
        parse_decimal_f32("16777216"),
        "zeros after the tie digits: even, 2^24",
    )
    assert_equal(
        parse_decimal_f32(big_tail),
        parse_decimal_f32("16777218"),
        "a non-zero digit past the buffer pushes 2^24 + 1 up",
    )
    # More than 120 integer digits of zeros after a 1, scaled back.
    assert_equal(
        parse_decimal_f32(String("1") + _zeros(130) + "e-100"),
        parse_decimal_f32("1e30"),
    )
    assert_equal(
        parse_decimal_f32(String("1") + _zeros(130) + "e-130"),
        one,
        "130 integer zeros scaled back",
    )
    # More than 120 non-zero integer digits.
    var ones = String("")
    for _ in range(130):
        ones += "1"
    assert_equal(
        parse_decimal_f32(ones + "e-100"),
        parse_decimal_f32("1.1111111e29"),
        "130 ones, scaled back",
    )
    print("  test_p1_digits_past_the_buffer: PASS")


def test_p2_exponent_and_trailing_text() raises:
    assert_equal(parse_decimal_f32("1E5"), parse_decimal_f32("100000"), "capital E")
    assert_equal(parse_decimal_f32("1e+5"), parse_decimal_f32("100000"))
    assert_equal(parse_decimal_f32("125e-2"), parse_decimal_f32("1.25"))
    assert_equal(parse_decimal_f32("0.5"), Float32(0.5))
    assert_equal(parse_decimal_f32("100.001"), parse_decimal_f32("100.001000"))
    assert_equal(parse_decimal_f32("1.05"), parse_decimal_f32("105e-2"))
    assert_equal(parse_decimal_f32("0.0500"), parse_decimal_f32("5e-2"))
    assert_equal(parse_decimal_f32("0.000"), Float32(0.0), "zeros")

    comptime NOT = "JsonError: not a proto3 float: "
    assert_equal(_refusal("1x"), String(NOT) + "1x", "junk after the integer part")
    assert_equal(_refusal("1.5x"), String(NOT) + "1.5x", "junk after the fraction")
    assert_equal(_refusal("1e5x"), String(NOT) + "1e5x", "junk after the exponent")
    assert_equal(_refusal("1E"), String(NOT) + "1E", "an exponent with no digits")
    assert_equal(_refusal("1e+"), String(NOT) + "1e+", "a signed exponent with no digits")
    assert_equal(_refusal("1."), String(NOT) + "1.", "a point with no fraction")
    assert_equal(_refusal(".5"), String(NOT) + ".5", "no integer part")
    assert_equal(_refusal("-"), String(NOT) + "-", "a sign alone")
    assert_equal(_refusal(""), String(NOT), "nothing")
    print("  test_p2_exponent_and_trailing_text: PASS")


def test_p3_the_smallest_normal_float32() raises:
    var min_normal = parse_decimal_f32("1.17549435e-38")
    assert_equal(_text(min_normal), String("1.1754944e-38"), "shortest decimal of 2^-126")
    assert_equal(parse_decimal_f32(_text(min_normal)), min_normal, "and it reads back")
    print("  test_p3_the_smallest_normal_float32: PASS")


def main() raises:
    test_p1_digits_past_the_buffer()
    test_p2_exponent_and_trailing_text()
    test_p3_the_smallest_normal_float32()
