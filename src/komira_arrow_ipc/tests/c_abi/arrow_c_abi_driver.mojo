# =============================================================================
# FFI-BOUNDARY: a C consumer and a C producer of the Arrow C Stream Interface,
# across a dlopen of arrow_c_abi_probe.
# =============================================================================
# This driver is the gate of //src/komira_arrow_ipc:arrow_c_abi_probe. It has
# no dependency: it shares no type with komira_arrow_ipc. It reads and writes
# ArrowSchema, ArrowArray and ArrowArrayStream as arrays of pointer-sized
# slots at the offsets of the C struct definitions in the Arrow C Data
# Interface ("Structure definitions") and C Stream Interface ("Structure
# definition") on LP64, and it calls every callback through a C function
# pointer (`abi("C")`). So it observes exactly what a C consumer such as
# pyarrow or arrow-rs observes.
#
# Who owns what: every struct, buffer and C string the driver produces is
# allocated from its `_Arena` and freed by `free_all` at the end of each
# direction; its release callbacks free nothing, they count. The library owns
# the structs it exports until the driver calls their release callbacks.
#
# Export direction (the library produces, the driver consumes):
#   1. `probe_export_stream` fills a stream; `get_schema`, then `get_next`
#      until the end-of-stream marker (an array whose release is NULL, C
#      Stream Interface "Semantics"), holding every chunk.
#   2. The driver releases the schema and then the STREAM, before it reads any
#      chunk. C Stream Interface "Result lifetimes": the data returned by
#      get_schema and get_next must be released independently, so a chunk
#      stays valid after its stream is released.
#   3. Every buffer of every array of every chunk is compared with the values
#      written out below by hand (lengths, null counts, n_buffers, validity
#      bits, offsets, bytes), and the schema with its format strings, names
#      and flags (C Data Interface "Data type description -- format strings",
#      ARROW_FLAG_NULLABLE = 2).
#   4. Each chunk is released through its own callback, which must set its
#      release member to NULL (C Data Interface "Released structure").
#   5. get_last_error, called after the drain, returns NULL: no call failed.
#      (arrow_c_abi_error_driver.mojo drives the error paths.)
#
# Import direction (the driver produces, the library consumes):
#   The driver builds a stream of two chunks with its own private_data and
#   release callbacks, one record per struct (stream, root schema, each child
#   schema, the dictionary schema, each chunk's root array, each child array,
#   each dictionary array). `probe_import_stream` drains it. Afterwards:
#   - every struct's release ran exactly once;
#   - no child or dictionary was released by the consumer in place. C Data
#     Interface "Release callback semantics -- for consumers": consumers MUST
#     NOT call a child's release callback, including the dictionary's. The
#     call count alone cannot see this: a parent's release skips a child whose
#     release is already NULL, so a direct child release followed by the root
#     release still counts 1 per struct. So each parent marks a child just
#     before it calls the child's release, and a release that runs at the
#     address the driver built the struct at without that mark is counted as
#     a direct release. A child the consumer moved ("Moving child arrays")
#     and then released runs at the consumer's address and is not counted.
#   The checksum the library returns must equal the one computed here from
#   the source values (the function is described in arrow_c_abi_probe.mojo).
# =============================================================================

from std.ffi import OwnedDLHandle
from std.memory import alloc, bitcast
from std.sys import CompilationTarget

comptime LIB = "./arrow_c_abi_probe.dylib" if CompilationTarget.is_macos() else "./arrow_c_abi_probe.so"

comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]
"""`void *`."""
comptime Words = UnsafePointer[Void, MutUntrackedOrigin]
"""A C struct viewed as an array of pointer-sized slots."""
comptime Bytes = UnsafePointer[UInt8, MutUntrackedOrigin]

comptime ReleaseFn = def (Words) abi("C") thin -> None
comptime GetSchemaFn = def (Words, Words) abi("C") thin -> Int32
comptime GetNextFn = def (Words, Words) abi("C") thin -> Int32
comptime LastErrorFn = def (Words) abi("C") thin -> Bytes

# struct ArrowSchema, 9 slots.
comptime S_WORDS = 9
comptime S_FORMAT = 0
comptime S_NAME = 1
comptime S_METADATA = 2
comptime S_FLAGS = 3
comptime S_N_CHILDREN = 4
comptime S_CHILDREN = 5
comptime S_DICTIONARY = 6
comptime S_RELEASE = 7
comptime S_PRIVATE = 8

# struct ArrowArray, 10 slots.
comptime A_WORDS = 10
comptime A_LENGTH = 0
comptime A_NULL_COUNT = 1
comptime A_OFFSET = 2
comptime A_N_BUFFERS = 3
comptime A_N_CHILDREN = 4
comptime A_BUFFERS = 5
comptime A_CHILDREN = 6
comptime A_DICTIONARY = 7
comptime A_RELEASE = 8
comptime A_PRIVATE = 9

# struct ArrowArrayStream, 5 slots.
comptime ST_WORDS = 5
comptime ST_GET_SCHEMA = 0
comptime ST_GET_NEXT = 1
comptime ST_GET_LAST_ERROR = 2
comptime ST_RELEASE = 3
comptime ST_PRIVATE = 4

comptime ARROW_FLAG_NULLABLE: Int64 = 2
comptime EINVAL: Int32 = 22


# --- slots --------------------------------------------------------------------
#
# SAFETY: every `Words` below is a live block of at least the slot count of
# the struct it holds: the driver's own (`_Arena`) or one the library handed
# over and has not been released. Reads and writes stay inside the block.


def _null() -> Void:
    """The NULL `void *`.

    # SAFETY: `Optional[UnsafePointer]` has the pointer's layout and `None` is
    # its all-zero pattern; the result is compared or stored, never read.
    """
    var none: Optional[Void] = None
    return UnsafePointer(to=none).bitcast[Void]()[]


def _is_null(p: Void) -> Bool:
    return Int(p) == 0


def _ptr(s: Words, i: Int) -> Void:
    return (s + i)[]


def _set_ptr(s: Words, i: Int, v: Void):
    (s + i)[] = v


def _i64(s: Words, i: Int) -> Int64:
    return (s.bitcast[Int64]() + i)[]


def _set_i64(s: Words, i: Int, v: Int64):
    (s.bitcast[Int64]() + i)[] = v


def _words_at(p: Void) -> Words:
    return p.bitcast[Void]()


def _slot_list(p: Void, i: Int) -> Words:
    """Element `i` of a `struct X **` array (children)."""
    return _words_at((p.bitcast[Void]() + i)[])


# --- function pointers in slots -------------------------------------------------
#
# SAFETY: a C function pointer and a `void *` are both one machine word on
# the platforms this runs on. The driver's own slots hold `abi("C")`
# functions, as the C struct definitions declare, and so do the library's
# get_schema, get_next and get_last_error slots. The library's release slots
# hold Mojo default-convention `thin` functions (c_data_stream.mojo, the
# comment above `_ArrayReleaseFn`); calling them through this C-typed pointer
# is the cross-seam measurement this gate makes on linux-x86_64, not a
# guarantee.


def _release_word(f: ReleaseFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def _schema_fn_word(f: GetSchemaFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def _next_fn_word(f: GetNextFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def _error_fn_word(f: LastErrorFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def _as_release(w: Void) -> ReleaseFn:
    var x = w
    return UnsafePointer(to=x).bitcast[ReleaseFn]()[]


def _as_get_schema(w: Void) -> GetSchemaFn:
    var x = w
    return UnsafePointer(to=x).bitcast[GetSchemaFn]()[]


def _as_get_next(w: Void) -> GetNextFn:
    var x = w
    return UnsafePointer(to=x).bitcast[GetNextFn]()[]


def _as_last_error(w: Void) -> LastErrorFn:
    var x = w
    return UnsafePointer(to=x).bitcast[LastErrorFn]()[]


# --- the arena: every block the driver allocates --------------------------------


struct _Arena(Movable):
    var blocks: List[Void]

    def __init__(out self):
        self.blocks = List[Void]()

    def bytes(mut self, n: Int) -> Void:
        """`n` zeroed bytes, 8-byte aligned (one byte when `n` is 0)."""
        var words = (n + 7) // 8 if n > 0 else 1
        var p = alloc[Int64](words).unsafe_origin_cast[MutUntrackedOrigin]()
        for k in range(words):
            (p + k).unsafe_write(Int64(0))
        var v = p.bitcast[NoneType]()
        self.blocks.append(v)
        return v

    def words(mut self, n: Int) -> Words:
        return _words_at(self.bytes(8 * n))

    def cstr(mut self, s: String) -> Void:
        var b = s.as_bytes()
        var p = self.bytes(len(b) + 1)
        var d = p.bitcast[UInt8]()
        for k in range(len(b)):
            d[k] = b[k]
        return p

    def free_all(mut self):
        for k in range(len(self.blocks)):
            self.blocks[k].bitcast[Int64]().free()
        self.blocks = List[Void]()


def _read_cstr(p: Void) -> String:
    var b = p.bitcast[UInt8]()
    var out = String("")
    var k = 0
    while b[k] != 0:
        out += chr(Int(b[k]))
        k += 1
    return out


# --- checks -------------------------------------------------------------------


def _fail(msg: String) raises:
    raise Error("arrow_c_abi_driver: " + msg)


def _eq(what: String, got: Int64, want: Int64) raises:
    if got != want:
        _fail(what + " is " + String(got) + ", expected " + String(want))


def _call_release(s: Words, slot: Int, what: String) raises:
    """Call the struct's own release callback once; it must NULL `release`."""
    var r = _ptr(s, slot)
    if _is_null(r):
        _fail(what + " is already released")
    _as_release(r)(s)
    if not _is_null(_ptr(s, slot)):
        _fail(what + ": its release callback left release non-NULL")


def _buffer(a: Words, i: Int, what: String) raises -> Void:
    var bufs = _ptr(a, A_BUFFERS)
    if _is_null(bufs):
        _fail(what + ": buffers is NULL")
    var p = (bufs.bitcast[Void]() + i)[]
    if _is_null(p):
        _fail(what + ": buffers[" + String(i) + "] is NULL")
    return p


def _child(a: Words, n_slot: Int, children_slot: Int, i: Int, what: String) raises -> Words:
    if _i64(a, n_slot) <= Int64(i):
        _fail(what + " has no child " + String(i))
    if _is_null(_ptr(a, children_slot)):
        _fail(what + ": children is NULL")
    var c = _slot_list(_ptr(a, children_slot), i)
    if _is_null(c.bitcast[NoneType]()):
        _fail(what + ": children[" + String(i) + "] is NULL")
    return c


def _check_array(a: Words, what: String, length: Int, null_count: Int, n_buffers: Int, has_dict: Bool) raises:
    if _is_null(_ptr(a, A_RELEASE)):
        _fail(what + " is released (release is NULL)")
    _eq(what + ".length", _i64(a, A_LENGTH), Int64(length))
    _eq(what + ".null_count", _i64(a, A_NULL_COUNT), Int64(null_count))
    _eq(what + ".offset", _i64(a, A_OFFSET), 0)
    _eq(what + ".n_buffers", _i64(a, A_N_BUFFERS), Int64(n_buffers))
    _eq(what + ".n_children", _i64(a, A_N_CHILDREN), 0)
    # C Data Interface, ArrowArray.dictionary: MUST be present for a
    # dictionary-encoded array, MUST be NULL otherwise.
    if has_dict and _is_null(_ptr(a, A_DICTIONARY)):
        _fail(what + ".dictionary is NULL for a dictionary-encoded array")
    if not has_dict and not _is_null(_ptr(a, A_DICTIONARY)):
        _fail(what + ".dictionary is not NULL")


def _check_validity(a: Words, what: String, valid: List[Bool], null_count: Int) raises:
    """C Data Interface, ArrowArray.buffers: the validity buffer MAY be NULL
    only when null_count is 0. Bits are LSB-first (Columnar format, "Validity
    bitmaps")."""
    if null_count == 0:
        return
    var bufs = _ptr(a, A_BUFFERS)
    if _is_null(bufs) or _is_null((bufs.bitcast[Void]() + 0)[]):
        _fail(what + ": buffers[0] (validity) is NULL with null_count " + String(null_count))
    var bm = (bufs.bitcast[Void]() + 0)[].bitcast[UInt8]()
    for r in range(len(valid)):
        var bit = ((bm[r >> 3] >> UInt8(r & 7)) & UInt8(1)) == UInt8(1)
        if bit != valid[r]:
            _fail(what + " validity bit " + String(r) + " is " + String(bit) + ", expected " + String(valid[r]))


def _check_bytes(a: Words, i: Int, what: String, want: String) raises:
    var w = want.as_bytes()
    if len(w) == 0:
        return  # a zero-size buffer MAY be NULL
    var p = _buffer(a, i, what).bitcast[UInt8]()
    for k in range(len(w)):
        _eq(what + " byte " + String(k), Int64(p[k]), Int64(w[k]))


def _check_i32s(a: Words, i: Int, what: String, want: List[Int32]) raises:
    var p = _buffer(a, i, what).bitcast[Int32]()
    for k in range(len(want)):
        _eq(what + "[" + String(k) + "]", Int64(p[k]), Int64(want[k]))


def _check_i64s(a: Words, i: Int, what: String, want: List[Int64]) raises:
    var p = _buffer(a, i, what).bitcast[Int64]()
    for k in range(len(want)):
        _eq(what + "[" + String(k) + "]", p[k], want[k])


# --- the export oracle, written out by hand ---------------------------------------


@fieldwise_init
struct _Chunk(Movable):
    """One exported chunk as the probe builds it, with every buffer spelled
    out: offsets and validity are written here, not computed."""

    var rows: Int
    var i64: List[Int64]
    var f64: List[Float64]
    var s_valid: List[Bool]
    var s_nulls: Int
    var s_offsets: List[Int32]
    var s_data: String
    var ls_offsets: List[Int64]
    var ls_data: String
    var d_idx: List[Int32]
    var dict_offsets: List[Int32]
    var dict_data: String
    var m_words: List[Int64]
    """Each decimal128 as two little-endian 64-bit words, low then high."""


def _chunk0() -> _Chunk:
    return _Chunk(
        rows=4,
        i64=[Int64(11), Int64(-22), Int64(33), Int64(44)],
        f64=[Float64(1.5), Float64(-2.25), Float64(3.125), Float64(4096.5)],
        s_valid=[True, False, True, True],
        s_nulls=1,
        s_offsets=[Int32(0), Int32(5), Int32(5), Int32(5), Int32(10)],
        s_data=String("alphadelta"),
        ls_offsets=[Int64(0), Int64(3), Int64(6), Int64(11), Int64(15)],
        ls_data=String("onetwothreefour"),
        d_idx=[Int32(2), Int32(0), Int32(1), Int32(2)],
        dict_offsets=[Int32(0), Int32(3), Int32(7), Int32(11)],
        dict_data=String("AIRRAILSHIP"),
        m_words=[Int64(12345), Int64(0), Int64(-1), Int64(-1), Int64(0), Int64(0), Int64(99999), Int64(0)],
    )


def _chunk1() -> _Chunk:
    return _Chunk(
        rows=3,
        i64=[Int64(55), Int64(66), Int64(-77)],
        f64=[Float64(0.5), Float64(8.0), Float64(-16.75)],
        s_valid=[False, True, True],
        s_nulls=1,
        s_offsets=[Int32(0), Int32(0), Int32(4), Int32(7)],
        s_data=String("zetaeta"),
        ls_offsets=[Int64(0), Int64(1), Int64(1), Int64(3)],
        ls_data=String("xyz"),
        d_idx=[Int32(1), Int32(1), Int32(0)],
        dict_offsets=[Int32(0), Int32(1), Int32(2)],
        dict_data=String("PQ"),
        # 100; -100; 2**70 + 7 (high word 64, low word 7).
        m_words=[Int64(100), Int64(0), Int64(-100), Int64(-1), Int64(7), Int64(64)],
    )


def _check_chunk(root: Words, ref want: _Chunk, what: String) raises:
    # The root is a struct array: one (validity) buffer, six children.
    if _is_null(_ptr(root, A_RELEASE)):
        _fail(what + " is released (release is NULL)")
    _eq(what + ".length", _i64(root, A_LENGTH), Int64(want.rows))
    _eq(what + ".null_count", _i64(root, A_NULL_COUNT), 0)
    _eq(what + ".n_buffers", _i64(root, A_N_BUFFERS), 1)
    _eq(what + ".n_children", _i64(root, A_N_CHILDREN), 6)
    var n = want.rows

    var i = _child(root, A_N_CHILDREN, A_CHILDREN, 0, what)
    _check_array(i, what + ".i", n, 0, 2, False)
    _check_i64s(i, 1, what + ".i", want.i64)

    var f = _child(root, A_N_CHILDREN, A_CHILDREN, 1, what)
    _check_array(f, what + ".f", n, 0, 2, False)
    var fp = _buffer(f, 1, what + ".f").bitcast[Float64]()
    for r in range(n):
        _eq(
            what + ".f[" + String(r) + "] bits",
            Int64(bitcast[DType.int64](fp[r])),
            Int64(bitcast[DType.int64](want.f64[r])),
        )

    var s = _child(root, A_N_CHILDREN, A_CHILDREN, 2, what)
    _check_array(s, what + ".s", n, want.s_nulls, 3, False)
    _check_validity(s, what + ".s", want.s_valid, want.s_nulls)
    _check_i32s(s, 1, what + ".s offsets", want.s_offsets)
    _check_bytes(s, 2, what + ".s data", want.s_data)

    var ls = _child(root, A_N_CHILDREN, A_CHILDREN, 3, what)
    _check_array(ls, what + ".ls", n, 0, 3, False)
    _check_i64s(ls, 1, what + ".ls offsets", want.ls_offsets)
    _check_bytes(ls, 2, what + ".ls data", want.ls_data)

    # Dictionary-encoded: the parent holds the index buffers (validity,
    # int32 indices); the values hang off `dictionary` (C Data Interface,
    # "Dictionary-encoded arrays").
    var d = _child(root, A_N_CHILDREN, A_CHILDREN, 4, what)
    _check_array(d, what + ".d", n, 0, 2, True)
    _check_i32s(d, 1, what + ".d indices", want.d_idx)
    var dv = _words_at(_ptr(d, A_DICTIONARY))
    _check_array(dv, what + ".d.dictionary", len(want.dict_offsets) - 1, 0, 3, False)
    _check_i32s(dv, 1, what + ".d.dictionary offsets", want.dict_offsets)
    _check_bytes(dv, 2, what + ".d.dictionary data", want.dict_data)

    # Decimal128: a fixed-width primitive, buffers (validity, 16-byte values).
    var m = _child(root, A_N_CHILDREN, A_CHILDREN, 5, what)
    _check_array(m, what + ".m", n, 0, 2, False)
    _check_i64s(m, 1, what + ".m words", want.m_words)


def _check_child_schema(root: Words, i: Int, fmt: String, name: String, flags: Int64, dict_fmt: String) raises:
    var what = "schema child " + String(i)
    var s = _child(root, S_N_CHILDREN, S_CHILDREN, i, "schema")
    if _is_null(_ptr(s, S_RELEASE)):
        _fail(what + " is released (release is NULL)")
    if _is_null(_ptr(s, S_FORMAT)):
        _fail(what + ": format is NULL")
    var got_fmt = _read_cstr(_ptr(s, S_FORMAT))
    if got_fmt != fmt:
        _fail(what + " format is '" + got_fmt + "', expected '" + fmt + "'")
    var got_name = _read_cstr(_ptr(s, S_NAME)) if not _is_null(_ptr(s, S_NAME)) else String("<NULL>")
    if got_name != name:
        _fail(what + " name is '" + got_name + "', expected '" + name + "'")
    _eq(what + " flags", _i64(s, S_FLAGS), flags)
    _eq(what + " n_children", _i64(s, S_N_CHILDREN), 0)
    var dict_p = _ptr(s, S_DICTIONARY)
    if dict_fmt == "":
        if not _is_null(dict_p):
            _fail(what + ".dictionary is not NULL")
        return
    if _is_null(dict_p):
        _fail(what + ".dictionary is NULL for a dictionary-encoded field")
    var got_dict = _read_cstr(_ptr(_words_at(dict_p), S_FORMAT))
    if got_dict != dict_fmt:
        _fail(what + ".dictionary format is '" + got_dict + "', expected '" + dict_fmt + "'")


def _check_schema(root: Words) raises:
    if _is_null(_ptr(root, S_RELEASE)):
        _fail("schema is released (release is NULL)")
    var fmt = _read_cstr(_ptr(root, S_FORMAT))
    if fmt != "+s":
        _fail("schema format is '" + fmt + "', expected '+s'")
    _eq("schema n_children", _i64(root, S_N_CHILDREN), 6)
    _check_child_schema(root, 0, "l", "i", 0, "")
    _check_child_schema(root, 1, "g", "f", 0, "")
    _check_child_schema(root, 2, "u", "s", ARROW_FLAG_NULLABLE, "")
    _check_child_schema(root, 3, "U", "ls", 0, "")
    _check_child_schema(root, 4, "i", "d", 0, "u")
    _check_child_schema(root, 5, "d:10,2", "m", 0, "")


def _export_direction(lib: OwnedDLHandle) raises:
    var arena = _Arena()
    var st = arena.words(ST_WORDS)
    _eq("probe_export_stream rc", Int64(lib.call["probe_export_stream", Int32](st)), 0)
    if _is_null(_ptr(st, ST_RELEASE)):
        _fail("exported stream is released (release is NULL)")
    if _is_null(_ptr(st, ST_GET_SCHEMA)) or _is_null(_ptr(st, ST_GET_NEXT)) or _is_null(_ptr(st, ST_GET_LAST_ERROR)):
        _fail("exported stream has a NULL callback")

    var sch = arena.words(S_WORDS)
    _eq("get_schema rc", Int64(_as_get_schema(_ptr(st, ST_GET_SCHEMA))(st, sch)), 0)
    _check_schema(sch)
    _call_release(sch, S_RELEASE, "exported schema")

    var chunks = List[Words]()
    while True:
        var a = arena.words(A_WORDS)
        _eq("get_next rc", Int64(_as_get_next(_ptr(st, ST_GET_NEXT))(st, a)), 0)
        if _is_null(_ptr(a, A_RELEASE)):
            break  # end of stream
        chunks.append(a)
        if len(chunks) > 2:
            _fail("the stream delivered more than 2 chunks")
    _eq("chunks delivered", Int64(len(chunks)), 2)
    if not _is_null(_as_last_error(_ptr(st, ST_GET_LAST_ERROR))(st).bitcast[NoneType]()):
        _fail("get_last_error after a clean drain is not NULL")

    # The stream goes first; every chunk must survive it.
    _call_release(st, ST_RELEASE, "exported stream")

    var want0 = _chunk0()
    var want1 = _chunk1()
    _check_chunk(chunks[0], want0, "chunk 0")
    _check_chunk(chunks[1], want1, "chunk 1")
    _call_release(chunks[0], A_RELEASE, "chunk 0")
    _call_release(chunks[1], A_RELEASE, "chunk 1")
    arena.free_all()
    print("export: 2 chunks read after the stream was released, every buffer as expected")


# --- the import direction: the driver's own producer -----------------------------

#
# The stream's private_data is a state block of _P_WORDS slots. Each schema
# and array the driver produces has its own record of _R_WORDS slots as
# private_data. Its release callback adds 1 to the call count, adds 1 to the
# direct count if it runs at the struct's home address without the parent's
# mark, releases its children and dictionary the first time only (marking
# each before the call), and sets its own release member to NULL. Nothing is
# freed by a release callback: the arena frees everything after the drain.

comptime _P_WORDS = 6
comptime _P_NEXT = 0
comptime _P_SCHEMA = 1
comptime _P_CHUNK0 = 2
comptime _P_STREAM_RELEASES = 4
comptime _P_SCHEMA_CALLS = 5

# A struct's record (its private_data).
comptime _R_WORDS = 4
comptime _R_CALLS = 0
comptime _R_DIRECT = 1
comptime _R_BY_PARENT = 2
comptime _R_HOME = 3


def _enter_release(s: Words, private_slot: Int) -> Bool:
    """Record one call of `s`'s release; True on the first call."""
    var r = _words_at(_ptr(s, private_slot))
    if Int(s) == Int(_ptr(r, _R_HOME)) and _i64(r, _R_BY_PARENT) == 0:
        _set_i64(r, _R_DIRECT, _i64(r, _R_DIRECT) + 1)
    _set_i64(r, _R_CALLS, _i64(r, _R_CALLS) + 1)
    return _i64(r, _R_CALLS) == 1


def _release_kid(kid: Words, release_slot: Int, private_slot: Int):
    """A parent's release of one child or dictionary: mark it, then call it.
    A NULL release means the consumer moved it out; it is skipped."""
    if not _is_null(_ptr(kid, release_slot)):
        _set_i64(_words_at(_ptr(kid, private_slot)), _R_BY_PARENT, 1)
        _as_release(_ptr(kid, release_slot))(kid)


def _drv_release_schema(s: Words) abi("C") -> None:
    if _enter_release(s, S_PRIVATE):
        for k in range(Int(_i64(s, S_N_CHILDREN))):
            _release_kid(_slot_list(_ptr(s, S_CHILDREN), k), S_RELEASE, S_PRIVATE)
        var d = _ptr(s, S_DICTIONARY)
        if not _is_null(d):
            _release_kid(_words_at(d), S_RELEASE, S_PRIVATE)
    _set_ptr(s, S_RELEASE, _null())


def _drv_release_array(a: Words) abi("C") -> None:
    if _enter_release(a, A_PRIVATE):
        for k in range(Int(_i64(a, A_N_CHILDREN))):
            _release_kid(_slot_list(_ptr(a, A_CHILDREN), k), A_RELEASE, A_PRIVATE)
        var d = _ptr(a, A_DICTIONARY)
        if not _is_null(d):
            _release_kid(_words_at(d), A_RELEASE, A_PRIVATE)
    _set_ptr(a, A_RELEASE, _null())


def _drv_release_stream(st: Words) abi("C") -> None:
    var state = _words_at(_ptr(st, ST_PRIVATE))
    _set_i64(state, _P_STREAM_RELEASES, _i64(state, _P_STREAM_RELEASES) + 1)
    _set_ptr(st, ST_RELEASE, _null())


def _move_struct(dst: Words, src: Words, n: Int, release_slot: Int):
    """Hand `src` over to the consumer's `dst`, after which `src` is marked
    released so it cannot be handed out twice."""
    for k in range(n):
        _set_ptr(dst, k, _ptr(src, k))
    _set_ptr(src, release_slot, _null())


def _drv_get_schema(st: Words, dst: Words) abi("C") -> Int32:
    var state = _words_at(_ptr(st, ST_PRIVATE))
    _set_i64(state, _P_SCHEMA_CALLS, _i64(state, _P_SCHEMA_CALLS) + 1)
    var tmpl = _words_at(_ptr(state, _P_SCHEMA))
    if _is_null(_ptr(tmpl, S_RELEASE)):
        return EINVAL
    _move_struct(dst, tmpl, S_WORDS, S_RELEASE)
    return 0


def _drv_get_next(st: Words, dst: Words) abi("C") -> Int32:
    var state = _words_at(_ptr(st, ST_PRIVATE))
    var k = Int(_i64(state, _P_NEXT))
    if k >= 2:
        # End of stream: a released array.
        for j in range(A_WORDS):
            _set_ptr(dst, j, _null())
        return 0
    _move_struct(dst, _words_at(_ptr(state, _P_CHUNK0 + k)), A_WORDS, A_RELEASE)
    _set_i64(state, _P_NEXT, Int64(k + 1))
    return 0


def _drv_get_last_error(st: Words) abi("C") -> Bytes:
    _ = st
    return _null().bitcast[UInt8]()


struct _Producer(Movable):
    var arena: _Arena
    var records: List[Words]
    var names: List[String]

    def __init__(out self):
        self.arena = _Arena()
        self.records = List[Words]()
        self.names = List[String]()

    def record(mut self, name: String, home: Words) -> Void:
        """A zeroed record for the struct built at `home`."""
        var r = self.arena.words(_R_WORDS)
        _set_ptr(r, _R_HOME, home.bitcast[NoneType]())
        self.records.append(r)
        self.names.append(name)
        return r.bitcast[NoneType]()

    def calls(self, k: Int) -> Int64:
        return _i64(self.records[k], _R_CALLS)

    def direct(self, k: Int) -> Int64:
        return _i64(self.records[k], _R_DIRECT)


def _schema_struct(
    mut p: _Producer, fmt: String, name: String, flags: Int64, children: List[Words], dictionary: Void, label: String
) -> Words:
    var s = p.arena.words(S_WORDS)
    _set_ptr(s, S_FORMAT, p.arena.cstr(fmt))
    _set_ptr(s, S_NAME, p.arena.cstr(name))
    _set_i64(s, S_FLAGS, flags)
    _set_i64(s, S_N_CHILDREN, Int64(len(children)))
    if len(children) > 0:
        var kids = p.arena.words(len(children))
        for k in range(len(children)):
            _set_ptr(kids, k, children[k].bitcast[NoneType]())
        _set_ptr(s, S_CHILDREN, kids.bitcast[NoneType]())
    _set_ptr(s, S_DICTIONARY, dictionary)
    _set_ptr(s, S_RELEASE, _release_word(_drv_release_schema))
    _set_ptr(s, S_PRIVATE, p.record(label, s))
    return s


def _array_struct(
    mut p: _Producer, length: Int, null_count: Int, bufs: List[Void], children: List[Words], dictionary: Void, label: String
) -> Words:
    var a = p.arena.words(A_WORDS)
    _set_i64(a, A_LENGTH, Int64(length))
    _set_i64(a, A_NULL_COUNT, Int64(null_count))
    _set_i64(a, A_N_BUFFERS, Int64(len(bufs)))
    var b = p.arena.words(len(bufs))
    for k in range(len(bufs)):
        _set_ptr(b, k, bufs[k])
    _set_ptr(a, A_BUFFERS, b.bitcast[NoneType]())
    _set_i64(a, A_N_CHILDREN, Int64(len(children)))
    if len(children) > 0:
        var kids = p.arena.words(len(children))
        for k in range(len(children)):
            _set_ptr(kids, k, children[k].bitcast[NoneType]())
        _set_ptr(a, A_CHILDREN, kids.bitcast[NoneType]())
    _set_ptr(a, A_DICTIONARY, dictionary)
    _set_ptr(a, A_RELEASE, _release_word(_drv_release_array))
    _set_ptr(a, A_PRIVATE, p.record(label, a))
    return a


@fieldwise_init
struct _Src(Movable):
    """The values of one chunk the driver produces."""

    var i64: List[Int64]
    var f64: List[Float64]
    var s: List[String]
    var s_valid: List[Bool]
    var ls: List[String]
    var d_values: List[String]
    var d_idx: List[Int32]
    var m_lo: List[Int64]
    var m_hi: List[Int64]


def _src0() -> _Src:
    return _Src(
        i64=[Int64(7), Int64(-8), Int64(9)],
        f64=[Float64(0.25), Float64(-1.0), Float64(2.0)],
        s=[String("ab"), String(""), String("c")],
        s_valid=[True, False, True],
        ls=[String("L1"), String(""), String("L333")],
        d_values=[String("red"), String("green")],
        d_idx=[Int32(1), Int32(0), Int32(1)],
        m_lo=[Int64(1), Int64(-2), Int64(3)],
        m_hi=[Int64(0), Int64(-1), Int64(0)],
    )


def _src1() -> _Src:
    return _Src(
        i64=[Int64(100), Int64(-200)],
        f64=[Float64(10.5), Float64(-0.125)],
        s=[String(""), String("xyz")],
        s_valid=[False, True],
        ls=[String("Q"), String("RS")],
        d_values=[String("blue")],
        d_idx=[Int32(0), Int32(0)],
        # 2**70 + 7; -5.
        m_lo=[Int64(7), Int64(-5)],
        m_hi=[Int64(64), Int64(-1)],
    )


def _all_valid(n: Int) -> List[Bool]:
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^


def _i64_buf(mut p: _Producer, v: List[Int64]) -> Void:
    var b = p.arena.bytes(8 * len(v))
    for k in range(len(v)):
        (b.bitcast[Int64]() + k)[] = v[k]
    return b


def _f64_buf(mut p: _Producer, v: List[Float64]) -> Void:
    var b = p.arena.bytes(8 * len(v))
    for k in range(len(v)):
        (b.bitcast[Float64]() + k)[] = v[k]
    return b


def _i32_buf(mut p: _Producer, v: List[Int32]) -> Void:
    var b = p.arena.bytes(4 * len(v))
    for k in range(len(v)):
        (b.bitcast[Int32]() + k)[] = v[k]
    return b


def _bitmap(mut p: _Producer, valid: List[Bool]) -> Void:
    var b = p.arena.bytes((len(valid) + 7) // 8).bitcast[UInt8]()
    for r in range(len(valid)):
        if valid[r]:
            b[r >> 3] = b[r >> 3] | (UInt8(1) << UInt8(r & 7))
    return b.bitcast[NoneType]()


def _offsets(mut p: _Producer, values: List[String], valid: List[Bool], wide: Bool) -> Void:
    """int32 (or, `wide`, int64) offsets; a NULL row has length 0."""
    var width = 8 if wide else 4
    var b = p.arena.bytes(width * (len(values) + 1))
    var at = 0
    for r in range(len(values) + 1):
        if wide:
            (b.bitcast[Int64]() + r)[] = Int64(at)
        else:
            (b.bitcast[Int32]() + r)[] = Int32(at)
        if r < len(values) and valid[r]:
            at += values[r].byte_length()
    return b


def _text(mut p: _Producer, values: List[String], valid: List[Bool]) -> Void:
    var all = String("")
    for r in range(len(values)):
        if valid[r]:
            all += values[r]
    var src = all.as_bytes()
    var b = p.arena.bytes(len(src))
    for k in range(len(src)):
        (b.bitcast[UInt8]() + k)[] = src[k]
    return b


def _nulls(valid: List[Bool]) -> Int:
    var n = 0
    for r in range(len(valid)):
        if not valid[r]:
            n += 1
    return n


def _chunk_array(mut p: _Producer, ref src: _Src, label: String) -> Words:
    var n = len(src.i64)
    var none = List[Words]()
    var every = _all_valid(n)
    var i = _array_struct(p, n, 0, [_null(), _i64_buf(p, src.i64)], none, _null(), label + ".i")
    var f = _array_struct(p, n, 0, [_null(), _f64_buf(p, src.f64)], none, _null(), label + ".f")
    var s = _array_struct(
        p,
        n,
        _nulls(src.s_valid),
        [_bitmap(p, src.s_valid), _offsets(p, src.s, src.s_valid, False), _text(p, src.s, src.s_valid)],
        none,
        _null(),
        label + ".s",
    )
    var ls = _array_struct(
        p, n, 0, [_null(), _offsets(p, src.ls, every, True), _text(p, src.ls, every)], none, _null(), label + ".ls"
    )
    var dict_every = _all_valid(len(src.d_values))
    var dv = _array_struct(
        p,
        len(src.d_values),
        0,
        [_null(), _offsets(p, src.d_values, dict_every, False), _text(p, src.d_values, dict_every)],
        none,
        _null(),
        label + ".d.dictionary",
    )
    var d = _array_struct(p, n, 0, [_null(), _i32_buf(p, src.d_idx)], none, dv.bitcast[NoneType](), label + ".d")
    var words = List[Int64]()
    for r in range(n):
        words.append(src.m_lo[r])
        words.append(src.m_hi[r])
    var m = _array_struct(p, n, 0, [_null(), _i64_buf(p, words)], none, _null(), label + ".m")
    return _array_struct(p, n, 0, [_null()], [i, f, s, ls, d, m], _null(), label)


def _schema_tree(mut p: _Producer) -> Words:
    var none = List[Words]()
    var dv = _schema_struct(p, "u", "", ARROW_FLAG_NULLABLE, none, _null(), "schema.d.dictionary")
    var i = _schema_struct(p, "l", "i", 0, none, _null(), "schema.i")
    var f = _schema_struct(p, "g", "f", 0, none, _null(), "schema.f")
    var s = _schema_struct(p, "u", "s", ARROW_FLAG_NULLABLE, none, _null(), "schema.s")
    var ls = _schema_struct(p, "U", "ls", 0, none, _null(), "schema.ls")
    var d = _schema_struct(p, "i", "d", 0, none, dv.bitcast[NoneType](), "schema.d")
    var m = _schema_struct(p, "d:10,2", "m", 0, none, _null(), "schema.m")
    return _schema_struct(p, "+s", "", 0, [i, f, s, ls, d, m], _null(), "schema")


# --- the checksum (the same function as arrow_c_abi_probe.mojo's) -----------------


struct _Fnv:
    var h: UInt64

    def __init__(out self):
        self.h = UInt64(0xCBF29CE484222325)

    def byte(mut self, b: UInt8):
        self.h = (self.h ^ UInt64(b)) * UInt64(0x100000001B3)

    def u64(mut self, v: UInt64):
        for k in range(8):
            self.byte(UInt8((v >> UInt64(8 * k)) & UInt64(0xFF)))

    def name(mut self, s: String):
        var b = s.as_bytes()
        for k in range(len(b)):
            self.byte(b[k])

    def text(mut self, s: String):
        var b = s.as_bytes()
        self.u64(UInt64(len(b)))
        for k in range(len(b)):
            self.byte(b[k])


def _hash_src(mut h: _Fnv, ref src: _Src):
    var n = len(src.i64)
    h.u64(UInt64(n))
    h.name("i")
    h.byte(1)
    for r in range(n):
        h.byte(1)
        h.u64(bitcast[DType.uint64](src.i64[r]))
    h.name("f")
    h.byte(2)
    for r in range(n):
        h.byte(1)
        h.u64(bitcast[DType.uint64](src.f64[r]))
    h.name("s")
    h.byte(3)
    for r in range(n):
        if src.s_valid[r]:
            h.byte(1)
            h.text(src.s[r])
        else:
            h.byte(0)
    h.name("ls")
    h.byte(4)
    for r in range(n):
        h.byte(1)
        h.text(src.ls[r])
    h.name("d")
    h.byte(5)
    for r in range(n):
        h.byte(1)
        h.text(src.d_values[Int(src.d_idx[r])])
    h.name("m")
    h.byte(6)
    h.byte(10)
    h.byte(2)
    for r in range(n):
        h.byte(1)
        h.u64(bitcast[DType.uint64](src.m_lo[r]))
        h.u64(bitcast[DType.uint64](src.m_hi[r]))


def _import_direction(lib: OwnedDLHandle) raises:
    var p = _Producer()
    var src0 = _src0()
    var src1 = _src1()
    var state = p.arena.words(_P_WORDS)
    _set_ptr(state, _P_SCHEMA, _schema_tree(p).bitcast[NoneType]())
    _set_ptr(state, _P_CHUNK0, _chunk_array(p, src0, "chunk0").bitcast[NoneType]())
    _set_ptr(state, _P_CHUNK0 + 1, _chunk_array(p, src1, "chunk1").bitcast[NoneType]())
    var st = p.arena.words(ST_WORDS)
    _set_ptr(st, ST_GET_SCHEMA, _schema_fn_word(_drv_get_schema))
    _set_ptr(st, ST_GET_NEXT, _next_fn_word(_drv_get_next))
    _set_ptr(st, ST_GET_LAST_ERROR, _error_fn_word(_drv_get_last_error))
    _set_ptr(st, ST_RELEASE, _release_word(_drv_release_stream))
    _set_ptr(st, ST_PRIVATE, state.bitcast[NoneType]())
    var sum_box = p.arena.bytes(8).bitcast[UInt64]()
    var err = p.arena.bytes(512)

    var rc = lib.call["probe_import_stream", Int32](st, sum_box, err, Int64(512))
    if rc != 0:
        _fail("probe_import_stream rc is " + String(rc) + ": " + _read_cstr(err))

    _eq("get_schema calls", _i64(state, _P_SCHEMA_CALLS), 1)
    _eq("chunks taken", _i64(state, _P_NEXT), 2)
    _eq("release of the stream: calls", _i64(state, _P_STREAM_RELEASES), 1)
    if not _is_null(_ptr(st, ST_RELEASE)):
        _fail("imported stream: release is not NULL after the drain")
    for k in range(len(p.names)):
        var c = p.calls(k)
        if c != 1:
            _fail("release of " + p.names[k] + " ran " + String(c) + " times, expected exactly 1")
        if p.direct(k) != 0:
            _fail("release of " + p.names[k] + " was called by the consumer in place, not by its parent's release")
    var h = _Fnv()
    _hash_src(h, src0)
    _hash_src(h, src1)
    if sum_box[] != h.h:
        _fail("probe_import_stream checksum is " + String(sum_box[]) + ", expected " + String(h.h))
    var structs = len(p.names)
    p.arena.free_all()
    print("import: " + String(structs) + " structs each released once, none in place, checksum " + String(h.h))


def main() raises:
    # The handle is never closed. With an `OwnedDLHandle` local, which closes
    # the library when it is dropped at the end of main, this program printed
    # "ok" and then died at process exit with SIGSEGV (exit 139): work that
    # runs at exit refers to the library's code once the library has run.
    # Unloading is not what this gate tests, so the handle is moved to a heap
    # block that is never freed and the library stays mapped until the end.
    var lib = alloc[OwnedDLHandle](1)
    lib.unsafe_write(OwnedDLHandle(LIB))
    _export_direction(lib[])
    _import_direction(lib[])
    print("ok")
