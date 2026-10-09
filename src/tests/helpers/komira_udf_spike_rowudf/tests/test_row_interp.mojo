# The interpreter a python_row.so context runs user code in, seen from
# inside it (fixtures in pyrt/udf_checks.py), through the C ABI only.
#
# What it proves, and the defect each part catches:
#   - a context's sub-interpreter refuses fork, exec and daemon threads and
#     allows plain threads (the PyInterpreterConfig the runtime sets); the
#     embedded interpreter imported no site module;
#   - the runtime's own directory (pyrt/) is first on sys.path, so a user
#     module there wins over the standard library (one inserted later);
#   - nothing leaks per call or per instance: the interpreter's allocated
#     blocks grow by less than 100 over 400 calls after 100 (a view, tuple
#     or argument a call makes and never drops), and after 50 open_instance
#     and close_instance cycles no RowInstance but the counting one, and no
#     read-set list, is alive (a reference open_instance takes and close
#     never drops).
#
# Every single-point mutant of the runtime and the adapter was run against
# the runtime tests (the PR's mutation scorecard). One that this file kills:
# row_runtime.c's open_context with allow_daemon_threads = 1: red.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_abi.runtime import CallOptions, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once
from komira_udf_spike_rowudf.read_sets import row_spec

comptime LIB = "./python_row.so"


def one() -> Batch:
    var b = Batch(1)
    var c = Column(TYPE_FLOAT64)
    c.append_float(1.0)
    b.columns.append(c^)
    return b^


def int_of(mut rt: UdfRuntime, name: String) raises -> Int64:
    var p: List[String] = ["price"]
    var r = call_once(rt, row_spec("udf_checks:" + name, p, TYPE_FLOAT64, TYPE_INT64), one())
    assert_true(r.outcome.is_ok(), name + ": " + String(r.outcome))
    return r.column.bits[0]


def test_isolation(mut rt: UdfRuntime) raises:
    assert_equal(int_of(rt, "forks"), 0, "fork refused")
    assert_equal(int_of(rt, "execs"), 0, "exec refused")
    assert_equal(int_of(rt, "threads"), 1, "threads allowed")
    assert_equal(int_of(rt, "daemon_threads"), 0, "daemon threads refused")
    assert_equal(int_of(rt, "site_free"), 1, "no site module")
    assert_equal(int_of(rt, "pyrt_first"), 1, "pyrt/ first on sys.path")


def test_leaks(mut rt: UdfRuntime) raises:
    var p: List[String] = ["price"]
    var spec = row_spec("udf_checks:blocks", p, TYPE_FLOAT64, TYPE_INT64)
    var pq: List[String] = ["price", "qty"]
    var other = row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    var u = rt.load(spec)
    var uo = rt.load(other)
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), String(inst.outcome))
    var b0 = Int64(0)
    for i in range(500):
        var r = rt.call_batch(inst.handle, spec, one(), CallOptions.plain())
        assert_true(r.outcome.is_ok(), String(r.outcome))
        if i == 99:
            b0 = r.column.bits[0]
        if i == 499:
            assert_true(r.column.bits[0] - b0 < 100, "blocks grew by " + String(r.column.bits[0] - b0) + " over 400 calls")
    rt.close_instance(inst.handle)
    # Instances: every RowInstance and read-set list the C side made for an
    # instance goes when it closes. Counted by type, not by blocks: opening
    # an instance runs library code (typing, inspect) whose caches grow.
    var count = row_spec("udf_checks:instances", p, TYPE_FLOAT64, TYPE_INT64)
    var uc = rt.load(count)
    var ic = rt.open_instance(ctx.handle, uc.handle)
    assert_true(ic.outcome.is_ok(), String(ic.outcome))
    for _ in range(50):
        var o = rt.open_instance(ctx.handle, uo.handle)
        assert_true(o.outcome.is_ok(), String(o.outcome))
        rt.close_instance(o.handle)
    var r = rt.call_batch(ic.handle, count, one(), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(r.column.bits[0], 1000, "only the counting instance is alive, and no read-set list")
    rt.close_instance(ic.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)
    rt.unload(uo.handle)
    rt.unload(uc.handle)


def main() raises:
    var rt = UdfRuntime.open(LIB)
    test_isolation(rt)
    test_leaks(rt)
    var l = rt.ledger()
    assert_equal(l.released, l.exported, "every exported argument array released")
    rt.shutdown()
    print("test_row_interp: ok")
