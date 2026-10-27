# =============================================================================
# komira_job_supervisor/loop_clock.mojo: the clock the run loop reads and waits
# on.
# =============================================================================
#
# The run loop reads the monotonic clock (the maximum runtime counts from the
# spawn) and waits one second between its checks. `LoopClock` is that pair, so
# a caller can supply a clock it owns: `SystemLoopClock` (what
# `run_job_supervisor` uses) reads the monotonic clock and sleeps for real;
# `ManualLoopClock` is a clock that moves only when the loop waits, by exactly
# the time waited, so a run of any length takes no time and every instant the
# loop reads is a count.
#
# The same manual clock is a shared cell, a count of nanoseconds in an
# `ArcPointer[Int]`. A `JobSupervisor` given the cell (`set_test_clock`) reads
# it for the spawn instant, the stream's flush interval and the terminal beat's
# retry budget, and moves it when the terminal beat waits to retry. A manual
# wait still yields the thread for a millisecond, so a loop that waits on a real
# child does not spin; nothing waits for that millisecond to pass and nothing
# fails if it is longer.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer

from komira_clock import now_ns


# `usleep`, not std's time.sleep: komira_async's reactor declares its own
# `nanosleep`, and a second declaration with another signature fails to
# legalize.
def usleep_ms(ms: Int):
    """Sleep `ms` milliseconds via usleep. A caught stop signal ends the sleep
    early (the handler has no SA_RESTART)."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def clock_now_ns(cell: Optional[ArcPointer[Int]]) -> UInt64:
    """The monotonic instant: `cell`'s nanoseconds when there is one, else the
    system's."""
    if cell:
        return UInt64(cell.value()[])
    return now_ns()


def clock_sleep_ms(cell: Optional[ArcPointer[Int]], ms: Int):
    """Wait `ms` milliseconds: for real without a cell; with one, move it
    forward by `ms` and yield the thread for a millisecond."""
    if ms <= 0:
        return
    if cell:
        cell.value()[] += ms * 1_000_000
        usleep_ms(1)
        return
    usleep_ms(ms)


trait LoopClock(Movable, Deinitable):
    """The clock of `run_job_supervisor_with_clock`."""

    def now_ns(self) -> UInt64:
        """The monotonic instant, in nanoseconds."""
        ...

    def sleep_secs(mut self, secs: Int):
        """Wait `secs` whole seconds."""
        ...

    def test_clock(self) -> Optional[ArcPointer[Int]]:
        """The manual clock cell the `JobSupervisor` is given, or None to use
        the system clock."""
        ...


struct SystemLoopClock(LoopClock):
    """The monotonic clock and a real wait."""

    def __init__(out self):
        pass

    def now_ns(self) -> UInt64:
        return now_ns()

    def sleep_secs(mut self, secs: Int):
        usleep_ms(secs * 1000)

    def test_clock(self) -> Optional[ArcPointer[Int]]:
        return None


struct ManualLoopClock(LoopClock):
    """A clock that moves only when the loop waits: `sleep_secs(n)` adds
    n * 10^9 to `cell` and records n * 1000 in `slept_ms`.

      cell       — the nanoseconds; give the same cell to a `JobSupervisor`
                   (`set_test_clock`) to put it on this clock.
      slept_ms   — every wait the loop asked for, in order.
    """

    var cell: ArcPointer[Int]
    var slept_ms: List[Int]

    def __init__(out self, cell: ArcPointer[Int]):
        self.cell = cell
        self.slept_ms = List[Int]()

    def now_ns(self) -> UInt64:
        return UInt64(self.cell[])

    def sleep_secs(mut self, secs: Int):
        self.slept_ms.append(secs * 1000)
        clock_sleep_ms(Optional[ArcPointer[Int]](self.cell), secs * 1000)

    def test_clock(self) -> Optional[ArcPointer[Int]]:
        return Optional[ArcPointer[Int]](self.cell)
