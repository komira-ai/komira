# Native libraries called from several threads at once, on threads the Mojo
# runtime did not create (docs/design/udf_runtime_interface.md section 1.2:
# a native library's contexts run in parallel, one per engine thread; the
# Mojo library's runtime library must be shareable in one process).
#
# The loop (UdfRuntime.time_call_batch_threads, native/bench_loop.c of
# komira_udf_spike_abi) starts its threads in C, so the only Mojo code on
# them is the library's own. Each thread calls `double` on an instance in a
# context of its own and reads back every output.
#
# What it proves and the defect each part catches:
#   - four threads on the C library, four on the Mojo library, and two on
#     each at once: every call returns OK, every output is 2 * x for every
#     row, and every input array is released once (state shared across
#     contexts that corrupts a result; a library that cannot run on a thread
#     it did not create; a release lost under concurrency);
#   - the loop's own check can fail: the same run read against 3 * x
#     reports every call as a mismatch (a loop that never compares).
# Mutant planted: bench_loop.c's output check always passing: red ("the
# loop did not see outputs other than 3 * x").

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import SHAPE_SCALAR
from komira_udf_spike_abi.runtime import Handle, ThreadTimes, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import ColumnType, TYPE_INT64
from komira_udf_spike_native.code import code_set

comptime THREADS = 4
comptime ROWS = 1024
comptime ITERS = 200


def _spec(lib: String, root: String) raises -> UdfSpec:
    var s = UdfSpec(SHAPE_SCALAR, "double", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)])
    var code = code_set(lib, root)
    s.code_root = code.root
    s.code = code.objects.copy()
    return s^


def _instances(mut rt: UdfRuntime, specs: List[UdfSpec], first_slot: Int) raises -> List[Handle]:
    """One instance of specs[i % len(specs)] per thread, each in its own context."""
    var out = List[Handle]()
    for t in range(THREADS):
        var u = rt.load(specs[t % len(specs)])
        assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
        var ctx = rt.open_context(UInt32(first_slot + t))
        var inst = rt.open_instance(ctx.handle, u.handle)
        assert_true(inst.outcome.is_ok(), "open_instance: " + String(inst.outcome))
        out.append(inst.handle.copy())
    return out^


def _check(t: ThreadTimes, what: String) raises:
    assert_equal(t.failures, 0, what + ": failed calls")
    assert_equal(t.mismatches, 0, what + ": outputs other than 2 * x")
    assert_equal(t.released, THREADS * ITERS, what + ": input arrays released")


def main() raises:
    var tmp = getenv("TMPDIR")
    var rt = UdfRuntime.open("./native.so")
    var c = _spec("./native_c.so", tmp + "/code")
    var m = _spec("./native_mojo.so", tmp + "/code")

    var on_c = _instances(rt, [c.copy()], 0)
    _check(rt.time_call_batch_threads(on_c, ROWS, False, 2.0, 0.0, ITERS), "the C library")
    var wrong = rt.time_call_batch_threads(on_c, ROWS, False, 3.0, 0.0, ITERS)
    assert_equal(wrong.mismatches, THREADS * ITERS, "the loop did not see outputs other than 3 * x")

    var on_m = _instances(rt, [m.copy()], THREADS)
    _check(rt.time_call_batch_threads(on_m, ROWS, False, 2.0, 0.0, ITERS), "the Mojo library")

    var mixed = _instances(rt, [c.copy(), m.copy()], 2 * THREADS)
    _check(rt.time_call_batch_threads(mixed, ROWS, False, 2.0, 0.0, ITERS), "both libraries at once")
    # Handles are not closed: shutdown is the end of the process here, and
    # the release ledger is not what this test reads.
    rt.shutdown()
    print("test_threads: ok")
