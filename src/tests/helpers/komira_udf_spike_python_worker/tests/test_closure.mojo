# The VALUE closure (producer/make_closure.py: a function of __main__ over a
# 16 MiB numpy model, cloudpickled) behind the worker transport, loaded once
# in a zygote and forked (pyworker_zygote.so) or loaded by every spawned
# worker (pyworker_spawn.so), through native/drive.c.
#
# What it proves, and the defect each part catches:
#   - the payload holds the model: its size is at least the model's (a
#     function pickled by reference, which would ship no model; the producer
#     refuses that too, failing :closure's build);
#   - values: 4 engine threads, x * 1.8 + 32 with the 1.8 read from the model
#     (a closure that lost its captured object);
#   - the digest: the same name over different bytes is refused at load with
#     ERR_CODE_DIGEST, on both start-ups (code run without its check);
#   - the model's pages: each spawned worker holds its own copy (USS at least
#     the model); each forked worker's USS is at least the model's size below
#     every spawned worker's, so the model is not among its private pages
#     (a zygote that loads nothing before it forks). A forked worker's USS is
#     not small: CPython's reference counts dirty the inherited object heap;
#     the model's buffer is apart from it and stays shared;
#   - the fork: the zygote logs its thread count and any warning os.fork
#     raised. With native thread pools limited to one thread it forks with
#     one thread. Unlimited, numpy's BLAS pool is running at the fork (more
#     than one thread when the action has more than one CPU), and CPython 3.13
#     raises no warning for it: the warning cannot be relied on to see native
#     threads (pinned, so a change shows).
#
# Mutants planted: proxy_runtime.c remote_udf sending LOAD to every forked
# worker as well (each deserializes its own model): red (a forked worker's
# USS holds the model). komira_udf_pyworker.py's payload() skipping the
# sha256 comparison: red (the tampered payload loads).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value
from komira_udf_spike_abi.contract import ERR_CODE_DIGEST
from komira_udf_spike_python_worker.drive import Driver
from komira_udf_spike_python_worker.report import check_ok, logs, num, processes, text
from komira_udf_spike_python_worker.workloads import closure

comptime MODEL_BYTES = 16 * 1024 * 1024


def fork_log(r: JsonValue) raises -> String:
    for line in logs(r):
        if "forked worker" in line:
            return line
    return ""


def fork_threads(line: String) raises -> Int:
    """The thread count in a fork log line."""
    var key = "zygote threads at fork "
    var at = line.find(key)
    if at < 0:
        raise Error("no thread count in: " + line)
    var n = 0
    var b = line.as_bytes()
    var i = at + key.byte_length()
    while i < len(b) and b[i] >= 0x30 and b[i] <= 0x39:
        n = n * 10 + Int(b[i] - 0x30)
        i += 1
    return n


def main() raises:
    var info: JsonValue
    with open("closure/info.json", "r") as f:
        info = parse_json_value(f.read())
    var sha = text(info, "sha256")
    assert_equal(num(info, "model_bytes"), MODEL_BYTES)
    assert_true(num(info, "payload_bytes") >= MODEL_BYTES, "the closure was pickled by value, model included")

    var spawned_uss = -1
    for v in ["spawn", "zygote"]:
        var d = Driver("./pyworker_" + v + ".so")
        assert_equal(d.status(), 0, d.message())
        var r = d.run(closure(4, 8192, 5, "closure/good", sha, 1))
        check_ok(r, v + " closure")
        print(v, "processes:", r.get("processes").serialize())
        var workers = processes(r, "context")
        assert_equal(len(workers), 4, v + ": one context worker per engine thread")
        for w in workers:
            var uss = num(w, "uss_kb") * 1024
            print(v, "worker", num(w, "pid"), "pss_kb", num(w, "pss_kb"), "uss_kb", num(w, "uss_kb"))
            if v == "spawn":
                assert_true(uss >= MODEL_BYTES, "a spawned worker holds its own model: USS " + String(uss))
                if spawned_uss < 0 or uss < spawned_uss:
                    spawned_uss = uss
            else:
                assert_true(
                    uss + MODEL_BYTES <= spawned_uss,
                    "a forked worker shares the zygote's model: USS " + String(uss) + ", spawned "
                    + String(spawned_uss),
                )
        if v == "zygote":
            var line = fork_log(r)
            print(line)
            assert_true("zygote threads at fork 1; warning: none" in line, line)
        r = d.run(closure(1, 8, 1, "closure/bad", sha, 1))
        assert_equal(num(r, "status"), Int(ERR_CODE_DIGEST), v + ": " + text(r, "message"))
        assert_true("do not match" in text(r, "message"), text(r, "message"))
        d.close()

    var d = Driver("./pyworker_zygote_threads.so")
    assert_equal(d.status(), 0, d.message())
    var r = d.run(closure(1, 8192, 3, "closure/good", sha, 1))
    check_ok(r, "zygote_threads closure")
    var fline = fork_log(r)
    print("native thread pools unlimited:", fline, "cpus", num(r, "cpus"))
    if num(r, "cpus") > 1:
        assert_true(fork_threads(fline) > 1, "numpy's BLAS threads run at the fork: " + fline)
    assert_true("warning: none" in fline, "os.fork raised a warning: " + fline)
    # Not closed here: dropping the Driver shuts the runtime down.
    print("test_closure: ok")
