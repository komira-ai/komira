# =============================================================================
# src/komira_http_core/tls/handshake_state.mojo — TLS state machine + reactor glue
# =============================================================================
#
#
#
# Two responsibilities:
#
#   1. **L0 conn state-machine extensions.** The plaintext L0 state set
#      (`CONN_STATE_READING`, `CONN_STATE_WAITING_FOR_WRITABLE` —
#      `src/komira_http_server/connection.mojo:29-30`) gains two TLS
#      variants — `CONN_STATE_TLS_HANDSHAKE_IN` and
#      `CONN_STATE_TLS_HANDSHAKE_OUT`. These are LOCAL to the TLS
#      pipeline; the plaintext path is unchanged and is unaware of them.
#
#   2. **`S2N_BLOCKED_ON_*` → reactor INTEREST mapping.** s2n_negotiate
#      / send / recv / shutdown all return a 3-valued blocked-status
#      (NOT_BLOCKED / BLOCKED_ON_READ / BLOCKED_ON_WRITE; see
#      `s2n_shim.mojo` for the safe `TLS_OUTCOME_*` aliases). This module
#      provides the canonical reactor-INTEREST mapping helpers that
#      callers use after each TLS state-transition call.
#
# The reactor itself (`Reactor.modify` in `komira_async`) ALREADY accepts a new
# `INTEREST_READ | INTEREST_WRITE` bitmask and rewires kqueue/epoll
# filters atomically. There is NO API extension to `komira_async`. The
# mapping is local here.
# =============================================================================

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
)


# =============================================================================
# L0 conn-state-machine extensions for TLS
# =============================================================================
#
# the plaintext L0 state-machine ports gain
# CONN_STATE_TLS_HANDSHAKE_IN / CONN_STATE_TLS_HANDSHAKE_OUT variants for
# the handshake-pending arcs. Post-handshake the conn falls back into the
# plaintext CONN_STATE_READING / CONN_STATE_WAITING_FOR_WRITABLE
# variants, with the read/write path going through TlsConnection.send/recv
# instead of raw try_io_read/write.
#
# Numbering: starts at 16 to give a wide gap above the plaintext range
# (currently 0-1). Plaintext additions in can occupy 2-15 without
# colliding.

comptime CONN_STATE_TLS_HANDSHAKE_IN: UInt8 = 16
"""Handshake stalled on read — peer must send more bytes. The reactor
registration should be armed with INTEREST_READ; on EPOLLIN /
EVFILT_READ fire, call `TlsConnection.handshake()` again."""

comptime CONN_STATE_TLS_HANDSHAKE_OUT: UInt8 = 17
"""Handshake stalled on write — kernel send buffer is full or s2n
wants to push out a ClientHelloResponse / etc. Reactor should be
armed with INTEREST_WRITE; on EPOLLOUT / EVFILT_WRITE fire, re-call
`TlsConnection.handshake()`."""


# =============================================================================
# TLS_OUTCOME → reactor INTEREST mapping
# =============================================================================


@always_inline
def outcome_to_interest(outcome: UInt8) -> UInt8:
    """Map a `TLS_OUTCOME_*` value (returned by `TlsConnection.handshake/
    send/recv/shutdown`) to the reactor INTEREST bitmask the caller
    should arm before returning to the event loop.

    - `TLS_OUTCOME_BLOCKED_ON_READ`  → `INTEREST_READ`  (1)
    - `TLS_OUTCOME_BLOCKED_ON_WRITE` → `INTEREST_WRITE` (2)
    - `TLS_OUTCOME_DONE`             → `INTEREST_READ`  (1)
      (post-DONE, the next operation is usually a recv; arm READ to
      detect peer data + close-notify)
    - `TLS_OUTCOME_ERROR`            → `0` (caller should close, not modify)

    Returns 0 on ERROR so callers can branch on `mask == 0` to know
    "no reactor modify; close instead".
    """
    if outcome == TLS_OUTCOME_BLOCKED_ON_READ:
        return INTEREST_READ
    if outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
        return INTEREST_WRITE
    if outcome == TLS_OUTCOME_DONE:
        # Post-DONE default: arm for the next inbound application data
        # event. Callers that want to immediately send post-handshake
        # data may override to INTEREST_WRITE.
        return INTEREST_READ
    # TLS_OUTCOME_ERROR or unknown -> caller should close.
    return UInt8(0)


@always_inline
def outcome_to_conn_state(outcome: UInt8, prior_state: UInt8) -> UInt8:
    """Map a handshake outcome + the prior L0 state to the next L0 state.

    For TLS handshake transitions:
      - BLOCKED_ON_READ  → CONN_STATE_TLS_HANDSHAKE_IN
      - BLOCKED_ON_WRITE → CONN_STATE_TLS_HANDSHAKE_OUT
      - DONE             → returns 0 (sentinel: caller transitions to
                           plaintext CONN_STATE_READING, which is the
                           value 0 in connection.mojo:29; same numeric
                           value but the semantic transition is
                           "handshake-done → start reading plaintext")
      - ERROR            → 255 (sentinel: caller closes; not a real state)

    `prior_state` is currently unused but retained in the signature
    for forward compatibility with state machines that need history
    (e.g. shutdown-during-rekey paths).
    """
    _ = prior_state  # forward-compat; silence unused
    if outcome == TLS_OUTCOME_BLOCKED_ON_READ:
        return CONN_STATE_TLS_HANDSHAKE_IN
    if outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
        return CONN_STATE_TLS_HANDSHAKE_OUT
    if outcome == TLS_OUTCOME_DONE:
        return UInt8(0)  # == CONN_STATE_READING (plaintext path)
    return UInt8(255)  # close sentinel


@always_inline
def is_tls_handshake_state(state: UInt8) -> Bool:
    """True iff `state` is one of the TLS handshake variants. Used by
    the L0 ready-event dispatch to route HANDSHAKE_IN/OUT fires back
    to `TlsConnection.handshake()` instead of the plaintext read/write
    path.
    """
    return state == CONN_STATE_TLS_HANDSHAKE_IN or state == CONN_STATE_TLS_HANDSHAKE_OUT
