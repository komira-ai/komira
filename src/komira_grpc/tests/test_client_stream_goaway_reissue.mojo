"""FALSIFIER — a CLIENT-STREAMING RPC that meets an unprocessed-stream
GOAWAY must be re-issued on a NEW connection, for ANY verb.

A client-streaming upload (a GCS `WriteObject`) that meets a recycling peer
sees

    HttpError[H2_PROTOCOL]: GOAWAY received; stream 21 > last_stream_id 19;
      will not be processed [h2-goaway-unprocessed]

The error text is CORRECT RFC reasoning; failing the request anyway would be
the wrong action. RFC 9113 §6.8: a stream numbered ABOVE the GOAWAY's
`Last-Stream-ID` was definitively NOT processed, so re-issuing it on a new
connection is safe. 21 > 19.

WHY THIS ARM NEEDS ITS OWN RE-ISSUE. The unary (§3a) and server-streaming
(§4a) re-issues do not reach it: `WriteObject` is CLIENT-STREAMING, so it
routes to `client_stream` (the code generator emits exactly one call shape per
(client_streaming, server_streaming) pair).

⚠ REPLAY SAFETY IS NOT IDEMPOTENCY, AND THIS IS THE HEART OF IT. `WriteObject`
is NOT idempotent and NOT in the SAFE set, so a verb-idempotency predicate (Go's
`net/http` `Request.isReplayable`, RFC 9110 §9.2.2) correctly refuses it. That is
the WRONG question. Idempotency is a promise the ORIGIN SERVER makes about what a
method MEANS, which a client cannot verify; an unprocessed-stream GOAWAY is the
peer STATING WHAT IT DID (nothing). The second is strictly stronger and
independently sufficient. (t2) below pins that the gate is still the stream-id
comparison and not a blanket "GOAWAY".

WHAT THIS FILE FALSIFIES:

  (t1) ABOVE — GOAWAY(last=0) against our stream 1: the client-stream RPC must
       RE-DIAL and SUCCEED. Without the re-issue the raise escapes
       `client_stream` verbatim ⇒ RED.
  (t2) BELOW — GOAWAY(last=1) INCLUDES our stream 1: must RAISE and must NOT
       dial again. A fully-successful second connection is ARMED, so "it
       returned a response" IS the failure signal. A `WriteObject` replayed
       without the proof is a duplicate object write.
  (t3) BYTE-FRESH — the re-issued request must carry the SAME request body. This
       is the assertion that pins the mechanism: it is tempting to believe
       draining the `ClientStreamEncoder` "EMPTIES the caller's buffer", making
       a rebuild impossible. It does not — `drain_chunk` is a copy-out drain
       that advances `_drain_cursor` and never truncates `_buf`. If
       `rewind_for_reissue` is removed, attempt 2 sends an EMPTY body and this
       arm goes RED while (t1) stays green.
  (t4) BOUND — a peer that GOAWAYs every connection must stop at
       `_GOAWAY_RETRY_MAX_ATTEMPTS`, not spin, and must say so. An unbounded
       retry is how an upload hangs forever instead of failing, which is worse
       than the bug being fixed.

The peer is a `ScriptedStream` — a byte script, no socket, no network, no
thread. Hermetic.
"""

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient
from komira_http.client.url import Url
from komira_http.codec.h2.frame import (
    H2_ERR_NO_ERROR,
    SettingsEntry,
    encode_data_frame,
    encode_goaway_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    ProtocolGrpcProto,
    encode_stream_message,
)
from komira_grpc.client import _GOAWAY_RETRY_MAX_ATTEMPTS


comptime RT = PerCoreAsyncRuntime[NoopSink]

# A real client-streaming RPC. `WriteObject` is (client_streaming=True,
# server_streaming=False) — the arm this file covers.
comptime _RPC_PATH: String = "/google.storage.v2.Storage/WriteObject"

# The client allocates odd stream ids from 1 on every FRESH connection, so the
# first RPC on any connection is stream 1. Both GOAWAY cases are stated relative
# to that one fact: last=0 EXCLUDES it, last=1 INCLUDES it.
comptime _FIRST_CLIENT_STREAM_ID: Int = 1

# A marker that survives into the h2 DATA frame verbatim — h2 compresses HEADERS
# (HPACK) but never DATA, so finding these bytes in a connection's write capture
# proves that connection carried the request BODY.
comptime _PAYLOAD_A: String = "WRITEOBJECT-CHUNK-ONE"
comptime _PAYLOAD_B: String = "WRITEOBJECT-CHUNK-TWO"


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _goaway_script(last_stream_id: Int) raises -> List[UInt8]:
    """A connection that greets and then immediately drains: server SETTINGS,
    then GOAWAY(NO_ERROR) with the given `Last-Stream-ID`, then EOF.

    This is the GRACEFUL shutdown a Google front end performs when recycling a
    connection — NO_ERROR, not a fault. `last_stream_id=0` means it processed
    nothing; `=1` means it may have processed our stream 1."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var debug = List[UInt8]()
    encode_goaway_frame(UInt32(last_stream_id), H2_ERR_NO_ERROR, debug^, out)
    return out^


def _write_object_ok_script(payload: String) raises -> List[UInt8]:
    """A connection that serves ONE successful client-streaming gRPC response on
    stream 1: SETTINGS + HEADERS(:status 200, application/grpc, grpc-status 0) +
    DATA(5-byte-enveloped `payload`, END_STREAM). Shaped like the single
    `WriteObjectResponse` GCS returns after the last request message."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)

    var body = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(payload)))

    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    hdrs.append(HpackHeader(String("grpc-status"), String("0")))
    hdrs.append(HpackHeader(String("content-length"), String(len(body))))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(_FIRST_CLIENT_STREAM_ID),
        block^,
        end_stream=False,
        end_headers=True,
        out=out,
    )
    encode_data_frame(
        UInt32(_FIRST_CLIENT_STREAM_ID), body^, end_stream=True, out=out,
    )
    return out^


def _h2_stream(var script: List[UInt8]) raises -> ScriptedStream:
    """One scripted connection that reports ALPN h2 — without that,
    `send_grpc_pooled` drops the dial and silently falls back to HTTP/1.1,
    which never produces a GOAWAY at all."""
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    return s^


def _h2_stream_capturing(
    var script: List[UInt8], shared: ArcPointer[List[UInt8]]
) raises -> ScriptedStream:
    """As `_h2_stream`, but mirrors every byte the client WRITES into `shared`,
    which outlives the stream. That is how (t3) reads attempt 2's request body
    after the call consumed the connection."""
    var s = ScriptedStream.from_read_script_with_capture(script^, shared)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    return s^


def _gcs_base() raises -> Url:
    """An https authority, so `send_grpc_pooled` takes the pooled-h2 path the
    https GCS gRPC client takes (its plaintext branch is h1)."""
    return Url.parse(String("https://storage.googleapis.com:443/"))


def _write_object_encoder() raises -> ClientStreamEncoder[ProtocolGrpcProto]:
    """The request half of a buffered `WriteObject`: N envelope-framed messages
    then `mark_close()` — byte-for-byte the shape a buffered GCS object
    upload builds."""
    var enc = ClientStreamEncoder[ProtocolGrpcProto].new()
    enc.encode_message(Span(_b(_PAYLOAD_A)))
    enc.encode_message(Span(_b(_PAYLOAD_B)))
    enc.mark_close()
    return enc^


def _contains(haystack: List[UInt8], needle: String) -> Bool:
    """Does `haystack` contain `needle`'s bytes? Used on an h2 write capture,
    where DATA payloads appear verbatim (h2 compresses HEADERS, never DATA)."""
    var n = _b(needle)
    if len(n) == 0 or len(haystack) < len(n):
        return False
    var limit = len(haystack) - len(n)
    var i = 0
    while i <= limit:
        var j = 0
        var hit = True
        while j < len(n):
            if haystack[i + j] != n[j]:
                hit = False
                break
            j = j + 1
        if hit:
            return True
        i = i + 1
    return False


# -----------------------------------------------------------------------------
# (t1) ABOVE Last-Stream-ID -> re-dial and succeed.
# -----------------------------------------------------------------------------


def test_bug_client_stream_goaway_above_last_stream_id_is_reissued() raises:
    """RED without the client-stream re-issue: the driver's raise escapes
    verbatim and the upload fails. GREEN with it: the RPC re-dials and
    returns the response the second connection serves."""
    print("  (t1) client-stream GOAWAY above Last-Stream-ID -> re-issued...")

    # Connection 1 drains immediately, having processed NOTHING (last=0 < our
    # stream 1). Connection 2 serves the real WriteObjectResponse.
    var conn1 = _h2_stream(_goaway_script(last_stream_id=0))
    var connector = ScriptedConnector.with_stream(conn1^)
    connector.arm_next(_h2_stream(_write_object_ok_script(String("GEN-1755"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _gcs_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()

    var result = grpc.client_stream[RT, ProtocolGrpcProto](
        String(_RPC_PATH),
        _write_object_encoder(),
        opts,
        Int(0),
        reactor,
        token,
    )

    var got = String("")
    for i in range(len(result.message_bytes)):
        got += chr(Int(result.message_bytes[i]))
    assert_equal(
        got,
        String("GEN-1755"),
        "the re-issued client-stream RPC must return the SECOND connection's"
        " response — without the re-issue the GOAWAY raise escapes"
        " `client_stream` and the WriteObject fails",
    )

    # THE MECHANISM, not just the outcome: a retry that re-used the DRAINING
    # connection would meet the same GOAWAY forever. Two dials proves the
    # re-issue went out on a NEW connection (RFC 9113 §6.8: a receiver MUST NOT
    # open additional streams on a GOAWAY'd connection).
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        2,
        "the re-issue must dial a NEW connection, not re-check-out the pooled"
        " one that just sent GOAWAY",
    )
    print("    OK — retried once, on a fresh conn, and returned the response")


# -----------------------------------------------------------------------------
# (t2) AT-OR-BELOW Last-Stream-ID -> must NOT be retried.
# -----------------------------------------------------------------------------


def test_bug_client_stream_goaway_at_or_below_is_not_retried() raises:
    """The correctness half. `Last-Stream-ID = 1` INCLUDES our stream 1, so RFC
    9113 §6.8 gives NO not-processed guarantee — the peer MAY have persisted the
    object. Replaying a `WriteObject` here is a duplicate write, and the
    re-issue must not widen the gate into "any GOAWAY"."""
    print("  (t2) client-stream GOAWAY at-or-below -> NOT retried...")

    var conn1 = _h2_stream(_goaway_script(last_stream_id=1))
    var connector = ScriptedConnector.with_stream(conn1^)
    # A fully-successful second connection is ARMED and must remain UNUSED.
    # Reaching it is the failure signal.
    connector.arm_next(_h2_stream(_write_object_ok_script(String("GEN-BAD"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _gcs_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()

    var raised = False
    try:
        var _r = grpc.client_stream[RT, ProtocolGrpcProto](
            String(_RPC_PATH),
            _write_object_encoder(),
            opts,
            Int(0),
            reactor,
            token,
        )
    except e:
        raised = True
        assert_true(
            String("h2-goaway-unprocessed") not in String(e),
            "the at-or-below class must NOT carry the not-processed token —"
            " if it does, the discriminator has collapsed and every GOAWAY is"
            " being replayed. Got: " + String(e),
        )

    assert_true(
        raised,
        "a GOAWAY whose Last-Stream-ID INCLUDES our stream carries no"
        " not-processed guarantee and MUST surface to the caller; retrying it"
        " would double-write the object",
    )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        1,
        "the at-or-below class must NOT dial a second connection — the armed"
        " success script proves a wrongly-retrying client would have returned"
        " a response instead of raising",
    )
    print("    OK — raised, and did not dial again")


# -----------------------------------------------------------------------------
# (t3) The re-issued request is BYTE-FRESH.
# -----------------------------------------------------------------------------


def test_bug_client_stream_reissue_resends_the_whole_request_body() raises:
    """THE MECHANISM ASSERTION. A retry that sends an EMPTY body would still
    satisfy (t1) — the scripted peer replays its script regardless of what it
    received — and would silently commit a zero-byte object.

    This pins the tempting-but-false claim that draining
    the encoder "EMPTIES the caller's buffer" so a byte-fresh rebuild is
    impossible. `drain_chunk` advances `_drain_cursor` and never truncates
    `_buf`, so `rewind_for_reissue()` restores the whole body for free. Remove
    that call and attempt 2 writes no DATA at all ⇒ this arm goes RED."""
    print("  (t3) the re-issue re-sends the WHOLE request body...")

    var cap1 = ArcPointer[List[UInt8]](List[UInt8]())
    var cap2 = ArcPointer[List[UInt8]](List[UInt8]())

    var conn1 = _h2_stream_capturing(_goaway_script(last_stream_id=0), cap1)
    var connector = ScriptedConnector.with_stream(conn1^)
    connector.arm_next(
        _h2_stream_capturing(
            _write_object_ok_script(String("GEN-1756")), cap2
        )
    )

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _gcs_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()

    var _result = grpc.client_stream[RT, ProtocolGrpcProto](
        String(_RPC_PATH),
        _write_object_encoder(),
        opts,
        Int(0),
        reactor,
        token,
    )

    # Attempt 1 carried the body (the GOAWAY arrives after the request is on
    # the wire — that is why the stream id is allocated at all).
    assert_true(
        _contains(cap1[], _PAYLOAD_A) and _contains(cap1[], _PAYLOAD_B),
        "attempt 1 must have written BOTH request messages — if not, this"
        " fixture is not exercising the path it claims to",
    )
    # Attempt 2 must carry the SAME body, rebuilt from the encoder.
    assert_true(
        _contains(cap2[], _PAYLOAD_A),
        "the RE-ISSUED request must re-send the first client-stream message."
        " An empty re-issue would still pass (t1) and would commit a"
        " zero-byte object in production",
    )
    assert_true(
        _contains(cap2[], _PAYLOAD_B),
        "the RE-ISSUED request must re-send EVERY client-stream message, not"
        " just the first — the whole framed buffer is replayed, not a chunk",
    )
    print("    OK — both messages re-sent on the fresh connection")


# -----------------------------------------------------------------------------
# (t4) The retry is BOUNDED and says so.
# -----------------------------------------------------------------------------


def test_bug_client_stream_goaway_retry_is_bounded() raises:
    """A peer recycling connections faster than it serves them must make the
    call FAIL, not spin. Six connections are armed; exactly
    `_GOAWAY_RETRY_MAX_ATTEMPTS` must be consumed, and the give-up must name
    both bounds and which one stopped it (an exhaustion that cannot be
    diagnosed without a rebuild is useless in a log)."""
    print("  (t4) the client-stream re-issue is bounded...")

    var conn1 = _h2_stream(_goaway_script(last_stream_id=0))
    var connector = ScriptedConnector.with_stream(conn1^)
    for _i in range(5):
        connector.arm_next(_h2_stream(_goaway_script(last_stream_id=0)))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _gcs_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()

    var msg = String("")
    var raised = False
    try:
        var _r = grpc.client_stream[RT, ProtocolGrpcProto](
            String(_RPC_PATH),
            _write_object_encoder(),
            opts,
            Int(0),
            reactor,
            token,
        )
    except e:
        raised = True
        msg = String(e)

    assert_true(raised, "an every-connection-GOAWAYs peer must fail the call")
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        _GOAWAY_RETRY_MAX_ATTEMPTS,
        "the client-stream re-issue must stop at _GOAWAY_RETRY_MAX_ATTEMPTS;"
        " six connections were armed, so a spin would consume more",
    )
    assert_true(
        String("H2_GOAWAY_RETRY_EXHAUSTED") in msg,
        "the give-up must be the EXHAUSTED class, not a raw GOAWAY — the raw"
        " form reads as a network fault. Got: "
        + msg,
    )
    assert_true(
        String("max_attempts=") in msg and String("budget_ms=") in msg,
        "the exhaustion must name BOTH bounds. Got: " + msg,
    )
    assert_true(
        String("stopped_on=") in msg,
        "the exhaustion must say WHICH bound stopped it. Got: " + msg,
    )
    print("    OK — bounded at", _GOAWAY_RETRY_MAX_ATTEMPTS, "attempts")


def main() raises:
    print("=== client-stream GOAWAY-unprocessed re-issue (WriteObject) ===")
    test_bug_client_stream_goaway_above_last_stream_id_is_reissued()
    test_bug_client_stream_goaway_at_or_below_is_not_retried()
    test_bug_client_stream_reissue_resends_the_whole_request_body()
    test_bug_client_stream_goaway_retry_is_bounded()
    print("=== ALL PASS ===")
