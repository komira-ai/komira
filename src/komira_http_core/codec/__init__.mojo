# =============================================================================
# src/komira_http_core/codec/__init__.mojo — L2 HTTP/1.1 codec facade
# =============================================================================
#
# ships the type surface; adds the parser (`h1` submodule) +
# response serialization helpers. See codec/h1/__init__.mojo for the
# parser symbols.
# =============================================================================

from .types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_UNKNOWN,
    RESPONSE_FRAMING_CHUNKED,
    RESPONSE_FRAMING_CONTENT_LENGTH,
    HttpMethod,
    HttpRequest,
    HttpResponse,
    serialize_response,
    serialize_response_head,
    status_text,
)
from .response_framing import (
    response_may_be_chunked,
    serialize_response_framed,
)
from .h1 import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecodeResult,
    ChunkedDecoder,
    HeadersParseOutcome,
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CHUNK_MISSING_CRLF,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
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
    PARSE_ERR_HEADER_VALUE_NOT_UTF8,
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
    build_100_continue_bytes,
    build_error_response_bytes,
    decode_block,
    parse_request_head,
    sanitize_for_log,
)
