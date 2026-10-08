# =============================================================================
# src/komira_http_core/tls/__init__.mojo — TLS layer (L1) curated re-exports
# =============================================================================
#
#
#
# Public surface exposed by the TLS layer. The internal `ffi.mojo` is
# NOT re-exported here — only safe wrappers and the L0 state-machine
# integration constants/helpers.
#
# Exports:
#   - `TlsConfig`     — per-server cert + ALPN
#   - `TlsConnection` — per-conn TLS state
#   - `PeerKeyUpdate` / `KeyUpdateCounts` — TLS 1.3 key update values
#   - `TLS_OUTCOME_*` — 3-state handshake/IO result enum
#   - `CONN_STATE_TLS_*` — L0 state-machine variants (extends transport)
#   - `outcome_to_interest` / `outcome_to_conn_state` — reactor glue
#
# `tls_init` / `last_s2n_errno` / `s2n_strerror_message` are also
# re-exported for advanced use (error reporting paths).
# the `tls_init` ctor is called lazily by `TlsConfig.__init__` so most
# callers never touch it directly.
# =============================================================================

from .conn import (
    CONN_STATE_CLOSED,
    CONN_STATE_READING,
    TlsStream,
)
from .handshake_state import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    is_tls_handshake_state,
    outcome_to_conn_state,
    outcome_to_interest,
)
from .key_update import KeyUpdateCounts, PeerKeyUpdate
from .s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TLS_VERSION_TLS12,
    TLS_VERSION_TLS13,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)
