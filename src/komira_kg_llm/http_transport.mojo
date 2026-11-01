# =============================================================================
# http_transport -- the transports over komira's HTTP client.
# =============================================================================
#
# `HttpChatTransport` and `HttpEmbedTransport` post one JSON body per call to the
# endpoint they were built with and return the response body. Each call makes a
# fresh connector, runs one synchronous request on a runtime of its own and
# drops both, so a transport holds no connection and no reactor and can be
# called from any thread that owns it.
#
# What the caller supplies, none of it with a default:
#   * `WireEndpoint`: host, port, path, the time bound and the size bound;
#   * `mk_connector`: a code pointer that makes the connector for one call from
#     the time bound in milliseconds. A plaintext connector sends `http`; a TLS
#     connector sends `https`. A connector that carries a credential over
#     plaintext is for loopback tests only;
#   * an `AuthHeaderProvider` (`NoAuth` to send none).
#
# What is checked on the way back:
#   * a status outside 200 to 299 raises, quoting the status and the first bytes
#     of the body (never the request, which can carry a credential);
#   * a body that ends before its declared length raises (the HTTP client does
#     this);
#   * a body longer than `max_response_bytes` raises (the client's own cap, which
#     is given that number, stops it);
#   * a body that is not UTF-8 raises.
#
# There is no retry. A request that fails fails once.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_core.transport.io_stream import Connector

from .auth_header import AuthHeaderProvider, validate_auth_header
from .transport import ChatTransport, EmbedTransport
from .wire_endpoint import WireEndpoint

# How much of an error response body an error message quotes.
comptime HTTP_ERROR_QUOTE_BYTES: Int = 256


struct HttpChatTransport[C: Connector, A: AuthHeaderProvider](ChatTransport):
    """A `ChatTransport` that posts over HTTP to a chat-completions endpoint."""

    # SAFETY: a `thin` code pointer to the connector factory. It holds a code
    # address only, no heap and no origin.
    var _mk_connector: def (timeout_ms: Int) raises thin -> Self.C
    var _endpoint: WireEndpoint
    var _auth: Self.A

    def __init__(
        out self,
        mk_connector: def (timeout_ms: Int) raises thin -> Self.C,
        var endpoint: WireEndpoint,
        var auth: Self.A,
    ):
        """A transport for one endpoint.

        Args:
            mk_connector: Makes the connector for one call, from the endpoint's
                time bound in milliseconds.
            endpoint: Where to post and the bounds on the exchange.
            auth: Supplies the authorization header of each request.
        """
        self._mk_connector = mk_connector
        self._endpoint = endpoint^
        self._auth = auth^

    def client_config(self) -> HttpClientConfig:
        """The client settings a call is made with.

        Returns:
            The default settings with the request time bound and the response
            size bound of the endpoint.
        """
        return _client_config(self._endpoint)

    def complete(self, request_json: String) raises -> String:
        """Post `request_json` and return the response body.

        Args:
            request_json: The complete JSON request body.

        Returns:
            The response body.
        """
        return _post_json[Self.C, Self.A](
            self._mk_connector,
            self._endpoint,
            self._auth,
            request_json,
            "chat transport",
        )


struct HttpEmbedTransport[C: Connector, A: AuthHeaderProvider](EmbedTransport):
    """An `EmbedTransport` that posts over HTTP to an embeddings endpoint."""

    # SAFETY: a `thin` code pointer to the connector factory. It holds a code
    # address only, no heap and no origin.
    var _mk_connector: def (timeout_ms: Int) raises thin -> Self.C
    var _endpoint: WireEndpoint
    var _auth: Self.A

    def __init__(
        out self,
        mk_connector: def (timeout_ms: Int) raises thin -> Self.C,
        var endpoint: WireEndpoint,
        var auth: Self.A,
    ):
        """A transport for one endpoint.

        Args:
            mk_connector: Makes the connector for one call, from the endpoint's
                time bound in milliseconds.
            endpoint: Where to post and the bounds on the exchange.
            auth: Supplies the authorization header of each request.
        """
        self._mk_connector = mk_connector
        self._endpoint = endpoint^
        self._auth = auth^

    def client_config(self) -> HttpClientConfig:
        """The client settings a call is made with.

        Returns:
            The default settings with the request time bound and the response
            size bound of the endpoint.
        """
        return _client_config(self._endpoint)

    def complete(self, request_json: String) raises -> String:
        """Post `request_json` and return the response body.

        Args:
            request_json: The complete JSON request body.

        Returns:
            The response body.
        """
        return _post_json[Self.C, Self.A](
            self._mk_connector,
            self._endpoint,
            self._auth,
            request_json,
            "embed transport",
        )


def _client_config(endpoint: WireEndpoint) -> HttpClientConfig:
    var cfg = HttpClientConfig.defaults()
    cfg.request_timeout_us = endpoint.timeout_us()
    cfg.max_response_body_bytes = endpoint.max_response_bytes
    return cfg


def _post_json[
    C: Connector, A: AuthHeaderProvider
](
    mk_connector: def (timeout_ms: Int) raises thin -> C,
    endpoint: WireEndpoint,
    auth: A,
    request_json: String,
    who: String,
) raises -> String:
    """One POST of `request_json` to `endpoint`; the checked response body."""
    var headers = HeaderMap()
    headers.append(String("Accept"), String("application/json"))
    headers.append(String("Content-Type"), String("application/json"))
    var credential = auth.header()
    if credential:
        var h = credential.take()
        validate_auth_header(h)
        headers.append(h.name.copy(), h.value.copy())
    var body_bytes = List[UInt8](capacity=request_json.byte_length())
    body_bytes.extend(request_json.as_bytes())
    var connector = mk_connector(endpoint.timeout_ms)
    var url: Url
    if connector.is_tls():
        url = Url.https(endpoint.host, endpoint.port, endpoint.path)
    else:
        url = Url.http(endpoint.host, endpoint.port, endpoint.path)
    var req = build_request_with_body[BytesBody](
        HttpMethod(code=HTTP_METHOD_POST),
        url^,
        headers^,
        BytesBody.from_bytes(body_bytes^),
    )
    var client = HttpClient[C](
        config=_client_config(endpoint), connector=connector^
    )
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
        req^, reactor
    )
    var status = Int(cr.status)
    var resp = cr.body.take_bytes()
    if status < 200 or status > 299:
        var n = len(resp)
        if n > HTTP_ERROR_QUOTE_BYTES:
            n = HTTP_ERROR_QUOTE_BYTES
        raise Error(
            who
            + ": the server answered HTTP "
            + String(status)
            + ", body begins "
            + String(from_utf8_lossy=Span(resp)[0:n])
        )
    try:
        return String(from_utf8=Span(resp))
    except:
        raise Error(who + ": the response body is not UTF-8 text")
