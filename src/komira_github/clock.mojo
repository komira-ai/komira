# =============================================================================
# komira_github/clock.mojo -- the wall clock the App JWT, the token cache and
#   the rate-limit latch read.
# =============================================================================
#
# Every time this package compares against GitHub's own times (a JWT's
# `iat`/`exp`, a token's `expires_at`, `x-ratelimit-reset`) is Unix seconds
# of the wall clock, so the clock is a seam: `SystemUnixClock` in production,
# `ManualUnixClock` in a test, moved by `set`/`advance` and never by sleeping.
# =============================================================================

from komira_clock import now_unix_ms


trait UnixClock(Movable, Deinitable):
    """The wall clock in whole seconds since the Unix epoch (UTC)."""

    def now_unix_seconds(mut self) -> Int64:
        ...


struct SystemUnixClock(UnixClock, Copyable, Movable, Deinitable):
    """The process's wall clock, read each time it is asked."""

    def __init__(out self):
        pass

    def now_unix_seconds(mut self) -> Int64:
        return Int64(Int(now_unix_ms() // 1000))


struct ManualUnixClock(UnixClock, Copyable, Movable, Deinitable):
    """A clock that moves only when told to."""

    var unix_seconds: Int64

    def __init__(out self, unix_seconds: Int64):
        self.unix_seconds = unix_seconds

    def now_unix_seconds(mut self) -> Int64:
        return self.unix_seconds

    def set(mut self, unix_seconds: Int64):
        self.unix_seconds = unix_seconds

    def advance(mut self, seconds: Int64):
        self.unix_seconds += seconds
