# N > 1 engine threads on python_subinterp.so, through the engine loop
# (native/engine_loop.c: one pthread per engine thread, each opening its own
# context and instance and calling only those).
#
# What it proves, and the defect each part catches:
#   - 4 threads x 20 batches of 1024 rows of the per-row function: every
#     output value right, calls == batches (no per-row crossing), every
#     exported argument array released (a race between contexts; a context
#     entered from the wrong thread; a leak);
#   - state per context: a module-global row counter counts 1..K on every
#     thread, so each thread's interpreter has its own copy of the module (a
#     runtime that shares one interpreter, or one module, across contexts);
#   - parallelism (design section 6.3): 4 threads each spin 200 ms of CPU in
#     user code; process CPU time over the wall time of that phase must be at
#     least 0.6 x min(4, CPUs) (a lock shared across engine threads: under
#     one GIL the ratio is about 1);
#   - the engine loop names no runtime and no language (it drives any
#     runtime library through the table).
#
# Mutant planted: python_runtime.c's open_context and close_context treating
# every context of the sub-interpreter build as a thread state of the main
# interpreter (one interpreter for all, describe unchanged): red (a
# thread's counter starts past 1 or ends past K: other threads' rows are
# counted in the same module).
# The shared conformance suite stays green under it: its cases are
# stateless, so this case is where a shared interpreter shows.

from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_python.engine import CAP_GLOBAL_LOCK, Engine, RunReport
from komira_udf_spike_python.workloads import call_counter, fahrenheit_rows, spin


def _all_ok(r: RunReport, what: String) raises:
    assert_equal(r.status, 0, what + ": " + r.message)
    for i in range(len(r.threads)):
        ref t = r.threads[i]
        assert_equal(t.status, 0, what + ": thread " + String(i) + ": " + t.message)
        assert_equal(t.exported, t.released, what + ": thread " + String(i) + " arrays exported vs released")


def _neutral() raises:
    for path in ["native/engine_loop.c", "engine.mojo"]:
        var text = String("")
        with open(path, "r") as f:
            text = f.read().lower()
        for word in ["python", "numpy", "komira-test/", "node"]:
            assert_false(word in text, path + " names '" + word + "'")


def main() raises:
    _neutral()
    var e = Engine("./python_subinterp.so")
    assert_equal(e.status(), 0, e.message())
    assert_equal(e.cap(CAP_GLOBAL_LOCK), 0)

    var r = e.run(fahrenheit_rows(4, 1024, 2, 20))
    _all_ok(r, "fahrenheit_rows")
    for t in r.threads:
        assert_equal(t.calls, 22)
        assert_equal(t.bad_values, 0)
        assert_equal(t.rows, 22 * 1024)

    var k = 50
    r = e.run(call_counter(4, k))
    _all_ok(r, "call_counter")
    for i in range(len(r.threads)):
        ref t = r.threads[i]
        assert_equal(t.first_value, 1, "thread " + String(i) + ": its interpreter's first row")
        assert_equal(t.last_value, Int64(k + 1), "thread " + String(i) + ": rows its own interpreter saw")
        assert_true(t.increasing)

    r = e.run(spin(4, 200))
    _all_ok(r, "spin")
    var cpu = Float64(r.cpu_user_ns + r.cpu_sys_ns)
    var ratio = cpu / Float64(r.wall_ns)
    var lanes = Float64(min(Int64(4), r.cpus))
    print("spin: cpus", r.cpus, "wall ms", r.wall_ns // 1_000_000, "cpu ms", Int(cpu) // 1_000_000, "ratio", ratio)
    assert_true(r.cpus >= 2, "the parallelism case needs 2 CPUs; this action has " + String(r.cpus))
    assert_true(ratio >= 0.6 * lanes, "CPU/wall " + String(ratio) + " below 0.6 x " + String(lanes))
    print("test_threads_subinterp: ok")
