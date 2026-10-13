# How the native runtime reads a code object, and what it reports of itself.
#
# What it proves and the defect each part catches:
#   - large files: junk of exactly 1 MiB, 1 MiB + 1 and 3 MiB + 1 bytes,
#     each staged under its own sha256, is refused for failing dlopen, never
#     for its digest (a read that stops at its first buffer, or grows it
#     wrong, hashes a prefix).
#   - a directory where the code object should be is refused as unreadable
#     (a read error taken for data or for the end of the file).
#   - descriptors: digest mismatches and libraries that fail dlopen leave no
#     file descriptor open (the code object's descriptor, or the memory file
#     of a library that failed to load, never closed).
#   - the code object's path: under an empty code root it is "/<hex>"; under
#     a root that leaves exactly room for the whole name (4095 bytes) the
#     library loads; under one a byte longer the refusal names the path cut
#     at the last whole hex pair (a bound on the path buffer off by one; the
#     name built without the root).
#   - the runtime's own checks come first: at load, a descriptor version 2
#     and non-canonical descriptor bytes are refused with ERR_DESCRIPTOR
#     although the code object is absent (a check left to the library, which
#     is never opened).
#   - describe, into a struct filled with 0xFF bytes so a field it never
#     writes shows: the native runtime writes exactly its fixed set (design
#     section 1.2): komira/native, abi1, descriptor version 1, every shape,
#     CPU, no features, NATIVE.
#   - refusal messages are whole: the exact text, row -1 and group -1 (a
#     message copied without its terminator; a refusal given a row).

from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CodeObject, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import ColumnType, TYPE_INT64

from komira_udf_spike_native.code import (
    digest_of,
    hex_of,
    host_role,
    open_fds,
    sha256_of,
    stage,
    stage_data,
    stage_under,
)


def _spec(root: String, var objects: List[CodeObject]) -> UdfSpec:
    var s = UdfSpec(SHAPE_SCALAR, "double", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT64, True)])
    s.code_root = root
    s.code = objects^
    return s^


def _exactly(got: Outcome, status: Int32, message: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_equal(got.message, message, what)
    assert_equal(got.row, -1, what + ": row")
    assert_equal(got.group, -1, what + ": group")


def _junk(n: Int) -> List[UInt8]:
    var d = List[UInt8](capacity=n)
    for i in range(n):
        d.append(UInt8((i * 131 + 7) & 255))
    return d^


def _large(mut rt: UdfRuntime, tmp: String) raises:
    var root = tmp + "/large"
    var sizes: List[Int] = [1 << 20, (1 << 20) + 1, (3 << 20) + 1]
    for n in sizes:
        var data = _junk(n)
        var spec = _spec(root, [stage_data(data, root, host_role(), sha256_of(data))])
        _exactly(
            rt.load(spec).outcome,
            ERR_LOAD,
            "dlopen of the verified library failed",
            "a file of " + String(n) + " bytes under its sha256",
        )


def _directory(mut rt: UdfRuntime, tmp: String) raises:
    var root = tmp + "/dir"
    var d = sha256_of(_junk(9))
    makedirs(root + "/" + hex_of(d), exist_ok=True)
    var got = rt.load(_spec(root, [CodeObject(host_role(), d.copy())])).outcome.copy()
    _exactly(got, ERR_LOAD, "the code object is missing or unreadable: " + root + "/" + hex_of(d), "a directory")


def _descriptors(mut rt: UdfRuntime, tmp: String) raises:
    var root = tmp + "/fds"
    var want = digest_of("./native_c.so")
    var mismatch = _spec(root, [stage_under("./native_mojo.so", root, host_role(), want)])
    var junk = _junk(100)
    var unloadable = _spec(root, [stage_data(junk, root, host_role(), sha256_of(junk))])
    var before = open_fds()
    assert_true(before > 0, "/proc/self/fd is not readable")
    for _ in range(3):
        _ = rt.load(mismatch)
        _ = rt.load(unloadable)
    assert_equal(open_fds(), before, "a refused code object left a file descriptor open")


def _path(mut rt: UdfRuntime, tmp: String) raises:
    # An absent object (never cached), and the C library for the root that fits.
    var obj = sha256_of(_junk(5))
    var hex = hex_of(obj)
    _exactly(
        rt.load(_spec("", [CodeObject(host_role(), obj.copy())])).outcome,
        ERR_LOAD,
        "the code object is missing or unreadable: /" + hex,
        "an empty code root",
    )
    # A root of `fit` bytes leaves room for "/" and the 64 hex digits in the
    # runtime's 4096-byte path buffer, with its terminator; one byte more
    # leaves room for 62 of them.
    var fit = 4096 - 1 - 1 - 64
    var root = tmp + "/long"
    var remaining = fit - root.byte_length()
    var parts = (remaining + 200) // 201
    var letters = remaining - parts
    for p in range(parts):
        root += "/"
        for _ in range(letters // parts + (letters % parts if p == 0 else 0)):
            root += "a"
    assert_equal(root.byte_length(), fit, "the long root's length")
    var one = stage("./native_c.so", root, host_role())
    var u = rt.load(_spec(root, [one.copy()]))
    assert_true(u.outcome.is_ok(), "a library whose path is 4095 bytes: " + String(u.outcome))
    rt.unload(u.handle)
    var longer = root + "b"
    makedirs(longer, exist_ok=True)
    var got = rt.load(_spec(longer, [CodeObject(host_role(), obj.copy())])).outcome.copy()
    _exactly(
        got,
        ERR_LOAD,
        "the code object is missing or unreadable: " + longer + "/" + String(hex[byte=0:62]),
        "a path one byte too long",
    )


def _descriptor_first(mut rt: UdfRuntime, tmp: String) raises:
    var absent = CodeObject(host_role(), sha256_of(_junk(3)))
    var newer = _spec(tmp + "/nowhere", [absent.copy()])
    newer.descriptor_version = 2
    _exactly(rt.load(newer).outcome, ERR_DESCRIPTOR, "descriptor_version 2 is newer than 1, the newest read here", "version 2")
    var bytes = _spec(tmp + "/nowhere", [absent.copy()])
    bytes.descriptor_raw = True
    bytes.descriptor = [UInt8(1)]
    _exactly(
        rt.load(bytes).outcome,
        ERR_DESCRIPTOR,
        "the descriptor is not canonical: field number 0",
        "non-canonical descriptor bytes",
    )
    var value = _spec(tmp + "/nowhere", [absent.copy()])
    value.form = FORM_PACKAGE
    _exactly(rt.load(value).outcome, ERR_DESCRIPTOR, "a native UDF's code form is BUNDLE", "form PACKAGE")


def _describe(mut rt: UdfRuntime) raises:
    # Over a struct of 0xFF bytes: every field below must be written by
    # describe, the zeros included.
    var c = rt.describe(0xFF)
    assert_equal(c.runtime_id, "komira/native")
    assert_equal(c.runtime_abi, "abi1")
    assert_equal(c.max_descriptor_version, 1, "max_descriptor_version")
    var every = (
        SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN | SHAPE_MAP_BATCHES_FRAME
        | SHAPE_MAP_BATCHES_FRAME_GROUPED | SHAPE_AGG_PLAIN | SHAPE_AGG_MERGEABLE | SHAPE_STEP
    )
    assert_equal(c.shapes, every, "shapes")
    assert_equal(c.devices, DEVICE_CPU, "devices")
    assert_equal(c.features, 0, "features")
    assert_equal(c.udf_class, CLASS_NATIVE, "udf_class")
    assert_true(not c.has_memory_report, "memory_report")


def main() raises:
    var tmp = getenv("TMPDIR")
    var rt = UdfRuntime.open("./native.so")
    _describe(rt)
    _large(rt, tmp)
    _directory(rt, tmp)
    _descriptors(rt, tmp)
    _path(rt, tmp)
    _descriptor_first(rt, tmp)
    rt.shutdown()
    print("test_native_io: ok")
