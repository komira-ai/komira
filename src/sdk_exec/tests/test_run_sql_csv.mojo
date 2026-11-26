# =============================================================================
# test_run_sql_csv: read_csv through run_sql answers what DuckDB answers
# =============================================================================
#
# Covers: read_csv through run_sql answers what the pinned DuckDB answers (the
# :csv_oracle action in BUCK) for every case of tests/csv/cases.sql: the
# inferred types and the rows of typed, quoted, NULL-bearing and |-delimited
# files and of a header with no row, filters, grouped and ungrouped aggregates
# and all_varchar, each over the committed file and over a gzip copy; every
# case is run; a missing file is refused at bind and header=false at lowering.
#
# The cases are the lines of tests/csv/cases.sql: the pinned DuckDB runs each
# query over the committed CSV files as a build action (`sql_oracle`) and
# writes its answer as a TSV; this test reads the same file for the query
# text, runs that text through `run_sql` (parse, bind, optimize, lower to a
# SOURCE_CSV segment, run on the pipeline) and compares the answer with
# DuckDB's by value, rows as a multiset (komira_plan_harness). A
# `DESCRIBE` case compares the type of each column under DuckDB's type names.
#
# Every case runs twice: over the files as committed, and over gzip copies of
# them (`<name>.csv.gz` under the scratch directory) against the same DuckDB
# answer, so a compressed file is read by its extension to the same rows.
#
#   test_typed_csv_equals_duckdb        BIGINT, DOUBLE, DATE and VARCHAR
#                                       columns: the inferred types, the rows,
#                                       a filter on a date and a double, a
#                                       grouped and an ungrouped aggregate,
#                                       all_varchar keeping each cell's text.
#   test_quoted_csv_equals_duckdb       a quoted comma, doubled quotes, a line
#                                       break, padding and a multi-byte
#                                       character, unquoted as DuckDB does.
#   test_null_bearing_csv_equals_duckdb an empty cell is NULL in every column
#                                       type: rows, counts, IS NULL, a NULL
#                                       group key.
#   test_dialect_and_header_only_csv_equal_duckdb
#                                       a `|` delimiter with a comma inside a
#                                       cell; a header with no row is no row
#                                       of VARCHAR columns.
#   test_gzip_csv_equals_duckdb         every case above over gzip copies.
#   test_every_case_is_run              each case of cases.sql belongs to one
#                                       of the tests above, so none is skipped.
#   test_a_missing_csv_is_refused_at_bind
#                                       a path with no file is refused before
#                                       anything runs.
#   test_a_csv_with_no_header_row_is_refused_at_lower
#                                       header=false is refused by name, not
#                                       answered with column names DuckDB
#                                       does not give.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from compression.compression_codecs import Gzip
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data, test_tmpdir
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_LOWER, run_sql


def _files() -> List[String]:
    var out = List[String]()
    out.append("typed.csv")
    out.append("quoted.csv")
    out.append("nulls.csv")
    out.append("pipe.csv")
    out.append("header_only.csv")
    return out^


def _prefixes() -> List[String]:
    var out = List[String]()
    out.append("typed_")
    out.append("quoted_")
    out.append("nulls_")
    out.append("pipe_")
    out.append("header_only_")
    return out^

comptime _DESCRIBE = "SELECT column_name, column_type FROM (DESCRIBE "


struct _Case(Copyable, Movable):
    var name: String
    var query: String

    def __init__(out self, var name: String, var query: String):
        self.name = name^
        self.query = query^


def _cases() raises -> List[_Case]:
    """Every `COPY (<query>) TO '<name>.tsv' ...;` line of cases.sql."""
    var out = List[_Case]()
    var text = read_data("cases.sql")
    for line in text.split("\n"):
        var l = String(line)
        if not l.startswith("COPY ("):
            continue
        var to = l.rfind(") TO '")
        var tsv = l.rfind(".tsv'")
        assert_true(to > 0 and tsv > to, "a COPY line of cases.sql: " + l)
        out.append(
            _Case(
                String(l[byte = to + 6 : tsv]),
                String(l[byte=6:to]),
            )
        )
    return out^


def _with_paths(query: String, gz: Bool) raises -> String:
    """`query` with each quoted fixture name replaced by its path: the staged
    file, or the gzip copy of it under the scratch directory."""
    var q = query
    var files = _files()
    for i in range(len(files)):
        ref f = files[i]
        var path = data_path(f)
        if gz:
            path = test_tmpdir() + "/" + f + ".gz"
        q = q.replace("'" + f + "'", "'" + path + "'")
    return q^


def _write_gzip_copies() raises:
    var files = _files()
    for i in range(len(files)):
        ref f = files[i]
        var text = read_data(f)
        var gz = Gzip.compress_gzip_file(text.as_bytes())
        var fh = open(test_tmpdir() + "/" + f + ".gz", "w")
        fh.write_bytes(Span(gz))
        fh.close()


def _duckdb_type(t: ArrowType) -> String:
    if t == ArrowType.INT64:
        return "BIGINT"
    if t == ArrowType.INT32:
        return "INTEGER"
    if t == ArrowType.FLOAT64:
        return "DOUBLE"
    if t == ArrowType.DATE32:
        return "DATE"
    if t == ArrowType.STRING:
        return "VARCHAR"
    if t == ArrowType.BOOL:
        return "BOOLEAN"
    return "arrow " + String(t)


def _run(text: String, mut problems: List[String], label: String) raises -> Optional[RecordBatch]:
    var ctx = EngineContext(EngineOptions(worker_count=3))
    var out = run_sql(ctx, text)
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return None
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return None
    return Optional(out.batches.pop(0))


def _check_types(c: _Case, gz: Bool, mut problems: List[String]) raises:
    var label = c.name + (String(" (gzip)") if gz else String(""))
    var head = String(_DESCRIBE)
    var inner = String(
        c.query[byte = head.byte_length() : c.query.byte_length() - 1]
    )
    var got = _run(_with_paths(inner, gz), problems, label)
    if not got:
        return
    ref batch = got.value()
    var want = parse_duckdb_tsv(read_data(c.name + ".tsv"))
    var n = batch.schema.num_columns()
    if n != len(want.rows):
        problems.append(
            label + ": " + String(n) + " columns, DuckDB "
            + String(len(want.rows))
        )
        return
    for i in range(n):
        var name = batch.schema.field_name(i)
        var type_name = _duckdb_type(batch.schema.field_arrow_type(i))
        var want_name = want.rows[i][0].value()
        var want_type = want.rows[i][1].value()
        if name != want_name or type_name != want_type:
            problems.append(
                label + ": column " + String(i + 1) + " is " + name + " "
                + type_name + ", DuckDB " + want_name + " " + want_type
            )


def _check_rows(c: _Case, gz: Bool, mut problems: List[String]) raises:
    var label = c.name + (String(" (gzip)") if gz else String(""))
    var got = _run(_with_paths(c.query, gz), problems, label)
    if not got:
        return
    var actual = render_batch(got.value(), CanonPolicy.unordered())
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(c.name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(label + ": " + String(report))
    except e:
        problems.append(label + ": " + String(e))


def _check_prefix(prefix: String, gz: Bool) raises:
    if gz:
        _write_gzip_copies()
    var problems = List[String]()
    var ran = 0
    var cases = _cases()
    for i in range(len(cases)):
        ref c = cases[i]
        if not c.name.startswith(prefix):
            continue
        ran += 1
        if c.query.startswith(_DESCRIBE):
            _check_types(c, gz, problems)
        else:
            _check_rows(c, gz, problems)
    assert_true(ran >= 1, "cases.sql holds no case named " + prefix + "*")
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def test_typed_csv_equals_duckdb() raises:
    _check_prefix("typed_", False)


def test_quoted_csv_equals_duckdb() raises:
    _check_prefix("quoted_", False)


def test_null_bearing_csv_equals_duckdb() raises:
    _check_prefix("nulls_", False)


def test_dialect_and_header_only_csv_equal_duckdb() raises:
    _check_prefix("pipe_", False)
    _check_prefix("header_only_", False)


def test_gzip_csv_equals_duckdb() raises:
    var prefixes = _prefixes()
    for i in range(len(prefixes)):
        _check_prefix(prefixes[i], True)


def test_every_case_is_run() raises:
    var cases = _cases()
    assert_true(len(cases) >= 17, "cases.sql holds " + String(len(cases)) + " cases")
    for i in range(len(cases)):
        var known = False
        var prefixes = _prefixes()
        for p in range(len(prefixes)):
            if cases[i].name.startswith(prefixes[p]):
                known = True
        assert_true(known, cases[i].name + " belongs to no test")


def test_a_missing_csv_is_refused_at_bind() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(
        ctx, "SELECT * FROM read_csv('" + test_tmpdir() + "/absent.csv')"
    )
    assert_true(Bool(out.refusal))
    assert_equal(out.refusal.value().step, String(STEP_BIND))
    assert_equal(len(out.batches), 0)


def test_a_csv_with_no_header_row_is_refused_at_lower() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(
        ctx,
        "SELECT * FROM read_csv('" + data_path("pipe.csv")
        + "', delim = '|', header = false)",
    )
    assert_true(Bool(out.refusal))
    assert_equal(out.refusal.value().step, String(STEP_LOWER))
    assert_true(
        "LOWERING_UNCUTTABLE_NODE" in out.refusal.value().reason,
        out.refusal.value().reason,
    )
    assert_true(
        "header=false" in out.refusal.value().reason,
        out.refusal.value().reason,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
