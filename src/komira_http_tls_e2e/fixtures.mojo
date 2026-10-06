# =============================================================================
# fixtures.mojo -- the TLS material and configurations the e2e legs share
# =============================================================================
#
# The certificates are komira_http_core's throwaway test fixtures, staged into
# each welded test's working directory at their source paths by `test_data`
# (see BUCK). The leaf names `localhost` and `127.0.0.1` and is signed by
# `root_ca.pem`; `smoke_cert.pem` is an unrelated self-signed CA, the trust
# anchor of a client that must NOT accept the leaf.
#
# The server configuration is the one an HTTPS server with HTTP/2 deploys: the
# leaf, TLS 1.3 preferences, ALPN `h2` first then `http/1.1`. The client
# connector trusts exactly one anchor (the OS store is wiped) and PINS its SNI,
# so a test chooses the name the client verifies independently of the address
# it dials.
# =============================================================================

from std.pathlib import Path

from komira_http_core.tls import TlsConfig
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import TlsConnector


comptime LEAF_CERT_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime LEAF_KEY_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime ROOT_CA_PATH = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"
comptime OTHER_CA_PATH = "src/komira_http_core/tests/fixtures/smoke_cert.pem"

# The handshake budget of every client connector here. Far above a loopback
# handshake (milliseconds) and far below the build action's patience, so a
# wedged handshake fails the leg with a named error instead of hanging it.
comptime CLIENT_HANDSHAKE_DEADLINE_US: Int64 = 10_000_000


def read_fixture(path: StaticString) raises -> String:
    """The text of a staged fixture file, read from the test's working
    directory."""
    return Path(String(path)).read_text()


def server_alpn_protocols() -> List[String]:
    """The ALPN list the e2e server advertises, in preference order: `h2`,
    then `http/1.1` (RFC 9113 section 3.2)."""
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    return alpn^


def server_tls_config() raises -> TlsConfig:
    """The server side: the fixture leaf and its key, TLS 1.3 preferences, and
    `server_alpn_protocols()`."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(read_fixture(LEAF_CERT_PATH), read_fixture(LEAF_KEY_PATH))
    config.set_alpn_protocols(server_alpn_protocols())
    return config^


def client_tls_connector(
    trust_anchor_path: StaticString,
    server_name: String,
    offer_h2: Bool,
) raises -> TlsConnector[KernelTcpConnector]:
    """A verifying client connector that trusts ONLY the certificate at
    `trust_anchor_path` and presents (and verifies) `server_name`.

    ALPN offers `http/1.1`, preceded by `h2` when `offer_h2`. The SNI is pinned,
    so the URL host (an IP literal in these tests) does not replace it."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.wipe_trust()
    config.add_trust_pem(read_fixture(trust_anchor_path))
    config.enable_verify_default()
    var alpn = List[String]()
    if offer_h2:
        alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    var connector = TlsConnector[KernelTcpConnector](
        config^, KernelTcpConnector.new(), VERIFY_PEER,
    )
    connector.set_server_name_for_next_connect(server_name)
    connector.set_handshake_deadline_us(CLIENT_HANDSHAKE_DEADLINE_US)
    return connector^
