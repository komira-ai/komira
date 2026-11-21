"""The checks of the multi-file scan tests: each reads DuckDB's answers from
answers.tsv, which its test declares, runs the same SQL through `run_sql` over
tables registered from the staged files, and compares the rows. A row is its
cells joined by '|' (a DATE as its days since 1970-01-01, a DECIMAL with its
scale, a NULL as NULL), the form answers.sql writes. A query with ORDER BY is
compared in order; any other query as the sorted list of its rows."""

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from runtime_paths import data_path
from scalar_arithmetic.decimal_cast import decimal_to_string
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


struct _Answers(Movable):
    """The rows of answers.tsv: (block, query, position, row), in file order
    (by block, then position)."""

    var block: List[String]
    var query: List[String]
    var line: List[String]

    def __init__(out self):
        self.block = List[String]()
        self.query = List[String]()
        self.line = List[String]()

    def names(self) -> List[String]:
        """Each block name once, in file order."""
        var out = List[String]()
        for i in range(len(self.block)):
            if len(out) == 0 or out[len(out) - 1] != self.block[i]:
                out.append(self.block[i])
        return out^

    def lines_of(self, name: String) -> List[String]:
        var out = List[String]()
        for i in range(len(self.block)):
            if self.block[i] == name:
                out.append(self.line[i])
        return out^

    def query_of(self, name: String) -> String:
        for i in range(len(self.block)):
            if self.block[i] == name:
                return self.query[i]
        return String("")


def _answers() raises -> _Answers:
    """The data rows of answers.tsv (the header dropped)."""
    var text = Path(data_path("answers.tsv")).read_text()
    var out = _Answers()
    var lines = text.split("\n")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var parts = line.split("\t")
        assert_equal(len(parts), 4, "answers.tsv row: " + line)
        out.block.append(String(parts[0]))
        out.query.append(String(parts[1]))
        out.line.append(String(parts[3]))
    assert_true(len(out.block) > 0, "answers.tsv holds no row")
    return out^


def _type_name(ref batch: RecordBatch, col: Int) raises -> String:
    """The name DuckDB gives the type of column `col`."""
    var t = batch.schema.field_arrow_type(col)
    if t == ArrowType.INT64:
        return "BIGINT"
    if t == ArrowType.INT32:
        return "INTEGER"
    if t == ArrowType.STRING:
        return "VARCHAR"
    if t == ArrowType.DATE32:
        return "DATE"
    if t == ArrowType.DECIMAL128:
        return (
            "DECIMAL("
            + String(batch.schema.field_decimal_precision(col))
            + ","
            + String(batch.schema.field_decimal_scale(col))
            + ")"
        )
    return String(t)


def _cell(ref batch: RecordBatch, col: Int, row: Int) raises -> String:
    ref c = batch.column_at(col)
    if c.is_null_at(row):
        return "NULL"
    var t = batch.schema.field_arrow_type(col)
    if t == ArrowType.INT64:
        return String(c.as_primitive[DType.int64]().get(row))
    if t == ArrowType.INT32 or t == ArrowType.DATE32:
        return String(c.as_primitive[DType.int32]().get(row))
    if t == ArrowType.STRING:
        return c.as_string().get(row)
    if t == ArrowType.DECIMAL128:
        return decimal_to_string(
            c.as_decimal128().get_i128(row), c.decimal_scale()
        )
    raise Error("column " + String(col) + " is " + String(t) + ", not a type the checks print")


def _join(cells: List[String]) -> String:
    var out = String("")
    for i in range(len(cells)):
        if i > 0:
            out += "|"
        out += cells[i]
    return out^


def _sorted(var lines: List[String]) -> List[String]:
    for i in range(1, len(lines)):
        var j = i
        while j > 0 and lines[j - 1] > lines[j]:
            var t = String(lines[j - 1])
            lines[j - 1] = String(lines[j])
            lines[j] = t^
            j -= 1
    return lines^


def _is_ordered(text: String) -> Bool:
    return text.lower().find(" order by ") >= 0


struct _Result(Movable):
    """What run_sql answered: the rows as text, the first batch's schema as
    text, or the refusal."""

    var lines: List[String]
    var schema: List[String]
    var refusal: String

    def __init__(out self):
        self.lines = List[String]()
        self.schema = List[String]()
        self.refusal = String("")


def _ask(mut ctx: EngineContext, text: String) -> _Result:
    var r = _Result()
    var outcome = run_sql(ctx, text)
    if outcome.refusal:
        r.refusal = (
            "refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason
        )
        return r^
    try:
        for b in range(len(outcome.batches)):
            ref batch = outcome.batches[b]
            if b == 0:
                for c in range(batch.num_columns()):
                    r.schema.append(batch.schema.field_name(c) + "|" + _type_name(batch, c))
            for row in range(batch.num_rows()):
                var cells = List[String]()
                for c in range(batch.num_columns()):
                    cells.append(_cell(batch, c, row))
                r.lines.append(_join(cells))
    except e:
        r.refusal = "unreadable answer: " + String(e)
    return r^


def _compare(
    name: String,
    text: String,
    var got: List[String],
    var want: List[String],
    ordered: Bool,
    mut problems: List[String],
):
    if not ordered:
        got = _sorted(got^)
        want = _sorted(want^)
    var same = len(got) == len(want)
    if same:
        for i in range(len(got)):
            if got[i] != want[i]:
                same = False
                break
    if same:
        return
    var msg = name + ": " + text + "\n    DuckDB: " + String(len(want)) + " rows"
    for i in range(min(len(want), 6)):
        msg += "\n      " + want[i]
    msg += "\n    komira: " + String(len(got)) + " rows"
    for i in range(min(len(got), 6)):
        msg += "\n      " + got[i]
    problems.append(msg)


def _check_query(
    mut ctx: EngineContext,
    name: String,
    text: String,
    ref answers: _Answers,
    expected_block: String,
    mut problems: List[String],
):
    var r = _ask(ctx, text)
    if r.refusal.byte_length() > 0:
        problems.append(name + ": " + text + " -- " + r.refusal)
        return
    _compare(
        name,
        text,
        r.lines.copy(),
        answers.lines_of(expected_block),
        _is_ordered(text),
        problems,
    )


def _assert_no_problems(problems: List[String]) raises:
    if len(problems) == 0:
        return
    var text = String(len(problems)) + " answers differ from DuckDB:\n"
    for i in range(min(len(problems), 20)):
        text += "  " + problems[i] + "\n"
    assert_true(False, text)


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _check_blocks(
    mut ctx: EngineContext, ref answers: _Answers, prefix: String
) raises -> Int:
    """Run every block of `prefix` (the query text is answers.tsv's own);
    returns how many ran."""
    var problems = List[String]()
    var asked = 0
    var names = answers.names()
    for i in range(len(names)):
        if not names[i].startswith(prefix):
            continue
        _check_query(
            ctx, names[i], answers.query_of(names[i]), answers, names[i], problems
        )
        asked += 1
    _assert_no_problems(problems)
    return asked


def _check_schema(
    mut ctx: EngineContext,
    ref answers: _Answers,
    table: String,
    block: String,
) raises:
    """The names, order and types of `SELECT *` over `table` are DuckDB's."""
    var r = _ask(ctx, "select * from " + table + " limit 1")
    assert_equal(r.refusal, "")
    var want = answers.lines_of(block)
    assert_true(len(want) > 0, block + " is not in answers.tsv")
    assert_equal(len(r.schema), len(want))
    for i in range(len(want)):
        assert_equal(r.schema[i], want[i], block + " column " + String(i))


def check_directory() raises:
    """The three files of dir3/ registered as one table by their directory:
    SELECT * names, order and types, and every d_* query of answers.tsv."""
    var answers = _answers()
    var ctx = _new_context()
    register_parquet(ctx, "dir3", data_path("dir3"))
    _check_schema(ctx, answers, "dir3", "schema_dir3")
    var asked = _check_blocks(ctx, answers, "d_")
    assert_true(asked >= 7, "too few directory queries in answers.tsv")


def check_hive() raises:
    """The Hive tree under hive/ registered by a glob: the partition columns
    come after the data columns in key order with DuckDB's types, and every h_*
    query of answers.tsv (filters on a partition column and on a data column, a
    partition column alone, GROUP BY, ORDER BY) answers DuckDB's rows."""
    var answers = _answers()
    var ctx = _new_context()
    register_parquet(ctx, "hv", data_path("hive") + "/**/*.parquet")
    _check_schema(ctx, answers, "hv", "schema_hv")
    var r = _ask(ctx, "select * from hv limit 1")
    assert_equal(r.refusal, "")
    var types = List[String]()
    for i in range(len(r.schema) - 3, len(r.schema)):
        var parts = r.schema[i].split("|")
        types.append(String(parts[1]))
    assert_equal(
        _join(types), answers.lines_of("types_hv")[0], "partition column types"
    )
    var asked = _check_blocks(ctx, answers, "h_")
    assert_true(asked >= 10, "too few Hive queries in answers.tsv")


def check_sql_globs() raises:
    """Globs and the Hive option in SQL text, with no table registered: each
    answers the rows of the matching block of answers.tsv."""
    var answers = _answers()
    var ctx = _new_context()
    var dir3 = data_path("dir3")
    var hive = data_path("hive")
    var names = List[String]()
    var texts = List[String]()
    names.append("g_all")
    texts.append("select id, g from read_parquet('" + dir3 + "/*.parquet') order by id")
    names.append("g_from")
    texts.append("select count(*) as n from '" + dir3 + "/*.parquet'")
    names.append("g_brace")
    texts.append("select id, s from read_parquet('" + dir3 + "/part-{0,2}.parquet') order by id")
    names.append("g_hive")
    texts.append(
        "select id, dt, tag, yr from read_parquet('" + hive + "/**/*.parquet') order by id"
    )
    names.append("g_hive")
    texts.append(
        "select id, dt, tag, yr from read_parquet('"
        + hive
        + "/**/*.parquet', hive_partitioning = true) order by id"
    )
    names.append("g_hive_off")
    texts.append(
        "select * from read_parquet('"
        + hive
        + "/**/*.parquet', hive_partitioning = false) order by id"
    )
    var problems = List[String]()
    for i in range(len(names)):
        assert_true(len(answers.lines_of(names[i])) > 0, names[i] + " is not in answers.tsv")
        _check_query(ctx, names[i], texts[i], answers, names[i], problems)
    _assert_no_problems(problems)
