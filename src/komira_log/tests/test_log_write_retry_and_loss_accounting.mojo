# =============================================================================
# test_log_write_retry_and_loss_accounting.mojo — the write(2) loop EVERY
# rendered log line funnels through.
# =============================================================================
#
# THE DEFECT CLASS. The naive `write(2)` loop a log sink reaches for is
#
#     if n <= 0:
#         break        # <- no retry, no classification, no counter
#
# ⚠ `n <= 0` IS NOT ONE CONDITION, IT IS TWO, AND THEY WANT OPPOSITE ANSWERS:
#
#   * EINTR / EAGAIN — the line is STILL DELIVERABLE. Container platforms send
#     SIGTERM on scale-down, so a signal landing mid-`write(2)` is a
#     routine event, not an exotic one, and `break` silently truncates the line
#     at the byte the signal arrived on.
#   * EPIPE / EBADF / ENOSPC — the fd is gone. Retrying is a spin.
#
# The naive loop answers both with "drop it, tell nobody". The §LEGACY arms
# below are a CHARACTERIZATION of that loop, driven against a real kernel with
# a real errno -- the evidence the defect is real rather than argued.
#
# ⛔ THE RULE THIS DOES **NOT** OVERTURN. `komira_libc.fd_write_all`
# states that a logger loop is RIGHT to give up rather than raise: "losing a
# diagnostic beats wedging the process". That stands. Nothing here raises and
# nothing here spins; what changes is that giving up is BOUNDED, CLASSIFIED
# and COUNTED instead of immediate, blind and silent.
#
# ⭐ WHY A NON-BLOCKING PIPE IS THE FIXTURE. It is the only way to get a
# genuine short write AND a genuine retryable errno out of a real kernel with
# no signals, no timing and no races: fill the pipe, and `write(2)` delivers
# exactly the bytes that fit (a PARTIAL write) and then -1/EAGAIN forever. A
# state machine driven by hand can assert the policy; only this can assert that
# the errno is readable from Mojo at all.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_log.log_write import (
    LOG_WRITE_RETRY_BUDGET,
    LOG_WRITE_CONTINUE,
    LOG_WRITE_COMPLETE,
    LOG_WRITE_FATAL,
    LOG_WRITE_EXHAUSTED,
    LineWrite,
    LogWriteLosses,
    log_write_eagain_errno,
    log_write_eintr_errno,
    log_write_errno_is_retryable,
    log_write_read_errno,
    write_line_best_effort,
    write_log_line,
)


# POSIX errno values. EINTR/EPIPE/EBADF/ENOSPC agree on Linux and Darwin;
# EAGAIN does not (11 vs 35), which is why the module derives it at comptime.
comptime _EINTR: Int32 = 4
comptime _EBADF: Int32 = 9
comptime _ENOSPC: Int32 = 28
comptime _EPIPE: Int32 = 32


# -----------------------------------------------------------------------------
# Fixture — a non-blocking pipe, filled.
# -----------------------------------------------------------------------------


struct _FullPipe(Deinitable):
    """A pipe whose WRITE end is O_NONBLOCK and whose buffer is full.

    `w` is then an fd on which `write(2)` returns -1/EAGAIN for a small payload
    and a PARTIAL count for one that straddles the remaining space.
    """

    var r: Int32
    var w: Int32
    var ok: Bool

    def __init__(out self):
        self.r = Int32(-1)
        self.w = Int32(-1)
        self.ok = False
        var fds = alloc[Int32](2)
        fds[0] = Int32(-1)
        fds[1] = Int32(-1)
        var rc = external_call["pipe", Int32](fds)
        if Int(rc) != 0:
            fds.unsafe_free()
            return
        self.r = fds[0]
        self.w = fds[1]
        fds.unsafe_free()
        # `komira_fcntl_set_nonblock` is the fixed-arity C wrapper
        # the core packages links. A bare variadic `fcntl` is
        # register/stack-ABI-fragile on Apple ARM64.
        _ = external_call["komira_fcntl_set_nonblock", Int32](self.w)
        self.ok = True

    def fill(mut self):
        """Fill the pipe buffer, so the next write stalls."""
        if not self.ok:
            return
        var chunk = String("x") * 1024
        # SAFETY: read-only view of a local String, consumed synchronously by
        # write(2) and never retained. Confined to this fixture.
        var base = chunk.unsafe_ptr()
        var guard = 0
        while guard < 4096:
            var n = external_call["komira_write_bytes", Int](
                self.w, base, UInt64(1024)
            )
            if n < 1024:
                break
            guard += 1
        _ = base
        _ = chunk

    # ⚠ THE WRITES GO THROUGH METHODS, AND THAT IS NOT STYLE. Mojo destroys a
    # value at its LAST USE (ASAP destruction), so `write_log_line(p.w, line)`
    # reads `p.w` into an Int32 argument, ends `p`'s lifetime, runs
    # `__deinit__` -- which closes both fds -- and only THEN performs the
    # write. Measured here first: every pipe arm came back EBADF(9) on a pipe
    # that had just been created successfully. Borrowing `self` across the call
    # is what keeps the fds open for it.

    def best_effort(mut self, s: String) -> LineWrite:
        return write_log_line(self.w, s)

    def legacy(mut self, s: String) -> _LegacyOutcome:
        return _legacy_write_loop(self.w, s)

    def __deinit__(deinit self):
        if Int(self.r) >= 0:
            _ = external_call["close", Int32](self.r)
        if Int(self.w) >= 0:
            _ = external_call["close", Int32](self.w)


struct _LegacyOutcome(Copyable, Movable):
    """What the naive loop managed, and what it walked away from."""

    var written: Int
    var errno_at_stop: Int32

    def __init__(out self, written: Int, errno_at_stop: Int32):
        self.written = written
        self.errno_at_stop = errno_at_stop


def _legacy_write_loop(fd: Int32, s: String) -> _LegacyOutcome:
    """The naive loop -- the only addition is that it CAPTURES the errno it
    ignores, so this test can show what the loop throws away.

    ⚠ THE ERRNO READ GOES THROUGH `log_write_read_errno()`, NOT A BARE
    `external_call["__errno_location", ...]`: on darwin the bare glibc symbol
    COMPILES and fails at LINK. The characterization is of the loop's
    BEHAVIOUR -- what it does with the errno -- and the platform spelling of
    the reader is not part of it.

    ⚠ THE CAPTURE IS INSIDE THE LOOP, IMMEDIATELY AFTER THE FAILING CALL.
    Reading errno after the following `assert_true` can see EBADF(9) where the
    kernel had set EAGAIN(11): errno is thread-local scratch that ANY intervening libc call
    may overwrite, assertion helpers included. `log_write.write_line_best_
    effort` reads it in the same statement-adjacent position for this reason.
    """
    var total = len(s.as_bytes())
    var off = 0
    var err = Int32(0)
    # SAFETY: read-only, never escapes, `s` outlives the loop.
    var base = s.unsafe_ptr()
    while off < total:
        var n = external_call["komira_write_bytes", Int](
            fd, base + off, UInt64(total - off)
        )
        if n <= 0:
            if n < 0:
                err = log_write_read_errno()
            break
        off += Int(n)
    _ = base
    return _LegacyOutcome(off, err)


# =============================================================================
# §POLICY — the classifier. Pure, no syscall.
# =============================================================================


def test_retryable_errnos_are_exactly_eintr_and_eagain() raises:
    """EINTR and EAGAIN mean the line is still deliverable; everything else
    means the fd is gone and retrying is a spin."""
    assert_true(
        log_write_errno_is_retryable(log_write_eintr_errno()),
        "EINTR is RETRYABLE -- a signal landing mid-write is the single most"
        " likely cause of a partial log write on a container platform, which"
        " SIGTERMs every container on scale-down",
    )
    assert_equal(
        log_write_eintr_errno(), _EINTR, "EINTR is 4 on Linux and on Darwin"
    )
    assert_true(
        log_write_errno_is_retryable(log_write_eagain_errno()),
        "EAGAIN/EWOULDBLOCK is RETRYABLE -- a congested non-blocking fd 1/2",
    )
    assert_false(
        log_write_errno_is_retryable(_EPIPE),
        "EPIPE is FATAL. The collector is gone; a retry budget spent here is a"
        " spin, which is strictly worse than the drop it replaces",
    )
    assert_false(
        log_write_errno_is_retryable(_EBADF), "EBADF is FATAL"
    )
    assert_false(
        log_write_errno_is_retryable(_ENOSPC), "ENOSPC is FATAL"
    )
    assert_false(
        log_write_errno_is_retryable(Int32(0)),
        "errno 0 is FATAL, and deliberately so: write(2) leaves errno UNTOUCHED"
        " on success (a successful write after a failed one still reads the"
        " STALE errno), so a 0 reaching the classifier means the"
        " caller could not attribute the failure. Unattributable is not"
        " retryable.",
    )


def test_eagain_is_platform_derived_not_hardcoded() raises:
    """EAGAIN is 11 on Linux and 35 on Darwin -- the ONE errno VALUE in this
    classifier that is not portable, but NOT the only non-portable thing in
    `log_write.mojo`; the symbol that READS errno is the other, and is covered
    by `test_errno_is_readable_on_THIS_platform` below. A hardcoded 11 would
    make every congested write on macOS classify FATAL and give up
    instantly."""
    var e = log_write_eagain_errno()
    assert_true(
        e == Int32(11) or e == Int32(35),
        "EAGAIN must be the platform's value (Linux 11 / Darwin 35), got "
        + String(Int(e)),
    )


# =============================================================================
# §STATE MACHINE — the retry/give-up policy as a pure function. No fd, no
# kernel, no signal: every sequence a kernel could produce, driven by hand.
# =============================================================================


def test_a_short_write_completes_the_line() raises:
    """Three partial writes that sum to the total = one delivered line. This is
    the case the loop ALWAYS handled; it is here so a retry budget cannot be
    added in a way that breaks it."""
    var w = LineWrite(10)
    assert_equal(w.observe(4, Int32(0)), LOG_WRITE_CONTINUE)
    assert_equal(w.observe(4, Int32(0)), LOG_WRITE_CONTINUE)
    assert_equal(w.observe(2, Int32(0)), LOG_WRITE_COMPLETE)
    assert_true(w.complete(), "all 10 bytes landed")
    assert_false(w.truncated(), "a completed line is not truncated")
    assert_false(w.lost(), "a completed line is not lost")
    assert_equal(w.retries, 0, "progress is not a retry")


def test_a_transient_failure_retries_and_completes() raises:
    """EINTR mid-line, then the write goes through. TODAY THIS LINE IS CUT IN
    HALF; the whole point of the fix is that it arrives."""
    var w = LineWrite(10)
    assert_equal(w.observe(4, Int32(0)), LOG_WRITE_CONTINUE)
    assert_equal(
        w.observe(-1, log_write_eintr_errno()),
        LOG_WRITE_CONTINUE,
        "EINTR must not end the line -- 6 bytes are still owed",
    )
    assert_equal(w.observe(6, Int32(0)), LOG_WRITE_COMPLETE)
    assert_true(w.complete(), "the line arrived WHOLE despite the signal")
    assert_equal(w.retries, 1, "and it cost exactly one retry")


def test_a_fatal_failure_gives_up_immediately_without_spending_the_budget(
) raises:
    """EPIPE on the first call. One observation, no retries, done. A budget
    spent on a dead fd is the unbounded spin the old comment warned about."""
    var w = LineWrite(10)
    assert_equal(w.observe(-1, _EPIPE), LOG_WRITE_FATAL)
    assert_equal(
        w.retries, 0, "a FATAL errno must not consume a single retry"
    )
    assert_true(w.lost(), "nothing landed, so the line is LOST, not truncated")
    assert_false(w.truncated())
    assert_equal(w.last_errno, _EPIPE, "and the cause is recorded")


def test_a_fatal_failure_after_partial_progress_is_TRUNCATED_not_lost(
) raises:
    """The distinction that matters once every line is JSON: a line that half
    landed is a MALFORMED entry the collector drops, which is a different
    failure from a line that never left."""
    var w = LineWrite(10)
    assert_equal(w.observe(4, Int32(0)), LOG_WRITE_CONTINUE)
    assert_equal(w.observe(-1, _EPIPE), LOG_WRITE_FATAL)
    assert_true(w.truncated(), "4 of 10 bytes on the wire == TRUNCATED")
    assert_false(w.lost())


def test_the_retry_budget_TERMINATES_against_a_permanently_failing_fd(
) raises:
    """⛔ THE ANTI-SPIN ARM. A fd that returns EAGAIN forever must exhaust the
    budget and STOP. A retry budget that can loop on a permanently-failing fd
    is strictly worse than the drop it replaces -- it wedges the process, which
    is the one thing a logger may never do."""
    var w = LineWrite(10)
    var steps = 0
    var verdict = LOG_WRITE_CONTINUE
    while steps < 10000:
        verdict = w.observe(-1, log_write_eagain_errno())
        steps += 1
        if verdict != LOG_WRITE_CONTINUE:
            break
    assert_equal(
        verdict,
        LOG_WRITE_EXHAUSTED,
        "a permanently-retryable fd must end in EXHAUSTED, never CONTINUE",
    )
    assert_equal(
        steps,
        LOG_WRITE_RETRY_BUDGET,
        "and it must end after exactly BUDGET stalls -- not 10000. The"
        " invariant is `retries <= LOG_WRITE_RETRY_BUDGET`, always.",
    )
    assert_true(w.lost(), "nothing landed")


def test_the_total_iteration_count_is_bounded_by_length_plus_budget() raises:
    """The budget is NOT reset by progress, and that is deliberate: with a
    reset, a fd alternating 1-byte-progress / EAGAIN runs len * BUDGET
    iterations. Without one the whole loop is bounded by len + BUDGET."""
    var w = LineWrite(4)
    var steps = 0
    var verdict = LOG_WRITE_CONTINUE
    while steps < 10000:
        # alternate: one byte of progress, then a retryable stall
        if steps % 2 == 0:
            verdict = w.observe(1, Int32(0))
        else:
            verdict = w.observe(-1, log_write_eagain_errno())
        steps += 1
        if verdict != LOG_WRITE_CONTINUE:
            break
    assert_true(
        steps <= 4 + LOG_WRITE_RETRY_BUDGET,
        "bounded by total + budget, got " + String(steps),
    )


def test_a_zero_return_cannot_spin() raises:
    """`write(2)` returning 0 for a non-empty buffer is unspecified, and errno
    is NOT set -- so it can be classified by nothing. It must still terminate:
    it consumes the budget like a stall."""
    var w = LineWrite(10)
    var steps = 0
    var verdict = LOG_WRITE_CONTINUE
    while steps < 10000:
        verdict = w.observe(0, Int32(0))
        steps += 1
        if verdict != LOG_WRITE_CONTINUE:
            break
    assert_false(
        verdict == LOG_WRITE_CONTINUE, "a 0-return loop must terminate"
    )
    assert_true(
        steps <= LOG_WRITE_RETRY_BUDGET,
        "within the budget, got " + String(steps),
    )


# =============================================================================
# §LEGACY — the naive loop, against a real kernel. These arms are a
# CHARACTERIZATION: they describe the defect, they do not endorse it.
# =============================================================================


def test_LEGACY_the_old_loop_truncates_a_line_on_a_RECOVERABLE_stall() raises:
    """⛔ THE DEFECT, MEASURED. A full non-blocking pipe hands back a PARTIAL
    write and then EAGAIN -- a transient, recoverable condition -- and the
    naive loop abandons the line mid-message having retried zero times and
    counted nothing."""
    var p = _FullPipe()
    if not p.ok:
        # pipe(2) failed: nothing to characterize. Not a pass for the fix --
        # the state-machine arms above carry the policy either way.
        return
    p.fill()
    var line = String("y") * 65536
    var out = p.legacy(line)
    assert_true(
        out.written < len(line.as_bytes()),
        "the pipe is full, so the old loop CANNOT have written the whole line",
    )
    assert_equal(
        out.errno_at_stop,
        log_write_eagain_errno(),
        "and the errno it walked away from is EAGAIN -- RETRYABLE. The line was"
        " deliverable and the loop dropped it anyway.",
    )


def test_LEGACY_the_old_loop_leaves_no_evidence() raises:
    """The half that makes it "the logs are fine" rather than "the logger is
    lossy": the old loop's ONLY output is a byte count nobody reads. It returns
    the same `void` on a delivered line and on a destroyed one."""
    var lost = _legacy_write_loop(Int32(-1), String("a line nobody will see"))
    assert_equal(
        lost.written,
        0,
        "nothing was written to a closed fd -- and the caller is told nothing,"
        " which is the whole finding",
    )


# =============================================================================
# §SYSCALL — the new primitive against a real kernel. This is the arm that
# proves errno is READABLE from Mojo after `komira_write_bytes`; without it the
# classifier above is a well-tested fiction.
# =============================================================================


def test_errno_is_readable_on_THIS_platform() raises:
    """⭐ REGRESSION: the errno reader must RESOLVE AT LINK on this platform.

    glibc exports `__errno_location`; Darwin's libSystem exports `__error`.
    An unbranched `external_call["__errno_location", ...]` compiles fine on
    macOS and then fails at LINK -- `___errno_location` undefined for arm64 --
    so no darwin binary in `komira_log`'s closure would link. That is a LINK
    failure, so no test can observe it at run time; what this test does is
    exist on the darwin side of the branch, so a reintroduction of the
    unbranched spelling cannot produce a green mac build.

    The VALUE half is checkable and checked: `write(2)` on fd -1 sets EBADF,
    which is 9 on Linux and on Darwin, and the read is statement-adjacent to
    the failing call because errno is scratch any libc call may clobber."""
    var one = String("x")
    # SAFETY: read-only, never escapes, `one` outlives the call.
    var n = external_call["komira_write_bytes", Int](
        Int32(-1), one.unsafe_ptr(), UInt64(1)
    )
    var err = log_write_read_errno()
    _ = one
    assert_true(n < 0, "write(2) on fd -1 must fail; got n=" + String(n))
    assert_equal(
        err,
        _EBADF,
        "the platform's errno reader must return the REAL EBADF(9); got "
        + String(Int(err))
        + " -- a 0 here means the reader read the wrong thread-local, not that"
        " the write succeeded",
    )
    assert_false(
        log_write_errno_is_retryable(err), "and EBADF must classify FATAL"
    )


def test_a_fatal_fd_is_classified_from_a_REAL_errno_and_does_not_hang(
) raises:
    """fd -1 -> write(2) returns -1 and sets EBADF. If errno were unreadable
    across the FFI boundary this arm is the one that fails, and the whole
    retry/fatal split would be unwritable."""
    var out = write_log_line(Int32(-1), String("x" * 64))
    assert_equal(
        out.last_errno,
        _EBADF,
        "the REAL errno must survive `komira_write_bytes`; got "
        + String(Int(out.last_errno)),
    )
    assert_equal(
        out.status, LOG_WRITE_FATAL, "EBADF is fatal, so we stop at once"
    )
    assert_equal(out.retries, 0, "and we do NOT spin on a dead fd")
    assert_true(out.lost())


def test_a_congested_fd_retries_the_budget_then_stops_TRUNCATED() raises:
    """A full non-blocking pipe: the line partially lands, the rest stalls on a
    REAL EAGAIN, the budget is spent, and the outcome is TRUNCATED with the
    cause recorded. Contrast the §LEGACY arm, which does the first half and
    then goes quiet."""
    var p = _FullPipe()
    if not p.ok:
        return
    p.fill()
    var out = p.best_effort(String("z" * 65536))
    assert_false(out.complete(), "the pipe is full; the line cannot complete")
    assert_equal(
        out.status,
        LOG_WRITE_EXHAUSTED,
        "EAGAIN is retryable, so we must exhaust the budget rather than give"
        " up on the first stall the way the old loop did",
    )
    assert_equal(
        out.retries,
        LOG_WRITE_RETRY_BUDGET,
        "and we must have actually spent it",
    )
    assert_equal(out.last_errno, log_write_eagain_errno())


def test_the_happy_path_still_writes_every_byte_exactly_once() raises:
    """A pipe with room: the whole line lands, in one call, with no retries and
    nothing counted. The fix must be invisible when the fd is healthy."""
    var p = _FullPipe()
    if not p.ok:
        return
    var line = String("hello, operator\n")
    var out = p.best_effort(line)
    assert_true(out.complete(), "a healthy fd takes the whole line")
    assert_equal(out.written, len(line.as_bytes()))
    assert_equal(out.retries, 0)
    assert_equal(out.last_errno, Int32(0), "and nothing is attributed")


def test_an_empty_payload_issues_no_syscall() raises:
    """A zero-length line is complete by definition. Mirrors
    `komira_libc.fd_write_all.write_all_fd`, which returns 0 without a
    syscall for the same reason."""
    var out = write_log_line(Int32(-1), String(""))
    assert_true(out.complete(), "nothing owed, nothing lost")
    assert_equal(out.written, 0)
    assert_equal(
        out.last_errno,
        Int32(0),
        "and NO syscall was issued, so no errno was attributed -- on a fd that"
        " would have failed",
    )


# =============================================================================
# §ACCOUNTING — the counter. "Dropped or truncated" must leave evidence an
# operator can reach, or the difference between "lossy under pressure" and
# "fine" is invisible.
# =============================================================================


def test_losses_are_counted_separately_for_lost_and_truncated() raises:
    var acc = LogWriteLosses()
    assert_equal(acc.lines_lost, Int64(0))
    assert_equal(acc.lines_truncated, Int64(0))

    var lost = LineWrite(10)
    _ = lost.observe(-1, _EPIPE)
    acc.note(lost)

    var trunc = LineWrite(10)
    _ = trunc.observe(4, Int32(0))
    _ = trunc.observe(-1, _EPIPE)
    acc.note(trunc)

    var fine = LineWrite(10)
    _ = fine.observe(10, Int32(0))
    acc.note(fine)

    assert_equal(acc.lines_lost, Int64(1), "one line never left")
    assert_equal(
        acc.lines_truncated,
        Int64(1),
        "one line left in pieces -- which, once every line is JSON, is a"
        " DROPPED entry at the collector rather than a damaged one",
    )
    assert_equal(
        acc.last_errno, _EPIPE, "and the most recent cause is retained"
    )


def test_the_report_is_EDGE_triggered_like_the_ring_overflow_reporter(
) raises:
    """Mirrors `KomiraAppLogEngine._report_overflow_drops`: announce each new
    batch ONCE rather than re-printing a cumulative total on every line. A
    level-triggered report on a congested fd is itself a log flood."""
    var acc = LogWriteLosses()
    assert_equal(
        acc.take_report(), String(""), "nothing lost, nothing announced"
    )

    var lost = LineWrite(10)
    _ = lost.observe(-1, _EPIPE)
    acc.note(lost)

    var first = acc.take_report()
    assert_true(first.byte_length() > 0, "a new loss must announce")
    assert_true(
        String("komira_log") in first,
        "the announcement must name the subsystem so it is greppable, got <"
        + first
        + ">",
    )
    assert_true(
        String("32") in first,
        "and it must carry the errno -- an operator cannot act on 'some writes"
        " failed'. got <" + first + ">",
    )
    assert_equal(
        acc.take_report(),
        String(""),
        "and it must NOT repeat itself while the total is unchanged",
    )

    var again = LineWrite(10)
    _ = again.observe(-1, _EPIPE)
    acc.note(again)
    assert_true(
        acc.take_report().byte_length() > 0, "a NEW loss announces again (edge, not once)"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
