# The conformance runner: every case of a corpus against one runtime
# library, through UdfRuntime only (docs/design/udf_runtime_interface.md
# section 6.3). It knows no runtime and no language: the library path is its
# input, and what the runtime can do comes from describe. A case is skipped
# only when its shape is not in capabilities.shapes, and the skip is
# reported.
#
# Besides each case's own expectation, every case checks what the contract
# promises for any call:
#   - every array and stream the host exported was released exactly once by
#     the end of the case, and no borrowed schema was released;
#   - every byte the runtime reserved through mem_reserve was returned by the
#     end of the case (a runtime that reserves its outputs and error strings,
#     as the reference runtime does, shows a host that never released one);
#   - an error status carries a message (an error code alone is a failure);
#   - no host post-condition broke unless the case expects that fault.
# The `capabilities` result checks the describe answer itself: the runtime
# id grammar, CPU among the devices, in-process among the transports, a
# defined threading value, a class with a hosting value it allows (0 for
# NATIVE; EMBEDDED or HOST_INTERPRETER for MANAGED), and the MEMORY_REPORT
# feature bit set exactly when its entry is. The class is read for nothing
# else: no case depends on it.

from std.os import listdir

from .cases import Case, Expect, Partial, parse_case
from .contract import (
    CLASS_MANAGED,
    CLASS_NATIVE,
    DEVICE_CPU,
    HOSTING_EMBEDDED,
    HOSTING_HOST_INTERPRETER,
    HOSTING_NONE,
    OK,
    SINGLE_THREAD,
    THREAD_SAFE,
    TRANSPORT_IN_PROCESS,
    status_name,
)
from .runtime import CallOptions, CodeSet, Handle, Opened, Outcome, UdfRuntime
from .values import Batch, Column, TYPE_FLOAT64, TYPE_INT32


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


def _run_call(mut rt: UdfRuntime, c: Case) raises -> String:
    var b = _bind(rt, c, 1)
    var res = rt.call_batch(b.insts[0], c.spec, c.input, c.options)
    _unbind(rt, b)
    var why = _check(res.outcome, c.expect)
    if why == "" and res.outcome.is_ok() and c.expect.column:
        why = same_column(res.column, c.expect.column.value())
    return why


def _run_split(mut rt: UdfRuntime, c: Case) raises -> String:
    """One instance over the whole input, another (in a second context) over
    it split in two at `split_at`: both must equal the expected column
    (design 3.4 rule 3)."""
    var b = _bind(rt, c, 2)
    var whole = rt.call_batch(b.insts[0], c.spec, c.input, c.options)
    var first = rt.call_batch(b.insts[1], c.spec, _slice(c.input, 0, c.split_at), c.options)
    var second = rt.call_batch(b.insts[1], c.spec, _slice(c.input, c.split_at, c.input.length), c.options)
    _unbind(rt, b)
    var outs = [whole.outcome.copy(), first.outcome.copy(), second.outcome.copy()]
    for i in range(3):
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
    return ""


def _run_frame(mut rt: UdfRuntime, c: Case) raises -> String:
    var b = _bind(rt, c, 1)
    var res = rt.run_frame(b.insts[0], c.spec, c.inputs, c.options)
    _unbind(rt, b)
    var why = _check(res.outcome, c.expect)
    if why == "" and res.outcome.is_ok() and c.expect.batches:
        why = _same_batches(res.outputs, c.expect.batches.value())
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
    _unbind(rt, b)
    if len(bad) > 0:
        return _check(bad[0], c.expect)
    var why = _check(Outcome.of(OK), c.expect)
    if why == "" and c.expect.column:
        why = same_column(result_col, c.expect.column.value())
    return why


def run_case(mut rt: UdfRuntime, c: Case) raises -> String:
    """"" when case `c` passes on `rt`; otherwise why it failed."""
    if c.run == "validate":
        return _check(rt.validate(c.spec), c.expect, False)
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


def _ledger_check(rt: UdfRuntime, before_exported: Int, before_released: Int, before_double: Int, before_schemas: Int, before_streams: Int, before_streams_released: Int, before_reserved: Int) -> String:
    var a = rt.ledger()
    var exported = a.exported - before_exported
    var released = a.released - before_released
    if released != exported:
        return String(exported) + " arrays exported to the runtime, " + String(released) + " released"
    if a.double_released != before_double:
        return "an array was released twice"
    if a.schemas_released != before_schemas:
        return "a borrowed schema was released by the runtime"
    if a.streams_released - before_streams_released != a.streams_exported - before_streams:
        return "an input stream was not released"
    if a.reserved_bytes != before_reserved:
        return (
            String(a.reserved_bytes - before_reserved) + " bytes the runtime reserved are still held:"
            + " an output or an error the host never released, or a runtime leak"
        )
    return ""


def _capabilities(mut rt: UdfRuntime) raises -> CaseResult:
    var caps = rt.describe()
    var why = String("")
    if not runtime_id_ok(caps.runtime_id):
        why = "runtime id '" + caps.runtime_id + "' is not <namespace>/<name>"
    elif caps.devices & DEVICE_CPU == 0:
        why = "devices lacks CPU"
    elif caps.transports & TRANSPORT_IN_PROCESS == 0:
        why = "transports lacks IN_PROCESS, and the in-process path is what this suite drives"
    elif caps.threading < THREAD_SAFE or caps.threading > SINGLE_THREAD:
        why = "threading " + String(caps.threading) + " is none of THREAD_SAFE, CONTEXT_PER_THREAD, SINGLE_THREAD"
    elif caps.udf_class == CLASS_NATIVE and caps.hosting != HOSTING_NONE:
        why = "a NATIVE runtime reports hosting 0, not " + String(caps.hosting)
    elif caps.udf_class == CLASS_MANAGED and caps.hosting != HOSTING_EMBEDDED and caps.hosting != HOSTING_HOST_INTERPRETER:
        why = "a MANAGED runtime reports hosting EMBEDDED or HOST_INTERPRETER, not " + String(caps.hosting)
    elif caps.udf_class != CLASS_NATIVE and caps.udf_class != CLASS_MANAGED:
        why = "udf_class " + String(caps.udf_class) + " is neither NATIVE nor MANAGED"
    elif not rt.feature_slots_agree():
        why = "the MEMORY_REPORT feature bit and the memory_report entry disagree"
    return CaseResult("capabilities", "PASS" if why == "" else "FAIL", why)


def run_suite(runtime_path: String, cases: List[Case], code: CodeSet = CodeSet.none()) raises -> Report:
    """Open the runtime library at `runtime_path` and run every case on it.
    A case that raises fails with the error as its reason; the suite goes
    on. A non-empty `code` replaces every case's code root and code objects
    (the same for every case: how a runtime that executes code objects
    gets them). Such a runtime may open its code objects at their first use
    and hold them, with what they reserved, until shutdown (the native
    runtime's libraries); so one validate before the first case opens them,
    and that open is not charged to a case's ledger. A runtime's own tests
    check that its shutdown returns what it held (the native runtime's
    test_leaks)."""
    var rt = UdfRuntime.open(runtime_path)
    var report = Report()
    var caps = rt.describe()
    report.runtime_id = caps.runtime_id
    report.results.append(_capabilities(rt))
    if len(code.objects) > 0 and len(cases) > 0:
        var first = cases[0].spec.copy()
        first.code_root = code.root
        first.code = code.objects.copy()
        _ = rt.validate(first)
    for i in range(len(cases)):
        var c = cases[i].copy()
        if len(code.objects) > 0:
            c.spec.code_root = code.root
            c.spec.code = code.objects.copy()
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
        if why == "":
            why = _ledger_check(
                rt, l.exported, l.released, l.double_released, l.schemas_released, l.streams_exported,
                l.streams_released, l.reserved_bytes,
            )
        if why != "":
            why += " [defect caught: " + c.defect + "]"
        report.results.append(CaseResult(c.name, "PASS" if why == "" else "FAIL", why))
    rt.shutdown()
    return report^
