# =============================================================================
# komira_grpc/client.mojo — GrpcClient: the wire layer wired onto HttpClient
# =============================================================================
#
# The production GrpcClient that dispatches the transport-free wire layer
# (wire.mojo / stream.mojo / headers.mojo) over `komira_http.HttpClient[C]`.
#
# The gRPC client adds ZERO transport. It marshals the caller's
# already-serialized message bytes into request body bytes (via
# `encode_unary_request[P]` / `encode_stream_message[P]`), sends them through
# `HttpClient.send`, and drives `RecvRingBody.poll_frame` to decode the
# response body bytes back into message bytes (via `decode_unary_response[P]` /
# `ServerStreamDecoder[P]`). The codec (proto vs JSON) is the generated stub's
# concern — the GrpcClient operates on opaque message bytes, so it never pulls
# a serializer into its own import set (keeps the substrate codec-agnostic).
#
# The wire-protocol axis is the comptime `P: Protocol` parameter selected
# by the generated stub at codegen time; the four entry points monomorphize
# per protocol so the hot path has ZERO runtime branches.
#
# Four entry points (one per streaming mode):
#   unary_call[P, ...]     — (false, false): 1 req → 1 resp.
#   server_stream[P, ...]  — (false, true):  1 req → N resp (pull iterator).
#   client_stream[P, ...]  — (true, false):  N req → 1 resp.
#   bidi_stream[P, ...]    — (true, true):   N req ↔ N resp.
#
# Cancellation-via-clock-token: the runtime's clock trips `token.cancel()` at
# the deadline; `RecvRingBody.poll_frame` checks `token.is_cancelled()` on
# every wire-read iteration and returns a CANCELLED error frame, which the
# response-drain loops here surface as a GrpcError(DEADLINE_EXCEEDED /
# CANCELLED). The token is threaded as a `ref token` per call — NOT a
# long-lived field (no borrowed-pointer fields) — per call_options.mojo's
# design note.
#
# Configuration: the one tunable (the wall budget of the not-processed
# re-issue, §0) is a field set by the caller through
# `GrpcClient.with_retry_budget_ms`; this module reads no environment.
#
# Encapsulation:
#   * The HttpClient is held as `OwnedPointer[HttpClient[C]]`; the raw
#     HttpClient never crosses the module boundary as an UnsafePointer.
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * NO long-lived borrowed-pointer fields — reactor + token + clock are
#     per-call args.
# =============================================================================

from std.memory import OwnedPointer

from komira_async.cancellation.token import CancellationToken
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.body import BytesBody
from komira_http.client.client import HttpClient, build_streaming_request
from komira_http.client.h2_client import (
    is_h2_goaway_unprocessed,
    is_h2_retryable_transport,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import method_post
from komira_http.client.response_body import RecvRingBody
from komira_http.client.state_machine import ClientResponse
from komira_http.client.url import Url
from komira_http.transport.io_stream import Connector

from komira_obs.clock import now_ns as _mono_now_ns

from komira_connect.status import (
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_DEADLINE_EXCEEDED,
)

from komira_http.transport.grpc_emit import is_grpc_content_type

from komira_grpc.protocol import Protocol
from komira_grpc.call_options import CallOptions
from komira_grpc.error import (
    GrpcError,
    format_grpc_error_message,
    parse_grpc_status_initial_headers,
    parse_grpc_status_trailers,
)
from komira_grpc.headers import (
    build_unary_request_headers,
    build_stream_request_headers,
)
from komira_grpc.retry import (
    RetryPolicy,
    backoff_draw_ms,
    is_retryable_grpc_error,
    sleep_backoff_ms,
)
from komira_grpc.wire import (
    encode_unary_request,
    decode_unary_response,
    encode_stream_message,
)
from komira_grpc.stream import (
    ServerStreamDecoder,
    ClientStreamEncoder,
    BidiStreamCodec,
    StreamOutcome,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_END_ERROR,
)


# =============================================================================
# §0 — NOT-PROCESSED re-issue bounds (RFC 9113 §6.8 GOAWAY + §8.7 / zero-bytes)
# =============================================================================
#
# ⚠ THE CONSTANTS BELOW KEEP THEIR `_GOAWAY_` NAMES even though the gate they
# bound accepts a second proof class (see `_not_processed_retry_or_raise`):
# `_GOAWAY_RETRY_MAX_ATTEMPTS` / `_GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT` are
# imported by name by the falsifier `test_goaway_unprocessed_retry`. The bounds
# are SHARED by both classes: one attempt counter and one wall budget for the
# whole re-issue sequence, so the worst case does not double when a sequence
# mixes them.
# =============================================================================
#
# A GOAWAY whose `Last-Stream-ID` is BELOW our stream is not a failure — it is
# the peer telling us, in the protocol's own words, that it did not process the
# request and that a NEW connection is where to re-issue it. Google's front ends
# send GOAWAY routinely to drain and recycle connections, so any RPC that lives
# long enough (a long-running-operation poll across a multi-minute deploy)
# WILL meet one, surfacing as e.g. "HttpError[H2_PROTOCOL]: GOAWAY received;
# stream 37 > last_stream_id 35; will not be processed". Surfacing it as a fatal
# error is a missing retry, not a network fault.
#
# ⚠ THE RETRY IS GATED ON THE STREAM-ID COMPARISON, NOT ON "GOAWAY". It fires
# only for `is_h2_goaway_unprocessed`, whose token is emitted by exactly one
# branch of the h2 driver — the one that established `sid > Last-Stream-ID`.
# The at-or-below class carries no such guarantee and is NOT retried here; it
# propagates to the caller, which is the layer that knows whether its verb is
# replayable. Retrying that class would duplicate non-idempotent work.
#
# BOUNDED ON TWO AXES, because either alone is insufficient: a pure attempt cap
# still permits N x (30 s TLS handshake + 120 s h2 wall) of hanging, and a pure
# wall bound permits an unbounded attempt storm against a peer that GOAWAYs
# instantly. An unbounded retry loop is how a caller hangs forever instead of
# failing, which is strictly worse than the bug being fixed.

comptime _GOAWAY_RETRY_MAX_ATTEMPTS: Int = 4
"""Total attempts for ONE unary RPC (the initial send + up to 3 re-issues).

Sized against what a GOAWAY MEANS: it is a connection-lifecycle event, not a
service fault, so consecutive fresh connections meeting it is a peer that is
recycling far faster than it is serving. 4 covers a drain wave landing on
back-to-back dials while still terminating."""

comptime _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT: Int64 = 90_000_000
"""Wall-clock ceiling (90 s) on the whole retry sequence, checked BEFORE each
re-issue. Bounds the case the attempt cap cannot: an attempt that itself takes
minutes (TLS handshake budget 30 s + h2 drive wall 120 s) before the GOAWAY
surfaces. A remaining budget smaller than the elapsed time of the attempt that
just failed means the next one cannot plausibly fit either."""


def _resolve_goaway_retry_budget_us(budget_ms: String) -> Int64:
    """The retry wall budget in µs, from a caller-supplied budget in
    MILLISECONDS (decimal text, e.g. the value of a binary's command-line
    flag). Empty / non-numeric / <= 0 / > 24h ⇒ the default: the setting can
    STATE a budget, never remove one. Every rejection path returns the
    default — there is no input that yields an unbounded retry loop."""
    if budget_ms.byte_length() == 0:
        return _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT
    var bytes = budget_ms.as_bytes()
    var acc = Int64(0)
    var i = 0
    while i < len(bytes):
        var c = bytes[i]
        if c < UInt8(0x30) or c > UInt8(0x39):
            return _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT
        acc = acc * Int64(10) + Int64(Int(c) - 0x30)
        if acc > Int64(86_400_000):  # > 24h of ms — treat as a typo
            return _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT
        i += 1
    if acc <= Int64(0):
        return _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT
    return acc * Int64(1000)


def _not_processed_retry_or_raise(
    path: String,
    attempts: Int,
    t0_ns: Int64,
    last_msg: String,
    budget_us: Int64,
) raises:
    """The NOT-PROCESSED re-issue DECISION, shared by every send arm that can
    rebuild its request byte-fresh per attempt.

    Returns normally => the caller must LOOP (re-issue on a new connection).
    Raises => the caller must NOT: either the error carries no not-processed
    proof (propagated VERBATIM, so the callers' existing classifiers keep
    matching it), or a bound is spent (`H2_GOAWAY_RETRY_EXHAUSTED` /
    `H2_TRANSPORT_RETRY_EXHAUSTED`). `budget_us` is the client's wall budget
    for the whole re-issue sequence (`GrpcClient.with_retry_budget_ms`).

    ★ TWO PROOF-CARRYING CLASSES, ONE GATE. The gate is
    and remains "the peer PROVED it took no action" — never a class NAME, and
    never the word "retryable". Two independent branches establish that proof
    and both are accepted here:

      * `is_h2_goaway_unprocessed` — RFC 9113 §6.8, stream id > Last-Stream-ID.
      * `is_h2_retryable_transport` — ZERO response bytes received, or RFC 9113
        §8.7 REFUSED_STREAM. See `h2_client.H2_RETRYABLE_TRANSPORT_TOKEN` for
        the per-raise-site enumeration; every emitter is gated on the proof and
        every sibling branch that saw even one response byte raises `IO_ERROR`
        instead.

    WHY THE SECOND ONE BELONGS HERE, AND NOT IN `is_retryable_grpc_error`. A
    caller that polls a long-running operation once per tick leaves its pooled
    connection idle across the whole inter-tick gap; a front end reaps it, and
    the next checkout writes into a dead socket, surfacing as
    `HttpError[RETRYABLE_TRANSPORT...]` with zero response bytes.
    `is_retryable_grpc_error` is a STATUS-CODE gate
    (`retry_mask_has(policy.retryable_codes, parse_grpc_status_code(msg))`) and
    a transport fault carries no status, so it correctly returns False.
    Widening THAT would be wrong three times over: it would make the
    policy mask stop describing what it retries; it is gated on a per-verb
    `policy`, so it would decline exactly the non-idempotent verbs this proof
    covers; and because `unary_call_retrying` retries by re-entering
    `unary_call`, the effective bound would silently become the PRODUCT of the
    two layers. It would also do nothing for `server_stream`, which has no
    `_retrying` variant. The argument for retrying a proof-carrying transport
    fault is the argument ALREADY MADE HERE for GOAWAY — so it belongs here,
    under the same bounds.

    It is one function precisely so the
    unary and server-streaming arms cannot drift into two different gates and
    two different exhaustion messages: the gate is the not-processed proof, and
    the give-up must always name both bounds and which one stopped it.
    """
    var goaway = is_h2_goaway_unprocessed(last_msg)
    var transport = is_h2_retryable_transport(last_msg)
    if not goaway and not transport:
        # No not-processed proof — including the at-or-below GOAWAY, IO_ERROR
        # (the peer had already answered), EOF_MID_RESPONSE, TIMEOUT and every
        # server status. Propagate the ORIGINAL message verbatim.
        raise Error(last_msg)
    var elapsed_us = (Int64(_mono_now_ns()) - t0_ns) // Int64(1000)
    var attempts_left = attempts < _GOAWAY_RETRY_MAX_ATTEMPTS
    var budget_left = elapsed_us < budget_us
    if not attempts_left or not budget_left:
        # ⚠ THE EXHAUSTION TOKEN NAMES THE CLASS THAT ACTUALLY EXHAUSTED, and it
        # is chosen from the LAST fault — the one the message also quotes, so the
        # token and the `Last:` text can never disagree. Reusing the GOAWAY token
        # for a reaped-socket give-up would send an operator hunting a GOAWAY
        # that is not there; "the reason word is the first thing an operator
        # reads" is the same argument `_bound_entry_fault` makes for its own
        # reason words. Both tokens contain "RETRY_EXHAUSTED", so a caller that
        # wants either can test that substring.
        raise Error(
            (
                "HttpError[H2_GOAWAY_RETRY_EXHAUSTED]: gave up"
                if goaway
                else "HttpError[H2_TRANSPORT_RETRY_EXHAUSTED]: gave up"
            )
            + " re-issuing "
            + path
            + " after "
            + String(attempts)
            + " attempt(s) over "
            + String(Int(elapsed_us // Int64(1000)))
            + " ms (max_attempts="
            + String(_GOAWAY_RETRY_MAX_ATTEMPTS)
            + ", budget_ms="
            + String(Int(budget_us // Int64(1000)))
            + ", stopped_on="
            + (
                String("attempts")
                if not attempts_left
                else String("wall_clock")
            )
            + "); "
            + (
                String(
                    "every attempt met a GOAWAY whose Last-Stream-ID excluded"
                    " our stream, so the request was never processed — the peer"
                    " is recycling connections faster than it is serving them."
                )
                if goaway
                else String(
                    "every attempt met a transport fault that PROVED the"
                    " request was not processed (zero response bytes, or RFC"
                    " 9113 §8.7 REFUSED_STREAM) — every re-issue dialed a fresh"
                    " connection and met the same thing, so this is the peer or"
                    " the path, not a reaped idle connection."
                )
            )
            + " Last: "
            + last_msg
        )
    # Fall through: the caller loops and the next attempt dials fresh.


# =============================================================================
# §0a — Terminal gRPC status: read it from the section that CARRIES it.
# =============================================================================


def _grpc_status_from_sections(
    headers: HeaderMap, trailers: HeaderMap,
) -> Optional[GrpcError]:
    """The terminal `grpc-status`, read from the response section that
    actually carries it. `None` means the server stated no status at all.

    ⛔ THIS FUNCTION EXISTS BECAUSE THE TWO CASES ARE DIFFERENT MESSAGES, AND
    READING BOTH OFF ONE MAP HIDES A REAL DEFECT FOR AS LONG AS IT WORKS.
    Classic gRPC puts the terminal status in HTTP/2 TRAILERS; a TRAILERS-ONLY
    response (no body) puts it in the INITIAL HEADERS block. An h2 codec that
    appends trailer fields into the SAME `HeaderMap` as the head's lets
    `parse_grpc_status_initial_headers(resp.headers)` find both — but then a
    trailer can also overwrite `:status` or inject a `content-length` the
    origin never committed to (RFC 9113 §8.1 forbids exactly this), so
    komira_http keeps the two sections apart.

    With the sections split, a plain `resp.headers` read finds the
    trailers-only status and SILENTLY DROPS the real-TRAILERS one — reporting
    every trailer-delivered failure as a SUCCESS. That is a strictly worse
    failure than the merge, which is why the split is finished HERE rather
    than undone in the codec.

    TRAILERS FIRST, deliberately: a server that sends both has committed to
    the trailer value last, and the gRPC spec's terminal status is the
    trailer. Falsifier:
    `unary_terminal_status_in_a_real_trailers_frame`
    (test_grpc_client_trailers_only_and_streams.mojo).
    """
    if trailers.contains_static("grpc-status"):
        return Optional(parse_grpc_status_trailers(trailers))
    return parse_grpc_status_initial_headers(headers)


# =============================================================================
# §0b — Response content-type validation (shared by all four entry points).
# =============================================================================


def _non_rpc_content_type(headers: HeaderMap) -> Optional[String]:
    """Some(the offending value) iff the response declares a content-type that
    is not an RPC content-type at all; None if it is one, or if none was sent.

    ⭐ WHY THIS EXISTS. Without a content-type check, a gRPC-unaware
    intermediary answering `:status: 200` with an HTML error page (a captive
    portal, a proxy 502 body, a misrouted request) has its HTML handed
    straight to `grpc_decode_unary`, which reads the first byte as the
    Compressed-Flag and the next four as a big-endian length — for a body
    starting `<htm`, 1752460652 — and raises

        truncated payload — envelope at offset 0 declares 1752460652 bytes

    i.e. a FRAMING diagnostic, naming a length invented out of the HTML, for
    what is actually a ROUTING failure. The operator is sent to debug a framing
    bug that does not exist. grpc-go checks the content-type FIRST and reports
    the type it actually got.

    ⚠ TWO DELIBERATE NARROWINGS, both of which a stricter reading would break:

    1. A MISSING content-type is NOT an error here. grpc-go does reject it
       (`malformed header: missing HTTP content-type`), but a TRAILERS-ONLY
       response carrying a real `grpc-status` and no content-type must still
       surface that status — the status is the answer, and is strictly more
       informative than a header complaint about the envelope that carried it.
       Pinned by `test_unary_trailers_only_without_content_type_is_not_an_eof`.
    2. The predicate is `komira_http.transport.grpc_emit.is_grpc_content_type`,
       the SAME one the serve loop routes on — not a second list.
       It admits gRPC, gRPC-Web and Connect types, so it is correct for every
       `Protocol` conformer without a per-protocol table that would drift from
       the router's.

    The gRPC-status check runs BEFORE this at every call site, so a server that
    states a real `grpc-status` always wins over a content-type complaint.
    """
    var ct_opt = headers.get(String("content-type"))
    if not ct_opt.__bool__():
        return Optional[String]()
    var ct = ct_opt.value()
    if is_grpc_content_type(ct):
        return Optional[String]()
    return Optional[String](ct)


def _raise_if_non_rpc_content_type(ct_problem: Optional[String]) raises:
    """Raise the typed INTERNAL status for a `_non_rpc_content_type` finding.

    Separate from the detection because the detection must run BEFORE the
    response is consumed by the body drain, and the raise must run AFTER it so
    the stream slot is released first — the same ordering the gRPC-status check
    at every call site already uses.
    """
    if not ct_problem.__bool__():
        return
    raise Error(
        format_grpc_error_message(
            GRPC_STATUS_INTERNAL,
            String(
                "komira_grpc: the response is not a gRPC response —"
                " content-type: "
            )
            + ct_problem.value()
            + ". The peer answered HTTP 200 with a non-RPC body (a proxy error"
            " page, a captive portal or a misrouted request); its bytes are"
            " not 5-byte-enveloped and must not be read as though they were",
        )
    )


# =============================================================================
# §1 — UnaryResult — the decoded unary response message bytes + status.
# =============================================================================


struct UnaryResult(Movable, Deinitable):
    """The decoded inner message bytes of a unary response.

    The generated stub feeds `message_bytes` into `Resp.decode[D]` to get
    the typed response. `http_status` / `grpc_status` are surfaced for
    diagnostics; on a non-OK status the GrpcClient raises before
    constructing a successful UnaryResult, so a returned UnaryResult always
    carries the OK message bytes.

    Movable, NOT Copyable — owns `message_bytes`.
    """

    var message_bytes: List[UInt8]
    """The envelope-stripped (gRPC) / bare (Connect) inner response bytes."""

    var http_status: UInt16
    """The HTTP status line value (200 on gRPC success)."""

    def __init__(out self, var message_bytes: List[UInt8], http_status: UInt16):
        self.message_bytes = message_bytes^
        self.http_status = http_status


# =============================================================================
# §2 — GrpcClient[C] — the wire layer wired onto HttpClient.
# =============================================================================


struct GrpcClient[C: Connector](Movable, Deinitable):
    """The production gRPC / Connect client. Wraps a single
    `HttpClient[C]` and dispatches the transport-free wire layer over it.

    Parametric over `C: Connector` (the HTTP transport's connector type) —
    monomorphizes to the concrete connector (KernelTcpConnector /
    TlsConnector / ScriptedConnector) at the construction site.

    The wire-protocol axis `P: Protocol` is a comptime parameter on each
    METHOD (not the struct), so one GrpcClient instance can drive multiple
    protocols (though generated stubs fix P at codegen time via the
    `<Service>Client[C, P]` struct parameter, which forwards P into each
    `unary_call[Self.P, ...]` call).

    Construction:
      * `GrpcClient(http, base_url)` — owned HttpClient + base authority Url.
      * `GrpcClient.new(http, base_url)` — same, static factory.

    Fields:
      _http     — the HTTP transport, held as OwnedPointer (single-owner
                  heap handle; the raw client never crosses the module
                  boundary).
      _base_url — scheme + host + port for the RPC endpoint. The per-call
                  RPC path (`/pkg.Service/Method`) is spliced onto this
                  authority to form the request target.
      _retry_budget_us — the wall budget of the not-processed re-issue
                  sequence; see `with_retry_budget_ms`.

    The reactor (`mut reactor`), cancellation token (`ref token`), and the
    runtime clock reading (`now_us`) are threaded per-call — NOT stored as
    fields — per call_options.mojo's design note (no borrowed-pointer
    fields).

    Movable, NOT Copyable — owns the HttpClient via OwnedPointer.
    """

    var _http: OwnedPointer[HttpClient[Self.C]]
    """The HTTP transport. OwnedPointer (single-owner heap allocation,
    stable address)."""

    var _base_url: Url
    """Scheme + host + port; the RPC path is appended per call."""

    var _plaintext_h2c: Bool
    """When True AND the base url is http://, the unary
    path drives the transport's h2c PRIOR-KNOWLEDGE route
    (`HttpClient.send_grpc_pooled_h2c`) instead of the default plaintext-h1
    fallback. Set by a caller that KNOWS the (http://) endpoint is a cleartext
    HTTP/2 gRPC server (e.g. a local cloud-service emulator). Default False:
    https → pooled h2 multiplex; http → fresh-dial h1."""

    var _retry_budget_us: Int64
    """Wall-clock budget (µs) of one not-processed re-issue sequence
    (`_not_processed_retry_or_raise`). Defaults to
    `_GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT`; set with `with_retry_budget_ms`."""

    def __init__(out self, var http: HttpClient[Self.C], var base_url: Url):
        self._http = OwnedPointer(http^)
        self._base_url = base_url^
        self._plaintext_h2c = False
        self._retry_budget_us = _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT

    def __init__(
        out self,
        var http: HttpClient[Self.C],
        var base_url: Url,
        plaintext_h2c: Bool,
    ):
        """As above, but with explicit h2c-prior-knowledge routing for a
        plaintext (http://) cleartext-HTTP/2 endpoint."""
        self._http = OwnedPointer(http^)
        self._base_url = base_url^
        self._plaintext_h2c = plaintext_h2c
        self._retry_budget_us = _GOAWAY_RETRY_WALL_BUDGET_US_DEFAULT

    @staticmethod
    def new(var http: HttpClient[Self.C], var base_url: Url) -> GrpcClient[Self.C]:
        return GrpcClient[Self.C](http^, base_url^)

    def with_retry_budget_ms(mut self, budget_ms: String):
        """Set the wall budget of the not-processed re-issue sequence, in
        MILLISECONDS, as decimal text — the form a binary's command-line flag
        delivers it in. The value is configuration supplied by the caller;
        this library reads no environment.

        Empty / non-numeric / <= 0 / > 24h ⇒ the default (90 s): the setting
        can STATE a budget, never remove one, so no input yields an unbounded
        retry loop. The attempt cap (`_GOAWAY_RETRY_MAX_ATTEMPTS`) is not
        configurable."""
        self._retry_budget_us = _resolve_goaway_retry_budget_us(budget_ms)

    # -------------------------------------------------------------------------
    # §2.1 — URL splicing helper.
    # -------------------------------------------------------------------------

    def _url_for_path(self, path: String) -> Url:
        """Build a per-call Url from the base authority + the RPC path.

        The RPC path (`/pkg.Service/Method`) becomes the request-target;
        the scheme/host/port come from the configured base URL.
        """
        return Url(
            scheme=String(self._base_url.scheme),
            host=String(self._base_url.host),
            port=self._base_url.port,
            path=String(path),
        )

    # -------------------------------------------------------------------------
    # §3 — unary_call[P] — (false, false): 1 req → 1 resp.
    # -------------------------------------------------------------------------

    def unary_call[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        request_message_bytes: Span[UInt8, _],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> UnaryResult:
        """Drive one unary RPC end-to-end.

        Flow:
          1. encode_unary_request[P]  — message bytes → request body bytes
             (5-byte envelope for classic gRPC; bare body for Connect).
          2. build_unary_request_headers[P] — content-type / accept /
             connect-protocol-version / grpc-timeout / metadata.
          3. build_request_with_body[BytesBody] + HttpClient.send — drive
             one request/response over the transport.
          4. _drain_unary_response — pull the RecvRingBody to End, honoring
             cancellation; surface CANCELLED as DEADLINE_EXCEEDED.
          5. decode_unary_response[P] — response body bytes → inner message
             bytes (raises GrpcError on non-OK).

        Args:
          path: The full RPC path `/pkg.Service/Method`.
          request_message_bytes: The already-serialized request message
            (the generated stub's `Req.encode[E]` output).
          opts: CallOptions (deadline + metadata).
          now_us: The runtime's current clock reading in microseconds (for
            the relative Grpc-Timeout header). Pass the runtime's
            `now_us()`; the GrpcClient stays clock-agnostic.
          reactor / token: per-call runtime handles.

        Returns the decoded inner response message bytes (UnaryResult).
        Raises GrpcError (as a `[grpc:N]`-prefixed Error) on any non-OK
        status, cancellation, or transport failure.
        """
        # 1-3. Encode + build + send, re-issuing on a GOAWAY that the peer
        # guaranteed it did not process. See `_send_unary_bounded_goaway_retry`.
        var resp = self._send_unary_bounded_goaway_retry[RT, P](
            path, request_message_bytes, opts, now_us, reactor,
        )
        var http_status = UInt16(Int(resp.status))
        # 3a. gRPC status from the response HEADERS / TRAILERS (classic gRPC
        # carries the terminal `grpc-status` in HTTP/2 trailers — OR, for a
        # TRAILERS-ONLY response, in the initial HEADERS block). The h2 codec
        # keeps the two sections APART, so the status is read
        # from whichever one carried it — see `_grpc_status_from_sections`; a
        # bare `resp.headers` read drops the trailer case entirely and reports
        # every trailer-delivered failure as a SUCCESS. A non-OK code here MUST
        # raise the typed
        # `[grpc:N]` status — WITHOUT this, a trailers-only error (e.g.
        # ALREADY_EXISTS on a duplicate CreateTask) has an EMPTY body and
        # `decode_unary_response` would raise a generic "empty body" instead of
        # the real status the caller's classifier keys on. Captured BEFORE the
        # `resp^` drain consumes the response.
        var grpc_err_opt = _grpc_status_from_sections(
            resp.headers, resp.trailers,
        )
        # 3b. Is this a gRPC response AT ALL? Captured here for the same reason
        # as the status above — `resp^` is consumed by the drain below. See
        # `_non_rpc_content_type`.
        var ct_problem = _non_rpc_content_type(resp.headers)
        # 4. Drain the streaming response body to completion (cancellation-
        #    aware) into one List[UInt8].
        var body_bytes = self._drain_response_body[RT](resp^, reactor, token)
        # 4a. Raise the trailer/header gRPC status if it is non-OK (do this
        # AFTER the drain so the stream slot is released first). Only the
        # enveloped (classic gRPC) protocol carries status in trailers; Connect
        # carries it in the body/HTTP-status, which decode_unary_response below
        # already handles.
        comptime if P.unary_is_enveloped():
            if grpc_err_opt.__bool__():
                ref ge = grpc_err_opt.value()
                if not ge.is_ok():
                    raise Error(
                        format_grpc_error_message(ge.code, ge.message)
                    )
        # 4b. No status was stated. If the body is not an RPC body at all, say
        # THAT — feeding it to the envelope decoder yields a framing diagnostic
        # for a routing failure. Ordered after the status raise on purpose: a
        # server that stated a real `grpc-status` has already answered.
        _raise_if_non_rpc_content_type(ct_problem)
        # 5. Decode the unary response (raises GrpcError on non-OK).
        var inner = decode_unary_response[P](Span(body_bytes), http_status)
        # decode_unary_response returns a span over body_bytes; copy out so
        # the returned UnaryResult owns its bytes (body_bytes drops here).
        var out = List[UInt8]()
        for i in range(len(inner)):
            out.append(inner[i])
        return UnaryResult(out^, http_status)

    # -------------------------------------------------------------------------
    # §3b — unary_call_retrying[P] — the STATUS-CODE replay (AIP-194).
    # -------------------------------------------------------------------------

    def unary_call_retrying[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        request_message_bytes: Span[UInt8, _],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
        policy: RetryPolicy,
    ) raises -> UnaryResult:
        """`unary_call`, replayed on the STATUS codes `policy` names.

        ⚠ TWO DIFFERENT RETRY LAYERS LIVE IN THIS FILE, AND THEY ARE NOT
        REDUNDANT. `_send_unary_bounded_goaway_retry` (§3a, below) retries a
        TRANSPORT event that carries a PROOF the peer did not process the
        request (RFC 9113 §6.8), which is why it is safe for a non-idempotent
        verb and is always on. THIS layer retries a SERVER STATUS, which carries
        no such proof — so it is gated on the caller's `policy`, which encodes
        whether replaying THIS VERB is safe. Neither subsumes the other: the
        GOAWAY class never reaches a `[grpc:N]` status, and a `[grpc:14]` never
        carries a Last-Stream-ID.

        WHY THE POLICY IS A PARAMETER AND NOT A CONSTANT HERE. Replay-safety is
        a property of the METHOD, and the only place that knows it is the proto
        model. The code generator derives it (from the `(google.api.http)`
        verb) and emits it at each call site, so the
        choice is visible in the generated source and auditable per verb rather
        than buried in the substrate.

        A policy that `retries_nothing()` routes straight to `unary_call` — no
        retry layer at all, byte for byte, and the default for every verb whose
        idempotency is not proven.

        BOUNDED, and on both axes that matter: `policy.max_attempts` (<= 16 by
        construction) and `policy.max_backoff_ms` (<= 120 s by construction), so
        the worst case is a bounded number of bounded waits. The exhaustion
        error names the attempt count, the policy's cap, and the last status —
        a give-up that cannot be diagnosed without a rebuild is useless in a
        log.

        ⚠ A NON-RETRYABLE STATUS PROPAGATES VERBATIM, ON THE FIRST ATTEMPT. A
        `PERMISSION_DENIED`, an `INVALID_ARGUMENT`, a `NOT_FOUND` must fail
        PROMPTLY and with the message the caller's error classifier already
        matches. A retry that turns a permanent failure into a slow permanent
        failure has spent the caller's budget to learn nothing.

        `now_us` is deliberately the ORIGINAL reading on every attempt, matching
        `_send_unary_bounded_goaway_retry`: `build_unary_request_headers`
        derives `Grpc-Timeout` as (opts.deadline - now_us), and re-reading the
        clock would hand each replay a freshly-computed timeout.
        """
        # The hot path: no clock read, no counter, no branch beyond this one.
        # Every method codegen could not prove idempotent lands here.
        if policy.retries_nothing():
            return self.unary_call[RT, P](
                path, request_message_bytes, opts, now_us, reactor, token,
            )
        var attempt = 0
        while True:
            attempt = attempt + 1
            try:
                return self.unary_call[RT, P](
                    path, request_message_bytes, opts, now_us, reactor, token,
                )
            except e:
                var last_msg = String(e)
                # PERMANENT (or a transport error with no `[grpc:` status, whose
                # verdict is unknown and whose one provably-safe class §3a
                # already handled): propagate verbatim, immediately.
                if not is_retryable_grpc_error(last_msg, policy):
                    raise Error(last_msg)
                if attempt >= policy.max_attempts:
                    raise Error(
                        "[grpc-retry:EXHAUSTED] gave up replaying "
                        + path
                        + " after "
                        + String(attempt)
                        + " attempt(s) (policy max_attempts="
                        + String(policy.max_attempts)
                        + ", max_backoff_ms="
                        + String(policy.max_backoff_ms)
                        + "); every attempt returned a status this method's"
                        " policy treats as transient. Last: "
                        + last_msg
                    )
                # Full jitter, so N concurrent callers entering backoff
                # together do not re-synchronise onto the same retry instant.
                sleep_backoff_ms(
                    backoff_draw_ms(
                        attempt,
                        policy,
                        UInt64(attempt) ^ UInt64(path.byte_length()),
                    )
                )

    # -------------------------------------------------------------------------
    # §3a — the GOAWAY-unprocessed re-issue (RFC 9113 §6.8).
    # -------------------------------------------------------------------------

    def _send_unary_bounded_goaway_retry[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        request_message_bytes: Span[UInt8, _],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """Send ONE unary request, re-issuing it on a NEW connection when — and
        ONLY when — the peer guaranteed it did not process the stream.

        WHY THIS LAYER. Every generated unary stub method funnels through
        `unary_call` (the code generator emits exactly one call shape), so
        handling it here covers every generated service at once, rather than
        the one verb that happens to surface it. It is
        also the LOWEST layer that CAN retry: `HttpClient.send_grpc_pooled`
        consumes its `ClientRequest` destructively, whereas every input here is
        borrowed and the request is rebuilt from scratch per attempt.

        ⚠ THE GATE IS THE STREAM-ID COMPARISON, NOT THE WORD "GOAWAY".
        `is_h2_goaway_unprocessed` keys on a token emitted by exactly one branch
        of the h2 driver — the one that proved `stream id > Last-Stream-ID`,
        RFC 9113 §6.8's definitive not-processed guarantee. That is what makes
        re-issuing safe for a NON-IDEMPOTENT verb (a `CreateJob`, a `RunJob`):
        the peer states it took no action. Every other error — including the
        at-or-below GOAWAY class, which carries `h2-goaway-maybe-processed` and
        NO guarantee — propagates verbatim on the first raise. Retrying that
        class would double-execute the request; the caller is the layer that
        can handle it (for example with adopt-then-reconcile, which is the
        correct remedy when the verdict is unknown).

        HOW THE RE-ISSUE REACHES A NEW CONNECTION. The raise unwinds through
        `_drive_one_h2_streaming_on_pool`, which owns the `H2ClientPool` by
        value for the duration of the drive — so the pool (and the GOAWAY'd
        conn's socket) is dropped, and `HttpClient._h2_pool` was already
        emptied by the `.take()` that started the send. The next attempt's
        `ensure_h2_pool` therefore finds no pool, takes the NEEDS_DIAL path and
        dials fresh. The test asserts this behaviourally via
        `ScriptedConnector.connect_call_count()` — one dial per attempt — so it
        cannot silently regress into re-using the draining connection, which
        would meet the same GOAWAY every time.

        Bounded on attempts AND wall clock; the exhaustion error names both.
        """
        var attempts = 0
        # The only work the SUCCESS path pays for: one monotonic clock read
        # (a vDSO `clock_gettime`). The wall budget is a field already
        # resolved at configuration time, so the failure branch reads no
        # configuration either.
        var t0_ns = Int64(_mono_now_ns())
        while True:
            attempts = attempts + 1
            # Rebuild the request from the (borrowed) inputs on EVERY attempt —
            # the send consumes it, and a replayed request must be byte-fresh.
            #
            # `now_us` is deliberately the ORIGINAL reading, not a fresh one:
            # `build_unary_request_headers` derives `Grpc-Timeout` as
            # (opts.deadline - now_us), so re-reading the clock would hand each
            # retry a FULL fresh timeout and let a retry sequence outlive the
            # caller's absolute deadline. Keeping it pinned means the retries
            # spend the caller's budget, not a new one.
            var req_body_bytes = encode_unary_request[P](request_message_bytes)
            var hdrs = build_unary_request_headers[P](opts, now_us)
            var url = self._url_for_path(path)
            var req = build_streaming_request[BytesBody](
                method_post(),
                url^,
                hdrs^,
                BytesBody.from_bytes(req_body_bytes^),
            )
            try:
                # Route through
                # the h2-multiplex pool so N concurrent RPCs to the same
                # authority share ONE connection. send_grpc_pooled returns the
                # same streaming ClientResponse[RecvRingBody] `send` does
                # (byte-identical response), but reuses the pooled h2 conn
                # instead of fresh-dialing per RPC.
                #
                # When this client was configured for a
                # plaintext h2c (cleartext HTTP/2) endpoint, route the (http://)
                # request through the transport's h2c PRIOR-KNOWLEDGE path
                # instead — gRPC requires HTTP/2, so a plaintext h2c server
                # (e.g. a local cloud-service emulator) needs h2 framing, not the
                # default plaintext-h1 fallback.
                if self._plaintext_h2c and self._base_url.is_http():
                    return self._http[].send_grpc_pooled_h2c[RT, BytesBody](
                        req^, reactor,
                    )
                return self._http[].send_grpc_pooled[RT, BytesBody](
                    req^, reactor,
                )
            except e:
                # Raises (verbatim, or EXHAUSTED) or returns => loop. The next
                # attempt dials a fresh connection (see the HOW THE RE-ISSUE
                # REACHES A NEW CONNECTION note above).
                _not_processed_retry_or_raise(
                    path, attempts, t0_ns, String(e), self._retry_budget_us
                )

    # -------------------------------------------------------------------------
    # §4 — server_stream[P] — (false, true): 1 req → N resp.
    # -------------------------------------------------------------------------

    def server_stream[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        request_message_bytes: Span[UInt8, _],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> ServerStreamDecoder[P]:
        """Open a server-streaming RPC: send ONE request, return a
        ServerStreamDecoder[P] pre-loaded with every response Data byte.

        Flow:
          1. encode_stream_message[P] — envelope-frame the single request
             message (streaming uses the 5-byte envelope for BOTH classic
             gRPC and Connect, unlike unary).
          2. build_stream_request_headers[P] — content-type / accept
             (`application/connect+proto` for Connect-streaming, not the
             unary `application/proto`).
          3. HttpClient.send.
          4. Pull the RecvRingBody to End (cancellation-aware), feeding each
             Data chunk into the decoder. The caller then drives
             `decoder.try_next_message()` to pull decoded messages.

        For classic gRPC the terminating status arrives in HTTP/2 trailers,
        which the response section split surfaces and the status check below
        reads; the RecvRingBody drain itself does not surface trailers, so
        the decoder's Connect END_STREAM envelope path handles termination
        for Connect-streaming. The decoder's `feed_trailers` is the hook for
        a drain that does surface them.

        Returns the loaded decoder. Raises on transport failure or
        cancellation.
        """
        # 1-3. Encode + build + send, re-issuing on a GOAWAY that the peer
        # guaranteed it did not process. See
        # `_send_server_stream_bounded_goaway_retry`.
        var resp = self._send_server_stream_bounded_goaway_retry[RT, P](
            path, request_message_bytes, opts, now_us, reactor,
        )
        # 3a. gRPC status from the response HEADERS / TRAILERS, captured BEFORE
        # the drain. A server-streaming ERROR
        # (e.g. ReadObject on a missing object -> NOT_FOUND, code 5) is a
        # TRAILERS-ONLY response: the terminal `grpc-status` rides in the HTTP/2
        # trailers and the body is EMPTY. Without surfacing it here, the decoder
        # loads ZERO messages and the caller (e.g. read_range) returns an EMPTY
        # buffer instead of raising NOT_FOUND — a truncated/silent read. The
        # unary path does this too (§3a); the server-stream path needs the
        # parallel check so a caller's error mapper can classify it. The
        # head and trailer sections are kept APART by the h2 codec, so the
        # status is read from whichever one carried it —
        # see `_grpc_status_from_sections`.
        var grpc_err_opt = _grpc_status_from_sections(
            resp.headers, resp.trailers,
        )
        # Is this a gRPC response AT ALL? Captured before the drain consumes
        # `resp`. See `_non_rpc_content_type`.
        var ct_problem = _non_rpc_content_type(resp.headers)
        var body_bytes = self._drain_response_body[RT](resp^, reactor, token)
        # 3b. Raise the trailer/header gRPC status if it is non-OK (AFTER the
        # drain so the stream slot is released first). Only the enveloped
        # (classic gRPC) protocol carries status in trailers.
        comptime if P.unary_is_enveloped():
            if grpc_err_opt.__bool__():
                ref ge = grpc_err_opt.value()
                if not ge.is_ok():
                    raise Error(
                        format_grpc_error_message(ge.code, ge.message)
                    )
        _raise_if_non_rpc_content_type(ct_problem)
        var decoder = ServerStreamDecoder[P].new()
        decoder.feed_owned(body_bytes^)
        return decoder^

    # -------------------------------------------------------------------------
    # §4a — the server-stream GOAWAY-unprocessed re-issue (RFC 9113 §6.8).
    # -------------------------------------------------------------------------

    def _send_server_stream_bounded_goaway_retry[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        request_message_bytes: Span[UInt8, _],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """`_send_unary_bounded_goaway_retry`, for the SERVER-STREAMING arm.

        WHY A SEPARATE ARM. `_send_unary_bounded_goaway_retry` is reached only
        from `unary_call` (and the codegen's `unary_call_retrying`, which routes
        into it), so without this a GOAWAY met on a server-streaming RPC (a GCS
        `ReadObject`, for example) would propagate verbatim as a RAW GOAWAY
        rather than being re-issued or exhausting as
        `H2_GOAWAY_RETRY_EXHAUSTED`.

        ### WHY THE IDEMPOTENCY ARGUMENT CARRIES HERE, AND THE ARGUMENT ITSELF

        Re-issuing is safe for a NON-IDEMPOTENT verb because RFC 9113 §6.8's
        `Last-Stream-ID` is the peer STATING it took no action — that is the
        gate (`is_h2_goaway_unprocessed`), not the word "GOAWAY". But the gate is
        only half of it: the request must also be REBUILDABLE byte-fresh per
        attempt, or attempt 2 sends something different from attempt 1.

        That precondition holds here for the same reason it holds for unary:
        every input is BORROWED (`request_message_bytes` is a `Span`), so the
        envelope, the headers, the URL and the request are all built INSIDE the
        loop from inputs the send cannot consume. `send_grpc_pooled` destroys
        its `ClientRequest`; nothing it destroys is the caller's.

        ### THE CLIENT-STREAMING ARM IS COVERED TOO (§4b)

        It is tempting to believe `client_stream` cannot be re-issued because
        it builds its body by DRAINING an owned encoder, so "after attempt 1
        the encoder holds nothing". That premise is false:
        `ClientStreamEncoder.drain_chunk` is a COPY-OUT drain that advances
        `_drain_cursor` and NEVER truncates `_buf`. The framed body survives
        the drain, so the rebuild is a cursor store (`rewind_for_reissue`) and
        costs the success path nothing. See §4b, which covers that arm under
        this same gate. `bidi_stream` REMAINS excluded, on the narrower ground
        stated there.

        Bounded on attempts AND wall clock by the SAME `_not_processed_retry_or_raise`
        the unary arm uses — one gate, one exhaustion message, no drift.

        ⚠ NO h2c BRANCH, deliberately: `server_stream` has never had one (only
        `unary_call` routes `_plaintext_h2c` through `send_grpc_pooled_h2c`), and
        adding one here would change plaintext-h2c server-streaming behaviour
        under cover of a retry fix. That gap is real and is left stated.
        """
        var attempts = 0
        # One monotonic clock read on the success path, as in the unary arm.
        var t0_ns = Int64(_mono_now_ns())
        while True:
            attempts = attempts + 1
            # Rebuild from the (borrowed) inputs on EVERY attempt — the send
            # consumes the request, and a replayed request must be byte-fresh.
            #
            # `now_us` is deliberately the ORIGINAL reading, not a fresh one:
            # `build_stream_request_headers` derives `Grpc-Timeout` as
            # (opts.deadline - now_us), so re-reading the clock would hand each
            # retry a FULL fresh timeout and let the sequence outlive the
            # caller's absolute deadline.
            var out_buf = List[UInt8]()
            encode_stream_message[P](out_buf, request_message_bytes)
            var hdrs = build_stream_request_headers[P](opts, now_us)
            var url = self._url_for_path(path)
            var req = build_streaming_request[BytesBody](
                method_post(),
                url^,
                hdrs^,
                BytesBody.from_bytes(out_buf^),
            )
            try:
                # Pooled h2
                # multiplex.
                return self._http[].send_grpc_pooled[RT, BytesBody](
                    req^, reactor,
                )
            except e:
                # Raises (verbatim, or EXHAUSTED) or returns => loop. The raise
                # unwinds through `_drive_one_h2_streaming_on_pool`, which owns
                # the `H2ClientPool` by value for the drive, so the GOAWAY'd
                # connection is dropped and the next attempt's `ensure_h2_pool`
                # takes the NEEDS_DIAL path and dials fresh.
                _not_processed_retry_or_raise(
                    path, attempts, t0_ns, String(e), self._retry_budget_us
                )

    # -------------------------------------------------------------------------
    # §4b — the client-stream GOAWAY-unprocessed re-issue (RFC 9113 §6.8).
    # -------------------------------------------------------------------------

    def _send_client_stream_bounded_goaway_retry[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        mut encoder: ClientStreamEncoder[P],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[RecvRingBody[Self.C.Stream]]:
        """`_send_unary_bounded_goaway_retry`, for the CLIENT-STREAMING arm.

        WHY A SEPARATE ARM. A client-streaming upload (a GCS `WriteObject`, for
        example) that meets

            HttpError[H2_PROTOCOL]: GOAWAY received; stream 21 >
            last_stream_id 19; will not be processed [h2-goaway-unprocessed]

        carries RFC 9113 §6.8's definitive not-processed guarantee (21 > 19);
        failing the request anyway would be the wrong action on a correct
        diagnosis. `WriteObject` is CLIENT-STREAMING, so it reaches
        `client_stream` — an arm the unary (§3a) and server-stream (§4a)
        re-issues do not cover.

        ### ⚠ THE REPLAY WARRANT IS THE PEER'S STATEMENT, NOT THE VERB'S SEMANTICS

        `WriteObject` is NOT idempotent and NOT in the SAFE set, so a
        verb-idempotency predicate (Go's `Request.isReplayable`, RFC 9110
        §9.2.2) correctly refuses it — and would be the WRONG question here.
        Idempotency is a promise the ORIGIN SERVER makes about what a method
        MEANS, which a client cannot verify. An unprocessed-stream GOAWAY is a
        strictly stronger and independently sufficient warrant: the peer has
        stated what it DID (nothing). `_not_processed_retry_or_raise` is gated on
        that proof and on nothing else — never on the verb, never on the word
        "GOAWAY".

        ### ★ WHY "THE ENCODER IS DRAINED, SO A REBUILD IS IMPOSSIBLE" IS FALSE

        It is tempting to exclude this arm on the grounds that `client_stream`
        DRAINS its `ClientStreamEncoder` (`while encoder.pending_bytes() > 0:
        drain_chunk(…)`), so "after attempt 1 the encoder holds nothing" and the
        only rebuild would be a retained multi-MiB COPY of the body, paid on
        the success path of every upload.

        Both halves are false, and they are false for the same one-line reason:
        **`ClientStreamEncoder.drain_chunk` does not truncate `_buf`.** It is a
        copy-out drain that advances `_drain_cursor`; the framed body is intact
        in the encoder for the encoder's whole life. So the rebuild is
        `encoder.rewind_for_reissue()` — a cursor store — and the SUCCESS path
        pays NOTHING it did not already pay (one drain, cursor never rewound, no
        retained copy, no extra allocation). A re-issue costs one more drain of a
        buffer that was going to be sent over TLS anyway.

        Nor is this case rare: a long-lived connection to a front end that
        recycles connections meets it routinely, and each unretried
        occurrence permanently loses one upload.

        Bounded on attempts AND wall clock by the SAME
        `_not_processed_retry_or_raise` the other two arms use — one gate, one
        exhaustion message, no drift.

        ⚠ `bidi_stream` REMAINS EXCLUDED and the exclusion is now narrow and
        real: its `BidiStreamCodec` is drained IN PLACE by a caller that may
        interleave, and its buffered shape is not the full-duplex shape it is
        headed for. A GOAWAY on it propagates verbatim.

        ⚠ NO h2c BRANCH, deliberately — same as §4a: only `unary_call` routes
        `_plaintext_h2c` through `send_grpc_pooled_h2c`, and adding one here
        would change plaintext-h2c client-streaming behaviour under cover of a
        retry fix. That gap is real and is left stated.
        """
        var attempts = 0
        # One monotonic clock read on the success path, as in the other arms.
        var t0_ns = Int64(_mono_now_ns())
        var max_chunk = 1 << 20
        while True:
            attempts = attempts + 1
            # Rebuild the body byte-fresh from the encoder on EVERY attempt.
            # `rewind_for_reissue` is a no-op on attempt 1 (nothing drained
            # yet), so the first send does no extra work.
            encoder.rewind_for_reissue()
            var req_body = List[UInt8]()
            while encoder.pending_bytes() > 0:
                var chunk = encoder.drain_chunk(max_chunk)
                for i in range(len(chunk)):
                    req_body.append(chunk[i])
            # `now_us` is deliberately the ORIGINAL reading, not a fresh one:
            # `build_stream_request_headers` derives `Grpc-Timeout` as
            # (opts.deadline - now_us), so re-reading the clock would hand each
            # retry a FULL fresh timeout and let the sequence outlive the
            # caller's absolute deadline. The retries spend the caller's
            # budget, not a new one.
            var hdrs = build_stream_request_headers[P](opts, now_us)
            var url = self._url_for_path(path)
            var req = build_streaming_request[BytesBody](
                method_post(),
                url^,
                hdrs^,
                BytesBody.from_bytes(req_body^),
            )
            try:
                # Pooled h2
                # multiplex.
                return self._http[].send_grpc_pooled[RT, BytesBody](
                    req^, reactor,
                )
            except e:
                # Raises (verbatim, or EXHAUSTED) or returns => loop. The raise
                # unwinds through `_drive_one_h2_streaming_on_pool`, which owns
                # the `H2ClientPool` by value for the drive, so the GOAWAY'd
                # connection is dropped and the next attempt's `ensure_h2_pool`
                # takes the NEEDS_DIAL path and dials FRESH. A re-issue can
                # therefore never meet the same draining connection.
                _not_processed_retry_or_raise(
                    path, attempts, t0_ns, String(e), self._retry_budget_us
                )

    # -------------------------------------------------------------------------
    # §5 — client_stream[P] — (true, false): N req → 1 resp.
    # -------------------------------------------------------------------------

    def client_stream[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        var encoder: ClientStreamEncoder[P],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> UnaryResult:
        """Drive a client-streaming RPC: the caller has already buffered N
        request messages into `encoder` (via `encoder.encode_message(...)`)
        and called `encoder.mark_close()`. This method drains the encoder's
        envelope-framed buffer into ONE request body, sends it, and returns
        the single terminal response message.

        Flow:
          1+2. Drain the encoder's framed buffer (half-close = END_STREAM is
             implicit in the buffered shape — all N messages are in one
             body; the request End IS the half-close), build the headers and
             send — all inside `_send_client_stream_bounded_goaway_retry`
             (§4b), which RE-ISSUES on a new connection when the peer proved it
             did not process the stream (RFC 9113 §6.8).
          3. Drain the response; the FIRST decoded message is the single
             client-streaming response (a client-stream yields one response
             message).

        The full request side is buffered before send. True incremental
        client-streaming (interleaved send while draining) is an HTTP/2
        StreamingBody follow-up; the encoder's drain_chunk API is ready for
        it. The wire form is identical either way.

        Returns the single response message bytes. Raises on a non-OK
        terminal status, cancellation, or transport failure.
        """
        # 1+2. Drain the (already mark_close'd) encoder's framed buffer, build
        # the request and send it — BOUNDED-RE-ISSUING on a not-processed proof
        # (§4b). A GOAWAY whose Last-Stream-ID excludes our stream is the peer
        # stating it did not process the request, which licenses a re-issue on a
        # NEW connection even for a non-idempotent verb like `WriteObject`.
        var resp = self._send_client_stream_bounded_goaway_retry[RT, P](
            path, encoder, opts, now_us, reactor,
        )
        var http_status = UInt16(Int(resp.status))
        # 2a. gRPC status from the response HEADERS / TRAILERS, captured BEFORE
        # the drain consumes the response. A
        # client-streaming ERROR (e.g. WriteObject with a stale
        # ifGenerationMatch -> FAILED_PRECONDITION) is a TRAILERS-ONLY response:
        # the terminal `grpc-status` rides in the HTTP/2 trailers and the body
        # is EMPTY. Without surfacing it here, `_first_stream_message` sees the
        # empty body and raises a generic "client-stream produced no response
        # message" (grpc_code 2 -> classifies as TRANSPORT) instead of the REAL
        # status (e.g. 9 FAILED_PRECONDITION -> PRECONDITION/412). The unary
        # path does this too (§3a); the streaming path needs the parallel
        # check. The head and trailer sections are kept APART by the h2 codec,
        # so the status is read from whichever one carried it —
        # see `_grpc_status_from_sections`.
        var grpc_err_opt = _grpc_status_from_sections(
            resp.headers, resp.trailers,
        )
        # Is this a gRPC response AT ALL? Captured before the drain consumes
        # `resp`. See `_non_rpc_content_type`.
        var ct_problem = _non_rpc_content_type(resp.headers)
        var body_bytes = self._drain_response_body[RT](resp^, reactor, token)
        # 2b. Raise the trailer/header gRPC status if it is non-OK (AFTER the
        # drain so the stream slot is released first). Only the enveloped
        # (classic gRPC) protocol carries status in trailers.
        comptime if P.unary_is_enveloped():
            if grpc_err_opt.__bool__():
                ref ge = grpc_err_opt.value()
                if not ge.is_ok():
                    raise Error(
                        format_grpc_error_message(ge.code, ge.message)
                    )
        _raise_if_non_rpc_content_type(ct_problem)
        # 3. The response is streaming-framed; pull the FIRST message.
        var decoder = ServerStreamDecoder[P].new()
        decoder.feed_owned(body_bytes^)
        return self._first_stream_message[P](decoder^, http_status)

    # -------------------------------------------------------------------------
    # §6 — bidi_stream[P] — (true, true): N req ↔ N resp.
    # -------------------------------------------------------------------------

    def bidi_stream[
        RT: Runtime, P: Protocol
    ](
        mut self,
        path: String,
        var codec: BidiStreamCodec[P],
        opts: CallOptions,
        now_us: Int,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> ServerStreamDecoder[P]:
        """Drive a bidirectional-streaming RPC.

        Buffered shape: the caller has buffered N request messages into
        `codec.encoder` and called `mark_close()`. This method drains the
        request half (in place — no field destructuring) into one body,
        sends it, and returns a fresh response-half decoder fed with every
        response Data byte. The caller drives `decoder.try_next_message()`
        to pull the N response messages.

        The two halves are independently owned — the
        request half is consumed here (drain + send), and a fresh decoder
        carries the response half (the codec's own `.decoder` is empty at
        send time, so building a fresh one is equivalent and avoids
        partial-moving fields out of `codec`, which Mojo bans). `codec` is
        consumed (dropped) at scope end.
        True full-duplex interleaving over an HTTP/2 stream is a transport
        follow-up; the wire form (5-byte envelopes both directions) is
        identical.

        Returns the loaded response decoder. Raises on transport failure or
        cancellation.
        """
        # Drain the request half IN PLACE (mut codec.encoder) — no field
        # move out of `codec`.
        var req_body = List[UInt8]()
        var max_chunk = 1 << 20
        while codec.encoder.pending_bytes() > 0:
            var chunk = codec.encoder.drain_chunk(max_chunk)
            for i in range(len(chunk)):
                req_body.append(chunk[i])
        var hdrs = build_stream_request_headers[P](opts, now_us)
        var url = self._url_for_path(path)
        var req = build_streaming_request[BytesBody](
            method_post(),
            url^,
            hdrs^,
            BytesBody.from_bytes(req_body^),
        )
        # Pooled h2 multiplex.
        var resp = self._http[].send_grpc_pooled[RT, BytesBody](req^, reactor)
        # ⭐ THE TERMINAL-STATUS CHECK, as on the other three entry points.
        #
        # `unary_call` (§3a), `server_stream` (§4 3a) and `client_stream` (§5
        # 2a) each read the terminal status and raise a non-OK
        # code, and each of their comments describes at length the
        # silent-empty-result defect the check exists to prevent. Without it
        # here, a bidi RPC the server REJECTED (PERMISSION_DENIED on a
        # trailers-only response, the shape every permission failure uses)
        # would return a decoder the caller finds EMPTY, with no indication
        # the RPC had failed at all.
        #
        # Captured BEFORE the drain consumes `resp`, raised AFTER it so the
        # stream slot is released first — the same ordering as the other three.
        var grpc_err_opt = _grpc_status_from_sections(
            resp.headers, resp.trailers,
        )
        var ct_problem = _non_rpc_content_type(resp.headers)
        var body_bytes = self._drain_response_body[RT](resp^, reactor, token)
        # `codec` (and its now-drained encoder + empty decoder) drops here.
        _ = codec^
        comptime if P.unary_is_enveloped():
            if grpc_err_opt.__bool__():
                ref ge = grpc_err_opt.value()
                if not ge.is_ok():
                    raise Error(
                        format_grpc_error_message(ge.code, ge.message)
                    )
        _raise_if_non_rpc_content_type(ct_problem)
        var decoder = ServerStreamDecoder[P].new()
        decoder.feed_owned(body_bytes^)
        return decoder^

    # -------------------------------------------------------------------------
    # §7 — Response-drain helper (cancellation-aware).
    # -------------------------------------------------------------------------

    def _drain_response_body[
        RT: Runtime
    ](
        self,
        var resp: ClientResponse[RecvRingBody[Self.C.Stream]],
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> List[UInt8]:
        """Pull `resp.body.poll_frame` to End, concatenating every Data
        frame into one owned List[UInt8].

        Cancellation: `RecvRingBody.poll_frame` checks
        `token.is_cancelled()` on every wire-read iteration and returns an
        ERROR frame with detail "CANCELLED" when the runtime's clock has
        tripped the deadline token. This loop maps that to a raised
        GrpcError(DEADLINE_EXCEEDED) so the caller sees a typed status —
        the in-flight read aborts at the next poll boundary.

        This mirrors `komira_http.collect_body` but raises a GrpcError
        (with the `[grpc:N]` prefix) rather than a raw HttpError, so the
        whole gRPC call path raises one consistent error shape.
        """
        var out = List[UInt8]()
        var max_iter = 1_000_000
        var iter = 0
        while True:
            iter = iter + 1
            if iter > max_iter:
                raise Error(
                    String("[grpc:")
                    + String(Int(GRPC_STATUS_UNKNOWN))
                    + "] komira_grpc: response-drain iteration cap exceeded"
                )
            var frame = resp.body.poll_frame[RT](reactor, token)
            if frame.is_end():
                break
            if frame.is_error():
                var detail = frame.error_detail()
                # The clock-token cancellation surfaces as "CANCELLED" from
                # RecvRingBody.poll_frame's token.is_cancelled() check.
                if detail == String("CANCELLED"):
                    raise Error(
                        String("[grpc:")
                        + String(Int(GRPC_STATUS_DEADLINE_EXCEEDED))
                        + "] komira_grpc: call cancelled (deadline tripped"
                        " the cancellation token)"
                    )
                raise Error(
                    String("[grpc:")
                    + String(Int(GRPC_STATUS_UNKNOWN))
                    + "] komira_grpc: transport error: "
                    + detail
                )
            if frame.is_trailers():
                # The terminal status was read from the response sections
                # before the drain (`_grpc_status_from_sections`); discard.
                _ = frame^
                continue
            if frame.is_pending():
                # Synchronous re-poll (the collect_body convention).
                continue
            if frame.is_data():
                var chunk = frame.take_data_chunk()
                for k in range(len(chunk)):
                    out.append(chunk[k])
        return out^

    # -------------------------------------------------------------------------
    # §8 — First-stream-message helper (client-streaming terminal response).
    # -------------------------------------------------------------------------

    def _first_stream_message[
        P: Protocol
    ](
        self,
        var decoder: ServerStreamDecoder[P],
        http_status: UInt16,
    ) raises -> UnaryResult:
        """Pull the FIRST decoded message out of a loaded
        ServerStreamDecoder — the client-streaming RPC's single response.

        Drives `decoder.try_next_message()` until a MESSAGE (the response)
        or a terminating outcome. END_OK with no prior message raises (a
        client-streaming RPC must yield exactly one response message);
        END_ERROR raises the carried GrpcError.
        """
        var max_iter = 1_000_000
        var iter = 0
        while True:
            iter = iter + 1
            if iter > max_iter:
                raise Error(
                    String("[grpc:")
                    + String(Int(GRPC_STATUS_UNKNOWN))
                    + "] komira_grpc: client-stream decode cap exceeded"
                )
            var outcome = decoder.try_next_message()
            if outcome.kind == STREAM_OUTCOME_MESSAGE:
                var bytes = List[UInt8]()
                swap(bytes, outcome.message_bytes)
                return UnaryResult(bytes^, http_status)
            elif outcome.kind == STREAM_OUTCOME_PENDING:
                # All bytes already fed (buffered shape); PENDING here means
                # the body was empty — no response message arrived.
                raise Error(
                    String("[grpc:")
                    + String(Int(GRPC_STATUS_UNKNOWN))
                    + "] komira_grpc: client-stream produced no response"
                    " message"
                )
            elif outcome.kind == STREAM_OUTCOME_END_OK:
                raise Error(
                    String("[grpc:")
                    + String(Int(GRPC_STATUS_UNKNOWN))
                    + "] komira_grpc: client-stream ended before a response"
                    " message"
                )
            else:
                # STREAM_OUTCOME_END_ERROR — raise the carried status.
                # Read code + message by copy (String is Copyable) rather
                # than partial-moving `outcome.error` out of `outcome`
                # (Mojo bans partial moves).
                raise Error(
                    format_grpc_error_message(
                        outcome.error.code, outcome.error.message
                    )
                )
