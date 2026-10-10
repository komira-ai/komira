# =============================================================================
# test_process_group.mojo -- ChildSpec.set_own_process_group and the group
# signal's guard.
# =============================================================================
#
#   test_the_child_leads_its_own_group
#       With set_own_process_group the child's process group id (field 5 of
#       /proc/<pid>/stat, read by the child itself) is its own pid, and
#       Supervisor.process_group() says so. CONTROL: without it the child is
#       in this process's group, not its own. Mutant: the shim drops
#       POSIX_SPAWN_SETPGROUP.
#   test_the_group_signal_refuses_every_group_but_a_job
#       proc_kill_group refuses pgid 1, 0 and -1 (kill(-1) reaches every
#       process the caller may signal; kill(0) the caller's own group). Signal
#       0 is used, so a defect sends nothing. Mutant: the shim's `pgid <= 1`
#       guard removed -> kill(-1, 0) and kill(0, 0) return 0.
#
# The first test reads /proc and is skipped off Linux.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_supervisor.supervisor import ChildSpec, Supervisor
from komira_supervisor.proc_ffi import proc_kill_group


comptime _OWN_PGID = "cut -d' ' -f5 /proc/$$/stat"


def _pgid_of_child(own_group: Bool) raises -> Tuple[Int32, String, Int32]:
    var spec = ChildSpec.shell(String(_OWN_PGID))
    if own_group:
        spec.set_own_process_group()
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    assert_true(pid > Int32(0), "spawned: " + String(pid))
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(0), "the child read its stat")
    var group = sup.process_group()
    sup.close()
    return (pid, String(out.strip()), group)


def test_the_child_leads_its_own_group() raises:
    var own = _pgid_of_child(True)
    assert_equal(own[1], String(own[0]), "the child's pgid is its pid")
    assert_equal(own[2], own[0], "process_group() is the pid")
    var shared = _pgid_of_child(False)
    assert_true(
        shared[1] != String(shared[0]),
        "CONTROL: without an own group the pgid is not the child's pid",
    )
    assert_equal(shared[2], Int32(-1), "CONTROL: no own group")
    print("  test_the_child_leads_its_own_group: PASS")


def test_the_group_signal_refuses_every_group_but_a_job() raises:
    for g in [Int32(1), Int32(0), Int32(-1)]:
        assert_true(
            proc_kill_group(g, Int32(0)) < Int32(0),
            "refused: pgid " + String(g),
        )
    print("  test_the_group_signal_refuses_every_group_but_a_job: PASS")


def main() raises:
    test_the_group_signal_refuses_every_group_but_a_job()
    comptime if CompilationTarget.is_linux():
        test_the_child_leads_its_own_group()
    else:
        print("  SKIP (not Linux: no /proc): test_the_child_leads_its_own_group")
    print("PASS test_process_group")
