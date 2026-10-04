# =============================================================================
# src/kci_pkg_upload/transport.mojo — the ONE-METHOD package-registry
#   transport seam, its scripted double, and its HTTPS conformer.
# =============================================================================
#
# ONE METHOD, `exchange(request) -> response`, because the PROTOCOL
# (multipart forms, index JSON, redirects, status classification) belongs in
# the registry clients, and the transport's whole job is to move bytes. So the double can script any conversation,
# including a redirect, a transport fault mid-upload, or a stale index — and
# `ScriptedPkgTransport` records the EXACT request each call sent (verb, host,
# path, every header, every body byte), which is what the golden-request and
# fidelity tests compare.
#
# THE HOST IS ON THE REQUEST, not the transport: one publish talks to an upload
# host, an index host and a file host, and "which host did the credential go
# to?" must be an assertable fact.
#
# ⚠ A NON-2xx STATUS IS NOT A RAISE. Status is control flow here (404 = ABSENT,
# 400 "File already exists" = DUPLICATE_REFUSED). The transport raises only on
# a genuine transport fault, and the clients turn that raise into UNKNOWN.
#
# Encapsulation: owned `String` / `List[UInt8]` values across the
# seam. No UnsafePointer, no wildcard origin.
# =============================================================================

from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime


# Every registry is HTTPS on 443; a plaintext registry is deliberately not
# supported (an upload credential must never leave the process in the clear).
comptime PKG_REGISTRY_PORT: UInt16 = 443


def ascii_eq_ignore_case(a: String, b: String) -> Bool:
    if a.byte_length() != b.byte_length():
        return False
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    for i in range(len(ab)):
        var ca = ab[i]
        var cb = bb[i]
        if ca >= UInt8(65) and ca <= UInt8(90):
            ca += UInt8(32)
        if cb >= UInt8(65) and cb <= UInt8(90):
            cb += UInt8(32)
        if ca != cb:
            return False
    return True


struct PkgRequest(Copyable, Movable, Deinitable):
    """One registry HTTP call.

      method  — an `HTTP_METHOD_*` code (komira_http_core).
      host    — the HOST this call goes to.
      path    — the path INCLUDING any query string.
      header_names / header_values — parallel lists, in send order.
      body    — EMPTY for GET.

    Layout: owned values only. No pointer field."""

    var method: UInt8
    var host: String
    var path: String
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(out self, method: UInt8, var host: String, var path: String):
        self.method = method
        self.host = host^
        self.path = path^
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = List[UInt8]()

    def with_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def with_authorization(mut self, authorization: String):
        """Attach `Authorization: <value>` — a NO-OP on an empty value, which
        means "send no credential" (an anonymous read), never "send an empty
        header"."""
        if authorization.byte_length() > 0:
            self.with_header(String("Authorization"), authorization.copy())

    def header_value(self, name: String) -> String:
        """The value of header `name` (ASCII-case-insensitive), or EMPTY."""
        for i in range(len(self.header_names)):
            if ascii_eq_ignore_case(self.header_names[i], name):
                return self.header_values[i].copy()
        return String("")


struct PkgResponse(Copyable, Movable, Deinitable):
    """One registry HTTP reply: status + the headers the protocol reads +
    body bytes (never a `String`: a fetched wheel is binary).

    Layout: owned values only. No pointer field."""

    var status: Int
    var header_names: List[String]
    var header_values: List[String]
    var body: List[UInt8]

    def __init__(out self, status: Int):
        self.status = status
        self.header_names = List[String]()
        self.header_values = List[String]()
        self.body = List[UInt8]()

    def with_header(mut self, var name: String, var value: String):
        self.header_names.append(name^)
        self.header_values.append(value^)

    def with_body(mut self, var body: List[UInt8]):
        self.body = body^

    def header(self, name: String) -> String:
        """Response header `name` (ASCII-case-insensitive), or EMPTY."""
        for i in range(len(self.header_names)):
            if ascii_eq_ignore_case(self.header_names[i], name):
                return self.header_values[i].copy()
        return String("")


trait PkgTransport(Movable, Deinitable):
    """One HTTP exchange. RAISES only on a transport fault; a non-2xx status is
    a `PkgResponse`."""

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        ...


struct ExchangeResult(Movable, Deinitable):
    """One exchange that did not raise: `ok == False` means the transport
    FAULTED and `fault` says how; otherwise `response` is the answer.

    Layout: owned values only. No pointer field."""

    var ok: Bool
    var response: PkgResponse
    var fault: String

    def __init__(out self, ok: Bool, var response: PkgResponse, var fault: String):
        self.ok = ok
        self.response = response^
        self.fault = fault^


def try_exchange[T: PkgTransport](mut transport: T, req: PkgRequest) -> ExchangeResult:
    """`transport.exchange(req)` with a transport fault turned into data. The
    registry clients never let a transport raise escape: on a mutating request
    it is UNKNOWN (the client cannot tell whether bytes left), and on a read it
    is UNKNOWN too (the caller re-probes)."""
    try:
        return ExchangeResult(True, transport.exchange(req), String(""))
    except e:
        return ExchangeResult(False, PkgResponse(0), String(e))


# =============================================================================
# ScriptedPkgTransport — the TEST DOUBLE (no sockets, no network).
# =============================================================================


struct ScriptedPkgTransport(PkgTransport, Deinitable):
    """Replays scripted answers in FIFO call order and records every request
    verbatim. An answer is either a `PkgResponse` or a scripted transport
    FAULT (`queue_fault`), which `exchange` raises — the "did the bytes
    leave?" case no status can express.

    Running off the end of the script RAISES naming the unscripted call, so a
    test cannot pass by the client making a request nobody expected.

    Layout: owned lists. No pointer field."""

    var _answers: List[PkgResponse]
    var _faults: List[String]
    var _is_fault: List[Bool]
    var _cursor: Int
    var _calls: List[PkgRequest]

    def __init__(out self):
        self._answers = List[PkgResponse]()
        self._faults = List[String]()
        self._is_fault = List[Bool]()
        self._cursor = 0
        self._calls = List[PkgRequest]()

    def queue(mut self, var response: PkgResponse):
        self._answers.append(response^)
        self._faults.append(String(""))
        self._is_fault.append(False)

    def queue_fault(mut self, var message: String):
        """Script a transport FAULT for the next call: `exchange` raises
        `message`."""
        self._answers.append(PkgResponse(0))
        self._faults.append(message^)
        self._is_fault.append(True)

    def call_count(self) -> Int:
        return len(self._calls)

    def call(self, i: Int) -> PkgRequest:
        return self._calls[i].copy()

    def unconsumed(self) -> Int:
        """Scripted answers no call consumed. A test asserts 0 to prove the
        client made every request it was expected to."""
        return len(self._answers) - self._cursor

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        self._calls.append(req.copy())
        if self._cursor >= len(self._answers):
            raise Error(
                String("ScriptedPkgTransport: no scripted answer for call #")
                + String(self._cursor)
                + String(" (")
                + req.host
                + req.path
                + String("); script more answers")
            )
        var i = self._cursor
        self._cursor += 1
        if self._is_fault[i]:
            raise Error(self._faults[i].copy())
        return self._answers[i].copy()


# =============================================================================
# HttpPkgTransport[C] — the PRODUCTION transport over komira_http_client.
# =============================================================================


struct HttpPkgTransport[C: Connector](PkgTransport, Deinitable):
    """Dials a fresh connector per call and drives ONE synchronous request over
    the shipped `HttpClient[C]`. TLS, framing, `Content-Length` and chunked
    decoding are the shipped client's.

    The factory TAKES THE HOST: one publish talks to several hosts, and the
    connector must present the right SNI and verify the right certificate for
    whichever one this call is for.

    Layout: the connector factory is a `def (String) thin -> C` FFI-POD fn-ptr
    field (a code pointer, no heap, no wildcard)."""

    var _mk_connector: def (String) thin -> Self.C

    def __init__(out self, mk_connector: def (String) thin -> Self.C):
        self._mk_connector = mk_connector

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        var headers = HeaderMap()
        for i in range(len(req.header_names)):
            headers.append(req.header_names[i].copy(), req.header_values[i].copy())
        var url = Url.https(req.host.copy(), PKG_REGISTRY_PORT, req.path.copy())
        var method = HttpMethod(code=req.method)

        var connector = self._mk_connector(req.host.copy())
        var client = HttpClient[Self.C].with_defaults(connector^)
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()

        # The arms differ ONLY in the body conformer (a compile-time parameter,
        # so a bodiless GET and a body-carrying POST cannot share one value).
        if len(req.body) == 0:
            var r = build_request_with_body[EmptyBody](
                method, url^, headers^, EmptyBody.new()
            )
            var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
                r^, reactor
            )
            return _lower(Int(cr.status), cr.headers, cr.body.take_bytes())

        var r2 = build_request_with_body[BytesBody](
            method, url^, headers^, BytesBody.from_bytes(req.body.copy())
        )
        var cr2 = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
            r2^, reactor
        )
        return _lower(Int(cr2.status), cr2.headers, cr2.body.take_bytes())


def _lower(status: Int, headers: HeaderMap, var body: List[UInt8]) -> PkgResponse:
    """Narrow an `HttpClient` response to the seam: only the headers the
    registry protocols read cross it."""
    var out = PkgResponse(status)
    _lift(headers, String("content-type"), out)
    _lift(headers, String("location"), out)
    _lift(headers, String("retry-after"), out)
    out.with_body(body^)
    return out^


def _lift(headers: HeaderMap, name: String, mut out: PkgResponse):
    var v = headers.get(name)
    if v:
        out.with_header(name.copy(), v.value())
