# =============================================================================
# test_inmem_source.mojo -- `InMemSource` and the in-memory scan plan builders.
# =============================================================================
#
# SUBJECT: `InMemSource` (the typed in-memory source) and
# `build_inmem_scan_plan`, `build_inmem_scan_plan_batches` and
# `build_inmem_scan_plan_table`.
#   1. the source: `take_batch` moves the batch out; `clone` is a deep copy
#      that survives the original's take; `descriptor` is an unnamed
#      SOURCE_IN_MEMORY variant over a copy; `resolve_agg_scan_schema` is the
#      batch's schema; the two parquet-shaped leaves raise;
#   2. the builders: a SCAN(SOURCE_IN_MEMORY) node carrying the batches in
#      order, the batch's schema, the synthetic name; zero batches raise;
#   3. the Table door: more than one chunk keeps the chunks (no concat), one
#      chunk and zero chunks build the single-batch plan, and zero chunks keep
#      the table's full schema.
# A builder that concatenated the chunks, reordered them or dropped the empty
# table's schema fails section 2 or 3; a clone that shared the batch fails
# section 1.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_column_format.column_format_storage import ColDescriptor
from komira_engine_runtime.morsel_sizing_policy import MorselSizingPolicy
from komira_op_agg_row_api.agg_spec import AggSpec
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import ParquetSourceData, MorselOp
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_SCAN, SOURCE_IN_MEMORY
from komira_scan_source.source_variant import SOURCE_VARIANT_IN_MEMORY

from komira_dispatch_sources.inmem_source import (
    InMemSource,
    build_inmem_scan_plan,
    build_inmem_scan_plan_batches,
    build_inmem_scan_plan_table,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    return sb.build()


def _chunk(start: Int, n: Int) raises -> RecordBatch:
    """`n` rows: k = start .., v = 10 * k."""
    var k = PrimitiveArray[DType.int64].allocate(n)
    var v = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k.store[1](i, SIMD[DType.int64, 1](Int64(start + i)))
        v.store[1](i, SIMD[DType.int64, 1](Int64(10 * (start + i))))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](k))
    rbb.add_column(Column.from_primitive[DType.int64](v))
    return rbb.build(_schema())


def _no_columns() raises -> RecordBatch:
    var rbb = RecordBatchBuilder()
    var sb = SchemaBuilder()
    return rbb.build(sb.build())


def _one_column(start: Int, n: Int) raises -> RecordBatch:
    """`n` rows of the single column k = start .."""
    var k = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k.store[1](i, SIMD[DType.int64, 1](Int64(start + i)))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](k))
    return rbb.build(sb.build())


def _renamed(n: Int) raises -> RecordBatch:
    """Two INT64 columns named k and w (not k and v)."""
    var k = PrimitiveArray[DType.int64].allocate(n)
    var w = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k.store[1](i, SIMD[DType.int64, 1](Int64(i)))
        w.store[1](i, SIMD[DType.int64, 1](Int64(i)))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("w"), ArrowType.INT64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](k))
    rbb.add_column(Column.from_primitive[DType.int64](w))
    return rbb.build(sb.build())


def _assert_k(b: RecordBatch, start: Int, n: Int) raises:
    assert_equal(b.num_rows(), n)
    var ks = b.column_at(0).as_primitive[DType.int64]()
    var vs = b.column_at(1).as_primitive[DType.int64]()
    for i in range(n):
        assert_equal(ks.get(i), Int64(start + i))
        assert_equal(vs.get(i), Int64(10 * (start + i)))


def _assert_two_columns(s: Schema) raises:
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_name(0), String("k"))
    assert_equal(s.field_name(1), String("v"))
    assert_true(s.field_arrow_type(1) == ArrowType.INT64)
    assert_false(s.field_nullable(0))
    assert_true(s.field_nullable(1))


def _assert_inmem_scan(
    plan: LogicalPlan, name: String, batches: Int
) raises:
    """`plan` is a SCAN(SOURCE_IN_MEMORY) carrying `batches` batches inline,
    named `name`."""
    assert_equal(plan.tag, PLAN_SCAN)
    ref sd = plan.scan_data_ref()
    assert_equal(sd.source_type, SOURCE_IN_MEMORY)
    assert_equal(sd.source.tag, SOURCE_VARIANT_IN_MEMORY)
    ref ims = sd.source._in_memory.value()
    assert_equal(ims.name.value(), name)
    assert_equal(len(ims.data[]), batches)


# --- 1. the source ----------------------------------------------------------


def test_take_and_clone() raises:
    var src = InMemSource(_chunk(0, 3))
    var copy = src.clone()
    _assert_k(src.take_batch(), 0, 3)
    _assert_k(copy.take_batch(), 0, 3)


def _raises_already_taken(what: String, msg: String) raises:
    assert_true(msg.find(what) >= 0, msg)
    assert_true(msg.find("already taken") >= 0, msg)


def test_use_after_take_raises() raises:
    var src = InMemSource(_chunk(0, 2))
    _ = src.take_batch()
    var cache = ParquetMetadataCache()
    var raised = False
    try:
        _ = src.clone()
    except e:
        raised = True
        _raises_already_taken(String("clone"), String(e))
    assert_true(raised, "clone after take_batch raises")
    raised = False
    try:
        _ = src.descriptor()
    except e:
        raised = True
        _raises_already_taken(String("descriptor"), String(e))
    assert_true(raised, "descriptor after take_batch raises")
    raised = False
    try:
        _ = src.resolve_agg_scan_schema(_pq(), cache)
    except e:
        raised = True
        _raises_already_taken(String("resolve_agg_scan_schema"), String(e))
    assert_true(raised, "resolve_agg_scan_schema after take_batch raises")
    raised = False
    try:
        _ = src.take_batch()
    except e:
        raised = True
        _raises_already_taken(String("take_batch"), String(e))
    assert_true(raised, "a second take_batch raises")


def test_descriptor() raises:
    var src = InMemSource(_chunk(5, 2))
    var sv = src.descriptor()
    assert_equal(sv.tag, SOURCE_VARIANT_IN_MEMORY)
    ref ims = sv._in_memory.value()
    assert_false(Bool(ims.name), "the descriptor is unnamed")
    assert_equal(len(ims.data[]), 1)
    _assert_k(ims.data[][0], 5, 2)
    _assert_k(src.take_batch(), 5, 2)


def _pq() -> ParquetSourceData:
    return ParquetSourceData(String("unused.parquet"), None, None)


def test_resolve_agg_scan_schema_is_the_batch_schema() raises:
    var src = InMemSource(_chunk(0, 1))
    var cache = ParquetMetadataCache()
    _assert_two_columns(src.resolve_agg_scan_schema(_pq(), cache))


def test_the_parquet_leaves_raise() raises:
    var src = InMemSource(_chunk(0, 1))
    var d = LocalDispatcher[NoopSink]()
    var cache = ParquetMetadataCache()
    var raised = False
    try:
        _ = src.materialize_into_source(
            0,
            d,
            CancellationToken.never(),
            _pq(),
            Slab[MorselOp](),
            MorselSizingPolicy.from_defaults(),
            cache,
            False,
            None,
            String(""),
            None,
        )
    except e:
        raised = True
        assert_true(String(e).find("in-memory terminal") >= 0, String(e))
    assert_true(raised, "materialize_into_source raises")
    raised = False
    try:
        _ = src.materialize_agg_into_source(
            d,
            CancellationToken.never(),
            _pq(),
            Slab[MorselOp](),
            List[ColDescriptor](),
            List[AggSpec](),
            _schema(),
            MorselSizingPolicy.from_defaults(),
            cache,
        )
    except e:
        raised = True
        assert_true(String(e).find("in-memory terminal") >= 0, String(e))
    assert_true(raised, "materialize_agg_into_source raises")


# --- 2. the builders --------------------------------------------------------


def test_build_inmem_scan_plan() raises:
    var plan = build_inmem_scan_plan(_chunk(0, 3))
    _assert_inmem_scan(plan, String("__inmem_typed_k_3"), 1)
    _assert_two_columns(plan.output_schema)
    _assert_k(plan.scan_data_ref().source._in_memory.value().data[][0], 0, 3)
    var bare = build_inmem_scan_plan(_no_columns())
    _assert_inmem_scan(bare, String("__inmem_typed__0"), 1)
    var one = build_inmem_scan_plan(_one_column(0, 2))
    _assert_inmem_scan(one, String("__inmem_typed_k_2"), 1)


def test_build_inmem_scan_plan_batches() raises:
    var batches = Slab[RecordBatch].create(0)
    batches.append(_chunk(0, 3))
    batches.append(_chunk(3, 4))
    var plan = build_inmem_scan_plan_batches(batches^)
    _assert_inmem_scan(plan, String("__inmem_typed_batches_k_7"), 2)
    _assert_two_columns(plan.output_schema)
    ref data = plan.scan_data_ref().source._in_memory.value().data[]
    _assert_k(data[0], 0, 3)
    _assert_k(data[1], 3, 4)

    var bare = Slab[RecordBatch].create(0)
    bare.append(_no_columns())
    bare.append(_no_columns())
    _assert_inmem_scan(
        build_inmem_scan_plan_batches(bare^),
        String("__inmem_typed_batches__0"),
        2,
    )

    var single = Slab[RecordBatch].create(0)
    single.append(_one_column(0, 2))
    single.append(_one_column(2, 3))
    _assert_inmem_scan(
        build_inmem_scan_plan_batches(single^),
        String("__inmem_typed_batches_k_5"),
        2,
    )


def test_batches_with_different_schemas_raise() raises:
    var renamed = Slab[RecordBatch].create(0)
    renamed.append(_chunk(0, 2))
    renamed.append(_renamed(2))
    var raised = False
    try:
        _ = build_inmem_scan_plan_batches(renamed^)
    except e:
        raised = True
        assert_true(String(e).find("schemas disagree") >= 0, String(e))
    assert_true(raised, "a renamed column raises")
    var counts = Slab[RecordBatch].create(0)
    counts.append(_chunk(0, 2))
    counts.append(_one_column(0, 2))
    raised = False
    try:
        _ = build_inmem_scan_plan_batches(counts^)
    except e:
        raised = True
        assert_true(String(e).find("schemas disagree") >= 0, String(e))
    assert_true(raised, "a different column count raises")


def test_zero_batches_raise() raises:
    var raised = False
    try:
        _ = build_inmem_scan_plan_batches(Slab[RecordBatch].create(0))
    except e:
        raised = True
        assert_true(String(e).find("zero batches") >= 0, String(e))
    assert_true(raised)


# --- 3. the Table door ------------------------------------------------------


def test_table_of_several_chunks_keeps_them() raises:
    var chunks: List[RecordBatch] = [_chunk(0, 2), _chunk(2, 1), _chunk(3, 3)]
    var plan = build_inmem_scan_plan_table(Table.from_chunks(chunks^, _schema()))
    _assert_inmem_scan(plan, String("__inmem_typed_batches_k_6"), 3)
    ref data = plan.scan_data_ref().source._in_memory.value().data[]
    _assert_k(data[0], 0, 2)
    _assert_k(data[1], 2, 1)
    _assert_k(data[2], 3, 3)


def test_table_of_two_chunks_keeps_them() raises:
    var chunks: List[RecordBatch] = [_chunk(0, 2), _chunk(2, 3)]
    var plan = build_inmem_scan_plan_table(Table.from_chunks(chunks^, _schema()))
    _assert_inmem_scan(plan, String("__inmem_typed_batches_k_5"), 2)
    ref data = plan.scan_data_ref().source._in_memory.value().data[]
    _assert_k(data[0], 0, 2)
    _assert_k(data[1], 2, 3)


def test_table_of_one_chunk_is_the_single_batch_plan() raises:
    var chunks: List[RecordBatch] = [_chunk(0, 4)]
    var plan = build_inmem_scan_plan_table(Table.from_chunks(chunks^, _schema()))
    _assert_inmem_scan(plan, String("__inmem_typed_k_4"), 1)
    _assert_k(plan.scan_data_ref().source._in_memory.value().data[][0], 0, 4)


def test_empty_table_keeps_its_schema() raises:
    var plan = build_inmem_scan_plan_table(
        Table.from_chunks(List[RecordBatch](), _schema())
    )
    _assert_inmem_scan(plan, String("__inmem_typed_k_0"), 1)
    _assert_two_columns(plan.output_schema)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
