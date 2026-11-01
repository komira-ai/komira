# The native runtime in a process whose standard input is closed, so the
# lowest free descriptor is 0: the code object's file is opened as
# descriptor 0, closed, and the library's memory file then takes 0 too.
#
# What it proves: descriptor 0 is a descriptor like any other. The C library
# loads from a code object read through descriptor 0 and is dlopened
# through a memory file that is descriptor 0, then answers [2, 4, 6].
#
# Defects caught: a failed open() or memfd_create() tested as `fd <= 0` or
# `fd < 1` (native_runtime.c, read_all and open_bytes): with stdin open,
# neither ever returns 0, so only a process like this one tells them apart.
# Mutants planted: both comparisons, each red here (the first refused as
# "the code object is missing or unreadable", the second as "dlopen of the
# verified library failed").

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64

from komira_udf_spike_native.code import close_stdin, host_role, stage, stdin_is_library_memfd, stdin_open


def main() raises:
    var root = getenv("TMPDIR") + "/stdin"
    var spec = UdfSpec(SHAPE_SCALAR, "double", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)])
    spec.code_root = root
    spec.code = [stage("./native_c.so", root, host_role())]
    var rt = UdfRuntime.open("./native.so")
    assert_true(close_stdin(), "standard input could not be closed")
    assert_true(not stdin_open(), "descriptor 0 is still open")
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load with descriptor 0 free: " + String(u.outcome))
    # The memory file is kept open for the life of the process: it holds 0.
    assert_true(stdin_is_library_memfd(), "the library's memory file is not descriptor 0")
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), "open_instance: " + String(inst.outcome))
    var b = Batch(3)
    var c = Column(TYPE_INT64)
    for v in [1, 2, 3]:
        c.append_int(Int64(v))
    b.columns.append(c^)
    var res = rt.call_batch(inst.handle, spec, b, CallOptions.plain())
    assert_true(res.outcome.is_ok(), "call_batch: " + String(res.outcome))
    assert_equal(String(res.column), "int64[2, 4, 6]")
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)
    rt.shutdown()
    print("test_stdin_closed: ok")
