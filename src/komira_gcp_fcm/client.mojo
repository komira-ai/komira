# =============================================================================
# komira_gcp_fcm/client.mojo -- `FcmClient`: one wake to one registration
#   token through FCM HTTP v1 `messages:send`.
# =============================================================================
#
#   POST https://fcm.googleapis.com/v1/projects/<project>/messages:send
#   Authorization: Bearer <token from the GcpTokenSource>
#   Content-Type: application/json; charset=utf-8
#   <message.mojo's body>
#
# sent through komira_http_client's `HttpClient` over the connector the
# caller gives, and read by outcome.mojo. FCM v1 has no googleapis proto (it
# is described only by a discovery document), so there is no generated
# client to wrap; this is the one REST call, written here.
#
# ORDER. `send_one` checks its inputs and builds the body, then asks the
# token source, then sends. A token source that raises stops the send
# before anything is dialled, and the raise names only the HTTP status the
# token endpoint answered (`no access token (HTTP 403); nothing was sent`),
# or says there was none; the token source's own text is not passed on.
#
# A per-token failure does not raise: a refused, dead or throttled token, and
# a connection that failed or timed out (TRANSIENT, `http_status` 0), are
# outcomes, so a caller sending to many tokens goes on to the next. The
# detail of a send with no answer keeps only komira_http_client's
# `HttpError[<KIND>]` when the failure names one, else says `transport
# error`; the failure's own text (an address, an errno) is not kept. What
# raises is an input refused before sending, a token that could not be
# minted, and a request komira_http_client refuses as `HttpError[URL_INVALID]`
# (an https endpoint over a plaintext connector, an http one over a TLS
# connector): that is the client's configuration, the same for every token,
# so it is not a TRANSIENT outcome a caller would retry.
#
# THE ENDPOINT. `FcmEndpoint.public()` is https to fcm.googleapis.com:443.
# `FcmEndpoint.https(host, port)` is another TLS host (a proxy in front of
# FCM). `FcmEndpoint.loopback_plaintext(port)` is plain http to 127.0.0.1,
# for a fake FCM in a test: the bearer token is sent in clear, so the host is
# fixed to the loopback address and cannot be set (and `url` refuses a
# plaintext endpoint for any other host, however it was built). The connector type
# follows the scheme: komira_http_client refuses an https URL over a
# plaintext connector and an http URL over a TLS one.
#
# A 401 is REFUSED. `GcpTokenSource` has no way to drop a token the server
# stopped accepting; a caller holding a `CachingTokenSource` that sees
# `http_status == 401` calls `tokens().invalidate()`.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import (
    AdcFetcher,
    CachingTokenSource,
    GcpConnectorTransport,
    GcpTokenSource,
    EnvSource,
    FileSource,
    ProcessEnv,
    ProcessFiles,
    SystemWallClock,
    WallClock,
    application_default_token_source_from,
)
from komira_http_client.body import BytesBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_retry import MonotonicClock, SystemClock

from .message import FCM_HOST, FcmWake, fcm_adc_options, fcm_message_json, fcm_send_path
from .outcome import FCM_TRANSIENT, FcmOutcome, classify_fcm_response


comptime FCM_PORT: UInt16 = 443
comptime JSON_CONTENT_TYPE: String = "application/json; charset=utf-8"
comptime LOOPBACK_HOST: String = "127.0.0.1"
comptime URL_INVALID_KIND: String = "HttpError[URL_INVALID]"


def _check_host(host: String) raises:
    """A non-empty run of `[a-z0-9.-]`: the bearer token is sent to it, so a
    `/`, `@`, `:` or `#` must not be able to name another host."""
    var b = host.as_bytes()
    if len(b) == 0:
        raise Error("komira_gcp_fcm: the FCM host is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "komira_gcp_fcm: the FCM host holds a byte outside [a-z0-9.-]"
            )


struct FcmEndpoint(Copyable, Movable, Deinitable):
    """Where `messages:send` is sent (module header)."""

    var host: String
    var port: UInt16
    var tls: Bool

    def __init__(out self, var host: String, port: UInt16, tls: Bool):
        self.host = host^
        self.port = port
        self.tls = tls

    @staticmethod
    def public() -> FcmEndpoint:
        """https://fcm.googleapis.com:443."""
        return FcmEndpoint(String(FCM_HOST), FCM_PORT, True)

    @staticmethod
    def https(var host: String, port: UInt16) raises -> FcmEndpoint:
        """Another TLS host. Refused unless the host is a non-empty run of
        `[a-z0-9.-]` and the port is not 0."""
        _check_host(host)
        if port == 0:
            raise Error("komira_gcp_fcm: the FCM port is 0")
        return FcmEndpoint(host^, port, True)

    @staticmethod
    def loopback_plaintext(port: UInt16) raises -> FcmEndpoint:
        """Plain http to 127.0.0.1:`port` (a fake FCM in a test)."""
        if port == 0:
            raise Error("komira_gcp_fcm: the FCM port is 0")
        return FcmEndpoint(String(LOOPBACK_HOST), port, False)

    def url(self, var path: String) raises -> Url:
        """The request URL. A plaintext endpoint built by hand for any host
        but 127.0.0.1 is refused here, before a token is asked for."""
        if self.tls:
            return Url.https(self.host.copy(), self.port, path^)
        if self.host != String(LOOPBACK_HOST):
            raise Error(
                "komira_gcp_fcm: plain http is only for 127.0.0.1; the bearer"
                " token would cross the network in clear"
            )
        return Url.http(self.host.copy(), self.port, path^)


def _http_status_in(text: String) -> Int:
    """The number after the first `HTTP ` in `text`, -1 when there is none.
    komira_gcp_core's token errors say `<who> answered HTTP <status>`."""
    var at = text.find("HTTP ")
    if at < 0:
        return -1
    var b = text.as_bytes()
    var i = at + 5
    var n = 0
    var digits = 0
    while i < len(b) and digits < 3:
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            break
        n = n * 10 + Int(c - UInt8(ord("0")))
        digits += 1
        i += 1
    if digits != 3:
        return -1
    return n


def token_mint_error(source_error: String) -> Error:
    """The error `send_one` raises when the token source raised: the HTTP
    status in its text, and nothing else of it."""
    var status = _http_status_in(source_error)
    var what = String("no HTTP status")
    if status >= 0:
        what = String("HTTP ") + String(status)
    return Error(
        "komira_gcp_fcm: no access token (" + what + "); nothing was sent"
    )


def _transport_kind(text: String) -> String:
    """`HttpError[<KIND>]` from a komira_http_client failure, else
    `transport error`. Nothing else of the text is kept."""
    var at = text.find("HttpError[")
    if at < 0:
        return String("transport error")
    var end = text.find("]", at)
    if end < 0 or end - at > 64:
        return String("transport error")
    return String(text[byte = at : end + 1])


def send_failure_outcome(text: String) raises -> FcmOutcome:
    """What a send that got no answer means, from komira_http_client's
    error text: `HttpError[URL_INVALID]` raises (the endpoint's scheme and
    the connector disagree, so every send fails the same way); any other
    failure is TRANSIENT with `http_status` 0 and the detail
    `POST FirebaseMessaging.SendMessage: no answer, <kind>`, where `<kind>`
    is `HttpError[<KIND>]` or `transport error` (`_transport_kind`)."""
    var kind = _transport_kind(text)
    if kind == String(URL_INVALID_KIND):
        raise Error(
            "komira_gcp_fcm: komira_http_client refused the request"
            " URL (HttpError[URL_INVALID]: the endpoint's scheme and"
            " the connector disagree); nothing was sent"
        )
    return FcmOutcome(
        FCM_TRANSIENT,
        0,
        String(),
        String(),
        -1,
        String("POST FirebaseMessaging.SendMessage: no answer, ") + kind,
    )


struct FcmClient[C: Connector, T: GcpTokenSource](Movable, Deinitable):
    """`messages:send` for one project.

    - `C`: the connector `HttpClient` dials (a TLS one for `public()` and
      `https(...)`, a plaintext one for `loopback_plaintext`).
    - `T`: the bearer's source; `fcm_application_default_token_source` for
      Application Default Credentials with `FCM_SCOPE`.

    No token is stored on the client; each send asks `T`."""

    var _http: HttpClient[Self.C]
    var _rt: BlockingRuntime[NoopSink]
    var _tokens: Self.T
    var _project_id: String
    var _endpoint: FcmEndpoint

    def __init__(
        out self,
        var http: HttpClient[Self.C],
        var tokens: Self.T,
        var project_id: String,
        var endpoint: FcmEndpoint = FcmEndpoint.public(),
    ) raises:
        """Refused when the project id is not a project id
        (`check_project_id`)."""
        _ = fcm_send_path(project_id)
        self._http = http^
        self._rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        self._tokens = tokens^
        self._project_id = project_id^
        self._endpoint = endpoint^

    def tokens(mut self) -> ref [self._tokens] Self.T:
        """The bearer's source (a caller drops a rejected cached token through
        it)."""
        return self._tokens

    def endpoint(self) -> FcmEndpoint:
        return self._endpoint.copy()

    def send_one(mut self, device_token: String, wake: FcmWake) raises -> FcmOutcome:
        """Send `wake` to one registration token (module header for what
        raises and what is an outcome)."""
        var body = fcm_message_json(device_token, wake)
        var url = self._endpoint.url(fcm_send_path(self._project_id))
        var bearer: String
        try:
            bearer = self._tokens.access_token()
        except e:
            raise token_mint_error(String(e))
        if bearer.byte_length() == 0:
            raise Error(
                "komira_gcp_fcm: the token source returned an empty token;"
                " nothing was sent"
            )
        var headers = HeaderMap()
        headers.append(String("Content-Type"), String(JSON_CONTENT_TYPE))
        headers.append(String("Authorization"), String("Bearer ") + bearer)
        var req = build_request_with_body[BytesBody](
            HttpMethod.post(),
            url^,
            headers^,
            BytesBody.from_str(body),
        )
        ref reactor = self._rt.reactor()
        try:
            var resp = self._http.send_buffered[
                BlockingRuntime[NoopSink], BytesBody
            ](req^, reactor)
            var retry_after: Int64 = -1
            var ra = resp.headers.get_int64(String("Retry-After"))
            if ra:
                retry_after = ra.value()
            return classify_fcm_response(
                Int(resp.status), retry_after, resp.body.take_bytes()
            )
        except e:
            return send_failure_outcome(String(e))


def fcm_application_default_token_source_from[
    E: EnvSource,
    F: FileSource,
    P: Connector,
    T: Connector,
    W: WallClock,
    K: MonotonicClock,
](
    mut env: E,
    mut files: F,
    http_config: HttpClientConfig,
    mk_plain: def () raises thin -> P,
    mk_tls: def () raises thin -> T,
    var clock: W,
    var monotonic: K,
) raises -> CachingTokenSource[
    AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], W], K
]:
    """komira_gcp_core's `application_default_token_source_from` asking for
    `FCM_SCOPE` (`fcm_adc_options()`), over the env, file and clock seams
    the caller gives. `fcm_application_default_token_source` is this over
    the process's own; this is the one place the FCM token's options are
    chosen."""
    return application_default_token_source_from(
        env,
        files,
        http_config,
        mk_plain,
        mk_tls,
        clock^,
        monotonic^,
        fcm_adc_options(),
        False,
    )


def fcm_application_default_token_source[P: Connector, T: Connector](
    http_config: HttpClientConfig,
    mk_plain: def () raises thin -> P,
    mk_tls: def () raises thin -> T,
) raises -> CachingTokenSource[
    AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], SystemWallClock],
    SystemClock,
]:
    """`fcm_application_default_token_source_from` over the process
    environment and filesystem and the system clocks; its connectors as
    komira_gcp_core's `application_default_token_source` documents."""
    var env = ProcessEnv()
    var files = ProcessFiles()
    # Mojo builds no Windows target, so the search runs its non-Windows arm,
    # as komira_gcp_core's `application_default_token_source` does.
    return fcm_application_default_token_source_from(
        env,
        files,
        http_config,
        mk_plain,
        mk_tls,
        SystemWallClock(),
        SystemClock(),
    )
