# =============================================================================
# Tests for OwnedFd -- RAII POSIX file descriptor wrapper
# =============================================================================

from std.ffi import external_call
from komira_libc.owned_fd import OwnedFd


def _open_devnull() -> Int32:
    """Open /dev/null read-only via fopen+fileno, return raw fd."""
    var path = String("/dev/null")
    var mode = String("r")
    var fp = external_call["fopen", Int64](
        path.as_c_string_slice().unsafe_ptr(),
        mode.as_c_string_slice().unsafe_ptr(),
    )
    if fp == 0:
        return Int32(-1)
    return external_call["fileno", Int32](fp)


def _fd_is_open(fd: Int32) -> Bool:
    """Check if a raw fd is still open via fcntl(fd, F_GETFD)."""
    # F_GETFD = 1 on both macOS and Linux.
    var result = external_call["fcntl", Int32](fd, Int32(1))
    return result >= Int32(0)


def assert_true(cond: Bool, msg: String = "assertion failed") raises:
    if not cond:
        raise Error(msg)


def assert_false(cond: Bool, msg: String = "assertion failed") raises:
    if cond:
        raise Error(msg)


def assert_equal(a: Int, b: Int, msg: String = "not equal") raises:
    if a != b:
        raise Error(msg + ": " + String(a) + " != " + String(b))


def test_create_valid() raises:
    """OwnedFd.from_raw with a real fd is valid."""
    var raw = _open_devnull()
    assert_true(raw >= Int32(0), "failed to open /dev/null")
    var owned = OwnedFd.from_raw(raw)
    assert_true(owned.is_valid(), "OwnedFd should be valid for fd >= 0")
    assert_equal(Int(owned.raw()), Int(raw), "raw() should return the original fd")


def test_create_invalid() raises:
    """OwnedFd.from_raw(-1) is not valid."""
    var owned = OwnedFd.from_raw(Int32(-1))
    assert_false(owned.is_valid(), "OwnedFd(-1) should not be valid")


def test_move_transfers_ownership() raises:
    """After move, the destination owns the fd and the source is consumed."""
    var raw = _open_devnull()
    assert_true(raw >= Int32(0), "failed to open /dev/null")
    var a = OwnedFd.from_raw(raw)
    var b = a^
    assert_true(b.is_valid(), "moved-to OwnedFd should be valid")
    assert_equal(Int(b.raw()), Int(raw), "moved-to should hold the original fd")
    # NOTE: We do not test _fd_is_open(raw) here because the move
    # transfer is an implementation detail of OwnedPointer. The key
    # invariant is that b.raw() == raw and b.is_valid() == True.


def test_drop_closes_fd() raises:
    """When an OwnedFd is dropped, the fd is closed."""
    var raw = _open_devnull()
    assert_true(raw >= Int32(0), "failed to open /dev/null")
    assert_true(_fd_is_open(raw), "fd should be open right after creation")

    # Create and immediately drop the OwnedFd.
    _ = OwnedFd.from_raw(raw)

    # After drop, the fd should be closed.
    assert_false(_fd_is_open(raw), "fd should be closed after OwnedFd drop")


def test_drop_invalid_fd_is_noop() raises:
    """Dropping an OwnedFd(-1) does not crash."""
    _ = OwnedFd.from_raw(Int32(-1))
    # If we get here without a crash, the test passes.


def main() raises:
    test_create_valid()
    test_create_invalid()
    test_move_transfers_ownership()
    test_drop_closes_fd()
    test_drop_invalid_fd_is_noop()
    print("test_owned_fd: 5/5 PASS")
