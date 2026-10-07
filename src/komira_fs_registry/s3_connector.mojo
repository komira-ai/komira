# =============================================================================
# komira_fs_registry/s3_connector.mojo -- the S3 arm's connector: plaintext
# or TLS, as the endpoint's scheme says
# =============================================================================
#
# komira_http_client sends an `https` URL only over a connector whose
# `is_tls()` is True and an `http` URL only over one whose `is_tls()` is
# False. The S3 arm is one type for every endpoint, so its connector is a
# sum: `SchemeConnector[P, T]` holds either a plaintext connector `P` or a
# TLS connector `T`, fixed when it is made, and its streams are the matching
# sum, `SchemeStream`, which forwards every `IoStream` method to the stream
# it holds.
#
# Which one an arm dials is decided by its endpoint, once, when the arm is
# made: `s3_endpoint_is_plaintext` reads the scheme of `S3Config.endpoint`
# ("" is AWS's own endpoint, https), and `s3_connector_factory` hands back the
# plaintext factory only for an `http://` endpoint. An `https://` endpoint,
# or AWS's, gets the TLS factory, and any other scheme is refused, so a
# plaintext connection is made only when the endpoint itself says `http`.
# `s3_prod_arm` builds the production arm that way.
#
# No UnsafePointer, no wildcard origin; both sums are value fields.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_aws_core import AwsCredsSource, SystemAwsClock
from komira_http_client.client import HttpClientConfig
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector, IoStream, StreamIo
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_objectstore_s3 import S3Config, S3Fs, S3FsOptions


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


# The production S3 arm's connector: a kernel TCP dial, plaintext or under
# TLS (public CA roots, the server name from each request's host).
comptime S3ProdConnector = SchemeConnector[
    KernelTcpConnector, TlsConnector[KernelTcpConnector]
]


def s3_prod_tls_connector() raises -> S3ProdConnector:
    """The production connector for an `https` endpoint."""
    return S3ProdConnector(tls=build_unpinned_public_ca_tls_connector())


def s3_prod_plain_connector() raises -> S3ProdConnector:
    """The production connector for an `http` endpoint."""
    return S3ProdConnector(plain=KernelTcpConnector.new())


def _ascii_prefix_is(s: String, lower_prefix: StringLiteral) -> Bool:
    """Whether `s` starts with `lower_prefix` (lowercase ASCII), comparing
    ASCII letters case-insensitively."""
    var a = s.as_bytes()
    var b = lower_prefix.as_bytes()
    if len(a) < len(b):
        return False
    for i in range(len(b)):
        var c = Int(a[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        if c != Int(b[i]):
            return False
    return True


def s3_endpoint_is_plaintext(endpoint: String) raises -> Bool:
    """True for an `http://` endpoint, False for an `https://` one or for
    "" (AWS's own endpoint, which is https). The scheme is compared ASCII
    case-insensitively (RFC 3986 section 3.1), so `HTTP://` is plaintext and
    `HTTPS://` is TLS. Raises `fs_registry: an S3 endpoint must start with
    http:// or https://, got '<endpoint>'` for anything else."""
    if endpoint.byte_length() == 0 or _ascii_prefix_is(endpoint, "https://"):
        return False
    if _ascii_prefix_is(endpoint, "http://"):
        return True
    raise Error(
        "fs_registry: an S3 endpoint must start with http:// or https://, got '"
        + endpoint
        + "'"
    )


def s3_connector_factory[
    C: Connector
](
    endpoint: String,
    mk_plain: def () raises thin -> C,
    mk_tls: def () raises thin -> C,
) raises -> def () raises thin -> C:
    """`mk_plain` for an `http://` endpoint, else `mk_tls`; refuses any other
    scheme (`s3_endpoint_is_plaintext`)."""
    if s3_endpoint_is_plaintext(endpoint):
        return mk_plain
    return mk_tls


def s3_prod_arm[
    T: AwsCredsSource & Copyable
](
    var bucket: String,
    var config: S3Config,
    http_config: HttpClientConfig,
    var creds: T,
    options: S3FsOptions = S3FsOptions.standard(),
) raises -> S3Fs[S3ProdConnector, T, SystemAwsClock]:
    """The production S3 arm on `bucket`, dialing plaintext when
    `config.endpoint` is `http://` and TLS otherwise (module header).
    Dials nothing here."""
    var mk = s3_connector_factory[S3ProdConnector](
        config.endpoint, s3_prod_plain_connector, s3_prod_tls_connector
    )
    return S3Fs[S3ProdConnector, T, SystemAwsClock](
        bucket^, config^, mk, http_config, creds^, SystemAwsClock(), options
    )
