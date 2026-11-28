# =============================================================================
# run_sql: unnest(list) in the SELECT list, run to rows
# =============================================================================
#
# The input is a derived table of FROM-less rows, so no file is read; the
# lists come from string_split. The answers are DuckDB v1.5.3's for the same
# SQL: one row per element, the other items repeated, and no row for a NULL
# list.
#
# What each test proves:
#   * test_unnest_gives_one_row_per_element_and_repeats_the_id: rows with a
#     two-element, a one-element and a three-element list give 2 + 1 + 3 rows,
#     each carrying its row's id, in id then element order.
#   * test_a_null_list_gives_no_row: a NULL string splits to a NULL list,
#     which gives no row, while the rows beside it keep theirs; a query whose
#     only list is NULL answers no rows.
#   * test_a_from_less_unnest_runs: `SELECT unnest(string_split('a,b', ','))`
#     is two rows named `unnest(string_split('a,b', ','))`.
#   Together they run the lowering inputs' walk through an Unnest
#   (`engine_lower._collect`): the scan below it must be counted for the plan
#   to lower.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def _rows(sql: String) raises -> List[String]:
    """`<id>|<element>` per row of every result batch, in result order (the
    queries order their rows). The id is the first column, the element the
    second."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    var rows = List[String]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        assert_equal(batch.num_columns(), 2)
        for r in range(batch.num_rows()):
            var id: Int64
            if batch.schema.field_arrow_type(0) == ArrowType.INT32:
                id = Int64(batch.column_at(0).as_primitive[DType.int32]().get(r))
            else:
                id = batch.column_at(0).as_primitive[DType.int64]().get(r)
            rows.append(
                String(id) + "|" + String(batch.column_at(1).as_string().get(r))
            )
    return rows^


comptime _INPUT = (
    "(SELECT 1 AS id, 'a,b' AS s UNION ALL SELECT 2, 'c'"
    " UNION ALL SELECT 3, 'd,e,f' UNION ALL SELECT 4, CAST(NULL AS VARCHAR)) t"
)


def _joined(rows: List[String]) -> String:
    var out = String("")
    for i in range(len(rows)):
        if i > 0:
            out += " "
        out += rows[i]
    return out^


def test_unnest_gives_one_row_per_element_and_repeats_the_id() raises:
    var rows = _rows(
        "SELECT id, unnest(string_split(s, ',')) AS x FROM " + _INPUT
        + " WHERE id < 4 ORDER BY id, x"
    )
    assert_equal(_joined(rows), "1|a 1|b 2|c 3|d 3|e 3|f")


def test_a_null_list_gives_no_row() raises:
    var rows = _rows(
        "SELECT id, unnest(string_split(s, ',')) AS x FROM " + _INPUT
        + " ORDER BY id, x"
    )
    assert_equal(_joined(rows), "1|a 1|b 2|c 3|d 3|e 3|f")
    var none = _rows(
        "SELECT id, unnest(string_split(s, ',')) AS x FROM " + _INPUT
        + " WHERE id = 4"
    )
    assert_equal(len(none), 0)


def test_a_from_less_unnest_runs() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(ctx, "SELECT unnest(string_split('a,b', ','))")
    assert_true(not out.refusal)
    var n = 0
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        assert_equal(
            batch.schema.field_name(0), "unnest(string_split('a,b', ','))"
        )
        for r in range(batch.num_rows()):
            assert_equal(
                String(batch.column_at(0).as_string().get(r)),
                "a" if n == 0 else "b",
            )
            n += 1
    assert_equal(n, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
