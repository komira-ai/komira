# =============================================================================
# RowOutput — row-native write-path carrier + shared row->RecordBatch bridge.
# =============================================================================
#
# Without a row-native write path the row-streaming pipeline bridges its
# surviving RowBlocks to a columnar `RecordBatch` at finalize (the row-streaming
# finalize bridge), then a row-text sink (CSV / JSONL) re-walks the columns back into
# per-row text — a row->col->row-text round-trip where the columnar form is a
# throwaway intermediary. The row-native write path lets a text sink consume the
# RowBlocks DIRECTLY, skipping the bridge.
#
# `RowOutput` is the value-typed carrier handed to `Sink.accept_row_blocks`. It
# bundles:
#   * `blocks`  — the surviving rows, one or more `RowBlock`s (owned by `^`).
#   * `layout`  — `RowOutputLayout`: per-output-column (offset, dtype_tag) +
#                 validity offset/flag — exactly the metadata
#                 `_bridge_to_record_batch` reads off `_out_layout`. It is a
#                 standalone value (no `RowLayout` dependency in the public sig)
#                 so the trait surface stays a self-contained
#                 `komira_core`-reachable carrier.
#   * `schema`  — the output Arrow schema (column names + types).
#
# `bridge_row_output_to_record_batch` is the SHARED bridge — it is BYTE-IDENTICAL
# to the row-streaming finalize bridge (same `read_fixed[DT]` /
# `read_var_string_at` reads, same `_attach_validity` data-driven bitmap, same
# fast fixed subset). The `Sink.accept_row_blocks` DEFAULT impl calls it then
# delegates to `accept_batch`, so every existing (columnar / binary / in-memory)
# sink inherits a no-op-equivalent path and is UNAFFECTED; only the row-text
# sinks override `accept_row_blocks` to serialize rows directly.
#
# Encapsulation: zero `UnsafePointer` in any public signature; zero wildcard
# origin; zero `unsafe_from_address`. The carrier owns its `Slab[RowBlock]` by
# value and is moved by `^` across the package boundary.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import Schema
from komira_core.arrow.string_builder import ArrowStringBuilder
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.collections.slab import Slab

from komira_eval.row_format.row_block import (
    RowBlock,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_STRING,
)


struct RowOutputLayout(Movable, Copyable, Deinitable):
    """Per-output-column cell-access metadata for a `RowOutput`.

    Mirrors the subset of `RowLayout` the finalize bridge reads
    (`_out_layout.key_descriptors[c].offset_in_row` / `.dtype_tag` +
    `has_validity` / `validity_offset`). Held by value (Lists of Copyable
    scalars) so `RowOutput` carries no `RowLayout` dependency in the public
    trait surface.

    Fields:
        offsets:         byte offset of each output column within an output row.
        dtype_tags:      `DT_*` tag of each output column (fast fixed subset +
                         DT_STRING).
        validity_offset: byte offset of the per-row validity bitmap (valid only
                         when `has_validity`).
        has_validity:    True iff the output rows carry a validity bitmap
                         (internal convention bit=1 == NULL).
    """

    var offsets: List[Int]
    var dtype_tags: List[UInt8]
    var validity_offset: Int
    var has_validity: Bool

    def __init__(
        out self,
        var offsets: List[Int],
        var dtype_tags: List[UInt8],
        validity_offset: Int,
        has_validity: Bool,
    ):
        self.offsets = offsets^
        self.dtype_tags = dtype_tags^
        self.validity_offset = validity_offset
        self.has_validity = has_validity

    @always_inline
    def n_cols(self) -> Int:
        return len(self.offsets)


struct RowOutput(Movable, Deinitable):
    """Row-native write-path carrier: surviving RowBlocks + their output layout
    + output schema.

    Handed to `Sink.accept_row_blocks(var ro: RowOutput)` by `ctx.run`'s
    text-sink + row-eligible branch. Owns its `Slab[RowBlock]` by value
    (RowBlock is Movable-not-Copyable; the carrier is moved by `^`, never
    copied).
    """

    var blocks: Slab[RowBlock]
    var layout: RowOutputLayout
    var schema: Schema

    def __init__(
        out self,
        var blocks: Slab[RowBlock],
        var layout: RowOutputLayout,
        var schema: Schema,
    ):
        self.blocks = blocks^
        self.layout = layout^
        self.schema = schema^

    def total_rows(self) -> Int:
        """Sum of `n_rows` across every block."""
        var n = 0
        for i in range(len(self.blocks)):
            n += self.blocks[i].n_rows
        return n


def _attach_validity[
    DT: DType
](
    mut arr: PrimitiveArray[DT],
    imm ro: RowOutput,
    col_idx: Int,
    n_rows_total: Int,
    has_validity: Bool,
    validity_offset: Int,
) raises:
    """Attach a validity bitmap to `arr` for output column `col_idx`, mirroring
    the row-streaming finalize bridge's validity attach BYTE-IDENTICALLY: build the bitmap
    ONLY IF at least one null is observed (the all-valid case keeps
    `validity = None`). The block's internal convention is bit=1 == NULL, so a
    null position CLEARS the Arrow bit (Arrow: bit=1 == valid).

    Walks every block, accumulating null row positions with a running row base
    so multi-block accumulators are handled correctly (the
    `accumulate_to_rows` path produces a single block; the loop generalizes)."""
    if not has_validity:
        return
    var null_positions = List[Int]()
    var row_base = 0
    for bi in range(len(ro.blocks)):
        ref blk = ro.blocks[bi]
        for r in range(blk.n_rows):
            if blk.is_cell_null(r, validity_offset, col_idx):
                null_positions.append(row_base + r)
        row_base += blk.n_rows
    if len(null_positions) > 0:
        var bm = Bitmap.create_all_valid(n_rows_total)
        for k in range(len(null_positions)):
            bm.clear(null_positions[k])
        arr.validity = Optional[Bitmap[HeapRegion]](bm^)
        arr.null_count = len(null_positions)


def bridge_row_output_to_record_batch(
    var ro: RowOutput,
) raises -> RecordBatch:
    """Drain a `RowOutput`'s RowBlocks column-by-column into a `RecordBatch`
    over `ro.schema` — the SHARED finalize bridge.

    BYTE-IDENTICAL to the row-streaming finalize bridge (same
    `read_fixed[DT]` / `read_var_string_at` reads, same data-driven validity).
    The `Sink.accept_row_blocks` DEFAULT impl calls this so columnar / binary /
    in-memory sinks inherit the existing bridge behavior unchanged.

    The accumulator is logically a SINGLE RowBlock for the row-streaming
    `accumulate_to_rows` path (one block); the loop concatenates across blocks
    in producer order for generality.
    """
    ref layout = ro.layout
    var n_cols = layout.n_cols()
    var has_validity = layout.has_validity
    var vo = layout.validity_offset
    var n_rows = ro.total_rows()
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for c in range(n_cols):
        var off = layout.offsets[c]
        var dt = layout.dtype_tags[c]
        if dt == DT_I64:
            var vals = List[Scalar[DType.int64]](capacity=n_rows)
            for bi in range(len(ro.blocks)):
                ref blk = ro.blocks[bi]
                for r in range(blk.n_rows):
                    vals.append(blk.read_fixed[DType.int64](r, off))
            var arr = PrimitiveArray[DType.int64].from_list(vals)
            _attach_validity(arr, ro, c, n_rows, has_validity, vo)
            rbb.add_column(Column.from_primitive[DType.int64](arr^))
        elif dt == DT_I32:
            var vals = List[Scalar[DType.int32]](capacity=n_rows)
            for bi in range(len(ro.blocks)):
                ref blk = ro.blocks[bi]
                for r in range(blk.n_rows):
                    vals.append(blk.read_fixed[DType.int32](r, off))
            var arr = PrimitiveArray[DType.int32].from_list(vals)
            _attach_validity(arr, ro, c, n_rows, has_validity, vo)
            rbb.add_column(Column.from_primitive[DType.int32](arr^))
        elif dt == DT_F64:
            var vals = List[Scalar[DType.float64]](capacity=n_rows)
            for bi in range(len(ro.blocks)):
                ref blk = ro.blocks[bi]
                for r in range(blk.n_rows):
                    vals.append(blk.read_fixed[DType.float64](r, off))
            var arr = PrimitiveArray[DType.float64].from_list(vals)
            _attach_validity(arr, ro, c, n_rows, has_validity, vo)
            rbb.add_column(Column.from_primitive[DType.float64](arr^))
        elif dt == DT_F32:
            var vals = List[Scalar[DType.float32]](capacity=n_rows)
            for bi in range(len(ro.blocks)):
                ref blk = ro.blocks[bi]
                for r in range(blk.n_rows):
                    vals.append(blk.read_fixed[DType.float32](r, off))
            var arr = PrimitiveArray[DType.float32].from_list(vals)
            _attach_validity(arr, ro, c, n_rows, has_validity, vo)
            rbb.add_column(Column.from_primitive[DType.float32](arr^))
        elif dt == DT_STRING:
            # Read the cell as a BORROWED span
            # (`var_string_span_at`) instead of an owned `List[UInt8]`. The
            # bytes are memcpied into `sb` on the very next line, so the owned
            # copy was one heap allocation per CELL — ~126M of them on a 6M-row
            # x 21-col all-VARCHAR passthrough, for zero benefit.
            var sb = ArrowStringBuilder()
            for bi in range(len(ro.blocks)):
                ref blk = ro.blocks[bi]
                for r in range(blk.n_rows):
                    if has_validity and blk.is_cell_null(r, vo, c):
                        sb.push_null()
                    else:
                        sb.push_bytes(blk.var_string_span_at(r, off))
            rbb.add_column(sb^.build())
        else:
            raise Error(
                "RowOutput bridge: output DType tag "
                + String(Int(dt))
                + " outside the row-streaming supported subset."
            )
    var sch = ro.schema.copy()
    return rbb.build(sch^)
