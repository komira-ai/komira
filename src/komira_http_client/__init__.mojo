# =============================================================================
# src/komira_http_client/__init__.mojo — HTTP client module facade
# =============================================================================
#
# The client module surface — typed
# foundational types:
#   * HeaderMap   — case-insensitive multi-value header map
#   * Url         — parsed URL
#   * HttpError   — typed client error
#   * RequestBody trait + EmptyBody + BytesBody (WRITE-direction)
#   * ResponseBody trait + BufferedResponseBody (READ-direction)
#   * BodyFrame enum
#
# The WRITE-direction body trait is `RequestBody`. The READ-direction
# `ResponseBody` trait (FRAME-shaped `poll_frame -> BodyFrame`) lives in
# `response_body.mojo`.
#
# Higher-level surfaces: HttpClient, request_writer, response_parser,
# state_machine, Service/Layer.
#
# Connectors: TlsConnector, and SchemeConnector (plaintext or TLS, fixed
# when it is made) with its production form KernelSchemeConnector.
# =============================================================================

from .auth import (
    AuthProvider,
    BearerTokenProvider,
    BearerTokenSource,
    StaticTokenSource,
)
from .body import BytesBody, EmptyBody, RequestBody, StreamingBody
from .body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BODY_FRAME_KIND_ERROR,
    BODY_FRAME_KIND_PENDING,
    BODY_FRAME_KIND_TRAILERS,
    BodyFrame,
    body_frame_kind_name,
)
from .response_body import (
    BufferedResponseBody,
    RecvRingBody,
    ResponseBody,
    collect_body,
)
from .owned_byte_body import OwnedByteBody
from .clock import (
    Clock,
    DeterministicRng,
    MockClock,
    Rng,
    SystemClock,
    SystemRng,
)
from .pool import (
    ALPN_H1,
    ALPN_H2,
    ALPN_UNKNOWN,
    PoolKey,
    PoolSizingKnobs,
    SCHEME_HTTP,
    SCHEME_HTTPS,
    VERIFY_PEER,
    VERIFY_SKIP,
)
from .session_cache import (
    DEFAULT_MAX_SESSION_CACHE_ENTRIES,
    SessionCache,
)
from .tls_connector import TlsClientStream, TlsConnector
from .scheme_connector import (
    KernelSchemeConnector,
    SchemeConnector,
    SchemeStream,
    kernel_plain_scheme_connector,
    kernel_tls_scheme_connector,
)
from .error import (
    HTTP_ERROR_BODY_TOO_LARGE,
    HTTP_ERROR_CANCELLED,
    HTTP_ERROR_CONNECT_FAILED,
    HTTP_ERROR_CONNECT_TIMEOUT,
    HTTP_ERROR_EOF_MID_RESPONSE,
    HTTP_ERROR_H2_PROTOCOL,
    HTTP_ERROR_HEADER_INVALID,
    HTTP_ERROR_HEADERS_TOO_LARGE,
    HTTP_ERROR_IO_ERROR,
    HTTP_ERROR_NONE,
    HTTP_ERROR_PROTOCOL_STATUS,
    HTTP_ERROR_RESPONSE_FRAMING,
    HTTP_ERROR_RETRYABLE_TRANSPORT,
    HTTP_ERROR_STATUS_LINE_INVALID,
    HTTP_ERROR_TIMEOUT,
    HTTP_ERROR_TLS_HANDSHAKE_FAILED,
    HTTP_ERROR_TLS_VERIFY_FAILED,
    HTTP_ERROR_URL_INVALID,
    HttpError,
)
from .header_map import HeaderEntry, HeaderMap
from .request_writer import (
    drain_body_into,
    method_delete,
    method_get,
    method_head,
    method_options,
    method_patch,
    method_post,
    method_put,
    serialize_request_head,
)
from .response_parser import (
    ResponseHead,
    ResponseParseLimits,
    parse_response_head,
)
# ⛔ THE OUTBOUND-BUDGET RULE — "a budget may not exceed the deadline of the
# context it runs inside". Re-exported so a caller ALREADY in a `raises` context
# can compose the refusal in one line
# (`if outbound_budget_exceeds_ceiling(...): raise Error(...detail...)`) without
# reaching past the package facade for it.
from .outbound_budget import (
    CLOUD_RUN_REQUEST_CEILING_US,
    OUTBOUND_BUDGET_DEFAULT_US,
    OUTBOUND_CEILING_NONE,
    OUTBOUND_CEILING_RESERVE_US,
    largest_permissible_budget_us,
    outbound_budget_exceeds_ceiling,
    outbound_budget_refusal_detail,
    outbound_budget_us,
    serving_request_ceiling_us,
)
from .client import (
    HttpClient,
    HttpClientConfig,
    build_get_request,
    build_head_request,
    build_delete_request,
    build_request_with_body,
    build_streaming_request,
)
from .h2_client import (
    H2C_FLAG_GOAWAY_RECEIVED,
    H2C_FLAG_PREFACE_SENT,
    H2C_FLAG_SERVER_SETTINGS_SEEN,
    H2C_FLAG_SETTINGS_SENT,
    H2_GOAWAY_MAYBE_PROCESSED_TOKEN,
    H2_GOAWAY_UNPROCESSED_TOKEN,
    H2ClientConnectionState,
    H2ClientStream,
    H2_MALFORMED_SCOPE_HEAD,
    H2_MALFORMED_SCOPE_NONE,
    H2_MALFORMED_SCOPE_TRAILER,
    apply_peer_settings_and_ack,
    build_initial_client_settings,
    drive_h2_streams_to_completion,
    emit_goaway_for_client,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    extract_trailers_for_stream,
    h2_drive_wall_us,
    has_pending_request_bodies,
    is_h2_goaway_unprocessed,
    is_h2_retryable_transport,
    process_received_frames,
    pump_pending_request_bodies,
    queue_client_preface_and_settings,
    stage_request_body,
)
from .h2_pool import (
    H2_CHECKOUT_AT_CAPACITY,
    H2_CHECKOUT_FOUND,
    H2_CHECKOUT_NEEDS_DIAL,
    H2_OUTCOME_FOUND,
    H2_OUTCOME_NEEDS_DIAL,
    H2_OUTCOME_PENDING,
    H2CheckoutOrPending,
    H2CheckoutResult,
    H2ClientPool,
    H2PendingCheckout,
    H2PooledConn,
)
from .objectstore_http import (
    ByteRange,
    HttpClientObjectStoreHttp,
    ObjectMetadata,
    ObjectStoreHttp,
    RangeFanoutResult,
    ScriptedObjectStoreHttp,
)
from .redirect import RedirectLayer
from .timeout import TimeoutLayer
from .retry import (
    BackoffCurve,
    RetryLayer,
    RetryPolicy,
    is_idempotent_method,
)
from .service import (
    ClientRequest,
    HttpLayer,
    HttpService,
    NoopLayer,
)
from .state_machine import (
    ClientResponse,
    OUTBOUND_STATE_DONE,
    OUTBOUND_STATE_ERROR,
    OUTBOUND_STATE_IDLE,
    OUTBOUND_STATE_READING_RESPONSE_BODY,
    OUTBOUND_STATE_READING_RESPONSE_HEAD,
    OUTBOUND_STATE_WRITING_REQUEST_HEADERS,
    OutboundDriver,
    state_name,
)
from .url import Url
