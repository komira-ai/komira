# The native runtime's own cases (docs/design/udf_runtime_interface.md
# section 6.3, the mode 1 rows), driven through the C ABI with crafted
# libraries. The corpus cannot hold them: each needs a library built to be
# refused.
#
# What it proves and the defect each part catches:
#   - digest: a library whose bytes do not match its sha256 is refused with
#     ERR_CODE_DIGEST (OPTIMIZED_UDF_CODE_DIGEST_MISMATCH) by validate and by
#     load, and the loader maps no object for it; so are the C library's own
#     bytes under its digest with the last byte flipped, and its bytes with
#     the last byte flipped under its true digest; a matching copy then loads
#     and maps one, so the count can see a load (machine code loaded before
#     its digest was checked; a compare of part of the digest; a refusal
#     remembered, so a good copy is refused too).
#   - SHA-256 known answers: files of 0, 1, 55, 56, 63, 64, 65, 119, 120,
#     127 and 128 bytes, each staged under its sha256 from komira_crypto, are
#     refused for failing dlopen (ERR_LOAD), never for their digest (the
#     runtime's own SHA-256 wrong at a padding boundary, where a refused
#     good library would otherwise go unseen).
#   - platform: a spec whose only library is for another platform is refused
#     by validate with ERR_UNSUPPORTED (OPTIMIZED_UDF_KIND_UNSUPPORTED)
#     naming this host's platform, with no object mapped; with a library for
#     each platform, the other platform's listed first and absent, load takes
#     this host's (a wrong-platform library loaded, or the first one taken).
#   - symbols: a runtime library (echo.so, which exports only the runtime
#     symbol) and a library exporting both symbols are refused with ERR_LOAD
#     naming the runtime symbol (a runtime and a user library confused).
#   - capabilities: libraries that each differ from the C library in one
#     describe field (native/variant_lib.c and native_c_affine) are refused
#     with ERR_LOAD naming that field: thread_affine 1, threading
#     SINGLE_THREAD, transports without IN_PROCESS, global_lock 1, udf_class
#     MANAGED; and one of another runtime_id (a library bound to concurrency
#     or a transport it cannot take; one arm of the check dropped).
#   - table: a library whose table reports ABI major 2, and one whose table's
#     struct_size ends before a required entry, are refused with ERR_ABI
#     naming which (a library table read past its end or in another ABI).
#   - shapes: a library whose describe lacks SCALAR loads a column UDF but
#     is refused at load, ERR_LOAD naming the shapes, for a SCALAR spec (a
#     UDF bound to a library without its shape).
#   - a code object that is absent, a malformed role, a form other than
#     BUNDLE and a spec with no code object, each refused by name.
#   - three libraries in one runtime and one context: the C library, the
#     Mojo library and the counted library each serve `double` inside the
#     runtime's one context; the counted library refuses any context it did
#     not open (its instance opened after the C library's, so a runtime
#     handing every library the first library context fails it), its context
#     holds a host reservation until the runtime's context is closed and not
#     after (a library context leaked), and a second load of a library maps
#     nothing new (a library opened twice).
# Mutants planted in native_runtime.c, each red here: the verified bytes'
# memory file dlopened before the digest compare ("a library was mapped
# before its digest was checked"); the runtime-symbol check skipped (echo.so
# refused for the wrong reason, both_symbols.so loaded); the library's
# describe not checked (the thread-affine library loaded); the first code
# object taken whatever its platform (validate accepts another platform's
# library); the memory file closed after dlopen, so the next library's
# /proc/self/fd/<n> names the one already loaded and dlopen returns it (echo.so
# "loads" as the C library loaded before it: the bug the first version of the
# runtime had, which this test found). Mutants planted in review, each red
# here: the threading, IN_PROCESS and udf_class arms and the table's ABI
# major and struct_size checks each dropped; the shape check at load
# dropped; the digest compared on its first byte only; the padding test
# `rest < 56` made `rest < 55`; the library context found without matching
# the library; close_context not forwarded to the library contexts.

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, CodeObject, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64

from komira_udf_spike_native.code import (
    bytes_of,
    digest_of,
    host_role,
    loaded_objects,
    other_role,
    sha256_of,
    stage,
    stage_data,
    stage_under,
)


def _ints_1_2_3() -> Batch:
    var b = Batch(3)
    var col = Column(TYPE_INT64)
    for v in range(1, 4):
        col.append_int(Int64(v))
    b.columns.append(col^)
    return b^


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
    var b = _ints_1_2_3()
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
    # Near misses: the C library's bytes under its digest with the last byte
    # flipped, and its bytes with the last byte flipped under its digest.
    var c_bytes = bytes_of("./native_c.so")
    var near = want.copy()
    near[31] ^= 1
    var last_digest = _spec(tmp + "/near", [stage_data(c_bytes, tmp + "/near", host_role(), near)])
    _refused(rt.load(last_digest).outcome, ERR_CODE_DIGEST, "do not match", "a digest whose last byte differs")
    var flipped = c_bytes.copy()
    flipped[len(flipped) - 1] ^= 1
    var last_byte = _spec(tmp + "/flip", [stage_data(flipped, tmp + "/flip", host_role(), want)])
    _refused(rt.load(last_byte).outcome, ERR_CODE_DIGEST, "do not match", "bytes whose last byte differs")
    assert_equal(loaded_objects(), before, "a near-miss library was mapped")
    var good = _spec(tmp + "/good", [stage("./native_c.so", tmp + "/good", host_role())])
    _double(rt, good)
    assert_true(loaded_objects() > before, "the verified library's load mapped no object")
    rt.shutdown()


def _sha256_lengths(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/lengths"
    var lengths: List[Int] = [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128]
    for n in lengths:
        var data = List[UInt8]()
        for i in range(n):
            data.append(UInt8((i * 7 + n) & 255))
        var spec = _spec(root, [stage_data(data, root, host_role(), sha256_of(data))])
        _refused(rt.validate(spec), ERR_LOAD, "dlopen", "a file of " + String(n) + " bytes under its sha256")
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
    var libs: List[String] = [
        "./variant_single_thread.so",
        "./variant_worker_only.so",
        "./variant_global_lock.so",
        "./variant_managed.so",
    ]
    var fields: List[String] = ["threading", "IN_PROCESS", "global_lock", "udf_class"]
    for i in range(len(libs)):
        var spec = _spec(root, [stage(libs[i], root, host_role())])
        _refused(rt.load(spec).outcome, ERR_LOAD, fields[i], libs[i])
    rt.shutdown()


def _table(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/table"
    var abi2 = _spec(root, [stage("./variant_abi2.so", root, host_role())])
    _refused(rt.load(abi2).outcome, ERR_ABI, "ABI major 1", "a library table of ABI major 2")
    var short = _spec(root, [stage("./variant_short_table.so", root, host_role())])
    _refused(rt.validate(short), ERR_ABI, "struct_size", "a library table ending before a required entry")
    rt.shutdown()


def _shapes(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/shapes"
    var obj = stage("./variant_no_scalar.so", root, host_role())
    var column = UdfSpec(
        SHAPE_MAP_BATCHES_COLUMN, "identity", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)]
    )
    column.code_root = root
    column.code = [obj.copy()]
    var u = rt.load(column)
    assert_true(u.outcome.is_ok(), "a column UDF on the library without SCALAR: " + String(u.outcome))
    rt.unload(u.handle)
    _refused(rt.load(_spec(root, [obj^])).outcome, ERR_LOAD, "shapes", "a SCALAR UDF on a library without SCALAR")
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


def _three_libraries(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/three"
    var spec_c = _spec(root, [stage("./native_c.so", root, host_role())])
    var spec_m = _spec(root, [stage("./native_mojo.so", root, host_role())])
    var spec_k = _spec(root, [stage("./variant_counted.so", root, host_role())])
    var u_c = rt.load(spec_c)
    var u_m = rt.load(spec_m)
    var u_k = rt.load(spec_k)
    assert_true(
        u_c.outcome.is_ok() and u_m.outcome.is_ok() and u_k.outcome.is_ok(),
        String(u_c.outcome) + " / " + String(u_m.outcome) + " / " + String(u_k.outcome),
    )
    var reserved = rt.reserved_bytes()
    var ctx = rt.open_context(0)
    var i_c = rt.open_instance(ctx.handle, u_c.handle)
    var i_m = rt.open_instance(ctx.handle, u_m.handle)
    var i_k = rt.open_instance(ctx.handle, u_k.handle)
    assert_true(i_c.outcome.is_ok() and i_m.outcome.is_ok(), String(i_c.outcome) + " / " + String(i_m.outcome))
    assert_true(i_k.outcome.is_ok(), "the counted library given a context it did not open: " + String(i_k.outcome))
    assert_true(rt.reserved_bytes() > reserved, "the counted library's context reserved nothing")
    var b = _ints_1_2_3()
    var r_c = rt.call_batch(i_c.handle, spec_c, b, CallOptions.plain())
    var r_m = rt.call_batch(i_m.handle, spec_m, b, CallOptions.plain())
    var r_k = rt.call_batch(i_k.handle, spec_k, b, CallOptions.plain())
    assert_equal(String(r_c.column), "int64[2, 4, 6]", "the C library in a shared context: " + String(r_c.outcome))
    assert_equal(String(r_m.column), "int64[2, 4, 6]", "the Mojo library in a shared context: " + String(r_m.outcome))
    assert_equal(
        String(r_k.column), "int64[2, 4, 6]", "the counted library in a shared context: " + String(r_k.outcome)
    )
    var before = loaded_objects()
    var again = rt.load(spec_c)
    assert_true(again.outcome.is_ok())
    assert_equal(loaded_objects(), before, "a second load of one library mapped it again")
    rt.unload(again.handle)
    rt.close_instance(i_c.handle)
    rt.close_instance(i_m.handle)
    rt.close_instance(i_k.handle)
    rt.close_context(ctx.handle)
    assert_equal(rt.reserved_bytes(), reserved, "a library context outlived the runtime's context")
    rt.unload(u_c.handle)
    rt.unload(u_m.handle)
    rt.unload(u_k.handle)
    rt.shutdown()


def main() raises:
    var tmp = getenv("TMPDIR")
    _digest(tmp)
    _sha256_lengths(tmp)
    _platform(tmp)
    _symbols(tmp)
    _capabilities(tmp)
    _table(tmp)
    _shapes(tmp)
    _malformed(tmp)
    _three_libraries(tmp)
    print("test_native_loader: ok")
