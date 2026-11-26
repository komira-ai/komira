"""Supervision in the komira/python runtime: how a worker's end is named, the forced stop
of a call that ignores its cancel or deadline, a MemoryError, a zygote that ends under
open contexts, and the worker loop's reading of the cancel word.

    test_udf_supervision.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.

A UDF that must be running when the test acts creates `<work>/started` and, where the
test releases it, waits for `<work>/go`; a helper thread waits for `started`, acts (a
signal, the cancel flag, the host clock) and, where the runtime must have seen the act
first, waits for the runtime's own trace line. Nothing here measures time: the grace
period of a forced stop passes only when the test moves the host's clock.
"""

import os
import signal
import struct
import sys
import threading
import time

import pyarrow as pa

import udf_host as h

I64 = pa.int64()
GRACE_MS = 1000

FIX = """import os
import resource
import time

WORK = %(work)r


def _mark(name):
    open(os.path.join(WORK, name), "w").close()


def _wait(name):
    while not os.path.exists(os.path.join(WORK, name)):
        time.sleep(0.001)


def zygote_pid(x):
    return os.getppid()


def worker_pid(x):
    return os.getpid()


def abort_on_one(x):
    if x == 1:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.abort()
    return os.getppid()


def exit_with(x):
    os._exit(x)


def wait_forever(x):
    _mark("started")
    _wait("never")
    return x


def spin(x):
    _mark("started")
    while True:
        time.sleep(0.001)


def out_of_memory(x):
    raise MemoryError()


def counted(x):
    with open(os.path.join(WORK, "calls"), "a", encoding="utf-8") as f:
        f.write("call\\n")
    return x


def gated_at_ten(x):
    if x == 10:
        _mark("started")
        _wait("go")
    return x
"""


def ints(*values):
    return pa.array(list(values), I64)


def spawned(env, gen):
    (e,) = [e for e in env.trace.events("spawn") if e["gen"] == str(gen)]
    return int(e["pid"])


def forked(env, ctx):
    """The pid of the worker the zygote forked for context `ctx` (1, 2, ... in opening order)."""
    (e,) = [e for e in env.trace.events("fork") if e["ctx"] == str(ctx)]
    return int(e["pid"])


def until(cond):
    while not cond():
        time.sleep(0.001)


def refused(r, status, message):
    assert (r.status, r.err.message) == (status, message), (r.status, r.err)
    assert r.array is None


class Fixtures:
    """One runtime with the fixture bundle; `udf(name)` loads (once) the entry `name`."""

    def __init__(self, env, options=None, **spec):
        self.env = env
        self.work = env._mk("work")
        self.rt = env.runtime(options=options)
        self.source = FIX % {"work": self.work}
        self.loaded = {}
        self.spec = spec

    def udf(self, name, **kw):
        if name not in self.loaded:
            args = dict(self.spec, **kw)
            self.loaded[name] = self.rt.load_ok(self.env.bundle_spec({"fix.py": self.source}, "fix:" + name, **args))
        return self.loaded[name]

    def instance(self, name, ctx=None, **kw):
        udf = self.udf(name, **kw)  # a context sees only the UDFs loaded before it opened
        ctx = ctx if ctx is not None else self.rt.open_context_ok()
        return ctx, ctx.open_instance_ok(udf)

    def marker(self, name):
        return os.path.join(self.work, name)

    def during_call(self, act):
        """A thread that waits for the UDF's `started`, then runs act(). Returns join()."""
        def body():
            until(lambda: os.path.exists(self.marker("started")))
            act()

        t = threading.Thread(target=body)
        t.start()
        return t.join


def exits(env):
    return [(e["ctx"], e["how"], e["value"]) for e in env.trace.events("exit")]


# ---- how an end is named ------------------------------------------------------


def an_aborting_udf_is_a_crash_naming_the_signal_and_the_session_goes_on(env):
    f = Fixtures(env)
    caps = f.rt.describe()
    assert caps["features"] == h.FEATURE_CONTAINS_CRASHES | h.FEATURE_FORCED_STOP, caps
    ctx, inst = f.instance("abort_on_one")
    zygote = spawned(env, 1)
    assert inst.call_ok([ints(0)]).to_pylist() == [zygote]
    worker = forked(env, 1)
    refused(inst.call([ints(0, 1, 2)]), h.ERR_WORKER_CRASHED,
            "the worker (pid %d) ended during the call with signal 6 (SIGABRT)" % worker)
    assert exits(env) == [("1", "signalled", "6")], env.trace.events("exit")
    refused(inst.call([ints(0)]), h.ERR_INSTANCE_LOST,
            "the worker (pid %d) is gone: it ended during an earlier call with signal 6 (SIGABRT); "
            "no user code ran" % worker)
    inst.close()
    ctx.close()
    _, again = f.instance("abort_on_one")
    assert again.call_ok([ints(0, 2)]).to_pylist() == [zygote, zygote]
    assert forked(env, 2) != worker
    assert env.trace.pids("spawn") == [zygote]
    assert env.trace.events("sigkill") == []


def an_exit_the_worker_did_not_report_is_a_crash_naming_its_status(env):
    f = Fixtures(env)
    for n, status in enumerate((3, 0), start=1):
        _, inst = f.instance("exit_with")
        refused(inst.call([ints(status)]), h.ERR_WORKER_CRASHED,
                "the worker (pid %d) ended during the call with exit status %d" % (forked(env, n), status))
    assert exits(env) == [("1", "exited", "3"), ("2", "exited", "0")], env.trace.events("exit")


def a_sigkill_from_outside_the_runtime_is_a_crash_and_not_a_forced_stop(env):
    f = Fixtures(env)
    _, inst = f.instance("wait_forever")
    join = f.during_call(lambda: os.kill(forked(env, 1), signal.SIGKILL))
    try:
        r = inst.call([ints(0)])
    finally:
        join()
    refused(r, h.ERR_WORKER_CRASHED, "the worker (pid %d) ended during the call with signal 9 (SIGKILL)" % forked(env, 1))
    assert env.trace.events("sigkill") == []


def a_worker_that_ended_between_calls_is_lost_and_runs_no_user_code(env):
    f = Fixtures(env)
    _, inst = f.instance("counted")
    assert inst.call_ok([ints(4)]).to_pylist() == [4]
    worker = forked(env, 1)
    watch = h.ExitWatch(worker)
    os.kill(worker, signal.SIGTERM)
    watch.wait()
    refused(inst.call([ints(5)]), h.ERR_INSTANCE_LOST,
            "the worker (pid %d) is gone: it ended with signal 15 (SIGTERM) while no call was running; "
            "no user code ran" % worker)
    with open(f.marker("calls"), encoding="utf-8") as calls:
        assert calls.read().splitlines() == ["call"]
    assert exits(env) == [("1", "signalled", "15")], env.trace.events("exit")


# ---- cancel, deadline and the forced stop -------------------------------------


def a_cancel_lands_between_rows_of_a_long_loop_and_the_worker_stays(env):
    f = Fixtures(env)
    f.udf("worker_pid")
    ctx, inst = f.instance("gated_at_ten")
    _, pid = f.instance("worker_pid", ctx=ctx)
    call_id = inst.next_call

    def act():
        inst.cancel.value = 1
        until(lambda: any(e["call"] == str(call_id) for e in env.trace.events("cancel_word")))
        open(f.marker("go"), "w").close()

    join = f.during_call(act)
    try:
        r = inst.call([pa.array(range(1_000_000), I64)])
    finally:
        join()
    assert (r.status, r.err.message, r.err.row) == (h.ERR_CANCELLED, "cancelled at row 11", 11), r.err
    assert pid.call_ok([ints(0)]).to_pylist() == [forked(env, 1)]
    assert env.trace.events("sigkill") == [] and exits(env) == []


def stopped_by_force(env, f, inst, fire, why, grace_ms=GRACE_MS, **call):
    """Run a call of `spin`; once it spins, fire() the cancel or the deadline, wait for
    the runtime's cancel_word line, then move the host clock past the grace period."""
    call_id = inst.next_call

    def act():
        fire()
        until(lambda: any(e["call"] == str(call_id) and e["why"] == why for e in env.trace.events("cancel_word")))
        (word,) = [e for e in env.trace.events("cancel_word") if e["call"] == str(call_id)]
        f.rt.state.now_value = int(word["now"]) + grace_ms * 1_000_000

    join = f.during_call(act)
    try:
        return inst.call([ints(0)], **call), call_id
    finally:
        join()


def kill_lines(env):
    return [(e["ctx"], e["pid"], e["call"], e["why"]) for e in env.trace.events("sigkill")]


def a_call_that_ignores_a_cancel_is_stopped_by_force_after_the_grace_period(env):
    f = Fixtures(env, options=env.options(grace_ms=GRACE_MS), batch_format=h.ARROW, shape=h.SHAPE_MAP_BATCHES_COLUMN)
    assert f.rt.describe()["features"] & h.FEATURE_FORCED_STOP
    _, inst = f.instance("spin")
    worker = forked(env, 1)
    r, call_id = stopped_by_force(env, f, inst, lambda: setattr(inst.cancel, "value", 1), "cancel")
    refused(r, h.ERR_KILLED, "the worker (pid %d) did not stop within grace_ms=%d after the cancel and was "
            "stopped with SIGKILL" % (worker, GRACE_MS))
    assert kill_lines(env) == [("1", str(worker), str(call_id), "cancel")], env.trace.events("sigkill")
    assert exits(env) == [("1", "signalled", "9")], env.trace.events("exit")
    refused(inst.call([ints(0)]), h.ERR_INSTANCE_LOST,
            "the worker (pid %d) is gone: it was stopped with SIGKILL during an earlier call; "
            "no user code ran" % worker)


def a_call_that_ignores_its_deadline_is_stopped_by_force_after_the_grace_period(env):
    f = Fixtures(env, options=env.options(grace_ms=GRACE_MS), batch_format=h.ARROW, shape=h.SHAPE_MAP_BATCHES_COLUMN)
    _, inst = f.instance("spin")
    worker = forked(env, 1)
    f.rt.state.now_value = 50
    r, call_id = stopped_by_force(env, f, inst, lambda: setattr(f.rt.state, "now_value", 200), "deadline",
                                  deadline_ns=100)
    refused(r, h.ERR_KILLED, "the worker (pid %d) did not stop within grace_ms=%d after its deadline passed and "
            "was stopped with SIGKILL" % (worker, GRACE_MS))
    assert kill_lines(env) == [("1", str(worker), str(call_id), "deadline")], env.trace.events("sigkill")
    refused(inst.call([ints(0)]), h.ERR_INSTANCE_LOST,
            "the worker (pid %d) is gone: it was stopped with SIGKILL during an earlier call; "
            "no user code ran" % worker)


def without_the_option_the_grace_period_is_two_seconds_of_the_host_clock(env):
    f = Fixtures(env, batch_format=h.ARROW, shape=h.SHAPE_MAP_BATCHES_COLUMN)
    _, inst = f.instance("spin")
    worker = forked(env, 1)
    r, call_id = stopped_by_force(env, f, inst, lambda: setattr(inst.cancel, "value", 1), "cancel", grace_ms=2000)
    refused(r, h.ERR_KILLED, "the worker (pid %d) did not stop within grace_ms=2000 after the cancel and was "
            "stopped with SIGKILL" % worker)
    assert kill_lines(env) == [("1", str(worker), str(call_id), "cancel")], env.trace.events("sigkill")
    (word,) = env.trace.events("cancel_word")
    (kill,) = env.trace.events("sigkill")
    assert int(kill["now"]) - int(word["now"]) == 2000 * 1_000_000, (word, kill)


def a_memory_error_ends_the_worker_after_its_answer(env):
    f = Fixtures(env)
    _, inst = f.instance("out_of_memory")
    worker = forked(env, 1)
    refused(inst.call([ints(0)]), h.ERR_OUT_OF_MEMORY, "MemoryError")
    # The EXIT report was read before the call returned.
    assert exits(env) == [("1", "exited", "1")], env.trace.events("exit")
    refused(inst.call([ints(0)]), h.ERR_INSTANCE_LOST,
            "the worker (pid %d) is gone: it ended with exit status 1 after it ran out of memory in an earlier "
            "call; no user code ran" % worker)


# ---- the zygote's end ------------------------------------------------------------


def the_zygote_ending_loses_its_contexts_and_the_next_load_starts_another(env):
    f = Fixtures(env)
    idle_ctx, idle = f.instance("zygote_pid")
    assert idle.call_ok([ints(0)]).to_pylist() == [spawned(env, 1)]
    busy_ctx, busy = f.instance("wait_forever")
    zygote, idle_worker, busy_worker = spawned(env, 1), forked(env, 1), forked(env, 2)
    watches = [h.ExitWatch(p) for p in (idle_worker, busy_worker)]
    join = f.during_call(lambda: os.kill(zygote, signal.SIGKILL))
    try:
        r = busy.call([ints(0)])
    finally:
        join()
    refused(r, h.ERR_WORKER_CRASHED, "the worker (pid %d) ended during the call when its zygote (pid %d) ended "
            "with signal 9 (SIGKILL)" % (busy_worker, zygote))
    refused(idle.call([ints(0)]), h.ERR_INSTANCE_LOST, "the worker (pid %d) is gone: its zygote (pid %d) ended "
            "with signal 9 (SIGKILL); no user code ran" % (idle_worker, zygote))
    for w in watches:
        w.wait()
    status, ctx, err = f.rt.open_context()
    assert (status, ctx) == (h.ERR_INSTANCE_LOST, None), err
    assert err.message == ("the zygote (pid %d) ended with signal 9 (SIGKILL); load the UDFs again to open a "
                           "context" % zygote), err
    again = f.rt.load_ok(env.bundle_spec({"fix.py": f.source}, "fix:zygote_pid"))
    second = spawned(env, 2)
    assert second != zygote
    assert f.rt.open_context_ok().open_instance_ok(again).call_ok([ints(0)]).to_pylist() == [second]
    idle_ctx.close()
    busy_ctx.close()
    assert [e["gen"] for e in env.trace.events("shutdown")] == ["1"], env.trace.events("shutdown")


# ---- the worker loop ---------------------------------------------------------------


def the_worker_loop_acts_only_on_a_cancel_word_naming_its_call(env):
    from komira._udf import worker

    batch = pa.record_batch([ints(1, 2, 3)], names=["x"])
    word = bytearray(struct.pack("<q", 7))
    try:
        worker._run_values(lambda x: x, batch, I64, word, 7)
    except worker._Fail as failed:
        assert (failed.code, failed.message, failed.row) == (worker.wire.ERR_CANCELLED, "cancelled at row 0", 0)
    else:
        raise AssertionError("a cancel word naming the call did not stop it")
    out = worker._run_values(lambda x: x * 2, batch, I64, word, 8)
    assert out.to_pylist() == [2, 4, 6]


def main(args):
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
