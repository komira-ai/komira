# The worker processes behind the proxy runtime, on both start-ups:
# pyworker_spawn.so (each context worker posix_spawned) and
# pyworker_zygote.so (each forked from a zygote), through native/drive.c.
#
# What it proves, and the defect each part catches:
#   - describe through the proxy: SINGLE_THREAD, global_lock 1, transports
#     WORKER, hosting EMBEDDED, MANAGED, thread_affine 0 (the proxy's handles
#     serve any engine thread);
#   - one process per context: 4 engine threads see 4 distinct worker pids,
#     none the engine's (a pool that shares a worker between threads);
#   - who started them: a spawned worker's parent is the engine; every forked
#     worker's parent is one zygote, which is not the engine (a "zygote" build
#     that spawns, or an engine that forks);
#   - state per context: a module-global row counter counts 1..K in every
#     worker, so no interpreter is shared and the zygote ran no call before
#     forking (a shared worker: values run past K); the proxy's accounting,
#     logged at close_context, counts those calls, with the worker's time
#     inside the wait and the wait inside the call;
#   - the numpy batch function on 4 threads: every value right;
#   - a crash: the worker aborts on row 3; the call returns ERR_INSTANCE_LOST
#     with UDF_WORKER_CRASHED (a spawned worker's signal is named), and the
#     next run, on new contexts, succeeds (a hang, or a crash taken as OK);
#   - kept views: a numpy function keeps a view of each of its first 30
#     inputs (64k rows: the 8 MiB heap holds 15), then lets go; every value
#     is right, the engine logs that the heap filled and batches went inline,
#     and that it had room again once the views went (a full heap that blocks,
#     or slots never freed);
#   - shutdown: after close, no worker or zygote process is left.
#
# Mutants planted: proxy_runtime.c pw_open_context spawning in the zygote
# build instead of forking: red (a forked worker's parent is the engine).
# proxy_channel.c drain_ring never freeing a released slot: red (the heap
# never has room again).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import (
    CLASS_MANAGED,
    ERR_INSTANCE_LOST,
    HOSTING_EMBEDDED,
    SINGLE_THREAD,
    TRANSPORT_WORKER,
)
from komira_udf_spike_python_worker.drive import Driver, pid_alive, self_pid
from komira_udf_spike_python_worker.report import call_split, check_ok, count_logs, num, per_thread, processes, text
from komira_udf_spike_python_worker.workloads import abort_on_3, counter, fahrenheit_np, fahrenheit_rows, keep_then_drop

comptime K = 50


def check_variant(v: String, mut seen: List[Int]) raises:
    var d = Driver("./pyworker_" + v + ".so")
    assert_equal(d.status(), 0, d.message())
    var me = self_pid()

    var r = d.run(counter("udf_worker_fixtures:worker_pid", 4, 3))
    check_ok(r, v + " worker_pid")
    assert_equal(num(r, "threading"), Int(SINGLE_THREAD))
    assert_equal(num(r, "global_lock"), 1)
    assert_equal(num(r, "transports"), Int(TRANSPORT_WORKER))
    assert_equal(num(r, "hosting"), Int(HOSTING_EMBEDDED))
    assert_equal(num(r, "udf_class"), Int(CLASS_MANAGED))
    assert_equal(num(r, "thread_affine"), 0)
    var pids = List[Int]()
    for t in per_thread(r):
        var p = num(t, "first_value")
        assert_equal(num(t, "last_value"), p, v + ": one worker per context, every call")
        assert_true(p != me, v + ": a call ran in the engine")
        for q in pids:
            assert_true(q != p, v + ": two contexts share worker " + String(p))
        pids.append(p)
        seen.append(p)

    r = d.run(counter("udf_worker_fixtures:worker_ppid", 4, 3))
    check_ok(r, v + " worker_ppid")
    var parent = -1
    for t in per_thread(r):
        var pp = num(t, "first_value")
        if v == "spawn":
            assert_equal(pp, me, "a spawned worker's parent is the engine")
        else:
            assert_true(pp != me, "a forked worker's parent is the zygote, not the engine")
            if parent >= 0:
                assert_equal(pp, parent, "every forked worker has the one zygote as parent")
            parent = pp
    if v == "zygote":
        var z = processes(r, "zygote")
        assert_equal(len(z), 1, "one zygote below the engine")
        assert_equal(num(z[0], "pid"), parent)
        assert_equal(num(z[0], "ppid"), me, "the engine spawned the zygote")
        seen.append(parent)
    else:
        assert_equal(len(processes(r, "control")), 1, "one control worker below the engine")
        seen.append(num(processes(r, "control")[0], "pid"))

    r = d.run(counter("udf_fixtures:call_counter", 4, K))
    check_ok(r, v + " call_counter")
    for t in per_thread(r):
        assert_true(t.get("increasing").as_bool(), v)
        assert_equal(num(t, "first_value"), 1, v + ": the zygote ran no call before forking")
        assert_equal(num(t, "last_value"), K + 2, v + ": first call, one warm-up, K measured")
    var cs = call_split(r)
    assert_equal(cs.calls, 4 * (K + 2), v + ": the proxy counted every call")
    assert_true(cs.worker_ns > 0 and cs.worker_ns <= cs.wait_ns and cs.wait_ns <= cs.call_ns, v)

    r = d.run(fahrenheit_np(4, 4096, 10, 1))
    check_ok(r, v + " fahrenheit_np")

    r = d.run(abort_on_3(8))
    assert_equal(num(r, "status"), Int(ERR_INSTANCE_LOST), v + ": " + text(r, "message"))
    assert_true("UDF_WORKER_CRASHED" in text(r, "message"), text(r, "message"))
    if v == "spawn":
        assert_true("signal 6" in text(r, "message"), text(r, "message"))
    r = d.run(fahrenheit_rows(1, 64, 3, 1))
    check_ok(r, v + " after a crash")

    r = d.run(keep_then_drop(65536, 40))
    check_ok(r, v + " keep_then_drop")
    assert_equal(count_logs(r, "heap full: batches go inline"), 1, v)
    assert_equal(count_logs(r, "heap has room again"), 1, v)
    d.close()


def main() raises:
    var seen = List[Int]()
    for v in ["spawn", "zygote"]:
        check_variant(v, seen)
    assert_true(len(seen) >= 10)
    for p in seen:
        assert_true(not pid_alive(p), "worker " + String(p) + " outlived the runtime's shutdown")
    print("test_worker_processes: ok")
