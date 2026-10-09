# =============================================================================
# komira_http_auth/clock.mojo: the wall clock the token checks read.
# =============================================================================
#
# `exp`, `iat` and `nbf` are Unix seconds, so the checks need the wall clock
# (CLOCK_REALTIME), not a monotonic one. The JWKS cache's max-age and its
# refetch window read the same clock, so one injected clock drives every time
# decision a verifier makes and a test can move it.
#
# `SystemAuthClock` reads `komira_clock.now_unix_ms`. `FixedAuthClock` is the
# test double: a value a test sets and advances. Its handles share one cell
# (`share()`), so a test keeps a handle after moving the clock into the
# verifier under test.
#
# No pointer in any signature. The only pointer is FixedAuthClock's
# `ArcPointer` over its own cell (shared ownership, one thread).
# =============================================================================

from std.memory import ArcPointer

from komira_clock import now_unix_ms


trait AuthClock(Movable, Deinitable):
    """A source of the current time in whole Unix seconds."""

    def now_unix_seconds(mut self) -> Int64:
        ...


struct SystemAuthClock(AuthClock, Movable, Deinitable):
    """The process wall clock (`CLOCK_REALTIME`), in whole seconds."""

    def __init__(out self):
        pass

    def now_unix_seconds(mut self) -> Int64:
        return now_unix_ms() // Int64(1000)


struct _ClockCell(Movable):
    var now: Int64

    def __init__(out self, now: Int64):
        self.now = now


struct FixedAuthClock(AuthClock, Movable, Deinitable):
    """A clock that reads whatever a test set. Handles made by `share()` read
    and move the same time."""

    var _p: ArcPointer[_ClockCell]

    def __init__(out self, now: Int64):
        self._p = ArcPointer[_ClockCell](_ClockCell(now))

    def __init__(out self, *, var _share: ArcPointer[_ClockCell]):
        self._p = _share^

    def share(self) -> FixedAuthClock:
        """A second handle over the same time."""
        return FixedAuthClock(_share=ArcPointer[_ClockCell](copy=self._p))

    def set(mut self, now: Int64):
        self._p[].now = now

    def advance(mut self, seconds: Int64):
        self._p[].now = self._p[].now + seconds

    def now_unix_seconds(mut self) -> Int64:
        return self._p[].now
