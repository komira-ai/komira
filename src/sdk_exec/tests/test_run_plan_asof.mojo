# =============================================================================
# test_run_plan_asof: an as-of join node runs over CSV and Parquet leaves and
# answers what DuckDB's ASOF LEFT JOIN answers
# =============================================================================
#
# Covers: a PLAN_ASOF_JOIN node (`LogicalPlan.asof_join`) over the plans of
# `read_parquet(...)` and `read_csv(...)` leaves runs through run_plan
# (optimize, lower to a right SINK_COLLECT segment and a left SINK_ASOF_JOIN
# segment, run on the pipeline) on 1 and 3 workers, and its rows equal the
# pinned DuckDB's answer to the same ASOF LEFT JOIN over the same files, as a
# multiset (the node emits its left rows in its sorted order).
#
# The files and answers are the `:asof_oracle` action in BUCK:
# tests/asof/data.sql writes the trades t, the quotes q (and q2, the same
# rows in another order), and the empty e and te, as Parquet in row groups of
# 3 rows and as CSV; each line of tests/asof/cases.sql is one ASOF LEFT JOIN
# DuckDB answers, written `<case>_<parquet|csv>.tsv`. Its columns are the
# node's own (the left side's, then the right side's, `_right` on a name the
# left side uses), so the answer is compared with the node's rows directly.
# This file states each case's node: the columns of each side, the key pairs,
# the ASOF columns and the direction (`>=` is BACKWARD, `<=` FORWARD).
#
# The tables hold, unsorted: a trade between two quotes of its symbol, one at
# a quote's time, one before every quote of its symbol, one after every quote
# of its symbol, a symbol with no quote, a NULL symbol and a NULL time on each
# side, and two quotes of B at the same time 15.
#
# What each test proves:
#   * test_backward_and_forward_keyed_match_duckdb: per symbol, `>=` matches
#     the latest quote at or before the trade and `<=` the earliest at or
#     after it; an equal time matches; a trade with no such quote, a NULL
#     symbol, a NULL time or a symbol with no quote keeps its row with NULL
#     quote columns; groups do not mix.
#   * test_no_key_matches_duckdb: with no key every quote is one group, the
#     NULL-symbol quote included.
#   * test_timestamp_asof_column_matches_duckdb: a TIMESTAMP ASOF column, read
#     from Parquet, is walked as its instants.
#   * test_a_csv_timestamp_column_is_refused_at_lower: komira's CSV reader
#     infers no TIMESTAMP (it reads the column as text, where DuckDB's reads a
#     timestamp) and SQL has no CAST to TIMESTAMP, so the same columns read
#     from CSV are a LOWERING_ASOF_UNSERVED refusal naming string, not an
#     answer.
#   * test_two_keys_match_duckdb: two key pairs (VARCHAR and BIGINT) both
#     have to match.
#   * test_tied_right_rows_match_duckdb: of two quotes at one time, the one
#     first in the file is the match in both directions, and swapping their
#     order in the file swaps the answer, as in DuckDB.
#   * test_empty_sides_match_duckdb: no quote gives every trade with NULL
#     quote columns; no trade gives no row, at the node's columns.
#   * test_every_case_is_run: every answer the oracle writes belongs to one of
#     the tests above, and every case they name has an answer.
#   * test_an_asof_column_of_another_type_is_refused_at_lower: ASOF columns of
#     VARCHAR are a LOWERING_ASOF_UNSERVED refusal at step lower, not run.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    AsofTolerance,
    LogicalPlan,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_plan import STEP_LOWER, run_plan
from sql.sql_frontend import plan_from_sql

# The column shapes of the cases: the left side's and the right side's
# columns, and the ASOF column of both.
comptime _INT = 0  # t(id, sym, ts) and q(sym, ts, px, qid) on ts
comptime _TS = 1  # t(id, sym, tts) and q(sym, tts, px, qid) on tts
comptime _TWO = 2  # t(id, sym, ts) and q(sym, qid, ts, px) on ts, keys sym and id=qid

comptime _NO_KEY = 0
comptime _SYM = 1


struct _Case(Copyable, Movable):
    var name: String
    var left: String
    var right: String
    var shape: Int
    var keys: Int
    var strategy: UInt8

    def __init__(
        out self,
        var name: String,
        var left: String,
        var right: String,
        shape: Int,
        keys: Int,
        strategy: UInt8,
    ):
        self.name = name^
        self.left = left^
        self.right = right^
        self.shape = shape
        self.keys = keys
        self.strategy = strategy


def _keyed() -> List[_Case]:
    var out = List[_Case]()
    out.append(_Case("backward_keyed", "t", "q", _INT, _SYM, ASOF_BACKWARD))
    out.append(_Case("forward_keyed", "t", "q", _INT, _SYM, ASOF_FORWARD))
    return out^


def _no_key() -> List[_Case]:
    var out = List[_Case]()
    out.append(_Case("backward_no_key", "t", "q", _INT, _NO_KEY, ASOF_BACKWARD))
    out.append(_Case("forward_no_key", "t", "q", _INT, _NO_KEY, ASOF_FORWARD))
    return out^


def _timestamp() -> List[_Case]:
    var out = List[_Case]()
    out.append(_Case("backward_timestamp", "t", "q", _TS, _SYM, ASOF_BACKWARD))
    out.append(_Case("forward_timestamp", "t", "q", _TS, _SYM, ASOF_FORWARD))
    return out^


def _two_keys() -> List[_Case]:
    var out = List[_Case]()
    out.append(_Case("backward_two_keys", "t", "q", _TWO, _SYM, ASOF_BACKWARD))
    return out^


def _ties() -> List[_Case]:
    var out = List[_Case]()
    out.append(_Case("backward_keyed", "t", "q", _INT, _SYM, ASOF_BACKWARD))
    out.append(_Case("forward_keyed", "t", "q", _INT, _SYM, ASOF_FORWARD))
    out.append(
        _Case("backward_ties_reordered", "t", "q2", _INT, _SYM, ASOF_BACKWARD)
    )
    out.append(
        _Case("forward_ties_reordered", "t", "q2", _INT, _SYM, ASOF_FORWARD)
    )
    return out^


def _empty() -> List[_Case]:
    var out = List[_Case]()
    out.append(
        _Case("backward_empty_right", "t", "e", _INT, _SYM, ASOF_BACKWARD)
    )
    out.append(
        _Case("backward_empty_left", "te", "q", _INT, _SYM, ASOF_BACKWARD)
    )
    return out^


def _kinds(name: String) -> List[String]:
    """The leaf kinds a case has an answer over: the empty tables and the
    TIMESTAMP cases are Parquet only (komira's CSV reader reads a timestamp as
    text; `test_a_csv_timestamp_column_is_refused_at_lower`)."""
    var out: List[String] = ["parquet"]
    if (
        not name.endswith("_empty_right")
        and not name.endswith("_empty_left")
        and not name.endswith("_timestamp")
    ):
        out.append("csv")
    return out^


def _side(ctx: EngineContext, cols: String, stem: String, kind: String) raises -> LogicalPlan:
    var file = stem + "." + kind
    return plan_from_sql(
        "SELECT " + cols + " FROM read_" + kind + "('" + data_path(file) + "')",
        ctx.catalog,
        ctx.footers,
    )


def _node(ctx: EngineContext, c: _Case, kind: String) raises -> LogicalPlan:
    var lcols = String("id, sym, ts")
    var rcols = String("sym, ts, px, qid")
    var on = String("ts")
    var lkeys = List[String]()
    var rkeys = List[String]()
    if c.keys == _SYM:
        lkeys.append("sym")
        rkeys.append("sym")
    if c.shape == _TS:
        lcols = "id, sym, tts"
        rcols = "sym, tts, px, qid"
        on = "tts"
    elif c.shape == _TWO:
        rcols = "sym, qid, ts, px"
        lkeys.append("id")
        rkeys.append("qid")
    return LogicalPlan.asof_join(
        _side(ctx, lcols, c.left, kind),
        _side(ctx, rcols, c.right, kind),
        lkeys^,
        rkeys^,
        on,
        on,
        c.strategy,
        AsofTolerance.none(),
    )


def _check(c: _Case, kind: String, workers: Int, mut problems: List[String]) raises:
    var name = c.name + "_" + kind
    var label = name + " on " + String(workers) + " workers"
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_plan(ctx, _node(ctx, c, kind))
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return
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


def _check_all(cases: List[_Case]) raises:
    var problems = List[String]()
    for i in range(len(cases)):
        var kinds = _kinds(cases[i].name)
        for k in range(len(kinds)):
            _check(cases[i], kinds[k], 1, problems)
            _check(cases[i], kinds[k], 3, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def test_backward_and_forward_keyed_match_duckdb() raises:
    _check_all(_keyed())


def test_no_key_matches_duckdb() raises:
    _check_all(_no_key())


def test_timestamp_asof_column_matches_duckdb() raises:
    _check_all(_timestamp())


def test_two_keys_match_duckdb() raises:
    _check_all(_two_keys())


def test_tied_right_rows_match_duckdb() raises:
    _check_all(_ties())
    # The answers themselves differ: trade 4 (B at 15) takes quote 4 from q
    # and quote 5 from q2, in both directions.
    var names: List[String] = [
        "backward_keyed_parquet",
        "backward_ties_reordered_parquet",
        "forward_keyed_parquet",
        "forward_ties_reordered_parquet",
    ]
    var want: List[String] = ["4", "5", "4", "5"]
    for i in range(len(names)):
        var found = False
        for line in read_data(names[i] + ".tsv").split("\n"):
            var cells = String(line).split("\t")
            if len(cells) == 7 and cells[0] == "4":
                assert_equal(String(cells[6]), want[i], names[i])
                found = True
        assert_true(found, names[i] + " holds trade 4")


def test_empty_sides_match_duckdb() raises:
    _check_all(_empty())


def test_every_case_is_run() raises:
    var named = List[String]()
    var groups = List[List[_Case]]()
    groups.append(_keyed())
    groups.append(_no_key())
    groups.append(_timestamp())
    groups.append(_two_keys())
    groups.append(_ties())
    groups.append(_empty())
    for g in range(len(groups)):
        for i in range(len(groups[g])):
            var kinds = _kinds(groups[g][i].name)
            for k in range(len(kinds)):
                named.append(groups[g][i].name + "_" + kinds[k])
    var answered = 0
    for line in read_data("cases.sql").split("\n"):
        var l = String(line)
        if not l.startswith("COPY ("):
            continue
        answered += 1
        var tsv = l.rfind(".tsv'")
        var to = l.rfind(") TO '")
        var name = String(l[byte = to + 6 : tsv])
        var found = False
        for i in range(len(named)):
            if named[i] == name:
                found = True
        assert_true(found, "no test runs case " + name)
    for i in range(len(named)):
        assert_true(read_data(named[i] + ".tsv").byte_length() > 0, named[i])
    assert_equal(answered, 18)


def test_an_asof_column_of_another_type_is_refused_at_lower() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var keys = List[String]()
    var plan = LogicalPlan.asof_join(
        _side(ctx, "id, sym", "t", "parquet"),
        _side(ctx, "sym, qid", "q", "parquet"),
        keys.copy(),
        keys.copy(),
        "sym",
        "sym",
        ASOF_BACKWARD,
        AsofTolerance.none(),
    )
    var out = run_plan(ctx, plan^)
    assert_true(not out.ok(), "an ASOF column of VARCHAR ran")
    ref r = out.refusal.value()
    assert_equal(r.step, String(STEP_LOWER))
    assert_true(
        r.reason.startswith("LOWERING_ASOF_UNSERVED: "), r.reason
    )
    assert_true("ASOF columns are" in r.reason, r.reason)


def test_a_csv_timestamp_column_is_refused_at_lower() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var keys: List[String] = ["sym"]
    var plan = LogicalPlan.asof_join(
        _side(ctx, "id, sym, tts", "t", "csv"),
        _side(ctx, "sym, tts, px, qid", "q", "csv"),
        keys.copy(),
        keys.copy(),
        "tts",
        "tts",
        ASOF_BACKWARD,
        AsofTolerance.none(),
    )
    var out = run_plan(ctx, plan^)
    assert_true(not out.ok(), "a CSV timestamp column ran as text")
    ref r = out.refusal.value()
    assert_equal(r.step, String(STEP_LOWER))
    assert_true(
        "the ASOF columns are string and string" in r.reason, r.reason
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_backward_and_forward_keyed_match_duckdb]()
    suite.test[test_no_key_matches_duckdb]()
    suite.test[test_timestamp_asof_column_matches_duckdb]()
    suite.test[test_two_keys_match_duckdb]()
    suite.test[test_tied_right_rows_match_duckdb]()
    suite.test[test_empty_sides_match_duckdb]()
    suite.test[test_every_case_is_run]()
    suite.test[test_an_asof_column_of_another_type_is_refused_at_lower]()
    suite.test[test_a_csv_timestamp_column_is_refused_at_lower]()
    suite^.run()
