# =============================================================================
# farm_capability_probe.mojo -- what a test action can do where `buck2 test`
# runs it (a farm worker when a farm is configured, otherwise the client).
# =============================================================================
#
# A standalone `mojo_test` (komira_test_minio/BUCK), not a welded test: it
# starts processes, opens sockets and reaches for the network, which no
# library gate may do. Each capability an end-to-end test of a real server
# needs is tried for real and printed as ONE machine-greppable line:
#
#   FARM-CAPABILITY <name> key=value ...
#
# REQUIRED (the test fails, naming the capability, when one is missing):
#   child_reap      spawn a long-lived child, stop it with SIGTERM, reap it,
#                   and find no child left to reap (komira_supervisor).
#   loopback        bind 127.0.0.1:0, connect to it, accept, and move one byte
#                   across (komira_async's socket setup and try_io calls).
#   pdeathsig       /usr/bin/setpriv --pdeathsig KILL: the child dies when its
#                   parent is SIGKILLed; and, as the control, the same child
#                   without setpriv SURVIVES its parent (else the check could
#                   not tell the two apart).
#   disk_1gib       write 1 GiB under TEST_TMPDIR, read its size back, delete it.
#
# REPORTED (printed, never a failure):
#   tmpdir_outside_checkout
#                   whether a directory from TEST_TMPDIR up to / holds `.git`
#                   or `.buckconfig`. The install-path test needs its scratch
#                   outside any checkout (kci_validate's `scratch_refusal`), so
#                   THAT test must refuse to run when this says no; here it is
#                   reported only, because gate_runner.sh makes TEST_TMPDIR
#                   under the action's working directory, which for an action
#                   run on the client (no farm configured) is inside the
#                   checkout; a required check would then be red for that
#                   reason, not for a missing capability.
#   uid             the current uid, the non-root /etc/passwd entry tried, and
#                   whether `setpriv --reuid/--regid --clear-groups` reaches it
#                   (a database server refuses to run as root) and whether that
#                   uid can create a file in TEST_TMPDIR. `rc` is the exit code
#                   of the shell setpriv runs, not of setpriv; the uid the shell
#                   reads back is the proof of the drop.
#   egress          a TCP connect to conda.modular.com:443 (`nc -w 3`, exec'd
#                   by the shell so the 8 s deadline's SIGTERM/SIGKILL reaches
#                   nc itself, name lookup included).
#
# The runner keeps a passing test's output to itself (gate_runner.sh prints
# the log only on failure); the lines are read from a failing run.
# No FFI is declared here: processes are komira_supervisor's, sockets
# komira_async's, the environment komira_libc's.
# =============================================================================

from std.os import remove
from std.os.path import exists, getsize, realpath
from std.time import perf_counter_ns, sleep

from komira_async.reactor.socket_io import (
    try_io_accept,
    try_io_connect,
    try_io_read,
    try_io_write,
)
from komira_async.reactor.socket_setup import (
    bind_inet,
    close_fd,
    get_so_error,
    getsockname_port,
    inet_loopback_be,
    listen_socket,
    sockaddr_in_bytes,
    socket_tcp_nonblocking,
)
from komira_libc.posix import _read_env
from komira_supervisor import ChildSpec, DetachedChild, SIGKILL, Supervisor

comptime _SETPRIV = "/usr/bin/setpriv"
comptime _EGRESS_HOST = "conda.modular.com"
comptime _EGRESS_PORT = 443
comptime _SIGTERM_NUMBER = 15
comptime _GIB = 1 << 30
comptime _MIB = 1 << 20


def _yn(b: Bool) -> String:
    return String("yes") if b else String("no")


struct Probe(Movable):
    """Collects the required capabilities that are missing."""

    var failures: List[String]

    def __init__(out self):
        self.failures = List[String]()

    def require(mut self, ok: Bool, capability: String, why: String):
        if ok:
            return
        print("REQUIRED CAPABILITY MISSING:", capability, "--", why)
        self.failures.append(capability + String(": ") + why)


struct ShellResult(Movable):
    """`rc` is the exit code, 128+N for a signal, -1 when the shell did not
    start; `timed_out` when it was stopped at the deadline."""

    var rc: Int
    var timed_out: Bool
    var out: String
    var err: String

    def __init__(out self, rc: Int, timed_out: Bool, var out: String, var err: String):
        self.rc = rc
        self.timed_out = timed_out
        self.out = out^
        self.err = err^


def _run(spec: ChildSpec, timeout_ms: Int) -> ShellResult:
    """Run `spec`, stopped (SIGTERM, then SIGKILL, to its pid only) at
    `timeout_ms`. For commands with small output: the pipes are drained
    after the exit, so the spawned pid must be the one holding them (a shell
    `exec`s its last command)."""
    var sup = Supervisor()
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        return ShellResult(-1, False, String(""), String("spawn failed: ") + String(pid))
    var waited = 0
    var timed_out = False
    while True:
        var r = sup.try_wait()
        if r.collected or r.error:
            break
        if waited >= timeout_ms:
            _ = sup.terminate(500)
            timed_out = True
            break
        sleep(0.02)
        waited += 20
    var out = sup.drain_pipe(sup.stdout_fd())
    var err = sup.drain_pipe(sup.stderr_fd())
    var info = sup.wait_exit()
    sup.close()
    return ShellResult(Int(info.shell_code), timed_out, out^, err^)


def _fields(line: String) -> List[String]:
    """The whitespace-separated fields of `line`."""
    var out = List[String]()
    var cur = String("")
    for b in line.as_bytes():
        if b == UInt8(32) or b == UInt8(9) or b == UInt8(10) or b == UInt8(13):
            if cur.byte_length() > 0:
                out.append(cur)
                cur = String("")
        else:
            cur += chr(Int(b))
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


def _read_file(path: String) -> String:
    """The file's text, or "" when it cannot be read."""
    var s = String("")
    try:
        with open(path, "r") as f:
            s = f.read()
    except:
        pass
    return s^


def _first_line(s: String) -> String:
    var i = s.find("\n")
    if i < 0:
        return s.copy()
    return String(s[byte=0:i])


# -----------------------------------------------------------------------------
# 1. child_reap
# -----------------------------------------------------------------------------
def probe_child_reap(mut p: Probe):
    var sup = Supervisor()
    var spec = ChildSpec(String("sleep"))
    spec.with_arg(String("30"))
    var pid = sup.spawn(spec)
    if pid <= Int32(0):
        print("FARM-CAPABILITY child_reap spawn=no errno=" + String(-Int(pid)))
        p.require(False, "child_reap", "spawning `sleep 30` failed")
        return
    sleep(0.3)
    var early = sup.try_wait()
    var alive = not early.collected and not early.error
    var info = sup.terminate(2000)
    # Reaped exactly once: a second reap of the pid finds no child (ECHILD).
    var again = DetachedChild(pid).poll_exit()
    sup.close()
    print(
        "FARM-CAPABILITY child_reap spawn=yes alive_after_300ms=" + _yn(alive)
        + " exit_signal=" + String(info.signal)
        + " no_zombie=" + _yn(again.error)
    )
    p.require(alive, "child_reap", "the child was gone 300 ms after spawn")
    p.require(
        Int(info.signal) == _SIGTERM_NUMBER,
        "child_reap",
        "expected the child to die of signal " + String(_SIGTERM_NUMBER)
        + ", reaped " + String(info.signal) + " (exit code " + String(info.exit_code) + ")",
    )
    p.require(again.error, "child_reap", "a second reap still found the child")


# -----------------------------------------------------------------------------
# 2. loopback
# -----------------------------------------------------------------------------
def probe_loopback(mut p: Probe):
    var lfd = Int32(-1)
    var cfd = Int32(-1)
    var afd = Int32(-1)
    var port = 0
    var accepted = False
    var moved = False
    var why = String("")
    try:
        lfd = socket_tcp_nonblocking()
        bind_inet(lfd, inet_loopback_be(), UInt16(0))
        listen_socket(lfd, Int32(4))
        port = Int(getsockname_port(lfd))
        cfd = socket_tcp_nonblocking()
        var sa = sockaddr_in_bytes(inet_loopback_be(), UInt16(port))
        var addr = List[UInt8]()
        for i in range(16):
            addr.append(sa[i])
        var c = try_io_connect(cfd, Span(addr))
        if c.is_error():
            why = String("connect errno ") + String(c.value())
        else:
            for _ in range(250):
                var a = try_io_accept(lfd)
                if a.is_ready():
                    afd = Int32(Int(a.value()))
                    accepted = True
                    break
                if a.is_error():
                    why = String("accept errno ") + String(a.value())
                    break
                sleep(0.02)
            if accepted:
                if get_so_error(cfd) != Int32(0):
                    why = String("connect completed with an error")
                else:
                    var msg = List[UInt8]()
                    msg.append(UInt8(0x2A))
                    var w = try_io_write(cfd, Span(msg))
                    var buf = List[UInt8]()
                    buf.append(UInt8(0))
                    for _ in range(250):
                        var r = try_io_read(afd, Span(buf))
                        if r.is_ready() and r.value() == Int64(1):
                            moved = buf[0] == UInt8(0x2A)
                            break
                        if r.is_error() or (r.is_ready() and r.value() == Int64(0)):
                            break
                        sleep(0.02)
                    if not moved:
                        why = String("the byte written (write ready=") + _yn(w.is_ready()) + String(") never arrived")
            elif why.byte_length() == 0:
                why = String("no connection to accept within 5 s")
    except e:
        why = String(e)
    close_fd(afd)
    close_fd(cfd)
    close_fd(lfd)
    print(
        "FARM-CAPABILITY loopback bind=" + _yn(port > 0) + " accept=" + _yn(accepted)
        + " byte_round_trip=" + _yn(moved)
    )
    p.require(port > 0 and accepted and moved, "loopback", why)


# -----------------------------------------------------------------------------
# 3. pdeathsig
# -----------------------------------------------------------------------------
def _proc_state(pid: Int) -> String:
    """The state letter of /proc/<pid>/stat ("R", "S", "Z", ...); "" when
    the process is gone."""
    var s = _read_file(String("/proc/") + String(pid) + String("/stat"))
    var i = s.rfind(")")
    if i < 0 or i + 3 > s.byte_length():
        return String("")
    return String(s[byte = i + 2 : i + 3])


def _is_dead(pid: Int) -> Bool:
    var st = _proc_state(pid)
    return st.byte_length() == 0 or st == String("Z")


struct OrphanOutcome(Movable):
    var started: Bool
    var died_with_parent: Bool
    var note: String

    def __init__(out self, started: Bool, died_with_parent: Bool, var note: String):
        self.started = started
        self.died_with_parent = died_with_parent
        self.note = note^


def _orphan(prefix: String) -> OrphanOutcome:
    """A shell P starts `<prefix> sleep 30` in the background and prints its
    pid C; once C runs `sleep`, P is SIGKILLed and reaped. Did C die too?"""
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(prefix + String("sleep 30 & echo $!; wait")))
    if pid <= Int32(0):
        return OrphanOutcome(False, False, String("spawn failed"))
    _ = sup.set_nonblocking(sup.stdout_fd())
    var text = String("")
    for _ in range(250):
        var chunk = sup.read_available(sup.stdout_fd())
        text += chunk.text
        if text.find("\n") >= 0 or chunk.eof or chunk.error:
            break
        sleep(0.02)
    var child = 0
    try:
        child = Int(atol(_first_line(text)))
    except:
        pass
    if child <= 0:
        _ = sup.terminate(500)
        sup.close()
        return OrphanOutcome(False, False, String("no child pid printed: '") + text + String("'"))
    # C has run setpriv's prctl once it is `sleep` (setpriv execs it after).
    var running = False
    for _ in range(250):
        if _read_file(String("/proc/") + String(child) + String("/comm")).startswith("sleep"):
            running = True
            break
        sleep(0.02)
    _ = sup.signal(SIGKILL)
    _ = sup.wait_exit()
    sup.close()
    var dead = False
    for _ in range(100):
        if _is_dead(child):
            dead = True
            break
        sleep(0.03)
    if not dead:
        # The control's orphan: stop it ourselves.
        _ = DetachedChild(Int32(child)).kill()
        for _ in range(100):
            if _is_dead(child):
                break
            sleep(0.03)
    var note = String("")
    if not running:
        note = String("the child never ran sleep")
    return OrphanOutcome(running, dead, note^)


def probe_pdeathsig(mut p: Probe):
    var have = exists(_SETPRIV)
    if not have:
        print("FARM-CAPABILITY pdeathsig setpriv=absent")
        p.require(False, "pdeathsig", String(_SETPRIV) + " does not exist")
        return
    var with_sig = _orphan(String(_SETPRIV) + String(" --pdeathsig KILL -- "))
    var control = _orphan(String(""))
    print(
        "FARM-CAPABILITY pdeathsig setpriv=present child_died_with_parent=" + _yn(with_sig.died_with_parent)
        + " control_orphan_survived=" + _yn(control.started and not control.died_with_parent)
    )
    p.require(with_sig.started, "pdeathsig", "with setpriv: " + with_sig.note)
    p.require(with_sig.died_with_parent, "pdeathsig", "the setpriv child outlived its SIGKILLed parent")
    p.require(control.started, "pdeathsig", "control: " + control.note)
    p.require(
        not control.died_with_parent,
        "pdeathsig",
        "the control child (no setpriv) died with its parent too, so this check cannot tell",
    )


# -----------------------------------------------------------------------------
# 4. uid (reported)
# -----------------------------------------------------------------------------
def probe_uid(tmp: String):
    var uid = -1
    for line in _read_file(String("/proc/self/status")).split("\n"):
        var f = _fields(String(line))
        if len(f) >= 2 and f[0] == String("Uid:"):
            try:
                uid = Int(atol(f[1]))
            except:
                pass
    # The target: `nobody` when /etc/passwd has it, else its first non-root entry.
    var name = String("")
    var tuid = -1
    var tgid = -1
    for line in _read_file(String("/etc/passwd")).split("\n"):
        var parts = String(line).split(":")
        if len(parts) < 4:
            continue
        try:
            var u = Int(atol(parts[2]))
            var g = Int(atol(parts[3]))
            if u == 0:
                continue
            if String(parts[0]) == String("nobody") or tuid < 0:
                name = String(parts[0])
                tuid = u
                tgid = g
                if name == String("nobody"):
                    break
        except:
            pass
    if tuid < 0:
        print("FARM-CAPABILITY uid current=" + String(uid) + " target=none uid_drop=no tmpdir_writable_after_drop=no")
        return
    var script = String(
        "while read k v r; do [ \"$k\" = Uid: ] && echo \"$v\"; done < /proc/self/status;"
        " if (: > \"$1/uid_probe\") 2>/dev/null; then echo writable; fi"
    )
    # TEST_TMPDIR reaches the inner shell as "$1", an argv entry of its own.
    var spec = ChildSpec(String(_SETPRIV))
    spec.with_arg(String("--reuid=") + String(tuid))
    spec.with_arg(String("--regid=") + String(tgid))
    spec.with_arg(String("--clear-groups"))
    spec.with_arg(String("--"))
    spec.with_arg(String("/bin/sh"))
    spec.with_arg(String("-c"))
    spec.with_arg(script)
    spec.with_arg(String("sh"))
    spec.with_arg(tmp)
    var r = _run(spec, 5000)
    # The uid the shell reads back is the proof; `rc` is the inner shell's.
    var dropped = _first_line(r.out) == String(tuid)
    var writable = r.out.find("writable") >= 0
    var probe_file = tmp + String("/uid_probe")
    if exists(probe_file):
        try:
            remove(probe_file)
        except:
            pass
    if r.err.byte_length() > 0:
        print("uid drop stderr:", _first_line(r.err))
    print(
        "FARM-CAPABILITY uid current=" + String(uid) + " target=" + name + ":" + String(tuid)
        + " uid_drop=" + _yn(dropped) + " rc=" + String(r.rc)
        + " tmpdir_writable_after_drop=" + _yn(writable)
    )


# -----------------------------------------------------------------------------
# 5. disk_1gib
# -----------------------------------------------------------------------------
def _free_mib(tmp: String) -> Int:
    """Available MiB on TEST_TMPDIR's filesystem (busybox `df -Pk`), -1 when unknown."""
    var spec = ChildSpec(String("df"))
    spec.with_arg(String("-Pk"))
    spec.with_arg(tmp)
    var r = _run(spec, 5000)
    if r.rc != 0:
        return -1
    var lines = r.out.split("\n")
    var i = len(lines) - 1
    while i > 0 and String(lines[i]).byte_length() == 0:
        i -= 1
    var f = _fields(String(lines[i]))
    if len(f) < 4:
        return -1
    try:
        return Int(atol(f[3])) // 1024
    except:
        return -1


def probe_disk(mut p: Probe, tmp: String):
    var free_before = _free_mib(tmp)
    var path = tmp + String("/farm_probe_1gib.bin")
    var chunk = List[UInt8](length=_MIB, fill=UInt8(0xA5))
    var written = False
    var size = -1
    var why = String("")
    var t0 = perf_counter_ns()
    try:
        with open(path, "w") as f:
            for _ in range(_GIB // _MIB):
                f.write_bytes(Span(chunk))
        written = True
        size = Int(getsize(path))
    except e:
        why = String(e)
    var ms = Int((perf_counter_ns() - t0) // 1_000_000)
    var free_full = _free_mib(tmp)
    var deleted = False
    try:
        if exists(path):
            remove(path)
        deleted = not exists(path)
    except e:
        why = String("delete: ") + String(e)
    print(
        "FARM-CAPABILITY disk_1gib free_mib_before=" + String(free_before)
        + " free_mib_with_file=" + String(free_full)
        + " written=" + _yn(written and size == _GIB) + " write_ms=" + String(ms)
        + " deleted=" + _yn(deleted)
    )
    if written and size != _GIB:
        why = String("size read back ") + String(size)
    p.require(written and size == _GIB and deleted, "disk_1gib", why)


# -----------------------------------------------------------------------------
# 6. egress (reported)
# -----------------------------------------------------------------------------
def probe_egress():
    # `exec`: the shell becomes nc, so the deadline's signals reach nc (and
    # the pipes it holds close) even while it is still resolving the name.
    var r = _run(
        ChildSpec.shell(
            String("exec nc -w 3 ") + String(_EGRESS_HOST) + String(" ") + String(_EGRESS_PORT)
            + String(" </dev/null")
        ),
        8000,
    )
    var verdict = String("no")
    if r.rc == 0:
        verdict = String("yes")
    elif r.rc == 127:
        verdict = String("unknown_no_nc")
    print(
        "FARM-CAPABILITY egress host=" + String(_EGRESS_HOST) + ":" + String(_EGRESS_PORT)
        + " tcp_connect=" + verdict + " rc=" + String(r.rc) + " timed_out=" + _yn(r.timed_out)
    )


# -----------------------------------------------------------------------------
# 7. tmpdir_outside_checkout
# -----------------------------------------------------------------------------
def probe_tmpdir(tmp: String):
    var d: String
    try:
        d = realpath(tmp)
    except e:
        print("FARM-CAPABILITY tmpdir_outside_checkout=unknown realpath_error=yes")
        return
    var real = d.copy()
    var found = String("")
    var levels = 0
    while True:
        var base = String("") if d == String("/") else d.copy()
        if exists(base + String("/.git")):
            found = base + String("/.git")
            break
        if exists(base + String("/.buckconfig")):
            found = base + String("/.buckconfig")
            break
        if d == String("/"):
            break
        var i = d.rfind("/")
        d = String("/") if i <= 0 else String(d[byte=0:i])
        levels += 1
    print("TEST_TMPDIR real path:", real)
    print(
        "FARM-CAPABILITY tmpdir_outside_checkout=" + _yn(found.byte_length() == 0)
        + " levels_walked=" + String(levels)
    )
    if found.byte_length() > 0:
        print("checkout marker found:", found)


def main() raises:
    var tmp = _read_env("TEST_TMPDIR")
    if tmp.byte_length() == 0:
        raise Error("farm_capability_probe: TEST_TMPDIR is unset; run it with `buck2 test`")
    var p = Probe()
    probe_child_reap(p)
    probe_loopback(p)
    probe_pdeathsig(p)
    probe_uid(tmp)
    probe_disk(p, tmp)
    probe_egress()
    probe_tmpdir(tmp)
    if len(p.failures) > 0:
        var msg = String("")
        for ref f in p.failures:
            msg += String("\n  ") + f
        print("FARM-CAPABILITY verdict=FAIL")
        raise Error(String("farm_capability_probe: required capabilities missing:") + msg)
    print("FARM-CAPABILITY verdict=PASS")
