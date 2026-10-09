# =============================================================================
# FFI-BOUNDARY: the komira_udf_runtime table of this native UDF library.
# =============================================================================
# native_init is what the library's one export, komira_udf_native_init_v1
# (so/native_mojo_so.mojo), returns: a table whose entries are the abi("C")
# functions below, over the fixtures of _fixtures.mojo and the frames and
# aggregates here (docs/design/udf_runtime_interface.md section 4.3).
#
# Who owns and frees each pointer:
#   - the table and the runtime handle: one block each, made by native_init
#     and freed by shutdown (Mojo has no global variables, so the table is
#     not static data: the host reads it only until shutdown, which this
#     relies on).
#   - udf, context, instance, groups and frame handles: one heap struct
#     each, made by its open entry and freed by its close entry.
#   - every block above, and every scratch block, is reserved from the host
#     (mem_reserve) while it lives and released when it is freed (_box,
#     _unbox, _scratch, _free_scratch): the host's reserved bytes are how a
#     test sees a block this library never frees. The harness's host never
#     refuses a reservation; a refusal is not handled here (spike code).
#   - `args`, `states` and `group_ids`: moved on entry into the instance's or
#     the groups' scratch blocks (calls on one of them are serialized by the
#     host), released here once, before the entry returns.
#   - the `in` stream of frame_open: moved into a 48-byte block of the frame,
#     released at the end of the stream or at frame_close.
#   - `out`: built by _arrow.mojo, the host's once OK is returned; NULL on
#     every other status.
# =============================================================================

from std.memory import alloc
from std.sys import size_of

from komira_udf_spike_abi._cabi import (
    CArrowDeviceArray,
    CArrowDeviceArrayStream,
    CUdfCapabilities,
    CUdfHost,
    CUdfRuntime,
    Void,
    as_get_next,
    as_release,
    free_zeroed,
    is_null,
    null_void,
    zeroed,
)
from komira_udf_spike_abi.contract import (
    ABI_MAJOR,
    ABI_MINOR,
    ARROW_DEVICE_CPU,
    CLASS_NATIVE,
    CONTEXT_PER_THREAD,
    DEVICE_CPU,
    ERR_ABI,
    ERR_CANCELLED,
    ERR_INTERNAL,
    ERR_RAISED,
    ERR_UNSUPPORTED,
    HOSTING_NONE,
    OK,
    SHAPE_AGG_MERGEABLE,
    SHAPE_AGG_PLAIN,
    SHAPE_MAP_BATCHES_COLUMN,
    SHAPE_MAP_BATCHES_FRAME,
    SHAPE_ROW,
    SHAPE_SCALAR,
    SHAPE_STEP,
    TRANSPORT_IN_PROCESS,
)

from ._arrow import (
    _cstr,
    arr,
    child,
    fail,
    i32_at,
    i64_at,
    is_valid,
    length,
    make_col,
    make_struct,
    move_array,
    n_children,
    release_array,
    set_cpu,
    set_null,
)
from ._fixtures import (
    F_ARGS_KEPT,
    F_DEVICE_NOT_CPU,
    F_ENDLESS,
    F_GROUP_MAX,
    F_NULL_COUNT_LIES,
    F_OK_WITHOUT_OUTPUT,
    F_OUT_SET_ON_ERROR,
    F_RUNNING_SUM,
    F_SUM_ARGS_KEPT,
    F_YIELD_TWO_THEN_RAISE,
    Fixture,
    check_spec,
    read_set,
    row_call,
    scalar,
    start_call,
    cancelled,
)

comptime _DEVICE_ARRAY = 128
"""Bytes of a struct ArrowDeviceArray."""
comptime _STREAM = 48
"""Bytes of a struct ArrowDeviceArrayStream."""


@fieldwise_init
struct _Rt(Movable):
    var host: Void
    var table: Void
    var id: Void
    var abi: Void


@fieldwise_init
struct _Udf(Movable):
    var host: Void
    var fx: Fixture
    var fields: List[String]


@fieldwise_init
struct _Ctx(Movable):
    var rt: Void
    var slot: UInt32


@fieldwise_init
struct _Inst(Movable):
    var host: Void
    var fx: Fixture
    var fields: List[String]
    var scratch: Void


@fieldwise_init
struct _Groups(Movable):
    var host: Void
    var fx: Int
    var st: List[Int64]
    var scratch: Void


@fieldwise_init
struct _Frame(Movable):
    var host: Void
    var fx: Int
    var stream: Void
    var done: Bool
    var running: Int64
    var group: Int64
    var max: Int64


def _reserve(host: Void, n: Int):
    # SAFETY: `host` is the komira_udf_host native_init got, alive until
    # shutdown returns.
    var h = host.bitcast[CUdfHost]()
    _ = h[].mem_reserve(h[].host_data, Int64(n))


def _release(host: Void, n: Int):
    # SAFETY: as _reserve.
    var h = host.bitcast[CUdfHost]()
    h[].mem_release(h[].host_data, Int64(n))


def _box[T: Movable & ImplicitlyDestructible](host: Void, var v: T) -> Void:
    # SAFETY: a heap slot of this library, untracked because the host holds
    # it across calls; written before the pointer leaves, freed by _unbox.
    _reserve(host, size_of[T]())
    var p = alloc[T](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(v^)
    return p.bitcast[NoneType]()


def _unbox[T: Movable & ImplicitlyDestructible](host: Void, p: Void):
    # SAFETY: `p` came from _box[T] and is freed once, by its close entry.
    var q = p.bitcast[T]()
    q.destroy_pointee()
    q.free()
    _release(host, size_of[T]())


def _scratch(host: Void, n: Int) -> Void:
    """`n` zeroed bytes, reserved from the host until _free_scratch."""
    _reserve(host, n)
    return zeroed(n)


def _free_scratch(host: Void, p: Void, n: Int):
    free_zeroed(p)
    _release(host, n)


def _set_out_slot(slot: Void, v: Void):
    # SAFETY: `slot` is the host's `komira_udf_xxx** out`.
    slot.bitcast[Void]()[] = v


# --- describe, validate, load ---------------------------------------------------


def _describe(rt: Void, c: Void) abi("C") -> Int32:
    var p = c.bitcast[CUdfCapabilities]()
    if is_null(c) or p[].struct_size < size_of[CUdfCapabilities]():
        return ERR_ABI
    var r = rt.bitcast[_Rt]()
    p[].runtime_id = r[].id
    p[].runtime_abi = r[].abi
    p[].max_descriptor_version = 0
    p[].shapes = (
        SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN | SHAPE_MAP_BATCHES_FRAME | SHAPE_AGG_PLAIN
        | SHAPE_AGG_MERGEABLE | SHAPE_STEP
    )
    p[].threading = CONTEXT_PER_THREAD
    p[].thread_affine = 0
    p[].transports = TRANSPORT_IN_PROCESS
    p[].hosting = HOSTING_NONE
    p[].devices = DEVICE_CPU
    p[].features = 0
    p[].udf_class = CLASS_NATIVE
    p[].global_lock = 0
    return OK


def _validate(rt: Void, s: Void, e: Void) abi("C") -> Int32:
    var fx = Fixture(0, 0, "", "", "")
    return check_spec(s, e, fx)


def _load(rt: Void, s: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var fx = Fixture(0, 0, "", "", "")
    var rc = check_spec(s, e, fx)
    if rc != OK:
        return rc
    var fields = read_set(s) if fx.shape == SHAPE_ROW else List[String]()
    var host = rt.bitcast[_Rt]()[].host
    _set_out_slot(out_p, _box(host, _Udf(host, fx^, fields^)))
    return OK


def _unload(u: Void) abi("C"):
    _unbox[_Udf](u.bitcast[_Udf]()[].host, u)


def _open_context(rt: Void, slot: UInt32, out_p: Void, e: Void) abi("C") -> Int32:
    _set_out_slot(out_p, _box(rt.bitcast[_Rt]()[].host, _Ctx(rt, slot)))
    return OK


def _close_context(c: Void) abi("C"):
    _unbox[_Ctx](c.bitcast[_Ctx]()[].rt.bitcast[_Rt]()[].host, c)


def _open_instance(c: Void, u: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var udf = u.bitcast[_Udf]()
    var host = c.bitcast[_Ctx]()[].rt.bitcast[_Rt]()[].host
    var scratch = _scratch(host, _DEVICE_ARRAY)
    _set_out_slot(out_p, _box(host, _Inst(host, udf[].fx.copy(), udf[].fields.copy(), scratch)))
    return OK


def _close_instance(i: Void) abi("C"):
    var host = i.bitcast[_Inst]()[].host
    _free_scratch(host, i.bitcast[_Inst]()[].scratch, _DEVICE_ARRAY)
    _unbox[_Inst](host, i)


# --- call_batch -------------------------------------------------------------------


def _call_batch(i: Void, call: Void, args: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var inst = i.bitcast[_Inst]()
    var fx = inst[].fx.id
    var shape = inst[].fx.shape
    arr(out_p)[].release = null_void()
    if fx == F_ARGS_KEPT:  # the bug: args read in place, never moved
        var kept = scalar(fx, inst[].host, call, args, out_p, e)
        if kept == OK:
            set_cpu(out_p)
        return kept
    var mine = inst[].scratch
    move_array(mine, args)  # moved in, whatever the status
    var rc = start_call(inst[].host, call, e)
    if rc == OK and mine.bitcast[CArrowDeviceArray]()[].device_type != ARROW_DEVICE_CPU:
        rc = fail(e, ERR_UNSUPPORTED, "only CPU arrays are read here")
    if rc == OK and shape & (SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN) == 0:
        rc = fail(e, ERR_UNSUPPORTED, "call_batch on a fixture of another shape")
    if rc == OK and shape == SHAPE_ROW:
        rc = row_call(fx, inst[].fields, mine, out_p, e)
    elif rc == OK:
        rc = scalar(fx, inst[].host, call, mine, out_p, e)
    if rc == OK:
        set_cpu(out_p)
        # The runtime bugs of the fixtures that plant them.
        if fx == F_OUT_SET_ON_ERROR:
            rc = fail(e, ERR_RAISED, "out_set_on_error: raised with out still set")
        elif fx == F_OK_WITHOUT_OUTPUT:
            release_array(out_p)
        elif fx == F_DEVICE_NOT_CPU:
            out_p.bitcast[CArrowDeviceArray]()[].device_type = 2  # ARROW_DEVICE_CUDA
        elif fx == F_NULL_COUNT_LIES:
            arr(out_p)[].null_count += 1
    release_array(mine)
    return rc


# --- mergeable aggregate: sum ---------------------------------------------------------


def _agg_open(i: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var inst = i.bitcast[_Inst]()
    if inst[].fx.shape != SHAPE_AGG_MERGEABLE:
        return fail(e, ERR_UNSUPPORTED, "agg_open on a fixture of another shape")
    var host = inst[].host
    var scratch = _scratch(host, 2 * _DEVICE_ARRAY)
    _set_out_slot(out_p, _box(host, _Groups(host, inst[].fx.id, List[Int64](), scratch)))
    return OK


def _fold(g: Void, call: Void, values: Void, gids: Void, n_groups: UInt32, e: Void, merge: Bool) -> Int32:
    """agg_update (`merge` False: the values are the argument struct's first
    child) and agg_merge (True: the values are the state column)."""
    var gr = g.bitcast[_Groups]()
    var v = gr[].scratch
    var ids = (gr[].scratch.bitcast[UInt8]() + _DEVICE_ARRAY).bitcast[NoneType]()
    move_array(v, values)  # both moved in
    move_array(ids, gids)
    var rc = OK
    var x = v if merge else (child(v, 0) if n_children(v) > 0 else null_void())
    if cancelled(call):
        rc = fail(e, ERR_CANCELLED, "cancelled before the batch")
    elif is_null(x) or length(ids) != length(v):
        rc = fail(e, ERR_INTERNAL, "group ids and values differ in length")
    while rc == OK and len(gr[].st) < Int(n_groups):
        gr[].st.append(0)
    if rc == OK:
        for r in range(length(v)):
            var gid = Int(i32_at(ids, r))
            if gid < 0 or gid >= Int(n_groups):
                rc = fail(e, ERR_INTERNAL, "a group id is not below n_groups", r)
                break
            if is_valid(x, r):
                gr[].st[gid] += i64_at(x, r)
    release_array(v)
    release_array(ids)
    return rc


def _agg_update(g: Void, call: Void, args: Void, gids: Void, n: UInt32, e: Void) abi("C") -> Int32:
    var host = g.bitcast[_Groups]()[].host
    if g.bitcast[_Groups]()[].fx == F_SUM_ARGS_KEPT:  # the bug: args read in place, never moved
        var view = _scratch(host, _DEVICE_ARRAY)
        move_array(view, args)
        # Put the host's release back: the host still owns `args`.
        arr(args)[].release = arr(view)[].release
        arr(view)[].release = null_void()
        var rc = _fold(g, call, view, gids, n, e, False)
        _free_scratch(host, view, _DEVICE_ARRAY)
        return rc
    return _fold(g, call, args, gids, n, e, False)


def _agg_merge(g: Void, call: Void, states: Void, gids: Void, n: UInt32, e: Void) abi("C") -> Int32:
    return _fold(g, call, states, gids, n, e, True)


def _emit(g: Void, n: UInt32, out_p: Void, e: Void) -> Int32:
    """The first `n` groups' sums, forgotten afterwards: the later groups
    move down by `n`, as the reference runtime's do."""
    arr(out_p)[].release = null_void()
    var gr = g.bitcast[_Groups]()
    var k = Int(n)
    if k > len(gr[].st):
        return fail(e, ERR_INTERNAL, "emit_first_n is above the group count")
    var d = make_col(out_p, k)
    var rest = List[Int64]()
    for i in range(len(gr[].st)):
        if i < k:
            d.bitcast[Int64]()[i] = gr[].st[i]
        else:
            rest.append(gr[].st[i])
    gr[].st = rest^
    set_cpu(out_p)
    return OK


def _agg_state(g: Void, n: UInt32, out_p: Void, e: Void) abi("C") -> Int32:
    return _emit(g, n, out_p, e)


def _agg_finish(g: Void, n: UInt32, out_p: Void, e: Void) abi("C") -> Int32:
    return _emit(g, n, out_p, e)


def _agg_close(g: Void) abi("C"):
    var host = g.bitcast[_Groups]()[].host
    _free_scratch(host, g.bitcast[_Groups]()[].scratch, 2 * _DEVICE_ARRAY)
    _unbox[_Groups](host, g)


# --- frames --------------------------------------------------------------------------


def _stream_release(s: Void):
    var st = s.bitcast[CArrowDeviceArrayStream]()
    if not is_null(st[].release):
        as_release(st[].release)(s)


def _frame_open(i: Void, call: Void, in_p: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var inst = i.bitcast[_Inst]()
    var host = inst[].host
    var mine = _scratch(host, _STREAM)
    # Moved in, whatever the status: copy the six words, NULL the source.
    for w in range(6):
        mine.bitcast[Int64]()[w] = in_p.bitcast[Int64]()[w]
    in_p.bitcast[CArrowDeviceArrayStream]()[].release = null_void()
    var shape = inst[].fx.shape
    var rc = OK
    if shape & (SHAPE_MAP_BATCHES_FRAME | SHAPE_AGG_PLAIN | SHAPE_STEP) == 0:
        rc = fail(e, ERR_UNSUPPORTED, "frame_open on a fixture of another shape")
    if rc == OK:
        rc = start_call(inst[].host, call, e)
    if rc != OK:
        _stream_release(mine)
        _free_scratch(host, mine, _STREAM)
        return rc
    _set_out_slot(out_p, _box(host, _Frame(host, inst[].fx.id, mine, False, 0, -1, 0)))
    return OK


def _pull(fr: Void, b: Void) -> Int32:
    """The next input batch into `b`; 0 with b's release NULL at the end."""
    for w in range(16):
        b.bitcast[Int64]()[w] = 0
    var s = fr.bitcast[_Frame]()[].stream
    return as_get_next(s.bitcast[CArrowDeviceArrayStream]()[].get_next)(s, b)


def _next_running_sum(fr: Void, out_p: Void, e: Void) -> Int32:
    var f = fr.bitcast[_Frame]()
    var b = _scratch(fr.bitcast[_Frame]()[].host, _DEVICE_ARRAY)
    if _pull(fr, b) != 0:
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "the input stream failed")
    if is_null(arr(b)[].release):
        f[].done = True
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return OK
    var n = length(b)
    if n_children(b) < 1:
        release_array(b)
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "running_sum: no input column")
    var x = child(b, 0)
    make_struct(out_p, n, 1)
    var col = child(out_p, 0)
    var d = make_col(col, n)
    for r in range(n):
        if not is_valid(x, r):
            d.bitcast[Int64]()[r] = 0
            set_null(col, r)
            continue
        f[].running += i64_at(x, r)
        d.bitcast[Int64]()[r] = f[].running
    release_array(b)
    _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
    set_cpu(out_p)
    return OK


def _next_group_max(fr: Void, out_p: Void, e: Void) -> Int32:
    """Pulls until a group is complete (or the input ends), and returns the
    completed groups' maxima, one row each, in ordinal order."""
    var f = fr.bitcast[_Frame]()
    var done = List[Int64]()
    var b = _scratch(fr.bitcast[_Frame]()[].host, _DEVICE_ARRAY)
    while len(done) == 0 and not f[].done:
        if _pull(fr, b) != 0:
            _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
            return fail(e, ERR_INTERNAL, "the input stream failed")
        var at_eos = is_null(arr(b)[].release)
        var n = 0 if at_eos else length(b)
        if at_eos:
            f[].done = True
        if n > 0 and n_children(b) < 2:
            release_array(b)
            _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
            return fail(e, ERR_INTERNAL, "group_max: a batch without its group and value columns")
        for r in range(n + 1):
            var at_end = r == n
            if at_end and not f[].done:
                break
            var gid = Int64(-1) if at_end else i64_at(child(b, 0), r)
            if not at_end and gid == f[].group:
                var val = i64_at(child(b, 1), r)
                if val > f[].max:
                    f[].max = val
                continue
            if f[].group >= 0:
                done.append(f[].max)
            f[].group = gid
            if not at_end:
                f[].max = i64_at(child(b, 1), r)
        release_array(b)
    _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
    if len(done) == 0:
        return OK  # the end
    var d = make_col(out_p, len(done))
    for i in range(len(done)):
        d.bitcast[Int64]()[i] = done[i]
    set_cpu(out_p)
    return OK


def _next_step(fr: Void, out_p: Void, e: Void) -> Int32:
    """A step: one length-1 batch of literals in; a table with no columns
    and as many rows as the first literal says, out."""
    var b = _scratch(fr.bitcast[_Frame]()[].host, _DEVICE_ARRAY)
    var rc = _pull(fr, b)
    fr.bitcast[_Frame]()[].done = True
    if rc != 0:
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "the input stream failed")
    if is_null(arr(b)[].release):
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "a step got no literal batch")
    var rows = i64_at(child(b, 0), 0) if length(b) == 1 and n_children(b) == 1 else Int64(-1)
    release_array(b)
    _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
    if rows < 0:
        return fail(e, ERR_INTERNAL, "a step's literal batch is not one int64 row")
    make_struct(out_p, Int(rows), 0)
    set_cpu(out_p)
    return OK


def _next_yield_two(fr: Void, out_p: Void, e: Void) -> Int32:
    """The input batch is the output (a runtime may return its input
    buffers), twice; then an error, with the rest unread."""
    var f = fr.bitcast[_Frame]()
    if f[].running == 2:
        f[].done = True
        return fail(e, ERR_RAISED, "yield_two_then_raise: raised after two outputs")
    if _pull(fr, out_p) != 0:
        return fail(e, ERR_INTERNAL, "the input stream failed")
    if is_null(arr(out_p)[].release):
        f[].done = True
    f[].running += 1
    set_cpu(out_p)
    return OK


def _next_endless(out_p: Void) -> Int32:
    make_struct(out_p, 1, 1)
    var d = make_col(child(out_p, 0), 1)
    d.bitcast[Int64]()[0] = 0
    set_cpu(out_p)
    return OK


def _frame_next(fr: Void, call: Void, out_p: Void, e: Void) abi("C") -> Int32:
    arr(out_p)[].release = null_void()
    if cancelled(call):
        return fail(e, ERR_CANCELLED, "cancelled between batches")
    var f = fr.bitcast[_Frame]()
    if f[].done:
        return OK  # the end: out's release stays NULL
    if f[].fx == F_RUNNING_SUM:
        return _next_running_sum(fr, out_p, e)
    if f[].fx == F_GROUP_MAX:
        return _next_group_max(fr, out_p, e)
    if f[].fx == F_YIELD_TWO_THEN_RAISE:
        return _next_yield_two(fr, out_p, e)
    if f[].fx == F_ENDLESS:
        return _next_endless(out_p)
    return _next_step(fr, out_p, e)


def _frame_close(fr: Void) abi("C"):
    var host = fr.bitcast[_Frame]()[].host
    var s = fr.bitcast[_Frame]()[].stream
    _stream_release(s)
    _free_scratch(host, s, _STREAM)
    _unbox[_Frame](host, fr)


# --- init and shutdown -------------------------------------------------------------------


comptime _ID = "komira/native"
comptime _ABI = "abi1"


def _shutdown(rt: Void) abi("C"):
    var r = rt.bitcast[_Rt]()
    var host = r[].host
    _free_scratch(host, r[].table, size_of[CUdfRuntime]())
    _free_scratch(host, r[].id, _ID.byte_length() + 1)
    _free_scratch(host, r[].abi, _ABI.byte_length() + 1)
    _unbox[_Rt](host, rt)


def native_init(host: Void, rt_slot: Void, e: Void) -> Void:
    """komira_udf_native_init_v1: this library's table, with its runtime
    handle written to `rt_slot`; NULL with `e` filled for a host of another
    ABI major."""
    var h = host.bitcast[CUdfHost]()
    if is_null(host) or h[].struct_size < size_of[CUdfHost]() or h[].abi_major != ABI_MAJOR:
        _ = fail(e, ERR_ABI, "this library speaks ABI major 1")
        return null_void()
    var block = _scratch(host, size_of[CUdfRuntime]())
    # SAFETY: a zeroed block of the table's size; every entry is written below
    # except memory_report, which stays NULL (no MEMORY_REPORT feature).
    var t = block.bitcast[CUdfRuntime]()
    t[].struct_size = size_of[CUdfRuntime]()
    t[].abi_major = ABI_MAJOR
    t[].abi_minor = ABI_MINOR
    t[].describe = _describe
    t[].validate = _validate
    t[].load = _load
    t[].unload = _unload
    t[].open_context = _open_context
    t[].close_context = _close_context
    t[].open_instance = _open_instance
    t[].close_instance = _close_instance
    t[].call_batch = _call_batch
    t[].frame_open = _frame_open
    t[].frame_next = _frame_next
    t[].frame_close = _frame_close
    t[].agg_open = _agg_open
    t[].agg_update = _agg_update
    t[].agg_merge = _agg_merge
    t[].agg_state = _agg_state
    t[].agg_finish = _agg_finish
    t[].agg_close = _agg_close
    t[].shutdown = _shutdown
    _reserve(host, _ID.byte_length() + 1)
    _reserve(host, _ABI.byte_length() + 1)
    _set_out_slot(rt_slot, _box(host, _Rt(host, block, _cstr(_ID), _cstr(_ABI))))
    return block
