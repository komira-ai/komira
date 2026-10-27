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
#   test_group_terminate_collects_the_group                      (Linux)
#       a child leading its own group with a background grandchild:
#       terminate_with(SIGTERM, 5000, reap_orphans=True) signals the GROUP and
#       collects the orphaned grandchild: the grandchild is gone, the group
#       is empty and no child is left. The time it took is not asserted.
#   test_a_term_ignoring_grandchild_is_killed_with_the_group     (Linux)
#       the child dies of SIGTERM at once; its grandchild catches SIGTERM,
#       prints "term-seen" and keeps running. The ladder holds the grace
#       before it escalates: the marker is on the pipe (the grandchild ran
#       its handler after the SIGTERM and before the SIGKILL), then SIGKILL
#       empties the group and the child's own first reason (SIGTERM, 143) is
#       kept. Time is not asserted: the marker is an event the grandchild
#       produces. A ladder that sends SIGKILL without waiting leaves no
#       marker.
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
from std.time import sleep

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
    child keeps running). Reads until the lines arrive or the child's output
    ends; no iteration cap and no deadline (a child that stays silent is
    stopped by the gate hang limit, `test_hang_limit_s`: see "Time limits" in
    tools/build/mojo/README.md)."""
    _ = sup.set_nonblocking(sup.stdout_fd())
    var acc = String("")
    while True:
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


def _await_no_child() raises:
    """Poll until every child is collected. No cap and no deadline: the
    collection is the event waited for."""
    while proc_probe_children().any_child:
        sleep(Float64(0.01))


def _await_zombie(pid: Int32) raises:
    """Poll until `pid` is an exited, unreaped child of this process. No cap
    and no deadline: the exit is the event waited for."""
    while proc_probe_children().exited_pid != pid:
        sleep(Float64(0.01))


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
    _await_zombie(orphan)
    assert_equal(sup.reap_orphans(), 1, "collected exactly the orphan")
    assert_false(proc_probe_children().any_child, "no child left")

    # Our own exited child is the Supervisor's to reap, never reap_orphans'.
    var own = Supervisor()
    var opid = own.spawn(ChildSpec.shell(String("exit 3")))
    _spawned(opid)
    _ = own.drain_pipe(own.stdout_fd())
    _ = own.drain_pipe(own.stderr_fd())
    _await_zombie(opid)
    assert_equal(own.reap_orphans(), 0, "our own child is not an orphan")
    assert_equal(own.wait_exit().exit_code, Int32(3), "still ours to reap")
    own.close()
    print("  test_adopted_orphan_is_collected_and_our_child_is_kept: PASS")


def test_group_terminate_collects_the_group() raises:
    var spec = ChildSpec.shell(
        String("sleep 30 >/dev/null 2>&1 & echo $!; wait")
    )
    spec.set_own_process_group()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    _spawned(pid)
    var grandchild = Int32(atol(String(_read_line(sup).strip())))
    var info = sup.terminate_with(SIGTERM, 5000, True)
    var left = proc_kill(grandchild, Int32(0))
    var group_left = proc_kill_group(pid, Int32(0))
    _await_no_child()
    _ = sup.drain_pipe(sup.stderr_fd())
    sup.close()
    assert_equal(info.signal, SIGTERM, "the child died of the group SIGTERM")
    assert_true(left < Int32(0), "the grandchild got the SIGTERM and was collected")
    assert_true(group_left < Int32(0), "the group is empty")
    print("  test_group_terminate_collects_the_group: PASS")


def _read_to_eof(mut sup: Supervisor) raises -> String:
    """Everything left on the child's stdout, up to its end. No cap and no
    deadline: the end of the stream (every writer gone) is the event waited
    for."""
    _ = sup.set_nonblocking(sup.stdout_fd())
    var acc = String("")
    while True:
        var c = sup.read_available(sup.stdout_fd())
        acc += c.text
        if c.eof or c.error:
            return acc
        if c.text.byte_length() == 0:
            sleep(Float64(0.01))


def test_a_term_ignoring_grandchild_is_killed_with_the_group() raises:
    # The child dies of the SIGTERM at once. Its grandchild catches it, says
    # so and keeps running, so only the SIGKILL ends it. The wait lasts until
    # the GROUP is empty or the grace runs out, then the group gets SIGKILL;
    # the child's own reason (SIGTERM) is kept.
    # The grandchild prints "ready" once its trap is set, so the SIGTERM
    # below cannot reach it first. "term-seen" is printed by its handler:
    # that line on the pipe is the proof the ladder waited between the
    # SIGTERM and the SIGKILL (a SIGKILL sent at once never lets the handler
    # run). The grace is counted in the supervisor's ticks and is long enough
    # for a handler that does one write; the test asserts on the marker, not
    # on how long anything took.
    var spec = ChildSpec.shell(
        String(
            "( trap 'echo term-seen' TERM; echo ready;"
            " while :; do sleep 30 >/dev/null 2>&1 & wait; done ) &"
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
    var info = sup.terminate_with(SIGTERM, 1000, True)
    var left = proc_kill(grandchild, Int32(0))
    var group_left = proc_kill_group(pid, Int32(0))
    var rest = _read_to_eof(sup)
    _await_no_child()
    _ = sup.drain_pipe(sup.stderr_fd())
    sup.close()
    assert_true(ready_seen, "the grandchild's trap was set before the SIGTERM")
    assert_equal(
        String(rest.strip()),
        String("term-seen"),
        "the grandchild ran its SIGTERM handler before the SIGKILL: the grace was held",
    )
    assert_equal(info.signal, SIGTERM, "the child's first reason is kept")
    assert_equal(info.shell_code, Int32(143))
    assert_true(left < Int32(0), "the grandchild was SIGKILLed and collected")
    assert_true(group_left < Int32(0), "the group is empty")
    print("  test_a_term_ignoring_grandchild_is_killed_with_the_group: PASS")


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
        test_group_terminate_collects_the_group()
        test_a_term_ignoring_grandchild_is_killed_with_the_group()
        test_group_escalation_collects_more_orphans_than_one_batch()
        test_default_signals_reset_an_ignored_signal()
    else:
        print("  SKIP (not Linux: no child subreaper, no /proc): the orphan,")
        print("  group and default-signal tests")
        assert_false(adopt_orphans(), "no subreaper off Linux")
    print("PASS test_pid1")
