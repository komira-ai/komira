# =============================================================================
# column_decoder_state — what the column decoder carries from page to page
# =============================================================================
#
# `decode_column_pages` (column_decoder) walks a column chunk's pages and
# builds one column at the end. `_ChunkAcc` is everything it carries between
# pages: the chunk's facts, the dictionary, and one accumulator per value
# form, each sized once for the chunk's declared value count on first use and
# appended at a running offset:
#
#   | accumulator          | holds                                          |
#   |----------------------|------------------------------------------------|
#   | dict_idx_buf         | dictionary codes (Int32), or the context's     |
#   |                      | reused codes buffer when use_recycled_codes    |
#   | plain_buf            | fixed-width values in Arrow layout: PLAIN,     |
#   |                      | DELTA_BINARY_PACKED, BYTE_STREAM_SPLIT, INT96  |
#   |                      | decoded to Int64 nanoseconds                   |
#   | bool_buf             | BOOLEAN values, bit-packed                     |
#   | string_pages         | dense string runs of a chunk that is not all   |
#   |                      | dictionary pages, in page order                |
#   | def_level_buf        | one validity bit per value of a nullable chunk |
#
# Every append is bounded by the chunk's value count: a data page may not
# declare more values than its chunk has left (checked in column_decoder
# before the page is read), so no running offset passes its buffer.
#
# It also holds the page CRC check and the page body decompression the
# decoder shares between page kinds.
# =============================================================================

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow.string_array import StringArray
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec import kSlopBytes
from komira_parquet_codec.compression import decompress
from komira_zlib import zlib_crc32

from .dictionary import DictionaryDecoder


struct _ChunkAcc(Movable):
    """A column chunk's decode state between pages; see the module header."""

    # The chunk's facts.
    var ptype: ParquetType
    var num_values: Int
    var nullable: Bool
    var type_length: Int
    var plain_elem_size: Int
    var is_decimal: Bool
    var flba_is_decimal: Bool
    var use_recycled_codes: Bool
    var total_decoded: Int

    # Dictionary pages and codes.
    var dict_decoder: DictionaryDecoder
    var has_dict: Bool
    var dict_idx_buf: Optional[OwnedAlignedBuffer]
    var dict_idx_count: Int

    # Fixed-width and BOOLEAN values.
    var plain_buf: Optional[OwnedAlignedBuffer]
    var plain_write_offset: Int
    var plain_elem_count: Int
    var bool_buf: Optional[OwnedAlignedBuffer]
    var bool_write_offset: Int

    # A BYTE_ARRAY chunk that is not all dictionary pages: its runs in order,
    # and how many of the codes are already in them.
    var string_pages: Slab[StringArray[HeapRegion]]
    var string_pages_mode: Bool
    var codes_flushed: Int

    # A numeric chunk whose dictionary pages are followed by PLAIN pages.
    var numeric_fallback: Bool

    # Validity of a nullable chunk.
    var def_level_buf: Optional[OwnedAlignedBuffer]
    var def_level_count: Int
    var all_pages_all_valid: Bool

    def __init__(
        out self,
        ptype: ParquetType,
        num_values: Int,
        nullable: Bool,
        type_length: Int,
        is_decimal: Bool,
        use_recycled_codes: Bool,
    ):
        self.ptype = ptype
        self.num_values = num_values
        self.nullable = nullable
        self.type_length = type_length
        self.plain_elem_size = _plain_elem_size(ptype, type_length)
        self.is_decimal = is_decimal
        self.flba_is_decimal = (
            is_decimal and ptype == ParquetType.FIXED_LEN_BYTE_ARRAY
        )
        self.use_recycled_codes = use_recycled_codes
        self.total_decoded = 0
        self.dict_decoder = DictionaryDecoder()
        self.has_dict = False
        self.dict_idx_buf = None
        self.dict_idx_count = 0
        self.plain_buf = None
        self.plain_write_offset = 0
        self.plain_elem_count = 0
        self.bool_buf = None
        self.bool_write_offset = 0
        self.string_pages = Slab[StringArray[HeapRegion]]()
        self.string_pages_mode = False
        self.codes_flushed = 0
        self.numeric_fallback = False
        self.def_level_buf = None
        self.def_level_count = 0
        self.all_pages_all_valid = True

    def has_nulls(self) -> Bool:
        """True when the chunk is nullable and some page had a null."""
        return (
            self.nullable
            and self.def_level_count > 0
            and not self.all_pages_all_valid
        )

    def ensure_plain_buf(mut self):
        """Allocate the fixed-width accumulator for the whole chunk, once."""
        if not self.plain_buf:
            self.plain_buf = OwnedAlignedBuffer(
                max(self.num_values * self.plain_elem_size, 1)
            )
            self.plain_write_offset = 0
            self.plain_elem_count = 0


def _plain_elem_size(ptype: ParquetType, type_length: Int) -> Int:
    """The width of one DECODED fixed-width value, 0 for BOOLEAN and
    BYTE_ARRAY. INT96 is 8: it decodes to Int64 nanoseconds, so its 12-byte
    source width is checked by its own decoder, not here."""
    if ptype == ParquetType.INT32 or ptype == ParquetType.FLOAT:
        return 4
    if (
        ptype == ParquetType.INT64
        or ptype == ParquetType.DOUBLE
        or ptype == ParquetType.INT96
    ):
        return 8
    if ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        return type_length
    return 0


def _check_page_crc(page: Span[UInt8, _], expected: UInt32) raises:
    """Refuse a page whose bytes do not match its header's CRC.

    The Parquet page checksum is the standard CRC-32 (the gzip and zlib
    polynomial) of the page bytes as stored, before decompression; the
    header carries it as an i32, kept here as its 32 bits.
    """
    var actual = zlib_crc32(page)
    if actual != expected:
        raise Error(
            "parquet: page CRC mismatch: the header says "
            + String(Int(expected))
            + ", the page's CRC-32 is "
            + String(Int(actual))
        )


def _page_into_scratch(
    codec: CompressionCodec,
    page: Span[UInt8, _],
    levels_len: Int,
    uncompressed_size: Int,
    mut scratch: OwnedAlignedBuffer,
) raises -> Int:
    """Put a page body into `scratch` decoded: its first `levels_len` bytes as
    stored (a DATA_PAGE_V2's level sections, never compressed), the rest
    decompressed with `codec` (or copied when UNCOMPRESSED). `scratch` grows
    and never shrinks; its length is set to the decoded size, which is
    returned.

    PERF-CRITICAL: the scratch is the context's, reused across every page,
    chunk and row group a worker decodes, so a page costs no allocation once
    the scratch has grown to the largest page. The capacity reserved past the
    decoded size (`kSlopBytes`) keeps the SNAPPY decoder's wide-copy loop on
    to the end of the page (without it the codec drops to its scalar loop);
    the length never covers it.

    Raises:
        Error if a compressed page declares a negative decoded size, or the
        codec fails.
    """
    var stored = len(page)
    if codec == CompressionCodec.UNCOMPRESSED:
        scratch.reserve(max(stored, 1))
        scratch.set_length(Int64(stored))
        if stored > 0:
            scratch.copy_from_span_at(0, page)
        return stored
    var values_size = uncompressed_size - levels_len
    if values_size < 0:
        raise Error(
            "parquet: corrupt page header: uncompressed_page_size "
            + String(uncompressed_size)
            + " is smaller than the page's "
            + String(levels_len)
            + " level bytes"
        )
    var cap = levels_len + values_size + kSlopBytes
    scratch.reserve(max(cap, 1))
    if levels_len > 0:
        scratch.copy_from_span_at(0, page[0:levels_len])
    var out = scratch.into_span_capacity()
    var written = 0
    if stored > levels_len:
        written = decompress(
            codec, page[levels_len:stored], out[levels_len:cap]
        )
    scratch.set_length(Int64(levels_len + written))
    return levels_len + written
