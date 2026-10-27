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
# The unit of work is a SET of stripes (`NestedStripes`, zero or more, in
# file order). `decode_column_subtree_stripes` returns ONE fully-materialized
# Arrow `Column` for a schema node and its descendants over every stripe: each
# node decodes its per-row metadata (PRESENT, LENGTH, union tags) stripe by
# stripe into one list, and passes each child its per-stripe row counts, so
# list / map / dense-union offsets continue across stripe boundaries and no
# Arrow-level concatenation of nested columns is needed.
# `decode_column_subtree` is the one-stripe form.
#
#   - PRIMITIVE leaf  -> reuse the column_decoder ColumnAcc machinery (each
#                        stripe appends to one accumulator).
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
# the flat Footer.types list. Each stripe's located streams are 4 parallel lists
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
from komira_arrow.schema import Schema, SchemaBuilder, Field
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
from .orc_logical_arrow import stamp_arrow_orc_metadata
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


struct NestedStripes(Movable):
    """The parsed StripeFooter and located streams of every stripe a nested
    read spans, in file order.

    Each stripe's located streams are kept in the flat parallel-list form
    (kind / column / start / end) so this module never imports
    `orc_reader._StreamLoc`. Zero stripes is a valid set: every subtree then
    decodes to a zero-row column.
    """

    var footers: List[StripeFooter]
    var locs_kind: List[List[Int]]
    var locs_col: List[List[Int]]
    var locs_start: List[List[Int]]
    var locs_end: List[List[Int]]

    def __init__(out self):
        self.footers = List[StripeFooter]()
        self.locs_kind = List[List[Int]]()
        self.locs_col = List[List[Int]]()
        self.locs_start = List[List[Int]]()
        self.locs_end = List[List[Int]]()

    def add_stripe(
        mut self,
        sf: StripeFooter,
        locs_kind: List[Int],
        locs_col: List[Int],
        locs_start: List[Int],
        locs_end: List[Int],
    ):
        """Append one stripe (its footer and located streams)."""
        self.footers.append(sf.copy())
        self.locs_kind.append(locs_kind.copy())
        self.locs_col.append(locs_col.copy())
        self.locs_start.append(locs_start.copy())
        self.locs_end.append(locs_end.copy())

    def count(self) -> Int:
        return len(self.footers)


# =============================================================================
# Stream gathering (flat-arena parallel-list form).
# =============================================================================


def _gather_streams_for_column(
    stripes: NestedStripes,
    s: Int,
    file_bytes: Span[UInt8, _],
    col_id: Int,
    codec: Int,
    block_size: Int,
) raises -> List[StreamSpan]:
    """Collect+decompress every (non-index) data stream for `col_id` in
    stripe `s`."""
    from .footer import (
        ORC_STREAM_ROW_INDEX,
        ORC_STREAM_BLOOM_FILTER,
        ORC_STREAM_BLOOM_FILTER_UTF8,
    )
    from .orc_codec import decompress_stream

    ref locs_kind = stripes.locs_kind[s]
    ref locs_col = stripes.locs_col[s]
    ref locs_start = stripes.locs_start[s]
    ref locs_end = stripes.locs_end[s]
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


@always_inline
def _sum(values: List[Int]) -> Int:
    var total = 0
    for i in range(len(values)):
        total += values[i]
    return total


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


def _present_in_stripe(
    stripes: NestedStripes,
    s: Int,
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    n_rows: Int,
) raises -> List[Bool]:
    """Decode one stripe's PRESENT (validity) stream for a node, or
    all-present."""
    var streams = _gather_streams_for_column(
        stripes, s, file_bytes, node_idx, codec, block_size
    )
    return _decode_present(streams, n_rows)


def _present_all_stripes(
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> List[Bool]:
    """The node's validity over every stripe's rows, in file order."""
    var out = List[Bool]()
    for s in range(stripes.count()):
        var p = _present_in_stripe(
            stripes, s, file_bytes, node_idx, codec, block_size, rows[s]
        )
        for i in range(len(p)):
            out.append(p[i])
    return out^


# =============================================================================
# Primitive leaf decode -> Column (via column_decoder's ColumnAcc).
# =============================================================================


def _decode_primitive_column(
    schema: OrcSchema,
    node_idx: Int,
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """Decode one PRIMITIVE schema node into an Arrow Column[HeapRegion]:
    each stripe appends `rows[s]` values to one accumulator, as the flat path
    does."""
    var node = schema.node(node_idx)
    var at = orc_node_to_arrow(schema, node_idx)
    var acc = make_accumulator(node.kind, at)
    for s in range(stripes.count()):
        var enc = _encoding_for(stripes.footers[s], node_idx)
        var streams = _gather_streams_for_column(
            stripes, s, file_bytes, node_idx, codec, block_size
        )
        decode_stripe_column(
            acc, node.kind, enc.kind, enc.dictionary_size, streams, rows[s]
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
    var stripes = NestedStripes()
    stripes.add_stripe(sf, locs_kind, locs_col, locs_start, locs_end)
    var rows = List[Int]()
    rows.append(n_rows)
    return decode_column_subtree_stripes(
        schema, node_idx, stripes, file_bytes, codec, block_size, rows
    )


def decode_column_subtree_stripes(
    schema: OrcSchema,
    node_idx: Int,
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """Decode schema node `node_idx` (and its descendants) across every
    stripe in `stripes` into ONE Arrow Column. `rows[s]` is the number of
    logical rows this node spans in stripe `s` (a stripe's row count for a
    top-level column; the parent's element count in that stripe for a child
    of LIST/MAP/UNION). The output holds `sum(rows)` rows in stripe order."""
    var kind = schema.node(node_idx).kind

    if _is_primitive_kind(kind):
        return _decode_primitive_column(
            schema, node_idx, stripes, file_bytes, codec, block_size, rows
        )
    elif kind == ORC_KIND_STRUCT:
        return _decode_struct(
            schema, node_idx, stripes, file_bytes, codec, block_size, rows
        )
    elif kind == ORC_KIND_LIST:
        return _decode_list(
            schema, node_idx, stripes, file_bytes, codec, block_size, rows
        )
    elif kind == ORC_KIND_MAP:
        return _decode_map(
            schema, node_idx, stripes, file_bytes, codec, block_size, rows
        )
    elif kind == ORC_KIND_UNION:
        return _decode_union(
            schema, node_idx, stripes, file_bytes, codec, block_size, rows
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
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """STRUCT: struct-level PRESENT validity + recurse each child at full
    n_rows. ORC struct children are NOT shortened by the struct's null bitmap
    — every child column still carries the struct's row count per stripe."""
    var node = schema.node(node_idx)
    var present = _present_all_stripes(
        stripes, file_bytes, node_idx, codec, block_size, rows
    )
    var validity = _validity_bitmap(present)
    var nc = _null_count(present)
    var n_rows = _sum(rows)

    var nfields = len(node.subtypes)
    var kids = Slab[Column[HeapRegion]].create(max(nfields, 1))
    var names = List[String]()
    for i in range(nfields):
        var child_idx = node.subtypes[i]
        var child_col = decode_column_subtree_stripes(
            schema, child_idx, stripes, file_bytes, codec, block_size, rows
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
    stripes: NestedStripes,
    s: Int,
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    n_present: Int,
) raises -> List[Int64]:
    """Decode stripe `s`'s per-element LENGTH stream (unsigned RLE) for a
    LIST/MAP node. Holds one entry per PRESENT (non-null) parent row."""
    var streams = _gather_streams_for_column(
        stripes, s, file_bytes, node_idx, codec, block_size
    )
    var lidx = _find_stream(streams, ORC_STREAM_LENGTH)
    if lidx < 0:
        raise Error(
            "OrcDecodeError.MISSING_LENGTH: LIST/MAP node "
            + String(node_idx)
            + " has no LENGTH stream"
        )
    var enc = _encoding_for(stripes.footers[s], node_idx)
    var lens = decode_int_rle(
        streams[lidx].bytes, n_present, False, _is_v2(enc.kind)
    )
    # LIST/MAP element counts are decoded as UNSIGNED RLE into Int64, so a
    # bit-width-64 DIRECT run yields an arbitrary pattern — negative as an
    # Int64. Those propagate straight into the CHILD subtree's row counts (via
    # `_list_row_lengths`) and into `_build_offsets_i32`. One branchless pass
    # here, at the single place LIST/MAP lengths enter the decoder, covers both
    # consumers. Mirrors `column_decoder._decode_lengths`.
    #
    # Call the shared helper; do not re-inline the loop. Copies of one
    # invariant drift, and a LENGTH decoder that misses it is a bounds bug.
    _check_lengths_non_negative(lens)
    return lens^


@always_inline
def _check_child_total(total: Int, node_idx: Int, what: StringSlice) raises:
    """Bound a LIST/MAP child element count before it becomes an allocation.

    `total` is the sum of writer-chosen per-row element counts. It is passed as
    the child subtree's row count AND ends up as the final Arrow offset, so the
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


struct _ListShape(Movable):
    """A LIST/MAP node's per-row validity and element counts over every
    stripe, plus each stripe's child element count (the child subtree's
    `rows`)."""

    var present: List[Bool]
    var row_lengths: List[Int]
    var child_rows: List[Int]

    def __init__(out self):
        self.present = List[Bool]()
        self.row_lengths = List[Int]()
        self.child_rows = List[Int]()


def _list_row_lengths(
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    node_idx: Int,
    codec: Int,
    block_size: Int,
    rows: List[Int],
    what: StringSlice,
) raises -> _ListShape:
    """Decode PRESENT + LENGTH of a LIST/MAP node in every stripe. A null row
    contributes length 0 (its child span is empty). The running element total
    is bounded after each stripe, BEFORE any child decode allocates for it:
    it becomes the child's row count and the last Arrow offset, and an Int32
    offsets buffer cannot address past `Int32.MAX` elements."""
    var shape = _ListShape()
    var total = 0
    for s in range(stripes.count()):
        var present = _present_in_stripe(
            stripes, s, file_bytes, node_idx, codec, block_size, rows[s]
        )
        var dense_lengths = _decode_length_stream(
            stripes, s, file_bytes, node_idx, codec, block_size,
            _count_true(present),
        )
        var stripe_total = 0
        var vi = 0
        for i in range(len(present)):
            shape.present.append(present[i])
            var n = 0
            if present[i]:
                n = Int(dense_lengths[vi])
                vi += 1
            shape.row_lengths.append(n)
            stripe_total += n
        total += stripe_total
        _check_child_total(total, node_idx, what)
        shape.child_rows.append(stripe_total)
    return shape^


# =============================================================================
# LIST.
# =============================================================================


def _decode_list(
    schema: OrcSchema,
    node_idx: Int,
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """LIST: PRESENT + per-element LENGTH + single child column. The child
    spans sum(lengths) rows; offsets are the prefix-sum of per-row lengths
    over every stripe, so they continue across stripe boundaries."""
    var node = schema.node(node_idx)
    if len(node.subtypes) < 1:
        raise Error("OrcDecodeError.MALFORMED: LIST node has no child")
    var shape = _list_row_lengths(
        stripes, file_bytes, node_idx, codec, block_size, rows, "LIST"
    )

    var child_col = decode_column_subtree_stripes(
        schema, node.subtypes[0], stripes, file_bytes, codec, block_size,
        shape.child_rows,
    )

    var offsets = _build_offsets_i32(shape.row_lengths)
    var validity = _validity_bitmap(shape.present)
    var nc = _null_count(shape.present)
    var la = ListArray[HeapRegion](
        offsets=offsets^,
        child=child_col^,
        validity=validity^,
        length=_sum(rows),
        null_count=nc,
    )
    return Column.from_list(la^)


# =============================================================================
# MAP.
# =============================================================================


def _decode_map(
    schema: OrcSchema,
    node_idx: Int,
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """MAP: PRESENT + per-element LENGTH + KEY child + VALUE child. Both
    children span sum(lengths) entries (parallel keys/values arrays)."""
    var node = schema.node(node_idx)
    if len(node.subtypes) < 2:
        raise Error("OrcDecodeError.MALFORMED: MAP node needs key + value child")
    var shape = _list_row_lengths(
        stripes, file_bytes, node_idx, codec, block_size, rows, "MAP"
    )

    var keys_col = decode_column_subtree_stripes(
        schema, node.subtypes[0], stripes, file_bytes, codec, block_size,
        shape.child_rows,
    )
    var values_col = decode_column_subtree_stripes(
        schema, node.subtypes[1], stripes, file_bytes, codec, block_size,
        shape.child_rows,
    )

    var offsets = _build_offsets_i32(shape.row_lengths)
    var validity = _validity_bitmap(shape.present)
    var nc = _null_count(shape.present)
    var ma = MapArray[HeapRegion](
        offsets=offsets^,
        keys=keys_col^,
        values=values_col^,
        validity=validity^,
        length=_sum(rows),
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
    stripes: NestedStripes,
    file_bytes: Span[UInt8, _],
    codec: Int,
    block_size: Int,
    rows: List[Int],
) raises -> Column[HeapRegion]:
    """UNION: PRESENT + DATA (byte-RLE tag stream) + N branch children. Child
    `i` holds values ONLY for rows where tag==i (tagged-dense). Reconstruct the
    Arrow Dense Union: type_ids = per-row tag, offsets = running per-child
    counter over every stripe. Null parent rows (PRESENT=0) take tag 0 with no
    child slot."""
    var node = schema.node(node_idx)
    var nbranch = len(node.subtypes)
    if nbranch < 1:
        raise Error("OrcDecodeError.MALFORMED: UNION node has no branches")

    # `n_rows * int32_size` below is an unchecked multiplication feeding an
    # allocation, while the fill loops run to `n_rows` — the same
    # wrap-to-a-short-buffer / write-to-n_rows mismatch that `ColumnAcc.reserve`
    # guards against on the BIGINT path. Reachable here via a UNION whose row
    # count came from a parent LIST/MAP element sum. One check before any
    # per-row work.
    var n_rows = _sum(rows)
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

    # child_counts[b]: branch b's values so far (the dense offset of the next
    # row tagged b). branch_rows[b][s]: branch b's value count in stripe s.
    var child_counts = List[Int]()
    var branch_rows = List[List[Int]]()
    for _b in range(nbranch):
        child_counts.append(0)
        branch_rows.append(List[Int]())
    var row_tags = List[Int8]()
    var row_offsets = List[Int32]()
    for s in range(stripes.count()):
        var present = _present_in_stripe(
            stripes, s, file_bytes, node_idx, codec, block_size, rows[s]
        )
        var streams = _gather_streams_for_column(
            stripes, s, file_bytes, node_idx, codec, block_size
        )
        var didx = _find_stream(streams, ORC_STREAM_DATA)
        if didx < 0:
            raise Error(
                "OrcDecodeError.MISSING_DATA: UNION has no TAG (DATA) stream"
            )
        var dense_tags = decode_byte_rle(
            streams[didx].bytes, _count_true(present)
        )
        var before = child_counts.copy()
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
        for b in range(nbranch):
            branch_rows[b].append(child_counts[b] - before[b])

    var kids = Slab[Column[HeapRegion]].create(max(nbranch, 1))
    var type_ids = List[Int]()
    for b in range(nbranch):
        var child_col = decode_column_subtree_stripes(
            schema, node.subtypes[b], stripes, file_bytes, codec, block_size,
            branch_rows[b],
        )
        kids.append(child_col^)
        type_ids.append(b)

    comptime int8_size = size_of[Int8]()
    comptime int32_size = size_of[Int32]()
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


# =============================================================================
# Output schema.
# =============================================================================


def nested_output_schema(
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


