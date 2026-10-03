# =============================================================================
# src/komira_http_client/tests/test_h1_response_trailers_and_ceilings.mojo
# =============================================================================
# H1 RESPONSE PATH — trailer section, chunk extensions, and the body ceiling,
# asserted AT THE CALLER ALTITUDE (`RecvRingBody` / `HttpClient`) rather than
# at the codec altitude where `decode_block` is driven directly.
#
# ⛔ WHY A NEW FILE RATHER THAN MORE CASES IN `test_recv_ring_body.mojo`.
# Three whole feature areas on this path were load-bearing DEAD CODE at the
# time this was written, and each was dead in a different way:
#
#   1. TRAILERS. `RecvRingBody._trailers` / `._trailers_emitted` are declared
#      (response_body.mojo §RecvRingBody fields), initialised in all three
#      ctors, and WRITTEN BY NOTHING. `BodyFrame.trailers(...)` exists and is
#      constructed by no production path, while `is_trailers()` is read by
#      both drain helpers (`collect_body`, `drain_bodies_round_robin`). The
#      only pre-existing test whose name says "trailer"
#      (`test_recv_ring_chunked_multi_chunk_with_trailer`) sends `0\r\n\r\n`
#      — the EMPTY trailer. No test anywhere sent a real trailer line.
#      ⚠ THIS IS NOT COSMETIC: gRPC-over-H1 carries its terminal status in
#      trailers, so a discarded trailer is a discarded status — the same
#      class of silent wrong answer as the chunked-framing incident.
#
#   2. THE BODY CEILING. `poll_frame`'s
#      `_accum.__len__() > _max_body_bytes - _emitted_bytes` guard was
#      implemented and asserted by NOTHING. An untested ceiling is a ceiling
#      that gets refactored into a no-op.
#
#   3. CHUNK EXTENSIONS. Covered only where `decode_block` is called
#      directly, i.e. at an altitude the caller that mishandles them cannot
#      be reached from.
#
# THESE CASES PIN CURRENT, CORRECT BEHAVIOUR. The cases that state a
# conformance bar this code does NOT meet live in the sibling file
# `test_h1_response_trailer_and_extension_limits_conformance.mojo` and are
# RED on purpose — they are the finding, not a defect in the test.
#
# No UnsafePointer crosses a module boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import RecvRingBody
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# §0 — Fixture helpers. Same shape as the neighbouring RecvRingBody suites.
# =============================================================================


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _append_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1


def _bytes_eq(buf: List[UInt8], s: String) -> Bool:
    var b = s.as_bytes()
    if buf.__len__() != len(b):
        return False
    var i = 0
    while i < buf.__len__():
        if buf[i] != b[i]:
            return False
        i = i + 1
    return True


def _slice_of(src: List[UInt8], start: Int, end_excl: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var i = start
    while i < end_excl:
        out.append(src[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


@fieldwise_init
struct DrainOutcome(Copyable, Movable, Deinitable):
    """What one full `poll_frame` drain produced.

    `detail` is "" on a clean End, otherwise the Error frame's detail
    string — the drain NEVER raises, because the error text is the subject
    of most assertions here. `trailers_frames` counts BodyFrame.trailers()
    sightings, which is the load-bearing-dead-code assertion: it is 0
    today, everywhere, and a caller that starts emitting trailers must
    change these numbers deliberately."""

    var detail: String
    var delivered: Int
    var trailers_frames: Int
    var data_frames: Int


def _drain(
    mut body: RecvRingBody[ScriptedStream],
    mut reactor: Reactor[NoopSink],
    ref tok: CancellationToken,
    mut out: List[UInt8],
) raises -> DrainOutcome:
    var iter = 0
    var trailers_frames = 0
    var data_frames = 0
    while True:
        iter = iter + 1
        if iter > 4_000_000:
            return DrainOutcome(
                detail=String("ITER_CAP"),
                delivered=out.__len__(),
                trailers_frames=trailers_frames,
                data_frames=data_frames,
            )
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if f.is_end():
            return DrainOutcome(
                detail=String(""),
                delivered=out.__len__(),
                trailers_frames=trailers_frames,
                data_frames=data_frames,
            )
        if f.is_error():
            return DrainOutcome(
                detail=f.error_detail(),
                delivered=out.__len__(),
                trailers_frames=trailers_frames,
                data_frames=data_frames,
            )
        if f.is_trailers():
            trailers_frames = trailers_frames + 1
            continue
        if f.is_data():
            data_frames = data_frames + 1
            var chunk = f.take_data_chunk()
            var k = 0
            while k < chunk.__len__():
                out.append(chunk[k])
                k = k + 1
    return DrainOutcome(
        detail=String(""),
        delivered=out.__len__(),
        trailers_frames=trailers_frames,
        data_frames=data_frames,
    )


def _drain_chunked_wire(
    var pre: List[UInt8],
    var wire: List[UInt8],
    max_read: Int,
    max_body_bytes: Int,
    mut out: List[UInt8],
) raises -> DrainOutcome:
    """Build a chunked RecvRingBody over (pre_body, wire) and drain it."""
    var stream = ScriptedStream.from_read_script(wire^)
    if max_read > 0:
        stream.set_max_read_per_call(max_read)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=pre^, max_body_bytes=max_body_bytes,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    return _drain(body, reactor, tok, out)


# A response body carrying a REAL, non-empty trailer section. `Expires` and
# `X-Sig` are the two shapes RFC 9110 §6.5 explicitly permits in a trailer.
comptime _TRAILER_WIRE = (
    "5\r\nhello\r\n0\r\nExpires: Wed\r\nX-Sig: abc\r\n\r\n"
)
comptime _TRAILER_PAYLOAD = "hello"


# =============================================================================
# §1 — A REAL trailer section. PINS "parsed and discarded".
# =============================================================================


def test_real_trailer_section_payload_exact_and_discarded() raises:
    """`5\\r\\nhello\\r\\n0\\r\\nExpires: Wed\\r\\nX-Sig: abc\\r\\n\\r\\n`.

    The payload must be EXACTLY "hello" — no trailer byte may leak into the
    body, which is the failure mode a trailer-unaware decoder produces.

    ⚠ AND THE PIN: zero Trailers frames. The trailer section is parsed for
    well-formedness and then DISCARDED; `RecvRingBody._trailers` is never
    written and `BodyFrame.trailers(...)` is never constructed. This
    assertion is the tripwire on that: a change that starts surfacing
    trailers must come here and say so."""
    var out = List[UInt8]()
    var res = _drain_chunked_wire(
        _make_bytes(String(_TRAILER_WIRE)),
        List[UInt8](),
        0,
        1024 * 1024,
        out,
    )
    assert_equal(res.detail, String(""))
    assert_true(_bytes_eq(out, String(_TRAILER_PAYLOAD)))
    assert_equal(res.trailers_frames, 0)


def test_real_trailer_section_split_across_every_offset() raises:
    """The same wire, with the pre_body/wire handoff placed at EVERY byte
    offset — so a read boundary lands inside the trailer NAME, inside the
    trailer VALUE, on the colon, and between the two terminating CRLFs.

    The pre_body seam is as arbitrary as a TCP read boundary: it is wherever
    the HEAD parse happened to stop. A trailer line is one of the three
    framing tokens the decoder can decline (chunk-size line, chunk-data
    CRLF, trailer line), so this is the trailer half of the caller's
    re-present-what-was-declined contract."""
    var full = _make_bytes(String(_TRAILER_WIRE))
    var n = full.__len__()
    var split = 0
    while split <= n:
        var out = List[UInt8]()
        var res = _drain_chunked_wire(
            _slice_of(full, 0, split),
            _slice_of(full, split, n),
            0,
            1024 * 1024,
            out,
        )
        assert_equal(res.detail, String(""))
        assert_true(_bytes_eq(out, String(_TRAILER_PAYLOAD)))
        assert_equal(res.trailers_frames, 0)
        split = split + 1


def test_real_trailer_section_every_read_size() raises:
    """The same wire delivered one, two, three ... bytes per `try_read`,
    which walks a read boundary through every position of the trailer
    section without needing a pre_body seam at all."""
    var full = _make_bytes(String(_TRAILER_WIRE))
    var k = 1
    while k <= 8:
        var out = List[UInt8]()
        var res = _drain_chunked_wire(
            List[UInt8](), _slice_of(full, 0, full.__len__()), k,
            1024 * 1024, out,
        )
        assert_equal(res.detail, String(""))
        assert_true(_bytes_eq(out, String(_TRAILER_PAYLOAD)))
        k = k + 1


# =============================================================================
# §2 — Trailers MUST NOT be merged into the header section (RFC 9112 §7.1.2).
# =============================================================================


def test_trailers_are_not_merged_into_the_response_header_map() raises:
    """Full-response altitude (`HttpClient.send` over `ScriptedConnector`),
    because "the response's header map" only exists here.

    `Vary` and `Content-Type` arrive as TRAILERS. RFC 9112 §7.1.2: a
    recipient that merges a trailer into the header section changes the
    meaning of the message after the caller has already acted on the
    headers — for `Content-Type` that is a content-sniffing divergence, and
    for `Vary` a cache-key one.

    ⚠ POSITIVE CONTROL IS LOAD-BEARING. Three "not present" assertions
    would also pass against a header map that was never populated at all.
    `X-Real: yes` is a genuine header on the same response and MUST be
    present, which is what makes the negatives mean something."""
    var url = Url.parse(String("http://127.0.0.1:8080/trailers"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var script = _make_bytes(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "X-Real: yes\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "0\r\n"
        "Vary: *\r\n"
        "Content-Type: text/plain\r\n"
        "\r\n"
    ))
    var stream = ScriptedStream.from_read_script(script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var resp = client.send[PerCoreAsyncRuntime[NoopSink]](req^, reactor)

    assert_equal(Int(resp.status), 200)
    # Positive control — the header map IS populated.
    assert_true(resp.headers.contains(String("X-Real")))
    # The trailers are NOT in it.
    assert_false(resp.headers.contains(String("Vary")))
    assert_false(resp.headers.contains(String("Content-Type")))

    var tok = CancellationToken.never()
    var out = List[UInt8]()
    var res = _drain(resp.body, reactor, tok, out)
    assert_equal(res.detail, String(""))
    assert_true(_bytes_eq(out, String("hello")))
    assert_equal(res.trailers_frames, 0)


def test_framing_relevant_trailers_are_discarded_not_acted_on() raises:
    """RFC 9112 §7.1.2 + RFC 9110 §6.5 — a trailer named `Transfer-Encoding`,
    `Content-Length`, `Host` or `Trailer` MUST be discarded, never merged and
    never acted on. This is the dangerous subset: acting on a
    `Content-Length` that arrives AFTER the body is a request-smuggling
    primitive, and acting on a trailer `Transfer-Encoding` re-frames a
    message that has already been framed.

    The assertion is "the framing the head established is the framing that
    held": the body is exactly the 5 bytes the chunked encoding delivered —
    NOT the 999 the trailer `Content-Length` claims — the stream ends
    cleanly, and none of the four names reaches the header map."""
    var url = Url.parse(String("http://127.0.0.1:8080/evil-trailers"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var script = _make_bytes(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "X-Real: yes\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "0\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Content-Length: 999\r\n"
        "Host: attacker.example\r\n"
        "Trailer: X-Whatever\r\n"
        "\r\n"
    ))
    var stream = ScriptedStream.from_read_script(script^)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var resp = client.send[PerCoreAsyncRuntime[NoopSink]](req^, reactor)

    assert_equal(Int(resp.status), 200)
    assert_true(resp.headers.contains(String("X-Real")))
    assert_false(resp.headers.contains(String("Content-Length")))
    assert_false(resp.headers.contains(String("Host")))
    assert_false(resp.headers.contains(String("Trailer")))
    # `Transfer-Encoding` IS a real header on this response; the assertion
    # that matters is that the trailer copy did not add a SECOND one.
    assert_equal(resp.headers.get_all(String("Transfer-Encoding")).__len__(), 1)

    var tok = CancellationToken.never()
    var out = List[UInt8]()
    var res = _drain(resp.body, reactor, tok, out)
    assert_equal(res.detail, String(""))
    assert_equal(out.__len__(), 5)
    assert_true(_bytes_eq(out, String("hello")))


def test_trailer_line_without_a_colon_is_rejected() raises:
    """A trailer section is `*( field-line CRLF )`; a line with no colon is
    not a field-line. Rejected as CHUNK_TRAILER_INVALID (kind 45) rather
    than skipped, because a skipped un-parseable line is how a smuggled
    body byte gets read as framing."""
    var out = List[UInt8]()
    var res = _drain_chunked_wire(
        _make_bytes(String("5\r\nhello\r\n0\r\nnot-a-field-line\r\n\r\n")),
        List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(res.detail.find(String("MALFORMED_CHUNKED")) >= 0)
    assert_true(res.detail.find(String("kind=45")) >= 0)


# =============================================================================
# §3 — A failure DURING the trailer section is an ERROR, never a clean end.
# =============================================================================


def test_read_error_in_trailer_section_is_an_error_not_a_clean_end() raises:
    """Go's `TestBodyReadBadTrailer`. Every body byte has been delivered and
    the 0-length chunk has been seen — the temptation is to call the body
    complete and swallow whatever happens next. It is not complete: the
    chunked message is not terminated until the trailer section's empty
    line, so a transport failure here is a TRUNCATED MESSAGE.

    The trap this pins is a caller that treats "I already have all the
    payload" as "I am done"."""
    # The payload and the 0-length chunk arrive as pre_body (exactly what
    # the HEAD parse leaves behind); the trailer section is left mid-line,
    # and the read that would have completed it fails with ECONNRESET.
    var stream = ScriptedStream.empty()
    stream.arm_error(Int64(104))  # ECONNRESET
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^,
        pre_body_bytes=_make_bytes(String("5\r\nhello\r\n0\r\nX-A: b")),
        max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var out = List[UInt8]()
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    var c1 = f1.take_data_chunk()
    var k = 0
    while k < c1.__len__():
        out.append(c1[k])
        k = k + 1
    assert_true(_bytes_eq(out, String("hello")))

    var res = _drain(body, reactor, tok, out)
    assert_true(res.detail.find(String("IO_ERROR")) >= 0)
    # And the payload was NOT re-delivered or extended by the failure.
    assert_true(_bytes_eq(out, String("hello")))


def test_eof_in_trailer_section_is_an_error_not_a_clean_end() raises:
    """The same shape with a peer CLOSE instead of an errno. All five
    payload bytes and the 0-length chunk arrived; the trailer section did
    not terminate. That is EOF_MID_RESPONSE, not End."""
    var out = List[UInt8]()
    var res = _drain_chunked_wire(
        _make_bytes(String("5\r\nhello\r\n0\r\nX-A: b\r\n")),
        List[UInt8](), 0, 1024 * 1024, out,
    )
    assert_true(res.detail.find(String("EOF_MID_RESPONSE")) >= 0)
    assert_true(_bytes_eq(out, String("hello")))


# =============================================================================
# §4 — Chunk extensions ON THE RESPONSE PATH.
# =============================================================================


def test_chunk_extensions_are_ignored_on_the_response_path() raises:
    """RFC 9112 §7.1.1 `chunk-ext`. Our only pre-existing coverage calls
    `decode_block` directly, so the caller that has to survive an extension
    (`RecvRingBody`, whose carry buffer now holds partial size lines) was
    reached by nothing.

    Cases, one per chunk of the same wire:
      * the hyper/Go canonical multi-extension line
        `;ilovew3;somuchlove=aretheseparametersfor;another=withvalue`
      * a quoted-string value containing escaped quotes and backslashes
      * BWS around the `;`
    All three are ignored; the payload is the concatenation and nothing
    else."""
    var wire = List[UInt8]()
    _append_str(
        wire,
        String(
            "5;ilovew3;somuchlove=aretheseparametersfor;another=withvalue"
            "\r\nhello\r\n"
        ),
    )
    _append_str(wire, String("5;a=\"b\\\"c\\\\d\"\r\nworld\r\n"))
    _append_str(wire, String("3 ; spaced = yes \r\n!!!\r\n"))
    _append_str(wire, String("0\r\n\r\n"))

    var out = List[UInt8]()
    var res = _drain_chunked_wire(
        List[UInt8](), wire^, 0, 1024 * 1024, out,
    )
    assert_equal(res.detail, String(""))
    assert_true(_bytes_eq(out, String("helloworld!!!")))


def test_chunk_extension_survives_a_read_boundary_inside_it() raises:
    """An extension makes the chunk-size line LONG, which makes it the most
    likely framing token for a read boundary to land inside. Swept at every
    read size 1..8."""
    var wire = List[UInt8]()
    _append_str(wire, String("5;ilovew3;somuchlove=are\r\nhello\r\n0\r\n\r\n"))
    var k = 1
    while k <= 8:
        var out = List[UInt8]()
        var res = _drain_chunked_wire(
            List[UInt8](), _slice_of(wire, 0, wire.__len__()), k,
            1024 * 1024, out,
        )
        assert_equal(res.detail, String(""))
        assert_true(_bytes_eq(out, String("hello")))
        k = k + 1


def test_chunk_size_line_length_cap_both_sides() raises:
    """`DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES` is 256, and the cap is applied to
    the LINE before `_parse_chunk_size_line` reads a single hex digit —
    which is the ordering that matters, because an unbounded line is an
    unbounded scan whatever the hex says.

    Both sides of the boundary: a 256-byte line is accepted, a 257-byte one
    is rejected. A one-sided limit test passes against a limit of zero."""
    # "5;" + 254 padding bytes == a 256-byte chunk-size line.
    var accept = List[UInt8]()
    _append_str(accept, String("5;"))
    var i = 0
    while i < 254:
        accept.append(UInt8(ord("a")))
        i = i + 1
    _append_str(accept, String("\r\nhello\r\n0\r\n\r\n"))
    var out_a = List[UInt8]()
    var res_a = _drain_chunked_wire(
        List[UInt8](), accept^, 0, 1024 * 1024, out_a,
    )
    assert_equal(res_a.detail, String(""))
    assert_true(_bytes_eq(out_a, String("hello")))

    # One byte more == 257 == rejected, as CHUNK_SIZE_INVALID (kind 43).
    var reject = List[UInt8]()
    _append_str(reject, String("5;"))
    var j = 0
    while j < 255:
        reject.append(UInt8(ord("a")))
        j = j + 1
    _append_str(reject, String("\r\nhello\r\n0\r\n\r\n"))
    var out_r = List[UInt8]()
    var res_r = _drain_chunked_wire(
        List[UInt8](), reject^, 0, 1024 * 1024, out_r,
    )
    assert_true(res_r.detail.find(String("MALFORMED_CHUNKED")) >= 0)
    assert_true(res_r.detail.find(String("kind=43")) >= 0)
    # Rejected BEFORE any payload was handed to the caller.
    assert_equal(out_r.__len__(), 0)


# =============================================================================
# §5 — THE BODY CEILING, which was implemented and asserted by nothing.
# =============================================================================


def test_body_ceiling_content_length_both_sides_of_the_boundary() raises:
    """`poll_frame`'s
    `_accum.__len__() > _max_body_bytes - _emitted_bytes` guard, on the
    Content-Length arm, at exactly the boundary.

    ⚠ BOTH SIDES OR IT PROVES NOTHING. A ceiling test that only shows the
    over-limit case rejected also passes against a ceiling of zero. 100
    bytes under a 100-byte ceiling must be DELIVERED; 101 must not."""
    # Accept: CL == ceiling.
    var body_100 = List[UInt8]()
    var i = 0
    while i < 100:
        body_100.append(UInt8(ord("x")))
        i = i + 1
    var s_a = ScriptedStream.from_read_script(body_100^)
    var b_a = RecvRingBody[ScriptedStream].new_content_length(
        s_a^, cl_total=100, pre_body_bytes=List[UInt8](),
    )
    b_a.set_max_body_bytes(100)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var out_a = List[UInt8]()
    var res_a = _drain(b_a, reactor, tok, out_a)
    assert_equal(res_a.detail, String(""))
    assert_equal(out_a.__len__(), 100)

    # Reject: CL == ceiling + 1.
    var body_101 = List[UInt8]()
    var j = 0
    while j < 101:
        body_101.append(UInt8(ord("x")))
        j = j + 1
    var s_r = ScriptedStream.from_read_script(body_101^)
    var b_r = RecvRingBody[ScriptedStream].new_content_length(
        s_r^, cl_total=101, pre_body_bytes=List[UInt8](),
    )
    b_r.set_max_body_bytes(100)
    var out_r = List[UInt8]()
    var res_r = _drain(b_r, reactor, tok, out_r)
    assert_equal(res_r.detail, String("BODY_TOO_LARGE"))
    assert_equal(out_r.__len__(), 0)


def test_body_ceiling_chunked_never_over_delivers_at_any_read_size() raises:
    """The chunked arm of the same ceiling, plus the invariant that makes it
    worth having: NO MORE THAN `max_body_bytes` BYTES EVER REACH THE CALLER.

    Swept across read sizes because the ceiling is checked per-poll against
    the accumulator, so the read cadence decides how much is in flight when
    it fires. A ceiling that holds at one read size and leaks at another is
    not a ceiling. The wire carries 200 payload bytes under a 100-byte
    ceiling."""
    var wire = List[UInt8]()
    _append_str(wire, String("64\r\n"))       # 0x64 == 100
    var i = 0
    while i < 100:
        wire.append(UInt8(ord("A")))
        i = i + 1
    _append_str(wire, String("\r\n64\r\n"))
    var j = 0
    while j < 100:
        wire.append(UInt8(ord("B")))
        j = j + 1
    _append_str(wire, String("\r\n0\r\n\r\n"))

    var reads = List[Int]()
    reads.append(1)
    reads.append(3)
    reads.append(64)
    reads.append(104)
    reads.append(0)  # unlimited
    var r = 0
    while r < reads.__len__():
        var out = List[UInt8]()
        var res = _drain_chunked_wire(
            List[UInt8](), _slice_of(wire, 0, wire.__len__()), reads[r],
            100, out,
        )
        assert_equal(res.detail, String("BODY_TOO_LARGE"))
        assert_true(out.__len__() <= 100)
        r = r + 1


def test_body_ceiling_chunked_accepts_exactly_the_ceiling() raises:
    """The accept side of the chunked ceiling: 100 payload bytes under a
    100-byte ceiling are delivered in full and the stream ends cleanly."""
    var wire = List[UInt8]()
    _append_str(wire, String("64\r\n"))
    var i = 0
    while i < 100:
        wire.append(UInt8(ord("A")))
        i = i + 1
    _append_str(wire, String("\r\n0\r\n\r\n"))
    var out = List[UInt8]()
    var res = _drain_chunked_wire(List[UInt8](), wire^, 0, 100, out)
    assert_equal(res.detail, String(""))
    assert_equal(out.__len__(), 100)


# =============================================================================
# §6 — Cancellation mid-drain.
# =============================================================================


def test_cancel_between_polls_surfaces_cancelled_and_leaves_body_open() raises:
    """The two pre-existing tests that name CANCELLED assert the error
    ENUM; neither reaches the mid-drain path where a real caller cancels —
    a request deadline firing while bytes are still arriving.

    Three things are asserted, and the third is the one that matters: the
    body is NOT marked done. `_done` is `take_stream`'s precondition, so a
    cancelled body that marked itself done would hand a half-consumed
    stream back to the keepalive-reuse cache, and the next request on that
    connection would read this response's tail as its own head."""
    var wire = List[UInt8]()
    var i = 0
    while i < 20:
        wire.append(UInt8(ord("A") + (i % 26)))
        i = i + 1
    var stream = ScriptedStream.from_read_script(wire^)
    stream.set_max_read_per_call(5)
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, cl_total=20, pre_body_bytes=List[UInt8](),
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.new()

    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    assert_equal(f1.chunk_len(), 5)

    tok.cancel(String("request deadline"))

    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_error())
    assert_equal(f2.error_detail(), String("CANCELLED"))
    # Idempotent: a cancelled body keeps saying CANCELLED, and NEVER
    # reports End — End would tell the drain loop the body completed.
    var f3 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f3.is_error())
    assert_equal(f3.error_detail(), String("CANCELLED"))
    assert_false(body.is_done())


# =============================================================================
# §7 — THE MANDATORY FALSE-POSITIVE GUARD for any extension/overhead limit.
# =============================================================================


def test_byte_at_a_time_chunking_is_not_rejected() raises:
    """Go's `TestChunkReaderByteAtATime`, and the guard WITHOUT WHICH a DoS
    fix for chunk-extension overhead goes green while breaking every
    legitimate byte-at-a-time producer.

    1 MiB of wire as ~175k single-byte chunks and NO extensions: 6 wire
    bytes per payload byte, an 83% overhead ratio. A naive
    overhead-ratio detector rejects this; a correct one (which charges
    EXTENSION bytes, not framing bytes) does not. It must stay accepted."""
    var n_chunks = 175_000
    var wire = List[UInt8]()
    var i = 0
    while i < n_chunks:
        wire.append(UInt8(ord("1")))
        wire.append(UInt8(0x0D))
        wire.append(UInt8(0x0A))
        wire.append(UInt8(ord("X")))
        wire.append(UInt8(0x0D))
        wire.append(UInt8(0x0A))
        i = i + 1
    _append_str(wire, String("0\r\n\r\n"))

    var out = List[UInt8]()
    var res = _drain_chunked_wire(
        List[UInt8](), wire^, 0, 8 * 1024 * 1024, out,
    )
    assert_equal(res.detail, String(""))
    assert_equal(out.__len__(), n_chunks)


def main() raises:
    test_real_trailer_section_payload_exact_and_discarded()
    test_real_trailer_section_split_across_every_offset()
    test_real_trailer_section_every_read_size()
    test_trailers_are_not_merged_into_the_response_header_map()
    test_framing_relevant_trailers_are_discarded_not_acted_on()
    test_trailer_line_without_a_colon_is_rejected()
    test_read_error_in_trailer_section_is_an_error_not_a_clean_end()
    test_eof_in_trailer_section_is_an_error_not_a_clean_end()
    test_chunk_extensions_are_ignored_on_the_response_path()
    test_chunk_extension_survives_a_read_boundary_inside_it()
    test_chunk_size_line_length_cap_both_sides()
    test_body_ceiling_content_length_both_sides_of_the_boundary()
    test_body_ceiling_chunked_never_over_delivers_at_any_read_size()
    test_body_ceiling_chunked_accepts_exactly_the_ceiling()
    test_cancel_between_polls_surfaces_cancelled_and_leaves_body_open()
    test_byte_at_a_time_chunking_is_not_rejected()
    print("PASS: h1 response trailers, extensions and ceilings")
