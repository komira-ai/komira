"""FALSIFIER — a transport fault that PROVED the peer did not process the
request must be re-issued on the gRPC path, bounded, and distinguishable from a
retry that never ran.

A caller that polls a long-running operation once per tick through
`GetOperation` (for example a deploy waiting on a Cloud Run create) leaves its
pooled connection idle across the whole inter-tick gap. Without this re-issue
every tick fails the same way:

    CloudRun GetOperation failed [UNKNOWN]: HttpError[RETRYABLE_TRANSPORT…]

and the caller makes no progress.

⛔ THE CLASSIFICATION IS NOT A RETRY BY ITSELF. On the gRPC path:

  * `is_retryable_grpc_error` returns False for any message with no `[grpc:`
    anchor, by design — it is a STATUS-CODE gate and a transport fault has no
    status.
  * A `_not_processed_retry_or_raise` gated on `is_h2_goaway_unprocessed` ONLY
    would re-raise everything else verbatim.

WHY THE SOCKET IS DEAD. `H2ClientPool` checkout has no liveness and no idle-age
check. A client built ONCE and used for one `GetOperation` per tick keeps its
pooled connection to `run.googleapis.com` idle across the whole inter-tick gap,
the front end reaps it, and the next checkout writes into a dead socket -> TCP
RST -> zero response bytes.

⭐ AND THE RETRY IS SAFE ON THE SAME PROOF THE GOAWAY ARM ALREADY ACCEPTS. Every
emitter of this class carries a NOT-PROCESSED proof — `total_read == 0` /
`len(self._recv_buf) == 0`, or RFC 9113 §8.7 REFUSED_STREAM — which is the same
proof class `_not_processed_retry_or_raise` already treats as sufficient to
replay a NON-IDEMPOTENT `CreateJob`. The gate is that proof, NEVER the word
"retryable": (t2) is the arm that holds that line.

WHAT THIS FILE FALSIFIES:

  (t1) RE-ISSUE — RST_STREAM(REFUSED_STREAM) on connection 1 must re-dial and
       return connection 2's response. Without the re-issue the raise escapes
       verbatim ⇒ RED.
  (t2) THE LINE — RST_STREAM(CANCEL) is `H2_STREAM_RESET`, carries NO proof, and
       must NOT be retried. A fully-successful second connection is ARMED and
       must remain UNUSED; "it returned a response" IS the failure signal. This
       arm is green with or without the re-issue and exists to stop (t1)'s
       re-issue becoming a blanket retry on the word "RETRYABLE".
  (t3) BOUNDED — a peer that refuses every connection must stop at
       `_GOAWAY_RETRY_MAX_ATTEMPTS`, not spin. Six connections are armed; exactly
       four must be consumed.
  (t4) THE TOKEN — the give-up must be `H2_TRANSPORT_RETRY_EXHAUSTED`, NOT the
       GOAWAY token (an operator must not be sent hunting a GOAWAY that is not
       there), and it must name both bounds and which one stopped it. This is
       what makes an exhausted retry distinguishable from one that never ran.
  (t5) THE STREAMING ARM — the same decision function serves `server_stream`,
       which is the GCS `ReadObject` shape. One arm proves the gate reaches it
       too.

★ (t1)/(t5)'s `connect_call_count() == 2` IS ALSO THE POOL-LIVENESS ANSWER. A
retry that re-checked out the SAME dead socket would buy nothing. It cannot:
`HttpClient._drive_grpc_pooled_found` takes the pool BY VALUE, so a raise from
the drive destroys the whole pool during unwind while `self._h2_pool` is already
empty from the `.take()` that started the send — the next attempt's
`ensure_h2_pool` finds nothing and takes the NEEDS_DIAL path. These assertions
pin that behaviourally, so it cannot silently regress into conn reuse.

The peer is a `ScriptedStream` — a byte script, no socket, no network, no
thread. Hermetic.
"""

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient
from komira_http.client.h2_client import (
    H2_RETRYABLE_TRANSPORT_TOKEN,
    is_h2_goaway_unprocessed,
    is_h2_retryable_transport,
)
from komira_http.client.url import Url
from komira_http.codec.h2.frame import (
    H2_ERR_CANCEL,
    H2_ERR_REFUSED_STREAM,
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_rst_stream_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    CallOptions,
    GrpcClient,
    ProtocolGrpcProto,
    encode_unary_request,
)
from komira_grpc.stream import (
    STREAM_OUTCOME_MESSAGE,
    ServerStreamDecoder,
)
from komira_grpc.client import _GOAWAY_RETRY_MAX_ATTEMPTS


comptime RT = PerCoreAsyncRuntime[NoopSink]

# The unary shape a re-entrant long-running-operation poll issues.
comptime _RPC_PATH: String = "/google.longrunning.Operations/GetOperation"
# The server-streaming shape a GCS object read issues.
comptime _STREAM_RPC_PATH: String = "/google.storage.v2.Storage/ReadObject"

# The client allocates odd stream ids from 1 on every FRESH connection, so the
# first RPC on any connection is stream 1.
comptime _FIRST_CLIENT_STREAM_ID: Int = 1


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime
    if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _rst_script(rst_error_code: UInt32) raises -> List[UInt8]:
    """A connection that greets and then RESETS our stream: server SETTINGS,
    then RST_STREAM(`rst_error_code`) on stream 1, then EOF.

    REFUSED_STREAM is RFC 9113 §8.7's definitive not-processed case — the peer
    states it took no action. Every other code means it MAY have executed the
    request before giving up, which is the (t1)/(t2) discriminator and the ONLY
    byte that differs between the two fixtures."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    encode_rst_stream_frame(
        UInt32(_FIRST_CLIENT_STREAM_ID), rst_error_code, out,
    )
    return out^


def _success_script(payload: String) raises -> List[UInt8]:
    """A connection that serves ONE successful unary gRPC response on stream 1."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)

    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(payload)))

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
    `send_grpc_pooled` drops the dial and falls back to HTTP/1.1, which never
    produces an h2 RST_STREAM at all."""
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    return s^


def _cloud_run_base() raises -> Url:
    """An https authority, so `send_grpc_pooled` takes the pooled-h2 path the
    https Cloud Run client takes (its plaintext branch is h1)."""
    return Url.parse(String("https://run.googleapis.com:443/"))


def _drain_decoder_messages(
    mut decoder: ServerStreamDecoder[ProtocolGrpcProto],
) raises -> List[String]:
    var out = List[String]()
    while True:
        var outcome = decoder.try_next_message()
        if outcome.kind != STREAM_OUTCOME_MESSAGE:
            break
        var text = String("")
        for i in range(len(outcome.message_bytes)):
            text += chr(Int(outcome.message_bytes[i]))
        out.append(text^)
    return out^


# -----------------------------------------------------------------------------
# (t1) REFUSED_STREAM -> re-dial and succeed.
# -----------------------------------------------------------------------------
def test_bug_retryable_transport_is_reissued_on_a_new_conn() raises:
    """RED if `_not_processed_retry_or_raise` gates on
    `is_h2_goaway_unprocessed` alone: the RETRYABLE_TRANSPORT raise escapes
    verbatim and the RPC fails, every tick. GREEN with the transport proof
    accepted: the RPC re-dials and returns the response the second connection
    serves."""
    print("  (t1) RETRYABLE_TRANSPORT -> re-issued on a fresh conn...")

    var conn1 = _h2_stream(_rst_script(H2_ERR_REFUSED_STREAM))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    connector.arm_next(_h2_stream(_success_script(String("OPERATION-DONE"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/operations/o"))

    var result = grpc.unary_call[RT, ProtocolGrpcProto](
        String(_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
    )

    var got = String("")
    for i in range(len(result.message_bytes)):
        got += chr(Int(result.message_bytes[i]))
    assert_equal(
        got,
        String("OPERATION-DONE"),
        "the re-issued RPC must return the SECOND connection's response —"
        " without the re-issue the RETRYABLE_TRANSPORT raise escapes and the call fails",
    )

    # ★ THE MECHANISM, AND THE POOL-LIVENESS ANSWER. A retry that re-checked out
    # the SAME dead socket would meet the same fault forever and buy nothing.
    # Two dials proves the re-issue went out on a NEW connection.
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        2,
        "the re-issue must dial a NEW connection — a retry onto the reaped"
        " socket is not a fix",
    )
    print("    OK — retried once, on a fresh conn, and returned the response")


# -----------------------------------------------------------------------------
# (t2) RST(CANCEL) -> must NOT be retried. THE CORRECTNESS HALF.
# -----------------------------------------------------------------------------
def test_bug_stream_reset_without_proof_is_not_retried() raises:
    """The line the re-issue must not cross. RST_STREAM(CANCEL) is classified
    `H2_STREAM_RESET`: outside REFUSED_STREAM the peer MAY have executed the
    request before resetting, so there is no not-processed proof and an
    automatic replay would double-execute a non-idempotent verb.

    The ONLY difference from (t1) is the RST error code. A fully-successful
    second connection is ARMED; a gate written on the word "RETRYABLE" — or on
    "any transport fault" — consumes it and returns a response. That is the
    failure this asserts against."""
    print("  (t2) RST(CANCEL) carries no proof -> NOT retried...")

    var conn1 = _h2_stream(_rst_script(H2_ERR_CANCEL))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    # The trap: armed, and must remain unused.
    connector.arm_next(_h2_stream(_success_script(String("MUST-NOT-REACH"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/operations/o"))

    var raised = False
    var message = String("")
    var returned = String("")
    try:
        var result = grpc.unary_call[RT, ProtocolGrpcProto](
            String(_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
        )
        for i in range(len(result.message_bytes)):
            returned += chr(Int(result.message_bytes[i]))
    except e:
        raised = True
        message = String(e)

    assert_true(
        raised,
        "RST(CANCEL) must RAISE, not be replayed. It returned: " + returned,
    )
    assert_true(
        String("H2_STREAM_RESET") in message,
        "the raise must be the no-proof class, verbatim; got " + message,
    )
    assert_true(
        not is_h2_retryable_transport(message),
        "the no-proof class must not be classified re-issuable; got " + message,
    )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        1,
        "exactly ONE dial — a second means the armed success connection was"
        " consumed, i.e. a request with no not-processed proof was replayed",
    )
    print("    OK — raised verbatim, and did NOT dial again")


# -----------------------------------------------------------------------------
# (t3)+(t4) BOUNDED, and the give-up names ITS OWN class.
# -----------------------------------------------------------------------------
def test_bug_retryable_transport_retry_is_bounded_and_names_its_class() raises:
    """An unbounded retry is how a caller hangs forever instead of failing,
    which is strictly worse than the bug being fixed. Six connections are armed
    and every one of them refuses; exactly `_GOAWAY_RETRY_MAX_ATTEMPTS` must be
    consumed.

    ⭐ AND THE GIVE-UP MUST BE DISTINGUISHABLE FROM A RETRY THAT NEVER RAN. The
    exhaustion token is what makes "we tried four fresh connections and every
    one was refused" different from "nothing retried this at all", and the
    latter must not be able to masquerade as the former. It must also NOT be
    the GOAWAY token: the
    reason word is the first thing an operator reads, and there is no GOAWAY
    here to go looking for."""
    print("  (t3/t4) bounded, and the give-up names its own class...")

    var conn1 = _h2_stream(_rst_script(H2_ERR_REFUSED_STREAM))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    var armed = 6
    for _i in range(armed - 1):
        connector.arm_next(_h2_stream(_rst_script(H2_ERR_REFUSED_STREAM)))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/operations/o"))

    var raised = False
    var message = String("")
    try:
        var _r = grpc.unary_call[RT, ProtocolGrpcProto](
            String(_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
        )
    except e:
        raised = True
        message = String(e)

    assert_true(raised, "a peer that refuses every connection must GIVE UP")

    # (t3) THE BOUND — exactly the attempt cap, not the armed supply.
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        _GOAWAY_RETRY_MAX_ATTEMPTS,
        (
            "the re-issue must stop at the attempt cap ("
            + String(_GOAWAY_RETRY_MAX_ATTEMPTS)
            + "), not consume every armed connection ("
            + String(armed)
            + ") — an unbounded retry is a hang"
        ),
    )

    # (t4) THE TOKEN + the diagnosable give-up.
    assert_true(
        String("H2_TRANSPORT_RETRY_EXHAUSTED") in message,
        (
            "the give-up must carry its OWN exhaustion token, so an exhausted"
            " retry is distinguishable from one that never ran; got " + message
        ),
    )
    assert_true(
        String("H2_GOAWAY_RETRY_EXHAUSTED") not in message,
        (
            "and it must NOT be the GOAWAY token — there was no GOAWAY, and the"
            " reason word is the first thing an operator reads; got " + message
        ),
    )
    var required = List[String]()
    required.append(String("max_attempts="))
    required.append(String("budget_ms="))
    required.append(String("stopped_on=attempts"))
    required.append(String("Last: "))
    for i in range(len(required)):
        assert_true(
            required[i] in message,
            (
                "the give-up must be diagnosable without a rebuild — missing `"
                + required[i]
                + "` in: "
                + message
            ),
        )
    print("    OK — stopped at the cap, named its own class and both bounds")


# -----------------------------------------------------------------------------
# (t5) THE SERVER-STREAMING ARM — the GCS object-read shape.
# -----------------------------------------------------------------------------
def test_bug_server_stream_retryable_transport_is_reissued() raises:
    """`server_stream` routes through the SAME decision function, so the gate
    must reach it too. This is the GCS `ReadObject` shape, and a reader that
    idles between reads meets a reaped connection exactly as the
    long-running-operation poll does."""
    print("  (t5) server-stream RETRYABLE_TRANSPORT -> re-issued...")

    var conn1 = _h2_stream(_rst_script(H2_ERR_REFUSED_STREAM))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    connector.arm_next(_h2_stream(_success_script(String("REGISTRY-ROW"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/_/buckets/b/objects/service%2Fexample-svc"))

    var decoder = grpc.server_stream[RT, ProtocolGrpcProto](
        String(_STREAM_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
    )
    var msgs = _drain_decoder_messages(decoder)

    assert_equal(
        len(msgs),
        1,
        "the re-issued server-stream must yield the SECOND connection's one"
        " message — without the re-issue the raise escapes and the read fails",
    )
    assert_equal(
        msgs[0],
        String("REGISTRY-ROW"),
        "and it must be that connection's payload, byte for byte",
    )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        2,
        "the re-issue must dial a NEW connection",
    )
    print("    OK — retried once, on a fresh conn, and returned the stream")


# -----------------------------------------------------------------------------
# (t6) THE PREDICATE ITSELF — the gate is the PROOF, never the word.
# -----------------------------------------------------------------------------
def test_not_processed_predicates_are_disjoint_and_exclude_the_giveups() raises:
    """⛔ THE ONE WAY TO WRITE THIS GATE THAT LOOPS FOREVER. Both give-up
    messages contain the word "RETRY"/"RETRYABLE"-adjacent text, and
    `H2_TRANSPORT_RETRY_EXHAUSTED` is itself raised BY the retry layer. A gate
    that grepped for "RETRYABLE" rather than keying on the class token would
    accept its own exhaustion message and re-enter the loop it just left.

    Also pins that the two proof classes stay DISJOINT: if either predicate ever
    starts answering True for the other's message the discriminator has
    collapsed, and (t2)'s correctness half collapses with it."""
    print("  (t6) predicate hygiene...")

    var transport = String(
        "HttpError[RETRYABLE_TRANSPORT]: h2 driver read s2n_errno=67108864"
        " with ZERO response bytes received"
    )
    var goaway = String(
        "HttpError[H2_PROTOCOL]: GOAWAY received; h2-goaway-unprocessed"
    )
    var giveup_t = String(
        "HttpError[H2_TRANSPORT_RETRY_EXHAUSTED]: gave up re-issuing /x"
    )
    var giveup_g = String(
        "HttpError[H2_GOAWAY_RETRY_EXHAUSTED]: gave up re-issuing /x"
    )
    var no_proof = String(
        "HttpError[IO_ERROR]: h2 driver read s2n_errno=1 after 8 response bytes"
    )

    assert_true(is_h2_retryable_transport(transport), "the class matches itself")
    assert_true(
        not is_h2_goaway_unprocessed(transport),
        "and it is NOT the GOAWAY class",
    )
    assert_true(
        not is_h2_retryable_transport(goaway),
        "the GOAWAY class is NOT the transport class",
    )
    # ⛔ THE LOOP GUARD.
    assert_true(
        not is_h2_retryable_transport(giveup_t),
        "the transport GIVE-UP must not re-enter the retry loop",
    )
    assert_true(
        not is_h2_retryable_transport(giveup_g),
        "nor must the GOAWAY give-up",
    )
    assert_true(
        not is_h2_goaway_unprocessed(giveup_g),
        "the GOAWAY give-up must not re-enter its own loop either",
    )
    assert_true(
        not is_h2_retryable_transport(no_proof),
        "a fault AFTER response bytes carries no proof and must not match",
    )
    # The token must remain the class marker the emitters actually write.
    assert_true(
        String(H2_RETRYABLE_TRANSPORT_TOKEN) in transport,
        "the token must be what the raise sites emit, or the predicate is blind",
    )
    print("    OK — disjoint, and neither give-up re-enters a retry loop")


def main() raises:
    print("test_retryable_transport_reissue...")
    test_bug_retryable_transport_is_reissued_on_a_new_conn()
    test_bug_stream_reset_without_proof_is_not_retried()
    test_bug_retryable_transport_retry_is_bounded_and_names_its_class()
    test_bug_server_stream_retryable_transport_is_reissued()
    test_not_processed_predicates_are_disjoint_and_exclude_the_giveups()
    print("OK test_retryable_transport_reissue")
