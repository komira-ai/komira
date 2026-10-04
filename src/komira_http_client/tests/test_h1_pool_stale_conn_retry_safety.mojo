# =============================================================================
# src/komira_http_client/tests/test_h1_pool_stale_conn_retry_safety.mojo
#   THE h1 KEEPALIVE POOL: STALE-CONNECTION RECOVERY AND REPLAY SAFETY.
# =============================================================================
#
# ★ WHY THIS FILE EXISTS. A service can degrade for days on
#
#     HttpError[EOF_MID_RESPONSE: chunked body unterminated]
#
# raised out of a REUSED keepalive connection while every chunked test is
# green. Coverage by file count is not coverage: the chunked tests test the
# CODEC, and this defect is in the POOL — specifically in the question every
# production HTTP client has to answer:
#
#     is this truncation a transient to retry, or real data loss to surface?
#
# The reference answer is Go's `persistConn.shouldRetryRequest`
# (`net/http/transport.go`), a THREE-TERM rule:
#
#     reused-connection  AND  no-response-header-data-yet
#                        AND  (nothing-was-written  OR  request-is-replay-safe)
#
# Every term is load-bearing and each guards a different disaster:
#   * `reused` — a FRESH connection that EOFs must never be retried, or a
#     genuinely-dead endpoint loops forever (Go's own comment: "if we retried
#     now, we could loop forever").
#   * `no header data` — once ANY response byte has arrived the server HAS run
#     the request; replaying double-executes it.
#   * `nothing written OR replay-safe` — a request that reached the wire may
#     have been executed even if we never saw a byte back. ⚠ THE THIRD TERM IS
#     GO'S `req.isReplayable()`, WHICH IS **NARROWER THAN "IDEMPOTENT"**: it
#     admits GET/HEAD/OPTIONS/TRACE and an explicit `Idempotency-Key`, and it
#     excludes PUT and DELETE even though RFC 9110 §9.2.2 lists both as
#     idempotent — because idempotency there is a property of the intended
#     effect on the ORIGIN SERVER, a promise the client cannot verify.
#
# urllib3 states the complementary half (`connectionpool.py`, the
# `_put_conn`/discard table): a connection that left the request on ANY dirty
# exit — read timeout, write error, framing error, decode error, cancellation —
# is DISCARDED, never returned to the pool.
#
# This file writes that bar against the four h1 entry points, with
# ScriptedStream/ScriptedConnector and zero sockets.
#
# ⛔ THE TESTS BELOW THAT FAIL ARE THE DELIVERABLE. Each one names, in its own
# docstring, the exact production behaviour it observed and why the reference
# clients do the other thing. Do not weaken an assertion to make one green.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
    pool_key_for_origin,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import collect_body
from komira_http_client.response_parser import (
    ResponseHead,
    ResponseParseLimits,
    parse_response_head,
)
from komira_http_client.service import ClientRequest
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# Fixtures — same shape as the neighbouring keepalive tests.
# =============================================================================


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


comptime _KEEPALIVE_200_LEN: Int = 40
"""`HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK` — 40 bytes. Callers cap
`set_max_read_per_call` at this so one try_read serves exactly one response,
which is what a real socket does and what keeps the head parser from
overrunning into the NEXT scripted response."""


def _keepalive_200() -> List[UInt8]:
    """One HTTP/1.1 200 with `Content-Length: 2` and no Connection header —
    the HTTP/1.1 default, i.e. keepalive-eligible."""
    return _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))


def _extend(mut dst: List[UInt8], src: List[UInt8]):
    var i = 0
    var n = src.__len__()
    while i < n:
        dst.append(src[i])
        i = i + 1


def _concat(var a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    _extend(a, b)
    return a^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if a.__len__() != b.__len__():
        return False
    var i = 0
    while i < a.__len__():
        if a[i] != b[i]:
            return False
        i = i + 1
    return True


def _str_of(bs: List[UInt8]) -> String:
    var out = String()
    var i = 0
    while i < bs.__len__():
        out += chr(Int(bs[i]))
        i = i + 1
    return out^


def _url(path: String) raises -> Url:
    return Url.parse(String("http://127.0.0.1:9000") + path)


def _put_req(
    path: String, payload: String,
) raises -> ClientRequest[BytesBody]:
    var hdrs = HeaderMap()
    return build_request_with_body[BytesBody](
        HttpMethod.put(), _url(path), hdrs^, BytesBody.from_bytes(_b(payload)),
    )


def _put_req_with_header(
    path: String, payload: String, hname: String, hvalue: String,
) raises -> ClientRequest[BytesBody]:
    """`_put_req` plus ONE extra request header — the `Idempotency-Key`
    opt-in, whose whole point is that it is stated per-request by the caller
    and is visible in the serialized head the replay re-sends."""
    var hdrs = HeaderMap()
    hdrs.insert(String(hname), String(hvalue))
    return build_request_with_body[BytesBody](
        HttpMethod.put(), _url(path), hdrs^, BytesBody.from_bytes(_b(payload)),
    )


def _post_req(
    path: String, payload: String,
) raises -> ClientRequest[BytesBody]:
    var hdrs = HeaderMap()
    return build_request_with_body[BytesBody](
        HttpMethod.post(), _url(path), hdrs^, BytesBody.from_bytes(_b(payload)),
    )


def _get_req(path: String) raises -> ClientRequest[EmptyBody]:
    var hdrs = HeaderMap()
    return build_get_request(_url(path), hdrs^)


# =============================================================================
# §1 — STALE REUSE, EOF AT BYTE 0, ON EACH ENTRY POINT THAT POOLS.
# =============================================================================
#
# The canonical benign case and the one every reference client recovers from:
# the server reaped an idle keepalive connection, so the next request on it
# gets a FIN before a single response byte. Go: `errServerClosedIdle` ->
# retried. urllib3: the connection is dropped and a new one dialled.
#
# ⚠ The FOURTH entry point — `HttpClient.send`,
# the streaming default — does not pool at all; §1d is the structural
# proof, and its absence from the pool is itself the finding.


def test_stale_reuse_eof_at_byte0_send_buffered_recovers() raises:
    """`send_buffered` on a reaped keepalive connection must recover: dial a
    FRESH connection, replay the idempotent GET, return the 200.

    MEASURED PRODUCTION BEHAVIOUR: it does NOT. The cache-hit arm
    of `HttpClient._dispatch_pooled_buffered` drives the cached stream with NO
    try/except and NO redial, so the transport error propagates to the caller
    as `HttpError[RETRYABLE_TRANSPORT]: peer closed before any response byte`.

    The sibling `call_pooled` path recovers from the identical event, so
    whether a reaped connection is survivable depends on which method the
    caller happened to pick. Go recovers on every path because the retry lives
    in `persistConn.roundTrip`, below the entry points, not in one of them."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_1.status), 200, "op1 must succeed")
    assert_true(
        client.h1_idle_conn_is_cached(),
        "op1 must stash a keepalive conn",
    )

    # The server reaped it. `connect` will hand out this healthy stream if the
    # client does the conformant thing and re-dials.
    client._connector.arm(
        ScriptedStream.from_read_script(_keepalive_200())
    )

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k1"))^, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_false(
        raised,
        msg=(
            "a reaped keepalive conn must be recovered from, not surfaced;"
            " got: " + detail
        ),
    )
    assert_equal(status_2, 200, "op2 must return the fresh conn's 200")
    assert_equal(
        client._connector.connect_call_count(),
        2,
        "op1 dial + op2 stale-conn redial = 2 connects",
    )


def test_stale_reuse_eof_at_byte0_call_pooled_recovers() raises:
    """`call_pooled` on a reaped keepalive connection recovers — the ONE h1
    buffered entry point that does. Pins the behaviour so the recovery arm
    cannot be deleted silently.

    Falsifier check: deleting the `except` arm at
    `HttpClient._call_pooled_self_c` turns this RED (the raise escapes)."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
        _get_req(String("/k1"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    connector.arm(ScriptedStream.from_read_script(_keepalive_200()))

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
            _get_req(String("/k1"))^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_false(raised, msg="call_pooled must recover; got: " + detail)
    assert_equal(status_2, 200)
    assert_equal(connector.connect_call_count(), 2)


def test_stale_reuse_eof_at_byte0_streaming_pooled_get_recovers() raises:
    """`send_streaming_pooled_get` — the `_streaming_idle_pool` entry point —
    recovers from a reaped keepalive connection. Pins its retry arm."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var key = pool_key_for_origin(String("127.0.0.1"), UInt16(9000), True)

    var resp_1 = client.send_streaming_pooled_get[PerCoreAsyncRuntime[NoopSink]](
        _get_req(String("/k1"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    var tok_1 = CancellationToken.never()
    var body_1 = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](resp_1.body, reactor, tok_1)
    assert_equal(body_1.__len__(), 2)
    client.reclaim_streaming_stream[PerCoreAsyncRuntime[NoopSink]](resp_1^, key.copy())
    assert_equal(
        client.streaming_idle_pool_len(),
        1,
        "the drained keepalive stream must be pooled",
    )

    connector.arm(ScriptedStream.from_read_script(_keepalive_200()))

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.send_streaming_pooled_get[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k1"))^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
        var tok_2 = CancellationToken.never()
        var _b2 = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
            resp_2.body, reactor, tok_2,
        )
        _ = resp_2^
    except e:
        raised = True
        detail = String(e)

    assert_false(
        raised,
        msg="streaming pooled GET must recover; got: " + detail,
    )
    assert_equal(status_2, 200)
    assert_equal(connector.connect_call_count(), 2)


def test_send_streaming_does_not_consult_the_h1_idle_cache() raises:
    """STRUCTURAL FINDING, pinned as a test: `HttpClient.send` — the streaming
    default — consults NO pool. It routes straight to
    `_run_one_request_streaming`, which calls `connector.connect` on every
    invocation.

    So after `send_buffered` has stashed a warm keepalive connection for an
    origin, a `send` to THAT SAME origin dials a second socket and leaves the
    stashed one sitting idle. This is not a crash; it is the reason the h1
    reuse ratio a caller measures depends on which method it calls, and the
    reason a stale-connection policy fixed in one entry point does not reach
    the others."""
    var script = _concat(_keepalive_200(), _keepalive_200())
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())
    assert_equal(client._connector.connect_call_count(), 1)

    client._connector.arm(
        ScriptedStream.from_read_script(_keepalive_200())
    )
    var resp_2 = client.send[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_2.status), 200)
    var tok = CancellationToken.never()
    var _bs = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](resp_2.body, reactor, tok)
    _ = resp_2^

    assert_equal(
        client._connector.connect_call_count(),
        2,
        "send() dials even with a warm conn cached — it consults no pool",
    )
    assert_true(
        client.h1_idle_conn_is_cached(),
        "and the cached conn is still sitting there, untouched",
    )


# =============================================================================
# §2 — EOF **MID-RESPONSE**: THE HALF THAT MUST NOT BE REPLAYED.
# =============================================================================
#
# Go, verbatim (`transport.go`): once any response header data has been read,
# the request is not retried, because the server has already run it.
# `EOF_MID_RESPONSE: chunked body unterminated` is by
# construction a truncation AFTER a complete `200 OK` head.


def test_stale_reuse_eof_mid_chunked_response_is_not_replayed() raises:
    """A reused connection delivers a full `200 OK` head + `Transfer-Encoding:
    chunked` + one `5\\r\\nhello\\r\\n` chunk, then EOFs with no terminating
    `0\\r\\n\\r\\n`. THE SERVER RAN THE REQUEST. A POST must therefore surface
    the truncation, not replay.

    REQUIRED: raise carrying `chunked body unterminated`; EXACTLY ONE connect
    (no redial); the fresh connection's wire capture EMPTY; the poisoned conn
    not re-stashed.

    MEASURED PRODUCTION BEHAVIOUR: `_call_pooled_self_c` wraps the
    WHOLE drive — head read, body collect and all — in one bare
    `except e: _ = e`, so it cannot tell a byte-0 EOF from a truncation four
    frames into the body. It redials and REPLAYS THE POST, returning a
    cheerful 200 for a request the server has now executed twice. That is
    silent duplicate execution, and it is the failure mode the three-term rule
    exists to prevent."""
    var truncated = _b(String(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"
    ))
    var script = _concat(_keepalive_200(), truncated)
    var stream_1 = ScriptedStream.from_read_script(script^)
    stream_1.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _put_req(String("/seg"), String("xy"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    # The fresh-dial stream, with a SHARED capture that survives its drop. If
    # anything is written into it, the request was replayed.
    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
            _post_req(String("/seg"), String("xy"))^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "a truncation AFTER the response head must surface, not replay;"
            " instead the POST returned status " + String(status_2)
        ),
    )
    assert_true(
        "chunked body unterminated" in detail,
        msg="must be the specific chunked-unterminated error; got: " + detail,
    )
    assert_equal(
        connector.connect_call_count(),
        1,
        "no redial is permitted once response header data has arrived",
    )
    assert_equal(
        replay_capture[].__len__(),
        0,
        "the POST must reach the wire exactly once — the replay stream must"
        " have received ZERO bytes",
    )
    assert_false(
        client.h1_idle_conn_is_cached(),
        "a truncated connection must never be returned to the pool",
    )


def test_stale_reuse_eof_mid_content_length_response_is_not_replayed() raises:
    """The Content-Length twin of the case above: the reused connection sends
    `Content-Length: 10` and then only 3 body bytes before EOF.

    REQUIRED: a DISTINCT error (`short body — CL=10 got=3`, not the chunked
    one — a truncated framed body and a truncated chunked body are two
    different things to go look at); no redial; no re-stash.

    MEASURED: same defect as the chunked case — the bare `except` replays."""
    var short_body = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"
    ))
    var script = _concat(_keepalive_200(), short_body)
    var stream_1 = ScriptedStream.from_read_script(script^)
    stream_1.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _put_req(String("/seg"), String("xy"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
            _post_req(String("/seg"), String("xy"))^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "a short framed body must surface, not replay; got status "
            + String(status_2)
        ),
    )
    assert_true(
        "short body" in detail,
        msg="must be the CL-short-body error, distinct from the chunked one;"
        " got: " + detail,
    )
    assert_true(
        "CL=10" in detail and "got=3" in detail,
        msg="the error must carry the expected/received byte counts; got: "
        + detail,
    )
    assert_equal(connector.connect_call_count(), 1)
    assert_equal(
        replay_capture[].__len__(),
        0,
        "the POST must reach the wire exactly once",
    )
    assert_false(client.h1_idle_conn_is_cached())


# =============================================================================
# §3 — RST vs EOF: TWO CLOSES, TWO DISPOSITIONS.
# =============================================================================


def test_idle_conn_reset_is_distinguishable_from_idle_conn_eof() raises:
    """A pooled connection reaped with a TCP RST and one reaped with a FIN are
    the SAME event to a policy that only looks at "the read failed" — but they
    arrive through different syscall results, and a client that keys a retry
    policy on one silently mis-handles the other.

    Asserts BOTH errors are `RETRYABLE_TRANSPORT` (same disposition — the
    request got no verdict either way) AND that the two messages are
    distinguishable (an operator has to be able to tell a load balancer
    reaping connections from a server closing them politely).

    Uses `arm_error_at(<script length>, ...)` — the fault-at-an-OFFSET
    vocabulary the harness slice landed. Armed at the END of the script it says
    "deliver the whole first response, then RST where the FIN would have been",
    which is the only way to reach `_drive_read_head`'s STREAM_IO_ERROR branch
    from a client entry point: `arm_error` is one-shot and is consumed by the
    request WRITE that precedes every head read, so before the offset
    vocabulary existed the RST/EOF discriminator had no end-to-end
    falsifier."""
    # --- (a) FIN: the exhausted script EOFs. ---
    var fin_stream = ScriptedStream.from_read_script(_keepalive_200())
    var fin_conn = ScriptedConnector.with_stream(fin_stream^)
    var fin_client = HttpClient[ScriptedConnector].with_defaults(fin_conn^)
    var reactor = _make_reactor()
    var _r1 = fin_client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_true(fin_client.h1_idle_conn_is_cached())

    var fin_detail = String()
    var fin_raised = False
    try:
        var _r2 = fin_client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k1"))^, reactor,
        )
    except e:
        fin_raised = True
        fin_detail = String(e)

    # --- (b) RST: the exhausted script reports ECONNRESET instead. ---
    var rst_script = _keepalive_200()
    var rst_script_len = rst_script.__len__()
    var rst_stream = ScriptedStream.from_read_script(rst_script^)
    # An RST exactly where the FIN would have been: the whole first response is
    # delivered, and the NEXT read — the pooled second request's head read —
    # gets ECONNRESET instead of the clean Eof the FIN arm above gets.
    rst_stream.arm_error_at(rst_script_len, Int64(104))  # ECONNRESET
    var rst_conn = ScriptedConnector.with_stream(rst_stream^)
    var rst_client = HttpClient[ScriptedConnector].with_defaults(rst_conn^)
    var _r3 = rst_client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_true(rst_client.h1_idle_conn_is_cached())

    var rst_detail = String()
    var rst_raised = False
    try:
        var _r4 = rst_client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k1"))^, reactor,
        )
    except e:
        rst_raised = True
        rst_detail = String(e)

    assert_true(fin_raised, msg="the FIN case must raise")
    assert_true(rst_raised, msg="the RST case must raise")
    assert_true(
        "RETRYABLE_TRANSPORT" in fin_detail,
        msg="a FIN before any response byte is retryable; got: " + fin_detail,
    )
    assert_true(
        "RETRYABLE_TRANSPORT" in rst_detail,
        msg="an RST before any response byte is retryable too; got: "
        + rst_detail,
    )
    assert_true(
        "errno=104" in rst_detail,
        msg="the RST must carry its errno so an operator can tell the two"
        " apart; got: " + rst_detail,
    )
    assert_false(
        fin_detail == rst_detail,
        msg="a reset and a clean close must not produce the same message",
    )


# =============================================================================
# §4 — GO'S THREE-TERM RETRY RULE, AS A TABLE.
# =============================================================================


def test_row1_not_replay_safe_with_bytes_written_is_not_retried() raises:
    """ROW 1 — reused ✓, no header data ✓, nothing-written ✗, replay-safe ✗
    ⇒ NO RETRY.

    ⚠ "REPLAY-SAFE", NOT "IDEMPOTENT", AND THE DISTINCTION IS THE WHOLE TEST.
    **PUT IS IDEMPOTENT** — RFC 9110 §9.2.2 lists PUT and DELETE alongside the
    safe methods. What
    PUT is not is REPLAY-SAFE: §9.2.2 defines idempotency as a property of the
    *intended effect on the origin server*, i.e. a promise the RESOURCE makes
    and the CLIENT cannot verify, and the only obligation it places on a client
    is the NEGATIVE one ("a client SHOULD NOT automatically retry a request
    with a non-idempotent method"). It never obliges retrying an idempotent
    one. Go draws exactly that line in shipped code: `Request.isReplayable`
    admits GET/HEAD/OPTIONS/TRACE — the SAFE set — plus an explicit
    `Idempotency-Key`, and admits neither PUT nor DELETE.

    So a PUT whose bytes reached the wire on a reused connection that then
    closed is exactly Go's `!req.isReplayable()` arm: the server may have
    received and executed it, and no byte came back to say either way. Go
    returns the error. urllib3 the same (`Retry(method_whitelist=...)` excludes
    PUT/POST/PATCH by default).

    REQUIRED: the error surfaces; EXACTLY ONE connect; the replay stream's
    capture EMPTY — the PUT reached the wire exactly once.

    MEASURED PRODUCTION BEHAVIOUR WHEN THIS TEST WAS WRITTEN:
    `_call_pooled_self_c` retried unconditionally, so the PUT was replayed onto
    a fresh connection and a 200 returned. FIXED the same day by narrowing
    `_h1_method_is_replay_safe` (client.mojo) from urllib3's
    GET/HEAD/PUT/DELETE/OPTIONS to RFC 9110 §9.2.1's SAFE methods — Go's
    shipped `Request.isReplayable` set — plus an explicit per-request
    `Idempotency-Key` opt-in. No assertion in this test changed.

    ✅ THE COLLISION IS RETIRED. TWO tests pinned the
    OPPOSITE outcome for this exact event, and NEITHER was about replay safety
    — each merely drove its fixture with a PUT. Both were changed at the
    REQUEST, never at an assertion; every count they held the code to is
    byte-identical to what it was before:
      * `test_pooled_dead_keepalive_redials_cleanly`
        (test_http_client_call_pooled_keepalive.mojo) — subject: the POOL
        VALIDITY GUARD, on the broker/S3 write path, where a body-carrying PUT
        is the request that path actually issues. Its op 2 now STATES the
        licence it was silently depending on, the way
        `test_idempotency_key_licenses_a_put_replay` below does. A
        strengthening: the test names its premise.
      * `test_dead_keepalive_retry_arm_resolves_before_its_dial`
        (test_dial_resolve_is_lazy.mojo) — subject: LAZY DNS RESOLUTION, for
        which the verb is irrelevant. Driven with a GET, which exercises
        resolution identically and does not couple a DNS test to the
        idempotency opt-in."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _put_req(String("/obj"), String("xy"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
            _put_req(String("/obj"), String("xy"))^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "a non-idempotent PUT whose bytes reached the wire must NOT be"
            " replayed; it returned status " + String(status_2) + " instead"
        ),
    )
    assert_equal(
        connector.connect_call_count(),
        1,
        "row 1 permits no second dial",
    )
    assert_equal(
        replay_capture[].__len__(),
        0,
        "the PUT must have reached the wire exactly once",
    )
    _ = detail


def test_row2_nonidempotent_with_nothing_written_is_retried_once() raises:
    """ROW 2 — reused ✓, no header data ✓, nothing-written ✓ ⇒ RETRY IS SAFE
    even for a POST (Go: `NothingWrittenNoBody` / `NothingWrittenGetBody`,
    both `failureN: 0`). Nothing reached the wire, so nothing can have been
    executed twice.

    Driven with `arm_write_error_after(EPIPE, 1)`: the first request's single
    write pools the connection, the second request's write fails having
    captured ZERO bytes.

    REQUIRED and OBSERVED: exactly one redial, exactly one wire copy on the
    fresh connection, a 200 back.

    ⚠ This test passes for the WRONG REASON and that is the point of pairing
    it with row 1: the code retries unconditionally, so it happens to be right
    here and is wrong there. One `except` cannot be both."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    stream_1.arm_write_error_after(Int64(32), 1)  # EPIPE on the 2nd write
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _post_req(String("/obj"), String("xy"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var post_2 = _post_req(String("/obj"), String("xy"))
    var expected_wire = post_2.request_bytes.copy()

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
            post_2^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_false(
        raised,
        msg="nothing was written, so the POST is safely retryable; got: "
        + detail,
    )
    assert_equal(status_2, 200)
    assert_equal(
        connector.connect_call_count(), 2, "exactly one re-dial",
    )
    assert_true(
        _bytes_eq(replay_capture[], expected_wire),
        msg=(
            "exactly one byte-identical wire copy on the fresh conn; got "
            + String(replay_capture[].__len__())
            + " bytes vs " + String(expected_wire.__len__())
        ),
    )


def test_row3_idempotent_with_bytes_written_replays_body_byte_identically()\
        raises:
    """ROW 3 — reused ✓, no header data ✓, idempotent ✓ ⇒ RETRY, and the
    request must be replayed BYTE-IDENTICALLY (Go rewinds via `GetBody`;
    urllib3 re-serialises from the retained body).

    A GET carrying a payload is used deliberately: it exercises the rewind of
    a body that has already been drained once, which is where a client that
    replays from a consumed cursor silently sends a truncated second request."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var hdrs_1 = HeaderMap()
    var req_1 = build_request_with_body[BytesBody](
        HttpMethod.get(), _url(String("/obj")), hdrs_1^,
        BytesBody.from_bytes(_b(String("payload-0123456789"))),
    )
    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        req_1^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var hdrs_2 = HeaderMap()
    var req_2 = build_request_with_body[BytesBody](
        HttpMethod.get(), _url(String("/obj")), hdrs_2^,
        BytesBody.from_bytes(_b(String("payload-0123456789"))),
    )
    var expected_wire = req_2.request_bytes.copy()
    var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        req_2^, connector, reactor,
    )
    assert_equal(Int(resp_2.status), 200, "an idempotent GET is retried")
    assert_equal(connector.connect_call_count(), 2)
    assert_true(
        _bytes_eq(replay_capture[], expected_wire),
        msg=(
            "the replayed request must be byte-identical (body REWOUND, not"
            " replayed from a consumed cursor); got "
            + String(replay_capture[].__len__())
            + " bytes vs " + String(expected_wire.__len__())
        ),
    )


def test_row4_fresh_conn_eof_is_never_retried() raises:
    """ROW 4 — the anti-infinite-loop invariant. A FRESH connection (never
    reused) whose response EOFs is NEVER retried. Go, verbatim: "if we retried
    now, we could loop forever."

    REQUIRED and OBSERVED: exactly ONE connect call."""
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    assert_false(
        client.h1_idle_conn_is_cached(),
        "the premise: nothing is pooled, so this dial is FRESH",
    )

    var raised = False
    var detail = String()
    try:
        var _r = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
            _get_req(String("/k1"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(raised, msg="a fresh conn that EOFs must surface the error")
    assert_equal(
        connector.connect_call_count(),
        1,
        "a fresh-connection failure must not dial again — that is the loop",
    )
    _ = detail


def test_idempotency_key_licenses_a_put_replay() raises:
    """ROW 1's OPT-IN ARM — the caller's explicit, per-request replay licence.

    Row 1 establishes that a bare PUT whose bytes reached the wire is NOT
    replayed, because "PUT is idempotent" (RFC 9110 §9.2.2) is a promise the
    ORIGIN SERVER makes and the client cannot verify. `Idempotency-Key`
    (draft-ietf-httpapi-idempotency-key-header) is how the party that CAN
    verify it says so, and Go honours exactly this header for exactly this
    reason (`Request.isReplayable`, golang.org/issue/19943).

    Same event as row 1 — a reaped keepalive conn, bytes on the wire, EOF
    before the first response byte — and the opposite, CORRECT outcome: one
    re-dial, a 200, and a BYTE-IDENTICAL second copy on the fresh connection.

    ⚠ THIS IS ALSO THE NON-WEAKENING REMEDY for the two tests row 1 collides
    with (`test_pooled_dead_keepalive_redials_cleanly`,
    `test_dead_keepalive_retry_arm_resolves_before_its_dial`): a PUT that means
    to be replayable says so."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _put_req_with_header(
            String("/obj"), String("xy"),
            String("Idempotency-Key"), String("k-42"),
        )^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var req_2 = _put_req_with_header(
        String("/obj"), String("xy"),
        String("Idempotency-Key"), String("k-42"),
    )
    var expected_wire = req_2.request_bytes.copy()
    var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        req_2^, connector, reactor,
    )
    assert_equal(
        Int(resp_2.status),
        200,
        "a PUT carrying an Idempotency-Key IS replayable",
    )
    assert_equal(
        connector.connect_call_count(), 2, "exactly one re-dial",
    )
    assert_true(
        _bytes_eq(replay_capture[], expected_wire),
        msg=(
            "the licensed replay must be byte-identical (the key must reach"
            " the server on the SECOND attempt too, or it cannot dedupe); got "
            + String(replay_capture[].__len__())
            + " bytes vs " + String(expected_wire.__len__())
        ),
    )


def test_empty_idempotency_key_licenses_nothing() raises:
    """THE OPT-IN'S FAIL-CLOSED EDGE. `Idempotency-Key:` with an empty value
    identifies no operation, so no server could deduplicate on it even if it
    wanted to — and a proxy that strips a header's VALUE must not thereby hand
    a non-safe verb a replay licence. Presence is not the test; a non-empty
    value is.

    Same fixture as row 1, and the same required outcome: the error surfaces,
    EXACTLY ONE connect, the replay stream's capture EMPTY."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
        _put_req_with_header(
            String("/obj"), String("xy"),
            String("Idempotency-Key"), String(""),
        )^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var replay_capture = ArcPointer[List[UInt8]](List[UInt8]())
    connector.arm(
        ScriptedStream.from_read_script_with_capture(
            _keepalive_200(), replay_capture,
        )
    )

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody](
            _put_req_with_header(
                String("/obj"), String("xy"),
                String("Idempotency-Key"), String(""),
            )^, connector, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "an EMPTY Idempotency-Key licenses nothing; the PUT returned"
            " status " + String(status_2) + " instead"
        ),
    )
    assert_equal(
        connector.connect_call_count(), 1, "an empty key permits no re-dial",
    )
    assert_equal(
        replay_capture[].__len__(),
        0,
        "the PUT must have reached the wire exactly once",
    )
    _ = detail


def test_stale_reuse_retry_is_at_most_once() raises:
    """The retry budget is ONE. Both the reused connection AND the fresh dial
    EOF; the result must be exactly 2 connects and a typed error — not a third
    dial and not a loop."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
        _get_req(String("/k1"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    # The fresh dial is dead too.
    connector.arm(ScriptedStream.empty())

    var raised = False
    var detail = String()
    try:
        var _r2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
            _get_req(String("/k1"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(raised, msg="a dead redial must surface, not loop")
    assert_true(
        "HttpError[" in detail,
        msg="the escaping error must be typed; got: " + detail,
    )
    assert_equal(
        connector.connect_call_count(),
        2,
        "at most one retry: 1 reuse attempt + 1 redial, never a third",
    )


# =============================================================================
# §5 — THE DIRTY-EXIT DISCARD TABLE (urllib3 connectionpool.py).
# =============================================================================


def _send_buffered_on_poisoned_pooled_conn(
    var poison: List[UInt8],
) raises -> Bool:
    """op1 pools a keepalive conn; op2 reuses it and meets `poison`. Returns
    `h1_idle_conn_is_cached()` afterwards — which must be False for every
    dirty exit."""
    var script = _concat(_keepalive_200(), poison^)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var _r1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    if not client.h1_idle_conn_is_cached():
        raise Error("fixture bug: op1 failed to pool a keepalive conn")
    try:
        var _r2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    except e:
        _ = e
    return client.h1_idle_conn_is_cached()


def test_every_dirty_exit_discards_the_pooled_conn() raises:
    """urllib3's discard table, one row per failure class. A connection that
    left a request on ANY dirty exit must NOT be returned to the pool — a
    pooled connection carrying unread bytes or an unfinished frame is how a
    response gets handed to the WRONG request.

    Rows: transport EOF at byte 0; chunked truncation; a malformed chunk-size
    line (decode error, distinct from truncation); a short framed body."""
    assert_false(
        _send_buffered_on_poisoned_pooled_conn(List[UInt8]()),
        msg="row: transport EOF at byte 0",
    )
    assert_false(
        _send_buffered_on_poisoned_pooled_conn(
            _b(String(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                "5\r\nhello\r\n"
            ))
        ),
        msg="row: chunked truncation",
    )
    assert_false(
        _send_buffered_on_poisoned_pooled_conn(
            _b(String(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                "ZZZZ\r\nhello\r\n"
            ))
        ),
        msg="row: malformed chunk-size line (decode error)",
    )
    assert_false(
        _send_buffered_on_poisoned_pooled_conn(
            _b(String("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
        ),
        msg="row: short framed body",
    )


# =============================================================================
# §6 — CONNECTION-CLOSE ELIGIBILITY.
# =============================================================================


def _head(s: String) raises -> ResponseHead:
    var bs = _b(s)
    return parse_response_head(Span[UInt8](bs), ResponseParseLimits.defaults())


def test_connection_close_eligibility_table() raises:
    """Token matching on `Connection` is case-insensitive, list-aware, and
    close-wins across duplicates; HTTP/1.0 defaults to close unless keep-alive
    is asked for. Every row is a direction a pooling bug hides in."""
    var mixed = _head(String(
        "HTTP/1.1 200 OK\r\nConnection: Close\r\nContent-Length: 0\r\n\r\n"
    ))
    assert_true(mixed.is_ok())
    assert_true(
        mixed.connection_close,
        "`Connection: Close` (mixed case) must close",
    )

    var shouty = _head(String(
        "HTTP/1.1 200 OK\r\ncOnNeCtIoN: cLoSe\r\nContent-Length: 0\r\n\r\n"
    ))
    assert_true(shouty.connection_close, "header NAME is case-insensitive too")

    var in_list = _head(String(
        "HTTP/1.1 200 OK\r\nConnection: keep-alive, close\r\n"
        "Content-Length: 0\r\n\r\n"
    ))
    assert_true(
        in_list.connection_close,
        "`close` as a token inside a list must close",
    )

    var dupes = _head(String(
        "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nConnection: close\r\n"
        "Content-Length: 0\r\n\r\n"
    ))
    assert_true(
        dupes.connection_close,
        "duplicate Connection headers: close WINS over an earlier keep-alive",
    )

    var h10_bare = _head(String(
        "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"
    ))
    assert_true(
        h10_bare.connection_close,
        "HTTP/1.0 without keep-alive is close-by-default",
    )

    var h10_ka = _head(String(
        "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"
    ))
    assert_false(
        h10_ka.connection_close,
        "HTTP/1.0 WITH keep-alive is poolable",
    )

    var h11_bare = _head(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    ))
    assert_false(
        h11_bare.connection_close,
        "HTTP/1.1 defaults to keepalive",
    )

    # `Proxy-Connection` is a Netscape-era hop-by-hop kludge. Go's
    # `net/http` ignores it entirely; CPython's `http.client._check_close`
    # consults it ONLY for HTTP/1.0 and ONLY in the keep-alive direction. On
    # HTTP/1.1 neither reference treats it as close, and RFC 7230 §A.1.2 says
    # so explicitly. PINNED IN THAT DIRECTION so a future "fix" cannot break
    # 1.1 pooling behind a proxy by making a stray token close the conn.
    var proxy_close = _head(String(
        "HTTP/1.1 200 OK\r\nProxy-Connection: Close, foo\r\n"
        "Content-Length: 0\r\n\r\n"
    ))
    assert_false(
        proxy_close.connection_close,
        "Proxy-Connection must not be consulted on HTTP/1.1 (Go, CPython,"
        " RFC 7230 A.1.2 all agree)",
    )


def test_connection_close_response_is_not_pooled_end_to_end() raises:
    """The parser-level table above, taken all the way through the client: a
    mixed-case `Connection: Close` response leaves NOTHING in the idle cache
    and the next request dials."""
    var stream_1 = ScriptedStream.from_read_script(_b(String(
        "HTTP/1.1 200 OK\r\nConnection: Close\r\nContent-Length: 2\r\n\r\nOK"
    )))
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(
        resp_1.connection_close,
        "the response must report connection_close",
    )
    assert_false(
        client.h1_idle_conn_is_cached(),
        "`Connection: Close` must not be pooled",
    )

    client._connector.arm(
        ScriptedStream.from_read_script(_keepalive_200())
    )
    var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k2"))^, reactor)
    assert_equal(Int(resp_2.status), 200)
    assert_equal(
        client._connector.connect_call_count(),
        2,
        "the next request must dial fresh",
    )


# =============================================================================
# §7 — UNSOLICITED BYTES ON AN IDLE CONNECTION.
# =============================================================================


def test_unsolicited_408_on_idle_conn_must_not_become_the_next_response()\
        raises:
    """Go issue 32310. A server that times out an idle keepalive connection
    commonly writes `408 Request Timeout` and closes. A client that does not
    read its idle connections hands that 408 to the NEXT request as if it were
    that request's answer.

    REQUIRED: the 408 evicts the connection; the next request dials fresh and
    receives the fresh server's 200. (Go reads idle connections precisely so
    it can see this and close; urllib3 re-checks `is_connection_dropped`.)

    MEASURED PRODUCTION BEHAVIOUR: there is no idle read and no
    liveness check anywhere on the h1 path, so op2 reuses the connection,
    parses the stale 408 as ITS OWN response head, and returns status 408 for
    a request the server never saw. That is a RESPONSE MIX-UP, not a status
    code — and with one more queued response on the wire it becomes request N
    receiving request N-1's body."""
    var stale_408 = _b(String(
        "HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n"
        "Content-Length: 0\r\n\r\n"
    ))
    var script = _concat(_keepalive_200(), stale_408^)
    var stream_1 = ScriptedStream.from_read_script(script^)
    stream_1.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    # The conformant path dials; this is what it would get.
    client._connector.arm(ScriptedStream.from_read_script(_b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nFRESH"
    ))))

    var raised = False
    var detail = String()
    var status_2 = 0
    var body_2 = String()
    try:
        var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k2"))^, reactor,
        )
        status_2 = Int(resp_2.status)
        body_2 = _str_of(resp_2.body.take_bytes())
    except e:
        raised = True
        detail = String(e)

    assert_false(raised, msg="op2 must succeed on a fresh conn; got: " + detail)
    assert_equal(
        status_2,
        200,
        "a stale 408 left on an idle conn must NEVER be delivered as the next"
        " request's response",
    )
    assert_equal(body_2, String("FRESH"), "op2 must read the FRESH server")
    assert_equal(
        client._connector.connect_call_count(),
        2,
        "the 408 must have evicted the idle conn, forcing a fresh dial",
    )


def test_garbage_on_idle_conn_is_never_parsed_as_a_response() raises:
    """The safety floor under the case above: whatever an idle connection has
    left on it, it must never be turned into a plausible-looking response.
    Arbitrary non-HTTP bytes must surface as a framing error and the
    connection must be discarded."""
    var garbage = _b(String("NOT-HTTP-AT-ALL \x01\x02\r\n\r\n"))
    var script = _concat(_keepalive_200(), garbage^)
    var stream_1 = ScriptedStream.from_read_script(script^)
    stream_1.set_max_read_per_call(_KEEPALIVE_200_LEN)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](_get_req(String("/k1"))^, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached())

    var raised = False
    var detail = String()
    var status_2 = 0
    try:
        var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            _get_req(String("/k2"))^, reactor,
        )
        status_2 = Int(resp_2.status)
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "garbage on an idle conn must never parse as a response; it"
            " returned status " + String(status_2)
        ),
    )
    assert_true(
        "HttpError[" in detail,
        msg="it must be a typed framing error; got: " + detail,
    )
    assert_false(
        client.h1_idle_conn_is_cached(),
        "and the conn must be discarded",
    )


# =============================================================================
# §8 — OBSERVABILITY: A TRANSPARENT RETRY THAT NOTHING COUNTS.
# =============================================================================


def test_call_pooled_dials_are_counted() raises:
    """A stale-connection retry is invisible unless something counts it.
    Every production pool exposes it — Go's `httptrace`
    `GotConn.Reused`/`WasIdle`, urllib3's `Retry.history`, hyper's pool
    metrics — precisely so "the pool is churning" can be seen before it
    becomes "the service is unavailable".

    This client's ONLY dial counter is `h1_pool_dials_total()`.

    MEASURED PRODUCTION BEHAVIOUR: `_call_pooled_self_c` calls
    `connector.connect` directly and NEVER calls `PerCorePool.insert_dialed`,
    so `h1_pool_dials_total()` stays 0 for the entire `call_pooled` path —
    the fresh dial is not counted, and neither is the stale-conn redial. A
    connection storm on the broker/S3 write path and a perfectly warm pool
    produce the identical counter reading: zero."""
    var stream_1 = ScriptedStream.from_read_script(_keepalive_200())
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()

    var resp_1 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
        _get_req(String("/k1"))^, connector, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_equal(
        connector.connect_call_count(), 1, "the fixture did dial once",
    )
    assert_equal(
        client.h1_pool_dials_total(),
        1,
        "a dial performed by call_pooled must be counted by the client's only"
        " dial counter",
    )

    connector.arm(ScriptedStream.from_read_script(_keepalive_200()))
    var resp_2 = client.call_pooled[PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody](
        _get_req(String("/k1"))^, connector, reactor,
    )
    assert_equal(Int(resp_2.status), 200)
    assert_equal(
        connector.connect_call_count(), 2, "the stale conn forced a redial",
    )
    assert_equal(
        client.h1_pool_dials_total(),
        2,
        "a stale-connection redial must be countable — otherwise a churning"
        " pool reads exactly like a healthy one",
    )


def main() raises:
    """Runs EVERY case and reports each verdict before failing, rather than
    aborting on the first red. The cases are independent conformance
    assertions against Go/urllib3 behaviour; knowing HOW MANY of the 20 are
    red, and WHICH, is the deliverable — a run that stops at the first one
    hides the rest."""
    var failures = List[String]()

    try:
        test_stale_reuse_eof_at_byte0_send_buffered_recovers()
        print("  PASS  stale_reuse_eof_at_byte0_send_buffered_recovers")
    except e:
        failures.append(
            String("stale_reuse_eof_at_byte0_send_buffered_recovers: ")
            + String(e)
        )
        print("  FAIL  stale_reuse_eof_at_byte0_send_buffered_recovers")
        print("        " + String(e))

    try:
        test_stale_reuse_eof_at_byte0_call_pooled_recovers()
        print("  PASS  stale_reuse_eof_at_byte0_call_pooled_recovers")
    except e:
        failures.append(
            String("stale_reuse_eof_at_byte0_call_pooled_recovers: ")
            + String(e)
        )
        print("  FAIL  stale_reuse_eof_at_byte0_call_pooled_recovers")
        print("        " + String(e))

    try:
        test_stale_reuse_eof_at_byte0_streaming_pooled_get_recovers()
        print("  PASS  stale_reuse_eof_at_byte0_streaming_pooled_get_recovers")
    except e:
        failures.append(
            String("stale_reuse_eof_at_byte0_streaming_pooled_get_recovers: ")
            + String(e)
        )
        print("  FAIL  stale_reuse_eof_at_byte0_streaming_pooled_get_recovers")
        print("        " + String(e))

    try:
        test_send_streaming_does_not_consult_the_h1_idle_cache()
        print("  PASS  send_streaming_does_not_consult_the_h1_idle_cache")
    except e:
        failures.append(
            String("send_streaming_does_not_consult_the_h1_idle_cache: ")
            + String(e)
        )
        print("  FAIL  send_streaming_does_not_consult_the_h1_idle_cache")
        print("        " + String(e))

    try:
        test_stale_reuse_eof_mid_chunked_response_is_not_replayed()
        print("  PASS  stale_reuse_eof_mid_chunked_response_is_not_replayed")
    except e:
        failures.append(
            String("stale_reuse_eof_mid_chunked_response_is_not_replayed: ")
            + String(e)
        )
        print("  FAIL  stale_reuse_eof_mid_chunked_response_is_not_replayed")
        print("        " + String(e))

    try:
        test_stale_reuse_eof_mid_content_length_response_is_not_replayed()
        print(
            "  PASS "
            " stale_reuse_eof_mid_content_length_response_is_not_replayed"
        )
    except e:
        failures.append(
            String(
                "stale_reuse_eof_mid_content_length_response_is_not_replayed: "
            )
            + String(e)
        )
        print(
            "  FAIL "
            " stale_reuse_eof_mid_content_length_response_is_not_replayed"
        )
        print("        " + String(e))

    try:
        test_idle_conn_reset_is_distinguishable_from_idle_conn_eof()
        print("  PASS  idle_conn_reset_is_distinguishable_from_idle_conn_eof")
    except e:
        failures.append(
            String("idle_conn_reset_is_distinguishable_from_idle_conn_eof: ")
            + String(e)
        )
        print("  FAIL  idle_conn_reset_is_distinguishable_from_idle_conn_eof")
        print("        " + String(e))

    try:
        test_row1_not_replay_safe_with_bytes_written_is_not_retried()
        print("  PASS  row1_not_replay_safe_with_bytes_written_is_not_retried")
    except e:
        failures.append(
            String("row1_not_replay_safe_with_bytes_written_is_not_retried: ")
            + String(e)
        )
        print("  FAIL  row1_not_replay_safe_with_bytes_written_is_not_retried")
        print("        " + String(e))

    try:
        test_row2_nonidempotent_with_nothing_written_is_retried_once()
        print("  PASS  row2_nonidempotent_with_nothing_written_is_retried_once")
    except e:
        failures.append(
            String("row2_nonidempotent_with_nothing_written_is_retried_once: ")
            + String(e)
        )
        print("  FAIL  row2_nonidempotent_with_nothing_written_is_retried_once")
        print("        " + String(e))

    try:
        test_row3_idempotent_with_bytes_written_replays_body_byte_identically()
        print("  PASS  row3_idempotent_replays_body_byte_identically")
    except e:
        failures.append(
            String("row3_idempotent_replays_body_byte_identically: ")
            + String(e)
        )
        print("  FAIL  row3_idempotent_replays_body_byte_identically")
        print("        " + String(e))

    try:
        test_row4_fresh_conn_eof_is_never_retried()
        print("  PASS  row4_fresh_conn_eof_is_never_retried")
    except e:
        failures.append(
            String("row4_fresh_conn_eof_is_never_retried: ") + String(e)
        )
        print("  FAIL  row4_fresh_conn_eof_is_never_retried")
        print("        " + String(e))

    try:
        test_idempotency_key_licenses_a_put_replay()
        print("  PASS  idempotency_key_licenses_a_put_replay")
    except e:
        failures.append(
            String("idempotency_key_licenses_a_put_replay: ") + String(e)
        )
        print("  FAIL  idempotency_key_licenses_a_put_replay")
        print("        " + String(e))

    try:
        test_empty_idempotency_key_licenses_nothing()
        print("  PASS  empty_idempotency_key_licenses_nothing")
    except e:
        failures.append(
            String("empty_idempotency_key_licenses_nothing: ") + String(e)
        )
        print("  FAIL  empty_idempotency_key_licenses_nothing")
        print("        " + String(e))

    try:
        test_stale_reuse_retry_is_at_most_once()
        print("  PASS  stale_reuse_retry_is_at_most_once")
    except e:
        failures.append(
            String("stale_reuse_retry_is_at_most_once: ") + String(e)
        )
        print("  FAIL  stale_reuse_retry_is_at_most_once")
        print("        " + String(e))

    try:
        test_every_dirty_exit_discards_the_pooled_conn()
        print("  PASS  every_dirty_exit_discards_the_pooled_conn")
    except e:
        failures.append(
            String("every_dirty_exit_discards_the_pooled_conn: ") + String(e)
        )
        print("  FAIL  every_dirty_exit_discards_the_pooled_conn")
        print("        " + String(e))

    try:
        test_connection_close_eligibility_table()
        print("  PASS  connection_close_eligibility_table")
    except e:
        failures.append(
            String("connection_close_eligibility_table: ") + String(e)
        )
        print("  FAIL  connection_close_eligibility_table")
        print("        " + String(e))

    try:
        test_connection_close_response_is_not_pooled_end_to_end()
        print("  PASS  connection_close_response_is_not_pooled_end_to_end")
    except e:
        failures.append(
            String("connection_close_response_is_not_pooled_end_to_end: ")
            + String(e)
        )
        print("  FAIL  connection_close_response_is_not_pooled_end_to_end")
        print("        " + String(e))

    try:
        test_unsolicited_408_on_idle_conn_must_not_become_the_next_response()
        print("  PASS  unsolicited_408_must_not_become_the_next_response")
    except e:
        failures.append(
            String("unsolicited_408_must_not_become_the_next_response: ")
            + String(e)
        )
        print("  FAIL  unsolicited_408_must_not_become_the_next_response")
        print("        " + String(e))

    try:
        test_garbage_on_idle_conn_is_never_parsed_as_a_response()
        print("  PASS  garbage_on_idle_conn_is_never_parsed_as_a_response")
    except e:
        failures.append(
            String("garbage_on_idle_conn_is_never_parsed_as_a_response: ")
            + String(e)
        )
        print("  FAIL  garbage_on_idle_conn_is_never_parsed_as_a_response")
        print("        " + String(e))

    try:
        test_call_pooled_dials_are_counted()
        print("  PASS  call_pooled_dials_are_counted")
    except e:
        failures.append(
            String("call_pooled_dials_are_counted: ") + String(e)
        )
        print("  FAIL  call_pooled_dials_are_counted")
        print("        " + String(e))

    if failures.__len__() > 0:
        var summary = String(
            "test_h1_pool_stale_conn_retry_safety: "
        ) + String(failures.__len__()) + String(" of 20 cases RED\n")
        var i = 0
        while i < failures.__len__():
            summary += String("  - ") + failures[i] + String("\n")
            i = i + 1
        raise Error(summary)
    print("[OK] test_h1_pool_stale_conn_retry_safety — all 20 tests passed")
