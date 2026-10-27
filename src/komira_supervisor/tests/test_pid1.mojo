# =============================================================================
# test_pid1.mojo -- what a PID 1 needs: the SIGTERM/SIGINT stop latch, orphan
# adoption and collection, the process-group stop ladder, and spawning a child
# with default signal dispositions.
#
# A file of its own: every test here changes process-wide state (signal
# handlers, a child subreaper, an ignored SIGHUP), which no other test file
# may inherit. The tests run in the order `main` names.
#
#   test_stop_latch_keeps_the_first_signal_until_taken
#       raise(SIGTERM) -> take 15, then 0; SIGINT -> 2; SIGTERM then SIGINT
#       -> 15 (the first caught wins), then 0. Mutants: the shim's handler
#       stores instead of compare-and-swap (last wins -> 2); take reads
#       without clearing (second take 15).
#   test_adopted_orphan_is_collected_and_our_child_is_kept      (Linux)
#       adopt_orphans() is True; a grandchild orphaned by its shell becomes
#       this process's zombie (the probe names it) and reap_orphans()
#       collects exactly it; a Supervisor's own exited child is never
#       collected by reap_orphans (its wait_exit still reads exit 3).
#   test_group_terminate_collects_the_group_within_the_grace     (Linux)
#       a child leading its own group with a background grandchild:
#       terminate_with(SIGTERM, 5000, reap_orphans=True) signals the GROUP,
#       collects the orphaned grandchild during the grace wait and returns as
#       soon as the group is empty (well before 5 s).
#   test_a_term_ignoring_grandchild_holds_the_ladder_then_is_killed (Linux)
#       the child dies of SIGTERM at once but its grandchild ignores it: the
#       wait holds until the grace (300 ms) runs out, SIGKILL empties the
#       group, and the child's own first reason (SIGTERM, 143) is kept.
#   test_group_escalation_collects_more_orphans_than_one_batch   (Linux)
#       a TERM-ignoring child with 300 TERM-ignoring grandchildren: the grace
#       runs out, SIGKILL goes to the group, the child reads 137, and the
#       settle loop collects all 300 orphans (more than one 256-pid batch),
#       leaving no child and an empty group.
#   test_default_signals_reset_an_ignored_signal                (Linux)
#       with SIGHUP ignored here, a child spawned with set_default_signals
#       has no ignored signal (/proc/self/status SigIgn all zero); CONTROL:
#       without it the child inherits the ignored SIGHUP.
#
# The Linux tests need a child subreaper (or PID 1) and /proc; off Linux they
# print a SKIP line naming the reason.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns, sleep

from komira_supervisor import (
    adopt_orphans,
    install_stop_signal_handler,
    take_stop_signal,
)
from komira_supervisor.supervisor import ChildSpec, Supervisor
from komira_supervisor.proc_ffi import (
    SIGINT,
    SIGKILL,
    SIGTERM,
    proc_kill,
    proc_kill_group,
    proc_probe_children,
)


def _spawned(pid: Int32) raises:
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


def _raise_signal(sig: Int32):
    # raise(3) signals the calling thread, so the handler has run when it
    # returns.
    _ = external_call["raise", Int32](sig)


def _read_lines(mut sup: Supervisor, n: Int) raises -> List[String]:
    """The child's first `n` stdout lines, read without waiting for EOF (the
    child keeps running). Up to 5 s."""
    _ = sup.set_nonblocking(sup.stdout_fd())
    var acc = String("")
    for _ in range(500):
        var c = sup.read_available(sup.stdout_fd())
        if c.text.byte_length() > 0:
            acc += c.text
            var lines = acc.split("\n")
            if len(lines) > n:
                var out = List[String]()
                for i in range(n):
                    out.append(String(lines[i]))
                return out^
            continue
        if c.eof or c.error:
            break
        sleep(Float64(0.01))
    _ = sup.terminate(1000)
    sup.close()
    raise Error(String("fewer than ") + String(n) + " lines from the child; read: " + acc)


def _read_line(mut sup: Supervisor) raises -> String:
    return _read_lines(sup, 1)[0]


def _no_child_within(ms: Int) raises -> Bool:
    for _ in range(ms // 10):
        if not proc_probe_children().any_child:
            return True
        sleep(Float64(0.01))
    return not proc_probe_children().any_child


# -----------------------------------------------------------------------------
def test_stop_latch_keeps_the_first_signal_until_taken() raises:
    install_stop_signal_handler()
    install_stop_signal_handler()  # idempotent
    assert_equal(take_stop_signal(), Int32(0), "nothing caught yet")
    _raise_signal(SIGTERM)
    assert_equal(take_stop_signal(), SIGTERM)
    assert_equal(take_stop_signal(), Int32(0), "the take cleared it")
    _raise_signal(SIGINT)
    assert_equal(take_stop_signal(), SIGINT)
    _raise_signal(SIGTERM)
    _raise_signal(SIGINT)
    assert_equal(take_stop_signal(), SIGTERM, "the first caught wins")
    assert_equal(take_stop_signal(), Int32(0))
    print("  test_stop_latch_keeps_the_first_signal_until_taken: PASS")


def test_adopted_orphan_is_collected_and_our_child_is_kept() raises:
    assert_true(adopt_orphans(), "a child subreaper (or PID 1)")
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(String("sleep 0.2 >/dev/null 2>&1 & echo $!"))
    )
    _spawned(pid)
    var line = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(0))
    sup.close()
    var orphan = Int32(atol(String(line.strip())))
    var seen = False
    for _ in range(500):
        if proc_probe_children().exited_pid == orphan:
            seen = True
            break
        sleep(Float64(0.01))
    assert_true(seen, "orphan " + String(orphan) + " became our zombie")
    assert_equal(sup.reap_orphans(), 1, "collected exactly the orphan")
    assert_false(proc_probe_children().any_child, "no child left")

    # Our own exited child is the Supervisor's to reap, never reap_orphans'.
    var own = Supervisor()
    var opid = own.spawn(ChildSpec.shell(String("exit 3")))
    _spawned(opid)
    _ = own.drain_pipe(own.stdout_fd())
    _ = own.drain_pipe(own.stderr_fd())
    for _ in range(500):
        if proc_probe_children().exited_pid == opid:
            break
        sleep(Float64(0.01))
    assert_equal(own.reap_orphans(), 0, "our own child is not an orphan")
    assert_equal(own.wait_exit().exit_code, Int32(3), "still ours to reap")
    own.close()
    print("  test_adopted_orphan_is_collected_and_our_child_is_kept: PASS")


def test_group_terminate_collects_the_group_within_the_grace() raises:
    var spec = ChildSpec.shell(
        String("sleep 30 >/dev/null 2>&1 & echo $!; wait")
    )
    spec.set_own_process_group()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    _spawned(pid)
    var grandchild = Int32(atol(String(_read_line(sup).strip())))
    var t0 = perf_counter_ns()
    var info = sup.terminate_with(SIGTERM, 5000, True)
    var ms = Int((perf_counter_ns() - t0) // 1000000)
    var left = proc_kill(grandchild, Int32(0))
    var group_left = proc_kill_group(pid, Int32(0))
    var none = _no_child_within(2000)
    _ = sup.drain_pipe(sup.stderr_fd())
    sup.close()
    assert_equal(info.signal, SIGTERM, "the child died of the group SIGTERM")
    assert_true(left < Int32(0), "the grandchild got the SIGTERM and was collected")
    assert_true(group_left < Int32(0), "the group is empty")
    assert_true(ms < 2500, "returned once the group emptied, after " + String(ms) + " ms")
    assert_true(none, "no child left")
    print("  test_group_terminate_collects_the_group_within_the_grace: PASS")


def test_a_term_ignoring_grandchild_holds_the_ladder_then_is_killed() raises:
    # The child dies of the SIGTERM at once; its grandchild ignores it. The
    # wait lasts until the GROUP is empty or the grace runs out, then the
    # group gets SIGKILL; the child's own reason (SIGTERM) is kept.
    # The grandchild prints "ready" only once it ignores SIGTERM, so the
    # SIGTERM below cannot reach it first.
    var spec = ChildSpec.shell(
        String(
            "(trap '' TERM; echo ready; exec sleep 30 >/dev/null 2>&1) &"
            " echo $!; wait"
        )
    )
    spec.set_own_process_group()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    _spawned(pid)
    var two = _read_lines(sup, 2)
    var pid_line = two[1] if two[0] == String("ready") else two[0]
    var ready_seen = two[0] == String("ready") or two[1] == String("ready")
    var grandchild = Int32(atol(String(pid_line.strip())))
    var t0 = perf_counter_ns()
    var info = sup.terminate_with(SIGTERM, 300, True)
    var ms = Int((perf_counter_ns() - t0) // 1000000)
    var left = proc_kill(grandchild, Int32(0))
    var group_left = proc_kill_group(pid, Int32(0))
    var none = _no_child_within(2000)
    _ = sup.drain_pipe(sup.stderr_fd())
    sup.close()
    assert_true(ready_seen, "the grandchild ignored SIGTERM before it")
    assert_equal(info.signal, SIGTERM, "the child's first reason is kept")
    assert_equal(info.shell_code, Int32(143))
    assert_true(ms >= 300, "waited the grace for the group: " + String(ms) + " ms")
    assert_true(left < Int32(0), "the grandchild was SIGKILLed and collected")
    assert_true(group_left < Int32(0), "the group is empty")
    assert_true(none, "no child left")
    print("  test_a_term_ignoring_grandchild_holds_the_ladder_then_is_killed: PASS")


def test_group_escalation_collects_more_orphans_than_one_batch() raises:
    var spec = ChildSpec.shell(
        String(
            "trap '' TERM; i=0; while [ $i -lt 300 ]; do"
            " sleep 30 >/dev/null 2>&1 & i=$((i+1)); done; echo ready; wait"
        )
    )
    spec.set_own_process_group()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    _spawned(pid)
    assert_equal(String(_read_line(sup).strip()), String("ready"))
    var info = sup.terminate_with(SIGTERM, 200, True)
    var group_left = proc_kill_group(pid, Int32(0))
    var any_child = proc_probe_children().any_child
    _ = sup.drain_pipe(sup.stderr_fd())
    sup.close()
    assert_equal(info.signal, SIGKILL, "TERM ignored: escalated to SIGKILL")
    assert_equal(info.shell_code, Int32(137))
    assert_true(group_left < Int32(0), "the group is empty")
    assert_false(any_child, "all 300 orphans collected")
    print("  test_group_escalation_collects_more_orphans_than_one_batch: PASS")


def _sigign_of(default_signals: Bool) raises -> String:
    var spec = ChildSpec.shell(String("grep '^SigIgn:' /proc/self/status"))
    if default_signals:
        spec.set_default_signals()
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(0), "grep found SigIgn")
    sup.close()
    return String(out.strip())


def test_default_signals_reset_an_ignored_signal() raises:
    # signal(SIGHUP, SIG_IGN); SIG_IGN is the handler value 1.
    _ = external_call["signal", Int64](Int32(1), Int64(1))
    var reset = _sigign_of(True)
    var inherited = _sigign_of(False)
    assert_equal(reset, String("SigIgn:\t0000000000000000"), "nothing ignored")
    var last = String(inherited[byte=inherited.byte_length() - 1 :])
    assert_true(
        String("13579bdf").find(last) >= 0,
        "CONTROL: without the flag SIGHUP (bit 0) stays ignored: " + inherited,
    )
    print("  test_default_signals_reset_an_ignored_signal: PASS")


def main() raises:
    test_stop_latch_keeps_the_first_signal_until_taken()
    comptime if CompilationTarget.is_linux():
        test_adopted_orphan_is_collected_and_our_child_is_kept()
        test_group_terminate_collects_the_group_within_the_grace()
        test_a_term_ignoring_grandchild_holds_the_ladder_then_is_killed()
        test_group_escalation_collects_more_orphans_than_one_batch()
        test_default_signals_reset_an_ignored_signal()
    else:
        print("  SKIP (not Linux: no child subreaper, no /proc): the orphan,")
        print("  group and default-signal tests")
        assert_false(adopt_orphans(), "no subreaper off Linux")
    print("PASS test_pid1")
