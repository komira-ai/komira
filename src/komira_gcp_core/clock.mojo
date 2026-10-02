# =============================================================================
# komira_gcp_core/clock.mojo — the injected clock every timed decision reads.
# =============================================================================
#
# Whether a cached access token is still fresh (`token.mojo`) depends on
# time. It reads a `Clock` passed in by the caller rather than the system
# clock directly, so a test can pin "now", advance it, and observe a sleep
# without waiting. (Retry waits and deadlines run on komira_retry's own
# `MonotonicClock` / `Sleeper` seams.)
#
# HOLD: this file is a placeholder for a shared clock. It moves out of this
# package when the komira_core split proposal lands and names the clock's
# home; until then nothing new goes into komira_core, so it stays here.
#
# `MonotonicClock` is the production conformer. It is MONOTONIC on purpose:
# every expiry this package computes is relative (`expires_in` seconds from
# the token endpoint), so a wall-clock
# step (NTP, a suspended VM) must not make a token look fresher or older than
# it is. A wall clock (for a JWT `iat`/`exp`) arrives with the JWT
# assertion in P18a-2.
# =============================================================================

from std.time import perf_counter_ns, sleep


trait Clock(Movable, Deinitable):
    """A source of "now" in milliseconds, and a way to wait.

    `now_ms` is only ever compared with another `now_ms` of the SAME clock, so
    its epoch is the conformer's choice. `sleep_ms` waits at least `ms`
    milliseconds; a fake conformer advances its own "now" instead."""

    def now_ms(mut self) -> Int64:
        """Milliseconds on this clock's own monotonic timeline."""
        ...

    def sleep_ms(mut self, ms: Int64):
        """Wait `ms` milliseconds (a non-positive `ms` returns at once)."""
        ...


struct MonotonicClock(Clock, Movable, Deinitable):
    """The process's monotonic clock (`perf_counter_ns`) and a real sleep."""

    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return Int64(perf_counter_ns() // 1_000_000)

    def sleep_ms(mut self, ms: Int64):
        if ms <= 0:
            return
        sleep(Float64(ms) / 1000.0)
