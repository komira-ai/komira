# =============================================================================
# stripe_emit.mojo — ORC per-stripe stream emission (the writer path).
# =============================================================================
#
# The inverse of the column_decoder + orc_reader stripe-locate logic: given a row range of
# a RecordBatch, this emits one stripe's worth of per-column streams:
#   - PRESENT  (boolean RLE) — emitted only when the column has nulls.
#   - DATA     (integer / byte / boolean / raw-IEEE RLE per column type).
#   - LENGTH   (unsigned RLE) — for STRING / BINARY DIRECT columns.
# Each stream is compressed via the chosen codec (compress_stream, chunk-framed
# with isOriginal fallback), then catalogued in a StripeFooter with per-column
# ColumnEncoding entries. Per-column statistics (min/max/sum/null-count) are
# accumulated for the file + stripe stats.
#
# Column coverage: BOOLEAN / TINYINT / SMALLINT / INT / BIGINT / DATE /
# FLOAT / DOUBLE / STRING / BINARY (DIRECT encoding only — dictionary write is
# not supported; the reader handles both). Integer streams use DIRECT_V2
# (RLEv2), so the reader's `is_v2` path round-trips them.
#
# Encapsulation: all I/O is owned List[UInt8] / List[Column]; no UnsafePointer
# crosses any module boundary.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.large_string_array import LargeStringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from .footer import (
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DIRECT_V2,
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
    ORC_KIND_BINARY,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_DATE,
    ORC_KIND_STRUCT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
    orc_kind_name,
)
from .rle_encode import (
    encode_int_rle_v2,
    encode_boolean_rle,
    encode_byte_rle,
)
from .orc_codec import compress_stream
from .stream_compress_parallel import compress_streams_parallel
from .protobuf_writer import (
    encode_stream,
    encode_column_encoding,
    encode_integer_statistics,
    encode_double_statistics,
    encode_string_statistics,
    encode_column_statistics,
    encode_row_index,
    encode_row_index_entry,
    encode_bloom_filter,
    encode_bloom_filter_index,
)
from .footer import (
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_COMPRESSION_NONE,
)
from .bloom_filter import OrcBloomFilter, make_orc_bloom_filter
from .int_stats_sum import add_to_int_sum
from std.memory import bitcast


# =============================================================================
# _OrcColEncoder — per-column typed Arrow array fetched ONCE per file.
# =============================================================================
#
# Why: every `batch.column_as_*` accessor (`Column.as_primitive` / `as_string`
# / `as_boolean`) DEEP-COPIES the WHOLE column buffer, not just a stripe's
# slice. A writer that calls it from every per-column helper
# (`_column_present`, `_emit_*`, `_compute_chunk_stats`) for EACH stripe pays
# O(n_stripes x total_column_bytes) of memcpy — hundreds of GB for a
# multi-million-row file with a small stride — far more than codec or RLE
# encode.
#
# So each column's typed Arrow array is fetched ONCE per file into a
# `Slab[_OrcColEncoder]` (the same shape as the Avro writer's column
# encoders), and `ref` access is threaded through `emit_stripe` and every
# per-column helper so they index into the already-fetched array (slicing by
# `row_start`) instead of re-copying.
#
# `Slab` (not `List`) because `_OrcColEncoder` holds Movable-only Arrow arrays:
# `List[T]` requires `T: Copyable`, `Slab[T]` requires only `Movable` (the same
# reason as the Avro writer's encoder slab and the ORC reader's output channel).
# Exactly one typed-array Optional is populated, selected by `kind`.


struct _OrcColEncoder(Movable):
    """A per-column ORC encoder holding the typed Arrow array fetched ONCE for
    the whole file. `kind` is the ORC Type.Kind; exactly one of the typed-array
    Optionals below is populated (matching `kind`)."""

    var kind: Int
    var i8: Optional[PrimitiveArray[DType.int8]]
    var i16: Optional[PrimitiveArray[DType.int16]]
    var i32: Optional[PrimitiveArray[DType.int32]]
    var i64: Optional[PrimitiveArray[DType.int64]]
    var f32: Optional[PrimitiveArray[DType.float32]]
    var f64: Optional[PrimitiveArray[DType.float64]]
    var b: Optional[BooleanArray]
    var s: Optional[StringArray[HeapRegion]]
    # ★ THE INT64-OFFSET TWIN OF `s`. `orc_writer` maps BOTH
    # ArrowType.STRING and ArrowType.LARGE_STRING onto ORC_KIND_STRING (ORC
    # has one string kind; the offset width is an Arrow in-memory property,
    # not an ORC one) — so a promoted column arrives here under the same kind
    # as a narrow one. Exactly ONE of `s` / `ls` is populated
    # for a string column; `str_*` below is the accessor that does not care
    # which.
    var ls: Optional[LargeStringArray[HeapRegion]]

    def __init__(out self, kind: Int):
        self.kind = kind
        self.i8 = None
        self.i16 = None
        self.i32 = None
        self.i64 = None
        self.f32 = None
        self.f64 = None
        self.b = None
        self.s = None
        self.ls = None

    # --- width-agnostic string accessors ---
    #
    # ⚠ THESE EXIST BECAUSE THE PER-CELL OPERATIONS HAVE NO OFFSET WIDTH.
    # `is_null` is a validity-bitmap read and `get` returns an owned String;
    # neither depends on how the row was addressed. Only the two hot
    # SPAN loops in `_emit_string` genuinely have to branch on width, because
    # a `Span` carries the buffer's origin and the two arrays' spans are
    # different types.

    @always_inline
    def str_is_wide(self) -> Bool:
        """True iff this column was fetched as `large_string` (Int64 offsets)."""
        return self.ls.__bool__()

    @always_inline
    def str_null_count(self) -> Int:
        if self.ls:
            return self.ls.value().null_count
        return self.s.value().null_count

    @always_inline
    def str_is_null(self, row: Int) -> Bool:
        if self.ls:
            return self.ls.value().is_null(row)
        return self.s.value().is_null(row)

    def str_get(self, row: Int) raises -> String:
        if self.ls:
            return self.ls.value().get(row)
        return self.s.value().get(row)


def build_col_encoders(
    batch: RecordBatch, col_kinds: List[Int]
) raises -> Slab[_OrcColEncoder]:
    """Fetch each top-level column's typed Arrow array ONCE for the whole file
    (see the encoder header above). Returns a `Slab` indexed by output-column position."""
    var encoders = Slab[_OrcColEncoder]()
    for c in range(len(col_kinds)):
        var kind = col_kinds[c]
        var enc = _OrcColEncoder(kind)
        if kind == ORC_KIND_BOOLEAN:
            enc.b = batch.column_as_boolean(c)
        elif kind == ORC_KIND_BYTE:
            enc.i8 = batch.column_at(c).as_primitive[DType.int8]()
        elif kind == ORC_KIND_SHORT:
            enc.i16 = batch.column_at(c).as_primitive[DType.int16]()
        elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
            enc.i32 = batch.column_as_primitive_int32(c)
        elif kind == ORC_KIND_LONG:
            enc.i64 = batch.column_as_primitive_int64(c)
        elif kind == ORC_KIND_FLOAT:
            enc.f32 = batch.column_as_primitive_float32(c)
        elif kind == ORC_KIND_DOUBLE:
            enc.f64 = batch.column_as_primitive_float64(c)
        elif kind == ORC_KIND_STRING:
            # ⛔ BRANCH ON THE COLUMN'S OWN TAG, NOT THE ORC KIND. Both Arrow
            # string widths map to ORC_KIND_STRING (`orc_writer._orc_kind`), so
            # the kind cannot tell them apart. An unconditional
            # `column_as_string` would, for a promoted column, either pay a
            # whole-column narrowing copy (below 2 GiB) or RAISE (above it) —
            # the size at which `large_string` is the only representation.
            if batch.column_at(c).arrow_type == ArrowType.LARGE_STRING:
                enc.ls = batch.column_as_large_string(c)
            else:
                enc.s = batch.column_as_string(c)
        else:
            raise Error(
                String("OrcWriteError.UNSUPPORTED_TYPE: ORC Type.Kind ")
                + orc_kind_name(kind)
                + " write is not supported (nested / binary / decimal / ts)"
            )
        encoders.append(enc^)
    return encoders^


# =============================================================================
# ColumnStats — per-column statistics accumulated over a stripe (or file).
# =============================================================================


@fieldwise_init
struct ColumnStats(Copyable, Movable):
    """Accumulated stats for one column. The active fields depend on kind."""

    var number_of_values: Int  # non-null count
    var has_null: Bool
    var is_int: Bool
    var is_double: Bool
    var is_string: Bool
    var int_min: Int64
    var int_max: Int64
    var int_sum: Optional[Int64]  # None once the running sum overflowed
    var dbl_min: Float64
    var dbl_max: Float64
    var dbl_sum: Float64
    var str_min: String
    var str_max: String
    var str_total_len: Int64

    @staticmethod
    def empty() -> ColumnStats:
        return ColumnStats(
            0, False, False, False, False,
            Int64(0), Int64(0), Optional[Int64](Int64(0)),
            Float64(0), Float64(0), Float64(0),
            String(""), String(""), Int64(0),
        )

    def to_column_statistics(self) -> List[UInt8]:
        """Encode this ColumnStats into an ORC ColumnStatistics protobuf."""
        var int_bytes = List[UInt8]()
        var dbl_bytes = List[UInt8]()
        var str_bytes = List[UInt8]()
        if self.is_int and self.number_of_values > 0:
            int_bytes = encode_integer_statistics(
                self.int_min, self.int_max, self.int_sum
            )
        elif self.is_double and self.number_of_values > 0:
            dbl_bytes = encode_double_statistics(
                self.dbl_min, self.dbl_max, self.dbl_sum
            )
        elif self.is_string and self.number_of_values > 0:
            str_bytes = encode_string_statistics(
                self.str_min, self.str_max, self.str_total_len
            )
        return encode_column_statistics(
            self.number_of_values,
            self.has_null,
            int_bytes,
            dbl_bytes,
            str_bytes,
        )


# =============================================================================
# StripeStreams — the emitted streams + StripeFooter + stats for one stripe.
# =============================================================================


@fieldwise_init
struct _PendingStream(Copyable, Movable):
    """A raw (uncompressed) stream awaiting codec-compress in the finalize pass.

    Captured by `_append_stream` / `_emit_row_index_streams` / `_emit_one_bloom_stream`
    in emit order; consumed by `finalize_stripe_streams_*`. `is_index`
    distinguishes ROW_INDEX/BLOOM streams (go to `result.index_data` +
    `result.index_stream_protos`) from DATA streams (go to `result.data` +
    `result.stream_protos`). `kind` + `column` are the Stream proto fields."""
    var kind: Int
    var column: Int
    var is_index: Bool


struct StripeStreams(Movable):
    """One stripe's emitted streams + its StripeFooter + per-column stats.

    `emit_stripe` COLLECTS raw streams + emit-order descriptors during the per-column emit
    pass; the codec-compress + assemble step runs as a separate pass via
    `finalize_stripe_streams_serial` (the serial fallback, byte-identical to
    an inline compress) or `finalize_stripe_streams_parallel`
    (dispatcher-backed parallel compress, the perf path).

    After finalize:
      `index_data` is the concatenated INDEX-block stream bytes (ROW_INDEX +
      BLOOM_FILTER_UTF8) and `data` is the concatenated
      DATA-block stream bytes. On disk the stripe is laid out
      `[index_data][data]`; `index_length = len(index_data)`.
      `index_stream_protos` are the StripeFooter Stream entries for the index
      block (listed FIRST), `stream_protos` are the data-block Stream entries.
      The reader's cumulative-offset walk consumes them in that order.

    BEFORE finalize:
      `raw_streams` holds the raw bytes for every collected stream in
      emit order. `pending_descs[i]` describes how stream `i` should be
      filed (kind / column / index-vs-data). `index_data` / `data` /
      `*_stream_protos` are EMPTY until finalize runs."""

    var index_data: List[UInt8]
    var data: List[UInt8]
    var index_stream_protos: List[List[UInt8]]
    var stream_protos: List[List[UInt8]]
    var encoding_protos: List[List[UInt8]]
    var col_stats: List[ColumnStats]
    # Raw-stream collection (pre-finalize).
    var raw_streams: List[List[UInt8]]
    var pending_descs: List[_PendingStream]

    def __init__(out self):
        self.index_data = List[UInt8]()
        self.data = List[UInt8]()
        self.index_stream_protos = List[List[UInt8]]()
        self.stream_protos = List[List[UInt8]]()
        self.encoding_protos = List[List[UInt8]]()
        self.col_stats = List[ColumnStats]()
        self.raw_streams = List[List[UInt8]]()
        self.pending_descs = List[_PendingStream]()


# =============================================================================
# _spec_encoding_for_kind — map ORC Type.Kind to the spec-valid ColumnEncoding.
# =============================================================================
#
# Apache ORC spec (orc_proto.proto §ColumnEncoding.Kind) plus orc-cpp/pyarrow
# reader behavior: STRUCT/LIST/MAP/UNION/BOOLEAN/BYTE/FLOAT/DOUBLE columns
# MUST be encoded as DIRECT (kind=0); SHORT/INT/LONG/DATE/STRING/VARCHAR/
# CHAR/BINARY use DIRECT_V2 (kind=2) when the writer emits RLEv2 (which this
# writer does for the integer + length streams). Cross-impl readers
# (pyarrow.orc, orc-cpp) raise "Unknown encoding for FloatColumnReader" /
# "StructColumnReader" if they see DIRECT_V2 on a non-int column.


@always_inline
def _spec_encoding_for_kind(kind: Int) -> Int:
    if (
        kind == ORC_KIND_BOOLEAN
        or kind == ORC_KIND_BYTE
        or kind == ORC_KIND_FLOAT
        or kind == ORC_KIND_DOUBLE
        or kind == ORC_KIND_STRUCT
        or kind == ORC_KIND_LIST
        or kind == ORC_KIND_MAP
        or kind == ORC_KIND_UNION
    ):
        return ORC_ENCODING_DIRECT
    return ORC_ENCODING_DIRECT_V2


# =============================================================================
# emit_stripe — emit a contiguous row range of a RecordBatch as one stripe.
# =============================================================================
#
# `col_node_ids[c]` is the ORC schema-tree node id (column id) of top-level
# output column c; `col_kinds[c]` is its ORC Type.Kind. The ROOT struct is
# node 0 (it has no streams of its own in this flat layout, but its
# ColumnEncoding entry must be present at index 0). We emit one ColumnEncoding
# per schema node (root + each column) so StripeFooter.columns is indexed by
# node id (matching the reader's `sf.columns[col_id]` access).


def _emit_stripe_collect_raw(
    ref encoders: Slab[_OrcColEncoder],
    row_start: Int,
    row_count: Int,
    col_node_ids: List[Int],
    col_kinds: List[Int],
    n_schema_nodes: Int,
    codec: Int,
    row_index_stride: Int,
    bloom_col_flags: List[Bool],
    bloom_fpp: Float64,
) raises -> StripeStreams:
    """Inner emit pass that COLLECTS raw streams into the result without compressing. The
    finalize pass (serial or parallel) runs the codec compress + assembly.

    The leaf `_append_stream` / `_emit_row_index_streams` /
    `_emit_one_bloom_stream` collect raw bytes rather than
    compress-and-append."""
    var result = StripeStreams()

    # ColumnEncoding per schema node (root struct + every column). The ORC spec
    # constrains valid ColumnEncoding.Kind per Type.Kind (orc-cpp's column
    # readers REJECT non-spec kinds on read, even though this package's reader
    # tolerates them):
    #   - STRUCT / LIST / MAP / UNION : DIRECT only (no V2 variant exists for
    #     these structural columns).
    #   - BOOLEAN / BYTE              : DIRECT only (no varint stream; bit-RLE
    #     and byte-RLE have no V1/V2 split).
    #   - FLOAT / DOUBLE              : DIRECT only (raw IEEE bytes; no varint).
    #   - SHORT / INT / LONG / DATE   : DIRECT_V2 (this writer emits RLEv2).
    #   - STRING / VARCHAR / CHAR / BINARY : DIRECT_V2 (LENGTH stream uses
    #     RLEv2; no dictionary write yet).
    # Node 0 is the root STRUCT. Nodes 1..n correspond to col_kinds[0..n-1]
    # in flat layout. The writer does not emit nested types, so col_kinds
    # entries are always primitive.
    result.encoding_protos.append(
        encode_column_encoding(ORC_ENCODING_DIRECT, 0)  # root STRUCT
    )
    for c in range(len(col_kinds)):
        result.encoding_protos.append(
            encode_column_encoding(_spec_encoding_for_kind(col_kinds[c]), 0)
        )
    # Root struct stats (node 0): number_of_values = row_count, no per-type sub.
    var root_stats = ColumnStats.empty()
    root_stats.number_of_values = row_count

    # Per-node stats placeholder (root + columns), filled as we emit.
    for _node in range(n_schema_nodes):
        result.col_stats.append(ColumnStats.empty())
    result.col_stats[0] = root_stats^

    # ROW_INDEX (index block) FIRST so on-disk layout is [index][data] — the
    # writer concatenates result.index_data before result.data, and the
    # StripeFooter lists index streams before data streams.
    if row_index_stride > 0:
        _emit_row_index_streams(
            encoders,
            row_start,
            row_count,
            col_node_ids,
            col_kinds,
            row_index_stride,
            codec,
            bloom_col_flags,
            bloom_fpp,
            result,
        )

    for c in range(len(col_node_ids)):
        var node_id = col_node_ids[c]
        var kind = col_kinds[c]
        _emit_primitive_column(
            encoders[c], node_id, kind, row_start, row_count, codec, result
        )

    return result^


def emit_stripe(
    ref encoders: Slab[_OrcColEncoder],
    row_start: Int,
    row_count: Int,
    col_node_ids: List[Int],
    col_kinds: List[Int],
    n_schema_nodes: Int,
    codec: Int,
    row_index_stride: Int = 0,
    bloom_col_flags: List[Bool] = List[Bool](),
    bloom_fpp: Float64 = 0.01,
) raises -> StripeStreams:
    """Emit `[row_start, row_start+row_count)` of `batch` as one ORC stripe.
    Serial-fallback entry — no dispatcher; finalize runs codec compress inline.

    If `row_index_stride > 0`, a ROW_INDEX stream is emitted per column with one
    entry per `row_index_stride` rows (the per-stride statistics). The DATA
    streams remain whole-stripe (the reader post-decode-filters skipped
    strides; positions-based mid-stream seek is not implemented).

    `bloom_col_flags[c]` (when present and True) emits a per-stride
    BLOOM_FILTER_UTF8 stream for output column `c`, indexed at the same
    `row_index_stride` granularity. Bloom requires ROW_INDEX (a stride layout).

    A thin wrapper around `_emit_stripe_collect_raw` +
    `finalize_stripe_streams_serial`."""
    var result = _emit_stripe_collect_raw(
        encoders, row_start, row_count, col_node_ids, col_kinds,
        n_schema_nodes, codec, row_index_stride, bloom_col_flags, bloom_fpp,
    )
    finalize_stripe_streams_serial(result, codec)
    return result^


def emit_stripe_with_dispatcher[disp_o: Origin[mut=True]](
    ref encoders: Slab[_OrcColEncoder],
    row_start: Int,
    row_count: Int,
    col_node_ids: List[Int],
    col_kinds: List[Int],
    n_schema_nodes: Int,
    codec: Int,
    row_index_stride: Int,
    bloom_col_flags: List[Bool],
    bloom_fpp: Float64,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> StripeStreams:
    """Dispatcher-aware sibling of `emit_stripe` — parallel codec compress
    across the stripe's collected raw streams.

    Threads the caller-owned LocalDispatcher into `finalize_stripe_streams_parallel`
    so the per-stream codec compress runs in parallel via
    `LocalDispatcher.run_with_state`. Stream order is preserved; on-disk
    bytes are byte-for-byte identical to the serial entry (same compress
    call per stream, same kind/column/length, same frame order)."""
    var result = _emit_stripe_collect_raw(
        encoders, row_start, row_count, col_node_ids, col_kinds,
        n_schema_nodes, codec, row_index_stride, bloom_col_flags, bloom_fpp,
    )
    finalize_stripe_streams_parallel[disp_o](
        result, codec, dispatcher_ptr, cancel_token^,
    )
    return result^


# =============================================================================
# ROW_INDEX emission — per-stride statistics.
# =============================================================================
#
# For each column, walk the stripe row range in `stride`-sized chunks; for each
# chunk compute that stride's ColumnStats (min/max/null-count over the chunk),
# encode it into a RowIndexEntry, and accumulate one RowIndex per column. The
# RowIndex bytes go in the index block. positions[] is emitted empty — this
# package's stride-skip relies on the statistics sub-message; cross-tool readers
# tolerate the optional positions field.


def _emit_row_index_streams(
    ref encoders: Slab[_OrcColEncoder],
    row_start: Int,
    row_count: Int,
    col_node_ids: List[Int],
    col_kinds: List[Int],
    stride: Int,
    codec: Int,
    bloom_col_flags: List[Bool],
    bloom_fpp: Float64,
    mut result: StripeStreams,
) raises:
    for c in range(len(col_node_ids)):
        var node_id = col_node_ids[c]
        var kind = col_kinds[c]
        var entries = List[List[UInt8]]()
        var s = 0
        while s < row_count:
            var chunk = row_count - s
            if chunk > stride:
                chunk = stride
            var st = _compute_chunk_stats(
                encoders[c], kind, row_start + s, chunk
            )
            var stats_proto = st.to_column_statistics()
            var empty_positions = List[Int]()
            entries.append(
                encode_row_index_entry(empty_positions, stats_proto)
            )
            s += chunk
        var ri_raw = encode_row_index(entries)
        # COLLECT
        # the raw stream when codec wants compress; inline-frame when codec
        # is NONE. The (is_index=True) descriptor routes through
        # `result.index_data` + `result.index_stream_protos` at assemble time.
        if codec == ORC_COMPRESSION_NONE:
            result.index_stream_protos.append(
                encode_stream(ORC_STREAM_ROW_INDEX, node_id, len(ri_raw))
            )
            for k in range(len(ri_raw)):
                result.index_data.append(ri_raw[k])
        else:
            result.pending_descs.append(
                _PendingStream(ORC_STREAM_ROW_INDEX, node_id, True)
            )
            result.raw_streams.append(ri_raw^)

        # Emit the BLOOM_FILTER_UTF8 stream for this column right after
        # its ROW_INDEX (the reader matches streams by (kind, column), so the
        # per-column ROW_INDEX-then-BLOOM ordering is what orc-cpp writes).
        var want_bloom = c < len(bloom_col_flags) and bloom_col_flags[c]
        if want_bloom:
            _emit_one_bloom_stream(
                encoders[c], node_id, kind, row_start, row_count, stride,
                bloom_fpp, codec, result,
            )


def _emit_one_bloom_stream(
    ref enc: _OrcColEncoder,
    node_id: Int,
    kind: Int,
    row_start: Int,
    row_count: Int,
    stride: Int,
    fpp: Float64,
    codec: Int,
    mut result: StripeStreams,
) raises:
    """Build + emit one column's per-stride BloomFilterIndex."""
    var bloom_entries = List[List[UInt8]]()
    var s = 0
    while s < row_count:
        var chunk = row_count - s
        if chunk > stride:
            chunk = stride
        var bf = _build_stride_bloom(
            enc, kind, row_start + s, chunk, fpp
        )
        bloom_entries.append(
            encode_bloom_filter(bf.num_hash_functions, Span(bf.bitset))
        )
        s += chunk
    var bi_raw = encode_bloom_filter_index(bloom_entries)
    # COLLECT
    # the raw bloom stream when codec wants compress; inline-frame when NONE.
    if codec == ORC_COMPRESSION_NONE:
        result.index_stream_protos.append(
            encode_stream(ORC_STREAM_BLOOM_FILTER_UTF8, node_id, len(bi_raw))
        )
        for k in range(len(bi_raw)):
            result.index_data.append(bi_raw[k])
    else:
        result.pending_descs.append(
            _PendingStream(ORC_STREAM_BLOOM_FILTER_UTF8, node_id, True)
        )
        result.raw_streams.append(bi_raw^)


def _build_stride_bloom(
    ref enc: _OrcColEncoder,
    kind: Int,
    row_start: Int,
    row_count: Int,
    fpp: Float64,
) raises -> OrcBloomFilter:
    """Insert every NON-null value in `[row_start, +row_count)` of the column
    into a freshly-sized bloom filter (one per stride). Reads the typed array
    fetched ONCE in `build_col_encoders`. The hash kernel matches the column's
    ORC type: Wang64 for int/date/bool, Wang64-double for float/double,
    Murmur3-64 for string/binary."""
    var bf = make_orc_bloom_filter(row_count, fpp)
    if kind == ORC_KIND_LONG:
        ref arr = enc.i64.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_long(arr.get(r))
    elif kind == ORC_KIND_SHORT:
        ref arr = enc.i16.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_long(Int64(Int(arr.get(r))))
    elif kind == ORC_KIND_BYTE:
        ref arr = enc.i8.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_long(Int64(Int(arr.get(r))))
    elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
        ref arr = enc.i32.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_long(Int64(Int(arr.get(r))))
    elif kind == ORC_KIND_FLOAT:
        ref arr = enc.f32.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_double(Float64(arr.get(r)))
    elif kind == ORC_KIND_DOUBLE:
        ref arr = enc.f64.value()
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                bf.add_double(arr.get(r))
    elif kind == ORC_KIND_STRING:
        for r in range(row_start, row_start + row_count):
            if not enc.str_is_null(r):
                bf.add_string(enc.str_get(r))
    # Other kinds (boolean, binary, nested) — no bloom values added; the bloom
    # is empty-but-sized and will simply not prune (conservative).
    return bf^


def _compute_chunk_stats(
    ref enc: _OrcColEncoder, kind: Int, row_start: Int, row_count: Int
) raises -> ColumnStats:
    """Per-stride ColumnStats for one column over `[row_start, +row_count)`.
    Reads the typed array fetched ONCE in `build_col_encoders`."""
    var st = ColumnStats.empty()
    # Elide the second `_column_present`
    # (the first one is in `_emit_*`) when the column is fully valid. The
    # null_count field-read substitutes for the O(row_count) bitmap walk.
    var has_nulls = _enc_has_nulls(enc, kind)
    if has_nulls:
        var present = _column_present(enc, kind, row_start, row_count)
        st.has_null = _has_any_null(present)
    if kind == ORC_KIND_BOOLEAN:
        ref arr = enc.b.value()
        var nvals = 0
        if not has_nulls:
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    nvals += 1
        st.number_of_values = nvals
    elif kind == ORC_KIND_FLOAT:
        st.is_double = True
        ref arr = enc.f32.value()
        var first = True
        var nvals = 0
        if not has_nulls:
            for r in range(row_start, row_start + row_count):
                _acc_dbl(st, Float64(arr.get(r)), first)
                first = False
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    _acc_dbl(st, Float64(arr.get(r)), first)
                    first = False
                    nvals += 1
        st.number_of_values = nvals
    elif kind == ORC_KIND_DOUBLE:
        st.is_double = True
        ref arr = enc.f64.value()
        var first = True
        var nvals = 0
        if not has_nulls:
            for r in range(row_start, row_start + row_count):
                _acc_dbl(st, arr.get(r), first)
                first = False
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    _acc_dbl(st, arr.get(r), first)
                    first = False
                    nvals += 1
        st.number_of_values = nvals
    elif kind == ORC_KIND_STRING:
        st.is_string = True
        var first = True
        var nvals = 0
        var total_len: Int64 = 0
        if not has_nulls:
            for r in range(row_start, row_start + row_count):
                var sv = enc.str_get(r)
                total_len += Int64(len(sv.as_bytes()))
                if first:
                    st.str_min = sv
                    st.str_max = sv
                    first = False
                else:
                    if sv < st.str_min:
                        st.str_min = sv
                    if sv > st.str_max:
                        st.str_max = sv
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not enc.str_is_null(r):
                    var sv = enc.str_get(r)
                    total_len += Int64(len(sv.as_bytes()))
                    if first:
                        st.str_min = sv
                        st.str_max = sv
                        first = False
                    else:
                        if sv < st.str_min:
                            st.str_min = sv
                        if sv > st.str_max:
                            st.str_max = sv
                    nvals += 1
        st.number_of_values = nvals
        st.str_total_len = total_len
    else:
        # Integer family (BYTE / SHORT / INT / LONG / DATE).
        st.is_int = True
        var first = True
        var nvals = 0
        if kind == ORC_KIND_BYTE:
            ref arr = enc.i8.value()
            if not has_nulls:
                for r in range(row_start, row_start + row_count):
                    _acc_int(st, Int64(arr.get(r)), first)
                    first = False
                nvals = row_count
            else:
                for r in range(row_start, row_start + row_count):
                    if not arr.is_null(r):
                        _acc_int(st, Int64(arr.get(r)), first)
                        first = False
                        nvals += 1
        elif kind == ORC_KIND_SHORT:
            ref arr = enc.i16.value()
            if not has_nulls:
                for r in range(row_start, row_start + row_count):
                    _acc_int(st, Int64(arr.get(r)), first)
                    first = False
                nvals = row_count
            else:
                for r in range(row_start, row_start + row_count):
                    if not arr.is_null(r):
                        _acc_int(st, Int64(arr.get(r)), first)
                        first = False
                        nvals += 1
        elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
            ref arr = enc.i32.value()
            if not has_nulls:
                for r in range(row_start, row_start + row_count):
                    _acc_int(st, Int64(arr.get(r)), first)
                    first = False
                nvals = row_count
            else:
                for r in range(row_start, row_start + row_count):
                    if not arr.is_null(r):
                        _acc_int(st, Int64(arr.get(r)), first)
                        first = False
                        nvals += 1
        else:
            ref arr = enc.i64.value()
            if not has_nulls:
                for r in range(row_start, row_start + row_count):
                    _acc_int(st, arr.get(r), first)
                    first = False
                nvals = row_count
            else:
                for r in range(row_start, row_start + row_count):
                    if not arr.is_null(r):
                        _acc_int(st, arr.get(r), first)
                        first = False
                        nvals += 1
        st.number_of_values = nvals
    return st^


# =============================================================================
# Per-column emit bodies.
# =============================================================================


def _append_stream(
    mut result: StripeStreams, kind: Int, column: Int, var raw: List[UInt8], codec: Int
) raises:
    """COLLECT raw stream `raw` + its (kind, column, is_index=False) descriptor
    when the codec wants compress (Zstd/Snappy/Zlib/Lz4/Lzo), OR inline
    compress-and-append when codec is NONE (zero-copy frame-raw fast path).

    The collect pass exists to feed `compress_streams_parallel` at finalize time. NONE
    codec has nothing to compress; the collect cost (List[List[UInt8]] +
    `_PendingStream` append per stream, tens of thousands of extra appends on
    a many-stripe file) is pure overhead with no parallel win to amortize.
    Inline NONE here keeps the single-pass byte-append shape for NONE and the
    full parallel-compress win for the compressing codecs."""
    if codec == ORC_COMPRESSION_NONE:
        # NONE codec has no chunk framing — the stream IS the raw bytes
        # (orc_codec.compress_stream's short-circuit). Inline-append directly
        # into the result.data buffer; skip the collect-pass entirely.
        result.stream_protos.append(
            encode_stream(kind, column, len(raw))
        )
        for i in range(len(raw)):
            result.data.append(raw[i])
        return
    result.pending_descs.append(
        _PendingStream(kind, column, False)
    )
    result.raw_streams.append(raw^)


# =============================================================================
# Finalize: compress + assemble collected raw streams (serial / parallel).
# =============================================================================
#
# `_append_stream` only collects; these helpers run the codec compress + the
# stripe-data / index-data assembly.
#
# Byte-identity contract: for every codec, the bytes produced by `serial`
# finalize equal those produced by `parallel` finalize — same
# `compress_stream` call, same order of frame, same routing of index-vs-data
# streams.


def finalize_stripe_streams_serial(
    mut result: StripeStreams, codec: Int
) raises:
    """Serial finalize: compress each collected raw stream INLINE in emit
    order, assemble into `result.data` + `result.index_data` + their stream
    protos. Byte-identical to the parallel finalize (same `compress_stream`
    calls, same order)."""
    var n = len(result.raw_streams)
    # Pop+process to avoid two-list duplication. The order of the
    # post-finalize `index_*` / data fields is the order of pending_descs.
    var raw_streams = List[List[UInt8]]()
    swap(raw_streams, result.raw_streams)
    var pending_descs = List[_PendingStream]()
    swap(pending_descs, result.pending_descs)

    # NONE codec fast path — skip the compress_stream call (it's a no-op
    # copy for NONE) and frame the raw bytes directly (byte-identical).
    if codec == ORC_COMPRESSION_NONE:
        for i in range(n):
            ref raw = raw_streams[i]
            ref d = pending_descs[i]
            if d.is_index:
                result.index_stream_protos.append(
                    encode_stream(d.kind, d.column, len(raw))
                )
                for j in range(len(raw)):
                    result.index_data.append(raw[j])
            else:
                result.stream_protos.append(
                    encode_stream(d.kind, d.column, len(raw))
                )
                for j in range(len(raw)):
                    result.data.append(raw[j])
        _ = raw_streams^
        _ = pending_descs^
        return

    for i in range(n):
        ref raw = raw_streams[i]
        ref d = pending_descs[i]
        var compressed = compress_stream(raw, codec)
        if d.is_index:
            result.index_stream_protos.append(
                encode_stream(d.kind, d.column, len(compressed))
            )
            for j in range(len(compressed)):
                result.index_data.append(compressed[j])
        else:
            result.stream_protos.append(
                encode_stream(d.kind, d.column, len(compressed))
            )
            for j in range(len(compressed)):
                result.data.append(compressed[j])

    _ = raw_streams^
    _ = pending_descs^


def finalize_stripe_streams_parallel[disp_o: Origin[mut=True]](
    mut result: StripeStreams,
    codec: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises:
    """Parallel finalize: dispatch per-stream compress across the runtime's
    worker pool via `LocalDispatcher.run_with_state`, then serial-assemble
    into `result.data` / `result.index_data` in emit order.

    Output bytes are byte-identical to `finalize_stripe_streams_serial`
    (same compress_stream call per stream, same kind/column/length proto,
    same frame order)."""
    var n = len(result.raw_streams)
    # Move out the raw streams (so the parallel dispatch holds them; clear
    # the in-result fields to avoid double-iteration).
    var raw_streams = List[List[UInt8]]()
    swap(raw_streams, result.raw_streams)
    var pending_descs = List[_PendingStream]()
    swap(pending_descs, result.pending_descs)

    if n == 0:
        _ = cancel_token^
        _ = raw_streams^
        _ = pending_descs^
        return

    # NONE-codec
    # fast path. `compress_stream(NONE, raw)` is just a List-copy (no chunk
    # framing, no FFI); parallelizing the copy adds dispatch + Slab + serial-
    # reassemble overhead with NO compress wall to amortize, so it is slower
    # than the serial path. Bypass the dispatch entirely for NONE codec and
    # route through the serial finalize (the same shape as the Avro writer's
    # null-codec raw-frame fast path).
    if codec == ORC_COMPRESSION_NONE:
        _ = cancel_token^
        # NONE codec has no chunk framing — the stream IS the raw bytes
        # (orc_codec.compress_stream's short-circuit). Skip the compress_stream
        # call entirely and frame the raw bytes inline (one List walk per
        # stream, no intermediate copy).
        for i in range(n):
            ref raw = raw_streams[i]
            ref d = pending_descs[i]
            if d.is_index:
                result.index_stream_protos.append(
                    encode_stream(d.kind, d.column, len(raw))
                )
                for j in range(len(raw)):
                    result.index_data.append(raw[j])
            else:
                result.stream_protos.append(
                    encode_stream(d.kind, d.column, len(raw))
                )
                for j in range(len(raw)):
                    result.data.append(raw[j])
        _ = raw_streams^
        _ = pending_descs^
        return

    # Parallel compress: dispatcher fans across worker shards; returns a
    # Slab of compressed payloads in INDEX ORDER.
    comptime r_o = origin_of(raw_streams)
    var compressed = compress_streams_parallel[r_o, disp_o](
        raw_streams, codec, dispatcher_ptr, cancel_token^,
    )
    _ = raw_streams^  # pinned across dispatch (origin r_o).

    # Serial assemble in emit order.
    for i in range(n):
        ref c = compressed[i]
        ref d = pending_descs[i]
        if d.is_index:
            result.index_stream_protos.append(
                encode_stream(d.kind, d.column, len(c))
            )
            for j in range(len(c)):
                result.index_data.append(c[j])
        else:
            result.stream_protos.append(
                encode_stream(d.kind, d.column, len(c))
            )
            for j in range(len(c)):
                result.data.append(c[j])

    _ = compressed^
    _ = pending_descs^


@always_inline
def _enc_has_nulls(ref enc: _OrcColEncoder, kind: Int) -> Bool:
    """Cheap O(1) check: does the typed
    Arrow array for `kind` have any nulls anywhere? Reads the typed array's
    `null_count` field (set once at array-build time; never recomputed). When
    False, every per-stripe call to `_column_present` would build a `List[Bool]`
    of all-True flags and `_has_any_null` would walk them only to return False;
    we elide that entire stride-sized scratch + walk on the common
    non-nullable path. When True, the List[Bool] path (`_column_present`)
    runs."""
    if kind == ORC_KIND_BOOLEAN:
        return enc.b.value().null_count != 0
    elif kind == ORC_KIND_STRING:
        return enc.str_null_count() != 0
    elif kind == ORC_KIND_FLOAT:
        return enc.f32.value().null_count != 0
    elif kind == ORC_KIND_DOUBLE:
        return enc.f64.value().null_count != 0
    elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
        return enc.i32.value().null_count != 0
    elif kind == ORC_KIND_BYTE:
        return enc.i8.value().null_count != 0
    elif kind == ORC_KIND_SHORT:
        return enc.i16.value().null_count != 0
    else:
        # LONG funnels through int64 access.
        return enc.i64.value().null_count != 0


def _column_present(
    ref enc: _OrcColEncoder, kind: Int, row_start: Int, row_count: Int
) raises -> List[Bool]:
    """Per-row present flags over the stripe row range. Reads the typed array
    fetched ONCE in `build_col_encoders` (no per-stripe re-copy)."""
    var present = List[Bool](capacity=row_count)
    if kind == ORC_KIND_BOOLEAN:
        ref arr = enc.b.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    elif kind == ORC_KIND_STRING:
        for r in range(row_start, row_start + row_count):
            present.append(not enc.str_is_null(r))
        return present^
    elif kind == ORC_KIND_FLOAT:
        ref arr = enc.f32.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    elif kind == ORC_KIND_DOUBLE:
        ref arr = enc.f64.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
        ref arr = enc.i32.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    elif kind == ORC_KIND_BYTE:
        ref arr = enc.i8.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    elif kind == ORC_KIND_SHORT:
        ref arr = enc.i16.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^
    else:
        # LONG funnels through int64 access.
        ref arr = enc.i64.value()
        for r in range(row_start, row_start + row_count):
            present.append(not arr.is_null(r))
        return present^


@always_inline
def _span_cmp_str[o: Origin](a: Span[UInt8, o], b: String) -> Int:
    """Byte-wise lexicographic compare of a borrowed span `a` against String `b`.
    Returns <0 if a<b, 0 if equal, >0 if a>b. Matches String's `<`/`>`
    (UTF-8 byte order == Unicode code-point order for well-formed UTF-8), so
    str_min / str_max stats stay byte-identical without an owned-String alloc
    per compared row."""
    var bb = b.as_bytes()
    var na = len(a)
    var nb = len(bb)
    var n = na if na < nb else nb
    for i in range(n):
        var av = Int(a[i])
        var bv = Int(bb[i])
        if av != bv:
            return av - bv
    return na - nb


@always_inline
def _has_any_null(present: List[Bool]) -> Bool:
    for i in range(len(present)):
        if not present[i]:
            return True
    return False


def _emit_primitive_column(
    ref enc: _OrcColEncoder,
    node_id: Int,
    kind: Int,
    row_start: Int,
    row_count: Int,
    codec: Int,
    mut result: StripeStreams,
) raises:
    if kind == ORC_KIND_BOOLEAN:
        _emit_boolean(enc, node_id, row_start, row_count, codec, result)
    elif kind == ORC_KIND_BYTE:
        _emit_tinyint(enc, node_id, row_start, row_count, codec, result)
    elif (
        kind == ORC_KIND_SHORT
        or kind == ORC_KIND_INT
        or kind == ORC_KIND_LONG
        or kind == ORC_KIND_DATE
    ):
        _emit_integer(enc, node_id, kind, row_start, row_count, codec, result)
    elif kind == ORC_KIND_FLOAT:
        _emit_float32(enc, node_id, row_start, row_count, codec, result)
    elif kind == ORC_KIND_DOUBLE:
        _emit_float64(enc, node_id, row_start, row_count, codec, result)
    elif kind == ORC_KIND_STRING:
        _emit_string(enc, node_id, row_start, row_count, codec, result)
    else:
        raise Error(
            String("OrcWriteError.UNSUPPORTED_TYPE: ORC Type.Kind ")
            + orc_kind_name(kind)
            + " write is not supported (nested / binary / decimal / ts)"
        )


def _maybe_emit_present(
    mut result: StripeStreams, node_id: Int, present: List[Bool], codec: Int
) raises -> Bool:
    """Emit the PRESENT stream iff any null. Returns has_null."""
    if _has_any_null(present):
        var raw = encode_boolean_rle(present)
        _append_stream(result, ORC_STREAM_PRESENT, node_id, raw^, codec)
        return True
    return False


def _emit_boolean(
    ref enc: _OrcColEncoder, node_id: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    # Skip the PRESENT-stream `List[Bool]` build entirely when the column is
    # fully valid (null_count==0). For a non-nullable table this branch is
    # taken for every stripe x every column, eliminating one stride-sized
    # List[Bool] allocation each.
    var has_nulls = _enc_has_nulls(enc, ORC_KIND_BOOLEAN)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, ORC_KIND_BOOLEAN, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    ref arr = enc.b.value()
    var flags = List[Bool](capacity=row_count)
    var nvals = 0
    if not has_nulls:
        # Skip per-row `is_null` in the fast (all-valid) loop.
        for r in range(row_start, row_start + row_count):
            flags.append(arr.get(r))
        nvals = row_count
    else:
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                flags.append(arr.get(r))
                nvals += 1
    var raw = encode_boolean_rle(flags)
    _append_stream(result, ORC_STREAM_DATA, node_id, raw^, codec)
    var st = ColumnStats.empty()
    st.number_of_values = nvals
    st.has_null = has_null
    result.col_stats[node_id] = st^


def _emit_tinyint(
    ref enc: _OrcColEncoder, node_id: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    """TINYINT DATA is BYTE RLE (one 2's-complement byte per value), NOT integer
    RLE — matches the reader's _decode_tinyint_into / decode_byte_rle."""
    var has_nulls = _enc_has_nulls(enc, ORC_KIND_BYTE)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, ORC_KIND_BYTE, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    ref arr = enc.i8.value()
    var bytes = List[UInt8](capacity=row_count)
    var st = ColumnStats.empty()
    st.is_int = True
    st.has_null = has_null
    var first = True
    if not has_nulls:
        for r in range(row_start, row_start + row_count):
            var v = Int64(arr.get(r))
            var b = Int(v) & 0xFF
            bytes.append(UInt8(b))
            _acc_int(st, v, first)
            first = False
    else:
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                var v = Int64(arr.get(r))
                # 2's-complement byte (the reader does `if b >= 128: b -= 256`).
                var b = Int(v) & 0xFF
                bytes.append(UInt8(b))
                _acc_int(st, v, first)
                first = False
    st.number_of_values = len(bytes)
    var raw = encode_byte_rle(bytes)
    _append_stream(result, ORC_STREAM_DATA, node_id, raw^, codec)
    result.col_stats[node_id] = st^


def _emit_integer(
    ref enc: _OrcColEncoder, node_id: Int, kind: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    # All-valid fast path. Integer and date columns dominate typical
    # analytical tables (keys, quantities, scaled decimals, dates), so the
    # bulk of write-encode time lands here.
    var has_nulls = _enc_has_nulls(enc, kind)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, kind, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    var vals = List[Int64](capacity=row_count)
    var st = ColumnStats.empty()
    st.is_int = True
    st.has_null = has_null
    var first = True
    if not has_nulls:
        # All-valid fast loops: skip the per-row null-guard branch entirely.
        if kind == ORC_KIND_SHORT:
            ref arr = enc.i16.value()
            for r in range(row_start, row_start + row_count):
                var v = Int64(arr.get(r))
                vals.append(v)
                _acc_int(st, v, first)
                first = False
        elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
            ref arr = enc.i32.value()
            for r in range(row_start, row_start + row_count):
                var v = Int64(arr.get(r))
                vals.append(v)
                _acc_int(st, v, first)
                first = False
        else:
            ref arr = enc.i64.value()
            for r in range(row_start, row_start + row_count):
                var v = arr.get(r)
                vals.append(v)
                _acc_int(st, v, first)
                first = False
    else:
        if kind == ORC_KIND_SHORT:
            ref arr = enc.i16.value()
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    var v = Int64(arr.get(r))
                    vals.append(v)
                    _acc_int(st, v, first)
                    first = False
        elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
            ref arr = enc.i32.value()
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    var v = Int64(arr.get(r))
                    vals.append(v)
                    _acc_int(st, v, first)
                    first = False
        else:
            ref arr = enc.i64.value()
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    var v = arr.get(r)
                    vals.append(v)
                    _acc_int(st, v, first)
                    first = False
    st.number_of_values = len(vals)
    var raw = encode_int_rle_v2(vals, True)
    _append_stream(result, ORC_STREAM_DATA, node_id, raw^, codec)
    result.col_stats[node_id] = st^


@always_inline
def _acc_int(mut st: ColumnStats, v: Int64, first: Bool):
    if first:
        st.int_min = v
        st.int_max = v
    else:
        if v < st.int_min:
            st.int_min = v
        if v > st.int_max:
            st.int_max = v
    add_to_int_sum(st.int_sum, v)


def _emit_float32(
    ref enc: _OrcColEncoder, node_id: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    var has_nulls = _enc_has_nulls(enc, ORC_KIND_FLOAT)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, ORC_KIND_FLOAT, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    ref arr = enc.f32.value()
    var raw = List[UInt8](capacity=row_count * 4)
    var st = ColumnStats.empty()
    st.is_double = True
    st.has_null = has_null
    var first = True
    var nvals = 0
    if not has_nulls:
        for r in range(row_start, row_start + row_count):
            var f = arr.get(r)
            var bits = bitcast[DType.uint32, 1](f)
            for k in range(4):
                raw.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))
            _acc_dbl(st, Float64(f), first)
            first = False
        nvals = row_count
    else:
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                var f = arr.get(r)
                var bits = bitcast[DType.uint32, 1](f)
                for k in range(4):
                    raw.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))
                _acc_dbl(st, Float64(f), first)
                first = False
                nvals += 1
    st.number_of_values = nvals
    _append_stream(result, ORC_STREAM_DATA, node_id, raw^, codec)
    result.col_stats[node_id] = st^


def _emit_float64(
    ref enc: _OrcColEncoder, node_id: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    var has_nulls = _enc_has_nulls(enc, ORC_KIND_DOUBLE)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, ORC_KIND_DOUBLE, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    ref arr = enc.f64.value()
    var raw = List[UInt8](capacity=row_count * 8)
    var st = ColumnStats.empty()
    st.is_double = True
    st.has_null = has_null
    var first = True
    var nvals = 0
    if not has_nulls:
        for r in range(row_start, row_start + row_count):
            var f = arr.get(r)
            var bits = bitcast[DType.uint64, 1](f)
            for k in range(8):
                raw.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
            _acc_dbl(st, f, first)
            first = False
        nvals = row_count
    else:
        for r in range(row_start, row_start + row_count):
            if not arr.is_null(r):
                var f = arr.get(r)
                var bits = bitcast[DType.uint64, 1](f)
                for k in range(8):
                    raw.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))
                _acc_dbl(st, f, first)
                first = False
                nvals += 1
    st.number_of_values = nvals
    _append_stream(result, ORC_STREAM_DATA, node_id, raw^, codec)
    result.col_stats[node_id] = st^


@always_inline
def _acc_dbl(mut st: ColumnStats, v: Float64, first: Bool):
    if first:
        st.dbl_min = v
        st.dbl_max = v
    else:
        if v < st.dbl_min:
            st.dbl_min = v
        if v > st.dbl_max:
            st.dbl_max = v
    st.dbl_sum += v


def _emit_string(
    ref enc: _OrcColEncoder, node_id: Int,
    row_start: Int, row_count: Int, codec: Int, mut result: StripeStreams,
) raises:
    var has_nulls = _enc_has_nulls(enc, ORC_KIND_STRING)
    var has_null: Bool = False
    if has_nulls:
        var present = _column_present(enc, ORC_KIND_STRING, row_start, row_count)
        has_null = _maybe_emit_present(result, node_id, present, codec)
    var data_raw = List[UInt8]()
    var lengths = List[Int64](capacity=row_count)
    var st = ColumnStats.empty()
    st.is_string = True
    st.has_null = has_null
    var first = True
    var nvals = 0
    var total_len: Int64 = 0

    # ⚠ THE WIDTH BRANCH IS HOISTED OUT OF THE ROW LOOP, so the narrow arm is
    # a plain STRING loop with its zero-copy `get_span` walk (the fetch-once
    # property this whole encoder exists for) and no per-row width test. The
    # two loops cannot be merged behind an accessor: `get_span` returns `Span[UInt8, origin_of(self.data)]`, whose origin is tied to the
    # concrete array, so the narrow and wide spans are different types.
    #
    # ORC's on-disk form has no offset width — DATA is raw UTF-8 and LENGTH is
    # an RLEv2 stream of per-row byte lengths — so both arms emit identical
    # streams for identical values. That equality is the oracle of
    # `test_orc_large_string_write_roundtrip`.
    if enc.str_is_wide():
        ref warr = enc.ls.value()
        if not has_nulls:
            for r in range(row_start, row_start + row_count):
                var wsb = warr.get_span(r)
                lengths.append(Int64(len(wsb)))
                data_raw.extend(wsb)
                total_len += Int64(len(wsb))
                if first:
                    var ws = warr.get(r)
                    st.str_min = ws
                    st.str_max = ws
                    first = False
                else:
                    var wcmp = _span_cmp_str(wsb, st.str_min)
                    if wcmp < 0:
                        st.str_min = warr.get(r)
                    elif _span_cmp_str(wsb, st.str_max) > 0:
                        st.str_max = warr.get(r)
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not warr.is_null(r):
                    var wsb2 = warr.get_span(r)
                    lengths.append(Int64(len(wsb2)))
                    data_raw.extend(wsb2)
                    total_len += Int64(len(wsb2))
                    if first:
                        var ws2 = warr.get(r)
                        st.str_min = ws2
                        st.str_max = ws2
                        first = False
                    else:
                        var wcmp2 = _span_cmp_str(wsb2, st.str_min)
                        if wcmp2 < 0:
                            st.str_min = warr.get(r)
                        elif _span_cmp_str(wsb2, st.str_max) > 0:
                            st.str_max = warr.get(r)
                    nvals += 1
    else:
        ref arr = enc.s.value()
        if not has_nulls:
            for r in range(row_start, row_start + row_count):
                # Zero-copy borrow of this row's UTF-8 bytes (no owned-String
                # alloc).
                var sb = arr.get_span(r)
                lengths.append(Int64(len(sb)))
                data_raw.extend(sb)
                total_len += Int64(len(sb))
                if first:
                    var s = arr.get(r)
                    st.str_min = s
                    st.str_max = s
                    first = False
                else:
                    var cmp = _span_cmp_str(sb, st.str_min)
                    if cmp < 0:
                        st.str_min = arr.get(r)
                    elif _span_cmp_str(sb, st.str_max) > 0:
                        st.str_max = arr.get(r)
            nvals = row_count
        else:
            for r in range(row_start, row_start + row_count):
                if not arr.is_null(r):
                    var sb2 = arr.get_span(r)
                    lengths.append(Int64(len(sb2)))
                    data_raw.extend(sb2)
                    total_len += Int64(len(sb2))
                    if first:
                        var s2 = arr.get(r)
                        st.str_min = s2
                        st.str_max = s2
                        first = False
                    else:
                        var cmp2 = _span_cmp_str(sb2, st.str_min)
                        if cmp2 < 0:
                            st.str_min = arr.get(r)
                        elif _span_cmp_str(sb2, st.str_max) > 0:
                            st.str_max = arr.get(r)
                    nvals += 1
    st.number_of_values = nvals
    st.str_total_len = total_len
    # DATA (raw UTF-8) + LENGTH (unsigned RLE).
    _append_stream(result, ORC_STREAM_DATA, node_id, data_raw^, codec)
    var len_raw = encode_int_rle_v2(lengths, False)
    _append_stream(result, ORC_STREAM_LENGTH, node_id, len_raw^, codec)
    result.col_stats[node_id] = st^
