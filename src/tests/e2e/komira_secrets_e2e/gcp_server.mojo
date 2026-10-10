# =============================================================================
# gcp_server.mojo -- the GCP fake behind TLS, and the generated client at it
# =============================================================================
#
# `GcpFakeServer` is what the duet steps for the GCP tests: a plaintext
# komira_http_server `HttpServer` whose requests reach `FakeSecretManager`,
# and the `TlsFront` (tls_front.mojo) that terminates TLS for it with
# komira_http_core's fixture leaf. Both are stepped by the duet's server
# thread, the front after the server.
#
# `gcp_loopback_client` builds the generated `SecretManagerServiceClient`
# as an application builds it, over a verifying `TlsConnector` that trusts
# ONLY the fixture root (`root_ca.pem`; the OS store is wiped), offering
# ALPN http/1.1, and points it at `set_rest_endpoint(host, port, plaintext
# = False)`: https, to the front's port. The leaf names `localhost` and
# `127.0.0.1`:
#
#   * the global client sends to `localhost`, and its SNI is left to the
#     per-request dial host, so the name the front records is the one the
#     client chose;
#   * the regional client stands for `secretmanager.<location>.rep.
#     googleapis.com`, which a sandbox cannot resolve, and sends to
#     `127.0.0.1`, the other name the leaf carries, with the SNI pinned to
#     `localhost` (an IP literal is not a server name, RFC 6066 section 3).
#     The fake tells the two endpoints apart by the `Host` header.
#
# The certificates are staged into each test's working directory at their
# source paths by `test_data` (BUCK). `NoTokenSource` is a token source that
# has no credential to give: it answers an empty token.
# =============================================================================

from std.pathlib import Path

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource
from komira_gcp_secretmanager.service import SecretManagerServiceClient
from komira_http_client.client import HttpClient
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.tls import TlsConfig
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from .duet import ServeStep
from .gcp_fake import FakeSecretManager
from .gcp_store import GCP_REGION
from .tls_front import TlsFront

comptime LEAF_CERT_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime LEAF_KEY_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime ROOT_CA_PATH = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"

comptime GLOBAL_HOST = "localhost"
comptime REGIONAL_HOST = "127.0.0.1"
# The token the fake accepts. Made up; no service issued it.
comptime TEST_ACCESS_TOKEN = "ya29.e2e-loopback-not-a-real-token"
comptime OTHER_ACCESS_TOKEN = "ya29.e2e-loopback-some-other-token"

# One server poll waits at most this long. Short, because the front is
# stepped between polls and a TLS handshake takes several round trips.
comptime GCP_POLL_TIMEOUT_US: Int32 = 1_000
comptime LOOPBACK_REQUEST_TIMEOUT_US = 30_000_000
comptime CLIENT_HANDSHAKE_DEADLINE_US: Int64 = 10_000_000

comptime GcpConnector = TlsConnector[KernelTcpConnector]


def _fixture(path: StaticString) raises -> String:
    return Path(String(path)).read_text()


def front_tls_config() raises -> TlsConfig:
    """The fixture leaf and its key, TLS 1.3 preferences, ALPN http/1.1
    only (the server behind the front speaks HTTP/1.1)."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(_fixture(LEAF_CERT_PATH), _fixture(LEAF_KEY_PATH))
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


struct GcpFakeServer(ServeStep):
    """The fake on a plaintext server on 127.0.0.1, behind a TLS front on
    another port of 127.0.0.1; clients dial `port()`, the front's."""

    var server: HttpServer[NoopGrpcDispatch]
    var fake: FakeSecretManager
    var front: TlsFront

    def __init__(out self, var fake: FakeSecretManager) raises:
        self.server = HttpServer(
            config=HttpServerConfig.default_ephemeral(), router=Router()
        )
        self.fake = fake^
        self.front = TlsFront(front_tls_config(), self.server.local_port())

    def port(self) raises -> UInt16:
        return self.front.port()

    def step(mut self) raises:
        _ = self.server.serve_one_iteration_dispatch[
            FakeSecretManager, BlockingRuntime[NoopSink]
        ](self.fake, GCP_POLL_TIMEOUT_US)
        self.front.step()


def gcp_fake_server() raises -> GcpFakeServer:
    """The fake holding `TEST_ACCESS_TOKEN`, serving global secrets at
    `GLOBAL_HOST` and `GCP_REGION`'s at `REGIONAL_HOST`."""
    return GcpFakeServer(
        FakeSecretManager(
            String(TEST_ACCESS_TOKEN),
            String(GLOBAL_HOST),
            String(GCP_REGION),
            String(REGIONAL_HOST),
        )
    )


struct NoTokenSource(GcpTokenSource, Movable, Deinitable):
    """A token source with no credential: every token it gives is empty."""

    def __init__(out self):
        pass

    def access_token(mut self) raises -> String:
        return String("")


def _connector(pin_localhost: Bool) raises -> GcpConnector:
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.wipe_trust()
    config.add_trust_pem(_fixture(ROOT_CA_PATH))
    config.enable_verify_default()
    var alpn = List[String]()
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    var connector = GcpConnector(config^, KernelTcpConnector.new(), VERIFY_PEER)
    if pin_localhost:
        connector.set_server_name_for_next_connect(String(GLOBAL_HOST))
    connector.set_handshake_deadline_us(CLIENT_HANDSHAKE_DEADLINE_US)
    return connector^


def gcp_loopback_client[
    T: GcpTokenSource
](port: UInt16, host: String, var tokens: T) raises -> SecretManagerServiceClient[
    GcpConnector, T
]:
    """The generated client sending https to `host`:`port` over a verifying
    TLS connector that trusts only the fixture root. `REGIONAL_HOST` pins
    the SNI to `localhost` (see the module header); any other host is
    presented as the server name."""
    var client = SecretManagerServiceClient[GcpConnector, T](
        HttpClient[GcpConnector].with_request_timeout_us(
            _connector(host == REGIONAL_HOST), LOOPBACK_REQUEST_TIMEOUT_US
        ),
        tokens^,
    )
    client.set_rest_endpoint(host.copy(), port, plaintext=False)
    return client^
