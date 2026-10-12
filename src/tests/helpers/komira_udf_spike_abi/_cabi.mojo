# =============================================================================
# FFI-BOUNDARY: the Mojo mirror of komira_udf_runtime.h and komira_udf_wire.h.
# =============================================================================
# One struct per C struct, field for field, in declaration order. The C
# compiler's sizes and offsets are compared with these by tests/test_layout
# (through native/layout_probe.c), so a field added, dropped or moved on one
# side only turns the build red.
#
# Only _host.mojo and _table.mojo use these types. runtime.mojo holds the
# pointers they hand it as `Word`s, which it cannot read through, and the
# package's public API takes and returns values. Every pointer field is untracked (MutUntrackedOrigin)
# because its memory belongs to the C side of the ABI or to an arena of
# _host.mojo; the comment on each struct says who owns it. Function pointers
# a runtime fills are typed `abi("C") thin` with opaque (`Void`) arguments,
# because the Mojo manual requires `abi("C")` on a function crossing the FFI
# boundary, and a struct pointer argument would make the types recursive.
# Callback slots the harness both fills and calls (the Arrow `release`
# slots, the error's `release`) are kept as `Void` words and converted at the
# call (`as_*` below), so a NULL slot is a plain comparison.
# =============================================================================

from std.ffi import external_call
from std.memory import alloc

comptime Void = UnsafePointer[NoneType, MutUntrackedOrigin]
"""`void *`, and every other C pointer at this boundary."""

# The table entries (komira_udf_runtime), in table order.
comptime DescribeFn = def (Void, Void) abi("C") thin -> Int32
comptime ValidateFn = def (Void, Void, Void) abi("C") thin -> Int32
comptime LoadFn = def (Void, Void, Void, Void) abi("C") thin -> Int32
comptime CloseFn = def (Void) abi("C") thin -> None
comptime OpenContextFn = def (Void, UInt32, Void, Void) abi("C") thin -> Int32
comptime OpenInstanceFn = def (Void, Void, Void, Void) abi("C") thin -> Int32
comptime CallBatchFn = def (Void, Void, Void, Void, Void) abi("C") thin -> Int32
comptime FrameOpenFn = def (Void, Void, Void, Void, Void) abi("C") thin -> Int32
comptime FrameNextFn = def (Void, Void, Void, Void) abi("C") thin -> Int32
comptime AggOpenFn = def (Void, Void, Void) abi("C") thin -> Int32
comptime AggUpdateFn = def (Void, Void, Void, Void, UInt32, Void) abi("C") thin -> Int32
comptime AggEmitFn = def (Void, UInt32, Void, Void) abi("C") thin -> Int32
comptime MemoryReportFn = def (Void) abi("C") thin -> Int64

# komira_udf_host callbacks.
comptime MemReserveFn = def (Void, Int64) abi("C") thin -> Int32
comptime MemReleaseFn = def (Void, Int64) abi("C") thin -> None
comptime NowNsFn = def (Void) abi("C") thin -> Int64
comptime LogFn = def (Void, Int32, Void) abi("C") thin -> None

# Arrow callbacks, called through `Void` words.
comptime ReleaseFn = def (Void) abi("C") thin -> None
comptime GetSchemaFn = def (Void, Void) abi("C") thin -> Int32
comptime GetNextFn = def (Void, Void) abi("C") thin -> Int32
comptime LastErrorFn = def (Void) abi("C") thin -> Void


struct CArrowSchema:
    """struct ArrowSchema. Owner: whoever's `release` it carries."""

    var format: Void
    var name: Void
    var metadata: Void
    var flags: Int64
    var n_children: Int64
    var children: Void
    var dictionary: Void
    var release: Void
    var private_data: Void


struct CArrowArray:
    """struct ArrowArray. Owner: whoever's `release` it carries."""

    var length: Int64
    var null_count: Int64
    var offset: Int64
    var n_buffers: Int64
    var n_children: Int64
    var buffers: Void
    var children: Void
    var dictionary: Void
    var release: Void
    var private_data: Void


struct CArrowArrayStream:
    """struct ArrowArrayStream (layout only: the ABI passes device streams)."""

    var get_schema: Void
    var get_next: Void
    var get_last_error: Void
    var release: Void
    var private_data: Void


struct CArrowDeviceArray:
    """struct ArrowDeviceArray. The struct belongs to whoever allocated it;
    the array inside belongs to its `release`."""

    var array: CArrowArray
    var device_id: Int64
    var device_type: Int32
    var sync_event: Void
    var reserved: InlineArray[Int64, 3]


struct CArrowDeviceArrayStream:
    """struct ArrowDeviceArrayStream."""

    var device_type: Int32
    var get_schema: Void
    var get_next: Void
    var get_last_error: Void
    var release: Void
    var private_data: Void


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
    """komira_udf_host: allocated by the harness, alive until shutdown returns."""

    var struct_size: Int
    var abi_major: UInt32
    var abi_minor: UInt32
    var host_data: Void
    var mem_reserve: MemReserveFn
    var mem_release: MemReleaseFn
    var now_ns: NowNsFn
    var log: LogFn


struct CUdfCapabilities:
    """komira_udf_capabilities: the harness's struct, filled by describe; the
    strings are the runtime's, static for its life."""

    var struct_size: Int
    var runtime_id: Void
    var runtime_abi: Void
    var max_descriptor_version: UInt32
    var shapes: UInt32
    var threading: UInt32
    var thread_affine: UInt32
    var transports: UInt32
    var hosting: UInt32
    var devices: UInt32
    var features: UInt32
    var udf_class: UInt32
    var global_lock: UInt32


struct CUdfSpec:
    """komira_udf_spec: the harness's, borrowed by validate and load."""

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
    """komira_udf_call: the harness's, alive until the call returns."""

    var struct_size: Int
    var deadline_ns: Int64
    var call_id: Int64
    var cancel: Void


struct CUdfRuntime:
    """komira_udf_runtime: the runtime's static table, read-only here."""

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
    var frame_open: FrameOpenFn
    var frame_next: FrameNextFn
    var frame_close: CloseFn
    var agg_open: AggOpenFn
    var agg_update: AggUpdateFn
    var agg_merge: AggUpdateFn
    var agg_state: AggEmitFn
    var agg_finish: AggEmitFn
    var agg_close: CloseFn
    var shutdown: CloseFn
    var memory_report: MemoryReportFn


struct CUdfWireHeader:
    """komira_udf_wire_header (layout only; wire.mojo encodes the bytes)."""

    var magic: UInt32
    var op: UInt32
    var request_id: UInt64
    var flags: UInt32
    var slot: UInt32
    var payload_offset: UInt64
    var payload_len: UInt64


# --- words --------------------------------------------------------------------
#
# SAFETY: a C function pointer and a `void *` are both one machine word on
# the platforms this runs on; every conversion below reinterprets one word
# held in a local.


struct Word(ImplicitlyCopyable, Movable):
    """A C pointer held by runtime.mojo: a runtime handle, a host block, a
    table. Only _host.mojo and _table.mojo read through it (`.p`)."""

    var p: Void

    def __init__(out self, p: Void):
        self.p = p

    @staticmethod
    def null() -> Word:
        return Word(null_void())

    def is_null(self) -> Bool:
        return is_null(self.p)


def null_void() -> Void:
    """The NULL `void *`.

    # SAFETY: `Optional[UnsafePointer]` has the pointer's layout and `None` is
    # its all-zero pattern; the result is compared or stored, never read.
    """
    var none: Optional[Void] = None
    return UnsafePointer(to=none).bitcast[Void]()[]


def is_null(p: Void) -> Bool:
    return Int(p) == 0


def as_release(w: Void) -> ReleaseFn:
    var x = w
    return UnsafePointer(to=x).bitcast[ReleaseFn]()[]


def as_get_next(w: Void) -> GetNextFn:
    var x = w
    return UnsafePointer(to=x).bitcast[GetNextFn]()[]


def release_word(f: ReleaseFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def get_schema_word(f: GetSchemaFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def get_next_word(f: GetNextFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def last_error_word(f: LastErrorFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def memory_report_word(f: MemoryReportFn) -> Void:
    var g = f
    return UnsafePointer(to=g).bitcast[Void]()[]


def zeroed(n: Int) -> Void:
    """`n` zeroed bytes, 8-byte aligned (8 when `n` is 0). The caller frees it
    with free_zeroed.

    # SAFETY: a fresh allocation of whole words, every word written before the
    # pointer is returned.
    """
    var words = (n + 7) // 8 if n > 0 else 1
    var p = alloc[Int64](words).unsafe_origin_cast[MutUntrackedOrigin]()
    for k in range(words):
        (p + k).unsafe_write(Int64(0))
    return p.bitcast[NoneType]()


def free_zeroed(p: Void):
    """Free a block from `zeroed`.

    # SAFETY: `p` came from `zeroed` (an Int64 allocation) and is freed once.
    """
    p.bitcast[Int64]().free()


def read_cstr(p: Void, limit: Int = 1 << 20) -> String:
    """The NUL-terminated UTF-8 text at `p` ("" for NULL), at most `limit`
    bytes, copied.

    # SAFETY: `p` is NULL or a NUL-terminated string its owner keeps alive
    # for this call; reads stop at the NUL or at `limit`.
    """
    if is_null(p):
        return String("")
    var b = p.bitcast[UInt8]()
    var out = List[UInt8]()
    var k = 0
    while k < limit and b[k] != 0:
        out.append(b[k])
        k += 1
    return String(from_utf8_lossy=Span(out))


@fieldwise_init
struct LayoutRows(Copyable, Movable):
    """The rows native/layout_probe.c reports: `names[i]` has `values[i]`."""

    var names: List[String]
    var values: List[Int64]


def c_layout_rows() -> LayoutRows:
    """Every row of the C layout probe, in its order."""
    var out = LayoutRows(List[String](), List[Int64]())
    var n = Int(external_call["komira_udf_spike_layout_count", Int64]())
    for i in range(n):
        # SAFETY: the probe returns a pointer into its static row table (a
        # string literal), never NULL for i < count.
        var name = external_call["komira_udf_spike_layout_name", Void](Int64(i))
        out.names.append(read_cstr(name))
        out.values.append(external_call["komira_udf_spike_layout_value", Int64](Int64(i)))
    return out^


def c_layout_edges() -> List[Int64]:
    """The probe's answers at -1 and at its row count, just outside its rows:
    [name(-1) is NULL, name(n) is NULL, value(-1), value(n)], a Bool as 0 or 1.
    """
    var n = external_call["komira_udf_spike_layout_count", Int64]()
    var at: List[Int64] = [Int64(-1), n]
    var out = List[Int64]()
    for k in range(2):
        # SAFETY: only compared with NULL, never read through.
        var name = external_call["komira_udf_spike_layout_name", Void](at[k])
        out.append(Int64(1) if is_null(name) else Int64(0))
    for k in range(2):
        out.append(external_call["komira_udf_spike_layout_value", Int64](at[k]))
    return out^
