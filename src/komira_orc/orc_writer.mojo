# =============================================================================
# orc_writer.mojo — ORC file writer orchestration.
# =============================================================================
#
# The inverse of the read path (orc_reader.mojo): given a RecordBatch + Arrow schema this
#   1. Builds the ORC Type[] schema tree (root struct + primitive children) from
#      the Arrow schema (the inverse of orc_node_to_arrow / OrcSchema lift).
#   2. Chunks rows into stripes (row_index_stride-based threshold).
#   3. Emits each stripe via stripe_emit (PRESENT / DATA / LENGTH streams,
#      codec-compressed + chunk-framed).
#   4. Accumulates per-stripe + per-file statistics.
#   5. Assembles the file: "ORC" magic + stripe bodies + Metadata + Footer +
#      PostScript + 1-byte PostScript length.
#
# Scope (correctness-first): flat root-struct of primitive columns
# (BOOLEAN / TINYINT / SMALLINT / INT / BIGINT / DATE / FLOAT / DOUBLE /
# STRING). DIRECT_V2 encoding (RLEv2 Short Repeat + Direct). Stripes are
# emitted one at a time; the streams within a stripe can be compressed in
# parallel (stream_compress_parallel). Nested STRUCT/LIST/MAP/UNION write,
# dictionary write and TIMESTAMP/DECIMAL/BINARY write are not supported yet;
# the reader handles all of them, so the round-trip bar (self-decode) is met
# for the supported columns.
#
# The acceptance bar is SELF-ROUND-TRIP: write -> read back via the reader ->
# assert equality, across all 6 codecs.
#
# Encapsulation: public API takes a borrowed RecordBatch + schema and a path /
# returns owned List[UInt8]. No UnsafePointer crosses any module boundary.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema

from .footer import (
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    orc_compression_name,
)
from .orc_schema import (
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_DATE,
    ORC_KIND_STRUCT,
)
from .stripe_emit import (
    emit_stripe,
    emit_stripe_with_dispatcher,
    StripeStreams,
    ColumnStats,
    build_col_encoders,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from .protobuf_writer import (
    encode_type_node,
    encode_stripe_information,
    encode_stripe_footer,
    encode_post_script,
    encode_footer,
    encode_metadata,
    encode_stripe_statistics,
)


# =============================================================================
# OrcWriterOptions.
# =============================================================================


struct OrcWriterOptions(Copyable, Movable):
    """ORC writer configuration.

    `row_index_stride` is the per-stride row count (default 10000). When
    `stripe_size_rows <= row_index_stride` (the default) each stripe holds
    one stride and the stripe IS the stride. When `stripe_size_rows >
    row_index_stride`, a stripe holds multiple strides — required for
    sub-stripe stride skip. `emit_row_index` toggles ROW_INDEX emission (per-
    stride statistics)."""

    var compression: Int  # ORC CompressionKind enum (default ZSTD)
    var row_index_stride: Int  # rows per stride (default 10000)
    var writer_timezone: String
    var stripe_size_rows: Int  # max rows per stripe (default = row_index_stride)
    var emit_row_index: Bool  # emit ROW_INDEX streams (stride skip)
    # Per-column bloom filter emission. `bloom_columns` lists the
    # OUTPUT column NAMES to write a BLOOM_FILTER_UTF8 stream for (empty =
    # default OFF, no bloom). `bloom_fpp` is the target false-positive rate
    # (canonical writer default 0.01 per orc.bloom.filter.fpp). Bloom is
    # per-stride, so it requires emit_row_index=True (the stripe must be split
    # into the same strides the bloom indexes).
    var bloom_columns: List[String]
    var bloom_fpp: Float64

    def __init__(
        out self, compression: Int, row_index_stride: Int, writer_timezone: String
    ):
        """3-arg ctor: stripe == stride, no ROW_INDEX (the default layout)."""
        self.compression = compression
        self.row_index_stride = row_index_stride
        self.writer_timezone = writer_timezone
        self.stripe_size_rows = row_index_stride
        self.emit_row_index = False
        self.bloom_columns = List[String]()
        self.bloom_fpp = 0.01

    def __init__(
        out self,
        compression: Int,
        row_index_stride: Int,
        writer_timezone: String,
        stripe_size_rows: Int,
        emit_row_index: Bool,
    ):
        self.compression = compression
        self.row_index_stride = row_index_stride
        self.writer_timezone = writer_timezone
        self.stripe_size_rows = stripe_size_rows
        self.emit_row_index = emit_row_index
        self.bloom_columns = List[String]()
        self.bloom_fpp = 0.01

    def __init__(
        out self,
        compression: Int,
        row_index_stride: Int,
        writer_timezone: String,
        stripe_size_rows: Int,
        emit_row_index: Bool,
        var bloom_columns: List[String],
        bloom_fpp: Float64,
    ):
        self.compression = compression
        self.row_index_stride = row_index_stride
        self.writer_timezone = writer_timezone
        self.stripe_size_rows = stripe_size_rows
        self.emit_row_index = emit_row_index
        self.bloom_columns = bloom_columns^
        self.bloom_fpp = bloom_fpp

    def copy(self) -> Self:
        return OrcWriterOptions(
            self.compression,
            self.row_index_stride,
            self.writer_timezone,
            self.stripe_size_rows,
            self.emit_row_index,
            self.bloom_columns.copy(),
            self.bloom_fpp,
        )

    @staticmethod
    def default() -> OrcWriterOptions:
        return OrcWriterOptions(ORC_COMPRESSION_ZSTD, 10000, String("UTC"))

    @staticmethod
    def with_stride(
        compression: Int,
        row_index_stride: Int,
        stripe_size_rows: Int,
        emit_row_index: Bool,
    ) -> OrcWriterOptions:
        """Construct options for a multi-stride stripe layout (stride skip)."""
        return OrcWriterOptions(
            compression,
            row_index_stride,
            String("UTC"),
            stripe_size_rows,
            emit_row_index,
        )

    @staticmethod
    def with_bloom(
        compression: Int,
        row_index_stride: Int,
        stripe_size_rows: Int,
        var bloom_columns: List[String],
        bloom_fpp: Float64 = 0.01,
    ) -> OrcWriterOptions:
        """Per-column bloom emission on a multi-stride layout. Implies
        emit_row_index=True (bloom is indexed at stride granularity)."""
        return OrcWriterOptions(
            compression,
            row_index_stride,
            String("UTC"),
            stripe_size_rows,
            True,
            bloom_columns^,
            bloom_fpp,
        )


# =============================================================================
# Arrow type -> ORC Type.Kind (inverse of orc_node_to_arrow primitive arms).
# =============================================================================


def _arrow_to_orc_kind(at: ArrowType) raises -> Int:
    if at == ArrowType.BOOL:
        return ORC_KIND_BOOLEAN
    elif at == ArrowType.INT8:
        return ORC_KIND_BYTE
    elif at == ArrowType.INT16:
        return ORC_KIND_SHORT
    elif at == ArrowType.INT32:
        return ORC_KIND_INT
    elif at == ArrowType.INT64:
        return ORC_KIND_LONG
    elif at == ArrowType.FLOAT32:
        return ORC_KIND_FLOAT
    elif at == ArrowType.FLOAT64:
        return ORC_KIND_DOUBLE
    elif at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
        return ORC_KIND_STRING
    elif at == ArrowType.DATE32:
        return ORC_KIND_DATE
    raise Error(
        String("OrcWriteError.UNSUPPORTED_TYPE: Arrow type ")
        + String(at)
        + " is not yet supported by the ORC writer (it writes primitive"
        " columns; nested / decimal / timestamp / binary are not supported)"
    )


# =============================================================================
# Build the ORC schema (Type[] node protos) + column-id map from Arrow schema.
# =============================================================================
#
# Flat layout: node 0 is the root STRUCT, child i is node i+1. col_node_ids[i]
# = i+1, col_kinds[i] = ORC kind of column i. n_schema_nodes = 1 + n_cols.


@fieldwise_init
struct _SchemaPlan(Movable):
    var type_protos: List[List[UInt8]]
    var col_node_ids: List[Int]
    var col_kinds: List[Int]
    var n_nodes: Int


def _build_schema_plan(schema: Schema) raises -> _SchemaPlan:
    var n_cols = schema.num_columns()
    var type_protos = List[List[UInt8]]()
    var col_node_ids = List[Int]()
    var col_kinds = List[Int]()
    var field_names = List[String]()

    # Root struct: subtypes = [1, 2, ..., n_cols].
    var subtypes = List[Int]()
    for c in range(n_cols):
        subtypes.append(c + 1)
        field_names.append(schema.field_name(c))
    type_protos.append(
        encode_type_node(
            ORC_KIND_STRUCT, subtypes, field_names, 0, 0, 0
        )
    )

    for c in range(n_cols):
        var at = schema.field_arrow_type(c)
        var kind = _arrow_to_orc_kind(at)
        var empty_sub = List[Int]()
        var empty_names = List[String]()
        type_protos.append(
            encode_type_node(kind, empty_sub, empty_names, 0, 0, 0)
        )
        col_node_ids.append(c + 1)
        col_kinds.append(kind)

    return _SchemaPlan(
        type_protos^, col_node_ids^, col_kinds^, 1 + n_cols
    )


# =============================================================================
# Per-file stats merge (combine each stripe's per-column stats).
# =============================================================================


def _merge_stats(mut acc: ColumnStats, s: ColumnStats):
    var was_empty = acc.number_of_values == 0 and not acc.has_null
    acc.has_null = acc.has_null or s.has_null
    if s.is_int:
        acc.is_int = True
        if acc.number_of_values == 0:
            acc.int_min = s.int_min
            acc.int_max = s.int_max
        elif s.number_of_values > 0:
            if s.int_min < acc.int_min:
                acc.int_min = s.int_min
            if s.int_max > acc.int_max:
                acc.int_max = s.int_max
        acc.int_sum += s.int_sum
    elif s.is_double:
        acc.is_double = True
        if acc.number_of_values == 0:
            acc.dbl_min = s.dbl_min
            acc.dbl_max = s.dbl_max
        elif s.number_of_values > 0:
            if s.dbl_min < acc.dbl_min:
                acc.dbl_min = s.dbl_min
            if s.dbl_max > acc.dbl_max:
                acc.dbl_max = s.dbl_max
        acc.dbl_sum += s.dbl_sum
    elif s.is_string:
        acc.is_string = True
        if s.number_of_values > 0:
            if acc.number_of_values == 0:
                acc.str_min = s.str_min
                acc.str_max = s.str_max
            else:
                if s.str_min < acc.str_min:
                    acc.str_min = s.str_min
                if s.str_max > acc.str_max:
                    acc.str_max = s.str_max
        acc.str_total_len += s.str_total_len
    acc.number_of_values += s.number_of_values
    _ = was_empty


# =============================================================================
# Public: write a RecordBatch to ORC bytes.
# =============================================================================


def _write_orc_bytes_core[has_dispatcher: Bool, disp_o: Origin[mut=True]](
    batch: RecordBatch,
    opts: OrcWriterOptions,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> List[UInt8]:
    """Shared core: stripe loop + (parallel-or-serial) compress + assemble.

    The `has_dispatcher` comptime flag prunes the parallel/serial branch at
    compile time. The dispatcher entry / serial entry public functions
    select the right branch at the call site — no `MutAnyOrigin` reaches
    the dispatch in either path."""
    var schema = batch.schema.copy()
    if schema.num_columns() == 0:
        _ = cancel_token^
        raise Error("OrcWriteError.EMPTY_SCHEMA: RecordBatch has no columns")

    var plan = _build_schema_plan(schema)
    var codec = opts.compression
    var n_rows = batch.num_rows()
    var stride = opts.row_index_stride if opts.row_index_stride > 0 else 10000
    # Rows per stripe. Default = stride (stripe IS the stride). A multi-stride
    # layout passes a larger stripe so a stripe holds multiple strides.
    var stripe_rows = opts.stripe_size_rows if opts.stripe_size_rows > 0 else stride
    if stripe_rows < stride:
        stripe_rows = stride
    var ri_stride = stride if opts.emit_row_index else 0

    # Map bloom column NAMES -> per-output-column flags. Bloom requires
    # ROW_INDEX (a stride layout); if emit_row_index is off, no bloom is written.
    var bloom_col_flags = List[Bool]()
    var n_cols = schema.num_columns()
    for c in range(n_cols):
        var name = schema.field_name(c)
        var flag = False
        if opts.emit_row_index:
            for b in range(len(opts.bloom_columns)):
                if opts.bloom_columns[b] == name:
                    flag = True
                    break
        bloom_col_flags.append(flag)

    var out = List[UInt8]()
    # Leading "ORC" magic (3 bytes) = header.
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("R")))
    out.append(UInt8(ord("C")))

    # Per-stripe accumulation.
    var stripe_infos = List[List[UInt8]]()  # StripeInformation protos
    var stripe_stats_protos = List[List[UInt8]]()  # per-stripe StripeStatistics

    # File-level per-node stats accumulator.
    var file_stats = List[ColumnStats]()
    for _i in range(plan.n_nodes):
        file_stats.append(ColumnStats.empty())

    # Fetch each column's typed Arrow array ONCE for the whole file.
    # Re-fetching (and DEEP-COPYING the full column buffer) once per stripe in
    # every per-column helper would be O(n_stripes x total_column_bytes)
    # memcpy, which dominates write time on a many-stripe file. The encoder slab is borrowed (`ref`) by every `emit_stripe` call below; the
    # stripe loop slices into the already-fetched arrays by `row_start`.
    var encoders = build_col_encoders(batch, plan.col_kinds)

    var row_start = 0
    var emitted_any = False
    while row_start < n_rows or not emitted_any:
        var rc = n_rows - row_start
        if rc > stripe_rows:
            rc = stripe_rows
        if rc < 0:
            rc = 0
        emitted_any = True

        var stripe: StripeStreams
        comptime if has_dispatcher:
            var disp = dispatcher_ptr.value()
            # Per-stripe parallel finalize. The cancel token is consumed per
            # dispatch call; renew it for the next stripe. The token is
            # `CancellationToken.never()` in synchronous writer flows, so
            # re-creating it is cheap and matches the caller's intent
            # (never-cancel in the write_orc path).
            stripe = emit_stripe_with_dispatcher[disp_o](
                encoders,
                row_start,
                rc,
                plan.col_node_ids,
                plan.col_kinds,
                plan.n_nodes,
                codec,
                ri_stride,
                bloom_col_flags,
                opts.bloom_fpp,
                disp,
                CancellationToken.never(),
            )
        else:
            stripe = emit_stripe(
                encoders,
                row_start,
                rc,
                plan.col_node_ids,
                plan.col_kinds,
                plan.n_nodes,
                codec,
                ri_stride,
                bloom_col_flags,
                opts.bloom_fpp,
            )

        # Stripe layout on disk: [index streams][data streams][StripeFooter].
        # index_length = len(index_data) (ROW_INDEX), data_length =
        # len(data). The StripeFooter lists index Stream entries before data
        # Stream entries so the reader's cumulative-offset walk matches.
        var stripe_offset = len(out)
        var index_len = len(stripe.index_data)
        for i in range(index_len):
            out.append(stripe.index_data[i])
        var data_len = len(stripe.data)
        for i in range(data_len):
            out.append(stripe.data[i])

        # StripeFooter: index Stream protos FIRST, then data Stream protos.
        var all_streams = List[List[UInt8]]()
        for i in range(len(stripe.index_stream_protos)):
            all_streams.append(stripe.index_stream_protos[i].copy())
        for i in range(len(stripe.stream_protos)):
            all_streams.append(stripe.stream_protos[i].copy())
        var sf_proto = encode_stripe_footer(
            all_streams,
            stripe.encoding_protos,
            opts.writer_timezone,
        )
        var sf_framed = _frame_metadata(sf_proto, codec)
        for i in range(len(sf_framed)):
            out.append(sf_framed[i])

        stripe_infos.append(
            encode_stripe_information(
                stripe_offset, index_len, data_len, len(sf_framed), rc
            )
        )

        # Per-stripe StripeStatistics + merge into file stats.
        var stripe_col_stats = List[List[UInt8]]()
        for node in range(plan.n_nodes):
            stripe_col_stats.append(
                stripe.col_stats[node].to_column_statistics()
            )
            _merge_stats(file_stats[node], stripe.col_stats[node])
        stripe_stats_protos.append(encode_stripe_statistics(stripe_col_stats))

        row_start += rc
        if rc == 0:
            break

    var content_length = len(out) - 3  # bytes after the 3-byte header magic

    # Metadata blob (per-stripe stats) — compressed + framed.
    var metadata_proto = encode_metadata(stripe_stats_protos)
    var metadata_framed = _frame_metadata(metadata_proto, codec)
    var metadata_start = len(out)
    for i in range(len(metadata_framed)):
        out.append(metadata_framed[i])

    # Footer (schema + stripe directory + file stats) — compressed + framed.
    var file_stat_protos = List[List[UInt8]]()
    for node in range(plan.n_nodes):
        file_stat_protos.append(file_stats[node].to_column_statistics())
    var footer_proto = encode_footer(
        3,  # headerLength ("ORC")
        content_length,
        stripe_infos,
        plan.type_protos,
        n_rows,
        file_stat_protos,
        ri_stride,  # rowIndexStride (>0 when ROW_INDEX is emitted)
    )
    var footer_framed = _frame_metadata(footer_proto, codec)
    var footer_start = len(out)
    for i in range(len(footer_framed)):
        out.append(footer_framed[i])

    # PostScript (ALWAYS uncompressed).
    var ps_proto = encode_post_script(
        len(footer_framed),
        codec,
        _block_size_for(codec),
        0,  # version major
        12,  # version minor (ORC 0.12)
        len(metadata_framed),
        String("ORC"),
    )
    for i in range(len(ps_proto)):
        out.append(ps_proto[i])

    # 1-byte PostScript length.
    if len(ps_proto) > 255:
        raise Error("OrcWriteError.POSTSCRIPT_TOO_LARGE: > 255 bytes")
    out.append(UInt8(len(ps_proto)))

    _ = metadata_start
    _ = footer_start
    _ = cancel_token^
    return out^


def write_orc_bytes(
    batch: RecordBatch, opts: OrcWriterOptions
) raises -> List[UInt8]:
    """Encode a RecordBatch into a complete in-memory ORC file (serial entry
    — no dispatcher; per-stream codec compress runs inline).

    Delegates to `_write_orc_bytes_core[has_dispatcher=False]`. Self-round-
    trips through `read_orc_bytes` (the acceptance bar)."""
    return _write_orc_bytes_core[has_dispatcher=False, disp_o=MutAnyOrigin](
        batch,
        opts,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def write_orc_bytes_with_dispatcher[disp_o: Origin[mut=True]](
    batch: RecordBatch,
    opts: OrcWriterOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> List[UInt8]:
    """Dispatcher-aware sibling of `write_orc_bytes` — per-stream parallel
    codec compress via `LocalDispatcher.run_with_state`.

    Threads the caller-owned LocalDispatcher into `emit_stripe_with_dispatcher`
    so the per-stream codec compress within each stripe runs in parallel
    via `LocalDispatcher.run_with_state`. Stream order is preserved; on-
    disk bytes are byte-for-byte identical to the serial entry (same
    `compress_stream` per stream, same kind/column/length proto, same
    frame order).

    Acceptance: SELF-ROUND-TRIP through `read_orc_bytes` AND byte-identity
    vs `write_orc_bytes` for the same RecordBatch + opts."""
    return _write_orc_bytes_core[has_dispatcher=True, disp_o=disp_o](
        batch,
        opts,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


@always_inline
def _block_size_for(codec: Int) -> Int:
    """Compression block size for the PostScript header (256 KiB default)."""
    if codec == ORC_COMPRESSION_NONE:
        return 0
    return 256 * 1024


def _frame_metadata(proto: List[UInt8], codec: Int) raises -> List[UInt8]:
    """Frame a metadata protobuf blob via the file codec (chunk-framed for
    compressed codecs; raw for NONE) — mirrors stream framing."""
    from .orc_codec import compress_stream
    return compress_stream(proto, codec)


def write_orc_file(
    batch: RecordBatch, path: String, opts: OrcWriterOptions
) raises:
    """Write a RecordBatch to an ORC file on disk (serial entry)."""
    var bytes = write_orc_bytes(batch, opts)
    _write_bytes_to_file(path, bytes)


def write_orc_file_with_dispatcher[disp_o: Origin[mut=True]](
    batch: RecordBatch,
    path: String,
    opts: OrcWriterOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises:
    """Dispatcher-aware variant of `write_orc_file` — wires the dispatcher
    through to `write_orc_bytes_with_dispatcher` for parallel stream compress.
    """
    var bytes = write_orc_bytes_with_dispatcher[disp_o](
        batch, opts, dispatcher_ptr, cancel_token^,
    )
    _write_bytes_to_file(path, bytes)


def _write_bytes_to_file(path: String, bytes: List[UInt8]) raises:
    """Write owned bytes to a file (binary).

    Routes through `LocalFs[NoopSink].write_at` rather than the concrete
    POSIX file API. The 64 MiB chunking workaround for the Mojo stdlib
    >2 GB silent-flush bug lives inside `LocalFs.write_at` (single-write
    fast path for sub-64 MiB payloads; chunked at 64 MiB above that). This
    decouples the ORC writer from the file API, so other file-system sinks
    can plug in without codec changes."""
    from komira_fs.local_fs import LocalFs
    from komira_fs.file_system import WriteMode
    from komira_async.ops.waker_sink import NoopSink

    var fs = LocalFs[NoopSink].new()
    var f = fs.open_write(path, WriteMode.create_truncate())
    _ = fs.write_at(f, Span(bytes))
    fs.close_write(f^)
