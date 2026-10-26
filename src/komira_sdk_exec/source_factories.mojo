# =============================================================================
# komira_sdk_exec/source_factories.mojo -- `file_source(path)`, the
#   extension-driven `SourceVariant` factory for file inputs.
# =============================================================================
#
# WHAT THIS IS. `file_source(path)` picks the `SourceVariant` arm for a file
# from the lower-cased extension of its path:
#   - `.parquet`, `.parquet.zst`, `.parquet.gz`, `.parquet.uncompressed`: reads
#     the Parquet footer once for the schema and returns a `SourceVariant` over
#     a `ParquetSource`. The extension is only a routing hint: the per-page
#     codec comes from the footer when the file is decoded.
#   - `.arrow`, `.arrows`, `.feather`: reads the file, checks the `ARROW1`
#     magic at both ends, decodes the footer's schema and returns the
#     `SourceVariant.from_arrow_uncompressed` arm over an `ArrowSource`.
#   - `.csv`: returns a `SourceVariant` over a `CsvSource` with an empty schema
#     (the schema is inferred when the scan is compiled).
#   - `.jsonl`, `.json`, `.ndjson` and their `.gz`, `.zst` and `.lz4` forms:
#     raises, naming the JSON read entry point. JSON needs a caller schema,
#     which a path alone does not carry.
#   - anything else: raises, listing the recognized extensions.
#
# No `UnsafePointer` appears in any signature.
# =============================================================================

from komira_arrow.schema import Schema
from komira_scan_source.arrow_source import ArrowSource
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.source_variant import SourceVariant

from komira_sdk.parquet_footer import read_parquet_footer


# =============================================================================
# Internal helper — extension cascade.
# =============================================================================


def _is_parquet_path(lower: String) -> Bool:
    """True if `lower` (a pre-lowered path) ends with any Parquet
    extension variant."""
    if lower.endswith(String(".parquet")):
        return True
    if lower.endswith(String(".parquet.zst")):
        return True
    if lower.endswith(String(".parquet.gz")):
        return True
    if lower.endswith(String(".parquet.uncompressed")):
        return True
    return False


def _is_arrow_ipc_path(lower: String) -> Bool:
    """True if `lower` ends with a recognized Arrow IPC file-format
    extension: `.arrow`, `.arrows` or `.feather`."""
    if lower.endswith(String(".arrow")):
        return True
    if lower.endswith(String(".arrows")):
        return True
    if lower.endswith(String(".feather")):
        return True
    return False


# =============================================================================
# file_source(path) — read-side auto-detect factory.
# =============================================================================


def file_source(var path: String) raises -> SourceVariant:
    """Auto-detect input format from file extension. Returns a
    `SourceVariant` tagged-union; caller passes to `ctx.read_source(...)`.

    Recognized extensions (case-insensitive):
      `.parquet*` (any codec variant) -> ParquetSource with footer-derived
          schema. The per-page codec comes from the footer when the file
          is decoded; the extension is documentary.
      `.arrow`, `.arrows`, `.feather` -> ArrowSource with the schema from
          the Arrow IPC File footer.
      `.csv` -> CsvSource with an empty schema.

    A JSON extension or an unrecognized extension raises with a message
    naming the alternative entry (e.g. `ctx.read_csv` /
    `ctx.read_json[T]`).

    Args:
        path: Input file path. Consumed.

    Returns:
        `SourceVariant` ready for `ctx.read_source(...)`.

    Raises:
        Error if the extension is not in the recognized set, or if the
        Parquet footer is malformed.
    """
    var lower = path.lower()
    if _is_parquet_path(lower):
        # Read the footer ONCE to derive the Arrow Schema (the metadata
        # pre-pass for the cost model + projection planning); the
        # ParquetSource constructor stores that schema and re-reads the
        # footer page-by-page at scan execution time. The per-codec
        # dispatch happens INSIDE the parquet decoder.
        var footer = read_parquet_footer(path)
        var schema = footer.take_schema()
        var src = ParquetSource(String(path), schema.copy())
        return SourceVariant(src^)
    elif _is_arrow_ipc_path(lower):
        # Arrow IPC path-mode source. Reads the full file bytes, validates
        # the ARROW1 magic, decodes the Footer's re-emitted Schema, and
        # wraps the path + Schema in an `ArrowSource` carried by the
        # `SourceVariant.from_arrow_uncompressed` arm. Only the schema is
        # discovered here; the RecordBatches are decoded later by a scan.
        var schema = _read_arrow_ipc_file_schema(path)
        var src = ArrowSource(String(path), schema^)
        return SourceVariant.from_arrow_uncompressed(src^)
    elif lower.endswith(String(".csv")):
        # The CSV arm goes through `CsvSource`. The schema is left empty
        # and is inferred when the scan is compiled.
        var schema = Schema()
        var src = CsvSource(String(path), schema^)
        return SourceVariant(src^)
    elif (
        lower.endswith(String(".jsonl"))
        or lower.endswith(String(".ndjson"))
        or lower.endswith(String(".json"))
        or lower.endswith(String(".jsonl.gz"))
        or lower.endswith(String(".ndjson.gz"))
        # The compressed-JSONL extensions get the same message as the
        # plain ones.
        or lower.endswith(String(".jsonl.zst"))
        or lower.endswith(String(".ndjson.zst"))
        or lower.endswith(String(".jsonl.lz4"))
        or lower.endswith(String(".ndjson.lz4"))
    ):
        raise Error(
            "file_source: JSON inputs are read via"
            " `ctx.read_json[T: JsonCompatible](path)` which returns"
            " `List[T]`; `file_source` does not read JSON."
        )
    else:
        raise Error(
            "file_source: unknown extension in path '"
            + path
            + "'. Recognized: .parquet, .parquet.zst, .parquet.gz,"
            + " .parquet.uncompressed, .arrow, .arrows, .feather."
            + " (CSV via ctx.read_csv, JSON via ctx.read_json[T].)"
        )


# =============================================================================
# _read_arrow_ipc_file_schema — open + decode an Arrow IPC File's Schema only.
# =============================================================================
#
# Used by `file_source(path)` to construct an `ArrowSource` carrying
# only the Schema (the cheap pre-scan metadata pass). Reads the full
# bytes — Arrow IPC files are typically small enough that
# slurp-then-decode is the simple shape here (Parquet files use a bounded
# footer-only seek; the Arrow IPC Footer position is at byte
# `n - 10 - footer_length` and `n` is known from the file size, so a seek to
# just the Footer + Schema would also work, but this reads the whole file).


def _read_arrow_ipc_file_schema(path: String) raises -> Schema:
    """Open an Arrow IPC file at `path`, validate the ARROW1 magic,
    decode the Footer, and return the re-emitted Schema.

    Used by `file_source(path)` for the `.arrow` / `.arrows` / `.feather`
    extension arm. Returns the Schema only — the RecordBatch decode
    happens later (at engine scan time via the SourceVariant arm, or
    immediately via `ctx.read_arrow(path)` for the eager path).
    """
    from komira_fs.handle import FileHandleReader
    from komira_arrow_ipc.ipc_encoder_dispatch import (
        ARROW1_HEADER_LEN,
        ARROW1_MAGIC_LEN,
    )
    from komira_arrow_ipc.ipc_flatbuf import (
        flatbuf_reader_over,
        read_footer,
        read_schema,
    )
    from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
    from komira_buffer.heap_region import HeapRegion
    from komira_op_sources.ipc_stream_frames import (
        _ipc_schema_desc_to_komira_schema,
    )

    var fr = FileHandleReader.from_path(path)
    var bytes = fr.read_all()
    fr.close()
    _ = fr^

    var n = len(bytes)
    if n < ARROW1_HEADER_LEN + 4 + ARROW1_MAGIC_LEN:
        raise Error(
            "_read_arrow_ipc_file_schema: file '" + path + "' too short ("
            + String(n) + " bytes); not a valid Arrow IPC File"
        )

    # Validate ARROW1\0\0 head + ARROW1 trailer magic.
    if (
        bytes[0] != UInt8(0x41) or bytes[1] != UInt8(0x52)
        or bytes[2] != UInt8(0x52) or bytes[3] != UInt8(0x4F)
        or bytes[4] != UInt8(0x57) or bytes[5] != UInt8(0x31)
        or bytes[6] != UInt8(0x00) or bytes[7] != UInt8(0x00)
    ):
        raise Error(
            "_read_arrow_ipc_file_schema: file '" + path
            + "' missing ARROW1\\0\\0 magic header (not a File-format"
            + " Arrow IPC file; Stream-format input has no header and"
            + " is not routed through file_source — use ctx.read_arrow"
            + " for Stream-format)"
        )
    if (
        bytes[n - 6] != UInt8(0x41) or bytes[n - 5] != UInt8(0x52)
        or bytes[n - 4] != UInt8(0x52) or bytes[n - 3] != UInt8(0x4F)
        or bytes[n - 2] != UInt8(0x57) or bytes[n - 1] != UInt8(0x31)
    ):
        raise Error(
            "_read_arrow_ipc_file_schema: file '" + path
            + "' missing ARROW1 trailer magic (truncated?)"
        )

    # i32 footer_length at byte n-10.
    var b0 = Int(bytes[n - 10]) & 0xFF
    var b1 = Int(bytes[n - 9]) & 0xFF
    var b2 = Int(bytes[n - 8]) & 0xFF
    var b3 = Int(bytes[n - 7]) & 0xFF
    var footer_len = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    if footer_len <= 0 or n - 10 - footer_len < 8:
        raise Error(
            "_read_arrow_ipc_file_schema: file '" + path
            + "' invalid footer_length " + String(footer_len)
        )

    var footer_start = n - 10 - footer_len
    var footer_fb = SharedAlignedBuffer[HeapRegion].heap_owned(footer_len)
    for i in range(footer_len):
        footer_fb.write_u8_at(i, bytes[footer_start + i])
    footer_fb.set_length(footer_len)

    var fr_fb = flatbuf_reader_over(footer_fb)
    var footer = read_footer(fr_fb, fr_fb.read_root_offset())
    var schema_desc = read_schema(fr_fb, footer.schema_table_pos)
    return _ipc_schema_desc_to_komira_schema(schema_desc, footer_fb)
