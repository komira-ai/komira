# =============================================================================
# FFI-BOUNDARY: the runtime library and its komira_udf_runtime table.
# =============================================================================
# dlopens a runtime library (RTLD_NOW | RTLD_LOCAL, design section 4.3), calls
# its one export komira_udf_runtime_init_v1, and calls the table's entries.
# runtime.mojo is the only caller; it passes only Words it got from here or
# from _host.mojo, and cannot read through them.
#
# Who owns and frees each pointer:
#   - the OwnedDLHandle: a heap slot written once and never freed, so the
#     library is never dlclosed (the design forbids it: runtimes start
#     threads and register exit handlers).
#   - the table: the runtime's static data, read only below its struct_size.
#   - rt, udf, context, instance, frame and groups handles: the runtime's,
#     created and freed only through the table.
#   - out-slots (`komira_udf_xxx** out`), capabilities, spec and call
#     structs, and the cancel flag: arena blocks of _host.mojo.
# =============================================================================

from std.ffi import OwnedDLHandle, RTLD
from std.memory import alloc
from std.sys import size_of

from ._cabi import (
    CUdfCall,
    CUdfCapabilities,
    CUdfRuntime,
    CUdfSpec,
    Void,
    Word,
    is_null,
    memory_report_word,
    null_void,
    read_cstr,
)
from ._host import _Arena

comptime INIT_SYMBOL = "komira_udf_runtime_init_v1"


def open_library(path: String) raises -> Word:
    """dlopen `path` and check it exports the init symbol. Raises
    UDF_RUNTIME_OPEN_FAILED or UDF_RUNTIME_MISSING_SYMBOL."""
    # SAFETY: one heap slot for the handle, re-originated untracked because it
    # outlives every Mojo scope: it is never freed once written (the file
    # header says why). On a failed open the slot is freed unwritten.
    var lib = alloc[OwnedDLHandle](1).unsafe_origin_cast[MutUntrackedOrigin]()
    try:
        lib.unsafe_write(OwnedDLHandle(path, RTLD.NOW | RTLD.LOCAL))
    except e:
        lib.free()
        raise Error("UDF_RUNTIME_OPEN_FAILED: " + path + ": " + String(e))
    if not lib[].check_symbol(INIT_SYMBOL):
        raise Error("UDF_RUNTIME_MISSING_SYMBOL: " + path + " has no " + INIT_SYMBOL)
    return Word(lib.bitcast[NoneType]())


def init_runtime(lib: Word, host: Word, rt_slot: Word, err: Word) -> Word:
    """Call the init export; the table, or NULL with `err` filled."""
    # SAFETY: `lib` is open_library's live slot; the three arguments are arena
    # blocks of the sizes the C prototype names.
    return Word(lib.p.bitcast[OwnedDLHandle]()[].call[INIT_SYMBOL, Void](host.p, rt_slot.p, err.p))


def slot_value(slot: Word) -> Word:
    """The pointer a runtime wrote into an out-slot (`komira_udf_xxx** out`)."""
    # SAFETY: `slot` is an 8-byte arena block.
    return Word(slot.p.bitcast[Void]()[])


# --- the table ------------------------------------------------------------------
#
# SAFETY (every function below): `t` is the table init_runtime returned; it is
# static in the runtime and never freed. UdfRuntime.open checked the table
# covers every required entry before any is read; memory_report, the one
# optional entry, is read only after memory_report_present.


def _tbl(t: Word) -> UnsafePointer[CUdfRuntime, MutUntrackedOrigin]:
    return t.p.bitcast[CUdfRuntime]()


def table_abi(t: Word) -> UInt32:
    return _tbl(t)[].abi_major


def table_size(t: Word) -> Int:
    return _tbl(t)[].struct_size


def required_size() -> Int:
    """The bytes a table must cover: every entry but the optional last one."""
    return size_of[CUdfRuntime]() - 8


def memory_report_present(t: Word) -> Bool:
    if table_size(t) < size_of[CUdfRuntime]():
        return False
    return not is_null(memory_report_word(_tbl(t)[].memory_report))


def t_describe(t: Word, rt: Word, caps: Word) -> Int32:
    var f = _tbl(t)[].describe
    return f(rt.p, caps.p)


def t_validate(t: Word, rt: Word, spec: Word, err: Word) -> Int32:
    var f = _tbl(t)[].validate
    return f(rt.p, spec.p, err.p)


def t_load(t: Word, rt: Word, spec: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].load
    return f(rt.p, spec.p, out_p.p, err.p)


def t_unload(t: Word, udf: Word):
    var f = _tbl(t)[].unload
    f(udf.p)


def t_open_context(t: Word, rt: Word, slot: UInt32, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].open_context
    return f(rt.p, slot, out_p.p, err.p)


def t_close_context(t: Word, ctx: Word):
    var f = _tbl(t)[].close_context
    f(ctx.p)


def t_open_instance(t: Word, ctx: Word, udf: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].open_instance
    return f(ctx.p, udf.p, out_p.p, err.p)


def t_close_instance(t: Word, inst: Word):
    var f = _tbl(t)[].close_instance
    f(inst.p)


def t_call_batch(t: Word, inst: Word, call: Word, args: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].call_batch
    return f(inst.p, call.p, args.p, out_p.p, err.p)


def t_frame_open(t: Word, inst: Word, call: Word, stream: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].frame_open
    return f(inst.p, call.p, stream.p, out_p.p, err.p)


def t_frame_next(t: Word, frame: Word, call: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].frame_next
    return f(frame.p, call.p, out_p.p, err.p)


def t_frame_close(t: Word, frame: Word):
    var f = _tbl(t)[].frame_close
    f(frame.p)


def t_agg_open(t: Word, inst: Word, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].agg_open
    return f(inst.p, out_p.p, err.p)


def t_agg_update(t: Word, g: Word, call: Word, args: Word, gids: Word, n: UInt32, err: Word) -> Int32:
    var f = _tbl(t)[].agg_update
    return f(g.p, call.p, args.p, gids.p, n, err.p)


def t_agg_merge(t: Word, g: Word, call: Word, states: Word, gids: Word, n: UInt32, err: Word) -> Int32:
    var f = _tbl(t)[].agg_merge
    return f(g.p, call.p, states.p, gids.p, n, err.p)


def t_agg_state(t: Word, g: Word, n: UInt32, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].agg_state
    return f(g.p, n, out_p.p, err.p)


def t_agg_finish(t: Word, g: Word, n: UInt32, out_p: Word, err: Word) -> Int32:
    var f = _tbl(t)[].agg_finish
    return f(g.p, n, out_p.p, err.p)


def t_agg_close(t: Word, g: Word):
    var f = _tbl(t)[].agg_close
    f(g.p)


def t_shutdown(t: Word, rt: Word):
    var f = _tbl(t)[].shutdown
    f(rt.p)


def t_memory_report(t: Word, ctx: Word) -> Int64:
    var f = _tbl(t)[].memory_report
    return f(ctx.p)


# --- structs the host fills -----------------------------------------------------
#
# SAFETY: every block is a zeroed arena block of its struct's size.


@fieldwise_init
struct CapsText(Copyable, Movable):
    var runtime_id: String
    var runtime_abi: String
    var words: List[UInt32]
    """max_descriptor_version, shapes, threading, thread_affine, transports,
    hosting, devices, features, udf_class, global_lock, in that order."""


def new_caps(mut arena: _Arena) -> Word:
    var c = arena.bytes(size_of[CUdfCapabilities]()).bitcast[CUdfCapabilities]()
    c[].struct_size = size_of[CUdfCapabilities]()
    return Word(c.bitcast[NoneType]())


def read_caps(c: Word) -> CapsText:
    var p = c.p.bitcast[CUdfCapabilities]()
    var w: List[UInt32] = [
        p[].max_descriptor_version, p[].shapes, p[].threading, p[].thread_affine,
        p[].transports, p[].hosting, p[].devices, p[].features, p[].udf_class, p[].global_lock,
    ]
    return CapsText(read_cstr(p[].runtime_id), read_cstr(p[].runtime_abi), w^)


def new_spec(
    mut arena: _Arena,
    shape: UInt32,
    form: Int32,
    entry: String,
    descriptor_version: UInt32,
    descriptor: List[UInt8],
    args: Word,
    result: Word,
    state: Word,
    null_mode: Int32,
    stability: Int32,
) -> Word:
    """A komira_udf_spec with no code objects (n_code 0)."""
    var s = arena.bytes(size_of[CUdfSpec]()).bitcast[CUdfSpec]()
    s[].struct_size = size_of[CUdfSpec]()
    s[].shape = Int32(shape)
    s[].form = form
    s[].entry = arena.cstr(entry)
    s[].descriptor_version = descriptor_version
    var d = arena.bytes(len(descriptor))
    for i in range(len(descriptor)):
        d.bitcast[UInt8]()[i] = descriptor[i]
    s[].descriptor = d
    s[].descriptor_len = len(descriptor)
    s[].args = args.p
    s[].result = result.p
    s[].state = state.p
    s[].null_mode = null_mode
    s[].stability = stability
    s[].code_root = arena.cstr("")
    s[].n_code = 0
    s[].code_roles = null_void()
    s[].code_sha256 = null_void()
    return Word(s.bitcast[NoneType]())


def new_call(mut arena: _Arena, deadline_ns: Int64, call_id: Int64, cancel: Bool) -> Word:
    """A komira_udf_call whose cancel flag is already set when `cancel`."""
    var flag = arena.bytes(8)
    flag.bitcast[Int32]()[] = 1 if cancel else 0
    var c = arena.bytes(size_of[CUdfCall]()).bitcast[CUdfCall]()
    c[].struct_size = size_of[CUdfCall]()
    c[].deadline_ns = deadline_ns
    c[].call_id = call_id
    c[].cancel = flag
    return Word(c.bitcast[NoneType]())


def cancel_flag_of(call: Word) -> Word:
    """The cancel flag of `call` (an arena block new_call allocated)."""
    # SAFETY: `call` is a CUdfCall block new_call filled.
    return Word(call.p.bitcast[CUdfCall]()[].cancel)
