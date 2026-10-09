# Calls through a runtime library's table that the engine loop does not
# make (native/probe_calls.c), on the worker builds.
#
# What it proves, and the defect each part catches:
#   - two arguments whose children are slices at different offsets (13 and
#     3), each with a null, one null count given and one left -1: every
#     value and both nulls of pair(x, y) = x * 1000 + y, twice, on the
#     spawn, zygote, pipe and pyarrow builds (an engine writer that takes
#     every column's offset from the first, or re-bases a bitmap wrongly;
#     the pyarrow build also reads the two-column batch with pyarrow);
#   - a UDF loaded after a context was opened, called in that context and
#     in one opened after the load, on the zygote and spawn builds (a
#     forked worker handed an id the zygote assigned after the fork, which
#     it never loaded); then, in that context, a UDF unloaded and another
#     loaded: the second one runs (a context that finds a UDF by its
#     handle's address, which the next load may reuse);
#   - refusals before any message: a child shorter than the batch, a child
#     count other than the signature's, a struct offset, a negative length,
#     three buffers, no values buffer, a negative child offset, args not on
#     the CPU, a call struct too small. Each with its status and reason,
#     `args` moved and released once; then a good call on the same context
#     (a check deleted: the engine reads past a child's buffers);
#   - kills, on the spawn, pipe and zygote builds: a call deaf to cancel and
#     to the clock (SIGUSR1 blocked, sleeping 20 s) is cancelled 300 ms in;
#     the worker is killed 2 s after the cancel reached it, and the call
#     returns ERR_CANCELLED in 2 .. 12 s. In a new context the same call
#     past a deadline 300 ms away is killed 2 s after it: ERR_DEADLINE in
#     2 .. 12 s. After each the next call on that context is
#     ERR_INSTANCE_LOST, its worker is gone after close_context, and a new
#     context still serves (an engine that waits on a worker that ignores
#     the cancel, section 5.2: "If the worker has not answered after a grace
#     period, the engine kills it").
#
# Mutants planted: ipc_codec.c pyw_ipc_batch_write taking every column's
# offset from the first column: red on two_args. proxy_runtime.c remote_udf
# treating every UDF as inherited by a forked worker: red on
# late_in_open_context (zygote). proxy_runtime.c remote_udf finding a
# context's UDF by its handle's address (as the first version did): red on
# after_unload. proxy_runtime.c args_layout_error without
# the short-child check: red on short_child. proxy_channel.c await_reply
# without the cancel kill: red on cancel_kill (about 20 s).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import (
    ERR_ABI,
    ERR_CANCELLED,
    ERR_DEADLINE,
    ERR_INSTANCE_LOST,
    ERR_INTERNAL,
    ERR_UNSUPPORTED,
)
from komira_udf_spike_python_worker.drive import probe_calls
from komira_udf_spike_python_worker.report import num, text


def ok(r: JsonValue, name: String, what: String) raises:
    var c = r.get(name)
    assert_equal(num(c, "status"), 0, what + " " + name + ": " + text(c, "message"))
    assert_equal(num(c, "value"), 0, what + " " + name + ": wrong values, or args not released once")


def refused(r: JsonValue, name: String, status: Int32, reason: String) raises:
    var c = r.get(name)
    assert_equal(num(c, "status"), Int(status), name + ": " + text(c, "message"))
    assert_true(reason in text(c, "message"), name + ": " + text(c, "message"))
    assert_equal(num(c, "value"), 1, name + ": args moved and released once")


def killed(r: JsonValue, name: String, status: Int32, what: String) raises:
    var c = r.get(name)
    var ms = num(c, "value")
    var said = what + " " + name + ": status " + String(num(c, "status")) + " after " + String(ms) + " ms: "
    said += text(c, "message")
    assert_equal(num(c, "status"), Int(status), said)
    assert_true("killed" in text(c, "message"), said)
    assert_true(ms >= 2000 and ms <= 12000, said)
    var next = r.get(name + "_next")
    assert_equal(num(next, "status"), Int(ERR_INSTANCE_LOST), what + ": " + text(next, "message"))
    assert_equal(num(next, "value"), 2, what + ": both calls' args released")
    var gone = r.get(name + "_worker_gone")
    assert_equal(num(gone, "status"), 0, what + ": the worker's pid was read")
    assert_equal(text(gone, "message"), "gone", what + ": the killed worker outlived close_context")


def main() raises:
    for v in ["spawn", "zygote", "pipe", "pyarrow"]:
        var t = probe_calls("./pyworker_" + v + ".so", "two_args")
        ok(t, "two_args", v)
        ok(t, "two_args_again", v)

    for v in ["zygote", "spawn"]:
        var l = probe_calls("./pyworker_" + v + ".so", "late_load")
        assert_equal(num(l.get("before"), "status"), 0, v + ": " + text(l.get("before"), "message"))
        ok(l, "late_in_open_context", v)
        ok(l, "late_in_new_context", v)
        ok(l, "after_unload", v)

    var r = probe_calls("./pyworker_spawn.so", "refusals")
    refused(r, "short_child", ERR_INTERNAL, "an argument is shorter than the batch")
    refused(r, "child_count", ERR_INTERNAL, "child count other than the bound signature's")
    refused(r, "struct_offset", ERR_INTERNAL, "nonzero offset")
    refused(r, "negative_length", ERR_INTERNAL, "negative length")
    refused(r, "three_buffers", ERR_INTERNAL, "not a fixed-width primitive")
    refused(r, "no_values", ERR_INTERNAL, "no values buffer")
    refused(r, "negative_offset", ERR_INTERNAL, "an argument has a negative offset")
    refused(r, "not_cpu", ERR_UNSUPPORTED, "not on the CPU")
    refused(r, "call_struct_size", ERR_ABI, "call struct_size")
    ok(r, "after_refusals", "spawn")

    for v in ["spawn", "pipe", "zygote"]:
        r = probe_calls("./pyworker_" + v + ".so", "kills")
        killed(r, "cancel_kill", ERR_CANCELLED, v)
        killed(r, "deadline_kill", ERR_DEADLINE, v)
        ok(r, "two_args", v + " after the kills")
    print("test_worker_calls: ok")
