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
#   * the response body is capped at komira_crypto's RS256_MAX_JWKS_BYTES
#     (256 KiB) and the round trip at the configured timeout, because the
#     fetch runs on the serving thread.
#
# `ScriptedJwksFetcher` is the test double: a queue of canned replies (or
# transport failures), with every fetched URL recorded. Its handles share one
# script (`share()`), so a test keeps one after moving the fetcher into the
# verifier. A fetch with nothing scripted raises, loudly.
#
# No pointer in any signature. The connector factory is a `thin` code pointer
# (the same carve-out komira_http_client's TlsHttpTransport uses); the scripted
# fetcher's state is behind an `ArcPointer` (shared ownership, one thread).
# =============================================================================

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_crypto.rs256_jwks import RS256_MAX_JWKS_BYTES
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


struct HttpsJwksFetcher(JwksFetcher, Movable, Deinitable):
    """The production fetcher: HTTPS only, certificate-checked, no redirects,
    body capped at 256 KiB, bounded by a timeout."""

    # SAFETY: a `thin` code pointer to a connector factory. It holds a code
    # address only, no heap and no origin; called once per fetch with the URL
    # host.
    var _mk_connector: TlsConnectorFactory
    var _timeout_us: Int

    def __init__(out self):
        self._mk_connector = default_tls_factory
        self._timeout_us = DEFAULT_JWKS_FETCH_TIMEOUT_US

    def __init__(out self, mk_connector: TlsConnectorFactory, timeout_us: Int):
        self._mk_connector = mk_connector
        self._timeout_us = timeout_us

    def fetch(mut self, url: String) raises -> JwksFetchResult:
        # Refused before the factory is called, so nothing is dialed.
        validate_jwks_url(url)
        var parsed = Url.parse(url)
        var host = parsed.host_copy()
        var headers = HeaderMap()
        headers.append(String("Accept"), String("application/json"))
        var req = build_get_request(parsed^, headers^)
        var connector = self._mk_connector(host)
        var cfg = HttpClientConfig.defaults()
        cfg.max_response_body_bytes = RS256_MAX_JWKS_BYTES
        cfg.request_timeout_us = self._timeout_us
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

    def __init__(out self):
        self.replies = List[_ScriptedReply]()
        self.urls = List[String]()


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
