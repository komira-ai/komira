# The run id: `<epoch>-<16 hex>`, a valid validation-run id, at most 63 bytes,
# taken from the clock and the entropy only; and 1000 real mints are distinct.

from std.collections import Set
from std.testing import assert_equal, assert_true

from komira_test_run_id import (
    FixedWallClock,
    ScriptedEntropy,
    hex16_lower,
    SystemClock,
    UrandomEntropy,
    mint_run_id,
)
from komira_validation_run.validation_run_tag import is_valid_validation_run_id


def test_format_from_scripted_sources() raises:
    var clock = FixedWallClock(1790000000)
    var entropy = ScriptedEntropy([UInt64(0xFF), UInt64(0xFFFFFFFFFFFFFFFF), UInt64(0)])
    var a = mint_run_id(clock, entropy)
    assert_equal(a.value, "1790000000-00000000000000ff")
    assert_equal(a.created_unix, 1790000000)
    assert_true(is_valid_validation_run_id(a.value))
    assert_true(a.value.byte_length() <= 63)
    var b = mint_run_id(clock, entropy)
    assert_equal(b.value, "1790000000-ffffffffffffffff")
    clock.advance(5)
    var c = mint_run_id(clock, entropy)
    assert_equal(c.value, "1790000005-0000000000000000")
    assert_equal(String(c), c.value)
    # The exported formatter is the one the id uses.
    assert_equal(hex16_lower(UInt64(0xAB)), "00000000000000ab")
    assert_equal(hex16_lower(UInt64(0xFFFFFFFFFFFFFFFF)), "ffffffffffffffff")


def test_refuses_a_zero_clock_and_an_exhausted_source() raises:
    var zero = FixedWallClock(0)
    var e1 = ScriptedEntropy([UInt64(1)])
    var refused = False
    try:
        _ = mint_run_id(zero, e1)
    except:
        refused = True
    assert_true(refused, "minted from a zero clock")
    var clock = FixedWallClock(1790000000)
    var empty = ScriptedEntropy(List[UInt64]())
    refused = False
    try:
        _ = mint_run_id(clock, empty)
    except:
        refused = True
    assert_true(refused, "minted with no entropy")


def test_a_refusal_names_its_cause_and_draws_nothing() raises:
    # A negative reading is refused like zero (`<= 0`, not `== 0`), the
    # message carries the reading, and a refused mint draws no entropy.
    var behind = FixedWallClock(-5)
    var e1 = ScriptedEntropy([UInt64(7)])
    var msg = String("")
    try:
        _ = mint_run_id(behind, e1)
    except e:
        msg = String(e)
    assert_equal(msg, "mint_run_id: the wall clock read -5; refusing to mint")
    assert_equal(e1.drawn, 0)
    # The first positive second is accepted: the boundary is 0, not 1.
    var first = FixedWallClock(1)
    var b = mint_run_id(first, e1)
    assert_equal(b.value, "1-0000000000000007")
    assert_equal(b.created_unix, 1)
    # An exhausted source's error reaches the caller unchanged.
    var clock = FixedWallClock(1790000000)
    msg = String("")
    try:
        _ = mint_run_id(clock, e1)
    except e:
        msg = String(e)
    assert_equal(msg, "ScriptedEntropy: script exhausted after 1 values")
    assert_equal(e1.drawn, 1)


def test_a_thousand_real_mints_are_distinct() raises:
    var clock = SystemClock()
    var entropy = UrandomEntropy()
    var seen = Set[String]()
    for _ in range(1000):
        var id = mint_run_id(clock, entropy)
        assert_true(is_valid_validation_run_id(id.value), id.value)
        assert_true(id.value.byte_length() <= 63)
        seen.add(id.value)
    assert_equal(len(seen), 1000)


def main() raises:
    test_format_from_scripted_sources()
    test_refuses_a_zero_clock_and_an_exhausted_source()
    test_a_refusal_names_its_cause_and_draws_nothing()
    test_a_thousand_real_mints_are_distinct()
    print("test_run_id: OK")
