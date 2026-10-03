# =============================================================================
# komira_uuid/clock.mojo — wall-clock milliseconds for UUIDv7
# =============================================================================
#
# UUIDv7 needs the WALL clock (CLOCK_REALTIME — Unix-epoch milliseconds),
# not a monotonic clock: the embedded timestamp must denote real creation
# time so the IDs sort by when they were minted.
#
# This package owns its own `clock_gettime` declaration rather than importing
# a clock from an observability package: those packages sit above this one in
# the dependency graph, so importing one here would form a package cycle.
#
# The clock reads the real clock and nothing else. A caller that needs a
# deterministic "now" (a test pinning the timestamp) passes it explicitly to
# the generator — see `generate_uuidv7(now_ms=...)` in `uuid.mojo`. There is
# no process-wide override.
#
# Encapsulation rule: the `external_call` + the stack-local timespec
# pointer stay INSIDE this file. The public symbol `now_unix_ms()` returns
# a plain `Int64` — no `UnsafePointer` crosses the module boundary.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# CLOCK_REALTIME = 0 — Unix-epoch wall clock; vDSO-accelerated on Linux
# x86_64 + aarch64 + Darwin. Matches <bits/time.h>.
comptime _CLOCK_REALTIME: Int32 = 0


def now_unix_ms() -> Int64:
    """Milliseconds since the Unix epoch (wall clock).

    Returns `Int64(0)` if the platform call fails (extremely unlikely).
    """
    # struct timespec { time_t tv_sec; long tv_nsec; } — both fields are
    # 8 bytes on x86_64 / aarch64 / Darwin; a stack-local Array[Int64, 2]
    # is layout-compatible. macOS exposes clock_gettime(2) since 10.12.
    var ts = Array[Int64, 2](fill=Int64(0))
    # SAFETY: the pointer carries `ts`'s own origin. `ts` is stack-local and
    # outlives the synchronous syscall (the kernel writes, then returns before
    # this frame destroys `ts`), and the kernel retains no address.
    var ts_ptr = UnsafePointer(to=ts).bitcast[Int64]()
    _ = external_call["clock_gettime", Int32](
        _CLOCK_REALTIME,
        ts_ptr,
    )
    # tv_sec * 1000 + tv_nsec / 1_000_000.
    return ts[0] * Int64(1000) + ts[1] // Int64(1_000_000)
