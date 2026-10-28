# =============================================================================
# group_clock.mojo: the clock a GroupCoordinator reads and waits on.
# =============================================================================
#
# The coordinator stamps wall-clock milliseconds into the persisted group state
# (rebalance deadline, round-open instant, a member's last liveness signal) and
# waits between polls of that state. Both go through a GroupClock, so a test
# drives them without a real wait:
#
#   * SystemGroupClock reads the Unix wall clock (komira_clock) and waits with
#     the standard library's sleep.
#   * ManualGroupClock moves only when told to. Its sleep_ms advances the
#     reading by the requested wait and returns at once, so a coordinator that
#     polls for a deadline sees the deadline pass instead of spinning.
#
# No pointer type appears in any signature.
# =============================================================================

from std.time import sleep

from komira_clock import now_unix_ms


trait GroupClock(Movable, Deinitable):
    """Wall-clock milliseconds and a wait."""

    def now_ms(mut self) -> Int64:
        """The current time in milliseconds."""
        ...

    def sleep_ms(mut self, ms: Int64):
        """Wait about `ms` milliseconds."""
        ...


struct SystemGroupClock(GroupClock, Movable, Deinitable):
    """The Unix wall clock; sleep_ms blocks the calling thread."""

    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return now_unix_ms()

    def sleep_ms(mut self, ms: Int64):
        if ms > Int64(0):
            sleep(Float64(Int(ms)) / 1000.0)


struct ManualGroupClock(GroupClock, Movable, Deinitable):
    """A clock that moves only through `set`, `advance` and `sleep_ms`."""

    var now: Int64
    # How many times `sleep_ms` was called, and the milliseconds it covered.
    var sleep_calls: Int
    var slept_ms: Int64

    def __init__(out self, start_ms: Int64 = Int64(0)):
        self.now = start_ms
        self.sleep_calls = 0
        self.slept_ms = Int64(0)

    def now_ms(mut self) -> Int64:
        return self.now

    def sleep_ms(mut self, ms: Int64):
        self.sleep_calls += 1
        if ms > Int64(0):
            self.slept_ms += ms
            self.now += ms

    def set(mut self, now_ms: Int64):
        self.now = now_ms

    def advance(mut self, ms: Int64):
        self.now += ms
