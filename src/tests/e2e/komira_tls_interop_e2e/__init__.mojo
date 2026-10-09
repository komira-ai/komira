# komira_tls_interop_e2e: komira's TLS (s2n-tls under komira_http_core.tls)
# against real TLS peers, each a child process of the test: aws-lc's bssl
# tool built from the pinned archive, as `bssl s_server` and `bssl s_client`,
# and CPython's `ssl` module (OpenSSL) in the pinned interpreter, as
# cpython_peer.py's server and client.
#
# A test-only package. Its tests (BUCK) run under `./buck2 test`, given the
# bssl binary or the interpreter as a flag; its welded tests check the
# reading of bssl's report and of the CPython server's port on their own.
# The library holds the peer processes (children.mojo), the reading of what
# bssl prints (bssl.mojo), the CPython peer (cpython.mojo, cpython_peer.py),
# the fixtures and komira's configurations (fixtures.mojo), and komira's side
# of a connection (tls_io.mojo).

from .bssl import (
    BsslReport,
    is_tls13_suite,
    parse_report,
    standard_cipher_name,
    tls_version_name,
)
from .cpython import LISTENING, PEER_SCRIPT, listening_port, start_cpython_peer
from .children import PeerGroup, PeerOutcome, deadline_after_ms, past, tick
from .fixtures import (
    LEAF_CERT_PATH,
    LEAF_KEY_PATH,
    OTHER_CA_PATH,
    ROOT_CA_PATH,
    SERVER_NAME,
    client_tls_config,
    flag,
    read_fixture,
    scratch_file,
    server_tls_config,
)
from .tls_io import (
    Socket,
    accept_one,
    close_notify,
    connect_loopback,
    free_loopback_port,
    handshake,
    listen_loopback,
    local_port,
    read_until,
    send_all,
)
