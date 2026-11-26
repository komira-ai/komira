"""Zygote generations of the komira/python runtime: a load of a module name that
an earlier bundle already imported retires the generation and is answered by a
new one, while contexts of the old generation keep their code until they close.

    test_udf_generations.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import os
import sys

import pyarrow as pa

import udf_host as h

I64 = pa.int64()

ADD_ONE = "def f(x):\n    return x + 1\n"
ADD_THOUSAND = "def f(x):\n    return x + 1000\n"
PARENT = "import os\n\ndef f(x):\n    return os.getppid()\n"


def ints(*values):
    return pa.array(list(values), I64)


def spawned(env, gen):
    (e,) = [e for e in env.trace.events("spawn") if e["gen"] == str(gen)]
    return int(e["pid"])


def forked(env, gen):
    (e,) = [e for e in env.trace.events("fork") if e["gen"] == str(gen)]
    return int(e["pid"])


def a_second_bundle_for_an_imported_module_loads_in_a_new_generation(env):
    rt = env.runtime()
    a = rt.load_ok(env.bundle_spec({"m.py": ADD_ONE}, "m:f"))
    ctx1 = rt.open_context_ok()
    inst1 = ctx1.open_instance_ok(a)
    assert inst1.call_ok([ints(1, 2, 3)]).to_pylist() == [2, 3, 4]
    assert env.trace.pids("spawn") == [spawned(env, 1)]

    rt.load_ok(env.bundle_spec({"m.py": ADD_THOUSAND}, "m:f"))
    b = rt.load_ok(env.bundle_spec({"m.py": ADD_THOUSAND}, "m:f"))

    names = env.trace.names()
    assert names.count("spawn") == 2 and names.count("hello") == 2, names
    spawn_at = [i for i, n in enumerate(names) if n == "spawn"]
    assert names.index("retire") < spawn_at[1], names
    assert [e["gen"] for e in env.trace.events("retire")] == ["1"]
    assert [e["gen"] for e in env.trace.events("hello")] == ["1", "2"]
    # A's load, B's refused load in generation 1, B's load in generation 2,
    # and the repeat of B in generation 2.
    assert [e["gen"] for e in env.trace.events("load")] == ["1", "1", "2", "2"]
    assert env.trace.events("shutdown") == []  # generation 1 still has a context

    ctx2 = rt.open_context_ok()
    inst2 = ctx2.open_instance_ok(b)
    assert inst2.call_ok([ints(1, 2, 3)]).to_pylist() == [1001, 1002, 1003]
    assert [e["gen"] for e in env.trace.events("fork")] == ["1", "2"]

    # The context opened before the retirement keeps the code it loaded.
    assert inst1.call_ok([ints(10)]).to_pylist() == [11]


def a_worker_of_the_new_generation_is_forked_from_its_zygote(env):
    rt = env.runtime()
    a = rt.load_ok(env.bundle_spec({"m.py": PARENT}, "m:f"))
    ctx1 = rt.open_context_ok()
    parent1 = ctx1.open_instance_ok(a).call_ok([ints(0)]).to_pylist()
    b = rt.load_ok(env.bundle_spec({"m.py": PARENT + "\n# another bundle\n"}, "m:f"))
    ctx2 = rt.open_context_ok()
    parent2 = ctx2.open_instance_ok(b).call_ok([ints(0)]).to_pylist()

    zygote1, zygote2 = spawned(env, 1), spawned(env, 2)
    assert zygote1 != zygote2
    assert parent1 == [zygote1] and parent2 == [zygote2], (parent1, parent2)
    assert forked(env, 2) != forked(env, 1)


def the_old_generation_ends_when_its_last_context_closes(env):
    rt = env.runtime()
    a = rt.load_ok(env.bundle_spec({"m.py": ADD_ONE}, "m:f"))
    ctx1 = rt.open_context_ok()
    inst1 = ctx1.open_instance_ok(a)
    inst1.call_ok([ints(1)])
    rt.load_ok(env.bundle_spec({"m.py": ADD_THOUSAND}, "m:f"))
    zygote1 = spawned(env, 1)

    assert env.trace.events("shutdown") == []
    assert not h.process_gone(zygote1), "generation 1 ended with a context open"
    inst1.close()
    # Closing the last context shuts the retired generation down and reaps its
    # zygote before close() returns, so no wait is needed.
    ctx1.close()
    (down,) = env.trace.events("shutdown")
    assert down["gen"] == "1" and down["pid"] == str(zygote1), down
    assert h.process_gone(zygote1), "the zygote of generation 1 outlived its last context"


def the_same_bundle_loaded_twice_stays_in_one_generation(env):
    rt = env.runtime()
    spec = env.bundle_spec({"m.py": ADD_ONE}, "m:f")
    first = rt.load_ok(spec)
    second = rt.load_ok(spec)
    ctx = rt.open_context_ok()
    assert ctx.open_instance_ok(first).call_ok([ints(1)]).to_pylist() == [2]
    assert ctx.open_instance_ok(second).call_ok([ints(2)]).to_pylist() == [3]
    assert env.trace.events("retire") == []
    assert env.trace.pids("spawn") == [spawned(env, 1)]
    assert [e["gen"] for e in env.trace.events("load")] == ["1", "1"]


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
