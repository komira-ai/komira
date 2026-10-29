# The lookups, the hashes as functions, and the scale-factor form of query 11.
#
# What each case proves:
# - test_lookups: `find_query` names a query by `suite/id` and returns its
#   dataset; an unknown suite, an unknown query, a key without a slash and an
#   unknown dataset are each refused with the name in the message.
# - test_query_hash_is_the_digest_of_the_text: `Query.sha256` is the SHA-256 of
#   exactly the text bytes, and two queries with different text differ.
# - test_suite_hash_follows_text_order_and_membership: the same queries give the
#   same suite digest; changing one character of one text, swapping two queries,
#   dropping one and adding one each change it.
# - test_suite_hash_names_the_query_and_not_only_its_text: two queries with the
#   same text under different ids hash differently from one another's suite.
# - test_notice: the TPC-H suite carries the "not a TPC result" sentence, the
#   other suites carry none.
# - test_q11_at_scale: scale factor 1 is the text of the suite; 10, 100 and 3
#   change only the fraction literal (0.0000100000, 0.0000010000,
#   0.0000333333); a scale factor below 1 is refused.
# - test_dataset_ddl: the DDL of the h2o groupby table is exactly the pinned
#   text, a table is found by name, a missing table is refused.

from std.testing import assert_equal, assert_false, assert_true

from komira_bench_corpus import (
    Query,
    Suite,
    dataset,
    dataset_names,
    find_query,
    sha256_hex,
    suite,
    suite_ids,
    tpch_q11_at_scale,
)


def _refused(key: String, what: String) raises:
    var message = String("")
    try:
        _ = find_query(key)
    except e:
        message = String(e)
    assert_true(message.find(what) >= 0, "message for " + key + ": " + message)


def test_lookups() raises:
    var q = find_query("tpch/q1")
    assert_equal(q.key(), "tpch/q1")
    assert_equal(q.dataset, "tpch")
    assert_equal(find_query("h2o/q3").dataset, "h2o_groupby")
    assert_equal(find_query("h2o/j3").dataset, "h2o_join")
    assert_equal(suite("h2o").query("j5").id, "j5")
    _refused("nosuch/q1", "no suite nosuch")
    _refused("clickbench/q0", "no suite clickbench")
    _refused("tpch/q23", "no query q23")
    _refused("tpch/q0", "no query q0")
    _refused("tpch", "is not suite/id")
    var message = String("")
    try:
        _ = dataset("hits")
    except e:
        message = String(e)
    assert_true(message.find("no dataset hits") >= 0, message)
    var ids = suite_ids()
    assert_equal(len(ids), 2)
    assert_equal(len(dataset_names()), 3)
    for i in range(len(ids)):
        assert_equal(suite(ids[i]).id, ids[i])


def test_query_hash_is_the_digest_of_the_text() raises:
    var a = Query("s", "a", "d", "select 1")
    var b = Query("s", "b", "d", "select 2")
    assert_equal(a.sha256(), sha256_hex("select 1"))
    assert_true(a.sha256() != b.sha256())
    assert_equal(a.sha256().byte_length(), 64)


def _suite(first: String, second: String) -> Suite:
    var qs = List[Query]()
    qs.append(Query("s", "a", "d", first.copy()))
    qs.append(Query("s", "b", "d", second.copy()))
    return Suite("s", "t", "", qs^)


def test_suite_hash_follows_text_order_and_membership() raises:
    var base = _suite("select 1", "select 2")
    assert_equal(base.sha256(), _suite("select 1", "select 2").sha256())
    assert_true(base.sha256() != _suite("select 1", "select 3").sha256())
    var swapped = List[Query]()
    swapped.append(Query("s", "b", "d", "select 2"))
    swapped.append(Query("s", "a", "d", "select 1"))
    assert_true(base.sha256() != Suite("s", "t", "", swapped^).sha256())
    var fewer = List[Query]()
    fewer.append(Query("s", "a", "d", "select 1"))
    assert_true(base.sha256() != Suite("s", "t", "", fewer^).sha256())
    var more = List[Query]()
    more.append(Query("s", "a", "d", "select 1"))
    more.append(Query("s", "b", "d", "select 2"))
    more.append(Query("s", "c", "d", "select 3"))
    assert_true(base.sha256() != Suite("s", "t", "", more^).sha256())


def test_suite_hash_names_the_query_and_not_only_its_text() raises:
    var one = List[Query]()
    one.append(Query("s", "a", "d", "select 1"))
    var other = List[Query]()
    other.append(Query("s", "z", "d", "select 1"))
    assert_true(Suite("s", "t", "", one^).sha256() != Suite("s", "t", "", other^).sha256())


def test_notice() raises:
    var tpch = suite("tpch")
    assert_true(tpch.notice.find("Derived from TPC-H; not a TPC result") == 0)
    assert_equal(suite("h2o").notice, "")


def test_q11_at_scale() raises:
    var base = suite("tpch").query("q11").text
    assert_equal(tpch_q11_at_scale(1), base)
    assert_equal(
        tpch_q11_at_scale(10),
        base.replace(String("0.0001000000"), String("0.0000100000")),
    )
    assert_equal(
        tpch_q11_at_scale(100),
        base.replace(String("0.0001000000"), String("0.0000010000")),
    )
    assert_equal(
        tpch_q11_at_scale(3),
        base.replace(String("0.0001000000"), String("0.0000333333")),
    )
    for bad in range(-1, 1):
        var refused = False
        try:
            _ = tpch_q11_at_scale(bad)
        except:
            refused = True
        assert_true(refused, "scale factor " + String(bad))


def test_dataset_ddl() raises:
    var d = dataset("h2o_groupby")
    assert_equal(
        d.ddl(),
        "CREATE TABLE x (\n  id1 VARCHAR,\n  id2 VARCHAR,\n  id3 VARCHAR,\n"
        "  id4 INTEGER,\n  id5 INTEGER,\n  id6 INTEGER,\n  v1 INTEGER,\n"
        "  v2 INTEGER,\n  v3 DOUBLE\n);\n",
    )
    assert_equal(d.table("x").columns[8].name, "v3")
    var refused = False
    try:
        _ = d.table("y")
    except:
        refused = True
    assert_true(refused)
    assert_false(dataset("tpch").ddl() == dataset("h2o_groupby").ddl())


def main() raises:
    test_lookups()
    test_query_hash_is_the_digest_of_the_text()
    test_suite_hash_follows_text_order_and_membership()
    test_suite_hash_names_the_query_and_not_only_its_text()
    test_notice()
    test_q11_at_scale()
    test_dataset_ddl()
    print("all api tests passed")
