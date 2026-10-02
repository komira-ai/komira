# =============================================================================
# src/kci_publish/pause.mojo -- `UsleepSleeper`: the wait between read-back
#   polls, as a komira_retry `Sleeper`.
# =============================================================================
#
# WHY NOT `std.time.sleep`. The HTTPS transport links komira_async, whose
# reactor declares libc `nanosleep` with its own signature; `std.time.sleep`
# declares it with another, and one binary cannot hold both (the compiler
# refuses the conflicting declaration). `usleep` is a distinct symbol. It is
# called in slices under one second, the range POSIX guarantees.
#
# A test passes komira_retry's `RecordingSleeper` instead and never waits.
#
# Encapsulation: no pointer; one libc call with scalar arguments.
# =============================================================================

from std.ffi import external_call

from komira_retry import Sleeper


comptime _SLICE_MS: Int64 = 500


struct UsleepSleeper(Sleeper, Movable, Deinitable):
    """Blocks the calling thread for the requested milliseconds."""

    def __init__(out self):
        pass

    def sleep_ms(mut self, ms: Int64) raises:
        var left = ms
        while left > 0:
            var step = left if left < _SLICE_MS else _SLICE_MS
            _ = external_call["usleep", Int32](UInt32(Int(step) * 1000))
            left -= step
