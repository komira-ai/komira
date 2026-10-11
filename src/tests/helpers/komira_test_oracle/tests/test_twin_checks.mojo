# The twin check fed planted defects: each must be reported.
#
# Defects these catch: a twin check that compares text instead of values
# (`1.50` against `1.5` would be a false difference), that misses a wrong
# cell, a missing row or a NULL where the twin has a value, that ignores the
# twin's row-order policy, or that does not report an answer with no twin
# and a twin with no answer.

from std.testing import TestSuite, assert_equal, assert_true

from komira_test_oracle import check_twin, pair_names


def _hand(order: String, rows: String) -> String:
    return (
        String("#! komira-plan-conformance v1\n#  order: ") + order
        + "\n#  float: ulps=0\n# derivation: planted\nk:int64?\tf:float64?\n" + rows
    )


def test_equal_by_value() raises:
    assert_equal(len(check_twin("c", "k\tf\n1\t1.50\n\t-0.0\n", _hand("total", "1\t1.5\n\\N\t-0.0\n"))), 0)


def test_differences_are_reported() raises:
    # A wrong cell.
    var p = check_twin("c", "k\tf\n1\t2.5\n", _hand("total", "1\t1.5\n"))
    assert_equal(len(p), 1)
    assert_true(p[0].startswith("c: the DuckDB answer and its HAND twin differ: 1 mismatch"))
    # A missing row, and a NULL for a value.
    assert_equal(len(check_twin("c", "k\tf\n1\t1.5\n", _hand("total", "1\t1.5\n2\t0.5\n"))), 1)
    assert_equal(len(check_twin("c", "k\tf\n\t1.5\n", _hand("total", "1\t1.5\n"))), 1)
    # -0.0 is not 0.0.
    assert_equal(len(check_twin("c", "k\tf\n1\t0.0\n", _hand("total", "1\t-0.0\n"))), 1)


def test_the_twins_order_policy() raises:
    var swapped = String("k\tf\n2\t0.5\n1\t1.5\n")
    assert_equal(len(check_twin("c", swapped, _hand("none", "1\t1.5\n2\t0.5\n"))), 0)
    assert_equal(len(check_twin("c", swapped, _hand("total", "1\t1.5\n2\t0.5\n"))), 1)


def test_unreadable_answer_is_reported() raises:
    var p = check_twin("c", "k\tg\n1\t1.5\n", _hand("total", "1\t1.5\n"))
    assert_equal(len(p), 1)
    assert_true(p[0].startswith("c: duckdb_tsv: column 2 is 'g'"))


def test_unpaired_names() raises:
    var answers: List[String] = ["a/x", "a/y"]
    var hands: List[String] = ["a/y", "a/z"]
    var p = pair_names(answers, hands)
    assert_equal(len(p), 2)
    assert_equal(p[0], "a/x: a DuckDB answer with no HAND twin")
    assert_equal(p[1], "a/z: a HAND twin with no DuckDB answer")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
