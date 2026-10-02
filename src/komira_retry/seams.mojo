# =============================================================================
# komira_retry/seams.mojo -- the clock, sleeper and random source a retry
# loop runs on, each a trait so a test pins time and never sleeps.
# =============================================================================
#
# The system conformers use only the standard library (`std.time`), so the
# package has no FFI and no dependency, and that is the rule: `SystemClock`
# stays on `std.time`. komira_retry imports nothing outside the standard
# library, komira_core included. A shared clock that lives elsewhere conforms
# to `MonotonicClock` in its own package and is injected by the caller; this
# package never imports it, and the trait needs no change for it.
#
# Units are milliseconds throughout. Retry waits are tens of milliseconds to
# seconds; nothing here needs finer precision.
# =============================================================================

from std.time import perf_counter_ns, sleep


trait MonotonicClock(Movable, Deinitable):
    """Milliseconds on a clock that never goes backwards. Only differences
    between two readings mean anything."""

    def now_ms(mut self) -> Int64:
        ...


trait Sleeper(Movable, Deinitable):
    """Waits `ms` milliseconds (`ms` >= 0). An async runtime supplies its own
    conformer that parks the task instead of blocking the thread."""

    def sleep_ms(mut self, ms: Int64) raises:
        ...


trait RetryRng(Movable, Deinitable):
    """Uniformly distributed 64-bit values, used only to spread retries
    apart. Never a source of secrets."""

    def next_u64(mut self) -> UInt64:
        ...


struct SystemClock(MonotonicClock, Movable, Deinitable):
    """The process's monotonic clock."""

    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return Int64(Int(perf_counter_ns() // 1_000_000))


struct SystemSleeper(Sleeper, Movable, Deinitable):
    """Blocks the calling thread."""

    def __init__(out self):
        pass

    def sleep_ms(mut self, ms: Int64) raises:
        if ms > 0:
            sleep(Float64(ms) / 1000.0)


struct SplitMix64Rng(RetryRng, Movable, Deinitable):
    """SplitMix64 (Steele, Lea and Flood, 2014): small and fast, plenty for
    jitter. Not a CSPRNG. `seeded_from_clock()` gives each process a
    different sequence; a test passes a fixed seed."""

    var _state: UInt64

    def __init__(out self, seed: UInt64):
        self._state = seed

    @staticmethod
    def seeded_from_clock() -> SplitMix64Rng:
        return SplitMix64Rng(UInt64(Int(perf_counter_ns())))

    def next_u64(mut self) -> UInt64:
        self._state += UInt64(0x9E3779B97F4A7C15)
        var z = self._state
        z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> 31)


struct ManualClock(MonotonicClock, Movable, Deinitable):
    """A test clock: reads `now`, moves only when told to."""

    var now: Int64

    def __init__(out self, start_ms: Int64 = 0):
        self.now = start_ms

    def now_ms(mut self) -> Int64:
        return self.now

    def advance(mut self, ms: Int64):
        self.now += ms


struct RecordingSleeper(Sleeper, Movable, Deinitable):
    """A test sleeper: records each requested wait and returns at once."""

    var slept: List[Int64]

    def __init__(out self):
        self.slept = List[Int64]()

    def sleep_ms(mut self, ms: Int64) raises:
        self.slept.append(ms)

    def total_ms(self) -> Int64:
        var t = Int64(0)
        for s in self.slept:
            t += s
        return t
