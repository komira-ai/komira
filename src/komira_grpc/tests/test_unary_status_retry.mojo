"""FALSIFIER — a TRANSIENT gRPC status must be replayed and succeed; a PERMANENT
one must fail on the FIRST attempt; and neither may depend on which verb it is
without the verb's policy SAYING so.

A server that answers

    [grpc:14] The service is currently unavailable. Please try again later

is telling the client to try again; a client that does not throws away
whatever long operation the call was part of over one transient status.

⚠ AND THE OTHER HALF IS THE CORRECTNESS HAZARD, which is why this file tests
BOTH directions with the same rig. A retry that hides a real failure is worse
than no retry: a `PERMISSION_DENIED` replayed five times over ~20 s of backoff
is a permanent failure that now costs the caller its budget AND arrives with a
mangled message the caller's classifier no longer matches. And a replayed CREATE
whose first attempt actually landed is TWO resources.

WHAT THIS FILE FALSIFIES:

  (r1) TRANSIENT  — `UNAVAILABLE` (14) under the idempotent policy: the RPC must
       replay and return the response scripted for attempt 2. Without the
       replay the status escapes `unary_call` verbatim ⇒ RED.
  (r2) PERMANENT  — `PERMISSION_DENIED` (7) under the SAME policy: must raise on
       attempt 1 and carry the ORIGINAL `[grpc:7]` message. A fully-successful
       attempt 2 is ARMED in the script; reaching it IS the failure signal.
  (r3) NOT-IN-SET — `INTERNAL` (13) under the idempotent policy: must NOT be
       retried. AIP-194 names only UNAVAILABLE and Google's shipped Cloud Run
       config uses only UNAVAILABLE; if 13 ever enters the default set, every
       generated CREATE replays a call that may already have landed.
  (r4) OPT-IN     — the SAME `INTERNAL` (13) under
       `internal_on_alreadyexists_guarded()`: must be retried. This is the pair
       that proves the retryable set is POLICY, not a hardcoded list — (r3) and
       (r4) differ in exactly one value.
  (r5) BOUND      — TWO-SIDED. 4 failures then a success must RETURN it (the
       5th attempt is made); 5 failures then a success must RAISE (no 6th
       attempt). The exhaustion error must name both bounds and the last
       status.
  (r6) NONE       — `RetryPolicy.none()` must not replay ANY status, including
       `UNAVAILABLE`. This is the codegen default for every verb whose
       idempotency the proto could not prove (including every rpc with no
       `(google.api.http)` annotation at all).

THE FAULT INJECTION is a `ScriptedConnector` — a byte script, no socket, no
network, no thread. Each failure is a status-carrying gRPC response (HEADERS
with `grpc-status: N`, then an empty END_STREAM DATA frame): how a Google front
end delivers a status-only error, and the shape `parse_grpc_status_initial_headers`
exists to read.

⚠ ONE CONNECTION, SUCCESSIVE STREAMS — not one connection per attempt. A
`[grpc:N]` status arrives on a HEALTHY connection (HTTP 200; the status is
raised above the transport), so the h2 multiplex pool survives and the replay
opens the NEXT stream on the SAME socket. See `_stream_id`.

⚠ THE POLICIES HERE USE 1 ms BACKOFF, not the shipped 1 s. That is a POLICY
VALUE, not a different mechanism — the loop, the jitter draw and the sleep call
are the production ones. `test_shipped_idempotent_policy_matches_googles_own_config`
pins the SHIPPED constants separately, so shrinking the test's wait cannot
silently shrink the product's.

Hermetic.
"""

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient
from komira_http.client.url import Url
from komira_http.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    CallOptions,
    GrpcClient,
    ProtocolGrpcProto,
    RETRY_CODES_AIP194,
    RetryPolicy,
    backoff_cap_ms,
    encode_unary_request,
    is_retryable_grpc_error,
    retry_mask_has,
)


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _RPC_PATH: String = "/google.cloud.run.v2.Jobs/CreateJob"

# The client allocates odd stream ids from 1 on every FRESH connection.
comptime _FIRST_CLIENT_STREAM_ID: Int = 1

comptime _GRPC_UNAVAILABLE: Int = 14
comptime _GRPC_INTERNAL: Int = 13
comptime _GRPC_PERMISSION_DENIED: Int = 7


# -----------------------------------------------------------------------------
# Fixtures.
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


def _append_status(
    sid: Int,
    code: Int,
    message: String,
    mut hpack: HpackEncoder,
    mut out: List[UInt8],
) raises:
    """Append ONE status-carrying gRPC error response on stream `sid`.

    ⚠ MINIMAL DELTA FROM `_append_success`: identical framing (HEADERS without
    END_STREAM, then a DATA frame with END_STREAM and a non-empty enveloped
    body), differing ONLY in `grpc-status` and `grpc-message`. Deliberate — the
    two appenders must differ in the STATUS, not in the framing, or the test
    measures the transport instead of the retry.

    The reason this is not the obvious trailers-only shape: both
    the END_STREAM-on-HEADERS form and the empty-DATA form make this rig report
    `HttpError[EOF_MID_RESPONSE]: peer closed while h2 streams in flight`
    instead of surfacing the status, so neither reaches the retry layer at all.
    `unary_call` raises the status from the INITIAL headers
    (`parse_grpc_status_initial_headers`) after draining the body, so the body
    is never decoded on this path and its content is irrelevant."""
    var body = encode_unary_request[ProtocolGrpcProto](
        Span(_b(String("error-body")))
    )
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
    hdrs.append(HpackHeader(String("grpc-status"), String(code)))
    hdrs.append(HpackHeader(String("grpc-message"), message))
    hdrs.append(HpackHeader(String("content-length"), String(len(body))))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(sid), block^, end_stream=False, end_headers=True, out=out,
    )
    encode_data_frame(UInt32(sid), body^, end_stream=True, out=out)


def _append_success(
    sid: Int, payload: String, mut hpack: HpackEncoder, mut out: List[UInt8]
) raises:
    """Append ONE successful unary gRPC response on stream `sid`."""
    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(payload)))
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
    hdrs.append(HpackHeader(String("grpc-status"), String("0")))
    hdrs.append(HpackHeader(String("content-length"), String(len(body))))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(sid), block^, end_stream=False, end_headers=True, out=out,
    )
    encode_data_frame(UInt32(sid), body^, end_stream=True, out=out)


def _stream_id(attempt: Int) -> Int:
    """The h2 stream id the `attempt`-th (1-based) RPC on ONE connection uses.

    ⚠ THE REPLAY STAYS ON THE SAME CONNECTION, and that is why the fixtures are
    shaped this way. Unlike the GOAWAY re-issue (§3a), which drops the pool and
    re-dials, a `[grpc:N]` status arrives on a perfectly HEALTHY connection:
    `send_grpc_pooled` returns HTTP 200, the status is raised ABOVE the
    transport, and the h2 multiplex pool is restored intact. So attempt 2 opens
    the NEXT odd stream on the SAME socket. Scripting one connection per attempt
    instead produces `EOF_MID_RESPONSE` on the replay."""
    return 2 * attempt - 1


def _script(codes: List[Int], var trailing: String) raises -> List[UInt8]:
    """One connection's whole read script: an error response per entry in
    `codes` on successive streams, then — if `trailing` is non-empty — a
    SUCCESSFUL response on the stream after them.

    The trailing success is usually a TRAP: for every "must not retry" case it
    is armed and must remain unread, so "it returned a payload" IS the failure
    signal.

    ⚠ ONE `HpackEncoder` FOR THE WHOLE SCRIPT. HPACK carries a dynamic table
    that both ends mutate as blocks are encoded/decoded; a fresh encoder per
    response desynchronises the client's decoder from response 2 onward."""
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    var hpack = HpackEncoder(max_table_size=4096)
    for i in range(len(codes)):
        _append_status(
            _stream_id(i + 1), codes[i], String("scripted failure"), hpack, out
        )
    if trailing.byte_length() > 0:
        _append_success(_stream_id(len(codes) + 1), trailing, hpack, out)
    return out^


def _h2_stream(var script: List[UInt8]) raises -> ScriptedStream:
    """One scripted connection reporting ALPN h2, serving its script ONE BYTE
    PER READ.

    ⚠ BOTH PROPERTIES ARE LOAD-BEARING.
      * Without the ALPN report, `send_grpc_pooled` drops the dial and falls
        back to HTTP/1.1, which never produces a gRPC status at all.
      * Without `set_max_read_per_call(1)`, a GREEDY read pulls the frames for
        streams the connection has not created yet; the client drops them, and
        the replay that later opens that stream finds nothing and reports
        `EOF_MID_RESPONSE`. Each attempt's drive then
        consumes only its own stream's frames and stops at its END_STREAM."""
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    return s^


def _cloud_run_base() raises -> Url:
    """An https authority, so `send_grpc_pooled` takes the pooled-h2 path the
    https Cloud Run client takes."""
    return Url.parse(String("https://run.googleapis.com:443/"))


def _fast_idempotent() -> RetryPolicy:
    """The shipped idempotent policy with the WAIT shrunk to 1 ms. Same loop,
    same jitter draw, same sleep call — only the backoff numbers differ, and
    (r7) pins the shipped ones so this cannot mask a change to them."""
    return RetryPolicy(5, 1, 1, 130, RETRY_CODES_AIP194)


def _fast_internal_guarded() -> RetryPolicy:
    """`internal_on_alreadyexists_guarded()`'s code set, at 1 ms backoff."""
    var shipped = RetryPolicy.internal_on_alreadyexists_guarded()
    return RetryPolicy(5, 1, 1, 130, shipped.retryable_codes)


# -----------------------------------------------------------------------------
# The rig: ONE scripted connection, one policy, one call.
# -----------------------------------------------------------------------------


def _codes(var a: List[Int]) -> List[Int]:
    return a^


def _run(
    var script: List[UInt8], policy: RetryPolicy
) raises -> Tuple[Bool, String, String]:
    """Drive ONE `unary_call_retrying` against a scripted peer.

    Returns (raised, returned_payload, error_message) so every case asserts on
    the SAME three observables and the cases differ only in the script and the
    policy — which is exactly the claim under test."""
    var conn = _h2_stream(script^)
    var connector = ScriptedConnector.with_stream(conn^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var grpc = GrpcClient[ScriptedConnector](http^, _cloud_run_base())
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("projects/p/locations/l"))

    var returned = String("")
    var message = String("")
    var raised = False
    try:
        var result = grpc.unary_call_retrying[RT, ProtocolGrpcProto](
            String(_RPC_PATH),
            Span(msg),
            opts,
            Int(0),
            reactor,
            token,
            policy,
        )
        for i in range(len(result.message_bytes)):
            returned += chr(Int(result.message_bytes[i]))
    except e:
        raised = True
        message = String(e)
    return (raised, returned, message)


# -----------------------------------------------------------------------------
# (r1) TRANSIENT -> replayed, and succeeds.
# -----------------------------------------------------------------------------


def test_bug_unavailable_status_is_replayed_and_succeeds() raises:
    """RED without the replay: the `[grpc:14]` raise escapes `unary_call`
    verbatim and the call fails. GREEN with it: the RPC replays and
    returns the response scripted for the SECOND attempt."""
    print("  (r1) UNAVAILABLE under the idempotent policy -> replayed...")

    var codes = List[Int]()
    codes.append(_GRPC_UNAVAILABLE)
    var out = _run(
        _script(codes^, String("JOB-CREATED")), _fast_idempotent()
    )
    var raised = out[0]
    var returned = out[1]
    var message = out[2]

    if raised:
        raise Error(
            "a transient UNAVAILABLE was NOT replayed:"
            " the server said 'try again later' and the client did not. got: "
            + message
        )
    assert_equal(
        returned,
        String("JOB-CREATED"),
        "the replay must return the response scripted for attempt 2 — that"
        " payload exists on no other stream, so returning it IS the proof a"
        " second request went out",
    )
    print("    OK — replayed once and returned the second attempt's response")


# -----------------------------------------------------------------------------
# (r2) PERMANENT -> raises promptly, verbatim, never reaches attempt 2.
# -----------------------------------------------------------------------------


def test_permanent_status_fails_on_the_first_attempt() raises:
    """A retry that hides a real failure is worse than no retry.

    `PERMISSION_DENIED` is not fixed by waiting — it needs an IAM change. It
    must raise on attempt 1 and keep its `[grpc:7]` message, which a caller's
    error classifier keys on. A fully-successful attempt 2 is ARMED in the script;
    returning its payload IS the failure."""
    print("  (r2) PERMISSION_DENIED -> fails promptly, verbatim...")

    var codes = List[Int]()
    codes.append(_GRPC_PERMISSION_DENIED)
    var out = _run(
        _script(codes^, String("MUST-NOT-REACH")), _fast_idempotent()
    )
    var raised = out[0]
    var returned = out[1]
    var message = out[2]

    if not raised:
        raise Error(
            "a PERMISSION_DENIED was RETRIED and returned '"
            + returned
            + "' — a permanent failure the retry layer converts into a SLOW"
            " permanent failure has spent the caller's budget to learn nothing"
        )
    assert_true(
        String("[grpc:7]") in message,
        String(
            "the original status must survive verbatim — the pod manager's"
            " classifier matches on it, and an exhaustion wrapper around a"
            " permanent error breaks every caller downstream. got: "
        )
        + message,
    )
    assert_true(
        String("EXHAUSTED") not in message,
        String(
            "a permanent error must not be reported as retry exhaustion — that"
            " names the wrong fault and sends the next reader to the wrong"
            " place. got: "
        )
        + message,
    )
    print("    OK — raised on attempt 1, verbatim")


# -----------------------------------------------------------------------------
# (r3)/(r4) THE SAME STATUS, TWO POLICIES — the pair that proves it is policy.
# -----------------------------------------------------------------------------


def test_internal_is_not_in_the_default_retryable_set() raises:
    """(r3) `INTERNAL` (13) is NOT in the default set — deliberately.

    AIP-194 names exactly one retryable code (UNAVAILABLE), and Google's shipped
    `google/cloud/run/v2/run_grpc_service_config.json` gives CreateService /
    UpdateService / DeleteService `retryPolicy: null` — no retry at all — while
    ListServices / GetService get `retryableStatusCodes: ["UNAVAILABLE"]`.
    INTERNAL carries no guarantee the call did not land, so a default that
    included it would make every generated CREATE replay a call that may
    already have created the resource."""
    print("  (r3) INTERNAL is NOT in the AIP-194 default set...")

    assert_true(
        not retry_mask_has(RETRY_CODES_AIP194, _GRPC_INTERNAL),
        "INTERNAL(13) must not be in the AIP-194 default mask",
    )
    assert_true(
        retry_mask_has(RETRY_CODES_AIP194, _GRPC_UNAVAILABLE),
        "UNAVAILABLE(14) must be in the AIP-194 default mask",
    )
    assert_equal(
        RetryPolicy.idempotent().retryable_codes,
        RETRY_CODES_AIP194,
        "the emitted idempotent policy must carry exactly the AIP-194 set",
    )

    var codes = List[Int]()
    codes.append(_GRPC_INTERNAL)
    var out = _run(
        _script(codes^, String("MUST-NOT-REACH")), _fast_idempotent()
    )
    var raised = out[0]
    var returned = out[1]

    if not raised:
        raise Error(
            "INTERNAL under the DEFAULT policy was replayed and returned '"
            + returned
            + "' — INTERNAL gives no guarantee the call did not land, so this"
            " is a CreateJob that may have created two jobs"
        )
    print("    OK — not retried")


def test_internal_is_retried_under_the_opt_in_guarded_policy() raises:
    """(r4) The SAME `INTERNAL` (13), the SAME wire script — retried, because
    the POLICY says so.

    `internal_on_alreadyexists_guarded()` is the opt-in for a create with a
    CLIENT-ASSIGNED id whose caller already treats ALREADY_EXISTS as success
    (AIP-133). There a replay that duplicates is observed as the original.

    (r3) and (r4) differ in exactly ONE value — the policy. That is what proves
    the retryable set is a parameter derived per verb, not a hardcoded list in
    the substrate."""
    print("  (r4) INTERNAL under the guarded opt-in policy -> replayed...")

    var codes = List[Int]()
    codes.append(_GRPC_INTERNAL)
    var out = _run(
        _script(codes^, String("JOB-CREATED")), _fast_internal_guarded()
    )
    var raised = out[0]
    var returned = out[1]
    var message = out[2]

    if raised:
        raise Error(
            "the guarded policy did not replay INTERNAL, the status it exists"
            " to replay for a create with a client-assigned id. got: "
            + message
        )
    assert_equal(
        returned,
        String("JOB-CREATED"),
        "the guarded replay must return attempt 2's response",
    )
    print("    OK — replayed once and returned the response")


# -----------------------------------------------------------------------------
# (r5) BOUND — two-sided: it must reach attempt N, and must not exceed it.
# -----------------------------------------------------------------------------


def test_retry_stops_at_exactly_max_attempts() raises:
    """An unbounded retry is how a caller hangs forever instead of failing,
    which is strictly worse than the bug being fixed. A bound that stops EARLY
    gives up on a transient status one attempt too soon.

    So the bound is pinned from BOTH sides with the same rig, and the two
    scripts differ by ONE failure:
      * 4 failures then a success -> must RETURN the success (so it reaches
        attempt 5),
      * 5 failures then a success -> must RAISE (so it never reaches attempt 6).
    Together those admit exactly `max_attempts == 5`."""
    print("  (r5) the attempt bound is exactly max_attempts, both sides...")

    var policy = _fast_idempotent()
    assert_equal(policy.max_attempts, 5, "the rig below assumes 5")

    # -- lower side: attempt 5 must still be made.
    var four = List[Int]()
    for _i in range(4):
        four.append(_GRPC_UNAVAILABLE)
    var lo = _run(_script(four^, String("OK-ON-ATTEMPT-5")), policy)
    if lo[0]:
        raise Error(
            "gave up BEFORE attempt 5, but max_attempts is 5 — a bound that"
            " stops early gives up on a transient status. got: " + lo[2]
        )
    assert_equal(
        lo[1],
        String("OK-ON-ATTEMPT-5"),
        "the 5th attempt's response must be returned",
    )

    # -- upper side: attempt 6 must never be made.
    var five = List[Int]()
    for _i in range(5):
        five.append(_GRPC_UNAVAILABLE)
    var hi = _run(_script(five^, String("MUST-NOT-REACH")), policy)
    if not hi[0]:
        raise Error(
            "a 6th attempt was made and returned '"
            + hi[1]
            + "' — the loop is not bounded by max_attempts"
        )
    var message = hi[2]
    assert_true(
        String("EXHAUSTED") in message,
        String("the give-up must name itself as exhaustion. got: ") + message,
    )
    assert_true(
        String("max_attempts=") in message
        and String("max_backoff_ms=") in message,
        String(
            "the give-up must state BOTH bounds, so the next reader can tell"
            " which one stopped it without a rebuild — the"
            " TLS-deadline precedent. got: "
        )
        + message,
    )
    assert_true(
        String("[grpc:14]") in message,
        String(
            "the give-up must carry the LAST status — 'gave up' without the"
            " reason sends the reader to the wrong subsystem. got: "
        )
        + message,
    )
    assert_true(
        _RPC_PATH in message,
        String("the give-up must name the RPC. got: ") + message,
    )
    print("    OK — reaches attempt 5, never attempt 6, and says so")


# -----------------------------------------------------------------------------
# (r6) NONE — the codegen default for an unproven verb replays nothing.
# -----------------------------------------------------------------------------


def test_policy_none_replays_nothing_not_even_unavailable() raises:
    """`RetryPolicy.none()` is what codegen emits for every verb whose
    idempotency the proto could not prove — every POST/PATCH, and every rpc
    that carries no `(google.api.http)` annotation at all.

    It must be behaviourally identical to a client with no retry layer: one attempt,
    whatever the status. UNAVAILABLE is the sharpest probe, since it is the one
    code the idempotent policy DOES replay."""
    print("  (r6) RetryPolicy.none() -> replays nothing...")

    assert_true(
        RetryPolicy.none().retries_nothing(),
        "none() must report itself as replaying nothing (the hot-path gate)",
    )
    assert_true(
        not is_retryable_grpc_error(
            String("[grpc:14] unavailable"), RetryPolicy.none()
        ),
        "none() must not classify UNAVAILABLE as retryable",
    )

    var codes = List[Int]()
    codes.append(_GRPC_UNAVAILABLE)
    var out = _run(
        _script(codes^, String("MUST-NOT-REACH")), RetryPolicy.none()
    )
    if not out[0]:
        raise Error(
            "none() replayed and returned '"
            + out[1]
            + "' — this is the default for every verb codegen could not prove"
            " idempotent, so a replay there is a duplicated non-idempotent call"
        )
    print("    OK — one attempt")


# -----------------------------------------------------------------------------
# (r7+) THE SHIPPED CONSTANTS + the pure decision functions.
# -----------------------------------------------------------------------------


def test_shipped_idempotent_policy_matches_googles_own_config() raises:
    """The four backoff numbers are Google's own, from the shipped
    `google/cloud/run/v2/run_grpc_service_config.json` retryPolicy:
    maxAttempts 5, initialBackoff 1s, maxBackoff 10s,
    backoffMultiplier 1.3.

    Pinned here because every other test in this file deliberately uses a 1 ms
    backoff. Without this, shrinking the test's wait would silently shrink the
    product's — and a client that backs off faster than the service was
    configured to expect is a client that amplifies the outage it is retrying
    through."""
    print("  (r7) shipped idempotent policy == Google's config...")

    var p = RetryPolicy.idempotent()
    assert_equal(p.max_attempts, 5, "maxAttempts")
    assert_equal(p.initial_backoff_ms, 1000, "initialBackoff 1s")
    assert_equal(p.max_backoff_ms, 10_000, "maxBackoff 10s")
    assert_equal(p.backoff_multiplier_pct, 130, "backoffMultiplier 1.3")

    # The schedule the numbers produce, saturating at the cap.
    assert_equal(backoff_cap_ms(1, p), 1000, "cap before retry 1")
    assert_equal(backoff_cap_ms(2, p), 1300, "cap before retry 2")
    assert_equal(backoff_cap_ms(3, p), 1690, "cap before retry 3")
    assert_equal(backoff_cap_ms(4, p), 2197, "cap before retry 4")
    assert_true(
        backoff_cap_ms(64, p) == 10_000,
        "the cap must SATURATE at max_backoff_ms, never grow without bound",
    )
    print("    OK")


def test_policy_constructor_clamps_every_unbounded_input() raises:
    """A policy is a plain value that the emitter, the call sites and any future
    config path all build. The constructor is the single place that can
    guarantee no input yields an unbounded or shrinking retry, so it clamps
    rather than trusts."""
    print("  (r8) the constructor clamps...")

    var absurd = RetryPolicy(1_000_000, -5, 1, -50, RETRY_CODES_AIP194)
    assert_equal(
        absurd.max_attempts,
        16,
        "max_attempts must clamp to the ceiling — there is no value meaning"
        " unbounded",
    )
    assert_equal(absurd.initial_backoff_ms, 0, "a negative backoff clamps to 0")
    assert_true(
        absurd.backoff_multiplier_pct >= 100,
        "a multiplier below 1.0 would SHRINK the backoff under load",
    )

    var inverted = RetryPolicy(3, 5000, 100, 130, RETRY_CODES_AIP194)
    assert_true(
        inverted.max_backoff_ms >= inverted.initial_backoff_ms,
        "max_backoff below initial_backoff must not invert the schedule",
    )

    var huge = RetryPolicy(3, 0, 999_999_999, 130, RETRY_CODES_AIP194)
    assert_equal(
        huge.max_backoff_ms, 120_000, "max_backoff clamps to the 2-minute ceiling"
    )

    assert_true(
        RetryPolicy(5, 1000, 10_000, 130, 0).retries_nothing(),
        "an EMPTY code set means retries nothing, however many attempts are"
        " configured",
    )
    print("    OK")


def test_a_transport_error_with_no_status_is_not_retried_here() raises:
    """A message with no `[grpc:` anchor is a TRANSPORT error, not a status, and
    its verdict is UNKNOWN — the call may have landed.

    The transport classes that carry a not-processed PROOF (RFC 9113 §6.8
    GOAWAY above Last-Stream-ID, zero response bytes, REFUSED_STREAM) are
    owned by `_send_unary_bounded_goaway_retry`,
    a layer below this one. If this layer ever started retrying anchorless
    errors it would replay that proof-free class too, which is precisely the
    double-execution the GOAWAY test's (g2) exists to prevent."""
    print("  (r9) an anchorless transport error is not retried here...")

    var p = RetryPolicy.idempotent()
    assert_true(
        not is_retryable_grpc_error(
            String(
                "HttpError[H2_PROTOCOL]: GOAWAY received; stream 37 <="
                " last_stream_id 39; may have been processed"
            ),
            p,
        ),
        "a GOAWAY-maybe-processed carries no status and must not be replayed"
        " by the status layer",
    )
    assert_true(
        not is_retryable_grpc_error(String("connection reset by peer"), p),
        "a bare transport error has an UNKNOWN verdict and must not replay",
    )
    assert_true(
        is_retryable_grpc_error(
            String("CloudRunJobs GetJob failed [UNAVAILABLE]: [grpc:14] x"), p
        ),
        "the anchor is found anywhere in the message, so a re-projected error"
        " still classifies",
    )
    print("    OK")


def main() raises:
    print("test_unary_status_retry: status-code retry in the generated clients")
    test_bug_unavailable_status_is_replayed_and_succeeds()
    test_permanent_status_fails_on_the_first_attempt()
    test_internal_is_not_in_the_default_retryable_set()
    test_internal_is_retried_under_the_opt_in_guarded_policy()
    test_retry_stops_at_exactly_max_attempts()
    test_policy_none_replays_nothing_not_even_unavailable()
    test_shipped_idempotent_policy_matches_googles_own_config()
    test_policy_constructor_clamps_every_unbounded_input()
    test_a_transport_error_with_no_status_is_not_retried_here()
    print("ALL PASS")
