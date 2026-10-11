# The runtime library's table entries the other tests do not reach, and what
# each build of the proxy starts (native/probe_table.c).
#
# What it proves, and the defect each part catches:
#   - validate and load refuse a spec before any message: NULL or short
#     (ERR_ABI), no argument or no result schema, a state type, args not a
#     struct, nine arguments, a result that is a struct, a type the
#     transport does not carry (ERR_UNSUPPORTED); eight arguments are
#     taken; with a NULL error, or one too short to write, only the status
#     comes back and nothing is written; every refusal's row and group are
#     -1 (a check deleted or loosened, a bound moved by one, an error
#     written past its struct);
#   - describe refuses NULL and a short struct, keeps a longer struct's
#     size, and gives every field (section 4.2), thread_affine 0 and no
#     memory_report for the proxy; the frame and aggregate entries refuse,
#     each releasing what it was given exactly once, with NULL inputs
#     taken, and outputs left released (an entry that leaks or double
#     releases its inputs);
#   - per build: the worker's native thread pools limited to one thread
#     (all but zygote_threads), the shared region mapped (all but pipe),
#     pyarrow imported (the pyarrow build only); a worker that exits with
#     status 3 is named as such where the engine is its parent; a lost
#     context refuses open_instance with ERR_INSTANCE_LOST; the proxy's
#     accounting is logged at level 3 at close_context only after calls; a
#     zygote's fork is logged at level 3; a call longer than 2^32 ns
#     answers (a build that starts the wrong worker, a wrong log level);
#   - before a batch the proxy refuses a deadline before the host's now and
#     a cancel already set, and takes a deadline equal to now; a deadline
#     the proxy's clock has not reached but the worker's has comes back
#     from the worker (the deadline crosses the transport intact); an
#     empty batch needs no values buffer, one row does;
#   - 17 UDFs in one context: the 17th refused; one UDF opened twice in a
#     context runs;
#   - init refuses a NULL, short or other-major host with ERR_ABI; a copy
#     of the library loaded by absolute path from another directory looks
#     for the interpreter in that directory.
#
# Mutants planted: the operator sweep of the pull request ran every mutant
# of proxy_runtime.c against this file (its table names each one this file
# kills).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import (
    ERR_ABI,
    ERR_CANCELLED,
    ERR_DEADLINE,
    ERR_INSTANCE_LOST,
    ERR_INTERNAL,
    ERR_LOAD,
    ERR_UNSUPPORTED,
)
from komira_udf_spike_python_worker.drive import probe_table
from komira_udf_spike_python_worker.report import num, text


def got(r: JsonValue, name: String, status: Int, reason: String, value: Int = 0) raises:
    var c = r.get(name)
    var said = name + ": status " + String(num(c, "status")) + ", value " + String(num(c, "value")) + ", "
    said += text(c, "message")
    assert_equal(num(c, "status"), status, said)
    assert_true(reason in text(c, "message"), said)
    assert_equal(num(c, "value"), value, said)


def main() raises:
    var r = probe_table("./pyworker_spawn.so", "specs")
    var a = Int(ERR_ABI)
    var u = Int(ERR_UNSUPPORTED)
    got(r, "spec_null", a, "spec struct_size is below this runtime's")
    got(r, "spec_short", a, "spec struct_size is below this runtime's")
    got(r, "spec_no_args", u, "a spec without argument or result schema")
    got(r, "spec_no_result", u, "a spec without argument or result schema")
    got(r, "spec_state", u, "a state type is for aggregates")
    got(r, "spec_args_not_struct", u, "args is not a struct of at most 8 fields")
    got(r, "spec_nine_args", u, "args is not a struct of at most 8 fields")
    got(r, "spec_eight_args", 0, "OK")
    got(r, "spec_result_struct", u, "the result is not one column")
    got(r, "spec_type_not_carried", u, "the worker transport carries no Arrow type 'tdD' (spike)")
    got(r, "load_result_type_not_carried", u, "the worker transport carries no Arrow type 'tdD' (spike)")
    got(r, "error_null", a, "")
    got(r, "error_short", a, "")

    r = probe_table("./pyworker_spawn.so", "entries")
    got(r, "describe_null", a, "")
    got(r, "describe_short", a, "")
    got(r, "describe", 0, "komira-test/python-worker cp313 0 5 3 0 2 1 1 0 2 1", 80)
    got(r, "frame_open", u, "frames are not in this runtime's shapes", 100)
    got(r, "frame_open_no_stream", u, "frames are not in this runtime's shapes")
    got(r, "frame_open_released_stream", u, "frames are not in this runtime's shapes")
    got(r, "frame_next", u, "frames are not in this runtime's shapes")
    got(r, "agg_open", u, "aggregates are not in this runtime's shapes")
    got(r, "agg_update", u, "aggregates are not in this runtime's shapes", 200)
    got(r, "agg_merge_no_ids", u, "aggregates are not in this runtime's shapes", 100)
    got(r, "agg_state", u, "aggregates are not in this runtime's shapes")
    got(r, "agg_finish", u, "aggregates are not in this runtime's shapes")
    got(r, "memory_report", 0, "")

    for v in ["spawn", "zygote", "pipe", "pyarrow", "zygote_threads"]:
        r = probe_table("./pyworker_" + v + ".so", "builds_long" if v == "spawn" else "builds")
        got(r, "blas_threads", 0, "OK", 0 if v == "zygote_threads" else 1)
        got(r, "shares_memory", 0, "OK", 0 if v == "pipe" else 1)
        got(r, "uses_pyarrow", 0, "OK", 1 if v == "pyarrow" else 0)
        got(r, "no_calls_no_stats", 0, "", 0)
        got(r, "calls_stats", 3, "", 1)
        var forks = v == "zygote" or v == "zygote_threads"
        got(r, "fork_log", 3 if forks else 0, "", 1 if forks else 0)
        got(r, "exit_3", Int(ERR_INSTANCE_LOST), "closed its control channel" if forks else "exited with status 3")
        got(r, "open_instance_lost", Int(ERR_INSTANCE_LOST), "UDF_WORKER_CRASHED")
        if v == "spawn":
            got(r, "call_over_2e32_ns", 0, "OK", 4400)

    r = probe_table("./pyworker_spawn.so", "deadline")
    got(r, "deadline_equal_now", 0, "OK")
    got(r, "deadline_one_ns_past", Int(ERR_DEADLINE), "the deadline passed before the batch")
    got(r, "deadline_in_worker", Int(ERR_DEADLINE), "the deadline passed at row 1", 1)
    got(r, "cancelled_before", Int(ERR_CANCELLED), "cancelled before the batch")
    got(r, "empty_no_values", 0, "OK")
    got(r, "one_row_no_values", Int(ERR_INTERNAL), "an argument has no values buffer")

    r = probe_table("./pyworker_spawn.so", "many")
    got(r, "seventeen_udfs", u, "open_instance: over 16 UDFs in one context (spike)", 16)
    got(r, "same_udf_twice", 0, "OK", 1)

    r = probe_table("./pyworker_spawn.so", "init")
    for k in ["init_host_null", "init_host_short", "init_host_major"]:
        got(r, k, a, "this runtime speaks ABI major 1")
    got(r, "init_copy", Int(ERR_LOAD), "init: the control worker: posix_spawn", 100)
    print("test_runtime_table: ok")
