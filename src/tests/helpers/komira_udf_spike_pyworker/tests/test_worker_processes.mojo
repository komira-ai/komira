# The worker processes behind the runtime library pyworker_zygote.so (a
# zygote started with posix_spawn, each context worker forked from it),
# through native/drive.c.
#
# What it proves, and the defect each part catches:
#   - describe through the library: MANAGED, features CONTAINS_CRASHES and
#     FORCED_STOP (and nothing else), descriptor version 1, CPU (a feature
#     claimed or dropped);
#   - one process per context: 4 engine threads see 4 distinct worker pids,
#     none the engine's (a pool that shares a worker between threads);
#   - who started them: every forked worker's parent is one zygote, which is
#     not the engine, and the zygote's parent is the engine (a library that
#     spawns its context workers, or an engine that forks);
#   - state per context: a module-global row counter counts 1..K in every
#     worker, so no interpreter is shared and the zygote ran no call before
#     forking (a shared worker: values run past K); the library's
#     accounting, logged at close_context, counts those calls, with the
#     worker's time inside the wait and the wait inside the call;
#   - the numpy batch function on 4 threads: every value right;
#   - a crash: the worker aborts on row 3; the call returns ERR_WORKER_CRASHED
#     with UDF_WORKER_CRASHED, and the next run, on new contexts, succeeds
#     (a hang, or a crash taken as OK);
#   - kept views: a numpy function keeps a view of each of its first 30
#     inputs (64k rows: the 8 MiB heap holds 15), then lets go; every value
#     is right, the engine logs that the heap filled and batches went inline,
#     and that it had room again once the views went (a full heap that blocks,
#     or slots never freed);
#   - shutdown: after close, no worker or zygote process is left.
#
# Mutants planted (on the earlier build with spawned workers too): a context
# worker spawned instead of forked: red (a worker's parent is the engine).
# proxy_channel.c drain_ring never freeing a released slot: red (the heap
# never has room again).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import (
    CLASS_MANAGED,
    ERR_WORKER_CRASHED,
    FEATURE_CONTAINS_CRASHES,
    FEATURE_FORCED_STOP,
)
from komira_udf_spike_pyworker.drive import Driver, pid_alive, self_pid
from komira_udf_spike_pyworker.report import call_split, check_ok, count_logs, num, per_thread, processes, text
from komira_udf_spike_pyworker.workloads import abort_on_3, counter, fahrenheit_np, fahrenheit_rows, keep_then_drop

comptime K = 50


def check_variant(v: String, mut seen: List[Int]) raises:
    var d = Driver("./pyworker_" + v + ".so")
    assert_equal(d.status(), 0, d.message())
    var me = self_pid()

    var r = d.run(counter("udf_worker_fixtures:worker_pid", 4, 3))
    check_ok(r, v + " worker_pid")
    assert_equal(num(r, "udf_class"), Int(CLASS_MANAGED))
    assert_equal(num(r, "features"), Int(FEATURE_CONTAINS_CRASHES | FEATURE_FORCED_STOP))
    assert_equal(num(r, "max_descriptor_version"), 1)
    assert_equal(num(r, "devices"), 1)
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
        assert_true(pp != me, "a forked worker's parent is the zygote, not the engine")
        if parent >= 0:
            assert_equal(pp, parent, "every forked worker has the one zygote as parent")
        parent = pp
    var z = processes(r, "zygote")
    assert_equal(len(z), 1, "one zygote below the engine")
    assert_equal(num(z[0], "pid"), parent)
    assert_equal(num(z[0], "ppid"), me, "the engine spawned the zygote")
    seen.append(parent)

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
    assert_equal(num(r, "status"), Int(ERR_WORKER_CRASHED), v + ": " + text(r, "message"))
    assert_true("UDF_WORKER_CRASHED" in text(r, "message"), text(r, "message"))
    r = d.run(fahrenheit_rows(1, 64, 3, 1))
    check_ok(r, v + " after a crash")

    r = d.run(keep_then_drop(65536, 40))
    check_ok(r, v + " keep_then_drop")
    assert_equal(count_logs(r, "heap full: batches go inline"), 1, v)
    assert_equal(count_logs(r, "heap has room again"), 1, v)
    d.close()


def main() raises:
    var seen = List[Int]()
    for v in ["zygote"]:
        check_variant(v, seen)
    assert_true(len(seen) >= 5, "4 context workers and the zygote seen")
    for p in seen:
        assert_true(not pid_alive(p), "worker " + String(p) + " outlived the runtime's shutdown")
    print("test_worker_processes: ok")
