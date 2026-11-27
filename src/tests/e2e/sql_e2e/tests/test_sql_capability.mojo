# One capability of the SQL surface end to end: the cases BUCK names for it
# (`--cases`), each through komira's SQL surface (so.sql_result) over
# komira_test_oracle's datasets and the regression tables, held to the pinned
# DuckDB's answer by value and in row order. The test of one cell of the
# surface capability matrix: BUCK declares it once per capability, as
# test_sql_<capability>, with only that capability's cases staged.
#
# Catches: komira answering one of the capability's cases otherwise than
# DuckDB, or refusing it; a case named for the capability but not staged, or
# staged but not named.

from std.sys import argv
from std.testing import assert_equal, assert_true

from sql_e2e import check_capability, flag_value, load_corpus, open_session, split_cases


def _args() -> List[String]:
    var args = argv()
    var out = List[String]()
    for i in range(len(args)):
        out.append(String(args[i]))
    return out^


def _lines(problems: List[String]) -> String:
    var out = String()
    for p in problems:
        out += "\n  " + p
    return out^


def test_the_capability_cases_equal_duckdb() raises:
    var args = _args()
    var capability = flag_value(args, "capability")
    var want = split_cases(flag_value(args, "cases"))
    var corpus = load_corpus(String("."))
    var session = open_session(String("tables"))
    var problems = check_capability(session, corpus, capability, want)
    assert_equal(len(problems), 0, String("sql_e2e ") + capability + " problems:" + _lines(problems))
    assert_equal(len(corpus.cases), len(want))
    assert_true(len(want) > 0)


def main() raises:
    # Called directly, not through TestSuite, which reads the arguments as
    # its own options.
    test_the_capability_cases_equal_duckdb()
    print("test_sql_capability PASS")
