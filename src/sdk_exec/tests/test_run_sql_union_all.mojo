# =============================================================================
# run_sql: UNION ALL over Parquet tables, with DuckDB's type widening
# =============================================================================
#
# Covers: UNION ALL over six small Parquet tables equals DuckDB for the same
# SQL: INTEGER with BIGINT is BIGINT, INTEGER with FLOAT is FLOAT, BIGINT or
# FLOAT or a DECIMAL with DOUBLE is DOUBLE, DECIMAL(12,2) with DECIMAL(10,4) is
# DECIMAL(14,4) and with INTEGER DECIMAL(12,2) (branches widened to DuckDB's
# common type), values exact and NULLs kept; three branches with a FROM-less
# one (a literal branch), count(*), sum, aggregates, GROUP BY and WHERE over
# `FROM (... UNION ALL ...) u`, an empty branch, the first branch's names,
# LIMIT, integer literal branches (INTEGER, or BIGINT when one needs it); a
# VARCHAR with an INTEGER (no common type) is refused at bind and an ORDER BY
# before UNION ALL at parse; and an ORDER BY with no union (the sort sinks'
# data reaches the builder).
#
# Six one-column Parquet tables are written here and registered on a context:
#
#   t_i32 (a INTEGER, s VARCHAR)  (1, 'x'), (NULL, 'y'), (3, 'z')
#   t_i64 (b BIGINT, s VARCHAR)   (5000000000, 'p'), (-7, 'q')
#   t_f32 (c FLOAT)               1.5, 2.25
#   t_f64 (d DOUBLE)              0.1, NULL
#   t_d2  (p DECIMAL(12,2))       123.45, -0.01
#   t_d4  (q DECIMAL(10,4))       1.2345, NULL
#
# Each test runs one SQL text with run_sql and compares the result with what
# DuckDB answers for the same SQL over the same rows: the column's name, its
# Arrow type (DuckDB's type: INTEGER is INT32, BIGINT INT64, FLOAT FLOAT32,
# DOUBLE FLOAT64, DECIMAL(p,s) DECIMAL128(p, s)), and the values in order
# (an ORDER BY in the query, or the branches' order, which is the order the
# concatenation keeps). The conformance corpus (cases union_all/ under
# src/tests/conformance/komira_sql_conformance) records DuckDB's answers for
# the same shapes over its own tables, checked by the pinned DuckDB;
# DECIMAL(12,2) with INTEGER is checked only here.
#
# What each test proves:
#   * test_int_and_bigint_widen_to_bigint: INTEGER with BIGINT is BIGINT, the
#     INTEGER values exact and the NULL kept, ordered NULLS LAST.
#   * test_int_and_float_widen_to_float: INTEGER with FLOAT is FLOAT, in
#     branch order (the sort sink takes no FLOAT32 key).
#   * test_bigint_and_double_widen_to_double_in_branch_order: BIGINT with
#     DOUBLE is DOUBLE; without ORDER BY the rows come branch by branch.
#   * test_float_and_double_widen_to_double: FLOAT with DOUBLE is DOUBLE.
#   * test_two_decimals_widen_to_the_wider_digits_and_scale: DECIMAL(12,2) with
#     DECIMAL(10,4) is DECIMAL(14,4), each value rescaled exactly, in branch
#     order (the sort sink takes no DECIMAL key).
#   * test_decimal_and_integer_widen_to_the_decimal: DECIMAL(12,2) with INTEGER
#     is DECIMAL(12,2) (an INTEGER needs ten digits before the point).
#   * test_decimal_and_double_widen_to_double: DECIMAL with DOUBLE is DOUBLE.
#   * test_three_branches_and_a_literal_branch: three branches, the last a
#     FROM-less SELECT of two bare literals (both named `literal`), ordered;
#     the result keeps the first branch's names.
#   * test_aggregates_over_a_derived_union: count(*) and sum over
#     `FROM (... UNION ALL ...) u`.
#   * test_a_grouped_count_over_a_union_of_three: GROUP BY over three branches,
#     one table read twice.
#   * test_a_filter_above_a_union: WHERE over a derived union.
#   * test_an_empty_branch_adds_no_rows: a branch whose WHERE keeps no row.
#   * test_the_first_branch_names_the_columns: `a AS lead` with `b AS other`
#     is a column named `lead`.
#   * test_integer_literal_branches_are_integer_unless_one_is_bigint:
#     `SELECT 1 UNION ALL SELECT 2` is INTEGER, with 5000000000 it is BIGINT.
#   * test_a_limit_over_a_union_keeps_that_many_rows: LIMIT 2 with no ORDER BY
#     keeps two rows of the union.
#   * test_an_order_by_runs_through_run_sql: `ORDER BY` with no union, both
#     directions. Catches run_lowered_plan not handing the builder the sort
#     sinks' data (every ORDER BY was refused at execute).
#   * test_unions_with_no_common_type_or_misplaced_clauses_are_refused: a
#     VARCHAR with a DOUBLE is refused at bind naming the column; an ORDER BY
#     before UNION ALL is refused at parse; the context runs the next query.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.decimal_array import Decimal128Array
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_PARSE, run_sql


# =============================================================================
# The tables
# =============================================================================


def _write(name: String, var batch: RecordBatch) raises -> String:
    var path = test_tmpdir() + "/sql_union_all_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(batch)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _strings(a: String, b: String, c: String = "") raises -> Column[HeapRegion]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    if c != "":
        out.append(c)
    return Column.from_string(StringArray.from_strings(out))


def _t_i32() raises -> RecordBatch:
    var a = ColumnBuilder[DType.int32].with_capacity(3)
    a.append(Int32(1))
    a.append_null()
    a.append(Int32(3))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.INT32, True))
    rb.add_column(a^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(_strings("x", "y", "z"))
    return rb.build(sb.build())


def _t_i64() raises -> RecordBatch:
    var b = ColumnBuilder[DType.int64].with_capacity(2)
    b.append(Int64(5000000000))
    b.append(Int64(-7))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("b", ArrowType.INT64, False))
    rb.add_column(b^.materialize())
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(_strings("p", "q"))
    return rb.build(sb.build())


def _t_f32() raises -> RecordBatch:
    var c = ColumnBuilder[DType.float32].with_capacity(2)
    c.append(Float32(1.5))
    c.append(Float32(2.25))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("c", ArrowType.FLOAT32, False))
    rb.add_column(c^.materialize())
    return rb.build(sb.build())


def _t_f64() raises -> RecordBatch:
    var d = ColumnBuilder[DType.float64].with_capacity(2)
    d.append(Float64(0.1))
    d.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(d^.materialize())
    return rb.build(sb.build())


def _i128(v: Int) -> SIMD[DType.int128, 1]:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _decimal_table(
    name: String, precision: Int, scale: Int, first: Int, second: Int, second_null: Bool
) raises -> RecordBatch:
    """One nullable DECIMAL(precision, scale) column of two rows, given as
    unscaled integers."""
    var col = Decimal128Array.allocate_nullable(2, precision, scale)
    col.set_i128(0, _i128(first))
    if second_null:
        col.set_null(1)
    else:
        col.set_i128(1, _i128(second))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128(name, precision, scale, True))
    rb.add_column(Column.from_decimal128(col^))
    return rb.build(sb.build())


def _context() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "t_i32", _write("i32", _t_i32()))
    register_parquet(ctx, "t_i64", _write("i64", _t_i64()))
    register_parquet(ctx, "t_f32", _write("f32", _t_f32()))
    register_parquet(ctx, "t_f64", _write("f64", _t_f64()))
    # 123.45 and -0.01 as DECIMAL(12,2); 1.2345 and NULL as DECIMAL(10,4).
    register_parquet(ctx, "t_d2", _write("d2", _decimal_table("p", 12, 2, 12345, -1, False)))
    register_parquet(ctx, "t_d4", _write("d4", _decimal_table("q", 10, 4, 12345, 0, True)))
    return ctx^


# =============================================================================
# Reading a result
# =============================================================================


def _run(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def _expect_column(
    ref batch: RecordBatch, col: Int, name: String, at: ArrowType
) raises:
    assert_equal(batch.schema.field_name(col), name)
    assert_true(
        batch.schema.field_arrow_type(col) == at,
        "column " + name + " is " + String(batch.schema.field_arrow_type(col)),
    )


def _expect_i64(ref batch: RecordBatch, col: Int, want: List[Int], null_at: Int = -1) raises:
    assert_equal(batch.num_rows(), len(want))
    var values = batch.column_at(col).as_primitive[DType.int64]()
    for r in range(len(want)):
        if r == null_at:
            assert_true(batch.column_at(col).is_null_at(r), "row " + String(r) + " is not NULL")
            continue
        assert_false(batch.column_at(col).is_null_at(r), "row " + String(r) + " is NULL")
        assert_equal(Int(values.get(r)), want[r], "row " + String(r))


def _expect_i32(ref batch: RecordBatch, col: Int, want: List[Int]) raises:
    assert_equal(batch.num_rows(), len(want))
    var values = batch.column_at(col).as_primitive[DType.int32]()
    for r in range(len(want)):
        assert_equal(Int(values.get(r)), want[r], "row " + String(r))


def _expect_f64(ref batch: RecordBatch, col: Int, want: List[Float64], null_at: Int = -1) raises:
    assert_equal(batch.num_rows(), len(want))
    var values = batch.column_at(col).as_primitive[DType.float64]()
    for r in range(len(want)):
        if r == null_at:
            assert_true(batch.column_at(col).is_null_at(r), "row " + String(r) + " is not NULL")
            continue
        assert_false(batch.column_at(col).is_null_at(r), "row " + String(r) + " is NULL")
        assert_equal(values.get(r), want[r], "row " + String(r))


def _expect_decimal(
    ref batch: RecordBatch, col: Int, precision: Int, scale: Int,
    want: List[Int], null_at: Int = -1,
) raises:
    """Column `col` is DECIMAL128(precision, scale) holding the unscaled
    `want` (row `null_at` NULL)."""
    assert_true(batch.schema.field_arrow_type(col) == ArrowType.DECIMAL128)
    assert_equal(batch.schema.field_decimal_precision(col), precision)
    assert_equal(batch.schema.field_decimal_scale(col), scale)
    assert_equal(batch.num_rows(), len(want))
    var values = batch.column_at(col).as_decimal128()
    for r in range(len(want)):
        if r == null_at:
            assert_true(batch.column_at(col).is_null_at(r), "row " + String(r) + " is not NULL")
            continue
        assert_false(batch.column_at(col).is_null_at(r), "row " + String(r) + " is NULL")
        assert_true(values.get_i128(r) == _i128(want[r]), "row " + String(r))


# =============================================================================
# Widening
# =============================================================================


def test_int_and_bigint_widen_to_bigint() raises:
    var ctx = _context()
    var batch = _run(ctx, "select a from t_i32 union all select b from t_i64 order by a")
    _expect_column(batch, 0, "a", ArrowType.INT64)
    _expect_i64(batch, 0, [-7, 1, 3, 5000000000, 0], null_at=4)


def test_int_and_float_widen_to_float() raises:
    var ctx = _context()
    # No ORDER BY: the sort sink takes no FLOAT32 key; the rows come branch
    # by branch.
    var batch = _run(ctx, "select a from t_i32 union all select c from t_f32")
    _expect_column(batch, 0, "a", ArrowType.FLOAT32)
    assert_equal(batch.num_rows(), 5)
    var values = batch.column_at(0).as_primitive[DType.float32]()
    assert_equal(values.get(0), Float32(1.0))
    assert_true(batch.column_at(0).is_null_at(1))
    assert_equal(values.get(2), Float32(3.0))
    assert_equal(values.get(3), Float32(1.5))
    assert_equal(values.get(4), Float32(2.25))


def test_bigint_and_double_widen_to_double_in_branch_order() raises:
    var ctx = _context()
    var batch = _run(ctx, "select b from t_i64 union all select d from t_f64")
    _expect_column(batch, 0, "b", ArrowType.FLOAT64)
    _expect_f64(batch, 0, [5000000000.0, -7.0, 0.1, 0.0], null_at=3)


def test_float_and_double_widen_to_double() raises:
    var ctx = _context()
    var batch = _run(ctx, "select c as x from t_f32 union all select d from t_f64 order by x")
    _expect_column(batch, 0, "x", ArrowType.FLOAT64)
    _expect_f64(batch, 0, [0.1, 1.5, 2.25, 0.0], null_at=3)


def test_two_decimals_widen_to_the_wider_digits_and_scale() raises:
    var ctx = _context()
    # No ORDER BY: the sort sink takes no DECIMAL key; the rows come branch
    # by branch.
    var batch = _run(ctx, "select p from t_d2 union all select q from t_d4")
    assert_equal(batch.schema.field_name(0), "p")
    # 123.4500, -0.0100, 1.2345, NULL as DECIMAL(14,4).
    _expect_decimal(batch, 0, 14, 4, [1234500, -100, 12345, 0], null_at=3)


def test_decimal_and_integer_widen_to_the_decimal() raises:
    var ctx = _context()
    var batch = _run(ctx, "select p from t_d2 union all select a from t_i32")
    # 123.45, -0.01, 1.00, NULL, 3.00 as DECIMAL(12,2), branch by branch.
    _expect_decimal(batch, 0, 12, 2, [12345, -1, 100, 0, 300], null_at=3)


def test_decimal_and_double_widen_to_double() raises:
    var ctx = _context()
    var batch = _run(ctx, "select p from t_d2 union all select d from t_f64")
    _expect_column(batch, 0, "p", ArrowType.FLOAT64)
    _expect_f64(batch, 0, [123.45, -0.01, 0.1, 0.0], null_at=3)


# =============================================================================
# Shapes
# =============================================================================


def test_three_branches_and_a_literal_branch() raises:
    var ctx = _context()
    var batch = _run(
        ctx,
        "select a as n, s from t_i32 union all select b, s from t_i64"
        " union all select 9, 'w' order by n",
    )
    assert_equal(batch.num_columns(), 2)
    _expect_column(batch, 0, "n", ArrowType.INT64)
    _expect_column(batch, 1, "s", ArrowType.STRING)
    _expect_i64(batch, 0, [-7, 1, 3, 9, 5000000000, 0], null_at=5)
    var s = batch.column_at(1).as_string()
    assert_equal(s.get(0), "q")
    assert_equal(s.get(3), "w")
    assert_equal(s.get(4), "p")
    assert_equal(s.get(5), "y")


def test_aggregates_over_a_derived_union() raises:
    var ctx = _context()
    var batch = _run(
        ctx,
        "select count(*) as c, sum(n) as total from"
        " (select a as n from t_i32 union all select b from t_i64) u",
    )
    assert_equal(batch.num_rows(), 1)
    _expect_column(batch, 0, "c", ArrowType.INT64)
    _expect_i64(batch, 0, [5])
    # DuckDB's HUGEINT sum is this engine's DECIMAL(38, 0).
    _expect_decimal(batch, 1, 38, 0, [4999999997])


def test_a_grouped_count_over_a_union_of_three() raises:
    var ctx = _context()
    var batch = _run(
        ctx,
        "select s, count(*) as n from (select s from t_i32 union all"
        " select s from t_i64 union all select s from t_i32) u"
        " group by s order by s",
    )
    assert_equal(batch.num_rows(), 5)
    var s = batch.column_at(0).as_string()
    assert_equal(s.get(0), "p")
    assert_equal(s.get(1), "q")
    assert_equal(s.get(2), "x")
    assert_equal(s.get(3), "y")
    assert_equal(s.get(4), "z")
    _expect_i64(batch, 1, [1, 1, 2, 2, 2])


def test_a_filter_above_a_union() raises:
    var ctx = _context()
    var batch = _run(
        ctx,
        "select n from (select a as n from t_i32 union all select b from t_i64) u"
        " where n > 2 order by n",
    )
    _expect_i64(batch, 0, [3, 5000000000])


def test_an_empty_branch_adds_no_rows() raises:
    var ctx = _context()
    var batch = _run(
        ctx, "select a from t_i32 where a > 100 union all select b from t_i64"
    )
    _expect_column(batch, 0, "a", ArrowType.INT64)
    _expect_i64(batch, 0, [5000000000, -7])


def test_the_first_branch_names_the_columns() raises:
    var ctx = _context()
    var batch = _run(
        ctx, "select a as lead from t_i32 union all select b as other from t_i64"
    )
    assert_equal(batch.num_columns(), 1)
    _expect_column(batch, 0, "lead", ArrowType.INT64)
    _expect_i64(batch, 0, [1, 0, 3, 5000000000, -7], null_at=1)


def test_integer_literal_branches_are_integer_unless_one_is_bigint() raises:
    var ctx = _context()
    var small = _run(ctx, "select 1 as n union all select 2")
    _expect_column(small, 0, "n", ArrowType.INT32)
    _expect_i32(small, 0, [1, 2])
    var wide = _run(ctx, "select 1 as n union all select 5000000000")
    _expect_column(wide, 0, "n", ArrowType.INT64)
    _expect_i64(wide, 0, [1, 5000000000])


def test_a_limit_over_a_union_keeps_that_many_rows() raises:
    var ctx = _context()
    var batch = _run(ctx, "select a from t_i32 union all select b from t_i64 limit 2")
    assert_equal(batch.num_rows(), 2)
    _expect_column(batch, 0, "a", ArrowType.INT64)


def test_an_order_by_runs_through_run_sql() raises:
    # The sort sink's data reaches the builder (`run_lowered_plan` hands it
    # `params.sort`), with no union in the plan, descending and ascending.
    var ctx = _context()
    _expect_i64(_run(ctx, "select b from t_i64 order by b"), 0, [-7, 5000000000])
    _expect_i64(
        _run(ctx, "select b from t_i64 order by b desc"), 0, [5000000000, -7]
    )


def test_unions_with_no_common_type_or_misplaced_clauses_are_refused() raises:
    var ctx = _context()
    var mixed = run_sql(ctx, "select s from t_i32 union all select d from t_f64")
    assert_true(Bool(mixed.refusal))
    assert_equal(mixed.refusal.value().step, String(STEP_BIND))
    assert_true(
        "UNION ALL column 1" in mixed.refusal.value().reason,
        mixed.refusal.value().reason,
    )
    var early = run_sql(
        ctx, "select a from t_i32 order by a union all select b from t_i64"
    )
    assert_true(Bool(early.refusal))
    assert_equal(early.refusal.value().step, String(STEP_PARSE))
    assert_true(
        "ORDER BY" in early.refusal.value().reason, early.refusal.value().reason
    )
    # The context runs the next query.
    var batch = _run(ctx, "select b from t_i64 union all select b from t_i64")
    _expect_i64(batch, 0, [5000000000, -7, 5000000000, -7])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
