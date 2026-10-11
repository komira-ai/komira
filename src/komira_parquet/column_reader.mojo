# =============================================================================
# column_reader — read one PLAIN fixed-width page straight from a file
# =============================================================================
#
# The shortest read path: given where a page's values sit in the file, read
# them (`ParquetFileReader.read_bytes`), decompress them, and alias the bytes
# as the Arrow array. It covers PLAIN, non-nullable INT32, INT64, FLOAT and
# DOUBLE values of one page, so the caller supplies the value byte range (past
# the page header) and the codec; the column decoder handles everything else.
#
# One copy per value at most: an UNCOMPRESSED page is the file read itself
# (zero-copy alias of the read buffer), and a compressed page is decompressed
# straight into the array's own buffer.
#
# `read_column_*` refuse any encoding but PLAIN; `read_column_*_direct` skip
# that argument. `read_raw_page_data` returns bytes as stored.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_fs.file_system import FileSystem
from komira_parquet_api.types import CompressionCodec, Encoding
from komira_parquet_codec.compression import decompress

from .file_reader import ParquetFileReader
from .plain import (
    decode_plain_float32_zero_copy,
    decode_plain_float64_zero_copy,
    decode_plain_int32_zero_copy,
    decode_plain_int64_zero_copy,
)


def read_column_int32[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    encoding: Encoding,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.int32]:
    """Read and decode a PLAIN INT32 page whose values start at file byte
    `offset` (`compressed_size` bytes as stored, `uncompressed_size` decoded).

    Raises:
        Error if `encoding` is not PLAIN, the read or the codec fails, or the
        decoded bytes hold fewer than `num_values` values.
    """
    _require_plain(encoding)
    return read_column_int32_direct(
        reader, offset, num_values, codec, compressed_size, uncompressed_size
    )


def read_column_int64[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    encoding: Encoding,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.int64]:
    """`read_column_int32` for INT64."""
    _require_plain(encoding)
    return read_column_int64_direct(
        reader, offset, num_values, codec, compressed_size, uncompressed_size
    )


def read_column_float32[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    encoding: Encoding,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.float32]:
    """`read_column_int32` for FLOAT."""
    _require_plain(encoding)
    return read_column_float32_direct(
        reader, offset, num_values, codec, compressed_size, uncompressed_size
    )


def read_column_float64[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    encoding: Encoding,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.float64]:
    """`read_column_int32` for DOUBLE."""
    _require_plain(encoding)
    return read_column_float64_direct(
        reader, offset, num_values, codec, compressed_size, uncompressed_size
    )


def read_column_int32_direct[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.int32]:
    """Read, decompress and alias a PLAIN INT32 page (no encoding check)."""
    return decode_plain_int32_zero_copy(
        _read_and_decompress(
            reader, offset, codec, compressed_size, uncompressed_size
        ),
        num_values,
    )


def read_column_int64_direct[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.int64]:
    """`read_column_int32_direct` for INT64."""
    return decode_plain_int64_zero_copy(
        _read_and_decompress(
            reader, offset, codec, compressed_size, uncompressed_size
        ),
        num_values,
    )


def read_column_float32_direct[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.float32]:
    """`read_column_int32_direct` for FLOAT."""
    return decode_plain_float32_zero_copy(
        _read_and_decompress(
            reader, offset, codec, compressed_size, uncompressed_size
        ),
        num_values,
    )


def read_column_float64_direct[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    num_values: Int,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> PrimitiveArray[DType.float64]:
    """`read_column_int32_direct` for DOUBLE."""
    return decode_plain_float64_zero_copy(
        _read_and_decompress(
            reader, offset, codec, compressed_size, uncompressed_size
        ),
        num_values,
    )


def read_raw_page_data[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    length: Int,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """`length` bytes at file byte `offset`, as stored (not decompressed)."""
    return reader.read_bytes(offset, length)


def _require_plain(encoding: Encoding) raises:
    if encoding != Encoding.PLAIN:
        raise Error(
            "column_reader: only PLAIN encoding supported, got "
            + String(encoding)
        )


def _read_and_decompress[FS: FileSystem](
    reader: ParquetFileReader[FS],
    offset: Int,
    codec: CompressionCodec,
    compressed_size: Int,
    uncompressed_size: Int,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """The page's decoded bytes: the file read itself when UNCOMPRESSED,
    else the read decompressed into a buffer of `uncompressed_size`."""
    if uncompressed_size < 0 or compressed_size < 0:
        raise Error(
            "column_reader: negative page size (compressed "
            + String(compressed_size)
            + ", uncompressed "
            + String(uncompressed_size)
            + ")"
        )
    if codec == CompressionCodec.UNCOMPRESSED:
        return reader.read_bytes(offset, uncompressed_size)
    var compressed = reader.read_bytes(offset, compressed_size)
    var obuf = OwnedAlignedBuffer(max(uncompressed_size, 1))
    var dst = obuf.into_span_capacity()
    var written = decompress(
        codec,
        compressed.view_ro().into_span(),
        dst[0:uncompressed_size],
    )
    obuf.set_length(Int64(written))
    return SharedAlignedBuffer.from_owned(obuf^)
