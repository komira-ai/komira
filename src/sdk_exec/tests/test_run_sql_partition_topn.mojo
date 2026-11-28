# =============================================================================
# test_run_sql_partition_topn: the top N rows per group, `WHERE rn <= N` over
# ROW_NUMBER or RANK, through run_sql equal the pinned DuckDB
# =============================================================================
#
# Covers: run_sql over a Parquet table DuckDB wrote (the
# :partition_topn_oracle action in BUCK) answers what the pinned DuckDB
# answers for each case of tests/partition_topn/cases.sql, on one and three
# workers. The optimizer fuses `rn <= K` and `rn < K` over a window that holds
# one ROW_NUMBER or RANK into a partition top-n (`optimizer_partition_topn`),
# which lowers to a SINK_PARTITION_TOPN segment; `rn <= 0`, `rn < 1`,
# `BETWEEN`, `IN` and `=` are not fused and run as the window and a filter.
#
# DuckDB writes top.parquet (tests/partition_topn/data.sql) and answers each
# case; run_sql runs the same text over the same file and its batch must equal
# DuckDB's rows, each column of the type the table or the window gives it.
#
#   test_row_number_at_most_n_equals_duckdb   rn <= 2 per group of a VARCHAR
#                                             key with a NULL group and a group
#                                             of one row, ties of the first
#                                             ORDER BY key broken by the second;
#                                             rn < 3 with rn in the output;
#                                             one BIGINT key and one order key;
#                                             no PARTITION BY; a K past every
#                                             group's size; a WHERE under the
#                                             window and an ORDER BY over it,
#                                             in DuckDB's order.
#   test_rank_at_most_n_keeps_every_tie_as_duckdb_does
#                                             RANK() <= 2 with 30 tied rows per
#                                             group (VARCHAR key and a BIGINT
#                                             key, past the kernel's heap of
#                                             k + 16); rk < 3 over a DOUBLE key
#                                             with an INTEGER partition key that
#                                             holds NULL; every row ranked over
#                                             an order key with NULLs, which
#                                             rank last in DESC.
#   test_at_most_zero_keeps_no_row_as_duckdb_does
#                                             rn <= 0 and rk < 1: no row, the
#                                             query's columns.
#   test_every_case_is_run                    each case of cases.sql belongs to
#                                             one of the tests above.
#   test_at_most_n_is_cut_as_a_partition_top_n
#                                             the cases fused into a partition
#                                             top-n lower to a
#                                             SINK_PARTITION_TOPN segment, and
#                                             the ones that keep no row do not
#                                             (they are not fused).
#   test_at_most_n_equals_the_forms_that_are_not_fused
#                                             rn <= 2 against rn BETWEEN 1 AND
#                                             2 and rn IN (1, 2), rn <= 1
#                                             against rn = 1, rk <= K against
#                                             rk BETWEEN 1 AND K, over a VARCHAR
#                                             key and over one BIGINT partition
#                                             and order key: the same rows on
#                                             one and three workers, ROW_NUMBER
#                                             ordered by a key with ties too
#                                             (the same tied rows are kept).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from physical_plan.physical_plan import SINK_PARTITION_TOPN
from runtime_paths import data_path, read_data
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_lower import lower_for_context
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_plan import optimize_for_run
from sdk_exec.engine_sql import run_sql
from sql.sql_frontend import plan_from_sql


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


def _query(name: String) raises -> String:
    """The query of case `name`, reading the file the oracle wrote."""
    var cases = _cases()
    for i in range(len(cases)):
        if cases[i].name == name:
            return _local(cases[i].query)
    raise Error("cases.sql holds no case " + name)


def _local(query: String) raises -> String:
    """`query` reading the file the oracle wrote."""
    return query.replace(
        "'top.parquet'", "'" + data_path("top.parquet") + "'"
    )


def _column_type(name: String) -> ArrowType:
    """The type a column of a case has: the table's, BIGINT for a ROW_NUMBER
    or RANK, NULL for a name this test does not know."""
    if name == "id" or name == "q" or name == "o" or name == "k":
        return ArrowType.INT64
    if name == "rn" or name == "rk":
        return ArrowType.INT64
    if name == "g":
        return ArrowType.STRING
    if name == "p":
        return ArrowType.INT32
    if name == "x":
        return ArrowType.FLOAT64
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
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_sql(ctx, _query(name))
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


def _row_number() -> List[String]:
    var out = List[String]()
    out.append("rn_le_2")
    out.append("rn_lt_3_kept")
    out.append("rn_one_int_key")
    out.append("rn_no_partition")
    out.append("rn_k_past_every_group")
    return out^


def _ordered() -> List[String]:
    var out = List[String]()
    out.append("rn_over_where_ordered")
    return out^


def _rank() -> List[String]:
    var out = List[String]()
    out.append("rank_le_2_ties")
    out.append("rank_ties_one_int_key")
    out.append("rank_lt_3_null_partition")
    out.append("rank_null_order_keys_last")
    return out^


def _no_row() -> List[String]:
    var out = List[String]()
    out.append("rn_le_0")
    out.append("rank_lt_1")
    return out^


def test_row_number_at_most_n_equals_duckdb() raises:
    _check_all(_row_number())
    _check_all(_ordered(), total=True)


def test_rank_at_most_n_keeps_every_tie_as_duckdb_does() raises:
    _check_all(_rank())


def test_at_most_zero_keeps_no_row_as_duckdb_does() raises:
    _check_all(_no_row())


def test_every_case_is_run() raises:
    var known = _row_number()
    known.extend(_ordered())
    known.extend(_rank())
    known.extend(_no_row())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


def _cuts_a_partition_top_n(query: String) raises -> Bool:
    """True when the plan `run_sql` lowers for `query` holds a
    SINK_PARTITION_TOPN segment."""
    var ctx = EngineContext(EngineOptions(worker_count=1))
    ctx.begin_query()
    var plan = plan_from_sql(query, ctx.catalog, ctx.footers)
    var lowered = lower_for_context(optimize_for_run(plan^), ctx)
    for i in range(len(lowered.segments)):
        if lowered.segments[i].sink_kind == SINK_PARTITION_TOPN:
            return True
    return False


def test_at_most_n_is_cut_as_a_partition_top_n() raises:
    var fused = _row_number()
    fused.extend(_ordered())
    fused.extend(_rank())
    for i in range(len(fused)):
        assert_true(
            _cuts_a_partition_top_n(_query(fused[i])),
            fused[i] + " is cut as a partition top-n",
        )
    var none = _no_row()
    for i in range(len(none)):
        assert_false(
            _cuts_a_partition_top_n(_query(none[i])),
            none[i] + " is not fused",
        )


def _ranked(fn_order: String, keep: String) -> String:
    """`SELECT id, g, o` of the rows of top.parquet whose `fn_order` window
    column `w` passes `keep`."""
    return (
        "SELECT id, g, o FROM (SELECT id, g, o, "
        + fn_order
        + " AS w FROM read_parquet('top.parquet')) ranked WHERE "
        + keep
    )


def _same_rows(fused: String, unfused: String) raises:
    """`fused`, cut as a partition top-n, and `unfused`, which is not, give
    the same rows on one and on three workers."""
    assert_true(_cuts_a_partition_top_n(_local(fused)), fused + " is fused")
    assert_false(
        _cuts_a_partition_top_n(_local(unfused)), unfused + " is not fused"
    )
    for workers in range(1, 4, 2):
        var label = fused + " against " + unfused + " on " + String(workers)
        var ctx = EngineContext(EngineOptions(worker_count=workers))
        var a = run_sql(ctx, _local(fused))
        var b = run_sql(ctx, _local(unfused))
        assert_false(Bool(a.refusal), label + ": the fused form runs")
        assert_false(Bool(b.refusal), label + ": the unfused form runs")
        var report = compare_canon(
            render_batch(b.batches[0], CanonPolicy.unordered()),
            render_batch(a.batches[0], CanonPolicy.unordered()),
        )
        assert_true(report.ok(), label + ": " + String(report))


def test_at_most_n_equals_the_forms_that_are_not_fused() raises:
    # Ordered by a key with ties: which tied rows are kept is the engine's
    # choice, and both forms make the same one.
    var rn_tied = String("row_number() OVER (PARTITION BY g ORDER BY o DESC)")
    _same_rows(_ranked(rn_tied, "w <= 2"), _ranked(rn_tied, "w BETWEEN 1 AND 2"))
    _same_rows(_ranked(rn_tied, "w <= 2"), _ranked(rn_tied, "w IN (1, 2)"))
    _same_rows(_ranked(rn_tied, "w <= 1"), _ranked(rn_tied, "w = 1"))
    # One BIGINT partition key and one BIGINT order key with 30 ties a value.
    var rn_int = String("row_number() OVER (PARTITION BY q ORDER BY k)")
    _same_rows(_ranked(rn_int, "w < 4"), _ranked(rn_int, "w BETWEEN 1 AND 3"))
    var rn_two = String("row_number() OVER (PARTITION BY q ORDER BY k, id DESC)")
    _same_rows(_ranked(rn_two, "w <= 3"), _ranked(rn_two, "w IN (1, 2, 3)"))
    var rk = String("rank() OVER (PARTITION BY g ORDER BY o DESC)")
    _same_rows(_ranked(rk, "w <= 2"), _ranked(rk, "w BETWEEN 1 AND 2"))
    var rk_int = String("rank() OVER (PARTITION BY q ORDER BY k)")
    _same_rows(_ranked(rk_int, "w <= 31"), _ranked(rk_int, "w BETWEEN 1 AND 31"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
