# =============================================================================
# src/komira_http_core/codec/h1/__init__.mojo — L2 HTTP/1.1 parser submodule
# =============================================================================
#
# Curated re-exports for the RFC-7230 parser surface. The parent
# `komira_http.codec.__init__` re-exports these so consumers can
# `from komira_http.codec import parse_request_head, ParseLimits` without
# typing the sub-path.
# =============================================================================

from .chunked import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecodeResult,
    ChunkedDecoder,
    decode_block,
)
from .chunked_encode import (
    CHUNKED_ENCODE_CHUNK_BYTES,
    append_chunk,
    append_chunk_size_line,
    append_chunked_body,
    append_last_chunk,
)
from .limits import (
    DEFAULT_MAX_BODY_BYTES,
    DEFAULT_MAX_HEADERS,
    DEFAULT_MAX_HEADER_BYTES,
    DEFAULT_MAX_REQUEST_LINE_BYTES,
    DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES,
    DEFAULT_MAX_TOTAL_HEADER_BYTES,
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CHUNK_EXT_TOO_LARGE,
    PARSE_ERR_CHUNK_MISSING_CRLF,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE,
    PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
    PARSE_ERR_CONTENT_LENGTH_CONFLICT,
    PARSE_ERR_CONTENT_LENGTH_INVALID,
    PARSE_ERR_EXPECT_UNSUPPORTED,
    PARSE_ERR_HEADER_COUNT_OVERFLOW,
    PARSE_ERR_HEADER_NAME_INVALID,
    PARSE_ERR_HEADER_NO_COLON,
    PARSE_ERR_HEADER_OBS_FOLD,
    PARSE_ERR_HEADER_SIZE_OVERFLOW,
    PARSE_ERR_HEADER_TOTAL_OVERFLOW,
    PARSE_ERR_HEADER_VALUE_CONTROL_CHAR,
    PARSE_ERR_HTTP_09_REJECTED,
    PARSE_ERR_HTTP_VERSION_BAD,
    PARSE_ERR_HTTP_VERSION_UNSUPPORTED,
    PARSE_ERR_METHOD_LOWERCASE,
    PARSE_ERR_METHOD_UNKNOWN,
    PARSE_ERR_NEED_MORE,
    PARSE_ERR_NONE,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
    PARSE_ERR_URI_TOO_LONG,
    PARSE_ERR_URI_WHITESPACE,
    ParseError,
    ParseLimits,
    sanitize_for_log,
)
from .parser import (
    HeadersParseOutcome,
    build_100_continue_bytes,
    build_error_response_bytes,
    parse_request_head,
)
