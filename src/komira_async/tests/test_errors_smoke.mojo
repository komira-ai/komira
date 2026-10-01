# =============================================================================
# test_errors_smoke.mojo
# =============================================================================
# Smoke test for komira_async.errors.
# Verifies the closed-surface error types import
# correctly. Compilation-only signal; no behavior assertions.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.errors.io_error import (
    AsyncError,
    BroadcastSendError,
    CancelledError,
    ChannelClosed,
    IoError,
    TimeoutError,
    TryRecvError,
    TrySendError,
)


def test_async_error_construct() raises:
    """AsyncError construct + msg field round-trip."""
    var e = AsyncError(msg=String("test"))
    assert_equal(e.msg, String("test"))


def test_io_error_construct() raises:
    """IoError construct: fd + errno + msg fields."""
    var e = IoError(fd=Int32(3), errno=Int32(11), msg=String("EAGAIN"))
    assert_equal(Int(e.fd), 3)
    assert_equal(Int(e.errno), 11)


def test_timeout_error_construct() raises:
    """TimeoutError construct: op_id + dur_ns."""
    var e = TimeoutError(op_id=Int64(7), dur_ns=Int64(1_000_000_000))
    assert_equal(Int(e.op_id), 7)


def test_cancelled_error_construct() raises:
    """CancelledError construct: op_id + reason."""
    var e = CancelledError(op_id=Int64(0), reason=String(""))
    assert_equal(e.reason, String(""))


def test_channel_closed_construct() raises:
    """ChannelClosed construct: msg field."""
    var e = ChannelClosed(msg=String("receiver dropped"))
    assert_true(e.msg.byte_length() > 0)


def test_broadcast_send_error_construct() raises:
    """BroadcastSendError construct: kind discriminator."""
    var e = BroadcastSendError(kind=UInt8(0))
    assert_equal(Int(e.kind), 0)


def test_try_send_error_construct() raises:
    """TrySendError construct (NOT in 6-error closed surface count;
    nested-result enum payload)."""
    var e = TrySendError(kind=UInt8(0), msg=String("Full"))
    assert_equal(Int(e.kind), 0)


def test_try_recv_error_construct() raises:
    """TryRecvError construct (also not in 6-error count)."""
    var e = TryRecvError(kind=UInt8(1), msg=String("Closed"))
    assert_equal(Int(e.kind), 1)


def main() raises:
    test_async_error_construct()
    test_io_error_construct()
    test_timeout_error_construct()
    test_cancelled_error_construct()
    test_channel_closed_construct()
    test_broadcast_send_error_construct()
    test_try_send_error_construct()
    test_try_recv_error_construct()
    print("PASS komira_async.errors smoke")
