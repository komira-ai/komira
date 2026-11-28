# =============================================================================
# test_run_sql_window: window functions through run_sql answer what DuckDB
# answers
# =============================================================================
#
# Covers: run_sql over a Parquet table DuckDB wrote (the :window_oracle action
# in BUCK) answers what the pinned DuckDB answers for each case of
# tests/window/cases.sql: row_number, rank, dense_rank, percent_rank,
# cume_dist, ntile, lag and lead (offsets, defaults, BIGINT, DOUBLE and
# VARCHAR), running sums over the default RANGE frame and over a unique key,
# running min, max, avg and count over tied keys, whole-partition sum, count,
# avg, min and max, first_value, last_value and nth_value, with no, one or two
# partition keys, several windows in one SELECT, a WHERE, an outer ORDER BY and
# no row, a CTE holding a window read twice, a window over a CTE aggregation
# read twice (and over a union of the reads) and a join with a window on its
# left side beside a CTE read twice, with NULL keys, tied order keys and the
# empty string, on one and three workers, each column of its documented type;
# every case is run, sum, avg, min and max over an INTEGER among them; a
# DECIMAL order key, and windows over the groups of a GROUP BY ordered by an
# aggregate; a DATE partition key and a float default over a BIGINT lag are
# LOWERING_WINDOW_UNSERVED refusals at step lower.
#
# The pinned DuckDB writes the table (tests/window/data.sql: 5000 rows in five
# row groups; a BIGINT id with no tie, an INTEGER, a VARCHAR and a BOOLEAN
# partition key, a BIGINT order key with many ties and NULLs, BIGINT, DOUBLE,
# VARCHAR, INTEGER, DATE and DECIMAL(12, 2) value columns, each with NULLs at
# a period of its own) and answers each query of tests/window/cases.sql as a
# build action (`sql_oracle`). This test reads the same cases.sql for the
# query text, runs it through `run_sql` (parse, bind, optimize, lower to a
# SINK_PARTITION_BY segment, run on the pipeline) over the same Parquet file,
# and compares the answer with DuckDB's by value, rows as a multiset
# (komira_plan_harness) except for the case with an outer ORDER BY on a total
# key, which compares in order. Each column of the answer also has the type
# the documented result types give it (ranking functions, count and a sum of a
# BIGINT INT64, avg, percent_rank, cume_dist and a sum of a DOUBLE FLOAT64,
# lag, lead, first_value, last_value, nth_value, min and max the argument's
# type, an integer sum computed by a GROUP BY DECIMAL128), which the
# comparison by value alone would not see.
#
#   test_ranking_functions_equal_duckdb      row_number per INTEGER and per
#                                            VARCHAR partition (ascending and
#                                            descending), rank and dense_rank
#                                            with tied and NULL order keys,
#                                            percent_rank, cume_dist, ntile(4).
#   test_lag_and_lead_equal_duckdb           lag and lead of a BIGINT, with an
#                                            offset and with a default, of a
#                                            VARCHAR with a string default,
#                                            of a DOUBLE with an integer default.
#   test_running_and_whole_partition_aggregates_equal_duckdb
#                                            a running sum over the default
#                                            RANGE frame (peers share a value)
#                                            and over a unique key, running min,
#                                            max, avg and count over tied keys,
#                                            sum, count,
#                                            count(*), avg, min and max over a
#                                            whole partition, NULL partitions
#                                            and NULL values included; sum, min,
#                                            max and avg of a nullable INTEGER
#                                            over both frames.
#   test_value_functions_equal_duckdb        first_value, last_value and
#                                            nth_value per partition, and
#                                            last_value over ROWS BETWEEN
#                                            UNBOUNDED PRECEDING AND
#                                            UNBOUNDED FOLLOWING.
#   test_window_shapes_equal_duckdb          no PARTITION BY, two partition
#                                            keys with a descending order key,
#                                            several windows in one SELECT
#                                            (two with one spec), a window over
#                                            a WHERE, an outer ORDER BY on a
#                                            total key, a WHERE no row passes.
#   test_windows_with_shared_subplans_equal_duckdb
#                                            a CTE holding a window read twice
#                                            (whole, and under two filters), a
#                                            window over a CTE aggregation read
#                                            twice (one window per read, and
#                                            one over a union of the reads),
#                                            and a join whose left side is a
#                                            window while a CTE is read twice.
#   test_windows_over_groups_and_decimal_keys_equal_duckdb
#                                            rank over a DECIMAL(12, 2) order
#                                            key with NULLs and ties; in a
#                                            GROUP BY, rank ordered by
#                                            count(*) DESC with a tie-break,
#                                            dense_rank ordered by an INTEGER
#                                            sum written in the OVER clause
#                                            (a DECIMAL(38, 0) key) beside the
#                                            same sum selected, rank over the
#                                            sum computed in a subquery per
#                                            VARCHAR partition (NULL and the
#                                            empty string included), rank per
#                                            BOOLEAN partition ordered by a
#                                            BIGINT sum, and row_number and
#                                            count(*) OVER () beside a HAVING.
#   test_every_case_is_run                   each case of cases.sql belongs to
#                                            one of the tests above.
#   test_unserved_windows_are_named_refusals_at_lower
#                                            a DATE partition key and a float
#                                            default over a BIGINT lag are
#                                            refused at step lower with a
#                                            LOWERING_WINDOW_UNSERVED reason.
#
# Every case runs on one worker and on three. Explicit ROWS and RANGE frames
# are test_run_sql_window_frames'.
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
from sdk_exec.engine_sql import STEP_LOWER, run_sql

comptime _REFUSAL_PREFIX = "LOWERING_WINDOW_UNSERVED: "


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


def _column_type(name: String) -> ArrowType:
    """The type a column of a case has: the table's for a column that passes
    through, and the documented result type for a window column (by its alias).
    NULL for a name this test does not know."""
    if name == "id" or name == "o" or name == "v":
        return ArrowType.INT64
    if name == "g":
        return ArrowType.INT32
    if name == "s" or name == "t":
        return ArrowType.STRING
    if name == "b":
        return ArrowType.BOOL
    # row_number, rank, dense_rank, ntile, count, a sum or min or max of a
    # BIGINT or an INTEGER (komira's INT64; DuckDB's sum is a HUGEINT), lag, lead,
    # first_value, last_value and nth_value of a BIGINT.
    if (
        name == "rn" or name == "rk" or name == "dr" or name == "q"
        or name == "cnt" or name == "cnv" or name == "sv" or name == "mnv"
        or name == "mxv" or name == "si" or name == "lv1" or name == "ld2" or name == "lv0"
        or name == "ld3" or name == "fv" or name == "lastv" or name == "nthv"
    ):
        return ArrowType.INT64
    # min and max of an INTEGER stay INTEGER.
    if name == "mni" or name == "mxi":
        return ArrowType.INT32
    # percent_rank, cume_dist, avg, and a sum, min, max, lag of a DOUBLE.
    if (
        name == "pr" or name == "cd" or name == "av" or name == "ai" or name == "sf"
        or name == "mnf" or name == "mxf" or name == "lf"
    ):
        return ArrowType.FLOAT64
    # lag, lead and first_value of a VARCHAR.
    if name == "lt" or name == "ldt" or name == "ft":
        return ArrowType.STRING
    # The DECIMAL(12, 2) column, and an INTEGER sum computed by a GROUP BY
    # (DuckDB's HUGEINT is DECIMAL(38, 0) here).
    if name == "m" or name == "units":
        return ArrowType.DECIMAL128
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


def _check(
    name: String, workers: Int, total: Bool, mut problems: List[String]
) raises:
    var label = name + " on " + String(workers) + " workers"
    var query = String("")
    var cases = _cases()
    for i in range(len(cases)):
        if cases[i].name == name:
            query = cases[i].query
    if query == "":
        problems.append(label + ": cases.sql holds no case " + name)
        return
    var text = query.replace(
        "'win.parquet'", "'" + data_path("win.parquet") + "'"
    )
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_sql(ctx, text)
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
    var policy = CanonPolicy.total() if total else CanonPolicy.unordered()
    var actual = render_batch(out.batches[0], policy^)
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(label + ": " + String(report))
    except e:
        problems.append(label + ": " + String(e))


def _check_all(var names: List[String], total: Bool = False) raises:
    var problems = List[String]()
    for i in range(len(names)):
        _check(names[i], 1, total, problems)
        _check(names[i], 3, total, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _ranking() -> List[String]:
    var out = List[String]()
    out.append("row_number_g")
    out.append("row_number_s_desc")
    out.append("rank_dense_rank")
    out.append("percent_rank_cume_dist")
    out.append("ntile4")
    return out^


def _lag_lead() -> List[String]:
    var out = List[String]()
    out.append("lag_lead_v")
    out.append("lag_lead_default")
    out.append("lag_lead_t")
    out.append("lag_f_default")
    return out^


def _aggregates() -> List[String]:
    var out = List[String]()
    out.append("running_sum_v")
    out.append("running_aggs_peers")
    out.append("running_sum_f")
    out.append("whole_partition_aggs")
    out.append("whole_partition_f")
    out.append("running_aggs_integer")
    out.append("whole_partition_integer")
    return out^


def _values() -> List[String]:
    var out = List[String]()
    out.append("value_functions")
    out.append("last_value_whole_frame")
    return out^


def _shapes() -> List[String]:
    var out = List[String]()
    out.append("no_partition")
    out.append("two_keys")
    out.append("several_windows")
    out.append("over_where")
    out.append("no_row")
    return out^


def _ordered() -> List[String]:
    var out = List[String]()
    out.append("ordered_output")
    return out^


def _shared() -> List[String]:
    var out = List[String]()
    out.append("cte_window_twice")
    out.append("cte_window_split")
    out.append("cte_window_over_group")
    out.append("cte_window_over_union")
    out.append("cte_window_join_shared")
    return out^


def _grouped() -> List[String]:
    var out = List[String]()
    out.append("rank_decimal_m")
    out.append("group_rank_by_count")
    out.append("group_rank_by_sum")
    out.append("subquery_rank_by_sum")
    out.append("group_partition_rank_by_sum")
    out.append("group_windows_having")
    return out^


def test_ranking_functions_equal_duckdb() raises:
    _check_all(_ranking())


def test_lag_and_lead_equal_duckdb() raises:
    _check_all(_lag_lead())


def test_running_and_whole_partition_aggregates_equal_duckdb() raises:
    _check_all(_aggregates())


def test_value_functions_equal_duckdb() raises:
    _check_all(_values())


def test_window_shapes_equal_duckdb() raises:
    _check_all(_shapes())
    _check_all(_ordered(), total=True)


def test_windows_with_shared_subplans_equal_duckdb() raises:
    _check_all(_shared())


def test_windows_over_groups_and_decimal_keys_equal_duckdb() raises:
    _check_all(_grouped())


def test_every_case_is_run() raises:
    var known = _ranking()
    known.extend(_lag_lead())
    known.extend(_aggregates())
    known.extend(_values())
    known.extend(_shapes())
    known.extend(_ordered())
    known.extend(_shared())
    known.extend(_grouped())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


struct _Refusal(Copyable, Movable):
    var label: String
    var query: String
    # The whole reason lowering gives, after the LOWERING_WINDOW_UNSERVED token.
    var reason: String

    def __init__(
        out self, var label: String, var query: String, var reason: String
    ):
        self.label = label^
        self.query = query^
        self.reason = reason^


def _refusals() -> List[_Refusal]:
    var t = String("FROM read_parquet('win.parquet')")
    var out = List[_Refusal]()
    out.append(_Refusal(
        "a DATE partition key",
        "SELECT id, row_number() OVER (PARTITION BY d ORDER BY id) AS rn " + t,
        "the PARTITION BY key 'd' has type date32, which the window's sort does not order",
    ))
    out.append(_Refusal(
        "a float default over a BIGINT lag",
        "SELECT id, lag(v, 1, 1.5) OVER (PARTITION BY g ORDER BY id) AS lv1 "
        + t,
        "LAG(v) has a default that the int64 column cannot hold unchanged",
    ))
    return out^


def test_unserved_windows_are_named_refusals_at_lower() raises:
    var refusals = _refusals()
    for i in range(len(refusals)):
        ref r = refusals[i]
        var text = r.query.replace(
            "'win.parquet'", "'" + data_path("win.parquet") + "'"
        )
        var ctx = EngineContext(EngineOptions(worker_count=1))
        var out = run_sql(ctx, text)
        assert_true(Bool(out.refusal), r.label + " is refused")
        var step = out.refusal.value().step
        var reason = out.refusal.value().reason
        assert_equal(step, String(STEP_LOWER), r.label + ": step")
        assert_equal(
            reason, _REFUSAL_PREFIX + r.reason, r.label + ": reason"
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
