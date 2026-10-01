# =============================================================================
# src/komira_http/tests/test_recv_ring_chunked_split_inside_framing.mojo
# =============================================================================
# ⛔ THE FALSIFIER FOR "A CHUNKED RESPONSE SURVIVES A READ BOUNDARY THAT LANDS
#    INSIDE A FRAMING TOKEN".
#
# THE DEFECT THIS PINS. `decode_block` (codec/h1/chunked.mojo) is an
# INCREMENTAL decoder with an explicit caller contract, stated on its own
# docstring: it returns `consumed` = "bytes from the input that the decoder
# processed (caller should advance its buffer pointer by this)", and on
# NEED_MORE the caller "should call again with more bytes appended to `src`".
# The decoder carries NO buffer of its own — its whole state is
# (state, current_chunk_remaining, bytes_emitted, err) — so ANY byte it
# declines to consume must be re-presented by the caller or it is GONE.
#
# `RecvRingBody._consume_scratch` violated that contract: it drove
# `decode_block` over a FRESH per-poll scratch buffer and threw the result
# away (`var _dec_res = decode_block(...)` / `return`). A `try_read` that
# happened to end INSIDE a framing token — a chunk-size line, the CRLF that
# terminates chunk data, a trailer line — silently DROPPED that partial
# token. The decoder then resumed mid-token, mis-framed, and never reached
# the 0-length chunk; when the peer eventually closed, `_finalize_on_eof`
# reported the observed symptom:
#
#     HttpError[EOF_MID_RESPONSE: chunked body unterminated]
#
# A read boundary inside chunk DATA was always safe (CHUNK_DATA consumes
# everything available), which is exactly why every pre-existing chunked
# RecvRingBody test passed: each of them splits the wire at a CHUNK
# boundary, never inside a framing token.
#
# ⚠ THE SWEEP IS THE POINT, NOT A CONVENIENCE. A hand-picked split offset
# pins one arithmetic accident; sweeping EVERY read size over a wire that
# carries a chunk-extension and a trailer pins the CLASS, and stays true
# when someone changes the scratch size or the decoder's internal cadence.
#
# No UnsafePointer crosses a boundary here; no wildcard origin.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.response_body import RecvRingBody
from komira_http.transport.scripted import ScriptedStream


# A well-formed chunked body that exercises, in one wire:
#   * a plain chunk-size line                     ("4\r\n")
#   * a chunk-size line carrying a chunk-EXTENSION ("6;ext=v\r\n")
#   * the CRLF that terminates chunk data
#   * the 0-length last chunk
#   * a non-empty TRAILER section
comptime _WIRE = "4\r\nAAAA\r\n6;ext=v\r\nBBBBBB\r\n0\r\nX-Trailer: v\r\n\r\n"
comptime _PAYLOAD = "AAAABBBBBB"


def _make_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


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


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _drain(
    mut body: RecvRingBody[ScriptedStream],
    mut reactor: Reactor[NoopSink],
    ref tok: CancellationToken,
    mut out: List[UInt8],
) raises -> String:
    """Drive poll_frame to End, concatenating Data frames into `out`.
    Returns "" on a clean End, or the Error frame's detail string. Never
    raises on a body-level error — the detail is the assertion's subject."""
    var iter = 0
    while True:
        iter = iter + 1
        if iter > 200000:
            return String("ITER_CAP")
        var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
        if f.is_end():
            return String("")
        if f.is_error():
            return f.error_detail()
        if f.is_data():
            var chunk = f.take_data_chunk()
            var k = 0
            while k < chunk.__len__():
                out.append(chunk[k])
                k = k + 1
    return String("")


# =============================================================================
# Test 1 — EVERY read size. The production repro.
# =============================================================================


def test_chunked_survives_every_wire_read_size() raises:
    """A well-formed chunked response must decode identically no matter
    where `try_read` chooses to stop. Sweeping max_read_per_call from 1 to
    len(wire) walks the read boundary across every byte offset of the wire,
    so every framing token — size line, extension, data CRLF, last chunk,
    trailer — is split at least once.

    ⛔ BEFORE THE FIX this failed at k=1 and at every k that lands a read
    boundary inside a framing token, with the observed symptom verbatim:
    "EOF_MID_RESPONSE: chunked body unterminated"."""
    var wire_len = _make_bytes(String(_WIRE)).__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var k = 1
    while k <= wire_len:
        var stream = ScriptedStream.from_read_script(_make_bytes(String(_WIRE)))
        stream.set_max_read_per_call(k)
        var body = RecvRingBody[ScriptedStream].new_chunked(
            stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        assert_equal(
            detail,
            String(""),
            String("read size k=") + String(k) + String(" drained with error"),
        )
        assert_true(
            _bytes_eq(got, String(_PAYLOAD)),
            String("read size k=") + String(k) + String(" wrong payload"),
        )
        k = k + 1


# =============================================================================
# Test 2 — EVERY head-parse handoff offset (the pre_body seam).
# =============================================================================


def test_chunked_survives_every_pre_body_split() raises:
    """`new_chunked` seeds `pre_body_bytes` — whatever the HEAD parse left
    in recv_buf past the header terminator — through the same decoder. That
    handoff offset is set by where the HEAD read happened to stop, so it is
    just as arbitrary as a body read boundary, and it lands inside a framing
    token just as often. Sweep every split of the wire into
    (pre_body, wire-remainder)."""
    var full = _make_bytes(String(_WIRE))
    var wire_len = full.__len__()
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var j = 0
    while j <= wire_len:
        var pre = List[UInt8]()
        var rest = List[UInt8]()
        var i = 0
        while i < wire_len:
            if i < j:
                pre.append(full[i])
            else:
                rest.append(full[i])
            i = i + 1
        var stream = ScriptedStream.from_read_script(rest^)
        var body = RecvRingBody[ScriptedStream].new_chunked(
            stream^, pre_body_bytes=pre^, max_body_bytes=1024 * 1024,
        )
        var got = List[UInt8]()
        var detail = _drain(body, reactor, tok, got)
        assert_equal(
            detail,
            String(""),
            String("pre_body split j=") + String(j) + String(" errored"),
        )
        assert_true(
            _bytes_eq(got, String(_PAYLOAD)),
            String("pre_body split j=") + String(j) + String(" wrong payload"),
        )
        j = j + 1


# =============================================================================
# Test 3 — a MALFORMED chunked body must fail FAST and LOUD, not spin.
# =============================================================================


def test_chunked_parse_error_is_surfaced_not_swallowed() raises:
    """⛔ THE ~300s HALF OF THE OBSERVED INCIDENT. `_consume_scratch` discarded
    `decode_block`'s outcome, so a CHUNKED_RES_ERROR left the decoder parked
    in _DECODE_STATE_ERROR with nothing reporting it: `is_done()` stays
    False, `_accum` is empty, and poll_frame fell through to
    `BodyFrame.pending()`. The drain then spun-and-parked against a decoder
    that could never make progress until the peer closed or the enclosing
    request deadline fired — which is why an EOF observable at once cost a
    multi-minute wall.

    A decoder that has entered ERROR must surface an Error frame on the
    poll that produced it. Asserting on the FIRST poll is the load-bearing
    half: a body that reports the error only after draining to EOF is the
    exact behaviour this pins against."""
    # "zz" is not a hex chunk size -> PARSE_ERR_CHUNK_SIZE_INVALID.
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("zz\r\nAAAA\r\n0\r\n\r\n"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        f1.is_error(),
        String(
            "first poll over a malformed chunk-size must be an Error frame"
        ),
    )


def test_chunked_parse_error_in_pre_body_is_surfaced() raises:
    """Same contract on the pre_body seam: a malformed chunked prefix
    handed over by the HEAD parse must surface on the first poll, without a
    wire read."""
    var stream = ScriptedStream.empty()
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^,
        pre_body_bytes=_make_bytes(String("zz\r\n")),
        max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        f1.is_error(),
        String("malformed pre_body must surface an Error frame"),
    )


# =============================================================================
# Test 4 — a GENUINELY truncated body still reports truncation.
# =============================================================================


def test_chunked_genuine_truncation_still_reports_unterminated() raises:
    """⚠ THE ANTI-OVER-FIT ASSERTION. The fix must not turn "the peer really
    did cut us off mid-body" into a success. A wire that ends before the
    0-length chunk must still report EOF_MID_RESPONSE — that error is
    CORRECT there, and it is the one the observed log was mis-attributing."""
    var stream = ScriptedStream.from_read_script(
        _make_bytes(String("4\r\nAAAA\r\n6\r\nBBB"))
    )
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, pre_body_bytes=List[UInt8](), max_body_bytes=1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var got = List[UInt8]()
    var detail = _drain(body, reactor, tok, got)
    assert_true(
        detail.startswith(String("EOF_MID_RESPONSE")),
        String("truncated body must still report EOF_MID_RESPONSE, got: ")
        + detail,
    )


def main() raises:
    test_chunked_survives_every_wire_read_size()
    test_chunked_survives_every_pre_body_split()
    test_chunked_parse_error_is_surfaced_not_swallowed()
    test_chunked_parse_error_in_pre_body_is_surfaced()
    test_chunked_genuine_truncation_still_reports_unterminated()
    print("PASS recv-ring chunked split-inside-framing tests")
