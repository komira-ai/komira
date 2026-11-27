# The check of one capability's cases (capability.mojo) fed wrong arguments
# and wrong stagings: each must be reported, named, word for word, and a
# capability whose cases all agree with DuckDB must pass.
#
# Catches: a flag read when it is absent, empty or given twice, or read from
# the program name; a `--cases` value split otherwise than at every comma; a
# case named but not staged, staged but not named, named twice or empty,
# taken for a pass; a staged refusal list accepted; a case komira refuses or
# answers otherwise than DuckDB taken for a pass; and a problem that does not
# name its capability.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from sql_e2e import Corpus, Refusal, SqlCase, check_capability, flag_value, open_session, split_cases

comptime _ONE = "-- one row\nSELECT 1 AS n ORDER BY n ASC NULLS LAST\n"
comptime _NO_TABLE = "SELECT n FROM no_such_table ORDER BY n ASC NULLS LAST"


def _corpus(names: List[String]) -> Corpus:
    """A corpus of `names`, each the one-row case with DuckDB's answer."""
    var corpus = Corpus()
    for n in names:
        corpus.cases.append(SqlCase(n, _ONE, "n\n1\n"))
    return corpus^


def test_a_flag_is_read_once_and_never_from_the_program_name() raises:
    var args: List[String] = ["--capability=prog", "--cases=a,b", "--capability=filter"]
    assert_equal(flag_value(args, "capability"), "filter")
    assert_equal(flag_value(args, "cases"), "a,b")
    with assert_raises(contains="sql_e2e: missing flag --other=<value>"):
        _ = flag_value(args, "other")
    var twice: List[String] = ["prog", "--cases=a", "--cases=b"]
    with assert_raises(contains="sql_e2e: flag --cases= given 2 times"):
        _ = flag_value(twice, "cases")
    var empty: List[String] = ["prog", "--cases="]
    with assert_raises(contains="sql_e2e: flag --cases= is empty"):
        _ = flag_value(empty, "cases")


def test_cases_split_at_every_comma() raises:
    var one = split_cases("a")
    assert_equal(len(one), 1)
    assert_equal(one[0], "a")
    var three = split_cases("a,,b")
    assert_equal(len(three), 3)
    assert_equal(three[0], "a")
    assert_equal(three[1], "")
    assert_equal(three[2], "b")


def test_cases_that_agree_with_duckdb_pass() raises:
    var session = open_session(String("tables"))
    var want: List[String] = ["a", "b"]
    var problems = check_capability(session, _corpus(want), "filter", want)
    assert_equal(len(problems), 0)


def test_the_named_and_the_staged_cases_must_be_the_same() raises:
    var session = open_session(String("tables"))
    var staged: List[String] = ["a", "c"]
    var want: List[String] = ["a", "b", "", "a", "a"]
    var problems = check_capability(session, _corpus(staged), "filter", want)
    assert_equal(len(problems), 4)
    assert_equal(problems[0], "filter: case b is named but not staged")
    assert_equal(problems[1], "filter: an empty case name in --cases")
    assert_equal(problems[2], "filter: case a is named twice")
    assert_equal(problems[3], "filter: case c is staged but not named")


def test_a_refusal_list_is_refused() raises:
    var session = open_session(String("tables"))
    var want: List[String] = ["a"]
    var corpus = _corpus(want)
    corpus.refusals.append(Refusal("a", "bind: a listed reason"))
    var problems = check_capability(session, corpus, "filter", want)
    assert_equal(len(problems), 2)
    assert_equal(problems[0], "filter: a refusal list is staged; every case of a capability must be answered")
    assert_equal(problems[1], "filter: a: listed as refused (bind: a listed reason), but komira answered")


def test_a_refused_or_wrong_case_fails_its_capability() raises:
    var session = open_session(String("tables"))
    var corpus = Corpus()
    corpus.problems.append("corpus: a problem of the corpus")
    corpus.cases.append(SqlCase("good", _ONE, "n\n1\n"))
    corpus.cases.append(SqlCase("refused", _NO_TABLE, "n\n"))
    corpus.cases.append(SqlCase("wrong", _ONE, "n\n2\n"))
    var want: List[String] = ["good", "refused", "wrong"]
    var problems = check_capability(session, corpus, "join_left", want)
    assert_equal(len(problems), 3)
    assert_equal(problems[0], "join_left: corpus: a problem of the corpus")
    assert_true(problems[1].startswith("join_left: refused: refused, and not listed in refusals.tsv: bind: "), problems[1])
    assert_true(problems[2].startswith("join_left: wrong: komira's answer differs from DuckDB's: "), problems[2])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
