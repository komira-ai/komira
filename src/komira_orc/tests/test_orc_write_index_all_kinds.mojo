# =============================================================================
# test_orc_write_index_all_kinds.mojo — the writer's per-stride ROW_INDEX
# statistics, per-stride bloom filters, per-stripe and per-file statistics
# for every column kind it writes, each with and without nulls.
# =============================================================================
#
# The batch holds 12 rows of 19 columns: tinyint / smallint / int / bigint /
# date / float / double / boolean / string, each twice (one with nulls, one
# without), and a large_string column with nulls. It is written as 2 stripes
# (8 + 4 rows) with a 4-row stride and a bloom filter on every column. The
# oracle is computed in this test from the input lists (min / max / non-null
# count over a row range); the file is parsed with the package's metadata
# parsers (decompressing through decompress_stream for a compressed codec).
#
#   T1  For NONE and ZSTD, serial and dispatcher-backed writes: the file reads
#       back to the input (values and nulls), the dispatcher bytes equal the
#       serial bytes, and every stride's ROW_INDEX statistics equal the oracle
#       (non-null count, has-null, int / double / string min and max).
#   T2  Every non-null value of a stride tests positive in that stride's
#       bloom filter (an emit arm that adds nothing, or the wrong value,
#       leaves a present value testing negative).
#   T3  The per-stripe statistics (Metadata) and per-file statistics
#       (Footer field 7, merged across stripes: the second stripe has a lower
#       double minimum and a lower string minimum and higher string maximum
#       than the first) equal the oracle.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_buffer.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    write_orc_bytes_with_dispatcher,
    read_orc_bytes,
    PostScript,
    Footer,
    Metadata,
    StripeFooter,
    OrcRowIndex,
    OrcBloomFilterIndex,
    OrcColumnStatistics,
    OrcBloomFilter,
    decompress_stream,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    PB_WIRE_LEN,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
)


comptime N = 12
comptime STRIDE = 4
comptime STRIPE = 8

# Column kinds of this test's spec.
comptime K_I8 = 0
comptime K_I16 = 1
comptime K_I32 = 2
comptime K_I64 = 3
comptime K_DATE = 4
comptime K_F32 = 5
comptime K_F64 = 6
comptime K_BOOL = 7
comptime K_STR = 8
comptime K_LSTR = 9


@fieldwise_init
struct _Col(Copyable, Movable):
    var name: String
    var kind: Int
    var ints: List[Int64]
    var dbls: List[Float64]
    var strs: List[String]
    var valid: List[Bool]


def _strings() -> List[String]:
    var s = List[String]()
    s.append("m"); s.append("c"); s.append("x"); s.append("a")
    s.append("q"); s.append("b"); s.append("z"); s.append("d")
    s.append("n"); s.append("A"); s.append("zz"); s.append("f")
    return s^


def _int_value(kind: Int, r: Int) -> Int64:
    if kind == K_I8:
        return Int64((r * 37) % 200 - 100)
    elif kind == K_I16:
        return Int64((r * 1000) % 7001 - 3500)
    elif kind == K_I32:
        return Int64(r * r * 1000 - 50000)
    elif kind == K_I64:
        return Int64(r - 6) * 10_000_000_000
    elif kind == K_DATE:
        return Int64(19000 + (r * 13) % 17 - 8)
    return Int64(1 if r % 3 == 0 else 0)  # K_BOOL


def _dbl_value(kind: Int, r: Int) -> Float64:
    if kind == K_F32:
        return Float64(r) * 1.5 - 7.25
    return -Float64(r) * 2.25 + 3.0  # K_F64


def _is_null(kind: Int, r: Int) -> Bool:
    if kind == K_I8:
        return r % 4 == 1
    elif kind == K_I16:
        return r % 3 == 2
    elif kind == K_I32:
        return r % 5 == 0
    elif kind == K_I64:
        return r == 7
    elif kind == K_DATE:
        return r % 4 == 3
    elif kind == K_F32:
        return r % 3 == 0
    elif kind == K_F64:
        return r % 4 == 2
    elif kind == K_BOOL:
        return r % 5 == 4
    return r % 4 == 0  # strings


def _spec() -> List[_Col]:
    var cols = List[_Col]()
    var names = List[String]()
    names.append("t8"); names.append("s16"); names.append("i32")
    names.append("l64"); names.append("dt"); names.append("f32")
    names.append("f64"); names.append("bl"); names.append("st")
    for k in range(9):
        for nullable in range(2):
            var ints = List[Int64]()
            var dbls = List[Float64]()
            var strs = List[String]()
            var valid = List[Bool]()
            var ss = _strings()
            for r in range(N):
                ints.append(_int_value(k, r))
                dbls.append(_dbl_value(k, r))
                strs.append(ss[r])
                valid.append(not (nullable == 1 and _is_null(k, r)))
            var name = names[k] + ("_n" if nullable == 1 else "_v")
            cols.append(_Col(name, k, ints^, dbls^, strs^, valid^))
    # The wide string column, with the narrow one's nulls.
    var lvalid = List[Bool]()
    for r in range(N):
        lvalid.append(not _is_null(K_STR, r))
    cols.append(_Col("ls_n", K_LSTR, List[Int64](), List[Float64](), _strings(), lvalid^))
    return cols^


def _column(c: _Col) raises -> Column[HeapRegion]:
    var k = c.kind
    if k == K_I8:
        var a = PrimitiveArray[DType.int8].allocate_nullable(N)
        for r in range(N):
            a.set(r, Int8(c.ints[r]))
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_primitive_with_arrow_type[DType.int8](a^, ArrowType.INT8)
    elif k == K_I16:
        var a = PrimitiveArray[DType.int16].allocate_nullable(N)
        for r in range(N):
            a.set(r, Int16(c.ints[r]))
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_primitive_with_arrow_type[DType.int16](a^, ArrowType.INT16)
    elif k == K_I32 or k == K_DATE:
        var a = PrimitiveArray[DType.int32].allocate_nullable(N)
        for r in range(N):
            a.set(r, Int32(c.ints[r]))
            if not c.valid[r]:
                a._set_null(r)
        var at = ArrowType.INT32 if k == K_I32 else ArrowType.DATE32
        return Column.from_primitive_with_arrow_type[DType.int32](a^, at)
    elif k == K_I64:
        var a = PrimitiveArray[DType.int64].allocate_nullable(N)
        for r in range(N):
            a.set(r, c.ints[r])
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    elif k == K_F32:
        var a = PrimitiveArray[DType.float32].allocate_nullable(N)
        for r in range(N):
            a.set(r, Float32(c.dbls[r]))
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_primitive[DType.float32](a^)
    elif k == K_F64:
        var a = PrimitiveArray[DType.float64].allocate_nullable(N)
        for r in range(N):
            a.set(r, c.dbls[r])
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_primitive[DType.float64](a^)
    elif k == K_BOOL:
        var a = BooleanArray.allocate_nullable(N)
        for r in range(N):
            a.set(r, c.ints[r] != 0)
            if not c.valid[r]:
                a._set_null(r)
        return Column.from_boolean(a^)
    elif k == K_STR:
        return Column.from_string(StringArray.from_strings_with_validity(c.strs, c.valid))
    return Column.from_large_string(LargeStringArray.from_strings_with_validity(c.strs, c.valid))


def _arrow_type(kind: Int) -> ArrowType:
    if kind == K_I8:
        return ArrowType.INT8
    elif kind == K_I16:
        return ArrowType.INT16
    elif kind == K_I32:
        return ArrowType.INT32
    elif kind == K_I64:
        return ArrowType.INT64
    elif kind == K_DATE:
        return ArrowType.DATE32
    elif kind == K_F32:
        return ArrowType.FLOAT32
    elif kind == K_F64:
        return ArrowType.FLOAT64
    elif kind == K_BOOL:
        return ArrowType.BOOL
    elif kind == K_STR:
        return ArrowType.STRING
    return ArrowType.LARGE_STRING


def _batch(spec: List[_Col]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder.with_capacity(len(spec))
    for i in range(len(spec)):
        sb.add_field(Field(spec[i].name, _arrow_type(spec[i].kind), True))
        b.add_column(_column(spec[i]))
    return b.build(sb.build())


def _opts(codec: Int, spec: List[_Col]) -> OrcWriterOptions:
    var names = List[String]()
    for i in range(len(spec)):
        names.append(spec[i].name)
    return OrcWriterOptions.with_bloom(codec, STRIDE, STRIPE, names^)


# -----------------------------------------------------------------------------
# The oracle over a row range.
# -----------------------------------------------------------------------------


def _is_int_kind(k: Int) -> Bool:
    return k == K_I8 or k == K_I16 or k == K_I32 or k == K_I64 or k == K_DATE


def _is_str_kind(k: Int) -> Bool:
    return k == K_STR or k == K_LSTR


def _check_stats(
    st: OrcColumnStatistics, c: _Col, lo: Int, hi: Int, label: String
) raises:
    var nvals = 0
    var any_null = False
    var imin = Int64.MAX
    var imax = Int64.MIN
    var dmin: Float64 = 1.0e308
    var dmax: Float64 = -1.0e308
    var smin = String("")
    var smax = String("")
    for r in range(lo, hi):
        if not c.valid[r]:
            any_null = True
            continue
        if nvals == 0 or c.strs[r] < smin:
            smin = c.strs[r]
        if nvals == 0 or c.strs[r] > smax:
            smax = c.strs[r]
        nvals += 1
        imin = min(imin, c.ints[r]) if len(c.ints) > 0 else imin
        imax = max(imax, c.ints[r]) if len(c.ints) > 0 else imax
        if len(c.dbls) > 0:
            dmin = min(dmin, c.dbls[r])
            dmax = max(dmax, c.dbls[r])
    assert_equal(st.number_of_values, nvals, label + ": number of values")
    assert_equal(st.has_null, any_null, label + ": has null")
    if _is_int_kind(c.kind):
        assert_true(st.has_int, label + ": int stats present")
        assert_equal(st.int_min, imin, label + ": int min")
        assert_equal(st.int_max, imax, label + ": int max")
    elif c.kind == K_F32 or c.kind == K_F64:
        assert_true(st.has_double, label + ": double stats present")
        assert_equal(st.dbl_min, dmin, label + ": double min")
        assert_equal(st.dbl_max, dmax, label + ": double max")
    elif _is_str_kind(c.kind):
        assert_true(st.has_string, label + ": string stats present")
        assert_equal(st.str_min, smin, label + ": string min")
        assert_equal(st.str_max, smax, label + ": string max")
    else:
        assert_false(st.has_int or st.has_double or st.has_string, label + ": bool carries no min/max")


def _check_bloom(
    bloom: OrcBloomFilter, c: _Col, lo: Int, hi: Int, label: String
) raises:
    for r in range(lo, hi):
        if not c.valid[r] or c.kind == K_BOOL:
            continue
        var hit: Bool
        if _is_int_kind(c.kind):
            hit = bloom.test_long(c.ints[r])
        elif c.kind == K_F32 or c.kind == K_F64:
            hit = bloom.test_double(c.dbls[r])
        else:
            hit = bloom.test_string(c.strs[r])
        assert_true(hit, label + ": row " + String(r) + " tests absent in its bloom")


# -----------------------------------------------------------------------------
# The file walk.
# -----------------------------------------------------------------------------


def _blob(file: List[UInt8], start: Int, end: Int, codec: Int) raises -> List[UInt8]:
    return decompress_stream(Span(file)[start:end], codec, 256 * 1024)


def _check_file(file: List[UInt8], codec: Int, spec: List[_Col], label: String) raises:
    var n = len(file)
    var ps_len = Int(file[n - 1])
    var ps = PostScript.parse(Span(file)[n - 1 - ps_len : n - 1])
    assert_equal(ps.compression, codec, label + ": PostScript codec")
    var footer_end = n - 1 - ps_len
    var footer_start = footer_end - ps.footer_length
    var metadata_start = footer_start - ps.metadata_length
    var footer_raw = _blob(file, footer_start, footer_end, codec)
    var footer = Footer.parse(Span(footer_raw))
    assert_equal(footer.num_stripes(), 2, label + ": stripes")
    assert_equal(footer.row_index_stride, STRIDE, label + ": stride")

    # T1 / T2 — per-stride statistics and blooms, per stripe.
    var stripe_lo = 0
    for s in range(2):
        ref si = footer.stripes[s]
        var sf_raw = _blob(file, si.stripe_footer_start(), si.stripe_footer_end(), codec)
        var sf = StripeFooter.parse(Span(sf_raw))
        var off = si.offset
        var seen_index = 0
        var seen_bloom = 0
        for k in range(len(sf.streams)):
            ref stream = sf.streams[k]
            var start = off
            off += stream.length
            if stream.kind != ORC_STREAM_ROW_INDEX and stream.kind != ORC_STREAM_BLOOM_FILTER_UTF8:
                continue
            var c = stream.column - 1
            var raw = _blob(file, start, start + stream.length, codec)
            var lab = label + " stripe " + String(s) + " " + spec[c].name
            if stream.kind == ORC_STREAM_ROW_INDEX:
                seen_index += 1
                var ri = OrcRowIndex.parse(Span(raw))
                assert_equal(len(ri.entries), (si.number_of_rows + STRIDE - 1) // STRIDE, lab + ": strides")
                for e in range(len(ri.entries)):
                    var lo = stripe_lo + e * STRIDE
                    _check_stats(ri.entries[e].statistics, spec[c], lo, lo + STRIDE, lab + " stride " + String(e))
            else:
                seen_bloom += 1
                var bi = OrcBloomFilterIndex.parse(Span(raw))
                for e in range(len(bi.entries)):
                    var lo = stripe_lo + e * STRIDE
                    var bf = OrcBloomFilter(
                        bi.entries[e].num_hash_functions, bi.entries[e].utf8bitset.copy()
                    )
                    _check_bloom(bf, spec[c], lo, lo + STRIDE, lab + " bloom " + String(e))
        assert_equal(seen_index, len(spec), label + ": a ROW_INDEX per column")
        assert_equal(seen_bloom, len(spec), label + ": a bloom per column")

        # T3 — this stripe's statistics in Metadata.
        stripe_lo += si.number_of_rows

    var md_raw = _blob(file, metadata_start, footer_start, codec)
    var md = Metadata.parse(Span(md_raw))
    assert_equal(md.stripe_stats_count, 2, label + ": stripe stats")
    for s in range(2):
        var lo = s * STRIPE
        var hi = min(lo + STRIPE, N)
        for c in range(len(spec)):
            _check_stats(
                md.per_stripe_stats[s].col_stats[c + 1], spec[c], lo, hi,
                label + " stripe stats " + String(s) + " " + spec[c].name,
            )

    # T3 — the file statistics (Footer field 7, one per schema node).
    var file_stats = List[OrcColumnStatistics]()
    var pos = 0
    while pos < len(footer_raw):
        var tag = pb_read_tag(Span(footer_raw), pos)
        pos = tag.new_pos
        if tag.field_number == 7 and tag.wire_type == PB_WIRE_LEN:
            var f = pb_read_len_field(Span(footer_raw), pos)
            file_stats.append(OrcColumnStatistics.parse(Span(footer_raw), f.payload_start, f.payload_end))
            pos = f.new_pos
        else:
            pos = pb_skip_field(Span(footer_raw), pos, tag.wire_type)
    assert_equal(len(file_stats), len(spec) + 1, label + ": file stats per node")
    assert_equal(file_stats[0].number_of_values, N, label + ": root node rows")
    for c in range(len(spec)):
        _check_stats(file_stats[c + 1], spec[c], 0, N, label + " file stats " + spec[c].name)


def _check_roundtrip(file: List[UInt8], spec: List[_Col], label: String) raises:
    var back = read_orc_bytes(Span(file))
    assert_equal(back.num_rows(), N, label + ": rows")
    for c in range(len(spec)):
        ref col = spec[c]
        var lab = label + " read " + col.name
        for r in range(N):
            var k = col.kind
            var is_null: Bool
            if k == K_I8:
                var a = back.column_at(c).as_primitive[DType.int8]()
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(Int64(a.get(r)), col.ints[r], lab)
            elif k == K_I16:
                var a = back.column_at(c).as_primitive[DType.int16]()
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(Int64(a.get(r)), col.ints[r], lab)
            elif k == K_I32 or k == K_DATE:
                var a = back.column_as_primitive_int32(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(Int64(a.get(r)), col.ints[r], lab)
            elif k == K_I64:
                var a = back.column_as_primitive_int64(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(a.get(r), col.ints[r], lab)
            elif k == K_F32:
                var a = back.column_as_primitive_float32(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(Float64(a.get(r)), col.dbls[r], lab)
            elif k == K_F64:
                var a = back.column_as_primitive_float64(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(a.get(r), col.dbls[r], lab)
            elif k == K_BOOL:
                var a = back.column_as_boolean(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(a.get(r), col.ints[r] != 0, lab)
            else:
                var a = back.column_as_string(c)
                is_null = a.is_null(r)
                if not is_null:
                    assert_equal(a.get(r), col.strs[r], lab)
            assert_equal(is_null, not col.valid[r], lab + ": null at row " + String(r))


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_index_and_bloom_all_kinds() raises:
    var spec = _spec()
    var batch = _batch(spec)
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    for i in range(2):
        var codec = ORC_COMPRESSION_NONE if i == 0 else ORC_COMPRESSION_ZSTD
        var label = String("NONE") if i == 0 else String("ZSTD")
        var serial = write_orc_bytes(batch, _opts(codec, spec))
        var par = write_orc_bytes_with_dispatcher[origin_of(disp)](
            batch, _opts(codec, spec), Pointer(to=disp), CancellationToken.never(),
        )
        assert_equal(len(par), len(serial), label + ": dispatcher bytes length")
        for b in range(len(serial)):
            if par[b] != serial[b]:
                raise Error(label + ": dispatcher byte " + String(b) + " differs")
        _check_roundtrip(serial, spec, label)
        _check_file(serial, codec, spec, label)
    _ = rt^


def main() raises:
    test_index_and_bloom_all_kinds()
    print("test_orc_write_index_all_kinds: ALL PASS")
