# =============================================================================
# komira_log.stderr_sink — thread-safe synchronous write(2) to stderr (fd 2).
# =============================================================================
#
# P1's sink: format-on-the-caller → ONE `write(2)` of the whole rendered line
# to fd 2 (stderr). Two correctness requirements:
#
#   1. THREAD SAFETY. P1 is called synchronously from ANY thread (the job supervisor's
#      heartbeat loop, a service's reconciler, a worker). Two threads
#      writing concurrently must not INTERLEAVE bytes within a line. We guard
#      the write with a process-static atomic spin-lock so each rendered line
#      reaches fd 2 atomically. `write(2)` to a regular fd is itself not
#      guaranteed atomic across threads for arbitrary lengths, so the lock is
#      load-bearing (not just belt-and-suspenders).
#
#   2. WHOLE-LINE WRITE. We build the full line (incl. trailing '\n') as one
#      `String`, then issue a single `write(2)`. No per-field writes.
#
# # Why a raw write(2) and not `print`
#
# Mojo's `print(...)` cannot be pointed at fd 2 the way a logger needs, so logs
# would otherwise land on
# stdout and pollute genuine CLI output. A direct `write(2)` to fd 2 is the
# clean separation: logs → stderr, user-facing CLI output → stdout via `print`.
#
# # FFI-BOUNDARY / encapsulation
#
# ⚠ THIS MODULE OWNS NO `write` external_call, AND THAT IS THE POINT. A
# hand-written write loop that `break`s on the first non-positive return — no
# retry, no errno classification, no counter — is easy to copy and wrong in
# every copy.
#
# The loop now lives in `komira_log.log_write`, once, tested once, reached by
# CALLING. No `UnsafePointer` crosses this module's API or appears in it at
# all: `write_line(String)` takes a String and returns nothing.
# =============================================================================

from komira_atomic_alias import AtomicU8
from std.memory import alloc, UnsafePointer, OwnedPointer

from komira_log.log_write import LogWriteLosses, write_log_line


# -----------------------------------------------------------------------------
# stderr is fd 2 on every POSIX platform (Linux + macOS, our two targets).
# -----------------------------------------------------------------------------

comptime _STDERR_FD: Int32 = 2


# -----------------------------------------------------------------------------
# The process-static write lock. An `Atomic[bool]` test-and-set spin-lock.
# Logging is bursty + lines are short, so contention is negligible and a spin
# (no syscall) is the right primitive — a futex/mutex would be heavier for the
# ~microsecond critical section of one `write(2)`.
#
# The lock lives inside `StderrSink` which the process-static `LogConfig`
# singleton owns (config.mojo). One lock per process → all log lines serialize
# through it. (P2 replaces this synchronous sink + lock entirely with the
# per-core ring drain; the lock is a P1-only artifact behind the stable
# facade.)
# -----------------------------------------------------------------------------


struct StderrSink(Movable):
    """Thread-safe synchronous stderr appender (fd 2).

    `Atomic` is NOT Movable in Mojo, so the lock word lives behind an
    `OwnedPointer[Atomic[DType.uint8]]`. This keeps
    `StderrSink` (and its owner `LogConfig`) Movable.
    """

    # SAFETY: the lock word is heap-owned via OwnedPointer (the
    # non-Movable-payload pattern). 0 == unlocked, 1 == locked.
    var _lock: OwnedPointer[AtomicU8]
    # Lines this sink failed to put on fd 2 whole. Counting them is the
    # difference between "the logger is lossy under pressure" and "the logs
    # are fine".
    var _losses: LogWriteLosses

    def __init__(out self):
        var raw = alloc[AtomicU8](1)
        raw[] = AtomicU8(UInt8(0))
        self._lock = OwnedPointer[AtomicU8](
            unsafe_from_raw_pointer=raw
        )
        self._losses = LogWriteLosses()

    @always_inline
    def _acquire(mut self):
        # SAFETY: a simple test-and-set spin-lock. `compare_exchange(expected,
        # 1)` spins until it flips 0→1. No syscall; the critical section is a
        # single `write(2)` of a short line, so the spin is sub-microsecond.
        while True:
            var expected = UInt8(0)
            if self._lock[].compare_exchange(expected, UInt8(1)):
                return

    @always_inline
    def _release(mut self):
        # Release the lock (store 0) with the static `Atomic.store` form.
        AtomicU8.store(
            UnsafePointer(to=self._lock[]).unsafe_bitcast[Scalar[DType.uint8]](), UInt8(0)
        )

    def write_line(mut self, line: String):
        """Write `line` to stderr atomically (whole-line, single write(2)).

        The caller passes the FULLY rendered line WITHOUT a trailing newline;
        this method appends '\\n' and issues one guarded `write(2)`.
        """
        var out = line + "\n"
        self._acquire()
        self._write_all(out)
        self._release()

    def _write_all(mut self, s: String):
        """Put `s` on fd 2 best-effort, count what does not make it, and
        announce any NEW losses on the next healthy line.

        ★ A BOUNDED RETRY BUDGET, NOT A `break` ON THE FIRST NON-POSITIVE
        RETURN. Without it an EINTR (routine: a platform SIGTERM on scale-down)
        or an EAGAIN on a congested fd 2 silently truncates the line
        mid-message, and nothing counts it. `write_log_line` classifies the errno, retries the
        transient cases within a bounded budget, gives up at once on a dead fd
        and RETURNS what happened.

        ⛔ IT DOES NOT RAISE, and that is deliberate — the rule `komira_core`'s
        fd write-all states: "losing a diagnostic beats wedging the process". A logger gives up. What it may not do is give up
        SILENTLY.
        """
        var outcome = write_log_line(_STDERR_FD, s)
        self._losses.note(outcome)
        # ⭐ EDGE-REPORT, mirroring `_report_overflow_drops`: announce each new
        # batch of losses once rather than re-printing a cumulative total per
        # line. Gated on `complete()` so the announcement is attempted only
        # when fd 2 has just proven healthy — a report written into the same
        # congestion that caused the loss is a second lost line, and its
        # outcome is deliberately NOT noted, so this can never recurse.
        if outcome.complete():
            var report = self._losses.take_report()
            if report.byte_length() > 0:
                _ = write_log_line(_STDERR_FD, report + "\n")

    @always_inline
    def dropped_line_count(self) -> Int64:
        """Lines of which NOTHING reached fd 2. NON-ZERO MEANS LOG LINES WERE
        LOST."""
        return self._losses.lines_lost

    @always_inline
    def truncated_line_count(self) -> Int64:
        """Lines of which only a PREFIX reached fd 2 — once the Cloud-Logging
        JSON layout lands, a malformed entry the collector DROPS rather than a
        damaged one it keeps."""
        return self._losses.lines_truncated

    @always_inline
    def last_write_errno(self) -> Int32:
        """The errno of the most recent loss, 0 if there has been none."""
        return self._losses.last_errno
