"""Unit test for `S2N_BLOCKED_ON_*` → reactor INTEREST
mapping.

Tests `outcome_to_interest` and `outcome_to_conn_state` from
`komira_http.tls.handshake_state` against the contract:

  - S2N_BLOCKED_ON_READ  → INTEREST_READ
  - S2N_BLOCKED_ON_WRITE → INTEREST_WRITE
  - S2N_NOT_BLOCKED      → INTEREST_READ (post-handshake default)
  - S2N_FAILURE          → 0 (close, don't modify)

The s2n constants themselves are validated against the s2n.h header
values via the alias declarations in `ffi.mojo`. The reactor INTEREST
constants come from the existing `komira_async.reactor.completion_queue`
module (INTEREST_READ=1, INTEREST_WRITE=2).

No s2n FFI calls happen in this test — pure compile-time alias
verification + the mapping function tables. Sized `small` (no
external link to libs2n; no socketpair).
"""

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_http.tls import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    is_tls_handshake_state,
    outcome_to_conn_state,
    outcome_to_interest,
)


def test_outcome_to_interest_blocked_on_read() raises:
    """S2N_BLOCKED_ON_READ maps to INTEREST_READ."""
    var mask = outcome_to_interest(TLS_OUTCOME_BLOCKED_ON_READ)
    if mask != INTEREST_READ:
        raise Error(
            "outcome_to_interest(BLOCKED_ON_READ): expected INTEREST_READ ("
            + String(Int(INTEREST_READ)) + "), got " + String(Int(mask))
        )


def test_outcome_to_interest_blocked_on_write() raises:
    """S2N_BLOCKED_ON_WRITE maps to INTEREST_WRITE."""
    var mask = outcome_to_interest(TLS_OUTCOME_BLOCKED_ON_WRITE)
    if mask != INTEREST_WRITE:
        raise Error(
            "outcome_to_interest(BLOCKED_ON_WRITE): expected INTEREST_WRITE ("
            + String(Int(INTEREST_WRITE)) + "), got " + String(Int(mask))
        )


def test_outcome_to_interest_done() raises:
    """DONE maps to INTEREST_READ (post-handshake default; arms for
    application-data inbound)."""
    var mask = outcome_to_interest(TLS_OUTCOME_DONE)
    if mask != INTEREST_READ:
        raise Error(
            "outcome_to_interest(DONE): expected INTEREST_READ (post-"
            "handshake default), got " + String(Int(mask))
        )


def test_outcome_to_interest_error() raises:
    """ERROR maps to 0 (caller should close, not modify)."""
    var mask = outcome_to_interest(TLS_OUTCOME_ERROR)
    if mask != UInt8(0):
        raise Error(
            "outcome_to_interest(ERROR): expected 0 (close sentinel), got "
            + String(Int(mask))
        )


def test_outcome_to_conn_state_blocked_on_read() raises:
    """BLOCKED_ON_READ maps to CONN_STATE_TLS_HANDSHAKE_IN."""
    var state = outcome_to_conn_state(
        TLS_OUTCOME_BLOCKED_ON_READ, UInt8(0)
    )
    if state != CONN_STATE_TLS_HANDSHAKE_IN:
        raise Error(
            "outcome_to_conn_state(BLOCKED_ON_READ): expected "
            "CONN_STATE_TLS_HANDSHAKE_IN ("
            + String(Int(CONN_STATE_TLS_HANDSHAKE_IN))
            + "), got " + String(Int(state))
        )


def test_outcome_to_conn_state_blocked_on_write() raises:
    """BLOCKED_ON_WRITE maps to CONN_STATE_TLS_HANDSHAKE_OUT."""
    var state = outcome_to_conn_state(
        TLS_OUTCOME_BLOCKED_ON_WRITE, UInt8(0)
    )
    if state != CONN_STATE_TLS_HANDSHAKE_OUT:
        raise Error(
            "outcome_to_conn_state(BLOCKED_ON_WRITE): expected "
            "CONN_STATE_TLS_HANDSHAKE_OUT ("
            + String(Int(CONN_STATE_TLS_HANDSHAKE_OUT))
            + "), got " + String(Int(state))
        )


def test_outcome_to_conn_state_done() raises:
    """DONE maps to 0 (== CONN_STATE_READING; transition to plaintext path)."""
    var state = outcome_to_conn_state(TLS_OUTCOME_DONE, UInt8(0))
    if state != UInt8(0):
        raise Error(
            "outcome_to_conn_state(DONE): expected 0 (CONN_STATE_READING), "
            "got " + String(Int(state))
        )


def test_outcome_to_conn_state_error() raises:
    """ERROR maps to 255 (close sentinel)."""
    var state = outcome_to_conn_state(TLS_OUTCOME_ERROR, UInt8(0))
    if state != UInt8(255):
        raise Error(
            "outcome_to_conn_state(ERROR): expected 255 (close sentinel), "
            "got " + String(Int(state))
        )


def test_is_tls_handshake_state() raises:
    """is_tls_handshake_state recognizes only HANDSHAKE_IN/OUT."""
    if not is_tls_handshake_state(CONN_STATE_TLS_HANDSHAKE_IN):
        raise Error("is_tls_handshake_state(HANDSHAKE_IN): expected True")
    if not is_tls_handshake_state(CONN_STATE_TLS_HANDSHAKE_OUT):
        raise Error("is_tls_handshake_state(HANDSHAKE_OUT): expected True")
    # Plaintext CONN_STATE_READING (0) and CONN_STATE_WAITING_FOR_WRITABLE (1)
    # are NOT TLS handshake states.
    if is_tls_handshake_state(UInt8(0)):
        raise Error("is_tls_handshake_state(READING=0): expected False")
    if is_tls_handshake_state(UInt8(1)):
        raise Error(
            "is_tls_handshake_state(WAITING_FOR_WRITABLE=1): expected False"
        )


def test_state_constants_disjoint_from_plaintext() raises:
    """The TLS state constants must be disjoint from the plaintext
    range (0-1) to allow union-state-machine dispatch without
    re-numbering. HANDSHAKE_IN=16, HANDSHAKE_OUT=17."""
    if CONN_STATE_TLS_HANDSHAKE_IN <= UInt8(1):
        raise Error(
            "CONN_STATE_TLS_HANDSHAKE_IN ("
            + String(Int(CONN_STATE_TLS_HANDSHAKE_IN))
            + ") must be > 1 (above the plaintext CONN_STATE_READING="
            "0 and CONN_STATE_WAITING_FOR_WRITABLE=1 range)"
        )
    if CONN_STATE_TLS_HANDSHAKE_OUT <= UInt8(1):
        raise Error(
            "CONN_STATE_TLS_HANDSHAKE_OUT ("
            + String(Int(CONN_STATE_TLS_HANDSHAKE_OUT))
            + ") must be > 1"
        )


def main() raises:
    """Drive all 9 unit tests."""
    print("== unit: S2N_BLOCKED_ON_* → reactor mapping ==")
    test_outcome_to_interest_blocked_on_read()
    test_outcome_to_interest_blocked_on_write()
    test_outcome_to_interest_done()
    test_outcome_to_interest_error()
    test_outcome_to_conn_state_blocked_on_read()
    test_outcome_to_conn_state_blocked_on_write()
    test_outcome_to_conn_state_done()
    test_outcome_to_conn_state_error()
    test_is_tls_handshake_state()
    test_state_constants_disjoint_from_plaintext()
    print("== reactor-mapping unit PASSED (10 tests) ==")
