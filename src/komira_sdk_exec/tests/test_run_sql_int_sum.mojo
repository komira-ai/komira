# =============================================================================
# run_sql: `sum()` over an integer column is DECIMAL(38, 0) and exact
# =============================================================================
#
# DuckDB types the sum of an integer as HUGEINT, which cannot overflow; this
# engine answers DECIMAL(38, 0), Arrow's one type that holds every HUGEINT
# total. Each test writes a Parquet table of INT64 / INT32 columns (several row
# groups, so several morsels and several workers' partial sums), runs SQL text
# through `run_sql` on a context of three workers, and compares the answer with
# an oracle computed HERE in 128-bit integers from the same values, never from
# the engine.
#
# What each test proves, and the defect it would catch:
#   * test_the_sum_of_an_int32_and_an_int64_is_declared_decimal_38_0: the result
#     schema's sum columns are nullable DECIMAL128(38, 0), for INT32 and INT64.
#     Catches an integer sum still declared INT64.
#   * test_many_rows_of_int64_max_sum_exactly: 3000 rows of 2^63 - 1 in 8 row
#     groups sum to 3000 * (2^63 - 1), ungrouped and grouped by key.
#     Catches a 64-bit accumulator or a 64-bit narrowing at emit (which refuse
#     or wrap), in the fold or in the merge of the workers' partials.
#   * test_many_rows_of_int64_min_sum_exactly: the same for 2^63 negated.
#   * test_partials_that_each_pass_int64_merge_exactly: row groups of two
#     2^63 - 1 values, so every partial is 2^64 - 2, past INT64, and the merge
#     is exact. Catches a merge that narrows a partial.
#   * test_max_max_min_min_is_minus_two: {MAX, MAX, MIN, MIN} in two row groups
#     (one partial 2^64 - 2, the other -2^64) is -2, ungrouped and under one
#     key. Catches a sum that refuses where an answer exists.
#   * test_groups_are_summed_separately_past_int64: two keys, each with its own
#     total past INT64, one negative.
#   * test_an_empty_sum_and_an_all_null_sum_are_null: a filter that keeps no
#     row gives one NULL row ungrouped and no row grouped; an all-NULL column
#     gives NULL ungrouped, NULL for an all-NULL group beside a group with a
#     value, and the group of the NULL key is summed on its own.
#   * test_expressions_and_case_over_integers_sum_exactly: sum(i + 1) and
#     sum(CASE ...) over the table equal the oracle and are DECIMAL(38, 0).
#   * test_a_boolean_sum_counts_the_true_rows_as_decimal_38_0: sum(i > 10) is the
#     number of TRUE rows, as DECIMAL(38, 0) (DuckDB's HUGEINT).
#   * test_expressions_above_the_sum_answer_like_duckdb: sum + 1 and sum * 2 are
#     exact DECIMALs past INT64, sum / count is a DOUBLE and sqrt(sum) runs. Catches a post-
#     aggregate operator that no longer accepts the widened sum.
#   * test_having_and_the_other_aggregates_run_beside_the_sum: HAVING on the
#     sum, and count / min / max / avg beside it, answer the oracle.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import SqlOutcome, run_sql


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=3))


struct _Rows(Movable):
    """The rows of a table t(k INT64, v INT64, i INT32), each column with its
    own NULL flags."""

    var k: List[Int64]
    var k_null: List[Bool]
    var v: List[Int64]
    var v_null: List[Bool]
    var i: List[Int32]
    var i_null: List[Bool]

    def __init__(out self):
        self.k = List[Int64]()
        self.k_null = List[Bool]()
        self.v = List[Int64]()
        self.v_null = List[Bool]()
        self.i = List[Int32]()
        self.i_null = List[Bool]()

    def add(
        mut self,
        k: Int,
        v: Int64,
        i: Int32,
        k_null: Bool = False,
        v_null: Bool = False,
        i_null: Bool = False,
    ):
        self.k.append(Int64(k))
        self.k_null.append(k_null)
        self.v.append(v)
        self.v_null.append(v_null)
        self.i.append(i)
        self.i_null.append(i_null)

    def rows(self) -> Int:
        return len(self.k)


def _batch(ref r: _Rows) raises -> RecordBatch:
    var n = r.rows()
    var k = PrimitiveArray[DType.int64].allocate_nullable(n)
    var v = PrimitiveArray[DType.int64].allocate_nullable(n)
    var i = PrimitiveArray[DType.int32].allocate_nullable(n)
    for x in range(n):
        k.set(x, r.k[x])
        v.set(x, r.v[x])
        i.set(x, r.i[x])
    for x in range(n):
        if r.k_null[x]:
            k._set_null(x)
        if r.v_null[x]:
            v._set_null(x)
        if r.i_null[x]:
            i._set_null(x)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("i", ArrowType.INT32, True))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    rb.add_column(Column.from_primitive[DType.int32](i^))
    return rb.build(sb.build())


def _register(
    mut ctx: EngineContext, name: String, ref r: _Rows, rows_per_group: Int
) raises:
    var path = test_tmpdir() + "/sql_int_sum_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(r), max_rows_per_rg=rows_per_group
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "t_" + name, path)


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


def _expect_decimal_38_0(ref batch: RecordBatch, col: Int) raises:
    assert_true(
        batch.schema.field_arrow_type(col) == ArrowType.DECIMAL128,
        "column " + String(col) + " is not declared DECIMAL128",
    )
    assert_equal(batch.schema.field_decimal_precision(col), 38)
    assert_equal(batch.schema.field_decimal_scale(col), 0)
    assert_true(batch.schema.field_nullable(col), "a sum is nullable")
    ref c = batch.column_at(col)
    assert_equal(c.decimal_precision(), 38)
    assert_equal(c.decimal_scale(), 0)


def _is_null(ref batch: RecordBatch, col: Int, row: Int) -> Bool:
    return batch.column_at(col).is_null_at(row)


def _dec(ref batch: RecordBatch, col: Int, row: Int) raises -> I128:
    assert_false(_is_null(batch, col, row), "the sum is NULL")
    return batch.column_at(col).as_decimal128().get_i128(row)


def _group_row(ref batch: RecordBatch, key: Int, key_is_null: Bool) raises -> Int:
    """The row of the group `key` (or of the NULL key) in a result whose first
    column is the INT64 key."""
    var keys = batch.column_at(0).as_primitive[DType.int64]()
    for r in range(batch.num_rows()):
        if key_is_null:
            if keys.is_null(r):
                return r
        elif not keys.is_null(r) and keys.get(r) == Int64(key):
            return r
    assert_true(False, "no group " + String(key))
    return -1


def _constant(rows: Int, v: Int64, i: Int32, keys: Int) -> _Rows:
    var r = _Rows()
    for x in range(rows):
        r.add(x % keys, v, i)
    return r^


def test_the_sum_of_an_int32_and_an_int64_is_declared_decimal_38_0() raises:
    var ctx = _new_context()
    var r = _Rows()
    for x in range(10):
        r.add(x % 2, Int64(x + 1), Int32(x + 1))
    _register(ctx, "declared", r, 4)
    var batch = _run(ctx, "select sum(i), sum(v) from t_declared")
    assert_equal(batch.num_rows(), 1)
    _expect_decimal_38_0(batch, 0)
    _expect_decimal_38_0(batch, 1)
    assert_true(_dec(batch, 0, 0) == _w(55))
    assert_true(_dec(batch, 1, 0) == _w(55))
    var grouped = _run(ctx, "select k, sum(i), sum(v) from t_declared group by k")
    assert_equal(grouped.num_rows(), 2)
    _expect_decimal_38_0(grouped, 1)
    _expect_decimal_38_0(grouped, 2)
    assert_true(_dec(grouped, 1, _group_row(grouped, 0, False)) == _w(1 + 3 + 5 + 7 + 9))
    assert_true(_dec(grouped, 2, _group_row(grouped, 1, False)) == _w(2 + 4 + 6 + 8 + 10))


def test_many_rows_of_int64_max_sum_exactly() raises:
    var rows = 3000
    var r = _constant(rows, Int64.MAX, Int32.MAX, 3)
    var ctx = _new_context()
    _register(ctx, "max", r, 400)
    var batch = _run(ctx, "select sum(v), sum(i) from t_max")
    _expect_decimal_38_0(batch, 0)
    assert_true(_dec(batch, 0, 0) == _w(rows) * _w(Int(Int64.MAX)))
    assert_true(_dec(batch, 1, 0) == _w(rows) * _w(Int(Int32.MAX)))
    var grouped = _run(ctx, "select k, sum(v) from t_max group by k")
    assert_equal(grouped.num_rows(), 3)
    for key in range(3):
        assert_true(
            _dec(grouped, 1, _group_row(grouped, key, False))
            == _w(rows // 3) * _w(Int(Int64.MAX))
        )


def test_many_rows_of_int64_min_sum_exactly() raises:
    var rows = 3000
    var r = _constant(rows, Int64.MIN, Int32.MIN, 3)
    var ctx = _new_context()
    _register(ctx, "min", r, 400)
    var batch = _run(ctx, "select sum(v), sum(i) from t_min")
    assert_true(_dec(batch, 0, 0) == _w(rows) * _w(Int(Int64.MIN)))
    assert_true(_dec(batch, 1, 0) == _w(rows) * _w(Int(Int32.MIN)))
    var grouped = _run(ctx, "select k, sum(v) from t_min group by k")
    for key in range(3):
        assert_true(
            _dec(grouped, 1, _group_row(grouped, key, False))
            == _w(rows // 3) * _w(Int(Int64.MIN))
        )


def test_partials_that_each_pass_int64_merge_exactly() raises:
    # Row groups of two values: every partial is 2^64 - 2, past INT64.
    var rows = 12
    var r = _constant(rows, Int64.MAX, 0, 1)
    var ctx = _new_context()
    _register(ctx, "partials", r, 2)
    var batch = _run(ctx, "select sum(v) from t_partials")
    assert_true(_dec(batch, 0, 0) == _w(rows) * _w(Int(Int64.MAX)))
    var grouped = _run(ctx, "select k, sum(v) from t_partials group by k")
    assert_equal(grouped.num_rows(), 1)
    assert_true(_dec(grouped, 1, 0) == _w(rows) * _w(Int(Int64.MAX)))


def test_max_max_min_min_is_minus_two() raises:
    var r = _Rows()
    r.add(1, Int64.MAX, 0)
    r.add(1, Int64.MAX, 0)
    r.add(1, Int64.MIN, 0)
    r.add(1, Int64.MIN, 0)
    var ctx = _new_context()
    _register(ctx, "cancel", r, 2)
    var batch = _run(ctx, "select sum(v) from t_cancel")
    assert_true(_dec(batch, 0, 0) == _w(-2))
    var grouped = _run(ctx, "select k, sum(v) from t_cancel group by k")
    assert_equal(grouped.num_rows(), 1)
    assert_true(_dec(grouped, 1, 0) == _w(-2))


def test_groups_are_summed_separately_past_int64() raises:
    var r = _Rows()
    for _ in range(5):
        r.add(1, Int64.MAX, 0)
    for _ in range(5):
        r.add(2, Int64.MIN, 0)
    var ctx = _new_context()
    _register(ctx, "groups", r, 3)
    var grouped = _run(ctx, "select k, sum(v) from t_groups group by k")
    assert_equal(grouped.num_rows(), 2)
    assert_true(
        _dec(grouped, 1, _group_row(grouped, 1, False)) == _w(5) * _w(Int(Int64.MAX))
    )
    assert_true(
        _dec(grouped, 1, _group_row(grouped, 2, False)) == _w(5) * _w(Int(Int64.MIN))
    )


def test_an_empty_sum_and_an_all_null_sum_are_null() raises:
    var ctx = _new_context()
    var r = _Rows()
    for x in range(6):
        r.add(x % 2, Int64(x), Int32(x))
    _register(ctx, "empty", r, 3)
    # No row passes the filter: one row, NULL, still typed DECIMAL(38, 0).
    var none = _run(ctx, "select sum(v), sum(i) from t_empty where k = 7")
    assert_equal(none.num_rows(), 1)
    _expect_decimal_38_0(none, 0)
    _expect_decimal_38_0(none, 1)
    assert_true(_is_null(none, 0, 0))
    assert_true(_is_null(none, 1, 0))
    # Grouped, no row passes: no group at all.
    var no_groups = _run(ctx, "select k, sum(v) from t_empty where k = 7 group by k")
    assert_equal(no_groups.num_rows(), 0)

    var nulls = _Rows()
    for x in range(6):
        nulls.add(x % 2, Int64(0), Int32(0), v_null=True, i_null=True)
    _register(ctx, "allnull", nulls, 2)
    var all_null = _run(ctx, "select sum(v), sum(i) from t_allnull")
    assert_equal(all_null.num_rows(), 1)
    _expect_decimal_38_0(all_null, 0)
    assert_true(_is_null(all_null, 0, 0))
    assert_true(_is_null(all_null, 1, 0))

    # Group 1 is all NULL, group 2 has a value, the NULL key has its own sum.
    var mixed = _Rows()
    mixed.add(1, Int64(0), Int32(0), v_null=True)
    mixed.add(1, Int64(0), Int32(0), v_null=True)
    mixed.add(2, Int64.MAX, Int32(0))
    mixed.add(2, Int64.MAX, Int32(0))
    mixed.add(2, Int64(0), Int32(0), v_null=True)
    mixed.add(0, Int64(5), Int32(0), k_null=True)
    mixed.add(0, Int64(7), Int32(0), k_null=True)
    _register(ctx, "mixed", mixed, 2)
    var grouped = _run(ctx, "select k, sum(v) from t_mixed group by k")
    assert_equal(grouped.num_rows(), 3)
    _expect_decimal_38_0(grouped, 1)
    assert_true(_is_null(grouped, 1, _group_row(grouped, 1, False)))
    assert_true(
        _dec(grouped, 1, _group_row(grouped, 2, False)) == _w(2) * _w(Int(Int64.MAX))
    )
    assert_true(_dec(grouped, 1, _group_row(grouped, 0, True)) == _w(12))


def test_expressions_and_case_over_integers_sum_exactly() raises:
    var r = _Rows()
    for x in range(20):
        r.add(x % 4, Int64.MAX - Int64(x), Int32(x), i_null=(x % 5 == 0))
    var ctx = _new_context()
    _register(ctx, "exprs", r, 6)
    var want_plus = _w(0)
    var want_case = _w(0)
    for x in range(r.rows()):
        if not r.i_null[x]:
            want_plus += _w(Int(r.i[x])) + _w(1)
            if r.i[x] > Int32(10):
                want_case += _w(Int(r.v[x]))
    var batch = _run(
        ctx,
        "select sum(i + 1), sum(case when i > 10 then v else 0 end) from t_exprs",
    )
    _expect_decimal_38_0(batch, 0)
    _expect_decimal_38_0(batch, 1)
    assert_true(_dec(batch, 0, 0) == want_plus)
    # The CASE adds 0 for a row with i <= 10 or a NULL i, so the oracle sums v
    # where i > 10 only.
    assert_true(_dec(batch, 1, 0) == want_case)


def test_a_boolean_sum_counts_the_true_rows_as_decimal_38_0() raises:
    var r = _Rows()
    var want = 0
    for x in range(30):
        r.add(x % 3, Int64(x), Int32(x), i_null=(x % 7 == 0))
        if x % 7 != 0 and x > 10:
            want += 1
    var ctx = _new_context()
    _register(ctx, "bool", r, 8)
    var batch = _run(ctx, "select sum(i > 10) from t_bool")
    _expect_decimal_38_0(batch, 0)
    assert_true(_dec(batch, 0, 0) == _w(want))


def test_expressions_above_the_sum_answer_like_duckdb() raises:
    # 8 rows of 2^63 - 1 and 8 rows of 7 in the INT32 column.
    var rows = 8
    var r = _constant(rows, Int64.MAX, Int32(7), 2)
    var ctx = _new_context()
    _register(ctx, "above", r, 3)
    var big = _w(rows) * _w(Int(Int64.MAX))
    var batch = _run(
        ctx,
        "select sum(v) + 1, sum(i) * 2, sum(v) / count(*), sqrt(sum(i)),"
        " sum(i) - sum(i) from t_above",
    )
    assert_equal(batch.num_rows(), 1)
    # DECIMAL arithmetic: exact past INT64.
    assert_true(_dec(batch, 0, 0) == big + _w(1))
    assert_true(_dec(batch, 1, 0) == _w(rows * 7 * 2))
    # `/` is DOUBLE, as in DuckDB: sum(v) / count(*) is 2^63 - 1 as a double.
    var ratio = batch.column_at(2).as_primitive[DType.float64]().get(0)
    assert_true(ratio > 9.2233720368547e18 and ratio < 9.2233720368548e18)
    var root = batch.column_at(3).as_primitive[DType.float64]().get(0)
    assert_true(root > 7.48331 and root < 7.48332)  # sqrt(56)
    assert_true(_dec(batch, 4, 0) == _w(0))


def test_having_and_the_other_aggregates_run_beside_the_sum() raises:
    var rows = 40
    var r = _constant(rows, Int64.MAX, Int32(3), 4)
    var ctx = _new_context()
    _register(ctx, "having", r, 7)
    var batch = _run(
        ctx,
        "select k, sum(v), count(v), min(v), max(v) from t_having group by k"
        " having sum(v) > 0",
    )
    assert_equal(batch.num_rows(), 4)
    _expect_decimal_38_0(batch, 1)
    for key in range(4):
        var row = _group_row(batch, key, False)
        assert_true(_dec(batch, 1, row) == _w(rows // 4) * _w(Int(Int64.MAX)))
        assert_equal(batch.column_at(2).as_primitive[DType.int64]().get(row), Int64(rows // 4))
        assert_equal(batch.column_at(3).as_primitive[DType.int64]().get(row), Int64.MAX)
        assert_equal(batch.column_at(4).as_primitive[DType.int64]().get(row), Int64.MAX)
    # A HAVING that no group meets keeps none.
    var none = _run(
        ctx, "select k, sum(v) from t_having group by k having sum(v) < 0"
    )
    assert_equal(none.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
