# The clock seam of the SMTP client. Every budget of a send is measured on a
# `SmtpClock`: the system's monotonic clock in production, or a counter a test
# owns. A test hands the same counter to `ScriptedStream.advance_clock_on_read`
# so that time passes exactly where the script says the peer is silent, and no
# test sleeps or reads the wall clock.

from std.memory import ArcPointer

from komira_clock import now_ns


struct SmtpClock(Copyable, Movable):
    """Microseconds on a monotonic clock, from the system or from a shared
    counter that a test advances."""

    var _cell: Optional[ArcPointer[Int]]

    def __init__(out self):
        """The system's monotonic clock."""
        self._cell = None

    @staticmethod
    def system() -> SmtpClock:
        """The system's monotonic clock (the default of `SmtpClientConfig`)."""
        return SmtpClock()

    @staticmethod
    def manual(cell: ArcPointer[Int]) -> SmtpClock:
        """A clock that reads `cell` (microseconds) and never moves by itself.
        Whoever holds the other end of the `ArcPointer` moves time."""
        var c = SmtpClock()
        c._cell = Optional[ArcPointer[Int]](cell)
        return c^

    def now_us(self) -> Int:
        """The current time in microseconds on this clock."""
        if self._cell:
            return self._cell.value()[]
        return Int(now_ns() // UInt64(1000))
