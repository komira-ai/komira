# =============================================================================
# clock.mojo -- the process clocks: monotonic ns, wall-clock ms/us, thread CPU
# =============================================================================
#
# Four reads, each a plain integer:
#
#   * `now_ns()`          monotonic nanoseconds, for measuring intervals.
#   * `now_unix_ms()`     wall clock, milliseconds since the Unix epoch.
#   * `now_unix_us()`     wall clock, microseconds since the Unix epoch.
#   * `thread_cpu_ns()`   CPU nanoseconds consumed by the calling thread.
#
# Every read calls libc's `clock_gettime` directly. The package has no C shim
# and no native dependency: the `timespec` is a stack-local `_Timespec` that
# this file owns, so the one raw pointer never leaves it and the public API
# returns integers only.
#
# `now_ns()` is the span hot path, so it resolves to the cheapest user-space
# monotonic source on each platform:
#
#   * macOS: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` from libSystem, a direct
#     `UInt64` with no `timespec` at all.
#   * Linux: `CLOCK_MONOTONIC`, a vDSO trampoline on x86_64 and aarch64 (no
#     syscall).
#
# The clock reads the real clock and nothing else. A test that needs a fixed
# "now" passes the instant to the code under test; there is no process-wide
# override and no environment variable.
#
# `test_clock` runs on Linux and macOS: the clock ids differ per kernel and are
# chosen at compile time below.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget

# CLOCK_REALTIME is 0 on Linux and Darwin.
comptime _CLOCK_REALTIME: Int32 = 0
# Darwin <sys/_types/_clockid_t.h>: CLOCK_UPTIME_RAW = 8 -- monotonic since
# boot, no leap-second smoothing, no syscall.
comptime _CLOCK_UPTIME_RAW: Int32 = 8
# <time.h>: Linux CLOCK_MONOTONIC = 1, CLOCK_THREAD_CPUTIME_ID = 3 (x86_64 and
# aarch64 alike); Darwin CLOCK_THREAD_CPUTIME_ID = 16.
comptime _CLOCK_MONOTONIC_LINUX: Int32 = 1
comptime _CLOCK_THREAD_CPUTIME_ID: Int32 = 16 if CompilationTarget.is_macos() else 3


struct _Timespec:
    """`struct timespec`: two 8-byte integers on x86_64, aarch64 and Darwin."""

    var tv_sec: Int64
    var tv_nsec: Int64

    def __init__(out self):
        self.tv_sec = 0
        self.tv_nsec = 0


@always_inline
def _read_ns(clock_id: Int32) -> UInt64:
    """Nanoseconds on `clock_id`, or 0 if `clock_gettime` fails.

    No clock used here can fail on either kernel; 0 is the "no reading"
    answer for a platform that surprises us.
    """
    var ts = _Timespec()
    # SAFETY: the pointer carries `ts`'s own origin. `ts` is stack-local and
    # outlives the synchronous call (the kernel writes, then returns before
    # this frame destroys `ts`), and the kernel retains no address. The
    # pointer is not stored or returned.
    var rc = external_call["clock_gettime", Int32](
        clock_id, UnsafePointer(to=ts)
    )
    if rc != 0:
        return 0
    return UInt64(ts.tv_sec) * UInt64(1_000_000_000) + UInt64(ts.tv_nsec)


@always_inline
def now_ns() -> UInt64:
    """User-space monotonic nanosecond timestamp.

    macOS: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.
    Linux: `CLOCK_MONOTONIC` (vDSO, no syscall).

    Returns 0 if the platform call fails, which neither kernel documents as
    possible for a monotonic clock.
    """

    comptime if CompilationTarget.is_macos():
        return external_call["clock_gettime_nsec_np", UInt64](
            _CLOCK_UPTIME_RAW
        )
    else:
        return _read_ns(_CLOCK_MONOTONIC_LINUX)


@always_inline
def now_unix_ms() -> Int64:
    """Milliseconds since the Unix epoch (wall clock, `CLOCK_REALTIME`).

    This is the clock credential-expiry timestamps, UUIDv7 and HTTP `Date`
    headers are denominated in, so it is the wall clock, not the monotonic
    one.

    Returns 0 if the platform call fails.
    """
    return Int64(_read_ns(_CLOCK_REALTIME) // UInt64(1_000_000))


@always_inline
def now_unix_us() -> Int64:
    """Microseconds since the Unix epoch (wall clock, `CLOCK_REALTIME`).

    The microsecond sibling of `now_unix_ms()`, for the unit TIMESTAMPTZ
    comparisons are denominated in.

    Returns 0 if the platform call fails.
    """
    return Int64(_read_ns(_CLOCK_REALTIME) // UInt64(1_000))


@always_inline
def thread_cpu_ns() -> UInt64:
    """CPU nanoseconds consumed by the CALLING THREAD.

    Pair with `now_ns()` across one bracket to get occupancy:

        var w0 = now_ns(); var c0 = thread_cpu_ns()
        ...the bracketed region...
        var wall = now_ns() - w0; var cpu = thread_cpu_ns() - c0
        # occupancy = cpu / wall; below 1.0 the thread was blocked, so
        # `wall` overstates the recoverable compute by 1/occupancy.

    Counts only this thread (`CLOCK_THREAD_CPUTIME_ID`); idle workers spinning
    elsewhere in the process are excluded, which is why
    `CLOCK_PROCESS_CPUTIME_ID` would be the wrong clock.

    Not vDSO-accelerated on Linux: a real syscall, roughly 100-600ns, 10-60x
    `now_ns()`. Call it at bracket bookends that fire once per driver
    invocation, never per morsel or per row.

    Returns 0 if the platform call fails.
    """
    return _read_ns(_CLOCK_THREAD_CPUTIME_ID)
