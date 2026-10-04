# =============================================================================
# src/kci_publish/pause.mojo -- `UsleepSleeper`: the wait between read-back
#   polls, as a komira_retry `Sleeper`; `NoWaitSleeper`, the test double.
# =============================================================================
#
# WHY NOT `std.time.sleep`. The HTTPS transport links komira_async, whose
# reactor declares libc `nanosleep` with its own signature; `std.time.sleep`
# declares it with another, and one binary cannot hold both (the compiler
# refuses the conflicting declaration). `usleep` is a distinct symbol. It is
# called in slices under one second, the range POSIX guarantees.
#
# A test passes `NoWaitSleeper` instead and never waits. Both are
# `WorkerSleeper`s: each upload worker gets its own (`for_worker`).
#
# Encapsulation: no pointer; one libc call with scalar arguments.
# =============================================================================

from std.ffi import external_call

from komira_retry import Sleeper

from .workers import WorkerSleeper


comptime _SLICE_MS: Int64 = 500


struct UsleepSleeper(WorkerSleeper, Movable, Deinitable):
    """Blocks the calling thread for the requested milliseconds."""

    def __init__(out self):
        pass

    def for_worker(self) -> Self:
        return Self()

    def sleep_ms(mut self, ms: Int64) raises:
        var left = ms
        while left > 0:
            var step = left if left < _SLICE_MS else _SLICE_MS
            _ = external_call["usleep", Int32](UInt32(Int(step) * 1000))
            left -= step


struct NoWaitSleeper(WorkerSleeper, Movable, Deinitable):
    """A test sleeper: returns at once; counts the waits it was asked for.
    Each worker's copy counts its own.

    Layout: an Int. No pointer field."""

    var waits: Int

    def __init__(out self):
        self.waits = 0

    def for_worker(self) -> Self:
        return Self()

    def sleep_ms(mut self, ms: Int64) raises:
        self.waits += 1
