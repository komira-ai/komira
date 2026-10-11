# =============================================================================
# komira_op_typed_source_api.avro_typed_source -- the Avro OCF row-format
#   source conformer: `AvroFileSource[FS]` (a `TypedSource`) and
#   `AvroReader[FS]` (a `SourceReader`).
# =============================================================================
#
# Avro OCF is a ROW-major format. The row path does not run a source's
#   column leaves: the caller routes a row-format scan to the row-streaming
#   driver off the lazy scan plan that `AvroReader.build_scan_plan` builds. So
#   `AvroFileSource.materialize_into_source` and the grouped-agg leaves RAISE:
#   a call reaching them is a misroute, reported rather than mishandled.
#
# WHAT `AvroFileSource` CARRIES: the live FS only. The inferred schema rides
#   on the lazy plan's scan leaf, so `build_source` is a pure FS move and no
#   full-file decode happens at READ. The FS is carried for symmetry with the
#   parquet conformer, so that a later cloud read names only its own FS.
#
# Pointers: `AvroFileSource._fs` and `AvroReader._fs` are plain owned
#   values. No `UnsafePointer`, no wildcard origin, no `unsafe_from_address`.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_async_api.token import CancellationToken
from komira_arrow_ipc.chunked_read import read_chunked
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan
from komira_physical_plan.physical_plan import ParquetSourceData, MorselOp
from komira_scan_source.avro_source import AvroSource
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_fs.file_system import FileSystem
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from komira_avro import decode_ocf_header, ResolutionTable
from komira_column_format.column_format_storage import ColDescriptor
from komira_op_agg_row_api.agg_spec import AggSpec
from komira_engine_runtime.morsel_sizing_policy import MorselSizingPolicy
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_scan_source.scan_registry import ScanRegistry

from .typed_source import TypedSource, SourceReader


# =============================================================================
# struct AvroFileSource[FS] -- the Avro OCF (row) TypedSource conformer.
# =============================================================================
struct AvroFileSource[FS: FileSystem = LocalFs[NoopSink]](
    TypedSource, Movable, Deinitable
):
    """The Avro OCF `TypedSource` conformer, a ROW-major source.

    The row path reads the Avro OCF through the row-streaming driver off the lazy
    scan plan; it does not call this source's column collect leaf.
    `AvroFileSource[LocalFs]` (the default) names no cloud backend."""

    # Bind the `TypedSource` trait's associated `Fs` to this struct's `FS`.
    comptime Fs = Self.FS

    var _fs: Self.FS
    """The live FS. The schema is not a field: the row collect reads it off the
    lazy plan's scan leaf, which `AvroReader.build_scan_plan` built with the
    inferred schema."""

    def __init__(out self, var fs: Self.FS):
        self._fs = fs^

    def clone(self) raises -> Self:
        return AvroFileSource[Self.FS](self._fs.clone())

    def descriptor(self) raises -> SourceVariant:
        """The source-identity descriptor. The row driver reads the source path
        off the lazy plan's scan leaf, not off this, so an empty parquet marker
        matches the parquet conformer's shape (nothing on the materialize hot
        path reads identity from here)."""
        var sv = SourceVariant(ParquetSource(String(""), Schema()))
        return sv^

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
        """The column collect leaf. RAISES for a Avro OCF (row) source: the caller
        routes a row source to the row-streaming driver, so a call here is a
        misroute."""
        _ = node_id
        _ = pq_data
        _ = operators
        _ = policy
        _ = count_only
        _ = cancel_token^
        _ = dyn_filter_arc^
        _ = dyn_filter_key^
        _ = extra_pushed_filter^
        raise Error(
            "AvroFileSource.materialize_into_source: a ROW source does not run the"
            " COLUMN collect leaf — the FOUNDATION frame dispatches on"
            " `S.orientation` and routes a ROW source to `execute_row_streaming`."
            " Reaching this leaf means the orientation dispatch was bypassed (a"
            " misroute)."
        )

    def resolve_agg_scan_schema(
        self,
        pq_data: ParquetSourceData,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> Schema:
        """The agg-descriptor pre-pass. RAISES: an aggregation over a Avro OCF
        source is not served by this leaf."""
        _ = pq_data
        _ = footer_cache
        raise Error(
            "AvroFileSource.resolve_agg_scan_schema: ROW-source breaker leaves (agg"
            " over Avro) are served row-native by `execute_row_streaming`, not"
            " this parquet-fused leaf."
        )

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
        """The grouped-agg breaker leaf. RAISES: an aggregation over a Avro OCF
        source is not served by this parquet-fused leaf."""
        _ = pq_data
        _ = operators
        _ = key_descriptors^
        _ = agg_descriptors^
        _ = output_schema^
        _ = policy
        _ = footer_cache
        _ = cancel_token^
        raise Error(
            "AvroFileSource.materialize_agg_into_source: ROW-source breaker leaves"
            " are served row-native by `execute_row_streaming`, not the"
            " parquet-fused agg leaf."
        )


# =============================================================================
# struct AvroReader[FS] -- the Avro OCF SourceReader conformer.
# =============================================================================
struct AvroReader[FS: FileSystem = LocalFs[NoopSink]](
    SourceReader, Movable, Deinitable
):
    """The Avro OCF `SourceReader` conformer: `comptime Source = AvroFileSource[FS]`; it
    holds one live `fs: FS`.

    `FS` defaults to `LocalFs[NoopSink]`. `build_scan_plan` parses the OCF
    header schema (no per-record decode) and returns a
    `LogicalPlan.scan_from_source(SourceVariant(AvroSource(path, schema)),
    schema)` scan node; the Avro source kind declares the ROW orientation.
    `build_source` moves the FS into a `AvroFileSource[FS]`."""

    # Bind the SourceReader trait's associated types to this struct's params.
    comptime Fs = Self.FS
    comptime Source = AvroFileSource[Self.FS]

    var _fs: Optional[Self.FS]
    """The live FS, held in an `Optional` so that `build_source` can `.take()`
    it out of `self` without a partial move. The reader is single-use, so the
    field is `Some` at the one `.take()` site."""

    def __init__(out self, var fs: Self.FS):
        self._fs = Optional[Self.FS](fs^)

    def build_source(var self) raises -> Self.Source:
        # `Optional.take` leaves `self._fs` None, so `self` destroys cleanly;
        # the live FS moves into the returned source.
        var fs = self._fs.take()
        return AvroFileSource[Self.FS](fs^)

    def build_scan_plan(self, path: String) raises -> LogicalPlan:
        # Parse the OCF header schema up front (only the header is touched; no
        # per-record decode at read time), then a
        # `LogicalPlan.scan_from_source(SourceVariant(AvroSource(path, schema)),
        # schema)` scan node. No source-kind argument: the Avro source kind
        # declares ROW, and the scan node derives it.
        var src_buf = read_chunked(path)
        var full = src_buf.view_range_ro(0, src_buf.len()).into_span()
        var header = decode_ocf_header(full)
        var avro_schema = header.parse_schema()
        var table = ResolutionTable.identity(avro_schema)
        var schema = table.out_schema.copy()
        var av = AvroSource(String(path), schema.copy())
        var sv = SourceVariant(av^)
        var plan = LogicalPlan.scan_from_source(sv^, schema^)
        return plan^


def default_local_avro_reader() raises -> AvroReader[LocalFs[NoopSink]]:
    """The default local Avro OCF reader, `AvroReader[LocalFs[NoopSink]]`. A
    concrete (non-generic) constructor, as `default_local_csv_reader`."""
    return AvroReader[LocalFs[NoopSink]](LocalFs[NoopSink].new())
