# komira_tls_interop_e2e: komira's TLS (s2n-tls under komira_http_core.tls)
# against real TLS peers built from the pinned aws-lc: its bssl tool, as
# `bssl s_server` and `bssl s_client`, a child process of the test.
#
# A test-only package. Its tests (BUCK) run under `./buck2 test`, given the
# bssl binary as a flag; its welded test checks the reading of bssl's report
# on its own. The library holds the peer processes (children.mojo), the
# reading of what bssl prints (bssl.mojo), the fixtures and komira's
# configurations (fixtures.mojo), and komira's side of a connection
# (tls_io.mojo).

from .bssl import (
    BsslReport,
    is_tls13_suite,
    parse_report,
    standard_cipher_name,
    tls_version_name,
)
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
