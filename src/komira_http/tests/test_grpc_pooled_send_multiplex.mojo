"""Pooled gRPC send gate.

Proves the Gap A multiplex invariant + the buffered A/B-safety guarantee:

  Test 1 (multiplex):  N concurrent unary gRPC RPCs to the SAME authority,
    routed through HttpClient.send_grpc_pooled (the entry GrpcClient now
    funnels through), multiplex on ONE pooled h2 connection. Asserted via
    the h2_pool COUNTERS — `h2_pool_dials_total() == 1` (one dial) and
    `h2_pool_conn_count_at(0) == 1` (one conn) after all N RPCs — NOT just
    a rowcount. Each RPC's response body is verified byte-correct.

  Test 2 (A/B byte-identity):  the new stream-less
    RecvRingBody.from_buffered_bytes conformer that bridges the buffered h2
    codec to the gRPC drain layer yields EXACTLY the bytes it was seeded
    with via poll_frame (one Data frame + End), identical to
    BufferedResponseBody.from_bytes — the guarantee that a buffered gRPC
    caller (StorageGrpcClient / GcpStorageClient) sees no behavioral change.

The fake/in-memory seam is the ScriptedConnector + ScriptedStream that the
existing fd-count structural gate (test_http_client_fdcount_structural.mojo)
and the h2 driver tests (test_L2_h2_client_driver.mojo) use — NO real
network. The ScriptedStream is armed with ALPN h2 + a pre-built server
response script (initial SETTINGS + N HEADERS/DATA frames keyed to the
client's deterministic stream ids 1,3,5,...).
"""

from std.sys import CompilationTarget

from std.builtin.swap import swap

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.cancellation.token import CancellationToken

from komira_http.client.body import BytesBody
from komira_http.client.client import (
    HttpClient,
    build_request_with_body,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import method_post
from komira_http.client.response_body import (
    BufferedResponseBody,
    RecvRingBody,
)
from komira_http.client.url import Url
from komira_http.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _bytes(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _build_n_response_script(n: Int) raises -> List[UInt8]:
    """Server-side h2 response script for N sequential RPCs on ONE conn.

    The client's `send_grpc_pooled` allocates client stream ids 1, 3, 5,
    ... (odd, +2 per RPC). The server replies with the initial SETTINGS
    frame followed by, for each stream id, a HEADERS(:status=200) +
    DATA(END_STREAM) carrying body "responseN". A single greedy read by
    the first drive populates every stream's per-stream response buffer
    (process_received_frames decodes ALL frames in the recv buffer), and
    each subsequent pooled RPC sees its awaited stream already complete.

    The HEADERS blocks are emitted by ONE server-side HpackEncoder in
    stream-id order so the client's HPACK decoder stays in sync.
    """
    var bytes = List[UInt8]()
    # Server initial SETTINGS (empty, non-ACK).
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)

    var hpack = HpackEncoder(max_table_size=4096)
    var k = 0
    while k < n:
        var sid = UInt32(1 + 2 * k)
        var body_str = String("response") + String(Int(sid))
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), String("200")))
        hdrs.append(
            HpackHeader(
                String("content-length"),
                String(len(body_str.as_bytes())),
            )
        )
        var block = hpack.encode_block(hdrs^)
        encode_headers_frame(
            sid, block^, end_stream=False, end_headers=True, out=bytes,
        )
        var body_bytes = _bytes(body_str)
        encode_data_frame(sid, body_bytes^, end_stream=True, out=bytes)
        k = k + 1
    return bytes^


def _grpc_post_request() raises -> Url:
    """A gRPC-shaped POST target — https authority so send_grpc_pooled
    takes the h2 multiplex path (NOT the plaintext fallback)."""
    return Url.parse(String("https://storage.googleapis.com:443/pkg.Svc/M"))


def test_n_grpc_rpcs_multiplex_on_one_pooled_h2_conn() raises:
    """Gap A multiplex gate. N pooled gRPC sends to the SAME https
    authority dial ONE h2 conn and run N streams on it.

    Asserts via the h2_pool counters:
      * h2_pool_dials_total() == 1   (exactly one dial)
      * h2_pool_conn_count_at(0) == 1 (all N streams shared one conn)
      * h2_pool_bucket_count() == 1   (one authority bucket)
      * connector.connect_call_count() == 1 (one socket dialed)
    and each RPC's response body matches the seeded "responseN".
    """
    print("  test_n_grpc_rpcs_multiplex_on_one_pooled_h2_conn...")

    var N = 6
    var resp_script = _build_n_response_script(N)
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    # Serve the script ONE byte per read so each RPC's drive consumes
    # ONLY its own stream's response frames and stops at its END_STREAM
    # boundary — the remaining streams' bytes stay in the script for the
    # next RPC's drive. (A greedy read would pull frames for streams not
    # yet created on the conn, which the client drops → EOF_MID_RESPONSE.)
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var i = 0
    while i < N:
        var url = _grpc_post_request()
        var hdrs = HeaderMap()
        # A small gRPC-ish request body (envelope-shaped bytes — content
        # is opaque to the transport; what matters is the pooled routing).
        var body_bytes = _bytes(String("req") + String(i))
        var req = build_request_with_body[BytesBody](
            method_post(), url^, hdrs^, BytesBody.from_bytes(body_bytes^),
        )
        var resp = client.send_grpc_pooled[
            PerCoreAsyncRuntime[NoopSink], BytesBody
        ](req^, reactor)
        assert_equal(Int(resp.status), 200)

        # Drain the streaming body — should be the seeded "responseN".
        var sid = 1 + 2 * i
        var got = List[UInt8]()
        var guard = 0
        while guard < 1_000_000:
            guard = guard + 1
            var frame = resp.body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
                reactor, token,
            )
            if frame.is_end():
                break
            if frame.is_data():
                var chunk = frame.take_data_chunk()
                var c = 0
                while c < len(chunk):
                    got.append(chunk[c])
                    c = c + 1
            # Pending/trailers: re-poll (no wire stream — won't pend).
        var got_str = String()
        var gi = 0
        while gi < len(got):
            got_str += chr(Int(got[gi]))
            gi = gi + 1
        var expected = String("response") + String(sid)
        assert_equal(
            got_str, expected,
            String("RPC ") + String(i) + String(" body mismatch"),
        )
        i = i + 1

    # THE multiplex invariant — counters, not rowcount:
    assert_equal(
        client._connector.connect_call_count(), 1,
        String("exactly ONE socket dialed for N pooled RPCs"),
    )
    assert_equal(
        client.h2_pool_dials_total(), 1,
        String("exactly ONE h2 conn registered (insert_dialed_h2)"),
    )
    assert_equal(
        client.h2_pool_bucket_count(), 1,
        String("all N RPCs landed on ONE authority bucket"),
    )
    assert_equal(
        client.h2_pool_conn_count_at(0), 1,
        String("all N streams multiplexed on ONE pooled conn"),
    )
    print("    OK")


def test_buffered_grpc_body_bytes_are_ab_identical() raises:
    """A/B byte-identity gate. The stream-less RecvRingBody the pooled
    gRPC path hands back (RecvRingBody.from_buffered_bytes) yields EXACTLY
    the seeded bytes via poll_frame — one Data frame + End — matching the
    BufferedResponseBody.from_bytes conformer the buffered gRPC callers
    already drive. This is the guarantee that StorageGrpcClient /
    GcpStorageClient observe no change in response bytes.
    """
    print("  test_buffered_grpc_body_bytes_are_ab_identical...")

    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var payload = _bytes(String("the-exact-grpc-response-envelope-bytes-0123"))

    # A: the BufferedResponseBody path (what a buffered caller used before).
    var buffered = BufferedResponseBody.from_bytes(payload.copy())
    var a_out = List[UInt8]()
    var ag = 0
    while ag < 16:
        var af = buffered.poll_frame[PerCoreAsyncRuntime[NoopSink]](
            reactor, token,
        )
        if af.is_end():
            break
        if af.is_data():
            var c = af.take_data_chunk()
            var ci = 0
            while ci < len(c):
                a_out.append(c[ci])
                ci = ci + 1
        ag = ag + 1

    # B: the new stream-less RecvRingBody the pooled gRPC path returns.
    var streaming = RecvRingBody[ScriptedStream].from_buffered_bytes(
        payload.copy()
    )
    var b_out = List[UInt8]()
    var bg = 0
    while bg < 16:
        var bf = streaming.poll_frame[PerCoreAsyncRuntime[NoopSink]](
            reactor, token,
        )
        if bf.is_end():
            break
        if bf.is_data():
            var c = bf.take_data_chunk()
            var ci = 0
            while ci < len(c):
                b_out.append(c[ci])
                ci = ci + 1
        bg = bg + 1

    # A == B == the seeded payload, byte-for-byte.
    assert_equal(len(a_out), len(payload), String("A length == payload"))
    assert_equal(len(b_out), len(payload), String("B length == payload"))
    var i = 0
    while i < len(payload):
        assert_equal(
            Int(a_out[i]), Int(payload[i]),
            String("A byte ") + String(i),
        )
        assert_equal(
            Int(b_out[i]), Int(a_out[i]),
            String("B byte ") + String(i) + String(" != A (A/B drift)"),
        )
        i = i + 1
    print("    OK")


def test_empty_buffered_grpc_body_yields_end_only() raises:
    """A/B edge: an empty gRPC response (e.g. delete_object → empty proto)
    yields End directly with NO Data frame — identical for both the
    stream-less RecvRingBody and BufferedResponseBody."""
    print("  test_empty_buffered_grpc_body_yields_end_only...")

    var reactor = _make_reactor()
    var token = CancellationToken.never()

    var streaming = RecvRingBody[ScriptedStream].from_buffered_bytes(
        List[UInt8]()
    )
    var f = streaming.poll_frame[PerCoreAsyncRuntime[NoopSink]](
        reactor, token,
    )
    assert_true(f.is_end(), String("empty body → first poll is End"))
    print("    OK")


def main() raises:
    test_n_grpc_rpcs_multiplex_on_one_pooled_h2_conn()
    test_buffered_grpc_body_bytes_are_ab_identical()
    test_empty_buffered_grpc_body_yields_end_only()
    print("[OK] test_grpc_pooled_send_multiplex — all 3 tests passed")
