# =============================================================================
# test_arrow_readers_round_trip.mojo: the package's Arrow IPC readers read back
# what komira_arrow_ipc's encoders write, through every entry module.
# =============================================================================
#
# Writer: the Stream grammar (schema, record batches, EOS) and the File grammar
# (magic, schema, record batches, Blocks, footer, length, trailer) assembled
# from `komira_arrow_ipc.ipc_encoder_dispatch` pieces, with two batches so the
# readers' multi-batch concat runs, and an LZ4 variant for the codec readers.
#
# Reader, one test per entry module:
#   - `arrow_stream_reader.decode_arrow_ipc_stream` and its strict-codec
#     sibling (frames sliced and concatenated by `ipc_stream_frames`);
#   - `arrow_file_reader.decode_arrow_ipc_auto` on both grammars (the auto
#     rule picks the stream or the file walk by the leading magic);
#   - `arrow_file_reader_codec.decode_arrow_ipc_file_with_observed_codec`
#     reports the batches' codec and refuses a codec the caller forbade;
#   - `arrow_file_reader_mmap.decode_arrow_ipc_file_path_mmap` over a written
#     file, uncompressed (borrows the mapping) and LZ4 (copy fallback), and
#     `is_arrow1_file_format_path` on a file and on a stream.
# Each decoded batch is compared with an independently built expected batch by
# `record_batch_diff` (schema, row count, every cell and validity bit). A
# reader that lost a batch, mis-sliced a frame, or dropped a validity bit
# fails the diff; one that ignored the strict codec returns instead of raising.
# =============================================================================

from std.io import FileHandle
from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression_codecs import Lz4Frame
from komira_arrow_ipc.ipc_body_compression import encode_record_batch_message_compressed
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    arrow_ipc_file_magic_header,
    arrow_ipc_message_metadata_length,
    encode_footer_message,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_arrow_ipc.ipc_flatbuf import Block
from komira_arrow_ipc.record_batch_compare import record_batch_diff

from komira_op_sources.arrow_file_reader import decode_arrow_ipc_auto
from komira_op_sources.arrow_file_reader_codec import (
    decode_arrow_ipc_file_with_observed_codec,
)
from komira_op_sources.arrow_file_reader_mmap import (
    decode_arrow_ipc_file_path_mmap,
    is_arrow1_file_format_path,
)
from komira_op_sources.arrow_stream_reader import (
    decode_arrow_ipc_stream,
    decode_arrow_ipc_stream_with_observed_codec,
)
from komira_op_sources.ipc_dict_cache import IpcDictCache

comptime _ROWS_A = 7
comptime _ROWS_B = 13
comptime _NO_STRICT = Int8(-2)
comptime _LZ4 = Int8(0)
comptime _ZSTD = Int8(1)


# ---------------------------------------------------------------------------
# Data: row g has id = g; v = g*3 - 10, NULL when g%3 == 0;
# s = "r{g}" + "x"*(g%4), NULL when g%5 == 4.
# ---------------------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT32, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _columns(n: Int, base: Int) raises -> Slab[Column[HeapRegion]]:
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var v = PrimitiveArray[DType.int32].allocate_nullable(n)
    var s_vals = List[String]()
    var s_valid = List[Bool]()
    for i in range(n):
        var g = base + i
        ids.set(i, Int64(g))
        if g % 3 == 0:
            v._set_null(i)
        else:
            v.set(i, Int32(g * 3 - 10))
        var s = "r" + String(g)
        for _ in range(g % 4):
            s += "x"
        s_valid.append(g % 5 != 4)
        s_vals.append(s if g % 5 != 4 else String(""))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](ids^))
    cols.append(Column.from_primitive[DType.int32](v^))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(s_vals, s_valid)))
    return cols^


def _expected() raises -> RecordBatch:
    """Both batches as one: the readers concatenate every batch they read."""
    var cols = _columns(_ROWS_A + _ROWS_B, 0)
    var bb = RecordBatchBuilder()
    while len(cols) > 0:
        bb.add_column(cols.take_at(0))
    return bb.build(_schema())


def _frame(n: Int, base: Int, codec: Int8) raises -> SharedAlignedBuffer[HeapRegion]:
    if codec == _LZ4:
        return encode_record_batch_message_compressed[Lz4Frame](_columns(n, base))
    return encode_record_batch_message(_columns(n, base))


def _append(mut out: List[UInt8], b: SharedAlignedBuffer[HeapRegion]):
    for i in range(b.len()):
        out.append(b.read_u8_at(i))


def _stream_bytes(codec: Int8) raises -> List[UInt8]:
    var out = List[UInt8]()
    _append(out, encode_schema_message(_schema()))
    _append(out, _frame(_ROWS_A, 0, codec))
    _append(out, _frame(_ROWS_B, _ROWS_A, codec))
    _append(out, arrow_ipc_eos_bytes())
    return out^


def _file_bytes(codec: Int8) raises -> List[UInt8]:
    var out = List[UInt8]()
    _append(out, arrow_ipc_file_magic_header())
    _append(out, encode_schema_message(_schema()))
    var blocks = List[Block]()
    var rows: List[Int] = [_ROWS_A, _ROWS_B]
    var base = 0
    for k in range(2):
        var frame = _frame(rows[k], base, codec)
        var meta = Int(arrow_ipc_message_metadata_length(frame))
        blocks.append(
            Block(
                offset=Int64(len(out)),
                meta_data_length=Int32(meta),
                body_length=Int64(frame.len() - meta),
            )
        )
        _append(out, frame)
        base += rows[k]
    _append(out, encode_footer_message(_schema(), List[Block](), blocks^))
    return out^


def _scratch(name: String) -> String:
    var d = getenv("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = getenv("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_op_sources_readers_" + name


def _write(path: String, bytes: List[UInt8]) raises:
    var h = FileHandle(path, "w")
    h.write_bytes(Span(bytes))
    h.close()


def _check(got: RecordBatch, what: String) raises:
    var d = record_batch_diff(_expected(), got)
    assert_true(d.equal, what + ": " + d.reason)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_stream_reader_reads_both_batches() raises:
    _check(decode_arrow_ipc_stream(_stream_bytes(Int8(-1))), "stream")


def test_auto_picks_the_stream_and_the_file_walk() raises:
    _check(decode_arrow_ipc_auto(_stream_bytes(Int8(-1))), "auto on a stream")
    _check(decode_arrow_ipc_auto(_file_bytes(Int8(-1))), "auto on a file")


def test_stream_observed_codec_reports_and_enforces() raises:
    var cache = IpcDictCache()
    var observed = Int8(-3)
    _check(
        decode_arrow_ipc_stream_with_observed_codec(_stream_bytes(_LZ4), cache, observed, _NO_STRICT),
        "lz4 stream",
    )
    assert_equal(observed, _LZ4)
    var raised = False
    try:
        var c2 = IpcDictCache()
        var o2 = Int8(-3)
        _ = decode_arrow_ipc_stream_with_observed_codec(_stream_bytes(_LZ4), c2, o2, _ZSTD)
    except e:
        raised = True
        assert_true(String(e).find("StrictMixedCodec") >= 0, String(e))
    assert_true(raised, "a stream whose batches are LZ4 must be refused when ZSTD is required")


def test_file_observed_codec_reports_and_enforces() raises:
    var cache = IpcDictCache()
    var observed = Int8(-3)
    _check(
        decode_arrow_ipc_file_with_observed_codec(_file_bytes(_LZ4), cache, observed, _NO_STRICT),
        "lz4 file",
    )
    assert_equal(observed, _LZ4)
    var raised = False
    try:
        var c2 = IpcDictCache()
        var o2 = Int8(-3)
        _ = decode_arrow_ipc_file_with_observed_codec(_file_bytes(_LZ4), c2, o2, _ZSTD)
    except e:
        raised = True
        assert_true(String(e).find("StrictMixedCodec") >= 0, String(e))
    assert_true(raised, "a file whose batches are LZ4 must be refused when ZSTD is required")


def test_mmap_reader_reads_a_written_file() raises:
    var plain = _scratch("plain.arrow")
    _write(plain, _file_bytes(Int8(-1)))
    assert_true(is_arrow1_file_format_path(plain), "a File-format path has the magic")
    var cache = IpcDictCache()
    _check(decode_arrow_ipc_file_path_mmap(plain, cache), "mmap uncompressed")

    var lz4 = _scratch("lz4.arrow")
    _write(lz4, _file_bytes(_LZ4))
    var cache2 = IpcDictCache()
    _check(decode_arrow_ipc_file_path_mmap(lz4, cache2), "mmap lz4 fallback")

    var stream = _scratch("stream.arrows")
    _write(stream, _stream_bytes(Int8(-1)))
    assert_false(is_arrow1_file_format_path(stream), "a stream has no File magic")


def test_truncated_file_is_refused() raises:
    var bytes = _file_bytes(Int8(-1))
    var cut = List[UInt8]()
    for i in range(len(bytes) - 3):
        cut.append(bytes[i])
    var raised = False
    try:
        _ = decode_arrow_ipc_auto(cut^)
    except:
        raised = True
    assert_true(raised, "a File missing its trailer must raise, not decode")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
