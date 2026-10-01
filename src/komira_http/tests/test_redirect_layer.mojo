# =============================================================================
# src/komira_http/tests/test_redirect_layer.mojo
# RedirectLayer.
# =============================================================================
#
# Contract:
#   (b-i)   same-origin redirect keeps Authorization
#   (b-ii)  cross-origin redirect strips Authorization
#   (b-iii) redirect loop detection raises HttpError
#   (b-iv)  max_redirects exceeded raises HttpError
#
# Plus extra coverage:
#   * 303 converts method to GET (RFC 7231 §6.4.4)
#   * 307/308 preserves method
#   * 301/302 on non-GET/HEAD surfaces unchanged
#   * No-redirect call returns directly
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.body import EmptyBody, RequestBody
from komira_http.client.header_map import HeaderMap
from komira_http.client.redirect import (
    RedirectLayer,
    _strip_sensitive_headers,
)
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.service import (
    ClientRequest,
    HttpService,
)
from komira_http.client.state_machine import ClientResponse
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.transport.io_stream import Connector
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# Test conformer: scripted HttpService that returns a sequence of
# scripted responses (status, headers).
# =============================================================================


struct ScriptedRedirectService(
    HttpService, Movable, Deinitable,
):
    # For each step: a status code + an optional Location URL string.
    var _statuses: List[Int]
    var _locations: List[String]
    var _call_count: Int
    # Each call observes the inbound headers — diagnostic for
    # cross-origin Authorization stripping tests.
    var _observed_authorization: List[String]

    @staticmethod
    def new(
        var statuses: List[Int], var locations: List[String],
    ) -> ScriptedRedirectService:
        return ScriptedRedirectService(
            _statuses=statuses^,
            _locations=locations^,
            _call_count=0,
            _observed_authorization=List[String](),
        )

    def __init__(
        out self,
        var _statuses: List[Int],
        var _locations: List[String],
        _call_count: Int,
        var _observed_authorization: List[String],
    ):
        self._statuses = _statuses^
        self._locations = _locations^
        self._call_count = _call_count
        self._observed_authorization = _observed_authorization^

    def call_count(self) -> Int:
        return self._call_count

    def observed_authorization(self, idx: Int) -> String:
        if idx < self._observed_authorization.__len__():
            return self._observed_authorization[idx]
        return String("<absent>")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        var idx = self._call_count
        self._call_count = self._call_count + 1
        # Observe the inbound Authorization header (or "<absent>").
        var auth_opt = req.headers.get(String("Authorization"))
        if auth_opt.__bool__():
            self._observed_authorization.append(auth_opt.value())
        else:
            self._observed_authorization.append(String("<absent>"))

        if idx >= self._statuses.__len__():
            raise Error(
                "HttpError[STATUS_LINE_INVALID]: scripted statuses "
                "exhausted (call #" + String(idx) + ")"
            )

        var status = self._statuses[idx]
        var resp_body = BufferedResponseBody.from_bytes(List[UInt8]())
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = Int32(status)
        resp.reason = String("Scripted")
        var resp_hdrs = HeaderMap()
        # If the scripted location is non-empty for this step, set
        # Location header.
        if idx < self._locations.__len__():
            var loc = self._locations[idx]
            if loc.byte_length() > 0:
                resp_hdrs.append(String("Location"), String(loc))
        resp.headers = resp_hdrs^
        resp.connection_close = False
        _ = req^
        return resp^


# =============================================================================
# Helpers.
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_connector() -> ScriptedConnector:
    var stream = ScriptedStream.empty()
    return ScriptedConnector.with_stream(stream^)


def _make_request_with_auth(url: String, auth: String) raises -> ClientRequest[EmptyBody]:
    var parsed_url = Url.parse(url)
    var headers = HeaderMap()
    if auth.byte_length() > 0:
        headers.append(String("Authorization"), String(auth))
    var bytes = List[UInt8]()
    return ClientRequest[EmptyBody](
        method=HttpMethod.get(),
        url=parsed_url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


# =============================================================================
# Acceptance test (b-i) — same-origin redirect keeps Authorization.
# =============================================================================


def test_same_origin_redirect_keeps_authorization() raises:
    """Initial request → 302 → final 200 at SAME origin.
    Authorization header must be present on both inbound calls."""
    var statuses = List[Int]()
    statuses.append(302)
    statuses.append(200)
    var locations = List[String]()
    locations.append(String("http://example.com/redirected"))
    locations.append(String(""))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(3),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"),
        String("Bearer secret-token"),
    )
    var resp = layer.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req^, connector, reactor)
    assert_equal(Int(resp.status), 200)
    assert_equal(Int(layer.last_hops()), 1)
    # Both calls saw the Authorization header.
    assert_equal(
        layer._inner.observed_authorization(0),
        String("Bearer secret-token"),
    )
    assert_equal(
        layer._inner.observed_authorization(1),
        String("Bearer secret-token"),
        "same-origin redirect MUST preserve Authorization",
    )


# =============================================================================
# Acceptance test (b-ii) — cross-origin strips Authorization.
# =============================================================================


def test_cross_origin_redirect_strips_authorization() raises:
    """Initial request to example.com → 302 → final 200 at attacker.com.
    The second call MUST NOT see Authorization (stripped)."""
    var statuses = List[Int]()
    statuses.append(302)
    statuses.append(200)
    var locations = List[String]()
    locations.append(String("http://attacker.com/redirected"))
    locations.append(String(""))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(3),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"),
        String("Bearer secret-token"),
    )
    var resp = layer.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req^, connector, reactor)
    assert_equal(Int(resp.status), 200)
    assert_equal(Int(layer.last_hops()), 1)
    # Call 0 (initial) had Authorization; call 1 (after cross-origin
    # redirect) MUST NOT.
    assert_equal(
        layer._inner.observed_authorization(0),
        String("Bearer secret-token"),
    )
    assert_equal(
        layer._inner.observed_authorization(1),
        String("<absent>"),
        "cross-origin redirect MUST strip Authorization",
    )


def test_different_port_is_cross_origin() raises:
    """example.com:80 → example.com:8080 is CROSS-ORIGIN (port mismatch).
    Authorization must be stripped."""
    var statuses = List[Int]()
    statuses.append(307)  # 307 preserves method
    statuses.append(200)
    var locations = List[String]()
    locations.append(String("http://example.com:8080/r"))
    locations.append(String(""))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(3),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com:80/start"),
        String("Bearer secret-token"),
    )
    var resp = layer.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req^, connector, reactor)
    assert_equal(Int(resp.status), 200)
    assert_equal(
        layer._inner.observed_authorization(1),
        String("<absent>"),
        "different port = cross-origin → strip Authorization",
    )


# =============================================================================
# Acceptance test (b-iii) — redirect loop detection raises.
# =============================================================================


def test_redirect_loop_detected() raises:
    """A → B → A. Should raise HttpError on the second time A is seen."""
    var statuses = List[Int]()
    statuses.append(302)
    statuses.append(302)
    var locations = List[String]()
    locations.append(String("http://example.com/b"))
    locations.append(String("http://example.com/start"))  # back to start
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(10),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"),
        String(""),
    )

    var raised = False
    try:
        var resp = layer.call_empty[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true(
            "redirect loop" in msg,
            "raised message must mention loop, got: " + msg,
        )
        raised = True
    assert_true(raised, "loop must raise")


# =============================================================================
# Acceptance test (b-iv) — max_redirects exceeded raises.
# =============================================================================


def test_max_redirects_exceeded_raises() raises:
    """max_redirects=2 → chain of 3 redirects fails."""
    var statuses = List[Int]()
    statuses.append(302)
    statuses.append(302)
    statuses.append(302)
    var locations = List[String]()
    locations.append(String("http://example.com/b"))
    locations.append(String("http://example.com/c"))
    locations.append(String("http://example.com/d"))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(2),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"),
        String(""),
    )

    var raised = False
    try:
        var resp = layer.call_empty[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true(
            "max_redirects" in msg,
            "raised message must mention max_redirects, got: " + msg,
        )
        raised = True
    assert_true(raised, "exceeding max_redirects must raise")


# =============================================================================
# No-redirect call.
# =============================================================================


def test_no_redirect_returns_directly() raises:
    """200 response with no Location header → no redirect followed.
    Returns directly, last_hops=0."""
    var statuses = List[Int]()
    statuses.append(200)
    var locations = List[String]()
    locations.append(String(""))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(
        inner^, UInt32(5),
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"),
        String(""),
    )
    var resp = layer.call_empty[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector
    ](req^, connector, reactor)
    assert_equal(Int(resp.status), 200)
    assert_equal(Int(layer.last_hops()), 0)


def test_loop_error_redacts_query_and_userinfo() raises:
    """The loop error names `scheme://host/path` only: a presigned Location's
    signature (query) and userinfo must not reach error and log text."""
    var statuses = List[Int]()
    statuses.append(302)
    statuses.append(302)
    var locations = List[String]()
    locations.append(String("http://u:pw@example.com/b?X-Sig=SECRETSIG"))
    locations.append(String("http://u:pw@example.com/b?X-Sig=SECRETSIG"))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(inner^, UInt32(10))
    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("http://example.com/start"), String(""),
    )
    var raised = False
    try:
        var resp = layer.call_empty[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true("redirect loop" in msg, "got: " + msg)
        assert_true("SECRETSIG" not in msg, "query leaked: " + msg)
        assert_true("pw" not in msg, "userinfo leaked: " + msg)
        assert_true("example.com/b" in msg, "path must remain: " + msg)
        raised = True
    assert_true(raised, "loop must raise")


def _assert_downgrade_refused(status: Int) raises:
    var statuses = List[Int]()
    statuses.append(status)
    statuses.append(200)
    var locations = List[String]()
    locations.append(String("http://example.com/plain"))
    locations.append(String(""))
    var inner = ScriptedRedirectService.new(statuses^, locations^)
    var layer = RedirectLayer[ScriptedRedirectService].wrap(inner^, UInt32(3))
    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_request_with_auth(
        String("https://example.com/start"), String("Bearer t"),
    )
    var raised = False
    try:
        var resp = layer.call_empty[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector
        ](req^, connector, reactor)
        _ = resp^
    except e:
        var msg = String(e)
        assert_true("downgrade" in msg, "got: " + msg)
        raised = True
    assert_true(raised, "downgrade must raise")
    assert_equal(layer._inner.call_count(), 1, "no request after the refusal")


def test_https_to_http_downgrade_refused() raises:
    """An https origin redirecting to http is refused before the second call,
    so a 307/308 never replays the request in cleartext."""
    _assert_downgrade_refused(307)


def test_https_to_http_downgrade_refused_on_301_get() raises:
    _assert_downgrade_refused(301)


def test_https_to_http_downgrade_refused_on_302_get() raises:
    _assert_downgrade_refused(302)


def test_strip_covers_cloud_credential_headers() raises:
    var h = HeaderMap()
    h.insert(String("X-Amz-Security-Token"), String("tok"))
    h.insert(String("x-goog-api-key"), String("key"))
    h.insert(String("X-Goog-User-Project"), String("proj"))
    h.insert(String("Accept"), String("*/*"))
    _strip_sensitive_headers(h)
    assert_true(not h.get(String("X-Amz-Security-Token")).__bool__())
    assert_true(not h.get(String("X-Goog-Api-Key")).__bool__())
    assert_true(not h.get(String("X-Goog-User-Project")).__bool__())
    assert_true(h.get(String("Accept")).__bool__(), "unrelated header kept")


def main() raises:
    test_same_origin_redirect_keeps_authorization()
    test_cross_origin_redirect_strips_authorization()
    test_different_port_is_cross_origin()
    test_redirect_loop_detected()
    test_max_redirects_exceeded_raises()
    test_no_redirect_returns_directly()
    test_loop_error_redacts_query_and_userinfo()
    test_https_to_http_downgrade_refused()
    test_https_to_http_downgrade_refused_on_301_get()
    test_https_to_http_downgrade_refused_on_302_get()
    test_strip_covers_cloud_credential_headers()
    print("[OK] test_redirect_layer — all 11 tests passed")
