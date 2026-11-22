"""The komira/python runtime in an engine process the test starts and ends: no runtime
process outlives the engine's, a zygote that someone else in the engine's process reaped,
the engine's signal handling, and a fork of the engine's process.

    test_udf_engine_child.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` is `//src/udf_python:komira_udf_python`.

Each case starts this file again as the engine (`--child <scenario>`), with the test's
interpreter, `sys.path` and temporary directory, in a process group of its own. The engine
reports to the test as JSON lines on a pipe and waits on a second pipe for the test's
`go`; the test watches the processes it did not start (the zygote, the workers) through
pidfds it opens while they are known to be running. Nothing here measures time.
"""

import json
import os
import select
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


def wait_forever(x):
    open(os.path.join(WORK, "started"), "w").close()
    while True:
        time.sleep(0.001)
"""

_BOOT = (
    "import json, runpy, sys, tempfile\n"
    "sys.path[:] = json.loads(sys.argv[1])\n"
    "tempfile.tempdir = sys.argv[2]\n"
    "sys.argv = sys.argv[3:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)


def ints(*values):
    return pa.array(list(values), I64)


def wait_for_exit(pidfd):
    """Block until the process behind `pidfd` has ended; closes the descriptor."""
    try:
        poller = select.poll()
        poller.register(pidfd, select.POLLIN)
        poller.poll()
    finally:
        os.close(pidfd)


def proc_masks():
    """The signals this process ignores and catches, as the kernel reports them."""
    with open("/proc/self/status", encoding="ascii") as f:
        return {k: v.strip() for k, _, v in (line.partition(":") for line in f) if k in ("SigIgn", "SigCgt")}


# ---- the engine (the child) ----------------------------------------------------


class Engine:
    """The child's side: a runtime with the fixture bundle, the report pipe and the go pipe."""

    def __init__(self, env, report_fd, go_fd):
        self.env = env
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
    pidfd = os.pidfd_open(zygote)
    os.kill(zygote, signal.SIGKILL)
    wait_for_exit(pidfd)
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


ENGINES = {"orphan": engine_orphan, "reaped": engine_reaped, "signals": engine_signals, "fork": engine_fork}


def engine_main(args):
    scenario = args[args.index("--child") + 1]
    lib_dir = args[args.index("--lib-dir") + 1]
    report_fd = int(args[args.index("--report-fd") + 1])
    go_fd = int(args[args.index("--go-fd") + 1])
    with h.Env(lib_dir) as env:
        ENGINES[scenario](Engine(env, report_fd, go_fd))


# ---- the test (the parent) -------------------------------------------------------


class Child:
    """An engine in a child process of its own group; read() its next report."""

    def __init__(self, env, scenario):
        rep_r, rep_w = os.pipe()
        go_r, go_w = os.pipe()
        argv = [sys.executable, "-I", "-S", "-c", _BOOT, json.dumps(sys.path), env.dir, os.path.abspath(__file__),
                "--child", scenario, "--lib-dir", os.path.dirname(env.lib),
                "--report-fd", str(rep_w), "--go-fd", str(go_r)]
        self.proc = subprocess.Popen(argv, pass_fds=(rep_w, go_r), process_group=0, stdin=subprocess.DEVNULL)
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
        pidfds = [os.pidfd_open(p) for p in [got["zygote"]] + got["workers"]]
        child.kill()
        for fd in pidfds:
            wait_for_exit(fd)
    finally:
        child.close()


def a_zygote_reaped_by_another_part_of_the_engine_is_named_with_an_unknown_status(env):
    child = Child(env, "reaped")
    try:
        got = child.read()
        (worker,) = got["workers"]
        pidfd = os.pidfd_open(worker)
        os.kill(got["zygote"], signal.SIGKILL)
        wait_for_exit(pidfd)
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
        pidfd = os.pidfd_open(got["zygote"])
        child.kill()
        wait_for_exit(pidfd)
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
