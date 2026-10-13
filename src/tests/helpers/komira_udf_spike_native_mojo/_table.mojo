# =============================================================================
# FFI-BOUNDARY: the komira_udf_runtime table of this native UDF library.
# =============================================================================
# native_init is what the library's one export, komira_udf_native_init_v1
# (so/native_mojo_so.mojo), returns: a table whose entries are the abi("C")
# functions below and the frames of _frames.mojo, over the fixtures of
# _fixtures.mojo (docs/design/udf_runtime_interface.md section 4.3).
#
# This is a native UDF library, loaded by the native runtime, which checks
# the descriptor at validate and load (design section 3.1); this library's
# load binds the spec's schemas to its fixture, so a spec its code was not
# built for is refused there (the runtime reports ERR_LOAD).
#
# Who owns and frees each pointer:
#   - the table and the runtime handle: one block each, made by native_init
#     and freed by shutdown (Mojo has no global variables, so the table is
#     not static data: the host reads it only until shutdown, which this
#     relies on).
#   - udf, context, instance, groups and frame handles: one heap struct
#     each, made by its open entry and freed by its close entry
#     (_handles.mojo).
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

from std.sys import size_of

from komira_udf_spike_abi._cabi import (
    CArrowDeviceArray,
    CArrowDeviceArrayStream,
    CUdfCapabilities,
    CUdfHost,
    CUdfRuntime,
    CUdfSpec,
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
    DEVICE_CPU,
    ERR_ABI,
    ERR_CANCELLED,
    ERR_HOST_CONTRACT,
    ERR_INTERNAL,
    ERR_RAISED,
    ERR_UNSUPPORTED,
    OK,
    SHAPE_AGG_MERGEABLE,
    SHAPE_AGG_PLAIN,
    SHAPE_MAP_BATCHES_COLUMN,
    SHAPE_MAP_BATCHES_FRAME,
    SHAPE_ROW,
    SHAPE_SCALAR,
    SHAPE_STEP,
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
    PAD_VALUE,
    make_col,
    make_struct,
    move_array,
    n_children,
    release_array,
    set_cpu,
    set_null,
    fail_keep_row,
    schema_child,
    schema_children,
    schema_flags,
    slice_col,
    struct_validity,
    word_at,
)
from ._frames import _frame_close, _frame_next, _frame_open
from ._handles import (
    _DEVICE_ARRAY,
    _Ctx,
    _Groups,
    _Inst,
    _Rt,
    _Udf,
    _box,
    _free_scratch,
    _release,
    _reserve,
    _scratch,
    _set_out_slot,
    _unbox,
)
from ._fixtures import (
    F_ARGS_KEPT,
    F_DEVICE_NOT_CPU,
    F_ENDLESS,
    F_GROUP_MAX,
    F_LEAF_EMPTY_DATA_NULL,
    F_LEAF_NULL_COUNT_UNKNOWN,
    F_LEAF_SLICED,
    F_NULL_COUNT_LIES,
    F_OK_WITHOUT_OUTPUT,
    F_OUT_SET_ON_ERROR,
    F_RAISE_NO_ROW,
    F_RUNNING_SUM,
    F_SUM_ARGS_KEPT,
    F_SUM_FINISH_SHORT,
    F_SUM_STATE_LONG,
    F_TABLE_NULL_COUNT_UNKNOWN,
    F_TABLE_SLICED,
    F_TWO_TYPES,
    F_CHILD_MOVED_OUT,
    F_FLAGS_PROBE,
    F_RAISE_AGAIN,
    F_RAISE_IF_5,
    F_RAISE_ROW_UNSET,
    F_SUM_ONE_SET,
    F_VOLATILE_COUNT,
    F_YIELD_FIRST,
    F_YIELD_TWO_THEN_RAISE,
    Fixture,
    check_spec,
    read_set,
    row_call,
    scalar,
    start_call,
    cancelled,
)

comptime _SLICE_AT = 11
"""leaf_sliced: the column's offset (not a multiple of 8, so the bitmap's
bits are shifted too)."""


# --- describe, validate, load ---------------------------------------------------


def _describe(rt: Void, c: Void) abi("C") -> Int32:
    var p = c.bitcast[CUdfCapabilities]()
    if is_null(c) or p[].struct_size < size_of[CUdfCapabilities]():
        return ERR_ABI
    var r = rt.bitcast[_Rt]()
    p[].runtime_id = r[].id
    p[].runtime_abi = r[].abi
    p[].max_descriptor_version = 1
    p[].shapes = (
        SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN | SHAPE_MAP_BATCHES_FRAME | SHAPE_AGG_PLAIN
        | SHAPE_AGG_MERGEABLE | SHAPE_STEP
    )
    p[].devices = DEVICE_CPU
    p[].features = 0
    p[].udf_class = CLASS_NATIVE
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
    # flags_probe: the flags of the argument struct's schema, of its first
    # field and of the result schema, as load sees them.
    # SAFETY: check_spec read the spec's struct_size, args and result.
    var sp = s.bitcast[CUdfSpec]()
    var args_s = sp[].args
    var first = schema_child(args_s, 0) if schema_children(args_s) > 0 else null_void()
    var flags: List[Int64] = [schema_flags(args_s), schema_flags(first), schema_flags(sp[].result)]
    var host = rt.bitcast[_Rt]()[].host
    var n_args = schema_children(args_s)
    _set_out_slot(out_p, _box(host, _Udf(host, fx^, fields^, flags^, n_args)))
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
    _set_out_slot(
        out_p,
        _box(host, _Inst(host, udf[].fx.copy(), udf[].fields.copy(), udf[].flags.copy(), scratch, 0, udf[].n_args, 0)),
    )
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
    # What the host owes this library (design 4.5, ERR_HOST_CONTRACT): CPU
    # arrays, an argument struct at offset 0 without a bitmap, one child per
    # argument bound at load.
    var dev = mine.bitcast[CArrowDeviceArray]()
    if rc == OK and (dev[].device_type != ARROW_DEVICE_CPU or dev[].device_id != -1 or not is_null(dev[].sync_event)):
        rc = fail(e, ERR_HOST_CONTRACT, "an argument array on another device than the CPU (design 4.4)")
    if rc == OK and (arr(mine)[].offset != 0 or not is_null(word_at(arr(mine)[].buffers, 0))):
        rc = fail(e, ERR_HOST_CONTRACT, "the argument struct has an offset or a bitmap (design 3.4 rule 5)")
    if rc == OK and n_children(mine) != inst[].n_args:
        rc = fail(
            e, ERR_HOST_CONTRACT,
            "the argument struct has " + String(n_children(mine)) + " children, the schema bound at load "
            + String(inst[].n_args),
        )
    if rc == OK and shape & (SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN) == 0:
        rc = fail(e, ERR_UNSUPPORTED, "call_batch on a fixture of another shape")
    if rc == OK and fx == F_RAISE_IF_5:
        # Naming no row: the host bisects to find it.
        var x = child(mine, 0)
        for r in range(length(mine)):
            if is_valid(x, r) and i64_at(x, r) == 5:
                rc = fail(e, ERR_RAISED, "raise_minus_one_if_row5: the batch holds the value 5")
                break
    if rc == OK and fx == F_VOLATILE_COUNT:
        # Counts its runs; a batch whose row 0 is -1 asks the count instead.
        var x = child(mine, 0)
        var probe = length(mine) > 0 and is_valid(x, 0) and i64_at(x, 0) == -1
        if not probe:
            inst[].runs += 1
            rc = fail(e, ERR_RAISED, "volatile_count_raise: raised after counting this run")
        else:
            var d = make_col(out_p, length(mine))
            for r in range(length(mine)):
                d.bitcast[Int64]()[r] = inst[].runs
            set_cpu(out_p)
            release_array(mine)
            return OK
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
        # A batch function raising naming no row (legal: row -1).
        elif fx == F_RAISE_NO_ROW:
            release_array(out_p)
            rc = fail(e, ERR_RAISED, "raise_no_row: raised naming no row")
        # Legal output layouts the host must read.
        elif fx == F_LEAF_SLICED:
            slice_col(out_p, _SLICE_AT)
        elif fx == F_LEAF_NULL_COUNT_UNKNOWN:
            arr(out_p)[].null_count = -1
        elif fx == F_LEAF_EMPTY_DATA_NULL and length(out_p) == 0:
            # SAFETY: make_col's two-entry buffer list; the block stays
            # private_data, which the release frees.
            arr(out_p)[].buffers.bitcast[Void]()[1] = null_void()
        # Each row r: the flags load saw, row 2 on the result schema's.
        elif fx == F_FLAGS_PROBE:
            for r in range(length(out_p)):
                # SAFETY: make_col's values block of length rows.
                word_at(arr(out_p)[].buffers, 1).bitcast[Int64]()[r] = inst[].flags[r if r < 2 else 2]
        # Code and message set, the row left as the host set it.
        elif fx == F_RAISE_ROW_UNSET:
            release_array(out_p)
            rc = fail_keep_row(e, ERR_RAISED, "raise_row_unset: no row given")
    if fx == F_CHILD_MOVED_OUT and n_children(mine) > 0 and not is_null(arr(mine)[].release):
        # The child moved out: its 80 bytes copied, the struct's slot marked
        # released, so the struct's release skips it; then released here.
        var kid = _scratch(inst[].host, _DEVICE_ARRAY)
        var slot = child(mine, 0)
        # SAFETY: `slot` is a struct ArrowArray (10 words) of the moved-in
        # argument struct; `kid` a 128-byte scratch block.
        for w in range(10):
            kid.bitcast[Int64]()[w] = slot.bitcast[Int64]()[w]
        arr(slot)[].release = null_void()
        release_array(kid)
        _free_scratch(inst[].host, kid, _DEVICE_ARRAY)
    release_array(mine)
    return rc


# --- mergeable aggregate: sum ---------------------------------------------------------


def _agg_open(i: Void, out_p: Void, e: Void) abi("C") -> Int32:
    var inst = i.bitcast[_Inst]()
    if inst[].fx.shape != SHAPE_AGG_MERGEABLE:
        return fail(e, ERR_UNSUPPORTED, "agg_open on a fixture of another shape")
    if inst[].fx.id == F_SUM_ONE_SET:
        inst[].group_sets += 1
        if inst[].group_sets > 1:
            return fail(e, ERR_INTERNAL, "this instance already opened its group set")
    var host = inst[].host
    var scratch = _scratch(host, 2 * _DEVICE_ARRAY)
    _set_out_slot(out_p, _box(host, _Groups(host, inst[].fx.id, List[Int64](), scratch, inst[].n_args)))
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
    if not merge and n_children(v) != gr[].n_args:
        rc = fail(
            e, ERR_HOST_CONTRACT,
            "the argument struct has " + String(n_children(v)) + " children, the schema bound at load "
            + String(gr[].n_args),
        )
    elif cancelled(call):
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


def _emit(g: Void, n: UInt32, extra: Int, out_p: Void, e: Void) -> Int32:
    """The first `n` groups' sums, forgotten afterwards: the later groups
    move down by `n`, as the reference runtime's do. The column has n +
    `extra` rows (a fixture's bug when not 0): the sums, then zeros."""
    arr(out_p)[].release = null_void()
    var gr = g.bitcast[_Groups]()
    var k = Int(n)
    if k > len(gr[].st):
        return fail(e, ERR_INTERNAL, "emit_first_n is above the group count")
    var rows = k + extra if k + extra > 0 else 0
    var d = make_col(out_p, rows)
    for i in range(rows):
        d.bitcast[Int64]()[i] = gr[].st[i] if i < k else 0
    var rest = List[Int64]()
    for i in range(k, len(gr[].st)):
        rest.append(gr[].st[i])
    gr[].st = rest^
    set_cpu(out_p)
    return OK


def _agg_state(g: Void, n: UInt32, out_p: Void, e: Void) abi("C") -> Int32:
    return _emit(g, n, 1 if g.bitcast[_Groups]()[].fx == F_SUM_STATE_LONG else 0, out_p, e)


def _agg_finish(g: Void, n: UInt32, out_p: Void, e: Void) abi("C") -> Int32:
    return _emit(g, n, -1 if g.bitcast[_Groups]()[].fx == F_SUM_FINISH_SHORT else 0, out_p, e)


def _agg_close(g: Void) abi("C"):
    var host = g.bitcast[_Groups]()[].host
    _free_scratch(host, g.bitcast[_Groups]()[].scratch, 2 * _DEVICE_ARRAY)
    _unbox[_Groups](host, g)



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
