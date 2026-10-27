# komira_clock

The process clocks, each read as a plain integer:

| function | clock | unit |
|---|---|---|
| `now_ns()` | monotonic (`CLOCK_MONOTONIC` on Linux, `CLOCK_UPTIME_RAW` on macOS) | nanoseconds, for measuring intervals |
| `now_unix_ms()` | wall clock (`CLOCK_REALTIME`) | milliseconds since the Unix epoch |
| `now_unix_us()` | wall clock (`CLOCK_REALTIME`) | microseconds since the Unix epoch |
| `thread_cpu_ns()` | the calling thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`) | nanoseconds |

Every read is a direct `clock_gettime` call (on macOS, `now_ns` is
`clock_gettime_nsec_np`). The package has no C shim and depends on nothing
but the standard library (its tests also use `komira_fork_join`), so any
package can import it. A read the platform
refuses returns 0; neither kernel documents that as possible for these
clocks.

The clocks read the real clock and nothing else: there is no process-wide
override and no environment variable. Code that needs a fixed "now" takes
the instant as an argument.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Measuring an interval

`now_ns()` never goes backwards, so the difference of two reads is the
elapsed time. It is a vDSO call on Linux (no system call), cheap enough for
a hot path.

```mojo
from komira_clock import now_ns
from std.testing import assert_true

var start = now_ns()
var total = 0
for i in range(1000):
    total += i  # the work being measured
var elapsed = now_ns() - start  # nanoseconds; never negative
print("summed", total, "in", elapsed, "ns")
assert_true(total == 499500)
assert_true(now_ns() >= start)
```

The reads are monotonic, so `elapsed` cannot underflow. Its value depends on the
machine, so report it (a metric, a log line) rather than compare it to a
constant.

## Wall-clock time

`now_unix_ms()` and `now_unix_us()` read the same wall clock in two units:
milliseconds for expiry timestamps and HTTP `Date` headers, microseconds for
timestamp comparisons. Use them for instants, never for intervals: the wall
clock can step.

```mojo
from komira_clock import now_unix_ms, now_unix_us
from std.testing import assert_true

var ms_before = now_unix_ms()
var us = now_unix_us()
var ms_after = now_unix_ms()
assert_true(ms_before > Int64(1_000_000_000_000))  # a 13-digit epoch reading
assert_true(ms_before < Int64(4_102_444_800_000))  # before 2100
assert_true(us // 1000 >= ms_before and us // 1000 <= ms_after)
```

## CPU time of the calling thread

`thread_cpu_ns()` counts only the calling thread, so other busy threads in
the process do not inflate it. Bracketing a region with both clocks gives
its occupancy (CPU time over wall time); below 1.0 the thread spent part of
the region blocked. It is a real system call on Linux, ten to sixty times the
cost of `now_ns()`, so read it once per region, not per row.

```mojo
from komira_clock import now_ns, thread_cpu_ns
from std.testing import assert_true

var wall_start = now_ns()
var cpu_start = thread_cpu_ns()
var acc = UInt64(0)
for i in range(20_000_000):
    acc = acc + UInt64(i) * UInt64(i)
var cpu_busy = thread_cpu_ns() - cpu_start
var wall_busy = now_ns() - wall_start
assert_true(acc != UInt64(1))  # the loop's result is used
assert_true(cpu_busy > UInt64(0))  # computing burns this thread's CPU
# Occupancy is cpu_busy / wall_busy: near 1.0 for a loop that never blocks.
# It depends on the machine and its load, so report it; do not assert on it.
print("cpu", cpu_busy, "ns of wall", wall_busy, "ns")
```
