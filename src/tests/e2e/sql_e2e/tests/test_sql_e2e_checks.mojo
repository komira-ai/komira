# The runner and the corpus reader fed wrong answers and broken lists: each must be reported,
# named, word for word, and an agreeing case must pass.
#
# Catches: a comparison of text instead of values (`1.50` against `1.5`), one
# that misses a wrong cell, ignores row order or another column name; a
# refusal not listed taken for a pass, a listed refusal komira answers or
# words otherwise taken for a pass; a refusal list that accepts a line with no
# step, an empty reason, a case it names twice or a name with no case; a
# reader that pairs a case with no answer or an answer with no case, or reads
# a file that is not `.sql` as a case; counts that drop a case; a session
# opened on a directory with no table; and a resident twin that is not
# registered from memory or does not hold its file's rows.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from so import Session, sql_result
from sql_e2e import (
    Corpus,
    Refusal,
    SqlCase,
    check_case,
    check_corpus,
    has_resident_twin,
    load_corpus,
    open_session,
    parse_refusals,
    query_text,
    run_sql_steps,
)

comptime _ONE = "-- one row\nSELECT 1 AS n ORDER BY n ASC NULLS LAST\n"
comptime _TWO_IDS = "SELECT id FROM nulls WHERE id < 2 ORDER BY id ASC NULLS LAST"
comptime _NO_TABLE = "SELECT n FROM no_such_table ORDER BY n ASC NULLS LAST"


def _refusal_of(mut session: Session, sql: String) -> String:
    """The text sql_result raises for `sql`, or empty when it answers."""
    try:
        _ = sql_result(session, sql)
    except e:
        return String(e)
    return String()


def test_query_text_drops_comment_and_blank_lines() raises:
    assert_equal(query_text("-- a\n\nSELECT 1\n-- b\nFROM t\n"), "SELECT 1 FROM t")


def test_the_steps_of_run_sql() raises:
    var steps = run_sql_steps()
    assert_equal(len(steps), 5)
    assert_equal(steps[0], "parse")
    assert_equal(steps[4], "execute")


def test_an_answer_equal_by_value_passes() raises:
    var session = open_session(String("tables"))
    assert_false(Bool(check_case(session, SqlCase("x", _ONE, "n\n1\n"), None)))
    # 1.50 and 1.5 are the same DOUBLE.
    var f = SqlCase("x", "SELECT CAST(1.5 AS DOUBLE) AS f ORDER BY f ASC NULLS LAST", "f\n1.50\n")
    assert_false(Bool(check_case(session, f, None)))
    assert_false(Bool(check_case(session, SqlCase("x", _TWO_IDS, "id\n0\n1\n"), None)))


def test_a_wrong_answer_is_reported() raises:
    var session = open_session(String("tables"))
    var prefix = String("x: komira's answer differs from DuckDB's: ")
    # A wrong cell, a missing row, an extra row.
    for answer in [String("n\n2\n"), String("n\n"), String("n\n1\n1\n")]:
        var p = check_case(session, SqlCase("x", _ONE, answer), None)
        assert_true(Bool(p), answer)
        assert_true(p.value().startswith(prefix), p.value())
    # The same rows in another order.
    var swapped = check_case(session, SqlCase("x", _TWO_IDS, "id\n1\n0\n"), None)
    assert_true(Bool(swapped))
    assert_true(swapped.value().startswith(prefix), swapped.value())
    # Another column name: DuckDB's answer does not read under komira's schema.
    var renamed = check_case(session, SqlCase("x", _ONE, "m\n1\n"), None)
    assert_true(Bool(renamed))
    assert_true(renamed.value().startswith(prefix + "duckdb_tsv: column 1 is 'm'"), renamed.value())


def test_refusals_are_held_to_the_list() raises:
    var session = open_session(String("tables"))
    var message = _refusal_of(session, _NO_TABLE)
    assert_true(message.startswith("bind: "), message)
    var refused = SqlCase("x", _NO_TABLE, "n\n")
    # Refused as listed, word for word.
    assert_false(Bool(check_case(session, refused, message)))
    # Refused and not listed.
    var unlisted = check_case(session, refused, None)
    assert_true(Bool(unlisted))
    assert_equal(unlisted.value(), "x: refused, and not listed in refusals.tsv: " + message)
    # Refused with other words than the list's.
    var other = check_case(session, refused, String("bind: another reason"))
    assert_true(Bool(other))
    assert_equal(
        other.value(),
        "x: refused with \"" + message + "\", refusals.tsv lists \"bind: another reason\"",
    )
    # Listed, but answered.
    var answered = check_case(session, SqlCase("x", _ONE, "n\n1\n"), String("bind: a listed reason"))
    assert_true(Bool(answered))
    assert_equal(answered.value(), "x: listed as refused (bind: a listed reason), but komira answered")


def test_the_refusal_list_is_checked() raises:
    var cases: List[String] = ["a", "b"]
    var refusals = List[Refusal]()
    var problems = List[String]()
    parse_refusals(
        "# comment\n\na\tlower: LOWERING_JOIN_UNSERVED: a reason\na\tbind: again\nb\n"
        + "b\tplan: no such step\nb\tbind: \nzz\tparse: a reason\nb\ta\tb\n",
        cases,
        refusals,
        problems,
    )
    assert_equal(len(refusals), 1)
    assert_equal(refusals[0].name, "a")
    assert_equal(refusals[0].message, "lower: LOWERING_JOIN_UNSERVED: a reason")
    assert_equal(len(problems), 6)
    assert_equal(problems[0], "a: listed in refusals.tsv twice")
    assert_equal(problems[1], "refusals.tsv line 5: not <case> TAB <step>: <reason>")
    assert_equal(
        problems[2],
        "refusals.tsv line 6: the refusal does not start with a step of run_sql and its reason: plan: no such step",
    )
    assert_equal(
        problems[3],
        "refusals.tsv line 7: the refusal does not start with a step of run_sql and its reason: bind: ",
    )
    assert_equal(problems[4], "zz: a refusal for no case")
    assert_equal(problems[5], "refusals.tsv line 9: not <case> TAB <step>: <reason>")


def test_the_corpus_pairs_cases_and_answers() raises:
    # BUCK stages tests/data/tree at tree/: case a with its answer and a
    # refusal, case b with no answer, answer c with no case and a refusal for
    # c, and cases/notes.txt, which is no case.
    var corpus = load_corpus(String("tree"))
    assert_equal(len(corpus.cases), 1)
    assert_equal(corpus.cases[0].name, "a")
    assert_equal(corpus.cases[0].answer, "n\n1\n")
    assert_equal(query_text(corpus.cases[0].sql), "SELECT 1 AS n ORDER BY n ASC NULLS LAST")
    assert_equal(corpus.refusal_of("a").value(), "bind: a listed reason")
    assert_false(Bool(corpus.refusal_of("b")))
    assert_equal(len(corpus.problems), 3)
    assert_equal(corpus.problems[0], "b: a case with no DuckDB answer")
    assert_equal(corpus.problems[1], "c: a DuckDB answer with no case")
    assert_equal(corpus.problems[2], "c: a refusal for no case")


def test_a_missing_root_is_an_empty_corpus() raises:
    var corpus = load_corpus(String("tree/absent"))
    assert_equal(len(corpus.cases), 0)
    assert_equal(len(corpus.problems), 0)


def test_the_report_counts_each_case_once() raises:
    var session = open_session(String("tables"))
    var corpus = Corpus()
    corpus.problems.append("corpus: a problem of the corpus")
    corpus.cases.append(SqlCase("good", _ONE, "n\n1\n"))
    corpus.cases.append(SqlCase("refused", _NO_TABLE, "n\n"))
    corpus.cases.append(SqlCase("wrong", _ONE, "n\n2\n"))
    corpus.refusals.append(Refusal("refused", _refusal_of(session, _NO_TABLE)))
    var report = check_corpus(session, corpus)
    assert_equal(report.answered, 1)
    assert_equal(report.refused, 1)
    assert_equal(len(report.problems), 2)
    assert_equal(report.problems[0], "corpus: a problem of the corpus")
    assert_true(report.problems[1].startswith("wrong: komira's answer differs from DuckDB's: "), report.problems[1])


def test_the_resident_twins_are_in_memory_and_hold_their_files_rows() raises:
    var session = open_session(String("tables"))
    for name in [String("lj_customer"), String("lj_orders")]:
        assert_true(has_resident_twin(name))
        var twin = session.engine.catalog.table_of(name + "_mem")
        assert_equal(twin.source.kind_name(), "in_memory")
        assert_equal(session.engine.catalog.table_of(name).source.kind_name(), "parquet")
        var file_rows = sql_result(session, "SELECT count(*) AS n FROM " + name)
        var twin_rows = sql_result(session, "SELECT count(*) AS n FROM " + name + "_mem")
        assert_equal(
            twin_rows.batches[0].column_at(0).as_primitive[DType.int64]().get(0),
            file_rows.batches[0].column_at(0).as_primitive[DType.int64]().get(0),
        )
    assert_false(has_resident_twin(String("nulls")))
    assert_false(session.engine.catalog.has(String("nulls_mem")))


def test_a_session_needs_a_table() raises:
    with assert_raises(contains="sql_e2e: no .parquet table in tree/cases"):
        _ = open_session(String("tree/cases"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
