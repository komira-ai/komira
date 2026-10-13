# The conformance runner: every case of a corpus against one runtime
# library, through UdfRuntime only (docs/design/udf_runtime_interface.md
# section 6.3). It knows no runtime and no language: the library path is its
# input, and what the runtime can do comes from describe. A case is skipped
# only when its shape is not in capabilities.shapes, its classes do not hold
# the runtime's udf_class, or a feature bit it needs is clear; each skip is
# reported with its reason. (A validate case of a shape the runtime lacks is
# not skipped: the host refuses it from describe, OPTIMIZED_UDF_KIND_
# UNSUPPORTED, without calling validate, as design sections 4.2 and 4.5 say.)
#
# A case binds its UDF as the host admits it: validate, then load.
#
# Besides each case's own expectation, every case checks what the contract
# promises for any call:
#   - every array, child array and stream the host exported was released
#     exactly once by the end of the case, and no borrowed schema was
#     released (checked on a failed case too, and added to its reason);
#   - every byte the runtime reserved through mem_reserve was returned by the
#     end of the case (a runtime that reserves its outputs and error strings,
#     as the reference runtime does, shows a host that never released one);
#   - an error status carries a message (an error code alone is a failure);
#   - no host post-condition broke unless the case expects that fault.
# The `capabilities` result checks the describe answer itself (design
# section 4.2): the runtime id grammar, CPU among the devices, a class of
# NATIVE or MANAGED (0 is refused), no feature bit this ABI does not
# define, and the MEMORY_REPORT feature bit set exactly when its entry is.
# How a runtime executes is not a capability, so nothing about it is
# checked. The class is read for nothing else but a case's `classes` gate.
#
# After a status that loses a context (contract.loses_context), a runner
# makes no further call into it: it stops, and the case's run error is that
# status's; UdfRuntime refuses a call into a lost context should one try.

from std.os import listdir

from .cases import Case, Expect, Partial, parse_case
from .contract import (
    CLASS_MANAGED,
    CLASS_NATIVE,
    DEVICE_CPU,
    ERR_UNSUPPORTED,
    FEATURES_DEFINED,
    KIND_UNSUPPORTED,
    OK,
    loses_context,
    status_name,
)
from ._host import Counts
from ._nested import run_nested_frame
from .runtime import CallOptions, CodeSet, Handle, Opened, Outcome, UdfRuntime
from .values import Batch, Column, TYPE_FLOAT64, TYPE_INT32

comptime EMPTY_CODE_ROOT = "./no-code-objects-here"
"""The code root of a case that sets code_root_empty: a path that holds no
code object (it does not exist), so a validate that opens code fails."""


@fieldwise_init
struct CaseResult(Copyable, Movable, Writable):
    var name: String
    var verdict: String
    """PASS, FAIL or SKIP."""
    var reason: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.verdict, " ", self.name)
        if self.reason != "":
            writer.write(": ", self.reason)


struct Report(Copyable, Movable, Writable):
    var runtime_id: String
    var results: List[CaseResult]

    def __init__(out self):
        self.runtime_id = ""
        self.results = List[CaseResult]()

    def count(self, verdict: String) -> Int:
        var n = 0
        for i in range(len(self.results)):
            if self.results[i].verdict == verdict:
                n += 1
        return n

    def result(self, name: String) raises -> CaseResult:
        for i in range(len(self.results)):
            if self.results[i].name == name:
                return self.results[i].copy()
        raise Error("UDF_CONFORM_NO_CASE: " + name)

    def write_to(self, mut writer: Some[Writer]):
        writer.write("runtime ", self.runtime_id, ": ", self.count("PASS"), " pass, ")
        writer.write(self.count("FAIL"), " fail, ", self.count("SKIP"), " skip\n")
        for i in range(len(self.results)):
            writer.write("  ", self.results[i], "\n")


def load_cases(dir: String) raises -> List[Case]:
    """Every `*.json` case under `dir`, in name order."""
    var names = List[String]()
    for n in listdir(dir):
        var s = String(n)
        if s.endswith(".json"):
            names.append(s)
    sort(names)
    var out = List[Case]()
    for i in range(len(names)):
        var path = dir + "/" + names[i]
        try:
            with open(path, "r") as f:
                out.append(parse_case(f.read()))
        except e:
            raise Error("UDF_CASE_MALFORMED: " + path + ": " + String(e))
    return out^


def _id_part_ok(p: String) -> Bool:
    var b = p.as_bytes()
    if len(b) < 1 or len(b) > 63:
        return False
    for i in range(len(b)):
        var c = b[i]
        var alnum = (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39)
        if not alnum and (i == 0 or (c != 0x2E and c != 0x5F and c != 0x2D)):
            return False
    return True


def runtime_id_ok(id: String) -> Bool:
    """`<namespace>/<name>`, each `[a-z0-9][a-z0-9._-]{0,62}` (design 3.1)."""
    var parts = id.split("/")
    return len(parts) == 2 and _id_part_ok(String(parts[0])) and _id_part_ok(String(parts[1]))


def _check(got: Outcome, e: Expect, at_call: Bool = True) -> String:
    """"" when the outcome is what the case expects (`at_call` False: the
    outcome is validate's)."""
    if got.status != e.status:
        return "status " + String(got) + ", expected " + status_name(e.status)
    if got.status != OK and got.message == "":
        return "status " + status_name(got.status) + " without a message"
    if e.run_error != "" and got.run_error(at_call) != e.run_error:
        return "run error " + got.run_error(at_call) + " (" + String(got) + "), expected " + e.run_error
    if e.run_error == "" and got.fault != "":
        return "host fault: " + got.fault
    if e.fault not in got.fault:
        return "fault '" + got.fault + "' does not contain the expected '" + e.fault + "'"
    if e.row != -2 and got.row != e.row:
        return "error row " + String(got.row) + ", expected " + String(e.row)
    if e.row_at_least != -2 and got.row < e.row_at_least:
        return "error row " + String(got.row) + ", expected at least " + String(e.row_at_least)
    if e.message_contains != "" and e.message_contains not in got.message:
        return "message '" + got.message + "' does not contain '" + e.message_contains + "'"
    return ""


def same_column(got: Column, want: Column) -> String:
    """"" when equal: same length, nulls in the same rows, equal values
    (float64 within 1e-9, relative)."""
    if len(got) != len(want):
        return "column " + String(got) + ", expected " + String(want)
    for i in range(len(want)):
        if got.valid[i] != want.valid[i]:
            return "row " + String(i) + " null mismatch: " + String(got) + ", expected " + String(want)
        if not want.valid[i]:
            continue
        if want.type_id == TYPE_FLOAT64:
            var g = got.as_float(i)
            var w = want.as_float(i)
            var scale = abs(w) if abs(w) > 1.0 else 1.0
            if not (abs(g - w) <= 1e-9 * scale):
                return "row " + String(i) + ": " + String(got) + ", expected " + String(want)
        elif got.bits[i] != want.bits[i]:
            return "row " + String(i) + ": " + String(got) + ", expected " + String(want)
    return ""


def _same_batches(got: List[Batch], want: List[Batch]) -> String:
    if len(got) != len(want):
        return String(len(got)) + " output batches, expected " + String(len(want))
    for i in range(len(want)):
        if got[i].length != want[i].length or len(got[i].columns) != len(want[i].columns):
            return "batch " + String(i) + " " + String(got[i]) + ", expected " + String(want[i])
        for c in range(len(want[i].columns)):
            var d = same_column(got[i].columns[c], want[i].columns[c])
            if d != "":
                return "batch " + String(i) + " " + d
    return ""


def _slice(b: Batch, lo: Int, hi: Int) -> Batch:
    var out = Batch(hi - lo)
    for c in range(len(b.columns)):
        var col = Column(b.columns[c].type_id)
        for r in range(lo, hi):
            col.bits.append(b.columns[c].bits[r])
            col.valid.append(b.columns[c].valid[r])
        out.columns.append(col^)
    return out^


struct _Bound(Movable):
    """A loaded UDF and, per instance a case opened, the instance and the
    context it lives in (each instance in its own context)."""

    var udf: Handle
    var ctxs: List[Handle]
    var insts: List[Handle]

    def __init__(out self, udf: Handle):
        self.udf = udf.copy()
        self.ctxs = List[Handle]()
        self.insts = List[Handle]()


def _bind(mut rt: UdfRuntime, c: Case, n_instances: Int) raises -> _Bound:
    """Load the case's UDF and open `n_instances` instances of it, each in
    a context of its own (slots 0, 1, ...): two instances never share a
    context, so state a runtime keeps per context or per process, not per
    instance, shows up as a wrong result."""
    var v = rt.validate(c.spec)
    if not v.is_ok():
        raise Error("validate: " + String(v))
    var u = rt.load(c.spec)
    if not u.outcome.is_ok():
        raise Error("load: " + String(u.outcome))
    var b = _Bound(u.handle)
    for i in range(n_instances):
        var ctx = rt.open_context(UInt32(i))
        if not ctx.outcome.is_ok():
            _unbind(rt, b)
            raise Error("open_context: " + String(ctx.outcome))
        b.ctxs.append(ctx.handle.copy())
        var inst = rt.open_instance(ctx.handle, b.udf)
        if not inst.outcome.is_ok():
            _unbind(rt, b)
            raise Error("open_instance: " + String(inst.outcome))
        b.insts.append(inst.handle.copy())
    return b^


def _unbind(mut rt: UdfRuntime, b: _Bound) raises:
    for i in range(len(b.insts)):
        rt.close_instance(b.insts[i])
    for i in range(len(b.ctxs)):
        rt.close_context(b.ctxs[i])
    rt.unload(b.udf)


def _then_call(mut rt: UdfRuntime, c: Case, inst: Handle) raises -> String:
    """The case's follow-up call on the same instance: it must succeed, so
    the context and instance were kept usable (design section 4.5)."""
    if not c.expect.then_input:
        return ""
    if rt.lost_context_of(inst):
        return "the follow-up call found the context lost"
    var res = rt.call_batch(inst, c.spec, c.expect.then_input.value(), CallOptions.plain())
    if not res.outcome.is_ok():
        return "the follow-up call on the same instance failed: " + String(res.outcome)
    if c.expect.then_column:
        var d = same_column(res.column, c.expect.then_column.value())
        if d != "":
            return "the follow-up call: " + d
    return ""


def _run_call(mut rt: UdfRuntime, c: Case) raises -> String:
    var b = _bind(rt, c, 1)
    var res = rt.call_batch(b.insts[0], c.spec, c.input, c.options)
    var why = _check(res.outcome, c.expect)
    if why == "" and res.outcome.is_ok() and c.expect.column:
        why = same_column(res.column, c.expect.column.value())
    if why == "":
        why = _then_call(rt, c, b.insts[0])
    _unbind(rt, b)
    return why


def _run_split(mut rt: UdfRuntime, c: Case) raises -> String:
    """One instance over the whole input, another (in a second context) over
    it split in two at `split_at`: both must equal the expected column
    (design 3.4 rule 3)."""
    var b = _bind(rt, c, 2)
    var whole = rt.call_batch(b.insts[0], c.spec, c.input, c.options)
    var first = rt.call_batch(b.insts[1], c.spec, _slice(c.input, 0, c.split_at), c.options)
    if loses_context(first.outcome.status):
        # Nothing more on a lost context: the run fails with the loss.
        _unbind(rt, b)
        return _check(first.outcome, c.expect)
    var second = rt.call_batch(b.insts[1], c.spec, _slice(c.input, c.split_at, c.input.length), c.options)
    # N x 1: every row its own batch, on the second instance again.
    var rows = Column(c.spec.result[0].type_id)
    var one_bad = Optional[Outcome](None)
    for r in range(c.input.length):
        if loses_context(second.outcome.status) or one_bad:
            break
        var one = rt.call_batch(b.insts[1], c.spec, _slice(c.input, r, r + 1), c.options)
        if not one.outcome.is_ok():
            one_bad = one.outcome.copy()
            break
        rows.bits.append(one.column.bits[0])
        rows.valid.append(one.column.valid[0])
    _unbind(rt, b)
    var outs: List[Outcome] = [whole.outcome.copy(), first.outcome.copy(), second.outcome.copy()]
    if one_bad:
        outs.append(one_bad.value().copy())
    for i in range(len(outs)):
        var why = _check(outs[i], c.expect)
        if why != "":
            return why
    var want = c.expect.column.value().copy()
    var why = same_column(whole.column, want)
    if why != "":
        return "one instance, one batch: " + why
    var joined = first.column.copy()
    for r in range(len(second.column)):
        joined.bits.append(second.column.bits[r])
        joined.valid.append(second.column.valid[r])
    why = same_column(joined, want)
    if why != "":
        return "two batches on a second instance: " + why
    why = same_column(rows, want)
    if why != "":
        return "one batch per row on the second instance: " + why
    return ""


def _concat(outputs: List[Batch], type_id: Int) -> Column:
    """The first column of every output, one after another."""
    var col = Column(type_id)
    for i in range(len(outputs)):
        if len(outputs[i].columns) == 0:
            continue
        for r in range(len(outputs[i].columns[0])):
            col.bits.append(outputs[i].columns[0].bits[r])
            col.valid.append(outputs[i].columns[0].valid[r])
    return col^


def _run_frame(mut rt: UdfRuntime, c: Case) raises -> String:
    var b = _bind(rt, c, 1)
    var calls = rt.calls()
    var res = rt.run_frame(b.insts[0], c.spec, c.inputs, c.options)
    calls = rt.calls() - calls
    var why = _check(res.outcome, c.expect)
    # The outputs are compared whatever the status: a frame that raises
    # after yielding must have handed out what it yielded before the error.
    if why == "" and c.expect.batches:
        why = _same_batches(res.outputs, c.expect.batches.value())
    if why == "" and c.expect.concat_column:
        var want = c.expect.concat_column.value().copy()
        why = same_column(_concat(res.outputs, want.type_id), want)
    if why == "" and c.expect.max_calls >= 0 and calls > Int64(c.expect.max_calls):
        why = String(calls) + " calls crossed into the runtime, at most " + String(c.expect.max_calls) + " expected"
    if why == "" and c.expect.max_outputs >= 0 and len(res.outputs) > c.expect.max_outputs:
        why = String(len(res.outputs)) + " outputs, at most " + String(c.expect.max_outputs) + " expected"
    if why == "" and c.expect.then_inputs and not rt.lost_context_of(b.insts[0]):
        var again = rt.run_frame(b.insts[0], c.spec, c.expect.then_inputs.value(), CallOptions.plain())
        if not again.outcome.is_ok():
            why = "the follow-up frame on the same instance failed: " + String(again.outcome)
        elif c.expect.then_batches:
            why = _same_batches(again.outputs, c.expect.then_batches.value())
            if why != "":
                why = "the follow-up frame: " + why
    elif why == "" and c.expect.then_inputs:
        why = "the follow-up frame found the context lost"
    _unbind(rt, b)
    var most = c.expect.max_pulls_before_first_output
    if why == "" and most >= 0 and res.pulls_before_first_output > most:
        why = (
            "the first output came after " + String(res.pulls_before_first_output)
            + " input batches were pulled, at most " + String(most) + " expected"
        )
    return why


def _run_agg_split(mut rt: UdfRuntime, c: Case) raises -> String:
    """Each partial on its own instance (agg_update, then agg_state of every
    group: a PARTIAL step); the states merged on one more instance
    (agg_merge, then agg_finish: the FINAL step). The first step whose
    outcome is not OK is the one the case's expectation is checked against;
    when every step is OK, the expectation must be OK and the final column
    the expected one."""
    var b = _bind(rt, c, len(c.partials) + 1)
    var calls = rt.calls()
    var bad = List[Outcome]()
    var states = List[Column]()
    for i in range(len(c.partials)):
        var g = rt.agg_open(b.insts[i])
        if not g.outcome.is_ok():
            bad.append(g.outcome.copy())
            break
        var p = c.partials[i].copy()
        var up = rt.agg_update(g.handle, p.input, p.group_ids, p.n_groups, c.options)
        if not up.is_ok():
            rt.agg_close(g.handle)
            bad.append(up^)
            break
        var st = rt.agg_state(g.handle, p.n_groups, c.spec.state.value())
        rt.agg_close(g.handle)
        if not st.outcome.is_ok():
            bad.append(st.outcome.copy())
            break
        states.append(st.column.copy())
    var result_col = Column(c.spec.result[0].type_id)
    if len(bad) == 0:
        var g = rt.agg_open(b.insts[len(c.partials)])
        if not g.outcome.is_ok():
            bad.append(g.outcome.copy())
        for i in range(len(states)):
            if len(bad) > 0:
                break
            var ids = List[Int32]()
            for k in range(len(states[i])):
                ids.append(Int32(k))
            var m = rt.agg_merge(g.handle, states[i], ids, c.n_groups, c.options)
            if not m.is_ok():
                bad.append(m^)
        if len(bad) == 0:
            var fin = rt.agg_finish(g.handle, c.n_groups, c.spec.result[0])
            if fin.outcome.is_ok():
                result_col = fin.column.copy()
            else:
                bad.append(fin.outcome.copy())
        if g.outcome.is_ok():
            rt.agg_close(g.handle)
    calls = rt.calls() - calls
    _unbind(rt, b)
    if len(bad) > 0:
        return _check(bad[0], c.expect)
    var why = _check(Outcome.of(OK), c.expect)
    if why == "" and c.expect.column:
        why = same_column(result_col, c.expect.column.value())
    if why == "" and c.expect.max_calls >= 0 and calls > Int64(c.expect.max_calls):
        why = String(calls) + " calls crossed into the runtime, at most " + String(c.expect.max_calls) + " expected"
    return why


def _run_load(mut rt: UdfRuntime, c: Case) raises -> String:
    """validate, which must pass, then load: the load's outcome is the
    case's (an admission status, `at_call` False)."""
    var v = rt.validate(c.spec)
    if not v.is_ok():
        return "validate: " + String(v)
    var u = rt.load(c.spec)
    if u.outcome.status == OK:
        rt.unload(u.handle)
    return _check(u.outcome, c.expect, False)


def _run_validate(mut rt: UdfRuntime, c: Case) raises -> String:
    """The host's admission of one spec: a shape the runtime lacks is
    refused from describe, before validate (OPTIMIZED_UDF_KIND_UNSUPPORTED,
    design sections 4.2 and 4.5); otherwise validate's own answer."""
    var caps = rt.describe()
    if c.spec.shape & caps.shapes == 0:
        var why = "the runtime's capabilities lack the shape " + String(c.spec.shape)
        return _check(Outcome(ERR_UNSUPPORTED, why, "", -1, -1, KIND_UNSUPPORTED + ": " + why), c.expect, False)
    return _check(rt.validate(c.spec), c.expect, False)


def _run_nested(mut rt: UdfRuntime, c: Case) raises -> String:
    """A frame whose pulls are answered on its own context (_nested.mojo):
    the frame's UDF and the nested scalar's are bound, as instances of one
    context."""
    var fv = rt.validate(c.spec)
    if not fv.is_ok():
        return "validate: " + String(fv)
    var fu = rt.load(c.spec)
    if not fu.outcome.is_ok():
        return "load: " + String(fu.outcome)
    var su = Opened(Outcome.of(OK), fu.handle.copy())
    var has_scalar = c.levels > 0 and Bool(c.nested)
    if has_scalar:
        var sv = rt.validate(c.nested.value())
        if not sv.is_ok():
            rt.unload(fu.handle)
            return "validate (nested): " + String(sv)
        su = rt.load(c.nested.value())
        if not su.outcome.is_ok():
            rt.unload(fu.handle)
            return "load (nested): " + String(su.outcome)
    var ctx = rt.open_context(0)
    if not ctx.outcome.is_ok():
        if has_scalar:
            rt.unload(su.handle)
        rt.unload(fu.handle)
        return "open_context: " + String(ctx.outcome)
    var fi = rt.open_instance(ctx.handle, fu.handle)
    var si = fi.copy()
    if has_scalar and fi.outcome.is_ok():
        si = rt.open_instance(ctx.handle, su.handle)
    var why = String("")
    if not fi.outcome.is_ok() or not si.outcome.is_ok():
        why = "open_instance: " + String(fi.outcome) + ", " + String(si.outcome)
    else:
        var res = run_nested_frame(rt, fi.handle, c.spec, si.handle, c.inputs, c.levels, c.pull_at, c.pull_do, c.options)
        why = _check(res.outcome, c.expect)
        if why == "" and c.expect.batches:
            why = _same_batches(res.outputs, c.expect.batches.value())
        if why == "" and c.expect.eio_at_least >= 0 and res.eio < c.expect.eio_at_least:
            why = String(res.eio) + " pulls got EIO, at least " + String(c.expect.eio_at_least) + " expected"
        if why == "" and not res.streams_released:
            why = "a producer stream was not released"
    if has_scalar and si.outcome.is_ok():
        rt.close_instance(si.handle)
    if fi.outcome.is_ok():
        rt.close_instance(fi.handle)
    rt.close_context(ctx.handle)
    if has_scalar:
        rt.unload(su.handle)
    rt.unload(fu.handle)
    return why


def _run_parallel(mut rt: UdfRuntime, c: Case) raises -> String:
    """`threads` instances, each in a context of its own, called at once on
    one thread each (native/bench_loop.c): every output must be a * x + b."""
    var b = _bind(rt, c, c.threads)
    var t = rt.time_call_batch_threads(b.insts, c.rows, c.spec.args[0].type_id == TYPE_FLOAT64, c.a, c.b, c.iters)
    _unbind(rt, b)
    if t.failures > 0 or t.mismatches > 0:
        return (
            String(t.failures) + " calls failed and " + String(t.mismatches) + " outputs were wrong, of "
            + String(c.threads * c.iters) + " calls on " + String(c.threads) + " contexts at once"
        )
    if t.released != c.threads * c.iters:
        return String(t.released) + " input arrays released, of " + String(c.threads * c.iters)
    return ""


def run_case(mut rt: UdfRuntime, c: Case) raises -> String:
    """"" when case `c` passes on `rt`; otherwise why it failed."""
    if c.run == "validate":
        return _run_validate(rt, c)
    if c.run == "load":
        return _run_load(rt, c)
    if c.run == "nested_frame":
        return _run_nested(rt, c)
    if c.run == "parallel":
        return _run_parallel(rt, c)
    if c.run == "init_abi":
        return _check(rt.init_refusal(2), c.expect)
    if c.run == "call_batch":
        return _run_call(rt, c)
    if c.run == "split":
        return _run_split(rt, c)
    if c.run == "frame":
        return _run_frame(rt, c)
    if c.run == "agg_split":
        return _run_agg_split(rt, c)
    raise Error("UDF_CASE_MALFORMED: " + c.name + ": run " + c.run)


def _ledger_check(rt: UdfRuntime, b: Counts) -> String:
    """"" when every array, child, stream and reservation of the case since
    `b` was released exactly once, and no borrowed schema was released."""
    var a = rt.ledger()
    var exported = a.exported - b.exported
    var released = a.released - b.released
    if released != exported:
        return String(exported) + " arrays exported to the runtime, " + String(released) + " released"
    var kids = a.children_exported - b.children_exported
    var kids_released = a.children_released - b.children_released
    if kids_released != kids:
        return String(kids) + " child arrays exported to the runtime, " + String(kids_released) + " released"
    if a.double_released != b.double_released:
        return "an array was released twice"
    if a.schemas_released != b.schemas_released:
        return "a borrowed schema was released by the runtime"
    if a.streams_released - b.streams_released != a.streams_exported - b.streams_exported:
        return "an input stream was not released"
    if a.reserved_bytes != b.reserved_bytes:
        return (
            String(a.reserved_bytes - b.reserved_bytes) + " bytes the runtime reserved are still held:"
            + " an output or an error the host never released, a handle never closed, or a runtime leak"
        )
    return ""


def _capabilities(mut rt: UdfRuntime) raises -> CaseResult:
    var caps = rt.describe()
    var why = String("")
    if not runtime_id_ok(caps.runtime_id):
        why = "runtime id '" + caps.runtime_id + "' is not <namespace>/<name>"
    elif caps.devices & DEVICE_CPU == 0:
        why = "devices lacks CPU"
    elif caps.udf_class != CLASS_NATIVE and caps.udf_class != CLASS_MANAGED:
        why = "udf_class " + String(caps.udf_class) + " is neither NATIVE nor MANAGED"
    elif caps.features & ~FEATURES_DEFINED != 0:
        why = "a feature bit this ABI does not define: features " + String(caps.features)
    elif not rt.feature_slots_agree():
        why = "the MEMORY_REPORT feature bit and the memory_report entry disagree"
    return CaseResult("capabilities", "PASS" if why == "" else "FAIL", why)


def run_suite(runtime_path: String, cases: List[Case], code: CodeSet = CodeSet.none()) raises -> Report:
    """Open the runtime library at `runtime_path` and run every case on it.
    A case that raises fails with the error as its reason; the suite goes
    on. A non-empty `code` replaces every case's code root and code objects
    (the same for every case: how a runtime that executes code objects
    gets them). Such a runtime may open its code objects at their first load
    and hold them, with what they reserved, until shutdown (the native
    runtime's libraries); so before the first case one load (and unload) of
    the first case that loads opens them, and that open is not charged to a
    case's ledger. validate opens no code (design section 4.3), so it cannot
    be what opens them. A runtime's own tests check that its shutdown
    returns what it held (the native runtime's test_leaks)."""
    var rt = UdfRuntime.open(runtime_path)
    var report = Report()
    var caps = rt.describe()
    report.runtime_id = caps.runtime_id
    report.results.append(_capabilities(rt))
    if len(code.objects) > 0:
        for i in range(len(cases)):
            var warm = cases[i].spec.copy()
            warm.code_root = code.root
            warm.code = code.objects.copy()
            var u = rt.load(warm)
            if u.outcome.status == OK:
                rt.unload(u.handle)
                break
    for i in range(len(cases)):
        var c = cases[i].copy()
        if len(code.objects) > 0:
            c.spec.code_root = code.root
            c.spec.code = code.objects.copy()
            if c.nested:
                var n = c.nested.value().copy()
                n.code_root = code.root
                n.code = code.objects.copy()
                c.nested = n^
        if c.code_root_empty:
            c.spec.code_root = EMPTY_CODE_ROOT
        if len(c.classes) > 0 and caps.udf_class not in c.classes:
            report.results.append(CaseResult(c.name, "SKIP", "the runtime's class is not among the case's classes"))
            continue
        if c.needs_features & caps.features != c.needs_features:
            report.results.append(CaseResult(c.name, "SKIP", "a feature bit the case needs is not in capabilities.features"))
            continue
        if c.runtime_lacks_shape and c.spec.shape & caps.shapes != 0:
            report.results.append(CaseResult(c.name, "SKIP", "the case is about a shape the runtime lacks, and it has it"))
            continue
        var instanceless = c.run == "validate" or c.run == "init_abi"
        if not instanceless and c.spec.shape & caps.shapes == 0:
            report.results.append(CaseResult(c.name, "SKIP", "shape not in capabilities.shapes"))
            continue
        var l = rt.ledger()
        var why: String
        try:
            why = run_case(rt, c)
        except e:
            why = String(e)
        # The ledger is checked on a failed case too: a failure path that
        # leaks (a handle left open) is a failure of its own.
        var leak = _ledger_check(rt, l)
        if why == "":
            why = leak
        elif leak != "":
            why += "; and " + leak
        if why != "":
            why += " [defect caught: " + c.defect + "]"
        report.results.append(CaseResult(c.name, "PASS" if why == "" else "FAIL", why))
    rt.shutdown()
    return report^
