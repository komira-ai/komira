"""Regression: the h2 client must drain a >64KB response to END_STREAM by
emitting WINDOW_UPDATE frames as it consumes DATA.

THE BUG: a `list_objects` call on a POPULATED bucket (hundreds of objects)
returns a GCS JSON list response of ~200KB. That exceeds the
HTTP/2 default flow-control window (65535 bytes). If the h2 client does NOT emit
`WINDOW_UPDATE` frames as it consumes the response body, a flow-control-
respecting server (GCS) stalls after ~64KB waiting for the window to reopen; the
client sees no more DATA and the 120s h2 driver wall-clock deadline fires
(`HttpError[TIMEOUT]: h2 driver wall-clock deadline exceeded`), while every
response below 64KB succeeds.

THE GUARD: drive the REAL `HttpClient.send_buffered` h2 path against a FLOW-
CONTROL-RESPECTING mock server (`FcH2Server`) that reveals response DATA only up
to the window it has been granted, and grows that window ONLY when it observes a
`WINDOW_UPDATE` frame (connection- AND stream-level, both required) in the
client's writes — exactly as GCS behaves. The response body is 200000 bytes,
~3x the default window. Pre-fix (no WINDOW_UPDATE on receive): the mock stalls at
65535 bytes, the client never advances, the drive loop trips its iteration/wall
cap -> raises TIMEOUT -> FAIL. Post-fix (WINDOW_UPDATE emitted on ring-drain):
the mock keeps streaming, the client reaches END_STREAM with the full body -> PASS.

Mojo 1.0.0b2 (def-only).
"""


from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.body import EmptyBody
from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url
from komira_http.codec.h2.connection_preface import H2_CLIENT_PREFACE_LEN
from komira_http.codec.h2.frame import (
    FRAME_DECODE_OK,
    FRAME_WINDOW_UPDATE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_2,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)

from std.testing import assert_equal, assert_true


# Match the client's advertised SETTINGS_INITIAL_WINDOW_SIZE (RFC default).
comptime FC_INITIAL_WINDOW: Int64 = 65535
# ~200KB response body — ~3x the default window, so the server MUST receive at
# least two rounds of WINDOW_UPDATE to finish streaming it.
comptime FC_BODY_BYTES: Int = 200_000
# DATA frame payload cap = the client's advertised SETTINGS_MAX_FRAME_SIZE.
comptime FC_MAX_FRAME: Int = 16384


struct FcH2Server(IoStream, Movable, Deinitable):
    """A flow-control-RESPECTING mock h2 server (IoStream conformer).

    Models the exact GCS behaviour the production hang exercises:
      * `try_read` reveals the SETTINGS+HEADERS prefix freely, then reveals DATA
        bytes ONLY up to `min(conn_window, stream_window)`. When that credit is
        exhausted (and body remains), it returns `pending()` — the server has
        stalled waiting for the client to reopen its receive window.
      * `try_write` captures the client's bytes; before each read we scan the new
        write bytes for `WINDOW_UPDATE` frames and credit the corresponding
        window (stream_id==0 -> connection; else -> stream). BOTH must reopen for
        the reveal to advance — catching a client that emits one level but not
        the other.

    fd()==-1 + has_buffered_readable()==False (inherited default) mean the h2
    driver's bounded park is a no-op here, so a genuine stall trips the driver's
    iteration cap quickly (a fast TIMEOUT) rather than blocking 120s of wall."""

    var _script: List[UInt8]
    var _cursor: Int
    var _prefix_len: Int
    var _conn_window: Int64
    var _stream_window: Int64
    var _write_buf: List[UInt8]
    var _scan_cursor: Int

    def __init__(out self, var script: List[UInt8], prefix_len: Int):
        self._script = script^
        self._cursor = 0
        self._prefix_len = prefix_len
        self._conn_window = FC_INITIAL_WINDOW
        self._stream_window = FC_INITIAL_WINDOW
        self._write_buf = List[UInt8]()
        self._scan_cursor = 0

    def _absorb_window_updates(mut self):
        """Scan newly-written client bytes for WINDOW_UPDATE frames and credit
        the matching window. Skips the 24-byte client preface once."""
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
                return
            if res.frame.header.kind == FRAME_WINDOW_UPDATE:
                var inc = Int64(Int(res.frame.window_update_increment))
                if res.frame.header.stream_id == UInt32(0):
                    self._conn_window = self._conn_window + inc
                else:
                    self._stream_window = self._stream_window + inc
            self._scan_cursor = self._scan_cursor + res.consumed

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        _ = reactor
        self._absorb_window_updates()
        var remaining = len(self._script) - self._cursor
        if remaining <= 0:
            return StreamIo.eof()
        var dst_len = len(dst)
        var n_to_copy: Int
        if self._cursor < self._prefix_len:
            # Free (non-flow-controlled) SETTINGS + HEADERS prefix.
            n_to_copy = self._prefix_len - self._cursor
            if dst_len < n_to_copy:
                n_to_copy = dst_len
            if remaining < n_to_copy:
                n_to_copy = remaining
        else:
            # DATA region: gated on the granted receive window.
            var allowed = self._conn_window
            if self._stream_window < allowed:
                allowed = self._stream_window
            if allowed <= Int64(0):
                # Server stalled — window exhausted, awaiting WINDOW_UPDATE.
                return StreamIo.pending(Int64(self._cursor))
            n_to_copy = remaining
            if dst_len < n_to_copy:
                n_to_copy = dst_len
            if Int(allowed) < n_to_copy:
                n_to_copy = Int(allowed)
            self._conn_window = self._conn_window - Int64(n_to_copy)
            self._stream_window = self._stream_window - Int64(n_to_copy)
        var k = 0
        while k < n_to_copy:
            dst[k] = self._script[self._cursor + k]
            k = k + 1
        self._cursor = self._cursor + n_to_copy
        return StreamIo.ready(Int64(n_to_copy))

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
        _ = self._script^
        _ = self._write_buf^

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_2

    def fd(self) -> Int32:
        return Int32(-1)


struct FcH2Connector(Connector, Movable, Deinitable):
    """Connector conformer handing out one pre-armed FcH2Server. Reports TLS so
    an `https://` client passes the scheme-check gate over the plaintext mock."""

    comptime Stream = FcH2Server

    var _armed: Optional[FcH2Server]

    def __init__(out self, var stream: FcH2Server):
        self._armed = Optional[FcH2Server](stream^)

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> FcH2Server:
        _ = reactor
        _ = ip_be
        _ = port
        if not self._armed:
            raise Error("FcH2Connector.connect: no stream armed")
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


def test_h2_large_response_drains_with_flow_control() raises:
    print("  test_h2_large_response_drains_with_flow_control...")

    # Build the server response: SETTINGS(empty) + HEADERS(:status 200) + DATA
    # frames (16384 payload each, last END_STREAM) totalling FC_BODY_BYTES. Only
    # the DATA region (bytes past `prefix_len`) is flow-controlled per RFC 9113
    # §5.2.1 — the SETTINGS + HEADERS prefix is revealed freely.
    var script = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, script)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(1), block^, end_stream=False, end_headers=True, out=script
    )
    var prefix_len = len(script)
    var remaining = FC_BODY_BYTES
    while remaining > 0:
        var chunk = FC_MAX_FRAME if remaining > FC_MAX_FRAME else remaining
        var payload = List[UInt8]()
        var pi = 0
        while pi < chunk:
            payload.append(UInt8(0x41))  # 'A'
            pi = pi + 1
        var last = (remaining - chunk) == 0
        encode_data_frame(UInt32(1), payload^, last, script)
        remaining = remaining - chunk
    var server = FcH2Server(script^, prefix_len)
    var connector = FcH2Connector(server^)
    var client = HttpClient[FcH2Connector].with_defaults(connector^)

    var url = Url.https(
        String("storage.googleapis.com"), UInt16(443), String("/storage/v1/b/x/o")
    )
    var headers = HeaderMap()
    var req = build_get_request(url^, headers^)

    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    # Pre-fix this call RAISES HttpError[TIMEOUT] (the server stalls at 65535
    # bytes and the client never sends WINDOW_UPDATE). Post-fix it returns 200
    # with the full body.
    var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
        req^, reactor
    )

    assert_equal(Int(cr.status), 200, "flow-controlled server replied 200")
    ref body = cr.body.bytes_ref()
    assert_equal(
        len(body), FC_BODY_BYTES,
        "the h2 client must drain the FULL >64KB body (pre-fix: stalls at 65535"
        " -> TIMEOUT; the list_objects 120s-wall wedge)",
    )
    print("    OK — drained", len(body), "body bytes past the 65535 window")


def main() raises:
    test_h2_large_response_drains_with_flow_control()
    print("PASS test_h2_large_response_flow_control")
