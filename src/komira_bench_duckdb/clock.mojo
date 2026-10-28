# The clock seam of the DuckDB session. Marker times are read from a
# `BenchClock`: the system's monotonic clock in production, or a counter a test
# owns and moves itself, so no test reads the wall clock or sleeps.

from std.memory import ArcPointer

from komira_clock import now_ns


struct BenchClock(Copyable, Movable):
    """Nanoseconds on a monotonic clock, from the system or from a shared
    counter that a test advances."""

    var _cell: Optional[ArcPointer[Int]]

    def __init__(out self):
        """The system's monotonic clock."""
        self._cell = None

    @staticmethod
    def system() -> BenchClock:
        return BenchClock()

    @staticmethod
    def manual(cell: ArcPointer[Int]) -> BenchClock:
        """A clock that reads `cell` (nanoseconds) and never moves by itself.
        Whoever holds the other end of the `ArcPointer` moves time."""
        var c = BenchClock()
        c._cell = Optional[ArcPointer[Int]](cell)
        return c^

    def now(self) -> Int:
        """The current time in nanoseconds on this clock."""
        if self._cell:
            return self._cell.value()[]
        return Int(now_ns())
