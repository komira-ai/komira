# =============================================================================
# test_localmodel_registry.mojo
#   SupervisorRegistry (N children keyed by id) and find_free_port (a bind(0)
#   ephemeral-port helper): several engine children on distinct ports, managed
#   and stopped with no orphans.
# =============================================================================
#
# WHAT THIS PROVES:
#
#   (1) find_free_port — returns a non-zero port; two consecutive calls return
#       DISTINCT ports (the kernel does not hand out the same ephemeral port
#       twice in quick succession). The returned port is FREE (re-bindable)
#       after the call (the listener was released).
#   (2) MULTI-CHILD LIFECYCLE — spawn TWO children through the registry under
#       distinct ids, both alive (poll -> CHILD_SPAWNED), terminate one (the
#       other stays alive), then the second; both end CHILD_GONE with NO orphan
#       (poll reaps the zombie). Exercises the real Supervisor.spawn +
#       try_wait reap + terminate(grace) path under the registry.
#   (3) BOOKKEEPING — count / live_count / contains / ids / pid_of /
#       duplicate-id rejection.
#   (4) terminate_all — the shutdown sweep stops every still-spawned child.
#
# Liveness here is the registry's own process-alive poll; no HTTP health probe.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_localmodel import (
    SupervisorRegistry,
    ChildHandle,
    ChildState,
    CHILD_SPAWNED,
    CHILD_GONE,
    CHILD_NOT_FOUND,
    find_free_port,
)
from komira_supervisor.supervisor import ChildSpec
from komira_core_ffi.posix import staged_python3


def _sleep_ms(ms: Int):
    if ms > 0:
        _ = external_call["usleep", Int32](UInt32(ms * 1000))


# A child that BINDS the given port (proving the port was free and could be
# handed to a real engine) then sleeps. Single-quoted shell -c arg, so the
# python source uses DOUBLE-quoted literals ONLY. It binds + listens then sleeps
# for a bounded time so a leaked child exits even if the test crashes before
# terminate.
def _binder_py(port: UInt16) -> String:
    var p = String(Int(port))
    return String(
        "import socket, time\n"
        "s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
        "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
        "s.bind((\"127.0.0.1\", "
    ) + p + String(
        "))\n"
        "s.listen(8)\n"
        "time.sleep(30)\n"
    )


def _spawn_binder(
    mut reg: SupervisorRegistry, id: String, port: UInt16
) -> ChildHandle:
    var py = _binder_py(port)
    # The interpreter comes from the test's staged runtime files; the literal
    # path is the fallback when nothing is staged.
    var _py = staged_python3()
    if len(_py.as_bytes()) == 0:
        _py = String("/usr/bin/python3")
    var cmd = String("\"") + _py + String("\" -c '") + py + String("'")
    return reg.spawn(id, ChildSpec.shell(cmd))


# =============================================================================
# (1) find_free_port — non-zero + distinct + re-bindable.
# =============================================================================
def test_find_free_port_distinct() raises:
    var p1 = find_free_port()
    var p2 = find_free_port()
    assert_true(p1 > UInt16(0), String("port 1 was 0"))
    assert_true(p2 > UInt16(0), String("port 2 was 0"))
    # Two consecutive ephemeral picks should differ (the kernel rotates them).
    assert_true(
        p1 != p2,
        String("two find_free_port calls returned the same port ") + String(p1),
    )

    # The port is FREE after the call (the listener was released) — a child can
    # bind it. We prove this by spawning a binder on p1; if the bind fails the
    # child exits immediately and the poll flips to GONE quickly.
    var reg = SupervisorRegistry()
    var h = _spawn_binder(reg, String("bind-check"), p1)
    assert_true(h.ok(), String("binder spawn failed pid=") + String(h.pid))
    # Give python a moment to import + bind; a successful bind keeps it alive.
    _sleep_ms(800)
    var st = reg.poll(String("bind-check"))
    assert_equal(
        st.state,
        CHILD_SPAWNED,
        String("binder on the just-freed port did not stay alive"),
    )
    reg.terminate_all(2000)


# =============================================================================
# (2) MULTI-CHILD REGISTRY LIFECYCLE — two children on auto-picked ports.
# =============================================================================
def test_multi_child_lifecycle() raises:
    print("(2) multi-child registry: spawn 2 binders on auto-picked ports")
    var reg = SupervisorRegistry()

    var port_a = find_free_port()
    var port_b = find_free_port()
    assert_true(port_a != port_b)

    var ha = _spawn_binder(reg, String("engine-a"), port_a)
    var hb = _spawn_binder(reg, String("engine-b"), port_b)
    assert_true(ha.ok(), String("engine-a spawn failed pid=") + String(ha.pid))
    assert_true(hb.ok(), String("engine-b spawn failed pid=") + String(hb.pid))
    print("  spawned engine-a pid", ha.pid, "on port", port_a)
    print("  spawned engine-b pid", hb.pid, "on port", port_b)

    assert_equal(reg.count(), 2)
    assert_equal(reg.live_count(), 2)

    # Both alive after a moment to bind.
    _sleep_ms(800)
    assert_equal(reg.poll(String("engine-a")).state, CHILD_SPAWNED)
    assert_equal(reg.poll(String("engine-b")).state, CHILD_SPAWNED)

    # Terminate engine-a INDEPENDENTLY; engine-b stays alive.
    var info_a = reg.terminate(String("engine-a"), 3000)
    print("  terminated engine-a shell_code", info_a.shell_code)
    assert_equal(reg.poll(String("engine-a")).state, CHILD_GONE)
    assert_equal(
        reg.poll(String("engine-b")).state,
        CHILD_SPAWNED,
        String("engine-b died when engine-a was terminated"),
    )
    assert_equal(reg.live_count(), 1)

    # Terminate engine-b; both now gone, NO orphan (poll reaps the zombie).
    var info_b = reg.terminate(String("engine-b"), 3000)
    print("  terminated engine-b shell_code", info_b.shell_code)
    assert_equal(reg.poll(String("engine-b")).state, CHILD_GONE)
    assert_equal(reg.live_count(), 0)
    print("  PASS (2 children spawned, terminated independently, no orphan)")


# =============================================================================
# (3) REGISTRY BOOKKEEPING — count / contains / ids / pid_of / dup-id.
# =============================================================================
def test_registry_bookkeeping() raises:
    var reg = SupervisorRegistry()
    assert_equal(reg.count(), 0)
    assert_false(reg.contains(String("x")))

    var port = find_free_port()
    var h = _spawn_binder(reg, String("solo"), port)
    assert_true(h.ok())
    assert_equal(reg.count(), 1)
    assert_true(reg.contains(String("solo")))
    assert_equal(reg.pid_of(String("solo")), h.pid)
    assert_equal(reg.pid_of(String("absent")), Int32(-1))

    var ids = reg.ids()
    assert_equal(len(ids), 1)
    assert_equal(ids[0], String("solo"))

    # Duplicate id -> no-op spawn (pid 0, not ok), count unchanged.
    var dup = _spawn_binder(reg, String("solo"), port)
    assert_false(dup.ok())
    assert_equal(dup.pid, Int32(0))
    assert_equal(reg.count(), 1)

    # poll / terminate of an absent id -> NOT_FOUND / sentinel.
    assert_equal(reg.poll(String("absent")).state, CHILD_NOT_FOUND)

    reg.terminate_all(2000)
    assert_equal(reg.live_count(), 0)


# =============================================================================
# (4) terminate_all — the shutdown sweep stops everything.
# =============================================================================
def test_terminate_all() raises:
    var reg = SupervisorRegistry()
    var pa = find_free_port()
    var pb = find_free_port()
    var pc = find_free_port()
    _ = _spawn_binder(reg, String("a"), pa)
    _ = _spawn_binder(reg, String("b"), pb)
    _ = _spawn_binder(reg, String("c"), pc)
    _sleep_ms(600)
    assert_equal(reg.live_count(), 3)

    reg.terminate_all(3000)
    assert_equal(reg.live_count(), 0)
    assert_equal(reg.poll(String("a")).state, CHILD_GONE)
    assert_equal(reg.poll(String("b")).state, CHILD_GONE)
    assert_equal(reg.poll(String("c")).state, CHILD_GONE)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
