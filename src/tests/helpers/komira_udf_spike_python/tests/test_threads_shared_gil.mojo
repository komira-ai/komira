# N > 1 engine threads on the shared-interpreter baseline,
# python_shared_gil.so, through the engine loop (native/engine_loop.c).
#
# What it proves, and the defect each part catches:
#   - 4 threads x 20 batches of the numpy batch function and of the per-row
#     function: every value right, calls == batches, every argument array
#     released (each thread enters the one interpreter through its own thread
#     state; a thread state shared or entered off its thread would crash or
#     corrupt);
#   - state is shared: the module-global row counter runs past K on some
#     thread, because every context is the same interpreter (the reason the
#     design rejects this mode for state, pinned so the two builds differ);
#   - the one lock: 4 threads spinning 200 ms of CPU each keep CPU time over
#     wall time at most 1.3 (a baseline that is not serialized would measure
#     something else than it says).
#
# Mutant planted: python_runtime.c opening (and closing) every context of
# the shared build as a sub-interpreter: red (numpy cannot load in a
# sub-interpreter, so fahrenheit_np fails on every thread).

from std.testing import assert_equal, assert_true

from komira_udf_spike_python.engine import CAP_GLOBAL_LOCK, Engine, RunReport
from komira_udf_spike_python.workloads import call_counter, fahrenheit_np, fahrenheit_rows, spin


def _all_ok(r: RunReport, what: String) raises:
    assert_equal(r.status, 0, what + ": " + r.message)
    for i in range(len(r.threads)):
        ref t = r.threads[i]
        assert_equal(t.status, 0, what + ": thread " + String(i) + ": " + t.message)
        assert_equal(t.exported, t.released, what + ": thread " + String(i) + " arrays exported vs released")


def main() raises:
    var e = Engine("./python_shared_gil.so")
    assert_equal(e.status(), 0, e.message())
    assert_equal(e.cap(CAP_GLOBAL_LOCK), 1)

    for w in [fahrenheit_np(4, 1024, 2, 20), fahrenheit_rows(4, 1024, 2, 20)]:
        var r = e.run(w)
        _all_ok(r, w.entry)
        for t in r.threads:
            assert_equal(t.calls, 22, w.entry)
            assert_equal(t.bad_values, 0, w.entry)

    var k = 50
    var r = e.run(call_counter(4, k))
    _all_ok(r, "call_counter")
    var past = 0
    for t in r.threads:
        assert_true(t.increasing)
        if t.last_value > Int64(k + 1):
            past += 1
    assert_true(past > 0, "one shared interpreter: some thread's counter runs past " + String(k + 1))

    r = e.run(spin(4, 200))
    _all_ok(r, "spin")
    var ratio = Float64(r.cpu_user_ns + r.cpu_sys_ns) / Float64(r.wall_ns)
    print("spin: cpus", r.cpus, "wall ms", r.wall_ns // 1_000_000, "ratio", ratio)
    assert_true(ratio <= 1.3, "CPU/wall " + String(ratio) + " above 1.3 under one GIL")
    print("test_threads_shared_gil: ok")
