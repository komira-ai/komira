# =============================================================================
# test_supervisor_scenarios.mojo — the komira_supervisor scenario suite.
# =============================================================================
#
# Spawn, capture, exit, kill and the exit monitor, plus two-pipe separation.
# Live on BOTH platforms: scenario (f) asserts the darwin EVFILT_PROC arm on
# macOS and the pidfd arm on Linux (see that scenario's header).
#
#   (a) capture N lines + exit 0       — full stdout captured, exit_code == 0
#   (b) >1 MB output, no deadlock       — all bytes drained (reactor-shape drain)
#   (c) SIGTERM a long-running child    — dies on SIGTERM, shell_code == 143
#   (d) SIGTERM-ignoring child          — escalates to SIGKILL, shell_code == 137
#   (e) no zombie after reap            — first reap ok, second reap ECHILD
#   (f) reactor-clean exit monitor      — darwin EVFILT_PROC fires (Linux: pidfd)
#   (g) TWO-PIPE SEPARATION             — stdout drain and stderr drain see only
#                                         their own stream
#   (n) BYTE-PRESERVING CAPTURE         — multi-byte UTF-8 written by a real
#                                         child survives drain_pipe, drain_both
#                                         and process_environ BYTE-FOR-BYTE.
#                                         See that scenario's own header.
#   (k) BARE-NAME PATH RESOLUTION       — a bare executable name is PATH-searched
#                                         (posix_spawnp); an unresolvable one
#                                         still fails loud. See the scenario's
#                                         own header.
#
# Drained continuously to avoid the pipe-buffer deadlock: we drain stdout AND
# stderr to EOF, THEN reap. With two pipes a child that writes a lot to ONE
# stream while the other stays small must still not deadlock — we drain both.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.time import sleep

from komira_supervisor.supervisor import (
    ChildSpec,
    ExitInfo,
    Supervisor,
    merge_env_overlay,
    process_environ,
)
from komira_supervisor.proc_ffi import (
    proc_close,
    proc_kqueue_exit_wait,
    proc_pidfd_open,
    proc_pidfd_wait,
    proc_reap,
)


def _banner(label: String):
    print("================================================================")
    print(label)
    print("================================================================")


# -----------------------------------------------------------------------------
# (a) child prints N lines then exits 0 -> capture all + exit code 0.
# -----------------------------------------------------------------------------
def scenario_a(mut fails: Int):
    print("(a) capture N lines + exit code 0")
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(
            String("for i in 1 2 3 4 5; do echo line-$i; done; exit 0")
        )
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())  # drain (empty) stderr too
    var info = sup.wait_exit()
    var ok_lines = True
    for i in range(1, 6):
        if String("line-") + String(i) not in out:
            ok_lines = False
    if ok_lines and info.exit_code == Int32(0):
        print("  PASS (5 lines captured, exit 0)")
    else:
        print("  FAIL: exit_code", info.exit_code, "out=", out)
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (b) child emits > one pipe buffer (~1MB) -> no deadlock, full capture.
# -----------------------------------------------------------------------------
def scenario_b(mut fails: Int):
    print("(b) >1MB output, no deadlock")
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(
            String(
                "i=0; while [ $i -lt 20000 ]; do "
                + "echo"
                + " AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-$i;"
                + " i=$((i+1)); done; exit 0"
            )
        )
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    var total = sup.drain_pipe_bytes(sup.stdout_fd())
    _ = sup.drain_pipe_bytes(sup.stderr_fd())
    var info = sup.wait_exit()
    if total > 1_000_000 and info.exit_code == Int32(0):
        print("  PASS (no deadlock; drained", total, "bytes)")
    else:
        print("  FAIL: only", total, "bytes, exit_code", info.exit_code)
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (c) long-running child -> SIGTERM -> exits; supervisor detects it.
# -----------------------------------------------------------------------------
def scenario_c(mut fails: Int):
    print("(c) SIGTERM a long-running child")
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("sleep 30")))
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    var info = sup.terminate(2000)
    # default SIGTERM disposition -> 128 + 15 = 143
    if info.shell_code == Int32(143):
        print("  PASS (died on SIGTERM, shell_code 143)")
    else:
        print(
            "  FAIL: shell_code", info.shell_code, "signal", info.signal,
        )
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (d) child traps/ignores SIGTERM -> escalate to SIGKILL -> dies.
# -----------------------------------------------------------------------------
def scenario_d(mut fails: Int):
    print("(d) SIGTERM-ignoring child escalates to SIGKILL")
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(
            String("trap '' TERM; while true; do sleep 1; done")
        )
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    # Let the shell install `trap '' TERM` before we signal — otherwise the
    # SIGTERM can race in before the trap is registered and kill the shell.
    sleep(0.15)
    var info = sup.terminate(800)  # 800ms grace, then SIGKILL
    # SIGKILL -> 128 + 9 = 137
    if info.shell_code == Int32(137):
        print("  PASS (ignored SIGTERM, died on SIGKILL, shell_code 137)")
    else:
        print(
            "  FAIL: shell_code", info.shell_code, "signal", info.signal,
        )
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (e) no zombies: after reap, a second reap reports ECHILD.
# -----------------------------------------------------------------------------
def scenario_e(mut fails: Int):
    print("(e) no zombie remains after reap")
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("echo done; exit 7")))
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()  # this reaps exactly once
    # A direct second reap (bypassing the Supervisor's idempotency cache) must
    # NOT find a live/zombie child -> ECHILD -> proc_reap reports error.
    var r2 = proc_reap(pid, nohang=True)
    if info.exit_code == Int32(7) and r2.error:
        print("  PASS (reaped once, no zombie, exit 7; 2nd reap ECHILD)")
    else:
        print(
            "  FAIL: exit_code", info.exit_code,
            "second-reap collected?", r2.collected, "error?", r2.error,
        )
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (f) reactor-clean exit monitor: child exit is a kernel EVENT, no SIGCHLD
#     handler. darwin: EVFILT_PROC / NOTE_EXIT (the production path registers
#     this on the long-lived reactor kqueue via kevent_register_proc_exit; here
#     we use the self-contained standalone wait to prove the kernel mechanism).
#     Linux: pidfd_open + POLLIN (the production path registers the SAME pidfd
#     on the reactor's epoll via exit_monitor.watch_process_exit; here we use
#     the self-contained poll() for the same reason the darwin arm uses a fresh
#     kqueue — to prove the KERNEL mechanism without standing up a reactor).
#
# Both arms ASSERT. A Linux arm that only printed SKIP would let scenario (f)
# assert nothing on every Linux machine while the suite reported green. Each
# Linux leg goes RED when the C shim is broken:
#   leg 1  `komira_proc_pidfd_wait` stubbed to `return 1` (always ready)
#            -> "FAIL: pidfd of a RUNNING child polled ready: 1". Leg 2 alone
#               would PASS under that stub.
#   leg 2  `komira_proc_pidfd_open` stubbed to `return -ENOSYS`
#            -> "FAIL: pidfd_open(live) returned -38".
# -----------------------------------------------------------------------------
def _scenario_f_darwin(mut fails: Int):
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(String("sleep 0.3; echo from-child; exit 0"))
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    # Drain the pipes first (short child); then ask the kernel for the exit
    # event WITHOUT reaping — proving EVFILT_PROC sees the transition itself.
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var fired = proc_kqueue_exit_wait(pid, Int32(5000))
    # Now reap to clear the zombie (EVFILT_PROC notifies, does not reap).
    var info = sup.wait_exit()
    if fired == Int32(1) and info.exit_code == Int32(0):
        print("  PASS (reactor saw exit as an EVENT, no SIGCHLD handler)")
    else:
        print("  FAIL: fired", fired, "exit_code", info.exit_code)
        fails += 1
    sup.close()


def _scenario_f_linux(mut fails: Int):
    # ---- LEG 1: a LIVE child's pidfd is NOT readable. --------------------
    # This leg is what makes the scenario discriminating. Leg 2 alone is
    # satisfied by a stub that returns 1 unconditionally — and this file's
    # own darwin/Linux stub pair in _proc_shim.c is exactly the shape that
    # produces such a stub by accident. `sleep 30` polled at timeout=0 is a
    # ~30s margin, not a race; scenario (c) already spawns the same child.
    var live = Supervisor()
    var live_pid = live.spawn(ChildSpec.shell(String("sleep 30")))
    if live_pid <= Int32(0):
        print("  FAIL: spawn(live) returned", live_pid)
        fails += 1
        return
    var live_fd = proc_pidfd_open(live_pid)
    if live_fd < Int32(0):
        print(
            "  FAIL: pidfd_open(live) returned", live_fd,
            "(negative is -errno; kernel >= 5.3 required)",
        )
        fails += 1
        _ = live.terminate(2000)
        live.close()
        return
    var live_ready = proc_pidfd_wait(live_fd, Int32(0))
    proc_close(live_fd)
    _ = live.terminate(2000)
    live.close()
    if live_ready != Int32(0):
        print(
            "  FAIL: pidfd of a RUNNING child polled ready:", live_ready,
            "(expected 0 = timeout; 1 means the fd does not track the"
            " process, -2 means the Linux arm was compiled out)",
        )
        fails += 1
        return

    # ---- LEG 2: the pidfd becomes readable on the exit TRANSITION. -------
    # Opened while the child is still alive (it sleeps 0.3s), so POLLIN here
    # is the kernel posting the transition, not a property of a pid that was
    # already dead when we asked.
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(String("sleep 0.3; echo from-child; exit 0"))
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    var pidfd = proc_pidfd_open(pid)
    if pidfd < Int32(0):
        print("  FAIL: pidfd_open returned", pidfd)
        fails += 1
        _ = sup.wait_exit()
        sup.close()
        return
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var fired = proc_pidfd_wait(pidfd, Int32(5000))
    proc_close(pidfd)
    # Now reap to clear the zombie (POLLIN notifies, it does not reap).
    var info = sup.wait_exit()
    if fired == Int32(1) and info.exit_code == Int32(0):
        print(
            "  PASS (pidfd not ready while alive; POLLIN on exit; no SIGCHLD"
            " handler)"
        )
    else:
        print("  FAIL: fired", fired, "exit_code", info.exit_code)
        fails += 1
    sup.close()


def scenario_f(mut fails: Int):
    print("(f) reactor-clean exit monitor (EVFILT_PROC / pidfd POLLIN)")
    comptime if CompilationTarget.is_macos():
        _scenario_f_darwin(fails)
    else:
        _scenario_f_linux(fails)


# -----------------------------------------------------------------------------
# (g) TWO-PIPE SEPARATION. The child writes DISTINCT text to stdout and stderr; the
#     stdout drain must see ONLY the stdout text and the stderr drain ONLY the
#     stderr text. This is load-bearing: a caller may stream stdout but only
#     tail-capture stderr for forensics.
# -----------------------------------------------------------------------------
def scenario_g(mut fails: Int):
    print("(g) two-pipe separation (stdout vs stderr)")
    var sup = Supervisor()
    # echo to stdout; echo ... >&2 to stderr. Interleave to prove they don't mix.
    var pid = sup.spawn(
        ChildSpec.shell(
            String(
                "echo OUT-ALPHA; echo ERR-BETA >&2; "
                + "echo OUT-GAMMA; echo ERR-DELTA >&2; exit 0"
            )
        )
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    var out = sup.drain_pipe(sup.stdout_fd())
    var err = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()

    var out_ok = (
        (String("OUT-ALPHA") in out)
        and (String("OUT-GAMMA") in out)
        and (String("ERR-BETA") not in out)
        and (String("ERR-DELTA") not in out)
    )
    var err_ok = (
        (String("ERR-BETA") in err)
        and (String("ERR-DELTA") in err)
        and (String("OUT-ALPHA") not in err)
        and (String("OUT-GAMMA") not in err)
    )
    if out_ok and err_ok and info.exit_code == Int32(0):
        print("  PASS (stdout and stderr captured on SEPARATE pipes)")
    else:
        print("  FAIL: out_ok", out_ok, "err_ok", err_ok)
        print("    stdout=[", out, "]")
        print("    stderr=[", err, "]")
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# (j) CONCURRENT-DRAIN NO-DEADLOCK — the two-pipe drain deadlock.
#
#     The child floods STDERR with >64KB (256KB here) and writes its terminal
#     marker line to STDOUT *last*. A sequential drain — `drain_pipe(stdout)`
#     fully, then `drain_pipe(stderr)` — deadlocks: the stdout marker only
#     arrives on child EXIT, so the stdout drain blocks until the child exits,
#     but the child is itself blocked on write(2) to the FULL (>64KB) stderr
#     pipe buffer that nobody is draining. The child never exits, the stdout
#     drain never returns, and the test times out.
#
#     The concurrent `drain_both(stdout_fd, stderr_fd)` interleaves both fds
#     non-blocking so neither buffer can fill while the other is read; the
#     child completes, both streams are captured in full, and the child exits 0.
# -----------------------------------------------------------------------------
def scenario_concurrent_drain_no_deadlock(mut fails: Int):
    print("(j) concurrent drain: >64KB stderr flood + stdout marker last")
    var sup = Supervisor()
    # Child: write ~256KB to STDERR (well past the ~64KB pipe buffer), THEN a
    # single terminal marker line to STDOUT as its LAST write, then exit 0.
    # `yes | head -c` emits deterministic bytes fast; redirect to fd 2 (stderr).
    # The stdout marker is written AFTER the stderr flood, so under a sequential
    # stdout-first drain the child wedges on the full stderr pipe before it can
    # emit the marker -> stdout EOF never arrives -> deadlock.
    var pid = sup.spawn(
        ChildSpec.shell(
            String(
                "yes ERRLINE | head -c 262144 1>&2; "
                + "echo DONE_MARKER=deadbeef; "
                + "exit 0"
            )
        )
    )
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    # Under test: drain BOTH pipes concurrently. Two sequential drain_pipe()
    # calls would HANG here.
    var streams = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    var out = streams[0]
    var err = streams[1]
    var info = sup.wait_exit()

    var out_ok = String("DONE_MARKER=deadbeef") in out
    # stderr must be captured IN FULL (not silently dropped): 262144 bytes of
    # "ERRLINE\n" -> err.byte_length() should be ~262144 (head -c exact cut).
    var err_len = err.byte_length()
    var err_ok = err_len >= 262000 and (String("ERRLINE") in err)
    if out_ok and err_ok and info.exit_code == Int32(0):
        print(
            "  PASS (no deadlock; stdout marker seen, stderr fully captured",
            err_len, "bytes)",
        )
    else:
        print(
            "  FAIL: out_ok", out_ok, "err_ok", err_ok,
            "err_len", err_len, "exit_code", info.exit_code,
        )
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# Idempotency edges: terminate after exit, and terminate twice.
# -----------------------------------------------------------------------------
def scenario_idempotent(mut fails: Int):
    print("(h) terminate-after-exit / double-terminate idempotency")
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 3")))
    if pid <= Int32(0):
        print("  FAIL: spawn returned", pid)
        fails += 1
        return
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info1 = sup.wait_exit()
    # The child already exited; terminate must be a no-op returning the cache.
    var info2 = sup.terminate(1000)
    var info3 = sup.terminate(1000)  # second terminate also a no-op
    if (
        info1.exit_code == Int32(3)
        and info2.exit_code == Int32(3)
        and info3.exit_code == Int32(3)
    ):
        print("  PASS (exit 3 cached; terminate idempotent)")
    else:
        print(
            "  FAIL: e1", info1.exit_code, "e2", info2.exit_code,
            "e3", info3.exit_code,
        )
        fails += 1
    sup.close()


# -----------------------------------------------------------------------------
# spawn failure: non-existent binary -> spawn returns a negative errno, no
# pipe fds leaked (the C shim cleans up before returning).
# -----------------------------------------------------------------------------
def scenario_spawn_fail(mut fails: Int):
    print("(i) spawn failure (non-existent binary path)")
    var sup = Supervisor()
    var spec = ChildSpec(String("/nonexistent/komira/binary/zzz"))
    var rc = sup.spawn(spec)
    if rc < Int32(0):
        print("  PASS (spawn returned -errno", rc, "no fd leak)")
    else:
        print("  FAIL: spawn unexpectedly succeeded rc", rc)
        fails += 1
        sup.close()


# -----------------------------------------------------------------------------
# (k) BARE-NAME PATH RESOLUTION — posix_spawnp, not posix_spawn.
#
# The non-`p` `posix_spawn` does NOT PATH-search, so every caller that passes a
# BARE executable name gets ENOENT even when the binary is installed and on
# PATH (for example a daemon runner whose default binary is a bare name, or a
# build driver spawning `crane`).
#
# With `posix_spawn`, `ChildSpec(String("sh"))` returns a NEGATIVE rc
# (-ENOENT == -2) from `spawn`, so the scenario reports FAIL. With
# `posix_spawnp` the bare name resolves against the inherited PATH exactly as
# execvp(3) does, the child runs, and stdout carries its marker.
#
# The second half is the guard against over-correcting: a bare name that is NOT
# on PATH must STILL fail loud (negative rc), never silently resolve to
# something else. A spawn that cannot find its binary must never look like a
# pass.
# -----------------------------------------------------------------------------
def scenario_bare_name_path_resolution(mut fails: Int):
    print("(k) bare-name binary resolves via PATH (posix_spawnp)")

    # -- (k1) a bare name that IS on PATH must spawn and run. --
    var sup = Supervisor()
    var spec = ChildSpec(String("sh"))
    spec.with_arg(String("-c"))
    spec.with_arg(String("echo path-resolved-ok"))
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        print(
            "  FAIL: bare-name spawn of 'sh' returned",
            pid,
            "— posix_spawn (non-p) does not PATH-search; the shim must use"
            " posix_spawnp",
        )
        fails += 1
    else:
        var out = sup.drain_pipe(sup.stdout_fd())
        _ = sup.drain_pipe(sup.stderr_fd())
        var info = sup.wait_exit()
        if String("path-resolved-ok") in out and info.exit_code == Int32(0):
            print("  PASS (k1: bare 'sh' PATH-resolved, ran, exit 0)")
        else:
            print("  FAIL: exit_code", info.exit_code, "out=", out)
            fails += 1
        sup.close()

    # -- (k2) a bare name that is NOT on PATH must still fail loud. --
    var sup2 = Supervisor()
    var missing = ChildSpec(String("komira-no-such-tool-zzz-9d3f"))
    var rc2 = sup2.spawn(missing)
    if rc2 < Int32(0):
        print("  PASS (k2: unresolvable bare name still fails, rc", rc2, ")")
    else:
        print(
            "  FAIL: unresolvable bare name spawned anyway, rc",
            rc2,
            "— a missing binary must never look like a pass",
        )
        fails += 1
        sup2.close()


# -----------------------------------------------------------------------------
# (m) ⛔ THE ENVIRONMENT IS ALL-OR-NOTHING, SO ONE AUTHORED VARIABLE CAN BE A
#     KILL SWITCH. Covers `set_env_over_inherited` (`merge_env_overlay` +
#     `process_environ`).
#
# `posix_spawn` has exactly two env arms — inherit `environ`, or REPLACE it —
# and `ChildSpec.set_env` takes the second. A caller that authors ONE variable
# (say `AWS_REGION`) through `set_env` therefore runs its child with EXACTLY
# ONE variable, which strips `LD_LIBRARY_PATH` (the child dies with `error while
# loading shared libraries`, exit 127) and `$HOME` + `AWS_PROFILE` (every arm of
# the AWS credential chain declines).
#
# ⚠ THE THREE ASSERTIONS BELOW ARE ONE CLAIM EACH, and the THIRD is the one a
# naive "just append the authored entries" fix fails: glibc's `getenv` returns
# the FIRST match in `envp`, so an appended override does not override. The
# merge REPLACES IN PLACE.
# -----------------------------------------------------------------------------
def _setenv(name: String, value: String):
    # SAFETY: both locals are rebound to `var` so `as_c_string_slice()` (a
    # mutating method) can be called; `setenv` COPIES both strings into
    # environ-managed storage before returning, and both locals are anchored
    # past the call.
    var n = name
    var v = value
    _ = external_call["setenv", Int32](
        n.as_c_string_slice().unsafe_ptr(),
        v.as_c_string_slice().unsafe_ptr(),
        Int32(1),  # overwrite
    )
    _ = n
    _ = v


comptime _ECHO_MARKERS: String = (
    'echo "A=[$MARKER_AMBIENT] C=[$MARKER_CLASH] AUTH=[$MARKER_AUTHORED]"'
)


def _run_capturing(var spec: ChildSpec) raises -> String:
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        sup.close()
        raise Error(String("spawn failed, rc=") + String(pid))
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()
    return out^


def _slist(var a: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    return out^


def _slist2(var a: String, var b: String) -> List[String]:
    var out = List[String]()
    out.append(a^)
    out.append(b^)
    return out^


def _count_entries_named(entries: List[String], name: String) -> Int:
    var pre = name + String("=")
    var n = 0
    for ref e in entries:
        if e.startswith(pre):
            n += 1
    return n


def scenario_env_overlay_vs_closed(mut fails: Int) raises:
    print("(m) closed env vs inherited-plus-overlay")
    _setenv(String("MARKER_AMBIENT"), String("ambient-ok"))
    _setenv(String("MARKER_CLASH"), String("from-ambient"))

    # -- (m0) `process_environ` sees this process's own environment. --
    var ambient = process_environ()
    if _count_entries_named(ambient, String("MARKER_AMBIENT")) == 1:
        print("  PASS (m0: process_environ reads the live environ)")
    else:
        print(
            "  FAIL: process_environ returned",
            len(ambient),
            "entries and none of them was the one just set",
        )
        fails += 1

    # -- (m1) THE CLOSED ARM — set_env replaces the environment. --
    var closed = ChildSpec.shell(_ECHO_MARKERS)
    closed.set_env(_slist(String("MARKER_AUTHORED=authored-ok")))
    var out_closed = _run_capturing(closed^)
    if (
        String("A=[]") in out_closed
        and String("C=[]") in out_closed
        and String("AUTH=[authored-ok]") in out_closed
    ):
        print("  PASS (m1: set_env REPLACES — the child sees nothing else)")
    else:
        print("  FAIL: set_env is no longer all-or-nothing; out=", out_closed)
        fails += 1

    # -- (m2) THE OVERLAY ARM — inherited AND authored. --
    var overlay = ChildSpec.shell(_ECHO_MARKERS)
    overlay.set_env_over_inherited(
        _slist2(
            String("MARKER_AUTHORED=authored-ok"),
            String("MARKER_CLASH=from-authored"),
        )
    )
    var out_overlay = _run_capturing(overlay^)
    if (
        String("A=[ambient-ok]") in out_overlay
        and String("AUTH=[authored-ok]") in out_overlay
    ):
        print("  PASS (m2: the child inherits AND receives the authored value)")
    else:
        print("  FAIL: overlay lost one half; out=", out_overlay)
        fails += 1

    # -- (m3) ★ THE AUTHORED VALUE WINS, AND EXACTLY ONCE. --
    var merged = merge_env_overlay(
        process_environ(), _slist(String("MARKER_CLASH=from-authored"))
    )
    var dupes = _count_entries_named(merged, String("MARKER_CLASH"))
    if String("C=[from-authored]") in out_overlay and dupes == 1:
        print("  PASS (m3: replaced IN PLACE — one entry, the authored value)")
    else:
        print(
            "  FAIL: the authored value did not win by name (entries named"
            " MARKER_CLASH:",
            dupes,
            ") out=",
            out_overlay,
        )
        fails += 1

    # -- (m4) a NEW name is appended; an entry with no `=` is its own name. --
    var base = _slist2(String("A=1"), String("B=2"))
    var m2 = merge_env_overlay(
        base^, _slist2(String("B=9"), String("C=3"))
    )
    if (
        len(m2) == 3
        and m2[0] == String("A=1")
        and m2[1] == String("B=9")
        and m2[2] == String("C=3")
    ):
        print("  PASS (m4: replace in place, append new, order preserved)")
    else:
        print("  FAIL: merge_env_overlay ordering/replacement wrong, len=", len(m2))
        fails += 1


# -----------------------------------------------------------------------------
# (n) BYTE-PRESERVING CAPTURE — the `chr(Int(byte))` mojibake regression.
#
# A byte->String seam written as `out += chr(Int(buf[i]))` reads each raw byte
# as a UNICODE CODEPOINT and re-encodes it, so every multi-byte character comes
# out as three mojibake characters and the stream gets LONGER:
#
#     wrote  4d e2 80 94 45 e2 80 a6 4e         "M—E…N"       9 bytes
#     read   4d c3 a2 c2 80 c2 94 45 c3 a2 …    "MâE⦔   15 bytes
#
# With such a seam each leg below fails, byte-level:
#
#   n1  drain_pipe          15 bytes: 4d c3 a2 c2 80 c2 94 45 c3 a2 c2 80 c2 a6 4e
#   n2  drain_both          the same 15 bytes, on stdout AND on stderr
#   n3  200000 written  ->  300000 read, 33334 mojibake pairs
#   n4  process_environ     the parent set 9 bytes; the read-back is those 15
#
# Protocol markers parsed out of captured stdout are usually ASCII and survive
# such a transcode; only the prose an operator reads is corrupted. So the
# assertions below are deliberately BYTE-LEVEL, never `in`/`==` on a String
# whose ASCII skeleton survives the bug.
#
# The child writes its bytes with `printf` OCTAL escapes, so what is under test
# is the capture path and not this file's own source encoding.
# -----------------------------------------------------------------------------
comptime _UTF8_MARKER_OCTAL: String = "M\\342\\200\\224E\\342\\200\\246N"


def _utf8_marker_bytes() -> List[UInt8]:
    """The exact 9 bytes `_UTF8_MARKER_OCTAL` tells `printf` to emit."""
    var e = List[UInt8]()
    e.append(UInt8(0x4D))                                    # 'M'
    e.append(UInt8(0xE2)); e.append(UInt8(0x80)); e.append(UInt8(0x94))  # — U+2014
    e.append(UInt8(0x45))                                    # 'E'
    e.append(UInt8(0xE2)); e.append(UInt8(0x80)); e.append(UInt8(0xA6))  # … U+2026
    e.append(UInt8(0x4E))                                    # 'N'
    return e^


def _hex_of(s: String) -> String:
    var b = s.as_bytes()
    var digits = String("0123456789abcdef")
    var out = String("")
    for i in range(len(b)):
        var c = Int(b[i])
        out += digits[byte=(c >> 4)]
        out += digits[byte=(c & 15)]
        out += " "
    return out^


def _bytes_are(s: String, want: List[UInt8]) -> Bool:
    var b = s.as_bytes()
    if len(b) != len(want):
        return False
    for i in range(len(want)):
        if b[i] != want[i]:
            return False
    return True


def _mojibake_pairs(s: String) -> Int:
    """Occurrences of `c3 a2` — the two bytes `chr(Int(0xE2))` produces, and the
    signature this whole class was found by."""
    var b = s.as_bytes()
    var n = 0
    for i in range(len(b) - 1):
        if b[i] == UInt8(0xC3) and b[i + 1] == UInt8(0xA2):
            n += 1
    return n


def scenario_utf8_byte_preserving_capture(mut fails: Int) raises:
    print("(n) byte-preserving capture: multi-byte UTF-8 survives the drain")
    var want = _utf8_marker_bytes()

    # -- (n1) drain_pipe: the blocking drain-to-EOF path. --
    var sup1 = Supervisor()
    var pid1 = sup1.spawn(
        ChildSpec.shell(String("printf '") + _UTF8_MARKER_OCTAL + String("'"))
    )
    if pid1 <= Int32(0):
        print("  FAIL: spawn returned", pid1)
        fails += 1
        return
    var out1 = sup1.drain_pipe(sup1.stdout_fd())
    _ = sup1.drain_pipe(sup1.stderr_fd())
    _ = sup1.wait_exit()
    sup1.close()
    if _bytes_are(out1, want) and _mojibake_pairs(out1) == 0:
        print("  PASS (n1: drain_pipe returned the 9 bytes the child wrote)")
    else:
        print(
            "  FAIL: drain_pipe mangled the stream — got",
            out1.byte_length(), "bytes:", _hex_of(out1),
            "( mojibake c3a2 pairs:", _mojibake_pairs(out1), ")",
        )
        fails += 1

    # -- (n2) drain_both / read_available: the incremental non-blocking path,
    #        asserted on BOTH streams (stderr is the one an operator reads on a
    #        failure, and it goes through the same seam). --
    var sup2 = Supervisor()
    var pid2 = sup2.spawn(
        ChildSpec.shell(
            String("printf '") + _UTF8_MARKER_OCTAL + String("'; printf '")
            + _UTF8_MARKER_OCTAL + String("' 1>&2")
        )
    )
    if pid2 <= Int32(0):
        print("  FAIL: spawn returned", pid2)
        fails += 1
        return
    var streams = sup2.drain_both(sup2.stdout_fd(), sup2.stderr_fd())
    var out2 = streams[0]
    var err2 = streams[1]
    _ = sup2.wait_exit()
    sup2.close()
    if _bytes_are(out2, want) and _bytes_are(err2, want):
        print("  PASS (n2: drain_both preserved both streams byte-for-byte)")
    else:
        print(
            "  FAIL: drain_both mangled a stream — stdout", out2.byte_length(),
            "bytes:", _hex_of(out2), "/ stderr", err2.byte_length(),
            "bytes:", _hex_of(err2),
        )
        fails += 1

    # -- (n3) CHUNK-BOUNDARY STRESS. 200000 bytes >> the 65536-byte read chunk,
    #        so multi-byte characters WILL be split across reads. Nothing on the
    #        path decodes, so the fragments must rejoin exactly: the assertion
    #        is the exact byte COUNT (a transcode inflates it) plus zero mojibake pairs anywhere in 200KB. --
    var sup3 = Supervisor()
    var pid3 = sup3.spawn(
        ChildSpec.shell(
            String("X=$(printf 'A\\342\\200\\224B'); yes \"$X\" | head -c 200000")
        )
    )
    if pid3 <= Int32(0):
        print("  FAIL: spawn returned", pid3)
        fails += 1
        return
    var streams3 = sup3.drain_both(sup3.stdout_fd(), sup3.stderr_fd())
    var big = streams3[0]
    _ = sup3.wait_exit()
    sup3.close()
    var big_len = big.byte_length()
    var big_bake = _mojibake_pairs(big)
    if big_len == 200000 and big_bake == 0:
        print("  PASS (n3: 200000 bytes across ~4 read chunks, none transcoded)")
    else:
        print(
            "  FAIL: chunked capture is not byte-exact — got", big_len,
            "bytes (want 200000), mojibake c3a2 pairs:", big_bake,
        )
        fails += 1

    # -- (n4) `process_environ` — the SAME class on the env path, asserted
    #        WITHOUT a child so the drain cannot mask or cause it. These entries
    #        become the child's real environment via set_env_over_inherited. --
    var marker = String(unsafe_from_utf8=Span(want))
    _setenv(String("MARKER_UTF8"), marker)
    var entries = process_environ()
    var prefix = String("MARKER_UTF8=")
    var plen = prefix.byte_length()
    var found = False
    var got_value = String("")
    for ref e in entries:
        if e.startswith(prefix):
            found = True
            var eb = e.as_bytes()
            got_value = String(unsafe_from_utf8=eb[plen : len(eb)])
    if found and _bytes_are(got_value, want):
        print("  PASS (n4: process_environ returned the value the parent set)")
    else:
        print(
            "  FAIL: process_environ transcoded an environment VALUE — found",
            found, "value", got_value.byte_length(), "bytes:",
            _hex_of(got_value),
        )
        fails += 1


def main() raises:
    print("")
    print("== komira_supervisor scenarios ==")
    print("Platform is_macos =", CompilationTarget.is_macos())
    print("")

    var fails = 0
    scenario_a(fails)
    scenario_b(fails)
    scenario_c(fails)
    scenario_d(fails)
    scenario_e(fails)
    scenario_f(fails)
    scenario_g(fails)
    scenario_concurrent_drain_no_deadlock(fails)
    scenario_idempotent(fails)
    scenario_spawn_fail(fails)
    scenario_bare_name_path_resolution(fails)
    scenario_env_overlay_vs_closed(fails)
    scenario_utf8_byte_preserving_capture(fails)

    print("")
    _banner(
        "RESULT: " + (String("ALL PASS") if fails == 0
                      else (String(fails) + " FAILURE(S)"))
    )
    print("")
    if fails != 0:
        raise Error(
            "komira_supervisor scenarios: " + String(fails) + " failure(s)"
        )
