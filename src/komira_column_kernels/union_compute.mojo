# =============================================================================
# UnionArray compute kernels — filter, take, hash, equality.
# =============================================================================
#
# Compute kernels
# for UNION_SPARSE + UNION_DENSE Columns, dispatching per-row by the
# union's `_type_ids` discriminator down to the appropriate child column.
#
# Per the Arrow spec (https://arrow.apache.org/docs/format/Columnar.html):
#
#   * Sparse union: 1 buffer (Int8 types, length=N).  N child arrays, EACH
#     of length N.  Filter / take operate uniformly across types_buf + each
#     child (the same mask / index list applies to types_buf and every
#     child verbatim).
#
#   * Dense union: 2 buffers (Int8 types + Int32 offsets, both length=N).
#     N child arrays with INDEPENDENT lengths.  Filter / take must
#     (a) filter / gather the types_buf,
#     (b) rewrite the offsets buffer so that for each surviving parent row
#         carrying type-id T, the offset is the running count of surviving
#         rows of type T,
#     (c) for each child, filter / gather the child by the SUBSET of
#         original child-row indices that map to surviving parent rows.
#
#   * Unions have NO validity bitmap of their own (Arrow spec — nullness
#     is determined entirely by the selected child's validity).  All
#     kernels in this module honor that.
#
# Equality (eval_eq_union) per Arrow spec: equal iff (same per-row type-id)
# AND (child element-equal at the selected child row).  Hash combines the
# child's hash with the discriminator type-id to prevent cross-type
# collisions: hash(value) = hash_child(child_row) XOR mix64(type_id).
#
# Child-type coverage: this kernel supports Int8/Int16/Int32/Int64 (signed
# + unsigned), Float32/Float64, Boolean, Utf8/LargeUtf8, Binary/LargeBinary,
# Date32/Date64, Time32/64, Timestamp, Duration, Decimal128/256,
# Interval_MDN, Struct, List, Map.  Nested children dispatch recursively.
# Unsupported child types raise an explicit error rather than silently
# producing a wrong shape.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import (
    Bitmap,
    gather_bits_aligned_buffer,
    read_bit_aligned_buffer,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.binary_array import BinaryArray
from komira_arrow.large_binary_array import LargeBinaryArray
from komira_arrow.decimal_array import Decimal128Array, DECIMAL128_BYTE_WIDTH
from komira_arrow.decimal256_array import Decimal256Array, DECIMAL256_BYTE_WIDTH
from komira_arrow.interval_mdn_array import (
    IntervalMonthDayNanoArray,
    INTERVAL_MDN_BYTE_WIDTH,
)
from komira_arrow.list_array import ListArray
from komira_arrow.struct_array import StructArray
from komira_arrow.map_array import MapArray
from komira_arrow.union_array import UnionArray
from komira_collections.slab import Slab

from komira_column_kernels.interval_mdn_kernels import hash_one_interval_mdn


# =============================================================================
# Internal helpers — per-Column take / filter / hash-one / eq-at dispatchers.
# These are deliberately recursive so a UNION child can itself be nested.
# =============================================================================


def _bytes_for(arrow_type: ArrowType) -> Int:
    """Per-row byte width of a fixed-width child type. Returns 0 for layouts
    that have NO fixed per-element byte width — var-len, nested, and BOOL —
    because callers route on `> 0` and 0 means "use the dedicated arm".

    ⚠ BOOL IS NOT IN THE `return 1` ARM, AND PUTTING IT THERE IS WORSE THAN
    OMITTING IT. Its buffer is `(n + 7) >> 3` bytes and its `_offset` is a BIT
    index, so there is no per-element byte width to return; answering 1 is not
    a conservative estimate, it is the claim that `row * 1` addresses a row.
    `_take_column_dispatch` routes on `> 0`, so a bool column would walk into
    `_take_fixed_width`, which copies BYTE i of the bitmap as ROW i into an
    `n`-byte buffer the consumer then reads as `n` BITS. No raise, no crash —
    WRONG BOOLS. `_eq_at`'s `(offset + i) * w + k` byte-compare would have the
    identical defect. Reachable from `agg_struct` (`GROUP BY <struct with a
    bool field>`) and from the nested gather route, so any SORT or JOIN gather
    over a nested column with a bool leaf would reach it too.
    """
    if arrow_type == ArrowType.INT8 or arrow_type == ArrowType.UINT8:
        return 1
    if (
        arrow_type == ArrowType.INT16
        or arrow_type == ArrowType.UINT16
        or arrow_type == ArrowType.FLOAT16
    ):
        return 2
    if (
        arrow_type == ArrowType.INT32
        or arrow_type == ArrowType.UINT32
        or arrow_type == ArrowType.FLOAT32
        or arrow_type == ArrowType.DATE32
        or arrow_type == ArrowType.TIME32_S
        or arrow_type == ArrowType.TIME32_MS
        or arrow_type == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return 4
    if (
        arrow_type == ArrowType.INT64
        or arrow_type == ArrowType.UINT64
        or arrow_type == ArrowType.FLOAT64
        or arrow_type == ArrowType.DATE64
        or arrow_type == ArrowType.TIME64_US
        or arrow_type == ArrowType.TIME64_NS
        or arrow_type == ArrowType.TIMESTAMP
        or arrow_type == ArrowType.TIMESTAMP_S
        or arrow_type == ArrowType.TIMESTAMP_MS
        or arrow_type == ArrowType.TIMESTAMP_US
        or arrow_type == ArrowType.TIMESTAMP_NS
        or arrow_type == ArrowType.DURATION_S
        or arrow_type == ArrowType.DURATION_MS
        or arrow_type == ArrowType.DURATION_US
        or arrow_type == ArrowType.DURATION_NS
        or arrow_type == ArrowType.INTERVAL_DAY_TIME
    ):
        return 8
    if arrow_type == ArrowType.DECIMAL128:
        return 16
    if arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return 16
    if arrow_type == ArrowType.DECIMAL256:
        return 32
    return 0


def _take_fixed_width(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a fixed-width column at the given indices."""
    var elem = _bytes_for(src.arrow_type)
    if elem == 0:
        raise Error(
            "_take_fixed_width: arrow_type "
            + String(src.arrow_type)
            + " is not a fixed-width type"
        )
    var n_out = len(indices)
    var data_buf = OwnedAlignedBuffer(max(n_out * elem, 1))
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error(
                "_take_fixed_width: index " + String(i)
                + " out of range [0, " + String(src._length) + ")"
            )
        var src_off = (src._offset + i) * elem
        data_buf.view_range_mut(r * elem, elem).copy_from_view_at(
            0, src._data.view_range_ro(src_off, elem)
        )
    data_buf.set_length(Int64(n_out * elem))


    # Validity.
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    var out = Column[HeapRegion](
        arrow_type=src.arrow_type,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )
    # Decimal precision/scale propagation.
    if src.arrow_type == ArrowType.DECIMAL128 or src.arrow_type == ArrowType.DECIMAL256:
        out._decimal_p = src._decimal_p
        out._decimal_s = src._decimal_s
    return out^


def _take_bool(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a bit-packed BOOL column at the given indices.

    The BOOL sibling of `_take_fixed_width`, and the reason it cannot BE
    `_take_fixed_width`: there is no per-row byte width to stride by. Uses the
    shared indexed primitive `bitmap.gather_bits_aligned_buffer` — the same one
    the FILTER survivor gather, SORT's finalize gather and the JOIN gather use
    — rather than a private bit loop, because hand-copied width ladders drift
    apart.

    `src._offset + indices[r]` are BOTH bit indices; the primitive takes the
    column's `_offset` as `src_bit_offset` and the row list relative to it.
    """
    var n_out = len(indices)
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error(
                "_take_bool: index " + String(i)
                + " out of range [0, " + String(src._length) + ")"
            )

    var bm_bytes = (n_out + 7) >> 3
    var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
    data_buf.zero()
    if n_out > 0:
        gather_bits_aligned_buffer(data_buf, src._data, src._offset, indices)
    data_buf.set_length(Int64(bm_bytes))

    # Validity — byte-for-byte the same shape as `_take_fixed_width`'s.
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )


def _take_var_len_i32(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a STRING/BINARY column (Int32 offsets)."""
    if not src._offsets:
        raise Error(
            "_take_var_len_i32: column missing offsets (arrow_type="
            + String(src.arrow_type) + ")"
        )
    comptime int32_size = size_of[Int32]()
    var src_offsets_view = src._offsets.value().view_ro()
    var n_out = len(indices)

    # First pass: total bytes.
    var total_bytes = 0
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error("_take_var_len_i32: index out of range")
        var s = Int(src_offsets_view.get_typed[Int32](src._offset + i))
        var e = Int(src_offsets_view.get_typed[Int32](src._offset + i + 1))
        total_bytes += e - s

    var off_buf = OwnedAlignedBuffer((n_out + 1) * int32_size)
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    off_buf.set_typed[Int32](0, Int32(0))
    var dst_off = 0
    for r in range(n_out):
        var i = indices[r]
        var s = Int(src_offsets_view.get_typed[Int32](src._offset + i))
        var e = Int(src_offsets_view.get_typed[Int32](src._offset + i + 1))
        var ln = e - s
        if ln > 0:
            data_buf.view_range_mut(dst_off, ln).copy_from_view_at(
                0, src._data.view_range_ro(s, ln)
            )
        dst_off += ln
        off_buf.set_typed[Int32](r + 1, Int32(dst_off))
    off_buf.set_length(Int64((n_out + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    return Column[HeapRegion](
        arrow_type=src.arrow_type,
        data=data_buf^,
        offsets=off_buf^,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )


def _take_var_len_i64(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a LARGE_STRING/LARGE_BINARY column (Int64 offsets)."""
    if not src._offsets:
        raise Error(
            "_take_var_len_i64: column missing offsets (arrow_type="
            + String(src.arrow_type) + ")"
        )
    comptime int64_size = size_of[Int64]()
    var src_offsets_view = src._offsets.value().view_ro()
    var n_out = len(indices)

    var total_bytes = 0
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error("_take_var_len_i64: index out of range")
        var s = Int(src_offsets_view.get_typed[Int64](src._offset + i))
        var e = Int(src_offsets_view.get_typed[Int64](src._offset + i + 1))
        total_bytes += e - s

    var off_buf = OwnedAlignedBuffer((n_out + 1) * int64_size)
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    off_buf.set_typed[Int64](0, Int64(0))
    var dst_off = 0
    for r in range(n_out):
        var i = indices[r]
        var s = Int(src_offsets_view.get_typed[Int64](src._offset + i))
        var e = Int(src_offsets_view.get_typed[Int64](src._offset + i + 1))
        var ln = e - s
        if ln > 0:
            data_buf.view_range_mut(dst_off, ln).copy_from_view_at(
                0, src._data.view_range_ro(s, ln)
            )
        dst_off += ln
        off_buf.set_typed[Int64](r + 1, Int64(dst_off))
    off_buf.set_length(Int64((n_out + 1) * int64_size))

    data_buf.set_length(Int64(total_bytes))


    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    return Column[HeapRegion](
        arrow_type=src.arrow_type,
        data=data_buf^,
        offsets=off_buf^,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )


def _take_list(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a LIST or MAP column.  Rebuilds offsets + flattens
    the selected per-row sub-ranges of the inner values child.  Preserves
    the original arrow_type (so a MAP input stays MAP, not silently
    rewritten to LIST), plus MAP's `_keys_sorted` flag."""
    if src.num_children() != 1:
        raise Error(
            "_take_list: LIST/MAP column must have exactly 1 child, got "
            + String(src.num_children())
        )
    if not src._offsets:
        raise Error("_take_list: LIST/MAP column missing offsets buffer")

    comptime int32_size = size_of[Int32]()
    var src_off_view = src._offsets.value().view_ro()
    var n_out = len(indices)

    # Collect inner-value indices for each selected outer row.
    var inner_indices = List[Int]()
    var new_off = List[Int]()
    new_off.append(0)
    var running = 0
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error("_take_list: index out of range")
        var s = Int(src_off_view.get_typed[Int32](src._offset + i))
        var e = Int(src_off_view.get_typed[Int32](src._offset + i + 1))
        for k in range(s, e):
            inner_indices.append(k)
        running += (e - s)
        new_off.append(running)

    var off_buf = OwnedAlignedBuffer((n_out + 1) * int32_size)
    for r in range(n_out + 1):
        off_buf.set_typed[Int32](r, Int32(new_off[r]))
    off_buf.set_length(Int64((n_out + 1) * int32_size))


    # Gather the inner child by the collected inner_indices.
    ref child_ref = src.child_at(0)
    var new_child = _take_column_dispatch(child_ref, inner_indices)

    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    var out = Column[HeapRegion](
        arrow_type=src.arrow_type,  # preserves LIST vs MAP discrimination.
        data=OwnedAlignedBuffer(1),  # LIST/MAP has no data buffer; placeholder.
        offsets=off_buf^,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )
    out._data.set_length(0)

    var kids = Slab[Column[HeapRegion]].create(1)
    kids.append(new_child^)
    out._children = kids^
    # Preserve LIST/MAP field-name + MAP's `_keys_sorted` flag.
    for i in range(len(src._field_names)):
        out._field_names.append(src._field_names[i])
    out._keys_sorted = src._keys_sorted
    return out^


def _take_struct(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a STRUCT column — apply `indices` to every field."""
    var nf = src.num_children()
    var n_out = len(indices)
    var kids = Slab[Column[HeapRegion]].create(max(nf, 1))
    for c in range(nf):
        ref ch = src.child_at(c)
        kids.append(_take_column_dispatch(ch, indices))

    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if src._validity:
        var bm = Bitmap.create_all_valid(n_out)
        for r in range(n_out):
            if not src._validity.value().test(src._offset + indices[r]):
                bm.clear(r)
                null_count += 1
        validity = bm^

    var out = Column[HeapRegion](
        arrow_type=ArrowType.STRUCT,
        data=OwnedAlignedBuffer(1),
        offsets=None,
        validity=validity^,
        length=n_out,
        null_count=null_count,
        offset=0,
    )
    out._data.set_length(0)

    out._children = kids^
    for i in range(len(src._field_names)):
        out._field_names.append(src._field_names[i])
    return out^


def _take_column_dispatch(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Dispatch table for take across all supported child types.  Recursive
    for nested children."""
    var at = src.arrow_type
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        return _take_var_len_i32(src, indices)
    elif at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        return _take_var_len_i64(src, indices)
    elif at == ArrowType.LIST or at == ArrowType.MAP:
        return _take_list(src, indices)
    elif at == ArrowType.STRUCT:
        return _take_struct(src, indices)
    elif at == ArrowType.UNION_SPARSE or at == ArrowType.UNION_DENSE:
        # Recursive union: gather via the union-specific path.
        return take_union(src, indices)
    elif at == ArrowType.BOOL:
        # BIT-PACKED BOOL ARM. Without this arm BOOL would fall into
        # `_take_fixed_width`, which is a per-row BYTE copy — silent wrong bools,
        # not an error. See the note on `_bytes_for`.
        return _take_bool(src, indices)
    elif _bytes_for(at) > 0:
        return _take_fixed_width(src, indices)
    else:
        raise Error(
            "_take_column_dispatch: unsupported child arrow_type "
            + String(at)
            + " (supported: INT8..FLOAT64, DECIMAL128/256, INTERVAL_MDN, "
              "STRING, BINARY, LARGE_STRING, LARGE_BINARY, LIST, STRUCT, "
              "UNION_SPARSE, UNION_DENSE)"
        )


# =============================================================================
# Public: take_union, filter_union
# =============================================================================


def take_union(src: Column[HeapRegion], indices: List[Int]) raises -> Column[HeapRegion]:
    """Gather rows from a union Column[HeapRegion] by parent-row indices.

    Sparse: every child has parent-length, so gather types_buf + each child
    by the same `indices` list — direct.

    Dense: gather types_buf by `indices`; for each parent row at index r in
    the output, look at types_buf[indices[r]] to find its child slot c, and
    record indices[r]'s old child-offset (from src._offsets) into a per-c
    sub-index list.  Then gather child c by its sub-index list, and rewrite
    output offsets so out_offset[r] = running_count_of(c) - 1.
    """
    if (
        src.arrow_type != ArrowType.UNION_SPARSE
        and src.arrow_type != ArrowType.UNION_DENSE
    ):
        raise Error(
            "take_union: expected UNION_SPARSE/UNION_DENSE, got "
            + String(src.arrow_type)
        )
    var nchild = src.num_children()
    var n_out = len(indices)
    var is_dense = src.arrow_type == ArrowType.UNION_DENSE

    # Build types buffer for the output.
    comptime int8_size = size_of[Int8]()
    var types_buf = OwnedAlignedBuffer(max(n_out * int8_size, 1))
    for r in range(n_out):
        var i = indices[r]
        if i < 0 or i >= src._length:
            raise Error("take_union: index out of range")
        var t = src._data.get_typed[Int8](src._offset + i)
        types_buf.set_typed[Int8](r, t)
    types_buf.set_length(Int64(n_out * int8_size))


    # Sparse: every child gets the SAME indices list.
    if not is_dense:
        var kids = Slab[Column[HeapRegion]].create(max(nchild, 1))
        for c in range(nchild):
            ref ch = src.child_at(c)
            kids.append(_take_column_dispatch(ch, indices))
        var out = Column[HeapRegion](
            arrow_type=ArrowType.UNION_SPARSE,
            data=types_buf^,
            offsets=None,
            validity=None,
            length=n_out,
            null_count=0,
            offset=0,
        )
        out._children = kids^
        for i in range(len(src._type_ids)):
            out._type_ids.append(src._type_ids[i])
        return out^

    # Dense: per-child sub-index lists + offset rewrite.
    comptime int32_size = size_of[Int32]()
    if not src._offsets:
        raise Error("take_union: dense union missing offsets buffer")
    var src_off_view = src._offsets.value().view_ro()

    # Build per-child sub-index list (the child-row indices we'll gather).
    var per_child_subidx = List[List[Int]]()
    for _ in range(nchild):
        per_child_subidx.append(List[Int]())

    # Build the output offsets buffer (parent-row offset into the gathered
    # child).  out_offsets[r] = running count of child rows with this type-id.
    var out_off_buf = OwnedAlignedBuffer(max(n_out * int32_size, 1))

    # Map declared type-id -> child index for fast lookup.
    # _type_ids[c] = declared type-id for child c (length == nchild).
    for r in range(n_out):
        var i = indices[r]
        var t = Int(src._data.get_typed[Int8](src._offset + i))
        # Find child index for this declared type-id.
        var child_idx = -1
        for c in range(nchild):
            if src._type_ids[c] == t:
                child_idx = c
                break
        if child_idx < 0:
            raise Error(
                "take_union: parent row " + String(i) + " has type-id "
                + String(t) + " not in declared type-ids list"
            )
        var src_child_off = Int(
            src_off_view.get_typed[Int32](src._offset + i)
        )
        per_child_subidx[child_idx].append(src_child_off)
        var new_off = len(per_child_subidx[child_idx]) - 1
        out_off_buf.set_typed[Int32](r, Int32(new_off))
    out_off_buf.set_length(Int64(n_out * int32_size))


    # Gather each child by its sub-index list.
    var kids = Slab[Column[HeapRegion]].create(max(nchild, 1))
    for c in range(nchild):
        ref ch = src.child_at(c)
        kids.append(_take_column_dispatch(ch, per_child_subidx[c]))

    var out = Column[HeapRegion](
        arrow_type=ArrowType.UNION_DENSE,
        data=types_buf^,
        offsets=out_off_buf^,
        validity=None,
        length=n_out,
        null_count=0,
        offset=0,
    )
    out._children = kids^
    for i in range(len(src._type_ids)):
        out._type_ids.append(src._type_ids[i])
    return out^


def filter_union(src: Column[HeapRegion], mask: Bitmap[HeapRegion]) raises -> Column[HeapRegion]:
    """Apply a boolean mask to a union Column.  Reduces to take_union
    via index materialization (the standard kernel-cookbook
    `filter == take_by_mask_indices` shape — see filter_interval_mdn)."""
    if mask.length != src._length:
        raise Error(
            "filter_union: mask length " + String(mask.length)
            + " != source length " + String(src._length)
        )
    var indices = List[Int]()
    for i in range(src._length):
        if mask.test(i):
            indices.append(i)
    return take_union(src, indices)


# =============================================================================
# Public: hash_union
# =============================================================================


@always_inline
def _mix64_type_id(t: Int) -> UInt64:
    """Single-step bit-mix on the discriminator type-id.  Spreads bits so
    `hash_child XOR mix64(t)` doesn't collide across (child_value, type_id)
    pairs.  Modeled after splitmix64 finalizer; one round is sufficient for
    the small-cardinality (0..127) Int8 type-id space."""
    var x = UInt64(t) + UInt64(0x9E3779B97F4A7C15)
    x = (x ^ (x >> 30)) * UInt64(0xBF58476D1CE4E5B5)
    x = (x ^ (x >> 27)) * UInt64(0x94D049BB133111EB)
    return x ^ (x >> 31)


def _hash_one_row(col: Column[HeapRegion], row: Int) raises -> UInt64:
    """Hash one row of a child Column[HeapRegion] to a UInt64.  Null rows hash to 0
    (consistent with the rest of the agg infra — see hash_interval_mdn).
    Recursive on nested children."""
    var at = col.arrow_type
    if col._validity:
        if not col._validity.value().test(col._offset + row):
            return UInt64(0)
    if at == ArrowType.BOOL:
        # BIT-PACKED BOOL ARM. BOOL must NOT fold into the INT8/UINT8 arm below:
        # for INT8 `get_typed[UInt8](_offset + row)` IS row `row`, but for BOOL it
        # is BYTE `row` of a buffer holding `(n + 7) >> 3` bytes whose `_offset`
        # is a BIT index. Row 0 would hash the whole first byte (not 0 or 1), rows
        # in different bytes would hash apart even when their bits were EQUAL, and
        # rows past `(n + 7) >> 3` would read off the end, with nothing raised.
        # `hash_struct_column` is the surface `agg_struct` uses for
        # `GROUP BY <struct>`, so one group would scatter across up to eight, and
        # `eq_struct_at` could not repair it — rows that hash apart never meet.
        if read_bit_aligned_buffer(col._data, col._offset + row):
            return UInt64(1)
        return UInt64(0)
    if at == ArrowType.INT8 or at == ArrowType.UINT8:
        return UInt64(UInt8(col._data.get_typed[UInt8](col._offset + row)))
    if at == ArrowType.INT16 or at == ArrowType.UINT16 or at == ArrowType.FLOAT16:
        return UInt64(UInt16(col._data.get_typed[UInt16](col._offset + row)))
    if at == ArrowType.INT32 or at == ArrowType.UINT32 or at == ArrowType.FLOAT32 \
        or at == ArrowType.DATE32 or at == ArrowType.TIME32_S \
        or at == ArrowType.TIME32_MS or at == ArrowType.INTERVAL_YEAR_MONTH:
        return UInt64(UInt32(col._data.get_typed[UInt32](col._offset + row)))
    if at == ArrowType.INT64 or at == ArrowType.UINT64 or at == ArrowType.FLOAT64 \
        or at == ArrowType.DATE64 or at == ArrowType.TIME64_US \
        or at == ArrowType.TIME64_NS or at == ArrowType.TIMESTAMP \
        or at == ArrowType.TIMESTAMP_S or at == ArrowType.TIMESTAMP_MS \
        or at == ArrowType.TIMESTAMP_US or at == ArrowType.TIMESTAMP_NS \
        or at == ArrowType.DURATION_S or at == ArrowType.DURATION_MS \
        or at == ArrowType.DURATION_US or at == ArrowType.DURATION_NS \
        or at == ArrowType.INTERVAL_DAY_TIME:
        return UInt64(col._data.get_typed[UInt64](col._offset + row))
    if at == ArrowType.DECIMAL128:
        var base = (col._offset + row) * DECIMAL128_BYTE_WIDTH
        var lo = UInt64(col._data.read_i64_le_at(base))
        var hi = UInt64(col._data.read_i64_le_at(base + 8))
        return lo ^ _mix64_type_id(Int(hi))
    if at == ArrowType.INTERVAL_MONTH_DAY_NANO:
        var base = (col._offset + row) * INTERVAL_MDN_BYTE_WIDTH
        var m = col._data.read_i32_le_at(base)
        var d = col._data.read_i32_le_at(base + 4)
        var n = col._data.read_i64_le_at(base + 8)
        return hash_one_interval_mdn(m, d, n)
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        if not col._offsets:
            raise Error("_hash_one_row: STRING/BINARY missing offsets")
        var ov = col._offsets.value().view_ro()
        var s = Int(ov.get_typed[Int32](col._offset + row))
        var e = Int(ov.get_typed[Int32](col._offset + row + 1))
        # FNV-1a 64-bit over the byte slice.
        var h = UInt64(0xCBF29CE484222325)
        for k in range(s, e):
            h = (h ^ UInt64(col._data.get_typed[UInt8](k))) * UInt64(0x100000001B3)
        return h
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        if not col._offsets:
            raise Error("_hash_one_row: LARGE_STRING/BINARY missing offsets")
        var ov = col._offsets.value().view_ro()
        var s = Int(ov.get_typed[Int64](col._offset + row))
        var e = Int(ov.get_typed[Int64](col._offset + row + 1))
        var h = UInt64(0xCBF29CE484222325)
        for k in range(s, e):
            h = (h ^ UInt64(col._data.get_typed[UInt8](k))) * UInt64(0x100000001B3)
        return h
    if at == ArrowType.STRUCT:
        # Combine field hashes (FNV-1a over per-field UInt64s).
        var h = UInt64(0xCBF29CE484222325)
        for c in range(col.num_children()):
            ref ch = col.child_at(c)
            var fh = _hash_one_row(ch, row)
            # Mix 8 bytes of `fh` byte-by-byte through FNV-1a.
            for b in range(8):
                h = (h ^ ((fh >> UInt64(b * 8)) & UInt64(0xFF))) * UInt64(0x100000001B3)
        return h
    if at == ArrowType.LIST:
        # Hash list = FNV-1a over each element's hash.
        if not col._offsets:
            raise Error("_hash_one_row: LIST missing offsets")
        var ov = col._offsets.value().view_ro()
        var s = Int(ov.get_typed[Int32](col._offset + row))
        var e = Int(ov.get_typed[Int32](col._offset + row + 1))
        ref ch = col.child_at(0)
        var h = UInt64(0xCBF29CE484222325)
        for k in range(s, e):
            var fh = _hash_one_row(ch, k)
            for b in range(8):
                h = (h ^ ((fh >> UInt64(b * 8)) & UInt64(0xFF))) * UInt64(0x100000001B3)
        return h
    raise Error(
        "_hash_one_row: unsupported child arrow_type "
        + String(at)
    )


def hash_union(src: Column[HeapRegion]) raises -> List[UInt64]:
    """Per-row hash of a union Column.  hash(value) = hash_child(child_row)
    XOR mix64(type_id), so two unions whose i-th rows carry DIFFERENT
    type-ids (with the same byte payload) hash to (effectively) different
    values.

    Sparse: child_row == parent_row.
    Dense:  child_row == offsets[parent_row].
    """
    if (
        src.arrow_type != ArrowType.UNION_SPARSE
        and src.arrow_type != ArrowType.UNION_DENSE
    ):
        raise Error(
            "hash_union: expected UNION_SPARSE/UNION_DENSE, got "
            + String(src.arrow_type)
        )
    var n = src._length
    var nchild = src.num_children()
    var is_dense = src.arrow_type == ArrowType.UNION_DENSE
    var out = List[UInt64](capacity=n)
    for r in range(n):
        var t = Int(src._data.get_typed[Int8](src._offset + r))
        # Find child index for declared type-id t.
        var child_idx = -1
        for c in range(nchild):
            if src._type_ids[c] == t:
                child_idx = c
                break
        if child_idx < 0:
            raise Error(
                "hash_union: row " + String(r) + " has type-id "
                + String(t) + " not in declared type-ids list"
            )
        var child_row: Int
        if is_dense:
            if not src._offsets:
                raise Error("hash_union: dense union missing offsets")
            child_row = Int(
                src._offsets.value().view_ro().get_typed[Int32](
                    src._offset + r
                )
            )
        else:
            child_row = r
        ref ch = src.child_at(child_idx)
        var h_child = _hash_one_row(ch, child_row)
        out.append(h_child ^ _mix64_type_id(t))
    return out^


# =============================================================================
# Public: eval_eq_union
# =============================================================================


def _eq_at(a: Column[HeapRegion], ai: Int, b: Column[HeapRegion], bi: Int) raises -> Bool:
    """Per-row element equality across two SAME-typed Columns.  Returns
    False if either row is null (matches the Arrow eq-with-nulls semantics
    used elsewhere — null != null)."""
    if a.arrow_type != b.arrow_type:
        return False
    if a._validity:
        if not a._validity.value().test(a._offset + ai):
            return False
    if b._validity:
        if not b._validity.value().test(b._offset + bi):
            return False
    var at = a.arrow_type
    if at == ArrowType.BOOL:
        # BIT-PACKED BOOL ARM. BOOL must not fall into the `w > 0` bytewise
        # compare below: comparing BYTE `offset + i` of two bitmaps as though it
        # were row i compares eight rows' worth of bits at once, and rows past the
        # first `(n + 7) >> 3` read off the end. It rides the shared
        # `bitmap.read_bit_aligned_buffer`, the scalar sibling of the
        # `gather_bits_aligned_buffer` the take path uses, rather than inlining its
        # own `>> 3` / `& 7` arithmetic.
        return read_bit_aligned_buffer(
            a._data, a._offset + ai
        ) == read_bit_aligned_buffer(b._data, b._offset + bi)
    var w = _bytes_for(at)
    if w > 0:
        # Fixed-width: bytewise compare.
        for k in range(w):
            var av = a._data.get_typed[UInt8]((a._offset + ai) * w + k)
            var bv = b._data.get_typed[UInt8]((b._offset + bi) * w + k)
            if av != bv:
                return False
        return True
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        if not a._offsets or not b._offsets:
            raise Error("_eq_at: STRING/BINARY missing offsets")
        var aov = a._offsets.value().view_ro()
        var bov = b._offsets.value().view_ro()
        var as_ = Int(aov.get_typed[Int32](a._offset + ai))
        var ae = Int(aov.get_typed[Int32](a._offset + ai + 1))
        var bs = Int(bov.get_typed[Int32](b._offset + bi))
        var be = Int(bov.get_typed[Int32](b._offset + bi + 1))
        if (ae - as_) != (be - bs):
            return False
        for k in range(ae - as_):
            if a._data.get_typed[UInt8](as_ + k) != b._data.get_typed[UInt8](bs + k):
                return False
        return True
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        if not a._offsets or not b._offsets:
            raise Error("_eq_at: LARGE_STRING/BINARY missing offsets")
        var aov = a._offsets.value().view_ro()
        var bov = b._offsets.value().view_ro()
        var as_ = Int(aov.get_typed[Int64](a._offset + ai))
        var ae = Int(aov.get_typed[Int64](a._offset + ai + 1))
        var bs = Int(bov.get_typed[Int64](b._offset + bi))
        var be = Int(bov.get_typed[Int64](b._offset + bi + 1))
        if (ae - as_) != (be - bs):
            return False
        for k in range(ae - as_):
            if a._data.get_typed[UInt8](as_ + k) != b._data.get_typed[UInt8](bs + k):
                return False
        return True
    if at == ArrowType.STRUCT:
        if a.num_children() != b.num_children():
            return False
        for c in range(a.num_children()):
            ref ac = a.child_at(c)
            ref bc = b.child_at(c)
            if not _eq_at(ac, ai, bc, bi):
                return False
        return True
    if at == ArrowType.LIST:
        if not a._offsets or not b._offsets:
            raise Error("_eq_at: LIST missing offsets")
        var aov = a._offsets.value().view_ro()
        var bov = b._offsets.value().view_ro()
        var as_ = Int(aov.get_typed[Int32](a._offset + ai))
        var ae = Int(aov.get_typed[Int32](a._offset + ai + 1))
        var bs = Int(bov.get_typed[Int32](b._offset + bi))
        var be = Int(bov.get_typed[Int32](b._offset + bi + 1))
        if (ae - as_) != (be - bs):
            return False
        ref ac = a.child_at(0)
        ref bc = b.child_at(0)
        for k in range(ae - as_):
            if not _eq_at(ac, as_ + k, bc, bs + k):
                return False
        return True
    raise Error(
        "_eq_at: unsupported child arrow_type " + String(at)
    )


def eval_eq_union(a: Column[HeapRegion], b: Column[HeapRegion]) raises -> Bitmap[HeapRegion]:
    """Per-row equality across two union Columns.  Returns a Bitmap with
    `result.test(i) == True` iff:
        (1) a.types_buf[i] == b.types_buf[i]  (same discriminator), AND
        (2) the children selected by those type-ids are element-equal at
            a's child_row vs b's child_row (sparse: child_row==i; dense:
            child_row==offsets[i]).
    Per the Arrow spec, two unions whose i-th rows have DIFFERENT
    type-ids are NEVER equal at row i, regardless of value bytes."""
    if (
        a.arrow_type != ArrowType.UNION_SPARSE and a.arrow_type != ArrowType.UNION_DENSE
    ) or (
        b.arrow_type != ArrowType.UNION_SPARSE and b.arrow_type != ArrowType.UNION_DENSE
    ):
        raise Error("eval_eq_union: both inputs must be UNION_*")
    if a._length != b._length:
        raise Error(
            "eval_eq_union: length mismatch: " + String(a._length)
            + " vs " + String(b._length)
        )
    if a.arrow_type != b.arrow_type:
        raise Error("eval_eq_union: sparse vs dense mismatch")
    if a.num_children() != b.num_children():
        raise Error("eval_eq_union: child count mismatch")
    var a_is_dense = a.arrow_type == ArrowType.UNION_DENSE
    var n = a._length
    var out = Bitmap.create(n)
    for r in range(n):
        var ta = Int(a._data.get_typed[Int8](a._offset + r))
        var tb = Int(b._data.get_typed[Int8](b._offset + r))
        if ta != tb:
            continue
        # Same type-id; find both child slots.
        var ac_idx = -1
        var bc_idx = -1
        for c in range(a.num_children()):
            if a._type_ids[c] == ta:
                ac_idx = c
                break
        for c in range(b.num_children()):
            if b._type_ids[c] == tb:
                bc_idx = c
                break
        if ac_idx < 0 or bc_idx < 0:
            continue  # one side has the type-id mapped, the other doesn't.
        var a_child_row: Int
        var b_child_row: Int
        if a_is_dense:
            if not a._offsets:
                raise Error("eval_eq_union: dense union a missing offsets")
            if not b._offsets:
                raise Error("eval_eq_union: dense union b missing offsets")
            a_child_row = Int(
                a._offsets.value().view_ro().get_typed[Int32](a._offset + r)
            )
            b_child_row = Int(
                b._offsets.value().view_ro().get_typed[Int32](b._offset + r)
            )
        else:
            a_child_row = r
            b_child_row = r
        ref ac = a.child_at(ac_idx)
        ref bc = b.child_at(bc_idx)
        if _eq_at(ac, a_child_row, bc, b_child_row):
            out.set(r)
    return out^


# =============================================================================
# Public: STRUCT composite-key hash + equality
# =============================================================================
# These are the surface for STRUCT-keyed GROUP BY (`df.group_by("addr").agg(...)`
# where `addr` is a STRUCT column).  The hash-aggregate key dispatch
# routes STRUCT keys through this composite-hash + composite-eq pair:
#   (a) `hash_struct_column` produces one UInt64 per row by FNV-1a-mixing
#       each child's per-row hash (recursive via `_hash_one_row`).
#   (b) `eq_struct_at` returns True iff every child's row matches per
#       Arrow's eq-with-nulls (which propagates NULL through eq as False —
#       matching the engine's GROUP-BY-null behavior on STRING keys).
# Both functions delegate to the union dispatch's `_hash_one_row` /
# `_eq_at` arms, so the STRUCT-arm-recursive semantics (NULL struct → 0,
# struct-of-NULLs → mix of zeros) are identical to the union dispatch.


def hash_struct_column(col: Column[HeapRegion]) raises -> List[UInt64]:
    """Per-row hash of a STRUCT column.  Each row's hash combines the
    per-row hashes of every child via FNV-1a.

    Null row (parent validity = 0): returns 0 (matches the engine's null-hash
    convention).  This means a NULL struct and any struct whose children
    all hash to 0 may collide; collision is resolved by `eq_struct_at`
    on the consumer side, which returns False on NULL on either side.
    """
    if col.arrow_type != ArrowType.STRUCT:
        raise Error(
            "hash_struct_column: expected STRUCT, got "
            + String(col.arrow_type)
        )
    var n = col._length
    var out = List[UInt64](capacity=n)
    for r in range(n):
        out.append(_hash_one_row(col, r))
    return out^


@always_inline
def eq_struct_at(a: Column[HeapRegion], ai: Int, b: Column[HeapRegion], bi: Int) raises -> Bool:
    """Per-row equality across two STRUCT columns.  Returns True iff
    every child's row is element-equal per Arrow eq-with-nulls.

    Constraints:
      - both columns MUST be STRUCT with identical child count.
      - NULL row on either side returns False (matches existing
        GROUP-BY-on-STRING null behavior).
    """
    if a.arrow_type != ArrowType.STRUCT or b.arrow_type != ArrowType.STRUCT:
        raise Error("eq_struct_at: both inputs must be STRUCT")
    return _eq_at(a, ai, b, bi)
