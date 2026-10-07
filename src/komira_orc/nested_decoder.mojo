# =============================================================================
# nested_decoder.mojo — ORC compound-type decode -> Arrow nested Column.
# =============================================================================
#
# column_decoder.mojo decodes PRIMITIVE top-level columns into a flat
# `ColumnAcc` accumulated across stripes. This module adds the 4 ORC compound types
# — STRUCT / LIST / MAP / UNION — which are RECURSIVE: a compound column owns
# child column subtrees (by schema-tree index link), and the decode is a
# depth-first descent that composes Arrow nested arrays bottom-up.
#
# The unit of work here is ONE stripe (the multi-stripe primitive accumulator
# path in column_decoder.mojo is separate).
# `decode_column_subtree` returns a fully-materialized Arrow `Column` for a
# schema node and its descendants:
#
#   - PRIMITIVE leaf  -> reuse the column_decoder ColumnAcc machinery (one stripe).
#   - STRUCT          -> PRESENT (struct-level validity) + recurse each child;
#                        assemble a StructArray. ORC struct children carry the
#                        FULL stripe row-count (the PRESENT bitmap only nulls
#                        rows, it does NOT shorten the children — unlike LIST).
#   - LIST            -> PRESENT + LENGTH (per-element length, RLE) + recurse
#                        the single child with n_rows = sum(lengths). Build the
#                        Arrow offsets via O(N) prefix-sum.
#   - MAP             -> PRESENT + LENGTH + recurse KEY child + VALUE child
#                        (both with n_rows = sum(lengths)); assemble a MapArray.
#   - UNION           -> PRESENT + DATA (byte-RLE tag stream, per-row 0..N-1) +
#                        recurse N branch children. ORC unions are tagged-DENSE
#                        on the wire: child i holds values ONLY for rows where
#                        tag==i, so child_n_rows[i] = popcount(tag==i). Build an
#                        Arrow Dense Union (type_ids = tags, offsets = running
#                        per-child counter). Sparse mapping is selected at the
#                        schema layer via arrow.orc.union_mode; the wire decode
#                        is always dense.
#
# Stream resolution: every schema node has a stable column id == its index in
# the flat Footer.types list. Located streams are passed as 4 parallel lists
# (kind/column/start/end) — the flat-arena form, no back-import cycle with
# orc_reader's `_StreamLoc`.
#
# Encapsulation: consumes borrowed Span byte views + located stream spans;
# returns an owned Arrow Column. No UnsafePointer crosses the module boundary.
# Recursion is over schema-tree INDICES (flat arena), never recursive structs.
# =============================================================================

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.list_array import ListArray
from komira_arrow.map_array import MapArray
from komira_arrow.struct_array import StructArray
from komira_arrow.union_array import UnionArray
from komira_collections.slab import Slab

from std.sys import size_of

from .footer import (
    StripeFooter,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY_V2,
)
from .orc_schema import (
    OrcSchema,
    orc_node_to_arrow,
    orc_kind_name,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_STRUCT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
)
from .rle_decode import decode_int_rle, decode_byte_rle
from .column_decoder import (
    StreamSpan,
    ColumnAcc,
    ORC_MAX_ROWS,
    make_accumulator,
    decode_stripe_column,
    _find_stream,
    _decode_present,
    _count_true,
    _check_lengths_non_negative,
)


# =============================================================================
# Small result structs (Mojo 1.0.0b1 tuple-return init is fiddly; named
# structs keep the position threading explicit and pointer-free).
# =============================================================================


@fieldwise_init
struct _Encoding(Copyable, Movable):
    var kind: Int
    var dictionary_size: Int




# =============================================================================
# Stream gathering (flat-arena parallel-list form).
# =============================================================================


def _gather_streams_for_column(
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    col_id: Int,
    codec: Int,
    block_size: Int,
) raises -> List[StreamSpan]:
    """Collect+decompress every (non-index) data stream for `col_id`."""
    from .footer import (
        ORC_STREAM_ROW_INDEX,
        ORC_STREAM_BLOOM_FILTER,
        ORC_STREAM_BLOOM_FILTER_UTF8,
    )
    from .orc_codec import decompress_stream

    var out = List[StreamSpan]()
    for i in range(len(locs_kind)):
        if locs_col[i] != col_id:
            continue
        var k = locs_kind[i]
        if (
            k == ORC_STREAM_ROW_INDEX
            or k == ORC_STREAM_BLOOM_FILTER
            or k == ORC_STREAM_BLOOM_FILTER_UTF8
        ):
            continue
        var raw = file_bytes[locs_start[i] : locs_end[i]]
        var decompressed = decompress_stream(raw, codec, block_size)
        out.append(StreamSpan(k, decompressed^))
    return out^


def _encoding_for(sf: StripeFooter, col_id: Int) raises -> _Encoding:
    """Return the ColumnEncoding (kind, dictionary_size) for column `col_id`."""
    if col_id >= len(sf.columns):
        raise Error(
            "OrcDecodeError.MISSING_ENCODING: column id "
            + String(col_id)
            + " has no ColumnEncoding entry"
        )
    var e = sf.columns[col_id].copy()
    return _Encoding(e.kind, e.dictionary_size)


@always_inline
def _is_v2(enc_kind: Int) -> Bool:
    return (
        enc_kind == ORC_ENCODING_DIRECT_V2
        or enc_kind == ORC_ENCODING_DICTIONARY_V2
    )


# =============================================================================
# Validity helpers.
# =============================================================================


@always_inline
def _null_count(present: List[Bool]) -> Int:
    var nc = 0
    for i in range(len(present)):
        if not present[i]:
            nc += 1
    return nc


def _validity_bitmap(present: List[Bool]) raises -> Optional[Bitmap[HeapRegion]]:
    """Build a validity Bitmap (None if all-present). Caller owns the result
    as a fresh local, so it can be moved out with `^` (no partial-move-out-of-
    struct hazard)."""
    if _null_count(present) == 0:
        return Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create_all_valid(len(present))
    for i in range(len(present)):
        if not present[i]:
            bm.clear(i)
    return Optional[Bitmap[HeapRegion]](bm^)


def _present_for_node(
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> List[Bool]:
    """Decode the PRESENT (validity) stream for a node, or all-present."""
    var streams = _gather_streams_for_column(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size,
    )
    return _decode_present(streams, n_rows)


# =============================================================================
# Primitive leaf decode -> Column (single stripe, via column_decoder's ColumnAcc).
# =============================================================================


def _decode_primitive_column(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """Decode one PRIMITIVE schema node into an Arrow Column[HeapRegion] for one stripe."""
    var node = schema.node(node_idx)
    var at = orc_node_to_arrow(schema, node_idx)
    var acc = make_accumulator(node.kind, at)
    var enc = _encoding_for(sf, node_idx)
    var streams = _gather_streams_for_column(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size,
    )
    decode_stripe_column(
        acc, node.kind, enc.kind, enc.dictionary_size, streams, n_rows
    )
    return acc^.build()


@always_inline
def _is_primitive_kind(kind: Int) -> Bool:
    return (
        kind == ORC_KIND_BOOLEAN
        or kind == ORC_KIND_BYTE
        or kind == ORC_KIND_SHORT
        or kind == ORC_KIND_INT
        or kind == ORC_KIND_LONG
        or kind == ORC_KIND_FLOAT
        or kind == ORC_KIND_DOUBLE
        or kind == ORC_KIND_STRING
        or kind == ORC_KIND_BINARY
        or kind == ORC_KIND_DATE
        or kind == ORC_KIND_VARCHAR
        or kind == ORC_KIND_CHAR
    )


# =============================================================================
# Recursive subtree decode.
# =============================================================================


def decode_column_subtree(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """Decode schema node `node_idx` (and its descendants) into an Arrow
    Column for one stripe. `n_rows` is the number of logical rows THIS node
    spans (== the parent's element count for a child of LIST/MAP/UNION)."""
    var kind = schema.node(node_idx).kind

    if _is_primitive_kind(kind):
        return _decode_primitive_column(
            schema, node_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )
    elif kind == ORC_KIND_STRUCT:
        return _decode_struct(
            schema, node_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )
    elif kind == ORC_KIND_LIST:
        return _decode_list(
            schema, node_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )
    elif kind == ORC_KIND_MAP:
        return _decode_map(
            schema, node_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )
    elif kind == ORC_KIND_UNION:
        return _decode_union(
            schema, node_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )

    raise Error(
        String("OrcDecodeError.UNSUPPORTED_TYPE: ORC Type.Kind ")
        + orc_kind_name(kind)
        + " in nested decode"
    )


# =============================================================================
# STRUCT.
# =============================================================================


def _decode_struct(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """STRUCT: struct-level PRESENT validity + recurse each child at full
    n_rows. ORC struct children are NOT shortened by the struct's null bitmap
    — every child column still carries `n_rows` values."""
    var node = schema.node(node_idx)
    var present = _present_for_node(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, n_rows,
    )
    var validity = _validity_bitmap(present)
    var nc = _null_count(present)

    var nfields = len(node.subtypes)
    var kids = Slab[Column[HeapRegion]].create(max(nfields, 1))
    var names = List[String]()
    for i in range(nfields):
        var child_idx = node.subtypes[i]
        var child_col = decode_column_subtree(
            schema, child_idx, sf, locs_kind, locs_col, locs_start, locs_end,
            file_bytes, codec, block_size, n_rows,
        )
        kids.append(child_col^)
        if i < len(node.field_names):
            names.append(node.field_names[i])
        else:
            names.append(String("_col") + String(i))

    var sa = StructArray._build(
        names, nfields, n_rows, kids^, validity^, nc
    )
    return Column.from_struct(sa^)


# =============================================================================
# LIST / MAP shared helpers.
# =============================================================================


def _decode_length_stream(
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    sf: StripeFooter,
    n_present: Int,
) raises -> List[Int64]:
    """Decode the per-element LENGTH stream (unsigned RLE) for a LIST/MAP node.
    Holds one entry per PRESENT (non-null) parent row."""
    var streams = _gather_streams_for_column(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size,
    )
    var lidx = _find_stream(streams, ORC_STREAM_LENGTH)
    if lidx < 0:
        raise Error(
            "OrcDecodeError.MISSING_LENGTH: LIST/MAP node "
            + String(node_idx)
            + " has no LENGTH stream"
        )
    var enc = _encoding_for(sf, node_idx)
    var lens = decode_int_rle(
        streams[lidx].bytes, n_present, False, _is_v2(enc.kind)
    )
    # LIST/MAP element counts are decoded as UNSIGNED RLE into Int64, so a
    # bit-width-64 DIRECT run yields an arbitrary pattern — negative as an
    # Int64. Those propagate straight into the CHILD subtree's `n_rows` (via the
    # `total_child` / `total_entries` sums in `_decode_list` / `_decode_map`) and
    # into `_build_offsets_i32`. One branchless pass here, at the single place
    # LIST/MAP lengths enter the decoder, covers both consumers. Mirrors
    # `column_decoder._decode_lengths`.
    #
    # Call the shared helper; do not re-inline the loop. Copies of one
    # invariant drift, and a LENGTH decoder that misses it is a bounds bug.
    _check_lengths_non_negative(lens)
    return lens^


@always_inline
def _check_child_total(total: Int, node_idx: Int, what: StringSlice) raises:
    """Bound a LIST/MAP child element count before it becomes an allocation.

    `total` is the sum of writer-chosen per-row element counts. It is passed as
    the child subtree's `n_rows` AND ends up as the final Arrow offset, so the
    Arrow Int32 offsets type is the honest ceiling.
    """
    if total < 0 or total > Int(Int32.MAX):
        raise Error(
            String("OrcDecodeError.OFFSET_OVERFLOW: ")
            + String(what)
            + " node "
            + String(node_idx)
            + " declares "
            + String(total)
            + " child elements, outside the [0, "
            + String(Int(Int32.MAX))
            + "] an Arrow Int32 offsets buffer can address"
        )


def _build_offsets_i32(lengths_per_row: List[Int]) raises -> OwnedAlignedBuffer:
    """Build an Arrow N+1 Int32 offsets buffer via prefix-sum of per-row
    element counts. offsets[0]=0; offsets[i+1]=offsets[i]+lengths[i].

    ⚠ THE Int32 CEILING IS A REAL BOUNDARY, NOT A CAST.

    `Int32(acc)` would TRUNCATE silently. With writer-chosen element counts
    that produces an Arrow ListArray whose offsets exceed its own child length —
    a well-formed-looking array that every later reader dereferences out of
    bounds. Same Int32-offset ceiling as LARGE_STRING; the honest answer is to
    refuse, not to wrap.

    The check is inside the prefix-sum loop because that is where `acc` exists;
    it is one compare against a constant per row, and it short-circuits.
    """
    comptime int32_size = size_of[Int32]()
    var n = len(lengths_per_row)
    var buf = OwnedAlignedBuffer(max((n + 1) * int32_size, 1))
    buf.set_typed[Int32](0, Int32(0))
    var acc = 0
    for i in range(n):
        acc += lengths_per_row[i]
        if acc > Int(Int32.MAX):
            raise Error(
                String("OrcDecodeError.OFFSET_OVERFLOW: LIST/MAP child offsets")
                + " reach "
                + String(acc)
                + " at row "
                + String(i)
                + ", past the Int32 ceiling "
                + String(Int(Int32.MAX))
                + " of an Arrow ListArray offsets buffer"
            )
        buf.set_typed[Int32](i + 1, Int32(acc))
    buf.set_length(Int64((n + 1) * int32_size))

    return buf^


def _per_row_lengths(present: List[Bool], dense_lengths: List[Int64]) -> List[Int]:
    """Expand dense (present-only) per-element lengths into a per-ROW list:
    a null row contributes length 0 (its child span is empty)."""
    var out = List[Int]()
    var vi = 0
    for i in range(len(present)):
        if present[i]:
            out.append(Int(dense_lengths[vi]))
            vi += 1
        else:
            out.append(0)
    return out^


# =============================================================================
# LIST.
# =============================================================================


def _decode_list(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """LIST: PRESENT + per-element LENGTH + single child column. Child spans
    sum(lengths) rows; offsets are prefix-sum of per-row lengths."""
    var node = schema.node(node_idx)
    if len(node.subtypes) < 1:
        raise Error("OrcDecodeError.MALFORMED: LIST node has no child")
    var present = _present_for_node(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, n_rows,
    )
    var n_present = _count_true(present)
    var dense_lengths = _decode_length_stream(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, sf, n_present,
    )
    var row_lengths = _per_row_lengths(present, dense_lengths)
    var total_child = 0
    for i in range(len(row_lengths)):
        total_child += row_lengths[i]
    # The sum of per-row element counts becomes the CHILD subtree's `n_rows` —
    # i.e. it drives the child's allocations — and it becomes the last Arrow
    # offset. Bound it BEFORE recursing rather than at `_build_offsets_i32`,
    # which runs after the child decode has already allocated. The bound is the
    # Arrow ListArray offsets type, not an arbitrary policy number: an Int32
    # offsets buffer cannot address past `Int32.MAX` elements.
    _check_child_total(total_child, node_idx, "LIST")

    var child_col = decode_column_subtree(
        schema, node.subtypes[0], sf, locs_kind, locs_col, locs_start,
        locs_end, file_bytes, codec, block_size, total_child,
    )

    var offsets = _build_offsets_i32(row_lengths)
    var validity = _validity_bitmap(present)
    var nc = _null_count(present)
    var la = ListArray[HeapRegion](
        offsets=offsets^,
        child=child_col^,
        validity=validity^,
        length=n_rows,
        null_count=nc,
    )
    return Column.from_list(la^)


# =============================================================================
# MAP.
# =============================================================================


def _decode_map(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """MAP: PRESENT + per-element LENGTH + KEY child + VALUE child. Both
    children span sum(lengths) entries (parallel keys/values arrays)."""
    var node = schema.node(node_idx)
    if len(node.subtypes) < 2:
        raise Error("OrcDecodeError.MALFORMED: MAP node needs key + value child")
    var present = _present_for_node(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, n_rows,
    )
    var n_present = _count_true(present)
    var dense_lengths = _decode_length_stream(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, sf, n_present,
    )
    var row_lengths = _per_row_lengths(present, dense_lengths)
    var total_entries = 0
    for i in range(len(row_lengths)):
        total_entries += row_lengths[i]
    # As `_decode_list`: bound the child row count before it becomes two child
    # subtree allocations (keys + values).
    _check_child_total(total_entries, node_idx, "MAP")

    var keys_col = decode_column_subtree(
        schema, node.subtypes[0], sf, locs_kind, locs_col, locs_start,
        locs_end, file_bytes, codec, block_size, total_entries,
    )
    var values_col = decode_column_subtree(
        schema, node.subtypes[1], sf, locs_kind, locs_col, locs_start,
        locs_end, file_bytes, codec, block_size, total_entries,
    )

    var offsets = _build_offsets_i32(row_lengths)
    var validity = _validity_bitmap(present)
    var nc = _null_count(present)
    var ma = MapArray[HeapRegion](
        offsets=offsets^,
        keys=keys_col^,
        values=values_col^,
        validity=validity^,
        length=n_rows,
        null_count=nc,
        keys_sorted=False,
    )
    return Column.from_map(ma^)


# =============================================================================
# UNION (tagged-dense on the wire -> Arrow Dense Union).
# =============================================================================


def _decode_union(
    schema: OrcSchema,
    node_idx: Int,
    sf: StripeFooter,
    locs_kind: List[Int],
    locs_col: List[Int],
    locs_start: List[Int],
    locs_end: List[Int],
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> Column[HeapRegion]:
    """UNION: PRESENT + DATA (byte-RLE tag stream) + N branch children. Child
    `i` holds values ONLY for rows where tag==i (tagged-dense). Reconstruct the
    Arrow Dense Union: type_ids = per-row tag, offsets = running per-child
    counter. Null parent rows (PRESENT=0) take tag 0 with no child slot."""
    var node = schema.node(node_idx)
    var nbranch = len(node.subtypes)
    if nbranch < 1:
        raise Error("OrcDecodeError.MALFORMED: UNION node has no branches")

    var present = _present_for_node(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size, n_rows,
    )
    var n_present = _count_true(present)

    var streams = _gather_streams_for_column(
        locs_kind, locs_col, locs_start, locs_end, file_bytes, node_idx,
        codec, block_size,
    )
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: UNION has no TAG (DATA) stream")
    var dense_tags = decode_byte_rle(streams[didx].bytes, n_present)

    var child_counts = List[Int]()
    for _b in range(nbranch):
        child_counts.append(0)
    var row_tags = List[Int8]()
    var row_offsets = List[Int32]()
    var vi = 0
    for i in range(len(present)):
        if present[i]:
            var tag = Int(dense_tags[vi])
            vi += 1
            if tag < 0 or tag >= nbranch:
                raise Error(
                    "OrcDecodeError.UNION_TAG_OOB: tag "
                    + String(tag)
                    + " out of [0, "
                    + String(nbranch)
                    + ")"
                )
            row_tags.append(Int8(tag))
            row_offsets.append(Int32(child_counts[tag]))
            child_counts[tag] += 1
        else:
            row_tags.append(Int8(0))
            row_offsets.append(Int32(0))

    var kids = Slab[Column[HeapRegion]].create(max(nbranch, 1))
    var type_ids = List[Int]()
    for b in range(nbranch):
        var child_col = decode_column_subtree(
            schema, node.subtypes[b], sf, locs_kind, locs_col, locs_start,
            locs_end, file_bytes, codec, block_size, child_counts[b],
        )
        kids.append(child_col^)
        type_ids.append(b)

    comptime int8_size = size_of[Int8]()
    comptime int32_size = size_of[Int32]()
    # `n_rows * int32_size` is an unchecked multiplication feeding an
    # allocation, while the fill loops below run to `n_rows` — the same
    # wrap-to-a-short-buffer / write-to-n_rows mismatch that `ColumnAcc.reserve`
    # guards against on the BIGINT path. Reachable here via a UNION whose `n_rows` came
    # from a parent LIST/MAP element sum. One check before the two allocations.
    if n_rows < 0 or n_rows > ORC_MAX_ROWS:
        raise Error(
            String("OrcDecodeError.BAD_ROW_COUNT: UNION node ")
            + String(node_idx)
            + " has row count "
            + String(n_rows)
            + ", outside [0, "
            + String(ORC_MAX_ROWS)
            + "]"
        )
    var types_buf = OwnedAlignedBuffer(max(n_rows * int8_size, 1))
    for i in range(n_rows):
        types_buf.set_typed[Int8](i, row_tags[i])
    types_buf.set_length(Int64(n_rows * int8_size))


    var offsets_buf = OwnedAlignedBuffer(max(n_rows * int32_size, 1))
    for i in range(n_rows):
        offsets_buf.set_typed[Int32](i, row_offsets[i])
    offsets_buf.set_length(Int64(n_rows * int32_size))


    var ua = UnionArray._build_dense(
        type_ids, types_buf^, offsets_buf^, kids^, n_rows
    )
    return Column.from_union(ua^)
