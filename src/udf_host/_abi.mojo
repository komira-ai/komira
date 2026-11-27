# =============================================================================
# FFI-BOUNDARY: a UDF runtime library and its komira_udf_runtime table.
# =============================================================================
# The engine's side of src/udf_abi/komira_udf_runtime.h (ABI 1.0,
# docs/design/udf_runtime_interface.md section 4.3): dlopen a runtime
# library (RTLD_NOW | RTLD_LOCAL), call its one export
# komira_udf_runtime_init_v1 with a host struct, and call the table's
# entries. runtime.mojo and instance.mojo are the only callers; they hold the
# pointers this file hands them as `Handle`s, which they cannot read through,
# and the package's public API takes and returns values.
#
# One Mojo struct per C struct, field for field (the spike harness's mirror,
# src/tests/helpers/komira_udf_spike_abi/_cabi.mojo, whose test_layout holds
# the same declarations to the C compiler's sizes and offsets).
#
# Who owns and frees each pointer:
#   - the OwnedDLHandle: a heap slot written once and never freed, so the
#     library is never dlclosed (design 4.3: runtimes start threads and
#     register exit handlers).
#   - the table: the runtime's static data, read only below its struct_size.
#   - the host struct and its options: one heap block each, made by
#     open_runtime and freed by free_host after shutdown returns (the runtime
#     keeps the host pointer until then; the options are borrowed for init
#     only, but are kept with the host for simplicity).
#   - rt, udf, context and instance handles: the runtime's, created and
#     freed only through the table.
#   - a spec, a call struct, an error, an out-slot and the two device arrays
#     of a call: heap blocks of this file, freed before the entry's wrapper
#     returns. The spec's strings and digests are blocks of the spec.
#   - the args array of call_batch: exported by arrow_ipc (its columns shared
#     into its private state) and moved to the runtime, which releases it
#     once, whatever the status; one the runtime left unmoved is released
#     here once and reported.
#   - a runtime's `out` array: the runtime's until it is validated and
#     copied (arrow_ipc.import_c_column), then released here once through its
#     own callback.
#   - komira_udf_error: allocated per call here; its strings are the
#     runtime's until its `release` (called once, when non-NULL).
# =============================================================================

from std.ffi import OwnedDLHandle, RTLD
from std.memory import alloc
from std.sys import size_of
from std.time import perf_counter_ns

from arrow.column import Column
from arrow.schema import Field, RecordBatch, Schema
from arrow_ipc.c_data_column import (
    export_field_schema,
    export_struct_array,
    export_struct_schema,
    import_c_column,
)
from arrow_ipc.c_data_interface import CArrowArray, CArrowSchema
from arrow_ipc.c_data_stream import consumer_release_c_array, consumer_release_c_schema
from byte_buffer.heap_region import HeapRegion

comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]
"""`void *`, and every other C pointer at this boundary."""

comptime INIT_SYMBOL = "komira_udf_runtime_init_v1"
comptime ABI_MAJOR: UInt32 = 1
comptime ABI_MINOR: UInt32 = 0
comptime ARROW_DEVICE_CPU: Int32 = 1
comptime _DEVICE_ARRAY_BYTES = 128
"""sizeof(struct ArrowDeviceArray): the 80-byte ArrowArray, device_id,
device_type and its padding, sync_event and three reserved words."""
comptime _ARRAY_BYTES = 80
"""sizeof(struct ArrowArray)."""

# The table entries (komira_udf_runtime) this host calls, and the others as
# words of the same size.
comptime DescribeFn = def (Void, Void) abi("C") thin -> Int32
comptime ValidateFn = def (Void, Void, Void) abi("C") thin -> Int32
comptime LoadFn = def (Void, Void, Void, Void) abi("C") thin -> Int32
comptime CloseFn = def (Void) abi("C") thin -> None
comptime OpenContextFn = def (Void, UInt32, Void, Void) abi("C") thin -> Int32
comptime OpenInstanceFn = def (Void, Void, Void, Void) abi("C") thin -> Int32
comptime CallBatchFn = def (Void, Void, Void, Void, Void) abi("C") thin -> Int32

# komira_udf_host callbacks.
comptime MemReserveFn = def (Void, Int64) abi("C") thin -> Int32
comptime MemReleaseFn = def (Void, Int64) abi("C") thin -> None
comptime NowNsFn = def (Void) abi("C") thin -> Int64
comptime LogFn = def (Void, Int32, Void) abi("C") thin -> None
comptime ReleaseFn = def (Void) abi("C") thin -> None


struct CUdfError:
    """komira_udf_error: the host allocates one per call; the runtime owns
    the strings until the host calls `release`."""

    var struct_size: Int
    var code: Int32
    var message: Void
    var user_trace: Void
    var row: Int64
    var group: Int64
    var release: Void
    var private_data: Void


struct CUdfHost:
    """komira_udf_host: alive from init until shutdown returns."""

    var struct_size: Int
    var abi_major: UInt32
    var abi_minor: UInt32
    var host_data: Void
    var mem_reserve: MemReserveFn
    var mem_release: MemReleaseFn
    var now_ns: NowNsFn
    var log: LogFn
    var n_options: Int
    var options: Void


struct CUdfCapabilities:
    """komira_udf_capabilities: filled by describe; the strings are the
    runtime's, static for its life."""

    var struct_size: Int
    var runtime_id: Void
    var runtime_abi: Void
    var max_descriptor_version: UInt32
    var shapes: UInt32
    var devices: UInt32
    var features: UInt32
    var udf_class: UInt32


struct CUdfSpec:
    """komira_udf_spec: the host's, borrowed by validate and load."""

    var struct_size: Int
    var shape: Int32
    var form: Int32
    var entry: Void
    var descriptor_version: UInt32
    var descriptor: Void
    var descriptor_len: Int
    var args: Void
    var result: Void
    var state: Void
    var null_mode: Int32
    var stability: Int32
    var code_root: Void
    var n_code: Int
    var code_roles: Void
    var code_sha256: Void


struct CUdfCall:
    """komira_udf_call: the host's, alive until the call returns."""

    var struct_size: Int
    var deadline_ns: Int64
    var call_id: Int64
    var cancel: Void


struct CUdfRuntime:
    """komira_udf_runtime: the runtime's static table, read-only here. The
    entries this host does not call are words of the same size."""

    var struct_size: Int
    var abi_major: UInt32
    var abi_minor: UInt32
    var describe: DescribeFn
    var validate: ValidateFn
    var load: LoadFn
    var unload: CloseFn
    var open_context: OpenContextFn
    var close_context: CloseFn
    var open_instance: OpenInstanceFn
    var close_instance: CloseFn
    var call_batch: CallBatchFn
    var frame_open: Void
    var frame_next: Void
    var frame_close: Void
    var agg_open: Void
    var agg_update: Void
    var agg_merge: Void
    var agg_state: Void
    var agg_finish: Void
    var agg_close: Void
    var shutdown: CloseFn
    var memory_report: Void


comptime REQUIRED_TABLE_BYTES = size_of[CUdfRuntime]() - 8
"""The bytes a table must cover: every entry up to `shutdown` (the optional
`memory_report` is never read)."""


struct Handle(ImplicitlyCopyable, Movable):
    """A C pointer this file handed out: a library slot, the table, the rt,
    a UDF, a context, an instance or the host block. Only this file reads
    through it."""

    var _p: Void

    def __init__(out self, p: Void):
        self._p = p

    @staticmethod
    def null() -> Handle:
        return Handle(_null())

    def is_null(self) -> Bool:
        return Int(self._p) == 0


def _null() -> Void:
    """The NULL `void *`."""
    # SAFETY: `Optional[UnsafePointer]` has the pointer's layout and `None`
    # is its all-zero pattern; the result is compared or stored, never read.
    var none: Optional[Void] = None
    return UnsafePointer(to=none).bitcast[Void]()[]


def _zeroed(n: Int) -> Void:
    """`n` zeroed bytes, 8-byte aligned (8 when `n` is 0); freed with
    `_free`."""
    # SAFETY: a fresh allocation of whole words, every word written before
    # the pointer is returned. Its origin is untracked because it is handed
    # to the runtime and outlives every Mojo scope until `_free`.
    var words = (n + 7) // 8 if n > 0 else 1
    var p = alloc[Int64](words).unsafe_origin_cast[MutUntrackedOrigin]()
    for k in range(words):
        (p + k).unsafe_write(Int64(0))
    return p.bitcast[NoneType]()


def _free(p: Void):
    """Free a block from `_zeroed` (NULL does nothing)."""
    if Int(p) == 0:
        return
    # SAFETY: `p` came from `_zeroed` (an Int64 allocation) and is freed once.
    p.bitcast[Int64]().free()


def _cstr(s: String) -> Void:
    """A NUL-terminated copy of `s` in a block of its own."""
    var b = s.as_bytes()
    var p = _zeroed(len(b) + 1)
    # SAFETY: the block is len + 1 zeroed bytes; the copy writes len.
    var d = p.bitcast[UInt8]()
    for k in range(len(b)):
        d[k] = b[k]
    return p


def _read_cstr(p: Void) -> String:
    """The NUL-terminated UTF-8 text at `p` ("" for NULL), at most 1 MiB,
    copied; bytes that are not UTF-8 are replaced."""
    if Int(p) == 0:
        return String("")
    # SAFETY: `p` is NULL or a NUL-terminated string its owner (the runtime)
    # keeps alive for this call; the read stops at the NUL or at 1 MiB.
    var b = p.bitcast[UInt8]()
    var out = List[UInt8]()
    var k = 0
    while k < (1 << 20) and b[k] != 0:
        out.append(b[k])
        k += 1
    return String(from_utf8_lossy=Span(out))


# --- the host struct and its callbacks ---------------------------------------
#
# Every callback is thread-safe (komira_udf_host): none touches state. The
# memory hooks accept every reservation (the engine does not yet count the
# bytes a runtime holds outside its Arrow buffers); the log is dropped.


def _host_mem_reserve(host_data: Void, bytes: Int64) abi("C") -> Int32:
    return 0


def _host_mem_release(host_data: Void, bytes: Int64) abi("C"):
    return


def _host_now_ns(host_data: Void) abi("C") -> Int64:
    return Int64(perf_counter_ns())


def _host_log(host_data: Void, level: Int32, utf8: Void) abi("C"):
    return


def now_ns() -> Int64:
    """The clock the host gives the runtime, which deadlines are read
    against (monotonic, nanoseconds)."""
    return Int64(perf_counter_ns())


# --- errors ---------------------------------------------------------------------


@fieldwise_init
struct ErrorText(Copyable, Movable):
    """What a runtime reported in a komira_udf_error."""

    var code: Int32
    var message: String
    var trace: String
    var row: Int64


def _new_error() -> Void:
    """A komira_udf_error for one call: code OK, row and group -2 (unset)."""
    var p = _zeroed(size_of[CUdfError]())
    # SAFETY: a zeroed block of the struct's size, written in place.
    var e = p.bitcast[CUdfError]()
    e[].struct_size = size_of[CUdfError]()
    e[].row = -2
    e[].group = -2
    return p


def _take_error(p: Void) -> ErrorText:
    """Copy the error's fields and strings, call its release once when it is
    set, and free the block."""
    # SAFETY: `p` is a block from `_new_error` the runtime may have filled;
    # its strings are the runtime's until `release`.
    var e = p.bitcast[CUdfError]()
    var out = ErrorText(e[].code, _read_cstr(e[].message), _read_cstr(e[].user_trace), e[].row)
    if Int(e[].release) != 0:
        var r = e[].release
        UnsafePointer(to=r).bitcast[ReleaseFn]()[](p)
    _free(p)
    return out^


# --- the library, init and the table ---------------------------------------------


@fieldwise_init
struct Opened(Movable):
    """What open_runtime made: the library slot, the table, the rt and the
    host block; or, when init refused, none of them and its error."""

    var lib: Handle
    var table: Handle
    var rt: Handle
    var host: Handle
    var refusal: Optional[ErrorText]


def open_runtime(path: String, options: List[String]) raises -> Opened:
    """dlopen `path`, check it exports the init symbol, and call init with a
    host of ABI 1.0 carrying `options` (each a `key=value` string). On a
    refusal by init the host is freed and `refusal` holds its error.

    Raises:
        UDF_RUNTIME_OPEN_FAILED when the library does not load,
        UDF_RUNTIME_MISSING_SYMBOL when it has no init export.
    """
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
    var n = len(options)
    var opts = _zeroed(8 * n)
    for i in range(n):
        # SAFETY: `opts` holds n pointer slots; each gets its own string block.
        opts.bitcast[Void]()[i] = _cstr(options[i])
    var hp = _zeroed(size_of[CUdfHost]())
    # SAFETY: a zeroed block of the host struct's size, written in place.
    var h = hp.bitcast[CUdfHost]()
    h[].struct_size = size_of[CUdfHost]()
    h[].abi_major = ABI_MAJOR
    h[].abi_minor = ABI_MINOR
    h[].host_data = opts
    h[].mem_reserve = _host_mem_reserve
    h[].mem_release = _host_mem_release
    h[].now_ns = _host_now_ns
    h[].log = _host_log
    h[].n_options = n
    h[].options = opts
    var slot = _zeroed(8)
    var err = _new_error()
    # SAFETY: `lib` is the live slot above; the three arguments are blocks of
    # the sizes the C prototype names.
    var t = lib[].call[INIT_SYMBOL, Void](hp, slot, err)
    var e = _take_error(err)  # released whatever init returned (design 4.4)
    # SAFETY: `slot` is an 8-byte block init wrote the rt into (or left 0).
    var rt = slot.bitcast[Void]()[]
    _free(slot)
    if Int(t) == 0:
        free_host(Handle(hp))
        return Opened(Handle.null(), Handle.null(), Handle.null(), Handle.null(), Optional(e^))
    return Opened(Handle(lib.bitcast[NoneType]()), Handle(t), Handle(rt), Handle(hp), None)


def free_host(host: Handle):
    """Free the host block and its options; after shutdown returned, or after
    init refused."""
    if host.is_null():
        return
    # SAFETY: `host` is the block open_runtime made; its options block holds
    # n_options string blocks. Nothing reads it after this.
    var h = host._p.bitcast[CUdfHost]()
    var opts = h[].options
    for i in range(h[].n_options):
        _free(opts.bitcast[Void]()[i])
    _free(opts)
    _free(host._p)


# SAFETY (every function below that reads `t`): `t` is the table init
# returned; it is static in the runtime and never freed. runtime.mojo checked
# its major and that it covers REQUIRED_TABLE_BYTES before any entry is read.


def _tbl(t: Handle) -> UnsafePointer[CUdfRuntime, MutUntrackedOrigin]:
    return t._p.bitcast[CUdfRuntime]()


def table_major(t: Handle) -> UInt32:
    return _tbl(t)[].abi_major


def table_bytes(t: Handle) -> Int:
    return _tbl(t)[].struct_size


@fieldwise_init
struct Caps(Copyable, Movable):
    """describe's answer, its strings copied."""

    var status: Int32
    var runtime_id: String
    var runtime_abi: String
    var shapes: UInt32


def describe(t: Handle, rt: Handle) -> Caps:
    var cp = _zeroed(size_of[CUdfCapabilities]())
    # SAFETY: a zeroed block of the struct's size; describe fills it and its
    # strings are static in the runtime.
    var c = cp.bitcast[CUdfCapabilities]()
    c[].struct_size = size_of[CUdfCapabilities]()
    var f = _tbl(t)[].describe
    var rc = f(rt._p, cp)
    var out = Caps(rc, _read_cstr(c[].runtime_id), _read_cstr(c[].runtime_abi), c[].shapes)
    _free(cp)
    return out^


def shutdown(t: Handle, rt: Handle):
    var f = _tbl(t)[].shutdown
    f(rt._p)


# --- the spec --------------------------------------------------------------------


@fieldwise_init
struct SpecValues(Movable):
    """The values of one komira_udf_spec (design 4.3), in the ABI's numbering."""

    var shape: Int32
    var form: Int32
    var entry: String
    var descriptor_version: UInt32
    var descriptor: List[UInt8]
    var args: Schema
    var result: Field
    var null_mode: Int32
    var stability: Int32
    var code_root: String
    var roles: List[String]
    var digests: List[List[UInt8]]


struct _Spec:
    """A komira_udf_spec in a block, with the schemas it borrows."""

    var block: Void
    var args: CArrowSchema
    var result: CArrowSchema

    def __init__(out self, ref v: SpecValues) raises:
        self.args = export_struct_schema(v.args)
        try:
            self.result = export_field_schema(v.result)
        except e:
            # SAFETY: `self.args` is the live schema just exported.
            consumer_release_c_schema(UnsafePointer(to=self.args).unsafe_origin_cast[MutUntrackedOrigin]())
            raise e^
        self.block = _zeroed(size_of[CUdfSpec]())
        # SAFETY: a zeroed block of the struct's size, written in place; each
        # string and the digests are blocks of their own, freed in __del__.
        var s = self.block.bitcast[CUdfSpec]()
        s[].struct_size = size_of[CUdfSpec]()
        s[].shape = v.shape
        s[].form = v.form
        s[].entry = _cstr(v.entry)
        s[].descriptor_version = v.descriptor_version
        var d = _zeroed(len(v.descriptor))
        for i in range(len(v.descriptor)):
            d.bitcast[UInt8]()[i] = v.descriptor[i]
        s[].descriptor = d
        s[].descriptor_len = len(v.descriptor)
        s[].args = UnsafePointer(to=self.args).bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
        s[].result = UnsafePointer(to=self.result).bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
        s[].state = _null()
        s[].null_mode = v.null_mode
        s[].stability = v.stability
        s[].code_root = _cstr(v.code_root)
        var n = len(v.roles)
        s[].n_code = n
        s[].code_roles = _zeroed(8 * n)
        s[].code_sha256 = _zeroed(32 * n)
        for i in range(n):
            s[].code_roles.bitcast[Void]()[i] = _cstr(v.roles[i])
            for k in range(32):
                var byte = v.digests[i][k] if k < len(v.digests[i]) else UInt8(0)
                s[].code_sha256.bitcast[UInt8]()[32 * i + k] = byte

    def __del__(deinit self):
        # SAFETY: the block and every block it points at were made in
        # __init__ and are freed once; the schemas are this struct's own
        # exports, released once through their callbacks.
        var s = self.block.bitcast[CUdfSpec]()
        _free(s[].entry)
        _free(s[].descriptor)
        _free(s[].code_root)
        for i in range(s[].n_code):
            _free(s[].code_roles.bitcast[Void]()[i])
        _free(s[].code_roles)
        _free(s[].code_sha256)
        _free(self.block)
        consumer_release_c_schema(UnsafePointer(to=self.args).unsafe_origin_cast[MutUntrackedOrigin]())
        consumer_release_c_schema(UnsafePointer(to=self.result).unsafe_origin_cast[MutUntrackedOrigin]())


@fieldwise_init
struct Status(Movable):
    """An entry's status, its error when it failed, and the handle it made."""

    var code: Int32
    var error: ErrorText
    var made: Handle


def validate(t: Handle, rt: Handle, ref v: SpecValues) raises -> Status:
    var spec = _Spec(v)
    var err = _new_error()
    var f = _tbl(t)[].validate
    var rc = f(rt._p, spec.block, err)
    return Status(rc, _take_error(err), Handle.null())


def load(t: Handle, rt: Handle, ref v: SpecValues) raises -> Status:
    var spec = _Spec(v)
    var err = _new_error()
    var slot = _zeroed(8)
    var f = _tbl(t)[].load
    var rc = f(rt._p, spec.block, slot, err)
    # SAFETY: `slot` is an 8-byte block load wrote the UDF into (or left 0).
    var made = Handle(slot.bitcast[Void]()[]) if rc == 0 else Handle.null()
    _free(slot)
    return Status(rc, _take_error(err), made)


def unload(t: Handle, udf: Handle):
    var f = _tbl(t)[].unload
    f(udf._p)


def open_context(t: Handle, rt: Handle, slot_index: UInt32) -> Status:
    var err = _new_error()
    var slot = _zeroed(8)
    var f = _tbl(t)[].open_context
    var rc = f(rt._p, slot_index, slot, err)
    # SAFETY: as in `load`.
    var made = Handle(slot.bitcast[Void]()[]) if rc == 0 else Handle.null()
    _free(slot)
    return Status(rc, _take_error(err), made)


def close_context(t: Handle, ctx: Handle):
    var f = _tbl(t)[].close_context
    f(ctx._p)


def open_instance(t: Handle, ctx: Handle, udf: Handle) -> Status:
    var err = _new_error()
    var slot = _zeroed(8)
    var f = _tbl(t)[].open_instance
    var rc = f(ctx._p, udf._p, slot, err)
    # SAFETY: as in `load`.
    var made = Handle(slot.bitcast[Void]()[]) if rc == 0 else Handle.null()
    _free(slot)
    return Status(rc, _take_error(err), made)


def close_instance(t: Handle, inst: Handle):
    var f = _tbl(t)[].close_instance
    f(inst._p)


# --- one call -----------------------------------------------------------------------


struct CallOutcome(Movable):
    """What one call_batch gave: its status and error, the column when it
    returned OK and the output passed the layout checks, and a fault (the
    runtime broke the ABI: `UDF_RUNTIME_FAULT: ...`) when it did not."""

    var code: Int32
    var error: ErrorText
    var column: Optional[Column[HeapRegion]]
    var fault: String

    def __init__(out self, code: Int32, var error: ErrorText):
        self.code = code
        self.error = error^
        self.column = None
        self.fault = String("")


def _release_array_at(p: Void) -> Bool:
    """Release the ArrowArray at `p` once through its own callback, when it is
    set. False when the callback left its slot set (a broken release)."""
    # SAFETY: `p` is the first 80 bytes of a device-array block of this file.
    var a = p.bitcast[CArrowArray]()
    if a[].is_released():
        return True
    consumer_release_c_array(a)
    return a[].is_released()


def _out_fault(p: Void, rows: Int, want: Field) -> String:
    """Why the device array `p` a runtime returned on OK is not a column of
    `rows` rows the host can read; "" when it is."""
    # SAFETY: `p` is a zeroed device-array block of this file the runtime
    # filled; only its fixed fields are read.
    var a = p.bitcast[CArrowArray]()
    if a[].is_released():
        return String("call_batch returned OK with no output array")
    var dev_type = (p + 88).bitcast[Int32]()[]
    var dev_id = (p + 80).bitcast[Int64]()[]
    var sync = (p + 96).bitcast[Void]()[]
    if dev_type != ARROW_DEVICE_CPU or dev_id != -1 or Int(sync) != 0:
        return "the output is on device " + String(dev_type) + "/" + String(dev_id) + ", not the CPU"
    if a[].length != Int64(rows):
        return String("")  # the length is the caller's post-condition, with its own code
    if a[].n_children != 0 or Int(a[].dictionary) != 0:
        return "the output of type " + String(want.arrow_type) + " has " + String(a[].n_children) + " children and a dictionary slot " + ("set" if Int(a[].dictionary) != 0 else "unset")
    if a[].null_count < -1 or a[].offset < 0:
        return "the output's null_count " + String(a[].null_count) + " or offset " + String(a[].offset) + " is negative"
    return String("")


def call_batch(
    t: Handle,
    inst: Handle,
    ref args: RecordBatch,
    deadline_ns: Int64,
    call_id: Int64,
    want: Field,
) raises -> CallOutcome:
    """One call_batch of `inst` on `args` (a struct array of its columns, on
    the CPU), with `deadline_ns` against now_ns (0: none). The output is
    validated and copied at `want`'s type, then released."""
    var arr = export_struct_array(args)
    var d_args = _zeroed(_DEVICE_ARRAY_BYTES)
    # SAFETY: a zeroed device-array block; the exported ArrowArray (80 bytes)
    # is moved into its first words, so the block, not `arr`, holds it.
    d_args.bitcast[CArrowArray]().unsafe_write(arr^)
    (d_args + 80).bitcast[Int64]()[] = -1
    (d_args + 88).bitcast[Int32]()[] = ARROW_DEVICE_CPU
    var d_out = _zeroed(_DEVICE_ARRAY_BYTES)
    var cp = _zeroed(size_of[CUdfCall]())
    # SAFETY: a zeroed block of the call struct's size; `cancel` stays NULL
    # (no host cancels a call yet).
    var c = cp.bitcast[CUdfCall]()
    c[].struct_size = size_of[CUdfCall]()
    c[].deadline_ns = deadline_ns
    c[].call_id = call_id
    var err = _new_error()
    var f = _tbl(t)[].call_batch
    var rc = f(inst._p, cp, d_args, d_out, err)
    var out = CallOutcome(rc, _take_error(err))
    _free(cp)
    # A runtime moves args whatever the status (design 4.4), leaving the
    # slot released; one it did not move is still the host's: released here,
    # once, and reported.
    # SAFETY: `d_args` is the device-array block passed as `args`.
    if not d_args.bitcast[CArrowArray]()[].is_released():
        _ = _release_array_at(d_args)
        out.fault = String("call_batch did not move its args")
    if rc != 0:
        # SAFETY: `d_out` is the zeroed device-array block passed as `out`.
        var set_on_failure = not d_out.bitcast[CArrowArray]()[].is_released()
        var released = _release_array_at(d_out)
        if out.fault == "" and set_on_failure:
            out.fault = String("call_batch set its output on a failure")
        elif out.fault == "" and not released:
            out.fault = String("the output array's release left its slot set")
        _free(d_args)
        _free(d_out)
        return out^
    var why = _out_fault(d_out, args.num_rows(), want)
    if why == "" and out.fault == "":
        try:
            var schema = export_field_schema(want)
            try:
                out.column = Optional(import_c_column(d_out.bitcast[CArrowArray]()[], schema))
            except e:
                why = String(e)
            consumer_release_c_schema(UnsafePointer(to=schema).unsafe_origin_cast[MutUntrackedOrigin]())
        except e:
            why = String(e)
    if not _release_array_at(d_out) and why == "":
        why = String("the output array's release left its slot set")
    if why != "" and out.fault == "":
        out.fault = why^
    _free(d_args)
    _free(d_out)
    return out^
