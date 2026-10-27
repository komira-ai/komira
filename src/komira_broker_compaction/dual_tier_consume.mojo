# =============================================================================
# dual_tier_consume.mojo: the dual-tier consume (compacted Parquet + live
# Arrow-IPC)
# =============================================================================
#
# The read path: resolve `[start_offset, tail)` across BOTH tiers (compacted
# Parquet and live Arrow-IPC) via `dual_tier_resolve` in `komira_broker`, GET
# each object's bytes, decode by tier, and hand back ordered RecordBatches.
#
#   compacted TierRef -> GET Parquet bytes -> decode_compacted_parquet_bytes
#   live      TierRef -> GET .seg bytes -> slice footer -> decode_arrow_ipc_stream
#
# READ-REPAIR: a live `.seg` GET that returns not-found (the segment was
# compacted and reaped underneath a slow reader, past the grace window) is
# handled by re-resolving the dual tier and falling back to the now-compacted
# range. The grace window (ReapWorker reaps only after the grace period) is the
# primary protection against that race; read-repair handles the residual. No
# leases are taken.
#
# Why this is in the adapter: it decodes both Arrow-IPC and Parquet, which
# `komira_broker` may not depend on. The offset resolution and the read-repair
# re-query live in `komira_broker` (`dual_tier_resolve`); this module is the
# format-aware decode and the GET fetch.
#
# No UnsafePointer in any signature; the substrate is held by value.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_collections.slab import Slab

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_broker.broker_core import SegmentFooter
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.compacted_index import (
    CompactionIndex,
    TierRef,
    dual_tier_resolve,
)
from komira_broker.sublineage_consume import SubLineageConsumeResolver

from komira_objectstore.store import CloneableConditionalWriteStore

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream
from komira_broker_compaction.consume_pushdown import _apply_consume_pushdown

from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
    ByteRange,
)
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet.rg_pruner import can_prune_row_group


# PAR1 magic.
comptime _PAR1_0 = UInt8(80)  # 'P'
comptime _PAR1_1 = UInt8(65)  # 'A'
comptime _PAR1_2 = UInt8(82)  # 'R'
comptime _PAR1_3 = UInt8(49)  # '1'


# =============================================================================
# decode_compacted_parquet_bytes — in-memory Parquet object -> one RecordBatch.
# =============================================================================


def decode_compacted_parquet_bytes(
    var parquet_bytes: List[UInt8],
) raises -> RecordBatch:
    """Decode a WHOLE compacted Parquet object (in memory) into one RecordBatch.

    No local disk: loads the bytes into a `SharedAlignedBuffer`, parses the
    footer metadata, and decodes each row group via the IO-free
    `decode_row_group_from_bytes`. Because the buffer holds the WHOLE file, the
    Parquet absolute byte offsets equal the view offsets — the row-group byte
    range slices directly into the buffer.

    Compaction rounds are bounded (<= max_segments small segments => well under
    one row-group's row cap), so a compacted object is single-row-group in the
    common case; a multi-RG object is decoded RG-by-RG and the per-RG batches
    are concatenated (each RG shares one schema).
    """
    var n = len(parquet_bytes)
    if n < 12:
        raise Error(
            "decode_compacted_parquet_bytes: object too small ("
            + String(n)
            + " bytes) to be a Parquet file"
        )
    # Trailing 8 bytes = footer_len (4 LE) + PAR1 magic (4).
    if (
        parquet_bytes[n - 4] != _PAR1_0
        or parquet_bytes[n - 3] != _PAR1_1
        or parquet_bytes[n - 2] != _PAR1_2
        or parquet_bytes[n - 1] != _PAR1_3
    ):
        raise Error("decode_compacted_parquet_bytes: missing trailing PAR1 magic")
    var footer_len = (
        Int(parquet_bytes[n - 8])
        | (Int(parquet_bytes[n - 7]) << 8)
        | (Int(parquet_bytes[n - 6]) << 16)
        | (Int(parquet_bytes[n - 5]) << 24)
    )
    if footer_len <= 0 or footer_len + 8 > n:
        raise Error(
            "decode_compacted_parquet_bytes: invalid footer length "
            + String(footer_len)
        )
    var metadata_offset = n - 8 - footer_len

    # Load the whole object into an aligned buffer (view offsets == file
    # absolute offsets).
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    buf.copy_from_bytes_list(parquet_bytes^)
    buf.set_length(n)

    var meta = parse_full_metadata(
        buf.view_range_ro(metadata_offset, footer_len)
    )
    var num_rgs = len(meta.row_groups)
    if num_rgs == 0:
        # Empty object — return an empty RecordBatch.
        _ = buf^
        return RecordBatch()

    var batches = Slab[RecordBatch]()
    for rg_idx in range(num_rgs):
        var rg = meta.row_groups[rg_idx].copy()
        var rg_br = row_group_byte_range(rg)
        var rg_view = buf.view_range_ro(rg_br.start, rg_br.length())
        var batch = decode_row_group_from_bytes(
            rg_view,
            rg_br,
            rg,
            meta.schema,
            ColumnProjection.all(),
        )
        batches.append(batch^)

    var nb = len(batches)
    var result: RecordBatch
    if nb == 1:
        result = batches.take_slot_unchecked(0)^
        batches.set_len_unchecked(0)
        _ = batches^
    else:
        # Multi-RG: fold the per-RG batches into one. For the bounded compaction
        # round (max_segments small segments => well under one RG's row cap) a
        # compacted object is single-RG, so this path is the rare large case.
        result = _fold_record_batches(batches^)

    # KEEPALIVE: hold `buf` alive past the batch construction. Mojo 1.0.0b1's
    # ASAP destruction can drop `buf` immediately after the last `view_range_ro`
    # — but a freshly-decoded column's FIRST data page can still be in flight
    # against the source view at that point (observed: row 0 reading
    # pointer-sized garbage when `buf` is freed early via `_ = buf^`). A method
    # call with an observable read on `buf` after `result` is built anchors the
    # buffer's liveness through the decode (an empty
    # `_ = buf` is NOT reliable; a real read is).
    var _anchor = buf.read_u8_at(n - 1)
    _ = _anchor
    _ = buf^
    return result^


# =============================================================================
# CompactedDecodeResult — a pruned compacted-object decode + its RG accounting.
# =============================================================================
#
# A predicate prunes row groups on the compacted Parquet tier, so the decode
# returns not just the batch but the row-group accounting: how many row groups
# the object had, how many the zonemap pruner skipped (no decode), and how many
# were decoded. `rgs_pruned > 0` shows that the row-group zonemap
# (`can_prune_row_group`) fired on this tier.


@fieldwise_init
struct CompactedDecodeResult(Movable, Deinitable):
    """A compacted-tier decode with predicate+projection pushdown + its
    row-group pruning accounting.

    Field layout:
      var batch: RecordBatch — the decoded (filtered + projected) rows.
      var rgs_total: Int     — row groups in the compacted Parquet object.
      var rgs_pruned: Int    — row groups SKIPPED by the zonemap pruner
                               (`can_prune_row_group` proved no match — no
                               decode, no IO into them). The capability-demo
                               win.
      var rgs_decoded: Int   — row groups actually decoded
                               (== rgs_total - rgs_pruned).
    """

    var batch: RecordBatch
    var rgs_total: Int
    var rgs_pruned: Int
    var rgs_decoded: Int

    def take_batch(deinit self) -> RecordBatch:
        """Consume `self`, returning the decoded batch. Mojo 1.0.0b1 rejects a
        single-field `^`-move out of the middle of a struct, so this whole-value
        consume (`deinit self` — the canonical idiom, mirrors
        `ConsumeSegment.take_stream_bytes`) moves the heap-owning `batch` field
        out without a partial-move. The POD RG-count fields are read BEFORE this
        call (they drop with the whole value)."""
        return self.batch^


# =============================================================================
# _projection_to_column_projection — map a name-list projection to leaf indices.
# =============================================================================


def _projection_to_column_projection(
    schema: Schema, projection: Optional[List[String]]
) raises -> ColumnProjection:
    """Map the consumer's `projection: List[String]` (column NAMES) to a Parquet
    `ColumnProjection` (leaf 0-based indices, in projection order) against the
    compacted object's Arrow `schema`. `None` -> `ColumnProjection.all()`.

    A projected name absent from the schema is a fail-loud error (the consumer
    asked for a column the compacted object does not carry). Mirrors the
    name->index resolution the engine ParquetSource projection uses; the leaf
    index is the Arrow column position (the compacted object is flat — no nested
    columns — so Arrow column i == parquet leaf i)."""
    if not projection:
        return ColumnProjection.all()
    ref names = projection.value()
    var indices = List[Int]()
    for i in range(len(names)):
        var found = -1
        for c in range(schema.num_columns()):
            if schema.field_name(c) == names[i]:
                found = c
                break
        if found < 0:
            raise Error(
                "decode_compacted_parquet_bytes_pushdown: projected column '"
                + names[i]
                + "' is not present in the compacted object's schema"
            )
        indices.append(found)
    return ColumnProjection.columns(indices^)


# =============================================================================
# decode_compacted_parquet_bytes_pushdown — RG/column-pruned compacted decode.
# =============================================================================


def decode_compacted_parquet_bytes_pushdown(
    var parquet_bytes: List[UInt8],
    var predicate: Optional[Expr],
    var projection: Optional[List[String]],
) raises -> CompactedDecodeResult:
    """Decode a WHOLE compacted Parquet object with compacted-tier pushdown:
    row-group zonemap PRUNING + column PROJECTION + a correctness row filter.

    This is the compacted-tier dual of the live tier's decode-time filter
    (`_apply_consume_pushdown`). Where the live Arrow-IPC
    tier carries no zonemap (so the win is only filter-before-flow), the
    COMPACTED Parquet tier carries per-row-group min/max statistics, so a
    `col <op> literal` predicate can SKIP whole row groups without decoding them
    — the genuine `ParquetSource` zonemap pruning (`rg_pruner.can_prune_row_group`,
    the same code path the engine's local Parquet scan uses).

    Pipeline (per row group):
      1. PRUNE: `can_prune_row_group(rg, metadata, predicate)` — if it proves the
         RG cannot match, SKIP it entirely (no byte slice, no column decode). The
         pruned-RG count is the capability-demo evidence (SCOPE item 4).
      2. PROJECT: decode only the projected leaf columns
         (`_projection_to_column_projection` -> `ColumnProjection`).
      3. FILTER: after the surviving RGs are decoded + folded, apply the row
         predicate for CORRECTNESS (the pruner is conservative — a surviving RG
         may still hold non-matching rows) + re-project, via the SAME
         `_apply_consume_pushdown` the live tier uses (byte-identical row set).

    CORRECTNESS: the predicate is ALWAYS applied at step 3; pruning at step 1 is
    a pure performance win that NEVER drops a matching row (`can_prune_row_group`
    returns True only when the stats PROVE no match; ambiguity -> conservative
    False -> the RG is decoded + the row filter decides).

    Returns the filtered+projected batch plus the RG accounting
    (`rgs_total` / `rgs_pruned` / `rgs_decoded`)."""
    var n = len(parquet_bytes)
    if n < 12:
        raise Error(
            "decode_compacted_parquet_bytes_pushdown: object too small ("
            + String(n)
            + " bytes) to be a Parquet file"
        )
    if (
        parquet_bytes[n - 4] != _PAR1_0
        or parquet_bytes[n - 3] != _PAR1_1
        or parquet_bytes[n - 2] != _PAR1_2
        or parquet_bytes[n - 1] != _PAR1_3
    ):
        raise Error(
            "decode_compacted_parquet_bytes_pushdown: missing trailing PAR1"
            " magic"
        )
    var footer_len = (
        Int(parquet_bytes[n - 8])
        | (Int(parquet_bytes[n - 7]) << 8)
        | (Int(parquet_bytes[n - 6]) << 16)
        | (Int(parquet_bytes[n - 5]) << 24)
    )
    if footer_len <= 0 or footer_len + 8 > n:
        raise Error(
            "decode_compacted_parquet_bytes_pushdown: invalid footer length "
            + String(footer_len)
        )
    var metadata_offset = n - 8 - footer_len

    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    buf.copy_from_bytes_list(parquet_bytes^)
    buf.set_length(n)

    var meta = parse_full_metadata(
        buf.view_range_ro(metadata_offset, footer_len)
    )
    var num_rgs = len(meta.row_groups)
    if num_rgs == 0:
        _ = buf^
        return CompactedDecodeResult(
            batch=RecordBatch(), rgs_total=0, rgs_pruned=0, rgs_decoded=0
        )

    # Decode-time column projection with FILTER-BEFORE-PROJECT ordering (the
    # same contract as the live tier). The predicate may reference a column the
    # projection drops, so:
    #   * NO predicate  -> project AT DECODE (full column-chunk-skip win; only
    #                      the projected leaf columns are decoded).
    #   * WITH predicate -> decode ALL columns on the surviving RGs (so the
    #                      predicate column is present for the row filter), then
    #                      filter-before-project at the fold via
    #                      `_apply_consume_pushdown`. The dominant compacted-tier
    #                      win (row-group PRUNING) is unaffected — the pruner
    #                      already skipped non-matching RGs before any decode.
    var obj_schema = _schema_from_metadata(meta)
    var decode_proj: ColumnProjection
    if predicate:
        decode_proj = ColumnProjection.all()
    else:
        decode_proj = _projection_to_column_projection(obj_schema, projection)

    var batches = Slab[RecordBatch]()
    var rgs_pruned = 0
    var rgs_decoded = 0
    for rg_idx in range(num_rgs):
        var rg = meta.row_groups[rg_idx].copy()

        # Step 1 — zonemap PRUNE. Only when a predicate is present; the genuine
        # ParquetSource RG pruner (`can_prune_row_group`) consults this RG's
        # column-chunk min/max stats. Conservative-False on any ambiguity.
        if predicate:
            if can_prune_row_group(rg, meta, predicate.value()):
                rgs_pruned += 1
                continue

        # Step 2 — decode the surviving RG (projected columns when no predicate;
        # all columns when a predicate is present, see above).
        var rg_br = row_group_byte_range(rg)
        var rg_view = buf.view_range_ro(rg_br.start, rg_br.length())
        var batch = decode_row_group_from_bytes(
            rg_view,
            rg_br,
            rg,
            meta.schema,
            decode_proj,
        )
        batches.append(batch^)
        rgs_decoded += 1

    # Fold the surviving RG batches into one.
    var nb = len(batches)
    var folded: RecordBatch
    if nb == 0:
        folded = RecordBatch()
    elif nb == 1:
        folded = batches.take_slot_unchecked(0)^
        batches.set_len_unchecked(0)
        _ = batches^
    else:
        folded = _fold_record_batches(batches^)

    # Step 3 — apply the row predicate (CORRECTNESS — the pruner is conservative)
    # then the projection, in FILTER-BEFORE-PROJECT order via the SAME
    # `_apply_consume_pushdown` the live tier uses (byte-identical row set).
    #   * predicate present -> pass (predicate, projection): filter on the
    #     full-column decode, THEN project to the output subset.
    #   * no predicate      -> the projection was already applied at decode, so
    #     pass (None, None) (a no-op fold).
    var filter_pred: Optional[Expr] = None
    var filter_proj: Optional[List[String]] = None
    if predicate:
        filter_pred = predicate^
        filter_proj = projection^
    var result = _apply_consume_pushdown(folded^, filter_pred^, filter_proj^)

    # KEEPALIVE: anchor `buf` past the decode (see decode_compacted_parquet_bytes
    # — an empty `_ = buf` is not reliable; a real read is).
    var _anchor = buf.read_u8_at(n - 1)
    _ = _anchor
    _ = buf^
    return CompactedDecodeResult(
        batch=result^,
        rgs_total=num_rgs,
        rgs_pruned=rgs_pruned,
        rgs_decoded=rgs_decoded,
    )


# =============================================================================
# _schema_from_metadata — Arrow Schema from parsed Parquet FileMetaData.
# =============================================================================


def _schema_from_metadata(meta: FileMetaData) raises -> Schema:
    """Build the Arrow `Schema` from a parsed Parquet `FileMetaData` (the flat
    leaf-column set — schema[1..] are the leaves, schema[0] is the root group).
    Used to resolve a name-list projection to leaf indices. Reuses the decoder's
    `_field_from_schema_element` so the field types/nullability match the decode
    path exactly."""
    from komira_parquet.decode_helpers import (
        field_from_schema_element as _field_from_schema_element,
    )
    from komira_arrow.schema import SchemaBuilder

    var sb = SchemaBuilder()
    var n = len(meta.schema)
    for i in range(1, n):
        sb.add_field(_field_from_schema_element(meta.schema[i].copy()))
    return sb.build()


# =============================================================================
# DecodedTierBatch — one decoded batch + its tier + authoritative offsets.
# =============================================================================


@fieldwise_init
struct DecodedTierBatch(Movable, Deinitable):
    """One decoded RecordBatch from a dual-tier consume + its provenance.

    Field layout:
      var batch: RecordBatch    — the decoded rows.
      var is_compacted: Bool    — True iff from the compacted (Parquet) tier.
      var base_offset: Int64    — first absolute offset in this batch.
      var last_offset: Int64    — last absolute offset in this batch.
      var record_count: Int64   — records.
    """

    var batch: RecordBatch
    var is_compacted: Bool
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64


# =============================================================================
# DualTierConsumer[Storage] — the adapter-side dual-tier read driver.
# =============================================================================


struct DualTierConsumer[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """Reads `[start_offset, tail)` across BOTH tiers, decoding by tier, with
    read-repair on a reaped live segment.

    Ownership (by value):
      var _consume: ConsumeCore[Storage]       — live read + resolve_index.
      var _index: CompactionIndex[Storage]     — compacted lineage.
      var _object_store: Storage               — GETs compacted Parquet objects.
    """

    var _consume: ConsumeCore[Self.Storage]
    var _index: CompactionIndex[Self.Storage]
    var _object_store: Self.Storage

    def __init__(
        out self,
        var consume: ConsumeCore[Self.Storage],
        var index: CompactionIndex[Self.Storage],
        var object_store: Self.Storage,
    ):
        self._consume = consume^
        self._index = index^
        self._object_store = object_store^

    # NOTE: no generic `build(store, ...)` factory — `Storage:
    # ConditionalWriteStore` does not guarantee `.clone()`. The CALLER (holding a
    # concrete cloneable store) builds the ConsumeCore + CompactionIndex +
    # object store and passes them via `__init__`. Same discipline as
    # CompactionWorker / BrokerCore.

    def read_from(
        mut self, start_offset: Int64
    ) raises -> Slab[DecodedTierBatch]:
        """Read every batch covering `[start_offset, tail)` across both tiers,
        in OFFSET ORDER. Compacted refs decode Parquet; live refs decode
        Arrow-IPC. On a live-segment 404 (reaped underneath), READ-REPAIR:
        re-resolve and retry the failed offset from the (now-compacted) tier."""
        return self._read_from_impl(start_offset, allow_repair=True)

    def _read_from_impl(
        mut self, start_offset: Int64, allow_repair: Bool
    ) raises -> Slab[DecodedTierBatch]:
        var live_index = self._consume.resolve_index()
        var refs = dual_tier_resolve(self._index, live_index, start_offset)
        var out = Slab[DecodedTierBatch]()
        for i in range(len(refs)):
            ref r = refs[i]
            if r.is_compacted:
                out.append(self._read_compacted_ref(r))
            else:
                try:
                    out.append(self._read_live_ref(r))
                except e:
                    if allow_repair and _is_not_found_msg(String(e)):
                        # READ-REPAIR: the live segment was reaped after the
                        # compaction superseded it. Re-resolve from this ref's
                        # base; the range is now in the compacted tier. Single
                        # repair attempt (allow_repair=False) — a second 404 is
                        # a real error.
                        var repaired = self._read_from_impl(
                            r.base_offset, allow_repair=False
                        )
                        _splice_repaired(out, repaired^)
                        return out^
                    raise e^
        return out^

    def _read_compacted_ref(mut self, r: TierRef) raises -> DecodedTierBatch:
        var pbytes = self._object_store.get(Path.parse(r.object_key))
        var batch = decode_compacted_parquet_bytes(pbytes^)
        return DecodedTierBatch(
            batch=batch^,
            is_compacted=True,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
        )

    def _read_live_ref(mut self, r: TierRef) raises -> DecodedTierBatch:
        # Reuse ConsumeCore.read_segment by reconstructing a SegmentRef.
        var seg_ref = SegmentRef(
            chunk_seq=r.live_chunk_seq,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
            object_key=String(r.object_key),
            crc32=UInt32(0),  # not checked here; read_segment cross-checks count
        )
        var seg = self._consume.read_segment(seg_ref^)
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        return DecodedTierBatch(
            batch=batch^,
            is_compacted=False,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
        )

    # =========================================================================
    # read_from_pushdown: the cross-tier consume with pushdown.
    # =========================================================================

    def read_from_pushdown(
        mut self,
        start_offset: Int64,
        var predicate: Optional[Expr],
        var projection: Optional[List[String]],
    ) raises -> DualTierPushdownResult:
        """Read `[start_offset, tail)` across BOTH tiers WITH consume-side
        pushdown (the routing that applies the pushdown on both tiers).

        Per tier:
          * COMPACTED Parquet refs -> `decode_compacted_parquet_bytes_pushdown`:
            row-group zonemap PRUNING (`can_prune_row_group`) + column PROJECTION
            + the correctness row filter. The pruned-RG counts aggregate into
            the result's accounting (the capability-demo evidence).
          * LIVE Arrow-IPC refs -> decode then the SAME `_apply_consume_pushdown`
            (the live tier carries no zonemap, so it is decode-time filter +
            project only — byte-identical row set, no RG skip possible).

        Returns the ordered decoded batches across both tiers PLUS the aggregate
        row-group accounting (`rgs_total` / `rgs_pruned` / `rgs_decoded`) summed
        over every compacted object touched — so a caller can assert that a
        predicate pruned row groups on the compacted tier vs an unfiltered read.

        Read-repair is NOT re-implemented here (the pushdown path is the
        query-as-table consume; a live 404 mid-pushdown surfaces — the unfiltered
        `read_from` carries the repair logic for the streaming consume)."""
        var live_index = self._consume.resolve_index()
        var refs = dual_tier_resolve(self._index, live_index, start_offset)
        var out = Slab[DecodedTierBatch]()
        var rgs_total = 0
        var rgs_pruned = 0
        var rgs_decoded = 0
        for i in range(len(refs)):
            ref r = refs[i]
            var pred_i: Optional[Expr] = None
            if predicate:
                pred_i = predicate.value().copy()
            var proj_i: Optional[List[String]] = None
            if projection:
                proj_i = projection.value().copy()
            if r.is_compacted:
                var cr = self._read_compacted_ref_pushdown(
                    r, pred_i^, proj_i^
                )
                rgs_total += cr.rgs_total
                rgs_pruned += cr.rgs_pruned
                rgs_decoded += cr.rgs_decoded
                out.append(
                    DecodedTierBatch(
                        batch=cr^.take_batch(),
                        is_compacted=True,
                        base_offset=r.base_offset,
                        last_offset=r.last_offset,
                        record_count=r.record_count,
                    )
                )
            else:
                out.append(self._read_live_ref_pushdown(r, pred_i^, proj_i^))
        return DualTierPushdownResult(
            batches=out^,
            rgs_total=rgs_total,
            rgs_pruned=rgs_pruned,
            rgs_decoded=rgs_decoded,
        )

    def _read_compacted_ref_pushdown(
        mut self,
        r: TierRef,
        var predicate: Optional[Expr],
        var projection: Optional[List[String]],
    ) raises -> CompactedDecodeResult:
        """GET one compacted Parquet object + decode it with RG/column pushdown."""
        var pbytes = self._object_store.get(Path.parse(r.object_key))
        return decode_compacted_parquet_bytes_pushdown(
            pbytes^, predicate^, projection^
        )

    def _read_live_ref_pushdown(
        mut self,
        r: TierRef,
        var predicate: Optional[Expr],
        var projection: Optional[List[String]],
    ) raises -> DecodedTierBatch:
        """Read one live Arrow-IPC segment + apply the decode-time filter +
        projection (the live-tier contract: no zonemap, so filter-before-flow
        only)."""
        var seg_ref = SegmentRef(
            chunk_seq=r.live_chunk_seq,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
            object_key=String(r.object_key),
            crc32=UInt32(0),
        )
        var seg = self._consume.read_segment(seg_ref^)
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        var filtered = _apply_consume_pushdown(
            batch^, predicate^, projection^
        )
        return DecodedTierBatch(
            batch=filtered^,
            is_compacted=False,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
        )


# =============================================================================
# SubLineageDualTierConsumer[Store]: the dual-tier consume over the
# sub-lineage model (folded `_base` + serve-merged tail, alongside compacted).
# =============================================================================


struct SubLineageDualTierConsumer[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The dual-tier consume driver for a partition in sub-lineage mode.
    Reads `[start_offset, tail)` across BOTH tiers, where the LIVE tier is the
    sub-lineage model's CONTIGUOUS dense index — the folded `_base` prefix + the serve-merged un-folded tail
    (`SubLineageConsumeResolver.resolve_index`) — instead of the single-manifest
    `ConsumeCore.resolve_index`.

    This is the consume-side analogue of `DualTierConsumer`: it interleaves the
    compacted Parquet tier with the sub-lineage live tier via the SAME
    `dual_tier_resolve` (the sub-lineage dense index is fed AS the `live_index`),
    decodes by tier, and hands back ordered RecordBatches. The `_base` folded
    segments + the serve-merged tail segments are read as ordinary live `.seg`s
    (they ARE `.seg` objects, in `_base` / source sub-lineages respectively) — the
    `object_key` on each `SegmentRef` carries the full key, so `ConsumeCore.
    read_segment` reads them unchanged.

    The caller routes through this consumer only when the partition is in
    sub-lineage mode and `_base` exists; other partitions use `DualTierConsumer`
    and `ConsumeCore.resolve_index` unchanged. The resolver's `has_base()` is
    the gate.

    Ownership (by value):
      var _resolver: SubLineageConsumeResolver[Store] — the dense index source
                                  (folded `_base` + serve-merged tail).
      var _consume: ConsumeCore[Store]   — read_segment for both `_base` + tail
                                  segments (the `.seg` GET + footer-slice).
      var _index: CompactionIndex[Store] — the compacted lineage.
      var _object_store: Store           — GETs compacted Parquet objects.
    """

    var _resolver: SubLineageConsumeResolver[Self.Store]
    var _consume: ConsumeCore[Self.Store]
    var _index: CompactionIndex[Self.Store]
    var _object_store: Self.Store

    def __init__(
        out self,
        var resolver: SubLineageConsumeResolver[Self.Store],
        var consume: ConsumeCore[Self.Store],
        var index: CompactionIndex[Self.Store],
        var object_store: Self.Store,
    ):
        self._resolver = resolver^
        self._consume = consume^
        self._index = index^
        self._object_store = object_store^

    def has_base(self) raises -> Bool:
        """Whether the partition is in sub-lineage mode with a live `_base` (the
        gate for routing here vs the legacy `DualTierConsumer`)."""
        return self._resolver.has_base()

    def read_from(
        mut self, start_offset: Int64
    ) raises -> Slab[DecodedTierBatch]:
        """Read every batch covering `[start_offset, tail)` across both tiers in
        OFFSET ORDER, with the LIVE tier resolved by the sub-lineage dense index
        (folded `_base` + serve-merged tail). Compacted refs decode Parquet; live
        refs (folded `_base` segments + serve-tail segments) decode Arrow-IPC. On
        a live-segment 404 (reaped underneath), READ-REPAIR: re-resolve + retry the
        failed offset from the (now-compacted) tier."""
        return self._read_from_impl(start_offset, allow_repair=True)

    def _read_from_impl(
        mut self, start_offset: Int64, allow_repair: Bool
    ) raises -> Slab[DecodedTierBatch]:
        # The SUB-LINEAGE dense index (folded `_base` + serve-merged tail) is fed
        # AS the live_index to the SAME dual_tier_resolve — so the compacted tier
        # interleaves with the sub-lineage live tier exactly as for the single-
        # manifest case. The serve-merged tail's dense offsets are byte-identical
        # to what the fold persists, so an offset committed against this
        # index resolves to the SAME record after the tail folds into `_base`.
        var live_index = self._resolver.resolve_index()
        var refs = dual_tier_resolve(self._index, live_index, start_offset)
        var out = Slab[DecodedTierBatch]()
        for i in range(len(refs)):
            ref r = refs[i]
            if r.is_compacted:
                out.append(self._read_compacted_ref(r))
            else:
                try:
                    out.append(self._read_live_ref(r))
                except e:
                    if allow_repair and _is_not_found_msg(String(e)):
                        var repaired = self._read_from_impl(
                            r.base_offset, allow_repair=False
                        )
                        _splice_repaired(out, repaired^)
                        return out^
                    raise e^
        return out^

    def _read_compacted_ref(mut self, r: TierRef) raises -> DecodedTierBatch:
        var pbytes = self._object_store.get(Path.parse(r.object_key))
        var batch = decode_compacted_parquet_bytes(pbytes^)
        return DecodedTierBatch(
            batch=batch^,
            is_compacted=True,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
        )

    def _read_live_ref(mut self, r: TierRef) raises -> DecodedTierBatch:
        # A live ref here is a folded `_base` segment OR a serve-merged tail
        # segment — both are ordinary `.seg` objects whose full key is on the
        # TierRef. ConsumeCore.read_segment GETs the object + slices the footer.
        var seg_ref = SegmentRef(
            chunk_seq=r.live_chunk_seq,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
            object_key=String(r.object_key),
            crc32=UInt32(0),
        )
        var seg = self._consume.read_segment(seg_ref^)
        var batch = decode_arrow_ipc_stream(seg^.take_stream_bytes())
        return DecodedTierBatch(
            batch=batch^,
            is_compacted=False,
            base_offset=r.base_offset,
            last_offset=r.last_offset,
            record_count=r.record_count,
        )


# =============================================================================
# DualTierPushdownResult — cross-tier pushdown consume + aggregate RG accounting.
# =============================================================================


struct DualTierPushdownResult(Movable, Deinitable):
    """The result of a `DualTierConsumer.read_from_pushdown` — the ordered
    decoded (filtered + projected) batches across both tiers PLUS the aggregate
    row-group accounting summed over every compacted object touched.

    `rgs_pruned > 0` is the load-bearing capability-demo evidence (SCOPE item 4):
    the predicate skipped whole row groups on the compacted Parquet tier (the
    genuine zonemap pruning) vs an unfiltered read that decodes all of them.

    Field layout:
      var batches: Slab[DecodedTierBatch] — ordered cross-tier decoded batches.
      var rgs_total: Int   — total compacted row groups across all objects.
      var rgs_pruned: Int  — compacted row groups SKIPPED by the zonemap pruner.
      var rgs_decoded: Int — compacted row groups actually decoded.
    """

    var batches: Slab[DecodedTierBatch]
    var rgs_total: Int
    var rgs_pruned: Int
    var rgs_decoded: Int

    def __init__(
        out self,
        var batches: Slab[DecodedTierBatch],
        rgs_total: Int,
        rgs_pruned: Int,
        rgs_decoded: Int,
    ):
        self.batches = batches^
        self.rgs_total = rgs_total
        self.rgs_pruned = rgs_pruned
        self.rgs_decoded = rgs_decoded


# =============================================================================
# helpers
# =============================================================================


def _fold_record_batches(
    var batches: Slab[RecordBatch],
) raises -> RecordBatch:
    """Concatenate N RecordBatches sharing one schema into one (the rare
    multi-row-group compacted-object fold). The schema, including DECIMAL
    precision and scale, is taken from the first batch. An empty slab yields
    an empty batch."""
    if len(batches) == 0:
        return RecordBatch()
    return concat_record_batches_nway(batches^)


def _splice_repaired(
    mut out: Slab[DecodedTierBatch], var repaired: Slab[DecodedTierBatch]
):
    """Append the repaired suffix to the batches already read. A compacted
    object that now covers the failed segment can also cover segments read
    earlier from the live tier, so those earlier batches are dropped: each
    offset is delivered once."""
    if len(repaired) > 0:
        var cut = repaired[0].base_offset
        while len(out) > 0 and out[len(out) - 1].last_offset >= cut:
            _ = out.pop()
    out.extend(repaired^)


@always_inline
def _is_not_found_msg(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )
