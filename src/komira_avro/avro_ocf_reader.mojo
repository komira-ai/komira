# =============================================================================
# avro_ocf_reader.mojo — OCF reader paths (identity and full resolution).
# =============================================================================
#
# `read_avro_bytes` / `read_avro_file` use IDENTITY resolution (strict mode):
#   WriterSchema == ReaderSchema == the schema embedded in the OCF header.
# `read_avro_bytes_resolved` / `read_avro_file_resolved` apply full
# reader-schema resolution (writer != reader).
#
# Read path:
#   1. decode_ocf_header(bytes) → schema JSON + codec tag + sync marker.
#   2. AvroSchema.parse(schema_json) → flat-arena schema tree (rejects
#      recursive schemas via the name visit-stack).
#   3. ResolutionTable.identity(schema) → one FieldAction per record field +
#      the derived Arrow output Schema.
#   4. scan_ocf_blocks_after_header → block coordinates.
#   5. Per block: decompress_block (the header's codec) → ActionTableInterpreter
#      decodes each record directly into Arrow column builders (NO Value enum).
#   6. interpreter.build_batch() → one RecordBatch for the whole file.
#
# Encapsulation: the public entry `read_avro_bytes(bytes)` takes a borrowed
# `Span[UInt8]` and returns an owned RecordBatch. No UnsafePointer crosses any
# module boundary.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch

from .action_table import ActionTableInterpreter, ResolutionTable
from .avro_codec import decompress_block
from .avro_schema import AvroSchema
from .ocf_block_scan import scan_ocf_blocks_after_header
from .ocf_header import decode_ocf_header


def read_avro_bytes(bytes: Span[UInt8, _]) raises -> RecordBatch:
    """Read an entire Avro OCF byte stream into one RecordBatch.

    Identity resolution (reader schema = writer schema = OCF-header schema).
    Every codec `decompress_block` supports. Raises on recursive schema, unsupported
    codec, malformed wire data, or a CRC32 mismatch on a snappy block.
    """
    var header = decode_ocf_header(bytes)
    var schema = header.parse_schema()  # raises on recursive / malformed schema

    var table = ResolutionTable.identity(schema)
    var interp = ActionTableInterpreter(table^)

    var blocks = scan_ocf_blocks_after_header(bytes, header)
    for bi in range(len(blocks)):
        var blk = blocks[bi].copy()
        var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
        var decompressed = decompress_block(header.codec_tag, raw)
        interp.decode_block(Span(decompressed), Int(blk.object_count))

    return interp.build_batch()


def read_avro_file(path: String) raises -> RecordBatch:
    """Read an Avro OCF file from disk into one RecordBatch.

    File ingestion routes
    through the common `LocalFs.read_whole` facade (mmap-backed MmapAlignedBuffer)
    instead of `Path.read_bytes()` (own-heap slurp). The decoder is Span-poly;
    the mmap region's lifetime is bound by the MmapAlignedBuffer's Arc keepalive
    and torn down via `munmap(2)` when this function returns.
    """
    from komira_fs.local_fs import LocalFs
    from komira_async.ops.waker_sink import NoopSink

    var fs = LocalFs[NoopSink].new()
    var src_buf = fs.read_whole(path)
    # NOTE: borrowed-from-mmap MmapAlignedBuffer has capacity=0 (sentinel) and
    # length=file_size. `view_ro()` is defined as "view over capacity" so it
    # would return a 0-length view here; use `view_range_ro(0, length)` to
    # get the full file bytes.
    return read_avro_bytes(
        src_buf.view_range_ro(0, src_buf.len()).into_span()
    )


# =============================================================================
# Full reader-schema resolution (writer != reader).
# =============================================================================


def read_avro_bytes_resolved(
    bytes: Span[UInt8, _], reader_schema_json: String
) raises -> RecordBatch:
    """Read an Avro OCF byte stream applying full reader-schema resolution
    (Avro spec "Schema Resolution").

    The WRITER schema is parsed from the OCF header; the READER schema is
    `reader_schema_json` (the caller's expected view). The resolution-rewriter
    walks the (writer, reader) pair at OCF-open and emits a runtime
    ResolutionTable (action-list); the ActionTableInterpreter applies it per
    record. Resolution rules: aliases, defaults, int↔long↔float↔double type
    promotion, string↔bytes, field-skip, union resolution, enum resolution,
    record-field-reorder.

    Raises typed `AvroResolutionError.*` on an unrecoverable mismatch (a reader
    field absent from the writer with no default; an illegal type promotion; a
    fixed-size mismatch; an unresolvable enum symbol)."""
    var header = decode_ocf_header(bytes)
    var writer = header.parse_schema()  # raises on recursive / malformed schema
    var reader = AvroSchema.parse(reader_schema_json)

    var table = ResolutionTable.resolve(writer, reader)
    var interp = ActionTableInterpreter(table^)

    var blocks = scan_ocf_blocks_after_header(bytes, header)
    for bi in range(len(blocks)):
        var blk = blocks[bi].copy()
        var raw = bytes[blk.payload_offset : blk.payload_offset + blk.payload_len]
        var decompressed = decompress_block(header.codec_tag, raw)
        interp.decode_block(Span(decompressed), Int(blk.object_count))

    return interp.build_batch()


def read_avro_file_resolved(
    path: String, reader_schema_json: String
) raises -> RecordBatch:
    """Read an Avro OCF file from disk with full reader-schema resolution.

    File ingestion routes through the common `LocalFs.read_whole` facade
    (mmap-backed MmapAlignedBuffer) instead of `Path.read_bytes()` (own-heap
    slurp).
    """
    from komira_fs.local_fs import LocalFs
    from komira_async.ops.waker_sink import NoopSink

    var fs = LocalFs[NoopSink].new()
    var src_buf = fs.read_whole(path)
    # See `read_avro_file` note: borrowed-from-mmap MmapAlignedBuffer has
    # capacity=0 (sentinel) and length=file_size; use view_range_ro
    # to get the full file bytes.
    return read_avro_bytes_resolved(
        src_buf.view_range_ro(0, src_buf.len()).into_span(),
        reader_schema_json,
    )
