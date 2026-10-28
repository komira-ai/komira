# =============================================================================
# test_orc_metadata_parse_edges.mojo — the metadata parsers' rarely-taken arms.
# =============================================================================
#
# Every protobuf message parser in footer.mojo skips a field it does not read
# (an unknown field number, or a known number with the wrong wire type) and
# keeps parsing the fields after it. Each test below puts such a field FIRST
# and a known field AFTER it, so a parser that stopped (or mis-advanced) at the
# skipped field loses the value the test asserts.
#
#   T1  the name ladders: every CompressionKind, ColumnEncoding.Kind and
#       Type.Kind name, and the fall-through name of an unknown value.
#   T2  orc_checked_extent: 2^48 is accepted, 2^48 + 1 refused (the field is
#       named in the message).
#   T3  Type: maximumLength / precision / scale, after an unknown field; the
#       encode_type_node writer for those fields round-trips.
#   T4  StripeInformation / Stream / ColumnEncoding: a LEN field before the
#       varints is skipped; encode_column_encoding's dictionarySize
#       round-trips.
#   T5  ColumnStatistics: DoubleStatistics (fixed64 min / max, the sum skipped
#       by width), an IntegerStatistics LEN field skipped, an unknown field;
#       a fixed64 double running past the buffer is refused.
#   T6  Metadata / StripeStatistics / StripeFooter / RowIndex /
#       BloomFilterIndex: an unknown field first.
#   T7  RowIndexEntry: packed positions (the writer's encode_row_index_entry)
#       and non-packed positions.
#   T8  BloomFilter: numHashFunctions 64 accepted, 65 refused; the legacy
#       fixed64 bitset field is skipped.
#   T9  parse_chunk_header: a header with fewer than 3 bytes left is refused.
#   T10 OrcFileTail.parse refusals: too small, PostScript length 0, PostScript
#       overrunning the file start, trailing magic not "ORC", Footer and
#       Metadata lengths overrunning the file start.
#   T11 OrcSchema: a backward child link is refused as cyclic, node() refuses
#       an index outside the tree, canonical form names an unnamed struct
#       field `_col<i>`, orc_node_to_arrow refuses an unknown kind.
#   T12 ACID detection: each of the six wrapper names (and the row kind) is
#       checked; acid_row_struct_index; acid_output_columns names an unnamed
#       row field `_col<i>`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_orc import (
    PostScript,
    Footer,
    Metadata,
    StripeFooter,
    StripeInformation,
    OrcRawType,
    OrcStream,
    OrcColumnEncoding,
    OrcColumnStatistics,
    OrcRowIndexEntry,
    OrcRowIndex,
    OrcBloomFilterEntry,
    OrcBloomFilterIndex,
    OrcFileTail,
    OrcSchema,
    parse_chunk_header,
    orc_compression_name,
    orc_encoding_name,
    orc_kind_name,
    orc_node_to_arrow,
    is_acid_schema,
    acid_row_struct_index,
    acid_output_columns,
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_len_field,
    pb_write_string_field,
    pb_write_message_field,
    pb_write_double_field,
    encode_type_node,
    encode_column_encoding,
    encode_row_index_entry,
    encode_post_script,
    encode_footer,
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_KIND_STRUCT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_DECIMAL,
    ORC_KIND_VARCHAR,
)
from komira_orc.footer import orc_checked_extent, OrcStripeStatistics


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _unknown_len(mut out: List[UInt8], field: Int):
    """An unknown LEN field holding 3 bytes that look like varint fields: a
    parser that read INTO it instead of skipping would see them."""
    var junk = List[UInt8]()
    junk.append(0x08)  # field 1 varint
    junk.append(0x7F)
    junk.append(0x00)
    pb_write_len_field(out, field, Span(junk))


def _fixed64(mut out: List[UInt8], field: Int, bits: UInt64):
    pb_write_tag(out, field, PB_WIRE_FIXED64)
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def _fixed32(mut out: List[UInt8], field: Int, bits: UInt32):
    pb_write_tag(out, field, PB_WIRE_FIXED32)
    for k in range(4):
        out.append(UInt8((bits >> UInt32(8 * k)) & 0xFF))


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


# -----------------------------------------------------------------------------
# T1 — name ladders.
# -----------------------------------------------------------------------------


def test_name_ladders() raises:
    assert_equal(orc_compression_name(0), "NONE")
    assert_equal(orc_compression_name(1), "ZLIB")
    assert_equal(orc_compression_name(2), "SNAPPY")
    assert_equal(orc_compression_name(3), "LZO")
    assert_equal(orc_compression_name(4), "LZ4")
    assert_equal(orc_compression_name(5), "ZSTD")
    assert_equal(orc_compression_name(6), "UNKNOWN")
    assert_equal(orc_compression_name(-1), "UNKNOWN")

    assert_equal(orc_encoding_name(0), "DIRECT")
    assert_equal(orc_encoding_name(1), "DICTIONARY")
    assert_equal(orc_encoding_name(2), "DIRECT_V2")
    assert_equal(orc_encoding_name(3), "DICTIONARY_V2")
    assert_equal(orc_encoding_name(4), "UNKNOWN")

    var kinds = List[String]()
    kinds.append("boolean")
    kinds.append("tinyint")
    kinds.append("smallint")
    kinds.append("int")
    kinds.append("bigint")
    kinds.append("float")
    kinds.append("double")
    kinds.append("string")
    kinds.append("binary")
    kinds.append("timestamp")
    kinds.append("array")
    kinds.append("map")
    kinds.append("struct")
    kinds.append("uniontype")
    kinds.append("decimal")
    kinds.append("date")
    kinds.append("varchar")
    kinds.append("char")
    kinds.append("timestamp with local time zone")
    for k in range(len(kinds)):
        assert_equal(orc_kind_name(k), kinds[k])
    assert_equal(orc_kind_name(19), "unknown")
    assert_equal(orc_kind_name(-1), "unknown")


# -----------------------------------------------------------------------------
# T2 — the uint64 -> Int extent bound.
# -----------------------------------------------------------------------------


def test_checked_extent_bound() raises:
    var cap = UInt64(1) << 48
    assert_equal(orc_checked_extent(cap, "x"), Int(1) << 48)
    assert_equal(orc_checked_extent(UInt64(0), "x"), 0)
    with assert_raises(
        contains="FIELD_TOO_LARGE: PostScript.footerLength = 281474976710657 exceeds"
    ):
        var ps = encode_post_script(
            Int(cap + 1), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"
        )
        _ = PostScript.parse(Span(ps))
    # A uint64 with its top bit set (an Int would read it negative).
    with assert_raises(contains="FIELD_TOO_LARGE: Footer.numberOfRows = 18446744073709551615"):
        var f = List[UInt8]()
        pb_write_varint_field(f, 6, UInt64.MAX)
        _ = Footer.parse(Span(f))


# -----------------------------------------------------------------------------
# T3 — Type fields 4 / 5 / 6 and an unknown field.
# -----------------------------------------------------------------------------


def test_type_decimal_and_varchar_fields() raises:
    var b = List[UInt8]()
    _unknown_len(b, 9)
    pb_write_varint_field(b, 1, UInt64(ORC_KIND_DECIMAL))
    pb_write_varint_field(b, 5, 38)
    pb_write_varint_field(b, 6, 9)
    pb_write_varint_field(b, 4, 77)
    _fixed32(b, 7, 0xDEADBEEF)
    var t = OrcRawType.parse(Span(b), 0, len(b))
    assert_equal(t.kind, ORC_KIND_DECIMAL)
    assert_equal(t.precision, 38)
    assert_equal(t.scale, 9)
    assert_equal(t.maximum_length, 77)
    assert_equal(len(t.subtypes), 0)

    # The writer's encoder for the same fields round-trips.
    var enc = encode_type_node(
        ORC_KIND_VARCHAR, List[Int](), List[String](), 40, 0, 0
    )
    var tv = OrcRawType.parse(Span(enc), 0, len(enc))
    assert_equal(tv.kind, ORC_KIND_VARCHAR)
    assert_equal(tv.maximum_length, 40)
    assert_equal(tv.precision, 0)
    var encd = encode_type_node(
        ORC_KIND_DECIMAL, List[Int](), List[String](), 0, 18, 4
    )
    var td = OrcRawType.parse(Span(encd), 0, len(encd))
    assert_equal(td.precision, 18)
    assert_equal(td.scale, 4)
    assert_equal(td.maximum_length, 0)


# -----------------------------------------------------------------------------
# T4 — StripeInformation / Stream / ColumnEncoding skip a LEN field.
# -----------------------------------------------------------------------------


def test_varint_messages_skip_len_fields() raises:
    var si = List[UInt8]()
    _unknown_len(si, 6)
    pb_write_varint_field(si, 1, 3)
    pb_write_varint_field(si, 2, 10)
    pb_write_varint_field(si, 3, 200)
    pb_write_varint_field(si, 4, 30)
    pb_write_varint_field(si, 5, 1000)
    var s = StripeInformation.parse(Span(si), 0, len(si))
    assert_equal(s.offset, 3)
    assert_equal(s.index_length, 10)
    assert_equal(s.data_length, 200)
    assert_equal(s.footer_length, 30)
    assert_equal(s.number_of_rows, 1000)

    var st = List[UInt8]()
    _unknown_len(st, 4)
    pb_write_varint_field(st, 1, 1)
    pb_write_varint_field(st, 2, 5)
    pb_write_varint_field(st, 3, 123)
    var o = OrcStream.parse(Span(st), 0, len(st))
    assert_equal(o.kind, 1)
    assert_equal(o.column, 5)
    assert_equal(o.length, 123)

    var ce = List[UInt8]()
    _unknown_len(ce, 3)
    var enc = encode_column_encoding(3, 250)
    for i in range(len(enc)):
        ce.append(enc[i])
    var c = OrcColumnEncoding.parse(Span(ce), 0, len(ce))
    assert_equal(c.kind, 3)
    assert_equal(c.dictionary_size, 250)
    # encode_column_encoding omits a zero dictionary size.
    var enc0 = encode_column_encoding(2, 0)
    assert_equal(len(enc0), 2)


# -----------------------------------------------------------------------------
# T5 — ColumnStatistics: double stats, skipped int-stats LEN field, unknowns.
# -----------------------------------------------------------------------------


def test_column_statistics_double_and_skips() raises:
    from std.memory import bitcast

    var dbl = List[UInt8]()
    _unknown_len(dbl, 5)  # a LEN field inside DoubleStatistics: skipped
    _fixed64(dbl, 1, bitcast[DType.uint64, 1](Float64(-2.5)))
    _fixed64(dbl, 3, bitcast[DType.uint64, 1](Float64(99.0)))  # sum: skipped by width
    _fixed64(dbl, 2, bitcast[DType.uint64, 1](Float64(1.0e10)))

    var ints = List[UInt8]()
    _unknown_len(ints, 4)  # a LEN field inside IntegerStatistics: skipped
    pb_write_varint_field(ints, 1, 7)  # zigzag 7 -> -4
    pb_write_varint_field(ints, 2, 8)  # zigzag 8 -> 4

    var cs = List[UInt8]()
    _unknown_len(cs, 12)
    pb_write_varint_field(cs, 1, 42)
    pb_write_message_field(cs, 3, dbl)
    pb_write_message_field(cs, 2, ints)
    pb_write_varint_field(cs, 10, 1)
    var s = OrcColumnStatistics.parse(Span(cs), 0, len(cs))
    assert_equal(s.number_of_values, 42)
    assert_true(s.has_double)
    assert_equal(s.dbl_min, -2.5)
    assert_equal(s.dbl_max, 1.0e10)
    assert_true(s.has_int)
    assert_equal(s.int_min, -4)
    assert_equal(s.int_max, 4)
    assert_true(s.has_null)
    assert_false(s.has_string)

    # Only a maximum: has_double is still set by the one field present.
    var only_max = List[UInt8]()
    _fixed64(only_max, 2, bitcast[DType.uint64, 1](Float64(3.0)))
    var cs2 = List[UInt8]()
    pb_write_message_field(cs2, 3, only_max)
    var s2 = OrcColumnStatistics.parse(Span(cs2), 0, len(cs2))
    assert_true(s2.has_double)
    assert_equal(s2.dbl_max, 3.0)
    assert_equal(s2.dbl_min, 0.0)

    # A fixed64 double whose 8 bytes run past the buffer end is refused.
    var cut = List[UInt8]()
    pb_write_tag(cut, 3, PB_WIRE_LEN)
    pb_write_varint(cut, 8)  # tag + 7 bytes: the payload ends with the buffer
    pb_write_tag(cut, 1, PB_WIRE_FIXED64)
    for _ in range(7):
        cut.append(0)
    with assert_raises(contains="MALFORMED_PROTOBUF: double past end"):
        _ = OrcColumnStatistics.parse(Span(cut), 0, len(cut))


# -----------------------------------------------------------------------------
# T6 — container messages skip an unknown field first.
# -----------------------------------------------------------------------------


def test_containers_skip_unknown_fields() raises:
    # ColumnStatistics with one value.
    var cs = List[UInt8]()
    pb_write_varint_field(cs, 1, 5)

    var ss = List[UInt8]()
    _unknown_len(ss, 2)
    pb_write_message_field(ss, 1, cs)
    var sst = OrcStripeStatistics.parse(Span(ss), 0, len(ss))
    assert_equal(len(sst.col_stats), 1)
    assert_equal(sst.col_stats[0].number_of_values, 5)

    var md = List[UInt8]()
    pb_write_varint_field(md, 2, 1)
    pb_write_message_field(md, 1, ss)
    pb_write_message_field(md, 1, ss)
    var m = Metadata.parse(Span(md))
    assert_equal(m.stripe_stats_count, 2)
    assert_equal(len(m.per_stripe_stats), 2)
    assert_equal(m.per_stripe_stats[1].col_stats[0].number_of_values, 5)
    var mc = m.copy()
    assert_equal(mc.stripe_stats_count, 2)
    assert_equal(mc.per_stripe_stats[0].col_stats[0].number_of_values, 5)

    var sf = List[UInt8]()
    _unknown_len(sf, 9)
    var st = List[UInt8]()
    pb_write_varint_field(st, 1, 1)
    pb_write_varint_field(st, 2, 1)
    pb_write_varint_field(st, 3, 64)
    pb_write_message_field(sf, 1, st)
    pb_write_string_field(sf, 3, "UTC")
    var f = StripeFooter.parse(Span(sf))
    assert_equal(len(f.streams), 1)
    assert_equal(f.streams[0].length, 64)
    assert_equal(f.writer_timezone, "UTC")

    var entry = List[UInt8]()
    pb_write_message_field(entry, 2, cs)
    var ri = List[UInt8]()
    pb_write_varint_field(ri, 3, 9)
    pb_write_message_field(ri, 1, entry)
    var r = OrcRowIndex.parse(Span(ri))
    assert_equal(len(r.entries), 1)
    assert_equal(r.entries[0].statistics.number_of_values, 5)
    var rc = r.copy()
    assert_equal(rc.entries[0].statistics.number_of_values, 5)

    var bits = List[UInt8]()
    for i in range(8):
        bits.append(UInt8(i + 1))
    var bf = List[UInt8]()
    pb_write_varint_field(bf, 1, 3)
    pb_write_len_field(bf, 3, Span(bits))
    var bfi = List[UInt8]()
    _unknown_len(bfi, 2)
    pb_write_message_field(bfi, 1, bf)
    var b = OrcBloomFilterIndex.parse(Span(bfi))
    assert_equal(len(b.entries), 1)
    assert_equal(b.entries[0].num_hash_functions, 3)
    assert_equal(len(b.entries[0].utf8bitset), 8)
    assert_equal(b.entries[0].utf8bitset[7], 8)
    var bc = b.copy()
    assert_equal(bc.entries[0].utf8bitset[0], 1)


# -----------------------------------------------------------------------------
# T7 — RowIndexEntry positions: packed and non-packed.
# -----------------------------------------------------------------------------


def test_row_index_entry_positions() raises:
    var pos = List[Int]()
    pos.append(0)
    pos.append(300)
    pos.append(70000)
    var packed = encode_row_index_entry(pos, List[UInt8]())
    var e = OrcRowIndexEntry.parse(Span(packed), 0, len(packed))
    assert_equal(len(e.positions), 3)
    assert_equal(e.positions[1], 300)
    assert_equal(e.positions[2], 70000)

    var np = List[UInt8]()
    pb_write_varint_field(np, 1, 11)
    _fixed32(np, 5, 1)  # unknown fixed32: skipped
    pb_write_varint_field(np, 1, 22)
    pb_write_varint_field(np, 1, 33)
    var e2 = OrcRowIndexEntry.parse(Span(np), 0, len(np))
    assert_equal(len(e2.positions), 3)
    assert_equal(e2.positions[0], 11)
    assert_equal(e2.positions[2], 33)


# -----------------------------------------------------------------------------
# T8 — BloomFilter numHashFunctions bound + the legacy bitset field.
# -----------------------------------------------------------------------------


def test_bloom_filter_entry_bounds() raises:
    var ok = List[UInt8]()
    _fixed64(ok, 2, 0xFFFF)  # legacy bitset: skipped
    pb_write_varint_field(ok, 1, 64)
    var e = OrcBloomFilterEntry.parse(Span(ok), 0, len(ok))
    assert_equal(e.num_hash_functions, 64)
    assert_false(e.has_utf8bitset)

    var bad = List[UInt8]()
    pb_write_varint_field(bad, 1, 65)
    with assert_raises(
        contains="FIELD_TOO_LARGE: BloomFilter.numHashFunctions = 65 exceeds the maximum 64"
    ):
        _ = OrcBloomFilterEntry.parse(Span(bad), 0, len(bad))


# -----------------------------------------------------------------------------
# T9 — chunk header at the buffer end.
# -----------------------------------------------------------------------------


def test_chunk_header_bounds() raises:
    var b = List[UInt8]()
    b.append(0x0B)  # (5 << 1) | 1
    b.append(0x00)
    b.append(0x00)
    b.append(0xAA)
    b.append(0xBB)
    var h = parse_chunk_header(Span(b), 0)
    assert_equal(h.compressed_length, 5)
    assert_true(h.is_original)
    assert_equal(h.payload_start, 3)
    with assert_raises(contains="chunk header runs past buffer end"):
        _ = parse_chunk_header(Span(b), 3)
    # Exactly three bytes left is enough.
    var h2 = parse_chunk_header(Span(b), 2)
    assert_equal(h2.payload_start, 5)


# -----------------------------------------------------------------------------
# T10 — OrcFileTail.parse refusals.
# -----------------------------------------------------------------------------


def _tail_file(footer: List[UInt8], ps: List[UInt8], lead: Int) -> List[UInt8]:
    """`ORC` + `lead` zero bytes + footer + PostScript + its length byte."""
    var out = _str_bytes("ORC")
    for _ in range(lead):
        out.append(0)
    for i in range(len(footer)):
        out.append(footer[i])
    for i in range(len(ps)):
        out.append(ps[i])
    out.append(UInt8(len(ps)))
    return out^


def test_file_tail_refusals() raises:
    var footer = encode_footer(3, 0, List[List[UInt8]](), List[List[UInt8]](), 0, List[List[UInt8]](), 0)

    # The well-formed baseline parses (so each refusal below is the one change).
    var good = _tail_file(
        footer, encode_post_script(len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"), 0
    )
    var t = OrcFileTail.parse(Span(good))
    assert_equal(t.footer_start, 3)
    assert_equal(t.footer_end, 3 + len(footer))
    assert_equal(t.num_rows(), 0)

    with assert_raises(contains="file too small to be ORC"):
        var tiny = _str_bytes("ORC")
        _ = OrcFileTail.parse(Span(tiny))

    with assert_raises(contains="PostScript length is 0"):
        var z = _str_bytes("ORC")
        z.append(0)
        _ = OrcFileTail.parse(Span(z))

    with assert_raises(contains="PostScript length overruns"):
        var o = _str_bytes("ORC")
        for _ in range(4):
            o.append(0)
        o.append(5)  # ps_start = 8 - 1 - 5 = 2 < 3
        _ = OrcFileTail.parse(Span(o))

    with assert_raises(contains="PostScript magic is not 'ORC' (got 'ORK')"):
        var bad_magic = _tail_file(
            footer, encode_post_script(len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORK"), 0
        )
        _ = OrcFileTail.parse(Span(bad_magic))

    with assert_raises(contains="footer length overruns file"):
        var over = _tail_file(
            footer, encode_post_script(len(footer) + 1, ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORC"), 0
        )
        _ = OrcFileTail.parse(Span(over))

    # Metadata of exactly the lead bytes fits; one more overruns.
    var md_fit = _tail_file(
        footer, encode_post_script(len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 4, "ORC"), 4
    )
    var tm = OrcFileTail.parse(Span(md_fit))
    assert_equal(tm.metadata_start, 3)
    assert_equal(tm.metadata_end, 7)
    with assert_raises(contains="metadata length overruns"):
        var md_over = _tail_file(
            footer, encode_post_script(len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, 5, "ORC"), 4
        )
        _ = OrcFileTail.parse(Span(md_over))


# -----------------------------------------------------------------------------
# T11 — OrcSchema refusals and fallbacks.
# -----------------------------------------------------------------------------


def _node(kind: Int, subtypes: List[Int], names: List[String]) -> OrcRawType:
    return OrcRawType(kind, subtypes.copy(), names.copy(), 0, 0, 0)


def test_schema_refusals_and_fallbacks() raises:
    # node 1 (a STRUCT) links back to itself.
    var cyc = List[OrcRawType]()
    cyc.append(_node(ORC_KIND_STRUCT, [1], ["a"]))
    cyc.append(_node(ORC_KIND_STRUCT, [1], ["b"]))
    with assert_raises(contains="CYCLIC_TYPE_TREE: node 1 references child 1"):
        _ = OrcSchema.from_types(cyc)
    var back = List[OrcRawType]()
    back.append(_node(ORC_KIND_STRUCT, [1, 2], ["a", "b"]))
    back.append(_node(ORC_KIND_INT, List[Int](), List[String]()))
    back.append(_node(ORC_KIND_STRUCT, [1], ["c"]))
    with assert_raises(contains="CYCLIC_TYPE_TREE: node 2 references child 1"):
        _ = OrcSchema.from_types(back)

    # Fewer field names than children: the canonical form names the rest.
    var unnamed = List[OrcRawType]()
    unnamed.append(_node(ORC_KIND_STRUCT, [1, 2], ["x"]))
    unnamed.append(_node(ORC_KIND_INT, List[Int](), List[String]()))
    unnamed.append(_node(ORC_KIND_LONG, List[Int](), List[String]()))
    var s = OrcSchema.from_types(unnamed)
    assert_equal(s.canonical_form(), "struct<x:int,_col1:bigint>")
    with assert_raises(contains="BAD_CHILD_INDEX"):
        _ = s.node(3)
    with assert_raises(contains="BAD_CHILD_INDEX"):
        _ = s.node(-1)
    assert_equal(s.node(2).kind, ORC_KIND_LONG)

    var unk = List[OrcRawType]()
    unk.append(_node(19, List[Int](), List[String]()))
    var su = OrcSchema.from_types(unk)
    with assert_raises(contains="UNKNOWN_TYPE: ORC Type.Kind 19 in orc_node_to_arrow"):
        _ = orc_node_to_arrow(su, 0)


# -----------------------------------------------------------------------------
# T12 — ACID wrapper detection.
# -----------------------------------------------------------------------------


def _acid_names() -> List[String]:
    var n = List[String]()
    n.append("operation")
    n.append("originalTransaction")
    n.append("bucket")
    n.append("rowId")
    n.append("currentTransaction")
    n.append("row")
    return n^


def _acid_schema(names: List[String], row_kind: Int) raises -> OrcSchema:
    var types = List[OrcRawType]()
    types.append(_node(ORC_KIND_STRUCT, [1, 2, 3, 4, 5, 6], names))
    for _ in range(5):
        types.append(_node(ORC_KIND_LONG, List[Int](), List[String]()))
    if row_kind == ORC_KIND_STRUCT:
        # row = struct<a:int, (unnamed):bigint>
        types.append(_node(ORC_KIND_STRUCT, [7, 8], ["a"]))
        types.append(_node(ORC_KIND_INT, List[Int](), List[String]()))
        types.append(_node(ORC_KIND_LONG, List[Int](), List[String]()))
    else:
        types.append(_node(row_kind, List[Int](), List[String]()))
    return OrcSchema.from_types(types)


def test_acid_detection() raises:
    var good = _acid_schema(_acid_names(), ORC_KIND_STRUCT)
    assert_true(is_acid_schema(good))
    assert_equal(acid_row_struct_index(good), 6)
    var cols = acid_output_columns(good, False)
    assert_equal(len(cols.names), 2)
    assert_equal(cols.names[0], "a")
    assert_equal(cols.names[1], "_col1")
    assert_equal(cols.node_idxs[0], 7)
    assert_equal(cols.node_idxs[1], 8)

    # Each wrapper name, renamed alone, is refused.
    for k in range(6):
        var names = _acid_names()
        names[k] = names[k] + "_"
        assert_false(is_acid_schema(_acid_schema(names, ORC_KIND_STRUCT)))
    # `row` that is not a STRUCT.
    assert_false(is_acid_schema(_acid_schema(_acid_names(), ORC_KIND_INT)))
    # A root that is not a STRUCT.
    var leaf = List[OrcRawType]()
    leaf.append(_node(ORC_KIND_INT, List[Int](), List[String]()))
    assert_false(is_acid_schema(OrcSchema.from_types(leaf)))


def main() raises:
    test_name_ladders()
    test_checked_extent_bound()
    test_type_decimal_and_varchar_fields()
    test_varint_messages_skip_len_fields()
    test_column_statistics_double_and_skips()
    test_containers_skip_unknown_fields()
    test_row_index_entry_positions()
    test_bloom_filter_entry_bounds()
    test_chunk_header_bounds()
    test_file_tail_refusals()
    test_schema_refusals_and_fallbacks()
    test_acid_detection()
    print("test_orc_metadata_parse_edges: ALL PASS")
