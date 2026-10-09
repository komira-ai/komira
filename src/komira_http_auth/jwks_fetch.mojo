# =============================================================================
# komira_http_auth/jwks_fetch.mojo: getting the issuer's JWK Set.
# =============================================================================
#
# `JwksFetcher` is the seam: one GET, returning the status, the
# `Cache-Control` header and the body bytes. komira_http_client's
# `HttpTransport` returns no response headers, so it cannot carry
# `Cache-Control`; this narrower seam does.
#
# `HttpsJwksFetcher` is the production conformer, over komira_http_client:
#   * the URL must be `https://` and is re-checked before any dial, so a
#     fetcher can never be pointed at plain HTTP whatever its caller did;
#   * the TLS connector comes from an injectable factory; the default is
#     `default_tls_factory` (peer verification against the TLS library's
#     default trust store, SNI = the host). That trust store is found
#     through the TLS library's default verify paths, which honour the
#     `SSL_CERT_FILE` and `SSL_CERT_DIR` environment variables: whoever sets
#     those for the process chooses which CAs may vouch for the JWKS host.
#     This is the one environment input on this path, and it is the TLS
#     library's, not a configuration flag of this package. That the default
#     constructor uses `default_tls_factory` is checked by review, not by a
#     test (a test cannot dial the public internet);
#   * redirects are not followed (a 3xx is a failed fetch);
#   * the response body is capped at komira_jwks' JWKS_MAX_DOCUMENT_BYTES
#     (256 KiB);
#   * the fetch timeout (`BearerJwtConfig.jwks_fetch_timeout_us`, which the
#     verifier hands over through `set_timeout_us`) bounds two phases: the
#     TLS handshake (`TlsConnector.set_handshake_deadline_us`, timed from the
#     end of the TCP connect) and the request (komira_http_client's
#     `request_timeout_us`, one wall-clock deadline armed at send-start).
#     Tests read both bounds through `connector_for` and `client_config`;
#     that fetch() dials through connector_for/client_config is checked by
#     review.
#
# WORST CASE, stated honestly. A fetch runs on the serving worker's
# event-loop thread and stalls that worker for its whole duration. It is the
# sum of: DNS resolution, which is UNBOUNDED (`getaddrinfo` takes no timeout
# and cannot be cancelled); the TCP connect, up to komira_http_core's fixed
# 5 s; the TLS handshake, up to the fetch timeout; and the request, up to the
# fetch timeout again. So a fetch takes the DNS time plus at most 5 s + 2 x
# the fetch timeout (15 s at the 5 s default), and with a hanging resolver it
# has no bound. The cache (jwks_cache.mojo) starts at most one fetch per
# refetch window, so a worker stalls this way at most once per window.
#
# `ScriptedJwksFetcher` is the test double: a queue of canned replies (or
# transport failures), with every fetched URL and the timeout it was given
# recorded. Its handles share one script (`share()`), so a test keeps one
# after moving the fetcher into the verifier. A fetch with nothing scripted
# raises, loudly.
#
# No pointer in any signature. The connector factory is a `thin` code pointer
# (the same carve-out komira_http_client's TlsHttpTransport uses); the scripted
# fetcher's state is behind an `ArcPointer` (shared ownership, one thread).
# =============================================================================

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_jwks import JWKS_MAX_DOCUMENT_BYTES
from komira_http_client.body import EmptyBody
from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_get_request,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.http_transport import (
    TlsConnectorFactory,
    default_tls_factory,
)
from komira_http_client.tls_connector import TlsConnector
from komira_http_client.url import Url
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_http_auth.config import (
    DEFAULT_JWKS_FETCH_TIMEOUT_US,
    validate_jwks_url,
)


@fieldwise_init
struct JwksFetchResult(Copyable, Movable, Deinitable):
    """One fetch: the HTTP status, the `Cache-Control` header if any, and the
    body bytes."""

    var status: Int
    var cache_control: Optional[String]
    var body: List[UInt8]


trait JwksFetcher(Movable, Deinitable):
    """GET a JWK Set. Raises only on a transport failure (DNS, TLS, timeout,
    an oversized body); an HTTP error status is returned."""

    def fetch(mut self, url: String) raises -> JwksFetchResult:
        ...

    def set_timeout_us(mut self, timeout_us: Int):
        """Set the fetch timeout in microseconds. `Rs256JwksVerifier` calls
        this with `BearerJwtConfig.jwks_fetch_timeout_us` when it is built, so
        the configuration is the one source of the value."""
        ...


struct HttpsJwksFetcher(JwksFetcher, Movable, Deinitable):
    """The production fetcher: HTTPS only, certificate-checked, no redirects,
    body capped at 256 KiB, the TLS handshake and the request each bounded by
    the fetch timeout (DNS and the TCP connect are not: module header)."""

    # SAFETY: a `thin` code pointer to a connector factory. It holds a code
    # address only, no heap and no origin; called once per fetch with the URL
    # host.
    var _mk_connector: TlsConnectorFactory
    var _timeout_us: Int

    def __init__(out self):
        """The public-CA connector factory and the default fetch timeout
        (the verifier replaces it with the configured one)."""
        self._mk_connector = default_tls_factory
        self._timeout_us = DEFAULT_JWKS_FETCH_TIMEOUT_US

    def __init__(out self, mk_connector: TlsConnectorFactory):
        """An explicit connector factory (tests), the default timeout."""
        self._mk_connector = mk_connector
        self._timeout_us = DEFAULT_JWKS_FETCH_TIMEOUT_US

    def set_timeout_us(mut self, timeout_us: Int):
        self._timeout_us = timeout_us

    def timeout_us(self) -> Int:
        """The fetch timeout in microseconds."""
        return self._timeout_us

    def client_config(self) -> HttpClientConfig:
        """The client settings `fetch` uses: the 256 KiB body cap and the
        request bound. A method so a test can read them without a network."""
        var cfg = HttpClientConfig.defaults()
        cfg.max_response_body_bytes = JWKS_MAX_DOCUMENT_BYTES
        cfg.request_timeout_us = self._timeout_us
        return cfg^

    def connector_for(
        self, host: String
    ) raises -> TlsConnector[KernelTcpConnector]:
        """The connector `fetch` dials `host` with: the factory's, with its
        TLS handshake bounded by the fetch timeout. A method so a test can read
        the deadline without a network."""
        var connector = self._mk_connector(host)
        connector.set_handshake_deadline_us(Int64(self._timeout_us))
        return connector^

    def fetch(mut self, url: String) raises -> JwksFetchResult:
        # Refused before the factory is called, so nothing is dialed.
        validate_jwks_url(url)
        var parsed = Url.parse(url)
        var host = parsed.host_copy()
        var headers = HeaderMap()
        headers.append(String("Accept"), String("application/json"))
        var req = build_get_request(parsed^, headers^)
        var connector = self.connector_for(host)
        var cfg = self.client_config()
        var client = HttpClient[TlsConnector[KernelTcpConnector]](
            config=cfg, connector=connector^
        )
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var cc = cr.headers.get(String("cache-control"))
        var body = cr.body.take_bytes()
        return JwksFetchResult(status=status, cache_control=cc, body=body^)


# -----------------------------------------------------------------------------
# The test double.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ScriptedReply(Copyable, Movable, Deinitable):
    var fail: Bool
    var status: Int
    var cache_control: Optional[String]
    var body: String


struct _ScriptState(Movable):
    var replies: List[_ScriptedReply]
    var urls: List[String]
    var timeout_us: Int

    def __init__(out self):
        self.replies = List[_ScriptedReply]()
        self.urls = List[String]()
        self.timeout_us = DEFAULT_JWKS_FETCH_TIMEOUT_US


struct ScriptedJwksFetcher(JwksFetcher, Movable, Deinitable):
    """A recording `JwksFetcher` for tests. Replies are consumed in order;
    `add` queues an HTTP reply and `add_failure` a transport failure. A fetch
    with an empty queue raises."""

    var _p: ArcPointer[_ScriptState]

    def __init__(out self):
        self._p = ArcPointer[_ScriptState](_ScriptState())

    def __init__(out self, *, var _share: ArcPointer[_ScriptState]):
        self._p = _share^

    def share(self) -> ScriptedJwksFetcher:
        """A second handle over the same script and recording."""
        return ScriptedJwksFetcher(_share=ArcPointer[_ScriptState](copy=self._p))

    def add(mut self, status: Int, body: String):
        """Queue a reply with no Cache-Control header."""
        self._p[].replies.append(
            _ScriptedReply(
                fail=False,
                status=status,
                cache_control=Optional[String](),
                body=body,
            )
        )

    def add(mut self, status: Int, cache_control: String, body: String):
        """Queue a reply carrying `Cache-Control: <cache_control>`."""
        self._p[].replies.append(
            _ScriptedReply(
                fail=False,
                status=status,
                cache_control=Optional[String](cache_control),
                body=body,
            )
        )

    def add_failure(mut self):
        """Queue a transport failure (the fetch raises)."""
        self._p[].replies.append(
            _ScriptedReply(
                fail=True,
                status=0,
                cache_control=Optional[String](),
                body=String(""),
            )
        )

    def set_timeout_us(mut self, timeout_us: Int):
        """Recorded only (`timeout_us`); a scripted fetch never waits."""
        self._p[].timeout_us = timeout_us

    def timeout_us(self) -> Int:
        """The last timeout set on any handle of this script."""
        return self._p[].timeout_us

    def fetch_count(self) -> Int:
        return len(self._p[].urls)

    def url_at(self, i: Int) -> String:
        return self._p[].urls[i].copy()

    def pending(self) -> Int:
        """Replies queued and not yet consumed."""
        return len(self._p[].replies)

    def fetch(mut self, url: String) raises -> JwksFetchResult:
        self._p[].urls.append(url)
        if len(self._p[].replies) == 0:
            raise Error(String("ScriptedJwksFetcher: no reply scripted"))
        var r = self._p[].replies.pop(0)
        if r.fail:
            raise Error(String("ScriptedJwksFetcher: scripted transport failure"))
        var body = List[UInt8]()
        body.extend(Span(r.body.as_bytes()))
        return JwksFetchResult(
            status=r.status, cache_control=r.cache_control, body=body^
        )
