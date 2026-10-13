# Calls through a runtime library's table that the engine loop does not
# make (native/probe_calls.c), on the zygote and pyarrow builds.
#
# What it proves, and the defect each part catches:
#   - two arguments whose children are slices at different offsets (13 and
#     3), each with a null, one null count given and one left -1: every
#     value and both nulls of pair(x, y) = x * 1000 + y, twice, on the
#     zygote and pyarrow builds (an engine writer that takes
#     every column's offset from the first, or re-bases a bitmap wrongly;
#     the pyarrow build also reads the two-column batch with pyarrow);
#   - a UDF loaded after a context was opened, called in that context and
#     in one opened after the load, on the zygote build (a
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
#   - kills, on the zygote build: a call deaf to cancel and
#     to the clock (sleeping 20 s) is cancelled 300 ms in;
#     the worker is killed 2 s after the cancel reached it (it has ended
#     by the time call_batch returns, not only after close_context), and the
#     call returns ERR_CANCELLED in 2 .. 12 s. In a new context the same call
#     past a deadline 300 ms away is killed 2 s after it: ERR_DEADLINE in
#     2 .. 12 s. After each the next call on that context is
#     ERR_INSTANCE_LOST, its worker is gone after close_context, and a new
#     context still serves (an engine that waits on a worker that ignores
#     the cancel, section 5.2: "if the worker has not answered within the
#     grace period, it kills the worker").
#
#   - and the cases the scripted mutation sweep asked for (native/
#     probe_calls.c's newer groups): a cancelled call leaves its context
#     serving; two UDFs in one context each run their own code and schema;
#     eight rounds of 40 held slots never fill the heap (each slot released
#     with its own id); nulls at a bitmap byte's edges; a user
#     error's Python traceback; a result over the reply heap; 1000 clock
#     reads (a deadline set, a 1000-row per-row call) under 500 ms (an
#     engine that answers a read only when its 1 ms poll times out takes
#     over 1000 ms); no engine heap growth over 200 refusals, loads and
#     instances, nor over validates taken, refused loads, calls whose user code raises
#     (the ERROR reply, its message and trace), contexts opened and closed
#     (the fork, its reply), and inits with shutdowns (blocks never freed,
#     found by the sweep); a cancel the host raises inside the worker's
#     clock read: ERR_CANCELLED, and the next call on the instance answers
#     (a worker that stops waiting for CLOCK when CANCEL arrives); the
#     library opened by its absolute path.
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
from komira_udf_spike_pyworker.drive import probe_calls
from komira_udf_spike_pyworker.report import num, text


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
    var ended = r.get(name + "_ended_at_return")
    assert_equal(num(ended, "status"), 0, what + ": the worker's pid was read")
    assert_equal(text(ended, "message"), "ended", what + ": the worker was not killed by the time the call returned")
    var next = r.get(name + "_next")
    assert_equal(num(next, "status"), Int(ERR_INSTANCE_LOST), what + ": " + text(next, "message"))
    assert_equal(num(next, "value"), 2, what + ": both calls' args released")
    var gone = r.get(name + "_worker_gone")
    assert_equal(num(gone, "status"), 0, what + ": the worker's pid was read")
    assert_equal(text(gone, "message"), "gone", what + ": the killed worker outlived close_context")


def main() raises:
    # First: the pyarrow library's first dlopen in this process is by its
    # absolute path.
    var a = probe_calls("./pyworker_pyarrow.so", "abs_path")
    ok(a, "two_args", "pyarrow opened by absolute path")
    for v in ["zygote", "pyarrow"]:
        var m = probe_calls("./pyworker_" + v + ".so", "after_cancel")
        var cn = m.get("cancelled")
        assert_equal(num(cn, "status"), Int(ERR_CANCELLED), v + " cancelled: " + text(cn, "message"))
        ok(m, "after_cancel_pair", v)
        var same = m.get("after_cancel_same")
        assert_equal(num(same, "status"), 0, v + " after_cancel_same: " + text(same, "message"))
        assert_equal(num(same, "value"), 5, v + " after_cancel_same: slow_loop(5)")
        var t2 = probe_calls("./pyworker_" + v + ".so", "two_udfs")
        ok(t2, "two_udfs_pair", v)
        ok(t2, "two_udfs_double", v)
        ok(t2, "two_udfs_pair_again", v)
        var n = probe_calls("./pyworker_" + v + ".so", "nulls")
        assert_equal(num(n.get("rows_9_last_null"), "status"), 0, v + ": " + text(n.get("rows_9_last_null"), "message"))
        assert_equal(num(n.get("rows_9_last_null"), "value"), 0, v + ": rows_9_last_null values and bits")
        assert_equal(num(n.get("column_8_rows_null"), "status"), 0, v + ": " + text(n.get("column_8_rows_null"), "message"))
        assert_equal(num(n.get("column_8_rows_null"), "value"), 0, v + ": column_8_rows_null values and bits")
        var tr = probe_calls("./pyworker_" + v + ".so", "trace")
        assert_true(text(tr.get("trace"), "message").startswith("TypeError"), v + ": " + text(tr.get("trace"), "message"))
        assert_equal(num(tr.get("trace"), "value"), 1, v + ": the trace is the Python traceback")
    for v in ["zygote"]:
        var mc = probe_calls("./pyworker_" + v + ".so", "many_calls")
        assert_equal(num(mc.get("many_calls"), "status"), 0, v + ": " + text(mc.get("many_calls"), "message"))
        assert_equal(num(mc.get("many_calls"), "value"), 0, v + ": heap-full warnings over 8 rounds of 40 held slots")
        var ct = probe_calls("./pyworker_" + v + ".so", "clock_time")
        assert_equal(num(ct.get("clock_time"), "status"), 0, v + ": " + text(ct.get("clock_time"), "message"))
        # 1000 clock reads: a read answered only when the engine's 1 ms poll
        # times out costs at least 1000 ms; one answered at once costs a
        # socket round trip (tens of us). 500 ms is half the stalled floor
        # and ten times the round trips the bench measures on a busy worker.
        var ct_ms = num(ct.get("clock_time"), "value")
        assert_true(ct_ms < 500, v + ": 1000 clock reads took " + String(ct_ms) + " ms")
    for v in ["zygote", "pyarrow"]:
        var bg = probe_calls("./pyworker_" + v + ".so", "big")
        assert_equal(num(bg.get("big"), "status"), 0, v + ": " + text(bg.get("big"), "message"))
        assert_equal(num(bg.get("big"), "value"), 0, v + ": a result over the reply heap")
    var lk = num(probe_calls("./pyworker_zygote.so", "leaks").get("leaks"), "value")
    assert_true(lk // 1000000 < 400, "refused validates grew the heap by " + String(lk // 1000000))
    assert_true((lk // 1000) % 1000 < 400, "load and unload grew the heap by " + String((lk // 1000) % 1000))
    assert_true(lk % 1000 < 400, "open and close instance grew the heap by " + String(lk % 1000))
    var lm = probe_calls("./pyworker_zygote.so", "leaks_more")
    for k in ["leak_validate_ok", "leak_load_refused", "leak_raised_call", "leak_context", "leak_init"]:
        var c = lm.get(k)
        assert_equal(num(c, "status"), 0, k + ": " + text(c, "message"))
        assert_true(num(c, "value") < 400, k + ": the engine's heap grew by " + String(num(c, "value")) + " bytes")
    var cic = probe_calls("./pyworker_zygote.so", "cancel_in_clock")
    var cc = cic.get("cancel_in_clock")
    assert_equal(num(cc, "status"), Int(ERR_CANCELLED), "cancel raised in now_ns: " + text(cc, "message"))
    assert_equal(num(cc, "value"), 1, "the host's flag was raised by the worker's clock read")
    var cn = cic.get("cancel_in_clock_next")
    assert_equal(num(cn, "status"), 0, "the next call after a cancel in now_ns: " + text(cn, "message"))
    assert_equal(num(cn, "value"), 0, "the next call's values")

    for v in ["zygote", "pyarrow"]:
        var t = probe_calls("./pyworker_" + v + ".so", "two_args")
        ok(t, "two_args", v)
        ok(t, "two_args_again", v)

    for v in ["zygote"]:
        var l = probe_calls("./pyworker_" + v + ".so", "late_load")
        assert_equal(num(l.get("before"), "status"), 0, v + ": " + text(l.get("before"), "message"))
        ok(l, "late_in_open_context", v)
        ok(l, "late_in_new_context", v)
        ok(l, "after_unload", v)

    var r = probe_calls("./pyworker_zygote.so", "refusals")
    refused(r, "short_child", ERR_INTERNAL, "an argument is shorter than the batch")
    refused(r, "child_count", ERR_INTERNAL, "child count other than the bound signature's")
    refused(r, "struct_offset", ERR_INTERNAL, "nonzero offset")
    refused(r, "negative_length", ERR_INTERNAL, "negative length")
    refused(r, "three_buffers", ERR_INTERNAL, "not a fixed-width primitive")
    refused(r, "no_values", ERR_INTERNAL, "no values buffer")
    refused(r, "negative_offset", ERR_INTERNAL, "an argument has a negative offset")
    refused(r, "not_cpu", ERR_UNSUPPORTED, "not on the CPU")
    refused(r, "call_struct_size", ERR_ABI, "call struct_size")
    ok(r, "after_refusals", "zygote")

    for v in ["zygote"]:
        r = probe_calls("./pyworker_" + v + ".so", "kills")
        killed(r, "cancel_kill", ERR_CANCELLED, v)
        killed(r, "deadline_kill", ERR_DEADLINE, v)
        ok(r, "two_args", v + " after the kills")
    print("test_worker_calls: ok")
