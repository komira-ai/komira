# The native runtime's own cases (docs/design/udf_runtime_interface.md
# section 6.3, the mode 1 rows), driven through the C ABI with crafted
# libraries. The corpus cannot hold them: each needs a library built to be
# refused.
#
# What it proves and the defect each part catches:
#   - digest: a library whose bytes do not match its sha256 is refused with
#     ERR_CODE_DIGEST (OPTIMIZED_UDF_CODE_DIGEST_MISMATCH) by validate and by
#     load, and the loader maps no object for it; a matching copy of the same
#     library then loads and maps one, so the count can see a load (machine
#     code loaded before its digest was checked; a refusal remembered, so a
#     good copy is refused too).
#   - platform: a spec whose only library is for another platform is refused
#     by validate with ERR_UNSUPPORTED (OPTIMIZED_UDF_KIND_UNSUPPORTED)
#     naming this host's platform, with no object mapped; with a library for
#     each platform, the other platform's listed first and absent, load takes
#     this host's (a wrong-platform library loaded, or the first one taken).
#   - symbols: a runtime library (echo.so, which exports only the runtime
#     symbol) and a library exporting both symbols are refused with ERR_LOAD
#     naming the runtime symbol (a runtime and a user library confused).
#   - capabilities: a library reporting thread_affine 1, and one reporting
#     another runtime_id and udf_class MANAGED, are refused with ERR_LOAD
#     naming the capability (a library bound to concurrency it cannot take).
#   - a code object that is absent, a malformed role, a form other than
#     BUNDLE and a spec with no code object, each refused by name.
#   - two libraries in one runtime and one context: the C and the Mojo
#     library each serve `double` through their own library context inside
#     the runtime's one context, and a second load of a library maps nothing
#     new (libraries shared or confused inside a context; a library opened
#     twice).
# Mutants planted in native_runtime.c, each red here: the verified bytes'
# memory file dlopened before the digest compare ("a library was mapped
# before its digest was checked"); the runtime-symbol check skipped (echo.so
# refused for the wrong reason, both_symbols.so loaded); the library's
# describe not checked (the thread-affine library loaded); the first code
# object taken whatever its platform (validate accepts another platform's
# library); the memory file closed after dlopen, so the next library's
# /proc/self/fd/<n> names the one already loaded and dlopen returns it (echo.so
# "loads" as the C library loaded before it: the bug the first version of the
# runtime had, which this test found).

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, CodeObject, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64
from komira_udf_spike_native.code import (
    digest_of,
    host_role,
    loaded_objects,
    other_role,
    stage,
    stage_under,
)


def _spec(root: String, var objects: List[CodeObject], form: Int32 = FORM_BUNDLE) -> UdfSpec:
    var s = UdfSpec(SHAPE_SCALAR, "double", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)])
    s.code_root = root
    s.code = objects^
    s.form = form
    return s^


def _refused(got: Outcome, status: Int32, words: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_true(words in got.message, what + ": message '" + got.message + "' lacks '" + words + "'")


def _double(mut rt: UdfRuntime, spec: UdfSpec) raises:
    """Load `spec`, call it on [1, 2, 3] in a context of its own, and check
    [2, 4, 6]."""
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), "open_instance: " + String(inst.outcome))
    var b = Batch(3)
    var col = Column(TYPE_INT64)
    for v in range(1, 4):
        col.append_int(Int64(v))
    b.columns.append(col^)
    var res = rt.call_batch(inst.handle, spec, b, CallOptions.plain())
    assert_true(res.outcome.is_ok(), "call_batch: " + String(res.outcome))
    assert_equal(String(res.column), "int64[2, 4, 6]")
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)


def _digest(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var want = digest_of("./native_c.so")
    var bad = _spec(tmp + "/bad", [stage_under("./native_mojo.so", tmp + "/bad", host_role(), want)])
    var before = loaded_objects()
    _refused(rt.validate(bad), ERR_CODE_DIGEST, "do not match", "validate, mismatched bytes")
    var l = rt.load(bad)
    _refused(l.outcome, ERR_CODE_DIGEST, "do not match", "load, mismatched bytes")
    assert_equal(l.outcome.run_error(False), "OPTIMIZED_UDF_CODE_DIGEST_MISMATCH")
    assert_equal(loaded_objects(), before, "a library was mapped before its digest was checked")
    var good = _spec(tmp + "/good", [stage("./native_c.so", tmp + "/good", host_role())])
    _double(rt, good)
    assert_true(loaded_objects() > before, "the verified library's load mapped no object")
    rt.shutdown()


def _platform(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/platform"
    var other = _spec(root, [stage("./native_c.so", root, other_role())])
    var before = loaded_objects()
    var v = rt.validate(other)
    _refused(v, ERR_UNSUPPORTED, host_role(), "validate, another platform's library only")
    assert_equal(v.run_error(False), "OPTIMIZED_UDF_KIND_UNSUPPORTED")
    _refused(rt.load(other).outcome, ERR_UNSUPPORTED, host_role(), "load, another platform's library only")
    assert_equal(loaded_objects(), before, "another platform's library was mapped")
    # The other platform's library first, and absent from the code root.
    var absent = CodeObject(other_role(), digest_of("./native_mojo.so"))
    _double(rt, _spec(root, [absent^, stage("./native_c.so", root, host_role())]))
    rt.shutdown()


def _symbols(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/symbols"
    var runtime_lib = _spec(root, [stage("./echo.so", root, host_role())])
    _refused(rt.load(runtime_lib).outcome, ERR_LOAD, "komira_udf_runtime_init_v1", "a runtime library")
    var both = _spec(root, [stage("./both_symbols.so", root, host_role())])
    _refused(rt.validate(both), ERR_LOAD, "komira_udf_runtime_init_v1", "a library exporting both symbols")
    _refused(rt.load(both).outcome, ERR_LOAD, "komira_udf_runtime_init_v1", "a library exporting both symbols")
    rt.shutdown()


def _capabilities(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/capabilities"
    var affine = _spec(root, [stage("./native_c_affine.so", root, host_role())])
    var l = rt.load(affine)
    _refused(l.outcome, ERR_LOAD, "thread_affine", "a thread-affine library")
    assert_equal(l.outcome.run_error(False), "OPTIMIZED_UDF_CODE_UNLOADABLE")
    var managed = _spec(root, [stage("./echo_as_library.so", root, host_role())])
    _refused(rt.load(managed).outcome, ERR_LOAD, "runtime_id", "a library of another runtime id")
    rt.shutdown()


def _malformed(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/malformed"
    var absent = _spec(root, [CodeObject(host_role(), digest_of("./native_mojo.so"))])
    _refused(rt.load(absent).outcome, ERR_LOAD, "missing", "an absent code object")
    var role = _spec(root, [stage("./native_c.so", root, "x86_64")])
    _refused(rt.validate(role), ERR_DESCRIPTOR, "lib:<os>-<cpu>", "a malformed role")
    var value = _spec(root, [stage("./native_c.so", root, host_role())], FORM_VALUE)
    _refused(rt.validate(value), ERR_DESCRIPTOR, "BUNDLE", "form VALUE")
    _refused(rt.validate(_spec(root, List[CodeObject]())), ERR_UNSUPPORTED, host_role(), "no code object")
    rt.shutdown()


def _two_libraries(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/two"
    var spec_c = _spec(root, [stage("./native_c.so", root, host_role())])
    var spec_m = _spec(root, [stage("./native_mojo.so", root, host_role())])
    var u_c = rt.load(spec_c)
    var u_m = rt.load(spec_m)
    assert_true(u_c.outcome.is_ok() and u_m.outcome.is_ok(), String(u_c.outcome) + " / " + String(u_m.outcome))
    var ctx = rt.open_context(0)
    var i_c = rt.open_instance(ctx.handle, u_c.handle)
    var i_m = rt.open_instance(ctx.handle, u_m.handle)
    var b = Batch(3)
    var col = Column(TYPE_INT64)
    for v in range(1, 4):
        col.append_int(Int64(v))
    b.columns.append(col^)
    var r_c = rt.call_batch(i_c.handle, spec_c, b, CallOptions.plain())
    var r_m = rt.call_batch(i_m.handle, spec_m, b, CallOptions.plain())
    assert_equal(String(r_c.column), "int64[2, 4, 6]", "the C library in a shared context: " + String(r_c.outcome))
    assert_equal(String(r_m.column), "int64[2, 4, 6]", "the Mojo library in a shared context: " + String(r_m.outcome))
    var before = loaded_objects()
    var again = rt.load(spec_c)
    assert_true(again.outcome.is_ok())
    assert_equal(loaded_objects(), before, "a second load of one library mapped it again")
    rt.unload(again.handle)
    rt.close_instance(i_c.handle)
    rt.close_instance(i_m.handle)
    rt.close_context(ctx.handle)
    rt.unload(u_c.handle)
    rt.unload(u_m.handle)
    rt.shutdown()


def main() raises:
    var tmp = getenv("TMPDIR")
    _digest(tmp)
    _platform(tmp)
    _symbols(tmp)
    _capabilities(tmp)
    _malformed(tmp)
    _two_libraries(tmp)
    print("test_native_loader: ok")
