"""L1 TLS handshake state machine unit tests.

Drives the TlsStream type's handshake state-machine without a real
client peer:

  1. Construct TlsStream(config, fd) — initial state should be
     CONN_STATE_TLS_HANDSHAKE_IN (server waits for ClientHello).
  2. drive_handshake() on a socketpair fd with no peer driving the
     handshake → outcome should be BLOCKED_ON_READ; interest mask
     INTEREST_READ; next_state CONN_STATE_TLS_HANDSHAKE_IN.
  3. drive_handshake() again with the same conditions → idempotent
     (still BLOCKED_ON_READ).
  4. handshake_done() should remain False until a real peer drives DONE.
  5. fd() returns the bound fd.

Real cross-peer handshake-to-DONE is exercised by the client-against-
server tests (test_L1_tls_client_handshake_against_test_root.mojo,
test_L2_https_verify_pass.mojo). This unit-level test focuses on the state-machine
WIRING — verifying that the public TlsStream API surfaces the right
outcome and reactor INTEREST mapping for the state-machine arcs the
HttpServer accept loop depends on.
"""

from std.ffi import external_call

from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    INTEREST_WRITE,
)
from komira_http.tls import (
    CONN_STATE_CLOSED,
    CONN_STATE_READING,
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsStream,
    is_tls_handshake_state,
    tls_init,
)
from std.pathlib import Path


# -----------------------------------------------------------------------------
# Fixture loader (matches the smoke test pattern)
# -----------------------------------------------------------------------------

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1


def _read_leaf_cert() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_cert.pem").read_text()


def _read_leaf_key() raises -> String:
    return Path("src/komira_http/tests/fixtures/tls/leaf_key.pem").read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    """Get a connected fd pair via libc socketpair(AF_UNIX, SOCK_STREAM)."""
    var sv = Array[Int32, 2](fill=Int32(-1))
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr,
    )
    if rc != Int32(0):
        raise Error("socketpair() failed")
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd < 0:
        return
    var _rc = external_call["close", Int32](fd)


def _build_test_config() raises -> TlsConfig:
    """Build a TlsConfig with the checked-in test-CA leaf cert + key."""
    var config = TlsConfig()
    config.load_cert(_read_leaf_cert(), _read_leaf_key())
    var protocols = List[String]()
    protocols.append(String("http/1.1"))
    config.set_alpn_protocols(protocols)
    return config^


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_tls_stream_initial_state() raises:
    """A fresh TlsStream should be in CONN_STATE_TLS_HANDSHAKE_IN with
    handshake_done() == False."""
    print("  test_tls_stream_initial_state...")
    var config = _build_test_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    try:
        var stream = TlsStream(config, server_fd)
        if stream.state() != CONN_STATE_TLS_HANDSHAKE_IN:
            raise Error(
                "expected CONN_STATE_TLS_HANDSHAKE_IN, got "
                + String(Int(stream.state()))
            )
        if stream.handshake_done():
            raise Error("expected handshake_done() == False")
        if stream.fd() != server_fd:
            raise Error(
                "expected fd() == " + String(Int(server_fd))
                + ", got " + String(Int(stream.fd()))
            )
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    print("    OK")


def test_drive_handshake_blocks_on_read() raises:
    """With a non-blocking fd and no peer driving the handshake,
    drive_handshake() should return (BLOCKED_ON_READ, INTEREST_READ,
    CONN_STATE_TLS_HANDSHAKE_IN). The handshake-done flag stays False.
    """
    print("  test_drive_handshake_blocks_on_read...")
    var config = _build_test_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    # Set fds non-blocking so s2n_negotiate returns BLOCKED instead of
    # blocking forever on read().
    var _rc1 = external_call["komira_fcntl_set_nonblock", Int32](server_fd)
    var _rc2 = external_call["komira_fcntl_set_nonblock", Int32](client_fd)
    try:
        var stream = TlsStream(config, server_fd)
        var hs = stream.drive_handshake()
        var outcome = hs[0]
        var mask = hs[1]
        var next_state = hs[2]
        if outcome != TLS_OUTCOME_BLOCKED_ON_READ:
            raise Error(
                "expected BLOCKED_ON_READ, got " + String(Int(outcome))
            )
        if mask != INTEREST_READ:
            raise Error(
                "expected INTEREST_READ mask, got " + String(Int(mask))
            )
        if next_state != CONN_STATE_TLS_HANDSHAKE_IN:
            raise Error(
                "expected next_state TLS_HANDSHAKE_IN, got "
                + String(Int(next_state))
            )
        if stream.handshake_done():
            raise Error("handshake should not be done yet")
        if stream.state() != CONN_STATE_TLS_HANDSHAKE_IN:
            raise Error("state should be TLS_HANDSHAKE_IN")
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    print("    OK")


def test_drive_handshake_idempotent_blocked() raises:
    """Calling drive_handshake() twice when no peer drives the
    handshake should return BLOCKED_ON_READ both times. State doesn't
    leak forward through repeated BLOCKED calls."""
    print("  test_drive_handshake_idempotent_blocked...")
    var config = _build_test_config()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    var _rc1 = external_call["komira_fcntl_set_nonblock", Int32](server_fd)
    var _rc2 = external_call["komira_fcntl_set_nonblock", Int32](client_fd)
    try:
        var stream = TlsStream(config, server_fd)
        var hs1 = stream.drive_handshake()
        var hs2 = stream.drive_handshake()
        if hs1[0] != TLS_OUTCOME_BLOCKED_ON_READ:
            raise Error("first call: expected BLOCKED_ON_READ")
        if hs2[0] != TLS_OUTCOME_BLOCKED_ON_READ:
            raise Error("second call: expected BLOCKED_ON_READ")
        if hs1[2] != hs2[2]:
            raise Error("next_state diverged across idempotent calls")
        if stream.handshake_done():
            raise Error("handshake should still not be done")
    finally:
        _close_fd(server_fd)
        _close_fd(client_fd)
    print("    OK")


def test_is_tls_handshake_state_predicate() raises:
    """The is_tls_handshake_state() predicate identifies TLS-handshake
    states correctly + rejects plaintext states."""
    print("  test_is_tls_handshake_state_predicate...")
    if not is_tls_handshake_state(CONN_STATE_TLS_HANDSHAKE_IN):
        raise Error("HANDSHAKE_IN should be a handshake state")
    if not is_tls_handshake_state(CONN_STATE_TLS_HANDSHAKE_OUT):
        raise Error("HANDSHAKE_OUT should be a handshake state")
    if is_tls_handshake_state(CONN_STATE_READING):
        raise Error("READING should not be a handshake state")
    if is_tls_handshake_state(CONN_STATE_CLOSED):
        raise Error("CLOSED should not be a handshake state")
    print("    OK")


def test_outcome_to_state_alphabet() raises:
    """The handshake_state.outcome_to_conn_state helper maps the 4
    TLS_OUTCOME_* values to the 4 conn-state-machine variants we
    depend on."""
    print("  test_outcome_to_state_alphabet...")
    # The mapping is exercised inside drive_handshake; here we just
    # smoke-test the integer alphabet for the 4 outcomes.
    if TLS_OUTCOME_DONE == TLS_OUTCOME_BLOCKED_ON_READ:
        raise Error("outcome alphabet collision")
    if TLS_OUTCOME_DONE == TLS_OUTCOME_BLOCKED_ON_WRITE:
        raise Error("outcome alphabet collision")
    if TLS_OUTCOME_DONE == TLS_OUTCOME_ERROR:
        raise Error("outcome alphabet collision")
    if TLS_OUTCOME_BLOCKED_ON_READ == TLS_OUTCOME_BLOCKED_ON_WRITE:
        raise Error("outcome alphabet collision")
    if INTEREST_READ == INTEREST_WRITE:
        raise Error("INTEREST alphabet collision")
    print("    OK")


def main() raises:
    print("== L1 TLS handshake ==")
    tls_init()
    test_tls_stream_initial_state()
    test_drive_handshake_blocks_on_read()
    test_drive_handshake_idempotent_blocked()
    test_is_tls_handshake_state_predicate()
    test_outcome_to_state_alphabet()
    print("== L1 TLS handshake PASSED (5 tests) ==")
