# =============================================================================
# komira_kg_enrich/lease_clock.mojo -- the time source of a fenced drain pass.
# =============================================================================
#
# A pass that holds a lease re-checks it before each delivery, so it needs the
# time at each check, not once at the start. The host supplies a `LeaseClock`
# (its own wall clock behind the trait); this package reads no clock itself.
#
# `FixedLeaseClock` always answers the same time: a pass on it never sees its
# lease expire, and still notices a lease that was taken over. `FakeLeaseClock`
# answers a counter that a test moves with `advance`; its clones share the
# counter, so a sender can move the time in the middle of a pass.
# =============================================================================

from std.memory import ArcPointer


trait LeaseClock(Movable, Deinitable):
    """The current time in microseconds, on the scale of the lease's
    `now_micros`."""

    def now_micros(mut self) raises -> Int64:
        ...


struct FixedLeaseClock(LeaseClock):
    """A clock that always answers the time it was built with."""

    var micros: Int64

    def __init__(out self, micros: Int64):
        self.micros = micros

    def now_micros(mut self) raises -> Int64:
        return self.micros


struct FakeLeaseClock(LeaseClock):
    """A counter that only `advance` and `set` move. `clone()` shares it."""

    var _state: ArcPointer[Int64]

    def __init__(out self, start_micros: Int64 = Int64(0)):
        self._state = ArcPointer[Int64](start_micros)

    def __init__(out self, *, var shared: ArcPointer[Int64]):
        self._state = shared^

    def clone(self) -> Self:
        return Self(shared=self._state.copy())

    def advance(mut self, micros: Int64):
        self._state[] += micros

    def set(mut self, micros: Int64):
        self._state[] = micros

    def now_micros(mut self) raises -> Int64:
        return self._state[]
