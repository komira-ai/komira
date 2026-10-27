# =============================================================================
# komira_dispatch_sources.inmem_source -- `InMemSource`, the typed in-memory
#   source: a `TypedSource` over a resident `RecordBatch`, and the builders of
#   the `SCAN(SOURCE_IN_MEMORY)` plan node it is read through.
# =============================================================================
#
# A typed in-memory source holds one resident batch by value. There is no file
# system read: the batch is the data. `comptime Fs` is bound to
# `LocalFs[NoopSink]` only because the trait requires a file system; nothing
# reads through it, and it names no cloud backend.
#
# The batch the in-memory terminal resolves is the one carried inline on the
# plan's `SCAN(SOURCE_IN_MEMORY)` node (`build_inmem_scan_plan` and its
# multi-batch and `Table` forms). The source keeps its own copy for `clone`
# and `descriptor`.
#
# The trait's collect and grouped-agg leaves are shaped for parquet (they take
# `ParquetSourceData`, a `ParquetMetadataCache`, a `MorselOp` Slab). An
# in-memory scan is resolved by the in-memory terminal instead, so those two
# leaves are never called for an `InMemSource`; they raise, so a misroute fails
# with a message rather than producing a wrong shape. `resolve_agg_scan_schema`
# returns the resident batch's schema.
#
# Pointers: the batch is a plain owned value held in an `Optional` (moved out
# with `Optional.take`). No `UnsafePointer`, no wildcard origin.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_column_format.column_format_storage import ColDescriptor
from komira_column_kernels.compiler_helpers import copy_batch
from komira_engine_runtime.morsel_sizing_policy import MorselSizingPolicy
from komira_fs.local_fs import LocalFs
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_op_agg_row_api.agg_spec import AggSpec
from komira_op_typed_source_api.typed_source import TypedSource
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import ParquetSourceData, MorselOp
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.scan_registry import ScanRegistry
from komira_scan_source.source_variant import SourceVariant


struct InMemSource(TypedSource, Movable, Deinitable):
    """The in-memory `TypedSource`: one resident `RecordBatch`, no file system
    read.

    `comptime Fs` is `LocalFs[NoopSink]`, which nothing reads through. The
    parquet-shaped collect and grouped-agg leaves raise (the in-memory terminal
    resolves the batch carried on the plan instead); `clone` deep-copies the
    batch, `descriptor` wraps a copy as a `SourceVariant`, and
    `resolve_agg_scan_schema` returns its schema."""

    comptime Fs = LocalFs[NoopSink]

    var _batch: Optional[RecordBatch]
    """The resident batch. Set from construction until `take_batch` moves it
    out; `take_batch`, `clone`, `descriptor` and `resolve_agg_scan_schema`
    raise once it is gone."""

    def __init__(out self, var batch: RecordBatch):
        self._batch = Optional[RecordBatch](batch^)

    def take_batch(mut self) raises -> RecordBatch:
        """Move the resident batch out; the source holds none afterwards.

        Raises:
            When the batch was already taken."""
        self._require_batch("take_batch")
        return self._batch.take()

    def _require_batch(self, what: StaticString) raises:
        if not self._batch:
            raise Error(
                String("InMemSource.")
                + String(what)
                + ": the resident batch was already taken by take_batch"
            )

    def clone(self) raises -> Self:
        """An independent source over a deep copy (`copy_batch`) of the
        resident batch.

        Raises:
            When the batch was already taken."""
        self._require_batch("clone")
        return InMemSource(copy_batch(self._batch.value()))

    def descriptor(self) raises -> SourceVariant:
        """The `SOURCE_IN_MEMORY` descriptor: an unnamed `InMemorySource` over
        a deep copy of the resident batch.

        Raises:
            When the batch was already taken."""
        self._require_batch("descriptor")
        var in_mem = InMemorySource.from_record_batch(
            copy_batch(self._batch.value()), None
        )
        return SourceVariant(in_mem^)

    def materialize_into_source(
        self,
        node_id: Int,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        pq_data: ParquetSourceData,
        operators: Slab[MorselOp],
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
        count_only: Bool,
        var dyn_filter_arc: Optional[ArcPointer[DynamicJoinFilter]],
        var dyn_filter_key: String,
        var extra_pushed_filter: Optional[Expr],
        scan_registry: ScanRegistry = ScanRegistry(unbound=True),
    ) raises -> RecordBatch:
        """Raises: the parquet collect leaf is never called for an in-memory
        source (the in-memory terminal resolves the batch carried on the
        plan)."""
        _ = node_id
        _ = pq_data
        _ = operators
        _ = policy
        _ = count_only
        _ = dyn_filter_arc^
        _ = dyn_filter_key^
        _ = extra_pushed_filter^
        _ = cancel_token^
        raise Error(
            "InMemSource.materialize_into_source: an in-memory source has no"
            " parquet collect leaf; the in-memory terminal resolves the batch"
            " carried on the plan's SCAN(SOURCE_IN_MEMORY) node"
        )

    def resolve_agg_scan_schema(
        self,
        pq_data: ParquetSourceData,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> Schema:
        """The resident batch's schema (there is no footer to read).

        Raises:
            When the batch was already taken."""
        self._require_batch("resolve_agg_scan_schema")
        _ = pq_data
        _ = footer_cache
        return self._batch.value().schema.copy()

    def materialize_agg_into_source(
        self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        pq_data: ParquetSourceData,
        operators: Slab[MorselOp],
        var key_descriptors: List[ColDescriptor],
        var agg_descriptors: List[AggSpec],
        var output_schema: Schema,
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> RecordBatch:
        """Raises: the parquet grouped-agg leaf is never called for an
        in-memory source (the in-memory terminal aggregates the batch carried
        on the plan)."""
        _ = pq_data
        _ = operators
        _ = key_descriptors^
        _ = agg_descriptors^
        _ = output_schema^
        _ = policy
        _ = footer_cache
        _ = cancel_token^
        raise Error(
            "InMemSource.materialize_agg_into_source: an in-memory source has"
            " no parquet grouped-agg leaf; the in-memory terminal aggregates the"
            " batch carried on the plan's SCAN(SOURCE_IN_MEMORY) node"
        )


def _schema_of(imm batch: RecordBatch) -> Schema:
    """A schema of `batch`'s fields: name, Arrow type and nullability."""
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(
            Field(
                batch.schema.field_name(i),
                batch.schema.field_arrow_type(i),
                batch.schema.field_nullable(i),
            )
        )
    return sb.build()


def _scan_name(
    prefix: String, imm first: RecordBatch, total_rows: Int
) -> String:
    """`<prefix><first column>_<total_rows>`; the first column's name is empty
    for a batch with no columns."""
    var suffix = String("")
    if first.num_columns() > 0:
        suffix = first.schema.field_name(0)
    return prefix + suffix + "_" + String(total_rows)


def _require_same_fields(imm first: RecordBatch, imm other: RecordBatch) raises:
    """Raise unless `other` has `first`'s column count, names and types."""
    var n = first.schema.num_columns()
    var same = other.schema.num_columns() == n
    if same:
        for i in range(n):
            if (
                first.schema.field_name(i) != other.schema.field_name(i)
                or first.schema.field_arrow_type(i)
                != other.schema.field_arrow_type(i)
            ):
                same = False
                break
    if not same:
        raise Error(
            "build_inmem_scan_plan_batches: the batches' schemas disagree"
            " (column count, names or types)"
        )


def build_inmem_scan_plan(var batch: RecordBatch) raises -> LogicalPlan:
    """A `SCAN(SOURCE_IN_MEMORY)` plan node carrying `batch` inline, as the
    one batch of an `InMemorySource`.

    The scan's schema is the batch's fields (name, type, nullability). The
    source is named `__inmem_typed_<first column>_<rows>` (`<first column>`
    is empty for a batch with no columns). Plan structure only: nothing is
    read or copied."""
    var schema = _schema_of(batch)
    var name = _scan_name(String("__inmem_typed_"), batch, batch.num_rows())
    var in_mem = InMemorySource.from_record_batch(
        batch^, Optional[String](name^)
    )
    var source = SourceVariant(in_mem^)
    return LogicalPlan.scan_from_source(source^, schema^)


def build_inmem_scan_plan_batches(
    var batches: Slab[RecordBatch],
) raises -> LogicalPlan:
    """A `SCAN(SOURCE_IN_MEMORY)` plan node carrying every batch of `batches`
    inline, in order, as one `InMemorySource`.

    The batches share one schema (column count, names and types); the scan's
    schema is the first batch's fields. The source is named
    `__inmem_typed_batches_<first column>_<total rows>`. Plan structure only.

    Raises:
        When `batches` is empty (there is no batch to take the schema from),
        or a batch's column count, names or types differ from the first's.
    """
    if len(batches) == 0:
        raise Error(
            "build_inmem_scan_plan_batches: zero batches; the scan's schema is"
            " taken from the first batch"
        )
    var schema = _schema_of(batches[0])
    var total_rows = 0
    for i in range(len(batches)):
        _require_same_fields(batches[0], batches[i])
        total_rows += batches[i].num_rows()
    var name = _scan_name(
        String("__inmem_typed_batches_"), batches[0], total_rows
    )
    var in_mem = InMemorySource.from_record_batches(
        batches^, Optional[String](name^)
    )
    var source = SourceVariant(in_mem^)
    return LogicalPlan.scan_from_source(source^, schema^)


def build_inmem_scan_plan_table(var table: Table) raises -> LogicalPlan:
    """A `SCAN(SOURCE_IN_MEMORY)` plan node carrying `table`'s chunks inline,
    without concatenating them.

    The chunk count picks the builder:
      * more than one chunk: `build_inmem_scan_plan_batches` over the chunks,
        in order (the in-memory leaf folds them back together in input order);
      * one chunk: `build_inmem_scan_plan` over that chunk, moved out;
      * no chunk: `build_inmem_scan_plan` over `Table.to_record_batch()`'s
        0-row batch, which carries the table's full schema (a batch with no
        columns would make a later projection fail to find its columns).
    The one- and zero-chunk plans are the ones `build_inmem_scan_plan` builds
    over the table's single batch, name included."""
    var n = table.num_chunks()
    if n > 1:
        var chunks = table.take_chunks()
        return build_inmem_scan_plan_batches(chunks^)
    if n == 1:
        var chunks = table.take_chunks()
        return build_inmem_scan_plan(chunks.take_at(0))
    return build_inmem_scan_plan(table^.to_record_batch())
