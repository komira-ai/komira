# =============================================================================
# Page CRC: the checksum field of a data page header
# =============================================================================
#
# parquet.thrift's `PageHeader.crc` is the standard CRC-32 (the gzip and zlib
# polynomial, `komira_zlib.zlib_crc32`) of the page's bytes as stored, after
# the header: the compressed body for a DataPage V1. It is NOT CRC-32C; a
# reader that checks the field (komira_parquet does, pyarrow does with
# page_checksum_verification) rejects a Castagnoli value.
#
# The page encoders build their headers without the field, so a writer that
# wants checksums rewrites the header: same sizes, same value count and
# encoding, plus `crc`. Only a chunk of one data page is rewritten. A
# dictionary chunk (a dictionary page, then a data page) is returned as it
# is, with no CRC on either page: the field is optional, and a reader checks
# it only when present.
# =============================================================================

from komira_zlib import zlib_crc32

from .column_page import ColumnPage, _append_bytes
from .thrift_writer import ThriftCompactWriter


def page_with_crc(var page: ColumnPage) raises -> ColumnPage:
    """`page` with its data page header carrying the CRC-32 of the stored
    body; a dictionary chunk comes back unchanged.

    Raises:
        Error: the page's bytes do not have the shape its sizes describe
            (header length is `len(data) - compressed_size`, and must be
            positive), or the new header's sizes overflow the i32 field.
    """
    if page.dict_page_size > 0:
        return page^
    var header_len = len(page.data) - page.compressed_size
    if header_len <= 0 or page.compressed_size < 0 or len(page.encodings) == 0:
        raise Error(
            "page_with_crc: column '"
            + page.column_name
            + "' has a "
            + String(len(page.data))
            + "-byte page with a "
            + String(page.compressed_size)
            + "-byte body"
        )
    var crc = zlib_crc32(Span(page.data)[header_len:])
    var w = ThriftCompactWriter()
    # The value encoding is the last the chunk lists (RLE for the definition
    # levels, when present, comes first).
    w.write_data_page_header(
        page.uncompressed_size,
        page.compressed_size,
        page.num_values,
        page.encodings[len(page.encodings) - 1],
        crc=Optional[UInt32](crc),
    )
    var header = w.take_bytes()
    var data = List[UInt8](capacity=len(header) + page.compressed_size)
    _append_bytes(data, header)
    data.extend(page.data[header_len:])
    page.data = data^
    return page^
