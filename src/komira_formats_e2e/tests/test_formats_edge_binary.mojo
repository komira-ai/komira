# =============================================================================
# Integer limits and IEEE-754 edge values through Avro OCF and ORC: the
# encoded bytes against the specs, then a bit-exact read-back.
# =============================================================================
#
# The dataset is `edge_numerics.mojo` (int batch: INT64/INT32 limits, -1, 0,
# +-(2^53+1), +-(2^24+1); float batch: -0.0, +0.0, +-smallest subnormal,
# largest subnormal, DBL_MIN, +-DBL_MAX, +-Inf, three NaNs (default payload,
# payload 0xDEADBEEF, sign bit set), and three values needing 17 significant
# digits). Every expected byte below is spelled by hand, not produced by a
# komira encoder, from the source named for it (the spec text, or where the
# spec is silent or differs, the Apache Java reference writer, said so):
#
#   Avro 1.11 "Binary Encoding": `long`/`int` are zig-zag then base-128
#   little-endian varint (zz(n) = (n << 1) ^ (n >> 63)). "a double is
#   written as 8 bytes. The double is converted into a 64-bit integer using
#   a method equivalent to Java's doubleToLongBits and then encoded in
#   little-endian format." doubleToLongBits collapses every NaN to
#   0x7FF8000000000000, so by the spec text rows 11 (payload 0xDEADBEEF) and
#   12 (sign set) would both be written 00 00 00 00 00 00 F8 7F. Apache Avro
#   Java's BinaryData.encodeDouble uses doubleToRawLongBits instead and keeps
#   payload and sign; komira matches the Java writer. The spec test below
#   asserts only "a NaN" for rows 11 and 12; the raw-bits expectation is a
#   separate test that names the Java writer as its oracle. Every other row
#   (including the default NaN, row 10) is the same under both.
#   A record is its fields concatenated; a non-null field has no union tag.
#
#   ORC v1 spec: a signed integer column (LONG, INT) in DIRECT_V2 encoding
#   has its DATA stream in RLE v2; a DIRECT run is a 2-byte header
#   (01 | 5-bit encoded width | 9-bit length-1) followed by the zig-zagged
#   values bit-packed big-endian at the encoded width (code 27 = 32 bits,
#   31 = 64 bits). DOUBLE DATA is 8 bytes per non-null value in IEEE-754
#   layout (spec); the byte order, little-endian, is the Apache ORC Java
#   writer's (SerializationUtils.writeDouble), not spec text. Column statistics are the `ColumnStatistics` protobuf
#   (numberOfValues = 1, intStatistics = 2 {min 1, max 2, sum 3 as sint64},
#   doubleStatistics = 3 {min 1, max 2, sum 3 as fixed64 double},
#   hasNull = 10).
#
# What each test proves, and the defect it catches:
#   * test_avro_long_int_bytes -- the block payload of the int batch equals
#     the hand-spelled varints: INT64_MIN is 9 x FF 01 (zz = 2^64-1),
#     INT64_MAX is FE 8 x FF 01, INT32 limits take 5 bytes. Catches a zig-zag
#     that mishandles the sign shift at the extremes.
#   * test_avro_double_bytes -- (spec) the float batch's payload is each bit
#     pattern little-endian: -0.0 keeps its sign byte (00 .. 80), the
#     subnormals, DBL_MAX and both infinities are exact; rows 11 and 12 are
#     any NaN. Catches a writer that canonicalizes -0.0 or byte-swaps.
#   * test_avro_nan_raw_bits_java_reference -- (Java writer, not spec) rows
#     11 and 12 keep payload and sign, as doubleToRawLongBits does. Catches
#     a writer that diverges from the Java reference by canonicalizing NaN.
#   * test_avro_readback_bit_exact -- read_avro_bytes returns every int and
#     every float bit pattern unchanged (rows 11, 12: the Java-writer bits).
#   * test_orc_rle_v2_and_double_bytes -- an uncompressed ORC of each batch:
#     both int columns are DIRECT_V2, their DATA streams are the DIRECT runs
#     above (7E 05 + 6 x 8 bytes; 76 05 + 6 x 4 bytes), the DOUBLE DATA stream
#     is the 16 bit patterns little-endian.
#   * test_orc_column_statistics -- stripe AND file statistics, as exact
#     protobuf bytes: ints {min INT64_MIN, max INT64_MAX, sum -2, hasNull 0};
#     doubles {min -Inf, max +Inf, sum NaN} -- the NaN rows (not first) are
#     skipped by min/max and poison only the sum, as Apache ORC's Java writer
#     (DoubleStatisticsImpl.updateDouble) does; a column whose FIRST value is
#     NaN gets min = max = that NaN (bits kept), again as the Java writer
#     does. The ORC spec itself says nothing about NaN in statistics; this
#     pins the reference behaviour. A column (INT64_MAX, 1), whose running
#     sum overflows int64, carries no `sum` (field 3) at stripe or file
#     level, as Apache ORC's Java writer (IntegerStatisticsImpl) omits it on
#     overflow; a wrapping writer would write sum = INT64_MIN
#     (18 FF FF FF FF FF FF FF FF FF 01). The int column above is ordered so
#     its running sum never overflows, so its sum (-2) is written.
#   * test_orc_readback_bit_exact -- read_orc_bytes returns every value and
#     bit pattern unchanged, uncompressed and with the default ZSTD codec.
#
# Planted mutants seen red here on the farm (product code, reverted; none
# was caught by the owning package's own tests):
#   * Avro encode_long clamping INT64_MIN to MIN+1: payload starts FD FF..
#     not FF FF.., and the read-back row 0 is -9223372036854775807.
#   * ORC _emit_float64 writing -0.0 as +0.0: DOUBLE DATA row 0 is all
#     zero bytes, and both read-backs return 0x0 for row 0.
#   * Avro encode_double writing every NaN as 0x7FF8000000000000 (what the
#     spec's doubleToLongBits wording allows; a divergence from the Java
#     reference writer, not a spec violation): rows 11 and 12 lose payload
#     and sign in test_avro_nan_raw_bits_java_reference and the read-back.
#   * ORC _acc_dbl skipping NaN (a "NaN-aware" min/max/sum): the NaN-first
#     column's stats become min -1.0, max 1.0 and a non-NaN sum.
# =============================================================================

from komira_avro import (
    AvroWriterOptions,
    decode_ocf_header,
    read_avro_bytes,
    scan_ocf_blocks,
    write_avro_bytes,
)
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_orc import (
    ORC_COMPRESSION_NONE,
    OrcFileTail,
    OrcWriterOptions,
    StripeFooter,
    read_orc_bytes,
    write_orc_bytes,
)

from komira_formats_e2e import (
    F_NAN_PAYLOAD,
    F_NEG_NAN,
    Mismatches,
    be_bytes,
    check_bytes,
    check_float_column_bits,
    check_int_column,
    float_batch_of_bits,
    float_edge_batch,
    float_edge_bits,
    hex_bytes,
    hex_of,
    int64_edges,
    int_edge_batch,
    is_nan_bits,
    le_bytes,
)


# Spec numbers (ORC v1 orc_proto.proto), spelled here rather than imported.
comptime _STREAM_DATA: Int = 1
comptime _ENC_DIRECT_V2: Int = 2


def _cat(mut out: List[UInt8], more: List[UInt8]):
    for i in range(len(more)):
        out.append(more[i])


def _find(hay: Span[UInt8, _], needle: Span[UInt8, _]) -> Int:
    var n = len(needle)
    var i = 0
    while i + n <= len(hay):
        var ok = True
        for k in range(n):
            if hay[i + k] != needle[k]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _all_bits_present(bits: List[UInt64]) -> List[Optional[UInt64]]:
    var out = List[Optional[UInt64]]()
    for i in range(len(bits)):
        out.append(Optional[UInt64](bits[i]))
    return out^


# =============================================================================
# Avro OCF.
# =============================================================================


def _avro_int_payload_want() raises -> List[UInt8]:
    """The int batch's records, field by field (i64 long, i32 int)."""
    var out = List[UInt8]()
    _cat(out, hex_bytes("FF FF FF FF FF FF FF FF FF 01"))  # INT64_MIN
    _cat(out, hex_bytes("FF FF FF FF 0F"))  # INT32_MIN
    _cat(out, hex_bytes("FE FF FF FF FF FF FF FF FF 01"))  # INT64_MAX
    _cat(out, hex_bytes("FE FF FF FF 0F"))  # INT32_MAX
    _cat(out, hex_bytes("01 01"))  # -1, -1
    _cat(out, hex_bytes("00 00"))  # 0, 0
    _cat(out, hex_bytes("82 80 80 80 80 80 80 20"))  # 2^53+1: zz 2^54+2
    _cat(out, hex_bytes("82 80 80 10"))  # 2^24+1: zz 2^25+2
    _cat(out, hex_bytes("81 80 80 80 80 80 80 20"))  # -(2^53+1): zz 2^54+1
    _cat(out, hex_bytes("81 80 80 10"))  # -(2^24+1): zz 2^25+1
    return out^


def _avro_single_block(
    bytes: List[UInt8], rows: Int, label: String, mut m: Mismatches
) raises -> List[UInt8]:
    var bs = Span(bytes)
    var blocks = scan_ocf_blocks(bs)
    if len(blocks) != 1:
        m.add(label + ": " + String(len(blocks)) + " blocks, want 1")
        return List[UInt8]()
    m.check(
        Int(blocks[0].object_count) == rows,
        label + ": block object_count " + String(blocks[0].object_count)
        + ", want " + String(rows),
    )
    var out = List[UInt8]()
    var s = blocks[0].payload_offset
    for i in range(s, s + blocks[0].payload_len):
        out.append(bs[i])
    return out^


def _avro_schema_has(
    bytes: List[UInt8], field_json: String, label: String, mut m: Mismatches
) raises:
    var h = decode_ocf_header(Span(bytes))
    var head = Span(bytes)[0 : h.header_len]
    m.check(
        _find(head, field_json.as_bytes()) >= 0,
        label + ": writer schema lacks " + field_json,
    )


def test_avro_long_int_bytes() raises:
    var m = Mismatches()
    var bytes = write_avro_bytes(int_edge_batch(), AvroWriterOptions())
    _avro_schema_has(bytes, '{"name":"i64","type":"long"}', "avro int", m)
    _avro_schema_has(bytes, '{"name":"i32","type":"int"}', "avro int", m)
    var payload = _avro_single_block(bytes, 6, "avro int", m)
    var want = _avro_int_payload_want()
    check_bytes(m, Span(payload), Span(want), "avro int payload")
    m.raise_if_any("test_avro_long_int_bytes")


def test_avro_double_bytes() raises:
    var m = Mismatches()
    var bits = float_edge_bits()
    var bytes = write_avro_bytes(float_edge_batch(), AvroWriterOptions())
    _avro_schema_has(bytes, '{"name":"f64","type":"double"}', "avro f64", m)
    var payload = _avro_single_block(bytes, len(bits), "avro f64", m)
    if len(payload) != 8 * len(bits):
        m.add(
            "avro f64 payload: " + String(len(payload)) + " bytes, want "
            + String(8 * len(bits)) + ": [" + hex_of(Span(payload)) + "]"
        )
    else:
        for r in range(len(bits)):
            var got = Span(payload)[8 * r : 8 * r + 8]
            if r == F_NAN_PAYLOAD or r == F_NEG_NAN:
                # Spec (doubleToLongBits) gives 7FF8000000000000; the Java
                # writer gives the raw bits. Both are a NaN: assert that.
                var g = UInt64(0)
                for k in range(8):
                    g |= UInt64(got[k]) << UInt64(8 * k)
                m.check(
                    is_nan_bits(g),
                    "avro f64 row " + String(r) + ": [" + hex_of(got)
                    + "] is not a little-endian NaN",
                )
                continue
            var want = le_bytes(bits[r], 8)
            check_bytes(m, got, Span(want), "avro f64 row " + String(r))
    m.raise_if_any("test_avro_double_bytes")


def test_avro_nan_raw_bits_java_reference() raises:
    """Oracle: Apache Avro Java BinaryData.encodeDouble, which writes
    Double.doubleToRawLongBits(d) little-endian. Not the spec text (see the
    header): a canonicalizing writer conforms to the spec and fails here."""
    var m = Mismatches()
    var bits = float_edge_bits()
    var bytes = write_avro_bytes(float_edge_batch(), AvroWriterOptions())
    var payload = _avro_single_block(bytes, len(bits), "avro f64 raw", m)
    if len(payload) == 8 * len(bits):
        var rows = [F_NAN_PAYLOAD, F_NEG_NAN]
        for i in range(len(rows)):
            var r = rows[i]
            var want = le_bytes(bits[r], 8)
            check_bytes(
                m, Span(payload)[8 * r : 8 * r + 8], Span(want),
                "avro f64 raw-bits row " + String(r),
            )
    else:
        m.add("avro f64 raw: payload is " + String(len(payload)) + " bytes")
    m.raise_if_any("test_avro_nan_raw_bits_java_reference")


def test_avro_readback_bit_exact() raises:
    var m = Mismatches()
    var ib = write_avro_bytes(int_edge_batch(), AvroWriterOptions())
    var ir = read_avro_bytes(Span(ib))
    check_int_column(m, ir, "i64", int64_edges(), "avro")
    var want32 = List[Int64]()
    want32.append(Int64(-2147483648))
    want32.append(Int64(2147483647))
    want32.append(Int64(-1))
    want32.append(Int64(0))
    want32.append(Int64(16777217))
    want32.append(Int64(-16777217))
    check_int_column(m, ir, "i32", want32, "avro")
    var fb = write_avro_bytes(float_edge_batch(), AvroWriterOptions())
    var fr = read_avro_bytes(Span(fb))
    check_float_column_bits(
        m, fr, "f64", _all_bits_present(float_edge_bits()), "avro"
    )
    m.raise_if_any("test_avro_readback_bit_exact")


# =============================================================================
# ORC: stream bytes and statistics.
# =============================================================================


def _orc_none(rb: RecordBatch) raises -> List[UInt8]:
    return write_orc_bytes(
        rb, OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    )


def _orc_stream(
    bytes: List[UInt8], column: Int, kind: Int, label: String, mut m: Mismatches
) raises -> List[UInt8]:
    """The bytes of stream (`column`, `kind`) of the only stripe. Streams lie
    back to back from the stripe offset in stripe-footer order (ORC spec)."""
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    if len(tail.footer.stripes) != 1:
        m.add(label + ": " + String(len(tail.footer.stripes)) + " stripes, want 1")
        return List[UInt8]()
    ref si = tail.footer.stripes[0]
    var fstart = si.offset + si.index_length + si.data_length
    var sf = StripeFooter.parse(bs[fstart : fstart + si.footer_length])
    var off = si.offset
    for k in range(len(sf.streams)):
        if sf.streams[k].column == column and sf.streams[k].kind == kind:
            var out = List[UInt8]()
            for i in range(off, off + sf.streams[k].length):
                out.append(bs[i])
            return out^
        off += sf.streams[k].length
    m.add(label + ": no stream kind " + String(kind) + " for node " + String(column))
    return List[UInt8]()


def _orc_encoding_kind(bytes: List[UInt8], column: Int) raises -> Int:
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    ref si = tail.footer.stripes[0]
    var fstart = si.offset + si.index_length + si.data_length
    var sf = StripeFooter.parse(bs[fstart : fstart + si.footer_length])
    return sf.columns[column].kind


def test_orc_rle_v2_and_double_bytes() raises:
    var m = Mismatches()
    var ib = _orc_none(int_edge_batch())
    m.check(_orc_encoding_kind(ib, 1) == _ENC_DIRECT_V2, "orc i64: not DIRECT_V2")
    m.check(_orc_encoding_kind(ib, 2) == _ENC_DIRECT_V2, "orc i32: not DIRECT_V2")

    # i64: DIRECT, width code 31 (64 bits), 6 values: 0x7E 0x05.
    var want64 = hex_bytes("7E 05")
    _cat(want64, be_bytes(UInt64(0xFFFFFFFFFFFFFFFF), 8))  # zz(INT64_MIN)
    _cat(want64, be_bytes(UInt64(0xFFFFFFFFFFFFFFFE), 8))  # zz(INT64_MAX)
    _cat(want64, be_bytes(UInt64(1), 8))  # zz(-1)
    _cat(want64, be_bytes(UInt64(0), 8))  # zz(0)
    _cat(want64, be_bytes(UInt64(0x0040000000000002), 8))  # zz(2^53+1)
    _cat(want64, be_bytes(UInt64(0x0040000000000001), 8))  # zz(-(2^53+1))
    var got64 = _orc_stream(ib, 1, _STREAM_DATA, "orc i64", m)
    check_bytes(m, Span(got64), Span(want64), "orc i64 DATA")

    # i32: DIRECT, width code 27 (32 bits), 6 values: 0x76 0x05.
    var want32 = hex_bytes("76 05")
    _cat(want32, be_bytes(UInt64(0xFFFFFFFF), 4))  # zz(INT32_MIN)
    _cat(want32, be_bytes(UInt64(0xFFFFFFFE), 4))  # zz(INT32_MAX)
    _cat(want32, be_bytes(UInt64(1), 4))
    _cat(want32, be_bytes(UInt64(0), 4))
    _cat(want32, be_bytes(UInt64(0x02000002), 4))  # zz(2^24+1)
    _cat(want32, be_bytes(UInt64(0x02000001), 4))  # zz(-(2^24+1))
    var got32 = _orc_stream(ib, 2, _STREAM_DATA, "orc i32", m)
    check_bytes(m, Span(got32), Span(want32), "orc i32 DATA")

    var bits = float_edge_bits()
    var fb = _orc_none(float_edge_batch())
    var wantf = List[UInt8]()
    for r in range(len(bits)):
        _cat(wantf, le_bytes(bits[r], 8))
    var gotf = _orc_stream(fb, 1, _STREAM_DATA, "orc f64", m)
    check_bytes(m, Span(gotf), Span(wantf), "orc f64 DATA")
    m.raise_if_any("test_orc_rle_v2_and_double_bytes")


def _pb_varint(bs: Span[UInt8, _], mut pos: Int) raises -> UInt64:
    var v: UInt64 = 0
    var shift: UInt64 = 0
    while True:
        if pos >= len(bs) or shift > 63:
            raise Error("protobuf: truncated varint")
        var b = bs[pos]
        pos += 1
        v |= UInt64(b & 0x7F) << shift
        if (b & 0x80) == 0:
            return v
        shift += 7


def _pb_len_fields(
    bs: Span[UInt8, _], start: Int, end: Int, field: Int
) raises -> List[Tuple[Int, Int]]:
    """(start, end) of each length-delimited occurrence of `field` in the
    message bytes [start, end); other fields are skipped by wire type."""
    var out = List[Tuple[Int, Int]]()
    var pos = start
    while pos < end:
        var tag = _pb_varint(bs, pos)
        var f = Int(tag >> 3)
        var wt = Int(tag & 7)
        if wt == 0:
            _ = _pb_varint(bs, pos)
        elif wt == 1:
            pos += 8
        elif wt == 5:
            pos += 4
        elif wt == 2:
            var n = Int(_pb_varint(bs, pos))
            if f == field:
                out.append((pos, pos + n))
            pos += n
        else:
            raise Error("protobuf: wire type " + String(wt))
    return out^


def _column_stats_bytes(
    bytes: List[UInt8], node: Int, label: String, mut m: Mismatches
) raises -> List[List[UInt8]]:
    """[stripe ColumnStatistics, file ColumnStatistics] of `node`: the stripe
    one from Metadata.stripeStats[0].colStats (fields 1, 1), the file one from
    Footer.statistics (field 7)."""
    var bs = Span(bytes)
    var tail = OrcFileTail.parse(bs)
    var out = List[List[UInt8]]()
    var stripes = _pb_len_fields(bs, tail.metadata_start, tail.metadata_end, 1)
    var file_stats = _pb_len_fields(bs, tail.footer_start, tail.footer_end, 7)
    if len(stripes) != 1:
        m.add(label + ": " + String(len(stripes)) + " StripeStatistics, want 1")
        return out^
    var cols = _pb_len_fields(bs, stripes[0][0], stripes[0][1], 1)
    if node >= len(cols) or node >= len(file_stats):
        m.add(label + ": no statistics for node " + String(node))
        return out^
    var a = List[UInt8]()
    for i in range(cols[node][0], cols[node][1]):
        a.append(bs[i])
    var b = List[UInt8]()
    for i in range(file_stats[node][0], file_stats[node][1]):
        b.append(bs[i])
    out.append(a^)
    out.append(b^)
    return out^


def _check_double_stats(
    got: List[UInt8],
    count: Int,
    min_bits: UInt64,
    max_bits: UInt64,
    label: String,
    mut m: Mismatches,
) raises:
    """numberOfValues, doubleStatistics {min, max, sum = any NaN}, hasNull 0.
    The sum's NaN bits are the platform's (Inf + -Inf), so only NaN-ness is
    asserted for it."""
    var head = hex_bytes("08")
    _cat(head, hex_bytes(String("10") if count == 16 else String("03")))
    _cat(head, hex_bytes("1A 1B 09"))
    _cat(head, le_bytes(min_bits, 8))
    _cat(head, hex_bytes("11"))
    _cat(head, le_bytes(max_bits, 8))
    _cat(head, hex_bytes("19"))
    if len(got) != len(head) + 8 + 2:
        m.add(label + ": " + String(len(got)) + " bytes [" + hex_of(Span(got)) + "]")
        return
    check_bytes(m, Span(got)[0 : len(head)], Span(head), label + " min/max")
    var sum_bits: UInt64 = 0
    for k in range(8):
        sum_bits |= UInt64(got[len(head) + k]) << UInt64(8 * k)
    m.check(is_nan_bits(sum_bits), label + ": sum is not NaN")
    var tail = hex_bytes("50 00")
    check_bytes(m, Span(got)[len(head) + 8 :], Span(tail), label + " hasNull")


def test_orc_column_statistics() raises:
    var m = Mismatches()
    var ib = _orc_none(int_edge_batch())
    var i64_want = hex_bytes(
        "08 06 12 18"
        " 08 FF FF FF FF FF FF FF FF FF 01"  # min INT64_MIN (sint64)
        " 10 FE FF FF FF FF FF FF FF FF 01"  # max INT64_MAX
        " 18 03"  # sum -2
        " 50 00"  # hasNull false
    )
    var i32_want = hex_bytes(
        "08 06 12 0E 08 FF FF FF FF 0F 10 FE FF FF FF 0F 18 03 50 00"
    )
    var s1 = _column_stats_bytes(ib, 1, "orc i64 stats", m)
    var s2 = _column_stats_bytes(ib, 2, "orc i32 stats", m)
    var where = [String("stripe"), String("file")]
    for k in range(len(s1)):
        check_bytes(m, Span(s1[k]), Span(i64_want), "orc i64 " + where[k] + " stats")
    for k in range(len(s2)):
        check_bytes(m, Span(s2[k]), Span(i32_want), "orc i32 " + where[k] + " stats")

    # The edge column: -0.0 first, NaN rows later. min -Inf, max +Inf.
    var fb = _orc_none(float_edge_batch())
    var sf = _column_stats_bytes(fb, 1, "orc f64 stats", m)
    for k in range(len(sf)):
        _check_double_stats(
            sf[k], 16, UInt64(0xFFF0000000000000), UInt64(0x7FF0000000000000),
            "orc f64 " + where[k] + " stats", m,
        )

    # A column whose FIRST value is NaN (payload kept): min = max = it.
    var nan_first = List[UInt64]()
    nan_first.append(UInt64(0x7FF80000DEADBEEF))
    nan_first.append(UInt64(0x3FF0000000000000))  # 1.0
    nan_first.append(UInt64(0xBFF0000000000000))  # -1.0
    var nb = _orc_none(float_batch_of_bits(nan_first))
    var sn = _column_stats_bytes(nb, 1, "orc NaN-first stats", m)
    for k in range(len(sn)):
        _check_double_stats(
            sn[k], 3, UInt64(0x7FF80000DEADBEEF), UInt64(0x7FF80000DEADBEEF),
            "orc NaN-first " + where[k] + " stats", m,
        )

    # A column whose running sum overflows int64: no field 3 (sum).
    var ov = PrimitiveArray[DType.int64].allocate(2)
    ov.set(0, Int64.MAX)
    ov.set(1, Int64(1))
    var osb = SchemaBuilder()
    osb.add_field(Field("i64", ArrowType.INT64, False))
    var ob = RecordBatchBuilder.with_capacity(1)
    ob.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](ov^, ArrowType.INT64)
    )
    var obytes = _orc_none(ob.build(osb.build()))
    var ov_want = hex_bytes(
        "08 02 12 0D"
        " 08 02"  # min 1
        " 10 FE FF FF FF FF FF FF FF FF 01"  # max INT64_MAX; no sum field
        " 50 00"  # hasNull false
    )
    var so = _column_stats_bytes(obytes, 1, "orc i64 overflow stats", m)
    for k in range(len(so)):
        check_bytes(
            m, Span(so[k]), Span(ov_want), "orc i64 overflow " + where[k] + " stats"
        )
    m.raise_if_any("test_orc_column_statistics")


def _orc_opts(k: Int) -> OrcWriterOptions:
    """k = 0: uncompressed; k = 1: the default options (ZSTD)."""
    if k == 0:
        return OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    return OrcWriterOptions.default()


def test_orc_readback_bit_exact() raises:
    var m = Mismatches()
    var want32 = List[Int64]()
    want32.append(Int64(-2147483648))
    want32.append(Int64(2147483647))
    want32.append(Int64(-1))
    want32.append(Int64(0))
    want32.append(Int64(16777217))
    want32.append(Int64(-16777217))
    var names = [String("orc none"), String("orc default")]
    for k in range(2):
        var ib = write_orc_bytes(int_edge_batch(), _orc_opts(k))
        var ir = read_orc_bytes(Span(ib))
        check_int_column(m, ir, "i64", int64_edges(), names[k])
        check_int_column(m, ir, "i32", want32, names[k])
        var fb = write_orc_bytes(float_edge_batch(), _orc_opts(k))
        var fr = read_orc_bytes(Span(fb))
        check_float_column_bits(
            m, fr, "f64", _all_bits_present(float_edge_bits()), names[k]
        )
    m.raise_if_any("test_orc_readback_bit_exact")


def main() raises:
    var failures = List[String]()
    try:
        test_avro_long_int_bytes()
    except e:
        failures.append(String(e))
    try:
        test_avro_double_bytes()
    except e:
        failures.append(String(e))
    try:
        test_avro_nan_raw_bits_java_reference()
    except e:
        failures.append(String(e))
    try:
        test_avro_readback_bit_exact()
    except e:
        failures.append(String(e))
    try:
        test_orc_rle_v2_and_double_bytes()
    except e:
        failures.append(String(e))
    try:
        test_orc_column_statistics()
    except e:
        failures.append(String(e))
    try:
        test_orc_readback_bit_exact()
    except e:
        failures.append(String(e))
    if len(failures) > 0:
        var msg = String("test_formats_edge_binary FAILED:")
        for i in range(len(failures)):
            msg += "\n" + failures[i]
        raise Error(msg)
    print("test_formats_edge_binary: ALL PASS")
