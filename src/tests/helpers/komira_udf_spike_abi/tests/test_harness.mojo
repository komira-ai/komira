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
#   - memory_report reaches the optional entry (echo reports 0).
# Mutants planted: runtime_id_ok accepting upper-case letters (A to Z among
# the alphanumerics): red ("upper case"). UdfRuntime.open not reading
# global_lock: red (echo_global_lock.so opens).

from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_abi.cases import parse_case
from komira_udf_spike_abi.conform import run_case, runtime_id_ok
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import UdfRuntime


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
    rt.shutdown()
    rt.shutdown()


def main() raises:
    _statuses()
    _runtime_ids()
    _case_refusals()
    _open_refusals()
    _handles_and_runs()
    print("test_harness: ok")
