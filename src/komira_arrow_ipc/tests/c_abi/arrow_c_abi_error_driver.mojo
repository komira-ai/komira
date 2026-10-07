# =============================================================================
# FFI-BOUNDARY: the error paths of the Arrow C Stream Interface, across a
# dlopen of arrow_c_abi_probe.
# =============================================================================
# The second gate of //src/komira_arrow_ipc:arrow_c_abi_probe. Like
# arrow_c_abi_driver.mojo (which drives the paths where every call succeeds),
# it has no dependency, reads and writes the C structs as arrays of
# pointer-sized slots at their LP64 offsets, and calls every callback through
# a C function pointer (`abi("C")`).
#
# The C Stream Interface: get_schema and get_next return 0 or an errno-style
# code; after a non-zero return the consumer may call get_last_error, which
# returns a NUL-terminated string, or NULL, valid until the next call on the
# stream. These two cases put a call of get_last_error, the slot that returns
# a pointer, on a path the gate runs, in each direction:
#
# Export error (the library produces, the driver consumes):
#   `probe_export_failing_stream` fills a stream of one list<int64> column
#   and no batches; its get_schema cannot derive the child type and fails.
#   get_schema must return EIO and leave the schema released, and
#   get_last_error must return the library's text.
#
# Import error (the driver produces, the library consumes), two producers:
#   - get_schema fails with EIO;
#   - get_schema hands out a struct<x: int64> schema, then get_next fails
#     with EIO.
#   Each producer's get_last_error returns the driver's text.
#   `probe_import_stream` must return EIO, its error message must contain
#   "<callback> failed (rc=5): <the driver's text>" (so the library called the
#   driver's get_last_error through its C slot and read the returned string),
#   it must call get_last_error exactly once and release the stream once, and
#   it must release the schema once if it was handed one (the root's release
#   releases the child; the consumer must not).
#
# Who owns what: every block the driver allocates is in its `_Arena`, freed
# at the end of each case; its release callbacks free nothing, they count.
# =============================================================================

from std.ffi import OwnedDLHandle
from std.memory import alloc
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

# struct ArrowSchema (C Data Interface "Structure definitions"), LP64.
comptime S_WORDS = 9
comptime S_FORMAT = 0
comptime S_NAME = 1
comptime S_N_CHILDREN = 4
comptime S_CHILDREN = 5
comptime S_RELEASE = 7
comptime S_PRIVATE = 8

# struct ArrowArrayStream (C Stream Interface "Structure definition"), LP64.
comptime ST_WORDS = 5
comptime ST_GET_SCHEMA = 0
comptime ST_GET_NEXT = 1
comptime ST_GET_LAST_ERROR = 2
comptime ST_RELEASE = 3
comptime ST_PRIVATE = 4

comptime EIO: Int32 = 5
comptime ERR_CAP = 512


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
    return (s + i).bitcast[Int64]()[]


def _set_i64(s: Words, i: Int, v: Int64):
    (s + i).bitcast[Int64]()[] = v


def _words_at(p: Void) -> Words:
    return p.bitcast[Void]()


# --- C function pointers as slot words ----------------------------------------
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


def _as_last_error(w: Void) -> LastErrorFn:
    var x = w
    return UnsafePointer(to=x).bitcast[LastErrorFn]()[]


# --- the arena ------------------------------------------------------------------


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


def _fail(msg: String) raises:
    raise Error("arrow_c_abi_error_driver: " + msg)


def _eq(what: String, got: Int64, want: Int64) raises:
    if got != want:
        _fail(what + " is " + String(got) + ", expected " + String(want))


def _contains(what: String, text: String, want: String) raises:
    if text.find(want) < 0:
        _fail(what + " is '" + text + "', expected it to contain '" + want + "'")


# --- export error ----------------------------------------------------------------


def _export_error(lib: OwnedDLHandle) raises:
    var arena = _Arena()
    var st = arena.words(ST_WORDS)
    _eq("probe_export_failing_stream rc", Int64(lib.call["probe_export_failing_stream", Int32](st)), 0)
    if _is_null(_ptr(st, ST_GET_SCHEMA)) or _is_null(_ptr(st, ST_GET_LAST_ERROR)) or _is_null(_ptr(st, ST_RELEASE)):
        _fail("failing stream has a NULL callback")
    var sch = arena.words(S_WORDS)
    _eq("failing stream: get_schema rc", Int64(_as_get_schema(_ptr(st, ST_GET_SCHEMA))(st, sch)), Int64(EIO))
    if not _is_null(_ptr(sch, S_RELEASE)):
        _fail("failing stream: get_schema failed but filled the schema")
    var e = _as_last_error(_ptr(st, ST_GET_LAST_ERROR))(st).bitcast[NoneType]()
    if _is_null(e):
        _fail("failing stream: get_last_error is NULL after get_schema failed")
    var text = _read_cstr(e)
    _contains("failing stream: get_last_error", text, "empty stream with nested column 'l'")
    _as_release(_ptr(st, ST_RELEASE))(st)
    if not _is_null(_ptr(st, ST_RELEASE)):
        _fail("failing stream: release did not set release to NULL")
    arena.free_all()
    print("export error: get_schema returned EIO, get_last_error returned: " + text)


# --- import error: the driver's failing producers ----------------------------------
#
# The stream's private_data, and each schema's, is one state block.

comptime _P_WORDS = 9
comptime _P_FAIL_SCHEMA = 0  # 1: get_schema fails; 0: get_next fails
comptime _P_SCHEMA_CALLS = 1
comptime _P_NEXT_CALLS = 2
comptime _P_ERROR_CALLS = 3
comptime _P_STREAM_RELEASES = 4
comptime _P_ROOT_RELEASES = 5
comptime _P_CHILD_RELEASES = 6
comptime _P_ERROR = 7  # the C string get_last_error returns
comptime _P_ROOT = 8  # the root schema get_schema hands out

comptime _ERROR_TEXT = "driver producer: the source is unavailable"


def _state(s: Words, private_slot: Int) -> Words:
    return _words_at(_ptr(s, private_slot))


def _bump(state: Words, slot: Int):
    _set_i64(state, slot, _i64(state, slot) + 1)


def _drv_release_child(s: Words) abi("C") -> None:
    _bump(_state(s, S_PRIVATE), _P_CHILD_RELEASES)
    _set_ptr(s, S_RELEASE, _null())


def _drv_release_root(s: Words) abi("C") -> None:
    _bump(_state(s, S_PRIVATE), _P_ROOT_RELEASES)
    var kid = _words_at(_ptr(_words_at(_ptr(s, S_CHILDREN)), 0))
    if not _is_null(_ptr(kid, S_RELEASE)):
        _as_release(_ptr(kid, S_RELEASE))(kid)
    _set_ptr(s, S_RELEASE, _null())


def _drv_release_stream(st: Words) abi("C") -> None:
    _bump(_state(st, ST_PRIVATE), _P_STREAM_RELEASES)
    _set_ptr(st, ST_RELEASE, _null())


def _drv_get_schema(st: Words, dst: Words) abi("C") -> Int32:
    var state = _state(st, ST_PRIVATE)
    _bump(state, _P_SCHEMA_CALLS)
    if _i64(state, _P_FAIL_SCHEMA) != 0:
        return EIO  # `dst` untouched: the consumer's struct stays released
    var root = _words_at(_ptr(state, _P_ROOT))
    for k in range(S_WORDS):
        _set_ptr(dst, k, _ptr(root, k))
    _set_ptr(root, S_RELEASE, _null())
    return 0


def _drv_get_next(st: Words, dst: Words) abi("C") -> Int32:
    _ = dst
    _bump(_state(st, ST_PRIVATE), _P_NEXT_CALLS)
    return EIO


def _drv_get_last_error(st: Words) abi("C") -> Bytes:
    var state = _state(st, ST_PRIVATE)
    _bump(state, _P_ERROR_CALLS)
    return _ptr(state, _P_ERROR).bitcast[UInt8]()


def _schema(mut arena: _Arena, state: Words, fmt: String, name: String, release: ReleaseFn) -> Words:
    var s = arena.words(S_WORDS)
    _set_ptr(s, S_FORMAT, arena.cstr(fmt))
    _set_ptr(s, S_NAME, arena.cstr(name))
    _set_ptr(s, S_RELEASE, _release_word(release))
    _set_ptr(s, S_PRIVATE, state.bitcast[NoneType]())
    return s


def _import_error(lib: OwnedDLHandle, fail_schema: Bool) raises:
    var arena = _Arena()
    var state = arena.words(_P_WORDS)
    _set_i64(state, _P_FAIL_SCHEMA, Int64(1) if fail_schema else Int64(0))
    _set_ptr(state, _P_ERROR, arena.cstr(_ERROR_TEXT))
    var child = _schema(arena, state, "l", "x", _drv_release_child)
    var root = _schema(arena, state, "+s", "", _drv_release_root)
    var kids = arena.words(1)
    _set_ptr(kids, 0, child.bitcast[NoneType]())
    _set_i64(root, S_N_CHILDREN, 1)
    _set_ptr(root, S_CHILDREN, kids.bitcast[NoneType]())
    _set_ptr(state, _P_ROOT, root.bitcast[NoneType]())
    var st = arena.words(ST_WORDS)
    _set_ptr(st, ST_GET_SCHEMA, _schema_fn_word(_drv_get_schema))
    _set_ptr(st, ST_GET_NEXT, _next_fn_word(_drv_get_next))
    _set_ptr(st, ST_GET_LAST_ERROR, _error_fn_word(_drv_get_last_error))
    _set_ptr(st, ST_RELEASE, _release_word(_drv_release_stream))
    _set_ptr(st, ST_PRIVATE, state.bitcast[NoneType]())
    var sum_box = arena.bytes(8)
    var err = arena.bytes(ERR_CAP)

    var which = "get_schema" if fail_schema else "get_next"
    var rc = lib.call["probe_import_stream", Int32](st, sum_box, err, Int64(ERR_CAP))
    _eq(which + " fails: probe_import_stream rc", Int64(rc), Int64(EIO))
    var msg = _read_cstr(err)
    _contains(which + " fails: the error message", msg, which + " failed (rc=5): " + _ERROR_TEXT)
    _eq(which + " fails: get_last_error calls", _i64(state, _P_ERROR_CALLS), 1)
    _eq(which + " fails: get_schema calls", _i64(state, _P_SCHEMA_CALLS), 1)
    _eq(which + " fails: get_next calls", _i64(state, _P_NEXT_CALLS), Int64(0) if fail_schema else Int64(1))
    _eq(which + " fails: stream releases", _i64(state, _P_STREAM_RELEASES), 1)
    _eq(which + " fails: root schema releases", _i64(state, _P_ROOT_RELEASES), Int64(0) if fail_schema else Int64(1))
    _eq(which + " fails: child schema releases", _i64(state, _P_CHILD_RELEASES), Int64(0) if fail_schema else Int64(1))
    if not _is_null(_ptr(st, ST_RELEASE)):
        _fail(which + " fails: the stream's release is not NULL after the drain")
    arena.free_all()
    print("import error (" + which + "): probe_import_stream returned EIO: " + msg)


def main() raises:
    # The handle is never closed, as in arrow_c_abi_driver.mojo: closing it
    # at the end of main made the process die at exit with SIGSEGV.
    var lib = alloc[OwnedDLHandle](1)
    lib.unsafe_write(OwnedDLHandle(LIB))
    _export_error(lib[])
    _import_error(lib[], True)
    _import_error(lib[], False)
    print("ok")
