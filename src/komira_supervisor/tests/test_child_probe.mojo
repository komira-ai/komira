# =============================================================================
# test_child_probe.mojo -- proc_probe_children: "does this process have any
# child?", asked without reaping one.
# =============================================================================
#
# A file of its own so its process starts with no child: the "no child" case
# depends on that, and on every test here reaping what it spawns.
#
#   test_no_child_reports_no_child
#       nothing spawned -> any_child False (waitid failed with ECHILD).
#   test_a_running_child_exists_and_is_not_exited
#       a live `sleep 30` -> any_child True, exited_pid 0, and it is still
#       alive after the probe.
#   test_an_exited_child_is_reported_and_left_reapable
#       a child that exited with 7, awaited by polling the probe until it
#       names the pid -> any_child True, exited_pid == its pid; then
#       waitpid(pid, WNOHANG) still collects exit code 7, and a second probe
#       says no child. Goes red when the shim drops WNOWAIT: the probe that
#       first sees the exit reaps it, and the waitpid fails with ECHILD.
#
# Not tested: a waitid failure other than ECHILD, which proc_probe_children
# raises. With its fixed arguments (valid idtype and options, a stack
# siginfo_t) waitid can fail only with ECHILD or EINTR (retried in the shim),
# so no honest test reaches the raise.
# =============================================================================

from std.testing import TestSuite
from std.time import sleep

from komira_supervisor.supervisor import ChildSpec, Supervisor
from komira_supervisor.proc_ffi import (
    ChildProbe,
    proc_kill,
    proc_probe_children,
)


def _spawned(pid: Int32) raises:
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


def _await_exited_unreaped(pid: Int32) raises -> String:
    """Poll the (non-reaping) probe 5 ms apart, up to 1000 times, until it names
    `pid` as an exited, unreaped child. Returns "" on success, else what went
    wrong. Polling the waitid state itself, not an exit notification: on XNU
    EVFILT_PROC NOTE_EXIT may fire before the child is a waitable zombie."""
    var polls = 0
    while True:
        var p = proc_probe_children()
        if p.exited_pid == pid:
            return String("")
        polls += 1
        if polls >= 1000:
            return (
                String("child ")
                + String(pid)
                + String(" not seen as exited after 1000 probes 5 ms apart")
                + String(" (last probe:")
                + String(" any_child ")
                + String(p.any_child)
                + String(", exited_pid ")
                + String(p.exited_pid)
                + String(")")
            )
        sleep(Float64(0.005))


def test_no_child_reports_no_child() raises:
    var p = proc_probe_children()
    if p.any_child:
        raise Error(
            String("no child spawned, yet the probe saw one (exited_pid ")
            + String(p.exited_pid)
            + String(")")
        )


def test_a_running_child_exists_and_is_not_exited() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exec sleep 30")))
    _spawned(pid)
    var p = ChildProbe(any_child=False, exited_pid=Int32(-1))
    var probe_error = String("")
    try:
        p = proc_probe_children()
    except e:
        probe_error = String(e)
    var alive_after = proc_kill(pid, Int32(0)) == Int32(0)
    # Stopped and reaped on every path, so no `sleep 30` outlives the test.
    _ = sup.terminate(1000)
    sup.close()
    if probe_error.byte_length() > 0:
        raise Error(probe_error)
    if not (p.any_child and p.exited_pid == Int32(0) and alive_after):
        raise Error(
            String("running child ")
            + String(pid)
            + String(": any_child ")
            + String(p.any_child)
            + String(", exited_pid ")
            + String(p.exited_pid)
            + String(", alive after the probe ")
            + String(alive_after)
        )


def test_an_exited_child_is_reported_and_left_reapable() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 7")))
    _spawned(pid)
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var waited: String
    try:
        waited = _await_exited_unreaped(pid)
    except e:
        waited = String(e)
    if waited.byte_length() > 0:
        _ = sup.terminate(1000)
        sup.close()
        raise Error(waited)
    var p = proc_probe_children()
    # waitpid(pid, WNOHANG): collects only if the probe left the zombie.
    var r = sup.try_wait()
    var after = proc_probe_children()
    if not r.collected:
        # Do not leave a child behind for the next test if it is still there.
        _ = sup.terminate(1000)
    sup.close()
    if not (p.any_child and p.exited_pid == pid):
        raise Error(
            String("exited child ")
            + String(pid)
            + String(": any_child ")
            + String(p.any_child)
            + String(", exited_pid ")
            + String(p.exited_pid)
        )
    if not (r.collected and r.exited and r.exit_code == Int32(7)):
        raise Error(
            String("the probe reaped the exited child ")
            + String(pid)
            + String(": waitpid afterwards collected ")
            + String(r.collected)
            + String(", error ")
            + String(r.error)
            + String(", exit_code ")
            + String(r.exit_code)
        )
    if after.any_child:
        raise Error(
            String("after reaping the only child the probe still saw one")
            + String(" (exited_pid ")
            + String(after.exited_pid)
            + String(")")
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
