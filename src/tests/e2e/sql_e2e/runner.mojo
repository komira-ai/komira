# =============================================================================
# sql_e2e/runner.mojo -- each case run through komira, held to DuckDB.
# =============================================================================
#
# A case's SELECT runs through `so.sql_result`, the call on values that
# libkomira's komira_sql_stream wraps: run_sql (parse, bind, optimize, lower,
# execute) over the tables registered on a session, then the check that every
# batch crosses the Arrow C stream. Its answer is held to DuckDB's BY VALUE
# and IN ROW ORDER: rendered with komira_plan_harness's render_table, DuckDB's
# TSV read under that schema with duckdb_tsv_canon, the two compared with
# compare_canon under CanonPolicy.total(). Every case's outermost ORDER BY is
# total (it orders by a unique key, or by every column), so row order is part
# of the claim. A refusal is held to refusals.tsv word for word.
#
# Every problem names its case and is reported, not only the first; one wrong
# answer is one problem.
# =============================================================================

from std.os import listdir

from arrow.table import Table
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_table,
)
from so import Session, register_arrow, register_parquet, sql_result

from .corpus import Corpus, SqlCase, query_text


struct E2eReport(Movable):
    """What a run did: cases answered and equal to DuckDB, cases refused as
    listed, and every problem, one line each, naming its case."""

    var answered: Int
    var refused: Int
    var problems: List[String]

    def __init__(out self):
        self.answered = 0
        self.refused = 0
        self.problems = List[String]()


def has_resident_twin(name: String) -> Bool:
    """Whether the table `name` is also registered from memory, as
    `<name>_mem`: lj_customer and lj_orders, the LEFT JOIN pair of
    sql/regression_tables.sql. sql/tables.sql names the same twins for
    DuckDB, as views of the same files."""
    return name == "lj_customer" or name == "lj_orders"


def open_session(tables_dir: String) raises -> Session:
    """A session with every `<table>.parquet` of `tables_dir` registered as
    `<table>`, and each table with a resident twin (`has_resident_twin`)
    registered a second time as `<table>_mem`: its rows read from the file
    through the session and registered with `register_arrow`, the table a
    host's Arrow stream becomes. Raises when the directory holds no Parquet
    file."""
    var session = Session()
    var registered = 0
    for entry in listdir(tables_dir):
        var f = String(entry)
        if f.endswith(".parquet") and f.byte_length() > 8:
            var name = String(f[byte = 0 : f.byte_length() - 8])
            register_parquet(session, name, tables_dir + "/" + f)
            registered += 1
            if has_resident_twin(name):
                var rows = sql_result(session, "SELECT * FROM " + name)
                register_arrow(
                    session,
                    name + "_mem",
                    Table.from_chunks(rows.take_batches(), rows.take_schema()),
                )
    if registered == 0:
        raise Error("sql_e2e: no .parquet table in " + tables_dir)
    return session^


def compare_answer(var result: Table, answer_tsv: String) -> String:
    """"" when `result` equals DuckDB's answer by value and in row order,
    else what differs (or why DuckDB's answer does not read under the
    result's schema)."""
    try:
        var actual = render_table(result, CanonPolicy.total())
        var expected = duckdb_tsv_canon(parse_duckdb_tsv(answer_tsv), actual)
        var report = compare_canon(expected, actual)
        if not report.ok():
            return String(report)
        return String()
    except e:
        return String(e)


def check_case(mut session: Session, sql_case: SqlCase, listed: Optional[String]) -> Optional[String]:
    """The problem of one case, or None when komira answers it as DuckDB
    does (`listed` None) or refuses it with exactly `listed`."""
    var refusal = String()
    var table = Table()
    var answered = False
    try:
        var answer = sql_result(session, query_text(sql_case.sql))
        table = Table.from_chunks(answer.take_batches(), answer.take_schema())
        answered = True
    except e:
        refusal = String(e)
    if answered:
        if listed:
            return sql_case.name + ": listed as refused (" + listed.value() + "), but komira answered"
        var diff = compare_answer(table^, sql_case.answer)
        if diff.byte_length() > 0:
            return sql_case.name + ": komira's answer differs from DuckDB's: " + diff
        return None
    if not listed:
        return sql_case.name + ": refused, and not listed in refusals.tsv: " + refusal
    if refusal != listed.value():
        return sql_case.name + ": refused with \"" + refusal + "\", refusals.tsv lists \"" + listed.value() + "\""
    return None


def check_corpus(mut session: Session, corpus: Corpus) -> E2eReport:
    """Every case of `corpus` run on `session`, after the corpus's own
    problems."""
    var report = E2eReport()
    for p in corpus.problems:
        report.problems.append(p)
    for c in corpus.cases:
        var listed = corpus.refusal_of(c.name)
        var problem = check_case(session, c, listed)
        if problem:
            report.problems.append(problem.value())
        elif listed:
            report.refused += 1
        else:
            report.answered += 1
    return report^
