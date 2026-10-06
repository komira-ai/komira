# =============================================================================
# test_supervisor_scenarios.mojo — the komira_supervisor scenario suite.
# =============================================================================
#
# Spawn, capture, exit, kill and the exit monitor, plus two-pipe separation.
# Live on BOTH platforms: the exit-monitor test asserts the darwin EVFILT_PROC
# arm on macOS and the pidfd arm on Linux (see that test's header).
#
# One scenario per `test_` function, run by `TestSuite`, so a failure names the
# scenario that failed instead of a count of failures in one `main`:
#
#   test_capture_lines_and_exit_zero            full stdout captured, exit 0
#   test_large_output_drains_without_deadlock   >1 MB drained, no deadlock
#   test_sigterm_stops_a_long_running_child     dies on SIGTERM, shell_code 143
#   test_sigterm_ignoring_child_escalates_to_sigkill   SIGKILL, shell_code 137
#   test_no_zombie_after_reap                   second reap reports ECHILD
#   test_exit_monitor_sees_exit_as_a_kernel_event   EVFILT_PROC / pidfd POLLIN
#   test_stdout_and_stderr_are_separate_pipes   each drain sees its own stream
#   test_concurrent_drain_does_not_deadlock     >64 KB stderr + stdout marker
#   test_terminate_after_exit_is_idempotent     exit code cached
#   test_spawn_of_missing_path_fails_with_errno negative rc, no fd leak
#   test_bare_name_resolves_via_path            posix_spawnp PATH search
#   test_unresolvable_bare_name_still_fails     no silent resolution
#   test_process_environ_* / test_set_env_* / test_overlay_* / test_merge_*
#                                               closed env vs inherited overlay
#   test_*_preserves_utf8_* / test_chunked_capture_is_byte_exact
#                                               byte-preserving capture
#
# Drained continuously to avoid the pipe-buffer deadlock: we drain stdout AND
# stderr to EOF, THEN reap. With two pipes a child that writes a lot to ONE
# stream while the other stays small must still not deadlock — we drain both.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import TestSuite
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


def _spawned(pid: Int32) raises:
    """Refuse a failed spawn. Nothing was started, so there is nothing to
    reap or close."""
    if pid <= Int32(0):
        raise Error(String("spawn returned ") + String(pid))


# -----------------------------------------------------------------------------
# Child prints N lines then exits 0 -> capture all + exit code 0.
# -----------------------------------------------------------------------------
def test_capture_lines_and_exit_zero() raises:
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String("for i in 1 2 3 4 5; do echo line-$i; done; exit 0")
            )
        )
    )
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())  # drain (empty) stderr too
    var info = sup.wait_exit()
    sup.close()
    var ok_lines = True
    for i in range(1, 6):
        if String("line-") + String(i) not in out:
            ok_lines = False
    if not (ok_lines and info.exit_code == Int32(0)):
        raise Error(
            String("exit_code ") + String(info.exit_code) + " out=" + out
        )


# -----------------------------------------------------------------------------
# Child emits > one pipe buffer (~1MB) -> no deadlock, full capture.
# -----------------------------------------------------------------------------
def test_large_output_drains_without_deadlock() raises:
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String(
                    "i=0; while [ $i -lt 20000 ]; do "
                    + "echo"
                    + " AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-$i;"
                    + " i=$((i+1)); done; exit 0"
                )
            )
        )
    )
    var total = sup.drain_pipe_bytes(sup.stdout_fd())
    _ = sup.drain_pipe_bytes(sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()
    if not (total > 1_000_000 and info.exit_code == Int32(0)):
        raise Error(
            String("only ")
            + String(total)
            + " bytes, exit_code "
            + String(info.exit_code)
        )


# -----------------------------------------------------------------------------
# Long-running child -> SIGTERM -> exits; supervisor detects it.
# -----------------------------------------------------------------------------
def test_sigterm_stops_a_long_running_child() raises:
    var sup = Supervisor()
    _spawned(sup.spawn(ChildSpec.shell(String("sleep 30"))))
    var info = sup.terminate(2000)
    sup.close()
    # default SIGTERM disposition -> 128 + 15 = 143
    if info.shell_code != Int32(143):
        raise Error(
            String("shell_code ")
            + String(info.shell_code)
            + " signal "
            + String(info.signal)
        )


# -----------------------------------------------------------------------------
# Child traps/ignores SIGTERM -> escalate to SIGKILL -> dies.
# -----------------------------------------------------------------------------
def test_sigterm_ignoring_child_escalates_to_sigkill() raises:
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String("trap '' TERM; while true; do sleep 1; done")
            )
        )
    )
    # Let the shell install `trap '' TERM` before we signal — otherwise the
    # SIGTERM can race in before the trap is registered and kill the shell.
    sleep(0.15)
    var info = sup.terminate(800)  # 800ms grace, then SIGKILL
    sup.close()
    # SIGKILL -> 128 + 9 = 137
    if info.shell_code != Int32(137):
        raise Error(
            String("shell_code ")
            + String(info.shell_code)
            + " signal "
            + String(info.signal)
        )


# -----------------------------------------------------------------------------
# No zombies: after reap, a second reap reports ECHILD.
# -----------------------------------------------------------------------------
def test_no_zombie_after_reap() raises:
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("echo done; exit 7")))
    _spawned(pid)
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()  # this reaps exactly once
    # A direct second reap (bypassing the Supervisor's idempotency cache) must
    # NOT find a live/zombie child -> ECHILD -> proc_reap reports error.
    var r2 = proc_reap(pid, nohang=True)
    sup.close()
    if not (info.exit_code == Int32(7) and r2.error):
        raise Error(
            String("exit_code ")
            + String(info.exit_code)
            + " second-reap collected? "
            + String(r2.collected)
            + " error? "
            + String(r2.error)
        )


# -----------------------------------------------------------------------------
# Reactor-clean exit monitor: child exit is a kernel EVENT, no SIGCHLD
# handler. darwin: EVFILT_PROC / NOTE_EXIT (the production path registers
# this on the long-lived reactor kqueue via kevent_register_proc_exit; here
# we use the self-contained standalone wait to prove the kernel mechanism).
# Linux: pidfd_open + POLLIN (the production path registers the SAME pidfd
# on the reactor's epoll via exit_monitor.watch_process_exit; here we use
# the self-contained poll() for the same reason the darwin arm uses a fresh
# kqueue — to prove the KERNEL mechanism without standing up a reactor).
#
# Both arms ASSERT. A Linux arm that only printed SKIP would assert nothing on
# every Linux machine while the suite reported green. Each Linux leg goes RED
# when the C shim is broken:
#   leg 1  `komira_proc_pidfd_wait` stubbed to `return 1` (always ready)
#            -> "pidfd of a RUNNING child polled ready: 1". Leg 2 alone
#               would PASS under that stub.
#   leg 2  `komira_proc_pidfd_open` stubbed to `return -ENOSYS`
#            -> "pidfd_open(live) returned -38".
# -----------------------------------------------------------------------------
def _exit_monitor_darwin() raises:
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(String("sleep 0.3; echo from-child; exit 0"))
    )
    _spawned(pid)
    # Drain the pipes first (short child); then ask the kernel for the exit
    # event WITHOUT reaping — proving EVFILT_PROC sees the transition itself.
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var fired = proc_kqueue_exit_wait(pid, Int32(5000))
    # Now reap to clear the zombie (EVFILT_PROC notifies, does not reap).
    var info = sup.wait_exit()
    sup.close()
    if not (fired == Int32(1) and info.exit_code == Int32(0)):
        raise Error(
            String("fired ")
            + String(fired)
            + " exit_code "
            + String(info.exit_code)
        )


def _exit_monitor_linux() raises:
    # ---- LEG 1: a LIVE child's pidfd is NOT readable. --------------------
    # This leg is what makes the test discriminating. Leg 2 alone is
    # satisfied by a stub that returns 1 unconditionally — and this package's
    # own darwin/Linux stub pair in _proc_shim.c is exactly the shape that
    # produces such a stub by accident. `sleep 30` polled at timeout=0 is a
    # ~30s margin, not a race; the SIGTERM test spawns the same child.
    var live = Supervisor()
    var live_pid = live.spawn(ChildSpec.shell(String("sleep 30")))
    _spawned(live_pid)
    var live_fd = proc_pidfd_open(live_pid)
    if live_fd < Int32(0):
        _ = live.terminate(2000)
        live.close()
        raise Error(
            String("pidfd_open(live) returned ")
            + String(live_fd)
            + " (negative is -errno; kernel >= 5.3 required)"
        )
    var live_ready = proc_pidfd_wait(live_fd, Int32(0))
    proc_close(live_fd)
    _ = live.terminate(2000)
    live.close()
    if live_ready != Int32(0):
        raise Error(
            String("pidfd of a RUNNING child polled ready: ")
            + String(live_ready)
            + " (expected 0 = timeout; 1 means the fd does not track the"
            + " process, -2 means the Linux arm was compiled out)"
        )

    # ---- LEG 2: the pidfd becomes readable on the exit TRANSITION. -------
    # Opened while the child is still alive (it sleeps 0.3s), so POLLIN here
    # is the kernel posting the transition, not a property of a pid that was
    # already dead when we asked.
    var sup = Supervisor()
    var pid = sup.spawn(
        ChildSpec.shell(String("sleep 0.3; echo from-child; exit 0"))
    )
    _spawned(pid)
    var pidfd = proc_pidfd_open(pid)
    if pidfd < Int32(0):
        _ = sup.wait_exit()
        sup.close()
        raise Error(String("pidfd_open returned ") + String(pidfd))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var fired = proc_pidfd_wait(pidfd, Int32(5000))
    proc_close(pidfd)
    # Now reap to clear the zombie (POLLIN notifies, it does not reap).
    var info = sup.wait_exit()
    sup.close()
    if not (fired == Int32(1) and info.exit_code == Int32(0)):
        raise Error(
            String("fired ")
            + String(fired)
            + " exit_code "
            + String(info.exit_code)
        )


def test_exit_monitor_sees_exit_as_a_kernel_event() raises:
    comptime if CompilationTarget.is_macos():
        _exit_monitor_darwin()
    else:
        _exit_monitor_linux()


# -----------------------------------------------------------------------------
# TWO-PIPE SEPARATION. The child writes DISTINCT text to stdout and stderr; the
# stdout drain must see ONLY the stdout text and the stderr drain ONLY the
# stderr text. This is load-bearing: a caller may stream stdout but only
# tail-capture stderr for forensics.
# -----------------------------------------------------------------------------
def test_stdout_and_stderr_are_separate_pipes() raises:
    var sup = Supervisor()
    # echo to stdout; echo ... >&2 to stderr. Interleave to prove they don't mix.
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String(
                    "echo OUT-ALPHA; echo ERR-BETA >&2; "
                    + "echo OUT-GAMMA; echo ERR-DELTA >&2; exit 0"
                )
            )
        )
    )
    var out = sup.drain_pipe(sup.stdout_fd())
    var err = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()

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
    if not (out_ok and err_ok and info.exit_code == Int32(0)):
        raise Error(
            String("out_ok ")
            + String(out_ok)
            + " err_ok "
            + String(err_ok)
            + " stdout=["
            + out
            + "] stderr=["
            + err
            + "]"
        )


# -----------------------------------------------------------------------------
# CONCURRENT-DRAIN NO-DEADLOCK — the two-pipe drain deadlock.
#
# The child floods STDERR with >64KB (256KB here) and writes its terminal
# marker line to STDOUT *last*. A sequential drain — `drain_pipe(stdout)`
# fully, then `drain_pipe(stderr)` — deadlocks: the stdout marker only
# arrives on child EXIT, so the stdout drain blocks until the child exits,
# but the child is itself blocked on write(2) to the FULL (>64KB) stderr
# pipe buffer that nobody is draining. The child never exits, the stdout
# drain never returns, and the test times out.
#
# The concurrent `drain_both(stdout_fd, stderr_fd)` interleaves both fds
# non-blocking so neither buffer can fill while the other is read; the
# child completes, both streams are captured in full, and the child exits 0.
# -----------------------------------------------------------------------------
def test_concurrent_drain_does_not_deadlock() raises:
    var sup = Supervisor()
    # Child: write ~256KB to STDERR (well past the ~64KB pipe buffer), THEN a
    # single terminal marker line to STDOUT as its LAST write, then exit 0.
    # `yes | head -c` emits deterministic bytes fast; redirect to fd 2 (stderr).
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String(
                    "yes ERRLINE | head -c 262144 1>&2; "
                    + "echo DONE_MARKER=deadbeef; "
                    + "exit 0"
                )
            )
        )
    )
    # Under test: drain BOTH pipes concurrently. Two sequential drain_pipe()
    # calls would HANG here.
    var streams = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    var out = streams[0]
    var err = streams[1]
    var info = sup.wait_exit()
    sup.close()

    var out_ok = String("DONE_MARKER=deadbeef") in out
    # stderr must be captured IN FULL (not silently dropped): 262144 bytes of
    # "ERRLINE\n" -> err.byte_length() should be ~262144 (head -c exact cut).
    var err_len = err.byte_length()
    var err_ok = err_len >= 262000 and (String("ERRLINE") in err)
    if not (out_ok and err_ok and info.exit_code == Int32(0)):
        raise Error(
            String("out_ok ")
            + String(out_ok)
            + " err_ok "
            + String(err_ok)
            + " err_len "
            + String(err_len)
            + " exit_code "
            + String(info.exit_code)
        )


# -----------------------------------------------------------------------------
# Idempotency edges: terminate after exit, and terminate twice.
# -----------------------------------------------------------------------------
def test_terminate_after_exit_is_idempotent() raises:
    var sup = Supervisor()
    _spawned(sup.spawn(ChildSpec.shell(String("exit 3"))))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info1 = sup.wait_exit()
    # The child already exited; terminate must be a no-op returning the cache.
    var info2 = sup.terminate(1000)
    var info3 = sup.terminate(1000)  # second terminate also a no-op
    sup.close()
    if not (
        info1.exit_code == Int32(3)
        and info2.exit_code == Int32(3)
        and info3.exit_code == Int32(3)
    ):
        raise Error(
            String("e1 ")
            + String(info1.exit_code)
            + " e2 "
            + String(info2.exit_code)
            + " e3 "
            + String(info3.exit_code)
        )


# -----------------------------------------------------------------------------
# Spawn failure: non-existent binary -> spawn returns a negative errno, no
# pipe fds leaked (the C shim cleans up before returning).
# -----------------------------------------------------------------------------
def test_spawn_of_missing_path_fails_with_errno() raises:
    var sup = Supervisor()
    var spec = ChildSpec(String("/nonexistent/komira/binary/zzz"))
    var rc = sup.spawn(spec)
    if rc >= Int32(0):
        sup.close()
        raise Error(String("spawn unexpectedly succeeded rc ") + String(rc))


# -----------------------------------------------------------------------------
# BARE-NAME PATH RESOLUTION — posix_spawnp, not posix_spawn.
#
# The non-`p` `posix_spawn` does NOT PATH-search, so every caller that passes a
# BARE executable name gets ENOENT even when the binary is installed and on
# PATH (for example a daemon runner whose default binary is a bare name, or a
# build driver spawning `crane`).
#
# With `posix_spawn`, `ChildSpec(String("sh"))` returns a NEGATIVE rc
# (-ENOENT == -2) from `spawn`. With `posix_spawnp` the bare name resolves
# against the inherited PATH exactly as execvp(3) does, the child runs, and
# stdout carries its marker.
#
# The second test is the guard against over-correcting: a bare name that is
# NOT on PATH must STILL fail loud (negative rc), never silently resolve to
# something else. A spawn that cannot find its binary must never look like a
# pass.
# -----------------------------------------------------------------------------
def test_bare_name_resolves_via_path() raises:
    var sup = Supervisor()
    var spec = ChildSpec(String("sh"))
    spec.with_arg(String("-c"))
    spec.with_arg(String("echo path-resolved-ok"))
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        raise Error(
            String("bare-name spawn of 'sh' returned ")
            + String(pid)
            + " — posix_spawn (non-p) does not PATH-search; the shim must use"
            + " posix_spawnp"
        )
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()
    if not (String("path-resolved-ok") in out and info.exit_code == Int32(0)):
        raise Error(
            String("exit_code ") + String(info.exit_code) + " out=" + out
        )


def test_unresolvable_bare_name_still_fails() raises:
    var sup = Supervisor()
    var missing = ChildSpec(String("komira-no-such-tool-zzz-9d3f"))
    var rc = sup.spawn(missing)
    if rc >= Int32(0):
        sup.close()
        raise Error(
            String("unresolvable bare name spawned anyway, rc ")
            + String(rc)
            + " — a missing binary must never look like a pass"
        )


# -----------------------------------------------------------------------------
# ⛔ THE ENVIRONMENT IS ALL-OR-NOTHING, SO ONE AUTHORED VARIABLE CAN BE A
# KILL SWITCH. Covers `set_env_over_inherited` (`merge_env_overlay` +
# `process_environ`).
#
# `posix_spawn` has exactly two env arms — inherit `environ`, or REPLACE it —
# and `ChildSpec.set_env` takes the second. A caller that authors ONE variable
# (say `AWS_REGION`) through `set_env` therefore runs its child with EXACTLY
# ONE variable, which strips `LD_LIBRARY_PATH` (the child dies with `error while
# loading shared libraries`, exit 127) and `$HOME` + `AWS_PROFILE` (every arm of
# the AWS credential chain declines).
#
# ⚠ THE OVERLAY TESTS BELOW ARE ONE CLAIM EACH, and
# `test_overlay_authored_value_wins_exactly_once` is the one a naive "just
# append the authored entries" fix fails: glibc's `getenv` returns the FIRST
# match in `envp`, so an appended override does not override. The merge
# REPLACES IN PLACE.
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


def _set_ambient_markers():
    _setenv(String("MARKER_AMBIENT"), String("ambient-ok"))
    _setenv(String("MARKER_CLASH"), String("from-ambient"))


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


def _overlay_child_output() raises -> String:
    var overlay = ChildSpec.shell(_ECHO_MARKERS)
    overlay.set_env_over_inherited(
        _slist2(
            String("MARKER_AUTHORED=authored-ok"),
            String("MARKER_CLASH=from-authored"),
        )
    )
    return _run_capturing(overlay^)


def test_process_environ_reads_the_live_environ() raises:
    _set_ambient_markers()
    var ambient = process_environ()
    if _count_entries_named(ambient, String("MARKER_AMBIENT")) != 1:
        raise Error(
            String("process_environ returned ")
            + String(len(ambient))
            + " entries and none of them was the one just set"
        )


def test_set_env_replaces_the_environment() raises:
    """THE CLOSED ARM — the child sees only what was authored."""
    _set_ambient_markers()
    var closed = ChildSpec.shell(_ECHO_MARKERS)
    closed.set_env(_slist(String("MARKER_AUTHORED=authored-ok")))
    var out = _run_capturing(closed^)
    if not (
        String("A=[]") in out
        and String("C=[]") in out
        and String("AUTH=[authored-ok]") in out
    ):
        raise Error(String("set_env is no longer all-or-nothing; out=") + out)


def test_overlay_child_inherits_and_receives_the_authored_value() raises:
    _set_ambient_markers()
    var out = _overlay_child_output()
    if not (
        String("A=[ambient-ok]") in out
        and String("AUTH=[authored-ok]") in out
    ):
        raise Error(String("overlay lost one half; out=") + out)


def test_overlay_authored_value_wins_exactly_once() raises:
    """★ Replaced IN PLACE: one entry, the authored value."""
    _set_ambient_markers()
    var out = _overlay_child_output()
    var merged = merge_env_overlay(
        process_environ(), _slist(String("MARKER_CLASH=from-authored"))
    )
    var dupes = _count_entries_named(merged, String("MARKER_CLASH"))
    if not (String("C=[from-authored]") in out and dupes == 1):
        raise Error(
            String("the authored value did not win by name (entries named")
            + " MARKER_CLASH: "
            + String(dupes)
            + ") out="
            + out
        )


def test_merge_env_overlay_replaces_in_place_and_appends() raises:
    """A clashing name is replaced where it stands, a new name is appended,
    and the order is preserved."""
    var base = _slist2(String("A=1"), String("B=2"))
    var m = merge_env_overlay(base^, _slist2(String("B=9"), String("C=3")))
    if not (
        len(m) == 3
        and m[0] == String("A=1")
        and m[1] == String("B=9")
        and m[2] == String("C=3")
    ):
        raise Error(
            String("merge_env_overlay ordering/replacement wrong, len=")
            + String(len(m))
        )


# -----------------------------------------------------------------------------
# BYTE-PRESERVING CAPTURE — the `chr(Int(byte))` mojibake regression.
#
# A byte->String seam written as `out += chr(Int(buf[i]))` reads each raw byte
# as a UNICODE CODEPOINT and re-encodes it, so every multi-byte character comes
# out as three mojibake characters and the stream gets LONGER:
#
#     wrote  4d e2 80 94 45 e2 80 a6 4e         "M—E…N"       9 bytes
#     read   4d c3 a2 c2 80 c2 94 45 c3 a2 …    "MâE⦔   15 bytes
#
# With such a seam each test below fails, byte-level:
#
#   drain_pipe          15 bytes: 4d c3 a2 c2 80 c2 94 45 c3 a2 c2 80 c2 a6 4e
#   drain_both          the same 15 bytes, on stdout AND on stderr
#   chunked capture     200000 written  ->  300000 read, 33334 mojibake pairs
#   process_environ     the parent set 9 bytes; the read-back is those 15
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


def test_drain_pipe_preserves_utf8_bytes() raises:
    """The blocking drain-to-EOF path."""
    var want = _utf8_marker_bytes()
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String("printf '") + _UTF8_MARKER_OCTAL + String("'")
            )
        )
    )
    var out = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _ = sup.wait_exit()
    sup.close()
    if not (_bytes_are(out, want) and _mojibake_pairs(out) == 0):
        raise Error(
            String("drain_pipe mangled the stream — got ")
            + String(out.byte_length())
            + " bytes: "
            + _hex_of(out)
            + "( mojibake c3a2 pairs: "
            + String(_mojibake_pairs(out))
            + ")"
        )


def test_drain_both_preserves_utf8_bytes_on_both_streams() raises:
    """The incremental non-blocking path, asserted on BOTH streams (stderr is
    the one an operator reads on a failure, and it goes through the same
    seam)."""
    var want = _utf8_marker_bytes()
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String("printf '") + _UTF8_MARKER_OCTAL + String("'; printf '")
                + _UTF8_MARKER_OCTAL + String("' 1>&2")
            )
        )
    )
    var streams = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    var out = streams[0]
    var err = streams[1]
    _ = sup.wait_exit()
    sup.close()
    if not (_bytes_are(out, want) and _bytes_are(err, want)):
        raise Error(
            String("drain_both mangled a stream — stdout ")
            + String(out.byte_length())
            + " bytes: "
            + _hex_of(out)
            + "/ stderr "
            + String(err.byte_length())
            + " bytes: "
            + _hex_of(err)
        )


def test_chunked_capture_is_byte_exact() raises:
    """CHUNK-BOUNDARY STRESS. 200000 bytes >> the 65536-byte read chunk, so
    multi-byte characters WILL be split across reads. Nothing on the path
    decodes, so the fragments must rejoin exactly: the assertion is the exact
    byte COUNT (a transcode inflates it) plus zero mojibake pairs anywhere in
    200KB."""
    var sup = Supervisor()
    _spawned(
        sup.spawn(
            ChildSpec.shell(
                String(
                    "X=$(printf 'A\\342\\200\\224B'); yes \"$X\" | head -c 200000"
                )
            )
        )
    )
    var streams = sup.drain_both(sup.stdout_fd(), sup.stderr_fd())
    var big = streams[0]
    _ = sup.wait_exit()
    sup.close()
    var big_len = big.byte_length()
    var big_bake = _mojibake_pairs(big)
    if not (big_len == 200000 and big_bake == 0):
        raise Error(
            String("chunked capture is not byte-exact — got ")
            + String(big_len)
            + " bytes (want 200000), mojibake c3a2 pairs: "
            + String(big_bake)
        )


def test_process_environ_preserves_utf8_value() raises:
    """The SAME class on the env path, asserted WITHOUT a child so the drain
    cannot mask or cause it. These entries become the child's real environment
    via set_env_over_inherited."""
    var want = _utf8_marker_bytes()
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
    if not (found and _bytes_are(got_value, want)):
        raise Error(
            String("process_environ transcoded an environment VALUE — found ")
            + String(found)
            + " value "
            + String(got_value.byte_length())
            + " bytes: "
            + _hex_of(got_value)
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
