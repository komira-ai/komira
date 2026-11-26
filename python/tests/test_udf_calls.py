"""Calls through the komira/python runtime: the values and nulls that come back,
the refusals of a result that is not the declared type, a user exception with its
trace, cancellation and deadlines read from the host's clock, and the host's
memory hook.

    test_udf_calls.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import gc
import os
import sys

import pyarrow as pa

import udf_host as h

I64, I32, F64 = pa.int64(), pa.int32(), pa.float64()

OPS = """import pyarrow as pa
import pyarrow.compute as pc

def ident(x):
    return x

def lossy_int(x):
    return 2.5

def lossy_float(x):
    return 2 ** 53 + 1

def a_bool(x):
    return True

def int_for_float(x):
    return 3

def narrow(x):
    return 2 ** 31

def raises(x):
    if x == 2:
        raise ValueError("boom")
    return x

def raises_silently(x):
    raise ValueError()

def plus_hundred(x):
    return None if x is None else x + 100

def mix(a, b):
    return None if a is None or b is None else a + b

def doubled(x):
    return pc.multiply(x, 2)

def floats(x):
    return pa.array([1.5] * len(x))

def short(x):
    return x.slice(1)

def not_an_array(x):
    return [1, 2, 3]

def column_raises(x):
    raise KeyError("k")
"""
RAISE_LINE = OPS.splitlines().index('        raise ValueError("boom")') + 1


def pa_ints(*v):
    return pa.array(list(v), I64)


def session(env, udfs):
    """Load every UDF {name: (entry, Spec kwargs)}, then open one context and
    one instance of each: {name: Instance}."""
    rt = env.runtime()
    loaded = {n: rt.load_ok(env.bundle_spec({"ops.py": OPS}, "ops:" + entry, **kw))
              for n, (entry, kw) in udfs.items()}
    ctx = rt.open_context_ok()
    return rt, {n: ctx.open_instance_ok(u) for n, u in loaded.items()}


def refused(r, status, message, row=None):
    assert r.status == status and r.err.message == message, (r.status, r.err)
    if row is not None:
        assert r.err.row == row, r.err
    assert r.array is None


def values_come_back_as_the_declared_types_with_nulls_and_empty_batches(env):
    rt, i = session(env, {
        "ident": ("ident", {}),
        "plus": ("plus_hundred", {}),
        "mix": ("mix", {"args": [("a", I32), ("b", F64)], "result": F64}),
        "int_for_float": ("int_for_float", {"result": F64}),
    })
    assert i["ident"].call_ok([pa_ints(1, 2, 3)]).to_pylist() == [1, 2, 3]
    assert i["ident"].call_ok([pa_ints()]).to_pylist() == []
    assert i["plus"].call_ok([pa.array([1, None, 3], I64)]).to_pylist() == [101, None, 103]
    out = i["mix"].call_ok([pa.array([1, None, 2], I32), pa.array([0.5, 1.0, None], F64)])
    assert out.type == F64 and out.to_pylist() == [1.5, None, None], out
    out = i["int_for_float"].call_ok([pa_ints(1, 2)])
    assert out.type == F64 and out.to_pylist() == [3.0, 3.0]


def a_result_that_is_not_the_declared_type_without_loss_is_refused_by_value(env):
    rt, i = session(env, {
        "lossy_int": ("lossy_int", {}),
        "lossy_float": ("lossy_float", {"result": F64}),
        "a_bool": ("a_bool", {}),
        "narrow": ("narrow", {"args": [("x", I32)], "result": I32}),
    })
    refused(i["lossy_int"].call([pa_ints(1)]), h.ERR_RETURN_TYPE,
            "row 0 returned float 2.5, which is not int64 without loss", 0)
    refused(i["lossy_float"].call([pa_ints(1, 2)]), h.ERR_RETURN_TYPE,
            "row 0 returned int 9007199254740993, which is not double without loss", 0)
    refused(i["a_bool"].call([pa_ints(1)]), h.ERR_RETURN_TYPE,
            "row 0 returned bool True, which is not int64 without loss", 0)
    refused(i["narrow"].call([pa.array([1], I32)]), h.ERR_RETURN_TYPE,
            "row 0 returned int 2147483648, which is not int32 without loss", 0)
    assert i["lossy_int"].call([pa_ints(1)]).status == h.ERR_RETURN_TYPE, "instance stays usable"


def a_user_exception_is_reported_with_its_row_and_the_users_file_and_line(env):
    rt, i = session(env, {"raises": ("raises", {}), "silent": ("raises_silently", {})})
    r = i["raises"].call([pa_ints(0, 1, 2, 3)])
    refused(r, h.ERR_RAISED, "ValueError: boom", 2)
    assert 'ops.py", line %d, in raises' % RAISE_LINE in r.err.trace, r.err.trace
    assert "komira/_udf" not in r.err.trace, r.err.trace
    refused(i["silent"].call([pa_ints(0)]), h.ERR_RAISED, "ValueError", 0)
    assert i["raises"].call_ok([pa_ints(0, 1)]).to_pylist() == [0, 1]


def column_functions_take_and_return_arrow_arrays(env):
    col = {"batch_format": h.ARROW}
    mapped = dict(col, shape=h.SHAPE_MAP_BATCHES_COLUMN)
    rt, i = session(env, {
        "scalar": ("doubled", col), "mapped": ("doubled", mapped),
        "floats": ("floats", mapped), "short": ("short", mapped),
        "not_an_array": ("not_an_array", mapped), "raises": ("column_raises", mapped),
        "ident": ("ident", mapped),
    })
    for name in ("scalar", "mapped"):
        assert i[name].call_ok([pa_ints(1, 2, 3)]).to_pylist() == [2, 4, 6]
    assert i["ident"].call_ok([pa.array([1, None], I64)]).to_pylist() == [1, None]
    refused(i["floats"].call([pa_ints(1, 2)]), h.ERR_RETURN_TYPE,
            "returned double, which is not int64 without loss")
    refused(i["not_an_array"].call([pa_ints(1)]), h.ERR_RETURN_TYPE,
            "returned list, not a pyarrow Array")
    refused(i["short"].call([pa_ints(1, 2, 3)]), h.ERR_LENGTH, "returned 2 values for 3 rows")
    refused(i["raises"].call([pa_ints(1)]), h.ERR_RAISED, "KeyError: 'k'", -1)


def a_cancel_or_deadline_already_set_is_refused_before_the_batch_is_sent(env):
    rt, i = session(env, {"ident": ("ident", {})})
    inst = i["ident"]
    refused(inst.call([pa_ints(1)], cancel=1), h.ERR_CANCELLED, "cancelled before the batch was sent")
    rt.state.now_value = 200
    refused(inst.call([pa_ints(1)], deadline_ns=100), h.ERR_DEADLINE,
            "the deadline passed before the batch was sent")
    rt.state.now_value = 50
    assert inst.call_ok([pa_ints(1)], deadline_ns=100).to_pylist() == [1]
    assert inst.call_ok([pa_ints(2)]).to_pylist() == [2]
    assert env.trace.events("cancel_word") == []


def result_bytes_are_reserved_with_the_host_and_released_with_the_array(env):
    rt, i = session(env, {"ident": ("ident", {})})
    inst = i["ident"]
    assert inst.call_ok([pa_ints(*range(1000))]).to_pylist() == list(range(1000))
    gc.collect()
    st = rt.state
    assert st.reserved > 0 and st.reserved == st.released, (st.reserved, st.released)
    st.refuse_memory = True
    r = inst.call([pa_ints(1, 2)])
    assert r.status == h.ERR_OUT_OF_MEMORY and r.array is None, r.err
    st.refuse_memory = False
    assert inst.call_ok([pa_ints(5)]).to_pylist() == [5]


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
