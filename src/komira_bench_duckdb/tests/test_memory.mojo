# DuckDB's printed sizes and the read-back check, on fixed text.
#
# What each test proves:
# - test_sizes_are_read_in_binary_and_decimal_units: `953.7 MiB`, `4 GiB`,
#   `10 GB`, `16384 B`, a bare number and lower-case units come out as the
#   right number of bytes with the right count of written decimals.
# - test_text_that_is_not_a_size_is_refused: empty text, a unit with no number,
#   an unknown unit and two numbers raise.
# - test_a_read_back_size_matches_within_the_rounding_of_its_digits: 953.7 MiB
#   matches 1000000000 bytes (rounded to one decimal), 1.0 GiB matches
#   1 GiB and a limit 3% away (the digits cannot tell), and neither matches a
#   limit that is a whole rounding step further (953.7 MiB against 1.01e9
#   bytes, 1.0 GiB against 1.1 GiB); an unreadable read-back
#   raises.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import parse_size, size_matches


def _refused(text: String) -> Bool:
    try:
        _ = parse_size(text)
    except:
        return True
    return False


def test_sizes_are_read_in_binary_and_decimal_units() raises:
    var a = parse_size(String("953.7 MiB"))
    assert_equal(a.decimals, 1)
    assert_equal(a.unit_bytes, 1048576.0)
    assert_true(a.bytes > 999900000.0 and a.bytes < 1000100000.0)
    assert_equal(parse_size(String("4 GiB")).bytes, 4294967296.0)
    assert_equal(parse_size(String("4GiB")).bytes, 4294967296.0)
    assert_equal(parse_size(String("10 GB")).bytes, 10000000000.0)
    assert_equal(parse_size(String("16384 B")).bytes, 16384.0)
    assert_equal(parse_size(String("2048")).bytes, 2048.0)
    assert_equal(parse_size(String("1 kib")).bytes, 1024.0)
    assert_equal(parse_size(String("1.5 KB")).bytes, 1500.0)


def test_text_that_is_not_a_size_is_refused() raises:
    assert_true(_refused(String("")))
    assert_true(_refused(String("MiB")))
    assert_true(_refused(String("4 furlongs")))
    assert_true(_refused(String("4 5 GiB")))
    assert_true(_refused(String("lots")))


def test_a_read_back_size_matches_within_the_rounding_of_its_digits() raises:
    assert_true(size_matches(String("953.7 MiB"), 1000000000.0))
    assert_false(size_matches(String("953.7 MiB"), 1010000000.0))
    assert_true(size_matches(String("1.0 GiB"), 1073741824.0))
    assert_true(size_matches(String("1.0 GiB"), 1073741824.0 * 1.03))
    assert_false(size_matches(String("1.0 GiB"), 1073741824.0 * 1.1))
    assert_true(size_matches(String("16384 B"), 16384.0))
    assert_false(size_matches(String("16384 B"), 16385.0 + 1.0))
    var raised = False
    try:
        _ = size_matches(String("lots"), 1.0)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
