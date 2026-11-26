"""Closing and unloading in the komira/python UDF runtime: a context's worker ends with its
context, an unload empties the zygote's registry entry, a closed instance leaves its worker.

    test_udf_lifecycle.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import os
import sys

import pyarrow as pa

import udf_host as h

I64 = pa.int64()


def ints(*values):
    return pa.array(list(values), I64)


WHO = """import os

def who(k):
    return os.getpid() if k == 0 else os.getppid()
"""

PLUS = """def plus_one(x):
    return x + 1

def plus_two(x):
    return x + 2
"""


def closing_a_context_ends_its_worker_and_leaves_the_other_context_usable(env):
    rt = env.runtime()
    who = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    plus = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    first, second = rt.open_context_ok(), rt.open_context_ok()
    first_who, second_who = first.open_instance_ok(who), second.open_instance_ok(who)
    first_plus, second_plus = first.open_instance_ok(plus), second.open_instance_ok(plus)
    doomed = first_who.call_ok([ints(0)]).to_pylist()[0]
    kept = second_who.call_ok([ints(0)]).to_pylist()[0]
    assert doomed != kept
    assert sorted(env.trace.pids("fork")) == sorted([doomed, kept])
    watch = h.ExitWatch(doomed)
    first_who.close()
    first_plus.close()
    first.close()
    watch.wait()
    assert not h.process_gone(kept)
    assert second_plus.call_ok([ints(1, 2, 3)]).to_pylist() == [2, 3, 4]
    assert second_who.call_ok([ints(0)]).to_pylist() == [kept]
    third = rt.open_context_ok()
    assert third.open_instance_ok(plus).call_ok([ints(9)]).to_pylist() == [10]
    assert [e["ctx"] for e in env.trace.events("fork")] == ["1", "2", "3"]


def closing_the_last_context_leaves_the_runtime_able_to_open_another(env):
    rt = env.runtime()
    plus = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    who = rt.load_ok(env.bundle_spec({"who.py": WHO}, "who:who"))
    ctx = rt.open_context_ok()
    inst = ctx.open_instance_ok(who)
    worker = inst.call_ok([ints(0)]).to_pylist()[0]
    watch = h.ExitWatch(worker)
    inst.close()
    ctx.close()
    watch.wait()
    again = rt.open_context_ok()
    assert again.open_instance_ok(plus).call_ok([ints(4)]).to_pylist() == [5]


def closing_one_instance_leaves_the_other_instance_of_the_context_callable(env):
    rt = env.runtime()
    one = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    two = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_two"))
    ctx = rt.open_context_ok()
    first, second = ctx.open_instance_ok(one), ctx.open_instance_ok(two)
    assert first.call_ok([ints(1)]).to_pylist() == [2]
    assert env.trace.events("close_instance") == []
    first.close()
    assert env.trace.events("close_instance") == [
        {"event": "close_instance", "ctx": "1", "inst": "1", "left": "1"}]
    assert second.call_ok([ints(1, 2)]).to_pylist() == [3, 4]
    reopened = ctx.open_instance_ok(one)
    assert reopened.call_ok([ints(10)]).to_pylist() == [11]
    second.close()
    reopened.close()
    assert [(e["inst"], e["left"]) for e in env.trace.events("close_instance")] == [
        ("1", "1"), ("2", "1"), ("3", "0")]


def instance_counts_are_kept_per_worker(env):
    rt = env.runtime()
    udf = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    first, second = rt.open_context_ok(), rt.open_context_ok()
    a, b = first.open_instance_ok(udf), first.open_instance_ok(udf)
    c = second.open_instance_ok(udf)
    c.close()
    a.close()
    assert [(e["ctx"], e["inst"], e["left"]) for e in env.trace.events("close_instance")] == [
        ("2", "1", "0"), ("1", "1", "1")]
    assert b.call_ok([ints(5)]).to_pylist() == [6]


def unloading_a_udf_reports_the_registry_it_leaves(env):
    rt = env.runtime()
    one = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    two = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_two"))
    loaded = {e["entry"]: e["udf"] for e in env.trace.events("load")}
    assert env.trace.events("unload") == []
    one.unload()
    assert env.trace.events("unload") == [
        {"event": "unload", "gen": "1", "udf": loaded["plus:plus_one"], "left": "1"}]
    ctx = rt.open_context_ok()
    assert ctx.open_instance_ok(two).call_ok([ints(1)]).to_pylist() == [3]
    two.unload()
    assert env.trace.events("unload")[-1] == {
        "event": "unload", "gen": "1", "udf": loaded["plus:plus_two"], "left": "0"}


def an_instance_opened_before_an_unload_keeps_working_in_its_context(env):
    rt = env.runtime()
    one = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    two = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_two"))
    before = rt.open_context_ok()
    held = before.open_instance_ok(one)
    one.unload()
    assert held.call_ok([ints(1)]).to_pylist() == [2]
    after = rt.open_context_ok()
    assert after.open_instance_ok(two).call_ok([ints(1)]).to_pylist() == [3]
    assert held.call_ok([ints(7)]).to_pylist() == [8]
    assert [e["left"] for e in env.trace.events("unload")] == ["1"]


def a_udf_loaded_after_an_unload_runs_in_the_same_generation(env):
    rt = env.runtime()
    one = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    one.unload()
    two = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_two"))
    assert [e["gen"] for e in env.trace.events("load")] == ["1", "1"]
    assert len(env.trace.events("spawn")) == 1
    ctx = rt.open_context_ok()
    assert ctx.open_instance_ok(two).call_ok([ints(1)]).to_pylist() == [3]
    assert [e["left"] for e in env.trace.events("unload")] == ["0"]


def a_runtime_without_the_trace_option_writes_no_lifecycle_lines(env):
    rt = env.runtime(options=env.options(drop=("trace",)))
    udf = rt.load_ok(env.bundle_spec({"plus.py": PLUS}, "plus:plus_one"))
    ctx = rt.open_context_ok()
    inst = ctx.open_instance_ok(udf)
    assert inst.call_ok([ints(1)]).to_pylist() == [2]
    inst.close()
    ctx.close()
    udf.unload()
    assert env.trace.events() == []


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
