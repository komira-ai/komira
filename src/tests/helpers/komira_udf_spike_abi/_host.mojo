# =============================================================================
# FFI-BOUNDARY: the host side of komira_udf_runtime.h, behind runtime.mojo.
# =============================================================================
# What the engine owes a runtime and checks of it (design sections 4.4 to
# 4.6): the host struct and its callbacks, the Arrow C Data arrays and the
# device stream the host exports, and the validation of every array a
# runtime returns before any value is read.
#
# Who owns and frees each pointer:
#   - _Arena blocks: every buffer, child array, schema, string and record the
#     host exports is a block of the UdfRuntime's arena, freed by free_all
#     after shutdown returns, never by a release callback. So a runtime that
#     releases late, twice, or after close is counted, not a use after free.
#   - _HostData: one zeroed block per UdfRuntime (host.host_data), freed with
#     the arena. Every release callback reaches it through its record and
#     counts there (single-threaded: the harness calls from one thread).
#   - exported arrays (`args`, `states`, `group_ids`, stream batches): moved
#     to the runtime, which calls `release` once; _release_array counts the
#     first call of a root in `released` and any later one in
#     `double_released`, releases the children still owned, and NULLs the
#     slot.
#   - exported schemas (spec.args/result/state): borrowed for validate and
#     load; a runtime must not release them, and _release_schema counts one
#     that does.
#   - the `in` stream of frame_open: moved to the runtime; _release_stream
#     counts its release. One frame_open did not move is still the host's,
#     and runtime.mojo releases it once (release_stream).
#   - _HostData.cancel_on_clock: the in-flight call's cancel flag, an arena
#     block, armed only between _begin and _end of that call.
#   - a runtime's `out` arrays: the runtime's until import_* has validated and
#     copied them, then released here once through their own callback.
#   - komira_udf_error: allocated per call here; its strings are the
#     runtime's until its `release` (called once, when non-NULL).
# =============================================================================

from std.ffi import external_call
from std.sys import size_of
from std.time import perf_counter_ns

from ._cabi import (
    CArrowArray,
    CArrowDeviceArray,
    CArrowDeviceArrayStream,
    CArrowSchema,
    CUdfError,
    CUdfHost,
    Void,
    Word,
    as_release,
    free_zeroed,
    get_next_word,
    get_schema_word,
    is_null,
    last_error_word,
    null_void,
    read_cstr,
    release_word,
    zeroed,
)
from .contract import ABI_MINOR, ARROW_DEVICE_CPU, ARROW_FLAG_NULLABLE, OK
from .values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT32, type_format, type_width

comptime _PAD_VALUE: Int64 = 0x5EAD5EAD
"""Written into the rows before an array's offset: a reader that ignores the
offset reads this, never a value of the column."""


struct _HostData:
    """host.host_data: the counts every callback keeps."""

    var exported: Int
    var released: Int
    var double_released: Int
    var schemas_released: Int
    var streams_exported: Int
    var streams_released: Int
    var reserved_bytes: Int
    var log_lines: Int
    var cancel_on_clock: Void
    """The cancel flag of the call in flight when it was started with
    cancel_during_call, else NULL: now_ns sets it (arm_cancel_on_clock)."""


struct _ArrRec:
    """private_data of an exported array."""

    var hd: Void
    var is_root: Int
    var releases: Int
    var n_children: Int
    var children: Void


struct _StreamRec:
    """private_data of an exported device stream: `n` prepared root arrays
    (CArrowArray, 80 bytes each) at `batches`, handed out in order."""

    var hd: Void
    var n: Int
    var next: Int
    var pulls: Int
    var batches: Void


struct _Arena(Movable):
    """Every block the host exports into (see the file header)."""

    var blocks: List[Void]

    def __init__(out self):
        self.blocks = List[Void]()

    def bytes(mut self, n: Int) -> Void:
        var p = zeroed(n)
        self.blocks.append(p)
        return p

    def word(mut self, n: Int) -> Word:
        """`n` zeroed bytes as a Word: an out-slot or an `out` array."""
        return Word(self.bytes(n))

    def cstr(mut self, s: String) -> Void:
        """A NUL-terminated copy of `s`.

        # SAFETY: the block is len + 1 zeroed bytes; the copy writes len.
        """
        var b = s.as_bytes()
        var p = self.bytes(len(b) + 1)
        var d = p.bitcast[UInt8]()
        for k in range(len(b)):
            d[k] = b[k]
        return p

    def free_all(mut self):
        for k in range(len(self.blocks)):
            free_zeroed(self.blocks[k])
        self.blocks = List[Void]()


# --- host struct and callbacks --------------------------------------------------


def _hd(p: Void) -> UnsafePointer[_HostData, MutUntrackedOrigin]:
    # SAFETY: `p` is the _HostData block make_host allocated, alive with the arena.
    return p.bitcast[_HostData]()


def _host_mem_reserve(host_data: Void, bytes: Int64) abi("C") -> Int32:
    _hd(host_data)[].reserved_bytes += Int(bytes)
    return OK


def _host_mem_release(host_data: Void, bytes: Int64) abi("C"):
    _hd(host_data)[].reserved_bytes -= Int(bytes)


def arm_cancel_on_clock(hd: Word, flag: Word):
    """From now until disarm_cancel_on_clock, the host's now_ns sets `flag`
    (a call's cancel flag, an arena block) each time a runtime reads the
    clock: a cancel set from inside the call, at a point the runtime's own
    clock read fixes."""
    _hd(hd.p)[].cancel_on_clock = flag.p


def disarm_cancel_on_clock(hd: Word):
    _hd(hd.p)[].cancel_on_clock = null_void()


def _host_now_ns(host_data: Void) abi("C") -> Int64:
    var flag = _hd(host_data)[].cancel_on_clock
    if not is_null(flag):
        # SAFETY: the armed flag is the in-flight call's arena block.
        external_call["komira_udf_spike_cancel_store", NoneType](flag)
    return Int64(perf_counter_ns())


def _host_log(host_data: Void, level: Int32, utf8: Void) abi("C"):
    _hd(host_data)[].log_lines += 1


def make_host(mut arena: _Arena, abi_major: UInt32) -> Word:
    """A komira_udf_host claiming `abi_major`, with a fresh _HostData.

    # SAFETY: both blocks are zeroed arena blocks of their struct's size; the
    # fields are plain words written in place.
    """
    var hd = arena.bytes(size_of[_HostData]())
    var h = arena.bytes(size_of[CUdfHost]()).bitcast[CUdfHost]()
    h[].struct_size = size_of[CUdfHost]()
    h[].abi_major = abi_major
    h[].abi_minor = ABI_MINOR
    h[].host_data = hd
    h[].mem_reserve = _host_mem_reserve
    h[].mem_release = _host_mem_release
    h[].now_ns = _host_now_ns
    h[].log = _host_log
    return Word(h.bitcast[NoneType]())


def host_data_of(host: Word) -> Word:
    # SAFETY: `host` is a block make_host filled.
    return Word(host.p.bitcast[CUdfHost]()[].host_data)


@fieldwise_init
struct Counts(Copyable, Movable):
    var exported: Int
    var released: Int
    var double_released: Int
    var schemas_released: Int
    var streams_exported: Int
    var streams_released: Int
    var reserved_bytes: Int
    """Bytes a runtime holds through mem_reserve, net of mem_release."""


def counts(hd: Word) -> Counts:
    var d = _hd(hd.p)
    return Counts(
        d[].exported, d[].released, d[].double_released, d[].schemas_released,
        d[].streams_exported, d[].streams_released, d[].reserved_bytes,
    )


# --- export -------------------------------------------------------------------
#
# SAFETY (every function below): `dst` is a zeroed block at least the size of
# the struct written there; every block written is an arena block.


def _release_array(arr: Void) abi("C"):
    var a = arr.bitcast[CArrowArray]()
    var rec = a[].private_data.bitcast[_ArrRec]()
    if rec[].is_root == 1:
        var d = _hd(rec[].hd)
        if rec[].releases == 0:
            d[].released += 1
        else:
            d[].double_released += 1
    rec[].releases += 1
    for i in range(rec[].n_children):
        var c = (rec[].children.bitcast[Void]() + i)[]
        var cr = c.bitcast[CArrowArray]()[].release
        if not is_null(cr):
            as_release(cr)(c)
    a[].release = null_void()


def _release_schema(s: Void) abi("C"):
    var p = s.bitcast[CArrowSchema]()
    _hd(p[].private_data)[].schemas_released += 1
    p[].release = null_void()


def _new_rec(mut arena: _Arena, hd: Void, is_root: Bool, n_children: Int, children: Void) -> Void:
    var rec = arena.bytes(size_of[_ArrRec]()).bitcast[_ArrRec]()
    rec[].hd = hd
    rec[].is_root = 1 if is_root else 0
    rec[].releases = 0
    rec[].n_children = n_children
    rec[].children = children
    return rec.bitcast[NoneType]()


def _fill_column(mut arena: _Arena, dst: Void, col: Column, hd: Void, is_root: Bool):
    var n = len(col)
    var off = col.offset
    var w = type_width(col.type_id)
    var nulls = col.null_count()
    var validity = null_void()
    if nulls > 0 or off > 0:
        validity = arena.bytes((off + n + 7) // 8)
        var vb = validity.bitcast[UInt8]()
        for i in range(off + n):
            if i < off or col.valid[i - off]:
                vb[i >> 3] = vb[i >> 3] | UInt8(1 << (i & 7))
    var data = arena.bytes((off + n) * w)
    for i in range(off + n):
        var v = _PAD_VALUE if i < off else col.bits[i - off]
        if w == 4:
            (data.bitcast[Int32]() + i)[] = Int32(v)
        else:
            (data.bitcast[Int64]() + i)[] = v
    var bufs = arena.bytes(16).bitcast[Void]()
    bufs[0] = validity
    bufs[1] = data
    var a = dst.bitcast[CArrowArray]()
    a[].length = Int64(n)
    a[].null_count = Int64(nulls)
    a[].offset = Int64(off)
    a[].n_buffers = 2
    a[].n_children = 0
    a[].buffers = bufs.bitcast[NoneType]()
    a[].children = null_void()
    a[].dictionary = null_void()
    a[].release = release_word(_release_array)
    a[].private_data = _new_rec(arena, hd, is_root, 0, null_void())
    if is_root:
        _hd(hd)[].exported += 1


def _fill_struct(mut arena: _Arena, dst: Void, batch: Batch, hd: Void):
    """A struct array of `batch.length` rows, no validity, offset 0, one child
    per column (design section 3.4 rule 5)."""
    var k = len(batch.columns)
    var children = arena.bytes(8 * k if k > 0 else 8).bitcast[Void]()
    for i in range(k):
        var c = arena.bytes(size_of[CArrowArray]())
        _fill_column(arena, c, batch.columns[i], hd, False)
        children[i] = c
    var bufs = arena.bytes(8).bitcast[Void]()
    bufs[0] = null_void()
    var a = dst.bitcast[CArrowArray]()
    a[].length = Int64(batch.length)
    a[].null_count = 0
    a[].offset = 0
    a[].n_buffers = 1
    a[].n_children = Int64(k)
    a[].buffers = bufs.bitcast[NoneType]()
    a[].children = children.bitcast[NoneType]()
    a[].dictionary = null_void()
    a[].release = release_word(_release_array)
    a[].private_data = _new_rec(arena, hd, True, k, children.bitcast[NoneType]())
    _hd(hd)[].exported += 1


def _set_cpu(dst: Void):
    var d = dst.bitcast[CArrowDeviceArray]()
    d[].device_id = -1
    d[].device_type = ARROW_DEVICE_CPU
    d[].sync_event = null_void()


def device_struct(mut arena: _Arena, batch: Batch, hd: Word) -> Word:
    """A host-owned ArrowDeviceArray holding `batch` as a struct array."""
    var d = arena.bytes(size_of[CArrowDeviceArray]())
    _fill_struct(arena, d, batch, hd.p)
    _set_cpu(d)
    return Word(d)


def device_column(mut arena: _Arena, col: Column, hd: Word) -> Word:
    """A host-owned ArrowDeviceArray holding `col` (group ids, states)."""
    var d = arena.bytes(size_of[CArrowDeviceArray]())
    _fill_column(arena, d, col, hd.p, True)
    _set_cpu(d)
    return Word(d)


def field_name(names: List[String], i: Int) -> String:
    """Field `i`'s name: `names[i]`, or `c<i>` past the end of `names`."""
    return names[i] if i < len(names) else "c" + String(i)


def schema_of(mut arena: _Arena, fields: List[ColumnType], names: List[String], as_struct: Bool, hd: Word) -> Word:
    """A borrowed ArrowSchema: a struct of `fields` named by field_name, or
    with `as_struct` False the single field itself."""
    if not as_struct:
        return Word(_schema_leaf(arena, fields[0], field_name(names, 0), hd.p))
    var k = len(fields)
    var children = arena.bytes(8 * k if k > 0 else 8).bitcast[Void]()
    for i in range(k):
        children[i] = _schema_leaf(arena, fields[i], field_name(names, i), hd.p)
    var s = arena.bytes(size_of[CArrowSchema]()).bitcast[CArrowSchema]()
    s[].format = arena.cstr("+s")
    s[].name = arena.cstr("")
    s[].metadata = null_void()
    s[].flags = 0
    s[].n_children = Int64(k)
    s[].children = children.bitcast[NoneType]()
    s[].dictionary = null_void()
    s[].release = release_word(_release_schema)
    s[].private_data = hd.p
    return Word(s.bitcast[NoneType]())


def _schema_leaf(mut arena: _Arena, f: ColumnType, name: String, hd: Void) -> Void:
    var s = arena.bytes(size_of[CArrowSchema]()).bitcast[CArrowSchema]()
    s[].format = arena.cstr(type_format(f.type_id))
    s[].name = arena.cstr(name)
    s[].metadata = null_void()
    s[].flags = ARROW_FLAG_NULLABLE if f.nullable else 0
    s[].n_children = 0
    s[].children = null_void()
    s[].dictionary = null_void()
    s[].release = release_word(_release_schema)
    s[].private_data = hd
    return s.bitcast[NoneType]()


# --- the frame input stream -----------------------------------------------------


def _stream_rec(s: Void) -> UnsafePointer[_StreamRec, MutUntrackedOrigin]:
    # SAFETY: `s` is a stream device_stream filled; its private_data is the
    # arena's _StreamRec.
    return s.bitcast[CArrowDeviceArrayStream]()[].private_data.bitcast[_StreamRec]()


def _stream_get_schema(s: Void, out_p: Void) abi("C") -> Int32:
    # Schemas are bound at load and never sent per call (design section 4.4).
    return 95  # ENOTSUP


def _stream_get_next(s: Void, out_p: Void) abi("C") -> Int32:
    var r = _stream_rec(s)
    r[].pulls += 1
    var d = out_p.bitcast[CArrowDeviceArray]()
    _set_cpu(out_p)
    if r[].next >= r[].n:
        d[].array.release = null_void()
        return 0
    # Move the prepared root into `out`: copy its ten words, NULL the source.
    var src = r[].batches.bitcast[Int64]() + r[].next * 10
    var dst = out_p.bitcast[Int64]()
    for w in range(10):
        dst[w] = src[w]
    src.bitcast[CArrowArray]()[].release = null_void()
    r[].next += 1
    return 0


def _stream_last_error(s: Void) abi("C") -> Void:
    return null_void()


def _release_stream(s: Void) abi("C"):
    var st = s.bitcast[CArrowDeviceArrayStream]()
    var r = _stream_rec(s)
    _hd(r[].hd)[].streams_released += 1
    # Batches the runtime never pulled are still the host's: release them.
    while r[].next < r[].n:
        var a = (r[].batches.bitcast[Int64]() + r[].next * 10).bitcast[NoneType]()
        as_release(a.bitcast[CArrowArray]()[].release)(a)
        r[].next += 1
    st[].release = null_void()


def device_stream(mut arena: _Arena, batches: List[Batch], hd_w: Word) -> Word:
    """A host-owned ArrowDeviceArrayStream handing out `batches` as struct
    arrays, then the end marker."""
    var hd = hd_w.p
    var n = len(batches)
    var roots = arena.bytes(size_of[CArrowArray]() * (n if n > 0 else 1))
    for i in range(n):
        _fill_struct(arena, (roots.bitcast[Int64]() + i * 10).bitcast[NoneType](), batches[i], hd)
    var rec = arena.bytes(size_of[_StreamRec]()).bitcast[_StreamRec]()
    rec[].hd = hd
    rec[].n = n
    rec[].next = 0
    rec[].pulls = 0
    rec[].batches = roots
    var s = arena.bytes(size_of[CArrowDeviceArrayStream]()).bitcast[CArrowDeviceArrayStream]()
    s[].device_type = ARROW_DEVICE_CPU
    s[].get_schema = get_schema_word(_stream_get_schema)
    s[].get_next = get_next_word(_stream_get_next)
    s[].get_last_error = last_error_word(_stream_last_error)
    s[].release = release_word(_release_stream)
    s[].private_data = rec.bitcast[NoneType]()
    _hd(hd)[].streams_exported += 1
    return Word(s.bitcast[NoneType]())


def stream_record(s: Word) -> Word:
    """The record of stream `s`, read before the stream is moved away."""
    return Word(s.p.bitcast[CArrowDeviceArrayStream]()[].private_data)


def stream_moved(s: Word) -> Bool:
    """Whether the runtime moved stream `s` out (its release slot is NULL)."""
    return is_null(s.p.bitcast[CArrowDeviceArrayStream]()[].release)


def release_stream(s: Word):
    """Release stream `s` through its own callback, if it is still set (a
    stream frame_open did not move is still the host's)."""
    var st = s.p.bitcast[CArrowDeviceArrayStream]()
    if not is_null(st[].release):
        as_release(st[].release)(s.p)


def pulls_of(rec: Word) -> Int:
    """get_next calls so far on the stream of `rec` (from stream_record)."""
    return rec.p.bitcast[_StreamRec]()[].pulls


def array_released(d: Word) -> Bool:
    """Whether the array of host device struct `d` has been moved out or
    released (its release slot is NULL)."""
    return is_null(d.p.bitcast[CArrowDeviceArray]()[].array.release)


# --- import ---------------------------------------------------------------------
#
# SAFETY: `d` is a host-allocated ArrowDeviceArray a runtime filled and
# returned OK on; every read below is inside a struct or buffer whose
# presence and count were checked first. C Data carries no buffer sizes, so
# a buffer shorter than offset + length is not detectable here.


def _fault(what: String) -> Error:
    return Error("UDF_RUNTIME_FAULT: " + what)


def check_device(d: Void) raises:
    var p = d.bitcast[CArrowDeviceArray]()
    if p[].device_type != ARROW_DEVICE_CPU or p[].device_id != -1 or not is_null(p[].sync_event):
        raise _fault(
            "device " + String(p[].device_type) + "/" + String(p[].device_id) + " is not the CPU"
        )


def _import_leaf(arr: Void, want: ColumnType, what: String) raises -> Column:
    var a = arr.bitcast[CArrowArray]()
    if is_null(a[].release):
        raise _fault(what + " is released")
    if a[].n_buffers != 2 or a[].n_children != 0 or not is_null(a[].dictionary):
        raise _fault(
            what + " layout: n_buffers " + String(a[].n_buffers) + ", n_children "
            + String(a[].n_children) + " for " + type_format(want.type_id)
        )
    var n = Int(a[].length)
    var off = Int(a[].offset)
    var nc = Int(a[].null_count)
    if n < 0 or off < 0 or nc < -1:
        raise _fault(what + ": length " + String(n) + ", offset " + String(off) + ", null_count " + String(nc))
    if is_null(a[].buffers):
        raise _fault(what + ": buffers is NULL")
    var bufs = a[].buffers.bitcast[Void]()
    var validity = bufs[0]
    var data = bufs[1]
    if n > 0 and is_null(data):
        raise _fault(what + ": data buffer is NULL")
    var col = Column(want.type_id)
    var w = type_width(want.type_id)
    for i in range(n):
        var at = off + i
        if not is_null(validity) and (validity.bitcast[UInt8]()[at >> 3] >> UInt8(at & 7)) & 1 == 0:
            col.append_null()
        elif w == 4:
            col.append_int(Int64((data.bitcast[Int32]() + at)[]))
        else:
            col.bits.append((data.bitcast[Int64]() + at)[])
            col.valid.append(True)
    # Also refuses a null_count above the length, and one above 0 with no
    # validity buffer: the bitmap counts at most `n` nulls, and none without one.
    if nc >= 0 and col.null_count() != nc:
        raise _fault(what + ": null_count " + String(nc) + ", validity says " + String(col.null_count()))
    return col^


def import_column(d: Word, want: ColumnType) raises -> Column:
    """Validate and copy the column a runtime returned in device struct `d`."""
    check_device(d.p)
    return _import_leaf(d.p, want, "result")


def import_struct(d: Word, want: List[ColumnType]) raises -> Batch:
    """Validate and copy the struct batch a runtime returned in `d` (run_frame
    checked it is not released: that is the end of a frame). The struct may
    sit at an offset into its children (Arrow: struct row i is child row
    offset + i, each child longer by at least that much); a table has no null
    rows."""
    check_device(d.p)
    var a = d.p.bitcast[CArrowArray]()
    if a[].n_buffers != 1 or Int(a[].n_children) != len(want):
        raise _fault(
            "struct layout: n_buffers " + String(a[].n_buffers) + ", n_children "
            + String(a[].n_children) + " (want " + String(len(want)) + ")"
        )
    var n = Int(a[].length)
    var off = Int(a[].offset)
    if n < 0 or off < 0:
        raise _fault("struct: length " + String(n) + ", offset " + String(off))
    if is_null(a[].buffers):
        raise _fault("struct: buffers is NULL")
    var validity = a[].buffers.bitcast[Void]()[0]
    var nulls = 0
    if not is_null(validity):
        for i in range(n):
            var at = off + i
            if (validity.bitcast[UInt8]()[at >> 3] >> UInt8(at & 7)) & 1 == 0:
                nulls += 1
    if a[].null_count >= 0 and Int(a[].null_count) != nulls:
        raise _fault("struct: null_count " + String(a[].null_count) + ", validity says " + String(nulls))
    if nulls > 0:
        raise _fault("struct result has " + String(nulls) + " null rows")
    var out = Batch(n)
    for i in range(len(want)):
        var c = (a[].children.bitcast[Void]() + i)[]
        if is_null(c):
            raise _fault("struct child " + String(i) + " is NULL")
        var col = _import_leaf(c, want[i], "child " + String(i))
        if len(col) < off + n:
            raise _fault(
                "child " + String(i) + " has " + String(len(col)) + " rows, the struct needs "
                + String(off + n)
            )
        var rows = Column(col.type_id)
        for r in range(off, off + n):
            rows.bits.append(col.bits[r])
            rows.valid.append(col.valid[r])
        out.columns.append(rows^)
    return out^


def release_out(d: Word) -> Bool:
    """Release the runtime array in `d` once through its own callback. False
    when the callback left its slot set (a broken release)."""
    var a = d.p.bitcast[CArrowArray]()
    if is_null(a[].release):
        return True
    as_release(a[].release)(d.p)
    return is_null(a[].release)


# --- errors -------------------------------------------------------------------


@fieldwise_init
struct ErrorText(Copyable, Movable):
    var code: Int32
    var message: String
    var trace: String
    var row: Int64
    var group: Int64


def new_error(mut arena: _Arena) -> Word:
    """A komira_udf_error for one call: code OK, row and group -1."""
    var e = arena.bytes(size_of[CUdfError]()).bitcast[CUdfError]()
    e[].struct_size = size_of[CUdfError]()
    e[].code = OK
    e[].message = null_void()
    e[].user_trace = null_void()
    e[].row = -1
    e[].group = -1
    e[].release = null_void()
    e[].private_data = null_void()
    return Word(e.bitcast[NoneType]())


def take_error(e: Word) -> ErrorText:
    """Copy the error's fields and strings, then call its release once."""
    var p = e.p.bitcast[CUdfError]()
    var out = ErrorText(p[].code, read_cstr(p[].message), read_cstr(p[].user_trace), p[].row, p[].group)
    if not is_null(p[].release):
        as_release(p[].release)(e.p)
    return out^
