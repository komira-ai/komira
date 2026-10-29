# The shape and the content of the query text.
#
# What each case proves:
# - test_suites_have_the_published_queries: tpch has q1..q22,
#   h2o q1..q10 then j1..j5, in that order, with no repeated key (a missing,
#   renamed or duplicated query fails).
# - test_text_is_one_bare_statement: no query is empty, ends in a semicolon or a
#   newline, holds a carriage return, a tab or a comment (the hash is of the
#   text, so stray whitespace would be pinned unnoticed).
# - test_every_identifier_is_known: in every query each word is an SQL word, a
#   column or table of the query's dataset (spelled exactly as the schema spells
#   it), or an alias the query defines. The check is closed-world over the whole
#   dataset: a misspelt column, or a pre-computed column the standard schema
#   lacks, fails; a column that exists in the dataset but in another table of it
#   passes.
# - test_tpch_validation_parameters: the substitution values of the TPC-H
#   validation run are in the text (query 1 interval of 90 days, query 2 size 15
#   and BRASS, query 3 BUILDING and 1995-03-15, ... query 22 country codes), and
#   no query holds a placeholder.
# - test_tpch_uses_the_standard_schema: the columns of the dates are DATE
#   literals (`date '1998-12-01'`), never epoch days, and no query reads a
#   column the standard schema does not have (covered with the identifier case).
# - test_h2o_datasets: the groupby queries read the groupby dataset and the join
#   queries the join dataset.

from std.testing import assert_equal, assert_false, assert_true

from komira_bench_corpus import (
    Dataset,
    Query,
    Suite,
    dataset,
    find_query,
    suite,
    suites,
)


def _contains(text: String, needle: String) -> Bool:
    return text.find(needle) >= 0


def _count(text: String, needle: String) -> Int:
    var n = 0
    var at = text.find(needle)
    while at >= 0:
        n += 1
        at = text.find(needle, at + needle.byte_length())
    return n


def _ids(s: Suite) -> String:
    var out = String("")
    for i in range(len(s.queries)):
        if i > 0:
            out += " "
        out += s.queries[i].id
    return out


def _numbered(prefix: String, first: Int, last: Int) -> String:
    var out = String("")
    for i in range(first, last + 1):
        if i > first:
            out += " "
        out += prefix + String(i)
    return out


def test_suites_have_the_published_queries() raises:
    assert_equal(_ids(suite("tpch")), _numbered("q", 1, 22))
    assert_equal(
        _ids(suite("h2o")),
        _numbered("q", 1, 10) + " " + _numbered("j", 1, 5),
    )
    var seen = List[String]()
    var all_suites = suites()
    for s in all_suites:
        for q in s.queries:
            for k in seen:
                assert_false(k == q.key(), "repeated key " + q.key())
            seen.append(q.key())
    assert_equal(len(seen), 37)


def test_text_is_one_bare_statement() raises:
    var all_suites = suites()
    for s in all_suites:
        for q in s.queries:
            var t = q.text
            var what = q.key()
            assert_true(t.byte_length() > 0, what)
            assert_false(t.endswith(";"), what + " ends in a semicolon")
            assert_false(t.endswith("\n"), what + " ends in a newline")
            assert_false(_contains(t, "\r"), what + " holds a CR")
            assert_false(_contains(t, "\t"), what + " holds a tab")
            assert_false(_contains(t, "--"), what + " holds a comment")
            assert_false(_contains(t, "/*"), what + " holds a comment")
            assert_false(_contains(t, ";"), what + " holds a semicolon")


# ---------------------------------------------------------------- identifiers


def _is_start(c: UInt8) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95


def _is_part(c: UInt8) -> Bool:
    return _is_start(c) or (c >= 48 and c <= 57)


def _words(sql: String) -> List[String]:
    """The words of `sql` outside single-quoted strings; a number is skipped."""
    var out = List[String]()
    var b = sql.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == 39:
            i += 1
            while i < n and b[i] != 39:
                i += 1
            i += 1
        elif _is_part(c):
            var j = i
            var raw = List[UInt8]()
            while j < n and _is_part(b[j]):
                raw.append(b[j])
                j += 1
            if _is_start(c):
                out.append(String(unsafe_from_utf8=Span(raw)))
            i = j
        else:
            i += 1
    return out^


def _has(names: List[String], word: String) -> Bool:
    for i in range(len(names)):
        if names[i] == word:
            return True
    return False


def _split(text: String) -> List[String]:
    var out = List[String]()
    var parts = text.split(String(" "))
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^


def _schema_words(d: Dataset, lower: Bool) -> List[String]:
    var out = List[String]()
    for t in d.tables:
        out.append(t.name.lower() if lower else t.name.copy())
        for c in t.columns:
            out.append(c.name.lower() if lower else c.name.copy())
    return out^


def _aliases(words: List[String]) -> List[String]:
    """The words that follow `as` (case-insensitively), spelled as written."""
    var out = List[String]()
    for i in range(len(words) - 1):
        if words[i].lower() == "as":
            out.append(words[i + 1].copy())
    return out^


comptime _TPCH_WORDS = (
    "select from where group by order having and or not in exists between like"
    " case when then else end as sum avg min max count distinct extract year"
    " month day interval date left outer join on substring for with desc limit"
    " n1 n2 l1 l2 l3 c_count revenue0"
)
comptime _H2O_WORDS = (
    "select from where group by order desc as sum avg min max count median"
    " stddev corr pow row_number over partition is not null inner left join"
    " using"
)


def _check_words(q: Query, d: Dataset) raises:
    var words = _words(q.text)
    var aliases = _aliases(words)
    var keywords: List[String]
    var exact: Bool
    if q.suite == "tpch":
        keywords = _split(String(_TPCH_WORDS))
        exact = False
    else:
        keywords = _split(String(_H2O_WORDS))
        exact = False
    var schema = _schema_words(d, not exact)
    for i in range(len(words)):
        var w = words[i].copy()
        var key = w.lower() if not exact else w.copy()
        var ok = _has(keywords, w.lower()) or _has(schema, key) or _has(aliases, w)
        assert_true(ok, q.key() + " has an unknown word " + w)


def test_every_identifier_is_known() raises:
    var all_suites = suites()
    for s in all_suites:
        for q in s.queries:
            _check_words(q, dataset(q.dataset))


def test_the_identifier_check_refuses_a_misspelt_column() raises:
    var q = find_query("tpch/q6")
    var bad = Query(
        q.suite.copy(),
        q.id.copy(),
        q.dataset.copy(),
        q.text.replace(String("l_discount"), String("l_discont")),
    )
    var refused = False
    try:
        _check_words(bad, dataset(bad.dataset))
    except:
        refused = True
    assert_true(refused)


# ------------------------------------------------------------------- content


def _expect(key: String, needles: List[String]) raises:
    var q = find_query(key)
    for i in range(len(needles)):
        assert_true(
            _contains(q.text, needles[i]),
            key + " lacks " + needles[i],
        )


def _l(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i].copy())
    return out^


def test_tpch_validation_parameters() raises:
    _expect("tpch/q1", _l("date '1998-12-01' - interval '90' day"))
    _expect("tpch/q2", _l("p_size = 15", "'%BRASS'", "r_name = 'EUROPE'", "limit 100"))
    _expect("tpch/q3", _l("'BUILDING'", "date '1995-03-15'", "limit 10"))
    _expect("tpch/q4", _l("date '1993-07-01'", "interval '3' month"))
    _expect("tpch/q5", _l("r_name = 'ASIA'", "date '1994-01-01'", "interval '1' year"))
    _expect("tpch/q6", _l("between 0.06 - 0.01 and 0.06 + 0.01", "l_quantity < 24"))
    _expect("tpch/q7", _l("'FRANCE'", "'GERMANY'", "date '1996-12-31'"))
    _expect("tpch/q8", _l("'BRAZIL'", "'AMERICA'", "'ECONOMY ANODIZED STEEL'"))
    _expect("tpch/q9", _l("'%green%'"))
    _expect("tpch/q10", _l("date '1993-10-01'", "l_returnflag = 'R'", "limit 20"))
    _expect("tpch/q11", _l("n_name = 'GERMANY'", "* 0.0001000000"))
    _expect("tpch/q12", _l("('MAIL', 'SHIP')", "date '1994-01-01'"))
    _expect("tpch/q13", _l("'%special%requests%'", "c_orders (c_custkey, c_count)"))
    _expect("tpch/q14", _l("'PROMO%'", "date '1995-09-01'", "interval '1' month"))
    _expect("tpch/q15", _l("with revenue0 as", "date '1996-01-01'", "max(total_revenue)"))
    _expect("tpch/q16", _l("'Brand#45'", "'MEDIUM POLISHED%'", "(49, 14, 23, 45, 19, 3, 36, 9)"))
    _expect("tpch/q17", _l("'Brand#23'", "'MED BOX'", "0.2 * avg(l_quantity)"))
    _expect("tpch/q18", _l("sum(l_quantity) > 300", "limit 100"))
    _expect("tpch/q19", _l("'Brand#12'", "'Brand#23'", "'Brand#34'", "l_quantity <= 20 + 10"))
    _expect("tpch/q20", _l("'forest%'", "'CANADA'", "date '1994-01-01'"))
    _expect("tpch/q21", _l("'SAUDI ARABIA'", "o_orderstatus = 'F'", "limit 100"))
    _expect("tpch/q22", _l("('13', '31', '23', '29', '30', '18', '17')", "c_acctbal > 0.00"))
    var tpch = suite("tpch")
    for q in tpch.queries:
        assert_false(_contains(q.text, "{"), q.key() + " has a placeholder")
        assert_false(_contains(q.text, ":1"), q.key() + " has a placeholder")
        assert_false(_contains(q.text, "?"), q.key() + " has a placeholder")


def test_tpch_uses_the_standard_schema() raises:
    var d = dataset("tpch")
    assert_equal(len(d.tables), 8)
    var columns = 0
    for t in d.tables:
        columns += len(t.columns)
    assert_equal(columns, 61)
    assert_equal(d.table("lineitem").columns[10].name, "l_shipdate")
    assert_equal(d.table("lineitem").columns[10].sql_type, "DATE")
    assert_equal(d.table("lineitem").columns[5].sql_type, "DECIMAL(15,2)")
    assert_equal(d.table("orders").columns[4].sql_type, "DATE")
    var tpch = suite("tpch")
    for q in tpch.queries:
        assert_false(_contains(q.text, "1970-01-01"), q.key() + " has epoch days")
        assert_false(_contains(q.text, "date_diff"), q.key() + " has epoch days")


def test_h2o_datasets() raises:
    var h = suite("h2o")
    for q in h.queries:
        if q.id.startswith("j"):
            assert_equal(q.dataset, "h2o_join", q.key())
        else:
            assert_equal(q.dataset, "h2o_groupby", q.key())
    assert_equal(len(dataset("h2o_join").tables), 4)
    assert_equal(len(dataset("h2o_groupby").tables), 1)


def main() raises:
    test_suites_have_the_published_queries()
    test_text_is_one_bare_statement()
    test_every_identifier_is_known()
    test_the_identifier_check_refuses_a_misspelt_column()
    test_tpch_validation_parameters()
    test_tpch_uses_the_standard_schema()
    test_h2o_datasets()
    print("all text tests passed")
