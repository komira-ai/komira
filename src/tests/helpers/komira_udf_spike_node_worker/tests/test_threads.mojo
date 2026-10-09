# N > 1 engine threads on node_worker.so, through the engine loop
# (native/engine_loop.c: one pthread per engine thread, each opening its own
# context, so its own worker process, and calling only its own instance).
#
# What it proves, and the defect each part catches:
#   - 4 threads of the per-row TypeScript function over 1024-row batches:
#     every output value right; each worker served exactly the batches its
#     thread sent (calls == batches: no per-row crossing, and no thread's
#     batch served by another's worker); four distinct worker processes;
#     every exported argument array released (a race between contexts; a
#     leak; one worker shared by every thread);
#   - parallelism (design section 6.3): 4 threads each call a function that
#     spins 200 ms per call; the workers' CPU time over the wall time must
#     be at least 0.6 x min(4, CPUs) (a lock shared across engine threads:
#     under one lock the ratio is about 1);
#   - the engine loop names no runtime and no language (it drives any
#     runtime library through the table).
#
# Mutant planted: proxy.c's call_batch taking one process-wide mutex around
# the request (a lock shared across engine threads): red (CPU/wall about 1
# on the spin case).

from std.testing import assert_equal, assert_false, assert_true

from komira_json import JsonValue, parse_json_value

from komira_udf_spike_abi.contract import SHAPE_SCALAR
from komira_udf_spike_node_worker.engine import CHECK_AFFINE, CHECK_ROWS, Workload, run

comptime LIB = "./node_worker.so"


def _neutral() raises:
    for path in ["native/engine_loop.c", "engine.mojo"]:
        var text = String("")
        with open(path, "r") as f:
            text = f.read().lower()
        for word in ["node", "javascript", "typescript", "python", "komira-test/"]:
            assert_false(word in text, path + " names '" + word + "'")


def _ok(r: JsonValue, what: String) raises:
    var why = r.get("message").as_string() if r.has("message") else String("")
    assert_equal(r.get("status").as_int64(), 0, what + ": " + why)
    var th = r.get("per_thread")
    for i in range(th.array_len()):
        var t = th.element_at(i)
        assert_equal(t.get("status").as_int64(), 0, what + ": thread " + String(i) + ": " + t.get("message").as_string())
    assert_equal(r.get("exported").as_int64(), r.get("released").as_int64(), what + ": arrays exported vs released")


def main() raises:
    _neutral()
    var r = parse_json_value(
        run(LIB, Workload("fahrenheit.mjs#fahrenheitRow", SHAPE_SCALAR, "g", 4, 1024, 20, 20, 0, CHECK_AFFINE, 1.8, 32.0))
    )
    _ok(r, "fahrenheitRow")
    var th = r.get("per_thread")
    assert_equal(th.array_len(), 4)
    var pids = List[Int64]()
    for i in range(4):
        var t = th.element_at(i)
        assert_equal(t.get("bad_values").as_int64(), 0, "thread " + String(i) + " values")
        var batches = 1 + t.get("warm_batches").as_int64() + Int64(t.get("samples_ns").array_len())
        assert_equal(t.get("worker_calls").as_int64(), batches, "thread " + String(i) + ": calls == batches")
        assert_equal(t.get("worker_rows").as_int64(), batches * 1024, "thread " + String(i) + ": rows")
        var pid = t.get("pid").as_int64()
        assert_true(pid > 0, "thread " + String(i) + " names its worker")
        for p in pids:
            assert_true(p != pid, "two threads share worker " + String(pid))
        pids.append(pid)

    r = parse_json_value(run(LIB, Workload("fixtures.mjs#spin", SHAPE_SCALAR, "l", 4, 1, 0, 2, 0, CHECK_ROWS, 200.0, 0.0)))
    _ok(r, "spin")
    var cpus = r.get("cpus").as_int64()
    var wall = Float64(r.get("wall_ns").as_int64())
    var cpu = 0.0
    th = r.get("per_thread")
    for i in range(th.array_len()):
        cpu += Float64(th.element_at(i).get("worker_cpu_ns").as_int64())
    var ratio = cpu / wall
    var lanes = Float64(min(Int64(4), cpus))
    print("spin: cpus", cpus, "wall ms", Int(wall) // 1_000_000, "worker cpu ms", Int(cpu) // 1_000_000, "ratio", ratio)
    assert_true(cpus >= 2, "the parallelism case needs 2 CPUs; this action has " + String(cpus))
    assert_true(ratio >= 0.6 * lanes, "CPU/wall " + String(ratio) + " below 0.6 x " + String(lanes))
    print("test_threads: ok")
