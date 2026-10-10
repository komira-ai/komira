# =============================================================================
# FFI-BOUNDARY: Arrow C Data arrays and errors, as a native UDF library sees
# them (docs/design/udf_runtime_interface.md section 4.4).
# =============================================================================
# Reading the rows of an array the host moved in, and building arrays the
# host takes over, with release callbacks of this library.
#
# Who owns and frees each pointer:
#   - an input array: the host's until moved; then this library's copy, which
#     it releases once through the array's own `release`.
#   - an output column: one `zeroed` block holding its two-entry buffer list,
#     its validity bitmap and its values; `_release_col` frees the block.
#   - an output struct: one block holding its buffer list (NULL validity
#     unless a fixture points it at the block's own 8-byte bitmap, after the
#     child pointers) and its child pointers, and one 80-byte block per
#     child; `_release_struct` releases each child still set, frees the
#     child blocks, then its own.
#   - an error's strings: `zeroed` blocks of this library, freed by
#     `_free_error`, which the host calls once.
# Every pointer here is untracked (the _cabi mirror's `Void`): its memory is
# the host's or a block of this library that outlives any Mojo scope.
# =============================================================================

from std.sys import size_of

from komira_udf_spike_abi._cabi import (
    CArrowArray,
    CArrowDeviceArray,
    CArrowSchema,
    CUdfError,
    Void,
    as_release,
    free_zeroed,
    is_null,
    null_void,
    read_cstr,
    release_word,
    zeroed,
)
from komira_udf_spike_abi.contract import ARROW_DEVICE_CPU, ERR_RAISED


def arr(p: Void) -> UnsafePointer[CArrowArray, MutUntrackedOrigin]:
    # SAFETY: `p` is a live struct ArrowArray (a device array starts with one).
    return p.bitcast[CArrowArray]()


def word_at(p: Void, i: Int) -> Void:
    """The i-th pointer of the pointer array at `p`."""
    # SAFETY: `p` holds at least i + 1 pointers (an array's buffers or
    # children, read below their count).
    return p.bitcast[Void]()[i]


def child(a: Void, i: Int) -> Void:
    return word_at(arr(a)[].children, i)


def n_children(a: Void) -> Int:
    return Int(arr(a)[].n_children)


def length(a: Void) -> Int:
    return Int(arr(a)[].length)


def is_valid(a: Void, r: Int) -> Bool:
    """Row r is not null: no validity buffer, or its bit set (offset read)."""
    var v = word_at(arr(a)[].buffers, 0)
    if is_null(v):
        return True
    var at = Int(arr(a)[].offset) + r
    # SAFETY: the bitmap covers offset + length bits (the host validated it).
    return (v.bitcast[UInt8]()[at >> 3] >> UInt8(at & 7)) & 1 == 1


def i64_at(a: Void, r: Int) -> Int64:
    # SAFETY: an int64 array: buffer 1 holds offset + length values.
    return word_at(arr(a)[].buffers, 1).bitcast[Int64]()[Int(arr(a)[].offset) + r]


def f64_at(a: Void, r: Int) -> Float64:
    # SAFETY: a float64 array: buffer 1 holds offset + length values.
    return word_at(arr(a)[].buffers, 1).bitcast[Float64]()[Int(arr(a)[].offset) + r]


def i32_at(a: Void, r: Int) -> Int32:
    # SAFETY: an int32 array: buffer 1 holds offset + length values.
    return word_at(arr(a)[].buffers, 1).bitcast[Int32]()[Int(arr(a)[].offset) + r]


def release_array(a: Void):
    """Release `a` through its own callback, if it is still set."""
    var f = arr(a)[].release
    if not is_null(f):
        as_release(f)(a)


def move_array(dst: Void, src: Void):
    """Move a device array: copy its 16 words to `dst`, NULL `src`'s release."""
    # SAFETY: both are 128-byte struct ArrowDeviceArray blocks.
    var s = src.bitcast[Int64]()
    var d = dst.bitcast[Int64]()
    for w in range(16):
        d[w] = s[w]
    arr(src)[].release = null_void()


def set_cpu(d: Void):
    """Mark device array `d` as CPU memory (device -1, no sync event)."""
    # SAFETY: `d` is a struct ArrowDeviceArray.
    var p = d.bitcast[CArrowDeviceArray]()
    p[].device_id = -1
    p[].device_type = ARROW_DEVICE_CPU
    p[].sync_event = null_void()
    for i in range(3):
        p[].reserved[i] = 0


# --- building outputs ------------------------------------------------------------


def _release_col(a: Void) abi("C"):
    free_zeroed(arr(a)[].private_data)
    arr(a)[].release = null_void()


def _vbytes(n: Int) -> Int:
    return (n + 7) // 8


def make_col(a: Void, n: Int) -> Void:
    """Make `a` an array of `n` 8-byte values, every row valid; the values,
    which the caller writes (int64 or float64 bits)."""
    var vb = _vbytes(n)
    var block = zeroed(16 + vb + 8 * n + 8)
    # SAFETY: the block holds the two buffer pointers, then the bitmap, then
    # n values at the next 8-byte boundary; every byte is inside it.
    var bufs = block.bitcast[Void]()
    var validity = (block.bitcast[UInt8]() + 16).bitcast[NoneType]()
    for i in range(vb):
        validity.bitcast[UInt8]()[i] = 0xFF
    var data = (block.bitcast[Int64]() + (16 + vb + 7) // 8).bitcast[NoneType]()
    bufs[0] = validity
    bufs[1] = data
    var p = arr(a)
    p[].length = Int64(n)
    p[].null_count = 0
    p[].offset = 0
    p[].n_buffers = 2
    p[].n_children = 0
    p[].buffers = block
    p[].children = null_void()
    p[].dictionary = null_void()
    p[].release = release_word(_release_col)
    p[].private_data = block
    return data


def set_null(a: Void, r: Int):
    """Clear row r's validity bit in a column of make_col."""
    var v = word_at(arr(a)[].buffers, 0).bitcast[UInt8]()
    # SAFETY: r < length, inside make_col's bitmap.
    v[r >> 3] = v[r >> 3] & ~(UInt8(1) << UInt8(r & 7))
    arr(a)[].null_count += 1


comptime PAD_VALUE: Int64 = 0x5EAD5EAD
"""The rows before a sliced output's offset."""


def slice_col(a: Void, at: Int):
    """Rebuild column `a` (int64, from make_col) at offset `at`: the `at` rows
    before it hold PAD_VALUE with null bits, so a reader that ignores the
    offset reads nulls and padding. Legal Arrow (C Data `offset`)."""
    var n = length(a)
    var s = zeroed(size_of[CArrowArray]())
    var d = make_col(s, at + n)
    for r in range(at + n):
        var pad = r < at
        # SAFETY: make_col's values block of at + n rows.
        d.bitcast[Int64]()[r] = PAD_VALUE if pad else i64_at(a, r - at)
        if pad or not is_valid(a, r - at):
            set_null(s, r)
    arr(s)[].null_count -= Int64(at)  # the pad rows are not the column's rows
    arr(s)[].offset = Int64(at)
    arr(s)[].length = Int64(n)
    release_array(a)
    # SAFETY: both are struct ArrowArray (80 bytes, 10 words); `a`'s is
    # released, `s`'s block moves to it, and the empty `s` is freed.
    for w in range(10):
        a.bitcast[Int64]()[w] = s.bitcast[Int64]()[w]
    free_zeroed(s)


def _release_struct(a: Void) abi("C"):
    var p = arr(a)
    for i in range(Int(p[].n_children)):
        var c = word_at(p[].children, i)
        release_array(c)
        free_zeroed(c)
    free_zeroed(p[].private_data)
    p[].release = null_void()


def make_struct(a: Void, n: Int, k: Int):
    """Make `a` a struct array of `n` rows with `k` children for the caller
    to fill (each an empty 80-byte array struct)."""
    var block = zeroed(8 + 8 * k + 8)
    # SAFETY: the block is the one-entry buffer list (NULL: no validity), k
    # child pointers after it, then 8 bytes for struct_validity.
    var kids = (block.bitcast[Void]() + 1)
    for i in range(k):
        kids[i] = zeroed(size_of[CArrowArray]())
    var p = arr(a)
    p[].length = Int64(n)
    p[].null_count = 0
    p[].offset = 0
    p[].n_buffers = 1
    p[].n_children = Int64(k)
    p[].buffers = block
    p[].children = kids.bitcast[NoneType]() if k > 0 else null_void()
    p[].dictionary = null_void()
    p[].release = release_word(_release_struct)
    p[].private_data = block


def struct_validity(a: Void) -> Void:
    """The 8-byte bitmap of struct `a` (from make_struct): rows 0 to 63, all
    valid, made its validity buffer."""
    var p = arr(a)
    # SAFETY: make_struct's block: 8 bytes of buffer list, n_children child
    # pointers, then the 8 bitmap bytes.
    var v = (p[].private_data.bitcast[UInt8]() + 8 + 8 * Int(p[].n_children)).bitcast[NoneType]()
    for i in range(8):
        v.bitcast[UInt8]()[i] = 0xFF
    p[].buffers.bitcast[Void]()[0] = v
    return v


# --- schemas -------------------------------------------------------------------------


def schema_format(s: Void) -> String:
    if is_null(s):
        return ""
    # SAFETY: `s` is a struct ArrowSchema the host lent for the call.
    return read_cstr(s.bitcast[CArrowSchema]()[].format)


def schema_name(s: Void) -> String:
    return read_cstr(s.bitcast[CArrowSchema]()[].name)


def schema_children(s: Void) -> Int:
    return Int(s.bitcast[CArrowSchema]()[].n_children)


def schema_child(s: Void, i: Int) -> Void:
    return word_at(s.bitcast[CArrowSchema]()[].children, i)


# --- errors -----------------------------------------------------------------------------


def _cstr(s: String) -> Void:
    var b = s.as_bytes()
    var p = zeroed(len(b) + 1)
    # SAFETY: len + 1 zeroed bytes; len written, the NUL stays.
    for i in range(len(b)):
        p.bitcast[UInt8]()[i] = b[i]
    return p


def _free_error(e: Void) abi("C"):
    var p = e.bitcast[CUdfError]()
    if not is_null(p[].message):
        free_zeroed(p[].message)
    if not is_null(p[].user_trace):
        free_zeroed(p[].user_trace)
    p[].message = null_void()
    p[].user_trace = null_void()
    p[].release = null_void()


def fail(e: Void, code: Int32, msg: String, row: Int = -1) -> Int32:
    """Fill the host's error `e` (when its struct_size covers ours) and
    return `code`. A raised error gets a trace naming this library."""
    if is_null(e):
        return code
    var p = e.bitcast[CUdfError]()
    if p[].struct_size < size_of[CUdfError]():
        return code
    p[].code = code
    p[].message = _cstr(msg)
    p[].user_trace = _cstr("native_mojo: the fixture raised: " + msg) if code == ERR_RAISED else null_void()
    p[].row = Int64(row)
    p[].group = -1
    p[].release = release_word(_free_error)
    return code
