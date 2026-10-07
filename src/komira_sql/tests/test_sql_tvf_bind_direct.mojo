# =============================================================================
# Direct tests of komira_sql.sql_tvf_bind: the bind-time schema of the
# read_csv / read_json / read_avro table functions and the scan leaf each one
# lowers to.
# =============================================================================
#
# Every input file is written under $TEST_TMPDIR by the test itself. What each
# test proves, and the defect (mutant) it catches:
#   1. csv_tvf_schema on `k;name` rows with delimiter ';' and has_header True
#      gives 2 columns, `k` int64 and `name` string.
#      (mutant: `_csv_read_options` drops the delimiter -> one column)
#   2. The same file with all_varchar gives the same 2 names, both STRING, with
#      the inferred nullability.
#      (mutant: the `all_varchar` branch skipped -> `k` stays int64)
#   3. has_header False reads the header row as data: the names are `col_0`,
#      `col_1`, never `k`, and column 0 is STRING because it holds `k`.
#      (mutant: `has_header` not threaded -> the names are `k`, `name`)
#   4. A CSV file holding only blank lines raises `inferred ZERO columns`.
#      (A 0-byte file never reaches the guard: mapping it raises first.)
#      (mutant: the zero-column guard removed -> no raise)
#   5. A `.csv.gz` file binds to the same schema as its plain text, through
#      the decompressing arm.
#      (mutant: the compressed-path test negated -> gzip bytes parsed as CSV)
#   6. json_tvf_schema on a 2-record `.jsonl` file gives its 2 keys; a
#      `.jsonl.gz` file gives the same; a file of blank lines raises
#      `inferred ZERO columns`.
#      (mutants: the JSON zero-column guard removed; the compressed arm reads
#      the raw bytes)
#   7. _jsonl_prefix_end: a short span ends at its length; a long span snaps
#      back to just past its last newline inside 256 KiB; a long span with no
#      newline in that window ends at 256 KiB.
#      (mutants: `<=` made `<`; the snap returned one byte short; the
#      no-newline fallback returning 0)
#   8. avro_tvf_schema reads the schema from a hand-built OCF header: a
#      record of `x: long` and `s: string` gives 2 columns, int64 and string.
#      (mutant: `avro_tvf_schema` returning an empty schema)
#   9. tvf_relation_schema dispatches each kind to its own arm: a CSV, a JSONL
#      and an Avro relation each bind to the schema of their direct call.
#      (mutant: the TVF_AVRO arm removed -> the OCF goes to JSON inference)
#  10. tvf_relation_scan on a read_csv relation returns a scan whose output
#      schema is csv_tvf_schema's and whose source is the CSV arm with the
#      fingerprint of `CsvSource(path, schema, mtime, RFC4180, ';', True)`:
#      the dialect and the file's mtime reach the leaf.
#      (mutants: the scan built with default CSV options; `mtime_ns` left 0)
#  11. tvf_relation_scan on read_json and read_avro relations: the JSON and
#      Avro arms, with the fingerprint of the source built with the stat
#      mtime.
#      (mutants: the avro arm left to the JSON arm; `mtime_ns` left 0)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema
from komira_buffer.file_identity import FileIdentity
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_csv.csv_options import QUOTE_STYLE_TAG_RFC4180
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env
from komira_parquet_api.types import CompressionCodec
from komira_parquet_codec.compression import compress, compress_bound
from komira_scan_source.avro_source import AvroSource
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_AVRO,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_JSON,
)

from komira_sql.sql_ast import FromRelation, TvfOptions, TVF_AVRO, TVF_CSV, TVF_JSON
from komira_sql.sql_tvf_bind import (
    _jsonl_prefix_end,
    avro_tvf_schema,
    csv_tvf_schema,
    json_tvf_schema,
    tvf_relation_scan,
    tvf_relation_schema,
)


# =============================================================================
# Helpers
# =============================================================================


def _scratch_path(name: String) -> String:
    """`name` under the directory this execution may write into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + String("/") + name


def _bytes_of(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _write(name: String, bytes: Span[UInt8, _]) raises -> String:
    var path = _scratch_path(name)
    var handle = open(path, "w")
    write_chunked(handle, bytes)
    handle.close()
    return path^


def _write_text(name: String, text: String) raises -> String:
    return _write(name, _bytes_of(text))


def _gzip(payload: Span[UInt8, _]) raises -> List[UInt8]:
    var bound = compress_bound(CompressionCodec.GZIP, len(payload))
    var buf = OwnedAlignedBuffer(bound)
    var n = compress(CompressionCodec.GZIP, payload, buf.into_span_capacity())
    var out = List[UInt8]()
    var span = buf.into_span_capacity()
    for i in range(n):
        out.append(span[i])
    return out^


comptime _CSV_TEXT = "k;name\n1;alpha\n2;beta\n3;gamma\n"
comptime _JSONL_TEXT = '{"a": 1, "b": "x"}\n{"a": 2, "b": "y"}\n'


def _semicolon_opts() -> TvfOptions:
    var o = TvfOptions()
    o.delimiter = UInt8(ord(";"))
    o.has_header = True
    return o^


def _avro_long(v: Int, mut out: List[UInt8]):
    """Append `v` as an Avro long: zigzag, then a base-128 varint."""
    var z = UInt64((v << 1) ^ (v >> 63))
    while z >= 0x80:
        out.append(UInt8((z & 0x7F) | 0x80))
        z = z >> 7
    out.append(UInt8(z))


def _ocf_header_only(schema_json: String) -> List[UInt8]:
    """An OCF file with a one-entry metadata map (`avro.schema`), its sync
    marker and no data block."""
    var out: List[UInt8] = [UInt8(ord("O")), UInt8(ord("b")), UInt8(ord("j")), 1]
    _avro_long(1, out)
    var key = String("avro.schema")
    _avro_long(key.byte_length(), out)
    for b in key.as_bytes():
        out.append(b)
    _avro_long(schema_json.byte_length(), out)
    for b in schema_json.as_bytes():
        out.append(b)
    _avro_long(0, out)
    for i in range(16):
        out.append(UInt8(0xA0 + i))
    return out^


comptime _AVRO_SCHEMA = (
    '{"type": "record", "name": "r", "fields": [{"name": "x", "type":'
    ' "long"}, {"name": "s", "type": "string"}]}'
)


def _assert_same_schema(got: Schema, want: Schema, what: String) raises:
    assert_equal(got.num_columns(), want.num_columns(), what + ": column count")
    for i in range(want.num_columns()):
        var g = got.field_at_unchecked(i)
        var w = want.field_at_unchecked(i)
        assert_equal(g.name, w.name, what + ": name of column " + String(i))
        assert_true(g.arrow_type == w.arrow_type, what + ": type of column " + String(i))
        assert_equal(g.nullable, w.nullable, what + ": nullability of column " + String(i))


def _mtime(path: String) -> UInt64:
    return UInt64(FileIdentity.stat_path(path).mtime_ns)


# =============================================================================
# 1-5: csv_tvf_schema
# =============================================================================


def test_csv_semicolon_header_gives_two_typed_columns() raises:
    var path = _write_text("t1.csv", _CSV_TEXT)
    var s = csv_tvf_schema(path, _semicolon_opts())
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_at_unchecked(0).name, "k")
    assert_equal(s.field_at_unchecked(1).name, "name")
    assert_true(s.field_at_unchecked(0).arrow_type == ArrowType.INT64, "k is int64")
    assert_true(s.field_at_unchecked(1).arrow_type == ArrowType.STRING, "name is string")


def test_csv_all_varchar_types_every_column_string() raises:
    var path = _write_text("t2.csv", _CSV_TEXT)
    var inferred = csv_tvf_schema(path, _semicolon_opts())
    var o = _semicolon_opts()
    o.all_varchar = True
    var s = csv_tvf_schema(path, o)
    assert_equal(s.num_columns(), 2)
    for i in range(2):
        var f = s.field_at_unchecked(i)
        assert_equal(f.name, inferred.field_at_unchecked(i).name)
        assert_true(f.arrow_type == ArrowType.STRING, "all_varchar column is string")
        assert_equal(f.nullable, inferred.field_at_unchecked(i).nullable)


def test_csv_has_header_false_reads_header_row_as_data() raises:
    var path = _write_text("t3.csv", _CSV_TEXT)
    var o = _semicolon_opts()
    o.has_header = False
    var s = csv_tvf_schema(path, o)
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_at_unchecked(0).name, "col_0")
    assert_equal(s.field_at_unchecked(1).name, "col_1")
    assert_true(
        s.field_at_unchecked(0).arrow_type == ArrowType.STRING,
        "column 0 holds the text `k`, so it is string",
    )


def test_csv_blank_file_raises_zero_columns() raises:
    var path = _write_text("t4.csv", "\n\n")
    var raised = False
    try:
        _ = csv_tvf_schema(path, _semicolon_opts())
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find("inferred ZERO columns") >= 0, msg)
        assert_true(msg.find("read_csv('") >= 0, msg)
    assert_true(raised, "a CSV file of blank lines must raise")


def test_csv_gz_binds_through_the_decompressing_arm() raises:
    var plain = _write_text("t5.csv", _CSV_TEXT)
    var gz = _write("t5.csv.gz", _gzip(_bytes_of(_CSV_TEXT)))
    _assert_same_schema(
        csv_tvf_schema(gz, _semicolon_opts()),
        csv_tvf_schema(plain, _semicolon_opts()),
        "csv.gz",
    )


# =============================================================================
# 6-7: json_tvf_schema and its prefix
# =============================================================================


def test_json_schema_plain_and_gz() raises:
    var plain = _write_text("t6.jsonl", _JSONL_TEXT)
    var s = json_tvf_schema(plain)
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_at_unchecked(0).name, "a")
    assert_equal(s.field_at_unchecked(1).name, "b")
    var gz = _write("t6.jsonl.gz", _gzip(_bytes_of(_JSONL_TEXT)))
    _assert_same_schema(json_tvf_schema(gz), s, "jsonl.gz")


def test_json_blank_file_raises_zero_columns() raises:
    var path = _write_text("t6b.jsonl", "\n\n")
    var raised = False
    try:
        _ = json_tvf_schema(path)
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find("inferred ZERO columns") >= 0, msg)
        assert_true(msg.find("read_json('") >= 0, msg)
    assert_true(raised, "a JSONL file of blank lines must raise")


def test_jsonl_prefix_end_bounds_and_snaps() raises:
    comptime CAP = 256 * 1024
    # At the bound: the whole span, even with a newline inside it.
    var exact = List[UInt8](length=CAP, fill=UInt8(ord("x")))
    exact[10] = UInt8(0x0A)
    assert_equal(_jsonl_prefix_end(Span(exact)), CAP)
    # Past the bound, newlines at 99 and CAP - 10: snap to just past the
    # last one inside the window.
    var long = List[UInt8](length=CAP + 100, fill=UInt8(ord("x")))
    long[99] = UInt8(0x0A)
    long[CAP - 10] = UInt8(0x0A)
    long[CAP + 50] = UInt8(0x0A)
    assert_equal(_jsonl_prefix_end(Span(long)), CAP - 9)
    # Past the bound with no newline in the window: the window itself.
    var flat = List[UInt8](length=CAP + 1, fill=UInt8(ord("x")))
    assert_equal(_jsonl_prefix_end(Span(flat)), CAP)


# =============================================================================
# 8-9: avro_tvf_schema and the dispatch
# =============================================================================


def test_avro_schema_from_ocf_header() raises:
    var path = _write("t8.avro", _ocf_header_only(_AVRO_SCHEMA))
    var s = avro_tvf_schema(path)
    assert_equal(s.num_columns(), 2)
    assert_equal(s.field_at_unchecked(0).name, "x")
    assert_equal(s.field_at_unchecked(1).name, "s")
    assert_true(s.field_at_unchecked(0).arrow_type == ArrowType.INT64, "x is int64")
    assert_true(s.field_at_unchecked(1).arrow_type == ArrowType.STRING, "s is string")


def test_relation_schema_dispatches_each_kind() raises:
    var csv = _write_text("t9.csv", _CSV_TEXT)
    var jsonl = _write_text("t9.jsonl", _JSONL_TEXT)
    var avro = _write("t9.avro", _ocf_header_only(_AVRO_SCHEMA))
    _assert_same_schema(
        tvf_relation_schema(FromRelation.tvf_of(csv, TVF_CSV, _semicolon_opts())),
        csv_tvf_schema(csv, _semicolon_opts()),
        "csv relation",
    )
    _assert_same_schema(
        tvf_relation_schema(FromRelation.tvf_of(jsonl, TVF_JSON, TvfOptions())),
        json_tvf_schema(jsonl),
        "json relation",
    )
    _assert_same_schema(
        tvf_relation_schema(FromRelation.tvf_of(avro, TVF_AVRO, TvfOptions())),
        avro_tvf_schema(avro),
        "avro relation",
    )


# =============================================================================
# 10-11: tvf_relation_scan
# =============================================================================


def test_csv_scan_carries_dialect_and_mtime() raises:
    var path = _write_text("t10.csv", _CSV_TEXT)
    var schema = csv_tvf_schema(path, _semicolon_opts())
    var plan = tvf_relation_scan(FromRelation.tvf_of(path, TVF_CSV, _semicolon_opts()))
    assert_true(plan.is_scan(), "read_csv lowers to a scan")
    _assert_same_schema(plan.output_schema, schema, "csv scan schema")
    ref source = plan.scan_data_ref().source
    assert_equal(Int(source.tag), Int(SOURCE_VARIANT_CSV))
    var mtime = _mtime(path)
    assert_true(mtime != 0, "a written file has a nonzero mtime")
    var want = SourceVariant(
        CsvSource(
            String(path), schema.copy(), mtime_ns=mtime,
            quote_style_tag=QUOTE_STYLE_TAG_RFC4180,
            delimiter=UInt8(ord(";")), has_header=True,
        )
    )
    assert_equal(source.fingerprint(), want.fingerprint(), "dialect + mtime")
    var default_dialect = SourceVariant(
        CsvSource(String(path), schema.copy(), mtime_ns=mtime)
    )
    assert_true(
        source.fingerprint() != default_dialect.fingerprint(),
        "the default dialect is a different source",
    )


def test_json_and_avro_scans_carry_mtime() raises:
    var jsonl = _write_text("t11.jsonl", _JSONL_TEXT)
    var jschema = json_tvf_schema(jsonl)
    var jplan = tvf_relation_scan(FromRelation.tvf_of(jsonl, TVF_JSON, TvfOptions()))
    assert_true(jplan.is_scan(), "read_json lowers to a scan")
    _assert_same_schema(jplan.output_schema, jschema, "json scan schema")
    ref jsource = jplan.scan_data_ref().source
    assert_equal(Int(jsource.tag), Int(SOURCE_VARIANT_JSON))
    var jwant = SourceVariant(
        JsonSource(String(jsonl), jschema.copy(), mtime_ns=_mtime(jsonl))
    )
    assert_equal(jsource.fingerprint(), jwant.fingerprint(), "json mtime")

    var avro = _write("t11.avro", _ocf_header_only(_AVRO_SCHEMA))
    var aschema = avro_tvf_schema(avro)
    var aplan = tvf_relation_scan(FromRelation.tvf_of(avro, TVF_AVRO, TvfOptions()))
    assert_true(aplan.is_scan(), "read_avro lowers to a scan")
    _assert_same_schema(aplan.output_schema, aschema, "avro scan schema")
    ref asource = aplan.scan_data_ref().source
    assert_equal(Int(asource.tag), Int(SOURCE_VARIANT_AVRO))
    var amtime = _mtime(avro)
    var awant = SourceVariant(AvroSource(String(avro), aschema.copy(), mtime_ns=amtime))
    assert_equal(asource.fingerprint(), awant.fingerprint(), "avro mtime")
    var unpinned = SourceVariant(AvroSource(String(avro), aschema.copy()))
    assert_true(
        asource.fingerprint() != unpinned.fingerprint(),
        "a leaf with mtime 0 is a different source",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
