# =============================================================================
# OP_UDF_APPLY
# =============================================================================
#
# The operator over morsels of the sample table (a = r, b = r * 10 with NULL
# where r % 5 == 2, s = "s" + r % 4), calling UDFs of komira-test/echo, the
# reference runtime of the conformance suite (echo.so): `double` answers
# 2 * x (NULL for NULL), `lost_on_call` loses its context on any call.
# What these tests prove:
#   * The answer is appended as the column the call names, every input column
#     kept in order, row i's answer the UDF's of row i (NULLs where the UDF
#     answers NULL).
#   * Under a selection mask the UDF is given the selected rows only, and the
#     batch comes out dense.
#   * A batch of no rows makes no call (a call of `lost_on_call` would fail)
#     and appends an empty column of the return type.
#   * A call naming a UDF the run does not bind, a ROW call, an op without a
#     call and a call with two output names are refused by name, before any
#     worker starts.
#   * Through `RealBuilder` and `run_plan`: a segment of the resident batch
#     with OP_UDF_APPLY then OP_PROJECT answers every row on three workers
#     with cut morsels (each worker opens its own instance); a segment over
#     no rows answers the projection's schema, the UDF column at its return
#     type (`_schema_at`); and a builder given no binding refuses the call by
#     name.
# Catches: an answer appended under another name or out of row order; an
# unselected row given to a UDF; a call made for an empty batch; a worker
# sharing another's instance; the UDF column missing from the schema of a
# segment no row reaches.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.boolean_array import BooleanArray
from arrow.schema import RecordBatch
from async_api.token import CancellationToken
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.morsel_operator import MorselOperatorImpl
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import MorselOp, OP_UDF_APPLY, SegmentDescPod
from physical_plan.udf_call_spec import UdfCallSpec
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.op_udf_apply import UdfApplyShared
from pipeline_exec.plan_harness import (
    b_is_null,
    batch_segment,
    chain,
    column_names,
    int64_column,
    null_column,
    project_columns,
    sample_batch,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import Expr
from plan_expr.expr_pool import ExprPool
from plan_ir.udf_ref import UDF_REF_KIND_MAP_BATCHES_COLUMN, UDF_REF_KIND_ROW, UDF_REF_KIND_SCALAR, UdfRef
from udf_host.runtime import UdfBinding, UdfRuntime, UdfRuntimeConfig

from komira_test_udf_host.echo_udfs import ECHO_LIBRARY, echo_ref

comptime OUT = "__udf_apply:1"


def _binding(var u: UdfRef) raises -> ArcPointer[UdfBinding]:
    var rt = ArcPointer(UdfRuntime.open(UdfRuntimeConfig(ECHO_LIBRARY, List[String](), "")))
    var refs = List[UdfRef]()
    refs.append(u^)
    return ArcPointer(UdfBinding.bind(rt, refs))


def _call(udf_index: Int = 0, kind: UInt8 = UDF_REF_KIND_SCALAR, two_names: Bool = False) -> MorselOp:
    var args = List[Expr]()
    args.append(Expr.col_ref("b"))
    var names = List[String]()
    names.append(OUT)
    if two_names:
        names.append("extra")
    return MorselOp.udf_call(OP_UDF_APPLY, UdfCallSpec(udf_index, kind, List[String](), args^, names^))


def _refusal(ref spec: MorselOp, binding: ArcPointer[UdfBinding]) -> String:
    try:
        _ = UdfApplyShared(spec, binding)
    except e:
        return String(e)
    return String("built")


def test_the_answer_is_appended_with_every_input_column() raises:
    var shared = UdfApplyShared(_call(), _binding(echo_ref("double", 1)))
    var op = shared.make(0)
    var m = Morsel(sample_batch(0, 8), 0, 0)
    _ = op.execute(m)
    var names = column_names(m.batch)
    assert_equal(len(names), 4)
    assert_equal(names[0], "a")
    assert_equal(names[2], "s")
    assert_equal(names[3], OUT)
    var got = int64_column(m.batch, 3)
    var nulls = null_column(m.batch, 3)
    for r in range(8):
        assert_equal(nulls[r], b_is_null(r), "row " + String(r))
        if not b_is_null(r):
            assert_equal(got[r], 2 * r * 10, "row " + String(r))


def test_a_masked_batch_gives_the_udf_the_selected_rows_only() raises:
    var shared = UdfApplyShared(_call(), _binding(echo_ref("double", 1)))
    var op = shared.make(0)
    var batch = sample_batch(0, 6)
    var mask = BooleanArray.allocate(6)
    for i in range(6):
        mask.set(i, i % 2 == 1)
    batch.set_selection_mask(mask^)
    var m = Morsel(batch^, 0, 0)
    _ = op.execute(m)
    assert_true(not m.batch.has_selection_mask())
    assert_equal(m.batch.num_rows(), 3)
    var a = int64_column(m.batch, 0)
    var got = int64_column(m.batch, 3)
    for i in range(3):
        assert_equal(a[i], 2 * i + 1)
        assert_equal(got[i], 2 * (2 * i + 1) * 10)


def test_a_batch_of_no_rows_makes_no_call() raises:
    var u = echo_ref("lost_on_call", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN)
    var shared = UdfApplyShared(_call(kind=UDF_REF_KIND_MAP_BATCHES_COLUMN), _binding(u^))
    var op = shared.make(0)
    var m = Morsel(sample_batch(0, 0), 0, 0)
    _ = op.execute(m)
    assert_equal(m.batch.num_rows(), 0)
    assert_equal(column_names(m.batch)[3], OUT)


def test_a_call_the_run_cannot_serve_is_refused_by_name() raises:
    var b = _binding(echo_ref("double", 1))
    assert_equal(
        _refusal(_call(udf_index=1), b),
        "PIPELINE_UDF_UNBOUND: an OP_UDF_APPLY calls UDF 1, and the run binds 1",
    )
    assert_equal(
        _refusal(_call(kind=UDF_REF_KIND_ROW), b),
        "PIPELINE_UDF_UNBOUND: UDF 0 (double, komira-test/echo) is a ROW call, which no operator serves yet",
    )
    assert_equal(_refusal(MorselOp.limit(1), b), "pipeline_exec: an OP_UDF_APPLY carries no UDF call")
    assert_equal(
        _refusal(_call(two_names=True), b), "pipeline_exec: an OP_UDF_APPLY names 2 output columns, not one"
    )


def _udf_segment(handle: Int, morsel_rows: Int) -> List[SegmentDescPod]:
    var names = List[String]()
    names.append("a")
    names.append(OUT)
    var out = List[SegmentDescPod]()
    out.append(batch_segment(0, handle, chain(_call(), project_columns(names)), morsel_rows))
    return out^


def test_a_segment_answers_every_row_on_three_workers() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](cache, pool)
    builder.set_udfs(_binding(echo_ref("double", 1)))
    var handle = builder.add_resident(sample_batch(0, 20))
    var dispatch = InlineDispatch()
    var out = run_plan(_udf_segment(handle, 3), builder, dispatch, 3, CancellationToken.new())
    var batch = out.take(0)
    var names = column_names(batch)
    assert_equal(len(names), 2)
    assert_equal(names[1], OUT)
    assert_equal(batch.num_rows(), 20)
    var a = int64_column(batch, 0)
    var got = int64_column(batch, 1)
    var nulls = null_column(batch, 1)
    for i in range(20):
        var r = a[i]
        assert_equal(nulls[i], b_is_null(r), "row " + String(r))
        if not b_is_null(r):
            assert_equal(got[i], 2 * r * 10, "row " + String(r))


def test_a_segment_no_row_reaches_has_the_udf_column_typed() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](cache, pool)
    builder.set_udfs(_binding(echo_ref("lost_on_call", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN)))
    var handle = builder.add_resident(sample_batch(0, 0))
    var dispatch = InlineDispatch()
    var out = run_plan(_udf_segment(handle, 0), builder, dispatch, 1, CancellationToken.new())
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.schema.field_at(1).name, OUT)
    assert_equal(String(batch.schema.field_at(1).arrow_type), "int64")


def test_a_builder_without_the_runs_udfs_refuses_the_call() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](cache, pool)
    var handle = builder.add_resident(sample_batch(0, 4))
    var dispatch = InlineDispatch()
    var got = String("ran")
    try:
        _ = run_plan(_udf_segment(handle, 0), builder, dispatch, 1, CancellationToken.new())
    except e:
        got = String(e)
    assert_true("PIPELINE_UDF_UNBOUND: an OP_UDF_APPLY calls UDF 0, and the run binds 0" in got, got)


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_answer_is_appended_with_every_input_column]()
    suite.test[test_a_masked_batch_gives_the_udf_the_selected_rows_only]()
    suite.test[test_a_batch_of_no_rows_makes_no_call]()
    suite.test[test_a_call_the_run_cannot_serve_is_refused_by_name]()
    suite.test[test_a_segment_answers_every_row_on_three_workers]()
    suite.test[test_a_segment_no_row_reaches_has_the_udf_column_typed]()
    suite.test[test_a_builder_without_the_runs_udfs_refuses_the_call]()
    suite^.run()
