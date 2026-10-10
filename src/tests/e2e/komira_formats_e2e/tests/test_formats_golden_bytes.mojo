# =============================================================================
# The writers' bytes against literals spelled from the format specs.
# =============================================================================
#
# test_formats_projected_roundtrip reads every file with komira's own reader,
# so a writer and reader that agree on a wrong encoding pass it. This file is
# the writer-side oracle: the expected bytes are spelled here, from the
# dataset table in dataset.mojo and the format specs, never produced by a
# komira encoder.
#
# What each test proves, and the defect it catches:
#   * test_csv_bytes_exact -- each partition's CsvSink file equals a literal:
#     the header row; RFC 4180 quoting of exactly the fields holding a comma,
#     a quote, LF or CR (rows 0, 3, 6, 7, 8, 9) and no other; every embedded
#     quote doubled; NULL as an empty field. Choices CsvSink documents and
#     this test pins on purpose: records end in LF (RFC 4180 says CRLF; the
#     sink writes LF), BOOL is `true`/`false`, FLOAT64 is the shortest
#     round-trip text with `.0` on integral values (`100.0`), and the empty
#     string is written as an empty field, the same bytes as NULL (row 1:
#     `,-2.25,,false`). If the sink ever writes `""` for the empty string,
#     this literal reds and the convention gets decided, not drifted into.
#   * test_jsonl_bytes_exact -- each partition's JSONL equals a literal: one
#     object per line, LF-terminated, keys in schema order, no whitespace,
#     an explicit `null` for every NULL (a writer that drops null keys reds),
#     `""` for the empty string, raw UTF-8 for non-ASCII (no \u escapes), and
#     `\n`, `\r`, `\"` escapes (RFC 8259 section 7).
#   * test_jsonl_reader_missing_key_and_surrogates -- hand-written JSONL the
#     writer never produces: a line that omits `score` and a line with
#     `"score":null` both read as NULL; a `😀` surrogate pair reads
#     as the 4 bytes F0 9F 98 80; a JSON-escaped LF reads as one LF byte.
#   * test_avro_ocf_framing -- the OCF starts with `Obj` 01, the header
#     metadata holds `avro.schema` with every field a `["null",T]` union
#     (null first, as a null default requires and as other Avro readers
#     expect), and the file ends with the 16-byte sync marker that also
#     closes the header.
#   * test_orc_tail_stats_and_streams -- an uncompressed ORC of the Zürich
#     rows: the file starts with `ORC`; the tail parses; the one stripe holds
#     5 rows; each column's stripe statistics report 4 non-null values and
#     hasNull; each column has a PRESENT stream; the `score` DATA stream is
#     8 bytes x 4 non-null values = 32 (the ORC spec omits NULL slots from
#     DATA; a writer that writes a value per slot gives 40). The tail is
#     parsed with komira_orc's protobuf structures (not the column decoder),
#     so this pins the writer's metadata, not a foreign reader's view.
#
# Planted mutants seen red here: CsvSink with the delimiter, quote, LF or CR
# quoting trigger dropped (the csv literal, first differing byte shown); the
# ORC writer skipping PRESENT and writing NULL slots into DATA (stats: 5
# non-null values, not 4); the ORC writer marking every slot present while
# DATA omits NULL slots (stats: hasNull false).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_fs.local_fs import LocalFs
from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_orc import (
    Metadata,
    ORC_COMPRESSION_NONE,
    ORC_STREAM_DATA,
    ORC_STREAM_PRESENT,
    OrcFileTail,
    OrcWriterOptions,
    StripeFooter,
    write_orc_bytes,
)
from komira_runtime_paths import test_tmpdir

from komira_formats_e2e import (
    batch_for_city,
    city_oslo,
    city_zurich,
    file_path,
    write_hive_tree,
)


comptime _Fs = LocalFs[NoopSink]

# Zürich = rows 0, 1, 2, 6, 9; Oslo = rows 3, 4, 5, 7, 8 (dataset.mojo).
comptime _CSV_ZURICH = (
    "id,score,name,flag\n"
    '1,1.5,"Grüße, Welt",true\n'
    ",-2.25,,false\n"
    "9007199254740993,,,\n"
    '3,0.5,"Zeile1\nZeile2 😀",true\n'
    '9,4.25,"Ende\r\nZeile",false\n'
)
comptime _CSV_OSLO = (
    "id,score,name,flag\n"
    '-42,0.1,"Ålesund ""Å""",\n'
    "7,,,true\n"
    ",100.0,東京,false\n"
    '-1,2.0,"""Å"" Ålesund",false\n'
    '8,-0.5,"Linje1\rLinje2",true\n'
)
comptime _JSONL_ZURICH = (
    '{"id":1,"score":1.5,"name":"Grüße, Welt","flag":true}\n'
    '{"id":null,"score":-2.25,"name":"","flag":false}\n'
    '{"id":9007199254740993,"score":null,"name":null,"flag":null}\n'
    '{"id":3,"score":0.5,"name":"Zeile1\\nZeile2 😀","flag":true}\n'
    '{"id":9,"score":4.25,"name":"Ende\\r\\nZeile","flag":false}\n'
)
comptime _JSONL_OSLO = (
    '{"id":-42,"score":0.1,"name":"Ålesund \\"Å\\"","flag":null}\n'
    '{"id":7,"score":null,"name":null,"flag":true}\n'
    '{"id":null,"score":100.0,"name":"東京","flag":false}\n'
    '{"id":-1,"score":2.0,"name":"\\"Å\\" Ålesund","flag":false}\n'
    '{"id":8,"score":-0.5,"name":"Linje1\\rLinje2","flag":true}\n'
)


def _hex_window(bs: Span[UInt8, _], at: Int) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var lo = at - 8 if at >= 8 else 0
    var hi = at + 8 if at + 8 <= len(bs) else len(bs)
    var out = List[UInt8]()
    for i in range(lo, hi):
        if i > lo:
            out.append(UInt8(ord(" ")))
        out.append(digits[Int(bs[i]) >> 4])
        out.append(digits[Int(bs[i]) & 0xF])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _assert_bytes(got: Span[UInt8, _], want: String, label: String) raises:
    var w = want.as_bytes()
    var n = len(got) if len(got) < len(w) else len(w)
    for i in range(n):
        if got[i] != w[i]:
            raise Error(
                label + ": first difference at byte " + String(i) + ": got ["
                + _hex_window(got, i) + "] want [" + _hex_window(w, i) + "]"
            )
    if len(got) != len(w):
        raise Error(
            label + ": " + String(len(got)) + " bytes, want " + String(len(w))
            + " (equal up to byte " + String(n) + ")"
        )


def _find(hay: Span[UInt8, _], needle: Span[UInt8, _], start: Int) -> Int:
    var n = len(needle)
    var i = start
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


def _tree() raises -> String:
    var root = test_tmpdir() + "/formats_e2e_golden"
    write_hive_tree(root)
    return root


def test_csv_bytes_exact() raises:
    var root = _tree()
    var fs = _Fs.new()
    var z = fs.read_whole(file_path(root, city_zurich(), "csv"))
    _assert_bytes(z.view_range_ro(0, z.len()).into_span(), _CSV_ZURICH, "csv Zürich")
    var o = fs.read_whole(file_path(root, city_oslo(), "csv"))
    _assert_bytes(o.view_range_ro(0, o.len()).into_span(), _CSV_OSLO, "csv Oslo")


def test_jsonl_bytes_exact() raises:
    var root = _tree()
    var fs = _Fs.new()
    var z = fs.read_whole(file_path(root, city_zurich(), "jsonl"))
    _assert_bytes(
        z.view_range_ro(0, z.len()).into_span(), _JSONL_ZURICH, "jsonl Zürich"
    )
    var o = fs.read_whole(file_path(root, city_oslo(), "jsonl"))
    _assert_bytes(o.view_range_ro(0, o.len()).into_span(), _JSONL_OSLO, "jsonl Oslo")


def test_jsonl_reader_missing_key_and_surrogates() raises:
    var text = String(
        '{"id":1,"name":"a\\nb"}\n'
        '{"id":2,"score":null,"name":"\\ud83d\\ude00"}\n'
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))
    var b = materialize_jsonl_to_batch(text.as_bytes(), sb.build())
    assert_equal(b.num_rows(), 2, "two lines")
    var score = b.column_as_primitive_float64(0)
    assert_true(score.is_null(0), "missing `score` key reads as NULL")
    assert_true(score.is_null(1), "`score`:null reads as NULL")
    var ids = b.column_as_primitive_int64(1)
    assert_equal(ids.get(0), Int64(1), "id row 0")
    assert_equal(ids.get(1), Int64(2), "id row 1")
    var names = b.column_as_string(2)
    var n0 = names.get(0)
    _assert_bytes(n0.as_bytes(), String("a\nb"), "escaped LF decodes to one byte")
    var n1 = names.get(1)
    var smile = List[UInt8]()
    smile.append(0xF0)
    smile.append(0x9F)
    smile.append(0x98)
    smile.append(0x80)
    _assert_bytes(
        n1.as_bytes(),
        String(StringSlice(unsafe_from_utf8=Span(smile))),
        "surrogate pair decodes to U+1F600",
    )


def test_avro_ocf_framing() raises:
    var root = _tree()
    var fs = _Fs.new()
    var cs = [city_zurich(), city_oslo()]
    for ci in range(len(cs)):
        var city = String(cs[ci])
        var buf = fs.read_whole(file_path(root, city, "avro"))
        var bs = buf.view_range_ro(0, buf.len()).into_span()
        var label = "avro " + city
        assert_true(len(bs) > 4 + 16, label + ": file too short")
        assert_true(
            bs[0] == 0x4F and bs[1] == 0x62 and bs[2] == 0x6A and bs[3] == 0x01,
            label + ": magic is not 4F 62 6A 01",
        )
        var key = _find(bs, String("avro.schema").as_bytes(), 4)
        assert_true(key > 0, label + ": header has no avro.schema")
        var unions = [
            String('{"name":"id","type":["null","long"]'),
            String('{"name":"score","type":["null","double"]'),
            String('{"name":"name","type":["null","string"]'),
            String('{"name":"flag","type":["null","boolean"]'),
        ]
        for u in range(len(unions)):
            assert_true(
                _find(bs, unions[u].as_bytes(), key) > key,
                label + ": writer schema lacks " + unions[u],
            )
        # The header ends with the 16-byte sync; every block ends with it too,
        # so the file's last 16 bytes occur first right after the metadata.
        var n = len(bs)
        var tail = List[UInt8]()
        for i in range(n - 16, n):
            tail.append(bs[i])
        var first = _find(bs, Span(tail), key)
        assert_true(
            first > key and first < n - 16,
            label + ": the trailing 16 bytes are not the header sync",
        )


def test_orc_tail_stats_and_streams() raises:
    var rb = batch_for_city(city_zurich())
    var bytes = write_orc_bytes(
        rb, OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    )
    var bs = Span(bytes)
    assert_true(
        bs[0] == 0x4F and bs[1] == 0x52 and bs[2] == 0x43, "ORC: leading magic"
    )
    var tail = OrcFileTail.parse(bs)
    assert_equal(tail.footer.number_of_rows, 5, "ORC: rows")
    assert_equal(len(tail.footer.stripes), 1, "ORC: one stripe")

    var meta = Metadata.parse(bs[tail.metadata_start : tail.metadata_end])
    assert_equal(meta.stripe_stats_count, 1, "ORC: one StripeStatistics")
    ref st = meta.per_stripe_stats[0]
    # Node 0 is the root struct; 1..4 are id, score, name, flag. Each has
    # exactly one NULL among the five Zürich rows (rows 1, 2, 2, 2).
    assert_true(len(st.col_stats) >= 5, "ORC: stats for root + 4 columns")
    for c in range(1, 5):
        assert_equal(
            st.col_stats[c].number_of_values, 4, "ORC: non-null count of node " + String(c)
        )
        assert_true(st.col_stats[c].has_null, "ORC: hasNull of node " + String(c))

    ref si = tail.footer.stripes[0]
    var fstart = si.offset + si.index_length + si.data_length
    var sf = StripeFooter.parse(bs[fstart : fstart + si.footer_length])
    var score_data = -1
    for c in range(1, 5):
        var has_present = False
        for k in range(len(sf.streams)):
            if sf.streams[k].column == c and sf.streams[k].kind == ORC_STREAM_PRESENT:
                has_present = True
            if (
                c == 2
                and sf.streams[k].column == c
                and sf.streams[k].kind == ORC_STREAM_DATA
            ):
                score_data = sf.streams[k].length
        assert_true(has_present, "ORC: no PRESENT stream for node " + String(c))
    assert_equal(score_data, 32, "ORC: score DATA = 8 bytes x 4 non-null values")


def main() raises:
    test_csv_bytes_exact()
    test_jsonl_bytes_exact()
    test_jsonl_reader_missing_key_and_surrogates()
    test_avro_ocf_framing()
    test_orc_tail_stats_and_streams()
    print("test_formats_golden_bytes: ALL PASS")
