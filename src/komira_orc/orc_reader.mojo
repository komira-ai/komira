# =============================================================================
# orc_reader.mojo — end-to-end ORC file read -> Arrow RecordBatch.
# =============================================================================
#
# Orchestration: takes a complete in-memory ORC file (`read_orc_file` maps the
# file from disk), parses the tail metadata (footer.mojo, codec-aware
# via orc_codec.mojo), then for each stripe:
#   1. Parse the StripeFooter (decompressed via the file codec).
#   2. Walk StripeFooter.streams in order, assigning each its byte span within
#      the stripe (offsets are cumulative from stripe.offset).
#   3. For each top-level column (the root struct's direct children), gather its
#      streams, decompress each, and decode -> Arrow Column (column_decoder.mojo).
#   4. Accumulate columns across stripes (one RecordBatch for the whole file).
#
# The flat path reads the root STRUCT's direct primitive children (identity
# schema, reader == writer). Nested children (STRUCT/LIST/MAP/UNION) and Hive
# ACID files take the recursive path in nested_decoder.mojo.
#
# Encapsulation: public API takes a borrowed Span (or a path String) and returns
# an owned RecordBatch. No UnsafePointer crosses the module boundary.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_FORMAT_READ
from std.memory import UnsafePointer
from std.sys import num_physical_cores
from komira_collections.slab import Slab
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.ops.waker_sink import NoopSink
from komira_async.cancellation.token import CancellationToken
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from .footer import (
    OrcFileTail,
    PostScript,
    Footer,
    StripeFooter,
    StripeInformation,
    ORC_COMPRESSION_NONE,
    ORC_MAGIC_LEN,
)
from .orc_schema import (
    OrcSchema,
    orc_node_to_arrow,
    ORC_KIND_STRUCT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_DATE,
)
from .orc_codec import decompress_stream
from .column_decoder import (
    StreamSpan,
    ColumnAcc,
    make_accumulator,
    decode_stripe_column,
)
from .nested_decoder import decode_column_subtree
from .orc_logical_arrow import (
    stamp_arrow_orc_metadata,
    is_acid_schema,
    acid_output_columns,
)


# =============================================================================
# Stream-span resolution within a stripe.
# =============================================================================
#
# StripeFooter.streams are listed in their on-disk order; each stream's bytes
# occupy `length` bytes, laid out contiguously starting at stripe.offset. We
# walk them once to assign every stream a [start, end) byte span. The first
# block (index streams: ROW_INDEX / BLOOM_FILTER) occupies `index_length`
# bytes; data streams follow. The cumulative-offset walk handles both.


@fieldwise_init
struct _StreamLoc(Copyable, Movable):
    """A located stream: (kind, column, file-relative byte span)."""

    var kind: Int
    var column: Int
    var start: Int
    var end: Int


def _checked_file_span(
    file_len: Int, start: Int, end: Int, what: StringSlice
) raises:
    """Validate a [start, end) byte range against the file before slicing it.

    ⚠ CALL THIS BEFORE EVERY `file_bytes[start:end]` ON UNTRUSTED ENDPOINTS.

    Span behaviour: an over-large END is CLAMPED and an
    over-large START yields length 0, so a merely-too-far offset degrades to a
    short span and the decoder raises TRUNCATED — that direction is NOT an OOB
    read and needs no check. The lethal direction is INVERTED (`start > end`),
    which yields a Span of NEGATIVE length; feeding one to `decompress_stream`
    SIGSEGVs the process at ASSERT=none.

    `footer.orc_checked_extent` bounds every metadata field at parse time so
    no sum of them can wrap, which makes inversion unreachable from that route.
    This is the FILE-RELATIVE half the parser cannot do: it does not know
    `len(file_bytes)`. Rejecting a stripe that claims bytes the file does not
    contain also turns a confusing downstream TRUNCATED into an error that names
    the stripe.
    """
    if start < 0 or end < start:
        raise Error(
            String("OrcDecodeError.BAD_SPAN: ")
            + String(what)
            + " byte range ["
            + String(start)
            + ", "
            + String(end)
            + ") is inverted or negative"
        )
    if end > file_len:
        raise Error(
            String("OrcDecodeError.BAD_SPAN: ")
            + String(what)
            + " byte range ["
            + String(start)
            + ", "
            + String(end)
            + ") runs past the end of a "
            + String(file_len)
            + "-byte file"
        )


def _locate_streams(
    sf: StripeFooter, stripe: StripeInformation, file_len: Int
) raises -> List[_StreamLoc]:
    """Assign each StripeFooter stream its byte span within the file.

    Each `Stream.length` is a protobuf uint64 the file's writer chose, summed
    onto `stripe.offset` with no relation to anything. `footer.orc_checked_extent`
    bounds each one at parse time (so the running `off` cannot wrap), and the
    per-stream check below bounds the RESULT against the file — one compare per
    stream per stripe, on a path that runs once per stripe, not per row.

    Note also that `off` is never reset to the data-stream region: index-stream
    lengths shift every subsequent data stream. That is faithful to ORC's
    layout (index streams physically precede data streams inside the stripe),
    but it means ONE bad index-stream length displaces every data stream in the
    stripe — which is exactly why the result needs checking rather than the
    inputs alone.
    """
    var locs = List[_StreamLoc]()
    var off = stripe.offset
    for i in range(len(sf.streams)):
        var s = sf.streams[i].copy()
        if s.length < 0:
            raise Error(
                String("OrcDecodeError.BAD_SPAN: stream ")
                + String(i)
                + " of this stripe declares a negative length "
                + String(s.length)
            )
        _checked_file_span(file_len, off, off + s.length, "stream " + String(i))
        locs.append(_StreamLoc(s.kind, s.column, off, off + s.length))
        off += s.length
    return locs^


# =============================================================================
# Build the Arrow output schema from the root struct's direct children.
# =============================================================================


def _resolve_projection(
    schema: OrcSchema, projection: List[Int]
) raises -> List[Int]:
    """Resolve a caller projection (output-column indices into the root
    struct's direct children) into the concrete list of child positions to
    decode. An EMPTY projection means "all columns" (the default, unchanged).
    Indices are validated and de-duplicated while preserving caller order so
    the output schema column order matches the projection."""
    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        raise Error(
            "OrcDecodeError.ROOT_NOT_STRUCT: the ORC reader needs a top-level struct"
        )
    var n_children = len(root.subtypes)
    var out = List[Int]()
    if len(projection) == 0:
        for i in range(n_children):
            out.append(i)
        return out^
    var seen = List[Bool]()
    for _i in range(n_children):
        seen.append(False)
    for i in range(len(projection)):
        var p = projection[i]
        if p < 0 or p >= n_children:
            raise Error(
                "OrcDecodeError.BAD_PROJECTION: output column index "
                + String(p)
                + " out of range [0, "
                + String(n_children)
                + ")"
            )
        if not seen[p]:
            seen[p] = True
            out.append(p)
    return out^


def _build_output_schema(
    schema: OrcSchema, child_positions: List[Int]
) raises -> Schema:
    """Derive an Arrow Schema from the selected root-struct children (one per
    `child_positions` entry, in that order)."""
    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        raise Error(
            "OrcDecodeError.ROOT_NOT_STRUCT: the ORC reader needs a top-level struct"
        )
    var sb = SchemaBuilder()
    for j in range(len(child_positions)):
        var i = child_positions[j]
        var child_idx = root.subtypes[i]
        var at = orc_node_to_arrow(schema, child_idx)
        var name: String
        if i < len(root.field_names):
            name = root.field_names[i]
        else:
            name = String("_col") + String(i)
        # nullable=True (ORC columns are nullable unless stats prove
        # otherwise; the PRESENT stream drives actual validity).
        sb.add_field(Field(name, at, True))
    return sb.build()


# =============================================================================
# Per-stripe decode -> one Column per top-level child.
# =============================================================================


def _gather_column_streams(
    locs: List[_StreamLoc],
    file_bytes: Span[UInt8, _],
    col_id: Int,
    codec: Int,
    block_size: Int,
) raises -> List[StreamSpan]:
    """Collect + decompress every (non-index) stream belonging to `col_id`."""
    from .footer import ORC_STREAM_ROW_INDEX, ORC_STREAM_BLOOM_FILTER
    from .footer import ORC_STREAM_BLOOM_FILTER_UTF8

    var out = List[StreamSpan]()
    for i in range(len(locs)):
        var loc = locs[i].copy()
        if loc.column != col_id:
            continue
        # Skip index streams — they are not data.
        if (
            loc.kind == ORC_STREAM_ROW_INDEX
            or loc.kind == ORC_STREAM_BLOOM_FILTER
            or loc.kind == ORC_STREAM_BLOOM_FILTER_UTF8
        ):
            continue
        var raw = file_bytes[loc.start : loc.end]
        var decompressed = decompress_stream(raw, codec, block_size)
        out.append(StreamSpan(loc.kind, decompressed^))
    return out^


# =============================================================================
# Public: read a complete ORC file from in-memory bytes -> one RecordBatch.
# =============================================================================


@always_inline
def _node_is_nested(schema: OrcSchema, node_idx: Int) raises -> Bool:
    var k = schema.node(node_idx).kind
    return (
        k == ORC_KIND_STRUCT
        or k == ORC_KIND_LIST
        or k == ORC_KIND_MAP
        or k == ORC_KIND_UNION
    )


def _schema_needs_nested_path(
    schema: OrcSchema, with_acid_columns: Bool
) raises -> Bool:
    """Nested-path dispatch: route through the recursive nested decoder iff any
    top-level child is itself a compound type, or the file is ACID-shaped
    (ACID needs the row.* lift / column suppression regardless)."""
    if is_acid_schema(schema):
        return True
    var root = schema.node(0)
    for i in range(len(root.subtypes)):
        if _node_is_nested(schema, root.subtypes[i]):
            return True
    return False


def read_orc_bytes(file_bytes: Span[UInt8, _]) raises -> RecordBatch:
    """Decode a complete in-memory ORC file into a single Arrow RecordBatch.

    Every codec; primitive top-level columns decode on the flat multi-stripe
    path with an identity schema. Nested STRUCT/LIST/MAP/UNION + ACID
    default-suppress are routed through the recursive `nested_decoder` path. The default
    `with_acid_columns=False` suppresses the 5 Hive ACID metadata columns and
    lifts `row.*`; pass `with_acid_columns=True` to expose all 6.
    """
    return read_orc_bytes_opts(file_bytes, False)


# =============================================================================
# Codec-aware file-tail parse (the writer round-trip exercises this).
# =============================================================================
#
# OrcFileTail.parse is NONE-codec-only (it hands the raw footer span straight to
# Footer.parse). When the file codec is compressed, the Footer + StripeFooter +
# Metadata blobs are themselves chunk-framed + codec-compressed. This helper
# parses the PostScript, then decompresses the Footer span via the file codec
# before Footer.parse — making the reader symmetric with the writer (which
# compresses every metadata blob through the file codec).


def _parse_tail_codec_aware(file_bytes: Span[UInt8, _]) raises -> OrcFileTail:
    var n = len(file_bytes)
    if n < ORC_MAGIC_LEN + 1:
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: file too small to be ORC")
    if not (
        file_bytes[0] == UInt8(ord("O"))
        and file_bytes[1] == UInt8(ord("R"))
        and file_bytes[2] == UInt8(ord("C"))
    ):
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: missing leading 'ORC' magic")

    var ps_len = Int(file_bytes[n - 1])
    if ps_len < 1:
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: PostScript length is 0")
    var ps_start = n - 1 - ps_len
    if ps_start < ORC_MAGIC_LEN:
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: PostScript overruns start")
    var ps = PostScript.parse(file_bytes[ps_start : n - 1])
    if ps.magic != "ORC":
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: PostScript magic != 'ORC'")

    # NONE codec: defer to the existing (validated) NONE-only parse.
    if ps.compression == ORC_COMPRESSION_NONE:
        return OrcFileTail.parse(file_bytes)

    var footer_end = ps_start
    var footer_start = footer_end - ps.footer_length
    if footer_start < ORC_MAGIC_LEN:
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: footer overruns start")
    var metadata_end = footer_start
    var metadata_start = metadata_end - ps.metadata_length
    if metadata_start < ORC_MAGIC_LEN:
        raise Error("OrcSchemaError.MALFORMED_PROTOBUF: metadata overruns start")
    # The two `< ORC_MAGIC_LEN` guards above catch an honestly-LARGE length (the
    # start goes very negative) — the honest-corruption case, handled correctly.
    # They do NOT catch a length >= 2^63: `Int` would wrap negative, so
    # `footer_end - (negative)` would land ABOVE footer_end, the guard would
    # pass, and the slice would be INVERTED. `PostScript.footerLength` /
    # `.metadataLength` are bounded at parse time (`footer.orc_checked_extent`),
    # so that wrap cannot happen; these two calls state the resulting invariant
    # explicitly and add the file-relative half the parser cannot do. Compare
    # `orc_stride_skip._parse_stripe_stats`, which carries the equivalent
    # `metadata_end <= metadata_start` pre-check.
    _checked_file_span(len(file_bytes), footer_start, footer_end, "file footer")
    _checked_file_span(
        len(file_bytes), metadata_start, metadata_end, "file metadata"
    )

    var footer_raw = file_bytes[footer_start:footer_end]
    var footer_bytes = decompress_stream(
        footer_raw, ps.compression, ps.compression_block_size
    )
    var footer = Footer.parse(Span(footer_bytes))
    return OrcFileTail(
        ps^, footer^, footer_start, footer_end, metadata_start, metadata_end
    )


def read_orc_bytes_opts(
    file_bytes: Span[UInt8, _], with_acid_columns: Bool
) raises -> RecordBatch:
    """`read_orc_bytes` with the `with_acid_columns` ACID-exposure toggle."""
    return _read_orc_bytes_core[has_dispatcher=False, disp_o=MutAnyOrigin](
        file_bytes,
        with_acid_columns,
        List[Int](),
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def read_orc_bytes_projected(
    file_bytes: Span[UInt8, _], projection: List[Int]
) raises -> RecordBatch:
    """Decode only the projected output columns (indices into the root struct's
    direct children, in caller order). An EMPTY `projection` decodes all columns
    (identical to `read_orc_bytes`). This is cascade level 1: a query that
    references K of N columns pays to decode only K of N — the single biggest
    decode-work reduction for wide tables.

    The projected columns are already correctly encoded/decoded — projection
    changes NO encoding semantics — so a full read + select is a valid oracle.
    """
    return _read_orc_bytes_core[has_dispatcher=False, disp_o=MutAnyOrigin](
        file_bytes,
        False,
        projection,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


# =============================================================================
# Dispatcher-aware read entries. Thread the caller's dispatcher + cancel token
# down to the parallel per-column decode. Byte-identical
# output to the dispatcher-less `read_orc_bytes*` entries above.
# =============================================================================


def read_orc_bytes_with_dispatcher[
    disp_o: Origin[mut=True],
](
    file_bytes: Span[UInt8, _],
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware sibling of `read_orc_bytes` — parallel per-column
    decode via the caller-owned `LocalDispatcher`."""
    return _read_orc_bytes_core[has_dispatcher=True, disp_o=disp_o](
        file_bytes,
        False,
        List[Int](),
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def read_orc_bytes_opts_with_dispatcher[
    disp_o: Origin[mut=True],
](
    file_bytes: Span[UInt8, _],
    with_acid_columns: Bool,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware sibling of `read_orc_bytes_opts`."""
    return _read_orc_bytes_core[has_dispatcher=True, disp_o=disp_o](
        file_bytes,
        with_acid_columns,
        List[Int](),
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def read_orc_bytes_projected_with_dispatcher[
    disp_o: Origin[mut=True],
](
    file_bytes: Span[UInt8, _],
    projection: List[Int],
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware sibling of `read_orc_bytes_projected`."""
    return _read_orc_bytes_core[has_dispatcher=True, disp_o=disp_o](
        file_bytes,
        False,
        projection,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


# =============================================================================
# Column-parallel decode — LocalDispatcher.run_with_state dispatch.
# =============================================================================
#
# Library code does not call the stdlib `parallelize` directly; it runs on the
# caller's `LocalDispatcher`, with the State/Segment/3-entry shape used across
# the engine's parallel kernels:
#   * `_OrcDecodeColsState[fb_o]` (KeepAlive, Movable) — OWNS the per-column
#     accumulator slab (`accs`), the per-column Arrow-Column output slab
#     (`col_out`), the per-column error channel (`col_errors`), and the
#     immutable serial-prelude inputs (`stripe_locs`, `stripe_nrows`,
#     `stripe_enc_kind`, `stripe_dict_size`, `col_ids`, `col_kinds`).
#     BORROWS the caller's `file_bytes` read-only via a typed-origin
#     `UnsafePointer[UInt8, fb_o]` + length (reconstructs a `Span` per task).
#     ZERO wildcard-origin fields.
#   * `_OrcDecodeColsTask[fb_o]` (Segment) — one task per DISPATCH worker;
#     each worker stride-partitions the columns it owns (`j % n_workers ==
#     task_id`) and runs the FULL per-column body (gather + decompress +
#     decode across every stripe, then `acc.build()` the Arrow Column in
#     worker), writing ONLY its own `accs[j]` / `col_out[j]` / `col_errors[j]`
#     slots — a disjoint-slot contract.
#   * Three entry points (canonical _serial / _with_dispatcher / _impl split):
#     - `_decode_orc_columns_parallel` — serial-fallback wrapper
#       (`has_pool=False`); callers without a dispatcher (the dispatcher-less
#       read entry points + test fixtures) hit this. It runs
#       the per-column body in a plain serial loop — identical work, zero
#       stdlib `parallelize`.
#     - `_decode_orc_columns_parallel_with_dispatcher[fb_o, disp_o]` —
#       dispatcher-aware variant; threads the caller's dispatcher + cancel
#       token into `LocalDispatcher.run_with_state` for the parallel
#       per-column decode.
#     - `_decode_orc_columns_impl[fb_o, has_pool, disp_o]` — shared body;
#       comptime `has_pool` prunes the parallel/serial branch. The lists are
#       MOVED INTO State at dispatch entry and reclaimed via `Optional.take()`
#       at dispatch return (never a partial move via
#       `UnsafePointer(to=state.field).take_pointee()`).
#
# SAFETY (DISPATCH-BOUNDARY): `run_with_state` is a synchronous wake-word
# barrier (fork-join). `file_bytes` is
# borrowed read-only via a CONCRETE typed origin (`fb_o`), never a wildcard;
# the barrier guarantees no worker dereferences it after this frame returns.
# Each worker writes a disjoint set of slab slots — zero shared mutable state.


struct _OrcDecodeColsState[
    fb_o: ImmOrigin,
](KeepAlive, Movable):
    """State for column-parallel ORC decode dispatch.

    OWNS every per-column work container + the immutable serial-prelude
    inputs (all `Optional`-wrapped so the State drop sees None placeholders
    after `Optional.take()` reclaim). BORROWS `file_bytes` read-only via a
    CONCRETE typed-origin pointer (`fb_o`) — no stale-pointer hazard across
    destroy and recreate, no wildcard.
    """

    # Borrowed read-only input — pinned to the caller's `file_bytes` Span
    # via `fb_o`. SAFETY: internal typed pointer; never exposed to the
    # public API. The task reconstructs a `Span[UInt8, fb_o]` from
    # (file_bytes_ptr, file_len).
    var file_bytes_ptr: UnsafePointer[UInt8, Self.fb_o]
    var file_len: Int
    # OWNED per-column accumulators. Each slot is an Optional that a worker
    # empties with `Optional.take()` before building the Arrow Column, so
    # every slot stays initialised and the slab drops soundly on ANY unwind
    # (a column error, a cancelled or failed dispatch).
    var accs: Optional[Slab[Optional[ColumnAcc]]]
    # OWNED per-column Arrow-Column output channel.
    var col_out: Optional[Slab[Optional[Column[HeapRegion]]]]
    # OWNED per-column error channel (workers cannot raise; first error per
    # column is stashed here and re-raised by the serial epilogue).
    var col_errors: Optional[List[Optional[String]]]
    # OWNED immutable serial-prelude inputs (read-only in the worker body).
    var stripe_locs: Optional[List[List[_StreamLoc]]]
    var stripe_nrows: Optional[List[Int]]
    var stripe_enc_kind: Optional[List[List[Int]]]
    var stripe_dict_size: Optional[List[List[Int]]]
    var col_ids: Optional[List[Int]]
    var col_kinds: Optional[List[Int]]
    # POD scalars.
    var n_cols: Int
    var n_stripes: Int
    var codec: Int
    var block_size: Int
    var n_workers: Int

    def __init__(
        out self,
        file_bytes_ptr: UnsafePointer[UInt8, Self.fb_o],
        file_len: Int,
        var accs: Slab[Optional[ColumnAcc]],
        var col_out: Slab[Optional[Column[HeapRegion]]],
        var col_errors: List[Optional[String]],
        var stripe_locs: List[List[_StreamLoc]],
        var stripe_nrows: List[Int],
        var stripe_enc_kind: List[List[Int]],
        var stripe_dict_size: List[List[Int]],
        var col_ids: List[Int],
        var col_kinds: List[Int],
        n_cols: Int,
        n_stripes: Int,
        codec: Int,
        block_size: Int,
        n_workers: Int,
    ):
        self.file_bytes_ptr = file_bytes_ptr
        self.file_len = file_len
        self.accs = Optional[Slab[Optional[ColumnAcc]]](accs^)
        self.col_out = Optional[Slab[Optional[Column[HeapRegion]]]](col_out^)
        self.col_errors = Optional[List[Optional[String]]](col_errors^)
        self.stripe_locs = Optional[List[List[_StreamLoc]]](stripe_locs^)
        self.stripe_nrows = Optional[List[Int]](stripe_nrows^)
        self.stripe_enc_kind = Optional[List[List[Int]]](stripe_enc_kind^)
        self.stripe_dict_size = Optional[List[List[Int]]](stripe_dict_size^)
        self.col_ids = Optional[List[Int]](col_ids^)
        self.col_kinds = Optional[List[Int]](col_kinds^)
        self.n_cols = n_cols
        self.n_stripes = n_stripes
        self.codec = codec
        self.block_size = block_size
        self.n_workers = n_workers


@fieldwise_init
struct _OrcDecodeColsTask[
    fb_o: ImmOrigin,
](Segment):
    """POD Segment for _OrcDecodeColsState dispatch — `n_workers` tasks,
    each stride-partitioning the columns it owns across [0, n_cols)."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY: the dispatch helper parameterizes run_with_state over
        # (_OrcDecodeColsState[fb_o], _OrcDecodeColsTask[fb_o]); the bitcast
        # resolves to the concrete state at the call site.
        var sp = UnsafePointer(to=state).bitcast[
            _OrcDecodeColsState[Self.fb_o]
        ]()
        var tid = Int(task_id)
        var n_workers = sp[].n_workers
        var n_cols_local = sp[].n_cols
        var n_stripes_local = sp[].n_stripes
        var codec_local = sp[].codec
        var block_size_local = sp[].block_size
        # Reconstruct the borrowed read-only file_bytes Span from the typed
        # pointer + length (concrete origin `fb_o`; no wildcard).
        var file_bytes_local = Span[UInt8, Self.fb_o](
            unsafe_ptr=sp[].file_bytes_ptr, length=sp[].file_len
        )
        # Stride partition: worker `tid` handles every column `j` with
        # `j % n_workers == tid` (balanced load).
        var j = tid
        while j < n_cols_local:
            try:
                ref acc = sp[].accs.value().get_mut_interior(j).value()
                var col_id = sp[].col_ids.value()[j]
                var kind = sp[].col_kinds.value()[j]
                for s in range(n_stripes_local):
                    ref locs = sp[].stripe_locs.value()[s]
                    var col_streams = _gather_column_streams(
                        locs, file_bytes_local, col_id, codec_local,
                        block_size_local,
                    )
                    decode_stripe_column(
                        acc,
                        kind,
                        sp[].stripe_enc_kind.value()[s][j],
                        sp[].stripe_dict_size.value()[s][j],
                        col_streams,
                        sp[].stripe_nrows.value()[s],
                    )
                # Build the Arrow Column in-worker (parallel), moving the
                # now-decoded accumulator out of its slot (left None).
                var owned_acc = sp[].accs.value().get_mut_interior(j).take()
                ref out_slot = sp[].col_out.value().get_mut_interior(j)
                out_slot = Optional[Column[HeapRegion]](owned_acc^.build())
            except e:
                sp[].col_errors.value()[j] = Optional[String](String(e))
            j = j + n_workers


# Result of the column-parallel decode: the accumulator slab (a slot is None
# where its column was built, Some where its column failed), the per-column
# Arrow-Column output slab, and the per-column error channel. Returned by
# move so the caller's epilogue can drain `col_out` into the RecordBatch and
# re-raise the first `col_errors`. The three are `Optional`-wrapped and
# reclaimed via `Optional.take()` (never a partial move; the struct drop sees
# None placeholders after the caller takes each).
struct _OrcDecodeColsResult(Movable):
    var accs: Optional[Slab[Optional[ColumnAcc]]]
    var col_out: Optional[Slab[Optional[Column[HeapRegion]]]]
    var col_errors: Optional[List[Optional[String]]]

    def __init__(
        out self,
        var accs: Slab[Optional[ColumnAcc]],
        var col_out: Slab[Optional[Column[HeapRegion]]],
        var col_errors: List[Optional[String]],
    ):
        self.accs = Optional[Slab[Optional[ColumnAcc]]](accs^)
        self.col_out = Optional[Slab[Optional[Column[HeapRegion]]]](col_out^)
        self.col_errors = Optional[List[Optional[String]]](col_errors^)


def _decode_orc_columns_parallel[
    fb_o: ImmOrigin,
](
    file_bytes: Span[UInt8, fb_o],
    var accs: Slab[Optional[ColumnAcc]],
    var col_out: Slab[Optional[Column[HeapRegion]]],
    var col_errors: List[Optional[String]],
    var stripe_locs: List[List[_StreamLoc]],
    var stripe_nrows: List[Int],
    var stripe_enc_kind: List[List[Int]],
    var stripe_dict_size: List[List[Int]],
    var col_ids: List[Int],
    var col_kinds: List[Int],
    n_cols: Int,
    n_stripes: Int,
    codec: Int,
    block_size: Int,
) raises -> _OrcDecodeColsResult:
    """Serial-fallback wrapper for `_decode_orc_columns_parallel_with_dispatcher`.

    Callers without a dispatcher (the dispatcher-less read entry points +
    test fixtures) hit this entry point. Runs the
    per-column decode body in a plain serial loop — identical work, zero
    stdlib `parallelize`.
    """
    return _decode_orc_columns_impl[fb_o, has_pool=False, disp_o=MutAnyOrigin](
        file_bytes,
        accs^,
        col_out^,
        col_errors^,
        stripe_locs^,
        stripe_nrows^,
        stripe_enc_kind^,
        stripe_dict_size^,
        col_ids^,
        col_kinds^,
        n_cols,
        n_stripes,
        codec,
        block_size,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def _decode_orc_columns_parallel_with_dispatcher[
    fb_o: ImmOrigin,
    disp_o: Origin[mut=True],
](
    file_bytes: Span[UInt8, fb_o],
    var accs: Slab[Optional[ColumnAcc]],
    var col_out: Slab[Optional[Column[HeapRegion]]],
    var col_errors: List[Optional[String]],
    var stripe_locs: List[List[_StreamLoc]],
    var stripe_nrows: List[Int],
    var stripe_enc_kind: List[List[Int]],
    var stripe_dict_size: List[List[Int]],
    var col_ids: List[Int],
    var col_kinds: List[Int],
    n_cols: Int,
    n_stripes: Int,
    codec: Int,
    block_size: Int,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> _OrcDecodeColsResult:
    """Dispatcher-aware variant — threads `dispatcher_ptr` + `cancel_token`
    from the caller down to `LocalDispatcher.run_with_state` for the parallel per-column
    decode.
    """
    return _decode_orc_columns_impl[fb_o, has_pool=True, disp_o=disp_o](
        file_bytes,
        accs^,
        col_out^,
        col_errors^,
        stripe_locs^,
        stripe_nrows^,
        stripe_enc_kind^,
        stripe_dict_size^,
        col_ids^,
        col_kinds^,
        n_cols,
        n_stripes,
        codec,
        block_size,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_orc_columns_impl[
    fb_o: ImmOrigin,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    file_bytes: Span[UInt8, fb_o],
    var accs: Slab[Optional[ColumnAcc]],
    var col_out: Slab[Optional[Column[HeapRegion]]],
    var col_errors: List[Optional[String]],
    var stripe_locs: List[List[_StreamLoc]],
    var stripe_nrows: List[Int],
    var stripe_enc_kind: List[List[Int]],
    var stripe_dict_size: List[List[Int]],
    var col_ids: List[Int],
    var col_kinds: List[Int],
    n_cols: Int,
    n_stripes: Int,
    codec: Int,
    block_size: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> _OrcDecodeColsResult:
    """Column-parallel ORC decode driver. Each worker decodes a stride-
    partitioned subset of the projected columns (gather + decompress +
    decode across every stripe, then `acc.build()` in-worker), writing only
    its own disjoint `accs[j]` / `col_out[j]` / `col_errors[j]` slots.

    Comptime `has_pool` prunes the parallel/serial branch — no wildcard
    origin reaches the dispatch in either path (canonical
    `_dedup_count_parallel_impl` pattern). Returns the (`accs`,
    `col_out`, `col_errors`) for the caller's serial epilogue.
    """
    if n_cols == 0:
        _ = cancel_token^
        return _OrcDecodeColsResult(accs^, col_out^, col_errors^)

    comptime if has_pool:
        # Resolve effective worker count: cap at min(n_cols, cores).
        var n_workers = num_physical_cores()
        if n_workers > n_cols:
            n_workers = n_cols
        if n_workers < 1:
            n_workers = 1

        # DISPATCH-BOUNDARY: build State + Task; dispatch via
        # LocalDispatcher.run_with_state. CONCRETE typed origins; no
        # MutExternalOrigin wildcards. `file_bytes` is borrowed read-only
        # via the typed-origin pointer; the per-column work containers are
        # MOVED INTO State and reclaimed via `Optional.take()` post-dispatch.
        var state = _OrcDecodeColsState[fb_o](
            file_bytes.unsafe_ptr(),
            len(file_bytes),
            accs^,
            col_out^,
            col_errors^,
            stripe_locs^,
            stripe_nrows^,
            stripe_enc_kind^,
            stripe_dict_size^,
            col_ids^,
            col_kinds^,
            n_cols,
            n_stripes,
            codec,
            block_size,
            n_workers,
        )
        var task = _OrcDecodeColsTask[fb_o](Int32(0))
        var disp = dispatcher_ptr.value()
        _ = disp[].run_with_state[
            _OrcDecodeColsState[fb_o],
            _OrcDecodeColsTask[fb_o],
        ](state, task^, n_workers, cancel_token^, site_id=SITE_FORMAT_READ)

        # Reclaim the work containers from State via Optional.take
        # (never a partial move via UnsafePointer). State drops at scope exit with all
        # Optional fields in None state. Only the three the caller needs
        # are returned; the rest drop here.
        var accs_back = state.accs.take()
        var col_out_back = state.col_out.take()
        var col_errors_back = state.col_errors.take()
        _ = state.stripe_locs.take()
        _ = state.stripe_nrows.take()
        _ = state.stripe_enc_kind.take()
        _ = state.stripe_dict_size.take()
        _ = state.col_ids.take()
        _ = state.col_kinds.take()
        _ = state^
        return _OrcDecodeColsResult(accs_back^, col_out_back^, col_errors_back^)
    else:
        # has_pool=False: caller did not thread a dispatcher. Serial per-
        # column loop on the same containers — identical work, no
        # parallelize.
        _ = cancel_token^
        for j in range(n_cols):
            try:
                ref acc = accs.get_mut_interior(j).value()
                var col_id = col_ids[j]
                var kind = col_kinds[j]
                for s in range(n_stripes):
                    ref locs = stripe_locs[s]
                    var col_streams = _gather_column_streams(
                        locs, file_bytes, col_id, codec, block_size,
                    )
                    decode_stripe_column(
                        acc,
                        kind,
                        stripe_enc_kind[s][j],
                        stripe_dict_size[s][j],
                        col_streams,
                        stripe_nrows[s],
                    )
                var owned_acc = accs.get_mut_interior(j).take()
                ref out_slot = col_out.get_mut_interior(j)
                out_slot = Optional[Column[HeapRegion]](owned_acc^.build())
            except e:
                col_errors[j] = Optional[String](String(e))
        return _OrcDecodeColsResult(accs^, col_out^, col_errors^)


def _read_orc_bytes_core[
    has_dispatcher: Bool = False,
    disp_o: Origin[mut=True] = MutAnyOrigin,
](
    file_bytes: Span[UInt8, _],
    with_acid_columns: Bool,
    projection: List[Int],
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]] = None,
    var cancel_token: CancellationToken = CancellationToken.never(),
) raises -> RecordBatch:
    """Shared ORC decode body. The comptime `has_dispatcher` flag prunes the
    parallel/serial column-decode branch at compile time: when `True` the
    column decode runs through `_decode_orc_columns_parallel_with_dispatcher`
    (caller-owned `LocalDispatcher.run_with_state` fork-join); when
    `False` (test fixtures / dispatcher-less callers) it runs the serial
    fallback. Byte-identical output either way.
    """
    var tail = _parse_tail_codec_aware(file_bytes)
    var schema = OrcSchema.from_types(tail.footer.types.copy())

    var codec = tail.post_script.compression
    var block_size = tail.post_script.compression_block_size

    if _schema_needs_nested_path(schema, with_acid_columns):
        # The nested / ACID path decodes recursively (single-stripe);
        # it does not use the column-decode fork-join, so drop the cancel_token.
        _ = cancel_token^
        if len(projection) != 0:
            raise Error(
                "OrcDecodeError.UNSUPPORTED: column-projection on nested / ACID"
                " ORC schemas is not supported (the nested path decodes all"
                " top-level columns)"
            )
        return _read_orc_nested(
            file_bytes, tail, schema, codec, block_size, with_acid_columns
        )

    var child_positions = _resolve_projection(schema, projection)
    var out_schema = _build_output_schema(schema, child_positions)
    var root = schema.node(0)
    var n_cols = len(child_positions)

    # One accumulator per PROJECTED output column, appended across ALL stripes,
    # then built once into a single RecordBatch (no batch concatenation needed —
    # mirrors the Avro ActionTableInterpreter accumulator).
    #
    # Pre-reserve each accumulator's active inner list + present list to the
    # file's total row count BEFORE the stripe loop. Without it, the geometric
    # growth cascade of `acc.i64s` across hundreds of stripes
    # (`List._realloc -> memmove`) dominates the decode. With the row count
    # known from the Footer, one up-front reserve eliminates ALL log2(stripes)
    # intermediate full-prefix memmoves.
    var total_rows = tail.footer.number_of_rows
    # `total_rows` is `Footer.numberOfRows` — writer-chosen metadata — and it is
    # about to become one allocation PER PROJECTED COLUMN. Cross-check it
    # against the bytes that exist: even a fully-RLE-compressed column costs
    # more than a bit per row, so a file cannot back more rows than it has bits.
    # This is the cheap file-relative bound; `ColumnAcc.reserve` carries the
    # absolute one (`ORC_MAX_ROWS`) for callers that do not come through here.
    if total_rows < 0 or total_rows > len(file_bytes) * 8:
        raise Error(
            String("OrcDecodeError.BAD_ROW_COUNT: Footer.numberOfRows = ")
            + String(total_rows)
            + " cannot be backed by a "
            + String(len(file_bytes))
            + "-byte file"
        )
    var accs = Slab[Optional[ColumnAcc]]()
    var col_ids = List[Int]()
    var col_kinds = List[Int]()
    for j in range(n_cols):
        var col_id = root.subtypes[child_positions[j]]
        var child = schema.node(col_id)
        var at = orc_node_to_arrow(schema, col_id)
        var acc = make_accumulator(child.kind, at)
        acc.reserve(total_rows)
        accs.append(Optional[ColumnAcc](acc^))
        col_ids.append(col_id)
        col_kinds.append(child.kind)

    # =====================================================================
    # Column-parallel decode.
    # =====================================================================
    # An ORC file's top-level columns are fully independent (disjoint stream
    # byte spans, disjoint output buffers), so they decode in parallel: each
    # worker gathers + decompresses + decodes ALL of its columns' streams
    # across every stripe into ITS OWN accumulator. Gather+decompress dominates
    # a compressed file and decode dominates an uncompressed one, so
    # parallelizing the WHOLE per-column body — not just decode — engages
    # every core on both. RecordBatch assembly stays serial after the join.
    #
    # SERIAL PRELUDE: parse every stripe footer once (cheap)
    # and precompute the per-stripe located-stream lists + per-(stripe,col)
    # encoding so each parallel worker reads only immutable shared state.
    var n_stripes = tail.footer.num_stripes()
    var stripe_locs = List[List[_StreamLoc]]()
    var stripe_nrows = List[Int]()
    # Per stripe, per output column j: encoding kind + dictionary size.
    var stripe_enc_kind = List[List[Int]]()
    var stripe_dict_size = List[List[Int]]()
    var declared_stripe_rows = 0
    for s in range(n_stripes):
        var stripe = tail.footer.stripes[s].copy()
        # This is the FIRST thing the reader touches per stripe — before any
        # column logic — so it is reachable with a ~100-byte file. Its endpoints
        # are the sum of four attacker-chosen uint64s
        # (offset + indexLength + dataLength, then + footerLength).
        _checked_file_span(
            len(file_bytes),
            stripe.stripe_footer_start(),
            stripe.stripe_footer_end(),
            "stripe " + String(s) + " footer",
        )
        var sf_raw = file_bytes[
            stripe.stripe_footer_start() : stripe.stripe_footer_end()
        ]
        var sf_bytes = decompress_stream(sf_raw, codec, block_size)
        var sf = StripeFooter.parse(sf_bytes)
        stripe_locs.append(_locate_streams(sf, stripe, len(file_bytes)))
        # ⚠ THE PER-STRIPE ROW COUNTS ARE INDEPENDENT OF Footer.numberOfRows.
        #
        # `acc.reserve(total_rows)` above sized every output column to the
        # FOOTER's row count, but the decode writes `stripe.number_of_rows`
        # values per stripe at the cumulative cursor `acc.n_rows`. Nothing
        # requires the per-stripe counts to sum to the footer's: a file
        # declaring numberOfRows = 1 with one stripe claiming 1,000,000 rows
        # would write ~8 MB of attacker-controlled Int64s into an 8-byte
        # allocation.
        #
        # `rle_decode.decode_rlev2_into_span` raises DESTINATION_OVERRUN, so the
        # write is stopped either way — but stopping it HERE, before a single stream is
        # gathered or decompressed, costs one add per stripe and produces an
        # error that names the actual inconsistency instead of a buffer size.
        var s_rows = stripe.number_of_rows
        if s_rows < 0 or s_rows > len(file_bytes) * 8:
            raise Error(
                String("OrcDecodeError.BAD_ROW_COUNT: stripe ")
                + String(s)
                + " declares "
                + String(s_rows)
                + " rows, which a "
                + String(len(file_bytes))
                + "-byte file cannot back"
            )
        declared_stripe_rows += s_rows
        if declared_stripe_rows > total_rows:
            raise Error(
                String("OrcDecodeError.STRIPE_ROWS_EXCEED_FOOTER: stripes 0..")
                + String(s)
                + " declare "
                + String(declared_stripe_rows)
                + " rows in total, but Footer.numberOfRows is "
                + String(total_rows)
                + " (the output buffers were sized to the footer's count)"
            )
        stripe_nrows.append(stripe.number_of_rows)
        var enc_kinds = List[Int]()
        var dict_sizes = List[Int]()
        for j in range(n_cols):
            var col_id = col_ids[j]
            if col_id >= len(sf.columns):
                raise Error(
                    "OrcDecodeError.MISSING_ENCODING: column id "
                    + String(col_id)
                    + " has no ColumnEncoding entry"
                )
            var encoding = sf.columns[col_id].copy()
            enc_kinds.append(encoding.kind)
            dict_sizes.append(encoding.dictionary_size)
        stripe_enc_kind.append(enc_kinds^)
        stripe_dict_size.append(dict_sizes^)

    # Per-column error channel (parallelize closures cannot raise — mirror
    # the CSV column-parallel reader's Optional[String] re-raise pattern).
    var col_errors = List[Optional[String]]()
    for _e in range(n_cols):
        col_errors.append(Optional[String](None))

    # Per-column OUTPUT channel: each worker builds its own Arrow Column AFTER
    # decoding (moving the accumulator out of its `accs` slot via
    # `Optional.take()`), so the `acc.build()` Column materialization —
    # otherwise the serial Amdahl tail of the decode — runs in parallel across
    # columns.
    # The serial epilogue only collects the finished Columns into a
    # RecordBatch (cheap pointer moves). Pre-sized to n_cols; each worker
    # writes ONLY its own slot j.
    # `Column` is Movable-only (not Copyable), so the output channel is a
    # `Slab[Optional[Column]]` (Slab requires only Movable), not a `List`
    # (List needs Copyable). Pre-filled with None; each worker assigns its
    # own slot j via `get_mut_interior`, the epilogue drains each with
    # `Optional.take()`.
    var col_out = Slab[Optional[Column[HeapRegion]]]()
    for _c in range(n_cols):
        col_out.append(Optional[Column[HeapRegion]](None))

    # The per-column decode runs on the caller-owned
    # `LocalDispatcher.run_with_state` fork-join substrate (library code does
    # not call stdlib `parallelize` directly). When the caller threads a
    # dispatcher (`has_dispatcher=True`), the decode fans across worker threads
    # via
    # `_decode_orc_columns_parallel_with_dispatcher`. Dispatcher-less
    # callers (test fixtures / direct-invocation) take the serial-fallback
    # entry — identical per-column decode work, zero stdlib `parallelize`.
    comptime if has_dispatcher:
        var _disp_ptr = dispatcher_ptr.value()
        var _r = _decode_orc_columns_parallel_with_dispatcher[
            disp_o=disp_o
        ](
            file_bytes, accs^, col_out^, col_errors^, stripe_locs^,
            stripe_nrows^, stripe_enc_kind^, stripe_dict_size^, col_ids^,
            col_kinds^, n_cols, n_stripes, codec, block_size,
            _disp_ptr, cancel_token^,
        )
        accs = _r.accs.take()
        col_out = _r.col_out.take()
        col_errors = _r.col_errors.take()
    else:
        _ = cancel_token^
        var _r = _decode_orc_columns_parallel(
            file_bytes, accs^, col_out^, col_errors^, stripe_locs^,
            stripe_nrows^, stripe_enc_kind^, stripe_dict_size^, col_ids^,
            col_kinds^, n_cols, n_stripes, codec, block_size,
        )
        accs = _r.accs.take()
        col_out = _r.col_out.take()
        col_errors = _r.col_errors.take()


    # No length fix-up on `accs` or `col_out`: every slot of both is an
    # Optional that stays initialised (None once taken), so both slabs drop
    # soundly on the re-raise below and on every other unwind.

    # Re-raise the first column failure, if any.
    for j in range(n_cols):
        if col_errors[j]:
            var msg = col_errors[j].value().copy()
            raise Error(
                String("OrcDecodeError: column-parallel decode of output")
                + String(" column ")
                + String(j)
                + String(" failed: ")
                + msg
            )

    # Every accumulator was already built into an Arrow Column IN-WORKER
    # (parallel) — drain the finished Columns into the RecordBatch. This
    # serial epilogue is a sequence of cheap pointer moves; the O(n_rows)
    # Column materialization happens in the parallel region.
    var builder = RecordBatchBuilder.with_capacity(n_cols)
    for j in range(n_cols):
        builder.add_column(col_out.get_mut_interior(j).take())
    return builder.build(out_schema.copy())


def read_orc_file(path: String) raises -> RecordBatch:
    """Read an ORC file from disk into a single Arrow RecordBatch."""
    # `read_chunked(path)` (mmap-backed whole-file slurp), not
    # `Path(path).read_bytes()`, so ORC reads stay correct on files >2 GB. The
    # stdlib `Path.read_bytes()` raises `"Failed to read from file:
    # Invalid argument"` (or silently truncates) on files >2 GB due to an
    # Int32 count overflow inside `FileHandle.read*`. Mmap returns a memory
    # region directly. `read_orc_bytes` is Span-poly; `.view_range_ro(0, length).into_span()` bridges.
    from komira_arrow_ipc.chunked_read import read_chunked

    var src_buf = read_chunked(path)
    return read_orc_bytes(
        src_buf.view_range_ro(0, src_buf.len()).into_span()
    )


def read_orc_file_opts(path: String, with_acid_columns: Bool) raises -> RecordBatch:
    """`read_orc_file` with the `with_acid_columns` ACID-exposure toggle."""
    # mmap-backed whole-file slurp — same reason as `read_orc_file` above.
    from komira_arrow_ipc.chunked_read import read_chunked

    var src_buf = read_chunked(path)
    return read_orc_bytes_opts(
        src_buf.view_range_ro(0, src_buf.len()).into_span(),
        with_acid_columns,
    )


def read_orc_file_with_dispatcher[
    disp_o: Origin[mut=True],
](
    path: String,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware sibling of `read_orc_file` — mmap-slurp the file then
    decode columns in parallel via the caller-owned `LocalDispatcher`.
    Byte-identical output to `read_orc_file`."""
    from komira_arrow_ipc.chunked_read import read_chunked

    var src_buf = read_chunked(path)
    return read_orc_bytes_with_dispatcher[disp_o=disp_o](
        src_buf.view_range_ro(0, src_buf.len()).into_span(),
        dispatcher_ptr,
        cancel_token^,
    )


# =============================================================================
# Nested / ACID read path (single-stripe, recursive descent).
# =============================================================================
#
# The flat fast path accumulates PRIMITIVE columns across stripes into a flat
# ColumnAcc. The nested path materializes each top-level output column (which
# may be a compound subtree) via `decode_column_subtree`. Multi-stripe
# concatenation of nested columns is not supported yet: >1 stripe with nested
# top-level columns raises a clear error.


def _build_nested_output_schema(
    schema: OrcSchema,
    col_node_idxs: List[Int],
    col_names: List[String],
) raises -> Schema:
    """Build the Arrow output Schema from the resolved output-column node
    indices + names, stamping arrow.orc.* extension metadata per leaf."""
    var sb = SchemaBuilder()
    for c in range(len(col_node_idxs)):
        var node_idx = col_node_idxs[c]
        var at = orc_node_to_arrow(schema, node_idx)
        var f = Field(col_names[c], at, True)
        stamp_arrow_orc_metadata(f, schema, node_idx)
        sb.add_field(f^)
    return sb.build()


def _read_orc_nested(
    file_bytes: Span[UInt8, _],
    tail: OrcFileTail,
    schema: OrcSchema,
    codec: Int,
    block_size: Int,
    with_acid_columns: Bool,
) raises -> RecordBatch:
    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        raise Error(
            "OrcDecodeError.ROOT_NOT_STRUCT: nested read needs a top-level"
            " struct"
        )

    # Resolve the top-level output columns. For an ACID file this lifts row.*
    # (default) or exposes all 6 columns (with_acid_columns=True). For a plain
    # nested file it is the root struct's direct children.
    var col_node_idxs = List[Int]()
    var col_names = List[String]()
    if is_acid_schema(schema):
        var plan = acid_output_columns(schema, with_acid_columns)
        col_node_idxs = plan.node_idxs.copy()
        col_names = plan.names.copy()
    else:
        for i in range(len(root.subtypes)):
            col_node_idxs.append(root.subtypes[i])
            if i < len(root.field_names):
                col_names.append(root.field_names[i])
            else:
                col_names.append(String("_col") + String(i))

    var out_schema = _build_nested_output_schema(
        schema, col_node_idxs, col_names
    )

    var n_stripes = tail.footer.num_stripes()
    if n_stripes != 1:
        raise Error(
            "OrcDecodeError.UNSUPPORTED: nested / ACID ORC read is single-"
            "stripe (got "
            + String(n_stripes)
            + " stripes); multi-stripe nested concat is not supported"
        )

    var stripe = tail.footer.stripes[0].copy()
    var n_rows = stripe.number_of_rows
    _checked_file_span(
        len(file_bytes),
        stripe.stripe_footer_start(),
        stripe.stripe_footer_end(),
        "stripe 0 footer",
    )
    var sf_raw = file_bytes[
        stripe.stripe_footer_start() : stripe.stripe_footer_end()
    ]
    var sf_bytes = decompress_stream(sf_raw, codec, block_size)
    var sf = StripeFooter.parse(sf_bytes)
    var locs = _locate_streams(sf, stripe, len(file_bytes))

    # Flatten located streams into the parallel-list form the recursive
    # decoder consumes (no _StreamLoc back-import cycle).
    var lk = List[Int]()
    var lc = List[Int]()
    var ls = List[Int]()
    var le = List[Int]()
    for i in range(len(locs)):
        var loc = locs[i].copy()
        lk.append(loc.kind)
        lc.append(loc.column)
        ls.append(loc.start)
        le.append(loc.end)

    var builder = RecordBatchBuilder.with_capacity(len(col_node_idxs))
    for c in range(len(col_node_idxs)):
        var col = decode_column_subtree(
            schema, col_node_idxs[c], sf, lk, lc, ls, le, file_bytes,
            codec, block_size, n_rows,
        )
        builder.add_column(col^)
    return builder.build(out_schema.copy())
