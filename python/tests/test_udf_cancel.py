"""A cancel flag or a deadline that fires while a call is running: the library
stores the call's id in the context's cancel word, the VALUES worker sees it
between rows and answers ERR_CANCELLED or ERR_DEADLINE, and the same instance
serves the next call.

    test_udf_cancel.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.

The UDF under test creates `<dir>/started` in row 0 and waits there until the
host creates `<dir>/go`. A second thread waits for `started`, fires the cancel
flag or moves the host clock, waits for the runtime's own `cancel_word` trace
line, and only then creates `go`. Nothing here measures time.
"""

import os
import sys
import threading
import time

import pyarrow as pa

import udf_host as h

I64 = pa.int64()

GATED = """import os
import time

def gated(x):
    if x == 0:
        open(os.path.join(%(dir)r, "started"), "w").close()
        while not os.path.exists(os.path.join(%(dir)r, "go")):
            time.sleep(0.001)
    return x
"""


def pa_ints(*v):
    return pa.array(list(v), I64)


def gated_instance(env, work):
    rt = env.runtime()
    spec = env.bundle_spec({"gated.py": GATED % {"dir": work}}, "gated:gated")
    udf = rt.load_ok(spec)
    return rt, rt.open_context_ok().open_instance_ok(udf)


def fire_during_call(env, work, fire, why, call_id):
    """A thread that waits for the UDF to be in row 0, calls fire(), waits for
    the runtime's cancel_word line for this call, then releases the UDF.
    Returns (start, finish): start() before the call, finish() after it."""
    done = threading.Event()

    def until(cond):
        while not cond():
            if done.is_set():
                return False
            time.sleep(0.001)
        return True

    def body():
        try:
            if not until(lambda: os.path.exists(os.path.join(work, "started"))):
                return
            fire()
            until(lambda: any(e.get("why") == why and e.get("call") == str(call_id)
                              for e in env.trace.events("cancel_word")))
        finally:
            open(os.path.join(work, "go"), "w").close()

    t = threading.Thread(target=body)

    def finish():
        done.set()
        t.join()

    return t.start, finish


def a_cancel_flag_set_during_a_call_stops_it_between_rows_and_not_the_next_call(env):
    work = env._mk("work")
    rt, inst = gated_instance(env, work)
    call_id = inst.next_call
    start, finish = fire_during_call(env, work, lambda: setattr(inst.cancel, "value", 1), "cancel", call_id)
    start()
    try:
        r = inst.call([pa_ints(0, 1, 2)])
    finally:
        finish()
    assert r.status == h.ERR_CANCELLED, r.err
    assert r.err.message == "cancelled at row 1" and r.err.row == 1, r.err
    assert r.array is None
    words = env.trace.events("cancel_word")
    assert [(e["call"], e["why"]) for e in words] == [(str(call_id), "cancel")], words
    # The stored word names the finished call, so it cannot cancel this one.
    assert inst.call_ok([pa_ints(5, 6, 7)]).to_pylist() == [5, 6, 7]
    assert len(env.trace.events("cancel_word")) == 1


def a_deadline_passing_during_a_call_stops_it_between_rows_and_not_the_next_call(env):
    work = env._mk("work")
    rt, inst = gated_instance(env, work)
    call_id = inst.next_call
    rt.state.now_value = 50
    start, finish = fire_during_call(env, work, lambda: setattr(rt.state, "now_value", 200), "deadline", call_id)
    start()
    try:
        r = inst.call([pa_ints(0, 1, 2)], deadline_ns=100)
    finally:
        finish()
    assert r.status == h.ERR_DEADLINE, r.err
    assert r.err.message == "the call passed its deadline at row 1" and r.err.row == 1, r.err
    assert r.array is None
    words = env.trace.events("cancel_word")
    assert [(e["call"], e["why"]) for e in words] == [(str(call_id), "deadline")], words
    assert inst.call_ok([pa_ints(5, 6, 7)]).to_pylist() == [5, 6, 7]
    assert len(env.trace.events("cancel_word")) == 1


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
