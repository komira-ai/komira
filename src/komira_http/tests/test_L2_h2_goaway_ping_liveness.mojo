"""L2 h2 client — GOAWAY disposition, PING conformance, and CONNECTION LIVENESS.

THE QUESTION THIS FILE ASKS: *how does an h2 connection that is UP but DEAD get
noticed, and when it is torn down, does the caller learn WHY?*

The failure it guards against: the connection stays open, the peer says
nothing, and every request takes minutes before 504-ing at the platform's
request ceiling. Without a liveness probe the only bound that fires is the 120s
wall clock in `drive_h2_streams_to_completion` — a budget, not a diagnosis. Every mechanism
below is one another h2 client uses to turn that silent multi-minute stall into
a fast, ATTRIBUTABLE failure:

  * RFC 9113 §6.8 GOAWAY `Last-Stream-ID` — the retryability discriminator, and
    the `Additional Debug Data` that carries the server's own explanation.
  * RFC 9113 §6.7 PING — the echo contract, and the keepalive/lost-ping probe
    that is the standard answer to "up but dead" (Go
    `TestTransportCloseAfterLostPing`, `TestTransportConnBecomesUnresponsive`).
  * RFC 9113 §6.5.2 SETTINGS validation — the values that, unrejected, make a
    connection un-driveable.
  * ITERATION-BOUNDED failure. The pre-existing h2 EOF test asserts only THAT a
    raise happens; the half that actually hurt in production is HOW LONG it
    took. Every drive here is given an explicit `max_iterations` and asserts
    the typed error rather than the driver's spin/cap give-up.

Reference bar (what other clients test that we did not):
  Go x/net/http2:  TestTransportUsesGoAwayDebugError_RoundTrip / _Body,
                   TestTransportDoNotHangOnZeroMaxFrameSize,
                   TestTransportCloseAfterLostPing,
                   TestTransportConnBecomesUnresponsive
  hyper (Rust):    recv_goaway_with_higher_last_processed_id
  nghttp2:         PING echo identity, SETTINGS bounds
"""

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.h2_client import (
    H2_GOAWAY_MAYBE_PROCESSED_TOKEN,
    H2_GOAWAY_UNPROCESSED_TOKEN,
    H2_RETRYABLE_TRANSPORT_TOKEN,
    H2ClientConnectionState,
    apply_peer_settings_and_ack,
    drive_h2_streams_to_completion,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    is_h2_goaway_unprocessed,
    is_h2_retryable_transport,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http.client.h2_pool import (
    H2ClientPool,
    H2PooledConn,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.pool import (
    ClientConn,
    PoolKey,
    VERIFY_PEER,
)
from komira_http.codec.h2.continuation_splitter import (
    split_header_block_into_frames,
)
from komira_http.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_PING,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    SETTINGS_ENABLE_PUSH,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_goaway_frame,
    encode_headers_frame,
    encode_ping_frame,
    encode_rst_stream_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import (
    HpackEncoder,
    HpackHeader,
)
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedStream


# -----------------------------------------------------------------------------
# Helpers — same shape as `test_L2_h2_client_driver.mojo`'s.
# -----------------------------------------------------------------------------


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _empty_settings(mut out: List[UInt8]):
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)


def _bytes_of(var s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _string_of(ref b: List[UInt8]) -> String:
    var s = String()
    var i = 0
    while i < len(b):
        s += chr(Int(b[i]))
        i = i + 1
    return s^


def _append_full_response(
    mut hpack: HpackEncoder,
    sid: UInt32,
    var body: String,
    mut out: List[UInt8],
) raises:
    """HEADERS(:status 200, END_HEADERS) + DATA(body, END_STREAM) for `sid`."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=False, end_headers=True, out=out,
    )
    var body_bytes = _bytes_of(body^)
    encode_data_frame(sid, body_bytes^, end_stream=True, out=out)


def _open_stream(
    mut h2: H2ClientConnectionState, var path: String,
) raises -> UInt32:
    """Allocate + register + encode request HEADERS for one GET."""
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid, String("GET"), String("https"),
        String("example.com"), path^, hdrs^, end_stream=True,
    )
    return sid


def _drive_and_capture(
    mut h2: H2ClientConnectionState,
    var script: List[UInt8],
    var awaited: List[UInt32],
    max_iters: Int,
) raises -> String:
    """Run the PRODUCTION driver over a scripted peer. Returns the raise
    message, or "" if the driver returned normally."""
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    var reactor = _make_reactor()
    var msg = String("")
    try:
        drive_h2_streams_to_completion[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](h2, stream, reactor, awaited^, max_iterations=max_iters)
    except e:
        msg = String(e)
    _ = stream^
    _ = reactor^
    return msg^


def _assert_not_a_spin_giveup(ref msg: String, ref what: String) raises:
    """⭐ THE ITERATION BOUND. A driver that discovers a condition the PEER
    ALREADY TOLD IT by exhausting a budget has not diagnosed anything — it has
    waited. Both of the driver's budget give-ups carry `parks=`; neither of its
    typed transport raises does (a property `test_L2_h2_over_tls_abrupt_close
    _no_spin._assert_did_not_spin` already relies on). So this is the same
    falsifier, applied to the GOAWAY / EOF / liveness paths."""
    if String("parks=") in msg:
        raise Error(
            what
            + ": the driver burned an iteration/wall budget instead of acting"
            " on what the peer had already said. THIS IS THE 250-300s SHAPE."
            " Got: " + msg
        )
    if String("iteration cap exceeded") in msg:
        raise Error(what + ": hit the iteration cap. Got: " + msg)
    if String("LIVELOCK") in msg:
        raise Error(what + ": gave up as LIVELOCK. Got: " + msg)


def _count_frames_of_kind(ref buf: List[UInt8], kind: UInt8) raises -> Int:
    """Decode `buf` as a frame stream (skipping a leading client preface if
    present) and count frames of `kind`."""
    var off = 0
    # The client preface is the 24-byte magic; skip it if present.
    if len(buf) >= 24 and buf[0] == UInt8(0x50) and buf[1] == UInt8(0x52):
        off = 24
    var n = 0
    while off < len(buf):
        var res = decode_frame(Span(buf)[off:], 16777215)
        if res.status != FRAME_DECODE_OK:
            break
        if res.frame.header.kind == kind:
            n = n + 1
        off = off + res.consumed
    return n


# =============================================================================
# §1 — GOAWAY: the retryability discriminator (RFC 9113 §6.8)
# =============================================================================


def test_goaway_splits_processed_streams_from_unprocessed_ones() raises:
    """RFC 9113 §6.8/§8.7: streams AT-OR-BELOW `Last-Stream-ID` may still
    complete; streams ABOVE it were definitively NOT processed and are safe to
    re-issue on a NEW connection even for a non-idempotent verb.

    The fixture is the real shape: five streams open, the server answers three,
    then GOAWAY(last=5, NO_ERROR). The point is that BOTH halves survive — the
    answered work is not thrown away, and the un-answered work is reported with
    the machine-readable not-processed token rather than as a generic failure.
    """
    print("  test_goaway_splits_processed_streams_from_unprocessed_ones...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var s1 = _open_stream(h2, String("/1"))
    var s3 = _open_stream(h2, String("/3"))
    var s5 = _open_stream(h2, String("/5"))
    var s7 = _open_stream(h2, String("/7"))
    var s9 = _open_stream(h2, String("/9"))

    var script = List[UInt8]()
    _empty_settings(script)
    var hpack = HpackEncoder(max_table_size=4096)
    _append_full_response(hpack, s1, String("one"), script)
    _append_full_response(hpack, s3, String("three"), script)
    _append_full_response(hpack, s5, String("five"), script)
    var debug = List[UInt8]()
    encode_goaway_frame(s5, H2_ERR_NO_ERROR, debug^, script)

    var awaited = List[UInt32]()
    awaited.append(s1)
    awaited.append(s3)
    awaited.append(s5)
    awaited.append(s7)
    awaited.append(s9)
    var msg = _drive_and_capture(h2, script^, awaited^, 500)

    if len(msg.as_bytes()) == 0:
        raise Error(
            "expected the driver to raise for stream " + String(Int(s7))
            + " > last_stream_id " + String(Int(s5))
        )
    _assert_not_a_spin_giveup(msg, String("GOAWAY above Last-Stream-ID"))
    if not is_h2_goaway_unprocessed(msg):
        raise Error(
            "★ RFC 9113 §8.7's not-processed guarantee was LOST. A stream"
            " above Last-Stream-ID is the one class that is safe to re-issue"
            " for ANY verb, and `is_h2_goaway_unprocessed` is the only"
            " sanctioned test for it. Got: " + msg
        )
    if not (String("stream " + String(Int(s7))) in msg):
        raise Error(
            "the raise must NAME the first unprocessed stream ("
            + String(Int(s7)) + "); got: " + msg
        )

    # The ANSWERED half must survive: the peer did that work, and a GOAWAY on a
    # later stream may not erase it.
    var r1 = extract_response_for_stream(h2, s1)
    if Int(r1[0]) != 200:
        raise Error("stream <= Last-Stream-ID lost its status")
    var b1 = List[UInt8]()
    swap(b1, r1[2])
    if _string_of(b1) != String("one"):
        raise Error("stream <= Last-Stream-ID lost its body")
    var r5 = extract_response_for_stream(h2, s5)
    var b5 = List[UInt8]()
    swap(b5, r5[2])
    if _string_of(b5) != String("five"):
        raise Error("the stream AT Last-Stream-ID lost its body")
    print("    OK — <=L complete; >L raises with the not-processed token")


def test_goaway_error_code_reaches_the_caller() raises:
    """★ A GOAWAY's ERROR CODE MUST BE DISTINGUISHABLE IN WHAT THE CALLER SEES.

    `mark_goaway_received` records `goaway_error_code`, and the driver's GOAWAY
    raise never mentions it — so GOAWAY(NO_ERROR) (a routine graceful
    shutdown / max-connection-age recycle) and GOAWAY(ENHANCE_YOUR_CALM) (the
    peer says WE are the problem) produce a BYTE-IDENTICAL error. Those two
    have opposite remedies: one is "re-dial, nothing is wrong", the other is
    "stop doing what you are doing". An operator reading the logs
    could not tell them apart.

    Asserted as a DISCRIMINATION, not a substring: drive the identical fixture
    twice, changing only the GOAWAY error code, and require the two messages to
    differ. That cannot be satisfied by accident.
    """
    print("  test_goaway_error_code_reaches_the_caller...")

    def _one(code: UInt32) raises -> String:
        var h2 = H2ClientConnectionState()
        queue_client_preface_and_settings(h2)
        var sid = _open_stream(h2, String("/"))
        var script = List[UInt8]()
        _empty_settings(script)
        var debug = List[UInt8]()
        encode_goaway_frame(UInt32(0), code, debug^, script)
        var awaited = List[UInt32]()
        awaited.append(sid)
        return _drive_and_capture(h2, script^, awaited^, 200)

    var m_no_error = _one(H2_ERR_NO_ERROR)
    var m_calm = _one(H2_ERR_ENHANCE_YOUR_CALM)
    if len(m_no_error.as_bytes()) == 0 or len(m_calm.as_bytes()) == 0:
        raise Error("expected both GOAWAY fixtures to raise")
    _assert_not_a_spin_giveup(m_no_error, String("GOAWAY(NO_ERROR)"))
    _assert_not_a_spin_giveup(m_calm, String("GOAWAY(ENHANCE_YOUR_CALM)"))
    if m_no_error == m_calm:
        raise Error(
            "★ THE GOAWAY ERROR CODE IS DROPPED. GOAWAY(NO_ERROR) and"
            " GOAWAY(ENHANCE_YOUR_CALM) produced the SAME error text, so the"
            " caller cannot tell a routine graceful shutdown from the peer"
            " telling us to back off. Both said: " + m_no_error
        )
    print("    OK — the GOAWAY error code discriminates the raise")


def test_goaway_debug_data_reaches_the_caller() raises:
    """★ GOAWAY `Additional Debug Data` IS THE SERVER'S OWN EXPLANATION, AND IT
    IS DROPPED ON THE FLOOR.

    `frame.mojo` decodes the bytes after the 8-byte fixed part into
    `frame.payload` — and `process_received_frames`' GOAWAY arm calls
    `mark_goaway_received(last_stream_id, error_code)`, which takes two
    arguments. The payload is discarded with the `Frame`.

    That is precisely the diagnostic that shortens an investigation: real
    servers put things like "max_age", "too_many_streams", or a request id in
    there. Go surfaces it (`TestTransportUsesGoAwayDebugError_RoundTrip` and
    `_Body` assert `GoAwayError.DebugData` reaches the caller of RoundTrip).
    """
    print("  test_goaway_debug_data_reaches_the_caller...")

    var explanation = String("server_shutting_down: max_connection_age")
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/"))
    var script = List[UInt8]()
    _empty_settings(script)
    var debug = _bytes_of(explanation)
    encode_goaway_frame(UInt32(0), H2_ERR_NO_ERROR, debug^, script)
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = _drive_and_capture(h2, script^, awaited^, 200)

    if len(msg.as_bytes()) == 0:
        raise Error("expected the driver to raise on GOAWAY(last=0)")
    _assert_not_a_spin_giveup(msg, String("GOAWAY with debug data"))
    if not (explanation in msg):
        raise Error(
            "★ THE SERVER'S OWN EXPLANATION NEVER REACHES THE CALLER. The"
            " GOAWAY carried debug data '" + explanation + "' and the error"
            " the caller sees is: " + msg
        )
    print("    OK — GOAWAY debug data is surfaced to the caller")


def test_goaway_last_stream_id_may_only_shrink() raises:
    """★ A SECOND GOAWAY MUST NOT WIDEN THE PROCESSED SET (hyper
    `recv_goaway_with_higher_last_processed_id`).

    RFC 9113 §6.8: "An endpoint MUST NOT increase the value they send in the
    last stream identifier, since the peers might already have retried
    unprocessed requests on another connection."

    `mark_goaway_received` assigns `goaway_last_stream_id` unconditionally, so
    a peer that sends GOAWAY(last=1) and then GOAWAY(last=9) silently converts
    stream 5 from "definitively not processed, safe to re-issue" into "may have
    been processed". A client that had already re-issued stream 5 on a fresh
    connection is now told, retroactively, that it may have double-executed it.
    An increase is the one direction the RFC forbids.
    """
    print("  test_goaway_last_stream_id_may_only_shrink...")

    var h2 = H2ClientConnectionState()
    var wire = List[UInt8]()
    var d1 = List[UInt8]()
    encode_goaway_frame(UInt32(1), H2_ERR_NO_ERROR, d1^, wire)
    var d2 = List[UInt8]()
    encode_goaway_frame(UInt32(9), H2_ERR_NO_ERROR, d2^, wire)
    h2.append_recv_bytes(Span(wire))
    _ = process_received_frames(h2)

    if not h2.is_goaway_received():
        raise Error("GOAWAY flag should be set")
    if h2.goaway_last_stream_id != UInt32(1):
        raise Error(
            "★ A SECOND GOAWAY WIDENED THE PROCESSED SET. First GOAWAY said"
            " last_stream_id=1 (so stream 5 was definitively NOT processed and"
            " safe to re-issue); the second said 9 and was accepted, so"
            " last_stream_id is now "
            + String(Int(h2.goaway_last_stream_id))
            + ". RFC 9113 §6.8 forbids an INCREASE precisely because the peer"
            " may already have retried those streams elsewhere."
        )
    print("    OK — a higher Last-Stream-ID is refused; the set only shrinks")


def test_goaway_last_stream_id_shrinking_is_honoured() raises:
    """The LEGAL second GOAWAY — the two-frame graceful shutdown every major
    server uses: GOAWAY(2^31-1, NO_ERROR) to announce "draining", then a final
    GOAWAY naming the real last processed stream. The second value must WIN,
    because it is smaller."""
    print("  test_goaway_last_stream_id_shrinking_is_honoured...")

    var h2 = H2ClientConnectionState()
    var wire = List[UInt8]()
    var d1 = List[UInt8]()
    encode_goaway_frame(UInt32(0x7fffffff), H2_ERR_NO_ERROR, d1^, wire)
    var d2 = List[UInt8]()
    encode_goaway_frame(UInt32(3), H2_ERR_NO_ERROR, d2^, wire)
    h2.append_recv_bytes(Span(wire))
    _ = process_received_frames(h2)
    if h2.goaway_last_stream_id != UInt32(3):
        raise Error(
            "the final (smaller) Last-Stream-ID must win; got "
            + String(Int(h2.goaway_last_stream_id))
        )
    print("    OK — graceful two-GOAWAY shutdown narrows correctly")


def test_goaway_unknown_error_code_is_not_special_cased() raises:
    """An UNKNOWN GOAWAY error code (0xFF — not in the RFC 9113 §7 registry)
    must be recorded and reported like any other; nothing may crash and no
    special path may trigger."""
    print("  test_goaway_unknown_error_code_is_not_special_cased...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/"))
    var script = List[UInt8]()
    _empty_settings(script)
    var debug = List[UInt8]()
    encode_goaway_frame(UInt32(0), UInt32(0xFF), debug^, script)
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = _drive_and_capture(h2, script^, awaited^, 200)
    if len(msg.as_bytes()) == 0:
        raise Error("expected a raise for stream above Last-Stream-ID")
    _assert_not_a_spin_giveup(msg, String("GOAWAY(unknown code)"))
    if not is_h2_goaway_unprocessed(msg):
        raise Error(
            "an unknown error code must not change the Last-Stream-ID"
            " disposition; got: " + msg
        )
    if h2.goaway_error_code != UInt32(0xFF):
        raise Error("the unknown error code must be recorded verbatim")
    print("    OK — unknown GOAWAY error code is inert")


def test_goaway_then_server_close_is_bounded_and_says_maybe_processed() raises:
    """The OTHER half of the discriminator, iteration-bounded. A stream
    AT-OR-BELOW Last-Stream-ID whose connection then closes carries NO
    not-processed guarantee, so it must be reported with the maybe-processed
    token — and it must be reported in a handful of driver trips, not by
    exhausting a budget. The failure is never about the error
    being absent; it is about how long it takes to arrive."""
    print("  test_goaway_then_server_close_is_bounded_and_says_maybe...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/"))
    var script = List[UInt8]()
    _empty_settings(script)
    var debug = List[UInt8]()
    # last_stream_id == our stream => AT-OR-BELOW => maybe processed.
    encode_goaway_frame(sid, H2_ERR_NO_ERROR, debug^, script)
    var awaited = List[UInt32]()
    awaited.append(sid)
    # ⭐ 32 iterations. The peer told us everything on its first two frames.
    var msg = _drive_and_capture(h2, script^, awaited^, 32)
    if len(msg.as_bytes()) == 0:
        raise Error("expected EOF_MID_RESPONSE after GOAWAY + close")
    _assert_not_a_spin_giveup(msg, String("GOAWAY at-or-below then close"))
    if not (String("EOF_MID_RESPONSE") in msg):
        raise Error("expected EOF_MID_RESPONSE; got " + msg)
    if not (H2_GOAWAY_MAYBE_PROCESSED_TOKEN in msg):
        raise Error(
            "a stream AT-OR-BELOW Last-Stream-ID must carry the"
            " maybe-processed token; got " + msg
        )
    if is_h2_goaway_unprocessed(msg):
        raise Error(
            "⛔ the at-or-below class must NEVER read as safely retryable —"
            " auto-retrying it duplicates a non-idempotent verb. Got: " + msg
        )
    print("    OK — bounded, and classified NOT auto-retryable")


def test_peer_debug_data_cannot_forge_a_retry_classifier_token() raises:
    """⛔ A PEER MUST NOT BE ABLE TO SPELL OUR RETRY TOKENS INTO OUR OWN ERROR.

    `test_goaway_then_server_close_is_bounded_and_says_maybe_processed` already
    pins that the AT-OR-BELOW class "must NEVER read as safely retryable". It
    sends EMPTY Additional Debug Data. This case sends the token itself.

    THE SURFACE. Both retry predicates in this repo are SUBSTRING matches on
    the error MESSAGE — `is_h2_goaway_unprocessed` on
    `H2_GOAWAY_UNPROCESSED_TOKEN`, `is_h2_retryable_transport` on
    `H2_RETRYABLE_TRANSPORT_TOKEN` — and `komira_grpc.client` re-issues the
    request on either, for ANY verb, idempotent or not. A substring predicate
    cannot tell our token from a peer's copy of it. So the moment GOAWAY debug
    data (RFC 9113 §6.8, peer-controlled, unbounded, arbitrary bytes) is
    rendered verbatim into that message, a server can promote its own
    "MUST NOT be auto-retried" teardown into an auto-retry and have a
    non-idempotent request executed twice — the same harm the last-stream-id
    clamp exists to prevent, arriving through the error string instead.

    It also falsifies the guarantee `is_h2_goaway_unprocessed` documents in so
    many words: "a message can only carry the token by having made the
    comparison."

    ⚠ THIS IS NOT A TEST THAT THE DIAGNOSTIC WAS DELETED. `goaway_debug=` must
    still be there — the fix is a rendering allowlist, and removing the field
    would pass a weaker version of this case while losing case [2]'s finding.
    """
    print("  test_peer_debug_data_cannot_forge_a_retry_classifier_token...")

    def _drive_with_debug(var payload: String) raises -> String:
        var h2 = H2ClientConnectionState()
        queue_client_preface_and_settings(h2)
        var sid = _open_stream(h2, String("/"))
        var script = List[UInt8]()
        _empty_settings(script)
        # last_stream_id == our stream => AT-OR-BELOW => maybe-processed, the
        # class whose own raise says it MUST NOT be auto-retried.
        var debug = _bytes_of(payload^)
        encode_goaway_frame(sid, H2_ERR_NO_ERROR, debug^, script)
        var awaited = List[UInt32]()
        awaited.append(sid)
        return _drive_and_capture(h2, script^, awaited^, 32)

    # --- vector 1: forge the not-processed proof -------------------------
    var forged_goaway = _drive_with_debug(H2_GOAWAY_UNPROCESSED_TOKEN)
    if len(forged_goaway.as_bytes()) == 0:
        raise Error("expected EOF_MID_RESPONSE after GOAWAY + close")
    _assert_not_a_spin_giveup(forged_goaway, String("forged GOAWAY debug"))
    if not (H2_GOAWAY_MAYBE_PROCESSED_TOKEN in forged_goaway):
        raise Error(
            "fixture is wrong — expected the at-or-below class; got: "
            + forged_goaway
        )
    if not (String("goaway_debug=") in forged_goaway):
        raise Error(
            "⛔ the peer's debug data must be NEUTRALIZED, not DELETED —"
            " `goaway_debug=` is gone, which silently reverts the finding"
            " that the server's own explanation must reach the caller. Got: "
            + forged_goaway
        )
    if is_h2_goaway_unprocessed(forged_goaway):
        raise Error(
            "⛔ A PEER FORGED THE NOT-PROCESSED TOKEN. The GOAWAY put '"
            + H2_GOAWAY_UNPROCESSED_TOKEN + "' in its Additional Debug Data"
            " and the at-or-below error now reads as SAFELY RETRYABLE, so"
            " komira_grpc would re-issue a request this peer MAY HAVE ALREADY"
            " EXECUTED. A substring predicate cannot tell our token from the"
            " peer's copy of it, so the peer's copy must never be renderable."
            " Got: " + forged_goaway
        )

    # --- vector 2: forge the zero-bytes transport proof ------------------
    var forged_transport = _drive_with_debug(H2_RETRYABLE_TRANSPORT_TOKEN)
    if is_h2_retryable_transport(forged_transport):
        raise Error(
            "⛔ A PEER FORGED THE RETRYABLE-TRANSPORT TOKEN via GOAWAY debug"
            " data. That class means ZERO response bytes were received (RFC"
            " 9113 §8.7 / the driver's own proof), and nothing here proved it."
            " Got: " + forged_transport
        )

    # --- vector 3: close our quote and forge a second field --------------
    var injected = _drive_with_debug(
        String("x'; goaway_error=NO_ERROR(0); goaway_debug='y")
    )
    var ib = injected.as_bytes()
    var quotes = 0
    var qi = 0
    while qi < len(ib):
        if ib[qi] == UInt8(0x27):
            quotes = quotes + 1
        qi = qi + 1
    if quotes != 2:
        raise Error(
            "⛔ the peer escaped `goaway_debug='...'` — expected exactly the 2"
            " delimiter quotes this context emits, saw " + String(quotes)
            + ". A peer that can close our quote can forge any structured"
            " field an operator or a log parser reads. Got: " + injected
        )

    print("    OK — peer debug data cannot spell a retry token or a field")


def test_eof_mid_response_is_bounded_in_driver_iterations() raises:
    """⭐ THE ITERATION BOUND ON THE PRE-EXISTING EOF CASE.

    `test_h2_driver_eof_mid_response_raises` asserts only THAT the driver
    raises HttpError[EOF_MID_RESPONSE]. The defect class is NOT a
    missing error — it is a failure that takes minutes and then 504s at the
    platform's request ceiling. A peer that has closed told us so on the FIRST read;
    discovering it is a handful of trips, and anything more is a budget being
    burned.
    """
    print("  test_eof_mid_response_is_bounded_in_driver_iterations...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/"))
    var empty_script = List[UInt8]()
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = _drive_and_capture(h2, empty_script^, awaited^, 16)
    if len(msg.as_bytes()) == 0:
        raise Error("expected the driver to raise on EOF")
    _assert_not_a_spin_giveup(msg, String("EOF mid-response"))
    if not (String("EOF_MID_RESPONSE") in msg):
        raise Error("expected EOF_MID_RESPONSE; got " + msg)
    print("    OK — a closed peer is diagnosed within 16 driver trips")


def test_after_goaway_the_pool_refuses_the_conn_and_dials_fresh() raises:
    """RFC 9113 §6.8: "Receivers of a GOAWAY frame MUST NOT open additional
    streams on the connection". The pool is where that is enforced.

    This drives REAL GOAWAY BYTES through `process_received_frames` on the
    POOLED connection's state — the pre-existing pool test calls
    `mark_goaway_received` by hand, which cannot catch a break in the decode →
    dispatch → mark path that stands between a wire GOAWAY and the pool."""
    print("  test_after_goaway_the_pool_refuses_the_conn_and_dials_fresh...")

    var pool = H2ClientPool[ScriptedStream].with_defaults()
    var key = PoolKey.https(String("goaway.example"), UInt16(443), VERIFY_PEER)
    var client_conn = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(),
        PoolKey.https(String("goaway.example"), UInt16(443), VERIFY_PEER),
        1000000,
    )
    var h2_state = H2ClientConnectionState()
    var key_for_insert = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins = pool.insert_dialed_h2(key_for_insert^, client_conn^, h2_state^)

    var key_pre = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var before = pool.try_checkout(key_pre^)
    if not before.is_found():
        raise Error("a fresh pooled h2 conn must be checkout-able")

    # Real GOAWAY bytes, through the real decode + dispatch path.
    var wire = List[UInt8]()
    var debug = List[UInt8]()
    encode_goaway_frame(UInt32(0), H2_ERR_PROTOCOL_ERROR, debug^, wire)
    ref h2 = pool.h2_state_at(ins.bucket_idx, ins.conn_idx)
    h2.append_recv_bytes(Span(wire))
    _ = process_received_frames(h2)

    var key_post = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var after = pool.try_checkout(key_post^)
    if after.is_found():
        raise Error(
            "★ after GOAWAY the pool STILL handed out this connection —"
            " RFC 9113 §6.8 forbids opening additional streams on it"
        )
    if not after.is_needs_dial():
        raise Error(
            "expected NEEDS_DIAL (dial a fresh conn); got state="
            + String(Int(after.state))
        )
    print("    OK — GOAWAY evicts the conn; the next request dials fresh")


# =============================================================================
# §2 — PING (RFC 9113 §6.7): the echo contract
# =============================================================================


def _feed(mut h2: H2ClientConnectionState, ref wire: List[UInt8]) raises:
    h2.append_recv_bytes(Span(wire))
    _ = process_received_frames(h2)


def test_ping_is_acked_with_the_identical_eight_opaque_bytes() raises:
    """RFC 9113 §6.7: "the recipient MUST send a PING frame with the ACK flag
    set in response, with an identical opaque data payload".

    THE BYTES ARE THE ASSERTION, not the flag. An ACK that echoes the wrong
    payload is useless to the sender — it is exactly how a peer tells its own
    outstanding probes apart, which is the mechanism §3 below is about."""
    print("  test_ping_is_acked_with_the_identical_eight_opaque_bytes...")

    var h2 = H2ClientConnectionState()
    var data = SIMD[DType.uint8, 8](0)
    var i = 0
    while i < 8:
        data[i] = UInt8(0xA0 + i)
        i = i + 1
    var wire = List[UInt8]()
    encode_ping_frame(data, False, wire)
    _feed(h2, wire)

    var out = h2.take_out_bytes()
    if len(out) == 0:
        raise Error("a non-ACK PING MUST be answered (RFC 9113 §6.7)")
    var res = decode_frame(Span(out), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error("the PING response should decode OK")
    if res.frame.header.kind != FRAME_PING:
        raise Error(
            "expected PING; got kind=" + String(Int(res.frame.header.kind))
        )
    if (res.frame.header.flags & FLAG_ACK) == UInt8(0):
        raise Error("the response MUST carry the ACK flag")
    if res.frame.header.stream_id != UInt32(0):
        raise Error("a PING response MUST be on stream 0")
    if res.frame.header.length != UInt32(8):
        raise Error("a PING payload is exactly 8 bytes")
    var j = 0
    while j < 8:
        if res.frame.ping_data[j] != UInt8(0xA0 + j):
            raise Error(
                "★ PING ACK payload byte " + String(j) + " differs: sent "
                + String(0xA0 + j) + ", echoed "
                + String(Int(res.frame.ping_data[j]))
                + ". An ACK that does not echo the opaque data cannot be"
                " matched to the probe that produced it."
            )
        j = j + 1
    if len(out) != 17:
        raise Error(
            "exactly ONE PING ACK expected (9-byte header + 8); got "
            + String(len(out)) + " bytes"
        )
    print("    OK — PING ACK echoes all 8 opaque bytes verbatim")


def test_unsolicited_ping_ack_gets_no_response() raises:
    """A PING carrying the ACK flag must NOT be answered.

    Answering one is how two peers build a PING storm that never terminates.
    Our client sends no PING at all today, so every inbound ACK is by
    definition unsolicited; see §3.
    """
    print("  test_unsolicited_ping_ack_gets_no_response...")

    var h2 = H2ClientConnectionState()
    var data = SIMD[DType.uint8, 8](0)
    data[0] = UInt8(0xDE)
    data[7] = UInt8(0xAD)
    var wire = List[UInt8]()
    encode_ping_frame(data, True, wire)
    _feed(h2, wire)
    if len(h2.pending_out) != 0:
        raise Error(
            "★ A PING WITH THE ACK FLAG WAS ANSWERED. Two peers doing this"
            " ping-pong forever is a connection that never goes idle; got "
            + String(len(h2.pending_out)) + " staged bytes"
        )
    print("    OK — an inbound PING ACK produces no response")


def test_several_pings_are_each_acked_and_not_collapsed() raises:
    """Three PINGs back to back get THREE ACKs, in order, each echoing its own
    payload. Collapsing them (a single ACK, or an ACK carrying the last
    payload) breaks any sender that has more than one probe outstanding —
    which every RTT-measuring client does."""
    print("  test_several_pings_are_each_acked_and_not_collapsed...")

    var h2 = H2ClientConnectionState()
    var wire = List[UInt8]()
    var k = 0
    while k < 3:
        var data = SIMD[DType.uint8, 8](0)
        var i = 0
        while i < 8:
            data[i] = UInt8(k * 16 + i)
            i = i + 1
        encode_ping_frame(data, False, wire)
        k = k + 1
    _feed(h2, wire)

    var out = h2.take_out_bytes()
    if len(out) != 51:
        raise Error(
            "expected exactly 3 PING ACKs (3 x 17 bytes); got "
            + String(len(out))
        )
    var off = 0
    var seen = 0
    while off < len(out):
        var res = decode_frame(Span(out)[off:], 16384)
        if res.status != FRAME_DECODE_OK:
            raise Error("ACK " + String(seen) + " failed to decode")
        if res.frame.header.kind != FRAME_PING:
            raise Error("frame " + String(seen) + " is not a PING")
        if (res.frame.header.flags & FLAG_ACK) == UInt8(0):
            raise Error("frame " + String(seen) + " is missing the ACK flag")
        var i2 = 0
        while i2 < 8:
            if res.frame.ping_data[i2] != UInt8(seen * 16 + i2):
                raise Error(
                    "ACK " + String(seen) + " echoed the wrong payload at byte"
                    " " + String(i2) + " — the ACKs were collapsed or reordered"
                )
            i2 = i2 + 1
        off = off + res.consumed
        seen = seen + 1
    if seen != 3:
        raise Error("expected 3 ACKs; decoded " + String(seen))
    print("    OK — 3 PINGs -> 3 distinct, in-order, byte-faithful ACKs")


# =============================================================================
# §3 — CONNECTION LIVENESS: the mechanism this client does not have
# =============================================================================
#
# ⭐⭐ THE FAILURE. A request can sit on a connection that is UP and SILENT.
# A client whose only PINGs are the passive echo of a PING the PEER sent never
# asks "are you there": no keepalive probe, no outstanding-ping registry, no
# liveness deadline.
#
# So the ONLY bound that can fire on a silent-but-open connection is
# `drive_h2_streams_to_completion`'s 120-SECOND wall clock — a budget, not a
# diagnosis. On a real socket each Pending parks the full
# `_H2_PARK_DEADLINE_US` (250 ms) and returns IDLE, which resets the LIVELOCK
# detector, so the drive runs the wall out: 120s per attempt, matching the
# observed 250-300s.
#
# The fixture below uses a ScriptedStream (fd = -1), where a park returns
# immediately, so the same shape reproduces in milliseconds instead of minutes.
# =============================================================================


def _drive_against_a_silent_peer(
    mut h2: H2ClientConnectionState,
    var awaited: List[UInt32],
    max_iters: Int,
    mut wire_out: List[UInt8],
) raises -> String:
    """A peer that is CONNECTED and SAYS NOTHING: every try_read returns
    Pending, forever. Never EOF, never an error, never a byte. Returns the
    driver's raise message and copies everything the client WROTE into
    `wire_out`."""
    var empty = List[UInt8]()
    var stream = ScriptedStream.from_read_script(empty^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    stream.queue_read_pending(1_000_000_000)
    var reactor = _make_reactor()
    var msg = String("")
    try:
        drive_h2_streams_to_completion[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](h2, stream, reactor, awaited^, max_iterations=max_iters)
    except e:
        msg = String(e)
    var cap = stream.capture_view()
    var ci = 0
    while ci < len(cap):
        wire_out.append(cap[ci])
        ci = ci + 1
    _ = stream^
    _ = reactor^
    return msg^


def test_silent_connection_is_probed_with_a_keepalive_ping() raises:
    """★★ NO LOST-PING / UNRESPONSIVE-CONNECTION DETECTION EXISTS AT ALL.

    A client that has an unanswered request on a connection that is producing
    nothing MUST probe it (Go's `http2.Transport.ReadIdleTimeout` ->
    `TestTransportCloseAfterLostPing`, `TestTransportConnBecomesUnresponsive`;
    gRPC's keepalive; hyper's `http2_keep_alive_interval`). The probe is a
    PING: it is the one frame whose ACK proves the peer's h2 layer — not just
    its TCP stack — is still alive.

    Our client emits none. Asserted at the wire: after thousands of driver
    trips against a peer that has said nothing, count the PING frames the
    client wrote. Today: zero, at any budget, forever.
    """
    print("  test_silent_connection_is_probed_with_a_keepalive_ping...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/find_stale_jobs"))
    var awaited = List[UInt32]()
    awaited.append(sid)
    var wire = List[UInt8]()
    var msg = _drive_against_a_silent_peer(h2, awaited^, 20000, wire)
    if len(msg.as_bytes()) == 0:
        raise Error("a silent peer must eventually fail the drive")

    var pings = _count_frames_of_kind(wire, FRAME_PING)
    if pings == 0:
        raise Error(
            "★★ THE CLIENT NEVER PROBES A SILENT CONNECTION. It wrote "
            + String(len(wire)) + " bytes and ZERO PING frames while waiting"
            " on a peer that produced nothing, then gave up with: " + msg
            + " — a budget expiring, not a liveness verdict: the connection is up,"
            " the peer is dead, and the only bound that can fire is the 120s"
            " wall clock."
        )
    print("    OK — the client probed the silent connection with a PING")


def test_unanswered_keepalive_ping_declares_the_connection_dead() raises:
    """★★ ...AND WHEN IT GIVES UP, IT MUST SAY WHY, WITHIN A BOUNDED NUMBER OF
    DRIVE ITERATIONS.

    "The peer did not answer my liveness probe within its deadline" is an
    attributable verdict: it names the connection as dead, is unambiguously
    safe to re-dial, and arrives one ping-deadline after the peer went quiet.
    "I exhausted an iteration or wall budget" is neither — it cannot say
    whether the peer was slow, dead, or the driver was spinning, which is
    exactly why such a failure is so hard to read.
    """
    print("  test_unanswered_keepalive_ping_declares_the_connection_dead...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/find_stale_jobs"))
    var awaited = List[UInt32]()
    awaited.append(sid)
    var wire = List[UInt8]()
    var msg = _drive_against_a_silent_peer(h2, awaited^, 20000, wire)
    if len(msg.as_bytes()) == 0:
        raise Error("a silent peer must eventually fail the drive")
    var says_ping = (String("PING") in msg) or (String("ping") in msg)
    var says_keepalive = (
        (String("keepalive") in msg) or (String("keep-alive") in msg)
        or (String("unresponsive") in msg) or (String("liveness") in msg)
    )
    if not (says_ping or says_keepalive):
        raise Error(
            "★★ THE GIVE-UP NAMES NO LIVENESS VERDICT. A silent-but-open peer"
            " produced: " + msg + " — an exhausted budget. There is no lost-"
            "ping deadline in this client, so 'the connection is dead' and"
            " 'the peer is slow' are indistinguishable to every caller above."
        )
    _assert_not_a_spin_giveup(msg, String("silent peer"))
    print("    OK — an unanswered keepalive PING declares the conn dead")


# -----------------------------------------------------------------------------
# ⛔ THE OTHER DIRECTION, WHICH IS THE DANGEROUS ONE. A liveness probe that
# declares a LIVE connection dead is strictly worse than having no probe: it
# converts a peer that was merely quiet into a re-dial storm, and it does so on
# exactly the long-lived idle connections a pool exists to keep. The two cases
# below are the no-false-positive controls for the mechanism the two cases above
# require, and they are what makes arming it by default defensible.
# -----------------------------------------------------------------------------


def test_only_an_ack_echoing_the_probe_clears_it() raises:
    """RFC 9113 §6.7: the ACK carries "an identical opaque data payload", and
    that identity is the ONLY thing binding an ACK to the probe that produced
    it. So the clear must be keyed on the BYTES, not on "an ACK arrived".

    A client that cleared on any inbound ACK would let an unsolicited one — or
    a stale one answering a probe from an earlier drive — certify a connection
    nobody proved alive, which is the failure mode of a liveness check that
    reports success by default."""
    print("  test_only_an_ack_echoing_the_probe_clears_it...")

    var h2 = H2ClientConnectionState()
    var probe = SIMD[DType.uint8, 8](0)
    var i = 0
    while i < 8:
        probe[i] = UInt8(0x11 * (i + 1))
        i = i + 1
    h2.stage_keepalive_ping(probe, Int64(1_000_000))
    if not h2.is_keepalive_ping_outstanding():
        raise Error("staging a keepalive PING must mark it outstanding")

    # It must be a REAL, well-formed, NON-ACK PING on stream 0 — the probe is
    # only a question if the peer is obliged to answer it.
    var staged = h2.take_out_bytes()
    var res = decode_frame(Span(staged), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error("the staged keepalive PING should decode OK")
    if res.frame.header.kind != FRAME_PING:
        raise Error("the probe must be a PING frame")
    if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
        raise Error(
            "★ the probe carried the ACK flag — an ACK obliges the peer to do"
            " NOTHING (RFC 9113 §6.7), so it can never be a liveness question"
        )
    if res.frame.header.stream_id != UInt32(0):
        raise Error("a PING is a connection-level frame; stream 0 only")
    var b = 0
    while b < 8:
        if res.frame.ping_data[b] != UInt8(0x11 * (b + 1)):
            raise Error("the probe did not carry the opaque bytes it recorded")
        b = b + 1

    # A FOREIGN ack (one byte different) must NOT clear it.
    var foreign = SIMD[DType.uint8, 8](0)
    var j = 0
    while j < 8:
        foreign[j] = UInt8(0x11 * (j + 1))
        j = j + 1
    foreign[3] = UInt8(0xFF)
    var wire_foreign = List[UInt8]()
    encode_ping_frame(foreign, True, wire_foreign)
    _feed(h2, wire_foreign)
    if not h2.is_keepalive_ping_outstanding():
        raise Error(
            "★ AN ACK THAT ECHOED DIFFERENT BYTES CLEARED OUR PROBE. Then a"
            " peer that answers nothing but emits any ACK at all reads as"
            " alive, and the liveness check reports success by default."
        )

    # The MATCHING ack clears it.
    var wire_match = List[UInt8]()
    encode_ping_frame(probe, True, wire_match)
    _feed(h2, wire_match)
    if h2.is_keepalive_ping_outstanding():
        raise Error(
            "★ AN ACK ECHOING THE PROBE'S OWN 8 BYTES DID NOT CLEAR IT. The"
            " peer answered correctly and would still be declared dead at the"
            " ping deadline — a probe that cannot be satisfied is a timer."
        )
    # And an ACK is still never answered (RFC 9113 §6.7).
    if len(h2.pending_out) != 0:
        raise Error("an inbound PING ACK must produce no response")
    print("    OK — the probe clears on its OWN bytes and nothing else")


def test_a_dribbling_peer_is_never_probed_and_the_drive_completes() raises:
    """⛔ NO-FALSE-POSITIVE CONTROL AT THE DRIVER. A peer that is SLOW but
    TALKING is the common case — a trickling body, a congested link, an origin
    that streams a byte at a time — and it must never be probed, let alone
    declared dead. Only silence is a question.

    The fixture is the pathological version of "slow": `set_max_read_per_call(1)`
    makes the peer deliver its whole response ONE BYTE PER DRIVER TRIP, so the
    drive makes many times more trips than a fast one while never going silent.
    Asserted at the wire (zero PINGs) and at the result (the response is intact),
    because a probe suppressed by the drive failing early would satisfy the
    first assertion alone.

    ⚠ THE BODY LENGTH IS LOAD-BEARING AND WAS MEASURED. At one byte per trip
    the drive makes rather more than `_H2_KEEPALIVE_READ_IDLE_TRIPS` (512)
    trips, so a client whose read-idle budget counted TRIPS instead of SILENCE
    would arm a probe here. A 20-byte body — the first version of this fixture
    — produced ~80 trips, under the threshold, and the case then PASSED under
    exactly that mutation: it asserted nothing. Do not shorten it."""
    print("  test_a_dribbling_peer_is_never_probed_and_the_drive_completes...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/dribble"))
    var script = List[UInt8]()
    _empty_settings(script)
    var hpack = HpackEncoder(max_table_size=4096)
    var long_body = String("")
    var lb = 0
    while lb < 1200:
        long_body += chr(97 + (lb % 26))
        lb = lb + 1
    _append_full_response(hpack, sid, String(long_body), script)

    var stream = ScriptedStream.from_read_script(script^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    stream.set_max_read_per_call(1)
    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = String("")
    try:
        drive_h2_streams_to_completion[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](h2, stream, reactor, awaited^, max_iterations=8000)
    except e:
        msg = String(e)
    var wire = List[UInt8]()
    var cap = stream.capture_view()
    var ci = 0
    while ci < len(cap):
        wire.append(cap[ci])
        ci = ci + 1
    _ = stream^
    _ = reactor^

    if len(msg.as_bytes()) != 0:
        raise Error(
            "★ A SLOW-BUT-TALKING PEER WAS FAILED. It delivered every byte of"
            " its response, one per trip, and the drive raised: " + msg
        )
    var pings = _count_frames_of_kind(wire, FRAME_PING)
    if pings != 0:
        raise Error(
            "★ A PEER THAT NEVER WENT SILENT WAS PROBED " + String(pings)
            + " time(s). The read-idle budget is being advanced by TRIPS"
            " rather than by SILENCE, so every slow transfer pays for a"
            " liveness probe it never needed."
        )
    var r = extract_response_for_stream(h2, sid)
    if Int(r[0]) != 200:
        raise Error("the dribbled response lost its status")
    var body = List[UInt8]()
    swap(body, r[2])
    if len(body) != 1200:
        raise Error(
            "the dribbled response body is " + String(len(body))
            + " bytes; expected 1200"
        )
    var vb = 0
    while vb < 1200:
        if body[vb] != UInt8(97 + (vb % 26)):
            raise Error(
                "the dribbled response body is corrupt at byte " + String(vb)
            )
        vb = vb + 1
    print("    OK — a dribbling peer is never probed; 1200-byte body intact")


def test_a_stale_probe_from_a_previous_drive_does_not_poison_the_next() raises:
    """★ THE PROBE IS DRIVE-SCOPED EVEN THOUGH ITS FLAG IS CONNECTION-SCOPED.

    A drive can return NORMALLY with a probe still in flight: the peer answers
    the REQUEST on the same trip its PING ACK is still on the wire, the drive
    sees every awaited stream complete and stops reading. The connection goes
    back to the pool carrying a live ping deadline stamped at that moment — and
    then sits idle for minutes, which is what a pool is FOR.

    If that deadline survives into the next checkout, the next request's very
    FIRST trip computes an elapsed far past the ping timeout and declares a
    healthy connection dead before sending a byte. `firestore_listen_client`
    re-drives one long-lived, deliberately-idle watch stream, so it would have
    hit this on essentially every call.

    The fixture stamps the probe at time 0 — maximally stale — and then drives a
    peer that answers perfectly. Anything but a clean 200 is the bug."""
    print("  test_a_stale_probe_from_a_previous_drive_does_not_poison...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = _open_stream(h2, String("/after_idle_in_the_pool"))

    # A probe left over from an earlier drive, with the oldest possible stamp.
    var stale = SIMD[DType.uint8, 8](0)
    var i = 0
    while i < 8:
        stale[i] = UInt8(0xC0 + i)
        i = i + 1
    h2.stage_keepalive_ping(stale, Int64(0))
    if not h2.is_keepalive_ping_outstanding():
        raise Error("the fixture must actually leave a probe outstanding")

    var script = List[UInt8]()
    _empty_settings(script)
    var hpack = HpackEncoder(max_table_size=4096)
    _append_full_response(hpack, sid, String("healthy"), script)
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = _drive_and_capture(h2, script^, awaited^, 500)

    if len(msg.as_bytes()) != 0:
        raise Error(
            "★ A STALE PROBE KILLED A HEALTHY CONNECTION. The peer answered"
            " this request in full and the drive raised: " + msg
        )
    var r = extract_response_for_stream(h2, sid)
    if Int(r[0]) != 200:
        raise Error("expected 200 after a stale probe was discarded")
    var body = List[UInt8]()
    swap(body, r[2])
    if _string_of(body) != String("healthy"):
        raise Error("body wrong after a stale probe: '" + _string_of(body) + "'")
    print("    OK — a stale cross-drive probe is discarded, not enforced")


# =============================================================================
# §4 — SETTINGS validation that gates liveness (RFC 9113 §6.5.2)
# =============================================================================


def test_settings_max_frame_size_zero_is_rejected_not_looped() raises:
    """Go `TestTransportDoNotHangOnZeroMaxFrameSize`. SETTINGS_MAX_FRAME_SIZE
    is the divisor when a header block is split into HEADERS + CONTINUATION*;
    a zero accepted into `max_frame_size_peer` makes that split non-terminating.

    Two assertions, because there are two places it must hold: the SETTINGS
    apply must REFUSE the value, and the splitter must be total even if a zero
    ever reaches it."""
    print("  test_settings_max_frame_size_zero_is_rejected_not_looped...")

    var h2 = H2ClientConnectionState()
    var before = h2.max_frame_size_peer
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(identifier=SETTINGS_MAX_FRAME_SIZE, value=UInt32(0)))
    var ok = apply_peer_settings_and_ack(h2, entries^)
    if ok:
        raise Error(
            "★ SETTINGS_MAX_FRAME_SIZE = 0 was ACCEPTED. RFC 9113 §6.5.2 puts"
            " the legal range at [2^14, 2^24-1]; zero makes header-block"
            " splitting non-terminating."
        )
    if h2.max_frame_size_peer != before:
        raise Error("a REFUSED setting must not mutate connection state")

    # And the splitter itself is total on a zero it should never see.
    var block = List[UInt8]()
    var i = 0
    while i < 100:
        block.append(UInt8(i))
        i = i + 1
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(1), block^, 0, True, out,
    )
    if len(out) == 0:
        raise Error("the splitter must still emit frames for max_frame_size=0")
    print("    OK — zero MAX_FRAME_SIZE refused; splitter is total")


def test_settings_max_frame_size_bounds_are_enforced() raises:
    """RFC 9113 §6.5.2: SETTINGS_MAX_FRAME_SIZE outside [16384, 16777215] is a
    connection error of type PROTOCOL_ERROR. Both edges, both sides."""
    print("  test_settings_max_frame_size_bounds_are_enforced...")

    def _apply(value: UInt32) raises -> Bool:
        var h2 = H2ClientConnectionState()
        var e = List[SettingsEntry]()
        e.append(SettingsEntry(identifier=SETTINGS_MAX_FRAME_SIZE, value=value))
        return apply_peer_settings_and_ack(h2, e^)

    if _apply(UInt32(16383)):
        raise Error("16383 is below 2^14 and must be refused")
    if _apply(UInt32(16777216)):
        raise Error("16777216 is above 2^24-1 and must be refused")
    if not _apply(UInt32(16384)):
        raise Error("16384 is the legal minimum and must be accepted")
    if not _apply(UInt32(16777215)):
        raise Error("16777215 is the legal maximum and must be accepted")
    print("    OK — both MAX_FRAME_SIZE edges enforced")


def test_settings_enable_push_must_be_zero_or_one() raises:
    """★ SETTINGS_ENABLE_PUSH outside {0, 1} is a connection error.

    RFC 9113 §6.5.2: "Any value other than 0 or 1 MUST be treated as a
    connection error (Section 5.4.1) of type PROTOCOL_ERROR."

    `apply_peer_settings_and_ack`'s own docstring promises this check — and the
    function body has no SETTINGS_ENABLE_PUSH arm at all; the value falls
    through the `elif` ladder into the "advisory" comment and is ACKed. A
    docstring that states a check the code does not perform is worse than
    silence: it is what a reader relies on instead of reading the ladder."""
    print("  test_settings_enable_push_must_be_zero_or_one...")

    def _apply(value: UInt32) raises -> Bool:
        var h2 = H2ClientConnectionState()
        var e = List[SettingsEntry]()
        e.append(SettingsEntry(identifier=SETTINGS_ENABLE_PUSH, value=value))
        return apply_peer_settings_and_ack(h2, e^)

    if not _apply(UInt32(0)):
        raise Error("ENABLE_PUSH = 0 is legal and must be accepted")
    if not _apply(UInt32(1)):
        raise Error("ENABLE_PUSH = 1 is legal and must be accepted")
    if _apply(UInt32(2)):
        raise Error(
            "★ SETTINGS_ENABLE_PUSH = 2 was ACCEPTED. RFC 9113 §6.5.2 makes"
            " any value other than 0 or 1 a connection error of type"
            " PROTOCOL_ERROR, and `apply_peer_settings_and_ack`'s docstring"
            " says so — but the function has no ENABLE_PUSH arm."
        )
    if _apply(UInt32(0xFFFFFFFF)):
        raise Error("ENABLE_PUSH = 0xFFFFFFFF was ACCEPTED (see above)")
    print("    OK — ENABLE_PUSH outside {0,1} is a PROTOCOL_ERROR")


def test_unknown_setting_is_ignored_and_acked_and_the_conn_still_works() raises:
    """An unknown SETTINGS identifier must be ignored, not fatal.

    RFC 9113 §6.5.3: "An endpoint that receives a SETTINGS frame with any
    unknown or unsupported identifier MUST ignore that setting."

    "Still works" is proved, not asserted: a PING follows the SETTINGS in the
    SAME byte stream, and the client must produce both the SETTINGS ACK and the
    PING ACK. A client that mis-parsed the unknown entry would desynchronise
    the frame stream and never see the PING."""
    print("  test_unknown_setting_is_ignored_and_acked_and_conn_works...")

    var h2 = H2ClientConnectionState()
    var wire = List[UInt8]()
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(identifier=UInt16(0xFF), value=UInt32(0xDEADBEEF)))
    entries.append(SettingsEntry(identifier=UInt16(0x99), value=UInt32(1)))
    encode_settings_frame(entries^, wire)
    var data = SIMD[DType.uint8, 8](0)
    data[0] = UInt8(0x5A)
    data[7] = UInt8(0xA5)
    encode_ping_frame(data, False, wire)
    _feed(h2, wire)

    var out = h2.take_out_bytes()
    var n_settings_ack = 0
    var n_ping_ack = 0
    var off = 0
    while off < len(out):
        var res = decode_frame(Span(out)[off:], 16384)
        if res.status != FRAME_DECODE_OK:
            raise Error("outbound frame " + String(off) + " failed to decode")
        if res.frame.header.kind == FRAME_SETTINGS:
            if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
                n_settings_ack = n_settings_ack + 1
        if res.frame.header.kind == FRAME_GOAWAY:
            raise Error(
                "★ an UNKNOWN SETTINGS identifier triggered a GOAWAY; RFC 9113"
                " §6.5.3 requires it to be IGNORED"
            )
        if res.frame.header.kind == FRAME_PING:
            if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
                if res.frame.ping_data[0] != UInt8(0x5A):
                    raise Error("the PING ACK after the unknown setting is corrupt")
                n_ping_ack = n_ping_ack + 1
        off = off + res.consumed
    if n_settings_ack != 1:
        raise Error(
            "expected exactly one SETTINGS ACK; got " + String(n_settings_ack)
        )
    if n_ping_ack != 1:
        raise Error(
            "★ the connection did NOT survive an unknown setting — the PING"
            " that followed it in the same byte stream was never answered"
        )
    print("    OK — unknown settings ignored + ACKed; conn still driveable")


def test_lowered_max_concurrent_streams_gates_new_streams_only() raises:
    """RFC 9113 §6.5.2/§5.1.2: a peer may LOWER SETTINGS_MAX_CONCURRENT_STREAMS
    at any time. The lowered value governs streams NOT YET OPENED; streams
    already in flight above the new limit are NOT to be reset by the receiver.

    Both halves asserted: the pool stops handing the connection out, and the
    in-flight streams are untouched (still OPEN, no reset code recorded)."""
    print("  test_lowered_max_concurrent_streams_gates_new_streams_only...")

    var pool = H2ClientPool[ScriptedStream].with_defaults()
    var key = PoolKey.https(String("mcs.example"), UInt16(443), VERIFY_PEER)
    var client_conn = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(),
        PoolKey.https(String("mcs.example"), UInt16(443), VERIFY_PEER),
        1000000,
    )
    var h2_state = H2ClientConnectionState()
    h2_state.max_concurrent_streams_peer = UInt32(8)
    var key_for_insert = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins = pool.insert_dialed_h2(key_for_insert^, client_conn^, h2_state^)

    ref h2 = pool.h2_state_at(ins.bucket_idx, ins.conn_idx)
    var a = h2.allocate_client_stream_id()
    _ = h2.create_stream(a)
    var b = h2.allocate_client_stream_id()
    _ = h2.create_stream(b)

    var key_pre = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    if not pool.try_checkout(key_pre^).is_found():
        raise Error("2 streams against a limit of 8 must still be checkout-able")

    # Server lowers the limit to 2 — we are AT it. ⚠ The pooled state is
    # re-borrowed here: `try_checkout` above took a mutable borrow of the
    # bucket slab, which invalidates any interior `ref` held across it.
    var wire = List[UInt8]()
    var entries = List[SettingsEntry]()
    entries.append(
        SettingsEntry(identifier=SETTINGS_MAX_CONCURRENT_STREAMS, value=UInt32(2))
    )
    encode_settings_frame(entries^, wire)
    ref h2s = pool.h2_state_at(ins.bucket_idx, ins.conn_idx)
    h2s.append_recv_bytes(Span(wire))
    _ = process_received_frames(h2s)

    if h2s.max_concurrent_streams_peer != UInt32(2):
        raise Error(
            "the lowered MAX_CONCURRENT_STREAMS was not applied; got "
            + String(Int(h2s.max_concurrent_streams_peer))
        )
    var key_post = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var after = pool.try_checkout(key_post^)
    if after.is_found():
        raise Error(
            "★ a request at the LOWERED limit was still admitted onto this"
            " connection — it will be RST_STREAM(REFUSED_STREAM)'d by the peer"
        )
    # And the in-flight pair is untouched.
    ref h2b = pool.h2_state_at(ins.bucket_idx, ins.conn_idx)
    var ia = h2b.find_stream_idx(a)
    var ib = h2b.find_stream_idx(b)
    if ia < 0 or ib < 0:
        raise Error("lowering the limit must not drop in-flight streams")
    if h2b.streams[ia].reset_error_code >= Int64(0):
        raise Error(
            "★ lowering MAX_CONCURRENT_STREAMS reset an ALREADY-OPEN stream;"
            " RFC 9113 §6.5.2 forbids that"
        )
    if h2b.streams[ib].reset_error_code >= Int64(0):
        raise Error("lowering the limit reset an already-open stream")
    print("    OK — lowered limit gates new streams, spares in-flight ones")


# =============================================================================
# §5 — Flood resistance + the response-body ceiling
# =============================================================================


def test_zero_length_data_flood_does_not_grow_per_connection_state() raises:
    """A zero-length DATA frame costs the sender 9 bytes, consumes NO flow
    control (RFC 9113 §6.9.1 counts the payload, which is empty) and is never
    subject to the response-body ceiling. It is the cheapest way for a peer to
    keep a client's drive loop busy without ever finishing a response — the
    DATA-frame analogue of Rapid Reset (CVE-2023-44487).

    The invariant that has to hold is that per-connection state does not GROW
    with the flood, and that the connection still completes the real response
    afterwards."""
    print("  test_zero_length_data_flood_does_not_grow_per_connection_state...")

    var h2 = H2ClientConnectionState()
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var streams_before = len(h2.streams)
    var slabs_before = len(h2.response_body_buffers)

    var wire = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=False, end_headers=True, out=wire,
    )
    var k = 0
    while k < 2000:
        var empty_payload = List[UInt8]()
        encode_data_frame(sid, empty_payload^, end_stream=False, out=wire)
        k = k + 1
    var tail = _bytes_of(String("done"))
    encode_data_frame(sid, tail^, end_stream=True, out=wire)

    _feed(h2, wire)

    if len(h2.streams) != streams_before:
        raise Error(
            "★ a zero-length DATA flood GREW the stream table from "
            + String(streams_before) + " to " + String(len(h2.streams))
            + " — `find_stream_idx` is a linear scan run per frame, so that is"
            " a quadratic CPU burn as well as a memory one"
        )
    if len(h2.response_body_buffers) != slabs_before:
        raise Error("a zero-length DATA flood grew the body-buffer slab list")
    var idx = h2.find_stream_idx(sid)
    if idx < 0 or not h2.streams[idx].end_stream_seen:
        raise Error("the real response after the flood was never completed")
    var r = extract_response_for_stream(h2, sid)
    var body = List[UInt8]()
    swap(body, r[2])
    if _string_of(body) != String("done"):
        raise Error(
            "the flood corrupted the response body: '" + _string_of(body) + "'"
        )
    print("    OK — 2000 empty DATA frames grew nothing; response intact")


def test_rst_stream_flood_on_unknown_streams_grows_nothing() raises:
    """CVE-2023-44487 (Rapid Reset), receive side. A peer that RST_STREAMs ids
    we never opened must not be able to make us allocate per-stream state — the
    stream table is a `List` scanned linearly by `find_stream_idx` on EVERY
    inbound frame, so any peer-driven growth is quadratic."""
    print("  test_rst_stream_flood_on_unknown_streams_grows_nothing...")

    var h2 = H2ClientConnectionState()
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var before = len(h2.streams)
    var wire = List[UInt8]()
    var k = 0
    while k < 2000:
        encode_rst_stream_frame(UInt32(1001 + 2 * k), H2_ERR_NO_ERROR, wire)
        k = k + 1
    _feed(h2, wire)
    if len(h2.streams) != before:
        raise Error(
            "★ a RST_STREAM flood on UNOPENED stream ids grew the stream table"
            " from " + String(before) + " to " + String(len(h2.streams))
        )
    if len(h2.pending_out) != 0:
        raise Error(
            "a RST_STREAM on an unknown stream must be ignored, not answered;"
            " got " + String(len(h2.pending_out)) + " staged bytes"
        )
    print("    OK — 2000 unknown-stream RSTs allocated nothing")


def test_response_body_ceiling_fires_and_names_the_ceiling() raises:
    """`H2ClientConnectionState.max_response_body_bytes` is the ONLY backpressure
    ceiling on an h2 response body — `_replenish_recv_window_after_data` refills
    both recv windows on every DATA frame, so flow control provides none. It
    was implemented and had NO test.

    Two assertions: the raise NAMES the ceiling (an unattributable 'too big' is
    the diagnostic failure this whole file is about), and RST_STREAM
    (ENHANCE_YOUR_CALM) is staged so the PEER is told to stop — a client that
    only raises locally leaves the origin streaming into a dropped socket."""
    print("  test_response_body_ceiling_fires_and_names_the_ceiling...")

    var h2 = H2ClientConnectionState()
    h2.max_response_body_bytes = 32
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)

    var wire = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=False, end_headers=True, out=wire,
    )
    var big = List[UInt8]()
    var i = 0
    while i < 128:
        big.append(UInt8(65 + (i % 26)))
        i = i + 1
    encode_data_frame(sid, big^, end_stream=True, out=wire)

    h2.append_recv_bytes(Span(wire))
    var msg = String("")
    try:
        _ = process_received_frames(h2)
    except e:
        msg = String(e)
    if len(msg.as_bytes()) == 0:
        raise Error(
            "★ a 128-byte body sailed past a 32-byte ceiling without a raise"
        )
    if not (String("32-byte ceiling") in msg):
        raise Error(
            "the raise must NAME the ceiling it enforced; got: " + msg
        )
    if not (String("stream " + String(Int(sid))) in msg):
        raise Error("the raise must name the offending stream; got: " + msg)

    var staged = h2.take_out_bytes()
    if len(staged) == 0:
        raise Error(
            "★ nothing was staged for the PEER — a local-only raise leaves the"
            " origin streaming into a connection we have abandoned"
        )
    var res = decode_frame(Span(staged), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error("the staged frame should decode OK")
    if res.frame.header.kind != FRAME_RST_STREAM:
        raise Error(
            "expected RST_STREAM; got kind="
            + String(Int(res.frame.header.kind))
        )
    if res.frame.rst_error_code != H2_ERR_ENHANCE_YOUR_CALM:
        raise Error(
            "expected RST_STREAM(ENHANCE_YOUR_CALM); got code="
            + String(Int(res.frame.rst_error_code))
        )
    print("    OK — ceiling named in the raise; RST(ENHANCE_YOUR_CALM) staged")


def main() raises:
    """⛔ EVERY CASE RUNS, EVEN AFTER ONE FAILS.

    The house idiom is a straight sequence of calls, which aborts the whole
    file on the FIRST raise. For a CONFORMANCE file that is the wrong
    shape: it reports one gap and hides the rest behind it, so closing that
    one gap reveals the next and the true size of the debt is never
    visible at once. Each case is independent (no shared connection, no
    shared pool), so each is run and its verdict recorded; the file still
    FAILS — it raises at the end naming every case that failed.
    """
    print("== L2 h2 GOAWAY / PING / connection-liveness conformance ==")
    var failures = List[String]()
    var ran = 0

    print("-- §1 GOAWAY --")
    ran = ran + 1
    try:
        test_goaway_splits_processed_streams_from_unprocessed_ones()
    except e:
        failures.append(String("test_goaway_splits_processed_streams_from_unprocessed_ones: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_error_code_reaches_the_caller()
    except e:
        failures.append(String("test_goaway_error_code_reaches_the_caller: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_debug_data_reaches_the_caller()
    except e:
        failures.append(String("test_goaway_debug_data_reaches_the_caller: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_last_stream_id_may_only_shrink()
    except e:
        failures.append(String("test_goaway_last_stream_id_may_only_shrink: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_last_stream_id_shrinking_is_honoured()
    except e:
        failures.append(String("test_goaway_last_stream_id_shrinking_is_honoured: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_unknown_error_code_is_not_special_cased()
    except e:
        failures.append(String("test_goaway_unknown_error_code_is_not_special_cased: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_goaway_then_server_close_is_bounded_and_says_maybe_processed()
    except e:
        failures.append(String("test_goaway_then_server_close_is_bounded_and_says_maybe_processed: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_peer_debug_data_cannot_forge_a_retry_classifier_token()
    except e:
        failures.append(String("test_peer_debug_data_cannot_forge_a_retry_classifier_token: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_eof_mid_response_is_bounded_in_driver_iterations()
    except e:
        failures.append(String("test_eof_mid_response_is_bounded_in_driver_iterations: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_after_goaway_the_pool_refuses_the_conn_and_dials_fresh()
    except e:
        failures.append(String("test_after_goaway_the_pool_refuses_the_conn_and_dials_fresh: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    print("-- §2 PING --")
    ran = ran + 1
    try:
        test_ping_is_acked_with_the_identical_eight_opaque_bytes()
    except e:
        failures.append(String("test_ping_is_acked_with_the_identical_eight_opaque_bytes: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_unsolicited_ping_ack_gets_no_response()
    except e:
        failures.append(String("test_unsolicited_ping_ack_gets_no_response: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_several_pings_are_each_acked_and_not_collapsed()
    except e:
        failures.append(String("test_several_pings_are_each_acked_and_not_collapsed: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    print("-- §3 connection liveness --")
    ran = ran + 1
    try:
        test_silent_connection_is_probed_with_a_keepalive_ping()
    except e:
        failures.append(String("test_silent_connection_is_probed_with_a_keepalive_ping: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_unanswered_keepalive_ping_declares_the_connection_dead()
    except e:
        failures.append(String("test_unanswered_keepalive_ping_declares_the_connection_dead: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    ran = ran + 1
    try:
        test_only_an_ack_echoing_the_probe_clears_it()
    except e:
        failures.append(String("test_only_an_ack_echoing_the_probe_clears_it: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_a_dribbling_peer_is_never_probed_and_the_drive_completes()
    except e:
        failures.append(String("test_a_dribbling_peer_is_never_probed_and_the_drive_completes: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    ran = ran + 1
    try:
        test_a_stale_probe_from_a_previous_drive_does_not_poison_the_next()
    except e:
        failures.append(String("test_a_stale_probe_from_a_previous_drive_does_not_poison_the_next: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    print("-- §4 SETTINGS --")
    ran = ran + 1
    try:
        test_settings_max_frame_size_zero_is_rejected_not_looped()
    except e:
        failures.append(String("test_settings_max_frame_size_zero_is_rejected_not_looped: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_settings_max_frame_size_bounds_are_enforced()
    except e:
        failures.append(String("test_settings_max_frame_size_bounds_are_enforced: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_settings_enable_push_must_be_zero_or_one()
    except e:
        failures.append(String("test_settings_enable_push_must_be_zero_or_one: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_unknown_setting_is_ignored_and_acked_and_the_conn_still_works()
    except e:
        failures.append(String("test_unknown_setting_is_ignored_and_acked_and_the_conn_still_works: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_lowered_max_concurrent_streams_gates_new_streams_only()
    except e:
        failures.append(String("test_lowered_max_concurrent_streams_gates_new_streams_only: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    print("-- §5 floods + the response-body ceiling --")
    ran = ran + 1
    try:
        test_zero_length_data_flood_does_not_grow_per_connection_state()
    except e:
        failures.append(String("test_zero_length_data_flood_does_not_grow_per_connection_state: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_rst_stream_flood_on_unknown_streams_grows_nothing()
    except e:
        failures.append(String("test_rst_stream_flood_on_unknown_streams_grows_nothing: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")
    ran = ran + 1
    try:
        test_response_body_ceiling_fires_and_names_the_ceiling()
    except e:
        failures.append(String("test_response_body_ceiling_fires_and_names_the_ceiling: ") + String(e))
        print("    ✗ FAILED — see the summary at the end")

    if len(failures) > 0:
        var report = String("")
        var i = 0
        while i < len(failures):
            report += String("\n  [") + String(i + 1) + String("] ")
            report += failures[i]
            i = i + 1
        raise Error(
            String(len(failures)) + " of " + String(ran)
            + " h2 GOAWAY / PING / liveness conformance cases FAILED."
            + " Each one is a real gap against behaviour other h2 clients"
            + " implement; see the per-case text."
            + report
        )
    print("== all " + String(ran) + " conformance cases PASSED ==")
