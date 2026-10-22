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
# Every read goes through the C shim in `native/komira_clock.c`. The shim owns
# what Mojo cannot see: the platform's clock ids (`CLOCK_THREAD_CPUTIME_ID` is
# 3 on Linux and 16 on macOS; `CLOCK_UPTIME_RAW` exists on macOS only) and the
# layout of `struct timespec`. Each shim function takes no argument and
# returns nanoseconds as a `UInt64`, or 0 if the platform refuses the read, so
# no pointer crosses the boundary in either direction and this file holds no
# platform constant.
#
# `now_ns()` is the span hot path. The shim resolves it to the cheapest
# user-space monotonic source on each platform (macOS:
# `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`; Linux: `CLOCK_MONOTONIC`, a vDSO
# trampoline with no syscall), so the call costs the C call and nothing more.
#
# The clock reads the real clock and nothing else. A test that needs a fixed
# "now" passes the instant to the code under test; there is no process-wide
# override and no environment variable.
# =============================================================================

from std.ffi import external_call


@always_inline
def _monotonic_ns() -> UInt64:
    """Monotonic nanoseconds from the C shim, or 0 if the platform refuses.

    FFI-BOUNDARY: `komira_clock_monotonic_ns` (native/komira_clock.c, linked
    from this package's `libkomira_clock.a`) takes no argument and returns a
    plain integer. No pointer is passed or returned, so there is nothing to
    own or free: the shim's `struct timespec` is a local of the C function.
    """
    return external_call["komira_clock_monotonic_ns", UInt64]()


@always_inline
def _realtime_ns() -> UInt64:
    """Nanoseconds since the Unix epoch from the C shim, or 0 if refused.

    FFI-BOUNDARY: `komira_clock_realtime_ns` (native/komira_clock.c) takes no
    argument and returns a plain integer; no pointer crosses the boundary.
    """
    return external_call["komira_clock_realtime_ns", UInt64]()


@always_inline
def _thread_cpu_ns() -> UInt64:
    """CPU nanoseconds of the calling thread from the C shim, or 0 if refused.

    FFI-BOUNDARY: `komira_clock_thread_cpu_ns` (native/komira_clock.c) takes
    no argument and returns a plain integer; no pointer crosses the boundary.
    """
    return external_call["komira_clock_thread_cpu_ns", UInt64]()


@always_inline
def now_ns() -> UInt64:
    """User-space monotonic nanosecond timestamp.

    macOS: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.
    Linux: `CLOCK_MONOTONIC` (vDSO, no syscall).

    Returns 0 if the platform call fails, which neither kernel documents as
    possible for a monotonic clock.
    """
    return _monotonic_ns()


@always_inline
def now_unix_ms() -> Int64:
    """Milliseconds since the Unix epoch (wall clock, `CLOCK_REALTIME`).

    This is the clock credential-expiry timestamps, UUIDv7 and HTTP `Date`
    headers are denominated in, so it is the wall clock, not the monotonic
    one.

    Returns 0 if the platform call fails.
    """
    return Int64(_realtime_ns() // UInt64(1_000_000))


@always_inline
def now_unix_us() -> Int64:
    """Microseconds since the Unix epoch (wall clock, `CLOCK_REALTIME`).

    The microsecond sibling of `now_unix_ms()`, for the unit TIMESTAMPTZ
    comparisons are denominated in.

    Returns 0 if the platform call fails.
    """
    return Int64(_realtime_ns() // UInt64(1_000))


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
    return _thread_cpu_ns()
