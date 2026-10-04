# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_chatty_child.mojo
# =============================================================================
#
# REGRESSION TEST for the pipe-drain DEADLOCK. A supervisor that drains the
# child's stdout/stderr pipes ONLY after exit deadlocks on a child that writes
# more than the OS pipe buffer (~64 KiB) before exiting: the child blocks on
# write() and never exits, so the exit poll never fires and the run loop
# heartbeats forever.
#
# THE FIX: incremental NON-BLOCKING drain during the run loop. Each
# poll_and_drain() call reads whatever stdout/stderr is ready RIGHT NOW (the
# capture-pipe read ends are O_NONBLOCK), so the pipe never fills and the child
# can finish its writes + exit. A FINAL drain-to-EOF after exit captures the
# tail.
#
# WHY THIS IS A DEFAULT (non-cluster) TEST: it only spawns a LOCAL shell child
# (`/bin/sh -c 'for ...; echo ...'`) and drives the job supervisor's lifecycle stepping
# methods directly: no heartbeat endpoint, no network, no object store. It is a welded test of
# //src/komira_job_supervisor:komira_job_supervisor.
#
# FAIL-FIRST: with the pre-fix post-exit-only drain, the poll loop below would
# spin until `spins` is exhausted WITHOUT the child ever being collected (the
# child is wedged on write()), so `child_exited` stays False and the COMPLETED
# assert fails (and in the real prod loop it would hang). The bounded spin cap
# turns the would-be hang into a deterministic FAIL.
#
# PASS-AFTER: the incremental drain keeps the pipe empty; the child writes all
# >128 KiB, exits 0, the job supervisor reaps it (child_exited), captures EVERY line
# (the full byte/line count, the last line present), and classifies COMPLETED.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_supervisor.supervisor import ChildSpec

from komira_objectstore import InMemoryConditionalStore

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    JobSupervisorConfig,
    SupervisorHeartbeat,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


struct SilentReporter(HeartbeatReporter):
    """Counts heartbeats and delivers none (this test sends none)."""

    var beats: Int

    def __init__(out self):
        self.beats = 0

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.beats += 1
        return HeartbeatOutcome(True, False, 200)


comptime TestSupervisor = JobSupervisor[SilentReporter, InMemoryConditionalStore]


def _supervisor(var config: JobSupervisorConfig) -> TestSupervisor:
    return TestSupervisor(config^, SilentReporter(), None)


def _sleep_ms(ms: Int):
    """usleep-backed pause between poll spins (the job supervisor links komira_async,
    so use the distinct `usleep` symbol, not stdlib time.sleep's nanosleep)."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _chatty_job_supervisor_config() -> JobSupervisorConfig:
    """A trivial JobSupervisorConfig (the heartbeat URL is never used: this
    test drives the lifecycle stepping methods directly). The stdout byte
    budget is generous so the full capture is asserted (no truncation)."""
    var argv = List[String]()
    return JobSupervisorConfig(
        String("job-chatty"),
        String("instance-chatty"),
        String("/bin/sh"),
        argv^,
        String("http://127.0.0.1:1/heartbeat"),
        heartbeat_interval_secs=1,
        max_stderr_lines=100,
        max_stdout_bytes=64 * 1024 * 1024,  # generous, no truncation
    )


# =============================================================================
# Test — a chatty child that writes >128 KiB to stdout BEFORE exiting must NOT
# deadlock: the job supervisor incrementally drains the pipe, captures all output, and
# classifies COMPLETED.
# =============================================================================
def test_chatty_child_no_deadlock_full_capture() raises:
    # 5000 lines, each ~40+ bytes -> ~200 KiB, well over the ~64 KiB pipe
    # buffer. The pre-fix job supervisor wedges here (child blocks on write() ~line
    # 1600); the post-fix job supervisor drains incrementally and the child finishes.
    comptime N_LINES = 5000
    var cmd = String(
        "i=1; while [ $i -le "
    ) + String(N_LINES) + String(
        " ]; do echo \"line $i"
        " ...padding_padding_padding_padding_padding...\"; i=$((i+1)); done"
    )

    var job_supervisor = _supervisor(_chatty_job_supervisor_config())
    job_supervisor.spawn_child_spec(ChildSpec.shell(cmd))
    assert_true(job_supervisor.spawned, "chatty child spawned")

    # Drive the poll loop. With the incremental drain each poll_and_drain reads
    # whatever stdout is ready, so the child never blocks and exits promptly.
    # The bounded spin cap turns a would-be hang (pre-fix) into a deterministic
    # FAIL rather than an actual hang.
    var spins = 0
    while not job_supervisor.child_exited and spins < 2000:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        _sleep_ms(2)
        spins += 1

    # FAIL-FIRST evidence: pre-fix this assert fails — the child is wedged on
    # write() and is never collected, so child_exited stays False.
    assert_true(
        job_supervisor.child_exited,
        "chatty child was reaped (no deadlock — the incremental drain kept the"
        " pipe from filling so the child could finish writing + exit)",
    )

    job_supervisor.analyze_exit()
    assert_true(
        job_supervisor.terminal_phase() == JobSupervisorPhase.completed(),
        "chatty child exit 0 -> COMPLETED",
    )

    # FULL CAPTURE: every one of the N_LINES lines landed in the stdout ring
    # (no truncation at this byte budget), and the LAST line is present + last.
    assert_equal(
        len(job_supervisor.stdout_ring),
        N_LINES,
        "all stdout lines captured (full incremental + final drain)",
    )
    assert_false(
        job_supervisor.stdout_truncated,
        "no truncation at the 64 MiB budget for ~200 KiB of output",
    )
    var last = job_supervisor.stdout_ring[len(job_supervisor.stdout_ring) - 1]
    # The last emitted line is `line 5000 ...padding...`.
    assert_true(
        _contains(last, String("line ") + String(N_LINES)),
        "the LAST stdout line was captured intact (the tail the child wrote"
        " between the last poll and exit — the final drain caught it)",
    )

    _ = job_supervisor^


# =============================================================================
# Test — the stdout byte budget caps the in-memory capture (no OOM) and flags
# truncation when a chatty job exceeds it.
# =============================================================================
def test_chatty_child_stdout_budget_truncation() raises:
    comptime N_LINES = 5000
    var cmd = String(
        "i=1; while [ $i -le "
    ) + String(N_LINES) + String(
        " ]; do echo \"line $i"
        " ...padding_padding_padding_padding_padding...\"; i=$((i+1)); done"
    )

    # A SMALL stdout budget (32 KiB) so the ~200 KiB of output is truncated.
    var argv = List[String]()
    var job_supervisor = _supervisor(
        JobSupervisorConfig(
            String("job-chatty-cap"),
            String("instance-chatty-cap"),
            String("/bin/sh"),
            argv^,
            String("http://127.0.0.1:1/heartbeat"),
            heartbeat_interval_secs=1,
            max_stderr_lines=100,
            max_stdout_bytes=32 * 1024,  # small, forces truncation
        )
    )
    job_supervisor.spawn_child_spec(ChildSpec.shell(cmd))

    var spins = 0
    while not job_supervisor.child_exited and spins < 2000:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        _sleep_ms(2)
        spins += 1

    # The child still finishes + is reaped (the drain still empties the pipe;
    # only the in-memory CAPTURE is bounded — the child's writes still succeed).
    assert_true(
        job_supervisor.child_exited,
        "child reaped even with a small stdout budget (drain still empties the"
        " pipe; only the in-memory log is capped)",
    )
    job_supervisor.analyze_exit()
    assert_true(
        job_supervisor.terminal_phase() == JobSupervisorPhase.completed(),
        "child exit 0 -> COMPLETED even under truncation",
    )
    assert_true(
        job_supervisor.stdout_truncated,
        "stdout_truncated flagged once the 32 KiB budget was exceeded",
    )

    _ = job_supervisor^


def _contains(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    var hn = len(hb)
    var nn = len(nb)
    if nn == 0:
        return True
    if nn > hn:
        return False
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if hb[i + j] != nb[j]:
                matched = False
                break
            j += 1
        if matched:
            return True
        i += 1
    return False


def main() raises:
    test_chatty_child_no_deadlock_full_capture()
    test_chatty_child_stdout_budget_truncation()
    print(
        "PASS test_job_supervisor_chatty_child (a child writing >128 KiB to stdout"
        " before exit does not deadlock the supervisor: incremental non-blocking"
        " drain keeps the pipe empty, full capture asserted, COMPLETED; the"
        " stdout byte budget caps the in-memory log + flags truncation)"
    )
