# =============================================================================
# merge_dict_columns -- N-way union of DICTIONARY-typed Columns
# =============================================================================
#
# Cross-worker dict merge helper. The pairwise version
# of this lives in concat.mojo::_concat_columns (DICTIONARY branch)
# and is called from streaming_concat._concat_variable_width_batches's
# pairwise-fold. This helper is the explicit N-way variant: takes a list of
# DICTIONARY Columns (same physical value dtype: BYTE_ARRAY strings),
# unions their dictionaries, remaps indices, returns a single DICTIONARY
# Column. Designed to be the call site for ParquetCollectSink.combine().
#
# Column is Movable-only (owns AlignedBuffers, Bitmap) so we use
# Slab[Column] rather than List[Column] for the input container --
# the caller must move columns in, and the helper consumes them.
#
# Algorithm
# ---------
# 1. Seed a `DictInterner` with the first dictionary's entries, in order.
# 2. For each subsequent column, `find_or_insert` each of its dict entries;
#    each is either already interned (reuse ordinal) or appended (new ordinal).
#    Build a per-column remap table `local_idx -> global_idx`.
# 3. Concatenate all index arrays into one output buffer, applying each
#    column's remap.
# 4. Rebuild the merged dictionary's offsets + data buffers from
#    `merged_strings`.
# 5. Carry validity per-row by concatenating each input's validity bitmap
#    (or an all-valid implicit bitmap when the input is non-nullable).
#
# Fast paths
# ----------
# * len(cols) == 0                       -> raise (no schema)
# * len(cols) == 1                       -> byte-copy the single column
# * all dicts are byte-identical in size+content -> skip the per-entry
#   dictionary scan; just concat indices unchanged
#
# Complexity: O(sum(len_i) + sum(dict_size_i)) — one hash probe per dictionary
# entry, amortised.
#
# ⛔ An O(K^2) linear scan is NOT fine on the premise that "K = distinct-values
# total is small … typically << 10^4". Common writers emit a dictionary PER
# ROW GROUP, so K is the column's distinct cardinality across the whole file —
# millions for a free-text column, orders of magnitude past that bound, and the
# resulting Σ k·d² comparisons never finish.
# =============================================================================

from std.memory import alloc, unsafe_memcpy
from std.sys import size_of

from ..collections.slab import Slab

from .owned_aligned_buffer import OwnedAlignedBuffer
from .offset_overflow import check_int32_offsets
from .dict_interner import DictInterner, dict_merge_probe_add
from .arrow_types import ArrowType
from ..io.heap_region import HeapRegion
from .bitmap import Bitmap
from .column import Column


def merge_dict_columns(cols: Slab[Column[HeapRegion]]) raises -> Column[HeapRegion]:
    """Union the dictionaries of N DICTIONARY Columns and remap indices.

    All inputs must be arrow_type == DICTIONARY with BYTE_ARRAY (string)
    values. Returns a single DICTIONARY Column whose dictionary is the
    union of inputs and whose indices reference the union.

    Args:
        cols: N DICTIONARY Columns (Slab because Column is
            Movable-only). Borrowed, not consumed.

    Returns:
        A new DICTIONARY Column with length == sum(col.len() for col in cols).

    Raises:
        Error if cols is empty, or any input is not DICTIONARY, or a dict
        column is missing its offsets/data buffers.
    """
    if len(cols) == 0:
        raise Error("merge_dict_columns: empty input list")

    # Type-check every input.
    for ci in range(len(cols)):
        ref c = cols[ci]
        if c.arrow_type != ArrowType.DICTIONARY:
            raise Error(
                "merge_dict_columns: input "
                + String(ci)
                + " is "
                + String(c.arrow_type)
                + ", expected DICTIONARY"
            )
        if not c._offsets:
            raise Error(
                "merge_dict_columns: input " + String(ci)
                + " missing dictionary offsets"
            )
        if not c._dict_data:
            raise Error(
                "merge_dict_columns: input " + String(ci)
                + " missing dictionary data"
            )

    # Single-column fast path: deep byte-copy of the only column.
    if len(cols) == 1:
        return _clone_column_fields(cols[0])

    # Fast path: check whether every input shares the same dict bytes with
    # the first. When so, skip the per-entry dictionary scan.
    # Migrated byte-compare loop onto `read_u8_at` (universal read).
    var all_dicts_identical = True
    ref first = cols[0]
    var first_dict_size = first._dict_size
    var first_dict_bytes = first._dict_data.value().len()
    for ci in range(1, len(cols)):
        ref c = cols[ci]
        if c._dict_size != first_dict_size:
            all_dicts_identical = False
            break
        if c._dict_data.value().len() != first_dict_bytes:
            all_dicts_identical = False
            break
        for b in range(first_dict_bytes):
            if (
                first._dict_data.value().read_u8_at(b)
                != c._dict_data.value().read_u8_at(b)
            ):
                all_dicts_identical = False
                break
        if not all_dicts_identical:
            break

    comptime int32_size = size_of[Int32]()
    var total_rows = 0
    for ci in range(len(cols)):
        total_rows += cols[ci]._length

    if all_dicts_identical:
        return _concat_identical_dicts(cols, total_rows)

    # Slow path: build merged dictionary + per-column remap tables.
    #
    # ⛔ NOT a linear scan (see the header note): a parquet file can carry a
    # dictionary PER ROW GROUP, so K is the column's distinct cardinality —
    # millions, not 10^4.
    # `DictInterner` makes the merge O(Σ dict_size) probes with no per-entry
    # `String`, preserving first-seen ordering and seed duplicates exactly (the
    # first column's index buffer is remapped by IDENTITY below, so its entry i
    # must stay at ordinal i even if its dictionary repeats a value).
    var interner = DictInterner(expected_entries=first_dict_size * len(cols))
    _seed_interner_from_column(interner, cols[0])

    # Column 0 has identity remap; build it first. Remaining remaps are
    # stored as a List of List (owned) since Int32 is Copyable.
    var remaps = List[List[Int32]]()
    var identity0 = List[Int32](capacity=first_dict_size)
    for i in range(first_dict_size):
        identity0.append(Int32(i))
    remaps.append(identity0^)

    for ci in range(1, len(cols)):
        ref c = cols[ci]
        var c_dict_size = c._dict_size
        var remap = List[Int32](capacity=c_dict_size)
        for si in range(c_dict_size):
            var s = Int(c._offsets.value().get_typed[Int32](si))
            var e = Int(c._offsets.value().get_typed[Int32](si + 1))
            remap.append(
                interner.find_or_insert(
                    c._dict_data.value().view_ro().sub(s, e - s)
                )
            )
        remaps.append(remap^)
    dict_merge_probe_add(interner.probes())

    # Build merged dictionary offsets + data — one bulk memcpy each out of the
    # interner's arena.
    var merged_size = interner.size()
    var merged_offs = OwnedAlignedBuffer((merged_size + 1) * int32_size)
    merged_offs.copy_from_int32_list(interner.offsets())
    merged_offs.set_length(Int64((merged_size + 1) * int32_size))

    var total_data_len = interner.total_bytes()

    # Int32-offset ceiling on the MERGED dictionary values buffer.
    check_int32_offsets(
        "merge_dictionaries(values)", total_data_len, merged_size
    )

    var merged_data = OwnedAlignedBuffer(max(total_data_len, 1))
    merged_data.copy_from_bytes_list(interner.bytes())
    merged_data.set_length(Int64(total_data_len))


    # Build the concatenated index buffer by applying each column's remap.
    # Migrated onto `get_typed[Int32]` / `set_typed[Int32]`.
    var idx_buf = OwnedAlignedBuffer(max(total_rows * int32_size, 1))
    var out_row = 0
    for ci in range(len(cols)):
        ref c = cols[ci]
        var n = c._length
        ref remap = remaps[ci]
        for r in range(n):
            var raw = Int(c._data.get_typed[Int32](r))
            idx_buf.set_typed[Int32](out_row + r, remap[raw])
        out_row += n
    idx_buf.set_length(Int64(total_rows * int32_size))


    # Concatenate validity bitmaps. If every input is non-null we skip
    # the bitmap entirely (null_count == 0, validity == None).
    var combined_validity = _concat_validities(cols, total_rows)
    var total_nulls = 0
    for ci in range(len(cols)):
        total_nulls += cols[ci]._null_count

    var out = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=idx_buf^,
        offsets=Optional[OwnedAlignedBuffer](merged_offs^),
        validity=combined_validity^,
        length=total_rows,
        null_count=total_nulls,
        offset=0,
    )
    out._set_dict_data_from_oab(merged_data^)
    out._dict_size = merged_size
    return out^


# =============================================================================
# Helpers
# =============================================================================


def _concat_identical_dicts(cols: Slab[Column[HeapRegion]], total_rows: Int) -> Column[HeapRegion]:
    """Fast path: all inputs share the same dictionary bytes. Just concat
    index buffers and copy dictionary from the first column."""
    # Migrated index-buf and dict buffer memcpys onto view-based copy.
    comptime int32_size = size_of[Int32]()
    var idx_buf = OwnedAlignedBuffer(max(total_rows * int32_size, 1))
    var write = 0
    for ci in range(len(cols)):
        ref c = cols[ci]
        var n_bytes = c._length * int32_size
        if n_bytes > 0:
            idx_buf.view_range_mut(write, n_bytes).copy_from_view_at(
                0, c._data.view_range_ro(0, n_bytes)
            )
        write += n_bytes
    idx_buf.set_length(Int64(total_rows * int32_size))


    ref first = cols[0]
    var off_bytes = first._offsets.value().len()
    var dict_offs = OwnedAlignedBuffer(max(off_bytes, 1))
    if off_bytes > 0:
        dict_offs.copy_from_view(
            first._offsets.value().view_range_ro(0, off_bytes)
        )
    dict_offs.set_length(Int64(off_bytes))


    var data_bytes = first._dict_data.value().len()
    var dict_data = OwnedAlignedBuffer(max(data_bytes, 1))
    if data_bytes > 0:
        dict_data.copy_from_view(
            first._dict_data.value().view_range_ro(0, data_bytes)
        )
    dict_data.set_length(Int64(data_bytes))


    var validity = _concat_validities(cols, total_rows)
    var total_nulls = 0
    for ci in range(len(cols)):
        total_nulls += cols[ci]._null_count

    var out = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=idx_buf^,
        offsets=Optional[OwnedAlignedBuffer](dict_offs^),
        validity=validity^,
        length=total_rows,
        null_count=total_nulls,
        offset=0,
    )
    out._set_dict_data_from_oab(dict_data^)
    out._dict_size = first._dict_size
    return out^


def _clone_column_fields(c: Column[HeapRegion]) -> Column[HeapRegion]:
    """Deep-clone a Column[HeapRegion] by byte-copying every buffer. Used because
    Column is Movable-only (no copy ctor).

    Migrated all buffer memcpys onto `copy_from_view`.
    """
    var data_bytes = c._data.len()
    var data = OwnedAlignedBuffer(max(data_bytes, 1))
    if data_bytes > 0:
        data.copy_from_view(c._data.view_range_ro(0, data_bytes))
    data.set_length(Int64(data_bytes))


    var offsets = Optional[OwnedAlignedBuffer](None)
    if c._offsets:
        var ob = c._offsets.value().len()
        var o = OwnedAlignedBuffer(max(ob, 1))
        if ob > 0:
            o.copy_from_view(c._offsets.value().view_range_ro(0, ob))
        o.set_length(Int64(ob))

        offsets = o^

    var validity = Optional[Bitmap[HeapRegion]](None)
    if c._validity:
        var bm_len = c._validity.value().length
        var bm = Bitmap.create(bm_len)
        var bb = (bm_len + 7) >> 3
        if bb > 0:
            bm.buffer.copy_from_view(
                c._validity.value().buffer.view_range_ro(0, bb)
            )
            bm.buffer.set_length(bb)

        validity = bm^

    var out = Column[HeapRegion](
        arrow_type=c.arrow_type,
        data=data^,
        offsets=offsets^,
        validity=validity^,
        length=c._length,
        null_count=c._null_count,
        offset=c._offset,
    )
    if c._dict_data:
        var dd = c._dict_data.value().len()
        var d = OwnedAlignedBuffer(max(dd, 1))
        if dd > 0:
            d.copy_from_view(c._dict_data.value().view_range_ro(0, dd))
        d.set_length(Int64(dd))

        out._set_dict_data_from_oab(d^)
    out._dict_size = c._dict_size
    return out^


def _seed_interner_from_column(mut interner: DictInterner, c: Column[HeapRegion]):
    """Seed `interner` with every entry of `c`'s dictionary, in order.

    `seed_append`, not `find_or_insert`: this column's index buffer is remapped
    by IDENTITY, so entry i must land at ordinal i even when the dictionary
    repeats a value. (Replaces `_dict_column_to_string_list`, which
    materialized one heap `String` per entry purely so a linear scan could
    compare them.)
    """
    for i in range(c._dict_size):
        var s = Int(c._offsets.value().get_typed[Int32](i))
        var e = Int(c._offsets.value().get_typed[Int32](i + 1))
        _ = interner.seed_append(c._dict_data.value().view_ro().sub(s, e - s))


def _concat_validities(cols: Slab[Column[HeapRegion]], total_rows: Int) -> Optional[Bitmap[HeapRegion]]:
    """Concatenate per-input validity bitmaps into a single total_rows
    bitmap. Returns None when every input is non-null (null_count == 0
    AND no validity bitmap attached) -- callers treat None as all-valid."""
    var any_nulls = False
    for ci in range(len(cols)):
        if cols[ci]._null_count > 0 or cols[ci]._validity:
            any_nulls = True
            break
    if not any_nulls:
        return None

    var bm = Bitmap.create(total_rows)
    var bm_bytes = (total_rows + 7) >> 3
    # Migrated per-byte 0xFF loop onto fill() (memset).
    if bm_bytes > 0:
        bm.buffer.view_range_mut(0, bm_bytes).fill(0xFF)
    bm.buffer.set_length(bm_bytes)


    var row = 0
    for ci in range(len(cols)):
        ref c = cols[ci]
        var n = c._length
        if c._validity:
            for r in range(n):
                if not c._validity.value().test(r):
                    bm.clear(row + r)
        row += n
    return bm^
