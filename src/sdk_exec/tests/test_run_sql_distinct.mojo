# =============================================================================
# run_sql: SELECT DISTINCT and COUNT(DISTINCT x) over Parquet tables
# =============================================================================
#
# Covers: run_sql over Parquet tables in several row groups: SELECT DISTINCT
# over an INT64 and a STRING column gives each value once and one NULL row
# (NULL and the empty string are two rows), below a filter and with ORDER BY
# (NULLs last); COUNT(DISTINCT x) ignores NULL, is an INT64 that is 0 for no
# rows and for all NULL, counts per group (the NULL key and an all-NULL group
# included), runs beside SUM and over a STRING; SELECT DISTINCT over two INT64
# columns gives each pair once.
#
# Each test writes a Parquet table t(k INT64, v INT64, s STRING) with small row
# groups (several morsels, so several workers' partial states to merge), runs
# SQL text through `run_sql` on a context of three workers, and compares the
# answer with an oracle computed HERE from the same values, never from the
# engine. The expected answers are DuckDB's for the same SQL: SELECT DISTINCT
# treats all NULLs of a column as one value, COUNT(DISTINCT x) ignores NULL and
# is an INT64 that is 0 (never NULL) for an empty or all-NULL input or group.
# The row order of an unordered result is unspecified, so a result is read by
# looking a row up by its key.
#
# What each test proves:
#   * test_distinct_over_an_int64_column_gives_each_value_once_and_one_null_row:
#     SELECT DISTINCT k over repeated values and several NULLs spread across
#     row groups gives one row per distinct value plus exactly one NULL row.
#   * test_distinct_over_a_string_column_keeps_null_and_empty_apart: SELECT
#     DISTINCT s over a column with NULL and the empty string gives each
#     non-NULL string once, the empty string once and one NULL row, so NULL
#     and "" are two rows.
#   * test_distinct_below_a_filter_sees_only_the_rows_that_pass: SELECT
#     DISTINCT k ... WHERE v > 20 de-duplicates the rows the filter keeps; a
#     row whose v is NULL does not pass.
#   * test_distinct_with_order_by_is_sorted_with_nulls_last: SELECT DISTINCT k
#     ORDER BY k gives the distinct values ascending and the one NULL row last,
#     DuckDB's default null order.
#   * test_count_distinct_ignores_null_and_is_int64: COUNT(DISTINCT v) over
#     repeats and NULLs is the number of distinct non-NULL values, an INT64.
#   * test_count_distinct_is_zero_for_no_rows_and_for_all_null: a filter that
#     keeps no row and an all-NULL column each give one row holding 0.
#   * test_count_distinct_per_group_counts_each_group_apart: GROUP BY k with
#     COUNT(DISTINCT v) counts per group, the NULL key is its own group, and a
#     group whose values are all NULL counts 0.
#   * test_count_distinct_beside_a_sum_in_one_aggregation: COUNT(DISTINCT v)
#     and SUM(v) in one GROUP BY: the count is of distinct values, the sum
#     (DECIMAL(38, 0)) is of every row, and an all-NULL group sums to NULL.
#   * test_count_distinct_over_a_string_column: COUNT(DISTINCT s), ungrouped
#     and per key, counts the empty string as a value and NULL not at all.
#   * test_distinct_over_two_int64_columns_gives_each_pair_once: SELECT
#     DISTINCT k, v over two INT64 columns gives each (k, v) pair of the rows
#     once, a NULL in either column a value of its own.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=3))


struct _Rows(Movable):
    """The rows of a table t(k INT64, v INT64, s STRING), each column with its
    own NULL flags."""

    var k: List[Int64]
    var k_null: List[Bool]
    var v: List[Int64]
    var v_null: List[Bool]
    var s: List[String]
    var s_null: List[Bool]

    def __init__(out self):
        self.k = List[Int64]()
        self.k_null = List[Bool]()
        self.v = List[Int64]()
        self.v_null = List[Bool]()
        self.s = List[String]()
        self.s_null = List[Bool]()

    def add(
        mut self,
        k: Int,
        v: Int,
        s: String,
        k_null: Bool = False,
        v_null: Bool = False,
        s_null: Bool = False,
    ):
        self.k.append(Int64(k))
        self.k_null.append(k_null)
        self.v.append(Int64(v))
        self.v_null.append(v_null)
        self.s.append(s)
        self.s_null.append(s_null)

    def rows(self) -> Int:
        return len(self.k)


def _batch(ref r: _Rows) raises -> RecordBatch:
    var n = r.rows()
    var k = PrimitiveArray[DType.int64].allocate_nullable(n)
    var v = PrimitiveArray[DType.int64].allocate_nullable(n)
    var valid = List[Bool]()
    for x in range(n):
        k.set(x, r.k[x])
        v.set(x, r.v[x])
        valid.append(not r.s_null[x])
    for x in range(n):
        if r.k_null[x]:
            k._set_null(x)
        if r.v_null[x]:
            v._set_null(x)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(r.s, valid))
    )
    return rb.build(sb.build())


def _register(
    mut ctx: EngineContext, name: String, ref r: _Rows, rows_per_group: Int
) raises:
    var path = test_tmpdir() + "/sql_distinct_" + name + ".parquet"
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


def _is_null(ref batch: RecordBatch, col: Int, row: Int) -> Bool:
    return batch.column_at(col).is_null_at(row)


def _int(ref batch: RecordBatch, col: Int, row: Int) raises -> Int64:
    assert_false(_is_null(batch, col, row), "the value is NULL")
    return batch.column_at(col).as_primitive[DType.int64]().get(row)


def _dec(ref batch: RecordBatch, col: Int, row: Int) raises -> I128:
    assert_false(_is_null(batch, col, row), "the sum is NULL")
    return batch.column_at(col).as_decimal128().get_i128(row)


def _str(ref batch: RecordBatch, col: Int, row: Int) raises -> String:
    """The string at a row of a STRING result column, plain or dictionary."""
    ref c = batch.column_at(col)
    if c.is_string_dict():
        var bv = c.string_dict_value_at(c.string_dict_code_at(row))
        var buf = List[UInt8](capacity=bv.len())
        for i in range(bv.len()):
            buf.append(bv.read_u8_at(i))
        return String(StringSlice(unsafe_from_utf8=Span(buf)))
    return c.as_string().get(row)


def _count_key(
    ref batch: RecordBatch, col: Int, key: Int, key_is_null: Bool
) raises -> Int:
    """The number of rows of an INT64 column `col` that hold `key` (or NULL)."""
    var n = 0
    for r in range(batch.num_rows()):
        if key_is_null:
            if _is_null(batch, col, r):
                n += 1
        elif not _is_null(batch, col, r) and _int(batch, col, r) == Int64(key):
            n += 1
    return n


def _group_row(
    ref batch: RecordBatch, key: Int, key_is_null: Bool
) raises -> Int:
    """The row of the group `key` (or of the NULL key) in a result whose first
    column is the INT64 key."""
    for r in range(batch.num_rows()):
        if key_is_null:
            if _is_null(batch, 0, r):
                return r
        elif not _is_null(batch, 0, r) and _int(batch, 0, r) == Int64(key):
            return r
    assert_true(False, "no group " + String(key))
    return -1


def _has_int(ref xs: List[Int64], x: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _has_str(ref xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _in_group(
    ref r: _Rows, x: Int, key: Int, key_is_null: Bool
) -> Bool:
    """Whether row `x` is in the group of `key` (the NULL key when asked)."""
    if key_is_null:
        return r.k_null[x]
    return (not r.k_null[x]) and r.k[x] == Int64(key)


def _distinct_v(ref r: _Rows, key: Int, key_is_null: Bool, all_rows: Bool) -> Int:
    """The oracle of COUNT(DISTINCT v) over a group (or over every row)."""
    var seen = List[Int64]()
    for x in range(r.rows()):
        if r.v_null[x]:
            continue
        if not all_rows and not _in_group(r, x, key, key_is_null):
            continue
        if not _has_int(seen, r.v[x]):
            seen.append(r.v[x])
    return len(seen)


def _distinct_s(ref r: _Rows, key: Int, key_is_null: Bool, all_rows: Bool) -> Int:
    """The oracle of COUNT(DISTINCT s) over a group (or over every row)."""
    var seen = List[String]()
    for x in range(r.rows()):
        if r.s_null[x]:
            continue
        if not all_rows and not _in_group(r, x, key, key_is_null):
            continue
        if not _has_str(seen, r.s[x]):
            seen.append(r.s[x])
    return len(seen)


def _keys_table() -> _Rows:
    """60 rows: k cycles 0..5 with a NULL every 9th row, v is x % 7 with a
    NULL every 5th row, s is a short string with a NULL every 11th row."""
    var r = _Rows()
    var words = List[String]()
    words.append("")
    words.append("a")
    words.append("bb")
    words.append("a")
    words.append("")
    words.append("ccc")
    for x in range(60):
        r.add(
            x % 6,
            x % 7,
            words[x % 6],
            k_null=(x % 9 == 8),
            v_null=(x % 5 == 4),
            s_null=(x % 11 == 10),
        )
    return r^


def test_distinct_over_an_int64_column_gives_each_value_once_and_one_null_row() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "int", r, 7)
    var want = List[Int64]()
    var want_null = False
    for x in range(r.rows()):
        if r.k_null[x]:
            want_null = True
        elif not _has_int(want, r.k[x]):
            want.append(r.k[x])
    assert_true(want_null, "the fixture has NULL keys")
    var batch = _run(ctx, "select distinct k from t_int")
    assert_equal(batch.num_rows(), len(want) + 1)
    for i in range(len(want)):
        assert_equal(_count_key(batch, 0, Int(want[i]), False), 1)
    assert_equal(_count_key(batch, 0, 0, True), 1)


def test_distinct_over_a_string_column_keeps_null_and_empty_apart() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "str", r, 9)
    var want = List[String]()
    var want_null = False
    for x in range(r.rows()):
        if r.s_null[x]:
            want_null = True
        elif not _has_str(want, r.s[x]):
            want.append(r.s[x])
    assert_true(want_null, "the fixture has NULL strings")
    assert_true(_has_str(want, String("")), "the fixture has the empty string")
    var batch = _run(ctx, "select distinct s from t_str")
    assert_equal(batch.num_rows(), len(want) + 1)
    var nulls = 0
    var seen = List[String]()
    for row in range(batch.num_rows()):
        if _is_null(batch, 0, row):
            nulls += 1
        else:
            var got = _str(batch, 0, row)
            assert_false(_has_str(seen, got), "a string is answered twice")
            seen.append(got)
    assert_equal(nulls, 1)
    for i in range(len(want)):
        assert_true(_has_str(seen, want[i]), "missing '" + want[i] + "'")


def test_distinct_below_a_filter_sees_only_the_rows_that_pass() raises:
    var r = _Rows()
    # Keys 1, 2 and NULL have rows past 20; key 3 only has rows at or below it,
    # and key 4 only a NULL v (which does not pass).
    for x in range(30):
        r.add(1 + (x % 2), 21 + x, "")
    for x in range(10):
        r.add(3, x, "")
    for x in range(5):
        r.add(0, 100 + x, "", k_null=True)
    for x in range(5):
        r.add(4, 100, "", v_null=True)
    var ctx = _new_context()
    _register(ctx, "filter", r, 6)
    var want = List[Int64]()
    var want_null = False
    for x in range(r.rows()):
        if r.v_null[x] or r.v[x] <= Int64(20):
            continue
        if r.k_null[x]:
            want_null = True
        elif not _has_int(want, r.k[x]):
            want.append(r.k[x])
    assert_equal(len(want), 2)
    assert_true(want_null)
    var batch = _run(ctx, "select distinct k from t_filter where v > 20")
    assert_equal(batch.num_rows(), 3)
    for i in range(len(want)):
        assert_equal(_count_key(batch, 0, Int(want[i]), False), 1)
    assert_equal(_count_key(batch, 0, 0, True), 1)
    assert_equal(_count_key(batch, 0, 3, False), 0)
    assert_equal(_count_key(batch, 0, 4, False), 0)


def test_distinct_with_order_by_is_sorted_with_nulls_last() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "order", r, 8)
    var want = List[Int64]()
    for x in range(r.rows()):
        if not r.k_null[x] and not _has_int(want, r.k[x]):
            want.append(r.k[x])
    # Insertion sort, ascending.
    for i in range(1, len(want)):
        var j = i
        while j > 0 and want[j - 1] > want[j]:
            var t = want[j]
            want[j] = want[j - 1]
            want[j - 1] = t
            j -= 1
    var batch = _run(ctx, "select distinct k from t_order order by k")
    assert_equal(batch.num_rows(), len(want) + 1)
    for i in range(len(want)):
        assert_equal(_int(batch, 0, i), want[i])
    assert_true(_is_null(batch, 0, len(want)), "the NULL row is last")


def test_count_distinct_ignores_null_and_is_int64() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "cnt", r, 7)
    var want = _distinct_v(r, 0, False, True)
    var batch = _run(ctx, "select count(distinct v) from t_cnt")
    assert_equal(batch.num_rows(), 1)
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(_int(batch, 0, 0), Int64(want))
    # The same count with the duplicates kept is larger, so the answer is of
    # distinct values and not of rows.
    var rows_with_value = 0
    for x in range(r.rows()):
        if not r.v_null[x]:
            rows_with_value += 1
    assert_true(want < rows_with_value)


def test_count_distinct_is_zero_for_no_rows_and_for_all_null() raises:
    var ctx = _new_context()
    var r = _keys_table()
    _register(ctx, "none", r, 7)
    var none = _run(ctx, "select count(distinct v) from t_none where k = 99")
    assert_equal(none.num_rows(), 1)
    assert_true(none.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(_int(none, 0, 0), Int64(0))

    var nulls = _Rows()
    for x in range(12):
        nulls.add(x % 3, 0, "x", v_null=True, s_null=True)
    _register(ctx, "allnull", nulls, 4)
    var all_null = _run(ctx, "select count(distinct v) from t_allnull")
    assert_equal(all_null.num_rows(), 1)
    assert_equal(_int(all_null, 0, 0), Int64(0))
    var all_null_s = _run(ctx, "select count(distinct s) from t_allnull")
    assert_equal(all_null_s.num_rows(), 1)
    assert_equal(_int(all_null_s, 0, 0), Int64(0))


def _mixed_groups() -> _Rows:
    """Keys 0..2 with repeated v and NULL v, the NULL key with its own values,
    and key 9 whose values are all NULL."""
    var r = _Rows()
    for x in range(36):
        r.add(x % 3, (x * 5) % 8, "", v_null=(x % 6 == 5))
    for x in range(8):
        r.add(0, 40 + (x % 3), "", k_null=True)
    for x in range(5):
        r.add(9, 0, "", v_null=True)
    return r^


def test_count_distinct_per_group_counts_each_group_apart() raises:
    var r = _mixed_groups()
    var ctx = _new_context()
    _register(ctx, "grp", r, 5)
    var batch = _run(ctx, "select k, count(distinct v) from t_grp group by k")
    assert_equal(batch.num_rows(), 5)
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.INT64)
    for key in range(3):
        assert_equal(
            _int(batch, 1, _group_row(batch, key, False)),
            Int64(_distinct_v(r, key, False, False)),
        )
    assert_equal(
        _int(batch, 1, _group_row(batch, 0, True)),
        Int64(_distinct_v(r, 0, True, False)),
    )
    assert_equal(_distinct_v(r, 0, True, False), 3)
    # The group of key 9 has only NULL values: it exists and counts 0.
    assert_equal(_int(batch, 1, _group_row(batch, 9, False)), Int64(0))


def test_count_distinct_beside_a_sum_in_one_aggregation() raises:
    var r = _mixed_groups()
    var ctx = _new_context()
    _register(ctx, "sum", r, 5)
    var batch = _run(
        ctx,
        "select k, count(distinct v), sum(v) from t_sum group by k",
    )
    assert_equal(batch.num_rows(), 5)
    assert_true(batch.schema.field_arrow_type(2) == ArrowType.DECIMAL128)
    var keys = List[Int]()
    keys.append(0)
    keys.append(1)
    keys.append(2)
    keys.append(9)
    keys.append(-1)  # the NULL key
    for i in range(len(keys)):
        var is_null_key = keys[i] < 0
        var key = keys[i]
        var row = _group_row(batch, key, is_null_key)
        assert_equal(
            _int(batch, 1, row),
            Int64(_distinct_v(r, key, is_null_key, False)),
        )
        var total = _w(0)
        var any_value = False
        for x in range(r.rows()):
            if _in_group(r, x, key, is_null_key) and not r.v_null[x]:
                total += _w(Int(r.v[x]))
                any_value = True
        if any_value:
            assert_true(_dec(batch, 2, row) == total)
        else:
            assert_true(_is_null(batch, 2, row), "an all-NULL group sums to NULL")


def test_count_distinct_over_a_string_column() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "cstr", r, 9)
    var want = _distinct_s(r, 0, False, True)
    var batch = _run(ctx, "select count(distinct s) from t_cstr")
    assert_equal(batch.num_rows(), 1)
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(_int(batch, 0, 0), Int64(want))
    var grouped = _run(
        ctx, "select k, count(distinct s) from t_cstr group by k"
    )
    var groups = 0
    var seen = List[Int64]()
    for x in range(r.rows()):
        if not r.k_null[x] and not _has_int(seen, r.k[x]):
            seen.append(r.k[x])
    groups = len(seen) + 1
    assert_equal(grouped.num_rows(), groups)
    for i in range(len(seen)):
        assert_equal(
            _int(grouped, 1, _group_row(grouped, Int(seen[i]), False)),
            Int64(_distinct_s(r, Int(seen[i]), False, False)),
        )
    assert_equal(
        _int(grouped, 1, _group_row(grouped, 0, True)),
        Int64(_distinct_s(r, 0, True, False)),
    )


def _pair_text(null: Bool, v: Int64) -> String:
    return "N" if null else String(v)


def test_distinct_over_two_int64_columns_gives_each_pair_once() raises:
    var r = _keys_table()
    var ctx = _new_context()
    _register(ctx, "two", r, 7)
    var batch = _run(ctx, "select distinct k, v from t_two")
    # The distinct (k, v) pairs of the rows, a NULL in either column a value
    # of its own.
    var want = List[String]()
    for x in range(r.rows()):
        var key = _pair_text(r.k_null[x], r.k[x]) + "|" + _pair_text(
            r.v_null[x], r.v[x]
        )
        var found = False
        for j in range(len(want)):
            if want[j] == key:
                found = True
        if not found:
            want.append(key)
    assert_equal(batch.num_rows(), len(want))
    var seen = List[Bool](length=len(want), fill=False)
    var k = batch.column_at(0).as_primitive[DType.int64]()
    var v = batch.column_at(1).as_primitive[DType.int64]()
    for i in range(batch.num_rows()):
        var key = _pair_text(batch.column_at(0).is_null_at(i), k.get(i)) + "|" + _pair_text(
            batch.column_at(1).is_null_at(i), v.get(i)
        )
        var at = -1
        for j in range(len(want)):
            if want[j] == key:
                at = j
        assert_true(at >= 0, "a pair no row holds: " + key)
        assert_false(seen[at], "pair " + key + " twice")
        seen[at] = True


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
