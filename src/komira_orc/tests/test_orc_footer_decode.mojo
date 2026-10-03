# =============================================================================
# test_orc_footer_decode.mojo — ORC Footer + OrcFileTail end-to-end decode.
# =============================================================================
#
# Acceptance: Footer decode (stripes + types + numberOfRows).
#
# The fixture is a hand-emitted, complete (synthetic) ORC file tail for a
# SF-tiny lineitem-shaped file: a `struct<l_orderkey:bigint,l_partkey:int,
# l_comment:string>` schema, 2 stripes, 2048 rows, NONE codec. Building the
# whole tail by hand exercises BOTH the wire-format spec AND the decoder, and
# round-trips offset arithmetic (PostScript length byte -> PostScript ->
# Footer -> Metadata spans).
#
# Coverage:
#   T1  Footer.parse: headerLength + contentLength + numberOfRows + stride.
#   T2  Footer.stripes: 2 stripes with correct offsets + row counts.
#   T3  Footer.types: 4-node flat tree (root struct + 3 leaves).
#   T4  OrcFileTail.parse: full tail walk from the trailing length byte.
#   T5  OrcFileTail rejects a file with a missing leading "ORC" magic.
#   T6  OrcFileTail rejects a non-NONE codec (clear error).
#   T7  StripeInformation.stripe_footer_start/end byte arithmetic.
#   T8  Metadata.parse: stripe-stats entry count.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    PostScript,
    Footer,
    Metadata,
    StripeInformation,
    OrcRawType,
    OrcFileTail,
    PB_WIRE_VARINT,
    PB_WIRE_LEN,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_INT,
    ORC_KIND_STRING,
)


# -----------------------------------------------------------------------------
# In-test protobuf encoders.
# -----------------------------------------------------------------------------


def _pb_varint(n: UInt64, mut out: List[UInt8]):
    var v = n
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _pb_tag(field_number: Int, wire_type: Int, mut out: List[UInt8]):
    _pb_varint(UInt64((field_number << 3) | wire_type), out)


def _pb_varint_field(field_number: Int, value: UInt64, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_VARINT, out)
    _pb_varint(value, out)


def _pb_string_field(field_number: Int, s: String, mut out: List[UInt8]):
    _pb_tag(field_number, PB_WIRE_LEN, out)
    var b = s.as_bytes()
    _pb_varint(UInt64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _pb_message_field(field_number: Int, body: List[UInt8], mut out: List[UInt8]):
    """Append a length-delimited embedded message field."""
    _pb_tag(field_number, PB_WIRE_LEN, out)
    _pb_varint(UInt64(len(body)), out)
    for i in range(len(body)):
        out.append(body[i])


def _enc_stripe(
    offset: Int, index_len: Int, data_len: Int, footer_len: Int, rows: Int
) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(offset), b)
    _pb_varint_field(2, UInt64(index_len), b)
    _pb_varint_field(3, UInt64(data_len), b)
    _pb_varint_field(4, UInt64(footer_len), b)
    _pb_varint_field(5, UInt64(rows), b)
    return b^


def _enc_type_leaf(kind: Int) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(kind), b)
    return b^


def _enc_struct_root(child_ids: List[Int], names: List[String]) -> List[UInt8]:
    var b = List[UInt8]()
    _pb_varint_field(1, UInt64(ORC_KIND_STRUCT), b)
    for i in range(len(child_ids)):
        _pb_varint_field(2, UInt64(child_ids[i]), b)
    for i in range(len(names)):
        _pb_string_field(3, names[i], b)
    return b^


def _build_footer() -> List[UInt8]:
    """Build a Footer for struct<l_orderkey:bigint,l_partkey:int,
    l_comment:string>, 2 stripes, 2048 rows."""
    var out = List[UInt8]()
    _pb_varint_field(1, 3, out)  # headerLength = 3 ("ORC")
    _pb_varint_field(2, 4096, out)  # contentLength

    # stripes (field 3): 2 stripes.
    _pb_message_field(3, _enc_stripe(3, 100, 1900, 48, 1024), out)
    _pb_message_field(3, _enc_stripe(2051, 100, 1900, 48, 1024), out)

    # types (field 4): flat pre-order. Index 0 = root struct with children
    # [1,2,3]; indices 1,2,3 = bigint / int / string leaves.
    var child_ids = List[Int]()
    child_ids.append(1)
    child_ids.append(2)
    child_ids.append(3)
    var names = List[String]()
    names.append(String("l_orderkey"))
    names.append(String("l_partkey"))
    names.append(String("l_comment"))
    _pb_message_field(4, _enc_struct_root(child_ids, names), out)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_LONG), out)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_INT), out)
    _pb_message_field(4, _enc_type_leaf(ORC_KIND_STRING), out)

    _pb_varint_field(6, 2048, out)  # numberOfRows
    _pb_varint_field(8, 10000, out)  # rowIndexStride
    return out^


def _build_metadata(stripe_stats_count: Int) -> List[UInt8]:
    """Build a Metadata blob with N (empty) stripeStats entries (field 1)."""
    var out = List[UInt8]()
    for _i in range(stripe_stats_count):
        var empty = List[UInt8]()
        _pb_message_field(1, empty, out)
    return out^


def _build_postscript(footer_len: Int, metadata_len: Int, codec: Int) -> List[UInt8]:
    var out = List[UInt8]()
    _pb_varint_field(1, UInt64(footer_len), out)
    _pb_varint_field(2, UInt64(codec), out)
    _pb_varint_field(3, 262144, out)
    _pb_varint_field(4, 0, out)
    _pb_varint_field(4, 12, out)
    _pb_varint_field(5, UInt64(metadata_len), out)
    _pb_string_field(8000, String("ORC"), out)
    return out^


def _build_orc_file(codec: Int, with_magic: Bool) -> List[UInt8]:
    """Assemble a complete (synthetic) ORC file tail: magic + content +
    metadata + footer + postscript + length byte."""
    var f = List[UInt8]()
    # Leading magic + 4096 bytes of stripe content placeholder.
    if with_magic:
        f.append(UInt8(ord("O")))
        f.append(UInt8(ord("R")))
        f.append(UInt8(ord("C")))
    else:
        f.append(UInt8(ord("X")))
        f.append(UInt8(ord("Y")))
        f.append(UInt8(ord("Z")))
    for _i in range(4096):
        f.append(0)

    var metadata = _build_metadata(2)
    for i in range(len(metadata)):
        f.append(metadata[i])

    var footer = _build_footer()
    for i in range(len(footer)):
        f.append(footer[i])

    var ps = _build_postscript(len(footer), len(metadata), codec)
    for i in range(len(ps)):
        f.append(ps[i])

    # Trailing PostScript length byte.
    f.append(UInt8(len(ps)))
    return f^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_footer_scalars() raises:
    """T1: Footer scalars decode."""
    var footer = Footer.parse(Span(_build_footer()))
    assert_equal(footer.header_length, 3)
    assert_equal(footer.content_length, 4096)
    assert_equal(footer.number_of_rows, 2048)
    assert_equal(footer.row_index_stride, 10000)


def test_footer_stripes() raises:
    """T2: Footer.stripes — 2 stripes with correct offsets + row counts."""
    var footer = Footer.parse(Span(_build_footer()))
    assert_equal(footer.num_stripes(), 2)
    assert_equal(footer.stripes[0].offset, 3)
    assert_equal(footer.stripes[0].number_of_rows, 1024)
    assert_equal(footer.stripes[1].offset, 2051)
    assert_equal(footer.stripes[1].number_of_rows, 1024)


def test_footer_types() raises:
    """T3: Footer.types — 4-node flat tree."""
    var footer = Footer.parse(Span(_build_footer()))
    assert_equal(len(footer.types), 4)
    assert_equal(footer.types[0].kind, ORC_KIND_STRUCT)
    assert_equal(len(footer.types[0].subtypes), 3)
    assert_equal(footer.types[0].subtypes[0], 1)
    assert_equal(footer.types[0].subtypes[2], 3)
    assert_equal(len(footer.types[0].field_names), 3)
    assert_equal(footer.types[0].field_names[0], String("l_orderkey"))
    assert_equal(footer.types[1].kind, ORC_KIND_LONG)
    assert_equal(footer.types[2].kind, ORC_KIND_INT)
    assert_equal(footer.types[3].kind, ORC_KIND_STRING)


def test_file_tail_end_to_end() raises:
    """T4: OrcFileTail walks the whole tail from the trailing length byte."""
    var f = _build_orc_file(ORC_COMPRESSION_NONE, True)
    var tail = OrcFileTail.parse(Span(f))
    assert_equal(tail.post_script.magic, String("ORC"))
    assert_equal(tail.post_script.compression, ORC_COMPRESSION_NONE)
    assert_equal(tail.num_stripes(), 2)
    assert_equal(tail.num_rows(), 2048)
    assert_equal(tail.footer.number_of_rows, 2048)
    # The footer span the tail located must equal the postscript footer_length.
    assert_equal(
        tail.footer_end - tail.footer_start, tail.post_script.footer_length
    )
    assert_equal(
        tail.metadata_end - tail.metadata_start, tail.post_script.metadata_length
    )


def test_file_tail_missing_magic_raises() raises:
    """T5: a file without the leading 'ORC' magic raises."""
    var f = _build_orc_file(ORC_COMPRESSION_NONE, False)
    var raised = False
    try:
        var _t = OrcFileTail.parse(Span(f))
    except:
        raised = True
    assert_true(raised, "missing leading ORC magic must raise")


def test_file_tail_unsupported_codec_raises() raises:
    """T6: a non-NONE codec raises a clear error from OrcFileTail.parse."""
    var f = _build_orc_file(ORC_COMPRESSION_ZSTD, True)
    var raised = False
    try:
        var _t = OrcFileTail.parse(Span(f))
    except:
        raised = True
    assert_true(raised, "ZSTD codec must raise (OrcFileTail.parse is NONE only)")


def test_stripe_footer_byte_arithmetic() raises:
    """T7: StripeInformation footer-span arithmetic is index+data then footer.
    """
    var si = StripeInformation(
        offset=3,
        index_length=100,
        data_length=1900,
        footer_length=48,
        number_of_rows=1024,
    )
    # footer starts after offset + index + data = 3 + 100 + 1900 = 2003.
    assert_equal(si.stripe_footer_start(), 2003)
    assert_equal(si.stripe_footer_end(), 2051)


def test_metadata_stripe_stats_count() raises:
    """T8: Metadata.parse counts stripeStats entries."""
    var md = Metadata.parse(Span(_build_metadata(2)))
    assert_equal(md.stripe_stats_count, 2)
    var md0 = Metadata.parse(Span(_build_metadata(0)))
    assert_equal(md0.stripe_stats_count, 0)


def main() raises:
    test_footer_scalars()
    test_footer_stripes()
    test_footer_types()
    test_file_tail_end_to_end()
    test_file_tail_missing_magic_raises()
    test_file_tail_unsupported_codec_raises()
    test_stripe_footer_byte_arithmetic()
    test_metadata_stripe_stats_count()
    print("test_orc_footer_decode: ALL PASS")
