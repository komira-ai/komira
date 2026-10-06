# komira_http_tls_e2e: a real komira_http_server `HttpServer` against a real
# komira_http_client `HttpClient` in one process: an HTTP/1.1 GET over TLS
# checked byte for byte, the ALPN pivot to h2 on both sides, a 4 MiB response
# flushed through the server's buffered-write path, and the client refusing an
# untrusted root and a wrong server name while the server goes on serving.
#
# A test-only package: those are its welded tests. The library holds what they
# share: the TLS fixtures and configurations (fixtures.mojo) and the runner that
# steps the server on one thread while the client runs on another (duet.mojo).

from .fixtures import (
    CLIENT_HANDSHAKE_DEADLINE_US,
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    OTHER_CA_PATH,
    ROOT_CA_PATH,
    client_tls_connector,
    read_fixture,
    server_alpn_protocols,
    server_tls_config,
)
from .duet import (
    ClientLeg,
    DispatchServeLoop,
    SERVE_POLL_TIMEOUT_US,
    ServeStep,
    TlsServeLoop,
    serve_while,
)
