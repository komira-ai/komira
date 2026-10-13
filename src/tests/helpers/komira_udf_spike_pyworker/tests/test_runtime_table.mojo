# The runtime library's table entries the other tests do not reach, and what
# each build of it starts (native/probe_table.c).
#
# What it proves, and the defect each part catches:
#   - validate and load refuse a spec before any message: NULL or short
#     (ERR_ABI), no argument or no result schema, a state type, args not a
#     struct, 65 arguments, a result that is a struct, a type the
#     transport does not carry (ERR_UNSUPPORTED); 64 arguments are
#     taken; with a NULL error, or one too short to write, only the status
#     comes back and nothing is written; every refusal's row and group are
#     -1 (a check deleted or loosened, a bound moved by one, an error
#     written past its struct);
#   - describe refuses NULL and a short struct, keeps a longer struct's
#     size, and gives every field (section 4.2: class MANAGED, features
#     CONTAINS_CRASHES and FORCED_STOP, descriptor version 1) and no
#     memory_report for the library; the frame and aggregate entries refuse,
#     each releasing what it was given exactly once, with NULL inputs
#     taken, and outputs left released (an entry that leaks or double
#     releases its inputs);
#   - per build (zygote, pyarrow, zygote_threads): the worker's native
#     thread pools limited to one thread (all but zygote_threads), one
#     shared region mapped (a forked worker has dropped the zygote's),
#     pyarrow imported (the pyarrow build only); a worker that exits with
#     status 3 during a call is ERR_WORKER_CRASHED (user code ran); the lost
#     context refuses open_instance with
#     ERR_INSTANCE_LOST; the library's accounting is logged at level 3 at
#     close_context only after calls; the zygote's fork is logged at level
#     3; a call longer than 2^32 ns answers (a build that starts the wrong
#     worker, a wrong log level);
#   - before a batch the library refuses a deadline before the host's now
#     and a cancel already set, and takes a deadline equal to now; a
#     deadline the library's clock has not reached but the worker's has
#     comes back from the worker (the deadline crosses the transport
#     intact); an empty batch needs no values buffer, one row does;
#   - with a deadline set the worker reads the clock after every row: a
#     deadline that passes during row 1 of 3 ends the call with
#     ERR_DEADLINE at row 2 (an adapter that reads the clock only after
#     row 0 and every 1024 rows runs on and answers OK), and one that
#     passes during the last row ends nothing: OK (an adapter that reports
#     row n, past the batch);
#   - 17 UDFs in one context: the 17th refused; one UDF opened twice in a
#     context runs;
#   - init refuses a NULL, short or other-major host with ERR_ABI; a copy
#     of the library loaded by absolute path from another directory looks
#     for the zygote's interpreter in that directory;
#   - a context worker killed while idle: the next open_instance, which runs
#     no user code, is ERR_INSTANCE_LOST, and so is a call on the old
#     instance (a library that calls every loss a crash);
#   - a normal shutdown after a context and a call takes under a second (an
#     engine that does not reap the zygote it started waits out its 2 s
#     fallback kill);
#   - the zygote ends during a LOAD (a module that exits the process that
#     imports it): load is ERR_WORKER_CRASHED naming the exit status (the
#     import is user code; the engine is the zygote's parent and reaps it),
#     a second load and a validate are ERR_INSTANCE_LOST (refused at once:
#     no user code ran for them), and
#     shutdown takes under a second (an engine that does not reap its own
#     child, or names it wrongly).
#
# Mutants planted: komira_udf_pyrt.py reading the clock after row 0 and then
# every 1024 rows (as it did before): red on deadline_after_row_1 only (the
# conformance case deadline_reached_during_call stays green on this runtime:
# the worker compares its own monotonic clock, and slow_loop's first row
# already passes the deadline). komira_udf_pyrt.py without `i + 1 < n`: red
# on deadline_in_last_row. The pull request's sweep ran every mutant of
# proxy_runtime.c against this file.

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import (
    ERR_ABI,
    ERR_CANCELLED,
    ERR_DEADLINE,
    ERR_HOST_CONTRACT,
    ERR_INSTANCE_LOST,
    ERR_WORKER_CRASHED,
    ERR_INTERNAL,
    ERR_LOAD,
    ERR_UNSUPPORTED,
)
from komira_udf_spike_pyworker.drive import probe_table
from komira_udf_spike_pyworker.report import num, text


def got(r: JsonValue, name: String, status: Int, reason: String, value: Int = 0) raises:
    var c = r.get(name)
    var said = name + ": status " + String(num(c, "status")) + ", value " + String(num(c, "value")) + ", "
    said += text(c, "message")
    assert_equal(num(c, "status"), status, said)
    assert_true(reason in text(c, "message"), said)
    assert_equal(num(c, "value"), value, said)


def main() raises:
    var r = probe_table("./pyworker_zygote.so", "specs")
    var a = Int(ERR_ABI)
    var u = Int(ERR_UNSUPPORTED)
    got(r, "spec_null", a, "spec struct_size is below this runtime's")
    got(r, "spec_short", a, "spec struct_size is below this runtime's")
    got(r, "spec_no_args", u, "a spec without argument or result schema")
    got(r, "spec_no_result", u, "a spec without argument or result schema")
    got(r, "spec_state", u, "a state type is for aggregates")
    got(r, "spec_args_not_struct", u, "args is not a struct of at most 64 fields")
    got(r, "spec_65_args", u, "args is not a struct of at most 64 fields")
    got(r, "spec_64_args", 0, "OK")
    got(r, "spec_result_struct", u, "the result is not one column")
    got(r, "spec_type_not_carried", u, "the worker transport carries no Arrow type 'tdD' (spike)")
    got(r, "load_result_type_not_carried", u, "the worker transport carries no Arrow type 'tdD' (spike)")
    got(r, "error_null", a, "")
    got(r, "error_short", a, "")

    r = probe_table("./pyworker_zygote.so", "entries")
    got(r, "describe_null", a, "")
    got(r, "describe_short", a, "")
    got(r, "describe", 0, "komira-test/python-worker cp313 1 5 1 6 2", 64)
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

    for v in ["zygote", "pyarrow", "zygote_threads"]:
        r = probe_table("./pyworker_" + v + ".so", "builds_long" if v == "zygote" else "builds")
        got(r, "blas_threads", 0, "OK", 0 if v == "zygote_threads" else 1)
        got(r, "shares_memory", 0, "OK", 1)
        got(r, "uses_pyarrow", 0, "OK", 1 if v == "pyarrow" else 0)
        got(r, "no_calls_no_stats", 0, "", 0)
        got(r, "calls_stats", 3, "", 1)
        got(r, "fork_log", 3, "", 1)
        got(r, "exit_3", Int(ERR_WORKER_CRASHED), "closed its control channel")
        got(r, "open_instance_lost", Int(ERR_INSTANCE_LOST), "UDF_WORKER_CRASHED")
        if v == "zygote":
            got(r, "call_over_2e32_ns", 0, "OK", 4400)

    r = probe_table("./pyworker_zygote.so", "deadline")
    got(r, "deadline_equal_now", 0, "OK")
    got(r, "deadline_one_ns_past", Int(ERR_DEADLINE), "the deadline passed before the batch")
    got(r, "deadline_in_worker", Int(ERR_DEADLINE), "the deadline passed at row 1", 1)
    got(r, "cancelled_before", Int(ERR_CANCELLED), "cancelled before the batch")
    got(r, "empty_no_values", 0, "OK")
    got(r, "one_row_no_values", Int(ERR_HOST_CONTRACT), "an argument has no values buffer")
    got(r, "deadline_after_row_1", Int(ERR_DEADLINE), "the deadline passed at row 2", 1)
    got(r, "deadline_in_last_row", 0, "OK")

    r = probe_table("./pyworker_zygote.so", "many")
    got(r, "seventeen_udfs", u, "open_instance: over 16 UDFs in one context (spike)", 16)
    got(r, "same_udf_twice", 0, "OK", 1)

    r = probe_table("./pyworker_zygote.so", "init")
    for k in ["init_host_null", "init_host_short", "init_host_major"]:
        got(r, k, a, "this runtime speaks ABI major 1")
    got(r, "init_copy", Int(ERR_LOAD), "init: the zygote: posix_spawn", 100)

    # A context worker lost while idle: the next open_instance runs no user
    # code, so it is ERR_INSTANCE_LOST, not ERR_WORKER_CRASHED; so is a call
    # on the old instance.
    r = probe_table("./pyworker_zygote.so", "lost_idle")
    got(r, "lost_idle_call", 0, "OK", 0)
    got(r, "lost_idle_open_instance", Int(ERR_INSTANCE_LOST), "UDF_WORKER_CRASHED", 0)
    got(r, "lost_idle_call_after", Int(ERR_INSTANCE_LOST), "", 0)

    # A normal shutdown is prompt: the zygote exits on SHUTDOWN and is
    # reaped at once (the fallback kill comes only after 2 s).
    r = probe_table("./pyworker_zygote.so", "shutdown")
    got(r, "shutdown_call", 0, "OK", 0)
    var sd_ms = num(r.get("shutdown_ms"), "value")
    assert_true(sd_ms < 1000, "a normal shutdown took " + String(sd_ms) + " ms")

    # The zygote ends during a LOAD: named by its exit status (the engine is
    # its parent and reaps it), every later request refused at once, and
    # shutdown prompt.
    r = probe_table("./pyworker_zygote.so", "zygote_exit")
    got(r, "zygote_exit_load", Int(ERR_WORKER_CRASHED), "UDF_WORKER_CRASHED: worker ", 0)
    got(r, "zygote_exit_load", Int(ERR_WORKER_CRASHED), " exited with status 3", 0)
    got(r, "zygote_exit_load_again", Int(ERR_INSTANCE_LOST), " exited with status 3", 0)
    got(r, "zygote_exit_validate", Int(ERR_INSTANCE_LOST), " exited with status 3", 0)
    var ms = num(r.get("zygote_exit_shutdown"), "value")
    assert_true(ms < 1000, "shutdown after the zygote ended took " + String(ms) + " ms")
    print("test_runtime_table: ok")
