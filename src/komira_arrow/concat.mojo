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

from std.memory import alloc, unsafe_memcpy, unsafe_memset
from std.sys import size_of, simd_width_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.arrow_types import arrow_fixed_byte_width, layouts_conflict
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.offset_overflow import ARROW_INT64_OFFSET_MAX, check_int32_offsets
from komira_arrow.dict_interner import DictInterner, dict_merge_probe_add
from komira_arrow.varlen_width_guard import check_fixed_width_dispatch
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


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

    Returns None (the all-valid encoding) iff BOTH inputs are fully valid
    (no validity bitmap AND zero null_count). Otherwise builds an
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
    var a_nulls = a._null_count
    var b_nulls = b._null_count
    if a_nulls == 0 and b_nulls == 0:
        return Optional[Bitmap[HeapRegion]](None)

    var total = len_a + len_b
    var bm = Bitmap.create_all_valid(total)

    # Mirror a's nulls into [0, len_a).
    if a._validity:
        ref av = a._validity.value()
        for i in range(len_a):
            if not av.test(i):
                bm.clear(i)
    elif a_nulls > 0:
        # Degenerate: bitmap-less column with a positive null_count. Clear
        # the leading `a_nulls` positions so count + bitmap stay consistent.
        var n = a_nulls if a_nulls <= len_a else len_a
        for i in range(n):
            bm.clear(i)

    # Mirror b's nulls into [len_a, total).
    if b._validity:
        ref bv = b._validity.value()
        for i in range(len_b):
            if not bv.test(i):
                bm.clear(len_a + i)
    elif b_nulls > 0:
        var n2 = b_nulls if b_nulls <= len_b else len_b
        for i in range(n2):
            bm.clear(len_a + i)

    return Optional[Bitmap[HeapRegion]](bm^)


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
        var data_len_a = a._data.len()
        var data_len_b = b._data.len()

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
                0, a._data.view_range_ro(0, data_len_a)
            )
        if data_len_b > 0:
            new_data.view_range_mut(data_len_a, data_len_b).copy_from_view_at(
                0, b._data.view_range_ro(0, data_len_b)
            )
        new_data.set_length(Int64(data_len_a + data_len_b))


        # Build merged offsets: a's offsets + b's offsets shifted by a's data length.
        comptime int32_size = size_of[Int32]()
        var offsets_bytes = (total + 1) * int32_size
        var new_offsets = OwnedAlignedBuffer(offsets_bytes)

        # Copy a's offsets (len_a + 1 entries).
        if a._offsets:
            for i in range(len_a + 1):
                new_offsets.set_typed[Int32](
                    i, a._offsets.value().get_typed[Int32](i)
                )
        else:
            for i in range(len_a + 1):
                new_offsets.set_typed[Int32](i, Int32(0))

        # PERF-CRITICAL: SIMD offset rewrite — load + add constant + store.
        # 3-4x speedup on aligned int32 addition. Migrated onto
        # MmapAlignedBuffer.load_simd / store_simd (byte-offset addressed).
        var base_offset = Int32(data_len_a)
        # byte offset into new_offsets where b's remapped offsets start:
        #   (len_a + 1) * 4 bytes. Each step writes W Int32s = W*4 bytes.
        var dst_byte_start = (len_a + 1) * int32_size
        if b._offsets:
            comptime W = simd_width_of[DType.int32]()
            var base_vec = SIMD[DType.int32, W](base_offset)
            # b's offsets start at index 1 (skip its first entry, which
            # is 0). In bytes: skip `int32_size` from base.
            var simd_end = (len_b // W) * W
            var i = 0
            while i < simd_end:
                var v = b._offsets.value().load_simd[DType.int32, W](
                    (1 + i) * int32_size
                )
                new_offsets.store_simd[DType.int32, W](
                    dst_byte_start + i * int32_size, v + base_vec
                )
                i += W
            while i < len_b:
                var v = b._offsets.value().get_typed[Int32](1 + i)
                new_offsets.set_typed[Int32](
                    len_a + 1 + i, v + base_offset
                )
                i += 1
        else:
            comptime W2 = simd_width_of[DType.int32]()
            var base_vec2 = SIMD[DType.int32, W2](base_offset)
            var simd_end2 = (len_b // W2) * W2
            var i2 = 0
            while i2 < simd_end2:
                new_offsets.store_simd[DType.int32, W2](
                    dst_byte_start + i2 * int32_size, base_vec2
                )
                i2 += W2
            while i2 < len_b:
                new_offsets.set_typed[Int32](
                    len_a + 1 + i2, base_offset
                )
                i2 += 1

        new_offsets.set_length(Int64(offsets_bytes))


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
        var wdata_len_a = a._data.len()
        var wdata_len_b = b._data.len()

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
                0, a._data.view_range_ro(0, wdata_len_a)
            )
        if wdata_len_b > 0:
            wnew_data.view_range_mut(
                wdata_len_a, wdata_len_b
            ).copy_from_view_at(0, b._data.view_range_ro(0, wdata_len_b))
        wnew_data.set_length(Int64(wdata_len_a + wdata_len_b))

        comptime int64_size = size_of[Int64]()
        var woffsets_bytes = (total + 1) * int64_size
        var wnew_offsets = OwnedAlignedBuffer(woffsets_bytes)

        # a's offsets pass through unchanged (its base is already 0).
        if a._offsets:
            for i in range(len_a + 1):
                wnew_offsets.set_typed[Int64](
                    i, a._offsets.value().get_typed[Int64](i)
                )
        else:
            for i in range(len_a + 1):
                wnew_offsets.set_typed[Int64](i, Int64(0))

        # b's offsets are rebased by a's data length, SIMD-staged exactly like
        # the narrow arm (same shape, 8-byte lanes).
        var wbase_offset = Int64(wdata_len_a)
        var wdst_byte_start = (len_a + 1) * int64_size
        if b._offsets:
            comptime WW = simd_width_of[DType.int64]()
            var wbase_vec = SIMD[DType.int64, WW](wbase_offset)
            var wsimd_end = (len_b // WW) * WW
            var wi = 0
            while wi < wsimd_end:
                var wv = b._offsets.value().load_simd[DType.int64, WW](
                    (1 + wi) * int64_size
                )
                wnew_offsets.store_simd[DType.int64, WW](
                    wdst_byte_start + wi * int64_size, wv + wbase_vec
                )
                wi += WW
            while wi < len_b:
                var wv2 = b._offsets.value().get_typed[Int64](1 + wi)
                wnew_offsets.set_typed[Int64](
                    len_a + 1 + wi, wv2 + wbase_offset
                )
                wi += 1
        else:
            # No offsets buffer on b: every one of its rows is empty, so each
            # offset is the running base.
            for wi3 in range(len_b):
                wnew_offsets.set_typed[Int64](len_a + 1 + wi3, wbase_offset)

        wnew_offsets.set_length(Int64(woffsets_bytes))

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
        var bm_bytes_a = (len_a + 7) >> 3
        var bm_bytes_total = (total + 7) >> 3
        var new_data = OwnedAlignedBuffer(bm_bytes_total)
        # Zero-fill first, then copy a's bits as whole bytes, then set
        # b's bits one-by-one (bit offset may not be byte-aligned).
        new_data.view_range_mut(0, bm_bytes_total).fill(0)
        if bm_bytes_a > 0:
            new_data.view_range_mut(0, bm_bytes_a).copy_from_view_at(
                0, a._data.view_range_ro(0, bm_bytes_a)
            )
        # Clear any trailing garbage bits in the last byte of a's data
        # to prevent them from interfering with b's bits via OR.
        var tail_bits = len_a & 7
        if tail_bits != 0 and bm_bytes_a > 0:
            var mask = UInt8((1 << tail_bits) - 1)
            var cur = new_data.read_u8_at(bm_bytes_a - 1)
            new_data.write_u8_at(bm_bytes_a - 1, cur & mask)
        # Append b's bits starting at bit position len_a.
        for i in range(len_b):
            # Read bit i from b.
            var src_byte = i >> 3
            var src_bit = i & 7
            var is_set = (
                b._data.read_u8_at(src_byte) >> UInt8(src_bit)
            ) & UInt8(1) != UInt8(0)
            if is_set:
                var dst_idx = len_a + i
                var dst_byte = dst_idx >> 3
                var dst_bit = dst_idx & 7
                var cur = new_data.read_u8_at(dst_byte)
                new_data.write_u8_at(
                    dst_byte, cur | (UInt8(1) << UInt8(dst_bit))
                )
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
        # Dictionary: concat int32 index buffers with cross-row-group remap.
        #
        # When different row groups have different dictionary orderings (e.g.,
        # RG0 dict=["A","B","C"] vs RG1 dict=["C","A","B"]), raw index
        # concatenation produces wrong results. We build a remap table that
        # translates b's dictionary indices to a's dictionary space.
        #
        # Fast path: if dictionaries have identical size and byte content,
        # skip remapping (most common case for DuckDB-written files).
        comptime int32_size = size_of[Int32]()

        # Determine if dictionaries differ.
        var needs_remap = False
        var dict_size_a = a._dict_size
        var dict_size_b = b._dict_size

        if dict_size_a != dict_size_b:
            needs_remap = True
        elif a._dict_data:
            if b._dict_data:
                # Same dict size -- compare dict data bytes for equality.
                var data_len_a = a._dict_data.value().len()
                var data_len_b = b._dict_data.value().len()
                if data_len_a != data_len_b:
                    needs_remap = True
                elif data_len_a > 0:
                    # Byte-by-byte comparison (could use memcmp if available).
                    # Migrated pointer indexing onto `read_u8_at`.
                    for i in range(data_len_a):
                        if (
                            a._dict_data.value().read_u8_at(i)
                            != b._dict_data.value().read_u8_at(i)
                        ):
                            needs_remap = True
                            break

        if not needs_remap:
            # Fast path: identical dictionaries. Just concat index buffers.
            # Migrated memcpy-via-ptr onto view-based copy.
            var idx_bytes_a = len_a * int32_size
            var idx_bytes_b = len_b * int32_size
            var new_data = OwnedAlignedBuffer(idx_bytes_a + idx_bytes_b)
            if idx_bytes_a > 0:
                new_data.view_range_mut(0, idx_bytes_a).copy_from_view_at(
                    0, a._data.view_range_ro(0, idx_bytes_a)
                )
            if idx_bytes_b > 0:
                new_data.view_range_mut(
                    idx_bytes_a, idx_bytes_b
                ).copy_from_view_at(
                    0, b._data.view_range_ro(0, idx_bytes_b)
                )
            new_data.set_length(Int64(idx_bytes_a + idx_bytes_b))


            var dict_offsets = Optional[OwnedAlignedBuffer](None)
            if a._offsets:
                var off_len = a._offsets.value().len()
                var off_buf = OwnedAlignedBuffer(off_len)
                if off_len > 0:
                    off_buf.copy_from_view(
                        a._offsets.value().view_range_ro(0, off_len)
                    )
                off_buf.set_length(Int64(off_len))

                dict_offsets = off_buf^

            var col = Column[HeapRegion](
                arrow_type=ArrowType.DICTIONARY,
                data=new_data^,
                offsets=dict_offsets^,
                validity=None,
                length=total,
                null_count=a._null_count + b._null_count,
                offset=0,
            )
            if a._dict_data:
                var dict_len = a._dict_data.value().len()
                var dict_buf = OwnedAlignedBuffer(dict_len)
                if dict_len > 0:
                    dict_buf.copy_from_view(
                        a._dict_data.value().view_range_ro(0, dict_len)
                    )
                dict_buf.set_length(Int64(dict_len))

                col._set_dict_data_from_oab(dict_buf^)
            col._dict_size = a._dict_size
            return col^

        # Slow path: different dictionaries. Build remap table b_idx -> merged_idx.
        # Strategy: start with a's dictionary as the "canonical" dictionary.
        # For each entry in b's dictionary, find matching entry in a or append.
        #
        # ⛔ NOT A LINEAR SCAN OVER A `List[String]`, and NOT a rare case:
        # common writers emit a dictionary PER ROW GROUP, so such a parquet
        # file lands here on column 0. A free-text column can intern millions
        # of distinct values over dozens of row groups, and a linear scan makes
        # the fold Σ k·d² comparisons — a merge that never finishes.
        #
        # `DictInterner` is an append-only bytes arena + Int32 offsets + an
        # open-addressing index, so a merge is O(Σ dict_size) probes and ZERO
        # per-entry `String` allocations. It preserves FIRST-SEEN insertion
        # order, which this repo's byte-equivalence oracles depend on, and
        # `seed_append` preserves DUPLICATES in a's dictionary — a's index
        # buffer is copied through unchanged below, so entry i must stay at
        # ordinal i even when a's dictionary is not distinct.
        var interner = DictInterner(
            expected_entries=dict_size_a + dict_size_b
        )
        for i in range(dict_size_a):
            var s = Int(a._offsets.value().get_typed[Int32](i))
            var e = Int(a._offsets.value().get_typed[Int32](i + 1))
            _ = interner.seed_append(
                a._dict_data.value().view_ro().sub(s, e - s)
            )

        # Build remap: for each b entry, find in merged or append.
        # SAFETY: remap is heap-allocated for dict_size_b entries. Freed after use.
        # Remap is a local scratch `alloc[Int32]` not backed
        # by an MmapAlignedBuffer — migrating this to an MmapAlignedBuffer (so we
        # can use typed R/W on it) changes the allocation pattern. Keep
        # raw alloc for now (this is internal-only pointer arithmetic,
        # not an escape across module boundary).
        var remap = alloc[Int32](max(dict_size_b, 1))
        for i in range(dict_size_b):
            var bs = Int(b._offsets.value().get_typed[Int32](i))
            var be = Int(b._offsets.value().get_typed[Int32](i + 1))
            (remap + i)[] = interner.find_or_insert(
                b._dict_data.value().view_ro().sub(bs, be - bs)
            )

        dict_merge_probe_add(interner.probes())

        var merged_size = interner.size()

        # Rebuild merged dictionary offsets and data. Both are one bulk memcpy
        # out of the interner's arena — the old form rebuilt them by walking a
        # `List[String]` that had itself been rebuilt at every fold step.
        var merged_offs_bytes = (merged_size + 1) * int32_size
        var merged_offs_buf = OwnedAlignedBuffer(merged_offs_bytes)
        merged_offs_buf.copy_from_int32_list(interner.offsets())
        merged_offs_buf.set_length(Int64(merged_offs_bytes))

        var total_data_len = interner.total_bytes()

        # Int32-offset ceiling on the MERGED dictionary values buffer.
        check_int32_offsets(
            "concat(dictionary values)", total_data_len, merged_size
        )

        var merged_data_buf = OwnedAlignedBuffer(max(total_data_len, 1))
        merged_data_buf.copy_from_bytes_list(interner.bytes())
        merged_data_buf.set_length(Int64(total_data_len))


        # Build merged index buffer: a's indices unchanged, b's remapped.
        var idx_bytes_a = len_a * int32_size
        var idx_bytes_b = len_b * int32_size
        var new_data = OwnedAlignedBuffer(idx_bytes_a + idx_bytes_b)
        if idx_bytes_a > 0:
            new_data.view_range_mut(0, idx_bytes_a).copy_from_view_at(
                0, a._data.view_range_ro(0, idx_bytes_a)
            )
        # Remap b's indices via typed R/W.
        for i in range(len_b):
            var b_raw = Int(b._data.get_typed[Int32](i))
            # Write at dst element-index (len_a + i), i.e. byte
            # idx_bytes_a + i * int32_size.
            new_data.set_typed[Int32](len_a + i, (remap + b_raw)[])
        new_data.set_length(Int64(idx_bytes_a + idx_bytes_b))


        remap.free()

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=new_data^,
            offsets=merged_offs_buf^,
            validity=_merge_validity(a, b, len_a, len_b),
            length=total,
            null_count=a._null_count + b._null_count,
            offset=0,
        )
        col._set_dict_data_from_oab(merged_data_buf^)
        col._dict_size = merged_size

        return col^

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
    if bytes_a > 0:
        new_data.view_range_mut(0, bytes_a).copy_from_view_at(
            0, a._data.view_range_ro(0, bytes_a)
        )
    if bytes_b > 0:
        new_data.view_range_mut(bytes_a, bytes_b).copy_from_view_at(
            0, b._data.view_range_ro(0, bytes_b)
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
            new_data.view_range_mut(write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(0, nb)
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
    comptime W = simd_width_of[DType.int32]()

    # Pass 1.
    var total_len = 0
    var total_data_bytes = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        total_data_bytes += bcol._data.len()
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True

    # Int32-offset ceiling. Pass 1 sums in 64-bit `Int`, but pass 2 rebases
    # every offset through an `Int32` `cumulative_data` accumulator. N-way
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
        var nb = bcol._data.len()
        if nb > 0:
            new_data.view_range_mut(data_write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(0, nb)
            )
        data_write_off += nb
    new_data.set_length(Int64(total_data_bytes))


    # Offsets buffer: (total_len + 1) * 4 bytes. Always emit a leading 0.
    var offsets_bytes = (total_len + 1) * int32_size
    var new_offsets = OwnedAlignedBuffer(offsets_bytes)
    new_offsets.set_typed[Int32](0, Int32(0))

    # Walk N batches; for each, append (per-row-offset[1..len] + cumulative)
    # via SIMD load+add+store, then bump the cumulative data offset.
    var cumulative_data = Int32(0)
    var dst_elem = 0  # element index where next batch's offsets begin
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var blen = bcol._length
        var base_vec = SIMD[DType.int32, W](cumulative_data)

        if bcol._offsets:
            # SIMD-stage: read input offsets[1..blen], add cumulative, store.
            var simd_end = (blen // W) * W
            var i = 0
            # +1: the leading 0 is at dst_elem=0 for the first input; for
            # subsequent inputs, the value at dst_elem was already written
            # by the prior iteration's offsets[blen-1] write. We start at
            # dst_elem+1 in every iteration.
            var dst_byte_start = (dst_elem + 1) * int32_size
            while i < simd_end:
                var v = bcol._offsets.value().load_simd[DType.int32, W](
                    (1 + i) * int32_size
                )
                new_offsets.store_simd[DType.int32, W](
                    dst_byte_start + i * int32_size, v + base_vec
                )
                i += W
            while i < blen:
                var v = bcol._offsets.value().get_typed[Int32](1 + i)
                new_offsets.set_typed[Int32](
                    dst_elem + 1 + i, v + cumulative_data
                )
                i += 1
        else:
            # No offsets buffer: all rows are empty. Fill cumulative_data.
            var i = 0
            while i < blen:
                new_offsets.set_typed[Int32](
                    dst_elem + 1 + i, cumulative_data
                )
                i += 1

        cumulative_data += Int32(bcol._data.len())
        dst_elem += blen
    new_offsets.set_length(Int64(offsets_bytes))


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
    comptime W = simd_width_of[DType.int64]()

    # Pass 1.
    var total_len = 0
    var total_data_bytes = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        var nb_len = bcol._data.len()
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
        var nb = bcol._data.len()
        if nb > 0:
            new_data.view_range_mut(data_write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(0, nb)
            )
        data_write_off += nb
    new_data.set_length(Int64(total_data_bytes))

    # Offsets buffer: (total_len + 1) * 8 bytes. Always emit a leading 0.
    var offsets_bytes = (total_len + 1) * int64_size
    var new_offsets = OwnedAlignedBuffer(offsets_bytes)
    new_offsets.set_typed[Int64](0, Int64(0))

    var cumulative_data = Int64(0)
    var dst_elem = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var blen = bcol._length
        var base_vec = SIMD[DType.int64, W](cumulative_data)

        if bcol._offsets:
            var simd_end = (blen // W) * W
            var i = 0
            var dst_byte_start = (dst_elem + 1) * int64_size
            while i < simd_end:
                var v = bcol._offsets.value().load_simd[DType.int64, W](
                    (1 + i) * int64_size
                )
                new_offsets.store_simd[DType.int64, W](
                    dst_byte_start + i * int64_size, v + base_vec
                )
                i += W
            while i < blen:
                var v2 = bcol._offsets.value().get_typed[Int64](1 + i)
                new_offsets.set_typed[Int64](
                    dst_elem + 1 + i, v2 + cumulative_data
                )
                i += 1
        else:
            # No offsets buffer: all rows are empty. Fill cumulative_data.
            for i2 in range(blen):
                new_offsets.set_typed[Int64](
                    dst_elem + 1 + i2, cumulative_data
                )

        cumulative_data += Int64(bcol._data.len())
        dst_elem += blen
    new_offsets.set_length(Int64(offsets_bytes))

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
        if bcol._validity:
            # Byte-aligned hot path: `Bitmap.copy_bits_into` overwrites
            # `bm[row_off..row_off+blen]` with the validity slice, which
            # is semantically equivalent here because `bm` was initialized
            # all-valid by `Bitmap.create_all_valid(total_len)`. The
            # primitive handles both byte-aligned (memcpy bulk) and
            # bit-unaligned (scalar bit-walk) cases.
            ref bv = bcol._validity.value()
            Bitmap.copy_bits_into(bm, row_off, bv, 0, blen)
        elif bcol._null_count > 0:
            var n = bcol._null_count if bcol._null_count <= blen else blen
            for i in range(n):
                bm.clear(row_off + i)
        row_off += blen

    return Optional[Bitmap[HeapRegion]](bm^)


def _all_dicts_byte_identical[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch], col_idx: Int, n_batches: Int
) -> Bool:
    """Return True iff all N batches' DICTIONARY column @col_idx share
    byte-identical dict bytes + dict size. v1 fast-path predicate.
    """
    ref c0 = batches[0].column_at(col_idx)
    var dsz0 = c0._dict_size
    if not c0._dict_data:
        # All-empty dict; check rest match.
        for b in range(1, n_batches):
            ref cb = batches[b].column_at(col_idx)
            if cb._dict_data or cb._dict_size != dsz0:
                return False
        return True
    var dlen0 = c0._dict_data.value().len()
    for b in range(1, n_batches):
        ref cb = batches[b].column_at(col_idx)
        if cb._dict_size != dsz0:
            return False
        if not cb._dict_data:
            return False
        var dlenb = cb._dict_data.value().len()
        if dlenb != dlen0:
            return False
        for i in range(dlen0):
            if (
                c0._dict_data.value().read_u8_at(i)
                != cb._dict_data.value().read_u8_at(i)
            ):
                return False
    return True


def _concat_columns_nway_dict_identical[
    o: Origin[mut=False]
](
    ref [o] batches: Slab[RecordBatch], col_idx: Int, n_batches: Int
) raises -> Column[HeapRegion]:
    """N-way concat of DICTIONARY columns whose dicts are byte-identical.

    Fast path: reuse first batch's dict + concat all batches' Int32
    index buffers via single-alloc + N memcpys.
    """
    comptime int32_size = size_of[Int32]()

    var total_len = 0
    var total_nulls = 0
    var any_validity = False
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        total_len += bcol._length
        total_nulls += bcol._null_count
        if bcol._validity:
            any_validity = True

    var idx_bytes_total = total_len * int32_size
    var new_data = OwnedAlignedBuffer(max(idx_bytes_total, 1))
    var write_off = 0
    for b_idx in range(n_batches):
        ref bcol = batches[b_idx].column_at(col_idx)
        var nb = bcol._length * int32_size
        if nb > 0:
            new_data.view_range_mut(write_off, nb).copy_from_view_at(
                0, bcol._data.view_range_ro(0, nb)
            )
        write_off += nb
    new_data.set_length(Int64(idx_bytes_total))


    ref c0 = batches[0].column_at(col_idx)
    var dict_offsets = Optional[OwnedAlignedBuffer](None)
    if c0._offsets:
        var off_len = c0._offsets.value().len()
        var off_buf = OwnedAlignedBuffer(max(off_len, 1))
        if off_len > 0:
            off_buf.copy_from_view(
                c0._offsets.value().view_range_ro(0, off_len)
            )
        off_buf.set_length(Int64(off_len))

        dict_offsets = off_buf^

    var validity = _merge_validity_nway(
        batches, col_idx, n_batches, total_len, any_validity
    )

    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=new_data^,
        offsets=dict_offsets^,
        validity=validity^,
        length=total_len,
        null_count=total_nulls,
        offset=0,
    )
    if c0._dict_data:
        var dlen = c0._dict_data.value().len()
        var dbuf = OwnedAlignedBuffer(max(dlen, 1))
        if dlen > 0:
            dbuf.copy_from_view(c0._dict_data.value().view_range_ro(0, dlen))
        dbuf.set_length(Int64(dlen))

        col._set_dict_data_from_oab(dbuf^)
    col._dict_size = c0._dict_size
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

    # DICTIONARY: fast path iff all dicts are byte-identical.
    if at == ArrowType.DICTIONARY:
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
