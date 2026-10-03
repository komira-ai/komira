# =============================================================================
# komira_log.log_write — the write(2) loop EVERY rendered log line goes through.
# =============================================================================
#
# # The defect this exists to make impossible
#
# The naive loop that carries a rendered log line to a file descriptor is
#
#     if n <= 0:
#         break        # <- no retry, no classification, no counter
#
# and it breaks on the FIRST non-positive return.
#
# ⚠ `n <= 0` IS NOT ONE CONDITION. IT IS TWO, AND THEY WANT OPPOSITE ANSWERS:
#
#   * **RETRYABLE** — `EINTR`, `EAGAIN`/`EWOULDBLOCK`. Transient; the line is
#     still deliverable. EINTR is not exotic: container platforms SIGTERM
#     every container on scale-down, so a signal landing inside `write(2)` is
#     a routine event, and `break` cuts the line at the byte it arrived on.
#   * **FATAL** — `EPIPE`, `EBADF`, `ENOSPC`, anything else. The fd is gone.
#     Retrying is a spin, and a spin in a logger is worse than the drop.
#
# # ⛔ What this does NOT change
#
# A logger loop is RIGHT to give up rather than raise — "losing a diagnostic
# beats wedging the process" (the rule `komira_core.io.fd_write_all` states).
# Nothing here raises. Nothing here blocks, sleeps or yields. Nothing here can
# iterate more than `len(payload) + budget` times. What this adds is that
# giving up is BOUNDED, CLASSIFIED and COUNTED instead of immediate, blind and
# silent.
#
# # Why a module and not a copy of the loop at each sink
#
# Because the defect lives in the copies: one loop, transcribed per sink, wrong
# per sink, and twins that nobody can fix in one place. This is the same
# argument `fd_write_all` makes for itself — a call site gets the policy by
# CALLING, not by remembering.
#
# # Why `komira_log` and not `komira_core`
#
# It has to be reachable from BOTH `komira_log` and `komira_http`, and
# `komira_log` is the package `komira_http` already depends on for logging. `komira_core`
# would also work and is the more obvious home for an io helper, but nearly
# every package depends on it and this does not need to be upstream of
# everything to do its job. This module imports only `komira_core`, so the
# edge is acyclic and the blast radius is the logging consumers — exactly the
# population that cares.
#
# # Sans-IO: the policy is a pure state machine
#
# `LineWrite` observes `(n, errno)` pairs and returns a verdict. It issues no
# syscall, so every sequence a kernel could produce — a short write, a signal
# mid-line, a permanently-congested fd, a `write` that returns 0 — is testable
# by hand, deterministically, with no signals and no timing. `write_line_best_
# effort` is the thin shell that turns real `write(2)` returns into those
# observations. The anti-spin property is proven against the state machine,
# where it is a property rather than a hope.
#
# # ⚠ errno is ONLY meaningful when `n < 0`
#
# Observed on linux-x86_64, Mojo 1.0.0, through `external_call["write", Int]`:
#
#     write(-1, ...)  -> n=-1, errno=9   (EBADF)
#     write(1,  ...)  -> n=6,  errno=9   (STALE — success does NOT clear it)
#     write(full non-blocking pipe) -> n=-1, errno=11 (EAGAIN)
#
# So a successful write leaves the PREVIOUS failure's errno in place. This
# module reads errno only on a negative return and passes 0 otherwise, and
# `log_write_errno_is_retryable(0)` is False so an unattributable failure is
# never treated as transient.
#
# # FFI / encapsulation
#
# Public surface is `Int32` / `Span[UInt8, _]` / `String` / `Int` / POD structs.
# The `unsafe_ptr()` arithmetic is confined to one function body; the pointer is
# read-only, never escapes, and the payload's origin pins the backing storage
# across the whole loop. `write(2)` copies into the kernel and retains nothing.
#
# `komira_write_bytes` (not a bare `external_call["write", ...]`) is the same
# choice `fd_write_all` made and for its reason: a bare `write` declaration
# collides with the stdlib's own reserved one once a link unit's closure also
# pulls in `std.os`'s, and `komira_log` sits in large closures. The shim is
# `komira_core`'s C wrapper library, and it is a direct `return write(...)`
# with no intervening libc call — so errno survives the extra C frame. The
# syscall arms of the test assert exactly that against a real kernel.
#
# Test coverage:
# `tests/test_log_write_retry_and_loss_accounting.mojo`.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call

from komira_core.io.fd_write_all import FD_WRITE_MAX_CALL_BYTES


# -----------------------------------------------------------------------------
# The budget.
# -----------------------------------------------------------------------------
#
# 8 immediate retries. The value is chosen against the case it EXISTS for:
# EINTR, which succeeds on the very next call — one retry would do. The
# remaining headroom is for a congested fd, where each retry is one more chance
# for the reader to drain, and where the cost of being wrong in the generous
# direction is 8 syscalls on a line that was going to be lost anyway.
#
# ⛔ It must stay SMALL and it must stay FINITE. "A retry budget that can loop
# on a permanently-failing fd is strictly worse than an immediate drop."
comptime LOG_WRITE_RETRY_BUDGET: Int = 8


# `LineWrite.observe` verdicts.
comptime LOG_WRITE_CONTINUE: UInt8 = UInt8(0)
"""Bytes are still owed and the fd is worth calling again."""
comptime LOG_WRITE_COMPLETE: UInt8 = UInt8(1)
"""Every byte of the line reached the kernel."""
comptime LOG_WRITE_FATAL: UInt8 = UInt8(2)
"""The fd is gone (EPIPE/EBADF/ENOSPC/...). Stop at once; do not spin."""
comptime LOG_WRITE_EXHAUSTED: UInt8 = UInt8(3)
"""The failure was transient but the budget ran out. Stop; the line is lost or
truncated, and either way it is COUNTED."""


@always_inline
def log_write_eintr_errno() -> Int32:
    """`EINTR` — 4 on Linux and on Darwin (POSIX historical; the two agree)."""
    return Int32(4)


@always_inline
def log_write_eagain_errno() -> Int32:
    """`EAGAIN`/`EWOULDBLOCK` for the current platform: 11 on Linux, 35 on
    Darwin. POSIX guarantees `EAGAIN == EWOULDBLOCK` on each.

    ⚠ THE ONE ERRNO *VALUE* IN THIS FILE THAT IS NOT PORTABLE — it is NOT the
    only non-portable thing in this file. A hardcoded 11 makes every congested
    write on macOS classify FATAL and give up on the first stall — i.e. the
    defect this module closes, reintroduced on one platform.
    Mirrors `komira_async.reactor.socket_io._eagain_errno`, which cannot be
    imported here (`komira_log` is below `komira_async`; the edge would cycle).

    ⛔ THE SECOND NON-PORTABLE FACT IS THE *SYMBOL* THAT READS ERRNO. It lives
    in `log_write_read_errno()` below. If you add a third, amend this sentence
    in the same change — a comment that says "the one" when there are two
    reads as complete when it is not.
    """
    comptime if CompilationTarget.is_macos():
        return Int32(35)
    else:
        return Int32(11)


@always_inline
def log_write_read_errno() -> Int32:
    """The calling thread's current `errno`, on either platform.

    ⚠ THE SYMBOL THAT RETURNS `int*` IS SPELLED DIFFERENTLY ON THE TWO
    PLATFORMS: glibc exports `__errno_location`, Darwin's libSystem exports
    `__error`. Neither is a macro at the ABI layer and neither exists on the
    other platform, so an unbranched `external_call["__errno_location", ...]`
    COMPILES on macOS and fails at LINK — `___errno_location` undefined for
    arm64, so no darwin binary in this library's closure would link. Same shape as
    `komira_async.reactor.socket_io.errno_get`, which cannot be imported here
    (`komira_log` is below `komira_async`; the edge would cycle).

    ⚠ ONLY MEANINGFUL IMMEDIATELY AFTER A FAILING CALL, and only when that
    call returned < 0 — see the file header. errno is thread-local scratch
    that ANY intervening libc call may overwrite, assertion helpers included.

    SAFETY: the libc helper returns a stable per-pthread `int*`. We read the
    Int32 at that address in this function body; no pointer escapes, so no
    `UnsafePointer` crosses a module boundary.
    """
    comptime if CompilationTarget.is_macos():
        # Darwin / libSystem: `__error()` returns int*.
        var errno_ptr = external_call[
            "__error", UnsafePointer[Int32, MutUntrackedOrigin]
        ]()
        return errno_ptr[]
    else:
        # Linux / glibc: `__errno_location()` returns int*.
        var errno_ptr = external_call[
            "__errno_location", UnsafePointer[Int32, MutUntrackedOrigin]
        ]()
        return errno_ptr[]


@always_inline
def log_write_errno_is_retryable(err: Int32) -> Bool:
    """True iff `err` says the line is STILL DELIVERABLE.

    Exactly `EINTR` and `EAGAIN`/`EWOULDBLOCK`. Everything else — including
    `0` — is fatal. Zero is deliberate: `write(2)` does not clear errno on
    success, so a caller that could not attribute a failure passes 0, and
    "unattributable" must not be read as "transient".
    """
    return err == log_write_eintr_errno() or err == log_write_eagain_errno()


# -----------------------------------------------------------------------------
# LineWrite — the policy, as a pure state machine.
# -----------------------------------------------------------------------------


struct LineWrite(Copyable, Movable):
    """Sans-IO progress + retry accounting for ONE line.

    Feed it `(n, errno)` pairs as `write(2)` returns them; it answers with a
    verdict and, when the loop ends, says which of the three bad outcomes it
    was. Issues no syscall, so the anti-spin property is provable by hand.
    """

    var total: Int
    """Bytes owed."""
    var written: Int
    """Bytes the kernel has accepted so far."""
    var retries: Int
    """Retryable stalls absorbed. NEVER exceeds `LOG_WRITE_RETRY_BUDGET`;
    reaching it is what produces `LOG_WRITE_EXHAUSTED`."""
    var last_errno: Int32
    """The errno of the most recent failing call, or 0 if none failed."""
    var status: UInt8
    """The current verdict (`LOG_WRITE_*`)."""

    def __init__(out self, total: Int):
        self.total = total
        self.written = 0
        self.retries = 0
        self.last_errno = Int32(0)
        self.status = (
            LOG_WRITE_COMPLETE if total <= 0 else LOG_WRITE_CONTINUE
        )

    def observe(mut self, n: Int, err: Int32) -> UInt8:
        """Record one `write(2)` return and answer whether to call again.

        Args:
            n: The syscall's return value. `> 0` is progress, `< 0` is a
                failure, `0` is the unspecified no-progress case.
            err: The errno — MEANINGFUL ONLY WHEN `n < 0`. Pass 0 otherwise;
                `write(2)` leaves errno untouched on success, so reading it
                after a good call yields a stale value from an earlier failure.

        Returns:
            One of `LOG_WRITE_CONTINUE` / `_COMPLETE` / `_FATAL` / `_EXHAUSTED`.
            Once it is not `_CONTINUE` the loop is over; further observations
            are refused (the verdict is sticky).
        """
        if self.status != LOG_WRITE_CONTINUE:
            return self.status
        if n > 0:
            self.written += n
            if self.written >= self.total:
                self.status = LOG_WRITE_COMPLETE
            return self.status
        # n <= 0. A NEGATIVE return carries an errno; a ZERO return does not
        # (POSIX leaves `write` returning 0 for a non-empty buffer
        # unspecified), so it can be classified by nothing and is treated as a
        # stall — which is what makes it terminate instead of spinning.
        if n < 0:
            self.last_errno = err
            if not log_write_errno_is_retryable(err):
                # ⛔ FATAL. Give up NOW, without spending a single retry. The
                # budget exists for a deliverable line; on a dead fd it is a
                # spin, and the old comment named that hazard exactly.
                self.status = LOG_WRITE_FATAL
                return self.status
        # Transient (or unclassifiable-but-no-progress): spend the budget.
        #
        # ⚠ THE BUDGET IS NOT RESET BY PROGRESS, DELIBERATELY. With a reset, a
        # fd that alternates one-byte-progress with a stall runs
        # `total * budget` iterations. Without one, the WHOLE loop is bounded
        # by `total + budget` — which is the bound the anti-spin arm asserts.
        self.retries += 1
        # `>=`, so the invariant is exactly `retries <= LOG_WRITE_RETRY_BUDGET`
        # and "budget" means what it reads as: the greatest number of retryable
        # stalls this line will absorb before it is given up on.
        if self.retries >= LOG_WRITE_RETRY_BUDGET:
            self.status = LOG_WRITE_EXHAUSTED
        return self.status

    @always_inline
    def complete(self) -> Bool:
        """Every byte reached the kernel."""
        return self.status == LOG_WRITE_COMPLETE

    @always_inline
    def truncated(self) -> Bool:
        """PART of the line reached the fd and the rest did not.

        ⚠ The worse of the two failures once a line is JSON (the structured
        layout `komira_log` renders on a deployed platform). A truncated TEXT line is a damaged entry
        an operator can still read; a truncated JSON line is unparseable, so
        the collector DROPS it and the entry is gone entirely.
        """
        return not self.complete() and self.written > 0

    @always_inline
    def lost(self) -> Bool:
        """NOTHING of the line reached the fd."""
        return not self.complete() and self.written == 0


# -----------------------------------------------------------------------------
# LogWriteLosses — the accounting, and the edge-triggered announcement.
# -----------------------------------------------------------------------------


struct LogWriteLosses(Copyable, Movable):
    """Per-sink loss counters plus a watermark, so a sink can announce NEW
    losses without re-printing a cumulative total on every line.

    Modelled on `komira_log_index.app_log_engine._report_overflow_drops`, which
    solves the identical problem for ring-overflow drops: a counter that only
    tests read is not observability, and a level-triggered report on a
    congested fd is itself a log flood.

    ⚠ IT IS A FIELD, NOT A PROCESS GLOBAL. Mojo 1.0.0 has no mutable
    module-level globals, and a new C translation unit for a counter would be a far bigger change
    than the defect warrants. Every sink that owns one of these is itself
    process-static — `LogConfig` owns the `StderrSink`, `SharedEngine` owns the
    `LogSink` — so the field IS the process counter, reachable through that
    owner. A caller with no owning struct (a free function) reports by writing
    an SOS line to the OTHER fd instead.
    """

    var lines_lost: Int64
    """Lines of which NOTHING reached the fd."""
    var lines_truncated: Int64
    """Lines of which only a PREFIX reached the fd."""
    var last_errno: Int32
    """The errno of the most recent loss, 0 if none."""
    var reported: Int64
    """`lines_lost + lines_truncated` as of the last `take_report()`."""

    def __init__(out self):
        self.lines_lost = Int64(0)
        self.lines_truncated = Int64(0)
        self.last_errno = Int32(0)
        self.reported = Int64(0)

    @always_inline
    def note(mut self, w: LineWrite):
        """Record the outcome of one line. A completed line costs nothing."""
        if w.complete():
            return
        if w.written > 0:
            self.lines_truncated += Int64(1)
        else:
            self.lines_lost += Int64(1)
        self.last_errno = w.last_errno

    @always_inline
    def total(self) -> Int64:
        """Lines this sink failed to deliver whole. NON-ZERO MEANS LOG LINES
        WERE LOST — the number an operator actually wants."""
        return self.lines_lost + self.lines_truncated

    @always_inline
    def unreported(self) -> Int64:
        """Losses since the last announcement."""
        return self.total() - self.reported

    def take_report(mut self) -> String:
        """The announcement for any NEW losses, and advance the watermark.

        Returns "" when there is nothing new, so a caller can write it
        unconditionally and stay silent on the healthy path.
        """
        var newly = self.unreported()
        if newly <= Int64(0):
            return String("")
        self.reported = self.total()
        return (
            String("komira_log: DROPPED ")
            + String(newly)
            + String(" log line(s) at the sink write — ")
            + String(self.lines_lost)
            + String(" lost, ")
            + String(self.lines_truncated)
            + String(" TRUNCATED (cumulative), last errno=")
            + String(Int(self.last_errno))
            + String(
                ". A truncated line is a malformed entry the collector drops,"
                " not a damaged one it keeps."
            )
        )


# -----------------------------------------------------------------------------
# write_line_best_effort — the IO shell.
# -----------------------------------------------------------------------------


def write_line_best_effort(fd: Int32, payload: Span[UInt8, _]) -> LineWrite:
    """Write every byte of `payload` to `fd`, best-effort. NEVER raises, never
    blocks, never spins.

    THE CONTRACT, in one line: a retryable failure is retried up to
    `LOG_WRITE_RETRY_BUDGET` times, a fatal one gives up at once, and either
    way the outcome is RETURNED so the caller can count it.

    Args:
        fd: An open, writable file descriptor. A bad one is not an error here —
            it is an `LOG_WRITE_FATAL` outcome with `EBADF` recorded.
        payload: The fully-rendered line, newline included. Empty issues NO
            syscall and reports complete, mirroring
            `komira_core.io.fd_write_all.write_all_fd`.

    Returns:
        The `LineWrite` describing what happened. `complete()` on the healthy
        path; otherwise `truncated()` or `lost()`, with `last_errno` set.
    """
    var total = len(payload)
    var w = LineWrite(total)
    if total == 0:
        return w^
    # SAFETY: `payload.unsafe_ptr()` is the caller's own buffer, read-only, and
    # never escapes this function. The Span's origin pins the backing storage
    # alive across every iteration; `write(2)` copies into the kernel and
    # retains nothing. No pointer crosses a module boundary.
    var base = payload.unsafe_ptr()
    while w.status == LOG_WRITE_CONTINUE:
        var remaining = total - w.written
        # The per-call clamp, taken from the canonical writer rather than
        # restated. `fd_write_all` records that it is unreachable for a
        # logger (a line is never 64 MiB) — it is applied anyway so this is a
        # strict superset of that loop and cannot become the outlier later.
        var request = remaining
        if request > FD_WRITE_MAX_CALL_BYTES:
            request = FD_WRITE_MAX_CALL_BYTES
        # ⚠ `fd` GOES IN AS `Int32`, NOT `Int(fd)`. Mojo legalizes ONE
        # signature per external symbol per link unit, and the two existing
        # declarations of this shim (`komira_core.io.posix_io.RawWriteFd.
        # write_bytes` and `komira_core.io.fd_write_all.write_all_fd`) both
        # pass it as `Int32`. An `Int(fd)` here widens the first argument to
        # `index` and the link fails with "existing function with conflicting
        # signature" as soon as this module shares a closure with another
        # declaration of the same symbol.
        var n = external_call["komira_write_bytes", Int](
            fd, base + w.written, UInt64(request)
        )
        # ⚠ errno is read ONLY on a negative return. A successful `write(2)`
        # leaves the PREVIOUS failure's errno in place (see the file
        # header), so reading it unconditionally attributes a healthy write to
        # a stale cause.
        var err = Int32(0)
        if n < 0:
            err = log_write_read_errno()
        _ = w.observe(Int(n), err)
    # Keep the buffer alive across the whole loop (the pointer above aliases
    # it).
    _ = base
    return w^


@always_inline
def write_log_line(fd: Int32, line: String) -> LineWrite:
    """`write_line_best_effort` over a `String`'s bytes — the spelling every
    caller in the tree actually wants, since a rendered log line is a String.

    The caller appends its own newline; this does not, because the three sinks
    build `line + "\\n"` as ONE String precisely so the newline rides the same
    single `write(2)` and two threads cannot splice half a line into another.
    """
    return write_line_best_effort(fd, line.as_bytes())
