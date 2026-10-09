# =============================================================================
# kci_gcp_emulator/emu_stream.mojo: the emulator behind komira_http_core's
# `Connector`.
# =============================================================================
#
# `EmulatorConnector` is a `Connector` whose every `connect` hands out an
# `EmulatorStream` over the one shared emulator (an `ArcPointer`), so a
# generated GCP client, its `HttpClient` and its connection pool run
# unchanged: what the client writes is an HTTP/1.1 request, and what it
# reads is the emulator's answer to it. The stream captures the request's
# bytes as the client writes them; the first read after the request is
# complete serves it (emu_serve.mojo) and replays the answer, which closes
# the connection, so every request dials again. Nothing reaches a socket or
# a resolver: the connector is plaintext (`is_tls` False), and the clients
# are pointed at IP-literal `http` endpoints, which the client dials without
# DNS.
#
# Ownership: the emulator lives in an `ArcPointer` shared by the test, the
# connectors and their streams; the last holder frees it. No pointer
# crosses this module's API.
# =============================================================================

from std.memory import ArcPointer, unsafe_memcpy

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)

from kci_gcp_emulator.emu_http import failure, parse_request, response_bytes
from kci_gcp_emulator.emu_serve import serve
from kci_gcp_emulator.emu_state import GcpEmulator


comptime _EPROTO: Int64 = 71
"""The errno a read reports when the client stopped before its request was
whole (the emulator has nothing to answer)."""


struct EmulatorStream(IoStream, Movable, Deinitable):
    """One connection to the emulator (the file header)."""

    var _emu: ArcPointer[GcpEmulator]
    var _request: List[UInt8]
    var _answer: List[UInt8]
    var _served: Bool
    var _cursor: Int

    def __init__(out self, emu: ArcPointer[GcpEmulator]):
        self._emu = emu.copy()
        self._request = List[UInt8]()
        self._answer = List[UInt8]()
        self._served = False
        self._cursor = 0

    def _serve(mut self) raises -> Bool:
        """Serve the captured request once it is whole; False while it is
        not."""
        var req = parse_request(self._request)
        if not req:
            return False
        var res = serve(self._emu[], req.value())
        self._answer = response_bytes(res)
        self._served = True
        return True

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        _ = reactor
        if not self._served:
            var whole: Bool
            try:
                whole = self._serve()
            except:
                self._answer = response_bytes(failure(400, String("emulator: a request that is not HTTP/1.1")))
                self._served = True
                whole = True
            if not whole:
                return StreamIo.error(_EPROTO)
        var remaining = len(self._answer) - self._cursor
        if remaining <= 0:
            return StreamIo.eof()
        var n = remaining
        if len(dst) < n:
            n = len(dst)
        # SAFETY: `dst` is the caller's buffer, valid for this call; the
        # source is this stream's own `_answer` from `_cursor`, and `n` is
        # at most what remains of it and at most `len(dst)`. Neither pointer
        # is stored.
        unsafe_memcpy(dest=dst.unsafe_ptr(), src=self._answer.unsafe_ptr() + self._cursor, count=n)
        self._cursor += n
        return StreamIo.ready(Int64(n))

    def unread(mut self, src: Span[UInt8, _]) raises:
        """Give back the tail of what was read: the cursor rewinds over it,
        after checking it is exactly the bytes handed out."""
        var n = len(src)
        if n == 0:
            return
        if n > self._cursor:
            raise Error(String("EmulatorStream.unread: more bytes given back than were read"))
        var base = self._cursor - n
        for i in range(n):
            if self._answer[base + i] != src[i]:
                raise Error(String("EmulatorStream.unread: the bytes given back are not the ones read"))
        self._cursor = base

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        _ = reactor
        for i in range(len(src)):
            self._request.append(src[i])
        return StreamIo.ready(Int64(len(src)))

    def close(var self):
        _ = self._request^
        _ = self._answer^

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct EmulatorConnector(Connector, Movable, Deinitable):
    """A plaintext `Connector` to the shared emulator (the file header).
    Every client needs one of its own; each is a handle on the same
    emulator."""

    comptime Stream = EmulatorStream

    var _emu: ArcPointer[GcpEmulator]
    var _dials: Int

    def __init__(out self, emu: ArcPointer[GcpEmulator]):
        self._emu = emu.copy()
        self._dials = 0

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> EmulatorStream:
        _ = reactor
        _ = ip_be
        _ = port
        self._dials += 1
        return EmulatorStream(self._emu)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^

    def dials(self) -> Int:
        """How many connections this connector has handed out."""
        return self._dials
