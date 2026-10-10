# The harness's own refusals and tables, apart from any case.
#
# What it proves and the defect each part catches:
#   - the status table: every status of the header has a name that maps back
#     to it, and each maps to the run error design section 4.5 gives it, with
#     ERR_UNSUPPORTED an admission refusal from validate and a runtime fault
#     from a call (a status renamed or mapped to another run's error);
#   - the runtime id grammar `<namespace>/<name>`, each part
#     `[a-z0-9][a-z0-9._-]{0,62}` (an id the design refuses accepted, or the
#     reverse);
#   - the case reader refuses, by name, a case it cannot run (a typo in a
#     case read as a default and passing vacuously);
#   - UdfRuntime.open refuses a missing library, a library without the init
#     export, and a runtime that refuses the host's ABI major, each by name;
#     and a runtime reporting THREAD_SAFE with global_lock 1
#     (echo_global_lock.so), naming both capabilities (design section 4.2: a
#     runtime with a global lock bound as a parallel virtual machine);
#   - a handle passed to an entry of another kind is refused before the
#     runtime sees it; a run the reader does not know is refused;
#   - memory_report reaches the optional entry (echo reports 0);
#   - every entry refuses a handle of another kind (a check dropped from one
#     entry lets a runtime read one handle as another);
#   - through echo_variant.so (echo with one thing wrong or at an edge,
#     refrt/echo_variants.inc): UdfRuntime.open refuses a table of another
#     major, a table short of a required entry, a describe that fails, and a
#     runtime the variant library cannot name; it opens a table that stops
#     before the optional entry (and reads that entry as absent) and a
#     CONTEXT_PER_THREAD runtime with global_lock 1; init_refusal reports an
#     init that accepts another major; both release an error init filled on
#     success (error_on_ok_init: the reserved bytes return to 0, a release
#     skipped on success caught); and the capability check fails each
#     describe answer that breaks one of its rules, for that rule, and passes
#     each legal edge (SINGLE_THREAD, NATIVE with hosting 0,
#     HOST_INTERPRETER, no MEMORY_REPORT with no entry).
# Mutants planted: runtime_id_ok accepting upper-case letters (A to Z among
# the alphanumerics): red ("upper case"). UdfRuntime.open not reading
# global_lock: red (echo_global_lock.so opens). The mutants of the variant
# and handle checks are listed with this file in the pull request's sweep
# table.

from std.os import setenv
from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_abi.cases import Case, parse_case
from komira_udf_spike_abi.conform import CaseResult, Report, load_cases, run_case, run_suite, runtime_id_ok
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, Outcome, UdfRuntime
from komira_udf_spike_abi.values import Batch, Column, TYPE_INT32

comptime VARIANT = "./echo_variant.so"
comptime MALFORMED = "src/tests/helpers/komira_udf_spike_abi/tests/data/malformed"
"""A directory holding one case file that is not JSON."""


def _raises_with(text: String, name: String) raises:
    var msg = String()
    try:
        _ = parse_case(text)
    except e:
        msg = String(e)
    assert_true(name in msg, "expected " + name + ", got '" + msg + "' for " + text)


def _statuses() raises:
    var want: List[String] = [
        "",
        "UDF_RUNTIME_FAULT",
        "OPTIMIZED_UDF_DESCRIPTOR_INVALID",
        "UDF_RUNTIME_FAULT",
        "OPTIMIZED_UDF_CODE_DIGEST_MISMATCH",
        "OPTIMIZED_UDF_CODE_UNLOADABLE",
        "UDF_RAISED",
        "UDF_RETURN_TYPE_MISMATCH",
        "UDF_BATCH_LENGTH_MISMATCH",
        "UDF_STATE_TOO_LARGE",
        "UDF_GROUP_TOO_LARGE",
        "UDF_CANCELLED",
        "UDF_DEADLINE_EXCEEDED",
        "UDF_OUT_OF_MEMORY",
        "UDF_INSTANCE_LOST",
        "UDF_RUNTIME_FAULT",
        "UDF_FIELD_NOT_DECLARED",
    ]
    assert_equal(len(want), STATUS_COUNT)
    for c in range(STATUS_COUNT):
        var name = status_name(Int32(c))
        assert_false(name.startswith("UNKNOWN"), "status " + String(c) + " has no name")
        assert_equal(Int(status_from_name(name)), c)
        assert_equal(run_error(Int32(c), True), want[c], name)
    assert_equal(run_error(ERR_UNSUPPORTED, False), "OPTIMIZED_UDF_KIND_UNSUPPORTED")
    assert_equal(run_error(Int32(STATUS_COUNT), True), "UDF_RUNTIME_FAULT", "an unknown status")
    assert_equal(status_name(Int32(STATUS_COUNT)), "UNKNOWN(17)")
    var msg = String()
    try:
        _ = status_from_name("ERR_NOPE")
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_STATUS_UNKNOWN"), msg)
    var shapes: List[String] = [
        "SCALAR", "ROW", "MAP_BATCHES_COLUMN", "MAP_BATCHES_FRAME", "MAP_BATCHES_FRAME_GROUPED",
        "AGG_PLAIN", "AGG_MERGEABLE", "STEP",
    ]
    for i in range(len(shapes)):
        assert_equal(Int(shape_from_name(shapes[i])), 1 << i, shapes[i])


def _runtime_ids() raises:
    assert_true(runtime_id_ok("komira-test/echo"))
    assert_true(runtime_id_ok("example.org/a_b-c.d"))
    assert_true(runtime_id_ok("0/9"))
    assert_true(runtime_id_ok("z/z"), "the last letter")
    var long_ok = String("a")
    for _ in range(62):
        long_ok += "b"
    assert_true(runtime_id_ok(long_ok + "/x"), "a 63-byte part")
    assert_false(runtime_id_ok(long_ok + "b/x"), "a 64-byte part")
    assert_false(runtime_id_ok("Komira/x"), "upper case")
    assert_false(runtime_id_ok("komira"), "no slash")
    assert_false(runtime_id_ok("a/b/c"), "two slashes")
    assert_false(runtime_id_ok("-a/b"), "a part starting with '-'")
    assert_false(runtime_id_ok("a/.b"), "a part starting with '.'")
    assert_false(runtime_id_ok("a/"), "an empty name")
    assert_false(runtime_id_ok("a/b c"), "a space")


def _case_refusals() raises:
    var ok = '{"name": "n", "defect": "d", "run": "validate", "entry": "e", "expect": {"status": "OK"}}'
    var c = parse_case(ok)
    assert_equal(c.name, "n")
    _raises_with('{"defect": "d", "run": "validate", "expect": {}}', "JsonError")
    _raises_with('{"name": "n", "defect": "d", "run": "validate", "shape": "NOPE", "expect": {}}', "UDF_SHAPE_UNKNOWN")
    _raises_with('{"name": "n", "defect": "d", "run": "validate", "form": "NOPE", "expect": {}}', "UDF_CASE_MALFORMED")
    _raises_with('{"name": "n", "defect": "d", "run": "validate", "stability": "NOPE", "expect": {}}', "UDF_CASE_MALFORMED")
    _raises_with('{"name": "n", "defect": "d", "run": "validate", "expect": {"status": "NOPE"}}', "UDF_STATUS_UNKNOWN")
    _raises_with(
        '{"name": "n", "defect": "d", "run": "validate", "args": [{"type": "int8"}], "expect": {}}',
        "UDF_TYPE_UNKNOWN",
    )
    _raises_with(
        '{"name": "n", "defect": "d", "run": "call_batch", "input": {"length": 2, "columns":'
        + ' [{"type": "int64", "values": [1]}]}, "expect": {}}',
        "UDF_CASE_MALFORMED",
    )
    _raises_with(
        '{"name": "n", "defect": "d", "run": "call_batch", "input": {"length": 0, "columns":'
        + ' [{"type": "int64", "values": [], "repeat": 0}]}, "expect": {}}',
        "UDF_CASE_MALFORMED",
    )
    var msg = String()
    try:
        _ = load_cases(MALFORMED)
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_CASE_MALFORMED") and "bad.json" in msg, "a file that is not a case: " + msg)


def _value_text() raises:
    """The values the harness reports, and their text (a report's lines are
    what a reader of a failed suite sees)."""
    var ok = Outcome.of(OK)
    assert_equal(ok.row, -1)
    assert_equal(ok.group, -1)
    assert_equal(String(ok), "OK")
    assert_equal(String(Outcome(ERR_RAISED, "", "", -1, -1, "")), "ERR_RAISED")
    assert_equal(
        String(Outcome(ERR_RAISED, "m", "", 0, -1, "UDF_RUNTIME_FAULT: x")),
        "ERR_RAISED 'm' row=0 fault=UDF_RUNTIME_FAULT: x",
    )
    var p = CallOptions.plain()
    assert_false(p.cancel or p.cancel_during_call or p.deadline_passed, "plain options set something")
    assert_equal(String(CaseResult("a", "PASS", "")), "PASS a")
    assert_equal(String(CaseResult("b", "FAIL", "why")), "FAIL b: why")
    var r = Report()
    r.runtime_id = "x/y"
    r.results.append(CaseResult("a", "PASS", ""))
    r.results.append(CaseResult("b", "FAIL", "why"))
    assert_equal(String(r), "runtime x/y: 1 pass, 1 fail, 0 skip\n  PASS a\n  FAIL b: why\n")


def _ok_drops_error_text() raises:
    """An error a runtime filled and then returned OK on is released, and
    the OK outcome carries none of it (UdfRuntime._outcome)."""
    var rt = UdfRuntime.open("./echo.so")
    var c = parse_case(
        '{"name": "n", "defect": "d", "run": "call_batch", "entry": "error_on_ok", "shape": "MAP_BATCHES_COLUMN",'
        + ' "args": [{"type": "int64"}], "result": [{"type": "int64"}],'
        + ' "input": {"length": 1, "columns": [{"type": "int64", "values": [4]}]}, "expect": {}}'
    )
    var udf = rt.load(c.spec)
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, udf.handle)
    var res = rt.call_batch(inst.handle, c.spec, c.input, c.options)
    assert_true(res.outcome.is_ok(), String(res.outcome))
    assert_equal(res.outcome.message, "", "an OK outcome kept the error's message")
    assert_equal(res.outcome.row, -1)
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(udf.handle)
    rt.shutdown()


def _open_refusals() raises:
    var msg = String()
    try:
        _ = UdfRuntime.open("./no_such_runtime.so")
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_RUNTIME_OPEN_FAILED"), msg)
    msg = String()
    try:
        _ = UdfRuntime.open("libc.so.6")
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_RUNTIME_MISSING_SYMBOL"), msg)
    msg = String()
    try:
        _ = UdfRuntime.open("./echo.so", ABI_MAJOR + 1)
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_RUNTIME_INIT") and "ERR_ABI" in msg, msg)
    msg = String()
    try:
        _ = UdfRuntime.open("./echo_global_lock.so")
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("UDF_RUNTIME_FAULT") and "THREAD_SAFE" in msg and "global_lock 1" in msg, msg
    )


def _handles_and_runs() raises:
    var rt = UdfRuntime.open("./echo.so")
    var caps = rt.describe()
    assert_equal(caps.udf_class, CLASS_MANAGED)
    assert_equal(caps.threading, THREAD_SAFE)
    assert_equal(caps.global_lock, 0)
    assert_true(caps.has_memory_report)
    var ctx = rt.open_context(0)
    assert_true(ctx.outcome.is_ok())
    assert_equal(rt.memory_report(ctx.handle), 0)
    var msg = String()
    try:
        rt.unload(ctx.handle)
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_HARNESS_HANDLE_KIND"), msg)
    rt.close_context(ctx.handle)
    var c = parse_case('{"name": "n", "defect": "d", "run": "nope", "expect": {}}')
    msg = String()
    try:
        _ = run_case(rt, c)
    except e:
        msg = String(e)
    assert_true(msg.startswith("UDF_CASE_MALFORMED"), msg)
    # Echo reserves its runtime struct through the host while it is up and
    # returns it at shutdown: shutdown reached the runtime, once.
    assert_true(rt.ledger().reserved_bytes > 0, "echo holds its runtime while it is up")
    rt.shutdown()
    assert_equal(rt.ledger().reserved_bytes, 0, "shutdown did not reach the runtime")
    rt.shutdown()
    assert_equal(rt.ledger().reserved_bytes, 0, "a second shutdown reached the runtime")


def _kind(e: Error) -> Int:
    """1 when `e` is the harness's handle-kind refusal."""
    return 1 if String(e).startswith("UDF_HARNESS_HANDLE_KIND") else 0


def _handle_kinds() raises:
    """Each entry of UdfRuntime given a handle of another kind."""
    var rt = UdfRuntime.open("./echo.so")
    var c = parse_case(
        '{"name": "n", "defect": "d", "run": "call_batch", "entry": "identity", "shape": "MAP_BATCHES_COLUMN",'
        + ' "args": [{"type": "int64"}], "result": [{"type": "int64"}], "expect": {}}'
    )
    var udf = rt.load(c.spec)
    assert_true(udf.outcome.is_ok(), String(udf.outcome))
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, udf.handle)
    assert_true(inst.outcome.is_ok(), String(inst.outcome))
    var u = udf.handle.copy()
    var x = ctx.handle.copy()
    var i = inst.handle.copy()
    var none = CallOptions.plain()
    var gids = List[Int32]()
    var refused = 0
    try:
        rt.unload(x)
    except e:
        refused += _kind(e)
    try:
        rt.close_context(u)
    except e:
        refused += _kind(e)
    try:
        _ = rt.open_instance(u, u)
    except e:
        refused += _kind(e)
    try:
        _ = rt.open_instance(x, x)
    except e:
        refused += _kind(e)
    try:
        rt.close_instance(x)
    except e:
        refused += _kind(e)
    try:
        _ = rt.memory_report(u)
    except e:
        refused += _kind(e)
    try:
        _ = rt.call_batch(x, c.spec, Batch(0), none)
    except e:
        refused += _kind(e)
    try:
        _ = rt.run_frame(x, c.spec, List[Batch](), none)
    except e:
        refused += _kind(e)
    try:
        _ = rt.agg_open(x)
    except e:
        refused += _kind(e)
    try:
        _ = rt.agg_update(i, Batch(0), gids, 0, none)
    except e:
        refused += _kind(e)
    try:
        _ = rt.agg_merge(i, Column(TYPE_INT32), gids, 0, none)
    except e:
        refused += _kind(e)
    try:
        _ = rt.agg_state(i, 0, c.spec.result[0])
    except e:
        refused += _kind(e)
    try:
        _ = rt.agg_finish(i, 0, c.spec.result[0])
    except e:
        refused += _kind(e)
    try:
        rt.agg_close(i)
    except e:
        refused += _kind(e)
    assert_equal(refused, 14, "entries that refused a handle of another kind")
    rt.close_instance(i)
    rt.close_context(x)
    rt.unload(u)
    rt.shutdown()


def _open_variant(name: String) raises -> UdfRuntime:
    _ = setenv("KOMIRA_UDF_ECHO_VARIANT", name)
    return UdfRuntime.open(VARIANT)


def _open_error(name: String) -> String:
    """UdfRuntime.open's error on variant `name`, or "" when it opens."""
    try:
        var rt = _open_variant(name)
        rt.shutdown()
    except e:
        return String(e)
    return ""


def _variants() raises:
    var msg = _open_error("no_such_variant")
    assert_true(msg.startswith("UDF_RUNTIME_INIT") and "names no variant" in msg, msg)
    msg = _open_error("table_major_2")
    assert_true(msg.startswith("UDF_RUNTIME_ABI") and "table major 2" in msg, msg)
    msg = _open_error("table_short")
    assert_true(msg.startswith("UDF_RUNTIME_ABI"), msg)
    msg = _open_error("describe_fails")
    assert_true(msg.startswith("UDF_RUNTIME_FAULT: describe returned"), msg)
    var rt = _open_variant("table_without_optional")
    assert_false(rt.describe().has_memory_report, "an entry past struct_size read as present")
    var ctx = rt.open_context(0)
    assert_equal(rt.memory_report(ctx.handle), -2, "memory_report called past struct_size")
    rt.close_context(ctx.handle)
    rt.shutdown()
    rt = _open_variant("per_thread_global_lock")
    var caps = rt.describe()
    assert_equal(caps.threading, CONTEXT_PER_THREAD)
    assert_equal(caps.global_lock, 1)
    rt.shutdown()
    rt = _open_variant("any_major")
    var o = rt.init_refusal(ABI_MAJOR + 1)
    assert_true(o.fault.startswith("UDF_RUNTIME_FAULT: init accepted ABI major"), String(o))
    assert_equal(o.row, -1)
    assert_equal(o.group, -1)
    # init fills the error and returns its table: UdfRuntime.open and
    # init_refusal still release it (design 4.4: once when non-NULL). The
    # variant reserves the error's strings through the host, and
    # init_refusal's host counts into the runtime's ledger, so a release
    # skipped on success leaves reserved bytes.
    var held = rt.ledger().reserved_bytes  # any_major: echo's runtime struct, held while it is up
    rt.shutdown()
    rt = _open_variant("error_on_ok_init")
    assert_equal(rt.ledger().reserved_bytes, held, "UdfRuntime.open kept the error init filled on success")
    o = rt.init_refusal(ABI_MAJOR + 1)
    assert_true(o.fault.startswith("UDF_RUNTIME_FAULT: init accepted ABI major"), String(o))
    # the runtime init_refusal's init created is shut down, and the error
    # released: the shared ledger is back where it was
    assert_equal(rt.ledger().reserved_bytes, held, "init_refusal kept the error init filled, or its runtime")
    rt.shutdown()
    var echo = UdfRuntime.open("./echo.so")
    o = echo.init_refusal(ABI_MAJOR + 1)
    assert_equal(o.fault, "", String(o))
    assert_equal(o.status, ERR_ABI)
    echo.shutdown()
    # name|PASS, or name|a fragment of the capability check's reason
    var want: List[String] = [
        "table_without_optional|PASS",
        "per_thread_global_lock|PASS",
        "single_thread|PASS",
        "native|PASS",
        "host_interpreter|PASS",
        "bad_id|runtime id 'Komira-test/echo'",
        "no_cpu|devices lacks CPU",
        "worker_only|transports lacks IN_PROCESS",
        "threading_0|threading 0 is none",
        "threading_4|threading 4 is none",
        "native_embedded|a NATIVE runtime reports hosting 0",
        "managed_hosting_0|a MANAGED runtime reports hosting EMBEDDED or HOST_INTERPRETER",
        "class_0|udf_class 0 is neither",
        "class_3|udf_class 3 is neither",
        "feature_without_entry|the MEMORY_REPORT feature bit and the memory_report entry disagree",
        "entry_without_feature|the MEMORY_REPORT feature bit and the memory_report entry disagree",
    ]
    for k in range(len(want)):
        var parts = want[k].split("|")
        var name = String(parts[0])
        var why = String(parts[1])
        _ = setenv("KOMIRA_UDF_ECHO_VARIANT", name)
        var r = run_suite(VARIANT, List[Case]()).result("capabilities")
        if why == "PASS":
            assert_equal(r.verdict, "PASS", name + ": " + r.reason)
        else:
            assert_equal(r.verdict, "FAIL", name + " passed the capability check")
            assert_true(why in r.reason, name + " failed for another reason: " + r.reason)


def main() raises:
    _statuses()
    _runtime_ids()
    _case_refusals()
    _open_refusals()
    _handles_and_runs()
    _handle_kinds()
    _variants()
    _value_text()
    _ok_drops_error_text()
    print("test_harness: ok")
