# =============================================================================
# test_dial_resolve_is_lazy.mojo — a POOLED-REUSE HIT PERFORMS NO RESOLVE.
# =============================================================================
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
# Seven pooled entry points on `HttpClient` resolved the dial address at the
# TOP of the method — strictly BEFORE the connection-pool probe:
#
#     var ip_be = _ip_be_from_host(host_str, port)   # <- getaddrinfo
#     ...
#     var outcome = pool[].try_checkout_or_pending(key)   # <- may need NO dial
#
# So a request that reused a warm h2/h1 connection and dialled NOTHING still
# performed a blocking `getaddrinfo(3)` — the ONLY unbounded blocking libc call
# in this tree (`komira_net/dns.mojo:382`; it takes no timeout argument
# and cannot be cancelled). On a serve loop that talks to Firestore and GCS on
# every tick that is one unbounded phase per request, forever, for nothing.
#
# ⛔ IT IS NOT A MOVE. `ip_be` is consumed by the dial-fresh RETRY arm inside
# the pooled path's `except` (the closed-keepalive race), so relocating the one
# statement below the probe leaves that arm naming a value the path that needs
# it never computed. The resolve became LAZY AT EVERY DIAL POINT instead —
# including the retry arms.
#
# ── WHY THIS FILE EXISTS: THE PROPERTY HAD NO OBSERVABLE ────────────────────
# ⛔ "THE POOLED PATH RETURNED QUICKLY" IS NOT A TEST OF THIS. It passes on the
# BROKEN code whenever DNS happens to be fast, which is almost always — and it
# is exactly the reasoning that let the defect live. The honest observable is a
# COUNT, so `HttpClient` now carries one: `dial_resolve_steps_total()`, bumped
# by `_resolve_dial_ip_be`, the single method every dial site resolves through.
#
# ⚠ IT COUNTS ENTRIES INTO THE RESOLVE STEP, NOT `getaddrinfo` CALLS — and that
# is what makes the property HERMETIC. The two differ by the IP-literal fast
# path inside `_ip_be_from_host`: for a DNS name one entry IS one getaddrinfo,
# for `127.0.0.1` it is a parse. The quantity laziness changes is the ENTRY
# COUNT, and asserting it needs no nameserver. (A counter that fired only on
# the DNS branch would be unassertable without a live resolver — the same
# unobservability that produced the bug.)
#
# ⭐ EVERY BEHAVIOURAL GATE ASSERTS A FLOOR AS WELL AS A CEILING, by pairing
# the resolve count with `connect_call_count()`. A change that broke dialling
# outright would ALSO show zero resolves on the reuse path; pinning
# `connect_call_count()` in the same assertion excludes that reading.
#
# ── THE TWO HALVES ──────────────────────────────────────────────────────────
# Gates 1-6 DRIVE the client over a ScriptedConnector: `send_buffered`
# (h1 pool), `call_pooled` (the h1 idle-conn cache, incl. its retry arm) and
# `send_grpc_pooled` (the h2 multiplex pool).
# Gates 7-9 READ `client.mojo` — because four of the seven converted methods
# (the streaming/objectstore and h2-batch paths) cannot be driven from here,
# and "every resolve sits immediately before a dial" is a property of the
# SOURCE that holds for all of them at once. Same technique, and same stated
# reason, as `test_slow_dial_phase_breadcrumb.mojo` gates 5-7.
#
# ⚠ AND THE READER READS CODE, NOT PROSE — this very header names
# `_resolve_dial_ip_be` several times. Comments are cut at the first `#` and
# `"""`-delimited docstrings contribute nothing; gate 9 pins that with a
# sentinel whose only whole occurrence is in a comment.
#
# HERMETIC: a scripted byte transport plus one text read of a
# checked-in file declared as test data. No socket, no resolver, no cloud.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.body import BytesBody, EmptyBody
from komira_http.client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import method_post
from komira_http.client.url import Url
from komira_http.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.codec.types import HttpMethod
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


comptime _CLIENT_SRC: String = "src/komira_http/client/client.mojo"
comptime _SELF_SRC: String = (
    "src/komira_http/tests/test_dial_resolve_is_lazy.mojo"
)

comptime _RESOLVE: String = "self._resolve_dial_ip_be("
"""The ONE counted entry into the dial-address resolve step.

⚠ THE `self.` IS LOAD-BEARING — it is what makes this the CALL spelling and not
the DECLARATION. Without it the token also matches `def _resolve_dial_ip_be(`,
and the site count comes back one higher than the dial count for a reason that
has nothing to do with the code being measured."""

comptime _RAW_RESOLVE: String = "_ip_be_from_host("
"""The UNCOUNTED free function. Legitimate in the three free-function dial
helpers (which consult no pool and dial unconditionally) and in exactly one
place inside the struct — the body of `_resolve_dial_ip_be`, which is what the
counter wraps. Anywhere ELSE inside `struct HttpClient` it is a resolve the
counter cannot see, i.e. a hole in every gate below."""

comptime _DIAL: String = "connect[RT]("
"""The dial itself — `Connector.connect`, whose `ip_be` parameter is the
already-resolved address this file is about."""

comptime _STRUCT_HEAD: String = "struct HttpClient[C: Connector]"

comptime _SINGLE_RESPONSE_BYTES: Int = 40
"""One canned "HTTP/1.1 200 OK / Content-Length: 2 / OK" response.
Status line (15) + CRLF (2) + "Content-Length: 2" (17) + CRLF (2) + CRLF (2)
+ body (2) = 40. The ScriptedStream must be capped at this per read or the
first request's greedy read swallows the whole script (see
`test_http_client_h1_keepalive_reuse.mojo` for the full statement)."""

def _converted_methods() -> List[String]:
    """The methods that resolve a dial address. NAMED, not counted: a rename or
    a deletion should RED the gate below and be re-stated deliberately, where a
    bare total would silently absorb it.

    ⚠ `send_grpc_pooled_h2c` was ALREADY lazy before this change — its resolve
    sat in the NEEDS_DIAL arm. It is listed because it is the in-file precedent
    the other seven were converted TO, and because it must not regress.

    (A free function rather than a `comptime` list: Mojo 1.0.0b2 refuses to
    materialize a comptime `List[String]` to runtime — it is not
    `ImplicitlyCopyable`.)"""
    var out = List[String]()
    out.append(String("_call_pooled_self_c"))
    out.append(String("send_grpc_pooled"))
    out.append(String("send_grpc_pooled_h2c"))
    out.append(String("send_streaming_pooled_get"))
    out.append(String("issue_streaming_get_nonblocking"))
    out.append(String("issue_streaming_put_nonblocking"))
    out.append(String("_dispatch_pooled_buffered"))
    out.append(String("send_buffered_batch"))
    return out^


# =============================================================================
# Harness
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


def _script_n_keepalive_responses(n: Int) -> List[UInt8]:
    """N back-to-back HTTP/1.1 200 OK responses, no Connection header (the
    HTTP/1.1 default is keepalive ⇒ connection_close=False ⇒ the stream is
    stashed for reuse)."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var part = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
        var j = 0
        var m = part.__len__()
        while j < m:
            out.append(part[j])
            j = j + 1
        i = i + 1
    return out^


# =============================================================================
# Gate 1 ★★ — THE HEADLINE. Ten pooled `send_buffered` sends, ONE resolve.
# =============================================================================
def test_h1_pooled_reuse_resolves_once_for_ten_sends() raises:
    print("-- test_h1_pooled_reuse_resolves_once_for_ten_sends --")
    var script = _script_n_keepalive_responses(10)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var i = 0
    while i < 10:
        var url = Url.parse(String("http://127.0.0.1:8080/health"))
        var hdrs = HeaderMap()
        var req = build_get_request(url^, hdrs^)
        var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
        assert_equal(Int(resp.status), 200, String("request ") + String(i))
        i = i + 1

    # THE FLOOR — one dial happened. Without this, the ceiling below is also
    # satisfied by a client that stopped dialling altogether.
    assert_equal(
        client._connector.connect_call_count(),
        1,
        (
            "the h1 keepalive pool stopped reusing: 10 sends must dial ONCE."
            " Read this before the resolve assertion below — zero resolves on"
            " a path that also stopped dialling is not the property under"
            " test."
        ),
    )
    # THE CEILING — the nine reuse hits resolved NOTHING.
    assert_equal(
        client.dial_resolve_steps_total(),
        1,
        (
            "a pooled-reuse hit entered the dial-address resolve step. On a"
            " DNS-name authority every one of those entries is a blocking,"
            " uncancellable `getaddrinfo` on the calling thread — paid by a"
            " request that reuses a warm connection and dials nothing. 10"
            " sends must cost exactly the 1 resolve their single dial needed."
        ),
    )
    print("    [OK] 10 sends -> 1 dial, 1 resolve")


# =============================================================================
# Gate 2 ★ — THE FLOOR ON ITS OWN. A COLD dial resolves EXACTLY ONCE.
# =============================================================================
def test_cold_dial_resolves_exactly_once() raises:
    """Laziness must not become absence. This is the gate a "fix" that simply
    deleted the resolve would fail — it would report 0, and every reuse
    assertion in this file would still pass."""
    print("-- test_cold_dial_resolves_exactly_once --")
    var script = _script_n_keepalive_responses(1)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    assert_equal(
        client.dial_resolve_steps_total(),
        0,
        "a client that has sent nothing must have resolved nothing.",
    )

    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(
        client._connector.connect_call_count(), 1, "the cold send must dial",
    )
    assert_equal(
        client.dial_resolve_steps_total(),
        1,
        (
            "the COLD dial did not resolve. A dial needs an address; a dial"
            " site that no longer reaches the resolve step is reading a stale"
            " or zero `ip_be`."
        ),
    )
    print("    [OK] cold dial -> exactly 1 resolve")


# =============================================================================
# Gate 3 ★ — RESOLVES TRACK DIALS, NOT REQUESTS.
# =============================================================================
def test_resolves_track_dials_not_requests() raises:
    """`Connection: close` drops the cached conn, so request #2 must dial
    fresh — and therefore resolve again. The invariant this pins is the
    1:1 one: one resolve per DIAL, never one per REQUEST."""
    print("-- test_resolves_track_dials_not_requests --")
    var script_1 = _b(String(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream_1 = ScriptedStream.from_read_script(script_1^)
    var connector = ScriptedConnector.with_stream(stream_1^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()

    var url_1 = Url.parse(String("http://127.0.0.1:8080/x"))
    var hdrs_1 = HeaderMap()
    var req_1 = build_get_request(url_1^, hdrs_1^)
    var resp_1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_1^, reactor,
    )
    assert_equal(Int(resp_1.status), 200)
    assert_equal(client.dial_resolve_steps_total(), 1)

    var script_2 = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    var stream_2 = ScriptedStream.from_read_script(script_2^)
    client._connector.arm(stream_2^)

    var url_2 = Url.parse(String("http://127.0.0.1:8080/y"))
    var hdrs_2 = HeaderMap()
    var req_2 = build_get_request(url_2^, hdrs_2^)
    var resp_2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req_2^, reactor,
    )
    assert_equal(Int(resp_2.status), 200)
    assert_equal(
        client._connector.connect_call_count(), 2,
        "Connection: close on #1 forces a fresh dial on #2",
    )
    assert_equal(
        client.dial_resolve_steps_total(),
        2,
        (
            "the SECOND dial reused the first dial's address instead of"
            " resolving. Laziness memoises NOTHING across calls — a cached"
            " address is a DNS cache, which is a separate decision with its"
            " own staleness failure mode and is deliberately not taken here."
        ),
    )
    print("    [OK] 2 requests, 2 dials, 2 resolves")


# =============================================================================
# Gate 4 ★★ — `call_pooled` (the h1 idle-conn cache): 10 ops, ONE resolve.
# =============================================================================
def test_call_pooled_reuse_resolves_once_for_ten_ops() raises:
    print("-- test_call_pooled_reuse_resolves_once_for_ten_ops --")
    var script = _script_n_keepalive_responses(10)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(_SINGLE_RESPONSE_BYTES)
    var connector = ScriptedConnector.with_stream(stream^)
    # `call_pooled` threads its OWN per-call connector; the client's own one is
    # unused on that path (the broker / S3 write shape).
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    var i = 0
    while i < 10:
        var url = Url.parse(String("http://127.0.0.1:9000/bucket/k"))
        var hdrs = HeaderMap()
        var body = BytesBody.from_bytes(_b(String("xy")))
        var req = build_request_with_body[BytesBody](
            HttpMethod.put(), url^, hdrs^, body^,
        )
        var resp = client.call_pooled[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, BytesBody
        ](req^, connector, reactor)
        assert_equal(Int(resp.status), 200, String("op ") + String(i))
        i = i + 1

    assert_equal(
        connector.connect_call_count(), 1,
        "call_pooled keepalive regressed: 10 ops must dial ONCE.",
    )
    assert_equal(
        client.dial_resolve_steps_total(),
        1,
        (
            "`_call_pooled_self_c` resolved on a reuse hit. This is the"
            " broker/S3 write path: a single append does several same-origin"
            " ops on one connector, and each was paying a resolve."
        ),
    )
    print("    [OK] 10 call_pooled ops -> 1 dial, 1 resolve")


# =============================================================================
# Gate 5 ★★ — THE RETRY ARM. A dead keepalive conn re-dials AND re-resolves.
# =============================================================================
def test_dead_keepalive_retry_arm_resolves_before_its_dial() raises:
    """The arm that makes this change a laziness rather than a move: op 2 finds
    a cached conn (so it must NOT resolve up front), the head-read fails on it,
    and the `except` arm dials FRESH — which needs an address of its own.

    If the retry arm's resolve were dropped (the tempting "move it below the
    probe" edit), the count stays at 1 while a real dial happens — so this gate
    reds on exactly that mistake.

    ⚠ DRIVEN WITH A **GET**, AND THE VERB IS NOT INCIDENTAL. This gate is about
    DNS resolution, which a GET exercises identically to any other verb — but
    reaching the retry arm at all requires a request the pool is permitted to
    replay (`_h1_pooled_retry_is_safe`, client.mojo). This fixture is a GET:
    `_h1_method_is_replay_safe` is RFC 9110 §9.2.1's SAFE set (Go's
    `Request.isReplayable`), so a PUT whose bytes reached the wire is not
    replayed — see
    `test_row1_not_replay_safe_with_bytes_written_is_not_retried`
    (`test_h1_pool_stale_conn_retry_safety.mojo`). A GET is replay-safe by the
    method alone, so it reaches the dial-fresh arm without coupling a DNS test
    to the `Idempotency-Key` opt-in. EVERY COUNT BELOW IS UNCHANGED: the verb
    is not an input to either the dial count or the resolve count."""
    print("-- test_dead_keepalive_retry_arm_resolves_before_its_dial --")
    var stream_1 = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    )
    var connector = ScriptedConnector.with_stream(stream_1^)
    var own_conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var client = HttpClient[ScriptedConnector].with_defaults(own_conn^)
    var reactor = _make_reactor()

    var url_1 = Url.parse(String("http://127.0.0.1:9000/bucket/k1"))
    var hdrs_1 = HeaderMap()
    var req_1 = build_get_request(url_1^, hdrs_1^)
    var resp_1 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req_1^, connector, reactor)
    assert_equal(Int(resp_1.status), 200)
    assert_true(client.h1_idle_conn_is_cached(), "op1 must stash a conn")
    assert_equal(client.dial_resolve_steps_total(), 1)

    # The cached stream's read script is now exhausted → its next try_read is
    # EOF → the reuse attempt's head-read errors → re-dial. Arm the
    # connector's next fresh dial with a healthy response.
    var fresh = ScriptedStream.from_read_script(
        _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    )
    connector.arm(fresh^)

    var url_2 = Url.parse(String("http://127.0.0.1:9000/bucket/k1"))
    var hdrs_2 = HeaderMap()
    var req_2 = build_get_request(url_2^, hdrs_2^)
    var resp_2 = client.call_pooled[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req_2^, connector, reactor)
    assert_equal(
        Int(resp_2.status), 200,
        "a dead keepalive conn must re-dial fresh and replay",
    )
    assert_equal(
        connector.connect_call_count(), 2,
        "op1 dial (1) + op2 dead-conn fresh re-dial (1) = 2",
    )
    assert_equal(
        client.dial_resolve_steps_total(),
        2,
        (
            "the dial-fresh RETRY arm dialled without resolving. `ip_be` is"
            " consumed inside that `except`, which is exactly why the fix"
            " could not be a relocation of the one statement: the arm needs"
            " its own resolve."
        ),
    )
    print("    [OK] retry arm: 2 dials, 2 resolves")


# =============================================================================
# Gate 6 ★★ — `send_grpc_pooled` (h2 multiplex): N RPCs, ONE resolve.
# =============================================================================
def _h2_response_script(n: Int) raises -> List[UInt8]:
    """Server-side h2 frames for N sequential RPCs on ONE conn — client stream
    ids 1, 3, 5, … Mirrors `test_grpc_pooled_send_multiplex.mojo`."""
    var bytes = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)
    var hpack = HpackEncoder(max_table_size=4096)
    var k = 0
    while k < n:
        var sid = UInt32(1 + 2 * k)
        var body_str = String("r") + String(Int(sid))
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), String("200")))
        hdrs.append(
            HpackHeader(
                String("content-length"), String(len(body_str.as_bytes())),
            )
        )
        var block = hpack.encode_block(hdrs^)
        encode_headers_frame(
            sid, block^, end_stream=False, end_headers=True, out=bytes,
        )
        var body_bytes = _b(body_str)
        encode_data_frame(sid, body_bytes^, end_stream=True, out=bytes)
        k = k + 1
    return bytes^


def test_grpc_pooled_h2_multiplex_resolves_once() raises:
    """N gRPC RPCs multiplexed on ONE pooled h2 conn cost ONE resolve.

    ⚠ THE AUTHORITY IS AN IP LITERAL ON PURPOSE. The sibling multiplex test
    uses `storage.googleapis.com`, which makes its own hermetic run perform a
    live `getaddrinfo` — the very call this file exists to stop paying. A
    literal keeps this gate off the network entirely; the resolve-step ENTRY,
    which is what is being counted, is identical either way."""
    print("-- test_grpc_pooled_h2_multiplex_resolves_once --")
    var N = 4
    var resp_script = _h2_response_script(N)
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    # One byte per read so each RPC's drive stops at its own END_STREAM.
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream_tls(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var i = 0
    while i < N:
        var url = Url.parse(String("https://127.0.0.1:443/pkg.Svc/M"))
        var hdrs = HeaderMap()
        var req = build_request_with_body[BytesBody](
            method_post(), url^, hdrs^,
            BytesBody.from_bytes(_b(String("req") + String(i))),
        )
        var resp = client.send_grpc_pooled[
            PerCoreAsyncRuntime[NoopSink], BytesBody
        ](req^, reactor)
        assert_equal(Int(resp.status), 200, String("rpc ") + String(i))
        var guard = 0
        while guard < 1_000_000:
            guard = guard + 1
            var frame = resp.body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
                reactor, token,
            )
            if frame.is_end():
                break
        i = i + 1

    assert_equal(
        client._connector.connect_call_count(), 1,
        "h2 multiplex regressed: N RPCs must share ONE dialled conn.",
    )
    assert_equal(
        client.h2_pool_dials_total(), 1,
        "exactly ONE h2 conn registered",
    )
    assert_equal(
        client.dial_resolve_steps_total(),
        1,
        (
            "`send_grpc_pooled` resolved on a multiplex hit. This is the"
            " Firestore/GCS path of a serve loop: N RPCs per tick on one warm"
            " connection, each of which was paying an unbounded resolve."
        ),
    )
    print("    [OK] " + String(N) + " RPCs -> 1 dial, 1 resolve")


# =============================================================================
# The source reader — code-only text.
# =============================================================================
def _count(haystack: String, needle: String) -> Int:
    """Non-overlapping occurrences of `needle` in `haystack`."""
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return 0
    var seen = 0
    var i = 0
    while i + len(n) <= len(h):
        var ok = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                ok = False
                break
        if ok:
            seen += 1
            i += len(n)
        else:
            i += 1
    return seen


def _cut_trailing_comment(line: String) raises -> String:
    """Everything before the first `#`. Not quote-aware and it does not need to
    be: cutting EARLY can only DROP text, and every assertion it feeds is a
    POSITIVE one, so an offender cannot hide behind it."""
    var parts = line.split(String("#"))
    return String(parts[0])


def _code_lines(text: String) raises -> List[String]:
    """`text` as lines, comment tails cut and `\"\"\"` docstrings removed."""
    var rows = text.split(String("\n"))
    var out = List[String]()
    var in_doc = False
    for i in range(len(rows)):
        var raw = String(rows[i])
        var triples = _count(raw, String('"""'))
        if in_doc:
            if triples > 0 and triples % 2 == 1:
                in_doc = False
            continue
        if triples > 0:
            if triples % 2 == 1:
                in_doc = True
            continue
        out.append(_cut_trailing_comment(raw))
    return out^


def _read_source(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _is_blank(line: String) -> Bool:
    var bs = line.as_bytes()
    for i in range(len(bs)):
        if bs[i] != UInt8(ord(" ")):
            return False
    return True


def _starts_at_column_zero(line: String) -> Bool:
    var bs = line.as_bytes()
    if len(bs) == 0:
        return False
    return bs[0] != UInt8(ord(" "))


def _block_from(lines: List[String], head: String) raises -> List[String]:
    """The lines of the declaration opening with `head`, up to (not including)
    the next declaration at the SAME indent or at column zero.

    Raises on a head that matches nothing — an empty block would satisfy every
    positive assertion below, so "found nothing to look at" must never read as
    "found nothing wrong"."""
    var out = List[String]()
    var inside = False
    var indent_is_method = head.find(String("    def ")) == 0
    for i in range(len(lines)):
        var row = lines[i]
        if not inside:
            if row.find(head) == 0:
                inside = True
                out.append(row)
            continue
        if indent_is_method:
            var is_def = row.find(String("    def ")) == 0
            var is_dec = row.find(String("    @")) == 0
            if is_def or is_dec:
                break
        if _starts_at_column_zero(row):
            break
        out.append(row)
    if len(out) == 0:
        raise Error(
            String("the source reader found NO declaration opening with `")
            + head
            + String("` in ")
            + _CLIENT_SRC
            + String(
                ". An empty block satisfies every positive assertion in this"
                " file, so a rename or a deletion must RED here rather than"
                " pass quietly."
            )
        )
    return out^


def _next_code_line(block: List[String], start: Int) -> String:
    """The first non-blank line strictly after `start`, or "" if none."""
    var i = start + 1
    while i < len(block):
        if not _is_blank(block[i]):
            return block[i]
        i = i + 1
    return String("")


# =============================================================================
# Gate 7 ★★ — EVERY RESOLVE SITS IMMEDIATELY BEFORE A DIAL.
# =============================================================================
def test_every_resolve_is_immediately_followed_by_a_dial() raises:
    """The structural statement of laziness, and the ONLY gate that reaches the
    four converted methods this file cannot drive (the two streaming-pooled
    issuers, the streaming GET, and the h2 batch).

    Pre-fix the resolve sat at the TOP of the method and the next code line was
    `set_dial_host` / `ensure_h2_pool` / the pool probe — so this gate is red
    on exactly the shape being removed."""
    print("-- test_every_resolve_is_immediately_followed_by_a_dial --")
    var lines = _code_lines(_read_source(_CLIENT_SRC))
    var methods = _converted_methods()
    var checked = 0
    for m in range(len(methods)):
        var name = methods[m]
        var block = _block_from(
            lines, String("    def ") + name + String("["),
        )
        var resolves = 0
        for i in range(len(block)):
            if _count(block[i], _RESOLVE) == 0:
                continue
            resolves += 1
            var nxt = _next_code_line(block, i)
            assert_true(
                _count(nxt, _DIAL) > 0,
                (
                    String("`")
                    + name
                    + String("` resolves a dial address and then does")
                    + String(" something OTHER than dial. The next code line")
                    + String(" is `")
                    + nxt
                    + String("`. A resolve NOT immediately followed by")
                    + String(" `")
                    + _DIAL
                    + String("` is a resolve some path reaches without")
                    + String(" dialling — which is the defect: a blocking,")
                    + String(" uncancellable getaddrinfo paid by a request")
                    + String(" that reuses a pooled connection.")
                ),
            )
        assert_true(
            resolves >= 1,
            (
                String("`")
                + name
                + String("` contains no call to `")
                + _RESOLVE
                + String("`. Either it stopped resolving (its dial reads a")
                + String(" stale address) or it resolves through some other")
                + String(" path the counter cannot see, which makes every")
                + String(" behavioural gate in this file blind to it.")
            ),
        )
        checked += resolves
    assert_true(
        checked >= len(methods),
        "the reader matched fewer resolve sites than there are methods.",
    )
    print(
        "    [OK] "
        + String(checked)
        + " resolve site(s) across "
        + String(len(methods))
        + " method(s), each immediately before a dial"
    )


# =============================================================================
# Gate 8 ★★ — NO DIAL IN THE STRUCT RESOLVES OFF THE COUNTER.
# =============================================================================
def test_struct_resolve_sites_match_struct_dial_sites() raises:
    """Two halves of one claim, and neither half is the other.

      * the ONLY raw `_ip_be_from_host(` inside `struct HttpClient` is the one
        inside `_resolve_dial_ip_be` itself — every other method resolve routes
        through that helper, so `dial_resolve_steps_total` is a TOTAL and not a
        sample. (The helper's own call is asserted to EXIST, not merely
        tolerated: a helper that stopped resolving would make every count in
        this file a count of nothing.)
      * resolve sites == dial sites — one resolve per dial, so neither a dial
        reading a stale address nor a resolve nothing dials can hide."""
    print("-- test_struct_resolve_sites_match_struct_dial_sites --")
    var lines = _code_lines(_read_source(_CLIENT_SRC))
    var block = _block_from(lines, _STRUCT_HEAD)
    var helper = _block_from(
        lines, String("    def _resolve_dial_ip_be("),
    )
    var raw = 0
    var counted = 0
    var dials = 0
    for i in range(len(block)):
        raw += _count(block[i], _RAW_RESOLVE)
        counted += _count(block[i], _RESOLVE)
        dials += _count(block[i], _DIAL)
    var raw_in_helper = 0
    for i in range(len(helper)):
        raw_in_helper += _count(helper[i], _RAW_RESOLVE)
    assert_equal(
        raw_in_helper,
        1,
        (
            String("`_resolve_dial_ip_be` does not call `")
            + _RAW_RESOLVE
            + String("`. It is the one place in the struct that may, and it")
            + String(" must: a counter that counts entries into a step that")
            + String(" no longer resolves makes every assertion in this file")
            + String(" a measurement of nothing.")
        ),
    )
    assert_equal(
        raw - raw_in_helper,
        0,
        (
            String("`struct HttpClient` calls the UNCOUNTED `")
            + _RAW_RESOLVE
            + String("` directly, outside `")
            + _RESOLVE
            + String("` (")
            + String(raw - raw_in_helper)
            + String(" site(s)). A direct call is a resolve no test can see,")
            + String(" which is the condition this whole file exists to end.")
        ),
    )
    assert_true(
        dials >= 1,
        "the reader found NO dial site in the struct — it is reading nothing.",
    )
    assert_equal(
        counted,
        dials,
        (
            String("the struct has ")
            + String(dials)
            + String(" dial site(s) but ")
            + String(counted)
            + String(" counted resolve(s). Fewer resolves means some dial")
            + String(" reads an address it did not compute; more means a")
            + String(" resolve runs on a path that never dials.")
        ),
    )
    print(
        "    [OK] "
        + String(dials)
        + " dial site(s), "
        + String(counted)
        + " counted resolve(s), 0 uncounted outside the helper"
    )


# =============================================================================
# Gate 9 ★★ — THE READER READS CODE, NOT PROSE.
# =============================================================================
def test_the_reader_reads_code_and_not_prose() raises:
    """This file's own header names `_resolve_dial_ip_be` and `connect[RT](`
    repeatedly. If the reader counted comments, gates 7 and 8 would be
    satisfiable by writing about the change instead of making it.

    ⚠ THE SENTINEL IS ASSEMBLED AT RUNTIME FROM TWO HALVES, DELIBERATELY. Spelt
    whole as a literal it would BE code, the joined token would appear in the
    code text, and the zero assertion could never hold — red for a reason that
    has nothing to do with the reader. Split, it occurs whole only in the
    comment on the next line:
        PROSE_ONLY_LAZYRESOLVE_SENTINEL
    """
    print("-- test_the_reader_reads_code_and_not_prose --")
    var sentinel = String("PROSE_ONLY") + String("_LAZYRESOLVE_SENTINEL")
    var self_text = _read_source(_SELF_SRC)
    assert_true(
        _count(self_text, sentinel) >= 1,
        (
            "the sentinel is gone from this file's comments — the control is"
            " vacuous. Restore it or the zero assertion below proves nothing."
        ),
    )
    var lines = _code_lines(self_text)
    var in_code = 0
    for i in range(len(lines)):
        in_code += _count(lines[i], sentinel)
    assert_equal(
        in_code,
        0,
        (
            "the reader counted a token that appears ONLY in a comment — so"
            " every source gate in this file could be satisfied by prose."
        ),
    )
    print("    [OK] prose contributes nothing to the reader")


def main() raises:
    print("=== test_dial_resolve_is_lazy ===")
    test_h1_pooled_reuse_resolves_once_for_ten_sends()
    test_cold_dial_resolves_exactly_once()
    test_resolves_track_dials_not_requests()
    test_call_pooled_reuse_resolves_once_for_ten_ops()
    test_dead_keepalive_retry_arm_resolves_before_its_dial()
    test_grpc_pooled_h2_multiplex_resolves_once()
    test_every_resolve_is_immediately_followed_by_a_dial()
    test_struct_resolve_sites_match_struct_dial_sites()
    test_the_reader_reads_code_and_not_prose()
    print("=== all gates passed ===")
