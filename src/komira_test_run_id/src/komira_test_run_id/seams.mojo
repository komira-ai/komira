# =============================================================================
# komira_test_run_id/seams.mojo -- the wall clock and the random source a run
# id is minted from, each a trait so a test pins them.
# =============================================================================
#
# Real conformers: `SystemClock` (komira_clock's wall clock, in whole
# seconds) and `UrandomEntropy` (/dev/urandom).
# Fakes: `FixedWallClock` and `ScriptedEntropy`.
#
# The entropy here names test resources (run ids, ports, a throwaway embedded
# server's root credential). It is not used to make anything a third party
# must not guess, except that throwaway credential, which never leaves the
# test's private temporary directory.
# =============================================================================

from komira_clock import now_unix_ms


trait WallClock(Movable, Deinitable):
    """Whole seconds since the Unix epoch. Creation times and deadlines are
    stamped from it."""

    def now_unix(mut self) -> Int:
        ...


trait Entropy(Movable, Deinitable):
    """Uniformly distributed 64-bit values. Raises when it cannot produce
    one; a caller never substitutes a constant."""

    def next_u64(mut self) raises -> UInt64:
        ...


struct SystemClock(WallClock):
    """The process's wall clock (`CLOCK_REALTIME`, read by komira_clock), in
    whole seconds. The WALL clock, not a monotonic one: callers stamp it on
    things other processes and other machines read (a creation time, a
    deadline)."""

    def __init__(out self):
        pass

    def now_unix(mut self) -> Int:
        return Int(now_unix_ms() // 1000)


struct FixedWallClock(WallClock):
    """A test clock: reads `now`, moves only when told to."""

    var now: Int

    def __init__(out self, now: Int):
        self.now = now

    def now_unix(mut self) -> Int:
        return self.now

    def advance(mut self, seconds: Int):
        self.now += seconds


struct UrandomEntropy(Entropy):
    """Reads `/dev/urandom`, eight bytes per value."""

    def __init__(out self):
        pass

    def next_u64(mut self) raises -> UInt64:
        var bytes: List[UInt8]
        try:
            with open("/dev/urandom", "r") as f:  # cov: unreachable a test cannot make the fixed path /dev/urandom fail to open
                bytes = f.read_bytes(8)  # cov: unreachable a test cannot make a read of /dev/urandom fail
        except:
            raise Error("entropy: cannot read /dev/urandom")  # cov: unreachable reached only when lines 72-73 raise
        if len(bytes) != 8:  # cov: unreachable a read of 8 bytes from /dev/urandom returns 8 bytes or raises
            raise Error("entropy: short read from /dev/urandom")  # cov: unreachable see the line above
        var v = UInt64(0)
        for i in range(8):
            v = (v << 8) | UInt64(bytes[i])
        return v


struct ScriptedEntropy(Entropy):
    """A test source: returns `values` in order, then raises. Running out is
    an error, so a test that draws more than it scripted fails loudly instead
    of repeating a value."""

    var values: List[UInt64]
    var drawn: Int

    def __init__(out self, var values: List[UInt64]):
        self.values = values^
        self.drawn = 0

    def next_u64(mut self) raises -> UInt64:
        if self.drawn >= len(self.values):
            raise Error(
                "ScriptedEntropy: script exhausted after "
                + String(self.drawn)
                + " values"
            )
        var v = self.values[self.drawn]
        self.drawn += 1
        return v
