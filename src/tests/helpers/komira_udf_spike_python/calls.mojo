# Small helpers the runtime's own tests share: specs, batches (sliced at an
# Arrow offset when asked), one call through a fresh context and instance,
# and the misuse check of the threads tests.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import ERR_INTERNAL, OK, status_name
from komira_udf_spike_abi.runtime import CallOptions, CallResult, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.engine import Engine
from komira_udf_spike_python.workloads import fahrenheit_rows


def spec1(shape: UInt32, entry: String, arg: Int, result: Int, nullable: Bool = True) -> UdfSpec:
    """One argument of type `arg`, a result of type `result`."""
    return UdfSpec(shape, entry, [ColumnType(arg, True)], [ColumnType(result, nullable)])


def ints(values: List[Int64], null_at: Int = -1, offset: Int = 0) -> Batch:
    """An int64 column; row `null_at` (if any) is null; exported at Arrow
    offset `offset` (the rows before it are padding)."""
    var c = Column(TYPE_INT64)
    c.offset = offset
    for i in range(len(values)):
        if i == null_at:
            c.append_null()
        else:
            c.append_int(values[i])
    var b = Batch(len(values))
    b.columns.append(c^)
    return b^


def floats(values: List[Float64], null_at: Int = -1, offset: Int = 0) -> Batch:
    """A float64 column; row `null_at` (if any) is null; exported at Arrow
    offset `offset` (the rows before it are padding)."""
    var c = Column(TYPE_FLOAT64)
    c.offset = offset
    for i in range(len(values)):
        if i == null_at:
            c.append_null()
        else:
            c.append_float(values[i])
    var b = Batch(len(values))
    b.columns.append(c^)
    return b^


def call_once(mut rt: UdfRuntime, spec: UdfSpec, args: Batch) raises -> CallResult:
    """load, open a context and an instance, one call_batch, close all.
    Raises if load, open_context or open_instance fails."""
    var u = rt.load(spec)
    if not u.outcome.is_ok():
        raise Error("load " + spec.entry + ": " + String(u.outcome))
    var c = rt.open_context(0)
    if not c.outcome.is_ok():
        raise Error("open_context: " + String(c.outcome))
    var i = rt.open_instance(c.handle, u.handle)
    if not i.outcome.is_ok():
        rt.close_context(c.handle)
        rt.unload(u.handle)
        raise Error("open_instance " + spec.entry + ": " + String(i.outcome))
    var r = rt.call_batch(i.handle, spec, args, CallOptions.plain())
    rt.close_instance(i.handle)
    rt.close_context(c.handle)
    rt.unload(u.handle)
    return r^


def open_instance_outcome(mut rt: UdfRuntime, spec: UdfSpec) raises -> Outcome:
    """load (which must pass), then open_instance's outcome."""
    var u = rt.load(spec)
    if not u.outcome.is_ok():
        raise Error("load " + spec.entry + ": " + String(u.outcome))
    var c = rt.open_context(0)
    if not c.outcome.is_ok():
        raise Error("open_context: " + String(c.outcome))
    var i = rt.open_instance(c.handle, u.handle)
    if i.outcome.status == OK:
        rt.close_instance(i.handle)
    rt.close_context(c.handle)
    rt.unload(u.handle)
    return i.outcome.copy()


def check_misuse(mut e: Engine) raises:
    """The engine's misuse probe on the per-row function: open_instance and
    call_batch from a thread other than the context's are refused
    (ERR_INTERNAL, naming the other thread) and the call's args are still
    moved and released; close_instance and close_context from that thread
    are logged and leave the handles alone (the owner's later calls and
    closes work); an argument struct at offset 1 is refused; every exported
    array is released."""
    var m = e.misuse(fahrenheit_rows(1, 64, 1, 0))
    assert_equal(m.load_status, OK, m.load_message)
    assert_equal(m.open_status, OK, m.open_message)
    assert_equal(status_name(m.foreign_open_instance), "ERR_INTERNAL", m.foreign_open_instance_message)
    assert_true("another thread" in m.foreign_open_instance_message, m.foreign_open_instance_message)
    assert_equal(status_name(m.foreign_call), "ERR_INTERNAL", m.foreign_call_message)
    assert_true("another thread" in m.foreign_call_message, m.foreign_call_message)
    assert_true(m.foreign_call_moved, "a refused call_batch still moves its args")
    assert_equal(m.foreign_close_logs, 2, "close_instance and close_context off the owner thread each log once")
    assert_equal(status_name(m.offset_call), status_name(ERR_INTERNAL), m.offset_call_message)
    assert_true("nonzero offset" in m.offset_call_message, m.offset_call_message)
    assert_true(m.offset_call_moved, "a refused call_batch still moves its args")
    assert_equal(m.after_call, OK, "the owner's call after the misuse: " + m.after_call_message)
    assert_equal(m.after_bad_values, 0)
    assert_equal(m.exported, 3)
    assert_equal(m.released, m.exported, "every exported argument array released")
