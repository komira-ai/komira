# =============================================================================
# clock -- the time the capture server stamps with, given by its host.
# =============================================================================
#
# The server reads no clock of its own. The host hands it a `CaptureClock` when
# it builds the server, and the server asks that clock once per request: the
# reading is the ingest time (`ts`) of every episode the request writes and the
# time a compaction fold marks the chunks it retires with. A host that wants the
# wall clock writes a conformer over `komira_clock.now_unix_ms`; a test passes
# `FixedClock` or `StepClock` and so names the time it expects in the graph.
# =============================================================================


trait CaptureClock(Movable, Deinitable):
    """A source of the current time in milliseconds since the Unix epoch."""

    def now_ms(mut self) -> Int64:
        """The time now. The server calls it once for each request it writes
        for, so a clock may be stateful.
        """
        ...


struct FixedClock(CaptureClock):
    """A clock that always reads the same time."""

    var _now_ms: Int64

    def __init__(out self, now_ms: Int64):
        """A clock stopped at `now_ms`."""
        self._now_ms = now_ms

    def now_ms(mut self) -> Int64:
        return self._now_ms


struct StepClock(CaptureClock):
    """A clock that moves a fixed step forward each time it is read: the first
    reading is `start_ms`, the next `start_ms + step_ms`, and so on."""

    var _next_ms: Int64
    var _step_ms: Int64

    def __init__(out self, start_ms: Int64, step_ms: Int64):
        """A clock whose first reading is `start_ms` and which advances by
        `step_ms` after each reading."""
        self._next_ms = start_ms
        self._step_ms = step_ms

    def now_ms(mut self) -> Int64:
        var reading = self._next_ms
        self._next_ms += self._step_ms
        return reading
