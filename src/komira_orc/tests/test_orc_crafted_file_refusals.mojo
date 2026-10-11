# =============================================================================
# test_orc_crafted_file_refusals.mojo — whole-file reads of hand-assembled ORC
# files whose metadata is inconsistent in exactly one way.
# =============================================================================
#
# The files are assembled here from the package's protobuf encoders (header
# "ORC", stripes of [index][data][StripeFooter], Metadata, Footer,
# PostScript, its length byte), so each one differs from a readable file in
# only the field a case names. The readable baseline is read back first.
#
#   T1  The codec-aware tail walk refuses: a file shorter than 4 bytes, a
#       missing leading magic, a PostScript length of 0, a PostScript running
#       into the magic, a trailing magic other than "ORC", and (compressed
#       codec) Footer and Metadata lengths running into the magic.
#   T2  Byte ranges: a stream running past the end of the file is refused
#       naming the stream; `_checked_file_span` refuses negative and inverted
#       ranges; `_locate_streams` refuses a negative stream length.
#   T3  Schema shape: a root that is not a struct (whole-file, stride-skip
#       and pruned reads, and the output-schema builder); a projection index
#       out of range; root fields with no names (named `_col<i>` by the
#       whole-file, stride-skip, pruned and nested reads); a root struct with
#       no children (a 0-column batch).
#   T4  Row counts: Footer.numberOfRows and a stripe's numberOfRows larger
#       than the file could back, stripes declaring more rows than the
#       Footer.
#   T5  A stripe with no ColumnEncoding for a column (whole-file and pruned
#       reads); a column whose DATA stream does not decode (the column's
#       error is re-raised naming it).
#   T6  Nested files: a projection is refused; a non-struct root; a
#       zero-stripe nested file.
#   T7  Stride-skip without a stride size (Footer.rowIndexStride 0) and with
#       ROW_INDEX entries for one column only: the missing statistics keep the
#       stride; a bloom entry with an empty bitset keeps it. Pruned read with a Metadata blob missing a column's
#       statistics, and with no Metadata blob: every stripe kept.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_raises

from komira_plan_expr.expr import Expr, BIN_LE, BIN_GT, BIN_EQ
from komira_plan_expr.scalar_value import ScalarValue

from komira_orc import (
    read_orc_bytes,
    read_orc_bytes_projected,
    read_orc_bytes_filtered,
    read_orc_bytes_pruned,
    OrcSchema,
    OrcRawType,
    OrcStream,
    OrcColumnEncoding,
    StripeFooter,
    StripeInformation,
    encode_type_node,
    encode_stream,
    encode_column_encoding,
    encode_stripe_footer,
    encode_stripe_information,
    encode_footer,
    encode_post_script,
    encode_metadata,
    encode_stripe_statistics,
    encode_column_statistics,
    encode_integer_statistics,
    encode_row_index,
    encode_row_index_entry,
    encode_bloom_filter,
    encode_bloom_filter_index,
    encode_int_rle_v2,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_KIND_STRUCT,
    ORC_KIND_LONG,
    ORC_KIND_LIST,
    ORC_STREAM_DATA,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_ENCODING_DIRECT,
    ORC_ENCODING_DIRECT_V2,
)
from komira_orc.orc_reader import _checked_file_span, _locate_streams, _build_output_schema


# -----------------------------------------------------------------------------
# The assembler.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _S(Copyable, Movable):
    """One stripe: index bytes, data bytes, Stream protos (index first), the
    ColumnEncodings, and the row count its StripeInformation declares."""

    var index: List[UInt8]
    var data: List[UInt8]
    var streams: List[List[UInt8]]
    var encodings: List[List[UInt8]]
    var rows: Int


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _append(mut out: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        out.append(b[i])


def _assemble(
    stripes: List[_S],
    types: List[List[UInt8]],
    footer_rows: Int,
    stride: Int,
    metadata: List[UInt8],
) -> List[UInt8]:
    var out = _bytes("ORC")
    var infos = List[List[UInt8]]()
    for s in range(len(stripes)):
        ref st = stripes[s]
        var offset = len(out)
        _append(out, st.index)
        _append(out, st.data)
        var sf = encode_stripe_footer(st.streams, st.encodings, "UTC")
        _append(out, sf)
        infos.append(
            encode_stripe_information(offset, len(st.index), len(st.data), len(sf), st.rows)
        )
    _append(out, metadata)
    var footer = encode_footer(3, len(out) - 3, infos, types, footer_rows, List[List[UInt8]](), stride)
    _append(out, footer)
    var ps = encode_post_script(len(footer), ORC_COMPRESSION_NONE, 0, 0, 12, len(metadata), "ORC")
    _append(out, ps)
    out.append(UInt8(len(ps)))
    return out^


def _struct(n: Int, names: List[String]) -> List[UInt8]:
    var subs = List[Int]()
    for i in range(n):
        subs.append(i + 1)
    return encode_type_node(ORC_KIND_STRUCT, subs, names, 0, 0, 0)


def _long_t() -> List[UInt8]:
    return encode_type_node(ORC_KIND_LONG, List[Int](), List[String](), 0, 0, 0)


def _names(*n: String) -> List[String]:
    var out = List[String]()
    for i in range(len(n)):
        out.append(n[i])
    return out^


def _flat_types(n_cols: Int, names: List[String]) -> List[List[UInt8]]:
    var t = List[List[UInt8]]()
    t.append(_struct(n_cols, names))
    for _ in range(n_cols):
        t.append(_long_t())
    return t^


def _encodings(n_nodes: Int) -> List[List[UInt8]]:
    var e = List[List[UInt8]]()
    e.append(encode_column_encoding(ORC_ENCODING_DIRECT, 0))
    for _ in range(n_nodes - 1):
        e.append(encode_column_encoding(ORC_ENCODING_DIRECT_V2, 0))
    return e^


def _vals(lo: Int, n: Int) -> List[Int64]:
    var v = List[Int64]()
    for i in range(n):
        v.append(Int64(lo + i))
    return v^


def _long_stripe(cols: List[List[Int64]]) raises -> _S:
    """One stripe of bigint columns (nodes 1..n), DATA streams only."""
    var data = List[UInt8]()
    var streams = List[List[UInt8]]()
    for c in range(len(cols)):
        var d = encode_int_rle_v2(cols[c], True)
        streams.append(encode_stream(ORC_STREAM_DATA, c + 1, len(d)))
        _append(data, d)
    var rows = len(cols[0]) if len(cols) > 0 else 0
    return _S(List[UInt8](), data^, streams^, _encodings(len(cols) + 1), rows)


def _one_col(lo: Int, n: Int) -> List[List[Int64]]:
    var c = List[List[Int64]]()
    c.append(_vals(lo, n))
    return c^


def _le(name: String, v: Int) -> Expr:
    return Expr.binary(BIN_LE, Expr.col_ref(name), Expr.literal(ScalarValue.from_int64(Int64(v))))


def _gt(name: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int64(Int64(v))))


def _one_stripe_file(footer_rows: Int) raises -> List[UInt8]:
    var s = List[_S]()
    s.append(_long_stripe(_one_col(10, 4)))
    return _assemble(s, _flat_types(1, _names("a")), footer_rows, 0, List[UInt8]())


# -----------------------------------------------------------------------------
# T1 — tail walk.
# -----------------------------------------------------------------------------


def test_tail_refusals() raises:
    var good = _one_stripe_file(4)
    var rb = read_orc_bytes(Span(good))
    assert_equal(rb.num_rows(), 4)
    assert_equal(Int(rb.column_as_primitive_int64(0).get(3)), 13)

    with assert_raises(contains="file too small to be ORC"):
        _ = read_orc_bytes(Span(_bytes("ORC")))
    with assert_raises(contains="missing leading 'ORC' magic"):
        var x = good.copy()
        x[0] = UInt8(ord("X"))
        _ = read_orc_bytes(Span(x))
    with assert_raises(contains="PostScript length is 0"):
        var z = _bytes("ORC")
        z.append(0)
        _ = read_orc_bytes(Span(z))
    with assert_raises(contains="PostScript overruns start"):
        var o = _bytes("ORC")
        for _ in range(4):
            o.append(0)
        o.append(5)
        _ = read_orc_bytes(Span(o))
    with assert_raises(contains="PostScript magic != 'ORC'"):
        var m = _bytes("ORC")
        var ps = encode_post_script(0, ORC_COMPRESSION_NONE, 0, 0, 12, 0, "ORK")
        _append(m, ps)
        m.append(UInt8(len(ps)))
        _ = read_orc_bytes(Span(m))
    # Compressed codec: the reader walks the tail itself.
    with assert_raises(contains="footer overruns start"):
        var f = _bytes("ORC")
        var ps = encode_post_script(1, ORC_COMPRESSION_ZSTD, 262144, 0, 12, 0, "ORC")
        _append(f, ps)
        f.append(UInt8(len(ps)))
        _ = read_orc_bytes(Span(f))
    with assert_raises(contains="metadata overruns start"):
        var md = _bytes("ORC")
        var ps = encode_post_script(0, ORC_COMPRESSION_ZSTD, 262144, 0, 12, 1, "ORC")
        _append(md, ps)
        md.append(UInt8(len(ps)))
        _ = read_orc_bytes(Span(md))


# -----------------------------------------------------------------------------
# T2 — byte ranges.
# -----------------------------------------------------------------------------


def test_byte_ranges() raises:
    # A DATA stream declaring 1000 bytes in a file far shorter.
    var st = _long_stripe(_one_col(0, 4))
    st.streams[0] = encode_stream(ORC_STREAM_DATA, 1, 1000)
    var s = List[_S]()
    s.append(st^)
    var f = _assemble(s, _flat_types(1, _names("a")), 4, 0, List[UInt8]())
    with assert_raises(contains="BAD_SPAN: stream 0 byte range [3, 1003) runs past the end of a"):
        _ = read_orc_bytes(Span(f))

    _checked_file_span(10, 0, 10, "whole")
    with assert_raises(contains="BAD_SPAN: probe byte range [-1, 2) is inverted or negative"):
        _checked_file_span(10, -1, 2, "probe")
    with assert_raises(contains="BAD_SPAN: probe byte range [5, 4) is inverted or negative"):
        _checked_file_span(10, 5, 4, "probe")
    with assert_raises(contains="BAD_SPAN: probe byte range [2, 11) runs past the end of a 10-byte file"):
        _checked_file_span(10, 2, 11, "probe")

    var streams = List[OrcStream]()
    streams.append(OrcStream(ORC_STREAM_DATA, 1, 2))
    streams.append(OrcStream(ORC_STREAM_DATA, 2, -1))
    var sf = StripeFooter(streams^, List[OrcColumnEncoding](), String(""))
    var si = StripeInformation(3, 0, 2, 0, 1)
    with assert_raises(contains="BAD_SPAN: stream 1 of this stripe declares a negative length -1"):
        _ = _locate_streams(sf, si, 100)


# -----------------------------------------------------------------------------
# T3 — schema shape.
# -----------------------------------------------------------------------------


def test_schema_shape() raises:
    # Root is a bigint, not a struct.
    var t = List[List[UInt8]]()
    t.append(_long_t())
    var leaf_root = _assemble(List[_S](), t, 0, 0, List[UInt8]())
    with assert_raises(contains="ROOT_NOT_STRUCT: the ORC reader needs a top-level struct"):
        _ = read_orc_bytes(Span(leaf_root))
    with assert_raises(contains="ROOT_NOT_STRUCT: stride-skip read needs a top-level struct"):
        _ = read_orc_bytes_filtered(Span(leaf_root), _le("a", 1))
    with assert_raises(contains="ROOT_NOT_STRUCT: pruned read needs a top-level struct"):
        _ = read_orc_bytes_pruned(Span(leaf_root), _le("a", 1), List[Int]())
    var leaf_types = List[OrcRawType]()
    leaf_types.append(OrcRawType(ORC_KIND_LONG, List[Int](), List[String](), 0, 0, 0))
    with assert_raises(contains="ROOT_NOT_STRUCT: the ORC reader needs a top-level struct"):
        _ = _build_output_schema(OrcSchema.from_types(leaf_types), List[Int]())

    # Projection out of range.
    var f = _one_stripe_file(4)
    with assert_raises(contains="BAD_PROJECTION: output column index 3 out of range [0, 1)"):
        _ = read_orc_bytes_projected(Span(f), [3])
    with assert_raises(contains="BAD_PROJECTION: output column index 1 out of range [0, 1)"):
        _ = read_orc_bytes_projected(Span(f), [1])
    with assert_raises(contains="BAD_PROJECTION: output column index -1 out of range [0, 1)"):
        _ = read_orc_bytes_projected(Span(f), [-1])

    # Two columns, only the first named.
    var two = List[List[Int64]]()
    two.append(_vals(0, 4))
    two.append(_vals(100, 4))
    var s = List[_S]()
    s.append(_long_stripe(two))
    var unnamed = _assemble(s, _flat_types(2, _names("a")), 4, 0, List[UInt8]())
    var rb = read_orc_bytes(Span(unnamed))
    assert_equal(rb.schema.field_name(0), "a")
    assert_equal(rb.schema.field_name(1), "_col1")
    var fr = read_orc_bytes_filtered(Span(unnamed), _le("_col1", 101))
    assert_equal(fr.strides_skipped, 0)
    assert_equal(fr.batch.num_rows(), 4)
    var pr = read_orc_bytes_pruned(Span(unnamed), _le("_col1", 101), [1])
    assert_equal(pr.batch.num_columns(), 1)
    assert_equal(pr.batch.schema.field_name(0), "_col1")
    assert_equal(Int(pr.batch.column_as_primitive_int64(0).get(2)), 102)

    # A root struct with no children: a batch of no columns.
    var empty_root = List[List[UInt8]]()
    empty_root.append(_struct(0, List[String]()))
    var none = _assemble(List[_S](), empty_root, 0, 0, List[UInt8]())
    var rb0 = read_orc_bytes(Span(none))
    assert_equal(rb0.num_columns(), 0)


# -----------------------------------------------------------------------------
# T4 — row counts.
# -----------------------------------------------------------------------------


def test_row_counts() raises:
    var huge = 1 << 40
    var f = _one_stripe_file(huge)
    with assert_raises(contains="BAD_ROW_COUNT: Footer.numberOfRows = 1099511627776 cannot be backed by a "):
        _ = read_orc_bytes(Span(f))

    var st = _long_stripe(_one_col(0, 4))
    st.rows = huge
    var s = List[_S]()
    s.append(st^)
    var g = _assemble(s, _flat_types(1, _names("a")), 4, 0, List[UInt8]())
    with assert_raises(contains="BAD_ROW_COUNT: stripe 0 declares 1099511627776 rows, which a "):
        _ = read_orc_bytes(Span(g))

    # Two stripes of 4 rows; the Footer says 5.
    var s2 = List[_S]()
    s2.append(_long_stripe(_one_col(0, 4)))
    s2.append(_long_stripe(_one_col(4, 4)))
    var h = _assemble(s2, _flat_types(1, _names("a")), 5, 0, List[UInt8]())
    with assert_raises(
        contains="STRIPE_ROWS_EXCEED_FOOTER: stripes 0..1 declare 8 rows in total, but Footer.numberOfRows is 5"
    ):
        _ = read_orc_bytes(Span(h))
    # Exactly 8 reads.
    var ok = _assemble(s2, _flat_types(1, _names("a")), 8, 0, List[UInt8]())
    assert_equal(read_orc_bytes(Span(ok)).num_rows(), 8)


# -----------------------------------------------------------------------------
# T5 — encodings and a column that does not decode.
# -----------------------------------------------------------------------------


def test_encoding_and_decode_failure() raises:
    var st = _long_stripe(_one_col(0, 4))
    var root_only = List[List[UInt8]]()
    root_only.append(encode_column_encoding(ORC_ENCODING_DIRECT, 0))
    st.encodings = root_only^
    var s = List[_S]()
    s.append(st^)
    var f = _assemble(s, _flat_types(1, _names("a")), 4, 0, List[UInt8]())
    with assert_raises(contains="MISSING_ENCODING: column id 1 has no ColumnEncoding entry"):
        _ = read_orc_bytes(Span(f))
    with assert_raises(contains="MISSING_ENCODING: column id 1 has no ColumnEncoding entry"):
        _ = read_orc_bytes_pruned(Span(f), _le("a", 100), List[Int]())

    # DATA: a SHORT_REPEAT run of 10 values in a 4-row stripe.
    var bad = _long_stripe(_one_col(0, 4))
    var d = List[UInt8]()
    d.append(0x07)  # W=1, R=10
    d.append(0x02)
    bad.data = d.copy()
    bad.streams[0] = encode_stream(ORC_STREAM_DATA, 1, len(d))
    var s2 = List[_S]()
    s2.append(bad^)
    var g = _assemble(s2, _flat_types(1, _names("a")), 4, 0, List[UInt8]())
    with assert_raises(
        contains="OrcDecodeError: column-parallel decode of output column 0 failed: OrcRleError.RUN_OVERRUN"
    ):
        _ = read_orc_bytes(Span(g))


# -----------------------------------------------------------------------------
# T6 — nested files.
# -----------------------------------------------------------------------------


def _nested_types(root_names: List[String]) -> List[List[UInt8]]:
    """struct<x: struct<>> — a top-level child that is itself a struct."""
    var t = List[List[UInt8]]()
    t.append(encode_type_node(ORC_KIND_STRUCT, [1], root_names, 0, 0, 0))
    t.append(encode_type_node(ORC_KIND_STRUCT, List[Int](), List[String](), 0, 0, 0))
    return t^


def _empty_stripe(rows: Int, n_nodes: Int) -> _S:
    return _S(List[UInt8](), List[UInt8](), List[List[UInt8]](), _encodings(n_nodes), rows)


def test_nested_files() raises:
    var s = List[_S]()
    s.append(_empty_stripe(2, 2))
    var named = _assemble(s, _nested_types(_names("x")), 2, 0, List[UInt8]())
    var rb = read_orc_bytes(Span(named))
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.schema.field_name(0), "x")
    with assert_raises(contains="column-projection on nested / ACID ORC schemas is not supported"):
        _ = read_orc_bytes_projected(Span(named), [0])

    var unnamed = _assemble(s, _nested_types(List[String]()), 2, 0, List[UInt8]())
    assert_equal(read_orc_bytes(Span(unnamed)).schema.field_name(0), "_col0")

    # A zero-stripe file is valid ORC. Refusing it is a known gap of the
    # single-stripe nested path (komira-ai/komira#1449), not the right answer:
    # this pins today's refusal, and fixing the gap changes it to an empty batch.
    var zero = _assemble(List[_S](), _nested_types(_names("x")), 0, 0, List[UInt8]())
    with assert_raises(contains="nested / ACID ORC read is single-stripe (got 0 stripes)"):
        _ = read_orc_bytes(Span(zero))

    # A LIST root whose child is a struct takes the nested path, which needs
    # a struct root.
    var lt = List[List[UInt8]]()
    lt.append(encode_type_node(ORC_KIND_LIST, [1], List[String](), 0, 0, 0))
    lt.append(encode_type_node(ORC_KIND_STRUCT, List[Int](), List[String](), 0, 0, 0))
    var list_root = _assemble(s, lt, 2, 0, List[UInt8]())
    with assert_raises(contains="ROOT_NOT_STRUCT: nested read needs a top-level struct"):
        _ = read_orc_bytes(Span(list_root))


# -----------------------------------------------------------------------------
# T7 — stride and stripe statistics that are missing.
# -----------------------------------------------------------------------------


def _int_stats(lo: Int, hi: Int, n: Int) -> List[UInt8]:
    return encode_column_statistics(
        n, False, encode_integer_statistics(Int64(lo), Int64(hi), Optional[Int64](None)),
        List[UInt8](), List[UInt8](),
    )


def test_missing_statistics_keep() raises:
    # Two columns, 4 rows. Column a's ROW_INDEX has 2 entries (the second
    # with no statistics), column b's has 1. Footer.rowIndexStride = 0.
    var cols = List[List[Int64]]()
    cols.append(_vals(0, 4))
    cols.append(_vals(50, 4))
    var st = _long_stripe(cols)
    var ea = List[List[UInt8]]()
    ea.append(encode_row_index_entry(List[Int](), _int_stats(0, 3, 4)))
    ea.append(encode_row_index_entry(List[Int](), _int_stats(100, 100, 1)))
    var eb = List[List[UInt8]]()
    eb.append(encode_row_index_entry(List[Int](), _int_stats(50, 53, 4)))
    var ria = encode_row_index(ea)
    var rib = encode_row_index(eb)
    # Column a's bloom: one entry with a utf8bitset field of no bytes.
    var bloom_entries = List[List[UInt8]]()
    bloom_entries.append(encode_bloom_filter(3, Span(List[UInt8]())))
    var bfa = encode_bloom_filter_index(bloom_entries)
    var index = List[UInt8]()
    _append(index, ria)
    _append(index, bfa)
    _append(index, rib)
    var streams = List[List[UInt8]]()
    streams.append(encode_stream(ORC_STREAM_ROW_INDEX, 1, len(ria)))
    streams.append(encode_stream(ORC_STREAM_BLOOM_FILTER_UTF8, 1, len(bfa)))
    streams.append(encode_stream(ORC_STREAM_ROW_INDEX, 2, len(rib)))
    for i in range(len(st.streams)):
        streams.append(st.streams[i].copy())
    st.index = index^
    st.streams = streams^
    var s = List[_S]()
    s.append(st^)
    var f = _assemble(s, _flat_types(2, _names("a", "b")), 4, 0, List[UInt8]())

    # Stride 0 = the whole stripe (stride size 0 -> the stripe's rows); its
    # stats prove b > 60 false. Stride 1 holds no rows; column a's entry 1
    # claims [100, 100], column b has no entry 1 (no statistics: kept).
    var res = read_orc_bytes_filtered(Span(f), _gt("b", 60))
    assert_equal(res.strides_total, 2)
    assert_equal(res.strides_skipped, 1)
    assert_equal(res.batch.num_rows(), 0)
    # a <= 50 skips stride 1 by column a's entry and keeps stride 0, whose 4
    # rows are the stripe's (a stride size of 0 means the whole stripe).
    var whole = read_orc_bytes_filtered(Span(f), _le("a", 50))
    assert_equal(whole.strides_skipped, 1)
    assert_equal(whole.batch.num_rows(), 4)
    assert_equal(Int(whole.batch.column_as_primitive_int64(1).get(3)), 53)
    var keep = read_orc_bytes_filtered(Span(f), _gt("b", 52))
    assert_equal(keep.strides_skipped, 0)
    assert_equal(keep.batch.num_rows(), 4)
    # a = 2 is inside stride 0's statistics; its bloom has no bits, which
    # cannot prove absence: stride 0 kept (stride 1's [100, 100] skips it).
    var eq = read_orc_bytes_filtered(
        Span(f), Expr.binary(BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(2)))
    )
    assert_equal(eq.strides_skipped, 1)
    assert_equal(eq.batch.num_rows(), 4)

    # Pruned read: Metadata whose stripe statistics list only the root node.
    var root_stats = List[List[UInt8]]()
    root_stats.append(encode_column_statistics(4, False, List[UInt8](), List[UInt8](), List[UInt8]()))
    var stripes_stats = List[List[UInt8]]()
    stripes_stats.append(encode_stripe_statistics(root_stats))
    var s2 = List[_S]()
    s2.append(_long_stripe(_one_col(0, 4)))
    var m = _assemble(s2, _flat_types(1, _names("a")), 4, 0, encode_metadata(stripes_stats))
    var pr = read_orc_bytes_pruned(Span(m), _gt("a", 100), List[Int]())
    assert_equal(pr.stripes_skipped, 0)
    assert_equal(pr.batch.num_rows(), 4)
    # The same with full statistics prunes the stripe (the control).
    var full_stats = List[List[UInt8]]()
    full_stats.append(encode_column_statistics(4, False, List[UInt8](), List[UInt8](), List[UInt8]()))
    full_stats.append(_int_stats(0, 3, 4))
    var ss = List[List[UInt8]]()
    ss.append(encode_stripe_statistics(full_stats))
    var mf = _assemble(s2, _flat_types(1, _names("a")), 4, 0, encode_metadata(ss))
    assert_equal(read_orc_bytes_pruned(Span(mf), _gt("a", 100), List[Int]()).stripes_skipped, 1)
    # No Metadata blob at all: kept.
    var nm = _assemble(s2, _flat_types(1, _names("a")), 4, 0, List[UInt8]())
    var pn = read_orc_bytes_pruned(Span(nm), _gt("a", 100), List[Int]())
    assert_equal(pn.stripes_skipped, 0)
    assert_equal(pn.batch.num_rows(), 4)


def main() raises:
    test_tail_refusals()
    test_byte_ranges()
    test_schema_shape()
    test_row_counts()
    test_encoding_and_decode_failure()
    test_nested_files()
    test_missing_statistics_keep()
    print("test_orc_crafted_file_refusals: ALL PASS")
