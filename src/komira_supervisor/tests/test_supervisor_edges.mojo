# =============================================================================
# test_supervisor_edges.mojo -- the guards, caches and protocols the scenario
# suite does not reach: the negative-fd guards, the exit cache, a child reaped
# behind the Supervisor's back, the environment read protocol and its growth
# path, argv/env blob marshalling, set_cwd, the detached spawn and its
# DetachedChild, and the reactor exit watch.
#
# One claim per `test_` function (TestSuite). What each would catch:
#
#   test_sleep_ms_sleeps_only_a_positive_duration
#       the microseconds _sleep_ms hands to usleep: 30 ms is 30000, 0 and -5
#       are 0 (no sleep, never a wrapped negative). A guard `ms <= 0` widened
#       to `ms <= 30` turns the 30 ms case into 0. No clock is read.
#   test_negative_and_closed_fds_are_refused_not_read
#       set_nonblocking(-1) == -1 without a syscall (a syscall gives -EBADF);
#       read_available(-1) is EOF; a read error on a closed fd is `error`,
#       never would_block; drain_both of two unopened ends returns ("", "").
#   test_drain_both_waits_out_a_silent_child
#       a child silent for 300 ms, then one line on each stream: a turn where
#       both pipes would_block pauses and retires neither (the scenario
#       suite reaches that pause only when timing allows).
#   test_wait_exit_and_try_wait_answer_from_the_cache
#       the second wait_exit and a later try_wait answer from the cache,
#       for an exit code and for a signal (Supervisor.signal); a lost cache
#       reaps twice and reads the -1 sentinel.
#   test_a_child_reaped_elsewhere_reads_as_the_sentinel_and_is_not_cached
#       the waitpid fails (ECHILD): ExitInfo is all -1 and nothing is cached,
#       so try_wait still reports the error.
#   test_env_name_of_an_entry_without_equals_is_the_entry
#       two `=`-less overlay entries keep distinct names (both appended).
#   test_cstr_blob_skips_nuls_and_is_never_empty
#   test_environ_at_protocol_out_of_range_and_too_small
#   test_process_environ_grows_once_for_an_entry_past_4096_bytes
#       the 4096-byte starting buffer boundary: an entry needing exactly 4096
#       bytes and one needing 4097 (the grow path) both come back whole, and
#       an entry after them is still read.
#   test_set_cwd_runs_the_child_there
#   test_spawn_detached_exit_env_and_errors
#   test_detached_child_term_kill_and_unset_pid
#   test_exit_watch_posts_the_cookie_on_exit_and_unwatch_closes   (Linux)
#
# Every child is reaped on every path; no test signals a pid it has reaped
# (a reaped pid may already name another process).
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.time import sleep

from komira_supervisor.supervisor import (
    ChildSpec,
    DetachedChild,
    DetachedExit,
    ExitInfo,
    Supervisor,
    _env_name_of,
    _sleep_ms,
    _usleep_micros,
    merge_env_overlay,
    process_environ,
    spawn_detached,
)
from komira_supervisor.proc_ffi import (
    ReapStatus,
    SIGKILL,
    SIGTERM,
    build_cstr_blob,
    proc_environ_at,
    proc_environ_count,
    proc_kqueue_exit_wait,
    proc_reap,
    proc_set_nonblocking,
)
from komira_supervisor.exit_monitor import (
    ProcExitWatch,
    unwatch_process_exit,
    watch_process_exit,
)
from komira_async.reactor.epoll_subsystem import (
    EpollEvent,
    epoll_close,
    epoll_create_v1,
    epoll_wait_decode,
)


comptime _CLOSED_FD = Int32(1000000)  # above any fd limit a test runs with


def _spawned(pid: Int32) raises:
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


def _setenv(name: String, value: String):
    # SAFETY: both locals are rebound to `var` so as_c_string_slice() can be
    # called; setenv copies both strings before returning; both are anchored
    # past the call.
    var n = name
    var v = value
    _ = external_call["setenv", Int32](
        n.as_c_string_slice().unsafe_ptr(),
        v.as_c_string_slice().unsafe_ptr(),
        Int32(1),
    )
    _ = n
    _ = v


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def _count(entries: List[String], want: String) -> Int:
    var n = 0
    for ref e in entries:
        if e == want:
            n += 1
    return n


def _await_detached(child: DetachedChild) raises -> DetachedExit:
    """Poll a detached child until it is not running. No cap and no deadline:
    the exit is the event waited for (a child that never exits is stopped by
    the gate hang limit, `test_hang_limit_s`: "Time limits" in
    tools/build/mojo/README.md)."""
    while True:
        var e = child.poll_exit()
        if not e.running:
            return e
        sleep(Float64(0.01))


# -----------------------------------------------------------------------------
def test_sleep_ms_sleeps_only_a_positive_duration() raises:
    # The clamp is a pure function of the argument, so the test reads what
    # `_sleep_ms` would hand to usleep instead of timing a real sleep.
    # What it does not check: that `_sleep_ms` passes `_usleep_micros(ms)` on
    # to usleep, and returns before it for 0. Observing that needs a sleeper
    # seam or a clock, and a test never waits on or asserts time.
    assert_equal(_usleep_micros(30), UInt32(30000), "30 ms is 30000 us")
    assert_equal(_usleep_micros(1), UInt32(1000), "the smallest positive")
    assert_equal(_usleep_micros(0), UInt32(0), "0 asks for no sleep")
    # usleep of a wrapped negative would be ~71 minutes.
    assert_equal(_usleep_micros(-5), UInt32(0), "a negative asks for no sleep")
    # Both calls return at once with no sleep requested.
    _sleep_ms(0)
    _sleep_ms(-5)


def test_negative_and_closed_fds_are_refused_not_read() raises:
    var sup = Supervisor()
    assert_equal(sup.set_nonblocking(Int32(-1)), Int32(-1), "no syscall on -1")
    assert_true(
        proc_set_nonblocking(_CLOSED_FD) < Int32(-1),
        "CONTROL: a syscall on a closed fd is -errno, not -1",
    )
    var neg = sup.read_available(Int32(-1))
    assert_true(neg.eof, "read_available(-1) is EOF")
    assert_false(neg.error or neg.would_block, "and nothing else")
    assert_equal(neg.text, String(""))
    var bad = sup.read_available(_CLOSED_FD)
    assert_true(bad.error, "a read error is `error`")
    assert_false(bad.eof or bad.would_block, "never EOF or would_block")
    var both = sup.drain_both(Int32(-1), Int32(-1))
    assert_equal(both[0], String(""))
    assert_equal(both[1], String(""))


def test_drain_both_waits_out_a_silent_child() raises:
    # 300 ms of silence: both pipes would_block on many turns (the loop's
    # pause), and neither is retired for it.
    var sup = Supervisor()
    _spawned(sup.spawn(ChildSpec.shell(String("sleep 0.3; echo out; echo err >&2"))))
    var both = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(0))
    sup.close()
    assert_equal(both[0], String("out\n"), "stdout after the silence")
    assert_equal(both[1], String("err\n"), "stderr after the silence")


def test_wait_exit_and_try_wait_answer_from_the_cache() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 4")))
    _spawned(pid)
    assert_equal(sup.pid(), pid)
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(4), "first wait")
    var again = sup.wait_exit()
    assert_equal(again.exit_code, Int32(4), "second wait reads the cache")
    assert_equal(again.signal, Int32(-1))
    var t = sup.try_wait()
    assert_true(t.collected and t.exited and not t.signaled and not t.error, "cached exit")
    assert_equal(t.exit_code, Int32(4))
    assert_equal(t.signal, Int32(-1))
    sup.close()

    var k = Supervisor()
    var kpid = k.spawn(ChildSpec.shell(String("exec sleep 30")))
    _spawned(kpid)
    assert_equal(k.signal(SIGKILL), Int32(0), "kill(pid, SIGKILL)")
    assert_equal(k.wait_exit().signal, SIGKILL)
    var again_k = k.wait_exit()
    assert_equal(again_k.signal, SIGKILL, "second wait reads the cache")
    assert_equal(again_k.shell_code, Int32(137))
    var tk = k.try_wait()
    assert_true(tk.collected and tk.signaled and not tk.exited, "cached signal")
    assert_equal(tk.signal, SIGKILL)
    assert_equal(tk.exit_code, Int32(-1))
    k.close()


def test_a_child_reaped_elsewhere_reads_as_the_sentinel_and_is_not_cached() raises:
    var s = ExitInfo.from_reap(
        ReapStatus(
            collected=False, error=True, exited=False,
            exit_code=Int32(-1), signaled=False, signal=Int32(-1),
        )
    )
    assert_equal(s.exit_code, Int32(-1))
    assert_equal(s.signal, Int32(-1))
    assert_equal(s.shell_code, Int32(-1))

    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 5")))
    _spawned(pid)
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var stolen = proc_reap(pid, nohang=False)
    assert_true(stolen.collected and stolen.exit_code == Int32(5), "reaped here")
    var info = sup.wait_exit()
    assert_equal(info.exit_code, Int32(-1), "ECHILD reads as the sentinel")
    assert_equal(info.signal, Int32(-1))
    assert_equal(info.shell_code, Int32(-1))
    var t = sup.try_wait()
    assert_true(t.error and not t.collected, "the failed wait was not cached")
    sup.close()


def test_env_name_of_an_entry_without_equals_is_the_entry() raises:
    assert_equal(_env_name_of(String("NOEQ")), String("NOEQ"))
    assert_equal(_env_name_of(String("K=V=W")), String("K"))
    assert_equal(_env_name_of(String("=V")), String(""))
    var base = List[String]()
    base.append(String("A=1"))
    var overlay = List[String]()
    overlay.append(String("X"))
    overlay.append(String("Y"))
    var m = merge_env_overlay(base^, overlay)
    assert_equal(len(m), 3, "X and Y are two names")
    assert_equal(m[1], String("X"))
    assert_equal(m[2], String("Y"))
    var base2 = List[String]()
    base2.append(String("X"))
    base2.append(String("A=1"))
    var ov2 = List[String]()
    ov2.append(String("X"))
    var m2 = merge_env_overlay(base2^, ov2)
    assert_equal(len(m2), 2, "an `=`-less name replaces itself in place")
    assert_equal(m2[0], String("X"))


def _blob_hex(b: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(b)):
        s += String(Int(b[i])) + " "
    return s^


def test_cstr_blob_skips_nuls_and_is_never_empty() raises:
    assert_equal(_blob_hex(build_cstr_blob(List[String]())), String("0 "), "no items")
    var one_empty = List[String]()
    one_empty.append(String(""))
    assert_equal(_blob_hex(build_cstr_blob(one_empty)), String("0 "), "one empty item")
    var raw = List[UInt8]()
    raw.append(UInt8(97))
    raw.append(UInt8(0))
    raw.append(UInt8(98))
    var items = List[String]()
    items.append(String(unsafe_from_utf8=Span[UInt8](raw)))
    items.append(String(""))
    items.append(String("c"))
    assert_equal(
        _blob_hex(build_cstr_blob(items)),
        String("97 98 0 0 99 0 "),
        "the embedded NUL is dropped; each item ends in one NUL",
    )


def test_environ_at_protocol_out_of_range_and_too_small() raises:
    _setenv(String("KOMIRA_SUP_PROTO"), String("v"))
    var n = proc_environ_count()
    assert_true(n > 0, "environ has the entry just set")
    var buf = List[UInt8]()
    for _ in range(64):
        buf.append(UInt8(0))
    var past = proc_environ_at(n, buf, 64)
    assert_equal(past.bytes, -1, "index == count is out of range")
    assert_equal(past.needed, 0, "out of range asks for no capacity")
    var neg = proc_environ_at(-1, buf, 64)
    assert_equal(neg.bytes, -1)
    assert_equal(neg.needed, 0)
    # Find the entry, then read it with one byte too few, then exactly enough.
    var idx = -1
    for i in range(n):
        var r = proc_environ_at(i, buf, 64)
        if r.bytes == String("KOMIRA_SUP_PROTO=v").byte_length() and String(
            unsafe_from_utf8=Span[UInt8](buf)[0 : r.bytes]
        ) == String("KOMIRA_SUP_PROTO=v"):
            idx = i
    assert_true(idx >= 0, "found the entry")
    var need = String("KOMIRA_SUP_PROTO=v").byte_length() + 1
    var short = proc_environ_at(idx, buf, need - 1)
    assert_equal(short.bytes, -1, "one byte short")
    assert_equal(short.needed, need, "asks for len + 1")
    var fits = proc_environ_at(idx, buf, need)
    assert_equal(fits.bytes, need - 1, "exactly enough")


def test_process_environ_grows_once_for_an_entry_past_4096_bytes() raises:
    # Entry bytes + NUL: "KOMIRA_SUP_FIT=" is 15 bytes; 4080 + 15 + 1 = 4096
    # fits the starting buffer; 4081 needs 4097, the grow path.
    var fit_v = _repeat(String("f"), 4080)
    var grow_v = _repeat(String("g"), 4081)
    var huge_v = _repeat(String("h"), 70000)
    _setenv(String("KOMIRA_SUP_FIT"), fit_v)
    _setenv(String("KOMIRA_SUP_GRO"), grow_v)
    _setenv(String("KOMIRA_SUP_HUG"), huge_v)
    _setenv(String("KOMIRA_SUP_AFTER"), String("after"))
    var env = process_environ()
    assert_equal(len(env), proc_environ_count(), "every entry read")
    assert_equal(_count(env, String("KOMIRA_SUP_FIT=") + fit_v), 1, "4096-byte entry")
    assert_equal(_count(env, String("KOMIRA_SUP_GRO=") + grow_v), 1, "4097-byte entry")
    assert_equal(_count(env, String("KOMIRA_SUP_HUG=") + huge_v), 1, "70016-byte entry")
    assert_equal(_count(env, String("KOMIRA_SUP_AFTER=after")), 1, "a later entry")


def test_set_cwd_runs_the_child_there() raises:
    var spec = ChildSpec.shell(String("pwd"))
    spec.set_cwd(String("/dev"))
    var sup = Supervisor()
    _spawned(sup.spawn(spec))
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    assert_equal(sup.wait_exit().exit_code, Int32(0))
    sup.close()
    assert_equal(String(out.strip()), String("/dev"))
    # CONTROL: without set_cwd the child runs where this test does.
    var spec2 = ChildSpec.shell(String("pwd"))
    var sup2 = Supervisor()
    _spawned(sup2.spawn(spec2))
    var out2 = sup2.drain_pipe(sup2.stdout_fd())
    _ = sup2.drain_pipe(sup2.stderr_fd())
    _ = sup2.wait_exit()
    sup2.close()
    assert_true(String(out2.strip()) != String("/dev"), "CONTROL: " + out2)


def _sh_args(cmd: String) -> List[String]:
    var a = List[String]()
    a.append(String("-c"))
    a.append(cmd)
    return a^


def test_spawn_detached_exit_env_and_errors() raises:
    var env = List[String]()
    env.append(String("KOMIRA_SUP_CODE=9"))
    var pid = spawn_detached(String("/bin/sh"), _sh_args(String("exit $KOMIRA_SUP_CODE")), env)
    _spawned(pid)
    var child = DetachedChild(pid)
    assert_equal(child.pid(), pid)
    var e = _await_detached(child)
    assert_true(e.exited and not e.signaled and not e.error, "exited")
    assert_equal(e.exit_code, Int32(9), "the explicit environment reached the child")
    var gone = child.poll_exit()
    assert_true(gone.error and not gone.running, "a reaped child polls as error")

    _setenv(String("KOMIRA_SUP_INHERIT"), String("7"))
    var ipid = spawn_detached(
        String("/bin/sh"), _sh_args(String("exit $KOMIRA_SUP_INHERIT")), List[String]()
    )
    _spawned(ipid)
    var ie = _await_detached(DetachedChild(ipid))
    assert_equal(ie.exit_code, Int32(7), "no env: the child inherits this one")

    var missing = spawn_detached(
        String("/nonexistent-komira-supervisor/x"), List[String](), List[String]()
    )
    assert_equal(missing, Int32(-2), "-ENOENT, not a pid")


def test_detached_child_term_kill_and_unset_pid() raises:
    for p in [Int32(0), Int32(-1)]:
        var unset = DetachedChild(p)
        var e = unset.poll_exit()
        assert_true(e.error and not e.running and not e.exited, "unset pid polls as error")
        assert_equal(unset.term(), Int32(-1), "no signal for pid " + String(p))
        assert_equal(unset.kill(), Int32(-1), "no signal for pid " + String(p))

    var tpid = spawn_detached(
        String("/bin/sh"), _sh_args(String("exec sleep 30")), List[String]()
    )
    _spawned(tpid)
    var t = DetachedChild(tpid)
    assert_true(t.poll_exit().running, "a live child is running")
    assert_equal(t.term(), Int32(0))
    var te = _await_detached(t)
    assert_true(te.signaled and not te.exited, "terminated by a signal")
    assert_equal(te.signal, SIGTERM)

    var kpid = spawn_detached(
        String("/bin/sh"), _sh_args(String("exec sleep 30")), List[String]()
    )
    _spawned(kpid)
    var k = DetachedChild(kpid)
    assert_equal(k.kill(), Int32(0))
    var ke = _await_detached(k)
    assert_equal(ke.signal, SIGKILL)


def test_exit_watch_posts_the_cookie_on_exit_and_unwatch_closes() raises:
    comptime if not CompilationTarget.is_linux():
        print("  SKIP (not Linux: this test drives the pidfd + epoll arm): exit watch")
        return
    assert_equal(
        proc_kqueue_exit_wait(Int32(1), Int32(0)), Int32(-2), "not darwin: -2"
    )
    assert_false(ProcExitWatch(pid=Int32(-1), pidfd=Int32(-1), cookie=0).is_valid())
    assert_true(ProcExitWatch(pid=Int32(0), pidfd=Int32(-1), cookie=0).is_valid())
    var efd = epoll_create_v1()
    var other = epoll_create_v1()
    var raised = String("")
    try:
        _ = watch_process_exit(efd, Int32(-1), UInt64(1))
    except e:
        raised = String(e)
    assert_true(raised.find("pidfd_open failed") >= 0, "bad pid: " + raised)

    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("sleep 0.3")))
    _spawned(pid)
    comptime COOKIE = UInt64(0xC0FFEE0000000001)
    var w = watch_process_exit(efd, pid, COOKIE)
    assert_true(w.is_valid() and w.pidfd >= Int32(0), "a pidfd is held")
    var events = List[EpollEvent]()
    var early = epoll_wait_decode(efd, events, Int32(0))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var n = epoll_wait_decode(efd, events, Int32(5000))
    var data = events[0].data if n > 0 else UInt64(0)
    _ = sup.wait_exit()
    sup.close()
    assert_equal(early, 0, "a running child posts nothing")
    assert_equal(n, 1, "the exit posts one event")
    assert_equal(data, COOKIE, "carrying the cookie")

    var held = w.pidfd
    # Deregistering from an epoll the pidfd was never added to fails
    # (ENOENT); unwatch still closes the pidfd and forgets it.
    unwatch_process_exit(other, w)
    assert_equal(w.pidfd, Int32(-1), "the watch forgets its pidfd")
    assert_true(proc_set_nonblocking(held) < Int32(0), "the pidfd is closed")
    unwatch_process_exit(efd, w)  # nothing held: a no-op
    epoll_close(efd)
    epoll_close(other)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
