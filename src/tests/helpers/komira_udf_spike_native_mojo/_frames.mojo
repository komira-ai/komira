# The frames of this native UDF library: MAP_BATCHES_FRAME, plain
# aggregates and steps (docs/design/udf_runtime_interface.md section 4.3).
# The handles and the memory they hold are _handles.mojo's (its
# FFI-BOUNDARY header says who owns and frees each pointer); the `in`
# stream is moved into a 48-byte block of the frame, released at the end of
# the stream or at frame_close.
#
# A pull (design section 4.3, "When producing a pull's input fails"): a
# get_next that fails has its get_last_error text copied first, and nothing
# but release is called on the stream after it (ERR_INTERNAL with that text,
# which the host ignores); a batch off the CPU, with a bitmap or offset on
# its struct, or another child count than the bound schema's is the host's
# breach (ERR_HOST_CONTRACT); a pull that returns with the call's cancel set
# or past its deadline releases the batch unread and fails with
# ERR_CANCELLED or ERR_DEADLINE.

from komira_udf_spike_abi._cabi import (
    CArrowDeviceArray,
    CArrowDeviceArrayStream,
    Void,
    as_get_next,
    as_last_error,
    as_release,
    is_null,
    null_void,
    read_cstr,
)
from komira_udf_spike_abi.contract import (
    ARROW_DEVICE_CPU,
    ERR_CANCELLED,
    ERR_DEADLINE,
    ERR_HOST_CONTRACT,
    ERR_INTERNAL,
    ERR_RAISED,
    ERR_UNSUPPORTED,
    OK,
    SHAPE_AGG_PLAIN,
    SHAPE_MAP_BATCHES_FRAME,
    SHAPE_STEP,
)

from ._arrow import (
    PAD_VALUE,
    _free_error,
    arr,
    child,
    fail,
    i64_at,
    is_valid,
    length,
    make_col,
    make_struct,
    n_children,
    release_array,
    set_cpu,
    set_null,
    struct_validity,
    word_at,
)
from ._fixtures import (
    F_ENDLESS,
    F_FRAME_ROW_COUNTS,
    F_GROUP_MAX,
    F_RAISE_AGAIN,
    F_RUNNING_SUM,
    F_RUNNING_SUM_CATCH,
    F_TABLE_NULL_COUNT_UNKNOWN,
    F_TABLE_SLICED,
    F_TWO_TYPES,
    F_YIELD_FIRST,
    F_YIELD_THREE_THEN_RAISE,
    F_YIELD_TWO_THEN_RAISE,
    cancelled,
    past_deadline,
    start_call,
)
from ._handles import _DEVICE_ARRAY, _Frame, _Inst, _STREAM, _box, _free_scratch, _scratch, _set_out_slot, _unbox

comptime _TABLE_AT = 2
"""table_sliced: the struct's offset."""
comptime _CHILD_AT = 3
"""table_sliced: its child's own offset."""


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
    var want = inst[].n_args + (1 if shape == SHAPE_AGG_PLAIN else 0)
    _set_out_slot(out_p, _box(host, _Frame(host, inst[].fx.id, mine, False, 0, -1, 0, False, want, null_void(), False)))
    return OK


def _pull(fr: Void, b: Void, e: Void) -> Int32:
    """The next input batch into `b`: OK, with b's release NULL at the end;
    else a failure with `e` filled (the file header says which)."""
    var f = fr.bitcast[_Frame]()
    for w in range(16):
        b.bitcast[Int64]()[w] = 0
    if f[].in_failed:
        return fail(e, ERR_INTERNAL, "the input stream failed earlier")
    var s = f[].stream
    var st = s.bitcast[CArrowDeviceArrayStream]()
    var got = as_get_next(st[].get_next)(s, b)
    if got != 0:
        var le = as_last_error(st[].get_last_error)(s)
        var why = read_cstr(le) if not is_null(le) else "no message"
        f[].in_failed = True
        arr(b)[].release = null_void()
        return fail(e, ERR_INTERNAL, "the input stream failed (" + String(got) + "): " + why)
    if is_null(arr(b)[].release):
        return OK
    # SAFETY: `b` is a 128-byte device array the host just wrote.
    var d = b.bitcast[CArrowDeviceArray]()
    if d[].device_type != ARROW_DEVICE_CPU or d[].device_id != -1 or not is_null(d[].sync_event):
        release_array(b)
        return fail(e, ERR_HOST_CONTRACT, "an input batch on another device than the CPU (design 4.4)")
    if arr(b)[].offset != 0 or not is_null(word_at(arr(b)[].buffers, 0)):
        release_array(b)
        return fail(e, ERR_HOST_CONTRACT, "an input batch's struct has an offset or a bitmap (design 3.4 rule 5)")
    if n_children(b) != f[].want:
        var n = n_children(b)
        release_array(b)
        return fail(
            e, ERR_HOST_CONTRACT,
            "an input batch has " + String(n) + " children, the schema bound at load " + String(f[].want),
        )
    if cancelled(f[].call):
        release_array(b)
        return fail(e, ERR_CANCELLED, "cancelled while the frame waited on its input; the batch was not run")
    if past_deadline(f[].host, f[].call):
        release_array(b)
        return fail(e, ERR_DEADLINE, "the deadline passed while the frame waited on its input; the batch was not run")
    return OK


def _next_running_sum(fr: Void, out_p: Void, e: Void) -> Int32:
    var f = fr.bitcast[_Frame]()
    var b = _scratch(fr.bitcast[_Frame]()[].host, _DEVICE_ARRAY)
    var got = _pull(fr, b, e)
    if got != OK:
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return got
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
        var got = _pull(fr, b, e)
        if got != OK:
            _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
            return got
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
    var rc = _pull(fr, b, e)
    fr.bitcast[_Frame]()[].done = True
    if rc != OK:
        _free_scratch(fr.bitcast[_Frame]()[].host, b, _DEVICE_ARRAY)
        return rc
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


def _next_yield_n(fr: Void, n: Int64, out_p: Void, e: Void) -> Int32:
    """The input batch is the output (a runtime may return its input
    buffers), `n` times; then an error (naming no row after two, row 1
    after three), with the rest unread."""
    var f = fr.bitcast[_Frame]()
    if f[].running == n:
        f[].done = True
        if n == 2:
            return fail(e, ERR_RAISED, "yield_two_then_raise: raised after two outputs")
        return fail(e, ERR_RAISED, "yield_three_then_raise: raised after three outputs", 1)
    var got = _pull(fr, out_p, e)
    if got != OK:
        return got
    if is_null(arr(out_p)[].release):
        f[].done = True
    f[].running += 1
    set_cpu(out_p)
    return OK


def _next_table(fr: Void, out_p: Void, e: Void, sliced: Bool) -> Int32:
    """Each input batch's first column as a one-column table, with a validity
    bitmap. table_sliced (`sliced`) places the n rows at struct offset
    _TABLE_AT over a child of _TABLE_AT + n rows at offset _CHILD_AT, the
    rows before them PAD_VALUE with null bits, in the child and in the
    struct's bitmap; table_null_count_unknown reports null_count -1. Both
    legal (n <= 62 here)."""
    var f = fr.bitcast[_Frame]()
    var host = f[].host
    var b = _scratch(host, _DEVICE_ARRAY)
    var got = _pull(fr, b, e)
    if got != OK:
        _free_scratch(host, b, _DEVICE_ARRAY)
        return got
    if is_null(arr(b)[].release):
        f[].done = True
        _free_scratch(host, b, _DEVICE_ARRAY)
        return OK
    var n = length(b)
    if n_children(b) < 1:
        release_array(b)
        _free_scratch(host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "table: no input column")
    var x = child(b, 0)
    var pad = _CHILD_AT + _TABLE_AT if sliced else 0
    make_struct(out_p, pad + n, 1)
    var col = child(out_p, 0)
    var d = make_col(col, pad + n)
    for r in range(pad + n):
        if r < pad or not is_valid(x, r - pad):
            d.bitcast[Int64]()[r] = PAD_VALUE if r < pad else 0
            set_null(col, r)
        else:
            d.bitcast[Int64]()[r] = i64_at(x, r - pad)
    release_array(b)
    _free_scratch(host, b, _DEVICE_ARRAY)
    set_cpu(out_p)
    var v = struct_validity(out_p)
    if sliced:
        arr(col)[].offset = Int64(_CHILD_AT)
        arr(col)[].length = Int64(_TABLE_AT + n)
        arr(col)[].null_count -= Int64(_CHILD_AT)  # the pad rows before the child's offset are not its rows
        arr(out_p)[].offset = Int64(_TABLE_AT)
        arr(out_p)[].length = Int64(n)
        for r in range(_TABLE_AT):
            # SAFETY: struct_validity's 8 bytes; r < 8.
            v.bitcast[UInt8]()[0] = v.bitcast[UInt8]()[0] & ~(UInt8(1) << UInt8(r))
    else:
        arr(out_p)[].null_count = -1
    return OK


def _next_two_types(fr: Void, out_p: Void, e: Void) -> Int32:
    """Each input batch's column x as a table (x int64, 10 * x int32), nulls
    where x is null."""
    var f = fr.bitcast[_Frame]()
    var host = f[].host
    var b = _scratch(host, _DEVICE_ARRAY)
    var got = _pull(fr, b, e)
    if got != OK:
        _free_scratch(host, b, _DEVICE_ARRAY)
        return got
    if is_null(arr(b)[].release):
        f[].done = True
        _free_scratch(host, b, _DEVICE_ARRAY)
        return OK
    var n = length(b)
    if n_children(b) < 1:
        release_array(b)
        _free_scratch(host, b, _DEVICE_ARRAY)
        return fail(e, ERR_INTERNAL, "table_two_types: no input column")
    var x = child(b, 0)
    make_struct(out_p, n, 2)
    var c0 = child(out_p, 0)
    var c1 = child(out_p, 1)
    var d0 = make_col(c0, n)
    var d1 = make_col(c1, n)
    for r in range(n):
        # SAFETY: make_col's values blocks of n rows (8 bytes each, int32 in
        # the first 4 * n of c1's).
        if is_valid(x, r):
            d0.bitcast[Int64]()[r] = i64_at(x, r)
            d1.bitcast[Int32]()[r] = Int32(10 * i64_at(x, r))
        else:
            set_null(c0, r)
            set_null(c1, r)
    release_array(b)
    _free_scratch(host, b, _DEVICE_ARRAY)
    set_cpu(out_p)
    return OK


def _next_row_counts(fr: Void, out_p: Void, e: Void) -> Int32:
    """frame_row_counts: each input batch, which has no columns, as a
    one-row table holding its row count (its length, design 3.4 rule 5)."""
    var f = fr.bitcast[_Frame]()
    var host = f[].host
    var b = _scratch(host, _DEVICE_ARRAY)
    var got = _pull(fr, b, e)
    if got != OK:
        _free_scratch(host, b, _DEVICE_ARRAY)
        return got
    if is_null(arr(b)[].release):
        f[].done = True
        _free_scratch(host, b, _DEVICE_ARRAY)
        return OK
    var n = length(b)
    release_array(b)
    _free_scratch(host, b, _DEVICE_ARRAY)
    make_struct(out_p, 1, 1)
    make_col(child(out_p, 0), 1).bitcast[Int64]()[0] = Int64(n)
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
    f[].call = call
    if f[].done:
        return OK  # the end: out's release stays NULL
    if f[].fx == F_RAISE_AGAIN:
        f[].running += 1
        if f[].running == 1:
            return fail(e, ERR_RAISED, "raise_again: raised")
        return fail(e, ERR_INTERNAL, "raise_again: frame_next called after an error")
    if f[].fx == F_YIELD_FIRST and not f[].yielded:
        # One output before any pull: a one-row table [0].
        f[].yielded = True
        make_struct(out_p, 1, 1)
        make_col(child(out_p, 0), 1).bitcast[Int64]()[0] = 0
        set_cpu(out_p)
        return OK
    if f[].fx == F_RUNNING_SUM or f[].fx == F_YIELD_FIRST:
        return _next_running_sum(fr, out_p, e)
    if f[].fx == F_RUNNING_SUM_CATCH:
        var rc = _next_running_sum(fr, out_p, e)
        if rc == OK or not f[].in_failed:
            return rc
        # User code caught the failed pull's error: it yields [-1] and ends.
        _free_error(e)
        f[].done = True
        make_struct(out_p, 1, 1)
        make_col(child(out_p, 0), 1).bitcast[Int64]()[0] = -1
        set_cpu(out_p)
        return OK
    if f[].fx == F_GROUP_MAX:
        return _next_group_max(fr, out_p, e)
    if f[].fx == F_YIELD_TWO_THEN_RAISE:
        return _next_yield_n(fr, 2, out_p, e)
    if f[].fx == F_YIELD_THREE_THEN_RAISE:
        return _next_yield_n(fr, 3, out_p, e)
    if f[].fx == F_FRAME_ROW_COUNTS:
        return _next_row_counts(fr, out_p, e)
    if f[].fx == F_ENDLESS:
        return _next_endless(out_p)
    if f[].fx == F_TABLE_SLICED or f[].fx == F_TABLE_NULL_COUNT_UNKNOWN:
        return _next_table(fr, out_p, e, f[].fx == F_TABLE_SLICED)
    if f[].fx == F_TWO_TYPES:
        return _next_two_types(fr, out_p, e)
    return _next_step(fr, out_p, e)


def _frame_close(fr: Void) abi("C"):
    var host = fr.bitcast[_Frame]()[].host
    var s = fr.bitcast[_Frame]()[].stream
    _stream_release(s)
    _free_scratch(host, s, _STREAM)
    _unbox[_Frame](host, fr)
