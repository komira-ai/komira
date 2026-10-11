# `execute_join_probe`'s routing, checked row by row (each output row is
# (probe id, build id), NULL as -1):
#   * SEMI and ANTI keep their meaning under `JOIN_ALGO_SORT_MERGE`: each kept
#     probe row once, probe columns only (the algorithm is not the join type);
#   * a composite-key join with a residual is refused, not run without the
#     residual;
#   * a single FLOAT64 key joins under the float model (NaN equals NaN, -0.0
#     equals +0.0; a NULL matches nothing), through the composite-key join;
#   * an INNER projection that keeps more than three quarters of the columns
#     comes out as projected, in its order;
#   * the sort-merge INNER, LEFT, RIGHT and FULL joins with NULL keys on both
#     sides; the hash RIGHT and FULL joins with an empty side; CROSS; the
#     single-key INNER with the table on the probe side; and the refusal of
#     RIGHT and FULL over composite keys.


from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import MorselOp
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_RIGHT, JOIN_FULL, JOIN_SEMI, JOIN_ANTI,
    JOIN_CROSS, JOIN_ALGO_SORT_MERGE,
)

from komira_op_join_probe.join_probe import (
    execute_join_probe,
    takes_composite_key_path,
)


comptime NULL: Int64 = -999


def _qnan() -> Float64:
    """The quiet NaN arithmetic produces."""
    return bitcast[DType.float64](UInt64(0x7FF8000000000000))


def _i64(vals: List[Int64]) -> Column[HeapRegion]:
    """INT64 values; `NULL` entries are NULL (their slot holds 0)."""
    var any_null = False
    for v in vals:
        if v == NULL:
            any_null = True
    if not any_null:
        return Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vals)
        )
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr._typed_ptr_mut()[i] = Int64(0) if vals[i] == NULL else vals[i]
        if vals[i] == NULL:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr^)


def _batch(
    key: String, keys: List[Int64], id: String, ty: ArrowType = ArrowType.INT64
) raises -> RecordBatch:
    """Columns `key` (INT64 `keys`) and `id` (0, 1, ...)."""
    var ids = List[Int64]()
    for i in range(len(keys)):
        ids.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field(key, ty, True))
    sb.add_field(Field(id, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(keys))
    rb.add_column(_i64(ids))
    return rb.build(sb.build())


def _f64_batch(key: String, keys: List[Float64], null_at: Int, id: String) raises -> RecordBatch:
    """Columns `key` (FLOAT64, NULL at row `null_at`, -1 for none) and `id`."""
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(keys))
    var ids = List[Int64]()
    for i in range(len(keys)):
        arr._typed_ptr_mut()[i] = keys[i]
        if i == null_at:
            arr._set_null(i)
        ids.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field(key, ArrowType.FLOAT64, True))
    sb.add_field(Field(id, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.float64](arr^))
    rb.add_column(_i64(ids))
    return rb.build(sb.build())


def _sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _run(imm probe: RecordBatch, imm op: MorselOp, imm build: RecordBatch) raises -> RecordBatch:
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2, sink_factory=_sink, backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref d = rt.dispatcher()
    return execute_join_probe(d, CancellationToken.never(), probe, op, build)


def _ids(imm out: RecordBatch, name: String) raises -> List[Int64]:
    var a = out.column_at(out.schema.column_index(name)).as_primitive[DType.int64]()
    var v = List[Int64]()
    for i in range(a.length):
        v.append(Int64(-1) if a.is_null(i) else a.get(i))
    return v^


def _pairs(imm out: RecordBatch, p: String, b: String) raises -> List[Int64]:
    """Rows as `(probe id + 1) * 100 + (build id + 1)` (NULL id: 0), sorted."""
    var pi = _ids(out, p)
    var bi = _ids(out, b)
    var v = List[Int64]()
    for i in range(len(pi)):
        v.append((pi[i] + 1) * 100 + (bi[i] + 1))
    sort(v)
    return v^


def _assert_list(got: List[Int64], want: List[Int64], what: String) raises:
    assert_equal(len(got), len(want), what + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _op(join_type: UInt8, algo: UInt8 = 0) -> MorselOp:
    if algo == 0:
        return MorselOp.join_probe(0, ["k"], ["bk"], join_type)
    return MorselOp.join_probe(0, ["k"], ["bk"], join_type, probe_algo=algo)


def test_semi_and_anti_under_the_sort_merge_algorithm() raises:
    """Probe keys 1, 1, 2, 5; build keys 1, 1, 2. SEMI keeps probe rows 0, 1,
    2 once each (an INNER merge would give rows 0 and 1 twice, with the build
    columns); ANTI keeps row 3."""
    var probe = _batch("k", [1, 1, 2, 5], "pid")
    var build = _batch("bk", [1, 1, 2], "bid")
    var semi = _run(probe, _op(JOIN_SEMI, JOIN_ALGO_SORT_MERGE), build)
    assert_equal(semi.num_columns(), 2, "SEMI: probe columns only")
    _assert_list(_ids(semi, "pid"), [0, 1, 2], "SEMI")
    var anti = _run(probe, _op(JOIN_ANTI, JOIN_ALGO_SORT_MERGE), build)
    assert_equal(anti.num_columns(), 2, "ANTI: probe columns only")
    _assert_list(_ids(anti, "pid"), [3], "ANTI")


def test_composite_keys_with_a_residual_are_refused() raises:
    """Two key pairs and a residual `pid > bid`: the residual join runs one
    key pair at most, and the composite join reads no residual, so this
    raises rather than emit the pairs the residual rejects."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("pid", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64([1, 2]))
    rb.add_column(_i64([1, 2]))
    rb.add_column(_i64([0, 1]))
    var probe = rb.build(sb.build())
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("x", ArrowType.INT64, False))
    sb2.add_field(Field("y", ArrowType.INT64, False))
    sb2.add_field(Field("bid", ArrowType.INT64, False))
    var rb2 = RecordBatchBuilder()
    rb2.add_column(_i64([1, 2]))
    rb2.add_column(_i64([1, 2]))
    rb2.add_column(_i64([5, 0]))
    var build = rb2.build(sb2.build())
    var op = MorselOp.join_probe_with_residual(
        0, ["a", "b"], ["x", "y"], JOIN_INNER,
        Expr.binary(BIN_GT, Expr.col_ref("pid"), Expr.col_ref("bid")),
        Optional[List[String]](None),
    )
    var raised = False
    try:
        _ = _run(probe, op, build)
    except:
        raised = True
    assert_true(raised, "a composite-key join with a residual must not run")


def test_single_float64_key_follows_the_float_model() raises:
    """Probe NaN, -0.0, 1.5, NULL; build NaN, +0.0, 2.5, NULL. INNER pairs
    NaN with NaN and -0.0 with +0.0; neither NULL matches."""
    var probe = _f64_batch("k", [_qnan(), -0.0, 1.5, 0.0], 3, "pid")
    var build = _f64_batch("bk", [_qnan(), 0.0, 2.5, 0.0], 3, "bid")
    assert_true(takes_composite_key_path(probe, build, _op(JOIN_INNER)), "route")
    _assert_list(
        _pairs(_run(probe, _op(JOIN_INNER), build), "pid", "bid"), [101, 202],
        "INNER",
    )
    _assert_list(
        _ids(_run(probe, _op(JOIN_ANTI), build), "pid"), [2, 3], "ANTI"
    )


def test_wide_projection_comes_out_as_projected() raises:
    """All four columns, reordered: more than three quarters kept, so the
    unprojected kernels run; the output is still the projection's order."""
    var probe = _batch("k", [1, 2, 3], "pid")
    var build = _batch("bk", [2, 3, 4], "bid")
    var op = MorselOp.join_probe_projected(
        0, ["k"], ["bk"], JOIN_INNER, ["bid", "pid", "bk", "k"]
    )
    var out = _run(probe, op, build)
    assert_equal(out.num_columns(), 4, "columns")
    assert_equal(out.schema.field_name(0), "bid")
    assert_equal(out.schema.field_name(1), "pid")
    assert_equal(out.schema.field_name(2), "bk")
    assert_equal(out.schema.field_name(3), "k")
    _assert_list(_pairs(out, "pid", "bid"), [201, 302], "rows")


def test_sort_merge_joins_with_null_keys() raises:
    """Probe 1, NULL, 0, 3; build 1, 1, NULL, 4; every NULL slot holds 0.
    Probe 0 matches build 0 and 1; probe 2's 0 does not match the build NULL,
    and neither NULL matches anything."""
    var probe = _batch("k", [1, NULL, 0, 3], "pid")
    var build = _batch("bk", [1, 1, NULL, 4], "bid")
    _assert_list(
        _pairs(_run(probe, _op(JOIN_INNER, JOIN_ALGO_SORT_MERGE), build), "pid", "bid"),
        [101, 102], "INNER",
    )
    _assert_list(
        _pairs(_run(probe, _op(JOIN_LEFT, JOIN_ALGO_SORT_MERGE), build), "pid", "bid"),
        [101, 102, 200, 300, 400], "LEFT",
    )
    _assert_list(
        _pairs(_run(probe, _op(JOIN_RIGHT, JOIN_ALGO_SORT_MERGE), build), "pid", "bid"),
        [3, 4, 101, 102], "RIGHT",
    )
    _assert_list(
        _pairs(_run(probe, _op(JOIN_FULL, JOIN_ALGO_SORT_MERGE), build), "pid", "bid"),
        [3, 4, 101, 102, 200, 300, 400], "FULL",
    )


def test_hash_right_and_full() raises:
    """The same rows through the hash table, then each with one side empty."""
    var probe = _batch("k", [1, NULL, 0, 3], "pid")
    var build = _batch("bk", [1, 1, NULL, 4], "bid")
    _assert_list(
        _pairs(_run(probe, _op(JOIN_RIGHT), build), "pid", "bid"),
        [3, 4, 101, 102], "RIGHT",
    )
    _assert_list(
        _pairs(_run(probe, _op(JOIN_FULL), build), "pid", "bid"),
        [3, 4, 101, 102, 200, 300, 400], "FULL",
    )
    var no_probe = _batch("k", List[Int64](), "pid")
    var no_build = _batch("bk", List[Int64](), "bid")
    _assert_list(
        _pairs(_run(no_probe, _op(JOIN_RIGHT), build), "pid", "bid"),
        [1, 2, 3, 4], "RIGHT, empty probe",
    )
    var right_empty = _run(probe, _op(JOIN_RIGHT), no_build)
    assert_equal(right_empty.num_rows(), 0, "RIGHT, empty build")
    assert_equal(right_empty.num_columns(), 4, "RIGHT, empty build: schema")
    _assert_list(
        _pairs(_run(probe, _op(JOIN_FULL), no_build), "pid", "bid"),
        [100, 200, 300, 400], "FULL, empty build",
    )
    _assert_list(
        _pairs(_run(no_probe, _op(JOIN_FULL), build), "pid", "bid"),
        [1, 2, 3, 4], "FULL, empty probe",
    )


def test_cross_join() raises:
    var probe = _batch("k", [7, 8], "pid")
    var build = _batch("bk", [9, 9, 9], "bid")
    var op = MorselOp.join_probe(0, List[String](), List[String](), JOIN_CROSS)
    _assert_list(
        _pairs(_run(probe, op, build), "pid", "bid"),
        [101, 102, 103, 201, 202, 203], "CROSS",
    )


def test_inner_with_the_table_on_the_probe_side() raises:
    """Build 7 rows, probe 2: the table goes on the probe side; same rows."""
    var probe = _batch("k", [3, 5], "pid")
    var build = _batch("bk", [1, 3, 3, 4, 5, 6, 7], "bid")
    _assert_list(
        _pairs(_run(probe, _op(JOIN_INNER), build), "pid", "bid"),
        [102, 103, 205], "INNER",
    )


def test_right_and_full_over_composite_keys_raise() raises:
    var probe = _f64_batch("k", [1.0], -1, "pid")
    var build = _f64_batch("bk", [1.0], -1, "bid")
    for jt in [JOIN_RIGHT, JOIN_FULL]:
        var raised = False
        try:
            _ = _run(probe, _op(jt), build)
        except:
            raised = True
        assert_true(raised, "RIGHT / FULL over a FLOAT64 key")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
