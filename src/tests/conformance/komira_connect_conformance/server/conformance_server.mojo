# =============================================================================
# conformance_server.mojo -- the Connect conformance suite's server-under-test
# =============================================================================
#
# The program `connectconformance --mode server` starts once per server
# configuration (protocol, HTTP version, TLS), as the suite's
# testing_servers.md describes:
#
#   1. read one size-delimited ServerCompatRequest from stdin (a 4-byte
#      big-endian length, then the message; the runner then closes stdin);
#   2. start a komira_http_server HttpServer[ConnectService] serving the
#      ConformanceService (service.mojo) on 127.0.0.1, an ephemeral port,
#      over TLS with the certificate and key the request carries, ALPN `h2`
#      then `http/1.1`;
#   3. write one size-delimited ServerCompatResponse to stdout: host
#      127.0.0.1, the port, and the request's certificate (which the
#      reference client then trusts);
#   4. step the serve loop until the runner stops it (SIGTERM).
#
# The server serves HTTP/2 over TLS only (komira_http_server routes RPCs to a
# ConnectService on that path alone; it has no cleartext h2), so a request
# without TLS is refused on stderr and the program exits non-zero; the suite
# config asks for none. Diagnostics go to stderr, which the runner relays; stdout carries the
# response alone.
# =============================================================================

from std.io import FileDescriptor

from komira_connect import ConnectService
from komira_http_core.tls import TlsConfig, tls_init
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from service import conformance_service
from wire import decode_compat_request, encode_compat_response

comptime _STDERR: FileDescriptor = FileDescriptor(2)
comptime _SERVE_POLL_TIMEOUT_US: Int32 = 100_000


def _read_delimited_stdin() raises -> List[UInt8]:
    """The one size-delimited message on stdin."""
    var raw: List[UInt8]
    with open("/dev/stdin", "r") as f:
        raw = f.read_bytes()
    if len(raw) < 4:
        raise Error("stdin held " + String(len(raw)) + " bytes, fewer than the 4-byte size prefix")
    var n = (Int(raw[0]) << 24) | (Int(raw[1]) << 16) | (Int(raw[2]) << 8) | Int(raw[3])
    if n != len(raw) - 4:
        raise Error(
            "the size prefix says " + String(n) + " bytes; stdin held "
            + String(len(raw) - 4) + " after it"
        )
    return List[UInt8](raw[4:])


def _write_delimited_stdout(message: List[UInt8]) raises:
    var n = len(message)
    var out = List[UInt8](capacity=n + 4)
    out.append(UInt8((n >> 24) & 0xFF))
    out.append(UInt8((n >> 16) & 0xFF))
    out.append(UInt8((n >> 8) & 0xFF))
    out.append(UInt8(n & 0xFF))
    out.extend(Span(message))
    var stdout = FileDescriptor(1)
    stdout.write_bytes(Span(out))


def _tls_config(cert_pem: String, key_pem: String) raises -> TlsConfig:
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(cert_pem, key_pem)
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def main() raises:
    tls_init()
    var req = decode_compat_request(_read_delimited_stdin())
    print(
        "conformance_server: protocol " + String(req.protocol) + ", HTTP version "
        + String(req.http_version) + ", TLS " + String(req.use_tls)
        + ", client certificates " + String(req.has_client_tls_cert),
        file=_STDERR,
    )
    if not req.use_tls or req.cert_pem.byte_length() == 0:
        print(
            "conformance_server: refused: this server serves RPCs over TLS (HTTP/2 by ALPN) only",
            file=_STDERR,
        )
        raise Error("no TLS requested")
    var server = HttpServer[ConnectService](
        config=HttpServerConfig.default_ephemeral(),
        router=Router(),
        tls_config=_tls_config(req.cert_pem, req.key_pem),
        grpc=conformance_service(),
    )
    var port = server.local_port()
    _write_delimited_stdout(encode_compat_response(String("127.0.0.1"), port, req.cert_pem))
    print("conformance_server: serving on 127.0.0.1:" + String(Int(port)), file=_STDERR)
    while True:
        _ = server.serve_one_iteration(_SERVE_POLL_TIMEOUT_US)
