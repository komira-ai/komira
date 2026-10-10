# The native runtime, and both libraries behind it, free what they allocate.
#
# A leak has no other effect a host can see, so this test reads the C heap
# (glibc's mallinfo2, native/probe.c) around the same calls made on the
# native runtime and on the echo runtime directly (echo.so, the reference
# runtime whose C fixtures are the C library's). The harness allocates the
# same for both, so the heap's growth over the same rounds must match.
#
# What it proves and the defect each part catches:
#   - handles: rounds of load, open_context, open_instance, call_batch, a
#     frame, a mergeable aggregate, every close and unload, plus the
#     library's refusals of a frame and groups on a scalar UDF and of an
#     unknown entry, a digest mismatch and a directory for a code object,
#     grow the heap by the same bytes behind native.so (with the C library,
#     and with the Mojo library) as on echo.so (a udf, context, instance,
#     frame or groups handle not freed, on success or on the library's
#     refusal, or a library's close not forwarded; a library context list
#     kept; the bytes read for a mismatched or unreadable code object, or a
#     refusal's message, never freed).
#   - the Mojo library's own blocks: it reserves every block from the host
#     while the block lives (its heap is not glibc's, so mallinfo2 cannot
#     see it); the reserved bytes are the same after the rounds as before
#     and zero after shutdown (a handle, scratch block or table not freed).
#   - instances the counted library refuses (slot 98) cost the runtime what
#     instances it opens and closes (slot 97) do (the runtime's instance
#     handle kept after the library refused).
#   - new libraries: a code object that fails dlopen, new each round, costs
#     the runtime its library record and no more (the bytes read, about
#     1 MiB, kept after the library failed to load).
#   - runtimes: rounds of open, a refused library, shutdown, cost nothing
#     (a library record or the runtime's handle not freed at shutdown).
# Mutants planted (the scorecard in the pull request lists each): every
# deleted free() of native_runtime.c whose block the tests reach, and the
# unload, close_instance, frame_close and agg_close forwards deleted: each
# red here.

from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, CodeObject, CodeSet, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64

from komira_udf_spike_native.code import (
    code_set,
    digest_of,
    heap_in_use,
    hex_of,
    host_role,
    sha256_of,
    stage_data,
    stage_under,
)

comptime WARM = 16
comptime ROUNDS = 64
comptime SLACK = 8
"""Bytes per round the two heaps may differ by; the smallest block glibc
allocates is 32 bytes, so one leaked block per round is four times this."""


def _i64() -> List[ColumnType]:
    return [ColumnType(TYPE_INT64, True)]


def _spec(shape: UInt32, entry: String, code: CodeSet, table: Bool = False, state: Bool = False) -> UdfSpec:
    var s = UdfSpec(shape, entry, _i64(), _i64())
    s.result_is_table = table
    if state:
        s.state = ColumnType(TYPE_INT64, True)
    s.code_root = code.root
    s.code = code.objects.copy()
    return s^


def _batch() -> Batch:
    var b = Batch(3)
    var c = Column(TYPE_INT64)
    for v in range(1, 4):
        c.append_int(Int64(v))
    b.columns.append(c^)
    return b^


def _round(mut rt: UdfRuntime, code: CodeSet, mismatch: UdfSpec, directory: UdfSpec) raises:
    var d = _spec(SHAPE_SCALAR, "double", code)
    var f = _spec(SHAPE_MAP_BATCHES_FRAME, "running_sum", code, True)
    var a = _spec(SHAPE_AGG_MERGEABLE, "sum", code, False, True)
    var ud = rt.load(d)
    var uf = rt.load(f)
    var ua = rt.load(a)
    var ctx = rt.open_context(0)
    var id = rt.open_instance(ctx.handle, ud.handle)
    var i_f = rt.open_instance(ctx.handle, uf.handle)
    var ia = rt.open_instance(ctx.handle, ua.handle)
    var r = rt.call_batch(id.handle, d, _batch(), CallOptions.plain())
    assert_true(r.outcome.is_ok(), "call_batch: " + String(r.outcome))
    var fr = rt.run_frame(i_f.handle, f, [_batch()], CallOptions.plain())
    assert_true(fr.outcome.is_ok(), "frame: " + String(fr.outcome))
    var g = rt.agg_open(ia.handle)
    assert_true(g.outcome.is_ok(), "agg_open: " + String(g.outcome))
    # Refused by the library, on both runtimes: a frame and groups on a
    # scalar UDF, and a load of an entry it lacks.
    assert_true(not rt.run_frame(id.handle, d, [_batch()], CallOptions.plain()).outcome.is_ok(), "a frame on a scalar")
    assert_true(not rt.agg_open(id.handle).outcome.is_ok(), "groups on a scalar")
    assert_true(not rt.load(_spec(SHAPE_SCALAR, "no_such_entry", code)).outcome.is_ok(), "an unknown entry")
    _ = rt.agg_update(g.handle, _batch(), [0, 1, 0], 2, CallOptions.plain())
    _ = rt.agg_finish(g.handle, 2, ColumnType(TYPE_INT64, True))
    rt.agg_close(g.handle)
    rt.close_instance(ia.handle)
    rt.close_instance(i_f.handle)
    rt.close_instance(id.handle)
    rt.close_context(ctx.handle)
    rt.unload(ua.handle)
    rt.unload(uf.handle)
    rt.unload(ud.handle)
    _ = rt.validate(mismatch)
    _ = rt.validate(directory)


def _handles(path: String, code: CodeSet, mismatch: UdfSpec, directory: UdfSpec) raises -> Int:
    """The heap's growth over ROUNDS rounds on the runtime at `path`. The
    host's reserved bytes (which the Mojo library reserves for every block it
    allocates) are the same after the rounds as before, and none are left
    after shutdown."""
    var rt = UdfRuntime.open(path)
    for _ in range(WARM):
        _round(rt, code, mismatch, directory)
    var before = heap_in_use()
    var reserved = rt.reserved_bytes()
    for _ in range(ROUNDS):
        _round(rt, code, mismatch, directory)
    var grown = heap_in_use() - before
    assert_equal(rt.reserved_bytes(), reserved, path + ": library memory kept over the rounds")
    rt.shutdown()
    assert_equal(rt.reserved_bytes(), 0, path + ": library memory kept after shutdown")
    return grown


def _junk(n: Int, seed: Int) -> List[UInt8]:
    var d = List[UInt8](capacity=n)
    for i in range(n):
        d.append(UInt8((i * 131 + seed) & 255))
    return d^


def _new_libraries(path: String, root: String) raises -> Int:
    """The heap's growth over ROUNDS validates, each of a new code object
    that fails dlopen."""
    var rt = UdfRuntime.open(path)
    var specs = List[UdfSpec]()
    for k in range(WARM + ROUNDS):
        var data = _junk(64 + k, k)
        var s = UdfSpec(SHAPE_SCALAR, "double", _i64(), _i64())
        s.code_root = root
        s.code = [stage_data(data, root, host_role(), sha256_of(data))]
        specs.append(s^)
    for k in range(WARM):
        _ = rt.validate(specs[k])
    var before = heap_in_use()
    for k in range(WARM, WARM + ROUNDS):
        _ = rt.validate(specs[k])
    var grown = heap_in_use() - before
    rt.shutdown()
    return grown


def _runtimes(path: String, unloadable: UdfSpec) raises -> Int:
    """The heap's growth over ROUNDS runtimes, each opened, given a library
    that fails dlopen, and shut down."""
    for _ in range(WARM):
        var rt = UdfRuntime.open(path)
        _ = rt.validate(unloadable)
        rt.shutdown()
    var before = heap_in_use()
    for _ in range(ROUNDS):
        var rt = UdfRuntime.open(path)
        _ = rt.validate(unloadable)
        rt.shutdown()
    return heap_in_use() - before


def _refused_instances(root: String, slot: UInt32) raises -> Int:
    """The heap's growth over ROUNDS contexts of `slot`, each given an
    instance of the counted library and closed: in slot 98 the library
    refuses the instance, in slot 97 it opens it (closed at once)."""
    var rt = UdfRuntime.open("./native.so")
    var code = code_set("./variant_counted.so", root)
    var u = rt.load(_spec(SHAPE_SCALAR, "double", code))
    assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
    var grown = 0
    for k in range(WARM + ROUNDS):
        if k == WARM:
            grown = heap_in_use()
        var c = rt.open_context(slot)
        var i = rt.open_instance(c.handle, u.handle)
        if i.outcome.is_ok():
            rt.close_instance(i.handle)
        rt.close_context(c.handle)
    grown = heap_in_use() - grown
    rt.unload(u.handle)
    rt.shutdown()
    return grown


def _same(got: Int, reference: Int, slack: Int, what: String) raises:
    assert_true(
        got - reference <= slack and reference - got <= slack,
        what + ": the heap grew " + String(got) + " bytes over " + String(ROUNDS) + " rounds, "
        + String(reference) + " on echo.so",
    )


def main() raises:
    var tmp = getenv("TMPDIR")
    var root = tmp + "/leaks"
    # The mismatched object under a root of its own: the libraries' code sets
    # stage the true bytes under the same digest.
    var mismatch = UdfSpec(SHAPE_SCALAR, "double", _i64(), _i64())
    mismatch.code_root = tmp + "/leaks_mismatch"
    mismatch.code = [stage_under("./native_mojo.so", mismatch.code_root, host_role(), digest_of("./native_c.so"))]
    var directory = UdfSpec(SHAPE_SCALAR, "double", _i64(), _i64())
    directory.code_root = tmp + "/leaks_dir"
    var dir_digest = sha256_of(_junk(7, 7))
    makedirs(directory.code_root + "/" + hex_of(dir_digest), exist_ok=True)
    directory.code = [CodeObject(host_role(), dir_digest^)]
    var c = code_set("./native_c.so", root)
    var m = code_set("./native_mojo.so", root)

    var echo = _handles("./echo.so", c, mismatch, directory)
    _same(_handles("./native.so", c, mismatch, directory), echo, ROUNDS * SLACK, "the C library's handles")
    _same(_handles("./native.so", m, mismatch, directory), echo, ROUNDS * SLACK, "the Mojo library's handles")
    _same(
        _refused_instances(tmp + "/leaks_counted", 98),
        _refused_instances(tmp + "/leaks_counted", 97),
        ROUNDS * SLACK,
        "instances the library refused",
    )

    # Each new library is remembered (a record of about 300 bytes); the bytes
    # read for it (1 MiB) are not.
    var lib_echo = _new_libraries("./echo.so", tmp + "/leaks_new_echo")
    _same(_new_libraries("./native.so", tmp + "/leaks_new"), lib_echo, ROUNDS * 2048, "new libraries")

    var junk = _junk(100, 1)
    var unloadable = UdfSpec(SHAPE_SCALAR, "double", _i64(), _i64())
    unloadable.code_root = root
    unloadable.code = [stage_data(junk, root, host_role(), sha256_of(junk))]
    _same(_runtimes("./native.so", unloadable), _runtimes("./echo.so", unloadable), ROUNDS * SLACK, "runtimes")
    print("test_leaks: ok")
