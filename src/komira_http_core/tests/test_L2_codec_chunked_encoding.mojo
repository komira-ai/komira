# =============================================================================
# tests/test_L2_codec_chunked_encoding.mojo
# =============================================================================
#
# chunked transfer-encoding decoder
# unit tests.
#
# RFC 7230 §4.1 cases:
#   * Happy path: 2 chunks + last-chunk + empty trailer
#   * Single zero-chunk → empty body
#   * Large single chunk
#   * Chunk-extension (after ';') ignored
#   * Trailer with one header — discarded; decoder completes
#   * Malformed chunk-size (non-hex) → error
#   * Missing CRLF after chunk-data → error
#   * Trailer line without colon → error
#   * Body-size cap honored (max_body_bytes) → 413
#   * Incremental: split a chunk across two decode_block calls
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecoder,
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CHUNK_MISSING_CRLF,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
    ParseLimits,
    decode_block,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def test_chunked_two_chunks_happy() raises:
    """Classic 2-chunk body: '5\\r\\nhello\\r\\n6\\r\\n world\\r\\n0\\r\\n\\r\\n'."""
    var buf = _bytes(String(
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    # 'hello' + ' world' = 11 bytes.
    assert_equal(len(body), 11)
    var s = String()
    var i = 0
    while i < len(body):
        s = s + chr(Int(body[i]))
        i = i + 1
    assert_equal(s, String("hello world"))


def test_chunked_zero_only_empty_body() raises:
    """Last-chunk only ('0\\r\\n\\r\\n') → DONE; body empty."""
    var buf = _bytes(String("0\r\n\r\n"))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 0)


def test_chunked_uppercase_hex_size() raises:
    """Uppercase hex chunk size accepted (RFC 7230 §4.1 1*HEXDIG)."""
    var buf = _bytes(String("A\r\n0123456789\r\n0\r\n\r\n"))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 10)


def test_chunked_extension_ignored() raises:
    """Chunk-size with ';ext=val' extension parsed and ignored."""
    var buf = _bytes(String(
        "5;name=value\r\nhello\r\n0\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 5)


def test_chunked_with_trailer_discarded() raises:
    """One trailer line (header-shaped) accepted and discarded."""
    var buf = _bytes(String(
        "5\r\nhello\r\n0\r\nX-Trailer: foo\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 5)


def test_chunked_size_invalid() raises:
    """Non-hex chunk-size → ERROR / PARSE_ERR_CHUNK_SIZE_INVALID."""
    var buf = _bytes(String("X\r\nfoo\r\n0\r\n\r\n"))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(Int(dec.err.kind), Int(PARSE_ERR_CHUNK_SIZE_INVALID))


def test_chunked_missing_crlf_after_data() raises:
    """Missing CRLF after chunk data → ERROR."""
    var buf = _bytes(String("5\r\nhelloXX0\r\n\r\n"))  # XX should be CRLF
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(Int(dec.err.kind), Int(PARSE_ERR_CHUNK_MISSING_CRLF))


def test_chunked_trailer_no_colon_rejected() raises:
    """Non-empty trailer line missing ':' → ERROR."""
    var buf = _bytes(String("0\r\nNoColon\r\n\r\n"))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, ParseLimits.defaults(), body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(
        Int(dec.err.kind), Int(PARSE_ERR_CHUNK_TRAILER_INVALID),
    )


def test_chunked_body_exceeds_max_413() raises:
    """A chunk-size exceeding limits.max_body_bytes → 413."""
    var limits = ParseLimits.defaults()
    limits.max_body_bytes = 5
    var buf = _bytes(String(
        "20\r\nabcdefghijklmnopqrstuvwxyz123456\r\n0\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, span, limits, body)
    assert_equal(Int(res.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(Int(dec.err.kind), Int(PARSE_ERR_BODY_TOO_LARGE))


def test_chunked_incremental_split_at_chunk_size_line() raises:
    """First call has only partial chunk-size line; resume after more bytes."""
    var part1 = _bytes(String("5"))  # partial chunk-size line
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res1 = decode_block(
        dec, Span[UInt8](part1), ParseLimits.defaults(), body,
    )
    assert_equal(Int(res1.outcome), Int(CHUNKED_RES_NEED_MORE))
    # Now feed the rest.
    var part2 = _bytes(String("5\r\nhello\r\n0\r\n\r\n"))
    var res2 = decode_block(
        dec, Span[UInt8](part2), ParseLimits.defaults(), body,
    )
    assert_equal(Int(res2.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 5)


def test_chunked_incremental_split_mid_chunk_data() raises:
    """Split between chunk-size line and chunk-data."""
    var part1 = _bytes(String("5\r\nhe"))
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res1 = decode_block(
        dec, Span[UInt8](part1), ParseLimits.defaults(), body,
    )
    assert_equal(Int(res1.outcome), Int(CHUNKED_RES_NEED_MORE))
    # Body now contains 'he'.
    assert_equal(len(body), 2)
    # Now feed the rest.
    var part2 = _bytes(String("llo\r\n0\r\n\r\n"))
    var res2 = decode_block(
        dec, Span[UInt8](part2), ParseLimits.defaults(), body,
    )
    assert_equal(Int(res2.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(len(body), 5)


def main() raises:
    test_chunked_two_chunks_happy()
    test_chunked_zero_only_empty_body()
    test_chunked_uppercase_hex_size()
    test_chunked_extension_ignored()
    test_chunked_with_trailer_discarded()
    test_chunked_size_invalid()
    test_chunked_missing_crlf_after_data()
    test_chunked_trailer_no_colon_rejected()
    test_chunked_body_exceeds_max_413()
    test_chunked_incremental_split_at_chunk_size_line()
    test_chunked_incremental_split_mid_chunk_data()
    print("PASS L2 codec chunked encoding tests")
