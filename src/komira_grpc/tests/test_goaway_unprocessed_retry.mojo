"""FALSIFIER — an HTTP/2 GOAWAY that EXCLUDES our stream is an explicit
"not processed, retry me", and must be retried; one that INCLUDES it must not.

A peer that recycles a connection answers an in-flight RPC with

    HttpError[H2_PROTOCOL]: GOAWAY received; stream 37 > last_stream_id 35;
      will not be processed

The message states the correct conclusion; failing the RPC anyway would be a
missing retry. RFC 9113 §6.8: a GOAWAY carries `Last-Stream-ID`, and streams
numbered ABOVE it were definitively not processed by the peer — the canonical
remedy is to re-issue them on a NEW connection, and it is safe to do so **even
for a non-idempotent verb**, because the peer has stated it took no action.
Google's front ends send GOAWAY routinely to drain and recycle connections, so
any RPC that lives long enough (a `GetExecution` poll across a multi-minute
deploy) WILL meet one. This is not a network fault.

⚠ AND THE OTHER HALF IS A CORRECTNESS HAZARD. A stream numbered AT-OR-BELOW
`Last-Stream-ID` "might still complete successfully" (§6.8) — the peer may have
executed it. Blanket-retrying every GOAWAY would double-execute a `CreateJob` or
a `RunJob`. The stream-id comparison is the ONLY thing that makes the retry
safe, so this file tests BOTH directions: the two cases below differ in ONE
byte of the GOAWAY frame's `Last-Stream-ID` field (0 vs 1) and must produce
OPPOSITE behaviour.

WHAT THIS FILE FALSIFIES:

  (g1) ABOVE  — GOAWAY(last=0) against our stream 1: the RPC must RE-DIAL and
       SUCCEED. Without the re-issue the raise escapes `unary_call` verbatim
       ⇒ RED.
  (g2) BELOW  — GOAWAY(last=1) against our stream 1: the RPC must RAISE and
       must NOT dial again. A second, fully-successful connection is ARMED and
       waiting; only a wrongly-retrying implementation reaches it, so "it
       returned a response" IS the failure signal here.
  (g3) BOUND  — a peer that GOAWAYs every connection must stop at
       `_GOAWAY_RETRY_MAX_ATTEMPTS`, not spin. Six connections are armed; four
       must be consumed. An unbounded retry is how a caller hangs forever
       instead of failing, which is worse than the bug being fixed.
  (g4) MESSAGE — the exhaustion error must say how many attempts over how long,
       plus both bounds and which one stopped it: a give-up that cannot be
       diagnosed without a rebuild is useless in a log.
  (g5) BUDGET — the caller-supplied wall-clock budget is FAIL-SAFE: every
       rejection path returns the default, so the setting can state a budget
       and never remove one; and `GrpcClient.with_retry_budget_ms` is the
       channel that sets it.
  (g6) TOKENS — neither disposition token is a substring of the other. If they
       ever overlap, the discriminator silently collapses into the blanket
       retry that (g2) exists to prevent.

⭐ (g7)(g8)(g9) THE SAME THREE QUESTIONS, ON THE SERVER-STREAMING ARM.

A re-issue on `unary_call` alone does not cover a GCS `ReadObject`, which is
SERVER-STREAMING: `server_stream` needs its own re-issue, and
`send_grpc_pooled` has no GOAWAY retry inside it either, so without one a RAW
GOAWAY escapes rather than `H2_GOAWAY_RETRY_EXHAUSTED`.

  (g7) ABOVE  — a server-streaming RPC meeting GOAWAY(last=0) must RE-DIAL and
       return the second connection's messages. Without the re-issue the raise
       escapes `server_stream` verbatim ⇒ RED.
  (g8) BOUND  — a peer that GOAWAYs every connection must stop at
       `_GOAWAY_RETRY_MAX_ATTEMPTS` and surface `H2_GOAWAY_RETRY_EXHAUSTED`,
       the SAME message the unary arm emits. Without the re-issue the raw h2
       error surfaces on attempt one ⇒ RED.
  (g9) BELOW  — GOAWAY(last=1) INCLUDES our stream, so the correctness half
       must hold here too: no second dial, no retry. A fully-successful second
       connection is ARMED and must remain unused. This one is green with or
       without the re-issue and is here to stay green — it is what stops
       (g7)'s re-issue from becoming a blanket retry.

The client-streaming arm is covered by `test_client_stream_goaway_reissue`.
`bidi_stream` is NOT covered, deliberately: its codec is drained in place by a
caller that may interleave (see `_send_client_stream_bounded_goaway_retry`). A
GOAWAY on it propagates verbatim.

The peer is a `ScriptedStream` — a byte script, no socket, no network, no
thread. Hermetic.
"""

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient
from komira_http_client.h2_client import (
    H2_GOAWAY_MAYBE_PROCESSED_TOKEN,
    H2_GOAWAY_UNPROCESSED_TOKEN,
    is_h2_goaway_unprocessed,
)
from komira_http_client.url import Url
from komira_http_core.codec.h2.frame import (
    H2_ERR_NO_ERROR,
    SettingsEntry,
    encode_data_frame,
    encode_goaway_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

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
from komira_grpc.client import (
    _GOAWAY_RETRY_MAX_ATTEMPTS,
    _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT,
    _resolve_goaway_retry_budget_us,
)


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _RPC_PATH: String = "/google.cloud.run.v2.Executions/GetExecution"

# The client allocates odd stream ids from 1 on every FRESH connection, so the
# first RPC on any connection is stream 1. Both GOAWAY cases below are stated
# relative to that one fact.
comptime _FIRST_CLIENT_STREAM_ID: Int = 1


# -----------------------------------------------------------------------------
# Fixtures — the two server scripts. They differ ONLY in Last-Stream-ID.
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
    nothing; `=1` means it may have processed our stream 1.
    """
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var debug = List[UInt8]()
    encode_goaway_frame(
        UInt32(last_stream_id), H2_ERR_NO_ERROR, debug^, out,
    )
    return out^


def _success_script(payload: String) raises -> List[UInt8]:
    """A connection that serves ONE successful unary gRPC response on stream 1:
    SETTINGS + HEADERS(:status 200, application/grpc, grpc-status 0) +
    DATA(5-byte-enveloped `payload`, END_STREAM)."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)

    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(payload)))

    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
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


def _cloud_run_base() raises -> Url:
    """An https authority, so `send_grpc_pooled` takes the pooled-h2 path the
    path an https Cloud Run client takes (its plaintext branch is h1)."""
    return Url.parse(String("https://run.googleapis.com:443/"))


# -----------------------------------------------------------------------------
# (g1) ABOVE Last-Stream-ID -> re-dial and succeed.
# -----------------------------------------------------------------------------


def test_bug_goaway_above_last_stream_id_is_reissued_on_a_new_conn() raises:
    """RED without the re-issue: the driver's raise escapes `unary_call`
    verbatim and the RPC fails. GREEN with it: the RPC re-dials and returns
    the response the second connection serves."""
    print("  (g1) GOAWAY above Last-Stream-ID -> re-issued...")

    # Connection 1 drains immediately, having processed NOTHING (last=0 < our
    # stream 1). Connection 2 serves the real answer.
    var conn1 = _h2_stream(_goaway_script(last_stream_id=0))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    connector.arm_next(_h2_stream(_success_script(String("EXECUTION-OK"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/jobs/j/executions/e"))

    var result = grpc.unary_call[RT, ProtocolGrpcProto](
        String(_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
    )

    var got = String("")
    for i in range(len(result.message_bytes)):
        got += chr(Int(result.message_bytes[i]))
    assert_equal(
        got,
        String("EXECUTION-OK"),
        "the re-issued RPC must return the SECOND connection's response —"
        " without the re-issue the GOAWAY raise escapes and the call fails",
    )

    # THE MECHANISM, not just the outcome: a retry that re-used the DRAINING
    # connection would meet the same GOAWAY forever. Two dials proves the
    # re-issue went out on a NEW connection.
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        2,
        "the re-issue must dial a NEW connection (RFC 9113 §6.8: a receiver"
        " MUST NOT open additional streams on a GOAWAY'd connection)",
    )
    print("    OK — retried once, on a fresh conn, and returned the response")


# -----------------------------------------------------------------------------
# (g2) AT-OR-BELOW Last-Stream-ID -> must NOT be retried.
# -----------------------------------------------------------------------------


def test_bug_goaway_at_or_below_last_stream_id_is_not_retried() raises:
    """The correctness half. `Last-Stream-ID = 1` INCLUDES our stream 1, so RFC
    9113 §6.8 gives no not-processed guarantee — the peer may have executed the
    request. Auto-retrying it would double-execute a non-idempotent verb.

    A fully-successful second connection is ARMED. A blanket "retry every
    GOAWAY" implementation consumes it and returns a response; that is the
    failure this asserts against. The ONLY difference from (g1) is the
    Last-Stream-ID byte."""
    print("  (g2) GOAWAY at-or-below Last-Stream-ID -> NOT retried...")

    var conn1 = _h2_stream(_goaway_script(last_stream_id=1))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    # The trap: armed, and must remain unused.
    connector.arm_next(_h2_stream(_success_script(String("MUST-NOT-REACH"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/jobs/j/executions/e"))

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

    if not raised:
        raise Error(
            "an at-or-below GOAWAY was RETRIED and returned '"
            + returned
            + "' — the peer may already have executed this request, so the"
            " retry duplicated a non-idempotent verb. The stream-id comparison"
            " is the only thing that makes the (g1) retry safe and it has been"
            " lost."
        )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        1,
        "an at-or-below GOAWAY must NOT dial again — a second dial IS the"
        " retry, whatever the call went on to return",
    )
    assert_true(
        H2_GOAWAY_MAYBE_PROCESSED_TOKEN in message,
        String(
            "the at-or-below class must name itself so it can never be"
            " mistaken for the retry-safe one. got: "
        )
        + message,
    )
    assert_true(
        not is_h2_goaway_unprocessed(message),
        String(
            "`is_h2_goaway_unprocessed` must be FALSE for the at-or-below"
            " class — it is the retry gate. got: "
        )
        + message,
    )
    print("    OK — raised, dialled once, and named the maybe-processed class")


# -----------------------------------------------------------------------------
# (g3)+(g4) the retry is BOUNDED, and says so when it gives up.
# -----------------------------------------------------------------------------


def test_bug_goaway_retry_is_bounded_and_says_how_many_over_how_long() raises:
    """A peer that GOAWAYs every connection must terminate. Six connections are
    armed; exactly `_GOAWAY_RETRY_MAX_ATTEMPTS` must be consumed — the extra two
    are what distinguishes "bounded at 4" from "bounded by the fixture"."""
    print("  (g3/g4) retry is bounded + the give-up carries evidence...")
    var connector = ScriptedConnector.with_stream_tls(
        _h2_stream(_goaway_script(last_stream_id=0))
    )
    var armed = 6
    for _i in range(armed - 1):
        connector.arm_next(_h2_stream(_goaway_script(last_stream_id=0)))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l/jobs/j/executions/e"))

    var raised = False
    var message = String("")
    try:
        var _r = grpc.unary_call[RT, ProtocolGrpcProto](
            String(_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
        )
    except e:
        raised = True
        message = String(e)

    assert_true(
        raised,
        "a peer that GOAWAYs every connection must eventually FAIL, not"
        " succeed and not spin",
    )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        _GOAWAY_RETRY_MAX_ATTEMPTS,
        String(
            "the retry must stop at _GOAWAY_RETRY_MAX_ATTEMPTS dials, not"
            " consume every armed connection (armed: "
        )
        + String(armed)
        + String(")"),
    )

    # (g4) the give-up must be diagnosable without a rebuild.
    var required = List[String]()
    required.append(String("H2_GOAWAY_RETRY_EXHAUSTED"))  # the class
    required.append(String(_RPC_PATH))  # which RPC
    required.append(
        String(_GOAWAY_RETRY_MAX_ATTEMPTS) + String(" attempt(s) over")
    )  # how many
    required.append(String(" ms ("))  # ... over how long
    required.append(
        String("max_attempts=") + String(_GOAWAY_RETRY_MAX_ATTEMPTS)
    )  # bound 1
    required.append(
        String("budget_ms=")
        + String(Int(_GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT // Int64(1000)))
    )  # bound 2
    required.append(String("stopped_on=attempts"))  # WHICH bound stopped it
    required.append(H2_GOAWAY_UNPROCESSED_TOKEN)  # the underlying class
    for i in range(len(required)):
        if required[i] not in message:
            raise Error(
                "exhaustion message is missing '"
                + required[i]
                + "' — a give-up that names neither its bounds nor what it"
                " spent cannot be diagnosed from a log. message: "
                + message
            )
    print("    OK — stopped at 4 dials and named both bounds")


# -----------------------------------------------------------------------------
# (g5) the wall-clock budget override is fail-safe.
# -----------------------------------------------------------------------------


def test_goaway_retry_budget_is_failsafe() raises:
    """The second bound. An attempt can itself take minutes (30 s TLS handshake
    + 120 s h2 drive wall) before the GOAWAY surfaces, which the attempt cap
    alone does not bound.

    Every rejection path must return the DEFAULT: the setting can STATE a
    budget, never remove one. A value that parsed to "no bound" would re-open
    the hang this whole mechanism converts into a typed error. The budget is
    configuration the CALLER supplies (`GrpcClient.with_retry_budget_ms`, e.g.
    from a command-line flag), so this also pins that the setter is the
    channel that reaches the client."""
    print("  (g5) wall-clock budget setting is fail-safe...")

    assert_equal(
        _resolve_goaway_retry_budget_us(String("1500")),
        Int64(1_500_000),
        "a positive integer of MILLISECONDS -> that many us",
    )

    # Every rejection path. Each of these, if it returned 0 or a huge value,
    # would disable the bound rather than restate it.
    var rejected = List[String]()
    rejected.append(String(""))  # empty (not configured)
    rejected.append(String("abc"))  # non-numeric
    rejected.append(String("12x"))  # trailing garbage
    rejected.append(String("-5"))  # sign is non-numeric here
    rejected.append(String("0"))  # zero is not "no bound"
    rejected.append(String("999999999"))  # > 24h of ms — a typo
    for i in range(len(rejected)):
        assert_equal(
            _resolve_goaway_retry_budget_us(rejected[i]),
            _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT,
            String("'")
            + rejected[i]
            + String("' must degrade to the DEFAULT, never to no bound"),
        )

    # The client: the default until the caller sets a budget, then that budget;
    # a rejected value restores the default rather than removing the bound.
    var connector = ScriptedConnector.with_stream_tls(
        _h2_stream(_goaway_script(last_stream_id=0))
    )
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    assert_equal(
        grpc._retry_budget_us,
        _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT,
        "a client nobody configured carries the default budget",
    )
    grpc.with_retry_budget_ms(String("1500"))
    assert_equal(
        grpc._retry_budget_us,
        Int64(1_500_000),
        "with_retry_budget_ms must set the budget the re-issue reads",
    )
    grpc.with_retry_budget_ms(String("0"))
    assert_equal(
        grpc._retry_budget_us,
        _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT,
        "a rejected setting must restore the default, never remove the bound",
    )
    print("    OK — every rejection path returns the default")


# -----------------------------------------------------------------------------
# (g6) the two disposition tokens cannot alias.
# -----------------------------------------------------------------------------


def test_goaway_disposition_tokens_are_disjoint() raises:
    """The discriminator is a substring test, so if either token contains the
    other, `is_h2_goaway_unprocessed` starts returning True for the
    maybe-processed class and (g2) silently becomes (g1). Cheap to assert,
    catastrophic to lose."""
    print("  (g6) disposition tokens are disjoint...")
    assert_true(
        H2_GOAWAY_UNPROCESSED_TOKEN not in H2_GOAWAY_MAYBE_PROCESSED_TOKEN,
        "the unprocessed token must NOT be a substring of the"
        " maybe-processed token — the retry gate is a substring test",
    )
    assert_true(
        H2_GOAWAY_MAYBE_PROCESSED_TOKEN not in H2_GOAWAY_UNPROCESSED_TOKEN,
        "and not the other way round either",
    )
    # And the predicate itself, on the two literal message shapes.
    assert_true(
        is_h2_goaway_unprocessed(
            String("HttpError[H2_PROTOCOL]: GOAWAY received; stream 37 >")
            + String(" last_stream_id 35; will not be processed [")
            + H2_GOAWAY_UNPROCESSED_TOKEN
            + String("]")
        ),
        "the canonical unprocessed-GOAWAY message classifies as retry-safe",
    )
    assert_true(
        not is_h2_goaway_unprocessed(
            String("HttpError[EOF_MID_RESPONSE]: peer closed ... [")
            + H2_GOAWAY_MAYBE_PROCESSED_TOKEN
            + String("]")
        ),
        "the at-or-below message does NOT",
    )
    # A bare "GOAWAY" must not be enough — that is the blanket-retry bug.
    assert_true(
        not is_h2_goaway_unprocessed(String("stream lost: GOAWAY received")),
        "matching the WORD 'GOAWAY' is the blanket retry this design rejects",
    )
    print("    OK")


# -----------------------------------------------------------------------------
# (g7)(g8)(g9) THE SERVER-STREAMING ARM.
# -----------------------------------------------------------------------------
#
# The RPC path below is a real one: GCS `ReadObject` is what an object read
# (`read_range`) issues, and it is SERVER-STREAMING. Everything else about
# these cases is the unary fixture above, unchanged — which is the point: the
# same peer behaviour, the same GOAWAY bytes, a different arm, and (without
# the streaming re-issue) the opposite outcome.

comptime _STREAM_RPC_PATH: String = "/google.storage.v2.Storage/ReadObject"


def _drain_decoder_messages(
    mut decoder: ServerStreamDecoder[ProtocolGrpcProto],
) raises -> List[String]:
    """Pull every decoded message out of a loaded decoder as text.

    The decoder is pre-loaded (`server_stream` drained the whole body before
    returning it), so PENDING here means "no more bytes will arrive" and the
    pull terminates — there is no body left to feed it from.
    """
    var out = List[String]()
    while True:
        var outcome = decoder.try_next_message()
        if outcome.kind != STREAM_OUTCOME_MESSAGE:
            # PENDING on a pre-loaded decoder == exhausted; END_OK / END_ERROR
            # are terminal. Either way there is nothing further to pull.
            break
        var text = String("")
        for i in range(len(outcome.message_bytes)):
            text += chr(Int(outcome.message_bytes[i]))
        out.append(text^)
    return out^


def test_bug_server_stream_goaway_above_last_stream_id_is_reissued() raises:
    """RED without the streaming re-issue: `server_stream` sending bare
    through `send_grpc_pooled` lets the driver's raise escape verbatim and the
    read fails. GREEN with it: it re-dials and returns the second
    connection's messages."""
    print("  (g7) server-stream GOAWAY above Last-Stream-ID -> re-issued...")

    var conn1 = _h2_stream(_goaway_script(last_stream_id=0))
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
        " message — without the re-issue the GOAWAY raise escapes and the read fails",
    )
    assert_equal(
        msgs[0],
        String("REGISTRY-ROW"),
        "and it must be that connection's payload, byte for byte",
    )
    # THE MECHANISM, not just the outcome: a retry that re-used the DRAINING
    # connection would meet the same GOAWAY forever.
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        2,
        "the re-issue must dial a NEW connection (RFC 9113 §6.8: a receiver"
        " MUST NOT open additional streams on a GOAWAY'd connection)",
    )
    print("    OK — retried once, on a fresh conn, and returned the stream")


def test_bug_server_stream_goaway_retry_is_bounded_and_names_the_class() raises:
    """The bound, on the streaming arm. Six connections are armed and exactly
    `_GOAWAY_RETRY_MAX_ATTEMPTS` must be consumed; the give-up must be the SAME
    `H2_GOAWAY_RETRY_EXHAUSTED` the unary arm emits, naming both bounds.

    RED without the streaming re-issue on BOTH halves: one dial, and a raw
    `H2_PROTOCOL` GOAWAY rather than a typed exhaustion."""
    print("  (g8) server-stream retry is bounded + names its class...")
    var connector = ScriptedConnector.with_stream_tls(
        _h2_stream(_goaway_script(last_stream_id=0))
    )
    var armed = 6
    for _i in range(armed - 1):
        connector.arm_next(_h2_stream(_goaway_script(last_stream_id=0)))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/_/buckets/b/objects/service%2Fexample-svc"))

    var raised = False
    var message = String("")
    try:
        var _d = grpc.server_stream[RT, ProtocolGrpcProto](
            String(_STREAM_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
        )
    except e:
        raised = True
        message = String(e)

    assert_true(
        raised,
        "a peer that GOAWAYs every connection must eventually FAIL, not"
        " succeed and not spin",
    )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        _GOAWAY_RETRY_MAX_ATTEMPTS,
        String(
            "the server-stream retry must stop at _GOAWAY_RETRY_MAX_ATTEMPTS"
            " dials, not consume every armed connection (armed: "
        )
        + String(armed)
        + String(")"),
    )

    # The typed give-up — the whole point. A RAW GOAWAY here means nothing
    # retried.
    var required = List[String]()
    required.append(String("H2_GOAWAY_RETRY_EXHAUSTED"))  # the class
    required.append(String(_STREAM_RPC_PATH))  # which RPC
    required.append(
        String(_GOAWAY_RETRY_MAX_ATTEMPTS) + String(" attempt(s) over")
    )
    required.append(
        String("max_attempts=") + String(_GOAWAY_RETRY_MAX_ATTEMPTS)
    )
    required.append(
        String("budget_ms=")
        + String(Int(_GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT // Int64(1000)))
    )
    required.append(String("stopped_on=attempts"))
    required.append(H2_GOAWAY_UNPROCESSED_TOKEN)
    for i in range(len(required)):
        if required[i] not in message:
            raise Error(
                "server-stream exhaustion message is missing '"
                + required[i]
                + "' — a RAW GOAWAY here means"
                " this arm retried nothing. message: "
                + message
            )
    print("    OK — stopped at 4 dials and named both bounds")


def test_bug_server_stream_goaway_at_or_below_is_not_retried() raises:
    """The correctness half, on the streaming arm. `Last-Stream-ID = 1`
    INCLUDES our stream 1, so RFC 9113 §6.8 gives no not-processed guarantee.

    Green with or without the streaming re-issue, and it must STAY green: it
    is what stops (g7)'s re-issue from being a blanket retry. A fully-successful
    second connection is ARMED; consuming it IS the failure."""
    print("  (g9) server-stream GOAWAY at-or-below -> NOT retried...")

    var conn1 = _h2_stream(_goaway_script(last_stream_id=1))
    var connector = ScriptedConnector.with_stream_tls(conn1^)
    connector.arm_next(_h2_stream(_success_script(String("MUST-NOT-REACH"))))

    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/_/buckets/b/objects/service%2Fexample-svc"))

    var raised = False
    var message = String("")
    var returned = String("")
    try:
        var decoder = grpc.server_stream[RT, ProtocolGrpcProto](
            String(_STREAM_RPC_PATH), Span(msg), opts, Int(0), reactor, token,
        )
        var msgs = _drain_decoder_messages(decoder)
        for i in range(len(msgs)):
            returned += msgs[i]
    except e:
        raised = True
        message = String(e)

    if not raised:
        raise Error(
            "an at-or-below GOAWAY was RETRIED on the streaming arm and"
            " returned '"
            + returned
            + "' — the peer may already have executed this request. The"
            " stream-id comparison is the only thing that makes the (g7) retry"
            " safe and it has been lost."
        )
    assert_equal(
        grpc._http[]._connector.connect_call_count(),
        1,
        "an at-or-below GOAWAY must NOT dial again — a second dial IS the"
        " retry, whatever the call went on to return",
    )
    assert_true(
        H2_GOAWAY_MAYBE_PROCESSED_TOKEN in message,
        String(
            "the at-or-below class must name itself on the streaming arm too."
            " got: "
        )
        + message,
    )
    print("    OK — raised, dialled once, named the maybe-processed class")


def main() raises:
    print("== h2 GOAWAY not-processed re-issue falsifier ==")
    test_bug_goaway_above_last_stream_id_is_reissued_on_a_new_conn()
    test_bug_goaway_at_or_below_last_stream_id_is_not_retried()
    test_bug_goaway_retry_is_bounded_and_says_how_many_over_how_long()
    test_goaway_retry_budget_is_failsafe()
    test_goaway_disposition_tokens_are_disjoint()
    test_bug_server_stream_goaway_above_last_stream_id_is_reissued()
    test_bug_server_stream_goaway_retry_is_bounded_and_names_the_class()
    test_bug_server_stream_goaway_at_or_below_is_not_retried()
    print("== h2 GOAWAY re-issue falsifier PASSED (8 tests) ==")
