# =============================================================================
# test_extract_mode_vocab.mojo -- the extraction-mode vocabulary.
# =============================================================================
#
#   ordinals     rules is 0 and model is 1 (a spec stores them) and the count
#                is 2.
#   names        each mode's name parses back to that mode; the name of an
#                unknown ordinal is "unknown".
#   parse        model is chosen only by the name "model" in some ASCII case;
#                the empty string, a misspelling, a name with extra bytes, the
#                name of a mode this package does not have and a non-ASCII
#                string all give rules.
#   normalise    every known ordinal is unchanged; every other integer in a wide
#                range, negatives included, gives rules and never model.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg_mode import (
    EXTRACT_MODE_COUNT,
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_RULES,
    extract_mode_name,
    is_known_extract_mode,
    normalize_extract_mode,
    parse_extract_mode,
)


def test_ordinals_are_the_stored_values() raises:
    assert_equal(EXTRACT_MODE_RULES, 0)
    assert_equal(EXTRACT_MODE_MODEL, 1)
    assert_equal(EXTRACT_MODE_COUNT, 2)


def test_membership_is_exactly_the_declared_ordinals() raises:
    for n in range(-5, 12):
        assert_equal(is_known_extract_mode(n), n >= 0 and n < EXTRACT_MODE_COUNT)


def test_each_mode_name_round_trips() raises:
    for n in range(EXTRACT_MODE_COUNT):
        assert_equal(parse_extract_mode(String(extract_mode_name(n))), n)
    assert_equal(extract_mode_name(EXTRACT_MODE_RULES), "rules")
    assert_equal(extract_mode_name(EXTRACT_MODE_MODEL), "model")


def test_an_unknown_ordinal_has_the_name_unknown() raises:
    assert_equal(extract_mode_name(2), "unknown")
    assert_equal(extract_mode_name(-1), "unknown")
    assert_equal(extract_mode_name(1000), "unknown")


def test_parse_accepts_model_in_any_ascii_case() raises:
    assert_equal(parse_extract_mode("model"), EXTRACT_MODE_MODEL)
    assert_equal(parse_extract_mode("MODEL"), EXTRACT_MODE_MODEL)
    assert_equal(parse_extract_mode("MoDeL"), EXTRACT_MODE_MODEL)
    assert_equal(parse_extract_mode("RULES"), EXTRACT_MODE_RULES)


def test_parse_of_anything_else_falls_back_to_rules() raises:
    assert_equal(parse_extract_mode(""), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("rules"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("modle"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("models"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("mode"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode(" model"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("model\n"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("structural"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("1"), EXTRACT_MODE_RULES)
    assert_equal(parse_extract_mode("mödel"), EXTRACT_MODE_RULES)


def test_normalise_keeps_every_known_ordinal() raises:
    assert_equal(normalize_extract_mode(EXTRACT_MODE_RULES), EXTRACT_MODE_RULES)
    assert_equal(normalize_extract_mode(EXTRACT_MODE_MODEL), EXTRACT_MODE_MODEL)


def test_normalise_never_yields_model_for_an_unknown_ordinal() raises:
    for n in range(-1000, 1000):
        var got = normalize_extract_mode(n)
        if n == EXTRACT_MODE_MODEL:
            assert_equal(got, EXTRACT_MODE_MODEL)
        else:
            assert_equal(got, EXTRACT_MODE_RULES)
    assert_equal(normalize_extract_mode(2), EXTRACT_MODE_RULES)
    assert_equal(normalize_extract_mode(0x7FFFFFFFFFFFFFFF), EXTRACT_MODE_RULES)
    assert_true(is_known_extract_mode(normalize_extract_mode(-7)))
    assert_false(normalize_extract_mode(-7) == EXTRACT_MODE_MODEL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
