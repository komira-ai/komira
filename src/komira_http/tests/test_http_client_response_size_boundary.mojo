# =============================================================================
# src/komira_http/tests/test_http_client_response_size_boundary.mojo
#   ★ THE RESPONSE-SIZE BOUNDARY GUARD.
# =============================================================================
#
# WHY THIS FILE EXISTS — "what unit test would catch this early?"
#
# An API client failed with:
#
#     HttpError[STATUS_LINE_INVALID]: HTTP-version bad prefix
#
# Bisecting the page size isolated it: a ~3.4 KB response parsed cleanly; a
# ~23.9 KB response did not, while curl showed the remote's reply was a
# well-formed 200 in both cases. So the suspect is RESPONSE SIZE handling
# inside OUR HTTP client, not the remote API.
#
# The suspect is the client's fixed 4096-byte read-head scratch
# (`HttpClient._read_head_scratch`, an `InlineArray[UInt8, 4096]`): a response
# whose bytes cross that boundary can be mis-framed, and the NEXT read is then
# interpreted as a status line — which is exactly what "HTTP-version bad prefix"
# means (the parser was handed body bytes where a status line should be).
#
# Shrinking a caller's page size is a mitigation, not a fix — ANY caller with a
# large response is still exposed. THIS is the real guard, and it sits at the
# layer that owns the defect.
#
# DISCIPLINE: every assertion here is on BEHAVIOUR — the REAL `HttpClient` is
# driven end-to-end across the size boundary via `ScriptedStream` and we assert
# on the parsed status / reason / body length. Nothing here inspects source
# text, buffer sizes, or private fields, so the guard keeps its meaning even if
# the scratch is resized or the read path is rewritten.
#
# ★★ RESULT, RECORDED HONESTLY: THESE TESTS WERE GREEN THE MOMENT
#    THEY WERE WRITTEN — no fix was applied to make them pass. They are a
#    regression GUARD, not a red->green reproduction, and saying otherwise would
#    misreport the evidence.
#
#    What they therefore PROVE is a NEGATIVE, and it is a useful one: over the
#    PLAINTEXT h1 buffered path the client reassembles a response correctly at
#    EVERY size tested (3.4 KB → 24 KB, including exactly-4096 and 4097) and at
#    EVERY read granularity tested (1 byte per read up to 16 KB per read). So
#    "the response is bigger than the 4096-byte read-head scratch" is NOT by
#    itself sufficient to cause `STATUS_LINE_INVALID`. The size hypothesis, as
#    stated, is FALSIFIED at this layer.
#
#    That NARROWS the live defect to what these tests do not yet cover:
#      (a) the TLS/h1 path — `ScriptedConnector.with_stream` is plaintext;
#          `with_stream_tls` exists and the live calls are all https; and
#      (b) KEEPALIVE CONNECTION REUSE — the live sequence is `POST /servers`
#          (small 422) followed by `GET /servers?count=500` (large) on the
#          REUSED idle connection. Residual undrained body bytes from a prior
#          response would be read as the next status line, which is EXACTLY
#          what "HTTP-version bad prefix" means.
#    (b) also explains the live "worked exactly ONCE, failed forever after"
#    shape far better than raw size does. Extending this file to cover (a)+(b)
#    is the next step on.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


# The client's read-head scratch is an `InlineArray[UInt8, 4096]`. The boundary
# sweep below straddles it deliberately: under it, exactly on it, just past it,
# and far past it (the ~23.9 KB shape that actually broke live).
comptime _SCRATCH_BYTES: Int = 4096


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _json_body_of_len(n: Int) -> String:
    """A well-formed JSON body of EXACTLY `n` bytes: `{"d":"aaa…"}`. Shaped like
    the Postmark list replies that triggered the live failure so the guard
    exercises a realistic payload, not a degenerate one."""
    var prefix = String('{"d":"')
    var suffix = String('"}')
    var fill_n = n - len(prefix.as_bytes()) - len(suffix.as_bytes())
    var filler = String("")
    var i = 0
    while i < fill_n:
        filler += "a"
        i = i + 1
    return prefix + filler + suffix


def _drive_response_of_body_len(body_len: Int) raises -> Int:
    """Drive the REAL `HttpClient` over a scripted 200 whose body is exactly
    `body_len` bytes, and return the body length the client actually parsed.

    A mis-framing client either raises (`STATUS_LINE_INVALID` — the live shape)
    or reports a truncated body; both fail the caller's assertions."""
    var url = Url.parse(String("http://127.0.0.1:8080/list"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var body = _json_body_of_len(body_len)
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\n")
        + String("Content-Type: application/json\r\n")
        + String("Content-Length: ")
        + String(body_len)
        + String("\r\n\r\n")
        + body
    )
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(
        Int(resp.status),
        200,
        String("a ") + String(body_len) + String("-byte response must parse as 200"),
    )
    assert_equal(resp.reason, String("OK"))
    return resp.body.bytes_remaining()


# =============================================================================
# Test 1 — the CONTROL. A small response (the `count=5` shape, ~3.4 KB) parses.
#          This one passed live; if it ever reddens the harness itself is wrong.
# =============================================================================
def test_small_response_under_the_scratch_boundary_parses() raises:
    var n = 3400
    assert_equal(
        _drive_response_of_body_len(n),
        n,
        "a ~3.4 KB response (the live-PASSING `count=5` shape) must round-trip",
    )


# =============================================================================
# Test 2 — ★ THE LIVE FAILURE, made hermetic. A ~23.9 KB response is the exact
#          `count=500` shape that raised `STATUS_LINE_INVALID: HTTP-version bad
#          prefix` against the real Postmark API.
# =============================================================================
def test_large_response_past_the_scratch_boundary_parses() raises:
    var n = 23900
    assert_equal(
        _drive_response_of_body_len(n),
        n,
        "a ~23.9 KB response (the live-FAILING `count=500` shape) must"
        " round-trip, not raise STATUS_LINE_INVALID",
    )


# =============================================================================
# Test 3 — the BISECT, frozen as a permanent sweep. The live investigation
#          bisected by page size by hand; this walks the same axis across the
#          4096-byte scratch boundary so the exact crossing point can never
#          regress silently again.
# =============================================================================
def test_response_size_sweep_across_the_scratch_boundary() raises:
    var sizes = List[Int]()
    sizes.append(_SCRATCH_BYTES - 512)   # comfortably under
    sizes.append(_SCRATCH_BYTES - 1)     # one byte under
    sizes.append(_SCRATCH_BYTES)         # exactly on the boundary
    sizes.append(_SCRATCH_BYTES + 1)     # one byte over — the classic off-by-one
    sizes.append(_SCRATCH_BYTES * 2)     # two scratch-fulls
    sizes.append(_SCRATCH_BYTES * 6)     # ~24 KB, the live shape

    for i in range(len(sizes)):
        var n = sizes[i]
        assert_equal(
            _drive_response_of_body_len(n),
            n,
            String("response of ") + String(n)
            + String(" body bytes must parse correctly across the ")
            + String(_SCRATCH_BYTES)
            + String("-byte read-head scratch boundary"),
        )


# =============================================================================
# Test 4 — a LARGE HEAD (many headers), not just a large body. The scratch holds
#          the HEAD, so a header block that alone crosses 4096 bytes is the most
#          direct expression of the suspected defect.
# =============================================================================
def test_large_header_block_past_the_scratch_boundary_parses() raises:
    var url = Url.parse(String("http://127.0.0.1:8080/list"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    # ~80 bytes per header * 80 headers ≈ 6.4 KB of HEAD alone.
    var head = String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
    for i in range(80):
        head += String("X-Pad-") + String(i) + String(": ")
        for _j in range(60):
            head += "p"
        head += String("\r\n")
    var body = String('{"ok":true}')
    var body_len = len(body.as_bytes())
    head += String("Content-Length: ") + String(body_len) + String("\r\n\r\n")

    var resp_script = _b(head + body)
    var stream = ScriptedStream.from_read_script(resp_script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(
        Int(resp.status),
        200,
        "a >4 KB HEADER BLOCK must parse as 200, not STATUS_LINE_INVALID",
    )
    assert_equal(
        resp.body.bytes_remaining(),
        body_len,
        "and the body after a large head must still be framed correctly",
    )
    assert_true(
        Int(resp.status) == 200,
        "the large-head response is fully parsed",
    )


# =============================================================================
# Test 5 — ★ THE FAITHFUL SHAPE: a large response delivered in CHUNKS.
#
#   Tests 1-4 hand the client the whole response in ONE read, because that is
#   `ScriptedStream`'s default (`_max_read_per_call = -1`, unlimited). A REAL
#   socket never does that: TCP delivers ~MSS-sized segments and TLS delivers
#   ~16 KB records, so a 24 KB response arrives as MANY partial reads and the
#   client must reassemble across them. That reassembly — not the raw byte
#   count — is where a head/body framing defect actually lives, and it is the
#   difference between the live failure and a green scripted test.
#
#   `set_max_read_per_call` is the knob that makes the mock behave like the
#   wire. Each chunk size below is swept against each response size so a
#   regression in multi-read reassembly cannot hide behind a single-read mock.
# =============================================================================
def _drive_chunked_response(body_len: Int, chunk: Int) raises -> Int:
    var url = Url.parse(String("http://127.0.0.1:8080/list"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var body = _json_body_of_len(body_len)
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\n")
        + String("Content-Type: application/json\r\n")
        + String("Content-Length: ")
        + String(body_len)
        + String("\r\n\r\n")
        + body
    )
    var stream = ScriptedStream.from_read_script(resp_script^)
    # ★ Deliver the response in `chunk`-sized pieces, like a real socket.
    stream.set_max_read_per_call(chunk)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(
        Int(resp.status),
        200,
        String("a ") + String(body_len) + String("-byte response delivered in ")
        + String(chunk)
        + String("-byte chunks must parse as 200, not STATUS_LINE_INVALID"),
    )
    return resp.body.bytes_remaining()


def test_large_response_delivered_in_socket_sized_chunks_parses() raises:
    var chunks = List[Int]()
    chunks.append(1)      # pathological: one byte per read
    chunks.append(1400)   # ~TCP MSS
    chunks.append(4096)   # exactly the scratch size
    chunks.append(16384)  # ~TLS record

    var sizes = List[Int]()
    sizes.append(3400)    # the live-PASSING `count=5` shape
    sizes.append(23900)   # the live-FAILING `count=500` shape

    for ci in range(len(chunks)):
        for si in range(len(sizes)):
            var n = sizes[si]
            assert_equal(
                _drive_chunked_response(n, chunks[ci]),
                n,
                String("body of ") + String(n) + String(" bytes over ")
                + String(chunks[ci])
                + String("-byte reads must reassemble exactly"),
            )


def main() raises:
    test_small_response_under_the_scratch_boundary_parses()
    test_large_response_past_the_scratch_boundary_parses()
    test_response_size_sweep_across_the_scratch_boundary()
    test_large_header_block_past_the_scratch_boundary_parses()
    test_large_response_delivered_in_socket_sized_chunks_parses()
    print(
        "[OK] test_http_client_response_size_boundary — all 5 tests passed"
    )
