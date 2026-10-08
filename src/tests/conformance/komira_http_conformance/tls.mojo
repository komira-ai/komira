# =============================================================================
# tls.mojo -- the TLS material of the conformance run
# =============================================================================
#
# The server's HTTP/2 runs only over TLS, chosen by ALPN (RFC 9113 section
# 3.2); it has no cleartext h2. The certificates are komira_http_core's
# throwaway test fixtures, staged into the test's working directory at their
# source paths (see BUCK). The leaf names `localhost` and `127.0.0.1` and is
# signed by `root_ca.pem`. h2spec does not verify it (`-k`); the
# komira_http_client request after the suite does, against that root alone.
# =============================================================================

from std.pathlib import Path

from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import TlsConnector
from komira_http_core.tls import TlsConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector


comptime LEAF_CERT_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime LEAF_KEY_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime ROOT_CA_PATH = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"

# The client's handshake budget: far above a loopback handshake and far below
# the build action's patience.
comptime CLIENT_HANDSHAKE_DEADLINE_US: Int64 = 10_000_000


def _fixture(path: StaticString) raises -> String:
    return Path(String(path)).read_text()


def server_tls_config() raises -> TlsConfig:
    """The fixture leaf and its key, TLS 1.3 preferences, ALPN `h2` then
    `http/1.1`: the configuration an HTTPS server with HTTP/2 deploys."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(_fixture(LEAF_CERT_PATH), _fixture(LEAF_KEY_PATH))
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def client_tls_connector() raises -> TlsConnector[KernelTcpConnector]:
    """A verifying client connector trusting only the fixture root, presenting
    and verifying `localhost`, offering ALPN `h2` then `http/1.1`."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.wipe_trust()
    config.add_trust_pem(_fixture(ROOT_CA_PATH))
    config.enable_verify_default()
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_PEER,
    )
    connector.set_server_name_for_next_connect(String("localhost"))
    connector.set_handshake_deadline_us(CLIENT_HANDSHAKE_DEADLINE_US)
    return connector^
