# =============================================================================
# Column / batch concatenation helpers — pure Arrow operations
# =============================================================================
#
# Arrow column operations with no parquet dependencies. Used by:
# - arrow_helpers/streaming_concat.mojo (pair-wise variable-width batch concat)
# - test helpers that materialize a full file to a RecordBatch
#
# SAFETY: — public surface is now `ref [o] Column` parameters.
# The column ownership lives inside a RecordBatch slot held by the caller;
# the typed origin lets the compiler track liveness through the call. No
# wildcard pointers cross the module boundary.
# =============================================================================

# =============================================================================
# WILDCARD-ORIGIN SITES: pending migration
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# Do NOT add new wildcard sites to this file.
# =============================================================================

from std.sys import size_of, simd_width_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from komira_arrow.column import Column
from komira_arrow.arrow_types import arrow_fixed_byte_width, layouts_conflict
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.offset_overflow import ARROW_INT64_OFFSET_MAX, check_int32_offsets
from komira_arrow.concat_dict import (
    _concat_dict_columns,
    _carry_dict_payload,
    _copy_dict_codes,
    _copy_dict_offsets,
    _dicts_identical,
    _refuse_dict_layout_disagreement,
)
from komira_arrow.varlen_width_guard import check_fixed_width_dispatch
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer


# =============================================================================
# _merge_validity — build the concatenated validity bitmap for a ++ b
# =============================================================================


def _merge_validity[
    o_a: Origin[mut=False], o_b: Origin[mut=False]
](
    ref [o_a] a: Column[HeapRegion],
    ref [o_b] b: Column[HeapRegion],
    len_a: Int,
    len_b: Int,
) raises -> Optional[Bitmap[HeapRegion]]:
    """Merge the validity bitmaps of two Columns into one covering a ++ b.

    Returns None (the all-valid encoding) iff BOTH inputs report a zero
    null_count. Otherwise builds an
    all-valid bitmap of length `len_a + len_b` and clears the null
    positions contributed by each side:
      * if a side has a validity bitmap, its cleared bits are mirrored;
      * if a side has no bitmap but a non-zero null_count, that is a
        degenerate "N nulls, positions unknown" column — we conservatively
        clear its LEADING `null_count` bits so the result's null_count and
        bitmap agree (this only arises from columns produced by a buggy
        prior concat; new code always carries a bitmap when nulls exist).

    Bug fix: the prior
    `_concat_columns` set `validity=None` while propagating
    `null_count = a._null_count + b._null_count`, producing a column that
    claimed N nulls with NO bitmap — so `is_null(i)` returned False at every
    row while `null_count()` reported N. This silently corrupted every
    nullable column routed through the pair-wise concat path (parquet RG
    merge happened to feed only all-valid columns, hiding it). Block-parallel
    Avro decode concatenates per-worker nullable batches and exposed it.
    """
    if a._null_count == 0 and b._null_count == 0:
        return Optional[Bitmap[HeapRegion]](None)

    var bm = Bitmap.create_all_valid(len_a + len_b)
    _copy_validity_window(bm, 0, a)
    _copy_validity_window(bm, len_a, b)
    return Optional[Bitmap[HeapRegion]](bm^)


def _copy_validity_window(
    mut bm: Bitmap[HeapRegion], dst_row: Int, col: Column[HeapRegion]
) raises:
    """Write `col`'s validity for its rows [0, _length) into `bm` at
    `dst_row`. `bm` arrives all-valid over that range.

    ★ ROW `i` OF A COLUMN IS VALIDITY BIT `_offset + i`. `Column.slice` shares
    the whole-column bitmap and moves `_offset`, so reading from bit 0 pairs
    each row with the null bit of the row `_offset` places earlier. The
    `Bitmap.copy_bits_into` primitive copies from any source bit (memcpy when
    both ends are byte-aligned, a bit walk otherwise).

    A bitmap-less column with a positive null_count is a degenerate "N nulls,
    positions unknown" column (only a buggy prior concat produced one; new
    code always carries a bitmap when nulls exist). Its LEADING `null_count`
    rows are cleared so the result's null_count and bitmap agree.
    """
    var n = col._length
    if n == 0:
        return
    if col._validity:
        Bitmap.copy_bits_into(bm, dst_row, col._validity.value(), col._offset, n)
    elif col._null_count > 0:
        var k = col._null_count if col._null_count <= n else n
        for i in range(k):
            bm.clear(dst_row + i)


@always_inline
def _var_len_window[dt: DType](col: Column[HeapRegion]) -> Tuple[Int, Int]:
    """The data-buffer byte window `[start, end)` holding `col`'s rows: offsets
    entries `_offset` and `_offset + _length`. Arrow does not require the first
    entry to be 0 nor the data buffer to end at the last one, so neither the
    buffer's start nor its length is the window. No offsets buffer (every row
    empty, a komira convention) or no rows is the empty window."""
    if col._length == 0 or not col._offsets:
        return (0, 0)
    ref offs = col._offsets.value()
    return (
        Int(offs.get_typed[Scalar[dt]](col._offset)),
        Int(offs.get_typed[Scalar[dt]](col._offset + col._length)),
    )


@always_inline
def _rebase_offsets[
    dt: DType
](
    mut dst: OwnedAlignedBuffer,
    dst_elem: Int,
    src: SharedAlignedBuffer[HeapRegion],
    src_elem: Int,
    count: Int,
    delta: Scalar[dt],
):
    """`dst[dst_elem + i] = src[src_elem + i] + delta` for `i` in `[0, count)`.
    The wrap-around add is exact: every result is a valid offset."""
    # PERF-CRITICAL: SIMD offset rewrite — load + add constant + store.
    # 3-4x speedup on int32 addition; loads/stores are unaligned (alignment=1),
    # byte-offset addressed through load_simd / store_simd.
    comptime sz = size_of[Scalar[dt]]()
    comptime W = simd_width_of[dt]()
    var delta_vec = SIMD[dt, W](delta)
    var simd_end = (count // W) * W
    var i = 0
    while i < simd_end:
        var v = src.load_simd[dt, W]((src_elem + i) * sz)
        dst.store_simd[dt, W]((dst_elem + i) * sz, v + delta_vec)
        i += W
    while i < count:
        dst.set_typed[Scalar[dt]](
            dst_elem + i, src.get_typed[Scalar[dt]](src_elem + i) + delta
        )
        i += 1


@always_inline
def _fill_offsets[
    dt: DType
](mut dst: OwnedAlignedBuffer, dst_elem: Int, count: Int, val: Scalar[dt]):
    """`dst[dst_elem + i] = val` for `i` in `[0, count)` (rows that are all
    empty, from an input with no offsets buffer)."""
    comptime sz = size_of[Scalar[dt]]()
    comptime W = simd_width_of[dt]()
    var v = SIMD[dt, W](val)
    var simd_end = (count // W) * W
    var i = 0
    while i < simd_end:
        dst.store_simd[dt, W]((dst_elem + i) * sz, v)
        i += W
    while i < count:
        dst.set_typed[Scalar[dt]](dst_elem + i, val)
        i += 1


# =============================================================================
# _refuse_concat_layout_disagreement — the inputs must agree about their own
# buffer layout BEFORE any of them is read at a width taken from one of them.
# =============================================================================
#
# ⚠ WHY THE CHECK EXISTS.
# Offset WIDTH is NOT a SCHEMA-level property: a concat kernel cannot read the
# first input's tag and stride every other input by it. Width is a
# DATA-DEPENDENT decision taken independently PER PRODUCER CALL: a gather whose output
# crosses 2 GiB emits Int64 offsets and tags its column `LARGE_STRING`. Two
# batches of one logical result can therefore disagree, and a concat that
# reads only input 0's tag strides input 1's Int64 offsets by 4 — wrong
# values, exactly correct row count, no raise.
#
# Two other consumers of per-batch columns already took this seriously and
# this file is the sweep to the third: `result_ipc._refuse_divergent_chunk_
# schemas` (an IPC stream carries ONE schema) and `cross_batch_gather` ("all
# sources share the same type per column").
#
# THE PREDICATE IS `layouts_conflict`, NOT `!=`, AND THAT IS DELIBERATE. It
# fires only when BOTH sides' layouts are known from the tag AND differ, so:
#   * STRING vs LARGE_STRING fires (Int32 vs Int64 offsets) — the case above;
#   * DICTIONARY vs STRING fires (codes vs per-row offsets);
#   * a tag zeroed to NULL by the `Column` MOVE defect does NOT fire, because
#     NULL's layout class is UNKNOWN. That signature is still repaired
#     elsewhere in the tree and must not become a concat failure here;
#   * STRING vs BINARY does not fire — same buffers, and this kernel produces
#     byte-identical output for either.


def _refuse_concat_layout_disagreement(
    site: StaticString,
    which: Int,
    first: ArrowType,
    other: ArrowType,
) raises:
    """Raise when two concat inputs describe different buffer layouts.

    Args:
        site: The concat kernel performing the check.
        which: Index of the disagreeing input (1 for `b` in the pair-wise arm).
        first: The type this kernel took its stride and dispatch from.
        other: The type input `which` actually carries.

    Raises:
        Error: named `ArrowConcatLayoutDisagreement`.
    """
    if not layouts_conflict(first, other):
        return
    raise Error(
        String("ArrowConcatLayoutDisagreement: ")
        + String(site)
        + String(" dispatched on input 0's type ")
        + String(first)
        + String(" (layout class ")
        + String(first.physical_layout_class())
        + String("), but input ")
        + String(which)
        + String(" carries ")
        + String(other)
        + String(" (layout class ")
        + String(other.physical_layout_class())
        + String(
            "). These are DIFFERENT buffer layouts, so concatenating them"
            " would read one input's buffers at the other's stride — e.g."
            " Int64 LARGE_STRING offsets read at Int32 width, which yields"
            " wrong values under an exactly-correct row count and raises"
            " nothing. Offset width is a PER-BATCH, data-dependent property"
            " (the Int32-ceiling promotion), so inputs"
            " must be brought to one type before concatenation rather than"
            " assumed to share one."
        )
    )


# =============================================================================
# _concat_columns — concat two Columns into one
# =============================================================================


def _concat_columns[
    o_a: Origin[mut=False], o_b: Origin[mut=False]
](
    ref [o_a] a: Column[HeapRegion],
    ref [o_b] b: Column[HeapRegion],
) raises -> Column[HeapRegion]:
    """Concatenate two Columns by appending b's data after a's data.

    Handles fixed-width primitives (memcpy of data buffers), strings /
    binary (memcpy of data buffers + offset remapping), booleans
    (bit-level copy), and dictionary columns (with cross-RG dict remap).

    Origin-polymorphic: `o_a` and `o_b` are inferred independently at each
    call site so callers whose two Column references come from different
    RecordBatch owners keep their exclusivity distinct per Mojo's lifetime
    checker.

    Inputs are borrowed as `ref [o] Column`, so no `UnsafePointer`
    crosses the module boundary; the copy walks AlignedBuffers via
    origin-tied views.

    Args:
        a: Reference to the first Column.
        b: Reference to the second Column.

    Returns:
        A new Column containing all rows from a followed by all rows from b.
    """
    var at = a.arrow_type
    var len_a = a._length
    var len_b = b._length
    var total = len_a + len_b

    # EVERY arm below dispatches on `at` alone and then reads BOTH columns'
    # buffers at the stride that implies. `b`'s own type was never consulted.
    # See `_refuse_concat_layout_disagreement` above for what that costs now
    # that offset width is decided per producer call.
    _refuse_concat_layout_disagreement(
        "_concat_columns(pair-wise)", 1, at, b.arrow_type
    )

    if at == ArrowType.STRING or at == ArrowType.BINARY:
        # String/binary: concat data buffers and remap offsets.
        # Migrated `memcpy(dest=_unsafe_data_ptr()+off, src=...)` onto
        # `view_range_mut(off, N).copy_from_view_at(0, src_view)` and
        # offsets onto `set_typed[Int32]` / `get_typed[Int32]` +
        # `load_simd[DType.int32, W]` / `store_simd` for the PERF-CRITICAL
        # SIMD offset rewrite path.
        #
        # ★ EACH INPUT CONTRIBUTES ITS WINDOW, NOT ITS BUFFER. Row i of a
        # column is offsets entry `_offset + i`; the first entry need not be 0
        # and the data buffer may run past the last one (both legal Arrow).
        var win_a = _var_len_window[DType.int32](a)
        var win_b = _var_len_window[DType.int32](b)
        var data_start_a = win_a[0]
        var data_start_b = win_b[0]
        var data_len_a = win_a[1] - win_a[0]
        var data_len_b = win_b[1] - win_b[0]

        # ★ THE INT32-OFFSET CEILING, WHICH THIS ARM DID NOT HAVE.
        #
        # The rebase below computes `base_offset = Int32(data_len_a)` and adds
        # it to every one of b's offsets in Int32 SIMD. Two inputs each
        # comfortably under 2 GiB whose CONCATENATION crosses it would wrap
        # NEGATIVE — the output's row COUNT exactly right and every row past
        # the crossing unaddressable. The N-WAY sibling
        # `_concat_columns_nway_var_len` carries exactly this check and names
        # concat as "the classic way to cross 2 GiB", because each input is
        # under the limit and only the SUM overflows.
        #
        # It RAISES rather than promoting to LARGE_STRING. Promotion needs an
        # Int64 offsets writer here AND a schema that follows the column, and
        # the lockstep that provides the latter lives in
        # `RecordBatchBuilder.build` — which several callers of this function
        # do not go through. A promoted column emitted into a batch whose
        # schema still says STRING is the wrap with extra steps, so widening
        # this arm is a design change, not a hardening. Checked BEFORE the allocation, per the module discipline
        # in `offset_overflow.mojo`: an overflowing concat must not first
        # commit >2 GiB of RSS.
        check_int32_offsets(
            "_concat_columns(pair-wise)", data_len_a + data_len_b, total
        )

        var new_data = OwnedAlignedBuffer(data_len_a + data_len_b)
        if data_len_a > 0:
            new_data.view_range_mut(0, data_len_a).copy_from_view_at(
                0, a._data.view_range_ro(data_start_a, data_len_a)
            )
        if data_len_b > 0:
            new_data.view_range_mut(data_len_a, data_len_b).copy_from_view_at(
                0, b._data.view_range_ro(data_start_b, data_len_b)
            )
        new_data.set_length(Int64(data_len_a + data_len_b))

        # Build merged offsets: a's offsets + b's offsets shifted by a's data length.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (total + 1) * int32_size
        var new_offsets = OwnedAlignedBuffer(offsets_bytes)
        new_offsets.set_length(Int64(offsets_bytes))

        # a's offsets entries [_offset, _offset + len_a], rebased to start at 0.
        if a._offsets and len_a > 0:
            _rebase_offsets[DType.int32](
                new_offsets,
                0,
                a._offsets.value(),
                a._offset,
                len_a + 1,
                Int32(-data_start_a),
            )
        else:
            # No offsets buffer or no rows: all zeros. An absent offsets
            # buffer meaning "every row empty" is a komira convention, not
            # Arrow's (Arrow carries length + 1 offsets for any non-empty array).
            _fill_offsets[DType.int32](new_offsets, 0, len_a + 1, Int32(0))

        # b's entries (_offset, _offset + len_b], rebased to follow a's bytes.
        # PERF-CRITICAL: SIMD rewrite in `_rebase_offsets`.
        if b._offsets and len_b > 0:
            _rebase_offsets[DType.int32](
                new_offsets,
                len_a + 1,
                b._offsets.value(),
                b._offset + 1,
                len_b,
                Int32(data_len_a - data_start_b),
            )
        else:
            _fill_offsets[DType.int32](
                new_offsets, len_a + 1, len_b, Int32(data_len_a)
            )

        return Column[HeapRegion](
            arrow_type=at,
            data=new_data^,
            offsets=new_offsets^,
            validity=_merge_validity(a, b, len_a, len_b),
            length=total,
            null_count=a._null_count + b._null_count,
            offset=0,
        )

    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        # ★ THE INT64-OFFSET VAR-LEN ARM. Mirror of the
        # STRING/BINARY arm above, at Int64 stride throughout.
        #
        # ⛔ WHY THIS ARM HAD TO EXIST. Before it, a LARGE_STRING column fell
        # past all three arms into `check_fixed_width_dispatch`, which RAISES.
        # Fail-closed, so nothing was corrupted — but it meant that after
        # Route B-prime promoted an overflowing column to `large_string`,
        # ANY query that concatenates got zero rows instead of an answer:
        # UNION ALL, the Union node, multi-path scalar aggregation
        # (`agg_scalar_fold`), spill reload, and multi-batch Arrow IPC
        # readback (`decode_arrow_ipc_stream` -> `_concat_batches`), which
        # made a pyarrow-written `large_string` file with >1 RecordBatch
        # unreadable by this engine.
        #
        # ⚠ THE OUTPUT KEEPS THE WIDE TAG — it never narrows back. Narrowing
        # would be lossy above 2 GiB and, below it, would make the output type
        # depend on the DATA rather than on the inputs, which is exactly the
        # per-chunk type instability `result_ipc.write_result_ipc_chunked_stream`
        # refuses as OUTPUT_SCHEMA_DIVERGED.
        # Each input contributes its offsets WINDOW (see the narrow arm).
        var wwin_a = _var_len_window[DType.int64](a)
        var wwin_b = _var_len_window[DType.int64](b)
        var wdata_start_a = wwin_a[0]
        var wdata_start_b = wwin_b[0]
        var wdata_len_a = wwin_a[1] - wwin_a[0]
        var wdata_len_b = wwin_b[1] - wwin_b[0]

        # ★ THE WIDE ARM'S OWN CEILING, STATED RATHER THAN SKIPPED.
        #
        # The narrow arm's `check_int32_offsets` above is load-bearing: two
        # sub-2-GiB inputs routinely SUM past 2 GiB, which is why concat is
        # called "the classic way to cross" it. The Int64 equivalent is
        # different in kind, not just in degree: both operands here are the
        # lengths of buffers that are RESIDENT IN MEMORY RIGHT NOW, so
        # reaching 2^63 bytes would require ~9.2 exabytes of live RSS. It is
        # unreachable on any machine this will ever run on.
        #
        # It is checked anyway, and in the overflow-SAFE form (subtract, never
        # add), for two reasons: an unchecked `Int` add is UB-shaped if the
        # premise ever stops holding (a future mmap/lazy-buffer substrate
        # whose `len()` is not backed by resident bytes), and a comment
        # asserting "unreachable" is not a guard. The cost is one compare per
        # concat.
        if wdata_len_a > ARROW_INT64_OFFSET_MAX - wdata_len_b:
            raise Error(
                "_concat_columns(pair-wise, int64 offsets): the concatenated"
                " data buffer would be "
                + String(wdata_len_a)
                + " + "
                + String(wdata_len_b)
                + " bytes, which exceeds the Int64 offset ceiling"
            )

        var wnew_data = OwnedAlignedBuffer(wdata_len_a + wdata_len_b)
        if wdata_len_a > 0:
            wnew_data.view_range_mut(0, wdata_len_a).copy_from_view_at(
                0, a._data.view_range_ro(wdata_start_a, wdata_len_a)
            )
        if wdata_len_b > 0:
            wnew_data.view_range_mut(
                wdata_len_a, wdata_len_b
            ).copy_from_view_at(
                0, b._data.view_range_ro(wdata_start_b, wdata_len_b)
            )
        wnew_data.set_length(Int64(wdata_len_a + wdata_len_b))

        comptime int64_size = size_of[Int64]()
        var woffsets_bytes = (total + 1) * int64_size
        var wnew_offsets = OwnedAlignedBuffer(woffsets_bytes)
        wnew_offsets.set_length(Int64(woffsets_bytes))

        # a's offsets window, rebased to start at 0.
        if a._offsets and len_a > 0:
            _rebase_offsets[DType.int64](
                wnew_offsets,
                0,
                a._offsets.value(),
                a._offset,
                len_a + 1,
                Int64(-wdata_start_a),
            )
        else:
            # No offsets buffer (every row empty: komira convention, see the
            # narrow arm) or no rows: all zeros.
            _fill_offsets[DType.int64](wnew_offsets, 0, len_a + 1, Int64(0))

        # b's offsets are rebased to follow a's bytes, SIMD-staged exactly
        # like the narrow arm (same helper, 8-byte lanes). No offsets buffer on
        # b (komira convention): every row is empty, each offset the running base.
        if b._offsets and len_b > 0:
            _rebase_offsets[DType.int64](
                wnew_offsets,
                len_a + 1,
                b._offsets.value(),
                b._offset + 1,
                len_b,
                Int64(wdata_len_a - wdata_start_b),
            )
        else:
            _fill_offsets[DType.int64](
                wnew_offsets, len_a + 1, len_b, Int64(wdata_len_a)
            )

        return Column[HeapRegion](
            arrow_type=at,
            data=wnew_data^,
            offsets=wnew_offsets^,
            validity=_merge_validity(a, b, len_a, len_b),
            length=total,
            null_count=a._null_count + b._null_count,
            offset=0,
        )

    if at == ArrowType.BOOL:
        # Boolean: bitmap stored as packed bits.
        # Migrated memset/memcpy/deref onto MmapAlignedBuffer typed API
        # (`zero()` is full-buffer, `view_range_mut(off, N).fill(0)` per-
        # range, `read_u8_at` / `write_u8_at`).
        #
        # ★ ROW i IS VALUE BIT `_offset + i` on both sides, so neither input
        # can be copied as whole bytes from bit 0. `copy_bits_aligned_buffer`
        # memcpys when the source and destination bit positions are both
        # byte-aligned and walks bits otherwise.
        var bm_bytes_total = (total + 7) >> 3
        var new_data = OwnedAlignedBuffer(max(bm_bytes_total, 1))
        new_data.set_length(Int64(bm_bytes_total))
        if bm_bytes_total > 0:
            new_data.view_range_mut(0, bm_bytes_total).fill(0)
        copy_bits_aligned_buffer(new_data, 0, a._data, a._offset, len_a)
        copy_bits_aligned_buffer(new_data, len_a, b._data, b._offset, len_b)
        new_data.set_length(Int64(bm_bytes_total))


        return Column[HeapRegion](
            arrow_type=at,
            data=new_data^,
            offsets=None,
            validity=_merge_validity(a, b, len_a, len_b),
            length=total,
            null_count=a._null_count + b._null_count,
            offset=0,
        )

    if at == ArrowType.DICTIONARY:
        # Dictionary: concat code buffers, remapping b's codes into a merged
        # dictionary when the two dictionaries differ (common writers emit a
        # dictionary PER ROW GROUP). See `concat_dict._concat_dict_columns`.
        return _concat_dict_columns(a, b, _merge_validity(a, b, len_a, len_b))

    # Fixed-width primitives: just concat data buffers.
    # Migrated onto view_range_mut(...).copy_from_view_at(...).
    #
    # ⚠ GUARD: FOUR arms precede this point (STRING/BINARY, LARGE_STRING/LARGE_BINARY,
    # BOOL, DICTIONARY). Everything else lands here — LIST / LARGE_LIST / MAP
    # (offsets + children) and STRUCT / UNION_* (children). For all of those,
    # `_arrow_type_byte_width` returns its 8-byte `else` fallback and this arm
    # would emit `offsets=None` at the Column ctor below, silently REINTERPRETING
    # the payload buffer as n_rows*8 fixed-width cells while faithfully copying
    # `arrow_type` and `length` onto the output. Raise instead.
    #
    # ⚠ THE GUARD IS LOAD-BEARING DESPITE THE LARGE_* ARM — it is
    # keyed on `carries_offsets`/`carries_children`, not on an enumeration, so
    # the nested types it catches are unaffected by widening the var-len ones.
    check_fixed_width_dispatch("concat(pair-wise)", at, total)
    var byte_width = _arrow_type_byte_width(at)
    var bytes_a = len_a * byte_width
    var bytes_b = len_b * byte_width
    var new_data = OwnedAlignedBuffer(bytes_a + bytes_b)
    # Row i of each input is element `_offset + i`.
    if bytes_a > 0:
        new_data.view_range_mut(0, bytes_a).copy_from_view_at(
            0, a._data.view_range_ro(a._offset * byte_width, bytes_a)
        )
    if bytes_b > 0:
        new_data.view_range_mut(bytes_a, bytes_b).copy_from_view_at(
            0, b._data.view_range_ro(b._offset * byte_width, bytes_b)
        )
    new_data.set_length(Int64(bytes_a + bytes_b))


    var fixed_col = Column[HeapRegion](
        arrow_type=at,
        data=new_data^,
        offsets=None,
        validity=_merge_validity(a, b, len_a, len_b),
        length=total,
        null_count=a._null_count + b._null_count,
        offset=0,
    )
    # Propagate decimal precision/scale metadata (DECIMAL128 routes through
    # the fixed-width arm; the Column ctor defaults p/s to 0, so carry them
    # forward from `a` — both inputs must share the same (p, s) by schema).
    fixed_col._decimal_p = a._decimal_p
    fixed_col._decimal_s = a._decimal_s
    return fixed_col^


@always_inline
def _arrow_type_byte_width(at: ArrowType) raises -> Int:
    """Return byte width for fixed-BYTE-width Arrow types; raise otherwise.

    ⚠ NOT ITS OWN LADDER: delegates to the canonical table
    (`arrow_fixed_byte_width`). A private ladder here drifts: unsigned types
    and FLOAT16 fall to an 8-byte `else` (a UINT8 column concatenated at 8
    bytes/row is an 8x overread), DECIMAL256 / INTERVAL_MONTH_DAY_NANO get 8,
    and the int32-backed temporal types (DATE32 / TIME32_* /
    INTERVAL_YEAR_MONTH) are copied at DOUBLE the row width, silently
    returning the wrong days on every multi-row-group date column.

    ★ BOOL IS NOT A 1-BYTE TYPE HERE. Both call sites handle BOOL specially —
    `_concat_columns` branches on it at the packed-bit arm above, and
    `_concat_one_column_nway` routes `at.is_nested() or at == ArrowType.BOOL`
    to the pair-wise fold. The raise is the thing that keeps that true: if a
    third caller ever appears without that branch, it fails loudly instead of
    concatenating bitmap bytes as rows.
    """
    return arrow_fixed_byte_width(at)


# =============================================================================
# N-way concat helpers
# =============================================================================
#
# The pair-wise `_concat_columns(a, b)` API above implements the canonical
# Column ++ Column semantics. When folding N batches, the natural
# `acc = concat(acc, batch[i])` loop is O(N^2) in total memcpy traffic
# (iteration K copies (K * per-batch-bytes) into a fresh accumulator).
# On a 49-batch table that is about half the wall, ~24x more memcpy than
# needed.
#
# The N-way fold below replaces the O(N^2) shape with a 2-pass O(N + total
# bytes) walk:
#   Pass 1: compute total length + total per-buffer bytes across all
#           N inputs (no allocation, just metadata read).
#   Pass 2: allocate ONE output MmapAlignedBuffer per buffer kind, sized to
#           the exact total; walk inputs once and memcpy each into its
#           precomputed offset.
#
# Coverage matches the pair-wise function: fixed-width primitives
# (incl. DECIMAL128), STRING / BINARY (Int32 offsets), BOOL packed-bit,
# and DICTIONARY. DICTIONARY uses a fast/slow split: the fast path
# (all input dicts byte-identical to the first) handles the common
# DuckDB / pyarrow file shape with zero remap; the slow path falls
# back to the pair-wise fold (which itself handles cross-dict remap).
# Nested types (LIST / STRUCT / MAP / UNION) fall back to pair-wise.
#
# The helpers take `ref [o] Slab[RecordBatch]` so the caller retains
# ownership of the batch slab across all N column folds. Per-batch
# columns are accessed via `batches[i].column_at(col_idx)` which yields
# a typed `ref [batches._bytes] Column`.


def _concat_columns_nway_fixed_width[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch],
    col_idx: Int,
    n_batches: Int,
    at: ArrowType,
    byte_width: Int,
) raises -> Column[HeapRegion]:
    """N-way concat of a fixed-width-primitive column across N batches.

    Pass 1: sum total_len + total_nulls + any-validity-flag.
    Pass 2: single allocation, N memcpys.
    """
    # Pass 1 - totals.
    var total_len = 0
    var total_nulls = 0
    var any_validity = False
    var dec_p = 0
    var dec_s = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True
        if b_idx == 0:
            dec_p = bcol._decimal_p
            dec_s = bcol._decimal_s

    # Pass 2 - allocate + N memcpys.
    var total_data_bytes = total_len * byte_width
    var new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))
    var write_off = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var nb = bcol._length * byte_width
        if nb > 0:
            # Row i of an input is element `_offset + i`.
            new_data.view_range_mut(write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(bcol._offset * byte_width, nb)
            )
        write_off += nb
    new_data.set_length(Int64(total_data_bytes))


    # Validity bitmap merge (single allocation if needed).
    var validity = _merge_validity_nway(
        batches, col_idx, n_batches, total_len, any_validity
    )

    var col = Column[HeapRegion](
        arrow_type=at,
        data=new_data^,
        offsets=None,
        validity=validity^,
        length=total_len,
        null_count=total_nulls,
        offset=0,
    )
    col._decimal_p = dec_p
    col._decimal_s = dec_s
    return col^


def _concat_columns_nway_var_len[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch],
    col_idx: Int,
    n_batches: Int,
    at: ArrowType,
) raises -> Column[HeapRegion]:
    """N-way concat of a STRING / BINARY column across N batches.

    Pass 1: sum total_len + total_data_bytes (sum of each input's data buf)
            + total_nulls.
    Pass 2: single data alloc + single offsets alloc; walk inputs; memcpy
            data, write rebased offsets via SIMD load+add+store.

    PRECONDITION, enforced by the caller: every input's column carries a type
    whose layout agrees with `at` (`_concat_one_column_nway` runs
    `_refuse_concat_layout_disagreement` over all N before dispatching here).
    This kernel reads every input's `_offsets` at Int32 stride unconditionally,
    so a LARGE_STRING input reaching it is a silent wrong answer. The
    `check_int32_offsets` below is NOT that check — it is a byte-count ceiling
    that catches such a mix only when the summed total happens to cross 2 GiB.
    """
    comptime int32_size = size_of[Int32]()

    # Pass 1.
    var total_len = 0
    var total_data_bytes = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        # The input's offsets WINDOW, not its whole data buffer: the first
        # entry need not be 0 and the buffer may run past the last one.
        var win = _var_len_window[DType.int32](bcol)
        total_data_bytes += win[1] - win[0]
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True

    # Int32-offset ceiling. Pass 1 sums in 64-bit `Int`, but pass 2 writes
    # every rebased offset as an `Int32`. N-way
    # concat is the classic way to cross 2 GiB: each input batch is well under
    # the limit and only the SUM overflows.
    var _cc_name = String()
    if n_batches > 0:
        _cc_name = batches[0].schema.field_name(col_idx)
    check_int32_offsets(
        "_concat_string_columns_multi", _cc_name, total_data_bytes, total_len
    )

    # Pass 2 - data buffer (single alloc + N memcpys).
    var new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))
    var data_write_off = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var dwin = _var_len_window[DType.int32](bcol)
        var nb = dwin[1] - dwin[0]
        if nb > 0:
            new_data.view_range_mut(data_write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(dwin[0], nb)
            )
        data_write_off += nb
    new_data.set_length(Int64(total_data_bytes))


    # Offsets buffer: (total_len + 1) * 4 bytes. Always emit a leading 0.
    var offsets_bytes = (total_len + 1) * int32_size
    var new_offsets = OwnedAlignedBuffer(offsets_bytes)
    new_offsets.set_length(Int64(offsets_bytes))
    new_offsets.set_typed[Int32](0, Int32(0))

    # Walk N batches; for each, append its offsets entries
    # (_offset, _offset + len] rebased from the window start onto the
    # cumulative output byte count (`_rebase_offsets`, the PERF-CRITICAL
    # SIMD load+add+store), then bump the cumulative data offset.
    var cumulative_data = 0
    var dst_elem = 0  # element index where next batch's offsets begin
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var blen = bcol._length
        var win = _var_len_window[DType.int32](bcol)
        # +1: the leading 0 is at dst_elem=0 for the first input; for
        # subsequent inputs, the value at dst_elem was already written by the
        # prior iteration's last entry. We start at dst_elem+1 every time.
        if bcol._offsets and blen > 0:
            _rebase_offsets[DType.int32](
                new_offsets,
                dst_elem + 1,
                bcol._offsets.value(),
                bcol._offset + 1,
                blen,
                Int32(cumulative_data - win[0]),
            )
        else:
            # No offsets buffer: all rows are empty. Fill cumulative_data.
            _fill_offsets[DType.int32](
                new_offsets, dst_elem + 1, blen, Int32(cumulative_data)
            )

        cumulative_data += win[1] - win[0]
        dst_elem += blen

    var validity = _merge_validity_nway(
        batches, col_idx, n_batches, total_len, any_validity
    )

    return Column[HeapRegion](
        arrow_type=at,
        data=new_data^,
        offsets=new_offsets^,
        validity=validity^,
        length=total_len,
        null_count=total_nulls,
        offset=0,
    )


def _concat_columns_nway_var_len_wide[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch],
    col_idx: Int,
    n_batches: Int,
    at: ArrowType,
) raises -> Column[HeapRegion]:
    """N-way concat of a LARGE_STRING / LARGE_BINARY column across N batches.

    The Int64-offset twin of `_concat_columns_nway_var_len`, with the same two
    passes and the same SIMD rebase shape at 8-byte lanes.

    PRECONDITION, enforced by the caller exactly as for the narrow twin: every
    input's column type agrees in LAYOUT with `at`
    (`_concat_one_column_nway` runs `_refuse_concat_layout_disagreement` over
    all N first). This kernel reads every input's `_offsets` at Int64 stride
    unconditionally, so a STRING input reaching it would be read at the wrong
    width — the agreement check, not this function, is what prevents that.

    ⚠ IT DOES NOT NARROW THE OUTPUT even when the concatenated total would fit
    Int32. Doing so would make the output type depend on the DATA rather than
    on the inputs, and a per-chunk type that moves is precisely what
    `result_ipc.write_result_ipc_chunked_stream` refuses as
    OUTPUT_SCHEMA_DIVERGED.
    """
    comptime int64_size = size_of[Int64]()

    # Pass 1.
    var total_len = 0
    var total_data_bytes = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        var wwin = _var_len_window[DType.int64](bcol)
        var nb_len = wwin[1] - wwin[0]
        # Overflow-safe accumulate against the Int64 offsets ceiling. See
        # `ARROW_INT64_OFFSET_MAX`'s docstring for why this can never fire on
        # resident buffers and is written anyway.
        if total_data_bytes > ARROW_INT64_OFFSET_MAX - nb_len:
            raise Error(
                "_concat_columns_nway_var_len_wide: the concatenated data"
                " buffer would exceed the Int64 offset ceiling at input "
                + String(b_idx)
            )
        total_data_bytes += nb_len
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True

    # Pass 2 - data buffer (single alloc + N memcpys).
    var new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))
    var data_write_off = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var dwin = _var_len_window[DType.int64](bcol)
        var nb = dwin[1] - dwin[0]
        if nb > 0:
            new_data.view_range_mut(data_write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(dwin[0], nb)
            )
        data_write_off += nb
    new_data.set_length(Int64(total_data_bytes))

    # Offsets buffer: (total_len + 1) * 8 bytes. Always emit a leading 0.
    var offsets_bytes = (total_len + 1) * int64_size
    var new_offsets = OwnedAlignedBuffer(offsets_bytes)
    new_offsets.set_length(Int64(offsets_bytes))
    new_offsets.set_typed[Int64](0, Int64(0))

    var cumulative_data = 0
    var dst_elem = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var blen = bcol._length
        var wwin = _var_len_window[DType.int64](bcol)
        if bcol._offsets and blen > 0:
            _rebase_offsets[DType.int64](
                new_offsets,
                dst_elem + 1,
                bcol._offsets.value(),
                bcol._offset + 1,
                blen,
                Int64(cumulative_data - wwin[0]),
            )
        else:
            # No offsets buffer: all rows are empty. Fill cumulative_data.
            _fill_offsets[DType.int64](
                new_offsets, dst_elem + 1, blen, Int64(cumulative_data)
            )

        cumulative_data += wwin[1] - wwin[0]
        dst_elem += blen

    var validity = _merge_validity_nway(
        batches, col_idx, n_batches, total_len, any_validity
    )

    return Column[HeapRegion](
        arrow_type=at,
        data=new_data^,
        offsets=new_offsets^,
        validity=validity^,
        length=total_len,
        null_count=total_nulls,
        offset=0,
    )


def _merge_validity_nway[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch],
    col_idx: Int,
    n_batches: Int,
    total_len: Int,
    any_validity: Bool,
) raises -> Optional[Bitmap[HeapRegion]]:
    """N-way validity bitmap merge.

    Mirrors `_merge_validity` semantics: returns None iff every input is
    fully valid (no bitmap AND zero null_count). Otherwise builds an
    all-valid bitmap of total_len bits and clears null positions from
    each input. Inputs with a positive null_count but NO bitmap (degenerate
    columns) clear their leading
    null_count bits.
    """
    var any_nulls = any_validity
    if not any_nulls:
        for b_idx in range(n_batches):
            ref bcol = batches[b_idx].column_at(col_idx)
            if bcol._null_count > 0:
                any_nulls = True
                break
    if not any_nulls:
        return Optional[Bitmap[HeapRegion]](None)

    #
    # Replaced per-bit scalar loop `for i: if not bv.test(i): bm.clear(...)`
    # with the existing `Bitmap.copy_bits_into` primitive, which routes
    # through `copy_bits_aligned_buffer` -> libc memcpy on byte-aligned
    # offsets (the common case when row counts are multiples of 8).
    #
    # Why Mojo can beat arrow-rs/arrow-cpp here:
    # arrow-rs's `bit_mask::set_bits` (the analogous primitive) processes
    # validity bits in 64-bit chunks via scalar u64 load_unaligned +
    # shift + count_zeros, expecting LLVM to auto-vectorize. arrow-cpp's
    # `BitmapWordReader/Writer<uint64_t>` is the same scalar-u64-chunk
    # pattern. Mojo's `copy_bits_aligned_buffer` uses libc memcpy on the
    # byte-aligned fast path, which on Apple M-series dispatches to
    # `_platform_memmove$VARIANT$Apple` (NEON LD1/ST1 64-byte stride).
    # That's a direct ~8x throughput win (64 bytes/iter vs 8 bytes/iter
    # for the scalar u64 loop) AND eliminates the per-iteration shift +
    # count_zeros overhead. For the unaligned tail (row_off % 8 != 0),
    # we fall back to the existing bit-unaligned scalar walk which still
    # beats the per-bit `bm.clear()` round-trip.
    var bm = Bitmap.create_all_valid(total_len)
    var row_off = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var blen = bcol._length
        # Byte-aligned hot path: `Bitmap.copy_bits_into` (inside
        # `_copy_validity_window`) overwrites `bm[row_off..row_off+blen]`
        # with the input's validity bits [_offset, _offset + blen), which is
        # semantically equivalent here because `bm` was initialized
        # all-valid by `Bitmap.create_all_valid(total_len)`. The primitive
        # handles both byte-aligned (memcpy bulk) and bit-unaligned (scalar
        # bit-walk) cases; a sliced input with `_offset % 8 != 0` takes the
        # walk.
        _copy_validity_window(bm, row_off, bcol)
        row_off += blen

    return Optional[Bitmap[HeapRegion]](bm^)


def _all_dicts_byte_identical[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch], col_idx: Int, n_batches: Int
) -> Bool:
    """Return True iff all N batches' DICTIONARY column @col_idx carry the
    same dictionary as batch 0 (`concat_dict._dicts_identical`: size, value
    dtype, value bytes AND, for a string dictionary, offsets). v1 fast-path
    predicate.
    """
    ref c0 = batches[0].column_at(col_idx)
    for b in range(1, n_batches):
        if not _dicts_identical(c0, batches[b].column_at(col_idx)):
            return False
    return True


def _concat_columns_nway_dict_identical[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch], col_idx: Int, n_batches: Int
) raises -> Column[HeapRegion]:
    """N-way concat of DICTIONARY columns whose dicts are identical.

    Fast path: reuse first batch's dict + concat every batch's code window
    (elements [_offset, _offset + _length), at the shared code width the
    caller has checked) via single-alloc + N memcpys.
    """
    ref c0 = batches[0].column_at(col_idx)
    var w = c0._dict_index_byte_width

    var total_len = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True

    var idx_bytes_total = total_len * w
    var new_data = OwnedAlignedBuffer(max(idx_bytes_total, 1))
    new_data.set_length(Int64(idx_bytes_total))
    var write_row = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        _copy_dict_codes(new_data, write_row, bcol, w)
        write_row += bcol._length

    var validity = _merge_validity_nway(
        batches, col_idx, n_batches, total_len, any_validity
    )

    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=new_data^,
        offsets=_copy_dict_offsets(c0),
        validity=validity^,
        length=total_len,
        null_count=total_nulls,
        offset=0,
    )
    _carry_dict_payload(col, c0, w)
    return col^


def _concat_one_column_nway[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch], col_idx: Int, n_batches: Int
) raises -> Column[HeapRegion]:
    """Single-column N-way concat dispatcher.

    Dispatches by ArrowType to the type-specific N-way kernels.  Falls
    back to the pair-wise `_concat_columns` fold for types not yet
    covered by the N-way redesign (nested LIST / STRUCT / MAP / UNION,
    DICTIONARY-with-divergent-dicts, BOOL).
    """
    if n_batches == 1:
        # Single input: deep-copy (we cannot move out of an interior ref
        # without invalidating the caller's borrow on Slab[RecordBatch]).
        return batches[0].column_at(col_idx).deep_copy()

    ref c0 = batches[0].column_at(col_idx)
    var at = c0.arrow_type

    # ★ EVERY ARM BELOW IS DISPATCHED FROM BATCH 0'S TAG ALONE, so batch 0's
    # tag decides the stride at which batches 1..N-1's buffers are read. Check
    # that they agree before any of them is read.
    #
    # ⚠ `_concat_columns_nway_var_len` IS ONLY PARTIALLY SELF-PROTECTING, AND
    # BY COINCIDENCE. Its `check_int32_offsets` on the SUMMED byte total does
    # catch some promoted/narrow mixes — but only the ones whose total happens
    # to exceed 2 GiB, and a LARGE_STRING column can be well under that: the
    # type-PRESERVING LARGE_* gather arms (`gather_batch_dispatch`) keep the
    # wide tag through a filter that cuts the payload to any size. A byte-count
    # guard is not a type check and must not be relied on as one.
    for _b in range(1, n_batches):
        _refuse_concat_layout_disagreement(
            "_concat_one_column_nway",
            _b,
            at,
            batches[_b].column_at(col_idx).arrow_type,
        )

    # STRING / BINARY var-len path (Int32 offsets).
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        return _concat_columns_nway_var_len(batches, col_idx, n_batches, at)

    # LARGE_STRING / LARGE_BINARY var-len path (Int64 offsets).
    #
    # ⛔ WITHOUT THIS ARM A PROMOTED COLUMN CONCATENATES TO NOTHING.
    # `is_nested()` does not match the LARGE_* var-len types and the arm above
    # does not either, so a `large_string` column would fall to
    # `check_fixed_width_dispatch` and RAISE. The single-batch case
    # (`n_batches == 1`, deep_copy above) works either way, which makes the
    # gap easy to miss: a one-RecordBatch `large_string` Arrow file reads
    # fine and a two-RecordBatch one would be refused.
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        return _concat_columns_nway_var_len_wide(
            batches, col_idx, n_batches, at
        )

    # DICTIONARY: fast path iff all dicts are identical.
    if at == ArrowType.DICTIONARY:
        # Every input's codes are read at batch 0's code width and decoded
        # through one kind of dictionary; refuse inputs that disagree.
        for _b in range(1, n_batches):
            _refuse_dict_layout_disagreement(
                "_concat_one_column_nway(dictionary)",
                _b,
                c0,
                batches[_b].column_at(col_idx),
            )
        if _all_dicts_byte_identical(batches, col_idx, n_batches):
            return _concat_columns_nway_dict_identical(
                batches, col_idx, n_batches
            )
        # Divergent-dict slow path: pair-wise fold via deep_copy accumulator.
        var acc = batches[0].column_at(col_idx).deep_copy()
        for b in range(1, n_batches):
            ref nxt = batches[b].column_at(col_idx)
            var merged = _concat_columns(acc, nxt)
            acc = merged^
        return acc^

    # BOOL + nested (LIST/STRUCT/MAP/UNION): pair-wise fold fallback.
    #
    # ⚠ This covers BOOL, NOT the nested types: `_concat_columns` has no
    # nested arm, so a nested type handed to it reaches ITS fixed-width arm,
    # which RAISES for the nested types rather than reinterpreting them as
    # 8-byte cells with children and offsets dropped. This path is loud
    # instead of wrong.
    if at.is_nested() or at == ArrowType.BOOL:
        var acc2 = batches[0].column_at(col_idx).deep_copy()
        for b in range(1, n_batches):
            ref nxt2 = batches[b].column_at(col_idx)
            var merged2 = _concat_columns(acc2, nxt2)
            acc2 = merged2^
        return acc2^

    # Fixed-width primitive arm (INT8/16/32/64, FLOAT32/64, DECIMAL128,
    # temporal storage types).
    #
    # ⚠ GUARD: without it, an offsets-carrying column arriving here would be
    # concatenated as an 8-byte fixed-width primitive — offsets dropped,
    # payload read as n_rows*8 cells, output still tagged with a correct row
    # count. The LARGE_* arm above handles the wide var-len types, so this
    # guard's job is the NESTED types (LIST / LARGE_LIST / MAP / STRUCT /
    # UNION_*), which have no N-way kernel.
    var nway_total = 0
    for b in range(n_batches):
        nway_total += batches[b].column_at(col_idx)._length
    check_fixed_width_dispatch("concat(n-way)", at, nway_total)
    var byte_width = _arrow_type_byte_width(at)
    return _concat_columns_nway_fixed_width(
        batches, col_idx, n_batches, at, byte_width
    )


def concat_record_batches_nway(
    var batches: Slab[RecordBatch],
) raises -> RecordBatch:
    """N-way concat of N RecordBatches into ONE via per-column N-way fold.

    Replaces the O(N^2) pair-wise `_concat_batches` accumulator pattern with
    a single 2-pass walk per column.  All input batches MUST share the
    same Schema (Arrow stream/file invariant).

    Per-column complexity: 2 passes (metadata sum + alloc-and-memcpy) over
    the N inputs.  Cross-column: one outer loop over Schema fields.  Total
    memcpy traffic = O(total_bytes), not O(N * total_bytes).

    Preconditions:
      - `batches.len >= 1` (caller handles the 0-batch case).

    Returns:
      A single merged RecordBatch carrying sum-of-row-counts rows.

    Raises iff any per-column `_concat_one_column_nway` raises.
    """
    var n_batches = len(batches)
    debug_assert(
        n_batches >= 1,
        "concat_record_batches_nway: caller must handle the 0-batch case",
    )

    if n_batches == 1:
        var only = batches.take_slot_unchecked(0)
        batches.set_len_unchecked(0)
        _ = batches^
        return only^

    # Take schema from the first batch (all batches share it per Arrow spec).
    # We deep-copy out of batch[0] so the schema survives the source slab's
    # destruction at end of function.
    var schema = batches[0].schema.copy()
    var num_cols = batches[0].num_columns()

    var merged_builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var merged_col = _concat_one_column_nway(batches, c, n_batches)
        merged_builder.add_column(merged_col^)

    # Drop all source batches.
    for b_idx in range(n_batches):
        UnsafePointer(to=batches.get_mut_interior(b_idx)).unsafe_deinit_pointee()
    batches.set_len_unchecked(0)
    _ = batches^

    return merged_builder.build(schema^)


def concat_record_batches_nway_ref[
    o: Origin[mut=False]
](ref [o] batches: Slab[RecordBatch]) raises -> RecordBatch:
    """BORROW-based N-way concat: read N RecordBatches THROUGH an immutable
    borrow and fold them into ONE owned RecordBatch — WITHOUT consuming the
    source `Slab`.

    Identical fold semantics to `concat_record_batches_nway` (same
    `_concat_one_column_nway` per-column kernel, byte-identical output), but
    the source batches are read by `ref` and left intact. This is the variant
    used by the zero-copy passthrough bare-scan gate, where the
    chunks live behind a SHARED `ArcPointer[Slab[RecordBatch]]` (the
    InMemorySource may be re-read by a session-cache plan re-compile) and so
    CANNOT be moved out. Reading by `ref` lets the gate concat the
    mmap-borrowed chunks DIRECTLY into one owned dense batch — eliminating the
    per-branch `copy_batch` deep-copy that the PLAN_UNION lowering performs
    (`lower_untyped._lower_multi_batch_in_memory_scan`). The mmap keepalive
    Arc on each source column stays alive through the borrow; the produced
    output owns its buffers (the per-column kernel allocs + memcpys), so the
    result survives independently of the source mmap.

    Preconditions:
      - `len(batches) >= 1` (caller handles the 0-batch case).
      - All batches share the same Schema (Arrow stream/file invariant).

    Returns:
      A single merged RecordBatch carrying sum-of-row-counts rows. The
      single-batch case (`len == 1`) deep-copies the lone batch (cannot move
      out of the borrow); N>1 allocs + memcpys per column.
    """
    var n_batches = len(batches)
    debug_assert(
        n_batches >= 1,
        "concat_record_batches_nway_ref: caller must handle the 0-batch case",
    )

    if n_batches == 1:
        # Cannot move out of the borrow; deep-copy the lone batch's columns
        # into owned storage. (Matches `_concat_one_column_nway`'s n==1 arm.)
        var schema1 = batches[0].schema.copy()
        var num_cols1 = batches[0].num_columns()
        var b1 = RecordBatchBuilder.with_capacity(num_cols1)
        for c in range(num_cols1):
            b1.add_column(batches[0].column_at(c).deep_copy())
        return b1.build(schema1^)

    var schema = batches[0].schema.copy()
    var num_cols = batches[0].num_columns()

    var merged_builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var merged_col = _concat_one_column_nway(batches, c, n_batches)
        merged_builder.add_column(merged_col^)

    return merged_builder.build(schema^)
