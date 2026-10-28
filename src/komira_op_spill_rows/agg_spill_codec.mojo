# =============================================================================
# agg_spill_codec -- the THSPILL2 write and read of a hash-aggregate table's
# packed group rows, and the shell tables a restore rebuilds from them
# =============================================================================
#
# A `RowHashAggTable` spills as its packed group-row image
# (`RowHashAggTable.spill_group_rows_sab`): every group's key cells followed by
# its aggregate-state cells, one fixed-stride row per group, and for a table
# with variable-width (string) keys an 8-byte group count header and the string
# heap the key descriptors point into. The image is wrapped in a
# `NativeRowBlock` and written as one THSPILL2 chunk.
#
# A restore reads the chunk back and rebuilds a SHELL table
# (`RowHashAggTable.from_spilled_group_rows`): the group rows verbatim, the
# aggregate registration and the variable-width key declaration copied from
# the live table, and an empty directory. A shell is only ever the argument of
# `RowHashAggTable.combine` (which re-hashes each of its rows) or the source of
# a hash repartition, so it needs no directory.
#
# The functions here touch only bytes, the storage and the table's public
# spill seam; the decisions (when to spill, fold or repartition) are
# `agg_spill.RowHashAggSpillState`'s.
# =============================================================================

from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_async.runtime.spill_prefetch import SpillPrefetcher

from komira_row_format.row_block import RowHashAggTable

from komira_engine_runtime.spill.fnv1a import fnv1a_64_partition_fingerprint
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_engine_runtime.spill.native_spill import NativeRowBlock
from komira_engine_runtime.spill.spill_storage import ChunkId
from komira_engine_runtime.spill.thspill2 import (
    THSpill2Decoder,
    THSpill2Encoder,
)


def agg_layout_fingerprint(table: RowHashAggTable) -> UInt64:
    """The schema fingerprint a spilled run of `table` carries: FNV-1a-64 over
    the fixed row stride and the aggregate op tags (the fold `NativeRowBlock`'s
    aggregate path uses). Every run of one aggregate shares it."""
    var tags = List[UInt8]()
    for a in range(table.n_aggs()):
        tags.append(table.agg_op_tags[a])
    return fnv1a_64_partition_fingerprint(table.rows.fixed_row_stride, tags)


def encode_group_rows_to_storage(
    mut storage: LocalDiskSpillStorage,
    var image: SharedAlignedBuffer[HeapRegion],
    n_groups: Int,
    has_var_keys: Bool,
    fingerprint: UInt64,
) raises -> ChunkId:
    """Write one packed group-row image as a THSPILL2 chunk on `storage` and
    return the chunk's id. `storage.sync()` runs before returning, so the
    caller may free the in-memory run afterwards.

    `NativeRowBlock` is a fixed-stride body: its row count must divide the
    body length. An all-fixed-width image is `n_groups` whole rows, so it
    carries `n_groups`. An image with variable-width keys is the 8-byte group
    count header, the rows and the string heap, which is no whole number of
    rows, so it is written as ONE opaque row; the group count is the caller's
    (it is passed to `restore_shell_from_chunk`)."""
    var rows = Int64(1) if has_var_keys else Int64(n_groups)
    var block = NativeRowBlock(image^, rows, fingerprint)
    var cid = THSpill2Encoder[NativeRowBlock].encode(storage, block^)
    storage.sync()
    return cid


def decode_group_rows_from_storage(
    mut storage: LocalDiskSpillStorage, chunk_id: ChunkId
) raises -> NativeRowBlock:
    """Read one spilled group-row image back (a copy, independent of the
    chunk file)."""
    return THSpill2Decoder[NativeRowBlock].decode_copy(storage, chunk_id)


# =============================================================================
# Shell tables
# =============================================================================


struct AggRegistration(Copyable, Movable):
    """What a shell table copies from the live table so its rows mean the same
    thing: the key stride, the fixed row stride, the aggregate op tags and
    state offsets, and the offsets of the variable-width key cells (empty for
    an all-fixed-width key)."""

    var key_stride: Int
    var fixed_stride: Int
    var agg_tags: List[UInt8]
    var agg_offsets: List[Int]
    var var_key_offsets: List[Int]
    var fingerprint: UInt64
    """`agg_layout_fingerprint` of the live table: every chunk restored under
    this registration must carry it."""

    def __init__(out self, table: RowHashAggTable):
        self.fingerprint = agg_layout_fingerprint(table)
        self.key_stride = table.key_stride
        self.fixed_stride = table.rows.fixed_row_stride
        self.agg_tags = List[UInt8]()
        self.agg_offsets = List[Int]()
        for a in range(table.n_aggs()):
            self.agg_tags.append(table.agg_op_tags[a])
            self.agg_offsets.append(table.agg_col_offsets[a])
        self.var_key_offsets = List[Int]()
        for i in range(len(table.var_key_offsets)):
            self.var_key_offsets.append(table.var_key_offsets[i])

    def has_var_keys(self) -> Bool:
        return len(self.var_key_offsets) > 0


def shell_from_image(
    var image: SharedAlignedBuffer[HeapRegion], reg: AggRegistration
) raises -> RowHashAggTable:
    """Rebuild a shell table from a packed group-row image held in memory (a
    snapshot or a repartitioned fragment).

    The group count comes from `RowHashAggTable.image_group_count`, which
    tells the two image shapes apart: `len / fixed_stride` for a fixed-width
    key, the 8-byte header for a variable-width key (whose image also holds the
    string heap, which a division would count as rows)."""
    var view = image.view_ro()
    var n_groups = RowHashAggTable.image_group_count(
        view, reg.fixed_stride, reg.has_var_keys()
    )
    var shell = RowHashAggTable.from_spilled_group_rows(
        view,
        n_groups,
        reg.key_stride,
        reg.fixed_stride,
        reg.agg_tags,
        reg.agg_offsets,
        reg.var_key_offsets.copy(),
    )
    _ = image^
    return shell^


def restore_shell_from_chunk(
    mut storage: LocalDiskSpillStorage,
    chunk_id: ChunkId,
    n_groups: Int,
    reg: AggRegistration,
) raises -> RowHashAggTable:
    """Read a spilled run and rebuild its shell table. The run carries the
    live table's variable-width key declaration, so `combine` hashes a string
    key's bytes rather than its heap descriptor.

    Raises if the chunk's layout fingerprint (fixed row stride and aggregate
    op tags) is not `reg.fingerprint`: a run written under another layout
    would otherwise be read as rows of this one. The THSPILL2 body carries no
    checksum, so a corrupted body that keeps its length is not detected."""
    var block = decode_group_rows_from_storage(storage, chunk_id)
    if block.schema_fingerprint() != reg.fingerprint:
        raise Error(
            "spilled aggregate run was written under a different layout: chunk"
            " fingerprint "
            + String(block.schema_fingerprint())
            + ", expected "
            + String(reg.fingerprint)
            + " (row stride and aggregate ops)"
        )
    return RowHashAggTable.from_spilled_group_rows(
        block.byte_view(),
        n_groups,
        reg.key_stride,
        reg.fixed_stride,
        reg.agg_tags,
        reg.agg_offsets,
        reg.var_key_offsets.copy(),
    )


def prefetch_run(
    mut prefetcher: SpillPrefetcher,
    storage: LocalDiskSpillStorage,
    chunk_ids: List[ChunkId],
    run_index: Int,
):
    """Ask the IO lane to read run `run_index`'s chunk file into the page cache
    while the caller folds the previous run. Does nothing when the prefetcher
    has no IO lane or `run_index` is past the last run. Best effort: a dropped
    post or a missing file costs only the warm read, never correctness (the
    fold's own read covers it)."""
    if not prefetcher.is_active():
        return
    if run_index < 0 or run_index >= len(chunk_ids):
        return
    var cid = chunk_ids[run_index]
    var path = storage.chunk_prefetch_path(cid)
    var n = Int(storage.chunk_recorded_length(cid))
    _ = prefetcher.prefetch_chunk(path, n)
