# =============================================================================
# run_sql: GROUP BY one DATE32, BOOL or DECIMAL column answers like DuckDB
# =============================================================================
#
# Covers: run_sql over a Parquet table of DATE32, BOOL, DECIMAL(12, 2),
# DECIMAL(30, 4) and INT64 columns in six row groups: GROUP BY one DATE32, BOOL
# or DECIMAL column equals an oracle computed in the test (the NULL key is one
# group; count(*), count(v) and sum(v) per group; the key keeps its type,
# precision and scale; decimal keys past INT64 exact); min and max of dates and
# the sum of decimals run under a BOOL key; a WHERE before the grouping keeps
# only the passing rows; an all-NULL key is one group; `group by d, b` (a key
# of a DATE32 and a BOOL column) groups by the pair and equals the oracle too.
#
# Each test writes a Parquet table t(d DATE32, b BOOL, m DECIMAL(12, 2),
# w DECIMAL(30, 4), v INT64) of 203 rows in row groups of 37 (six row groups,
# so several morsels and several workers' partial tables), runs SQL text
# through `run_sql` on a context of three workers, and compares the answer with
# an oracle computed HERE by a loop over the same row functions (never from the
# engine). The oracle follows DuckDB: the rows whose key is NULL form ONE group
# of their own; count(*) counts the rows of a group, count(v) the rows whose v
# is not NULL; sum(v) is DECIMAL(38, 0) here (DuckDB's HUGEINT) and is NULL for
# a group with no non-NULL v. Group order is unspecified, so a group is found
# in the result by its key. Day numbers include negative ones (days before the
# epoch), decimals include negative values, and the values of w lie far past
# the INT64 range.
#
# What each test proves, and the defect it would catch:
#   * test_a_date_key_groups_like_duckdb: group by d gives one group per
#     distinct day plus one NULL-key group, each with the oracle's count(*),
#     count(v) and sum(v); the key column is DATE32.
#     Catches a date key read as INT32, a NULL key merged into a day's group,
#     and a group dropped or split between workers.
#   * test_a_bool_key_groups_like_duckdb: group by b gives exactly the groups
#     TRUE, FALSE and NULL, with the oracle's aggregates; the key is BOOL.
#   * test_a_decimal_key_groups_like_duckdb: group by m (DECIMAL(12, 2)) gives
#     the oracle's groups, and the key column is DECIMAL128 of precision 12 and
#     scale 2.
#     Catches a decimal key compared on its low half only or at another scale.
#   * test_a_decimal_key_past_int64_groups_exactly: group by w (DECIMAL(30, 4),
#     values about 5 * 10^20 and negated) gives the oracle's groups with the
#     exact key values; the key column is DECIMAL128 of precision 30, scale 4.
#     Catches a decimal key narrowed to 64 bits (the high half lost).
#   * test_aggregates_of_dates_and_decimals_run_under_a_bool_key: group by b
#     with min(d), max(d) (DATE32) and sum(m) (scale 2) equals the oracle,
#     including NULL results for a group with no non-NULL input.
#   * test_a_filter_before_the_grouping_keeps_only_the_passing_rows: where
#     v > 50 group by b counts only the rows that pass (a NULL v does not).
#     Catches a selection mask ignored by the key read.
#   * test_an_all_null_key_is_one_group: with every key NULL, each of the four
#     keys gives one group whose key is NULL and whose count(*) is the row
#     count.
#   * test_a_date_and_bool_key_groups_by_the_pair: group by d, b gives one
#     group per (d, b) pair of the rows, a NULL in either column a value of its
#     own, each with the oracle's count(*); the key columns stay DATE32 and
#     BOOL.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import SqlOutcome, run_sql

comptime _ROWS = 203
comptime _ROWS_PER_GROUP = 37

comptime _KIND_D = 0
comptime _KIND_B = 1
comptime _KIND_M = 2
comptime _KIND_W = 3


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _pow20() -> I128:
    var p = _w(1)
    for _ in range(20):
        p = p * _w(10)
    return p


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=3))


# The row functions. A `_*_class` is the row's key class, or -1 for a NULL key;
# a `_*_val` is the key value of a class.


def _d_class(n: Int) -> Int:
    if n % 17 == 0:
        return -1
    return n % 23


def _d_val(c: Int) -> Int:
    return (c - 8) * 131  # negative for c < 8: days before the epoch


def _b_class(n: Int) -> Int:
    if n % 7 == 0:
        return -1
    if n % 3 == 0:
        return 1
    return 0


def _m_class(n: Int) -> Int:
    if n % 19 == 0:
        return -1
    return n % 29


def _m_val(c: Int) -> Int:
    return (c - 14) * 123457 + c  # unscaled, scale 2


def _w_class(n: Int) -> Int:
    if n % 16 == 0:
        return -1
    return n % 13


def _w_val(c: Int) -> I128:
    return _w(c - 6) * _pow20() + _w(c)  # unscaled, scale 4


def _v_null(n: Int) -> Bool:
    return n % 6 == 2


def _v_val(n: Int) -> Int:
    return n * 3 - 100


def _class_of(kind: Int, n: Int, all_null: Bool) -> Int:
    if all_null:
        return -1
    if kind == _KIND_D:
        return _d_class(n)
    if kind == _KIND_B:
        return _b_class(n)
    if kind == _KIND_M:
        return _m_class(n)
    return _w_class(n)


def _classes(kind: Int) -> Int:
    if kind == _KIND_D:
        return 23
    if kind == _KIND_B:
        return 2
    if kind == _KIND_M:
        return 29
    return 13


def _key_name(kind: Int) -> String:
    if kind == _KIND_D:
        return "d"
    if kind == _KIND_B:
        return "b"
    if kind == _KIND_M:
        return "m"
    return "w"


def _batch(all_null: Bool) raises -> RecordBatch:
    var n = _ROWS
    var d = PrimitiveArray[DType.int32].allocate_nullable(n)
    var b = BooleanArray.allocate_nullable(n)
    var m = Decimal128Array.allocate_nullable(n, 12, 2)
    var w = Decimal128Array.allocate_nullable(n, 30, 4)
    var v = PrimitiveArray[DType.int64].allocate_nullable(n)
    for x in range(n):
        var dc = _class_of(_KIND_D, x, all_null)
        if dc < 0:
            d._set_null(x)
        else:
            d.set(x, Int32(_d_val(dc)))
        var bc = _class_of(_KIND_B, x, all_null)
        if bc < 0:
            b._set_null(x)
        else:
            b.set(x, bc == 1)
        var mc = _class_of(_KIND_M, x, all_null)
        if mc < 0:
            m.set_null(x)
        else:
            m.set_i128(x, _w(_m_val(mc)))
        var wc = _class_of(_KIND_W, x, all_null)
        if wc < 0:
            w.set_null(x)
        else:
            w.set_i128(x, _w_val(wc))
        if _v_null(x):
            v._set_null(x)
        else:
            v.set(x, Int64(_v_val(x)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](d^, ArrowType.DATE32)
    )
    sb.add_field(Field("b", ArrowType.BOOL, True))
    rb.add_column(Column.from_boolean(b))
    sb.add_field(Field.decimal128("m", 12, 2, True))
    rb.add_column(Column.from_decimal128(m^))
    sb.add_field(Field.decimal128("w", 30, 4, True))
    rb.add_column(Column.from_decimal128(w^))
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    return rb.build(sb.build())


def _register(mut ctx: EngineContext, name: String, all_null: Bool) raises:
    var path = test_tmpdir() + "/sql_group_keys_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(all_null), max_rows_per_rg=_ROWS_PER_GROUP
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


def _dec(ref batch: RecordBatch, col: Int, row: Int) raises -> I128:
    assert_false(batch.column_at(col).is_null_at(row), "the value is NULL")
    return batch.column_at(col).as_decimal128().get_i128(row)


def _int(ref batch: RecordBatch, col: Int, row: Int) raises -> Int:
    assert_false(batch.column_at(col).is_null_at(row), "the value is NULL")
    return Int(batch.column_at(col).as_primitive[DType.int64]().get(row))


def _day(ref batch: RecordBatch, col: Int, row: Int) raises -> Int:
    assert_false(batch.column_at(col).is_null_at(row), "the value is NULL")
    return Int(batch.column_at(col).as_primitive[DType.int32]().get(row))


def _key_equals(
    ref batch: RecordBatch, kind: Int, row: Int, c: Int
) raises -> Bool:
    ref col = batch.column_at(0)
    if kind == _KIND_D:
        return Int(col.as_primitive[DType.int32]().get(row)) == _d_val(c)
    if kind == _KIND_B:
        return col.as_boolean().get(row) == (c == 1)
    if kind == _KIND_M:
        return col.as_decimal128().get_i128(row) == _w(_m_val(c))
    return col.as_decimal128().get_i128(row) == _w_val(c)


def _group_row(
    ref batch: RecordBatch, kind: Int, c: Int, null_key: Bool
) raises -> Int:
    """The row of the group of class `c` (or of the NULL key) in a result whose
    first column is the key."""
    ref col = batch.column_at(0)
    for r in range(batch.num_rows()):
        if col.is_null_at(r):
            if null_key:
                return r
        elif not null_key and _key_equals(batch, kind, r, c):
            return r
    assert_true(False, "no group of class " + String(c))
    return -1


struct _Buckets(Movable):
    """One bucket per key class, and a last one for the NULL key: the rows,
    the rows with a non-NULL v, and their sum."""

    var rows: List[Int]
    var non_null: List[Int]
    var total: List[I128]

    def __init__(out self, classes: Int):
        self.rows = List[Int]()
        self.non_null = List[Int]()
        self.total = List[I128]()
        for _ in range(classes + 1):
            self.rows.append(0)
            self.non_null.append(0)
            self.total.append(_w(0))

    def add(mut self, slot: Int, n: Int):
        self.rows[slot] += 1
        if not _v_null(n):
            self.non_null[slot] += 1
            self.total[slot] += _w(_v_val(n))

    def groups(self) -> Int:
        var g = 0
        for s in range(len(self.rows)):
            if self.rows[s] > 0:
                g += 1
        return g


def _slot(c: Int, classes: Int) -> Int:
    if c < 0:
        return classes
    return c


def _oracle(kind: Int, all_null: Bool, only_v_above_50: Bool) -> _Buckets:
    var classes = _classes(kind)
    var o = _Buckets(classes)
    for n in range(_ROWS):
        if only_v_above_50 and (_v_null(n) or _v_val(n) <= 50):
            continue
        o.add(_slot(_class_of(kind, n, all_null), classes), n)
    return o^


def _expect_key_type(ref batch: RecordBatch, kind: Int) raises:
    if kind == _KIND_D:
        assert_true(batch.schema.field_arrow_type(0) == ArrowType.DATE32)
        assert_true(batch.column_at(0).arrow_type == ArrowType.DATE32)
    elif kind == _KIND_B:
        assert_true(batch.schema.field_arrow_type(0) == ArrowType.BOOL)
        assert_true(batch.column_at(0).arrow_type == ArrowType.BOOL)
    else:
        assert_true(batch.schema.field_arrow_type(0) == ArrowType.DECIMAL128)
        assert_true(batch.column_at(0).arrow_type == ArrowType.DECIMAL128)
        if kind == _KIND_M:
            assert_equal(batch.schema.field_decimal_precision(0), 12)
            assert_equal(batch.schema.field_decimal_scale(0), 2)
        else:
            assert_equal(batch.schema.field_decimal_precision(0), 30)
            assert_equal(batch.schema.field_decimal_scale(0), 4)


def _group_test(kind: Int, all_null: Bool, name: String) raises:
    """`select K, count(*), count(v), sum(v) from t group by K` equals the
    oracle, for the key column `K` of `kind`."""
    var ctx = _new_context()
    _register(ctx, name, all_null)
    var key = _key_name(kind)
    var batch = _run(
        ctx,
        "select "
        + key
        + ", count(*), count(v), sum(v) from t_"
        + name
        + " group by "
        + key,
    )
    var want = _oracle(kind, all_null, False)
    var classes = _classes(kind)
    _expect_key_type(batch, kind)
    assert_equal(batch.schema.field_decimal_precision(3), 38)
    assert_equal(batch.schema.field_decimal_scale(3), 0)
    assert_equal(batch.num_rows(), want.groups())
    for s in range(classes + 1):
        if want.rows[s] == 0:
            continue
        var null_key = s == classes
        var row = _group_row(batch, kind, s, null_key)
        assert_equal(_int(batch, 1, row), want.rows[s])
        assert_equal(_int(batch, 2, row), want.non_null[s])
        if want.non_null[s] == 0:
            assert_true(batch.column_at(3).is_null_at(row), "an empty sum")
        else:
            assert_true(_dec(batch, 3, row) == want.total[s])


def test_a_date_key_groups_like_duckdb() raises:
    # The oracle has all 23 days and the NULL key, so the group count is 24.
    assert_equal(_oracle(_KIND_D, False, False).groups(), 24)
    _group_test(_KIND_D, False, "date")


def test_a_bool_key_groups_like_duckdb() raises:
    assert_equal(_oracle(_KIND_B, False, False).groups(), 3)
    _group_test(_KIND_B, False, "bool")


def test_a_decimal_key_groups_like_duckdb() raises:
    _group_test(_KIND_M, False, "dec12")


def test_a_decimal_key_past_int64_groups_exactly() raises:
    # The keys differ only above bit 64 in part: -6 * 10^20 + 0 and so on.
    assert_true(_w_val(12) > _w(Int(Int64.MAX)))
    assert_true(_w_val(0) < _w(Int(Int64.MIN)))
    _group_test(_KIND_W, False, "dec30")


def test_aggregates_of_dates_and_decimals_run_under_a_bool_key() raises:
    var ctx = _new_context()
    _register(ctx, "aggs", False)
    var batch = _run(
        ctx,
        "select b, min(d), max(d), sum(m) from t_aggs group by b",
    )
    assert_equal(batch.num_rows(), 3)
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.DATE32)
    assert_true(batch.schema.field_arrow_type(2) == ArrowType.DATE32)
    assert_true(batch.schema.field_arrow_type(3) == ArrowType.DECIMAL128)
    assert_equal(batch.schema.field_decimal_scale(3), 2)
    # Slots 0 and 1 are the classes FALSE and TRUE, slot 2 is the NULL key.
    for s in range(3):
        var has_day = False
        var lo = 0
        var hi = 0
        var has_m = False
        var total = _w(0)
        for n in range(_ROWS):
            if _slot(_b_class(n), 2) != s:
                continue
            var dc = _d_class(n)
            if dc >= 0:
                if not has_day or _d_val(dc) < lo:
                    lo = _d_val(dc)
                if not has_day or _d_val(dc) > hi:
                    hi = _d_val(dc)
                has_day = True
            var mc = _m_class(n)
            if mc >= 0:
                has_m = True
                total += _w(_m_val(mc))
        assert_true(has_day and has_m, "the oracle's group has inputs")
        var row = _group_row(batch, _KIND_B, s, s == 2)
        assert_equal(_day(batch, 1, row), lo)
        assert_equal(_day(batch, 2, row), hi)
        assert_true(_dec(batch, 3, row) == total)


def test_a_filter_before_the_grouping_keeps_only_the_passing_rows() raises:
    var ctx = _new_context()
    _register(ctx, "filter", False)
    var batch = _run(
        ctx, "select b, count(*) from t_filter where v > 50 group by b"
    )
    var want = _oracle(_KIND_B, False, True)
    var all_rows = _oracle(_KIND_B, False, False)
    # The filter drops rows: a NULL v and every v <= 50.
    assert_true(want.rows[0] + want.rows[1] + want.rows[2] < _ROWS)
    assert_true(want.rows[0] < all_rows.rows[0])
    assert_equal(batch.num_rows(), want.groups())
    for s in range(3):
        if want.rows[s] == 0:
            continue
        var row = _group_row(batch, _KIND_B, s, s == 2)
        assert_equal(_int(batch, 1, row), want.rows[s])


def test_an_all_null_key_is_one_group() raises:
    for kind in range(4):
        var name = "null" + _key_name(kind)
        _group_test(kind, True, name)
    var ctx = _new_context()
    _register(ctx, "nullkeys", True)
    var batch = _run(ctx, "select m, count(*) from t_nullkeys group by m")
    assert_equal(batch.num_rows(), 1)
    assert_true(batch.column_at(0).is_null_at(0))
    assert_equal(_int(batch, 1, 0), _ROWS)


def _db_text(dc: Int, bc: Int) -> String:
    var d = String("N") if dc < 0 else String(_d_val(dc))
    var b = String("N") if bc < 0 else String(bc)
    return d + "|" + b


def test_a_date_and_bool_key_groups_by_the_pair() raises:
    var ctx = _new_context()
    _register(ctx, "multi", False)
    var batch = _run(ctx, "select d, b, count(*) from t_multi group by d, b")
    # The oracle: the rows of each (d, b) pair, a NULL in either column a
    # value of its own.
    var keys = List[String]()
    var counts = List[Int]()
    for n in range(_ROWS):
        var key = _db_text(_d_class(n), _b_class(n))
        var at = -1
        for j in range(len(keys)):
            if keys[j] == key:
                at = j
        if at < 0:
            keys.append(key)
            counts.append(0)
            at = len(keys) - 1
        counts[at] += 1
    assert_equal(batch.num_rows(), len(keys))
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.DATE32)
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.BOOL)
    var seen = List[Bool](length=len(keys), fill=False)
    for r in range(batch.num_rows()):
        var d = String("N")
        if not batch.column_at(0).is_null_at(r):
            d = String(_day(batch, 0, r))
        var b = String("N")
        if not batch.column_at(1).is_null_at(r):
            b = String(1) if batch.column_at(1).as_boolean().get(r) else String(0)
        var key = d + "|" + b
        var at = -1
        for j in range(len(keys)):
            if keys[j] == key:
                at = j
        assert_true(at >= 0, "a group no row holds: " + key)
        assert_false(seen[at], "group " + key + " twice")
        seen[at] = True
        assert_equal(_int(batch, 2, r), counts[at], "count(*) of " + key)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
