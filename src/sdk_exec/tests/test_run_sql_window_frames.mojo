# =============================================================================
# test_run_sql_window_frames: ROWS and RANGE frames through run_sql equal the
# pinned DuckDB
# =============================================================================
#
# Covers: run_sql over two Parquet tables DuckDB wrote (the
# :window_frames_oracle action in BUCK) answers what the pinned DuckDB answers
# for each case of tests/window_frames/cases.sql, on one and three workers:
# ROWS frames (sliding, empty at a partition's edge, running and tail,
# descending, offsets past the partition) with sum, count, avg, min, max,
# first_value, last_value and nth_value, and RANGE frames with offsets over a
# BIGINT key with ties and NULLs, an INTEGER key with an offset past 32 bits
# and a DOUBLE key with NaN, infinities, -0.0 and NULL, with keys at the ends
# of BIGINT and INTEGER range; no PARTITION BY, ranking and LAG ignoring their
# frame, a WHERE and no row; every case is run; a RANGE bound that leaves the
# key's type fails at step execute with DuckDB's overflow error, and a frame
# DuckDB refuses fails at step bind with DuckDB's reason.
#
# DuckDB writes frames.parquet and edge.parquet (tests/window_frames/data.sql)
# and answers each case of tests/window_frames/cases.sql; run_sql runs the
# same text over the same files, on one worker and on three, and its batch
# must equal DuckDB's rows, each column of the type its alias names.
#
#   test_rows_frames_equal_duckdb             sum, count, count(*), avg, min
#                                             and max over a sliding ROWS
#                                             frame; frames empty at a
#                                             partition's edge (NULL, and a
#                                             count of 0); running and tail
#                                             frames and the single-bound
#                                             shorthand; first_value,
#                                             last_value and nth_value of a
#                                             BIGINT, VARCHAR and DOUBLE; a
#                                             descending order; offsets of
#                                             9223372036854775807, past the
#                                             partition, and 0.
#   test_range_frames_with_offsets_equal_duckdb
#                                             a BIGINT key with ties and NULLs
#                                             (both directions, frames before,
#                                             after and around the row, 0
#                                             offsets), an INTEGER key with an
#                                             offset past 32 bits, a DOUBLE key
#                                             with NaN, both infinities, -0.0
#                                             and NULL.
#   test_frame_shapes_equal_duckdb            no PARTITION BY, ranking and LAG
#                                             with a frame they ignore, a WHERE
#                                             and a WHERE no row passes.
#   test_offsets_at_the_ends_of_the_key_types_equal_duckdb
#                                             BIGINT keys at both ends with an
#                                             offset of 9223372036854775807
#                                             that stays in range, INTEGER keys
#                                             at both ends with offsets past 32
#                                             bits.
#   test_every_case_is_run                    each case of cases.sql belongs to
#                                             one of the tests above.
#   test_a_range_bound_that_leaves_the_keys_type_fails_as_duckdb_does
#                                             BIGINT subtraction and addition
#                                             and INTEGER subtraction fail at
#                                             step execute with DuckDB's
#                                             overflow error, whole.
#   test_frames_duckdb_refuses_fail_at_bind   a frame shape DuckDB's parser
#                                             refuses, a RANGE offset over two
#                                             ORDER BY keys and over a VARCHAR
#                                             key fail at step bind with
#                                             DuckDB's reason.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, run_sql


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
            _Case(String(l[byte = to + 6 : tsv]), String(l[byte=6:to]))
        )
    return out^


def _local(query: String) raises -> String:
    """`query` reading the files the oracle wrote."""
    return query.replace(
        "'frames.parquet'", "'" + data_path("frames.parquet") + "'"
    ).replace("'edge.parquet'", "'" + data_path("edge.parquet") + "'")


def _column_type(name: String) -> ArrowType:
    """The type a column of a case has: the table's for a column that passes
    through, the alias prefix's for a window column (n_ BIGINT, d_ DOUBLE,
    s_ VARCHAR), NULL for a name this test does not know."""
    if name == "id":
        return ArrowType.INT64
    if name == "p":
        return ArrowType.INT32
    if name.startswith("n_"):
        return ArrowType.INT64
    if name.startswith("d_"):
        return ArrowType.FLOAT64
    if name.startswith("s_"):
        return ArrowType.STRING
    return ArrowType.NULL


def _type_problem(ref batch: RecordBatch) -> String:
    """The first column whose type is not the one expected, or ""."""
    for c in range(batch.schema.num_columns()):
        var n = batch.schema.field_name(c)
        var want = _column_type(n)
        if want == ArrowType.NULL:
            return "column " + n + " has no expected type in this test"
        var t = batch.schema.field_arrow_type(c)
        if t != want:
            return "column " + n + " is " + String(t) + ", expected " + String(want)
    return ""


def _check(name: String, workers: Int, mut problems: List[String]) raises:
    var label = name + " on " + String(workers) + " workers"
    var query = String("")
    var cases = _cases()
    for i in range(len(cases)):
        if cases[i].name == name:
            query = cases[i].query
    if query == "":
        problems.append(label + ": cases.sql holds no case " + name)
        return
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_sql(ctx, _local(query))
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return
    var typed = _type_problem(out.batches[0])
    if typed != "":
        problems.append(label + ": " + typed)
    var actual = render_batch(out.batches[0], CanonPolicy.unordered())
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(label + ": " + String(report))
    except e:
        problems.append(label + ": " + String(e))


def _check_all(var names: List[String]) raises:
    var problems = List[String]()
    for i in range(len(names)):
        _check(names[i], 1, problems)
        _check(names[i], 3, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _rows() -> List[String]:
    var out = List[String]()
    out.append("rows_sliding")
    out.append("rows_empty_edges")
    out.append("rows_running_and_tail")
    out.append("rows_value_fns")
    out.append("rows_desc")
    out.append("rows_wide_offsets")
    return out^


def _range() -> List[String]:
    var out = List[String]()
    out.append("range_bigint")
    out.append("range_bigint_one_sided")
    out.append("range_bigint_desc")
    out.append("range_int32")
    out.append("range_double")
    return out^


def _shapes() -> List[String]:
    var out = List[String]()
    out.append("no_partition")
    out.append("frame_ignored")
    out.append("over_where")
    out.append("no_row")
    return out^


def _edges() -> List[String]:
    var out = List[String]()
    out.append("edge_bigint_wide")
    out.append("edge_int32_wide")
    return out^


def test_rows_frames_equal_duckdb() raises:
    _check_all(_rows())


def test_range_frames_with_offsets_equal_duckdb() raises:
    _check_all(_range())


def test_frame_shapes_equal_duckdb() raises:
    _check_all(_shapes())


def test_offsets_at_the_ends_of_the_key_types_equal_duckdb() raises:
    _check_all(_edges())


def test_every_case_is_run() raises:
    var known = _rows()
    known.extend(_range())
    known.extend(_shapes())
    known.extend(_edges())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


def _fails(query: String, step: String, reason: String) raises:
    for workers in range(1, 4, 2):
        var ctx = EngineContext(EngineOptions(worker_count=workers))
        var out = run_sql(ctx, _local(query))
        var label = query + " on " + String(workers) + " workers"
        assert_true(Bool(out.refusal), label + " fails")
        assert_equal(out.refusal.value().step, step, label + ": step")
        assert_equal(out.refusal.value().reason, reason, label + ": reason")


def test_a_range_bound_that_leaves_the_keys_type_fails_as_duckdb_does() raises:
    var head = String("partition_frame_index: Out of Range Error: Overflow in ")
    var tail = ")! (the RANGE frame bound of the ORDER BY key '"
    var edge = String(" FROM read_parquet('edge.parquet')")
    _fails(
        "SELECT id, sum(x) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND"
        " CURRENT ROW) AS n_sum" + edge,
        String(STEP_EXECUTE),
        head + "subtraction of INT64 (-9223372036854775808 - 1" + tail + "k')",
    )
    _fails(
        "SELECT id, count(*) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND"
        " 1 FOLLOWING) AS n_cnt" + edge,
        String(STEP_EXECUTE),
        head + "addition of INT64 (9223372036854775807 + 1" + tail + "k')",
    )
    _fails(
        "SELECT id, count(*) OVER (ORDER BY i RANGE BETWEEN 1 PRECEDING AND"
        " CURRENT ROW) AS n_cnt" + edge,
        String(STEP_EXECUTE),
        head + "subtraction of INT32 (-2147483648 - 1" + tail + "i')",
    )


def test_frames_duckdb_refuses_fail_at_bind() raises:
    var frames = String(" FROM read_parquet('frames.parquet')")
    _fails(
        "SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND"
        " CURRENT ROW) AS n_sum" + frames,
        String(STEP_BIND),
        "SQL syntax error: frame starting from following row cannot have"
        " preceding rows",
    )
    _fails(
        "SELECT id, sum(v) OVER (ORDER BY k, id RANGE BETWEEN 1 PRECEDING AND"
        " CURRENT ROW) AS n_sum" + frames,
        String(STEP_BIND),
        "SQL bind error: RANGE frames must have only one ORDER BY expression",
    )
    _fails(
        "SELECT id, sum(v) OVER (ORDER BY t RANGE BETWEEN 1 PRECEDING AND"
        " CURRENT ROW) AS n_sum" + frames,
        String(STEP_BIND),
        "SQL bind error: a RANGE frame with an offset subtracts the offset"
        " from the ORDER BY key, and 't' is VARCHAR, which has no `-` (DuckDB:"
        " no function matches '-(VARCHAR, INTEGER_LITERAL)')",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
