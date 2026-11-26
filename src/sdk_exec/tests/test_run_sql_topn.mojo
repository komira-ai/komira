# =============================================================================
# run_sql: ORDER BY with LIMIT and OFFSET equals DuckDB, ties and NULLs included
# =============================================================================
#
# Covers: ORDER BY with LIMIT and OFFSET through run_sql over Parquet tables in
# small row groups, on 1, 3 and 7 workers: each case of the order_by_limit
# corpus with a LIMIT or an OFFSET (ties at the cut, NULLS FIRST and LAST in
# both directions, NaN above inf, a 20000-row table, total orders carrying k)
# answers the pinned DuckDB's rows in its order; the comparison reports a
# reordered, changed, missing and added row; every staged case is run or listed
# as refused (an OFFSET with no LIMIT is refused at bind by name, and the two
# corpus cases that have one are listed, not skipped); a negative LIMIT is
# refused at parse.
#
# The tables T (twelve rows: BIGINT with ties and NULLs, DOUBLE with NaN, inf
# and NULLs, text, a low-cardinality text) and U (20000 rows: a BIGINT with
# ties and a NULL for every k divisible by 37) are the rows of the `T` and `U`
# of the `order_by_limit` corpus's tables.sql
# (src/tests/conformance/komira_sql_conformance). They are written here as
# Parquet files in small row groups (several morsels), registered, and every
# case of that corpus that has a LIMIT or an OFFSET is run through `run_sql`:
# the case's SELECT is staged as `sql/<case>.sql` and the answer the pinned
# DuckDB gives it as `duckdb/<case>.tsv`. The comparison is by value and in
# row order (CanonPolicy.total(): the order is part of the claim).
#
# What each test proves:
#   * test_cases_equal_duckdb_on_one_worker, ..._on_three_workers,
#     ..._on_seven_workers: each staged case but the two listed as refused
#     answers DuckDB's rows in DuckDB's order on that many workers: top-N with and without an offset, a range
#     whose start or end falls inside a run of tied keys (key-only cases),
#     total orders that carry k, NULLS FIRST and NULLS LAST in both directions,
#     NaN above inf, an offset past the end, LIMIT 0, and the 20000-row table
#     whose per-worker top-N is cut many times.
#   * test_every_case_is_run: the staged cases are the 43 cases of the corpus
#     with a LIMIT or an OFFSET; each has a SQL text and an answer, and each
#     is either run or listed as refused with its token: offset_only and
#     offset_past_end_no_limit (an OFFSET with no LIMIT) are refused at bind
#     by name, not answered.
#   * test_the_comparison_is_not_vacuous: a staged answer with two rows in
#     the other order, with one value changed, with a row missing, and with a
#     row added is reported as a mismatch; the answer itself is not.
#   * test_a_negative_limit_is_refused_before_it_runs: LIMIT -1 over an ORDER BY
#     is refused at parse with a reason and no batch, not answered.

from std.math import inf, nan
from std.os import listdir
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import data_path, read_data, test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_PARSE, run_sql

comptime _STAGED_CASES = 43


# =============================================================================
# The tables: the rows of tables.sql
# =============================================================================


def _int_col(vals: List[Int], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var n = len(vals)
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Int64(vals[i]))
    for i in range(n):
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


def _f64_col(vals: List[Float64], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var n = len(vals)
    var a = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        a.set(i, vals[i])
    for i in range(n):
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.float64](a^)


def _str_col(vals: List[String], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var valid = List[Bool]()
    for i in range(len(vals)):
        valid.append(not nulls[i])
    return Column.from_string(StringArray.from_strings_with_validity(vals, valid))


struct _T(Movable):
    var k: List[Int]
    var k_null: List[Bool]
    var a: List[Int]
    var a_null: List[Bool]
    var b: List[Int]
    var b_null: List[Bool]
    var d: List[Float64]
    var d_null: List[Bool]
    var s: List[String]
    var s_null: List[Bool]
    var c: List[String]
    var c_null: List[Bool]
    var g: List[Int]
    var g_null: List[Bool]

    def __init__(out self):
        self.k = List[Int]()
        self.k_null = List[Bool]()
        self.a = List[Int]()
        self.a_null = List[Bool]()
        self.b = List[Int]()
        self.b_null = List[Bool]()
        self.d = List[Float64]()
        self.d_null = List[Bool]()
        self.s = List[String]()
        self.s_null = List[Bool]()
        self.c = List[String]()
        self.c_null = List[Bool]()
        self.g = List[Int]()
        self.g_null = List[Bool]()

    def add(
        mut self,
        k: Int,
        a: Int,
        b: Int,
        d: Float64,
        s: String,
        c: String,
        g: Int,
        a_null: Bool = False,
        d_null: Bool = False,
        s_null: Bool = False,
    ):
        self.k.append(k)
        self.k_null.append(False)
        self.a.append(a)
        self.a_null.append(a_null)
        self.b.append(b)
        self.b_null.append(False)
        self.d.append(d)
        self.d_null.append(d_null)
        self.s.append(s)
        self.s_null.append(s_null)
        self.c.append(c)
        self.c_null.append(False)
        self.g.append(g)
        self.g_null.append(False)


def _table_t() raises -> RecordBatch:
    var t = _T()
    var nan_ = nan[DType.float64]()
    var inf_ = inf[DType.float64]()
    t.add(0, 3, 1, 1.5, "apple", "red", 2)
    t.add(1, 1, 2, 0.0, "Banana", "blue", 1, d_null=True)
    t.add(2, 0, 1, nan_, "", "red", 2, a_null=True, s_null=True)
    t.add(3, 3, 0, inf_, "", "green", 3)
    t.add(4, 2, 5, -inf_, "Apple", "blue", 1)
    t.add(5, 1, 1, 0.0, "apple pie", "red", 2)
    t.add(6, 0, 9, 7.25, "Ünïcodé", "green", 3, a_null=True)
    t.add(7, 10, 3, -3.75, "banana", "blue", 1)
    t.add(8, 3, 7, 2.5, "a", "blue", 2)
    t.add(9, -5, 4, 0.0, "Z", "green", 3, d_null=True)
    t.add(10, 0, 8, 0.0, "zebra", "blue", 1)
    t.add(11, 2, 2, nan_, " lead", "red", 2)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(_int_col(t.k, t.k_null))
    sb.add_field(Field("a", ArrowType.INT64, True))
    rb.add_column(_int_col(t.a, t.a_null))
    sb.add_field(Field("b", ArrowType.INT64, True))
    rb.add_column(_int_col(t.b, t.b_null))
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(_f64_col(t.d, t.d_null))
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(_str_col(t.s, t.s_null))
    sb.add_field(Field("c", ArrowType.STRING, True))
    rb.add_column(_str_col(t.c, t.c_null))
    sb.add_field(Field("g", ArrowType.INT64, True))
    rb.add_column(_int_col(t.g, t.g_null))
    return rb.build(sb.build())


def _table_u() raises -> RecordBatch:
    var k = List[Int]()
    var x = List[Int]()
    var k_null = List[Bool]()
    var x_null = List[Bool]()
    for i in range(20000):
        k.append(i)
        k_null.append(False)
        x.append((i * 7919) % 1009)
        x_null.append(i % 37 == 0)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    rb.add_column(_int_col(k, k_null))
    sb.add_field(Field("x", ArrowType.INT64, True))
    rb.add_column(_int_col(x, x_null))
    return rb.build(sb.build())


def _register(
    mut ctx: EngineContext, name: String, var batch: RecordBatch, rows_per_group: Int
) raises:
    var path = test_tmpdir() + "/sql_topn_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        batch, max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, name, path)


def _context(workers: Int) raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    _register(ctx, "t", _table_t(), 4)
    _register(ctx, "u", _table_u(), 1500)
    return ctx^


# =============================================================================
# The cases
# =============================================================================

comptime _REFUSED_TOKEN = "OFFSET without LIMIT"


# Cases the SQL binder refuses for a reason outside this change: an OFFSET with
# no LIMIT is refused at bind by name (`_REFUSED_TOKEN`), where DuckDB skips
# the rows. Each must be refused with that token, not answered and not skipped.
def _refused() -> List[String]:
    var out = List[String]()
    out.append("offset_only")
    out.append("offset_past_end_no_limit")
    return out^


def _is_refused(name: String) -> Bool:
    var r = _refused()
    for i in range(len(r)):
        if r[i] == name:
            return True
    return False


def _case_names() raises -> List[String]:
    """The cases staged as `sql/<case>.sql`, sorted."""
    var out = List[String]()
    for entry in listdir(data_path("sql")):
        var f = String(entry)
        if f.endswith(".sql"):
            out.append(String(f[byte = 0 : f.byte_length() - 4]))
    # insertion sort: the listing order is the file system's
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            var tmp = out[j - 1]
            out[j - 1] = out[j]
            out[j] = tmp
            j -= 1
    return out^


def _query(name: String) raises -> String:
    """The case's SELECT: its file without the comment lines."""
    var text = read_data("sql/" + name + ".sql")
    var out = String("")
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith("--") or l == "":
            continue
        out += l + " "
    return out^


def _compare(batch: RecordBatch, tsv: String) raises -> String:
    """"" when `batch` equals the DuckDB answer `tsv` by value and in row
    order, else the report."""
    var actual = render_batch(batch, CanonPolicy.total())
    try:
        var expected = duckdb_tsv_canon(parse_duckdb_tsv(tsv), actual)
        var report = compare_canon(expected, actual)
        if not report.ok():
            return String(report)
        return String("")
    except e:
        return String(e)


def _run_cases(workers: Int) raises -> Int:
    var ctx = _context(workers)
    var names = _case_names()
    var problems = String("")
    var ran = 0
    var refused = 0
    for i in range(len(names)):
        ref name = names[i]
        var out = run_sql(ctx, _query(name))
        if _is_refused(name):
            if not out.refusal or _REFUSED_TOKEN not in out.refusal.value().reason:
                problems += "\n  " + name + ": expected a refusal naming " + _REFUSED_TOKEN
            elif out.refusal.value().step != String(STEP_BIND):
                problems += "\n  " + name + ": refused at " + out.refusal.value().step
            else:
                refused += 1
            continue
        if out.refusal:
            problems += (
                "\n  " + name + ": refused at " + out.refusal.value().step
                + ": " + out.refusal.value().reason
            )
            continue
        if len(out.batches) != 1:
            problems += "\n  " + name + ": " + String(len(out.batches)) + " batches"
            continue
        var diff = _compare(out.batches[0], read_data("duckdb/" + name + ".tsv"))
        if diff != "":
            problems += "\n  " + name + " on " + String(workers) + " workers: " + diff
            continue
        ran += 1
    assert_equal(problems, String(""))
    assert_equal(refused, len(_refused()))
    return ran


def test_cases_equal_duckdb_on_one_worker() raises:
    assert_equal(_run_cases(1), _STAGED_CASES - len(_refused()))


def test_cases_equal_duckdb_on_three_workers() raises:
    assert_equal(_run_cases(3), _STAGED_CASES - len(_refused()))


def test_cases_equal_duckdb_on_seven_workers() raises:
    assert_equal(_run_cases(7), _STAGED_CASES - len(_refused()))


def test_every_case_is_run() raises:
    var names = _case_names()
    assert_equal(len(names), _STAGED_CASES)
    var kinds = List[String]()
    kinds.append("limit_offset")
    kinds.append("offset_only")
    kinds.append("fetch_first_3")
    kinds.append("topn_a_k_nulls_first_offset")
    kinds.append("topn_d_desc_nulls_first_cut_in_nan")
    kinds.append("topn_u_x_k_deep_offset")
    for i in range(len(kinds)):
        var found = False
        for j in range(len(names)):
            if names[j] == kinds[i]:
                found = True
        assert_true(found, kinds[i] + " is not staged")
    for i in range(len(names)):
        var q = _query(names[i])
        var upper = q.upper()
        assert_true(
            "LIMIT" in upper or "OFFSET" in upper or "FETCH" in upper,
            names[i] + " has no LIMIT or OFFSET",
        )
        assert_true(read_data("duckdb/" + names[i] + ".tsv").byte_length() > 0, names[i])


def test_the_comparison_is_not_vacuous() raises:
    var ctx = _context(3)
    var out = run_sql(
        ctx, "SELECT a FROM t ORDER BY a ASC NULLS LAST LIMIT 5"
    )
    assert_true(not out.refusal)
    assert_equal(len(out.batches), 1)
    ref batch = out.batches[0]
    assert_equal(_compare(batch, "a\n-5\n0\n1\n1\n2\n"), String(""))
    assert_true(_compare(batch, "a\n-5\n0\n1\n2\n1\n") != "", "other order")
    assert_true(_compare(batch, "a\n-5\n0\n1\n1\n3\n") != "", "other value")
    assert_true(_compare(batch, "a\n-5\n0\n1\n1\n") != "", "a row missing")
    assert_true(_compare(batch, "a\n-5\n0\n1\n1\n2\n2\n") != "", "a row added")


def test_a_negative_limit_is_refused_before_it_runs() raises:
    var ctx = _context(1)
    var out = run_sql(ctx, "SELECT a FROM t ORDER BY a LIMIT -1")
    assert_true(Bool(out.refusal))
    assert_equal(out.refusal.value().step, String(STEP_PARSE))
    assert_true(out.refusal.value().reason != "", "a reason")
    assert_equal(len(out.batches), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
