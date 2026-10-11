# =============================================================================
# test_cd_parallel_driver -- the grouped COUNT(DISTINCT) driver gives DuckDB's
# answer: distinct counts, NULL values, NULL group keys, and the fixed
# aggregates beside COUNT(DISTINCT)
# =============================================================================
#
# Every expectation is computed in the test from the raw fixture lists by a
# linear scan (`Dict` / `Set`), never by another kernel; the comments give the
# DuckDB answer for the small fixtures. The large fixtures have more than
# 65,536 rows, so K > 1 workers split the groups (asserted where it matters).
# Output row order is not part of GROUP BY's contract, so results are compared
# as a map from key to row.
#
# What each test catches:
#   * `test_int_key_counts_match_the_oracle`: a wrong distinct count, a group
#     dropped or emitted twice by the worker merge;
#   * `test_null_values_are_not_distinct_values`: a NULL value's data word
#     admitted as a value (the NULL rows store -777777, which no real row has),
#     and an all-NULL group dropped or counted as 1 instead of 0;
#   * `test_all_null_column_every_group_counts_zero` and
#     `test_ungrouped_skips_nulls`: the same over a column that is all NULL
#     (every worker sees only NULLs) and without GROUP BY;
#   * `test_null_int_key_is_one_group_apart_from_zero`: a NULL key merged into
#     the real key 0 (its data word), or one group per NULL row;
#   * `test_null_string_key_is_one_group_apart_from_empty`: the same for a
#     STRING key, whose NULL cell has the bytes of '';
#   * `test_large_string_key_groups_by_value`: a LARGE_STRING key read with
#     Int32 offsets (every row a wrong byte span);
#   * `test_fixed_aggregates_follow_duckdb`: SUM / COUNT / MIN / MAX / AVG that
#     fold a NULL row, answer 0 or a sentinel instead of NULL for a group with
#     no input, order NaN below a number, or sum integers through Float64
#     (2^53 + 1 is not a Float64);
#   * `test_int32_outputs_keep_their_type`: an INT32 key or MIN emitted as an
#     INT64 column under an INT32 field;
#   * `test_sliced_int_key_and_value_columns`: a key, value or validity read
#     at row r instead of the column's offset + r;
#   * `test_ungrouped_aggregate_and_empty_input`: no row, or a crash, for an
#     aggregate without GROUP BY over no rows (DuckDB: one row, count 0);
#   * `test_unsupported_key_type_is_refused`: a FLOAT64 key silently read as
#     an integer.
#
# Mutants run while writing it (each turned the named tests red):
#   * no NULL-mask key component (the key read raw, as the driver did before):
#     both NULL-key tests;
#   * the fixed-aggregate fold without its NULL skip and with MIN / MAX by bare
#     `<` / `>` (the fold before): the fixed-aggregate test;
#   * the COUNT(DISTINCT) column read through worker 0 for every output row:
#     every multi-worker test in this file.
# =============================================================================

from std.collections import Dict, List, Optional, Set
from std.math import inf, isnan, nan
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import AggExpr, count, count_distinct, max, mean, min, sum
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)

comptime _WORKERS: Int = 4
comptime _BIG: Int = 70_000
comptime _NULL_WORD: Int = -777777


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(
    imm batch: RecordBatch,
    keys: List[String],
    var aggs: AggExprArray,
    var out_fields: List[Field],
) raises -> RecordBatch:
    """Run the driver over `batch`, grouped by `keys`, on `_WORKERS` workers."""
    var group_by = ExprArray()
    for i in range(len(keys)):
        group_by.append(col(keys[i]).copy_expr())
    var osb = SchemaBuilder()
    for i in range(len(out_fields)):
        osb.add_field(out_fields[i])
    var n_aggs = len(aggs)
    var sink = AggSinkData(group_by^, aggs^, osb.build())
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, sink, len(keys), n_aggs, batch.num_rows()
    )


def _i64_col(vals: List[Int], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a.set(i, Int64(vals[i]))
        if len(nulls) > 0 and nulls[i]:
            a._set_null(i)
    return Column.from_primitive[DType.int64](a^)


def _batch2(var c0: Column[HeapRegion], at0: ArrowType, var c1: Column[HeapRegion], at1: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", at0, True))
    sb.add_field(Field("v", at1, True))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(c0^)
    b.add_column(c1^)
    return b.build(sb.build())


def _cd_out(key_at: ArrowType) -> List[Field]:
    var f = List[Field]()
    f.append(Field("k", key_at, False))
    f.append(Field("n", ArrowType.INT64, False))
    return f^


def _one_cd() -> AggExprArray:
    var a = AggExprArray()
    a.append(count_distinct(col("v")))
    return a^


def _int_key_counts(imm rb: RecordBatch) raises -> Dict[Int, Int]:
    """Output (INT64 key, count) as a map; raises on a key emitted twice."""
    var keys = rb.column_at(0).as_primitive[DType.int64]()
    var cnts = rb.column_at(1).as_primitive[DType.int64]()
    var out = Dict[Int, Int]()
    for r in range(rb.num_rows()):
        var k = Int(keys.get(r))
        if k in out:
            raise Error("key " + String(k) + " emitted twice")
        out[k] = Int(cnts.get(r))
    return out^


# -----------------------------------------------------------------------------
# Distinct counts and NULL values
# -----------------------------------------------------------------------------


def test_int_key_counts_match_the_oracle() raises:
    """997 keys over 70,000 rows; key k has 1 + k % 13 distinct values."""
    var ks = List[Int]()
    var vs = List[Int]()
    var oracle = Dict[Int, Set[Int]]()
    for r in range(_BIG):
        var k = (r * 31) % 997
        var v = (r // 997) % (1 + k % 13)
        ks.append(k)
        vs.append(v)
        if k not in oracle:
            oracle[k] = Set[Int]()
        oracle[k].add(v)
    var none = List[Bool]()
    var rb = _run(
        _batch2(_i64_col(ks, none), ArrowType.INT64, _i64_col(vs, none), ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.INT64),
    )
    var got = _int_key_counts(rb)
    assert_equal(len(got), len(oracle), "one row per key")
    for e in oracle.items():
        assert_equal(got[e.key], len(e.value), "key " + String(e.key))
    assert_true(_should_use_parallel_count_distinct(_BIG, _WORKERS), "K > 1 ran")


def test_null_values_are_not_distinct_values() raises:
    """Key r % 50; every third row's value is NULL (data word -777777), and
    every row of key 7 is NULL -> key 7 counts 0, every key is emitted."""
    var ks = List[Int]()
    var vs = List[Int]()
    var nulls = List[Bool]()
    var oracle = Dict[Int, Set[Int]]()
    for r in range(_BIG):
        var k = r % 50
        var is_null = r % 3 == 0 or k == 7
        ks.append(k)
        vs.append(_NULL_WORD if is_null else (r // 50) % 11)
        nulls.append(is_null)
        if k not in oracle:
            oracle[k] = Set[Int]()
        if not is_null:
            oracle[k].add((r // 50) % 11)
    var rb = _run(
        _batch2(_i64_col(ks, List[Bool]()), ArrowType.INT64, _i64_col(vs, nulls), ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.INT64),
    )
    var got = _int_key_counts(rb)
    assert_equal(len(got), 50, "every key, the all-NULL one included")
    assert_equal(got[7], 0, "an all-NULL group counts 0")
    for e in oracle.items():
        assert_equal(got[e.key], len(e.value), "key " + String(e.key))


def test_all_null_column_every_group_counts_zero() raises:
    """Every value NULL: each worker that owns a group sees only NULLs. All
    four groups are emitted (they have rows), each counting 0, not 1."""
    var ks = List[Int]()
    var vs = List[Int]()
    var nulls = List[Bool]()
    for r in range(_BIG):
        ks.append(r % 4)
        vs.append(_NULL_WORD)
        nulls.append(True)
    var rb = _run(
        _batch2(_i64_col(ks, List[Bool]()), ArrowType.INT64, _i64_col(vs, nulls), ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.INT64),
    )
    var got = _int_key_counts(rb)
    assert_equal(len(got), 4, "all four groups survive the merge")
    for g in range(4):
        assert_equal(got[g], 0, "group " + String(g) + " is all-NULL")


def test_ungrouped_skips_nulls() raises:
    """No GROUP BY over 70,000 rows, every 7th value NULL (data word
    -777777): one row, the distinct count of the non-NULL values."""
    var vs = List[Int]()
    var nulls = List[Bool]()
    var want = Set[Int]()
    for r in range(_BIG):
        var is_null = r % 7 == 0
        vs.append(_NULL_WORD if is_null else r % 401)
        nulls.append(is_null)
        if not is_null:
            want.add(r % 401)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(_i64_col(vs, nulls))
    var out = List[Field]()
    out.append(Field("n", ArrowType.INT64, False))
    var rb = _run(b.build(sb.build()), List[String](), _one_cd(), out^)
    assert_equal(rb.num_rows(), 1)
    assert_equal(Int(rb.column_at(0).as_primitive[DType.int64]().get(0)), len(want))


# -----------------------------------------------------------------------------
# NULL group keys
# -----------------------------------------------------------------------------


def test_null_int_key_is_one_group_apart_from_zero() raises:
    """k = r % 5 with every 4th row's key NULL (data word 0, and 0 is a real
    key); v = r % 9. DuckDB: keys 0..4 plus one NULL group."""
    var ks = List[Int]()
    var knulls = List[Bool]()
    var vs = List[Int]()
    var real = Dict[Int, Set[Int]]()
    var null_vals = Set[Int]()
    for r in range(_BIG):
        var kn = r % 4 == 1
        var k = 0 if kn else r % 5
        ks.append(k)
        knulls.append(kn)
        vs.append(r % 9 if kn else r % 3)
        if kn:
            null_vals.add(r % 9)
        else:
            if k not in real:
                real[k] = Set[Int]()
            real[k].add(r % 3)
    var rb = _run(
        _batch2(_i64_col(ks, knulls), ArrowType.INT64, _i64_col(vs, List[Bool]()), ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.INT64),
    )
    assert_equal(rb.num_rows(), 6, "five keys and one NULL group")
    var kcol = rb.column_at(0).as_primitive[DType.int64]()
    var cnts = rb.column_at(1).as_primitive[DType.int64]()
    var n_null = 0
    for r in range(rb.num_rows()):
        if rb.column_at(0).is_null_at(r):
            n_null += 1
            assert_equal(Int(cnts.get(r)), len(null_vals), "the NULL group's count")
        else:
            var k = Int(kcol.get(r))
            assert_equal(Int(cnts.get(r)), len(real[k]), "key " + String(k))
    assert_equal(n_null, 1, "exactly one NULL group")
    assert_true(rb.schema.field_at(0).nullable, "the key field is nullable")


def test_null_string_key_is_one_group_apart_from_empty() raises:
    """s in {'', 'a', 'b', NULL}: '' is a real key and NULL a separate group."""
    var keys = List[String]()
    var valid = List[Bool]()
    var vs = List[Int]()
    var oracle = Dict[String, Set[Int]]()
    for r in range(_BIG):
        var m = r % 4
        var s = String("") if m == 0 else (String("a") if m == 1 else String("b"))
        var is_null = m == 3
        keys.append(String("") if is_null else s)
        valid.append(not is_null)
        vs.append(r % (5 + m))
        var tag = String("<NULL>") if is_null else s
        if tag not in oracle:
            oracle[tag] = Set[Int]()
        oracle[tag].add(r % (5 + m))
    var kc = Column.from_string(StringArray.from_strings_with_validity(keys, valid))
    var rb = _run(
        _batch2(kc^, ArrowType.STRING, _i64_col(vs, List[Bool]()), ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.STRING),
    )
    assert_equal(rb.num_rows(), 4, "'', 'a', 'b' and NULL")
    var sk = rb.column_at(0).as_string()
    var cnts = rb.column_at(1).as_primitive[DType.int64]()
    for r in range(rb.num_rows()):
        var tag = String("<NULL>") if rb.column_at(0).is_null_at(r) else sk.get(r)
        assert_equal(Int(cnts.get(r)), len(oracle[tag]), "group " + tag)


def test_large_string_key_groups_by_value() raises:
    """A LARGE_STRING key (Int64 offsets) beside an INT key, through the
    general driver: grouped by the string VALUE. Reading Int64 offsets as
    Int32 would give every row a wrong byte span and mis-group silently."""
    var keys = List[String]()
    var ps = List[Int]()
    var vs = List[Int]()
    var oracle = Dict[String, Set[Int]]()
    for r in range(_BIG):
        var s = String("key-") + String(r % 37) + String("-") + String((r % 37) * 13)
        keys.append(s)
        ps.append(r % 2)
        vs.append(r % 19)
        var tag = String(r % 2) + "|" + s
        if tag not in oracle:
            oracle[tag] = Set[Int]()
        oracle[tag].add(r % 19)
    var sb = SchemaBuilder()
    sb.add_field(Field("p", ArrowType.INT64, False))
    sb.add_field(Field("k", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(_i64_col(ps, List[Bool]()))
    b.add_column(Column.from_large_string(LargeStringArray.from_strings(keys)))
    b.add_column(_i64_col(vs, List[Bool]()))
    var out = List[Field]()
    out.append(Field("p", ArrowType.INT64, False))
    out.append(Field("k", ArrowType.STRING, False))
    out.append(Field("n", ArrowType.INT64, False))
    var rb = _run(b.build(sb.build()), ["p", "k"], _one_cd(), out^)
    assert_equal(rb.num_rows(), len(oracle), "one row per (p, k)")
    var pc = rb.column_at(0).as_primitive[DType.int64]()
    var kc = rb.column_at(1).as_string()
    var nc = rb.column_at(2).as_primitive[DType.int64]()
    for r in range(rb.num_rows()):
        var tag = String(Int(pc.get(r))) + "|" + kc.get(r)
        assert_true(tag in oracle, "unknown group " + tag)
        assert_equal(Int(nc.get(r)), len(oracle[tag]), "group " + tag)


# -----------------------------------------------------------------------------
# Fixed aggregates beside COUNT(DISTINCT)
# -----------------------------------------------------------------------------


def test_fixed_aggregates_follow_duckdb() raises:
    """Key r % 4 over 70,000 rows with an INT64 `i` and a FLOAT64 `f`:
      * key 0: `i` all NULL, `f` all NULL;
      * key 1: `i` = 2^53 + 1 on its first two rows (SUM exact only in Int64), `f`
        alternates NaN and 1.0;
      * key 2: `i` NULL on every 3rd row, `f` = -inf on one row, else 2.5;
      * key 3: plain values.
    SELECT k, count(DISTINCT i), sum(i), count(i), count(*), min(f), max(f),
    avg(i) GROUP BY k gives, per DuckDB: key 0 -> 0, NULL, 0, n, NULL, NULL,
    NULL; key 1 max(f) NaN, min(f) 1.0; key 2 min(f) -inf."""
    var n = _BIG
    var ks = List[Int]()
    var iv = List[Int]()
    var inull = List[Bool]()
    var fa = PrimitiveArray[DType.float64].allocate_nullable(n)
    var sum_i = Dict[Int, Int]()
    var cnt_i = Dict[Int, Int]()
    var rows = Dict[Int, Int]()
    var dist = Dict[Int, Set[Int]]()
    for k in range(4):
        sum_i[k] = 0
        cnt_i[k] = 0
        rows[k] = 0
        dist[k] = Set[Int]()
    var big = (1 << 53) + 1
    var neg_inf_row = 6
    for r in range(n):
        var k = r % 4
        ks.append(k)
        rows[k] = rows[k] + 1
        var i_null: Bool
        var i_val: Int
        if k == 0:
            i_null = True
            i_val = _NULL_WORD
        elif k == 1:
            i_null = False
            i_val = big if r < 8 else r % 2
        elif k == 2:
            i_null = (r // 4) % 3 == 0
            i_val = _NULL_WORD if i_null else r % 17
        else:
            i_null = False
            i_val = r % 23
        iv.append(i_val)
        inull.append(i_null)
        if not i_null:
            sum_i[k] = sum_i[k] + i_val
            cnt_i[k] = cnt_i[k] + 1
            dist[k].add(i_val)
        if k == 0:
            fa.set(r, 99.0)
            fa._set_null(r)
        elif k == 1:
            fa.set(r, nan[DType.float64]() if (r // 4) % 2 == 0 else 1.0)
        elif k == 2:
            fa.set(r, -inf[DType.float64]() if r == neg_inf_row else 2.5)
        else:
            fa.set(r, Float64(r % 7))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("i", ArrowType.INT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(_i64_col(ks, List[Bool]()))
    b.add_column(_i64_col(iv, inull))
    b.add_column(Column.from_primitive[DType.float64](fa^))
    var batch = b.build(sb.build())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("i")))
    aggs.append(sum(col("i")))
    aggs.append(count(col("i")))
    aggs.append(count())
    aggs.append(min(col("f")))
    aggs.append(max(col("f")))
    aggs.append(mean(col("i")))
    var out = List[Field]()
    out.append(Field("k", ArrowType.INT64, False))
    out.append(Field("cd", ArrowType.INT64, False))
    out.append(Field("s", ArrowType.INT64, False))
    out.append(Field("c", ArrowType.INT64, False))
    out.append(Field("cs", ArrowType.INT64, False))
    out.append(Field("mn", ArrowType.FLOAT64, False))
    out.append(Field("mx", ArrowType.FLOAT64, False))
    out.append(Field("av", ArrowType.FLOAT64, False))
    var rb = _run(batch, ["k"], aggs^, out^)
    assert_equal(rb.num_rows(), 4)
    var kc = rb.column_at(0).as_primitive[DType.int64]()
    for r in range(4):
        var k = Int(kc.get(r))
        var what = "key " + String(k) + ": "
        assert_equal(Int(rb.column_at(1).as_primitive[DType.int64]().get(r)), len(dist[k]), what + "cd")
        assert_equal(Int(rb.column_at(3).as_primitive[DType.int64]().get(r)), cnt_i[k], what + "count(i)")
        assert_equal(Int(rb.column_at(4).as_primitive[DType.int64]().get(r)), rows[k], what + "count(*)")
        if k == 0:
            assert_true(rb.column_at(2).is_null_at(r), what + "sum of no input is NULL")
            assert_true(rb.column_at(5).is_null_at(r), what + "min of no input is NULL")
            assert_true(rb.column_at(6).is_null_at(r), what + "max of no input is NULL")
            assert_true(rb.column_at(7).is_null_at(r), what + "avg of no input is NULL")
            continue
        assert_false(rb.column_at(2).is_null_at(r), what + "sum")
        assert_equal(Int(rb.column_at(2).as_primitive[DType.int64]().get(r)), sum_i[k], what + "sum exact")
        var mn = Float64(rb.column_at(5).as_primitive[DType.float64]().get(r))
        var mx = Float64(rb.column_at(6).as_primitive[DType.float64]().get(r))
        var av = Float64(rb.column_at(7).as_primitive[DType.float64]().get(r))
        assert_equal(av, Float64(sum_i[k]) / Float64(cnt_i[k]), what + "avg")
        if k == 1:
            assert_true(isnan(mx), what + "max over NaN is NaN")
            assert_equal(mn, 1.0, what + "min skips NaN")
        elif k == 2:
            assert_equal(mn, -inf[DType.float64](), what + "min is -inf")
            assert_equal(mx, 2.5, what + "max")
    assert_true(rb.schema.field_at(2).nullable, "sum field nullable")
    assert_false(rb.schema.field_at(3).nullable, "count field stays not null")


def test_int32_outputs_keep_their_type() raises:
    """INT32 key and MIN(INT32) under INT32 fields come back as INT32 columns."""
    var ka = PrimitiveArray[DType.int32].allocate(_BIG)
    var va = PrimitiveArray[DType.int32].allocate(_BIG)
    var mins = Dict[Int, Int]()
    for r in range(_BIG):
        var k = r % 10
        var v = 1000 - (r % 977)
        ka.set(r, Int32(k))
        va.set(r, Int32(v))
        if k not in mins or v < mins[k]:
            mins[k] = v
    var batch = _batch2(
        Column.from_primitive[DType.int32](ka^), ArrowType.INT32,
        Column.from_primitive[DType.int32](va^), ArrowType.INT32,
    )
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    aggs.append(min(col("v")))
    var out = List[Field]()
    out.append(Field("k", ArrowType.INT32, False))
    out.append(Field("n", ArrowType.INT64, False))
    out.append(Field("m", ArrowType.INT32, False))
    var rb = _run(batch, ["k"], aggs^, out^)
    assert_equal(rb.column_at(0).arrow_type, ArrowType.INT32, "key column type")
    assert_equal(rb.column_at(2).arrow_type, ArrowType.INT32, "min column type")
    var kc = rb.column_at(0).as_primitive[DType.int32]()
    var mc = rb.column_at(2).as_primitive[DType.int32]()
    for r in range(rb.num_rows()):
        assert_equal(Int(mc.get(r)), mins[Int(kc.get(r))], "min per key")


def test_sliced_int_key_and_value_columns() raises:
    """The same rows read through a zero-copy slice (column offset 1,000) give
    the counts of the sliced rows only."""
    var n = _BIG + 2_000
    var ks = List[Int]()
    var vs = List[Int]()
    var vnull = List[Bool]()
    var oracle = Dict[Int, Set[Int]]()
    for r in range(n):
        var k = r % 30
        ks.append(k)
        # Rows before the slice carry values no sliced row has, so a read at
        # row r instead of offset + r changes the counts.
        var v = 10_000 + r if r < 1_000 else (r // 30) % (2 + k)
        vs.append(v)
        var is_null = r % 7 == 0
        vnull.append(is_null)
        if r >= 1_000 and r < 1_000 + _BIG:
            if k not in oracle:
                oracle[k] = Set[Int]()
            if not is_null:
                oracle[k].add(v)
    var kc = _i64_col(ks, List[Bool]()).slice(1_000, _BIG)
    var vc = _i64_col(vs, vnull).slice(1_000, _BIG)
    var rb = _run(
        _batch2(kc^, ArrowType.INT64, vc^, ArrowType.INT64),
        ["k"], _one_cd(), _cd_out(ArrowType.INT64),
    )
    var got = _int_key_counts(rb)
    assert_equal(len(got), len(oracle))
    for e in oracle.items():
        assert_equal(got[e.key], len(e.value), "key " + String(e.key))


# -----------------------------------------------------------------------------
# No GROUP BY, no rows, refusals
# -----------------------------------------------------------------------------


def test_ungrouped_aggregate_and_empty_input() raises:
    """SELECT count(DISTINCT v): over 70,000 rows with 300 values -> 300; over
    no rows -> one row, 0 (DuckDB)."""
    var vs = List[Int]()
    for r in range(_BIG):
        vs.append((r * 7) % 300)
    var ks = List[Int]()
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(_i64_col(vs, List[Bool]()))
    var out = List[Field]()
    out.append(Field("n", ArrowType.INT64, False))
    var rb = _run(b.build(sb.build()), List[String](), _one_cd(), out.copy())
    assert_equal(rb.num_rows(), 1)
    assert_equal(Int(rb.column_at(0).as_primitive[DType.int64]().get(0)), 300)
    var sb0 = SchemaBuilder()
    sb0.add_field(Field("v", ArrowType.INT64, False))
    var b0 = RecordBatchBuilder.with_capacity(1)
    b0.add_column(_i64_col(ks, List[Bool]()))
    var rb0 = _run(b0.build(sb0.build()), List[String](), _one_cd(), out^)
    assert_equal(rb0.num_rows(), 1, "an aggregate without GROUP BY has one row")
    assert_equal(Int(rb0.column_at(0).as_primitive[DType.int64]().get(0)), 0)


def test_unsupported_key_type_is_refused() raises:
    var fa = PrimitiveArray[DType.float64].allocate(4)
    var vs: List[Int] = [1, 2, 3, 4]
    var rb = _batch2(
        Column.from_primitive[DType.float64](fa^), ArrowType.FLOAT64,
        _i64_col(vs, List[Bool]()), ArrowType.INT64,
    )
    with assert_raises(contains="is not supported"):
        _ = _run(rb, ["k"], _one_cd(), _cd_out(ArrowType.FLOAT64))


def test_parallel_threshold() raises:
    """The driver is chosen from 65,536 rows on more than one worker."""
    assert_false(_should_use_parallel_count_distinct(65_535, 8))
    assert_true(_should_use_parallel_count_distinct(65_536, 8))
    assert_false(_should_use_parallel_count_distinct(1_000_000, 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
