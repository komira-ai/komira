"""The komira/python runtime in an engine process the test starts and ends: no runtime
process outlives the engine's, a zygote that someone else in the engine's process reaped,
the engine's signal handling, and a fork of the engine's process.

    test_udf_engine_child.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.

Each case starts this file again as the engine (`--child <scenario>`), with the test's
interpreter, `sys.path` and temporary directory, in a process group of its own. The engine
reports to the test as JSON lines on a pipe and waits on a second pipe for the test's
`go`; the test watches the processes it did not start (the zygote, the workers) through
exit watches it opens while they are known to be running (`udf_host.ExitWatch`: a pidfd on
Linux, a kqueue on macOS). Nothing here measures time.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time

import pyarrow as pa

import udf_host as h

I64 = pa.int64()

FIX = """import os
import time

WORK = %(work)r


def zygote_pid(x):
    return os.getppid()


def hold(x):
    import signal
    open(os.path.join(WORK, "started"), "w").close()
    with open(os.path.join(WORK, "handler"), "w") as f:
        f.write("1" if signal.getsignal(signal.SIGINT) is signal.default_int_handler else "0")
    while not os.path.exists(os.path.join(WORK, "release")):
        time.sleep(0.001)
    return os.getpid()


def ask(x):
    input()
    return x


def probe(x):
    import json
    import tempfile
    fds = fd_names()
    info = {"environ": dict(os.environ), "fds": fds, "tmp": tempfile.gettempdir(), "cwd": os.listdir(".")}
    with open(os.path.join(WORK, "probe.json"), "w", encoding="utf-8") as f:
        json.dump(info, f)
    return x


def wait_forever(x):
    open(os.path.join(WORK, "started"), "w").close()
    while True:
        time.sleep(0.001)
""" + h.FD_NAMES

_BOOT = (
    "import json, runpy, sys, tempfile\n"
    "sys.path[:] = json.loads(sys.argv[1])\n"
    "tempfile.tempdir = sys.argv[2]\n"
    "sys.argv = sys.argv[3:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)


def ints(*values):
    return pa.array(list(values), I64)


def proc_masks():
    """The signals this process ignores and catches, as the kernel reports them: the SigIgn
    and SigCgt lines of /proc/self/status on Linux; on macOS, which has no /proc, the same two
    masks (bit n-1 for signal n) from the handler sigaction() reports for each signal."""
    if sys.platform == "darwin":
        import ctypes

        class Sigaction(ctypes.Structure):  # <sys/signal.h>, struct sigaction
            _fields_ = [("handler", ctypes.c_void_p), ("mask", ctypes.c_uint32), ("flags", ctypes.c_int)]

        sigaction = ctypes.CDLL(None, use_errno=True).sigaction
        sigaction.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
        masks = {"SigIgn": 0, "SigCgt": 0}
        for sig in range(1, signal.NSIG):
            if sig in (signal.SIGKILL, signal.SIGSTOP):
                continue  # never ignored or caught; macOS refuses even to report them (EINVAL)
            act = Sigaction()
            if sigaction(sig, None, ctypes.byref(act)) != 0:
                raise OSError(ctypes.get_errno(), "sigaction(%d)" % sig)
            if act.handler == 1:  # SIG_IGN
                masks["SigIgn"] |= 1 << (sig - 1)
            elif act.handler:  # neither SIG_DFL nor SIG_IGN
                masks["SigCgt"] |= 1 << (sig - 1)
        return {k: "%016x" % v for k, v in masks.items()}
    with open("/proc/self/status", encoding="ascii") as f:
        return {k: v.strip() for k, _, v in (line.partition(":") for line in f) if k in ("SigIgn", "SigCgt")}


# ---- the engine (the child) ----------------------------------------------------


class Engine:
    """The child's side: a runtime with the fixture bundle, the report pipe and the go pipe."""

    def __init__(self, env, report_fd, go_fd, extra=()):
        self.env = env
        self.extra = list(extra)
        self.report = os.fdopen(report_fd, "w", encoding="utf-8")
        self.go = os.fdopen(go_fd, "r", encoding="utf-8")
        self.work = env._mk("work")
        self.source = FIX % {"work": self.work}
        self.rt = None  # made at the first instance, or by the scenario

    def instance(self, entry):
        if self.rt is None:
            self.rt = self.env.runtime()
        udf = self.rt.load_ok(self.env.bundle_spec({"fix.py": self.source}, "fix:" + entry))
        return self.rt.open_context_ok().open_instance_ok(udf)

    def tell(self, **what):
        self.report.write(json.dumps(what) + "\n")
        self.report.flush()

    def wait_go(self):
        self.go.readline()

    def pids(self):
        (zygote,) = self.env.trace.pids("spawn")
        return zygote, self.env.trace.pids("fork")

    def call_in_thread(self, inst):
        threading.Thread(target=lambda: inst.call([ints(0)]), daemon=True).start()
        while not os.path.exists(os.path.join(self.work, "started")):
            time.sleep(0.001)


def outcome(r):
    return {"status": r.status, "message": r.err.message if r.err is not None else None,
            "values": r.array.to_pylist() if r.array is not None else None}


def engine_orphan(e):
    idle = e.instance("zygote_pid")
    idle.call_ok([ints(0)])
    e.call_in_thread(e.instance("wait_forever"))
    zygote, workers = e.pids()
    e.tell(zygote=zygote, workers=workers)
    e.wait_go()  # the test kills this process here


def engine_reaped(e):
    inst = e.instance("zygote_pid")
    inst.call_ok([ints(0)])
    reaped = []
    reaper = threading.Thread(target=lambda: reaped.append(os.waitpid(-1, 0)[0]), daemon=True)
    reaper.start()
    zygote, workers = e.pids()
    e.tell(zygote=zygote, workers=workers)
    e.wait_go()  # the test has killed the zygote and seen the worker end
    reaper.join()
    e.tell(reaped=reaped, call=outcome(inst.call([ints(0)])))


def engine_signals(e):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    before = proc_masks()
    e.rt = e.env.runtime()
    calls = []
    udf = e.rt.load_ok(e.env.bundle_spec({"fix.py": e.source + ABORT}, "fix:abort"))
    inst = e.rt.open_context_ok().open_instance_ok(udf)
    calls.append(outcome(inst.call([ints(0)])))
    calls.append(outcome(inst.call([ints(0)])))
    pid = e.rt.load_ok(e.env.bundle_spec({"fix.py": e.source + ABORT}, "fix:zygote_pid"))
    other = e.rt.open_context_ok().open_instance_ok(pid)
    calls.append(outcome(other.call([ints(0)])))
    # An unload writes to the control socket without looking first: with the zygote gone,
    # that write meets a closed peer, which must be an error and never a SIGPIPE.
    (zygote,) = e.env.trace.pids("spawn")
    watch = h.ExitWatch(zygote)
    os.kill(zygote, signal.SIGKILL)
    watch.wait()
    e.rt.table.unload(pid.handle)
    e.tell(before=before, after=proc_masks(), calls=calls)


ABORT = """

def abort(x):
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.abort()
"""


def engine_fork(e):
    inst = e.instance("zygote_pid")
    inst.call_ok([ints(0)])
    zygote, workers = e.pids()
    spec = e.env.bundle_spec({"fix.py": e.source}, "fix:zygote_pid")
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            call = outcome(inst.call([ints(0)]))
            status, udf, err = e.rt.load(spec)
            load = {"status": status, "udf": udf is not None, "message": err.message if err else None}
            status, ctx, err = e.rt.open_context()
            opened = {"status": status, "ctx": ctx is not None, "message": err.message if err else None}
            os.write(w, json.dumps({"call": call, "load": load, "open_context": opened}).encode())
        finally:
            os._exit(0)
    os.close(w)
    with os.fdopen(r, "rb") as f:
        in_fork = json.loads(f.read())
    os.waitpid(pid, 0)
    e.tell(zygote=zygote, workers=workers, in_fork=in_fork, in_parent=outcome(inst.call([ints(0)])))
    e.wait_go()  # the test kills this process here


def engine_stdin(e):
    outcome_of_input = outcome(e.instance("ask").call([ints(0)]))
    e.tell(call=outcome_of_input)
    e.wait_go()


def engine_sigint(e):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    inst = e.instance("hold")
    first = []
    threading.Thread(target=lambda: first.append(outcome(inst.call([ints(0)]))), daemon=True).start()
    while not os.path.exists(os.path.join(e.work, "started")):
        time.sleep(0.001)
    _, workers = e.pids()
    e.tell(work=e.work, workers=workers)
    e.wait_go()  # the test has sent SIGINT to this process group and released the call
    while not first:
        time.sleep(0.001)
    with open(os.path.join(e.work, "handler"), encoding="ascii") as f:
        handler = f.read()
    e.tell(first=first[0], second=outcome(inst.call([ints(0)])), handler=handler)


def engine_probe(e):
    # An inheritable descriptor of this process, which no worker may receive.
    extra_path = e.env.path("extra_fd")
    extra_fd = os.open(extra_path, os.O_CREAT | os.O_WRONLY, 0o600)
    os.set_inheritable(extra_fd, True)
    e.instance("probe").call_ok([ints(5)])
    e.tell(work=e.work, extra_fd_path=extra_path)


def engine_packages(e):
    sys_path, *modules = e.extra
    e.rt = e.env.runtime(options=e.env.options() + ["sys_path=" + sys_path])
    done = {}
    for module in modules:
        status, udf, err = e.rt.load(h.Spec(module + ":inc", form=h.FORM_PACKAGE))
        done[module] = {"status": status, "message": err.message if err else None,
                        "values": None if udf is None else
                        e.rt.open_context_ok().open_instance_ok(udf).call_ok([ints(4)]).to_pylist()}
    e.tell(done=done)


ENGINES = {"orphan": engine_orphan, "reaped": engine_reaped, "signals": engine_signals, "fork": engine_fork,
           "stdin": engine_stdin, "sigint": engine_sigint, "probe": engine_probe, "packages": engine_packages}


def engine_main(args):
    scenario = args[args.index("--child") + 1]
    lib_dir = args[args.index("--lib-dir") + 1]
    report_fd = int(args[args.index("--report-fd") + 1])
    go_fd = int(args[args.index("--go-fd") + 1])
    extra = args[args.index("--extra") + 1:] if "--extra" in args else []
    # The test watches this engine's processes itself, and ends it with a signal in some cases.
    with h.Env(lib_dir, check_leaks=False) as env:
        ENGINES[scenario](Engine(env, report_fd, go_fd, extra))


# ---- the test (the parent) -------------------------------------------------------


class Child:
    """An engine in a child process of its own group; read() its next report."""

    def __init__(self, env, scenario, stdin=subprocess.DEVNULL, variables=None, extra=()):
        rep_r, rep_w = os.pipe()
        go_r, go_w = os.pipe()
        argv = [sys.executable, "-I", "-S", "-c", _BOOT, json.dumps(sys.path), env.dir, os.path.abspath(__file__),
                "--child", scenario, "--lib-dir", os.path.dirname(env.lib),
                "--report-fd", str(rep_w), "--go-fd", str(go_r)]
        if extra:
            argv += ["--extra"] + list(extra)
        child_env = None if variables is None else dict(os.environ, **variables)
        self.proc = subprocess.Popen(argv, pass_fds=(rep_w, go_r), process_group=0, stdin=stdin, env=child_env)
        os.close(rep_w)
        os.close(go_r)
        self.reports = os.fdopen(rep_r, "r", encoding="utf-8")
        self.go_w = go_w

    def read(self):
        line = self.reports.readline()
        assert line, "the engine ended without a report (status %s)" % self.proc.poll()
        return json.loads(line)

    def go(self):
        os.write(self.go_w, b"go\n")

    def kill(self):
        self.proc.kill()
        self.proc.wait()

    def close(self):
        if self.proc.poll() is None:
            self.kill()
        self.reports.close()
        os.close(self.go_w)


def no_runtime_process_outlives_the_engine(env):
    child = Child(env, "orphan")
    try:
        got = child.read()
        assert len(got["workers"]) == 2, got
        watches = [h.ExitWatch(p) for p in [got["zygote"]] + got["workers"]]
        child.kill()
        for w in watches:
            w.wait()
    finally:
        child.close()


def a_zygote_reaped_by_another_part_of_the_engine_is_named_with_an_unknown_status(env):
    child = Child(env, "reaped")
    try:
        got = child.read()
        (worker,) = got["workers"]
        watch = h.ExitWatch(worker)
        os.kill(got["zygote"], signal.SIGKILL)
        watch.wait()
        child.go()
        done = child.read()
        assert done["reaped"] == [got["zygote"]], done
        assert done["call"] == {
            "status": h.ERR_INSTANCE_LOST, "values": None,
            "message": "the worker (pid %d) is gone: its zygote (pid %d) ended with an unknown status; "
                       "no user code ran" % (worker, got["zygote"]),
        }, done
    finally:
        child.close()


def the_runtime_leaves_the_engines_signal_handling_as_it_found_it(env):
    child = Child(env, "signals")
    try:
        got = child.read()
        assert got["before"] == got["after"], got
        statuses = [c["status"] for c in got["calls"]]
        assert statuses == [h.ERR_WORKER_CRASHED, h.ERR_INSTANCE_LOST, h.OK], got["calls"]
        assert got["calls"][0]["message"].endswith("ended during the call with signal 6 (SIGABRT)"), got["calls"]
        assert child.proc.wait() == 0
    finally:
        child.close()


def a_fork_of_the_engine_cannot_reach_the_runtime_and_leaves_the_parent_working(env):
    child = Child(env, "fork")
    try:
        got = child.read()
        (worker,) = got["workers"]
        forked_why = "this process is a fork of the process that owns the runtime's zygote and workers"
        assert got["in_fork"] == {
            "call": {
                "status": h.ERR_INSTANCE_LOST, "values": None,
                "message": "the worker (pid %d) is gone: %s; no user code ran" % (worker, forked_why),
            },
            "load": {"status": h.ERR_INSTANCE_LOST, "udf": False, "message": "komira/python: " + forked_why},
            "open_context": {"status": h.ERR_INSTANCE_LOST, "ctx": False, "message": "komira/python: " + forked_why},
        }, got
        assert got["in_parent"] == {"status": h.OK, "message": None, "values": [got["zygote"]]}, got
        watch = h.ExitWatch(got["zygote"])
        child.kill()
        watch.wait()
    finally:
        child.close()


def a_call_that_reads_input_gets_end_of_file_when_the_engines_stdin_is_a_pipe_nobody_writes(env):
    held_r, held_w = os.pipe()
    child = Child(env, "stdin", stdin=held_r)
    try:
        got = child.read()
        assert got["call"] == {"status": h.ERR_RAISED, "values": None,
                               "message": "EOFError: EOF when reading a line"}, got
    finally:
        child.close()
        os.close(held_r)
        os.close(held_w)


def a_sigint_to_the_engines_group_leaves_a_call_running_and_the_worker_with_python_s_handler(env):
    child = Child(env, "sigint")
    try:
        got = child.read()
        (worker,) = got["workers"]
        os.killpg(child.proc.pid, signal.SIGINT)
        open(os.path.join(got["work"], "release"), "w").close()
        child.go()
        done = child.read()
        assert done["first"] == {"status": h.OK, "message": None, "values": [worker]}, done
        assert done["second"] == {"status": h.OK, "message": None, "values": [worker]}, done
        assert done["handler"] == "1", done
    finally:
        child.close()


def a_worker_sees_none_of_the_engines_environment_or_descriptors(env):
    child = Child(env, "probe", variables={"KOMIRA_ENGINE_ONLY": "visible"})
    try:
        got = child.read()
        with open(os.path.join(got["work"], "probe.json"), encoding="utf-8") as f:
            info = json.load(f)
        environ = info["environ"]
        home = environ.pop("HOME")
        tmp = environ.pop("TMPDIR")
        if sys.platform == "darwin":
            # CoreFoundation sets this one in its own process as it starts (libarrow links it):
            # "0x<uid>:<encoding>:<region>", not the engine's.
            cf = environ.pop("__CF_USER_TEXT_ENCODING")
            assert cf.startswith("0x%X:" % os.getuid()), cf
        assert environ == {
            "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1", "MKL_NUM_THREADS": "1",
            "VECLIB_MAXIMUM_THREADS": "1", "NUMEXPR_NUM_THREADS": "1",
            "JE_ARROW_MALLOC_CONF": "background_thread:false", "LC_ALL": "C",
            "TZ": "UTC", "PATH": "/usr/bin:/bin",
        }, environ
        assert os.path.basename(os.path.dirname(home)).startswith("worker-"), home
        assert info["tmp"] == tmp and info["cwd"] == [], info
        exe = os.path.realpath(sys.executable)
        # Descriptors 0 to 2 are the worker's own; above them only its cancel word and its socket,
        # and on macOS the kqueue of the thread that ends the worker with its zygote (fstat
        # reports a kqueue as S_IFIFO). The cancel word there is an unlinked file under the
        # runtime's scratch.
        rest = sorted(v for k, v in info["fds"].items() if int(k) > 2 and v != exe)
        if sys.platform == "darwin":
            assert len(rest) == 3 and os.path.basename(rest[0]).startswith("cancel-") and \
                os.path.basename(os.path.dirname(rest[0])) == "rt" and not os.path.exists(rest[0]) and \
                rest[1:] == ["mode:10000", "socket:"], info["fds"]
        else:
            assert len(rest) == 2 and rest[0].startswith("/memfd:komira-udf-cancel") and \
                rest[1].startswith("socket:"), info["fds"]
        assert info["fds"]["0"] == "/dev/null", info["fds"]
        assert got["extra_fd_path"] not in info["fds"].values(), info["fds"]
    finally:
        child.close()


def a_package_resolves_from_the_sys_path_option_and_not_from_the_engines_path_or_user_site(env):
    # The zygote gets a fixed environment and runs isolated, so the engine's PYTHONPATH and
    # user site must stay out of its imports whatever the engine's own settings are.
    import sysconfig
    roots = {}
    for name in ("pkgfirst", "pkgsecond", "pkgthird"):
        roots[name] = env.path(name)
        os.mkdir(roots[name])
    home = env.path("home")
    os.mkdir(home)
    user_site = sysconfig.get_path("purelib", scheme="posix_user", vars={"userbase": home})
    os.makedirs(user_site)
    # pkgsecond is on the engine's PYTHONPATH, pkgthird in the user site of the engine's HOME.
    for name, root in (("pkgfirst", roots["pkgfirst"]), ("pkgsecond", roots["pkgsecond"]), ("pkgthird", user_site)):
        with open(os.path.join(root, name + ".py"), "w", encoding="utf-8") as f:
            f.write("def inc(x):\n    return x + 1\n")
    child = Child(env, "packages", variables={"PYTHONPATH": roots["pkgsecond"], "HOME": home},
                  extra=[roots["pkgfirst"], "pkgfirst", "pkgsecond", "pkgthird"])
    try:
        done = child.read()["done"]
        assert done["pkgfirst"] == {"status": h.OK, "message": None, "values": [5]}, done
        for module in ("pkgsecond", "pkgthird"):
            assert done[module]["status"] == h.ERR_LOAD and done[module]["values"] is None, done
        assert done["pkgsecond"]["message"].startswith("import of 'pkgsecond' failed: ModuleNotFoundError"), done
        assert done["pkgthird"]["message"].startswith("import of 'pkgthird' failed: ModuleNotFoundError"), done
    finally:
        child.close()


def main(args):
    if "--child" in args:
        return engine_main(args)
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    me = sys.modules["__main__"]
    cases = [f for f in (getattr(me, n) for n in dir(me))
             if getattr(f, "__module__", None) == "__main__" and callable(f)
             and getattr(f, "__code__", None) is not None
             and f.__code__.co_argcount == 1 and f.__code__.co_varnames[0] == "env"]
    for case in cases:
        with h.Env(lib_dir) as env:
            case(env)
        print("ok", case.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
