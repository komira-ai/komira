# =============================================================================
# komira_http_client/http_transport.mojo
#   The VENDOR-NEUTRAL HTTP round-trip SEAM — the `HttpTransport` trait, the
#   `TransportResponse` {status, body} POD, the method tags, the two recording
#   TEST DOUBLES (`ScriptedTransport` / `SharedScriptedTransport`), AND the
#   PRODUCTION public-CA-TLS conformer `TlsHttpTransport`.
# =============================================================================
#
# WHY THIS MODULE EXISTS. `HttpTransport` is the one HTTP seam that API
# clients (cloud metadata token providers, IAM-credential and secret-store
# clients, email-relay clients, token exchanges) inject fakes through. A
# client built on it is tested against `ScriptedTransport` and runs in
# production over `TlsHttpTransport` (public-CA TLS, HTTP/1.1).
#
# ⚠ WHY `TransportResponse` AND NOT `HttpResponse`. `HttpResponse` is the
# SERVER-side response type in `komira_http_core/codec/types.mojo`, and a client
# that also serves HTTP holds both types at once. `TransportResponse` says
# exactly what it is — the `HttpTransport` seam's return value — and collides
# with nothing.
#
# POINTER DISCIPLINE: ZERO UnsafePointer in any signature;
# NO wildcard origin; NO `unsafe_from_address`; NO take_pointee. The only
# pointer here is `SharedScriptedTransport._p`, an `ArcPointer` over TEST-DOUBLE
# recording state.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import (
    HttpClient,
    build_get_request,
    build_delete_request,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.service import ClientRequest
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HTTP_METHOD_PUT, HttpMethod
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from std.memory import ArcPointer


# =============================================================================
# §1 — HTTP method tags. Plain verb ordinals every `HttpTransport` conformer
# and caller uses: GET (fetch), POST (create), PUT (update / verify), DELETE
# (bodyless erase).
# =============================================================================
comptime PM_METHOD_GET: Int = 0
comptime PM_METHOD_POST: Int = 1
comptime PM_METHOD_PUT: Int = 2
comptime PM_METHOD_DELETE: Int = 3
"""A bodyless DELETE (e.g. `DELETE /domains/{id}`)."""


# =============================================================================
# §2 — TransportResponse — the value returned from a round-trip: status + body.
#
# A plain owned-value POD. Like GoogleApiResponse, the STATUS is in hand: an API
# may use 422 (unprocessable — e.g. a domain already exists) and 401 (bad token)
# as routine, non-exceptional control flow that the client maps to typed errors;
# only genuine TRANSPORT failures (DNS, TLS, connection) raise.
# =============================================================================
@fieldwise_init
struct TransportResponse(Copyable, Movable, Deinitable):
    """The result of an HTTP round-trip: the HTTP status + raw body String.
    A value POD — no pointers, no borrowed origins."""

    var status: Int
    var body: String

    @always_inline
    def is_success(self) -> Bool:
        """True iff the status is 2xx."""
        return self.status >= 200 and self.status < 300


# =============================================================================
# §3 — HttpTransport trait — the seam every HTTP client in this repo drives.
#
# ONE method: `request(method, url, header_name, header_value, body)` ->
# TransportResponse. The single auth header is passed IN, not owned by the
# transport, so the same transport serves every API and a test fake never needs
# to know the token. `raises` so a real transport surfaces transport failures.
# =============================================================================
trait HttpTransport(Movable, Deinitable):
    """The HTTP round-trip seam. Conformers: `TlsHttpTransport`
    (production, komira_http + public-CA TLS) and `ScriptedTransport` /
    `SharedScriptedTransport` (test fakes). The single auth header is passed per
    request; the transport is auth-agnostic."""

    def request(
        mut self,
        method: Int,
        url: String,
        header_name: String,
        header_value: String,
        body: String,
    ) raises -> TransportResponse:
        ...


# =============================================================================
# §4 — ScriptedTransport — the TEST fake. Records calls + replays canned JSON.
#
# The ScriptedChatTransport idiom: a list of (match-substring, status, body)
# rows; `request` returns the FIRST row whose match-substring appears in the
# url+body (empty substring = catch-all). Every call is RECORDED (method, url,
# header_name, header_value, body) so a test can assert the exact request shape
# — the right endpoints were hit, the right token header was sent, the body
# carried the domain/server name. A non-matching request RAISES (loud), so a
# missing expectation fails the test rather than silently passing.
#
# CUSTODY-TEST property: the recorded `header_value` lets a test assert the
# token header was sent to the wire WITHOUT the production code ever logging it
# — the test inspects the recording, the production path never does.
# =============================================================================
@fieldwise_init
struct _ScriptedRow(Copyable, Movable, Deinitable):
    """One canned reply: fire when `match_str` is a substring of url+body."""

    var match_str: String
    var status: Int
    var body: String


@fieldwise_init
struct RecordedCall(Copyable, Movable, Deinitable):
    """One recorded outbound request — for test assertions on request shape."""

    var method: Int
    var url: String
    var header_name: String
    var header_value: String
    var body: String


struct ScriptedTransport(
    HttpTransport, Defaultable, Movable, Deinitable
):
    """A recording test fake for `HttpTransport`. `add(match, status, body)`
    registers a canned reply; `request` returns the first row whose `match` is
    a substring of url+body and RECORDS the call for later assertion. A
    non-matching request raises (loud). No sockets, no live backend."""

    var _rows: List[_ScriptedRow]
    var calls: List[RecordedCall]

    def __init__(out self):
        self._rows = List[_ScriptedRow]()
        self.calls = List[RecordedCall]()

    def add(mut self, match_str: String, status: Int, body: String):
        """Register a canned reply. `match_str` empty == catch-all (register
        last)."""
        self._rows.append(_ScriptedRow(match_str, status, body))

    def call_count(self) -> Int:
        return len(self.calls)

    def request(
        mut self,
        method: Int,
        url: String,
        header_name: String,
        header_value: String,
        body: String,
    ) raises -> TransportResponse:
        self.calls.append(
            RecordedCall(method, url, header_name, header_value, body)
        )
        var hay = url + " " + body
        for i in range(len(self._rows)):
            ref row = self._rows[i]
            if (
                len(row.match_str.as_bytes()) == 0
                or _contains(hay, row.match_str)
            ):
                return TransportResponse(row.status, row.body)
        raise Error(
            String("ScriptedTransport: no canned reply matched request to ")
            + url
        )


# =============================================================================
# SharedScriptedTransport — a ScriptedTransport whose recording survives the MOVE
# into the client that consumes it.
#
# WHY IT EXISTS. `ScriptedTransport` is owned BY VALUE by the client that drives
# it (and therefore by the provisioners built over it), so once a test hands its
# transport to the code under test the recording is unreachable — a test can no
# longer ask "which ACCOUNT TOKEN did that route actually put on the wire?". A
# guard that must tell two credentials apart has to answer exactly that, so the
# spy needs a SECOND handle over ONE recording, the usual shape of a shared
# test double.
#
# SAFETY: `ArcPointer` ref-counted shared ownership of the recording state — a
# TEST DOUBLE, driven on ONE thread (fork-join tests never share a transport).
# The recorded `header_value` is inspected only BY THE TEST; the production path
# still never logs a token.
# =============================================================================
struct _SharedScriptedState(Movable):
    """The shared interior: the canned replies + the recorded calls."""

    var rows: List[_ScriptedRow]
    var calls: List[RecordedCall]

    def __init__(out self):
        self.rows = List[_ScriptedRow]()
        self.calls = List[RecordedCall]()


struct SharedScriptedTransport(
    HttpTransport, Defaultable, Movable, Deinitable
):
    """A recording `HttpTransport` test fake whose recording is SHARED: `share()`
    hands back a second handle over ONE recording, so a test can still read the
    calls after the transport has been MOVED into the client under test. Same
    scripting contract as `ScriptedTransport` (`add(match, status, body)`; a
    non-matching request RAISES loudly)."""

    var _p: ArcPointer[_SharedScriptedState]

    def __init__(out self):
        self._p = ArcPointer[_SharedScriptedState](_SharedScriptedState())

    def __init__(out self, *, var _share: ArcPointer[_SharedScriptedState]):
        self._p = _share^

    def share(self) -> SharedScriptedTransport:
        """A SECOND handle over ONE recording. SAFETY: ArcPointer ref-counted
        shared ownership; a TEST DOUBLE on ONE thread."""
        return SharedScriptedTransport(
            _share=ArcPointer[_SharedScriptedState](copy=self._p)
        )

    def add(mut self, match_str: String, status: Int, body: String):
        """Register a canned reply. `match_str` empty == catch-all (register
        last)."""
        self._p[].rows.append(_ScriptedRow(match_str, status, body))

    def call_count(self) -> Int:
        return len(self._p[].calls)

    def header_value_at(self, i: Int) -> String:
        """The token-header VALUE the i-th recorded request carried — the
        provenance evidence a custody test asserts on."""
        return self._p[].calls[i].header_value.copy()

    def header_name_at(self, i: Int) -> String:
        """The token-header NAME the i-th recorded request carried."""
        return self._p[].calls[i].header_name.copy()

    def sent_header_value(self, value: String) -> Bool:
        """True iff SOME recorded request carried exactly `value` as its token
        header. A guard asserts the DURABLE token was sent AND that the
        in-process one never was."""
        ref calls = self._p[].calls
        for i in range(len(calls)):
            if calls[i].header_value == value:
                return True
        return False

    def url_at(self, i: Int) -> String:
        return self._p[].calls[i].url.copy()

    def body_at(self, i: Int) -> String:
        """The REQUEST BODY the i-th recorded request carried. A
        redirect/credential-disclosure guard reads this: a call that registers a
        webhook puts the target HOST **and** the webhook credential in the body
        (`{"HookUrl":"https://user:secret@host/hook"}`), so "we never pointed the
        provider at a caller-supplied host" and "no credential left this process
        toward an unvalidated target" are only assertable off the body — the URL
        alone (`/servers/<id>`) shows neither."""
        return self._p[].calls[i].body.copy()

    def method_at(self, i: Int) -> Int:
        """The HTTP method ordinal of the i-th recorded request (`PM_METHOD_*`)."""
        return self._p[].calls[i].method

    def request(
        mut self,
        method: Int,
        url: String,
        header_name: String,
        header_value: String,
        body: String,
    ) raises -> TransportResponse:
        self._p[].calls.append(
            RecordedCall(method, url, header_name, header_value, body)
        )
        var hay = url + " " + body
        ref rows = self._p[].rows
        for i in range(len(rows)):
            ref row = rows[i]
            if (
                len(row.match_str.as_bytes()) == 0
                or _contains(hay, row.match_str)
            ):
                return TransportResponse(row.status, row.body)
        raise Error(
            String(
                "SharedScriptedTransport: no canned reply matched request to "
            )
            + url
        )


# -----------------------------------------------------------------------------
# _contains — small substring check (the test-fake's own; no stdlib dep).
# -----------------------------------------------------------------------------
def _contains(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0:
        return True
    if len(nb) > len(hb):
        return False
    for start in range(len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[start + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


# =============================================================================
# §4 — the connector-factory fn-ptr TYPE alias + the default factory (mirrors
# GoogleHttpClient §2). The factory takes the request host so SNI is set per
# request; `raises` because the s2n FFI config can fail; `thin` so it is a
# plain code-pointer storable field.
# =============================================================================
comptime TlsConnectorFactory = def (
    String,  # host — used to set SNI per request
) raises thin -> TlsConnector[KernelTcpConnector]


def default_tls_factory(
    host: String,
) raises -> TlsConnector[KernelTcpConnector]:
    """The default public-CA TLS connector factory for ANY public host (the
    GCP metadata server, Secret Manager, the SES endpoints). Verify-peer
    against the OS / public-CA trust store,
    SNI = `host`, HTTP/1.1. A 1-line delegation to the primitive."""
    return build_public_ca_tls_connector(host)


# =============================================================================
# §5 — TlsHttpTransport — the PRODUCTION transport over komira_http.
#
# The SAME composition as GoogleHttpClient: a `def (host) raises thin ->
# TlsConnector[KernelTcpConnector]` factory field (the FFI-POD carve-out),
# a fresh connector + BlockingRuntime per request, the borrowed reactor
# threaded through `send_buffered` and never stored.
# =============================================================================
struct TlsHttpTransport(
    HttpTransport, Defaultable, Movable, Deinitable
):
    """Production `HttpTransport` over komira_http: dials a public-CA TLS
    connector (SNI = the request host) per request, runs one synchronous
    request on a BlockingRuntime, returns {status, body}. Only transport errors
    raise; HTTP error statuses (401/422/5xx) are returned for the client."""

    # # SAFETY: FFI-POD code pointer (the sanctioned wildcard carve-out,
    # the pointer rules). Holds a code address, NO heap, NO wildcard origin
    # (the return type is concrete). Identical to GoogleHttpClient._mk_connector
    # (google_http_client.mojo:183). Called per request with the request host.
    var _mk_connector: TlsConnectorFactory
    # The per-request drive-loop deadline (microseconds). `0` selects the
    # generous 600s default (`with_defaults` == `with_request_timeout_us(0)`).
    # A POSITIVE value BOUNDS the round-trip so a slow / non-responsive peer
    # cannot wedge the calling thread (the request-access notify path sets a
    # tight bound so a public unauthenticated endpoint stays best-effort). Just
    # a plain Int — no heap, no pointer, no wildcard origin.
    var _request_timeout_us: Int

    def __init__(out self):
        """Construct with the standard public-CA TLS connector factory (no
        request-timeout bound — the generous 600s default)."""
        self._mk_connector = default_tls_factory
        self._request_timeout_us = 0

    def __init__(out self, mk_connector: TlsConnectorFactory):
        """Construct with an explicit connector factory (advanced / test), no
        request-timeout bound (the 600s default)."""
        self._mk_connector = mk_connector
        self._request_timeout_us = 0

    def __init__(
        out self,
        mk_connector: TlsConnectorFactory,
        request_timeout_us: Int,
    ):
        """Construct with an explicit connector factory + a per-request
        drive-loop deadline (microseconds; `0` = the 600s default). The
        request-access notify path uses this to BOUND the `/email` send so a
        slow peer can't hang the request serve loop (best-effort)."""
        self._mk_connector = mk_connector
        self._request_timeout_us = request_timeout_us

    @staticmethod
    def with_request_timeout(request_timeout_us: Int) -> Self:
        """The standard public-CA transport with a per-request drive-loop
        deadline set (microseconds). Used by the request-access notify path so
        the `/email` send fails FAST rather than wedging the serve loop."""
        return Self(default_tls_factory, request_timeout_us)

    def request(
        mut self,
        method: Int,
        url: String,
        header_name: String,
        header_value: String,
        body: String,
    ) raises -> TransportResponse:
        var parsed = Url.parse(url)
        var host = parsed.host_copy()
        var headers = HeaderMap()
        headers.append(String("Accept"), String("application/json"))
        # The single auth header (bearer / account token / API key), passed in.
        headers.append(header_name, header_value)
        if method == PM_METHOD_GET:
            var req = build_get_request(parsed^, headers^)
            return self._run_get(req^, host^)
        if method == PM_METHOD_DELETE:
            # A bodyless DELETE (the external-reap resource deletes). Reuses the
            # EmptyBody `_run_get` path (same bodyless round-trip shape).
            var reqd = build_delete_request(parsed^, headers^)
            return self._run_get(reqd^, host^)
        # POST (create domain / create server) or PUT (verifyDkim) — both carry
        # a JSON body (verifyDkim takes an empty `{}`). The HTTP verb differs.
        headers.append(String("Content-Type"), String("application/json"))
        var verb = (
            HTTP_METHOD_PUT if method == PM_METHOD_PUT else HTTP_METHOD_POST
        )
        var body_bytes = List[UInt8]()
        var src = body.as_bytes()
        for i in range(len(src)):
            body_bytes.append(src[i])
        var req2 = build_request_with_body[BytesBody](
            HttpMethod(code=verb),
            parsed^,
            headers^,
            BytesBody.from_bytes(body_bytes^),
        )
        return self._run_post(req2^, host^)

    def _run_get(
        self, var req: ClientRequest[EmptyBody], var host: String
    ) raises -> TransportResponse:
        var connector = self._mk_connector(host)
        var client = HttpClient[
            TlsConnector[KernelTcpConnector]
        ].with_request_timeout_us(connector^, self._request_timeout_us)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()
        var text = String(unsafe_from_utf8=Span(resp_bytes))
        return TransportResponse(status, text^)

    def _run_post(
        self, var req: ClientRequest[BytesBody], var host: String
    ) raises -> TransportResponse:
        var connector = self._mk_connector(host)
        var client = HttpClient[
            TlsConnector[KernelTcpConnector]
        ].with_request_timeout_us(connector^, self._request_timeout_us)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()
        var text = String(unsafe_from_utf8=Span(resp_bytes))
        return TransportResponse(status, text^)
