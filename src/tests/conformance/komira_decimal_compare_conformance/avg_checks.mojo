"""The checks of the AVG site tests: each query of avg_sites.tsv is run through
`run_sql` against the tables pj, pd and pa (the Parquet files the test
declares), and the DOUBLE it answers for each group k is compared, bit for bit,
with the DOUBLE DuckDB's own avg() printed (`printf('%.17e')`: eighteen
significant digits, which read back to the same double)."""

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
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


def _new_avg_context() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "pj", data_path("pj.parquet"))
    register_parquet(ctx, "pd", data_path("pd.parquet"))
    register_parquet(ctx, "pa", data_path("pa.parquet"))
    return ctx^


def _bits_text(x: Float64) -> String:
    return String(bitcast[DType.uint64](x))


def check_avg_query(name: String) raises:
    """Every row the query `name` of avg_sites.tsv answers has DuckDB's DOUBLE
    for its group, as the same 64 bits, and every group DuckDB answers has a
    row."""
    var rows = _rows("avg_sites.tsv")
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
    assert_true(len(want_k) >= 1, name + ": avg_sites.tsv holds no group")

    var ctx = _new_avg_context()
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
    var found = List[Bool]()
    for _ in range(len(want_k)):
        found.append(False)
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
            var at = -1
            for j in range(len(want_k)):
                if want_k[j] == k:
                    at = j
            if at < 0:
                problems.append(name + ": group " + String(k) + " is not in DuckDB's answer")
                continue
            found[at] = True
            var want = parse_float_f64(
                want_text[at].as_bytes(), 0, want_text[at].byte_length()
            )
            var got = xs.get(i)
            if bitcast[DType.uint64](got) != bitcast[DType.uint64](want):
                problems.append(
                    name
                    + " group "
                    + String(k)
                    + ": DuckDB gives "
                    + want_text[at]
                    + " (bits "
                    + _bits_text(want)
                    + "), komira "
                    + String(got)
                    + " (bits "
                    + _bits_text(got)
                    + ")"
                )
    for j in range(len(want_k)):
        if not found[j]:
            problems.append(name + ": group " + String(want_k[j]) + " has no row")
    _assert_no_problems(problems)
