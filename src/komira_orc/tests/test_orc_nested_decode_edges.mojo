# =============================================================================
# test_orc_nested_decode_edges.mojo — the nested (STRUCT / LIST / MAP / UNION)
# decoder's null rows, index-stream skipping and refusals.
# =============================================================================
#
# Each case hands `decode_column_subtree` one stripe's streams directly (the
# streams are hand-encoded with the package's RLE encoders), so a refusal is
# reached with exactly the one defect it names.
#
#   T1  ROW_INDEX and BLOOM_FILTER_UTF8 streams of a LIST and its child are
#       skipped, never decompressed (here they are not valid chunk framing,
#       so decompressing them would raise).
#   T2  LIST with a null row: the null row has length 0 and is null; the
#       child holds only the present rows' elements.
#   T3  STRUCT whose field names are fewer than its children: the rest are
#       named `_col<i>`.
#   T4  UNION with a null row: tag 0, offset 0, no child slot taken.
#   T5  Refusals: a child kind the nested decoder does not decode (timestamp,
#       decimal); a primitive node with no ColumnEncoding; a LIST / MAP / UNION
#       with too few children; a LIST with no LENGTH stream; LIST and MAP
#       element totals past the Int32 offsets ceiling; a UNION with no tag
#       stream; a union tag past its branches; a UNION asked for a negative
#       row count; the offsets prefix sum past Int32.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_orc import (
    OrcRawType,
    OrcSchema,
    OrcStream,
    OrcColumnEncoding,
    StripeFooter,
    decode_column_subtree,
    encode_int_rle_v2,
    encode_byte_rle,
    encode_boolean_rle,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
    ORC_KIND_TIMESTAMP,
    ORC_KIND_DECIMAL,
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DIRECT_V2,
)
from komira_orc.nested_decoder import _build_offsets_i32
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# One stripe's streams, laid end to end.
# -----------------------------------------------------------------------------


struct _Stripe(Movable):
    var kinds: List[Int]
    var cols: List[Int]
    var starts: List[Int]
    var ends: List[Int]
    var bytes: List[UInt8]
    var streams: List[OrcStream]
    var encodings: List[OrcColumnEncoding]
    var framed: Bool

    def __init__(out self, n_nodes: Int, framed: Bool = False):
        self.kinds = List[Int]()
        self.cols = List[Int]()
        self.starts = List[Int]()
        self.ends = List[Int]()
        self.bytes = List[UInt8]()
        self.streams = List[OrcStream]()
        self.encodings = List[OrcColumnEncoding]()
        self.framed = framed
        for _ in range(n_nodes):
            self.encodings.append(OrcColumnEncoding(ORC_ENCODING_DIRECT_V2, 0))

    def add(mut self, kind: Int, col: Int, data: List[UInt8], raw: Bool = False):
        """Append one stream. In a framed (compressed-codec) stripe each stream
        is one stored chunk, unless `raw` asks for the bytes as given."""
        var body = List[UInt8]()
        if self.framed and not raw:
            var h = (len(data) << 1) | 1
            body.append(UInt8(h & 0xFF))
            body.append(UInt8((h >> 8) & 0xFF))
            body.append(UInt8((h >> 16) & 0xFF))
        for i in range(len(data)):
            body.append(data[i])
        self.kinds.append(kind)
        self.cols.append(col)
        self.starts.append(len(self.bytes))
        for i in range(len(body)):
            self.bytes.append(body[i])
        self.ends.append(len(self.bytes))
        self.streams.append(OrcStream(kind, col, len(body)))

    def footer(self) -> StripeFooter:
        return StripeFooter(self.streams.copy(), self.encodings.copy(), String("UTC"))


def _decode(
    schema: OrcSchema, node: Int, st: _Stripe, n_rows: Int
) raises -> Column[HeapRegion]:
    var codec = ORC_COMPRESSION_ZSTD if st.framed else ORC_COMPRESSION_NONE
    return decode_column_subtree(
        schema, node, st.footer(), st.kinds, st.cols, st.starts, st.ends,
        Span(st.bytes), codec, 0, n_rows,
    )



def _t(kind: Int, subtypes: List[Int], names: List[String]) -> OrcRawType:
    return OrcRawType(kind, subtypes.copy(), names.copy(), 0, 0, 0)


def _leaf(kind: Int) -> OrcRawType:
    return _t(kind, List[Int](), List[String]())


def _ints(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(vals)):
        out.append(Int64(vals[i]))
    return out^


def _bools(*vals: Bool) -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(vals)):
        out.append(vals[i])
    return out^


def _list_of_long() raises -> OrcSchema:
    var t = List[OrcRawType]()
    t.append(_t(ORC_KIND_LIST, [1], List[String]()))
    t.append(_leaf(ORC_KIND_LONG))
    return OrcSchema.from_types(t)


# -----------------------------------------------------------------------------
# T1 / T2 — LIST.
# -----------------------------------------------------------------------------


def test_list_index_streams_skipped_and_null_row() raises:
    var schema = _list_of_long()
    # Rows: [1], null, [2, 3]. A stored-chunk (compressed-codec) stripe whose
    # index streams are a single byte: not a valid chunk header.
    var st = _Stripe(2, framed=True)
    var junk = List[UInt8]()
    junk.append(0xFF)
    st.add(ORC_STREAM_ROW_INDEX, 0, junk, raw=True)
    st.add(ORC_STREAM_BLOOM_FILTER_UTF8, 1, junk, raw=True)
    st.add(ORC_STREAM_PRESENT, 0, encode_boolean_rle(_bools(True, False, True)))
    st.add(ORC_STREAM_LENGTH, 0, encode_int_rle_v2(_ints(1, 2), False))
    st.add(ORC_STREAM_ROW_INDEX, 1, junk, raw=True)
    st.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(1, 2, 3), True))
    var col = _decode(schema, 0, st, 3)
    var la = col.as_list()
    assert_equal(len(la), 3)
    assert_false(la.is_null(0))
    assert_true(la.is_null(1))
    assert_false(la.is_null(2))
    assert_equal(la.get_length(0), 1)
    assert_equal(la.get_length(1), 0)
    assert_equal(la.get_length(2), 2)
    assert_equal(la.get_offset(2), 1)
    assert_equal(la.total_values(), 3)
    var child = la.child.as_primitive[DType.int64]()
    assert_equal(Int(child.get(0)), 1)
    assert_equal(Int(child.get(2)), 3)


# -----------------------------------------------------------------------------
# T3 — STRUCT with an unnamed field.
# -----------------------------------------------------------------------------


def test_struct_unnamed_field() raises:
    var t = List[OrcRawType]()
    t.append(_t(ORC_KIND_STRUCT, [1, 2], ["a"]))
    t.append(_leaf(ORC_KIND_LONG))
    t.append(_leaf(ORC_KIND_LONG))
    var schema = OrcSchema.from_types(t)
    var st = _Stripe(3)
    st.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(5, 6), True))
    st.add(ORC_STREAM_DATA, 2, encode_int_rle_v2(_ints(7, 8), True))
    var col = _decode(schema, 0, st, 2)
    var sa = col.as_struct()
    assert_equal(sa.field_name(0), "a")
    assert_equal(sa.field_name(1), "_col1")
    assert_equal(Int(sa.child_at(1).as_primitive[DType.int64]().get(1)), 8)


# -----------------------------------------------------------------------------
# T4 — UNION with a null row.
# -----------------------------------------------------------------------------


def _union2() raises -> OrcSchema:
    var t = List[OrcRawType]()
    t.append(_t(ORC_KIND_UNION, [1, 2], List[String]()))
    t.append(_leaf(ORC_KIND_LONG))
    t.append(_leaf(ORC_KIND_LONG))
    return OrcSchema.from_types(t)


def _tags(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def test_union_null_row() raises:
    var schema = _union2()
    # Rows: tag 1 (20), null, tag 0 (10), tag 1 (21).
    var st = _Stripe(3)
    st.add(ORC_STREAM_PRESENT, 0, encode_boolean_rle(_bools(True, False, True, True)))
    st.add(ORC_STREAM_DATA, 0, encode_byte_rle(_tags(1, 0, 1)))
    st.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(10), True))
    st.add(ORC_STREAM_DATA, 2, encode_int_rle_v2(_ints(20, 21), True))
    var col = _decode(schema, 0, st, 4)
    var ua = col.as_union()
    assert_equal(Int(ua.type_id_at(0)), 1)
    assert_equal(Int(ua.type_id_at(1)), 0)
    assert_equal(Int(ua.offset_at(1)), 0)
    assert_equal(Int(ua.type_id_at(2)), 0)
    assert_equal(Int(ua.offset_at(2)), 0)
    assert_equal(Int(ua.type_id_at(3)), 1)
    assert_equal(Int(ua.offset_at(3)), 1)
    assert_equal(ua.child_at(0).as_primitive[DType.int64]().length, 1)
    assert_equal(Int(ua.child_at(1).as_primitive[DType.int64]().get(1)), 21)


# -----------------------------------------------------------------------------
# T5 — refusals.
# -----------------------------------------------------------------------------


def test_refusals() raises:
    # A struct child of a kind the nested decoder does not decode.
    for k in range(2):
        var kind = ORC_KIND_TIMESTAMP if k == 0 else ORC_KIND_DECIMAL
        var t = List[OrcRawType]()
        t.append(_t(ORC_KIND_STRUCT, [1], ["x"]))
        t.append(_leaf(kind))
        var name = String("timestamp") if k == 0 else String("decimal")
        with assert_raises(contains="UNSUPPORTED_TYPE: ORC Type.Kind " + name + " in nested decode"):
            _ = _decode(OrcSchema.from_types(t), 0, _Stripe(2), 1)

    # A primitive node with no ColumnEncoding entry (the footer lists 1 of 2).
    var schema = _list_of_long()
    var noenc = _Stripe(1)
    noenc.add(ORC_STREAM_LENGTH, 0, encode_int_rle_v2(_ints(1), False))
    noenc.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(4), True))
    with assert_raises(contains="MISSING_ENCODING: column id 1 has no ColumnEncoding entry"):
        _ = _decode(schema, 0, noenc, 1)

    # Too few children.
    var bare_list = List[OrcRawType]()
    bare_list.append(_t(ORC_KIND_LIST, List[Int](), List[String]()))
    with assert_raises(contains="MALFORMED: LIST node has no child"):
        _ = _decode(OrcSchema.from_types(bare_list), 0, _Stripe(1), 1)
    var one_map = List[OrcRawType]()
    one_map.append(_t(ORC_KIND_MAP, [1], List[String]()))
    one_map.append(_leaf(ORC_KIND_LONG))
    with assert_raises(contains="MALFORMED: MAP node needs key + value child"):
        _ = _decode(OrcSchema.from_types(one_map), 0, _Stripe(2), 1)
    var bare_union = List[OrcRawType]()
    bare_union.append(_t(ORC_KIND_UNION, List[Int](), List[String]()))
    with assert_raises(contains="MALFORMED: UNION node has no branches"):
        _ = _decode(OrcSchema.from_types(bare_union), 0, _Stripe(1), 1)

    # LIST with no LENGTH stream.
    var nolen = _Stripe(2)
    nolen.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(4), True))
    with assert_raises(contains="MISSING_LENGTH: LIST/MAP node 0 has no LENGTH stream"):
        _ = _decode(schema, 0, nolen, 1)

    # Element totals past Int32.MAX: two rows of 2^30 elements each.
    var big = _Stripe(2)
    big.add(ORC_STREAM_LENGTH, 0, encode_int_rle_v2(_ints(1 << 30, 1 << 30), False))
    with assert_raises(
        contains="OFFSET_OVERFLOW: LIST node 0 declares 2147483648 child elements, outside the [0, 2147483647]"
    ):
        _ = _decode(schema, 0, big, 2)
    var map_t = List[OrcRawType]()
    map_t.append(_t(ORC_KIND_MAP, [1, 2], List[String]()))
    map_t.append(_leaf(ORC_KIND_LONG))
    map_t.append(_leaf(ORC_KIND_LONG))
    var bigm = _Stripe(3)
    bigm.add(ORC_STREAM_LENGTH, 0, encode_int_rle_v2(_ints(1 << 30, 1 << 30), False))
    with assert_raises(contains="OFFSET_OVERFLOW: MAP node 0 declares 2147483648 child elements"):
        _ = _decode(OrcSchema.from_types(map_t), 0, bigm, 2)

    # UNION refusals.
    var u = _union2()
    var notag = _Stripe(3)
    with assert_raises(contains="MISSING_DATA: UNION has no TAG (DATA) stream"):
        _ = _decode(u, 0, notag, 1)
    var badtag = _Stripe(3)
    badtag.add(ORC_STREAM_DATA, 0, encode_byte_rle(_tags(0, 2)))
    badtag.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(_ints(10), True))
    with assert_raises(contains="UNION_TAG_OOB: tag 2 out of [0, 2)"):
        _ = _decode(u, 0, badtag, 2)
    var neg = _Stripe(3)
    neg.add(ORC_STREAM_DATA, 0, encode_byte_rle(List[UInt8]()))
    neg.add(ORC_STREAM_DATA, 1, encode_int_rle_v2(List[Int64](), True))
    neg.add(ORC_STREAM_DATA, 2, encode_int_rle_v2(List[Int64](), True))
    with assert_raises(contains="BAD_ROW_COUNT: UNION node 0 has row count -1, outside [0, 1099511627776]"):
        _ = _decode(u, 0, neg, -1)


def test_offsets_prefix_sum_ceiling() raises:
    var ok = List[Int]()
    ok.append(Int(Int32.MAX) - 1)
    ok.append(1)
    var buf = _build_offsets_i32(ok)
    assert_equal(Int(buf.get_typed[Int32](2)), Int(Int32.MAX))
    var over = List[Int]()
    over.append(Int(Int32.MAX))
    over.append(0)
    over.append(1)
    with assert_raises(
        contains="OFFSET_OVERFLOW: LIST/MAP child offsets reach 2147483648 at row 2, past the Int32 ceiling 2147483647"
    ):
        _ = _build_offsets_i32(over)


def main() raises:
    test_list_index_streams_skipped_and_null_row()
    test_struct_unnamed_field()
    test_union_null_row()
    test_refusals()
    test_offsets_prefix_sum_ceiling()
    print("test_orc_nested_decode_edges: ALL PASS")
