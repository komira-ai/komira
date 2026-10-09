# =============================================================================
# tests/test_live_row.mojo — the falsifier for `live.mojo`: the streamed row
#   line's exact bytes, and that `emit_live_row` has put them on fd 1 by the
#   time it returns.
# =============================================================================
#
# WHAT THIS PINS, AND WHY EACH ASSERTION EXISTS.
#
# ★ `test_live_row_line_is_marker_ordinal_then_row` compares the WHOLE line,
#   not a substring: marker, one space, the ordinal in decimal, `: `, then the
#   caller's rendered row unchanged. A dropped separator, a swapped order, or an
#   ordinal that is not the one passed in each changes the bytes. The marker
#   comes first for a reason, asserted on its own: a `[PASS] ...` row rendered
#   through the live line must not START with `[PASS]`, or a prefix-anchored
#   reader of the end-of-run report counts it twice.
#
# ★ `test_emit_live_row_is_on_fd1_when_it_returns` redirects fd 1 into a socket
#   pair, emits one row, and reads the socket without waiting while fd 1 still
#   points at it. The exact line, newline included, must already be there: a
#   row that is not on fd 1 when the call returns (not printed, printed to
#   another stream, held in a buffer of this process, or carrying another
#   ordinal) fails it.
#
#   It does NOT tell `flush=True` from `flush=False`. On the pinned Mojo
#   (1.0.0) a CPU `print` writes its bytes to the fd before it returns either
#   way; `flush` only adds an `fflush` of a C stdio stream that `print` does not
#   write through. Dropping the flag is a mutant no test can kill today.
#
# Hermetic: one socket pair owned by the test, closed on every path.
# =============================================================================

from std.ffi import external_call
from std.sys import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from kci_validator_rows.live import (
    LIVE_ROW_MARKER,
    emit_live_row,
    live_row_line,
)


comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1
comptime _MSG_DONTWAIT_LINUX: Int32 = 0x40
comptime _MSG_DONTWAIT_DARWIN: Int32 = 0x80


def _socketpair() -> SIMD[DType.int32, 2]:
    """An AF_UNIX stream pair, or (-1, -1)."""
    var fds = SIMD[DType.int32, 2](-1, -1)
    # SAFETY: socketpair(2) writes two int32 into this local; the pointer does
    # not outlive the call.
    var rc = external_call["socketpair", Int32](
        _AF_UNIX,
        _SOCK_STREAM,
        Int32(0),
        UnsafePointer(to=fds).bitcast[UInt8](),
    )
    if rc < 0:
        return SIMD[DType.int32, 2](-1, -1)
    return fds


def _drain(fd: Int32) -> String:
    """Every byte left on `fd`, read until end of stream.

    The caller has closed every write end, so `recv` returns 0 at the end
    rather than blocking."""
    var out = String()
    var buf = List[UInt8](capacity=256)
    for _ in range(256):
        buf.append(UInt8(0))
    for _ in range(64):
        # SAFETY: recv(2) writes at most 256 bytes into this local list during
        # the call only.
        var n = external_call["recv", Int](
            fd, buf.unsafe_ptr(), UInt64(256), Int32(0)
        )
        if n <= 0:
            break
        for i in range(n):
            out += chr(Int(buf[i]))
    return out


def test_live_row_line_is_marker_ordinal_then_row() raises:
    assert_equal(
        live_row_line(7, String("[PASS] livez_200 (the app answers)")),
        String("LIVE-ROW 7: [PASS] livez_200 (the app answers)"),
    )
    # A multi-digit ordinal is the number, not its last digit.
    assert_equal(
        live_row_line(12, String("[FAIL] unauth_401")),
        String("LIVE-ROW 12: [FAIL] unauth_401"),
    )
    # The rendered row is carried through even when empty.
    assert_equal(live_row_line(1, String()), String("LIVE-ROW 1: "))
    assert_equal(String(LIVE_ROW_MARKER), String("LIVE-ROW"))
    var line = live_row_line(3, String("[PASS] row_three"))
    assert_false(line.startswith("[PASS]"), line)
    assert_true(line.startswith(String(LIVE_ROW_MARKER)), line)


def test_emit_live_row_is_on_fd1_when_it_returns() raises:
    # Anything this process already buffered for stdout goes out now, to the
    # real fd 1, so the capture below holds only the emitted row.
    print("", end="", flush=True)
    var sv = _socketpair()
    assert_true(sv[0] >= 0, "socketpair failed")
    var saved = external_call["dup", Int32](Int32(1))
    if saved < Int32(0):
        _ = external_call["close", Int32](sv[1])
        _ = external_call["close", Int32](sv[0])
        raise Error("dup(1) failed: cannot capture stdout")
    _ = external_call["dup2", Int32](sv[1], Int32(1))
    emit_live_row(5, String("[PASS] cancel_mid_run"))
    # Read what reached the socket while fd 1 still points at it, without
    # waiting: the row must be there by the time the call returned.
    var flags = _MSG_DONTWAIT_DARWIN
    if CompilationTarget.is_linux():
        flags = _MSG_DONTWAIT_LINUX
    var buf = List[UInt8](capacity=256)
    for _ in range(256):
        buf.append(UInt8(0))
    # SAFETY: recv(2) writes at most 256 bytes into this local list during the
    # call only.
    var n = external_call["recv", Int](
        sv[0], buf.unsafe_ptr(), UInt64(256), flags
    )
    var got = String()
    for i in range(n if n > 0 else 0):
        got += chr(Int(buf[i]))
    _ = external_call["dup2", Int32](saved, Int32(1))
    _ = external_call["close", Int32](saved)
    _ = external_call["close", Int32](sv[1])
    got += _drain(sv[0])
    _ = external_call["close", Int32](sv[0])
    assert_equal(got, String("LIVE-ROW 5: [PASS] cancel_mid_run\n"))


def main() raises:
    test_live_row_line_is_marker_ordinal_then_row()
    test_emit_live_row_is_on_fd1_when_it_returns()
    print("test_live_row: ALL PASS")
