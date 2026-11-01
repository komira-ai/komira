# =============================================================================
# CountDistinctAggSink — key types, input types and declared output types
# =============================================================================
#
# `SELECT k, count(DISTINCT v), min(v), max(v), sum(f), avg(f), min(vi),
#  max(vi), min(ff), max(ff), count(v), sum(v), avg(v) GROUP BY k` over three
# workers, where `k` is INT32, `v` is a nullable INT64, `vi` an INT32, `f` a
# FLOAT64 and `ff` a FLOAT32. Every output column is compared, group by group,
# with an oracle computed in the test from the generated rows.
#
# What each test asserts:
#   * an INT32 key reads back as an INT32 column, a NULL key forms one group
#     that reads back as NULL, and the output key field is nullable only when
#     a NULL group exists;
#   * a group whose `v` is NULL in every row answers 0 for count(DISTINCT v)
#     and count(v) and NULL for min, max, sum and avg of `v`;
#   * integer MIN / MAX across workers, floating-point SUM / AVG across
#     workers, and MIN / MAX of an INT32 and of a FLOAT32 input each match the
#     oracle, and every output column has the type its schema field declares;
#   * an empty result, with no worker or with workers that saw no row, carries
#     every column at its declared type, including INT32 and FLOAT32.
# =============================================================================

from std.collections import Dict, Set
from std.memory import OwnedPointer, Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_operator_api.memory_reservation import MemoryReservation
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)
from komira_plan_expr.agg_expr import (
    count,
    count_distinct,
    max,
    mean,
    min,
    sum,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggLocal,
    CountDistinctAggSink,
)


comptime _WORKERS: Int = 3
comptime _BATCHES: Int = 2
comptime _ROWS: Int = 240
# Group id of the keys whose `v` is NULL in every row.
comptime _ALL_NULL_GROUP: Int = 5
comptime _NULL_KEY: Int64 = -999_999


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _gid(i: Int, w: Int, b: Int) -> Int:
    return (i + w * 2 + b) % 6


def _v_is_null(i: Int, w: Int, b: Int) -> Bool:
    return _gid(i, w, b) == _ALL_NULL_GROUP or i % 11 == 3


def _v(i: Int, w: Int, b: Int) -> Int64:
    return Int64((i * 13 + w * 101 + b * 7) % 50 - 20)


def _vi(i: Int, w: Int) -> Int32:
    return Int32((i * 5 + w * 3) % 41 - 20)


def _f(i: Int, w: Int) -> Float64:
    return Float64(((i * 31 + w * 17) % 200) - 100) / 4.0


def _batch(w: Int, b: Int, null_key_every: Int) raises -> RecordBatch:
    var ka: PrimitiveArray[DType.int32]
    if null_key_every > 0:
        ka = PrimitiveArray[DType.int32].allocate_nullable(_ROWS)
    else:
        ka = PrimitiveArray[DType.int32].allocate(_ROWS)
    var va = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
    var via = PrimitiveArray[DType.int32].allocate(_ROWS)
    var fa = PrimitiveArray[DType.float64].allocate(_ROWS)
    var ffa = PrimitiveArray[DType.float32].allocate(_ROWS)
    for i in range(_ROWS):
        ka.store[1](i, Scalar[DType.int32](Int32(_gid(i, w, b))))
        va.store[1](i, Scalar[DType.int64](_v(i, w, b)))
        via.store[1](i, Scalar[DType.int32](_vi(i, w)))
        fa.store[1](i, Scalar[DType.float64](_f(i, w)))
        ffa.store[1](i, Scalar[DType.float32](Float32(_f(i, w))))
    for i in range(_ROWS):
        if null_key_every > 0 and i % null_key_every == 7:
            ka._set_null(i)
        if _v_is_null(i, w, b):
            va._set_null(i)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT32, null_key_every > 0))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("vi", ArrowType.INT32, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("ff", ArrowType.FLOAT32, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](ka^))
    rb.add_column(Column.from_primitive[DType.int64](va^))
    rb.add_column(Column.from_primitive[DType.int32](via^))
    rb.add_column(Column.from_primitive[DType.float64](fa^))
    rb.add_column(Column.from_primitive[DType.float32](ffa^))
    return rb.build(sb.build())


# Output column positions.
comptime _C_K: Int = 0
comptime _C_CD: Int = 1
comptime _C_MNV: Int = 2
comptime _C_MXV: Int = 3
comptime _C_SF: Int = 4
comptime _C_AF: Int = 5
comptime _C_MNVI: Int = 6
comptime _C_MXVI: Int = 7
comptime _C_MNFF: Int = 8
comptime _C_MXFF: Int = 9
comptime _C_CV: Int = 10
comptime _C_SV: Int = 11
comptime _C_AV: Int = 12


def _declared() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT32)
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.FLOAT64)
    t.append(ArrowType.FLOAT64)
    t.append(ArrowType.INT32)
    t.append(ArrowType.INT32)
    t.append(ArrowType.FLOAT32)
    t.append(ArrowType.FLOAT32)
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.FLOAT64)
    return t^


def _sink(null_key_every: Int) raises -> CountDistinctAggSink:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("cd"))
    aggs.append(min(col("v")).alias("mnv"))
    aggs.append(max(col("v")).alias("mxv"))
    aggs.append(sum(col("f")).alias("sf"))
    aggs.append(mean(col("f")).alias("af"))
    aggs.append(min(col("vi")).alias("mnvi"))
    aggs.append(max(col("vi")).alias("mxvi"))
    aggs.append(min(col("ff")).alias("mnff"))
    aggs.append(max(col("ff")).alias("mxff"))
    aggs.append(count(col("v")).alias("cv"))
    aggs.append(sum(col("v")).alias("sv"))
    aggs.append(mean(col("v")).alias("av"))
    var names = List[String]()
    names.append(String("k"))
    names.append(String("cd"))
    names.append(String("mnv"))
    names.append(String("mxv"))
    names.append(String("sf"))
    names.append(String("af"))
    names.append(String("mnvi"))
    names.append(String("mxvi"))
    names.append(String("mnff"))
    names.append(String("mxff"))
    names.append(String("cv"))
    names.append(String("sv"))
    names.append(String("av"))
    var types = _declared()
    var osb = SchemaBuilder()
    for c in range(len(names)):
        # The key is declared NOT NULL (the sink must mark it nullable when a
        # NULL group exists); `cd` and `cv` are never NULL; the rest may be.
        var nullable = not (c == _C_K or c == _C_CD or c == _C_CV)
        osb.add_field(Field(names[c], types[c], nullable))
    var pq = ParquetSourceData(
        String(""), Optional[List[String]](None), Optional[Expr](None)
    )
    return CountDistinctAggSink.new(
        AggSinkData(gb^, aggs^, osb.build()), pq^, Slab[MorselOp]()
    )


def _drive(
    var sink: CountDistinctAggSink, num_workers: Int, null_key_every: Int,
    feed: Bool,
) raises -> RecordBatch:
    var sink_global = sink.init_global()
    var locals = Slab[OwnedPointer[CountDistinctAggLocal]].create(
        num_workers + 1
    )
    for _ in range(num_workers):
        locals.append(OwnedPointer[CountDistinctAggLocal](sink.init_local()))
    if feed:
        for w in range(num_workers):
            for b in range(_BATCHES):
                ref local = locals[w][]
                sink.consume(w, local, sink_global, _batch(w, b, null_key_every))
    var reservation = MemoryReservation()
    sink.combine(sink_global, locals^, reservation)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var out = sink.finalize(
        sink_global^, Pointer(to=disp), CancellationToken.new()
    )
    var popped = out.output.pop()
    _ = out^
    rt.shutdown()
    return popped.take()


struct _Want(Copyable, Movable):
    var cd: Set[Int64]
    var rows: Int
    var nv: Int
    var sv: Int64
    var mnv: Int64
    var mxv: Int64
    var sf: Float64
    var mnvi: Int32
    var mxvi: Int32
    var mnff: Float32
    var mxff: Float32

    def __init__(out self):
        self.cd = Set[Int64]()
        self.rows = 0
        self.nv = 0
        self.sv = 0
        self.mnv = 0
        self.mxv = 0
        self.sf = 0
        self.mnvi = 0
        self.mxvi = 0
        self.mnff = 0
        self.mxff = 0


def _oracle(null_key_every: Int) raises -> Dict[Int64, _Want]:
    var want = Dict[Int64, _Want]()
    for w in range(_WORKERS):
        for b in range(_BATCHES):
            for i in range(_ROWS):
                var key = Int64(_gid(i, w, b))
                if null_key_every > 0 and i % null_key_every == 7:
                    key = _NULL_KEY
                if key not in want:
                    want[key] = _Want()
                ref o = want[key]
                var first_row = o.rows == 0
                o.rows += 1
                if not _v_is_null(i, w, b):
                    var v = _v(i, w, b)
                    o.cd.add(v)
                    o.sv += v
                    if o.nv == 0 or v < o.mnv:
                        o.mnv = v
                    if o.nv == 0 or v > o.mxv:
                        o.mxv = v
                    o.nv += 1
                o.sf += _f(i, w)
                var vi = _vi(i, w)
                var ff = Float32(_f(i, w))
                if first_row or vi < o.mnvi:
                    o.mnvi = vi
                if first_row or vi > o.mxvi:
                    o.mxvi = vi
                if first_row or ff < o.mnff:
                    o.mnff = ff
                if first_row or ff > o.mxff:
                    o.mxff = ff
    return want^


def _check_types(got: RecordBatch) raises:
    var types = _declared()
    assert_equal(got.num_columns(), len(types), "column count")
    for c in range(len(types)):
        assert_true(
            got.column_arrow_type(c) == types[c],
            "column " + String(c) + " is not at its declared type",
        )


def _check(got: RecordBatch, null_key_every: Int) raises:
    _check_types(got)
    var want = _oracle(null_key_every)
    assert_equal(got.num_rows(), len(want), "one row per group")
    ref kc = got.column_at(_C_K)
    var ka = kc.as_primitive[DType.int32]()
    var cd = got.column_at(_C_CD).as_primitive[DType.int64]()
    ref mnv_c = got.column_at(_C_MNV)
    var mnv = mnv_c.as_primitive[DType.int64]()
    ref mxv_c = got.column_at(_C_MXV)
    var mxv = mxv_c.as_primitive[DType.int64]()
    var sf = got.column_at(_C_SF).as_primitive[DType.float64]()
    var af = got.column_at(_C_AF).as_primitive[DType.float64]()
    var mnvi = got.column_at(_C_MNVI).as_primitive[DType.int32]()
    var mxvi = got.column_at(_C_MXVI).as_primitive[DType.int32]()
    var mnff = got.column_at(_C_MNFF).as_primitive[DType.float32]()
    var mxff = got.column_at(_C_MXFF).as_primitive[DType.float32]()
    var cv = got.column_at(_C_CV).as_primitive[DType.int64]()
    ref sv_c = got.column_at(_C_SV)
    var sv = sv_c.as_primitive[DType.int64]()
    ref av_c = got.column_at(_C_AV)
    var av = av_c.as_primitive[DType.float64]()
    var seen = Set[Int64]()
    var saw_all_null = False
    for row in range(got.num_rows()):
        var key = _NULL_KEY if kc.is_null_at(row) else Int64(ka.get(row))
        assert_true(key in want, "unknown group " + String(key))
        assert_true(key not in seen, "group emitted twice: " + String(key))
        seen.add(key)
        ref o = want[key]
        var tag = "group " + String(key) + ": "
        assert_equal(Int(cd.get(row)), len(o.cd), tag + "count(DISTINCT v)")
        assert_equal(Int(cv.get(row)), o.nv, tag + "count(v)")
        assert_equal(Int(mnvi.get(row)), Int(o.mnvi), tag + "min(vi)")
        assert_equal(Int(mxvi.get(row)), Int(o.mxvi), tag + "max(vi)")
        assert_true(mnff.get(row) == o.mnff, tag + "min(ff)")
        assert_true(mxff.get(row) == o.mxff, tag + "max(ff)")
        assert_true(sf.get(row) == o.sf, tag + "sum(f)")
        assert_true(
            af.get(row) == o.sf / Float64(o.rows), tag + "avg(f)"
        )
        if o.nv == 0:
            saw_all_null = True
            assert_true(mnv_c.is_null_at(row), tag + "min(v) is NULL")
            assert_true(mxv_c.is_null_at(row), tag + "max(v) is NULL")
            assert_true(sv_c.is_null_at(row), tag + "sum(v) is NULL")
            assert_true(av_c.is_null_at(row), tag + "avg(v) is NULL")
        else:
            assert_true(not mnv_c.is_null_at(row), tag + "min(v) not NULL")
            assert_equal(Int(mnv.get(row)), Int(o.mnv), tag + "min(v)")
            assert_equal(Int(mxv.get(row)), Int(o.mxv), tag + "max(v)")
            assert_equal(Int(sv.get(row)), Int(o.sv), tag + "sum(v)")
            assert_true(
                av.get(row) == Float64(o.sv) / Float64(o.nv), tag + "avg(v)"
            )
    assert_true(saw_all_null, "fixture: a group with no non-NULL v exists")


def test_int32_key_with_a_null_group_and_every_aggregate() raises:
    var got = _drive(_sink(29), _WORKERS, 29, True)
    _check(got, 29)
    ref kc = got.column_at(_C_K)
    var nulls = 0
    for row in range(got.num_rows()):
        if kc.is_null_at(row):
            nulls += 1
    assert_equal(nulls, 1, "the NULL key is one group")
    assert_true(
        got.schema.field_nullable(_C_K),
        "a NULL group makes the key field nullable although declared NOT NULL",
    )


def test_int32_key_without_null_keeps_the_key_field_not_null() raises:
    var got = _drive(_sink(0), _WORKERS, 0, True)
    _check(got, 0)
    assert_true(
        not got.schema.field_nullable(_C_K),
        "no NULL group: the key field stays as declared",
    )
    assert_equal(got.column_at(_C_K).null_count(), 0, "no NULL key emitted")


def test_empty_result_without_workers_has_the_declared_types() raises:
    var got = _drive(_sink(0), 0, 0, False)
    assert_equal(got.num_rows(), 0, "no worker, no group")
    _check_types(got)


def test_empty_result_from_workers_without_rows_has_the_declared_types() raises:
    var got = _drive(_sink(0), _WORKERS, 0, False)
    assert_equal(got.num_rows(), 0, "workers saw no row, no group")
    _check_types(got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
