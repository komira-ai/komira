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
#     and maps one, so the count can see a load; with that library open,
#     its digest with any one of its 32 bytes changed, naming its own bytes,
#     is still read and refused (machine code loaded before its digest was
#     checked; a compare of part of the digest, at load or in the lookup of
#     an open library; a refusal remembered, so a good copy is refused too).
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
#     naming the runtime symbol (a runtime and a user library confused); a
#     library without the native symbol, and one whose init fails, each by
#     its whole message, the failed init's error released (its message
#     holds host bytes).
#   - capabilities: libraries that each differ from the C library in one
#     describe field (native/variant_lib.c and native_c_affine) are refused
#     with ERR_LOAD naming that field: thread_affine 1, threading
#     SINGLE_THREAD, transports without IN_PROCESS, global_lock 1, udf_class
#     MANAGED; and one of another runtime_id (a library bound to concurrency
#     or a transport it cannot take; one arm of the check dropped); each
#     variant refused after its init is shut down at once (the host bytes
#     its init reserved come back).
#   - table: a library whose table reports ABI major 2, one whose table's
#     struct_size ends before close_instance and one that ends one entry
#     short (before shutdown) are refused with ERR_ABI naming which, and no
#     entry of theirs is called again, shutdown included; a table ending
#     exactly at shutdown loads (a library table read past its end or in
#     another ABI; the bound moved by one entry).
#   - shapes: a library whose describe lacks SCALAR loads a column UDF but
#     is refused at load, ERR_LOAD naming the shapes, for a SCALAR spec (a
#     UDF bound to a library without its shape).
#   - a code object that is absent, a malformed role, a form other than
#     BUNDLE and a spec with no code object, each refused by name; near-miss
#     roles (`lib:<os>-`, `lib:-<cpu>`, `lib:-<os>-<cpu>`, `lib:<os>`,
#     `lib:`, `lib;...`, no `lib:`) refused beside a good library, before or
#     after it; one-letter platforms (`lib:a-b`) accepted beside it; roles a
#     byte from this host's refused as another platform's. Every refusal
#     has row -1 and group -1.
#   - three libraries in one runtime and one context: the C library, the
#     Mojo library and the counted library each serve `double` inside the
#     runtime's one context; the counted library refuses any context it did
#     not open (its instance opened after the C library's, so a runtime
#     handing every library the first library context fails it), its context
#     holds a host reservation until the runtime's context is closed and not
#     after (a library context leaked), and a second load of a library maps
#     nothing new (a library opened twice).
#   - slots (design section 4.3, open_context: a dense index per engine
#     thread): runtime contexts of slots 2, 0, 3, 1 each give the counted
#     library its own slot (a library context opened with slot 0).
#   - library contexts: a second instance of a library in a context, first
#     or third in it, reuses its library context; five libraries, then
#     twelve copies of the C library, in one context each answer (the list
#     of library contexts grown wrong); the counted library's refusals of a
#     context (slot 99) and of an instance (slot 98) come back whole.
#   - shutdown (design section 4.4: `shutdown` drains every queue): the
#     deferred library queues each released output, holding host bytes, and
#     drains the queue at its next call and at its shutdown; the runtime's
#     shutdown must reach it (a library never shut down).
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
# the library; close_context not forwarded to the library contexts. Round
# 2's, each red here: the open-library lookup's memcmp over 31 and over 1
# byte ("a digest differing from an open library's in one byte took that
# library"); the library context opened with slot 0, and the runtime context
# storing slot 0 ("the library context of runtime slot 1 got another
# slot"); the libraries' shutdown skipped ("the runtime's shutdown left the
# library's release queue undrained"); the table bound moved to
# offsetof(shutdown) ("a library table one entry short: OK"); the role
# check without `dash[1] != 0` ("a near-miss code role was not refused as
# malformed"). The full sweep is in the pull request's scorecard.

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, CodeObject, Handle, Outcome, UdfRuntime, UdfSpec
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

comptime INIT_BYTES = 77
"""What each native/variant_lib.c library reserves from the host from its
init until its shutdown."""


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
    assert_equal(got.row, -1, what + ": a refusal with a row")
    assert_equal(got.group, -1, what + ": a refusal with a group")


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
    # A library already open is found by its whole sha256: digests that share
    # all but one byte with the loaded library's, at every byte, each name the
    # C library's bytes, which do not match them. Each must be read and
    # refused, never answered from the library already open.
    var missed = String()
    for k in range(32):
        var twin = want.copy()
        twin[k] ^= 0x80
        var spec = _spec(tmp + "/twin", [stage_data(c_bytes, tmp + "/twin", host_role(), twin)])
        var got = rt.load(spec)
        if got.outcome.status != ERR_CODE_DIGEST:
            missed += " byte " + String(k) + ": " + String(got.outcome) + ";"
            if got.outcome.is_ok():
                rt.unload(got.handle)
    assert_equal(missed, "", "a digest differing from an open library's in one byte took that library")
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
    var none = _spec(root, [stage("./no_symbol.so", root, host_role())])
    var got = rt.validate(none)
    _refused(got, ERR_LOAD, "", "a library without the native library symbol")
    assert_equal(got.message, "the library does not export komira_udf_native_init_v1", "its message, whole")
    # A library whose init fails: refused with init's own message, and the
    # error init filled is released (its message holds host bytes).
    var reserved = rt.reserved_bytes()
    var fails = _spec(root, [stage("./variant_init_fails.so", root, host_role())])
    var f = rt.validate(fails)
    _refused(f, ERR_LOAD, "", "a library whose init fails")
    assert_equal(f.message, "the library's init failed: init_fails refuses every host", "its message, whole")
    assert_equal(rt.reserved_bytes(), reserved, "the error of a failed library init was not released")
    _refused(rt.load(fails).outcome, ERR_LOAD, "init_fails refuses every host", "a library whose init failed, again")
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
        var reserved = rt.reserved_bytes()
        _refused(rt.load(spec).outcome, ERR_LOAD, fields[i], libs[i])
        # Each variant reserves host bytes at init until its shutdown: a
        # library refused for its describe is shut down at once.
        assert_equal(rt.reserved_bytes(), reserved, libs[i] + ": refused after init and never shut down")
    rt.shutdown()


def _table(tmp: String) raises:
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/table"
    # A refused table is never called again, its shutdown included: each
    # variant's init reserved INIT_BYTES, which only its shutdown returns.
    var reserved = rt.reserved_bytes()
    var abi2 = _spec(root, [stage("./variant_abi2.so", root, host_role())])
    _refused(rt.load(abi2).outcome, ERR_ABI, "ABI major 1", "a library table of ABI major 2")
    assert_equal(rt.reserved_bytes() - reserved, INIT_BYTES, "the shutdown of a table of ABI major 2 was called")
    var short = _spec(root, [stage("./variant_short_table.so", root, host_role())])
    _refused(rt.validate(short), ERR_ABI, "struct_size", "a library table ending before a required entry")
    assert_equal(rt.reserved_bytes() - reserved, 2 * INIT_BYTES, "the shutdown of a short table was called")
    # The bound itself: one entry short (no shutdown) is refused, and a table
    # ending exactly at shutdown (no optional memory_report) is accepted.
    var one_short = _spec(root, [stage("./variant_one_short.so", root, host_role())])
    _refused(rt.load(one_short).outcome, ERR_ABI, "struct_size", "a library table one entry short")
    assert_equal(rt.reserved_bytes() - reserved, 3 * INIT_BYTES, "a table without shutdown was shut down")
    _double(rt, _spec(root, [stage("./variant_exact_table.so", root, host_role())]))
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
    # Near-miss roles, each beside this host's good library (after it and
    # before it), so only the role's own check can refuse the spec.
    var host = host_role()
    var dash = host.find("-")
    var os = String(host[byte=4:dash])
    var cpu = String(host[byte = dash + 1 :])
    var near: List[String] = [
        "lib:" + os + "-",
        "lib:-" + cpu,
        "lib:-" + os + "-" + cpu,
        "lib:" + os,
        "lib:",
        "lib:-",
        "lib;" + os + "-" + cpu,
        "lib" + os + "-" + cpu,
        "Lib:" + os + "-" + cpu,
        "ib:" + os + "-" + cpu,
        os + "-" + cpu,
        "",
    ]
    var good_obj = stage("./native_c.so", root, host)
    var accepted = String()
    for i in range(len(near)):
        var bad = CodeObject(near[i], digest_of("./native_mojo.so"))
        var after = rt.validate(_spec(root, [good_obj.copy(), bad.copy()]))
        var before = rt.validate(_spec(root, [bad^, good_obj.copy()]))
        if after.status != ERR_DESCRIPTOR or before.status != ERR_DESCRIPTOR:
            accepted += " '" + near[i] + "': " + String(after) + " / " + String(before) + ";"
    assert_equal(accepted, "", "a near-miss code role was not refused as malformed")
    # Well-formed roles of one-letter platforms, beside this host's library:
    # accepted, the host's taken.
    for r in ["lib:a-b", "lib:" + os + "-b", "lib:a-" + cpu]:
        var beside = rt.validate(_spec(root, [CodeObject(r, digest_of("./native_mojo.so")), good_obj.copy()]))
        assert_true(beside.status == OK, "the well-formed role '" + r + "' beside this host's: " + String(beside))
    # Well-formed roles that are not this host's: one byte short and one long.
    var near_host: List[String] = [String(host[byte = 0 : host.byte_length() - 1]), host + "x"]
    for r in near_host:
        var only = _spec(root, [stage("./native_c.so", root, r)])
        _refused(rt.validate(only), ERR_UNSUPPORTED, host, "a library for the platform role '" + r + "'")
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


def _slots(tmp: String) raises:
    """Each library context is opened with its runtime context's slot (design
    section 4.3, open_context: `slot` is a dense index, one per engine
    thread): the counted library reserves its record's size plus the slot it
    was given, so a context of slot s reserves s bytes more than one of slot
    0. Slots opened out of order, so a slot taken from the order of opening
    fails too."""
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/slots"
    var spec = _spec(root, [stage("./variant_counted.so", root, host_role())])
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
    var base = rt.reserved_bytes()
    var order: List[Int] = [2, 0, 3, 1]
    var deltas: List[Int] = [0, 0, 0, 0]
    var ctxs = List[Handle]()
    var insts = List[Handle]()
    for s in order:
        var ctx = rt.open_context(UInt32(s))
        var before = rt.reserved_bytes()
        var inst = rt.open_instance(ctx.handle, u.handle)
        assert_true(inst.outcome.is_ok(), "open_instance in slot " + String(s) + ": " + String(inst.outcome))
        deltas[s] = rt.reserved_bytes() - before
        ctxs.append(ctx.handle.copy())
        insts.append(inst.handle.copy())
    assert_true(deltas[0] > 0, "the counted library's context of slot 0 reserved nothing")
    for s in range(1, 4):
        assert_equal(deltas[s] - deltas[0], s, "the library context of runtime slot " + String(s) + " got another slot")
    for i in range(len(insts)):
        rt.close_instance(insts[i])
        rt.close_context(ctxs[i])
    assert_equal(rt.reserved_bytes(), base, "a library context outlived its runtime context")
    rt.unload(u.handle)
    rt.shutdown()


def _library_contexts(tmp: String) raises:
    """A runtime context opens one library context per library and reuses
    it: a second instance of a library in one context reserves nothing new
    and gets that library's context, not the first library's; five libraries
    in one context (past the runtime's first four slots) each answer. A
    library's refusal to open its context or an instance is returned as it
    is, and nothing is kept of it."""
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/contexts"
    var paths: List[String] = [
        "./native_c.so",
        "./native_mojo.so",
        "./variant_counted.so",
        "./variant_deferred.so",
        "./variant_exact_table.so",
    ]
    var specs = List[UdfSpec]()
    var udfs = List[Handle]()
    for p in paths:
        var spec = _spec(root, [stage(p, root, host_role())])
        var u = rt.load(spec)
        assert_true(u.outcome.is_ok(), p + ": " + String(u.outcome))
        specs.append(spec^)
        udfs.append(u.handle.copy())
    var ctx = rt.open_context(5)
    var insts = List[Handle]()
    for i in range(len(udfs)):
        var inst = rt.open_instance(ctx.handle, udfs[i])
        assert_true(inst.outcome.is_ok(), paths[i] + " in a shared context: " + String(inst.outcome))
        insts.append(inst.handle.copy())
    var reserved = rt.reserved_bytes()
    var again = rt.open_instance(ctx.handle, udfs[2])
    assert_true(again.outcome.is_ok(), "a second counted instance in its context: " + String(again.outcome))
    assert_equal(rt.reserved_bytes(), reserved, "a second instance of a library opened a second library context")
    insts.append(again.handle.copy())
    for i in range(len(insts)):
        var k = i if i < len(specs) else 2
        var r = rt.call_batch(insts[i], specs[k], _ints_1_2_3(), CallOptions.plain())
        assert_equal(String(r.column), "int64[2, 4, 6]", paths[k] + " in a context of five: " + String(r.outcome))
    for i in range(len(insts)):
        rt.close_instance(insts[i])
    rt.close_context(ctx.handle)
    # The library first in its context is found again too.
    var first = rt.open_context(6)
    var k1 = rt.open_instance(first.handle, udfs[2])
    var at = rt.reserved_bytes()
    var k2 = rt.open_instance(first.handle, udfs[2])
    assert_true(k1.outcome.is_ok() and k2.outcome.is_ok(), String(k1.outcome) + " / " + String(k2.outcome))
    assert_equal(rt.reserved_bytes(), at, "the first library of a context opened a second library context")
    rt.close_instance(k1.handle)
    rt.close_instance(k2.handle)
    rt.close_context(first.handle)
    # Twelve libraries in one context, each a copy of the C library with
    # bytes appended (another sha256, another mapping): the context's list of
    # library contexts grows past its first four slots twice.
    var c_bytes = bytes_of("./native_c.so")
    var many = rt.open_context(7)
    var copies = List[Handle]()
    var copy_udfs = List[Handle]()
    var copy_specs = List[UdfSpec]()
    for k in range(12):
        var data = c_bytes.copy()
        for _ in range(k + 1):
            data.append(0)
        var spec = _spec(root, [stage_data(data, root, host_role(), sha256_of(data))])
        var u = rt.load(spec)
        assert_true(u.outcome.is_ok(), "copy " + String(k) + ": " + String(u.outcome))
        var inst = rt.open_instance(many.handle, u.handle)
        assert_true(inst.outcome.is_ok(), "copy " + String(k) + " in a context of twelve: " + String(inst.outcome))
        copies.append(inst.handle.copy())
        copy_udfs.append(u.handle.copy())
        copy_specs.append(spec^)
    for k in range(12):
        var r = rt.call_batch(copies[k], copy_specs[k], _ints_1_2_3(), CallOptions.plain())
        assert_equal(String(r.column), "int64[2, 4, 6]", "copy " + String(k) + ": " + String(r.outcome))
        rt.close_instance(copies[k])
    rt.close_context(many.handle)
    for k in range(12):
        rt.unload(copy_udfs[k])
    # The counted library refuses a context in slot 99 and an instance in a
    # context of slot 98: each refusal comes back with its own message.
    var base = rt.reserved_bytes()
    for slot in [99, 98]:
        var c = rt.open_context(UInt32(slot))
        var i = rt.open_instance(c.handle, udfs[2])
        _refused(i.outcome, ERR_INTERNAL, "", "the counted library in slot " + String(slot))
        var want = "counted refuses a context in slot 99" if slot == 99 else "counted refuses an instance in slot 98"
        assert_equal(i.outcome.message, want, "slot " + String(slot))
        rt.close_context(c.handle)
    assert_equal(rt.reserved_bytes(), base, "a refused library context was kept")
    for i in range(len(udfs)):
        rt.unload(udfs[i])
    rt.shutdown()


def _shutdown_drains(tmp: String) raises:
    """The runtime's shutdown reaches every library's (design section 4.4:
    `shutdown` drains every deferred-release queue). The deferred library
    queues each output the host releases, holding host-reserved bytes, and
    drains the queue at its next call and at its shutdown."""
    var rt = UdfRuntime.open("./native.so")
    var root = tmp + "/deferred"
    var spec = _spec(root, [stage("./variant_deferred.so", root, host_role())])
    var base = rt.reserved_bytes()
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), "open_instance: " + String(inst.outcome))
    var opened = rt.reserved_bytes()
    var held = 0
    for call in range(3):
        var res = rt.call_batch(inst.handle, spec, _ints_1_2_3(), CallOptions.plain())
        assert_equal(String(res.column), "int64[2, 4, 6]", "call " + String(call) + ": " + String(res.outcome))
        if call == 0:
            held = rt.reserved_bytes() - opened
            assert_true(held >= 1000, "a released output was not queued: " + String(held) + " bytes held")
        assert_equal(rt.reserved_bytes() - opened, held, "the queue was not drained at the next call")
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)
    assert_true(rt.reserved_bytes() - base >= 1000, "the queue drained before shutdown")
    rt.shutdown()
    assert_equal(rt.reserved_bytes(), base, "the runtime's shutdown left the library's release queue undrained")


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
    _slots(tmp)
    _library_contexts(tmp)
    _shutdown_drains(tmp)
    print("test_native_loader: ok")
