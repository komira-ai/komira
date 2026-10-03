"""Regression: the h2 client must UPLOAD a request body larger than the initial
send window (65535) by chunking it into flow-control-sized DATA frames and
refilling as the server reopens the window via WINDOW_UPDATE — otherwise any
large HTTP/2 PUT/POST (a bulk storage upload, for example) hangs.

THE BUG: the h2 client staged
the ENTIRE request body as ONE DATA frame in `pending_out` with END_STREAM set,
ignoring BOTH the peer's SETTINGS_MAX_FRAME_SIZE and the 65535-byte send window.
The driver flushed the first window's worth to the socket; `pending_out` emptied;
NO further body was queued as the server's WINDOW_UPDATEs reopened the window;
`end_stream_seen` never flipped; and `drive_h2_streams_to_completion` spun reads
until the 100k iteration cap fired:
`HttpError[TIMEOUT]: h2 driver iteration cap exceeded`. Small bodies (< the first
window) fully queued into the first `pending_out` and completed, which is why a
single small put-object worked but a >~32KB PUT wedged deterministically.

THE GUARD: drive the REAL `HttpClient.send_buffered` h2 PUT path against a
FLOW-CONTROL-RESPECTING mock server (`SendFcH2Server`) that models a conformant
peer:
  * it grants the client only the initial 65535-byte send window;
  * it decodes the client's inbound request DATA frames and enforces its receive
    window — a DATA frame whose length exceeds the currently-granted window is a
    flow-control violation and the server STALLS forever (never replies);
  * as it consumes request DATA it emits WINDOW_UPDATE (connection- AND
    stream-level) back to the client, reopening the send window;
  * only after it observes END_STREAM on the fully-received request body does it
    emit HEADERS(:status 200) + DATA(END_STREAM).

The request body is 300000 bytes — ~4.6x the default window — so the client MUST
send it across multiple WINDOW_UPDATE rounds. Pre-fix: the client emits one
oversized DATA frame, the server rejects it as a flow-control / frame-size
violation and stalls, the client never sees END_STREAM, the drive loop trips its
iteration cap -> raises TIMEOUT -> FAIL. Post-fix: the client chunks within the
window, refills on each WINDOW_UPDATE, reaches END_STREAM, and the server replies
200 -> PASS. A second case uploads a multi-MB body to prove arbitrary sizes.

Mojo 1.0.0b2 (def-only).
"""


from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.codec.h2.connection_preface import H2_CLIENT_PREFACE_LEN
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_DECODE_OK,
    FRAME_WINDOW_UPDATE,
    MAX_FRAME_PAYLOAD_DEFAULT,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_2,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)

from std.testing import assert_equal, assert_true


# The client advertises the RFC-default SETTINGS_INITIAL_WINDOW_SIZE, so the
# server grants the client a 65535-byte send window until it emits WINDOW_UPDATE.
comptime SEND_FC_INITIAL_WINDOW: Int = 65535
# The server's advertised SETTINGS_MAX_FRAME_SIZE (RFC default) — the client must
# also keep each DATA frame within this cap, orthogonal to the send window.
comptime SEND_FC_MAX_FRAME: Int = MAX_FRAME_PAYLOAD_DEFAULT  # 16384


struct SendFcH2Server(IoStream, Movable, Deinitable):
    """A flow-control-RESPECTING mock h2 server for the REQUEST-UPLOAD path.

    Models a conformant peer receiving a large request body:
      * `try_write` captures the client's bytes. Before each captured write we
        decode any newly-complete inbound frames. Request DATA frames are gated
        on the server's RECEIVE window (initial 65535, decremented per byte). A
        DATA frame whose length exceeds the currently-available receive window is
        a flow-control VIOLATION -> the server marks itself stalled and NEVER
        replies (reproducing the pre-fix wedge: the client that dumps the whole
        body at once trips this).
      * As it consumes valid request DATA, it accumulates a receive-drain count
        and, once past a watermark (half the initial window), stages a
        WINDOW_UPDATE pair (connection stream_id=0 + the request stream) into its
        OUTBOUND queue, restoring the receive window. This is what reopens the
        CLIENT's send window.
      * `try_read` reveals: first the server SETTINGS(empty), then any staged
        WINDOW_UPDATEs, and — once END_STREAM on the request is observed — the
        HEADERS(:status 200) + DATA(END_STREAM) final response.

    fd()==-1 so the driver's bounded park is a no-op; a genuine stall trips the
    iteration cap quickly rather than blocking the 120s wall."""

    var _outbound: List[UInt8]      # server -> client bytes, revealed by try_read
    var _out_cursor: Int
    var _write_buf: List[UInt8]     # captured client -> server bytes
    var _scan_cursor: Int           # decode progress into _write_buf
    var _recv_window: Int           # server receive window (conn+stream, merged)
    var _recv_drained: Int          # bytes consumed since last WINDOW_UPDATE
    var _req_stream_id: UInt32
    var _req_end_seen: Bool
    var _final_response_staged: Bool
    var _stalled: Bool

    def __init__(out self):
        self._outbound = List[UInt8]()
        self._out_cursor = 0
        self._write_buf = List[UInt8]()
        self._scan_cursor = 0
        self._recv_window = SEND_FC_INITIAL_WINDOW
        self._recv_drained = 0
        self._req_stream_id = UInt32(0)
        self._req_end_seen = False
        self._final_response_staged = False
        self._stalled = False
        # Stage the server's initial SETTINGS immediately (empty = defaults).
        var entries = List[SettingsEntry]()
        encode_settings_frame(entries^, self._outbound)

    def _stage_final_response(mut self):
        """Stage HEADERS(:status 200) + empty DATA(END_STREAM) for the request
        stream once the full body has been received."""
        if self._final_response_staged:
            return
        var hpack = HpackEncoder(max_table_size=4096)
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), String("200")))
        var block = hpack.encode_block(hdrs^)
        encode_headers_frame(
            self._req_stream_id, block^, end_stream=False, end_headers=True,
            out=self._outbound,
        )
        var empty = List[UInt8]()
        encode_data_frame(self._req_stream_id, empty^, True, self._outbound)
        self._final_response_staged = True

    def _process_client_writes(mut self):
        """Decode newly-complete client frames from _write_buf. Enforce the
        receive window on request DATA; emit WINDOW_UPDATEs as it drains; note
        END_STREAM."""
        if self._stalled:
            return
        # Skip the 24-byte client preface once.
        if self._scan_cursor == 0 and len(self._write_buf) >= H2_CLIENT_PREFACE_LEN:
            self._scan_cursor = H2_CLIENT_PREFACE_LEN
        while True:
            var avail = len(self._write_buf) - self._scan_cursor
            if avail < 9:
                return
            var tail = List[UInt8]()
            var i = self._scan_cursor
            while i < len(self._write_buf):
                tail.append(self._write_buf[i])
                i = i + 1
            var res = decode_frame(Span(tail), 16777215)
            if res.status != FRAME_DECODE_OK:
                # Not a full frame yet (or malformed) — wait for more bytes.
                return
            var kind = res.frame.header.kind
            var sid = res.frame.header.stream_id
            var flags = res.frame.header.flags
            if kind == FRAME_DATA:
                var plen = len(res.frame.payload)
                # FLOW-CONTROL ENFORCEMENT: a DATA frame larger than the granted
                # receive window is a violation — the pre-fix client's single
                # oversized frame trips this and the server stalls forever.
                if plen > self._recv_window:
                    self._stalled = True
                    return
                if self._req_stream_id == UInt32(0):
                    self._req_stream_id = sid
                self._recv_window = self._recv_window - plen
                self._recv_drained = self._recv_drained + plen
                # Replenish once we've drained past half the initial window.
                if self._recv_drained >= (SEND_FC_INITIAL_WINDOW // 2):
                    var credit = self._recv_drained
                    # Connection-level (stream_id=0) + stream-level WINDOW_UPDATE.
                    encode_window_update_frame(
                        UInt32(0), UInt32(credit), self._outbound
                    )
                    encode_window_update_frame(
                        sid, UInt32(credit), self._outbound
                    )
                    self._recv_window = self._recv_window + credit
                    self._recv_drained = 0
                if (flags & FLAG_END_STREAM) != UInt8(0):
                    self._req_end_seen = True
                    self._stage_final_response()
            # (HEADERS / WINDOW_UPDATE / SETTINGS from the client are consumed
            # silently — we only gate on request DATA for this guard.)
            self._scan_cursor = self._scan_cursor + res.consumed

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        _ = reactor
        # Fold in any client writes that landed since the last read.
        self._process_client_writes()
        var remaining = len(self._outbound) - self._out_cursor
        if remaining <= 0:
            if self._req_end_seen and self._final_response_staged:
                # Whole response delivered — signal graceful EOF.
                return StreamIo.eof()
            # Nothing to reveal yet — the server is waiting for more request
            # DATA (or has stalled). Park; fd()==-1 so the driver busy-loops.
            return StreamIo.pending(Int64(self._out_cursor))
        var n = remaining
        var dst_len = len(dst)
        if dst_len < n:
            n = dst_len
        var k = 0
        while k < n:
            dst[k] = self._outbound[self._out_cursor + k]
            k = k + 1
        self._out_cursor = self._out_cursor + n
        return StreamIo.ready(Int64(n))

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        _ = reactor
        var n = len(src)
        var i = 0
        while i < n:
            self._write_buf.append(src[i])
            i = i + 1
        return StreamIo.ready(Int64(n))

    def close(var self):
        _ = self._outbound^
        _ = self._write_buf^

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_2

    def fd(self) -> Int32:
        return Int32(-1)


struct SendFcH2Connector(Connector, Movable, Deinitable):
    """Connector handing out one pre-armed SendFcH2Server. Reports TLS so an
    `https://` client passes the scheme-check over the plaintext mock."""

    comptime Stream = SendFcH2Server

    var _armed: Optional[SendFcH2Server]

    def __init__(out self, var stream: SendFcH2Server):
        self._armed = Optional[SendFcH2Server](stream^)

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> SendFcH2Server:
        _ = reactor
        _ = ip_be
        _ = port
        if not self._armed:
            raise Error("SendFcH2Connector.connect: no stream armed")
        return self._armed.take()

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return True

    def set_dial_host(mut self, var host: String):
        """`Connector.set_dial_host` — inert on this scripted double: it never
        handshakes, so it has no SNI to present. Present so the double still
        conforms to `Connector`."""
        _ = host^


def _synthetic_body(n: Int) raises -> List[UInt8]:
    var b = List[UInt8]()
    var i = 0
    while i < n:
        b.append(UInt8((i * 31 + 7) & 0xFF))
        i = i + 1
    return b^


def _run_put_of_size(body_len: Int) raises -> Int:
    """Drive a real h2 PUT of `body_len` bytes against the flow-control-
    respecting mock server; return the response status. Pre-fix this RAISES
    HttpError[TIMEOUT] for body_len > 65535; post-fix it returns 200."""
    var server = SendFcH2Server()
    var connector = SendFcH2Connector(server^)
    var client = HttpClient[SendFcH2Connector].with_defaults(connector^)

    var url = Url.https(
        String("storage.googleapis.com"), UInt16(443),
        String("/upload/storage/v1/b/x/o"),
    )
    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("application/octet-stream"))
    var body = _synthetic_body(body_len)
    var req = build_request_with_body[BytesBody](
        HttpMethod.put(), url^, headers^, BytesBody.from_bytes(body^)
    )

    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
        req^, reactor
    )
    return Int(cr.status)


def test_h2_large_request_body_128kb_uploads_under_flow_control() raises:
    print("  test_h2_large_request_body_128kb_uploads_under_flow_control...")
    # 300000 bytes ~= 4.6x the 65535 send window: the client MUST send it across
    # multiple WINDOW_UPDATE rounds. Pre-fix (single oversized DATA frame): the
    # server rejects it as a flow-control violation and stalls; the driver trips
    # the iteration cap -> raises TIMEOUT. Post-fix: chunked + refilled -> 200.
    var status = _run_put_of_size(300000)
    assert_equal(
        status, 200,
        "the h2 client must UPLOAD a >64KB body to END_STREAM under flow"
        " control (pre-fix: one oversized DATA frame -> server stall -> h2"
        " driver iteration cap exceeded TIMEOUT)",
    )
    print("    OK — 300000-byte body uploaded under flow control -> 200")


def test_h2_multi_mb_request_body_uploads_under_flow_control() raises:
    print("  test_h2_multi_mb_request_body_uploads_under_flow_control...")
    # ~2.5 MB — proves the streaming send path handles arbitrary sizes (dozens
    # of WINDOW_UPDATE rounds), well within the 100k iteration cap.
    var status = _run_put_of_size(2_500_000)
    assert_equal(
        status, 200,
        "a multi-MB h2 request body must upload to END_STREAM under flow control",
    )
    print("    OK — 2500000-byte body uploaded under flow control -> 200")


def test_h2_small_request_body_still_uploads() raises:
    print("  test_h2_small_request_body_still_uploads...")
    # Below the first window — the pre-fix path handled this (single frame that
    # fits); the fix must not regress it.
    var status = _run_put_of_size(8000)
    assert_equal(status, 200, "a sub-window body must still upload -> 200")
    print("    OK — 8000-byte body uploaded -> 200")


def main() raises:
    print("== h2 large-request-body send flow control ==")
    test_h2_small_request_body_still_uploads()
    test_h2_large_request_body_128kb_uploads_under_flow_control()
    test_h2_multi_mb_request_body_uploads_under_flow_control()
    print("PASS test_h2_large_request_body_send_flow_control")
