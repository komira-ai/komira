# =============================================================================
# test_fd_write_all_clamps_per_call_length.mojo
# =============================================================================
#
# ★ THE ORACLE IS THE KERNEL'S OWN RECORD OF THE LENGTH ARGUMENT, NOT A MOCK.
#
# The defect under test is not "the bytes come out wrong" — a loop that asks
# `write(2)` for `total - off` is byte-correct for every payload it can
# finish. The defect is the LENGTH `write(2)` IS ASKED FOR: `total - off` on
# the first call is the whole payload, and macOS refuses `nbyte > INT_MAX`
# outright (-1 / EINVAL, ZERO bytes written) while linux caps the same call at
# `0x7ffff000` and returns a partial write. So a >3 GB result written to
# stdout fails on darwin with every byte unwritten, while the identical code
# is green on linux.
#
# So an assertion about the OUTPUT BYTES cannot see this, and neither can a
# >2 GiB test on linux — it passes with and without the fix. What CAN see it is
# a real file descriptor that PRESERVES MESSAGE BOUNDARIES: an `AF_UNIX`
# `SOCK_DGRAM` socketpair turns each `write(2)` into exactly one datagram, so
# reading the datagrams back reports the length of every call the function made.
# Real fd, real syscalls, no seam and no stub — the kernel is the witness.
#
# ⚠ THE RECEIVE BUFFER IS DELIBERATELY LARGER THAN THE WHOLE PAYLOAD. `recv`
# TRUNCATES a datagram to the buffer it is given, so receiving into a
# `max_call_bytes`-sized buffer would report an oversized call as exactly
# `max_call_bytes` and turn this test into a guaranteed pass — a checker whose
# elements go false when the subject shrinks.
#
# ⚠ THE >2 GiB LEG lives in `test_large_writes.mojo` (a manual target). It is
# NOT the falsifier: on linux it is green with the clamp and green without it,
# because linux short-writes instead of refusing. Its value is that it drives a
# genuinely >INT_MAX payload through the REAL function against a REAL fd.
#
# MUTATIONS THAT TURN THIS FILE RED.
#
# ★ Deleting the clamp in `fd_write_all.mojo` (`var request = remaining`)
#   reds two legs on linux:
#
#     FAIL test_clamp_is_the_kernel_visible_call_length
#       AssertionError: `left == right` comparison failed:
#          left: 1
#         right: 5
#         reason: number of write(2) calls the kernel observed (1 means
#                 UNCLAMPED)
#     FAIL test_exact_multiple_of_the_clamp_makes_no_empty_final_call
#          left: 1  right: 3
#
#   Restoring the clamp returns every leg to PASS.
#
# The others are REASONED, not run, and are listed so the next reader knows
# which leg is aimed at what:
#   * clamp to `max_call_bytes` unconditionally instead of taking the min — the
#     sub-clamp leg sees a 4096-byte datagram for a 700-byte payload.
#   * `off += Int(n)` -> `off += request` — the byte-identity assertions diverge.
#   * `base + off` -> `base` — likewise (which is why `_payload` is a
#     sequence and not a constant fill).
#   * drop the `max_call_bytes <= 0` refusal — the refusal leg spins instead of
#     raising, which the suite reports as a timeout rather than a pass.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.io.fd_write_all import write_all_fd, FD_WRITE_MAX_CALL_BYTES


# =============================================================================
# §A — the socketpair rig. One datagram per `write(2)`, read back verbatim.
# =============================================================================

comptime _AF_UNIX: Int32 = Int32(1)
comptime _SOCK_DGRAM: Int32 = Int32(2)

# Big enough that nothing in this file can fill the socket buffer and block.
comptime _SOCK_BUF_BYTES: Int32 = Int32(1024 * 1024)

# Larger than every payload below, so an OVERSIZED datagram arrives whole
# instead of silently truncated to the size we were hoping for.
comptime _RECV_CAP: Int = 65536


@always_inline
def _at_fdcwd() -> Int32:
    """-2 on Darwin, -100 on Linux. POSIX mandates no value; the wrong one makes
    every relative-path `openat(2)` fail with EBADF. Same constant, same reason,
    as `posix_io.mojo:_at_fdcwd`."""
    comptime if CompilationTarget.is_macos():
        return Int32(-2)
    else:
        return Int32(-100)


@always_inline
def _sol_socket() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0xFFFF)
    else:
        return Int32(1)


@always_inline
def _so_sndbuf() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x1001)
    else:
        return Int32(7)


@always_inline
def _so_rcvbuf() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x1002)
    else:
        return Int32(8)


def _set_buf(fd: Int32, optname: Int32) raises:
    """SAFETY: `val` is a stack local; `setsockopt(2)` reads 4 bytes out of it
    synchronously and retains nothing. The pointer never leaves this helper."""
    var val = Int32(_SOCK_BUF_BYTES)
    var rc = external_call["setsockopt", Int32](
        fd,
        _sol_socket(),
        optname,
        UnsafePointer(to=val).bitcast[UInt8](),
        UInt32(4),
    )
    if rc < 0:
        raise Error(
            "setsockopt(optname="
            + String(optname)
            + ") failed; the rig cannot guarantee a non-blocking send"
        )


def _dgram_pair() raises -> Array[Int32, 2]:
    """A connected AF_UNIX datagram socketpair, both ends non-blocking and
    generously buffered.

    Non-blocking is not an optimisation: it is what makes a rig failure show up
    as a RAISE instead of a hang. A blocked `write(2)` inside `write_all_fd`
    would look like a slow test, and this file is a build gate.

    SAFETY: `pair` is a stack local; `socketpair(2)` writes two ints into it and
    does not retain the pointer. Confined to this helper.
    """
    var pair = Array[Int32, 2](fill=Int32(-1))
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_DGRAM, Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair(AF_UNIX, SOCK_DGRAM) failed")
    _set_buf(pair[0], _so_sndbuf())
    _set_buf(pair[1], _so_rcvbuf())
    _ = external_call["komira_fcntl_set_nonblock", Int32](pair[0])
    _ = external_call["komira_fcntl_set_nonblock", Int32](pair[1])
    return pair^


def _close(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _drain(fd: Int32, mut lengths: List[Int], mut bytes_out: List[UInt8]):
    """Receive every queued datagram. Appends one entry to `lengths` per
    `write(2)` the writer made, and every received byte to `bytes_out`.

    SAFETY: `scratch` is a stack local; `recv(2)` copies into it and retains
    nothing. The pointer is confined to this helper.
    """
    var scratch = Array[UInt8, _RECV_CAP](fill=UInt8(0))
    # A cap, so a rig that never reports "empty" fails the count assertion
    # rather than spinning forever.
    for _attempt in range(4096):
        var n = external_call["recv", Int](
            fd, scratch.unsafe_ptr(), UInt(_RECV_CAP), Int32(0)
        )
        if n <= 0:
            return
        lengths.append(Int(n))
        for i in range(Int(n)):
            bytes_out.append(scratch[i])


def _payload(n: Int) -> List[UInt8]:
    """Deterministic non-constant bytes — a constant fill would let a loop that
    re-sends the FIRST chunk every time pass the byte-identity assertion."""
    var out = List[UInt8]()
    var x = UInt32(0x1234_5678)
    for _i in range(n):
        x = x * UInt32(1664525) + UInt32(1013904223)
        out.append(UInt8((x >> UInt32(16)) & UInt32(0xFF)))
    return out^


def _write_and_observe(
    payload: List[UInt8],
    max_call_bytes: Int,
    mut lengths: List[Int],
    mut got: List[UInt8],
) raises -> Int:
    """Drive `write_all_fd` at `max_call_bytes`, fill `lengths` with the length
    of every `write(2)` call the kernel observed and `got` with the bytes that
    came back out, and return what the function claims it wrote."""
    # ★ THE TRUNCATION TRAP, CLOSED BY ARITHMETIC AND NOT BY A COMMENT.
    # `recv` truncates a datagram to the buffer it is given. If a payload ever
    # grew past `_RECV_CAP`, an UNCLAMPED write would be reported as a
    # `_RECV_CAP`-byte call and every `<= max_call_bytes` assertion below would
    # pass on the strength of the receive buffer rather than the clamp. Refuse
    # instead: the rig must be able to SEE a call bigger than it wants.
    if len(payload) >= _RECV_CAP:
        raise Error(
            "rig misuse: a "
            + String(len(payload))
            + "-byte payload can produce a datagram this rig's "
            + String(_RECV_CAP)
            + "-byte receive buffer would TRUNCATE, which would make every"
            " per-call-length assertion vacuous. Raise _RECV_CAP or shrink the"
            " payload."
        )
    var pair = _dgram_pair()
    var claimed = 0
    try:
        claimed = write_all_fd(
            pair[0], Span(payload), String("test"), max_call_bytes
        )
        _drain(pair[1], lengths, got)
    except e:
        _close(pair[0])
        _close(pair[1])
        raise e
    _close(pair[0])
    _close(pair[1])
    return claimed


def _assert_bytes_equal(
    expected: List[UInt8], got: List[UInt8], what: String
) raises:
    assert_equal(len(got), len(expected), what + ": length")
    for i in range(len(expected)):
        if got[i] != expected[i]:
            raise Error(
                what
                + ": byte "
                + String(i)
                + " is "
                + String(Int(got[i]))
                + ", expected "
                + String(Int(expected[i]))
            )


# =============================================================================
# §B — THE FALSIFIER. Remove the clamp and this test fails.
# =============================================================================


def test_clamp_is_the_kernel_visible_call_length() raises:
    """4233 bytes at a 1024-byte clamp is FIVE `write(2)` calls, and the kernel
    says so. Unclamped it is ONE call of 4233 — the exact shape that is -1 /
    EINVAL on darwin once the number passes INT_MAX."""
    var payload = _payload(4233)
    var lengths = List[Int]()
    var got = List[UInt8]()
    var claimed = _write_and_observe(payload, 1024, lengths, got)

    assert_equal(claimed, 4233, "write_all_fd's own return")
    assert_equal(
        len(lengths),
        5,
        "number of write(2) calls the kernel observed (1 means UNCLAMPED)",
    )
    assert_equal(lengths[0], 1024, "call 0 length")
    assert_equal(lengths[1], 1024, "call 1 length")
    assert_equal(lengths[2], 1024, "call 2 length")
    assert_equal(lengths[3], 1024, "call 3 length")
    assert_equal(lengths[4], 137, "call 4 length (the tail, NOT a full chunk)")
    for i in range(len(lengths)):
        assert_true(
            lengths[i] <= 1024,
            "call " + String(i) + " exceeded the clamp",
        )
    _assert_bytes_equal(payload, got, "clamped multi-call payload")


def test_exact_multiple_of_the_clamp_makes_no_empty_final_call() raises:
    """1536 at 512 is three calls, not four — an off-by-one in the loop that
    issued a zero-length final call would show up as a fourth datagram."""
    var payload = _payload(1536)
    var lengths = List[Int]()
    var got = List[UInt8]()
    var claimed = _write_and_observe(payload, 512, lengths, got)
    assert_equal(claimed, 1536)
    assert_equal(len(lengths), 3, "three calls, no zero-length tail")
    assert_equal(lengths[0], 512)
    assert_equal(lengths[1], 512)
    assert_equal(lengths[2], 512)
    _assert_bytes_equal(payload, got, "exact-multiple payload")


def test_payload_below_the_clamp_is_one_call() raises:
    """The clamp must not FRAGMENT a payload that already fits. A `request`
    hard-wired to `max_call_bytes` would send 4096 bytes for a 700-byte
    payload — reading 4096 bytes of adjacent memory off the end of the buffer."""
    var payload = _payload(700)
    var lengths = List[Int]()
    var got = List[UInt8]()
    var claimed = _write_and_observe(payload, 4096, lengths, got)
    assert_equal(claimed, 700)
    assert_equal(len(lengths), 1, "one call")
    assert_equal(lengths[0], 700, "and it asked for 700, not 4096")
    _assert_bytes_equal(payload, got, "sub-clamp payload")


def test_production_default_clamp_is_used_when_omitted() raises:
    """The default argument binds, and it does not split a small payload."""
    var payload = _payload(333)
    var pair = _dgram_pair()
    var lengths = List[Int]()
    var got = List[UInt8]()
    var claimed = write_all_fd(pair[0], Span(payload), String("test"))
    _drain(pair[1], lengths, got)
    _close(pair[0])
    _close(pair[1])
    assert_equal(claimed, 333)
    assert_equal(len(lengths), 1)
    assert_equal(lengths[0], 333)
    _assert_bytes_equal(payload, got, "default-clamp payload")


def test_empty_payload_issues_no_syscall() raises:
    """`_write_ipc_stream` calls the sink once per frame and a result with no
    dictionary column legitimately has zero `DictionaryBatch` frames. A
    zero-length datagram is a REAL datagram and the peer would see one."""
    var payload = List[UInt8]()
    var lengths = List[Int]()
    var got = List[UInt8]()
    var claimed = _write_and_observe(payload, 1024, lengths, got)
    assert_equal(claimed, 0)
    assert_equal(len(lengths), 0, "no write(2) at all")


def test_non_positive_clamp_is_refused_not_looped_forever() raises:
    """A zero clamp makes no progress. Refusing beats spinning."""
    var payload = _payload(64)
    var pair = _dgram_pair()
    var raised = False
    try:
        _ = write_all_fd(pair[0], Span(payload), String("test"), 0)
    except e:
        raised = True
        assert_true(
            String(e).find("max_call_bytes") >= 0,
            "the refusal must name the argument: " + String(e),
        )
    _close(pair[0])
    _close(pair[1])
    assert_true(raised, "a zero clamp must raise")


def test_shipped_clamp_is_below_the_darwin_write_ceiling() raises:
    """A BOUND on the constant, and deliberately not the falsifier — the tests
    above are. It exists so a future edit that raises the clamp past INT_MAX
    (re-creating the exact defect, since darwin's `write(2)` refuses
    `nbyte > INT_MAX`) fails here instead of at run time on darwin."""
    assert_true(
        FD_WRITE_MAX_CALL_BYTES > 0
        and FD_WRITE_MAX_CALL_BYTES <= 1024 * 1024 * 1024,
        "clamp out of range: " + String(FD_WRITE_MAX_CALL_BYTES),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
