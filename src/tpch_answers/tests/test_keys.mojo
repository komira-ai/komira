# The ORDER BY key table of the TPC-H corpus.
#
# What each test proves:
# - test_every_corpus_query_has_an_entry: q1 .. q22 each resolve, and exactly the
#   queries whose text has no top-level ORDER BY (q6, q14, q17, q19) have no key.
# - test_a_query_with_an_order_by_has_the_keys_of_its_text: the keys of q2
#   (mixed directions), q10 (third column), q13 (two descending) and q16 (a
#   descending key first) are the positions and directions the corpus text
#   states.
# - test_an_unknown_query_is_refused: an id outside q1 .. q22 raises, so a key
#   table never silently answers "no order" for a query it does not know.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from bench_corpus import suite

from tpch_answers import tpch_order_keys


def test_every_corpus_query_has_an_entry() raises:
    var corpus = suite("tpch")
    assert_equal(len(corpus.queries), 22)
    for i in range(len(corpus.queries)):
        ref q = corpus.queries[i]
        var keys = tpch_order_keys(q.id)
        var has_order = q.text.find(String("\norder by\n")) >= 0
        assert_equal(len(keys) > 0, has_order)


def test_a_query_with_an_order_by_has_the_keys_of_its_text() raises:
    var q2 = tpch_order_keys("q2")
    assert_equal(len(q2), 4)
    assert_equal(q2[0].column, 0)
    assert_true(q2[0].descending)
    assert_equal(q2[1].column, 2)
    assert_equal(q2[2].column, 1)
    assert_equal(q2[3].column, 3)
    var q10 = tpch_order_keys("q10")
    assert_equal(len(q10), 1)
    assert_equal(q10[0].column, 2)
    assert_true(q10[0].descending)
    var q13 = tpch_order_keys("q13")
    assert_equal(q13[0].column, 1)
    assert_equal(q13[1].column, 0)
    assert_true(q13[0].descending and q13[1].descending)
    var q16 = tpch_order_keys("q16")
    assert_equal(len(q16), 4)
    assert_equal(q16[0].column, 3)
    assert_true(q16[0].descending)
    assert_true(not q16[1].descending)


def test_an_unknown_query_is_refused() raises:
    with assert_raises(contains="no TPC-H query is called 'q23'"):
        _ = tpch_order_keys("q23")
    with assert_raises(contains="no TPC-H query is called ''"):
        _ = tpch_order_keys("")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
