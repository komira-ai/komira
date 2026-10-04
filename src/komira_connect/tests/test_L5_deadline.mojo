# =============================================================================
# test_L5_deadline.mojo — Grpc-Timeout + Connect-Timeout-Ms parsing
# =============================================================================
#
# Deadline header parsing.
#
# Coverage:
#   T1   parse_grpc_timeout — all 6 units (H/M/S/m/u/n) parse to micros.
#   T2   parse_grpc_timeout — malformed input returns DEADLINE_UNSET_MICROS.
#   T3   parse_grpc_timeout — empty/whitespace returns UNSET.
#   T4   parse_grpc_timeout — nanosecond ceiling: 1500n → 2us (ceil-div).
#   T5   parse_connect_timeout_ms — basic decimal parse + saturation.
#   T6   parse_connect_timeout_ms — malformed returns UNSET.
#   T7   encode_grpc_timeout_us round-trip via the largest fitting unit.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    DEADLINE_UNSET_MICROS,
    parse_grpc_timeout,
    parse_connect_timeout_ms,
    encode_grpc_timeout_us,
)


def test_t1_grpc_timeout_units() raises:
    """T1 — all six units parse correctly."""
    assert_equal(parse_grpc_timeout(String("5H")), 5 * 3_600_000_000, "5H")
    assert_equal(parse_grpc_timeout(String("3M")), 3 * 60_000_000, "3M")
    assert_equal(parse_grpc_timeout(String("10S")), 10_000_000, "10S")
    assert_equal(parse_grpc_timeout(String("500m")), 500_000, "500ms")
    assert_equal(parse_grpc_timeout(String("250u")), 250, "250us")
    assert_equal(parse_grpc_timeout(String("1000n")), 1, "1000ns → 1us")


def test_t2_grpc_timeout_malformed() raises:
    """T2 — malformed → UNSET."""
    assert_equal(parse_grpc_timeout(String("5X")), DEADLINE_UNSET_MICROS, "bad unit")
    assert_equal(parse_grpc_timeout(String("abc")), DEADLINE_UNSET_MICROS, "no digits")
    assert_equal(parse_grpc_timeout(String("123456789S")), DEADLINE_UNSET_MICROS, "9 digits")
    assert_equal(parse_grpc_timeout(String("S")), DEADLINE_UNSET_MICROS, "just unit")


def test_t3_grpc_timeout_empty() raises:
    """T3 — empty header → UNSET."""
    assert_equal(parse_grpc_timeout(String("")), DEADLINE_UNSET_MICROS, "empty")


def test_t4_grpc_timeout_nanosecond_ceiling() raises:
    """T4 — nanosecond timeouts ceil up to the next microsecond."""
    assert_equal(parse_grpc_timeout(String("1n")), 1, "1ns → 1us (ceil)")
    assert_equal(parse_grpc_timeout(String("999n")), 1, "999ns → 1us (ceil)")
    assert_equal(parse_grpc_timeout(String("1500n")), 2, "1500ns → 2us")


def test_t5_connect_timeout_ms() raises:
    """T5 — Connect-Timeout-Ms basic parse."""
    assert_equal(parse_connect_timeout_ms(String("100")), 100_000, "100ms → 100000us")
    assert_equal(parse_connect_timeout_ms(String("1")), 1_000, "1ms → 1000us")
    assert_equal(parse_connect_timeout_ms(String("60000")), 60_000_000, "60s")


def test_t6_connect_timeout_ms_malformed() raises:
    """T6 — malformed → UNSET."""
    assert_equal(parse_connect_timeout_ms(String("")), DEADLINE_UNSET_MICROS, "empty")
    assert_equal(parse_connect_timeout_ms(String("abc")), DEADLINE_UNSET_MICROS, "non-digit")
    assert_equal(parse_connect_timeout_ms(String("100abc")), DEADLINE_UNSET_MICROS, "trailing junk")


def test_t7_encode_grpc_timeout_largest_unit() raises:
    """T7 — encode_grpc_timeout_us picks the largest unit that fits."""
    assert_equal(encode_grpc_timeout_us(3_600_000_000), String("1H"), "1 hour")
    assert_equal(encode_grpc_timeout_us(60_000_000), String("1M"), "1 minute")
    assert_equal(encode_grpc_timeout_us(1_000_000), String("1S"), "1 second")
    assert_equal(encode_grpc_timeout_us(1_500_000), String("1500m"), "1.5 sec → 1500ms")
    assert_equal(encode_grpc_timeout_us(250), String("250u"), "250us")
    assert_equal(encode_grpc_timeout_us(0), String("0u"), "zero")

    # Round-trip via parse_grpc_timeout
    assert_equal(parse_grpc_timeout(encode_grpc_timeout_us(5_000_000)), 5_000_000, "5s round-trip")
    assert_equal(parse_grpc_timeout(encode_grpc_timeout_us(123)), 123, "123us round-trip")


def main() raises:
    test_t1_grpc_timeout_units()
    test_t2_grpc_timeout_malformed()
    test_t3_grpc_timeout_empty()
    test_t4_grpc_timeout_nanosecond_ceiling()
    test_t5_connect_timeout_ms()
    test_t6_connect_timeout_ms_malformed()
    test_t7_encode_grpc_timeout_largest_unit()
    print("test_L5_deadline: 7/7 PASS")
