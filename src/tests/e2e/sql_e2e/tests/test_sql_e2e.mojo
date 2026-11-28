# The corpus run end to end: every case of cases/ through komira's SQL
# surface (so.sql_result, what komira_sql_stream runs) over
# komira_test_oracle's datasets and the regression tables, held to the
# pinned DuckDB's answer by value and in row order, or refused with exactly
# the text refusals.tsv lists.
#
# Catches: komira answering a case otherwise than DuckDB (a wrong value, a
# missing or extra row, rows in another order, another column name); a
# refusal that is not listed, or a listed one komira now answers or words
# otherwise; a case staged without its answer or an answer without its case;
# a corpus staged short (the count of cases is pinned); and a runner that
# reports nothing when one answer is wrong.

from std.testing import TestSuite, assert_equal, assert_true

from sql_e2e import check_corpus, load_corpus, open_session

# `ls src/tests/e2e/sql_e2e/cases/*.sql | wc -l`; BUCK stages each with its
# answer, so a case lost on the way fails here.
comptime _CASES = 144

# A case whose answer is one row starting with count(*) of `nulls`, 5000.
comptime _COUNTS_CASE = "aggregate_counts"


def _lines(problems: List[String]) -> String:
    var out = String()
    for p in problems:
        out += "\n  " + p
    return out^


def test_every_case_equals_duckdb_or_is_refused_by_name() raises:
    var corpus = load_corpus(String("."))
    assert_equal(len(corpus.cases), _CASES)
    var session = open_session(String("tables"))
    var report = check_corpus(session, corpus)
    assert_equal(len(report.problems), 0, String("sql_e2e problems:") + _lines(report.problems))
    assert_equal(report.answered + report.refused, _CASES)
    assert_true(report.answered > 0)


def test_one_wrong_answer_is_one_failing_case() raises:
    # The whole corpus with one DuckDB answer changed in one cell (count(*)
    # 5000 read as 4999): that case alone fails, named, and every other
    # case still passes or is refused as listed.
    var corpus = load_corpus(String("."))
    var changed = False
    for i in range(len(corpus.cases)):
        if corpus.cases[i].name == _COUNTS_CASE:
            var wrong = corpus.cases[i].answer.replace("\n5000\t", "\n4999\t")
            changed = wrong != corpus.cases[i].answer
            corpus.cases[i].answer = wrong
    assert_true(changed)
    var session = open_session(String("tables"))
    var report = check_corpus(session, corpus)
    assert_equal(len(report.problems), 1, _lines(report.problems))
    assert_true(
        report.problems[0].startswith(String(_COUNTS_CASE) + ": komira's answer differs from DuckDB's: "),
        report.problems[0],
    )
    assert_equal(report.answered + report.refused, _CASES - 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
