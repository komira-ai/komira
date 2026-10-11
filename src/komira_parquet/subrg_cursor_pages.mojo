# =============================================================================
# subrg_cursor_pages — the page-level helpers of `ResumableColumnCursor`
# =============================================================================
#
# The pieces of the sub-row-group cursor (`subrg_column_cursor`) that read one
# page, or walk page headers, without touching the cursor's resume state:
#
#   * `_decompress_page_into`: a page body into the cursor's reused scratch,
#     with the codec's tail slop reserved;
#   * `_decode_numeric_dict` / `_decode_string_dict`: a PLAIN dictionary page
#     into the cursor's dictionary lists (numeric entries widened to Int64 or
#     Float64; strings as N+1 offsets plus packed bytes, so a worker builds no
#     string array);
#   * `_admit_all_pages`: the whole-chunk header walk that refuses a chunk at
#     open when any data page is out of scope (see its docstring);
#   * `_zero_code_stream`: the RLE stream that stands in for a dictionary-index
#     page of bit width 0.
#
# Everything here is package-private and takes Spans and owned buffers; no
# pointer crosses a function boundary.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    PageType,
    ParquetType,
)
from komira_parquet_codec.compression import decompress

from .page_header_parser import _parse_page_header
from .plain import (
    decode_plain_float32,
    decode_plain_float64,
    decode_plain_int32,
    decode_plain_int64,
)

# Bytes reserved past a page's decoded size so the SNAPPY decoder's fast loop
# (which writes in wide blocks) stays enabled to the end of the page.
comptime _CODEC_SLOP: Int = 64


@always_inline
def _ptype_width(ptype: ParquetType) -> Int:
    """Element width in bytes of a fixed-width numeric physical type: 8 for
    INT64 and DOUBLE, 4 for INT32 and FLOAT."""
    if ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
        return 8
    return 4


@always_inline
def _ptype_is_float(ptype: ParquetType) -> Bool:
    """True for FLOAT and DOUBLE."""
    return ptype == ParquetType.FLOAT or ptype == ParquetType.DOUBLE


def _decompress_page_into(
    codec: CompressionCodec,
    body: Span[UInt8, _],
    uncompressed_size: Int,
    mut scratch: OwnedAlignedBuffer,
) raises:
    """Decompress (or copy, when UNCOMPRESSED) one page body into `scratch`
    and set its length to the decoded size. `scratch` grows, never shrinks.

    Raises:
        Error if the codec fails, or a compressed page declares a negative
        uncompressed size.
    """
    var comp_size = len(body)
    if codec != CompressionCodec.UNCOMPRESSED and uncompressed_size < 0:
        raise Error(
            "parquet: corrupt page header: negative uncompressed_page_size "
            + String(uncompressed_size)
        )
    var need = (
        uncompressed_size if codec != CompressionCodec.UNCOMPRESSED else comp_size
    )
    var cap = max(need + _CODEC_SLOP, 1)
    scratch.reserve(cap)
    if codec == CompressionCodec.UNCOMPRESSED:
        scratch.set_length(Int64(comp_size))
        if comp_size > 0:
            var dv = scratch.view_mut()
            # SAFETY: `scratch` was reserved for `cap >= comp_size` bytes and
            # its length set to `comp_size` above; `body` holds `comp_size`.
            unsafe_memcpy(
                dest=dv._unsafe_ptr(), src=body.unsafe_ptr(), count=comp_size
            )
        return
    var outspan = scratch.into_span_capacity()
    var written = decompress(codec, body, outspan[0:cap])
    scratch.set_length(Int64(written))


def _decode_numeric_dict(
    ptype: ParquetType,
    page: Span[UInt8, _],
    dict_nv: Int,
    mut ints: List[Int64],
    mut floats: List[Float64],
) raises:
    """Decode a PLAIN dictionary page of INT32 / INT64 (into `ints`, INT32
    sign-extended) or FLOAT / DOUBLE (into `floats`, FLOAT widened).

    Raises:
        Error if `dict_nv` entries do not fit in the decoded page: the count
        comes from the file, and the bound is checked, not assumed.
    """
    if dict_nv <= 0:
        return
    var width = _ptype_width(ptype)
    if dict_nv * width > len(page):
        raise Error(
            "parquet: corrupt dictionary page: num_values "
            + String(dict_nv)
            + " * width "
            + String(width)
            + " exceeds the "
            + String(len(page))
            + " decoded dictionary bytes"
        )
    if ptype == ParquetType.INT64:
        ints = List[Int64](capacity=dict_nv)
        var arr = decode_plain_int64(page, dict_nv)
        for e in range(dict_nv):
            ints.append(arr.get_typed[Scalar[DType.int64]](e))
    elif ptype == ParquetType.INT32:
        ints = List[Int64](capacity=dict_nv)
        var arr = decode_plain_int32(page, dict_nv)
        for e in range(dict_nv):
            ints.append(Int64(arr.get_typed[Scalar[DType.int32]](e)))
    elif ptype == ParquetType.DOUBLE:
        floats = List[Float64](capacity=dict_nv)
        var arr = decode_plain_float64(page, dict_nv)
        for e in range(dict_nv):
            floats.append(arr.get_typed[Scalar[DType.float64]](e))
    else:
        floats = List[Float64](capacity=dict_nv)
        var arr = decode_plain_float32(page, dict_nv)
        for e in range(dict_nv):
            floats.append(Float64(arr.get_typed[Scalar[DType.float32]](e)))


def _decode_string_dict(
    page: Span[UInt8, _],
    dict_nv: Int,
    mut offsets: List[Int32],
    mut data: List[UInt8],
) -> Bool:
    """Decode a PLAIN BYTE_ARRAY dictionary page (`[u32 LE length][bytes]`
    repeated) into N+1 cumulative `offsets` (from 0) and the packed entry
    bytes. Returns False, with both lists emptied, when an entry's length
    prefix or body runs past the page."""
    offsets = List[Int32](capacity=max(dict_nv, 0) + 1)
    data = List[UInt8]()
    offsets.append(Int32(0))
    var dlen = len(page)
    var pos = 0
    var total = 0
    for _ in range(max(dict_nv, 0)):
        if pos + 4 > dlen:
            offsets = List[Int32]()
            data = List[UInt8]()
            return False
        var slen = (
            Int(page[pos])
            | (Int(page[pos + 1]) << 8)
            | (Int(page[pos + 2]) << 16)
            | (Int(page[pos + 3]) << 24)
        )
        pos += 4
        if slen > dlen - pos or total + slen > Int(Int32.MAX):
            offsets = List[Int32]()
            data = List[UInt8]()
            return False
        data.extend(page[pos : pos + slen])
        pos += slen
        total += slen
        offsets.append(Int32(total))
    return True


def _admit_all_pages(
    chunk: Span[UInt8, _],
    start: Int,
    is_dict: Bool,
    flat_enc: Encoding,
    num_values: Int,
) -> Bool:
    """Walk every page header from `start` and say whether the cursor can
    decode every data page of the chunk. Header parses and size skips only;
    no body is read.

    `try_open` checks the first data page. This walk checks the rest, so a
    chunk the cursor cannot finish is refused before it emits a row rather
    than in the middle of a decode, after rows were handed on. The shape a
    valid file produces is a dictionary spill: a writer whose dictionary
    fills its byte budget keeps writing PLAIN data pages into the same chunk
    after RLE_DICTIONARY ones. A page is refused when:

      1. its header consumes no bytes (the walk would not advance);
      2. it is not a V1 DATA_PAGE (DATA_PAGE_V2, INDEX_PAGE, a second
         DICTIONARY_PAGE);
      3. its `compressed_page_size` is negative or runs past the chunk;
      4. the chunk is dictionary-encoded and the page is neither
         RLE_DICTIONARY nor PLAIN_DICTIONARY;
      5. the chunk is flat and the page's encoding differs from the first
         page's (`flat_enc`);
      6. the header does not parse;

    and the chunk is refused when (7) it declares rows but holds no data
    page. What a header cannot show, an OPTIONAL page's actual nulls, is
    still found by decoding the page body, mid-decode.
    """
    var data_len = len(chunk)
    var off = start
    var pages = 0
    while off < data_len:
        var body_off: Int
        var comp_size: Int
        try:
            var hdr = _parse_page_header(chunk[off:data_len])
            comp_size = hdr.header.compressed_page_size
            body_off = off + hdr.bytes_consumed
            if body_off <= off:
                return False
            if hdr.header.type != PageType.DATA_PAGE:
                return False
            if comp_size < 0 or comp_size > data_len - body_off:
                return False
            if is_dict:
                if (
                    hdr.header.encoding != Encoding.RLE_DICTIONARY
                    and hdr.header.encoding != Encoding.PLAIN_DICTIONARY
                ):
                    return False
            elif hdr.header.encoding != flat_enc:
                return False
        except:
            return False
        off = body_off + comp_size
        pages += 1
    if pages == 0 and num_values > 0:
        return False
    return True


def _zero_code_stream(page_nv: Int) -> List[UInt8]:
    """The RLE / Bit-Packing Hybrid stream, at bit width 1, of `page_nv`
    zeros: one RLE run header `(page_nv << 1) | 0` as a ULEB128, then the
    value byte 0. A dictionary-index page of bit width 0 means every code is
    0; decoding this stream keeps the cursor's resume logic unchanged."""
    var body = List[UInt8]()
    var v = page_nv << 1
    while True:
        var b = UInt8(v & 0x7F)
        v = v >> 7
        if v != 0:
            body.append(b | UInt8(0x80))
        else:
            body.append(b)
            break
    body.append(UInt8(0))
    return body^
