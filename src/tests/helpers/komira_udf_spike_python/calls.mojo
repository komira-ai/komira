# Small helpers the runtime's own tests share: specs, batches, and one call
# through a fresh context and instance.

from komira_udf_spike_abi.contract import OK
from komira_udf_spike_abi.runtime import CallOptions, CallResult, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT64


def spec1(shape: UInt32, entry: String, arg: Int, result: Int, nullable: Bool = True) -> UdfSpec:
    """One argument of type `arg`, a result of type `result`."""
    return UdfSpec(shape, entry, [ColumnType(arg, True)], [ColumnType(result, nullable)])


def ints(values: List[Int64]) -> Batch:
    var c = Column(TYPE_INT64)
    for v in values:
        c.append_int(v)
    var b = Batch(len(values))
    b.columns.append(c^)
    return b^


def floats(values: List[Float64], null_at: Int = -1) -> Batch:
    """A float64 column; row `null_at` (if any) is null."""
    var c = Column(TYPE_FLOAT64)
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
