"""The checks of the DECIMAL-to-DOUBLE site tests: each query of
double_sites.tsv is run through `run_sql` against the tables pj, pd and pg (the
Parquet files the test declares), and the DOUBLE it answers for each group k
is compared bit for bit with the DOUBLE DuckDB printed."""

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_decimal_compare_conformance.checks import (
    _assert_no_problems,
    _rows,
)
from komira_jsonl.value_parsers.parse_float import parse_float_f64
from komira_runtime_paths import data_path
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import run_sql


def _new_site_context() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "pj", data_path("pj.parquet"))
    register_parquet(ctx, "pd", data_path("pd.parquet"))
    register_parquet(ctx, "pg", data_path("pg.parquet"))
    return ctx^


def check_double_site(name: String) raises:
    """Every group of the query `name` of double_sites.tsv answers the DOUBLE
    DuckDB answers (the text DuckDB prints reads back exactly), and no group is
    missing or extra."""
    var rows = _rows("double_sites.tsv")
    var text = String("")
    var want_k = List[Int]()
    var want_text = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 4)
        if cells[0] != name:
            continue
        text = cells[1]
        want_k.append(Int(atol(cells[2])))
        want_text.append(cells[3])
    assert_true(len(want_k) >= 9, name + ": double_sites.tsv holds too few groups")

    var ctx = _new_site_context()
    var outcome = run_sql(ctx, text)
    if outcome.refusal:
        assert_true(
            False,
            name
            + ": refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason,
        )
    var problems = List[String]()
    var seen = 0
    for b in range(len(outcome.batches)):
        ref batch = outcome.batches[b]
        ref kcol = batch.column_at(0)
        ref xcol = batch.column_at(1)
        if xcol.arrow_type != ArrowType.FLOAT64:
            assert_true(
                False,
                name + ": the answer is " + String(xcol.arrow_type) + ", not DOUBLE",
            )
        var xs = xcol.as_primitive[DType.float64]()
        var ks = kcol.as_primitive[DType.int64]()
        for i in range(batch.num_rows()):
            var k = Int(ks.get(i))
            var found = -1
            for j in range(len(want_k)):
                if want_k[j] == k:
                    found = j
            seen += 1
            if found < 0:
                problems.append(name + ": group " + String(k) + " is not in DuckDB's answer")
                continue
            var want = parse_float_f64(
                want_text[found].as_bytes(), 0, want_text[found].byte_length()
            )
            var got = xs.get(i)
            if got != want:
                problems.append(
                    name
                    + " group "
                    + String(k)
                    + ": DuckDB gives "
                    + want_text[found]
                    + ", komira "
                    + String(got)
                )
    if seen != len(want_k):
        problems.append(
            name
            + ": DuckDB answers "
            + String(len(want_k))
            + " groups, komira "
            + String(seen)
        )
    _assert_no_problems(problems)


def check_reviewer_group_sums() raises:
    """DuckDB's own numbers for the two integer sums at which a one-rounding
    conversion differs: group 7 sums to -(2^64) - 2^11 - 1 and group 10 to
    -(2^70) - 2^17 - 1, and `sum(v) * 1e0` over them is -1.8446744073709552e+19
    and -1.1805916207174113e+21 (a single correctly rounded conversion gives
    ...556e+19 and ...116e+21)."""
    var ctx = _new_site_context()
    var outcome = run_sql(
        ctx, "select k, sum(v) * 1e0 as x from pj where k = 7 or k = 10 group by k"
    )
    if outcome.refusal:
        assert_true(False, "refused: " + outcome.refusal.value().reason)
    var seen = 0
    for b in range(len(outcome.batches)):
        ref batch = outcome.batches[b]
        var ks = batch.column_at(0).as_primitive[DType.int64]()
        var xs = batch.column_at(1).as_primitive[DType.float64]()
        for i in range(batch.num_rows()):
            var want_text = String("-1.8446744073709552e+19")
            if ks.get(i) == Int64(10):
                want_text = String("-1.1805916207174113e+21")
            var want = parse_float_f64(
                want_text.as_bytes(), 0, want_text.byte_length()
            )
            assert_true(
                xs.get(i) == want,
                "group " + String(ks.get(i)) + ": " + String(xs.get(i)),
            )
            seen += 1
    assert_equal(seen, 2)
