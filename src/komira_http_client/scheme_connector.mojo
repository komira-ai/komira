# =============================================================================
# komira_http_client/scheme_connector.mojo -- a connector that is plaintext or
# TLS, fixed when it is made
# =============================================================================
#
# komira_http_client sends an `https` URL only over a connector whose
# `is_tls()` is True and an `http` URL only over one whose `is_tls()` is
# False. A client of one type that serves either kind of endpoint therefore
# needs a connector that is a sum: `SchemeConnector[P, T]` holds either a
# plaintext connector `P` or a TLS connector `T`, chosen when it is made, and
# its streams are the matching sum, `SchemeStream`, which forwards every
# `IoStream` method to the stream it holds.
#
# `KernelSchemeConnector` is the production one: a kernel TCP dial, plaintext
# or under TLS with public CA roots (the server name from each request's
# host). `kernel_plain_scheme_connector` and `kernel_tls_scheme_connector`
# make its two forms. Which form an endpoint gets is the caller's decision,
# made from the endpoint's scheme: komira_objectstore_s3's
# `s3_connector_factory` and komira_azure_blob's `azure_connector_factory`
# pick the plaintext form only for an `http://` endpoint.
#
# No UnsafePointer, no wildcard origin; both sums are value fields.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.transport.io_stream import Connector, IoStream, StreamIo
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)


struct SchemeStream[
    P: IoStream & Movable & Deinitable, T: IoStream & Movable & Deinitable
](IoStream, Movable, Deinitable):
    """A plaintext stream `P` or a TLS stream `T`, exactly one set."""

    var _plain: Optional[Self.P]
    var _tls: Optional[Self.T]

    def __init__(out self, *, var plain: Self.P):
        self._plain = Optional[Self.P](plain^)
        self._tls = None

    def __init__(out self, *, var tls: Self.T):
        self._plain = None
        self._tls = Optional[Self.T](tls^)

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](mut self, mut reactor: Reactor[RT.Sink], dst: Span[UInt8, o]) raises -> StreamIo:
        if self._tls:
            return self._tls.value().try_read[RT, o](reactor, dst)
        return self._plain.value().try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], src: Span[UInt8, _]
    ) raises -> StreamIo:
        if self._tls:
            return self._tls.value().try_write[RT](reactor, src)
        return self._plain.value().try_write[RT](reactor, src)

    def close(var self):
        if self._tls:
            self._tls.take().close()
        elif self._plain:
            self._plain.take().close()

    def negotiated_protocol(self) -> UInt8:
        if self._tls:
            return self._tls.value().negotiated_protocol()
        return self._plain.value().negotiated_protocol()

    def fd(self) -> Int32:
        if self._tls:
            return self._tls.value().fd()
        return self._plain.value().fd()

    def has_buffered_readable(self) -> Bool:
        if self._tls:
            return self._tls.value().has_buffered_readable()
        return self._plain.value().has_buffered_readable()

    def unread(mut self, src: Span[UInt8, _]) raises:
        if self._tls:
            self._tls.value().unread(src)
        else:
            self._plain.value().unread(src)

    def wire_bytes_moved(self) -> Int:
        if self._tls:
            return self._tls.value().wire_bytes_moved()
        return self._plain.value().wire_bytes_moved()

    def pending_wait_is_write(self, pending_token: Int64, call_is_write: Bool) -> Bool:
        if self._tls:
            return self._tls.value().pending_wait_is_write(pending_token, call_is_write)
        return self._plain.value().pending_wait_is_write(pending_token, call_is_write)


struct SchemeConnector[P: Connector, T: Connector](Connector, Movable, Deinitable):
    """A plaintext connector `P` or a TLS connector `T`, exactly one set,
    chosen when it is made (`plain` or `tls`); `is_tls()` says which."""

    comptime Stream = SchemeStream[Self.P.Stream, Self.T.Stream]

    var _plain: Optional[Self.P]
    var _tls: Optional[Self.T]

    def __init__(out self, *, var plain: Self.P):
        self._plain = Optional[Self.P](plain^)
        self._tls = None

    def __init__(out self, *, var tls: Self.T):
        self._plain = None
        self._tls = Optional[Self.T](tls^)

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> Self.Stream:
        if self._tls:
            return Self.Stream(tls=self._tls.value().connect[RT](reactor, ip_be, port))
        return Self.Stream(plain=self._plain.value().connect[RT](reactor, ip_be, port))

    def transport_kind(self) -> UInt8:
        if self._tls:
            return self._tls.value().transport_kind()
        return self._plain.value().transport_kind()

    def is_tls(self) -> Bool:
        return Bool(self._tls) and self._tls.value().is_tls()

    def set_dial_host(mut self, var host: String):
        if self._tls:
            self._tls.value().set_dial_host(host^)
        else:
            self._plain.value().set_dial_host(host^)


# The production connector: a kernel TCP dial, plaintext or under TLS
# (public CA roots, the server name from each request's host).
comptime KernelSchemeConnector = SchemeConnector[
    KernelTcpConnector, TlsConnector[KernelTcpConnector]
]


def kernel_tls_scheme_connector() raises -> KernelSchemeConnector:
    """The production connector in its TLS form, for an `https` endpoint."""
    return KernelSchemeConnector(tls=build_unpinned_public_ca_tls_connector())


def kernel_plain_scheme_connector() raises -> KernelSchemeConnector:
    """The production connector in its plaintext form, for an `http`
    endpoint."""
    return KernelSchemeConnector(plain=KernelTcpConnector.new())
