# =============================================================================
# Streaming concat helpers — merge per-RG RecordBatches into one
# =============================================================================
#
# Two concat strategies:
# - _concat_rg_batches_into_one: fast O(N) memcpy for fixed-width columns
# - _concat_variable_width_batches: pairwise concat for string/dict columns
# =============================================================================

from std.math import max
from std.memory import alloc, unsafe_memcpy, unsafe_memset, UnsafePointer
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.arrow_types import (
    ARROW_LAYOUT_OFFSETS_I64,
    arrow_fixed_byte_width,
)
from komira_arrow.concat import _refuse_concat_layout_disagreement
from komira_arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    check_emittable_int32_offsets,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


def _concat_rg_batches_into_one[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
) raises -> RecordBatch:
    """Single-pass O(N) concat of per-RG RecordBatches.

    Preconditions:
    - `rg_batches[i]` is either None (empty RG) or Some(batch) where
      every batch has the same schema.
    - The destination slot `rg_batches[i]` is taken (moved out) during
      the concat; callers should treat this buffer as consumed.

    Strategy: compute total_rows + (per-column total_data_bytes for
    var-width) from the slot metadata, pre-allocate one output
    `MmapAlignedBuffer[64]` per column sized for the totals, then for
    each RG memcpy its columns into the destination slot at the
    current write offset. One memcpy per (RG, column) pair -- O(N),
    vs the legacy `_concat_columns` which is O(N^2) pairwise.

    Supports fixed-width numeric columns (INT32, INT64, FLOAT32,
    FLOAT64). Other types raise; `_concat_variable_width_batches` handles
    STRING and DICTIONARY.
    """
    # Find the first non-empty RG to source the schema from.
    var schema_rg_idx = -1
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            schema_rg_idx = i
            break
    if schema_rg_idx < 0:
        return RecordBatch()

    var num_cols = (rg_batches + schema_rg_idx)[].value().num_columns()

    # Stream AQ count-only fast path. When every per-RG batch is the
    # synthetic zero-column count batch (see
    # `RecordBatch.count_only`), we just sum `num_rows` across morsels
    # and return a single zero-column batch. This complements the
    # `_decode_with_late_mat` count-only hook used by CB-02 / CB-03.
    # Correctness: callers that see `num_columns() == 0` use num_rows
    # only (`_execute_agg_sink_no_keys` count-star fast path).
    if num_cols == 0:
        var total_rows_co = 0
        for i in range(num_rgs):
            if (rg_batches + i)[]:
                total_rows_co += (rg_batches + i)[].value().num_rows()
                # Drain the slot so the caller's subsequent `.free()`
                # does not destroy already-moved RecordBatch internals.
                # `_` receives the taken Optional and drops it at end of
                # statement; the inner RecordBatch has no owning
                # pointers, so drop is trivially cheap.
                var _taken = (rg_batches + i).take_pointee()
                _ = _taken^
        return RecordBatch.count_only(total_rows_co)

    # Per-column totals and type info.
    var total_rows = 0
    var col_types = List[ArrowType]()
    var col_widths = List[Int]()
    for c in range(num_cols):
        ref col_ref = (rg_batches + schema_rg_idx)[].value().column_at(c)
        col_types.append(col_ref.arrow_type)
        col_widths.append(_arrow_type_byte_width(col_ref.arrow_type))
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            total_rows += (rg_batches + i)[].value().num_rows()

    # Pre-allocate one destination buffer per column.
    # SAFETY: dst_bufs owns `num_cols` heap allocations. They're moved
    # into Column instances at the end and freed when those Columns die.
    var dst_bufs = alloc[OwnedAlignedBuffer](num_cols)
    for c in range(num_cols):
        var nbytes = max(total_rows * col_widths[c], 1)
        (dst_bufs + c).unsafe_write(OwnedAlignedBuffer(nbytes))

    # Walk each RG and memcpy its columns into the destination slots.
    var write_rows = 0
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        var rg_rows = (rg_batches + i)[].value().num_rows()
        for c in range(num_cols):
            var width = col_widths[c]
            if width == 0:
                raise Error(
                    "streaming_parquet: non-fixed-width column in "
                    "_concat_rg_batches_into_one (fixed-width columns only)"
                )
            ref src_col = (rg_batches + i)[].value().column_at(c)
            var src_bytes = rg_rows * width
            if src_bytes > 0:
                # Dest copy at non-zero
                # offset routes through MmapAlignedBuffer.copy_from_view_at
                # (offset-aware variant of copy_from_view). Pointer
                # arithmetic stays inside the primitive; this site no
                # longer touches MmapAlignedBuffer's raw pointer.
                var src_view = src_col._data.view_range_ro(
                    src_col._offset * width, src_bytes
                )
                (dst_bufs + c)[].copy_from_view_at(write_rows * width, src_view)
        write_rows += rg_rows

    # Build the schema and RecordBatch from the destination buffers.
    #
    # `field_at(c)` COPIES THE WHOLE Field, and the 3-argument
    # `Field(name, type, nullable)` rebuild this replaced did not. A Field also
    # carries the IANA timezone (TIMESTAMP_* — tz is NOT part of the ArrowType,
    # so `timestamp[us, tz=UTC]` and a naive `timestamp[us]` are the same
    # ArrowType) and the decimal (precision, scale). Reconstructing from three
    # arguments silently drops both, which turns a UTC-stamped column into a
    # naive one and a scale-2 decimal into a scale-0 integer. The sibling copy
    # of this loop (the engine runtime's parallel streaming concat, serial arm)
    # carries the same `field_at(c)` for the same reason.
    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field((rg_batches + schema_rg_idx)[].value().schema.field_at(c))
    var out_schema = sb.build()

    var builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var at = col_types[c]
        var buf = (dst_bufs + c).take_pointee()
        buf.set_length(Int64(total_rows * col_widths[c]))

        builder.add_column(Column[HeapRegion](
            arrow_type=at,
            data=buf^,
            offsets=None,
            validity=None,
            length=total_rows,
            null_count=0,
            offset=0,
        ))
    dst_bufs.free()

    return builder.build(out_schema^)


# =============================================================================
# _arrow_type_byte_width — DERIVED from the canonical table, not re-listed
# =============================================================================
#
# ⛔ NOT A HAND-WRITTEN LADDER. A ladder that answers for the INT/UINT/FLOAT
#    families and NOTHING ELSE sends DECIMAL128, DATE32, TIMESTAMP_*, DATE64,
#    TIME32_*, TIME64_*, DURATION_*, INTERVAL_* and DECIMAL256 onto
#    `return 0`. Its callers TEST for 0 — `_concat_fixed_columns_multi` raises
#    `unsupported type <T>` on it — so the engine could not read a decimal or
#    temporal column out of any parquet file with MORE THAN ONE ROW GROUP,
#    which is the normal case at any scale.
#
# ⛔ AND A HAND-WRITTEN FIX WOULD REOPEN IT AT THE NEXT TYPE. The byte width of
#    an ArrowType is a property OF the ArrowType, and there is ONE place that
#    states it: `arrow/arrow_types.arrow_fixed_byte_width`, which exists to
#    replace drifted copies of this ladder (each one a silent-wrong-width
#    hazard). So this delegates, and a type added to the Arrow type system is
#    answered here the moment it is answered there.
#
# WHY THE 0 SENTINEL SURVIVES THE DELEGATION. `arrow_fixed_byte_width` RAISES
# for layouts that have no per-element byte width (BOOL bit-packed, STRING /
# BINARY / LARGE_* offsets-carried, FIXED_SIZE_BINARY schema-carried,
# DICTIONARY, the nested and *_VIEW layouts). Every caller of THIS function
# branches on `width == 0` to route to the string / pair-wise / raise arms
# (`_concat_variable_width_batches`, `concat_record_batches_column_parallel`'s
# `any_untiled_type` gate, `_concat_rg_batches_into_one`), so the sentinel is
# the contract here and converting the raise back into it keeps every one of
# those branches meaning what it meant.
# =============================================================================


@always_inline
def _arrow_type_byte_width(at: ArrowType) -> Int:
    """Byte width for fixed-BYTE-width Arrow types; 0 for every other layout.

    DERIVED from `arrow/arrow_types.arrow_fixed_byte_width`, the single
    fixed-byte-width table in the tree. Do NOT re-enumerate types here.

    Args:
        at: The ArrowType to measure.

    Returns:
        Bytes per element, or 0 if `at` has no fixed per-element byte width
        (the sentinel this function's callers branch on).
    """
    try:
        return arrow_fixed_byte_width(at)
    except:
        # NO fixed per-element byte width. The canonical table names the type
        # in its Error; the callers here need the 0 sentinel, not the message.
        return 0


def _concat_variable_width_batches[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    *,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Concat per-RG batches that may include variable-width columns.

    Single-pass multi-way concat for STRING / BINARY and
    fixed-width numeric columns. For BOOL and DICTIONARY columns we
    still fall back to the pair-wise `_concat_columns` fold -- their
    layout (packed bits, per-RG private dicts requiring cross-RG remap)
    doesn't admit a trivial memcpy-per-batch strategy.

    ⚠ DICTIONARY columns ARE on the hot path -- see the gate below.

    Rationale
    ---------
    A pair-wise fold is O(N^2) over the accumulated payload
    bytes: each step reallocates an ever-growing output buffer and
    memcopies the running accumulator; on a sink combine it can be the
    single largest item. A single-pass multi-way concat visits
    each byte at most once: one pass over the staging slots to sum
    per-column totals, then one O(N_rows + N_bytes) copy pass.

    Args:
        rg_batches: The staging slots (consumed).
        num_rgs: Number of staging slots.
        offset_promote_at: Int32-offset trip point for the STRING/BINARY
            columns (see `offset_overflow.clamp_offset_promote_at`).
            Defaults to the production ceiling.
    """
    # Find the first non-empty batch to source the schema from.
    var schema_idx = -1
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            schema_idx = i
            break
    if schema_idx < 0:
        return RecordBatch()

    var num_cols = (rg_batches + schema_idx)[].value().num_columns()

    # Zero-column batches carry only a row count (`RecordBatch.count_only`,
    # or a batch of empty records): sum it under the first batch's schema.
    # The builder below cannot: with no column it has no length to read,
    # and would return 0 rows.
    if num_cols == 0:
        var schema = (rg_batches + schema_idx)[].value().schema.copy()
        var total_rows = 0
        for i in range(num_rgs):
            if (rg_batches + i)[]:
                total_rows += (rg_batches + i)[].value().num_rows()
                _ = (rg_batches + i)[].take()
        var out = RecordBatch.count_only(total_rows)
        out.schema = schema^
        return out^

    # Classify each column's type. If ANY column is BOOL or DICTIONARY, the
    # multi-way fast path cannot handle it -- fall back to the pair-wise fold
    # for the ENTIRE batch.
    #
    # ⛔ THIS IS NOT A RARE CASE. Common parquet writers emit a dictionary PER
    # ROW GROUP and preserve BYTE_ARRAY dictionaries by default, so such a
    # file trips this gate at column 0. The dictionary merge behind it is
    # O(Σ d) (see `arrow/dict_interner.mojo`).
    #
    # ★ ROUTED PER COLUMN. A WHOLE-BATCH gate would send every column of a
    # wide batch down the pair-wise fold because of ONE BOOL/DICTIONARY
    # column -- an N^2 memcpy of all the others. Each column picks its own
    # kernel, so a dictionary column costs the fold for ITSELF and the others
    # keep the single-pass multi-way path. There is no batch-level `any_slow`
    # property.
    #
    # ⚠ The BOOL/DICTIONARY arm MUST be tested before the STRING/BINARY arm
    # and before the fixed-width fallthrough. `_arrow_type_byte_width` reports
    # 0 for both, so the fallthrough would raise "unsupported type"; it does
    # not silently corrupt, but it does turn a working concat into an error.

    # Multi-way fast path. Build each output column in one allocation
    # + one pass across the staging slots.
    # `field_at(c)` — the WHOLE Field, including the TIMESTAMP timezone and the
    # decimal (precision, scale) that a 3-argument Field rebuild drops. See the
    # note in `_concat_rg_batches_into_one`.
    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field((rg_batches + schema_idx)[].value().schema.field_at(c))

    var builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var at = (rg_batches + schema_idx)[].value().column_at(c).arrow_type
        if at == ArrowType.BOOL or at == ArrowType.DICTIONARY:
            builder.add_column(
                _concat_slow_column_pairwise(rg_batches, num_rgs, c)
            )
        elif at == ArrowType.STRING or at == ArrowType.BINARY:
            builder.add_column(
                _concat_string_columns_multi(
                    rg_batches,
                    num_rgs,
                    c,
                    offset_promote_at=offset_promote_at,
                )
            )
        else:
            builder.add_column(_concat_fixed_columns_multi(rg_batches, num_rgs, c, at))

    # Consume staging slots: take() each populated batch so the sink's
    # `staging.free()` leaves no live Optional[RecordBatch] behind.
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            _ = (rg_batches + i)[].take()

    return builder.build(sb.build())


def _concat_string_columns_multi[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
    *,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> Column[HeapRegion]:
    """Single-pass multi-way concat for one STRING/BINARY column.

    Two scans: (1) sum total_rows + total_data_bytes; (2) allocate
    destination buffers and memcpy each source batch's payload slice
    at the running cursor while computing adjusted offsets into the
    destination offsets buffer.

    Handles source-level `_offset` (slicing): data_start is
    `src_off[offset]`, and the i-th source offset is
    `src_off[offset + i] - src_off[offset]`.

    Preserves validity bitmap by copying per-row bits at the destination
    row cursor (one logical pass). Null-count sums across batches.

    `offset_promote_at` is the Int32-offset trip point handed to
    `check_emittable_int32_offsets` (production ceiling by default).
    """
    comptime int32_size = size_of[Int32]()

    # Scan 1: totals.
    var total_rows = 0
    var total_bytes = 0
    var total_nulls = 0
    var any_validity = False
    var src_at = ArrowType.STRING
    # THE LAYOUT REFERENCE — input 0's type, i.e. the one the ROUTING sites
    # dispatched on. `src_at` below is the LAST batch's tag (pre-existing
    # behaviour, deliberately untouched); it cannot serve as the reference,
    # because a check against a value the loop is still overwriting compares
    # each batch only with its predecessor and lets a divergent tail through.
    var ref_at = ArrowType.STRING
    var have_ref = False
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        # ⛔ EVERY READ BELOW IS AT INT32 STRIDE — `src_off` is a hard
        # `bitcast[Scalar[DType.int32]]` — so a LARGE_STRING batch arriving
        # here is read at half its offset width: wrong values from its first
        # row on, an exactly-correct row count, and nothing raised. Offset
        # width became a PER-BATCH, data-dependent property at the Int32
        # promotion, so the routing sites' dispatch on ONE
        # batch's tag stopped being a proof about the others.
        if not have_ref:
            ref_at = col_ref.arrow_type
            have_ref = True
        else:
            _refuse_concat_layout_disagreement(
                "streaming concat(n-way, whole column)",
                i,
                ref_at,
                col_ref.arrow_type,
            )
        src_at = col_ref.arrow_type
        var rows = col_ref._length
        total_rows += rows
        if col_ref._validity:
            any_validity = True
        total_nulls += col_ref._null_count
        if rows > 0:
            var off = col_ref._offset
            # PERF-CRITICAL: origin-tied view-derived pointer, via
            # `view_ro()._unsafe_ptr().bitcast[Scalar[DType.int32]]()`.
            # Per-iteration view local bound from `Optional.value()` ref-chain;
            # released at iter end.
            var src_off_view = col_ref._offsets.value().view_ro()
            var src_off = src_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            var data_start = Int((src_off + off)[])
            var data_end = Int((src_off + off + rows)[])
            total_bytes += data_end - data_start

    # ⛔ THE INT32 OFFSET CEILING. `total_bytes` is summed in 64-bit `Int`
    # above and then narrowed per element by scan 2's `Int32(byte_cursor -
    # data_start)`. Past INT32_MAX that narrowing is a silent two's-complement
    # wrap: negative offsets, garbage `get_length`, and a row COUNT that stays
    # exactly right — the failure mode every row-count assertion passes.
    # Concat is the classic way to cross it, because each input batch
    # is comfortably legal on its own and only the SUM is not.
    #
    # Placed HERE, between the total and the allocation, for the two reasons
    # `offset_overflow.mojo` states: it is O(1) per column (guarding the
    # per-element narrowing instead would put a branch in the copy loop for no
    # extra coverage), and it fails BEFORE committing >2 GiB of RSS.
    #
    # RAISE, NOT PROMOTE — and the choice is not this kernel's to make
    # differently. `arrow/concat.mojo`'s pair-wise and n-way arms
    # both answer exactly this case (narrow inputs whose SUM crosses the
    # ceiling) with this same check; promotion is a GATHER-side capability
    # (`compiler_helpers._parallel_string_gather`), not a concat-side one.
    # Teaching the streaming spine to promote means a second, Int64 set of the
    # tiled fork's offset stores and its byte-identity proofs, and it would
    # make the output SCHEMA a function of the DATA at a site whose consumers
    # refuse exactly that divergence.
    check_emittable_int32_offsets(
        "streaming concat(n-way, whole column)",
        total_bytes,
        total_rows,
        promote_at=offset_promote_at,
    )

    # Pre-allocate output buffers.
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    data_buf.set_length(Int64(total_bytes))

    var off_bytes = (total_rows + 1) * int32_size
    var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
    off_buf.set_length(Int64(off_bytes))

    # PERF-CRITICAL: origin-tied view-derived pointer, via
    # `view_mut()._unsafe_ptr().bitcast[Scalar[DType.int32]]()`. Function-
    # scope `out_off_view` local; NLL releases the &mut borrow at last use
    # of `out_off` so trailing `off_buf^` consume at the
    # `Column(...)` return site compiles.
    var out_off_view = off_buf.view_mut()
    var out_off = out_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    # Optional destination validity bitmap -- only allocated if ANY
    # source batch carried a validity bitmap.
    var validity_opt: Optional[Bitmap[HeapRegion]] = None
    if any_validity:
        var bm = Bitmap.create(total_rows)
        # Initialize to all-valid; per-row bit writes below clear nulls.
        # Bitmap.create already zero-initializes; set every bit first.
        for i in range(total_rows):
            bm.set(i)
        validity_opt = bm^

    # Scan 2: memcpy payloads + write offsets + validity bits.
    var row_cursor = 0
    var byte_cursor = 0
    (out_off + 0)[] = Int32(0)
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        var rows = col_ref._length
        if rows == 0:
            continue
        var off = col_ref._offset
        # PERF-CRITICAL: origin-tied view-derived pointer; offset-walk in
        # tight loop. §2.6 BANNED `_typed_ptr_ro[DType.int32]()`
        # retired onto `view_ro()._unsafe_ptr().bitcast[Scalar[DType.int32]]()`.
        # Per-iteration view local bound from `Optional.value()` ref-chain.
        var src_off_view = col_ref._offsets.value().view_ro()
        var src_off = src_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var data_start = Int((src_off + off)[])
        var data_end = Int((src_off + off + rows)[])
        var data_len = data_end - data_start

        # Payload memcpy.
        if data_len > 0:
            # PERF-CRITICAL: bulk byte memcpy via view-based copy.
            # `view_range_mut(byte_cursor, data_len)` produces a sized
            # ByteView; `view_range_ro(data_start, data_len)` on src
            # likewise. Same memcpy under the hood; origin-tracked.
            data_buf.view_range_mut(byte_cursor, data_len).copy_from_view_at(
                0,
                col_ref._data.view_range_ro(data_start, data_len),
            )

        # Offset remap: out_off[row_cursor + 1 + j] = src_off[off + 1 + j]
        #                                            - data_start
        #                                            + byte_cursor
        var base = Int32(byte_cursor - data_start)
        for j in range(rows):
            (out_off + row_cursor + 1 + j)[] = (src_off + off + 1 + j)[] + base

        # Validity copy.
        if validity_opt:
            if col_ref._validity:
                ref src_bm = col_ref._validity.value()
                for j in range(rows):
                    if not src_bm.test(off + j):
                        validity_opt.value().clear(row_cursor + j)
            # else: all-valid, already set above.

        row_cursor += rows
        byte_cursor += data_len

    return Column[HeapRegion](
        arrow_type=src_at,
        data=data_buf^,
        offsets=off_buf^,
        validity=validity_opt^,
        length=total_rows,
        null_count=total_nulls,
        offset=0,
    )


# =============================================================================
# STRING/BINARY ROW-RANGE TILING
# =============================================================================
#
# ★ WHY VARIABLE-WIDTH COLUMNS ARE SPLITTABLE HERE. It is tempting to classify
# variable-width columns as UNSPLITTABLE because splitting them "would need a
# per-row byte-offset pre-pass". That is TRUE FOR A GATHER and FALSE FOR A
# CONCAT, and the difference is the whole lever:
#
#   * A GATHER's output row i comes from an arbitrary source row, so the
#     destination byte offset of row i depends on the lengths of the i-1 rows
#     before it — genuinely per-row, which is why `_parallel_string_gather`
#     runs a length wave and a serial scan between its two passes.
#   * A CONCAT's output is the input batches laid end to end. Batch i's whole
#     payload lands contiguously at a per-BATCH prefix sum, and every row inside
#     it keeps its source spacing. So a tile that owns OUTPUT rows [rs, re)
#     needs, per intersected batch, exactly THREE Int32 loads:
#         src_off[off]                    (the batch's own data start)
#         src_off[off + local_start]      (this tile's first row)
#         src_off[off + local_start+num]  (one past this tile's last row)
#     — O(tiles * batches), never O(rows).
#
# ★ AND BOTH PREFIX SUMS ARE ALREADY AT HAND.
# `_concat_string_columns_multi` scan 1 (above) already reads
# `src_off[off]` and `src_off[off+rows]` for every batch — the per-batch BYTE
# prefix — and discards everything but their sum; and the tiled driver already
# builds and shares `batch_row_offset`, the per-batch ROW prefix.
#
# ★ THIS IS A MOVE, NOT A DELETE: fanning a copy does not stop the copy, and
# where a concat's output is immediately re-morselized, deleting the pair beats
# fanning either half. That deletion needs a new (batch, row) addressing mode
# inside the multi-key join kernel — the most saturated fork of a wide join —
# with a wrong ANSWER as its failure mode, so tiling the concat is the cheaper
# and safer change. It does not foreclose the delete.
# =============================================================================


def _string_batch_byte_prefix[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
) raises -> List[Int]:
    """Per-batch DESTINATION BYTE prefix for STRING/BINARY column `col`.

    Returns `num_rgs + 1` entries: `prefix[i]` is the byte offset at which batch
    `i`'s payload starts in the concatenated data buffer, and `prefix[num_rgs]`
    is the column's total byte length. Empty (`None`) and zero-row slots
    contribute 0 and do not advance the cursor — the same accounting
    `_concat_string_columns_multi`'s `byte_cursor` performs, hoisted out of the
    copy loop so a row-range tile can start anywhere without replaying it.

    O(num_rgs). Reads exactly the two Int32 per batch that scan 1 of
    `_concat_string_columns_multi` already reads (`src_off[off]` and
    `src_off[off + rows]`) and currently throws away.
    """
    var prefix = List[Int](capacity=num_rgs + 1)
    var cursor = 0
    # THE TILED PATH'S LAYOUT CHECK LIVES HERE, folded into the walk it already
    # makes. `_concat_string_columns_multi`'s scan 1 carries the twin for the
    # whole-column path; the tiled driver never calls that function, so without
    # this a divergent LARGE_* batch would be read at Int32 stride by every
    # tile that intersects it — the same silent wrong answer, fanned out.
    #
    # ⚠ A ZERO-ROW BATCH IS CHECKED TOO, DELIBERATELY, AND IT IS THE ONE PLACE
    # THIS IS STRICTER THAN THE WRAP ITSELF REQUIRES. A zero-row batch
    # contributes no bytes, so reading it at the wrong stride harms nothing
    # here. It is checked anyway for two reasons: the whole-column twin already
    # lets a zero-row batch decide the OUTPUT TAG (`src_at` is assigned from
    # every non-None slot, zero-row included), so its layout is not in fact
    # irrelevant; and a producer emitting a zero-row batch whose offset width
    # disagrees with its siblings has an unstable output schema, which is the
    # defect, not an edge case to tolerate. `layouts_conflict` returns False for
    # an UNKNOWN layout class, so a default-constructed / NULL-tagged column —
    # the `Column` MOVE-defect signature — still passes through untouched.
    var ref_at = ArrowType.STRING
    var have_ref = False
    for i in range(num_rgs):
        prefix.append(cursor)
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        if not have_ref:
            ref_at = col_ref.arrow_type
            have_ref = True
        else:
            _refuse_concat_layout_disagreement(
                "streaming concat(n-way, row-range tiled)",
                i,
                ref_at,
                col_ref.arrow_type,
            )
        var rows = col_ref._length
        if rows == 0:
            continue
        var off = col_ref._offset
        # PERF-CRITICAL: origin-tied view-derived pointer (same shape as scan 1
        # of `_concat_string_columns_multi`). Per-iteration view local bound from
        # `Optional.value()`; released at iteration end.
        var src_off_view = col_ref._offsets.value().view_ro()
        var src_off = src_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        cursor += Int((src_off + off + rows)[]) - Int((src_off + off)[])
    prefix.append(cursor)
    return prefix^


def _concat_string_column_into_range[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
    imm batch_row_offset: List[Int],
    imm batch_byte_prefix: List[Int],
    row_start: Int,
    row_end: Int,
    mut dst_data: OwnedAlignedBuffer,
    mut dst_off: OwnedAlignedBuffer,
) raises:
    """Copy OUTPUT rows [row_start, row_end) of STRING/BINARY column `col`,
    across all input batches, into the pre-sized `dst_data` / `dst_off` buffers.

    The variable-width sibling of `_concat_fixed_column_into_range`, with the
    same batch loop, the same `[lo, hi)` intersect against the tile range and
    the same disjoint-destination contract. `dst_off[0]` is written by the
    DRIVER, never by a tile — it is the one output slot no row range owns.

    BYTE-IDENTICAL TO `_concat_string_columns_multi` BY CONSTRUCTION, because it
    is that function's scan-2 arithmetic restricted to a row window and nothing
    else:
        byte_cursor := batch_byte_prefix[i]      (was: the running cursor)
        row_cursor  := batch_row_offset[i]       (was: the running cursor)
        base        := Int32(byte_cursor - data_start)
        dst_off[row_cursor + 1 + j] = src_off[off + 1 + j] + base
    For the whole-column case (row_start=0, row_end=total_rows) every term
    reduces to the original's, including the Int32 wraparound of `base` — see
    the note below on the offset ceiling.

    ★ THE INT32 OFFSET CEILING IS CHECKED BY THE DRIVER, NOT HERE, AND THAT
    IS WHY THE BYTE-IDENTITY CLAIM ABOVE SURVIVES IT. This helper still
    performs no `check_int32_offsets` — deliberately: a tile runs inside the
    fork, where a raise is a per-worker error flag rather than a refusal, and
    a per-tile branch would be a hot-loop cost for no coverage the driver does
    not already have. What changed is that the wrap is no longer REACHABLE
    from here. Both drivers that call this helper now check the whole column's
    64-bit byte total against INT32_MAX before they size a destination buffer
    (`_concat_tiled`, off `_string_batch_byte_prefix`'s last entry), so a
    column that would wrap raises `ArrowOffsetOverflow` before the first tile
    is dispatched. The arithmetic in this function is untouched.

    ⚠ Do NOT "complete" this by adding the check here as well. The guard's
    whole contract (`offset_overflow.mojo`) is that it fires BEFORE the
    destination is allocated; by the time a tile runs, it has been.

    Disjointness (the parallelize contract): two tiles of the SAME column write
    (a) destination BYTE ranges that cannot overlap, because the tile row ranges
    partition [0, total_rows) and a row's byte extent is monotone in its row
    index within the concatenated layout; and (b) destination int32 offset slots
    [row_start+1, row_end], which likewise partition [1, total_rows]. Different
    columns write different buffers. Validity is NOT touched here — it is owned
    whole-column by the kind-2 work item, so no two threads share a bitmap byte.
    """
    # PERF-CRITICAL: origin-tied view-derived typed pointer over the SHARED
    # destination offsets buffer. Tiles write disjoint int32 slots of it (see
    # the disjointness note above), so the aliased `mut` is sound.
    var out_off_view = dst_off.view_mut()
    var out_off = out_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        var rows = col_ref._length
        if rows == 0:
            continue
        var b_out_start = batch_row_offset[i]
        var b_out_end = b_out_start + rows
        # Intersect the batch's output extent with the tile range.
        var lo = b_out_start if b_out_start > row_start else row_start
        var hi = b_out_end if b_out_end < row_end else row_end
        if lo >= hi:
            continue
        var local_start = lo - b_out_start  # source row within this batch
        var num = hi - lo
        var off = col_ref._offset

        var src_off_view = col_ref._offsets.value().view_ro()
        var src_off = src_off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        # `data_start` is the batch's own payload origin — honoured on EVERY
        # read, because a source batch may already be sliced (`_offset > 0`).
        var data_start = Int((src_off + off)[])
        var byte_cursor = batch_byte_prefix[i]

        # THE THREE INT32 LOADS. `data_start` above, plus this tile's own byte
        # window inside the batch. Everything else is per-batch metadata.
        var win_start = Int((src_off + off + local_start)[])
        var win_end = Int((src_off + off + local_start + num)[])
        var win_len = win_end - win_start
        if win_len > 0:
            # PERF-CRITICAL: bulk byte memcpy via view-based copy (same
            # primitive as the whole-column path). Disjoint dst slice.
            dst_data.view_range_mut(
                byte_cursor + win_start - data_start, win_len
            ).copy_from_view_at(
                0, col_ref._data.view_range_ro(win_start, win_len)
            )

        # Offset remap — the whole-column formula, restricted to [lo, hi).
        var base = Int32(byte_cursor - data_start)
        for j in range(num):
            (out_off + lo + 1 + j)[] = (
                src_off + off + local_start + 1 + j
            )[] + base


def _concat_fixed_column_into_range[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
    width: Int,
    imm batch_row_offset: List[Int],
    row_start: Int,
    row_end: Int,
    mut dst: OwnedAlignedBuffer,
) raises:
    """Copy OUTPUT rows [row_start, row_end) of fixed-width column `col`,
    across all input batches, into `dst` (a pre-sized destination buffer)
    at byte offset `row * width`. Read-only on the input batches; writes
    ONLY the disjoint destination byte slice [row_start*width, row_end*width).

    ROW-RANGE TILING PRIMITIVE.
    When the concat's column count is below the worker count, the
    column-parallel concat dispatch (one task per column) starves workers.
    A 2D (col, row_range) dispatch calls this helper once per tile so N
    workers share ONE column's copy. `batch_row_offset[i]` is the output
    row index of batch `i`'s first row (see `_fixed_batch_row_offsets`).
    Partial batches at a tile boundary are handled by intersecting each
    batch's output extent [b_out_start, b_out_end) with the tile range;
    for the whole-column case (row_start=0, row_end=total_rows) this is
    byte-identical to the legacy single-pass loop.

    Disjointness (the parallelize contract): two tiles of the SAME column
    write [row_start, row_end) byte slices that do not overlap (the tile
    ranges partition [0, total_rows)); different columns write different
    `dst` buffers. No cross-tile synchronization is needed because the
    destination is pre-sized (no realloc) and validity is resolved
    separately (serially, on the driver) — this helper touches ONLY the
    fixed-width value bytes.
    """
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        var rows = col_ref._length
        if rows == 0:
            continue
        var b_out_start = batch_row_offset[i]
        var b_out_end = b_out_start + rows
        # Intersect the batch's output extent with the tile range.
        var lo = b_out_start if b_out_start > row_start else row_start
        var hi = b_out_end if b_out_end < row_end else row_end
        if lo >= hi:
            continue
        var local_start = lo - b_out_start  # source row within this batch
        var num = hi - lo
        var off = col_ref._offset
        var src_bytes = num * width
        # PERF-CRITICAL: bulk fixed-width copy via view-based copy
        # (memcpy under the hood; origin-tracked). Disjoint dst slice.
        #
        # =====================================================================
        # ⛔ DO NOT FORCE `fast_copy_bytes[variant=VARIANT_UNROLLED]` HERE
        #    WITHOUT THE MEASUREMENT THAT DECIDES IT.
        # =====================================================================
        #
        # Single-threaded, `_copy_large_unrolled` LOSES to `rep movsb` at every
        # size in the 128 KiB..16 MiB band (see the `ERMS_MIN`/`ERMS_MAX`
        # block in `simd/fast_copy.mojo`), with glibc's own ERMS `memmove` as
        # an agreeing control.
        #
        # What that does NOT cover: every caller of THIS helper is the
        # opposite regime -- the driver-serial whole-column path and the
        # row-range tile inside `_concat_tiled`'s fork-join wave, which runs
        # after the streaming drivers have joined at the barrier, with every
        # worker in the wave running this same copy. N-way concurrent large
        # copies are a different regime.
        #
        # ⇒ THE ANSWER THERE IS UNKNOWN, NOT "FLIP IT", and both directions
        # are live. A `vmovdqu` loop's loads and stores are ordinary uops the
        # ROB reorders around, and it is not a compiler memory barrier
        # (`_copy_erms` carries `~{memory}`, necessarily). But `rep movsb`'s
        # no-RFO store path moves LESS DRAM traffic, which is worth MORE, not
        # less, as a many-worker copy wave approaches the socket roof. Do not
        # assume the concurrent case reverses the single-threaded one.
        #
        # ⚠ SCOPE: this is about the finalize concat, NOT about
        # `fast_copy_bytes` generally. Other >= 128 KiB callers
        # (`arrow/column.mojo` deep copies, `arrow/concat.mojo`) DO run
        # alongside unrelated work and the paragraph above does not cover them.
        dst.view_range_mut(lo * width, src_bytes).copy_from_view_at(
            0,
            col_ref._data.view_range_ro((off + local_start) * width, src_bytes),
        )


def _sum_fixed_null_count[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
) raises -> Int:
    """Sum the per-batch `_null_count` for fixed-width column `col` (the
    concatenated column's total null count — identical to the legacy
    single-pass accumulation)."""
    var total = 0
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            total += (rg_batches + i)[].value().column_at(col)._null_count
    return total


def _build_fixed_validity[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
    total_rows: Int,
    imm batch_row_offset: List[Int],
) raises -> Optional[Bitmap[HeapRegion]]:
    """Build the concatenated validity bitmap for fixed-width column `col`,
    or None if no source batch carried a validity bitmap.

    Extracted verbatim from the legacy `_concat_fixed_columns_multi`
    validity pass so the whole-column and row-range-tiled paths share ONE
    validity implementation (byte-identical by construction). `create_all_valid`
    (memset 0xFF) seeds the destination all-valid; each batch's bits overwrite
    its row range via `Bitmap.copy_bits_into` (byte-aligned fast path + correct
    bit-unaligned fallback). This runs SERIALLY on the driver after the tiled
    data copy joins — validity is a 1-bit/row buffer (8-64x smaller than the
    value payload) so it is not worth parallelizing, and keeping it serial
    sidesteps the bitmap boundary-byte cross-tile race.
    """
    var any_validity = False
    for i in range(num_rgs):
        if (rg_batches + i)[]:
            if (rg_batches + i)[].value().column_at(col)._validity:
                any_validity = True
                break
    if not any_validity:
        return None

    var validity = Bitmap.create_all_valid(total_rows)
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref col_ref = (rg_batches + i)[].value().column_at(col)
        var rows = col_ref._length
        if rows == 0:
            continue
        if col_ref._validity:
            Bitmap.copy_bits_into(
                validity,
                batch_row_offset[i],
                col_ref._validity.value(),
                col_ref._offset,
                rows,
            )
    return Optional[Bitmap[HeapRegion]](validity^)


def _concat_fixed_columns_multi[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
    at: ArrowType,
) raises -> Column[HeapRegion]:
    """Single-pass multi-way concat for one fixed-width numeric column.

    Mirrors the fast path in `_concat_rg_batches_into_one` but scoped
    to one column so it can coexist with string columns in the same
    output batch.

    Routes through the shared `_concat_fixed_column_into_range` (data) +
    `_build_fixed_validity` (validity) + `_sum_fixed_null_count` (null
    count) helpers so this whole-column path and the row-range-TILED
    concat driver (`concat_record_batches_column_parallel`) emit
    byte-identical output — the whole-column case is just the single tile
    [0, total_rows).
    """
    var width = _arrow_type_byte_width(at)
    if width == 0:
        # ⚠ NAME THE REAL CAUSE FOR THE WIDE OFFSETS-CARRIED TYPES. Every
        # routing site into this file sends a column here when it is neither
        # BOOL/DICTIONARY nor STRING/BINARY, so a uniformly-LARGE_STRING
        # column — the ordinary shape downstream of the Int32 promotion — would
        # land in the FIXED-WIDTH kernel and be reported as "unsupported type
        # large_string". That sends the reader looking for a
        # missing row in the fixed-byte-width table, which is not what is
        # missing: the type has no per-element width BY DESIGN, and what this
        # spine lacks is a 64-bit-offset varlen ARM.
        # `arrow/concat.mojo` has one; the
        # streaming spine does not. Refuse in the reader's own vocabulary.
        if at.physical_layout_class() == ARROW_LAYOUT_OFFSETS_I64:
            raise Error(
                String("ArrowStreamingConcatNoWideArm: ")
                + String(at)
                + String(
                    " carries 64-bit (Int64) offsets, and the streaming concat"
                    " spine emits 32-bit offsets only — its string kernels"
                    " read every offsets buffer through a hard"
                    " `bitcast[Scalar[DType.int32]]`. This is a MISSING ARM,"
                    " not a missing fixed-byte-width table row: an"
                    " offsets-carried type has no per-element byte width by"
                    " design. The pair-wise and n-way kernels in"
                    " `komira_arrow/concat.mojo` do have wide arms;"
                    " route through those, or keep the column"
                    " narrow until the streaming spine grows one."
                )
            )
        raise Error(
            "_concat_fixed_columns_multi: unsupported type " + String(at)
        )

    # Prefix-sum of per-batch OUTPUT row offsets (None / zero-row batches
    # contribute 0). `batch_row_offset[i]` is the output row index of batch
    # `i`'s first row — the row→batch map shared with the row-range tiled
    # concat so the two paths are byte-identical.
    var batch_row_offset = List[Int](capacity=num_rgs)
    var total_rows = 0
    var schema_col_batch = -1
    for i in range(num_rgs):
        batch_row_offset.append(total_rows)
        if (rg_batches + i)[]:
            if schema_col_batch < 0:
                schema_col_batch = i
            total_rows += (rg_batches + i)[].value().column_at(col)._length
    # `schema_col_batch < 0` means EVERY slot is empty; there is then no source
    # column to carry per-column metadata from, and the output is a zero-row
    # column. The carry below is skipped in that case rather than indexing a
    # None slot.

    var nbytes = max(total_rows * width, 1)
    var data_buf = OwnedAlignedBuffer(nbytes)
    data_buf.set_length(Int64(total_rows * width))

    _concat_fixed_column_into_range(
        rg_batches, num_rgs, col, width, batch_row_offset, 0, total_rows, data_buf
    )

    var validity_opt = _build_fixed_validity(
        rg_batches, num_rgs, col, total_rows, batch_row_offset
    )
    var total_nulls = _sum_fixed_null_count(rg_batches, num_rgs, col)

    var out = Column[HeapRegion](
        arrow_type=at,
        data=data_buf^,
        offsets=None,
        validity=validity_opt^,
        length=total_rows,
        null_count=total_nulls,
        offset=0,
    )
    # DECIMAL (p, s) IS PER-COLUMN, NOT PART OF THE ArrowType — carry it.
    #
    # This was unreachable while the width ladder refused DECIMAL128, and it is
    # the SILENT half of P0-4: with the width fixed and this line missing, a
    # multi-row-group decimal column concatenates its 16-byte cells perfectly
    # and comes back with scale 0, so `312.50` reads as `31250`. No raise, no
    # warning, wrong number. The pair-wise fold has long carried these two
    # fields (`arrow/concat._concat_columns`, "Propagate decimal
    # precision/scale metadata"); this path did not, because it could not yet
    # be reached with a decimal.
    #
    # (p, s) is the COMPLETE set of per-column metadata a fixed-BYTE-width
    # column can carry: `_dict_*` belongs to DICTIONARY, `_children` /
    # `_field_names` / `_type_ids` to the nested and union layouts, and
    # `_inner_size` to FIXED_SIZE_BINARY / FIXED_SIZE_LIST — and every one of
    # those types has NO fixed per-element byte width, so it cannot arrive
    # here. That is derived from the same table the width comes from, not from
    # inspecting today's callers.
    if schema_col_batch >= 0:
        ref src0 = (rg_batches + schema_col_batch)[].value().column_at(col)
        out._decimal_p = src0._decimal_p
        out._decimal_s = src0._decimal_s
    return out^


def _concat_variable_width_batches_pairwise[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
) raises -> RecordBatch:
    """Legacy pair-wise fold -- retained for BOOL / DICTIONARY columns
    that the multi-way fast path does not yet handle."""
    var result = RecordBatch()
    var first = True
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        var taken = (rg_batches + i)[].take()
        if first:
            result = taken^
            first = False
        else:
            result = _concat_two_batches(result^, taken^)
    return result^


def _concat_slow_column_pairwise[o: Origin[mut=True]](
    rg_batches: UnsafePointer[Optional[RecordBatch], o],
    num_rgs: Int,
    col: Int,
) raises -> Column[HeapRegion]:
    """Pair-wise fold of ONE column across the staging slots.

    The per-COLUMN counterpart of `_concat_variable_width_batches_pairwise`,
    which folds whole BATCHES. Covers exactly the two layouts the multi-way
    kernels cannot memcpy: BOOL (bit-packed, so a byte-stride copy is wrong)
    and DICTIONARY (per-batch private dictionaries needing a cross-batch
    remap). Every other type must go to the multi-way kernels.

    ⚠ READS, NEVER CONSUMES. The whole-batch fold `take()`s each slot as it
    folds, which is safe only because it owns every column. Here the other
    columns still have to be read after this returns, so the accumulator is
    seeded with a `deep_copy()` and the slots are left populated for the
    caller to drain once, after all columns are built.

    Byte-equivalence with the whole-batch fold: the accumulator visits the
    same populated slots in the same ascending order and calls the same
    `_concat_columns` kernel, so the emitted bytes match the fold this
    replaces for these columns. None slots are skipped (not merged) by both;
    populated zero-row batches are folded by both.

    Args:
        rg_batches: Staging slots, `num_rgs` wide.
        num_rgs: Number of staging slots.
        col: Column index to fold.

    Returns:
        The concatenated column, or an empty Column if every slot is None.

    Raises:
        Error: if `_concat_columns` rejects the pair (e.g. a nested type).
    """
    from komira_arrow.concat import _concat_columns

    var acc = Column[HeapRegion]()
    var seeded = False
    for i in range(num_rgs):
        if not (rg_batches + i)[]:
            continue
        ref src = (rg_batches + i)[].value().column_at(col)
        if not seeded:
            acc = src.deep_copy()
            seeded = True
        else:
            var merged = _concat_columns(acc, src)
            acc = merged^
    return acc^


def _concat_two_batches(
    var left: RecordBatch,
    var right: RecordBatch,
) raises -> RecordBatch:
    """Pair-wise concat of two owned RecordBatches via `_concat_columns`.

    Both inputs are consumed. Used as the slow-path fallback for
    variable-width column concat (STRING / BINARY / DICTIONARY).
    """
    from komira_arrow.concat import _concat_columns
    var num_cols = left.num_columns()
    var builder = RecordBatchBuilder.with_capacity(num_cols)
    var sb = SchemaBuilder()
    for c in range(num_cols):
        # `field_at(c)` — the WHOLE Field (timezone + decimal p/s included).
        # This is the BOOL / DICTIONARY fallback arm, so a file that mixes a
        # bool column with a tz-stamped timestamp routes its ENTIRE batch
        # through here; the 3-argument rebuild dropped the tz for every column
        # in it. See the note in `_concat_rg_batches_into_one`.
        sb.add_field(left.schema.field_at(c))
        ref a_ref = left.column_at(c)
        ref b_ref = right.column_at(c)
        var merged = _concat_columns(a_ref, b_ref)
        builder.add_column(merged^)
    _ = left^
    _ = right^
    return builder.build(sb.build())
