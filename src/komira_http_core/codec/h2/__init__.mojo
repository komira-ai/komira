# =============================================================================
# src/komira_http_core/codec/h2/__init__.mojo — L2 HTTP/2 codec submodule
# =============================================================================
#
#
#
# Curated re-exports for the RFC-9113 HTTP/2 codec surface. The parent
# `komira_http_core.codec.__init__` re-exports a focused subset of these so
# consumers can `from komira_http_core.codec import H2Frame, ...` without
# the sub-path.
#
# Spec: RFC 9113 (HTTP/2) + RFC 7541 (HPACK).
# Shared by the server and the client (the codec is
# direction-agnostic).
# =============================================================================

from .frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PADDED,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_PUSH_PROMISE,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    FRAME_DECODE_ERROR,
    FRAME_DECODE_NEED_MORE,
    FRAME_DECODE_OK,
    Frame,
    FrameDecodeResult,
    FrameHeader,
    H2_ERR_COMPRESSION_ERROR,
    H2_ERR_CONNECT_ERROR,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_HTTP_1_1_REQUIRED,
    H2_ERR_INADEQUATE_SECURITY,
    H2_ERR_INTERNAL_ERROR,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_REFUSED_STREAM,
    H2_ERR_SETTINGS_TIMEOUT,
    H2_ERR_STREAM_CLOSED,
    MAX_FRAME_PAYLOAD_DEFAULT,
    MAX_FRAME_PAYLOAD_HARD_CAP,
    SETTINGS_ENABLE_PUSH,
    SETTINGS_HEADER_TABLE_SIZE,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    SETTINGS_MAX_HEADER_LIST_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_goaway_frame,
    encode_headers_frame,
    encode_ping_frame,
    encode_rst_stream_frame,
    encode_settings_ack_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from .hpack import (
    HPACK_REPR_INDEXED,
    HPACK_REPR_LITERAL_INCREMENTAL,
    HPACK_REPR_LITERAL_NEVER,
    HPACK_REPR_LITERAL_NO_INDEX,
    HPACK_REPR_SIZE_UPDATE,
    HpackDecoder,
    HpackDynamicTable,
    HpackEncoder,
    HpackHeader,
    decode_integer,
    decode_string,
    encode_integer,
    encode_string,
    hpack_static_lookup,
)
from .stream import (
    H2_STREAM_ACTION_GOAWAY,
    H2_STREAM_ACTION_KEEP,
    H2_STREAM_ACTION_RST,
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_IDLE,
    STREAM_STATE_OPEN,
    STREAM_STATE_RESERVED_LOCAL,
    STREAM_STATE_RESERVED_REMOTE,
    StreamAction,
    StreamState,
)
from .flow_control import (
    FLOW_RESULT_FLOW_CONTROL_ERROR,
    FLOW_RESULT_GOAWAY,
    FLOW_RESULT_OK,
    FLOW_RESULT_RST_STREAM,
    FlowResult,
    RecvFlowController,
    SendFlowController,
)
from .connection_preface import (
    H2_CLIENT_PREFACE,
    H2_CLIENT_PREFACE_LEN,
    PREFACE_ERROR,
    PREFACE_NEED_MORE,
    PREFACE_OK,
    PrefaceCheckResult,
    check_client_preface,
)
from .alpn import (
    ALPN_PROTOCOL_H2,
    ALPN_PROTOCOL_HTTP11,
    is_h2_negotiated,
)
from .connection_state import (
    H2_CONN_FLAG_GOAWAY_SENT,
    H2_CONN_FLAG_PEER_SETTINGS_ACK,
    H2_CONN_FLAG_PREFACE_OK,
    H2_CONN_FLAG_SETTINGS_SENT,
    H2ConnectionState,
)
from .continuation_splitter import split_header_block_into_frames
from .response_validation import (
    H2_MALFORMED_BAD_CONTENT_LENGTH,
    H2_MALFORMED_BAD_FIELD_NAME,
    H2_MALFORMED_BAD_FIELD_VALUE,
    H2_MALFORMED_BAD_STATUS,
    H2_MALFORMED_BAD_TE,
    H2_MALFORMED_CONFLICTING_CONTENT_LENGTH,
    H2_MALFORMED_CONNECTION_SPECIFIC,
    H2_MALFORMED_CONTENT_LENGTH_MISMATCH,
    H2_MALFORMED_DATA_BEFORE_HEAD,
    H2_MALFORMED_DUPLICATE_PSEUDO,
    H2_MALFORMED_NO_STATUS,
    H2_MALFORMED_OK,
    H2_MALFORMED_PSEUDO_AFTER_REGULAR,
    H2_MALFORMED_PSEUDO_IN_TRAILER,
    H2_MALFORMED_TRAILER_NOT_END_STREAM,
    H2_MALFORMED_UNDEFINED_PSEUDO,
    H2BlockVerdict,
    h2_content_length_of,
    h2_field_name_is_valid,
    h2_field_value_is_valid,
    h2_is_connection_specific_field,
    h2_is_pseudo_name,
    h2_malformed_reason_text,
    h2_status_code_of,
    h2_status_has_no_content,
    h2_status_is_informational,
    h2_te_value_is_trailers,
    h2_validate_response_head,
    h2_validate_response_trailers,
)
