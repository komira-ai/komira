# =============================================================================
# komira_agent/tests/test_agent_chatty_child.mojo
# =============================================================================
#
# REGRESSION TEST for the supervisor-agent pipe-drain DEADLOCK. The original agent drained the child's stdout/stderr pipes ONLY
# post-exit; a child that writes more than the OS pipe buffer (~64 KiB) to
# stdout BEFORE exiting fills the pipe, blocks on write(), and NEVER reaches
# exit -> the agent's exit-poll never fires -> the run loop heartbeats forever
# (deadlock).
#
# THE FIX: incremental NON-BLOCKING drain during the run loop. Each
# poll_and_drain() call reads whatever stdout/stderr is ready RIGHT NOW (the
# capture-pipe read ends are O_NONBLOCK), so the pipe never fills and the child
# can finish its writes + exit. A FINAL drain-to-EOF after exit captures the
# tail.
#
# WHY THIS IS A DEFAULT (non-cluster) TEST: it only spawns a LOCAL shell child
# (`/bin/sh -c 'for ...; echo ...'`) and drives the agent's lifecycle stepping
# methods directly — no job-manager, no network, no S3. It is a welded test of
# //src/komira_agent:komira_agent.
#
# FAIL-FIRST: with the pre-fix post-exit-only drain, the poll loop below would
# spin until `spins` is exhausted WITHOUT the child ever being collected (the
# child is wedged on write()), so `child_exited` stays False and the COMPLETED
# assert fails (and in the real prod loop it would hang). The bounded spin cap
# turns the would-be hang into a deterministic FAIL.
#
# PASS-AFTER: the incremental drain keeps the pipe empty; the child writes all
# >128 KiB, exits 0, the agent reaps it (child_exited), captures EVERY line
# (the full byte/line count, the last line present), and classifies COMPLETED.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_supervisor.supervisor import ChildSpec

from komira_agent import AgentConfig, PlainAgent
from komira_agent.agent_state import AgentPhase


def _sleep_ms(ms: Int):
    """usleep-backed pause between poll spins (the agent links komira_async,
    so use the distinct `usleep` symbol, not stdlib time.sleep's nanosleep)."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _chatty_agent_config() -> AgentConfig:
    """A trivial AgentConfig (the loopback host/port are never used — this test
    drives the lifecycle stepping methods directly, no heartbeat). The stdout
    byte budget is generous so the full capture is asserted (no truncation)."""
    var argv = List[String]()
    return AgentConfig(
        String("00000000-0000-0000-0000-0000000000aa"),
        String("pod-chatty"),
        String("/bin/sh"),
        argv^,
        String("127.0.0.1"),
        UInt16(1),
        1,    # heartbeat_interval_secs (unused here)
        100,  # max_stderr_lines
        64 * 1024 * 1024,  # max_stdout_bytes — generous, no truncation
    )


# =============================================================================
# Test — a chatty child that writes >128 KiB to stdout BEFORE exiting must NOT
# deadlock: the agent incrementally drains the pipe, captures all output, and
# classifies COMPLETED.
# =============================================================================
def test_chatty_child_no_deadlock_full_capture() raises:
    # 5000 lines, each ~40+ bytes -> ~200 KiB, well over the ~64 KiB pipe
    # buffer. The pre-fix agent wedges here (child blocks on write() ~line
    # 1600); the post-fix agent drains incrementally and the child finishes.
    comptime N_LINES = 5000
    var cmd = String(
        "i=1; while [ $i -le "
    ) + String(N_LINES) + String(
        " ]; do echo \"line $i"
        " ...padding_padding_padding_padding_padding...\"; i=$((i+1)); done"
    )

    var agent = PlainAgent(_chatty_agent_config())
    agent.spawn_child_spec(ChildSpec.shell(cmd))
    assert_true(agent.spawned, "chatty child spawned")

    # Drive the poll loop. With the incremental drain each poll_and_drain reads
    # whatever stdout is ready, so the child never blocks and exits promptly.
    # The bounded spin cap turns a would-be hang (pre-fix) into a deterministic
    # FAIL rather than an actual hang.
    var spins = 0
    while not agent.child_exited and spins < 2000:
        agent.poll_and_drain()
        if agent.child_exited:
            break
        _sleep_ms(2)
        spins += 1

    # FAIL-FIRST evidence: pre-fix this assert fails — the child is wedged on
    # write() and is never collected, so child_exited stays False.
    assert_true(
        agent.child_exited,
        "chatty child was reaped (no deadlock — the incremental drain kept the"
        " pipe from filling so the child could finish writing + exit)",
    )

    agent.analyze_exit()
    assert_true(
        agent.terminal_phase() == AgentPhase.completed(),
        "chatty child exit 0 -> COMPLETED",
    )

    # FULL CAPTURE: every one of the N_LINES lines landed in the stdout ring
    # (no truncation at this byte budget), and the LAST line is present + last.
    assert_equal(
        len(agent.stdout_ring),
        N_LINES,
        "all stdout lines captured (full incremental + final drain)",
    )
    assert_false(
        agent.stdout_truncated,
        "no truncation at the 64 MiB budget for ~200 KiB of output",
    )
    var last = agent.stdout_ring[len(agent.stdout_ring) - 1]
    # The last emitted line is `line 5000 ...padding...`.
    assert_true(
        _contains(last, String("line ") + String(N_LINES)),
        "the LAST stdout line was captured intact (the tail the child wrote"
        " between the last poll and exit — the final drain caught it)",
    )

    _ = agent^


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
    var agent = PlainAgent(
        AgentConfig(
            String("00000000-0000-0000-0000-0000000000bb"),
            String("pod-chatty-cap"),
            String("/bin/sh"),
            argv^,
            String("127.0.0.1"),
            UInt16(1),
            1,
            100,
            32 * 1024,  # max_stdout_bytes — small, forces truncation
        )
    )
    agent.spawn_child_spec(ChildSpec.shell(cmd))

    var spins = 0
    while not agent.child_exited and spins < 2000:
        agent.poll_and_drain()
        if agent.child_exited:
            break
        _sleep_ms(2)
        spins += 1

    # The child still finishes + is reaped (the drain still empties the pipe;
    # only the in-memory CAPTURE is bounded — the child's writes still succeed).
    assert_true(
        agent.child_exited,
        "child reaped even with a small stdout budget (drain still empties the"
        " pipe; only the in-memory log is capped)",
    )
    agent.analyze_exit()
    assert_true(
        agent.terminal_phase() == AgentPhase.completed(),
        "child exit 0 -> COMPLETED even under truncation",
    )
    assert_true(
        agent.stdout_truncated,
        "stdout_truncated flagged once the 32 KiB budget was exceeded",
    )

    _ = agent^


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
        "PASS test_agent_chatty_child (a child writing >128 KiB to stdout"
        " before exit no longer deadlocks the agent: incremental non-blocking"
        " drain keeps the pipe empty, full capture asserted, COMPLETED; the"
        " stdout byte budget caps the in-memory log + flags truncation)"
    )
