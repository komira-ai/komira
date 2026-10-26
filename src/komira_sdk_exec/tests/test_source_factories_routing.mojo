# =============================================================================
# file_source(path) routes by extension; FileSource keeps one arm per format
# =============================================================================
#
# `file_source(path)` (`source_factories.mojo`) picks a `SourceVariant` arm from
# the lower-cased extension. `FileSource[F]` (`file_source.mojo`) holds a
# `ParquetSource` for the five Parquet codecs and a `JsonSource` for `Jsonl`,
# and answers empty for any other format. The files here are built byte by byte
# under the test's scratch directory: a Parquet file with a hand-written Thrift
# footer, and an Arrow IPC File with a schema message and a footer, no batches.
#
# What each test proves, and the defect it catches:
#   * every Parquet extension (`.parquet`, `.parquet.zst`, `.parquet.gz`,
#     `.parquet.uncompressed`, and an upper-case spelling) gives the Parquet
#     arm with the footer's schema `a int64 not-null, s string nullable` (an
#     extension dropped from the cascade falls to the "unknown extension"
#     error; a case-sensitive match fails the upper-case path);
#   * a Parquet file with a garbage footer raises (a footer error swallowed);
#   * `.arrow`, `.arrows` and `.feather` give the Arrow arm
#     (`SOURCE_VARIANT_ARROW_UNCOMPRESSED`) with the footer's schema
#     `id int64 not-null, s string nullable` (an extension dropped; the wrong
#     arm; the schema left empty);
#   * an Arrow file that is too short, has a wrong head magic, a wrong trailer
#     magic, or a zero footer length raises with the message that names the
#     check (a check skipped or merged into another);
#   * `.csv` gives the CSV arm with an empty schema;
#   * each of the nine JSON extensions raises with the JSON message (one
#     dropped from the cascade gets the "unknown extension" message instead);
#   * an unrecognized extension raises and names the path;
#   * `FileSource[...].from_path` returns the Parquet arm with the footer's
#     schema and raises on a bad file;
#   * each of the five Parquet codecs holds a source: schema with two columns,
#     a non-zero fingerprint, a copy with the same schema and fingerprint, and
#     pushdown accepted for `a == 5` (a codec left out of one accessor's
#     cascade answers empty for that accessor);
#   * `FileSource[Csv]` holds no source: empty schema, -1 rows, fingerprint 0,
#     no pushdown;
#   * `FileSource[Jsonl]` answers its caller schema, -1 rows, a non-zero
#     fingerprint and no pushdown (the JSON arm confused with the Parquet one).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.formats import Csv, Jsonl, Parquet
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.serde_format import SerdeFormat
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_file_magic_header,
    encode_footer_message,
    encode_schema_message,
)
from komira_arrow_ipc.ipc_flatbuf import Block
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_compression.compression_codecs import (
    Gzip,
    Lz4Raw,
    Snappy,
    Uncompressed,
    Zstd,
)
from komira_plan_expr.expr import BIN_EQ, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_ARROW_UNCOMPRESSED,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_PARQUET,
)

from komira_sdk_exec.file_source import FileSource
from komira_sdk_exec.source_factories import file_source


# ---------------------------------------------------------------------------
# A Parquet file with a hand-written footer (schema: root, `a` INT64 REQUIRED,
# `s` BYTE_ARRAY UTF8 OPTIONAL; 42 rows; no row groups).
# ---------------------------------------------------------------------------


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _name(mut out: List[UInt8], header: UInt8, name: String):
    out.append(header)
    _uleb(out, name.byte_length())
    for b in name.as_bytes():
        out.append(b)


def _parquet_footer() -> List[UInt8]:
    var f: List[UInt8] = [0x15]  # 1: i32 version
    _zz(f, 2)
    f.append(0x19)  # 2: list schema
    f.append(0x3C)  # 3 structs
    _name(f, 0x48, "schema")  # root: 4 name, 5 num_children
    f.append(0x15)
    _zz(f, 2)
    f.append(0x00)
    f.append(0x15)  # a: type INT64, repetition REQUIRED, name
    _zz(f, 2)
    f.append(0x25)
    _zz(f, 0)
    _name(f, 0x18, "a")
    f.append(0x00)
    f.append(0x15)  # s: type BYTE_ARRAY, repetition OPTIONAL, name, UTF8
    _zz(f, 6)
    f.append(0x25)
    _zz(f, 1)
    _name(f, 0x18, "s")
    f.append(0x25)
    _zz(f, 0)
    f.append(0x00)
    f.append(0x16)  # 3: i64 num_rows
    _zz(f, 42)
    f.append(0x19)  # 4: list row_groups, empty
    f.append(0x0C)
    f.append(0x00)
    return f^


def _parquet_bytes(body: List[UInt8]) -> List[UInt8]:
    """`PAR1`, padding, `body` as the footer, its length and `PAR1`."""
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(24):
        out.append(UInt8(i * 7 % 251))
    for i in range(len(body)):
        out.append(body[i])
    var n = len(body)
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    for b in "PAR1".as_bytes():
        out.append(b)
    return out^


# ---------------------------------------------------------------------------
# An Arrow IPC File: header magic, schema message, footer with no batches.
# ---------------------------------------------------------------------------


def _arrow_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _append(mut out: List[UInt8], b: SharedAlignedBuffer[HeapRegion]):
    for i in range(b.len()):
        out.append(b.read_u8_at(i))


def _arrow_bytes() raises -> List[UInt8]:
    var out = List[UInt8]()
    _append(out, arrow_ipc_file_magic_header())
    _append(out, encode_schema_message(_arrow_schema()))
    _append(out, encode_footer_message(_arrow_schema(), List[Block](), List[Block]()))
    return out^


def _write(file_name: String, data: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + file_name
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()
    return path^


def _assert_a_s(schema: Schema) raises:
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "a")
    assert_equal(schema.field_arrow_type(0), ArrowType.INT64)
    assert_false(schema.field_nullable(0))
    assert_equal(schema.field_name(1), "s")
    assert_equal(schema.field_arrow_type(1), ArrowType.STRING)
    assert_true(schema.field_nullable(1))


def _assert_id_s(schema: Schema) raises:
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_name(0), "id")
    assert_equal(schema.field_arrow_type(0), ArrowType.INT64)
    assert_false(schema.field_nullable(0))
    assert_equal(schema.field_name(1), "s")
    assert_equal(schema.field_arrow_type(1), ArrowType.STRING)
    assert_true(schema.field_nullable(1))


def _a_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _a_eq_5() raises -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5))
    )


# ---------------------------------------------------------------------------
# file_source: Parquet
# ---------------------------------------------------------------------------


def _check_parquet_route(file_name: String) raises:
    var path = _write(file_name, _parquet_bytes(_parquet_footer()))
    var sv = file_source(String(path))
    assert_equal(sv.tag, SOURCE_VARIANT_PARQUET)
    _assert_a_s(sv.schema())


def test_every_parquet_extension_gives_the_parquet_arm() raises:
    _check_parquet_route("sf_ok.parquet")
    _check_parquet_route("sf_ok.parquet.zst")
    _check_parquet_route("sf_ok.parquet.gz")
    _check_parquet_route("sf_ok.parquet.uncompressed")
    _check_parquet_route("SF_UPPER.PARQUET")


def test_a_garbage_parquet_footer_raises() raises:
    var garbage: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    var path = _write("sf_garbage.parquet", _parquet_bytes(garbage))
    with assert_raises():
        _ = file_source(String(path))


# ---------------------------------------------------------------------------
# file_source: Arrow IPC
# ---------------------------------------------------------------------------


def _check_arrow_route(file_name: String) raises:
    var path = _write(file_name, _arrow_bytes())
    var sv = file_source(String(path))
    assert_equal(sv.tag, SOURCE_VARIANT_ARROW_UNCOMPRESSED)
    _assert_id_s(sv.schema())


def test_every_arrow_extension_gives_the_arrow_arm() raises:
    _check_arrow_route("sf_ok.arrow")
    _check_arrow_route("sf_ok.arrows")
    _check_arrow_route("sf_ok.feather")
    _check_arrow_route("SF_UPPER.ARROW")


def test_arrow_file_too_short_raises() raises:
    var short: List[UInt8] = [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31, 0, 0, 1, 2]
    var path = _write("sf_short.arrow", short)
    with assert_raises(contains="too short"):
        _ = file_source(String(path))


def test_arrow_file_with_a_wrong_head_magic_raises() raises:
    var bytes = _arrow_bytes()
    bytes[0] = 0x00
    var path = _write("sf_head.arrow", bytes)
    with assert_raises(contains="magic header"):
        _ = file_source(String(path))


def test_arrow_file_with_a_wrong_trailer_magic_raises() raises:
    var bytes = _arrow_bytes()
    bytes[len(bytes) - 1] = 0x00
    var path = _write("sf_trailer.arrow", bytes)
    with assert_raises(contains="trailer magic"):
        _ = file_source(String(path))


def test_arrow_file_with_a_zero_footer_length_raises() raises:
    var bytes = _arrow_bytes()
    var n = len(bytes)
    for k in range(4):
        bytes[n - 10 + k] = 0x00
    var path = _write("sf_footer_len.arrow", bytes)
    with assert_raises(contains="invalid footer_length"):
        _ = file_source(String(path))


def test_arrow_file_with_an_oversized_footer_length_raises() raises:
    var bytes = _arrow_bytes()
    var n = len(bytes)
    bytes[n - 10] = 0xFF
    bytes[n - 9] = 0xFF
    var path = _write("sf_footer_big.arrow", bytes)
    with assert_raises(contains="invalid footer_length"):
        _ = file_source(String(path))


# ---------------------------------------------------------------------------
# file_source: CSV, JSON, unknown
# ---------------------------------------------------------------------------


def test_csv_gives_the_csv_arm_with_an_empty_schema() raises:
    var sv = file_source(String("in.csv"))
    assert_equal(sv.tag, SOURCE_VARIANT_CSV)
    assert_equal(sv.schema().num_columns(), 0)
    var upper = file_source(String("IN.CSV"))
    assert_equal(upper.tag, SOURCE_VARIANT_CSV)


def _refuses_json(path: String) raises:
    with assert_raises(contains="JSON inputs are read via"):
        _ = file_source(String(path))


def test_every_json_extension_raises_the_json_message() raises:
    _refuses_json("in.jsonl")
    _refuses_json("in.ndjson")
    _refuses_json("in.json")
    _refuses_json("in.jsonl.gz")
    _refuses_json("in.ndjson.gz")
    _refuses_json("in.jsonl.zst")
    _refuses_json("in.ndjson.zst")
    _refuses_json("in.jsonl.lz4")
    _refuses_json("in.ndjson.lz4")
    _refuses_json("IN.JSONL")


def test_an_unknown_extension_raises_and_names_the_path() raises:
    with assert_raises(contains="unknown extension in path 'data.xyz'"):
        _ = file_source(String("data.xyz"))


# ---------------------------------------------------------------------------
# FileSource
# ---------------------------------------------------------------------------


def test_from_path_returns_the_parquet_arm_with_the_footer_schema() raises:
    var path = _write("fs_from_path.parquet", _parquet_bytes(_parquet_footer()))
    var sv = FileSource[Parquet[Zstd[3]]].from_path(String(path))
    assert_equal(sv.tag, SOURCE_VARIANT_PARQUET)
    _assert_a_s(sv.schema())


def test_from_path_on_a_bad_file_raises() raises:
    var garbage: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    var path = _write("fs_from_path_bad.parquet", _parquet_bytes(garbage))
    with assert_raises():
        _ = FileSource[Parquet[Snappy]].from_path(String(path))


def _check_parquet_codec_arm[F: SerdeFormat](path: String) raises:
    var fs = FileSource[F](String(path), _a_schema())
    _assert_a_s(fs.schema())
    assert_true(fs.fingerprint() != UInt64(0))
    assert_true(fs.supports_filter_pushdown(_a_eq_5()))
    assert_true(Bool(fs.parquet_source_view()))
    assert_false(Bool(fs.json_source_view()))
    var copied = fs.copy()
    _assert_a_s(copied.schema())
    assert_equal(copied.fingerprint(), fs.fingerprint())


def test_each_parquet_codec_holds_a_source() raises:
    _check_parquet_codec_arm[Parquet[Uncompressed]]("c0.parquet")
    _check_parquet_codec_arm[Parquet[Snappy]]("c1.parquet")
    _check_parquet_codec_arm[Parquet[Zstd[3]]]("c2.parquet")
    _check_parquet_codec_arm[Parquet[Gzip[6]]]("c3.parquet")
    _check_parquet_codec_arm[Parquet[Lz4Raw]]("c4.parquet")


def test_a_format_with_no_source_answers_empty() raises:
    var fs = FileSource[Csv[]](String("in.csv"), _a_schema())
    assert_equal(fs.schema().num_columns(), 0)
    assert_equal(fs.estimate_rows(), -1)
    assert_equal(fs.fingerprint(), UInt64(0))
    assert_false(fs.supports_filter_pushdown(_a_eq_5()))
    assert_false(Bool(fs.parquet_source_view()))
    assert_false(Bool(fs.json_source_view()))


def test_the_jsonl_arm_answers_from_its_json_source() raises:
    var fs = FileSource[Jsonl](String("in.jsonl"), _a_schema())
    _assert_a_s(fs.schema())
    assert_equal(fs.estimate_rows(), -1)
    assert_true(fs.fingerprint() != UInt64(0))
    assert_false(fs.supports_filter_pushdown(_a_eq_5()))
    assert_true(Bool(fs.json_source_view()))
    assert_false(Bool(fs.parquet_source_view()))
    var copied = fs.copy()
    assert_equal(copied.fingerprint(), fs.fingerprint())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
