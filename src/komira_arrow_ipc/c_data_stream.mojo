# =============================================================================
# FFI-BOUNDARY: Arrow C Stream Interface (ArrowArrayStream) + RecordBatch <-> C
# =============================================================================
# Library: Apache Arrow C Stream Interface + C Data Interface specs. No
#   dlopen — the ABI is defined by struct layout + a small set of function
#   pointers, not a library symbol table. Consumers are PyArrow / Pandas /
#   Polars / Rust Arrow.
#
# Spec references:
#   - https://arrow.apache.org/docs/format/CStreamInterface.html
#   - https://arrow.apache.org/docs/format/CDataInterface.html
#   - Rust canonical impl: arrow-rs `arrow-array/src/ffi_stream.rs`
#     (FFI_ArrowArrayStream / ArrowArrayStreamReader)
#   - DataFusion `DataFrame::execute_stream` -> `to_record_batch_reader`
#     (prior art)
#
# This module EXTENDS `c_data_interface.mojo` (which defines the foundational
# CArrowSchema / CArrowArray POD structs + the single-array primitive export
# stub) with:
#   1. `CArrowArrayStream` — the streaming POD struct (get_schema / get_next /
#      get_last_error / release function pointers + private_data).
#   2. `RecordBatch -> CArrowArray` / `Schema -> CArrowSchema` export — the
#      struct-of-children layout, one CArrowArray child per Column, buffer
#      pointers borrow the live Column's AlignedBuffers (kept alive by the
#      stream's private_data, which owns the materialized batches).
#   3. `CArrowArray + CArrowSchema -> RecordBatch` import — copies each child
#      array's buffers into fresh Mojo Columns.
#   4. Per-struct release callbacks for CArrowSchema / CArrowArray /
#      CArrowArrayStream — each walks its children, frees the heap it
#      allocated, then sets its own `release` member to NULL per the Arrow
#      C Data Interface "Released structure" contract.
#   5. `build_record_batch_stream` — the entry point used by the SDK's
#      Arrow C stream materializer: takes owned materialized
#      `Slab[RecordBatch]` + `Schema`, populates a caller-allocated
#      CArrowArrayStream.
#   6. `drain_record_batch_stream` — the entry point used by the SDK's
#      `from_arrow_c_stream` factory: reads schema + pulls
#      every chunk + releases the stream + returns owned `Slab[RecordBatch]`.
#
# SUPPORTED TYPE SUBSET (exports/imports wired here):
#   - Int8/Int16/Int32/Int64, UInt8/UInt16/UInt32/UInt64        — 2 buffers
#   - Float32/Float64                                            — 2 buffers
#   - Bool (packed bits)                                         — 2 buffers
#   - Date32 (i32 days), Date64 (i64 ms)                         — 2 buffers
#   - Timestamp (s/ms/us/ns; i64)                                — 2 buffers
#   - Decimal128 (16-byte little-endian)                         — 2 buffers
#   - String / Utf8 (i32 offsets + utf8 bytes)                   — 3 buffers
#   - Binary (i32 offsets + raw bytes)                           — 3 buffers
#   - LargeString / LargeUtf8 (i64 offsets + utf8 bytes)         — 3 buffers
#   - LargeBinary (i64 offsets + raw bytes)                      — 3 buffers
#   - Dictionary (parent: i32 indices; child via .dictionary)    — 2 buffers
# The type system also recognizes Decimal256, Time32/Time64, Duration,
# Interval (3 sub-variants), Union (sparse/dense) and the nested types
# (List<T> / Struct / Map); `_arrow_type_n_buffers` and the build/import arms
# below are the authority on which of them cross the C ABI, and anything else
# raises `UnsupportedArrowCABIType`. LargeString / LargeBinary / Binary share
# the 3-buffer var-len shape (offset width i32 for STRING/BINARY, i64 for
# LARGE_STRING/LARGE_BINARY). Columns with a non-zero logical `offset`
# (sliced columns) are not handled on the *export* side — materialized
# batches always start at offset 0, so this is not a hot path.
#
# SAFETY: every `UnsafePointer[..., MutExternalOrigin]` here is at the C ABI
#   boundary; lifetime is mediated by the C Data Interface release-callback
#   protocol, not Mojo's compile-time origin tracking. No wildcard origins.
#   No `unsafe_from_address`. Raw `alloc`/`free` is module-internal (the
#   FFI carve-out) — never exposed across the
#   public API; callers see only owned typed values / the caller-allocated
#   C struct pointer.
# =============================================================================

from std.memory import alloc, unsafe_memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import (
    ArrowType,
    decimal_format_string,
    decimal256_format_string,
    parse_format_string,
    extract_decimal_params,
    extract_timestamp_timezone,
    extract_union_type_ids,
    union_format_string,
)
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap
from komira_arrow_ipc.c_data_interface import (
    CArrowSchema,
    CArrowArray,
    ARROW_FLAG_NULLABLE,
    ARROW_FLAG_DICTIONARY_ORDERED,
    ARROW_FLAG_MAP_KEYS_SORTED,
    encode_metadata,
    decode_metadata,
    _is_null,
    _non_null,
)
from komira_arrow.column import Column
from komira_arrow.schema import Schema, Field, RecordBatch, SchemaBuilder
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_collections.slab import Slab


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer (the stdlib has no `UnsafePointer[T, o]()` null
    ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the non-null-pointer layout guarantee); `None` is
    # the all-zero (NULL) bit pattern. Replaces the removed null ctor with
    # NO `unsafe_from_address=Int(0)`. Used for FFI NULL sentinels/args
    # (e.g. Arrow C-ABI NULL fields, codec NULL prefs/options); the C side
    # treats NULL as documented (default options / absent field).
    #
    # NOTE: the `MutExternalOrigin` ORIGIN on the C-Data-Interface FFI
    # surface is the documented FFI-boundary carve-out (allowlisted); its
    # migration to a concrete origin is a separate effort, OUT OF SCOPE for
    # the b2 null-ctor unblock.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# =============================================================================
# NULL TESTS AT THE C ABI BOUNDARY — THREE MEANINGS, NOT ONE
# =============================================================================
#
# `_is_null` / `_non_null` are DEFINED ONCE, in `c_data_interface.mojo`, and
# imported above — deliberately unlike `_null_ptr`, which this file duplicates.
# The duplicate would be the more dangerous kind of copy: two files answering
# "is this pointer NULL" with two independent bodies is exactly how the answers
# drift apart, and both files read the same producer's structs.
#
# ⚠ `not p` WAS ONE SPELLING FOR THREE DIFFERENT SENTENCES. That is why the
# wrappers below are named rather than inlined — at a glance, every site read
# the same, and they are not the same question:
#
#   `release == NULL`      "A released structure is indicated by setting its
#                           release callback to NULL. Before reading and
#                           interpreting a structure's data, consumers SHOULD
#                           check for a NULL release callback and treat it
#                           accordingly (probably by erroring out)."
#                          ⇒ REFUSE (or, for get_next, END OF STREAM).
#
#   `buffers[i] == NULL`   "The buffer pointers MAY be null only in two
#                           situations: (1) for the null bitmap buffer, if
#                           ArrowArray.null_count is 0; (2) for any buffer
#                           (including variadic buffers), if the size in bytes
#                           of the corresponding buffer would be 0."
#                          ⇒ CONDITIONALLY LEGAL. Neither situation is implied
#                            by the pointer being NULL, so the test alone is
#                            never the answer — see `_require_c_buffer`.
#
#   `children == NULL`     "MAY be NULL only if n_children is 0."
#   `name`/`metadata`      Optional; NULL means absent. `format` is Mandatory.
#   `dictionary == NULL`   "MUST be present if [it] represents a dictionary-
#                           encoded [type/array]. MUST be NULL otherwise."
#                          ⇒ the DISCRIMINATOR, not an error.
#
# Reading a NULL buffer pointer as if it were the "released" or "absent field"
# case is what let a malformed foreign array through as uninitialised heap;
# falsifier `tests/test_arrow_c_data_null_buffer_semantics.mojo`.


# =============================================================================
# Type aliases for the FFI boundary.
# =============================================================================

comptime OpaquePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
"""`void*` at the C ABI boundary."""

comptime _SchemaPtr = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _ArrayPtr = UnsafePointer[CArrowArray, MutUntrackedOrigin]

# Function-pointer field types for ArrowArrayStream. The first argument is the
# stream-self pointer; we type it `OpaquePtr` rather than
# `UnsafePointer[CArrowArrayStream, ...]` to avoid the recursive struct type
# in a stored fn-ptr field (the callbacks bitcast it back internally). `thin`
# = non-capturing (required for a stored fn-ptr field); `abi("C")` = the C
# calling convention. The slots are `abi("C")` because the C Stream Interface
# declares them as C function pointers (a foreign producer such as pyarrow,
# arrow-rs or a C library fills them with C functions, and a foreign consumer
# calls ours as C functions), and because the Mojo manual requires `abi("C")`
# on a function that crosses the FFI boundary. Mojo documents no guarantee
# that its default convention matches C. The bug these types fixed came from
# `raises`, not from a missing `abi("C")`: a `raises thin` slot read a garbage
# return code from a C callee (measured in the block above
# `drain_c_abi_record_batch_stream`). Non-raising default-convention
# `get_schema`/`get_next` slots, the two that return `Int32`, were measured
# to interoperate with C on linux-x86_64 (that run did not call
# `get_last_error`), so the dlopen gate of `:arrow_c_abi_probe` would not
# catch those two losing `abi("C")`; whether the pointer-returning
# `get_last_error` would interoperate without it was not measured. The gate
# does catch any of the three gaining `raises`: `arrow_c_abi_driver.mojo`
# calls `get_schema` and `get_next` in both directions, and
# `arrow_c_abi_error_driver.mojo` calls `get_last_error` in both directions
# after a forced failure and checks the text. No callback raises: errors are
# a non-zero errno-style return and the text `get_last_error` returns.
comptime _GetSchemaFn = def(OpaquePtr, _SchemaPtr) abi("C") thin -> Int32
comptime _GetNextFn = def(OpaquePtr, _ArrayPtr) abi("C") thin -> Int32
comptime _GetLastErrorFn = def(OpaquePtr) abi("C") thin -> UnsafePointer[Int8, MutUntrackedOrigin]


# =============================================================================
# UnsupportedArrowCABIType — caller-friendly error sentinel.
# =============================================================================

@always_inline
def _unsupported(arrow_type: ArrowType, where: String) -> Error:
    """Build the `UnsupportedArrowCABIType` error message used by both the
    export and the drain paths."""
    return Error(
        "UnsupportedArrowCABIType: Arrow type '"
        + String(arrow_type)
        + "' is not in the supported Arrow C Data Interface subset ("
        + where
        + "). Supported: Int*/UInt*/Float*/Bool/Date32/Date64/"
        + "Timestamp/Decimal128/Decimal256/Time32/Time64/Duration/"
        + "Interval (YearMonth, DayTime)/String/Binary/LargeString/"
        + "LargeBinary/Dictionary/List/Struct/Map/Union (sparse, dense)."
        + "  Extension types are passed-through as metadata; Run-End-"
        + "Encoded (REE), Float16 SIMD compute, and Decimal256 arith are"
        + " not supported."
    )


# =============================================================================
# CArrowArrayStream — C ABI struct for the streaming variant.
# =============================================================================

struct CArrowArrayStream(Movable):
    """Arrow C Stream Interface struct.

    Matches the ArrowArrayStream C struct layout exactly:

        struct ArrowArrayStream {
            int (*get_schema)(struct ArrowArrayStream*, struct ArrowSchema*);
            int (*get_next)(struct ArrowArrayStream*, struct ArrowArray*);
            const char* (*get_last_error)(struct ArrowArrayStream*);
            void (*release)(struct ArrowArrayStream*);
            void* private_data;
        };

    Ownership: the `release` callback is the lifetime mechanism. After a
    consumer calls `release(&stream)`, `stream.release` MUST be NULL (the
    "released structure" contract — a non-null release pointer means the
    resource is still live). `private_data` holds the Mojo-side owning
    handle (`_CStreamState*`) so `release` can reclaim the materialized
    batches' heap.
    """

    # SAFETY: ALL pointer fields are required by the Arrow C Stream
    # Interface ABI. They cannot be OwnedPointer/ArcPointer — the ABI
    # mandates raw pointers + null semantics + function pointers, and the
    # release callback (not Mojo's origin tracker) manages ownership.

    var get_schema: _GetSchemaFn
    """Mandatory. `int (*)(ArrowArrayStream*, ArrowSchema* out)` — fills
    `out` with the (constant for the whole stream) schema. Returns 0 on
    success."""

    var get_next: _GetNextFn
    """Mandatory. `int (*)(ArrowArrayStream*, ArrowArray* out)` — fills
    `out` with the next chunk. On end-of-stream `out` is left in the
    released state (`out.release == NULL`). Returns 0 on success."""

    var get_last_error: _GetLastErrorFn
    """Mandatory. `const char* (*)(ArrowArrayStream*)` — returns a
    null-terminated UTF8 description of the last error, or NULL if there
    was none. Only meaningful after a callback returned non-zero."""

    var release: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Release callback. Stored as an opaque pointer holding a
    `_StreamReleaseFn`; we keep it as `void*` so `is_released()` is a
    plain null check and the producer can null it out post-release. NULL
    means already released."""

    var private_data: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Producer-private. Holds the heap-allocated `_CStreamState`."""

    def __init__(out self):
        """Create a zeroed-out (released) CArrowArrayStream — all
        callbacks point at the no-op stubs and `release`/`private_data`
        are NULL. A consumer that sees `release == NULL` treats the
        struct as already released."""
        self.get_schema = _stub_get_schema
        self.get_next = _stub_get_next
        self.get_last_error = _stub_get_last_error
        self.release = _null_ptr[NoneType, MutUntrackedOrigin]()
        self.private_data = _null_ptr[NoneType, MutUntrackedOrigin]()

    def is_released(self) -> Bool:
        """Per the Arrow spec, a NULL release callback means the struct
        has been released and must not be used."""
        return _is_null(self.release)


# --- No-op stubs (used by the zeroed-out CArrowArrayStream). ---
#
# Calling a callback of a released stream is a consumer error the spec leaves
# undefined; these return EINVAL (22) and write nothing.

def _stub_get_schema(stream: OpaquePtr, out_schema: _SchemaPtr) abi("C") -> Int32:
    _ = stream
    _ = out_schema
    return Int32(22)  # EINVAL


def _stub_get_next(stream: OpaquePtr, out_array: _ArrayPtr) abi("C") -> Int32:
    _ = stream
    _ = out_array
    return Int32(22)  # EINVAL


def _stub_get_last_error(stream: OpaquePtr) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    _ = stream
    return _null_ptr[Int8, MutUntrackedOrigin]()


# =============================================================================
# _CStreamState — the Mojo-side owning handle stashed in `private_data`.
# =============================================================================

struct _CStreamState(Movable, Deinitable):
    """Producer-private state for an exported CArrowArrayStream.

    Owns the materialized batches (so the buffer pointers handed out by
    `get_next` stay valid for the consumer's reads) plus the cursor and a
    sticky last-error string. Heap-allocated by `build_record_batch_stream`
    via raw `alloc` (FFI carve-out), pointer laundered into
    `CArrowArrayStream.private_data`, reclaimed by `release_c_stream`.

    No raw-pointer fields: `last_error_bytes` is a `List[UInt8]` holding a
    null-terminated UTF8 copy of the last error (empty == no error). The C
    `get_last_error` callback returns a pointer INTO this List's storage,
    which is valid until the next call to any stream method (the next
    `set_error` may replace it, `release_c_stream` destroys it) — exactly
    the Arrow C Stream Interface lifetime contract for the returned
    `const char*`. The `List` is owned by the struct (no wildcard-origin
    field).
    """

    var batches: Slab[RecordBatch]
    var schema: Schema
    var next_idx: Int
    var last_error_bytes: List[UInt8]

    def __init__(out self, var batches: Slab[RecordBatch], var schema: Schema):
        self.batches = batches^
        self.schema = schema^
        self.next_idx = 0
        self.last_error_bytes = List[UInt8]()

    def set_error(mut self, msg: String):
        var bytes = msg.as_bytes()
        var n = len(bytes)
        var buf = List[UInt8]()
        buf.reserve(n + 1)
        for i in range(n):
            buf.append(bytes[i])
        buf.append(UInt8(0))  # null-terminate for the C ABI
        self.last_error_bytes = buf^


# =============================================================================
# _CArrayState — per-EXPORTED-ARRAY private state. The independence guarantee.
# =============================================================================

struct _CArrayState(Movable, Deinitable):
    """Producer-private state for ONE exported CArrowArray: stashed in that
    array's own `private_data`, destroyed by that array's own `release`.

    ⚠ THE CONTRACT THIS EXISTS TO SATISFY. The Arrow C data interface says an
    exported array is an INDEPENDENT export — it owns, or shares ownership of,
    every byte its buffer pointers reach; the consumer calls `release` exactly
    once; and it stays valid after whatever produced it is gone. A stream is
    explicitly "whatever produced it": `ArrowArrayStream.release` may be called
    while arrays it already delivered are still live, and pyarrow does exactly
    that on every `reader.read_all()` whose reader then drops.

    If the delivered chunks BORROWED instead — `_build_column_array` reading
    the buffer `void*` slots straight out of the batch owned by
    `_CStreamState`, and `release_c_stream` destroying that batch — element 0
    of every buffer would read back as the allocator's freelist link, a heap
    address written in place of the value: sums come back as 0.0 and doubles
    as denormal garbage. The stream-outlives-context integration test guards
    this.

    ⚠ IT IS STILL ZERO-COPY, AND THAT IS WHY IT IS THIS AND NOT A COPY.
    `cols` holds one `Column.share()` per exported column — an Arc refcount
    bump on each backing `SharedAlignedBuffer` region, recursive through
    validity / offsets / dictionary bytes / nested children. NO BYTE IS COPIED.
    The exported buffer pointers are then read out of THESE shared columns, so
    the array points into storage its own `private_data` holds a reference to,
    and the producing batch's death merely decrements a refcount. Copying would
    have forfeited the only reason this egress path exists.

    Lifetime, end to end: `_build_record_batch_array` allocates one of these per
    delivered chunk and hangs it off the root array; `_release_array` destroys
    and frees it when the CONSUMER releases that array. Child and dictionary
    arrays leave `private_data` NULL — one state per delivered export, reachable
    from the root, is the whole tree's keepalive because `Column.share()` is
    recursive.
    """

    var cols: Slab[Column[HeapRegion]]
    """One Arc-share per exported top-level column. Dropping this Slab is the
    only thing that decrements those refcounts."""

    def __init__(out self, var cols: Slab[Column[HeapRegion]]):
        self.cols = cols^


# =============================================================================
# Low-level C-string + buffers-array helpers (FFI carve-out: raw alloc).
# =============================================================================

@always_inline
def _copy_string_to_c_int8(s: String) -> UnsafePointer[Int8, MutUntrackedOrigin]:
    """Heap-allocate a null-terminated copy of `s`. Caller owns the result
    (freed by the release callback / `_CStreamState.__del__`)."""
    var n = s.byte_length()
    var buf = alloc[Int8](n + 1).unsafe_origin_cast[MutUntrackedOrigin]()
    var s_ref = s
    var src = s_ref.as_c_string_slice().unsafe_ptr()
    if n > 0:
        unsafe_memcpy(dest=buf, src=src, count=n)
    (buf + n).unsafe_write(Int8(0))
    return buf


@always_inline
def _c_str_len(p: UnsafePointer[Int8, MutUntrackedOrigin]) -> Int:
    """`strlen` for a null-terminated C string. Returns 0 for NULL."""
    if _is_null(p):
        return 0
    var n = 0
    while p[n] != Int8(0):
        n += 1
    return n


@always_inline
def _c_str_to_mojo(p: UnsafePointer[Int8, MutUntrackedOrigin]) -> String:
    """Copy a null-terminated C string into a Mojo String. NULL -> ""."""
    if _is_null(p):
        return String("")
    return String(unsafe_from_utf8_ptr=p.bitcast[UInt8]())


# =============================================================================
# Per-Column buffer-count + format-string derivation (export side).
# =============================================================================

def _arrow_type_n_buffers(arrow_type: ArrowType) raises -> Int:
    """How many physical buffers a CArrowArray for `arrow_type` has, per
    the columnar-format spec.

    Coverage is BROAD, not a narrow subset — read the arms below, not the
    "supported subset" phrasing this function's error message inherits from
    `_unsupported` (that string names the same set from the other
    direction). Handled here:

      * every integer width (`is_integer`) and float width (`is_floating`)
      * Bool, Date32, Date64, every Timestamp unit (`is_timestamp`)
      * Decimal128 AND Decimal256
      * every Time (`is_time`), Duration (`is_duration`) and Interval
        (`is_interval`) variant
      * String, Binary, LargeString, LargeBinary
      * Dictionary, List, Struct, Map
      * both Union encodings — sparse (1 buffer) and dense (2)

    Only the trailing `else` raises `UnsupportedArrowCABIType`. Do NOT design
    around a "primitives only" limit that is not here — check whether a type
    already has an arm before building a fallback path around it.

    Note this answers the BUFFER COUNT only. A type can be counted here and
    still be rejected further along the export path (child schemas, format
    string, per-type buffer fill), so a non-raising return is not by itself
    proof of end-to-end support.
    """
    if (
        arrow_type.is_integer()
        or arrow_type.is_floating()
        or arrow_type == ArrowType.BOOL
        or arrow_type == ArrowType.DATE32
        or arrow_type == ArrowType.DATE64
        or arrow_type.is_timestamp()
        or arrow_type == ArrowType.DECIMAL128
        # Decimal256 (32-byte LE) is a fixed-width
        # primitive on the wire — 2 buffers (validity + data), same layout as
        # Decimal128. Precision/scale ride on Field.
        or arrow_type == ArrowType.DECIMAL256
        # Time / Duration / Interval types are
        # i32/i64 (or fixed-width packed) primitives on the wire — 2 buffers.
        or arrow_type.is_time()
        or arrow_type.is_duration()
        or arrow_type.is_interval()
    ):
        return 2  # [validity, data]
    elif (
        arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.BINARY
        or arrow_type == ArrowType.LARGE_STRING
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        return 3  # [validity, offsets, data]
    elif arrow_type == ArrowType.DICTIONARY:
        # Parent dictionary array has 2 buffers
        # (validity + indices); the value-type array hangs off the
        # CArrowArray.dictionary slot with its own buffer layout.
        return 2
    elif arrow_type == ArrowType.LIST:
        # List = validity + i32 offsets, 1 child.
        return 2
    elif arrow_type == ArrowType.STRUCT:
        # Struct = validity ONLY, N children.
        return 1
    elif arrow_type == ArrowType.MAP:
        # Map = validity + i32 offsets,
        # 1 child (entries struct).
        return 2
    elif arrow_type == ArrowType.UNION_SPARSE:
        # Sparse union = 1 buffer (Int8 types).
        # NO validity bitmap (Arrow spec — nullness comes from children).
        return 1
    elif arrow_type == ArrowType.UNION_DENSE:
        # Dense union = 2 buffers (Int8 types +
        # Int32 offsets).  NO validity bitmap.
        return 2
    else:
        raise _unsupported(arrow_type, "export")


def _column_format_string(col: Column[HeapRegion]) raises -> String:
    """Format string for a Column[HeapRegion] on the C ABI. Decimal128 / Decimal256 use
    their precision/scale-qualified form from the Column's carried (p, s),
    falling back to spec defaults if the Column carries no decimal metadata."""
    var t = col.arrow_type
    if t == ArrowType.DECIMAL128:
        var p = col.decimal_precision()
        var s = col.decimal_scale()
        if p < 1:
            return decimal_format_string(38, 18)
        return decimal_format_string(p, s)
    if t == ArrowType.DECIMAL256:
        # Decimal256 format string is
        # `d:P,S,256` — bitwidth third comma-separated component.
        var p = col.decimal_precision()
        var s = col.decimal_scale()
        if p < 1:
            return decimal256_format_string(76, 0)
        return decimal256_format_string(p, s)
    if t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        # Union format string is
        # `+us:I,J,...` (sparse) / `+ud:I,J,...` (dense).  Pull the
        # declared type-ids from the Column's `_type_ids` slot.
        return union_format_string(t, col._type_ids)
    var fmt = t.format_string()
    # `format_string()` returns "n" for unknown — guard against silently
    # exporting a wrong type.
    if fmt == "n" and t != ArrowType.NULL:
        raise _unsupported(t, "export")
    return fmt


# =============================================================================
# Column -> CArrowArray  (one "child" of the struct-of-children root).
# =============================================================================
#
# The CArrowArray's buffer pointers BORROW the live Column's MmapAlignedBuffer
# memory. The Column (inside the stream's `_CStreamState.batches`) must
# outlive the consumer's reads — the release callback enforces this by
# keeping `_CStreamState` alive until the consumer releases the root array.
#
# `_release_array` (recursive) is the per-array release; it frees the
# `buffers` array and (for the root) the `children` array, then nulls the
# `release` member. It does NOT free the borrowed buffer bytes — those are
# owned by `_CStreamState`.


def _alloc_buffers_array(n: Int) -> UnsafePointer[OpaquePtr, MutUntrackedOrigin]:
    """Allocate (and zero) a `void*[n]` array for CArrowArray.buffers."""
    if n == 0:
        return _null_ptr[OpaquePtr, MutUntrackedOrigin]()
    var arr = alloc[OpaquePtr](n).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(n):
        (arr + i).unsafe_write(_null_ptr[NoneType, MutUntrackedOrigin]())
    return arr


def _alloc_array_ptr_array(n: Int) -> UnsafePointer[_ArrayPtr, MutUntrackedOrigin]:
    if n == 0:
        return _null_ptr[_ArrayPtr, MutUntrackedOrigin]()
    var arr = alloc[_ArrayPtr](n).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(n):
        (arr + i).unsafe_write(_null_ptr[CArrowArray, MutUntrackedOrigin]())
    return arr


def _alloc_schema_ptr_array(n: Int) -> UnsafePointer[_SchemaPtr, MutUntrackedOrigin]:
    if n == 0:
        return _null_ptr[_SchemaPtr, MutUntrackedOrigin]()
    var arr = alloc[_SchemaPtr](n).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(n):
        (arr + i).unsafe_write(_null_ptr[CArrowSchema, MutUntrackedOrigin]())
    return arr


def _release_array(arr_ptr: _ArrayPtr) -> None:
    """CArrowArray release callback. Walks children + dictionary, frees the
    heap THIS struct allocated (its buffers array; for the root, its
    children array + the heap-allocated child CArrowArray structs), DROPS the
    array's share of the buffer bytes, then sets `arr_ptr[].release = NULL`
    per the Arrow spec.

    ⚠ THIS IS WHAT MAKES THE EXPORT INDEPENDENT. The buffer bytes are not
    "borrowed from the stream" — an exported root carries a `_CArrayState` in
    `private_data` holding one `Column.share()` per column, i.e. one Arc
    reference per backing region. Destroying that state DECREMENTS; the bytes
    die only when the last holder — this array, its producing batch, or another
    exported chunk over the same batch — is gone. So releasing the STREAM
    cannot invalidate a chunk the consumer still holds, and releasing a CHUNK
    cannot invalidate the stream or its siblings, in either order.
    """
    if _is_null(arr_ptr):
        return
    ref a = arr_ptr[]
    if a.is_released():
        return
    # Children: walk + release + free the child structs (we heap-allocated
    # an array of n_children CArrowArray structs).
    if a.n_children > 0 and _non_null(a.children):
        var child_arr = a.children.bitcast[_ArrayPtr]()
        for i in range(Int(a.n_children)):
            var c = (child_arr + i)[]
            if _non_null(c):
                _release_array(c)
                c.free()
        a.children.free()
        a.children = _null_ptr[UnsafePointer[CArrowArray, MutUntrackedOrigin], MutUntrackedOrigin]()
    # Release the dictionary CArrowArray (if
    # non-NULL).  Recursive — `dictionary` itself owns a buffers array.
    if _non_null(a.dictionary):
        _release_array(a.dictionary)
        a.dictionary.free()
        a.dictionary = _null_ptr[CArrowArray, MutUntrackedOrigin]()
    # Buffers array (the void* slots, not the bytes they point at).
    if _non_null(a.buffers):
        a.buffers.free()
        a.buffers = _null_ptr[UnsafePointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin]()
    a.n_children = 0
    a.n_buffers = 0
    # THIS array's share of the buffer BYTES. Only a delivered root carries a
    # `_CArrayState`; children and dictionary arrays leave `private_data` NULL,
    # so this is a no-op for them and the whole tree's keepalive is the root's
    # (Column.share() is recursive). Dropping the state decrements one Arc per
    # column — it does not free bytes another holder still references. Done
    # LAST, after every read of `a`, and before `release` is nulled.
    if _non_null(a.private_data):
        var st = a.private_data.bitcast[_CArrayState]()
        st.unsafe_deinit_pointee()
        st.free()
        a.private_data = _null_ptr[NoneType, MutUntrackedOrigin]()
    # "Released structure": the spec REQUIRES the callback to null its own
    # `release` member. Arrow's C helpers abort() if it does not.
    a.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _release_schema(sch_ptr: _SchemaPtr) -> None:
    """CArrowSchema release callback. Frees format/name strings, walks +
    releases children, frees the heap-allocated child structs + children
    array, then NULLs `release` per the Arrow spec."""
    if _is_null(sch_ptr):
        return
    ref s = sch_ptr[]
    if _is_null(s.release):
        return
    if _non_null(s.format):
        s.format.free()
        s.format = _null_ptr[Int8, MutUntrackedOrigin]()
    if _non_null(s.name):
        s.name.free()
        s.name = _null_ptr[Int8, MutUntrackedOrigin]()
    if _non_null(s.metadata):
        s.metadata.free()
        s.metadata = _null_ptr[Int8, MutUntrackedOrigin]()
    if s.n_children > 0 and _non_null(s.children):
        var child_arr = s.children.bitcast[_SchemaPtr]()
        for i in range(Int(s.n_children)):
            var c = (child_arr + i)[]
            if _non_null(c):
                _release_schema(c)
                c.free()
        s.children.free()
        s.children = _null_ptr[UnsafePointer[CArrowSchema, MutUntrackedOrigin], MutUntrackedOrigin]()
    # Release the dictionary value-type schema
    # (if non-NULL).  Recursive.
    if _non_null(s.dictionary):
        _release_schema(s.dictionary)
        s.dictionary.free()
        s.dictionary = _null_ptr[CArrowSchema, MutUntrackedOrigin]()
    s.n_children = 0
    # "Released structure": the spec REQUIRES the callback to null its own
    # `release` member. Arrow's C helpers abort() if it does not.
    s.release = _null_ptr[NoneType, MutUntrackedOrigin]()


# --- Release-callback discipline ---------------------------------------------
#
# The in-tree `CArrowSchema` / `CArrowArray` / `CArrowArrayStream` declare
# `release` as `UnsafePointer[NoneType, MutExternalOrigin]` (a `void*`,
# predating Mojo fn-ptr fields). Per the Arrow C Data Interface contract, the
# CONSUMER calls `release(&struct)` exactly once, and the callback must free
# what the producer allocated and set `release = NULL` ("released structure").
#
# So the slot holds a REAL FUNCTION ADDRESS — `_release_array`,
# `_release_schema`, `_release_stream` — reinterpreted into the `void*`-typed
# field. Both are one machine word, so this is byte-for-byte what a C producer
# writes, and `((void(*)(ArrowArray*))a->release)(a)` on the consumer side
# lands in real code.
#
# ⛔ NOT A "LIVE MARKER". A non-NULL placeholder (e.g. a pointer to a one-byte
# heap allocation) satisfies every Mojo-side test (`release` non-NULL ⇒
# `is_released()` False) while guaranteeing that pyarrow, pandas, polars, or
# arrow-rs jump the program counter into a heap data byte: SIGBUS, PC at an
# unmapped heap address. Mojo spells the type `def (T) thin -> None`; the
# `release` slot of each of the three structs holds a `thin` fn pointer of
# that type, and the whole point of the C Data Interface is foreign consumers. Arrow's own C helpers
# additionally `abort()` when a release callback fails to null itself out,
# which a heap byte can never do. The release-callback-is-a-function-pointer
# unit test guards this.

# The spec's callback types, verbatim:
#     void (*release)(struct ArrowSchema*);
#     void (*release)(struct ArrowArray*);
#     void (*release)(struct ArrowArrayStream*);
# `thin` = non-capturing (no context word). These release slots keep the Mojo
# default calling convention, unlike the three `abi("C")` stream slots
# (`_GetSchemaFn`/`_GetNextFn`/`_GetLastErrorFn`). That is a deviation from
# what the spec declares and from the Mojo manual's rule that a function
# crossing the FFI boundary be `abi("C")`; Mojo documents no guarantee that
# its default convention matches C. It holds today by measurement, not by
# contract: the measured return-code skew came from the `raises` convention,
# and these slots do not raise (non-raising default-convention `get_schema`
# and `get_next` slots, which return `Int32`, were also measured to work with
# C callers and callees on linux-x86_64).
# Evidence that the release slots work across the seam: the RELEASE arm of
# the measurement block above
# `drain_c_abi_record_batch_stream`, and the dlopen gate of
# `:arrow_c_abi_probe`, which releases every exported and imported struct
# through these slots. VERIFIED against a real C caller,
# not assumed: a `cc`-compiled C function that casts the `void*` slot to
# `void (*)(struct*)` and calls it reaches the Mojo callback with the correct
# argument, and observes `release == NULL` on return — i.e. exactly the
# sequence pyarrow's C++ importer performs.
comptime _ArrayReleaseFn = def (_ArrayPtr) thin -> None
comptime _SchemaReleaseFn = def (_SchemaPtr) thin -> None
comptime _StreamReleaseFn = def (
    UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
) thin -> None


# ⚠ CONSUMER-SIDE DISPATCH DOES NOT LIVE HERE, AND THAT IS NOT A STYLE CHOICE.
# The obvious tidier shape — have `release_c_array` read the slot back into a
# fn-ptr and call THROUGH it, so our own tests exercise the same indirection a
# C consumer does — SEGFAULTS THE MOJO 1.0.0b2 COMPILER. Not the built binary:
# the compiler, during `MojoCompileExecutable` of any test that imports this
# module from the precompiled the core packages (`(Segmentation fault)`, no diagnostic).
# It is specifically an indirect call through a bitcast `def (T) thin -> None`
# made from a function elaborated OUT OF A precompiled package; the identical call
# compiles fine in test-local source. So `release_c_*` below calls the release
# function directly, and the falsifying test does the reinterpret-and-call
# itself. Do not "simplify" this back.

def _release_stream(
    stream_ptr: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
) -> None:
    """CArrowArrayStream release callback. Destroys + frees the producer-
    private `_CStreamState` (which owns the materialized batches' heap),
    re-points the three callbacks at the no-op stubs, then NULLs `release`
    per the Arrow spec. Idempotent."""
    if _is_null(stream_ptr):
        return
    ref st = stream_ptr[]
    if st.is_released():
        return
    if _non_null(st.private_data):
        var sp = st.private_data.bitcast[_CStreamState]()
        sp.unsafe_deinit_pointee()
        sp.free()
        st.private_data = _null_ptr[NoneType, MutUntrackedOrigin]()
    st.get_schema = _stub_get_schema
    st.get_next = _stub_get_next
    st.get_last_error = _stub_get_last_error
    # "Released structure": the spec REQUIRES the callback to null its own
    # `release` member. Arrow's C helpers abort() if it does not.
    st.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _release_array_entry(arr_ptr: _ArrayPtr) -> None:
    """Non-recursive entry trampoline whose ADDRESS goes in the `release` slot.

    `_release_array` is SELF-RECURSIVE (it walks children). Taking a recursive
    function's address here segfaults the Mojo compiler — not the binary,
    the compiler — while elaborating a consumer TU that lets an exported
    struct drop as a local (deterministic, no diagnostic). The one-hop
    trampoline is not decoration.
    """
    _release_array(arr_ptr)


def _release_schema_entry(sch_ptr: _SchemaPtr) -> None:
    """Non-recursive entry trampoline — see `_release_array_entry`."""
    _release_schema(sch_ptr)


def _set_array_release(mut a: CArrowArray):
    """Install the real release callback on `a.release`.

    # SAFETY: a `thin` fn-ptr and a `void*` are both one machine word; the C
    # Data Interface's `release` member IS a code pointer whose in-tree
    # declaration is `void*` only because the struct predates Mojo fn-ptr
    # fields. This reinterpret is the producer half of the ABI; the only
    # reader is the consumer, through the C ABI.
    """
    var f: _ArrayReleaseFn = _release_array_entry
    a.release = UnsafePointer(to=f).bitcast[OpaquePtr]()[]


def _set_schema_release(mut s: CArrowSchema):
    """Install the real release callback on `s.release`.

    # SAFETY: see `_set_array_release`.
    """
    var f: _SchemaReleaseFn = _release_schema_entry
    s.release = UnsafePointer(to=f).bitcast[OpaquePtr]()[]


def _set_stream_release(mut st: CArrowArrayStream):
    """Install the real release callback on `st.release`.

    # SAFETY: see `_set_array_release`.
    """
    var f: _StreamReleaseFn = _release_stream
    st.release = UnsafePointer(to=f).bitcast[OpaquePtr]()[]


# --- Public Mojo-side "call the release callback" helpers. ---
#
# These are the MOJO-side entry points; each calls its release function
# directly. A foreign consumer instead calls the `release` slot, which holds
# that same function's address — see the compiler-segfault note above for why
# the two paths are not unified, and
# `tests/test_c_data_release_callback_is_fn_ptr.mojo` for the test that
# covers the slot itself.
#
# ⛔ ALL THREE ARE THE PRODUCER HALF. CALL THEM ONLY ON A STRUCT THIS MODULE
# EXPORTED. Each frees heap by ASSUMING who allocated it — `buffers` /
# `children` from `_alloc_buffers_array` / `_alloc_array_ptr_array`,
# `format` / `name` / `metadata` from `_copy_string_to_c_int8`, `private_data`
# as a `_CArrayState` / `_CStreamState`. On a struct someone else filled in,
# every one of those assumptions is false and `private_data` is the worst of
# them: `destroy_pointee` runs a Mojo destructor over the foreign producer's
# private struct and then frees a block we do not own. For anything a foreign
# producer produced, use the `consumer_release_c_*` trio above. The
# foreign-release import unit test guards this for `drain_record_batch_stream`.

def release_c_array(arr_ptr: _ArrayPtr) -> None:
    """Invoke the release callback of a CArrowArray **exported by this module**
    (the Mojo-side equivalent of C's `array.release(&array)`). Recursive
    into children; NULLs `arr_ptr[].release` afterwards. Idempotent (safe
    on an already-released / zeroed struct).

    ⛔ NOT for a foreign-produced array — use `consumer_release_c_array`.
    """
    _release_array(arr_ptr)


def release_c_schema(sch_ptr: _SchemaPtr) -> None:
    """Invoke the release callback of a CArrowSchema **exported by this
    module**. Recursive into children; NULLs `sch_ptr[].release`. Idempotent.

    ⛔ NOT for a foreign-produced schema — use `consumer_release_c_schema`.
    """
    _release_schema(sch_ptr)


def release_c_stream(stream_ptr: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]) -> None:
    """Invoke the release callback of a CArrowArrayStream **exported by this
    module** (Mojo-side equivalent of C's `stream.release(&stream)`). Frees
    the `_CStreamState`, NULLs `stream_ptr[].release`. Idempotent.

    ⛔ NOT for a foreign-produced stream — use `consumer_release_c_stream`.
    """
    _release_stream(stream_ptr)


# =============================================================================
# CONSUMER-SIDE disposal — for structs we did NOT produce.
# =============================================================================
#
# ⚠ THE THREE `release_c_*` HELPERS ABOVE ARE THE PRODUCER HALF. THEY MUST NEVER
# RUN ON A FOREIGN STRUCT. `_release_array` / `_release_schema` /
# `_release_stream` free heap by ASSUMING who allocated it: `buffers` and
# `children` came from `_alloc_buffers_array` / `_alloc_array_ptr_array`,
# `format` / `name` / `metadata` from `_copy_string_to_c_int8`, and
# `private_data` is dereferenced AS a `_CArrayState`,
# destroyed, and freed. Every one of those is a lie about a struct pyarrow
# filled in, and the `private_data` one is the worst kind: `destroy_pointee`
# runs `Slab[Column[HeapRegion]]`'s destructor over the foreign producer's
# bytes, so a `List` length and data pointer are read out of whatever that
# producer's private struct happens to hold and then freed.
#
# `drain_record_batch_stream` is a CONSUMER. What the C Data Interface requires
# of a consumer is one sentence long: call the struct's OWN `release` member and
# do nothing else. That is what these do.
#
# ⚠ THE BITCAST-AND-CALL IS THE SHAPE THE MODULE NOTE ABOVE WARNS ABOUT, AND IT
# IS LOAD-BEARING HERE RATHER THAN COSMETIC. The note at "CONSUMER-SIDE DISPATCH
# DOES NOT LIVE HERE" rejected routing the PRODUCER helpers through the slot —
# a pure refactor, whose only benefit was that our own tests would exercise the
# indirection. This is not that. For a struct we did not produce there is no
# other callable: the producer's release address is reachable ONLY through the
# slot. It compiles and runs from inside the precompiled the core packages; if a future compiler regresses it, the fallback is
# to leak the foreign allocation, never to guess at its shape.


@always_inline
def _as_array_release_fn(p: OpaquePtr) -> _ArrayReleaseFn:
    """Reinterpret a `release` slot as `void (*)(struct ArrowArray*)`.

    # SAFETY: the consumer half of the C Data Interface ABI. The slot is
    # declared `void*` in the in-tree struct only because the struct predates
    # Mojo fn-ptr fields; per the spec it holds a function pointer, and both are
    # one machine word, so this is exactly what a C consumer's
    # `((void(*)(ArrowArray*))a->release)(a)` compiles to. Guarded by a non-null
    # check at every call site.
    """
    return UnsafePointer(to=p).bitcast[_ArrayReleaseFn]()[]


@always_inline
def _as_schema_release_fn(p: OpaquePtr) -> _SchemaReleaseFn:
    """Reinterpret a `release` slot as `void (*)(struct ArrowSchema*)`.

    # SAFETY: see `_as_array_release_fn`.
    """
    return UnsafePointer(to=p).bitcast[_SchemaReleaseFn]()[]


@always_inline
def _as_stream_release_fn(p: OpaquePtr) -> _StreamReleaseFn:
    """Reinterpret a `release` slot as `void (*)(struct ArrowArrayStream*)`.

    # SAFETY: see `_as_array_release_fn`.
    """
    return UnsafePointer(to=p).bitcast[_StreamReleaseFn]()[]


def consumer_release_c_array(arr_ptr: _ArrayPtr) -> None:
    """Dispose of a CArrowArray THIS MODULE DID NOT PRODUCE by calling its own
    `release` member, per the C Data Interface consumer contract.

    Use this — never `release_c_array` — on anything a foreign producer filled
    in. Idempotent: a NULL pointer or an already-released struct is a no-op, so
    it is safe on the end-of-stream sentinel `get_next` leaves behind.
    """
    if _is_null(arr_ptr):
        return
    ref a = arr_ptr[]
    if a.is_released():
        return
    _as_array_release_fn(a.release)(arr_ptr)


def consumer_release_c_schema(sch_ptr: _SchemaPtr) -> None:
    """Dispose of a foreign-produced CArrowSchema via its own `release`.
    See `consumer_release_c_array`."""
    if _is_null(sch_ptr):
        return
    ref s = sch_ptr[]
    if _is_null(s.release):
        return
    _as_schema_release_fn(s.release)(sch_ptr)


def consumer_release_c_stream(
    stream_ptr: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]
) -> None:
    """Dispose of a foreign-produced CArrowArrayStream via its own `release`.
    See `consumer_release_c_array`."""
    if _is_null(stream_ptr):
        return
    ref st = stream_ptr[]
    if st.is_released():
        return
    _as_stream_release_fn(st.release)(stream_ptr)


# =============================================================================
# Export: build a CArrowSchema for a Column / Schema.
# =============================================================================

def _build_column_schema(col: Column[HeapRegion], name: String, nullable: Bool) raises -> CArrowSchema:
    """Build a primitive/string CArrowSchema for a single Column."""
    # Validate type coverage early (raises UnsupportedArrowCABIType).
    _ = _arrow_type_n_buffers(col.arrow_type)
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(_column_format_string(col))
    s.name = _copy_string_to_c_int8(name)
    s.flags = ARROW_FLAG_NULLABLE if nullable else 0
    s.n_children = 0
    _set_schema_release(s)
    return s^


def _build_record_batch_schema_no_data(schema: Schema) raises -> CArrowSchema:
    """Build the root struct CArrowSchema (`+s` format) WITHOUT a sample
    RecordBatch (used only for empty streams with no nested columns).
    Fall-back for `_exported_get_schema`
    when `state.batches` is empty.
    """
    var ncols = schema.num_columns()
    var root = CArrowSchema()
    root.format = _copy_string_to_c_int8(String("+s"))
    root.name = _copy_string_to_c_int8(String(""))
    root.flags = 0
    root.n_children = Int64(ncols)
    if ncols > 0:
        var child_arr = _alloc_schema_ptr_array(ncols)
        for i in range(ncols):
            var arrow_t = schema.field_arrow_type(i)
            _ = _arrow_type_n_buffers(arrow_t)
            var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
            var field = schema.field_at(i)
            var built = _build_column_schema_from_field(field)
            cs.unsafe_write(built^)
            (child_arr + i).unsafe_write(cs)
        root.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
    _set_schema_release(root)
    return root^


def _build_record_batch_schema(schema: Schema, ref batch: RecordBatch) raises -> CArrowSchema:
    """Build the root struct CArrowSchema (`+s` format) with one child
    CArrowSchema per column.

    Takes the RecordBatch alongside the
    Schema, so that nested-type columns can drive their child format
    strings from the Column's actual child arrow_types (the Field's
    flat `_child_types` loses parameterization like Decimal128 (p,s)
    or Timestamp tz — the Column has the truth)."""
    var ncols = schema.num_columns()
    var root = CArrowSchema()
    root.format = _copy_string_to_c_int8(String("+s"))
    root.name = _copy_string_to_c_int8(String(""))
    root.flags = 0
    root.n_children = Int64(ncols)
    if ncols > 0:
        var child_arr = _alloc_schema_ptr_array(ncols)
        for i in range(ncols):
            var arrow_t = schema.field_arrow_type(i)
            # Validate per-column coverage; raises before we leak anything.
            _ = _arrow_type_n_buffers(arrow_t)
            var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
            # Field-driven export.  The Field
            # carries everything the format string + flags + metadata +
            # dictionary slot need; `Field.format_string()` is the source of
            # truth for the parent format string.
            var field = schema.field_at(i)
            ref col = batch.column_at(i)
            var built = _build_column_schema_from_field_and_column(field, col)
            cs.unsafe_write(built^)
            (child_arr + i).unsafe_write(cs)
        root.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
    _set_schema_release(root)
    return root^


def _build_column_schema_from_field(field: Field) raises -> CArrowSchema:
    """Build a CArrowSchema for a single column, driven by the Field's
    parameterized state.  Source of truth: `Field.format_string()` —
    which carries Decimal P/S, Timestamp tz, Union type-ids, and the dict
    INDEX type for the parent slot.

    Also populates (in addition to format + name + flags):
      * `metadata` — encoded via `encode_metadata` from the Field's kv list
        (NULL if no entries).
      * `flags` — Field's `_flags` OR'd with `ARROW_FLAG_NULLABLE` (derived
        from `nullable`).
      * `dictionary` — for DICTIONARY fields, a child CArrowSchema with the
        value type (current storage: STRING / "u").
    """
    var s = CArrowSchema()
    var fmt = field.format_string()
    if fmt == "n" and field.arrow_type != ArrowType.NULL:
        raise _unsupported(field.arrow_type, "export")
    s.format = _copy_string_to_c_int8(fmt)
    s.name = _copy_string_to_c_int8(field.name)
    # Compose flag bits.
    var bits = field._flags
    if field.nullable:
        bits = bits | ARROW_FLAG_NULLABLE
    else:
        # Make sure the nullable bit is cleared when the Field says non-null.
        bits = bits & (~ARROW_FLAG_NULLABLE)
    s.flags = bits
    s.n_children = 0
    # Pack metadata kv-list (if any).
    if field.metadata_count() > 0:
        # The Field's kv-list is a value type; copy out for encode_metadata.
        var keys = List[String]()
        var values = List[String]()
        for i in range(field.metadata_count()):
            keys.append(field._metadata_keys[i])
            values.append(field._metadata_values[i])
        s.metadata = encode_metadata(keys^, values^)
    # Dictionary value-type child schema.
    if field.arrow_type == ArrowType.DICTIONARY:
        var dict_s = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        var built_value = _build_dictionary_value_schema(field)
        dict_s.unsafe_write(built_value^)
        s.dictionary = dict_s
    _set_schema_release(s)
    return s^


def _build_column_schema_from_column(ref col: Column[HeapRegion], name: String, nullable: Bool) raises -> CArrowSchema:
    """Build a CArrowSchema purely from a Column[HeapRegion] (no Field). Used to emit
    CHILD schemas for nested types (LIST item / STRUCT field / MAP entries
    + key/value), where Field's flat `_child_types` would lose
    parameterization.

    For each child Column, we drive the format string from
    `_column_format_string(col)` (which handles Decimal128 (p,s),
    Decimal256 (p,s), and all primitive/string/binary/dict format
    strings) and recurse into nested children for LIST/STRUCT/MAP.
    """
    var t = col.arrow_type
    _ = _arrow_type_n_buffers(t)  # validate coverage
    var s = CArrowSchema()
    var fmt = _column_format_string(col)
    s.format = _copy_string_to_c_int8(fmt)
    s.name = _copy_string_to_c_int8(name)
    s.flags = ARROW_FLAG_NULLABLE if nullable else 0
    s.n_children = 0
    # Recurse into children for nested types.
    if t == ArrowType.LIST:
        if col.num_children() != 1:
            raise Error(
                "ArrowCStream(export): LIST column must have 1 child, got "
                + String(col.num_children())
            )
        var child_arr = _alloc_schema_ptr_array(1)
        var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        # Arrow spec: list child is named "item" by default (PyArrow's
        # convention).  This uses the default; custom child names could be
        # plumbed via Column._field_names[0] if set.
        var item_name = String("item")
        if col.num_children() == 1 and len(col._field_names) >= 1 and col._field_names[0] != "":
            item_name = col._field_names[0]
        ref kid = col.child_at(0)
        var built = _build_column_schema_from_column(kid, item_name, True)
        cs.unsafe_write(built^)
        (child_arr + 0).unsafe_write(cs)
        s.n_children = 1
        s.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
    elif t == ArrowType.STRUCT:
        var nchild = col.num_children()
        s.n_children = Int64(nchild)
        if nchild > 0:
            var child_arr = _alloc_schema_ptr_array(nchild)
            for i in range(nchild):
                ref kid = col.child_at(i)
                var cname = String("f") + String(i)
                if i < len(col._field_names) and col._field_names[i] != "":
                    cname = col._field_names[i]
                var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
                var built = _build_column_schema_from_column(kid, cname, True)
                cs.unsafe_write(built^)
                (child_arr + i).unsafe_write(cs)
            s.children = child_arr.bitcast[
                UnsafePointer[CArrowSchema, MutUntrackedOrigin]
            ]()
    elif t == ArrowType.MAP:
        # MAP child = entries Struct<key, value>. The struct child is named
        # "entries" by spec convention; the inner struct fields are
        # "key" and "value".
        if col.num_children() != 1:
            raise Error(
                "ArrowCStream(export): MAP column must have 1 entries"
                " child, got " + String(col.num_children())
            )
        var child_arr = _alloc_schema_ptr_array(1)
        var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        ref kid = col.child_at(0)
        if kid.arrow_type != ArrowType.STRUCT:
            raise Error(
                "ArrowCStream(export): MAP entries child must be STRUCT,"
                " got " + String(kid.arrow_type)
            )
        var entries_name = String("entries")
        var built = _build_column_schema_from_column(kid, entries_name, False)
        cs.unsafe_write(built^)
        (child_arr + 0).unsafe_write(cs)
        s.n_children = 1
        s.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
        # Honor keys_sorted on MAP.
        if col.keys_sorted():
            s.flags = s.flags | ARROW_FLAG_MAP_KEYS_SORTED
    elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
        # Union with N child schemas.  Child
        # names default to "f0", "f1", ...; `col._field_names` is consulted
        # if present (parallel to `_children`).
        var nchild = col.num_children()
        s.n_children = Int64(nchild)
        if nchild > 0:
            var u_child_arr = _alloc_schema_ptr_array(nchild)
            for i in range(nchild):
                ref kid_u = col.child_at(i)
                var cname_u = String("f") + String(i)
                if i < len(col._field_names) and col._field_names[i] != "":
                    cname_u = col._field_names[i]
                var cs_u = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
                var built_u = _build_column_schema_from_column(kid_u, cname_u, True)
                cs_u.unsafe_write(built_u^)
                (u_child_arr + i).unsafe_write(cs_u)
            s.children = u_child_arr.bitcast[
                UnsafePointer[CArrowSchema, MutUntrackedOrigin]
            ]()
    _set_schema_release(s)
    return s^


def _build_column_schema_from_field_and_column(field: Field, ref col: Column[HeapRegion]) raises -> CArrowSchema:
    """Build a CArrowSchema for a column, using both the Field (for
    name/flags/metadata/dictionary) and the Column (for nested-type
    child recursion).

    For non-nested types, behaves identically to
    `_build_column_schema_from_field`.  For nested LIST/STRUCT/MAP,
    recurses into the Column's children to emit child CArrowSchemas
    that preserve Decimal128 (p,s), Timestamp tz, and other
    parameterized child type info.
    """
    var s = CArrowSchema()
    var fmt = field.format_string()
    if fmt == "n" and field.arrow_type != ArrowType.NULL:
        raise _unsupported(field.arrow_type, "export")
    s.format = _copy_string_to_c_int8(fmt)
    s.name = _copy_string_to_c_int8(field.name)
    var bits = field._flags
    if field.nullable:
        bits = bits | ARROW_FLAG_NULLABLE
    else:
        bits = bits & (~ARROW_FLAG_NULLABLE)
    # Honor MAP keys_sorted from the Column too (not only the Field flag).
    if field.arrow_type == ArrowType.MAP and col.keys_sorted():
        bits = bits | ARROW_FLAG_MAP_KEYS_SORTED
    s.flags = bits
    s.n_children = 0
    if field.metadata_count() > 0:
        var keys = List[String]()
        var values = List[String]()
        for i in range(field.metadata_count()):
            keys.append(field._metadata_keys[i])
            values.append(field._metadata_values[i])
        s.metadata = encode_metadata(keys^, values^)
    if field.arrow_type == ArrowType.DICTIONARY:
        var dict_s = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        var built_value = _build_dictionary_value_schema(field)
        dict_s.unsafe_write(built_value^)
        s.dictionary = dict_s
    # Nested child recursion.
    if field.arrow_type == ArrowType.LIST:
        if col.num_children() != 1:
            raise Error(
                "ArrowCStream(export): LIST column must have 1 child, got "
                + String(col.num_children())
            )
        var child_arr = _alloc_schema_ptr_array(1)
        var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        ref kid = col.child_at(0)
        var item_name = String("item")
        if len(col._field_names) >= 1 and col._field_names[0] != "":
            item_name = col._field_names[0]
        var built = _build_column_schema_from_column(kid, item_name, True)
        cs.unsafe_write(built^)
        (child_arr + 0).unsafe_write(cs)
        s.n_children = 1
        s.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
    elif field.arrow_type == ArrowType.STRUCT:
        var nchild = col.num_children()
        s.n_children = Int64(nchild)
        if nchild > 0:
            var child_arr = _alloc_schema_ptr_array(nchild)
            for i in range(nchild):
                ref kid = col.child_at(i)
                var cname = String("f") + String(i)
                if i < len(col._field_names) and col._field_names[i] != "":
                    cname = col._field_names[i]
                var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
                var built = _build_column_schema_from_column(kid, cname, True)
                cs.unsafe_write(built^)
                (child_arr + i).unsafe_write(cs)
            s.children = child_arr.bitcast[
                UnsafePointer[CArrowSchema, MutUntrackedOrigin]
            ]()
    elif field.arrow_type == ArrowType.MAP:
        if col.num_children() != 1:
            raise Error(
                "ArrowCStream(export): MAP column must have 1 entries"
                " child, got " + String(col.num_children())
            )
        var child_arr = _alloc_schema_ptr_array(1)
        var cs = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
        ref kid = col.child_at(0)
        if kid.arrow_type != ArrowType.STRUCT:
            raise Error(
                "ArrowCStream(export): MAP entries child must be STRUCT,"
                " got " + String(kid.arrow_type)
            )
        var built = _build_column_schema_from_column(kid, String("entries"), False)
        cs.unsafe_write(built^)
        (child_arr + 0).unsafe_write(cs)
        s.n_children = 1
        s.children = child_arr.bitcast[
            UnsafePointer[CArrowSchema, MutUntrackedOrigin]
        ]()
    elif (
        field.arrow_type == ArrowType.UNION_SPARSE
        or field.arrow_type == ArrowType.UNION_DENSE
    ):
        # Union with N child schemas, driven
        # by the Field (for the parent format string + names) and the
        # Column (for child type recursion).  The Field's format_string()
        # already encodes `+us:I,J,...` / `+ud:I,J,...` via the
        # `_union_type_ids` slot.
        var nchild = col.num_children()
        s.n_children = Int64(nchild)
        if nchild > 0:
            var u_child_arr = _alloc_schema_ptr_array(nchild)
            for i in range(nchild):
                ref kid_u = col.child_at(i)
                var cname_u = String("f") + String(i)
                if i < len(col._field_names) and col._field_names[i] != "":
                    cname_u = col._field_names[i]
                var cs_u = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
                var built_u = _build_column_schema_from_column(kid_u, cname_u, True)
                cs_u.unsafe_write(built_u^)
                (u_child_arr + i).unsafe_write(cs_u)
            s.children = u_child_arr.bitcast[
                UnsafePointer[CArrowSchema, MutUntrackedOrigin]
            ]()
    _set_schema_release(s)
    return s^


def _build_dictionary_value_schema(field: Field) raises -> CArrowSchema:
    """Build the value-type CArrowSchema attached to a DICTIONARY parent's
    `dictionary` slot.  Current storage is STRING / "u" (matches
    `StringDictionaryArray`).  Other value types (Int*, FixedSizeBinary,
    ...) are not wired. The child carries no
    metadata of its own and is always nullable (matches PyArrow default).

    """
    var s = CArrowSchema()
    s.format = _copy_string_to_c_int8(String("u"))
    s.name = _copy_string_to_c_int8(String(""))
    s.flags = ARROW_FLAG_NULLABLE
    s.n_children = 0
    _set_schema_release(s)
    return s^


# =============================================================================
# Export: build a CArrowArray for a Column / RecordBatch.
# =============================================================================

def _build_column_array(ref col: Column[HeapRegion]) raises -> CArrowArray:
    """Build a primitive/string CArrowArray for a single Column.

    ⚠ INTERNAL BUILDER — IT DOES NOT ESTABLISH OWNERSHIP, ITS CALLER DOES.
    The buffer `void*` slots point INTO `col`'s `SharedAlignedBuffer` bytes, so
    the RESULT IS ONLY AS ALIVE AS `col`. Nothing here retains anything.

    The one caller that hands a result to a consumer —
    `_build_record_batch_array` — satisfies that by passing a `Column.share()`
    it has already moved into the exported root's `_CArrayState`, so the bytes
    outlive the export by construction. It recurses (children, dictionary) on
    that same shared column, and `share()` is recursive, so every array in the
    tree points into storage the root's state references. Do NOT call this with
    a borrowed column and hand the result across the C ABI: that is a
    use-after-free, where releasing the stream turns element 0 of every buffer
    into a freelist pointer.
    """
    var t = col.arrow_type
    var nb = _arrow_type_n_buffers(t)
    var is_var_len = (
        t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    )
    var is_nested = (
        t == ArrowType.LIST
        or t == ArrowType.STRUCT
        or t == ArrowType.MAP
    )
    # Unions have N child columns and NO
    # validity bitmap of their own (Arrow spec).  Treated as "nested" for
    # the children-recursion path below, but distinguished here because
    # the buffer-slot layout differs: buffers[0] is the TYPES buffer
    # (not validity), and the dense union additionally has buffers[1]
    # for the Int32 offsets.
    var is_union = (
        t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE
    )
    if col.offset() != 0 and is_var_len:
        # Variable-length offsets are absolute; a non-zero logical offset
        # would need an offsets-buffer rewrite. Materialized batches are
        # offset-0, so this is not a hot path.
        raise Error(
            "UnsupportedArrowCABIType: variable-length Column[HeapRegion] with non-zero"
            " logical offset (type=" + String(t) + ", offset="
            + String(col.offset()) + ") — not supported"
        )
    if col.offset() != 0 and is_nested:
        # Same caveat for nested offsets.
        raise Error(
            "UnsupportedArrowCABIType: nested Column[HeapRegion] with non-zero"
            " logical offset (type=" + String(t) + ", offset="
            + String(col.offset()) + ") — not supported"
        )
    if col.offset() != 0 and is_union:
        # Union slices are layout-dependent (sparse vs dense reslice
        # differently); deferred.
        raise Error(
            "UnsupportedArrowCABIType: union Column[HeapRegion] with non-zero"
            " logical offset (type=" + String(t) + ", offset="
            + String(col.offset()) + ") — not supported"
        )
    var a = CArrowArray()
    a.length = Int64(col.length())
    a.null_count = Int64(col.null_count())
    a.offset = Int64(col.offset())
    a.n_buffers = Int64(nb)
    a.n_children = 0
    var bufs = _alloc_buffers_array(nb)
    # Unions have NO validity bitmap (Arrow
    # spec).  buffers[0] is the TYPES buffer; buffers[1] (dense only) is
    # the OFFSETS buffer.  All other types put validity at buffers[0].
    # FFI-CARVE-OUT: buffers are reached through
    # `view_ro() + view._unsafe_ptr()` (never a wildcard-shim accessor on
    # the holder buffer). The 4-cast chain below preserves
    # the wildcard receiver semantics required by the Arrow C ABI buffer
    # array slot:
    #   1. `view_ro()` → `ByteView[origin]` tied to the holder buffer
    #   2. `._unsafe_ptr()` → `UnsafePointer[UInt8, origin]`
    #   3. `.bitcast[NoneType]()` preserves origin
    #   4. `.unsafe_mut_cast[True]()` flips immut→mut
    #   5. `.unsafe_origin_cast[MutExternalOrigin]()` widens origin to
    #      satisfy the FFI receiver — the C consumer's lifetime contract
    #      (release callback) replaces compile-time origin tracking at
    #      the FFI boundary. File-level FFI carve-out.
    # `SharedAlignedBuffer[K]` exposes view_ro/view_mut with the
    # same `ByteView[origin]` shape.
    if is_union:
        # buffers[0] = types buffer (Int8) from col._data.
        var types_view = col._data.view_ro()
        var types_ptr = types_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 0).unsafe_write(types_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
        # Dense: buffers[1] = offsets buffer (Int32) from col._offsets.
        if t == ArrowType.UNION_DENSE and col._offsets:
            var off_view = col._offsets.value().view_ro()
            var off_ptr = off_view._unsafe_ptr().bitcast[
                NoneType
            ]().unsafe_mut_cast[True]()
            (bufs + 1).unsafe_write(off_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    else:
        # buffers[0] = validity bitmap (NULL if no nulls).
        if col._validity:
            var bm_view = col._validity.value().buffer.view_ro()
            var bm_ptr = bm_view._unsafe_ptr().bitcast[
                NoneType
            ]().unsafe_mut_cast[True]()
            (bufs + 0).unsafe_write(bm_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
        # else: leave NULL (already zero-init'd).
    if is_var_len:
        # buffers[1] = offsets (i32 for STRING/BINARY, i64 for
        # LARGE_STRING/LARGE_BINARY); buffers[2] = data bytes (utf8 or raw).
        # Same physical shape, different
        # offset width — carried by the format string (`u`/`z`/`U`/`Z`).
        # See FFI-CARVE-OUT block above for the
        # view_ro chain rationale.
        if col._offsets:
            var off_view = col._offsets.value().view_ro()
            var off_ptr = off_view._unsafe_ptr().bitcast[
                NoneType
            ]().unsafe_mut_cast[True]()
            (bufs + 1).unsafe_write(off_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
        var data_view = col._data.view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 2).unsafe_write(data_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    elif t == ArrowType.DICTIONARY:
        # Dictionary array.
        # buffers[1] = i32 indices buffer (from col._data).
        var idx_view = col._data.view_ro()
        var idx_ptr = idx_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 1).unsafe_write(idx_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    elif t == ArrowType.LIST or t == ArrowType.MAP:
        # LIST / MAP — buffers[1] = i32 offsets.
        # No data buffer at this level (children carry the values).
        if col._offsets:
            var off_view = col._offsets.value().view_ro()
            var off_ptr = off_view._unsafe_ptr().bitcast[
                NoneType
            ]().unsafe_mut_cast[True]()
            (bufs + 1).unsafe_write(off_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    elif t == ArrowType.STRUCT:
        # STRUCT — only validity at this level.
        # No buffers[1].
        pass
    elif is_union:
        # Union buffers already handled above
        # (types at bufs[0], dense offsets at bufs[1]).  No data buffer at
        # this level — children carry the values.
        pass
    else:
        var data_view = col._data.view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 1).unsafe_write(data_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    a.buffers = bufs
    # Build the dictionary value-type child
    # CArrowArray (STRING with the dict offsets + bytes).  Attached to
    # `a.dictionary` so the consumer can reach the values array.
    if t == ArrowType.DICTIONARY:
        var dict_a = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
        var built_values = _build_dictionary_values_array(col)
        dict_a.unsafe_write(built_values^)
        a.dictionary = dict_a
    # Recurse on children for LIST / STRUCT /
    # MAP. Each child Column gets its own CArrowArray (heap-allocated) in
    # the parent's `children` slot. `_release_array` walks + frees them.
    # Unions also recurse on N children.
    if is_nested or is_union:
        var nchild = col.num_children()
        a.n_children = Int64(nchild)
        if nchild > 0:
            var child_arr = _alloc_array_ptr_array(nchild)
            for i in range(nchild):
                ref kid = col.child_at(i)
                var ca = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
                var built = _build_column_array(kid)
                ca.unsafe_write(built^)
                (child_arr + i).unsafe_write(ca)
            a.children = child_arr.bitcast[
                UnsafePointer[CArrowArray, MutUntrackedOrigin]
            ]()
    _set_array_release(a)
    return a^


def _build_dictionary_values_array(ref col: Column[HeapRegion]) raises -> CArrowArray:
    """Build a STRING CArrowArray pointing at the dictionary values stored
    in `col._offsets` (dict_size+1 offsets) + `col._dict_data` (utf8 bytes).
    Matches the `StringDictionaryArray` storage used for DICTIONARY
    columns.  3 buffers: validity (NULL — dict values are non-null),
    i32 offsets, utf8 bytes.
    """
    var a = CArrowArray()
    a.length = Int64(col._dict_size)
    a.null_count = 0
    a.offset = 0
    a.n_buffers = 3
    a.n_children = 0
    var bufs = _alloc_buffers_array(3)
    # buffers[0] = validity (NULL — no nulls in the value table)
    # buffers[1] = i32 offsets
    # Via `view_ro() + view._unsafe_ptr()`, as in `_build_column_array`
    # above. FFI-carve-out file; see header.
    if col._offsets:
        var off_view = col._offsets.value().view_ro()
        var off_ptr = off_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 1).unsafe_write(off_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    # buffers[2] = utf8 data
    if col._dict_data:
        var data_view = col._dict_data.value().view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]()
        (bufs + 2).unsafe_write(data_ptr.unsafe_origin_cast[MutUntrackedOrigin]())
    a.buffers = bufs
    _set_array_release(a)
    return a^


def _build_record_batch_array(ref batch: RecordBatch) raises -> CArrowArray:
    """Build the root struct CArrowArray with one child CArrowArray per
    Column. The root struct array itself carries only a (NULL) validity
    buffer slot (n_buffers == 1, the struct-layout convention).

    ⚠ THE RESULT DOES NOT DEPEND ON `batch` OUTLIVING IT, AND THAT IS THE
    WHOLE POINT. This is the ONE place a delivered export is made independent:
    every column is `share()`d first, the shares are moved into a heap
    `_CArrayState` hung off `root.private_data`, and the buffer pointers are
    read out of THOSE shared columns. `batch` may then die — including via
    `release_c_stream` destroying the `_CStreamState` that owns it — with the
    exported array still fully readable, which is what the Arrow C data
    interface requires and what pyarrow's `read_all()` + drop-the-reader does
    on every call. `share()` is an Arc refcount bump per backing region, not a
    byte copy: the export stays zero-copy.

    Cost per delivered chunk: one Slab of N `Column` structs plus one refcount
    increment per buffer. No `memcpy` of column data, at any width.
    """
    var ncols = batch.num_columns()

    # STEP 1 — take the shares BEFORE any pointer is read out of a column, so
    # there is no window in which the export points at bytes it does not hold a
    # reference to. `Column.share()` recurses into children / validity /
    # offsets / dictionary bytes, so ONE share per top-level column covers the
    # entire exported tree beneath it.
    var shared = Slab[Column[HeapRegion]].with_capacity(ncols if ncols > 0 else 1)
    for i in range(ncols):
        shared.append(batch.column_at(i).share())

    var root = CArrowArray()
    root.length = Int64(batch.num_rows())
    root.null_count = 0
    root.offset = 0
    # Struct array: 1 buffer (validity), which we leave NULL (no nulls).
    root.n_buffers = 1
    root.n_children = Int64(ncols)

    # STEP 2 — build each child FROM THE SHARED COLUMN, never from `batch`'s.
    # The two alias the same bytes, so the pointer VALUES are identical; taking
    # them from the share is what makes the ownership structural rather than
    # incidental, and keeps the invariant checkable by reading this function.
    var child_arr = _alloc_array_ptr_array(ncols)
    var built_n = 0
    try:
        for i in range(ncols):
            var ca = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
            var built = _build_column_array(shared[i])
            ca.unsafe_write(built^)
            (child_arr + i).unsafe_write(ca)
            built_n += 1
    except e:
        # Unwind: there is no CArrowArray carrying a release callback yet, so
        # a raise here would otherwise leak the children built so far. The
        # shares in `shared` are dropped by its own destructor. `_exported_
        # get_next` turns this raise into EIO and the consumer may retry, so
        # the leak would repeat rather than happen once.
        for j in range(built_n):
            var c = (child_arr + j)[]
            if _non_null(c):
                _release_array(c)
                c.free()
        child_arr.free()
        raise e^
    # A zero-column batch leaves `children` NULL: `_alloc_array_ptr_array(0)`
    # returns NULL, so there is nothing to attach and nothing to free.
    if ncols > 0:
        root.children = child_arr.bitcast[
            UnsafePointer[CArrowArray, MutUntrackedOrigin]
        ]()
    root.buffers = _alloc_buffers_array(1)

    # STEP 3 — hand the shares to the array itself. From here the consumer's
    # `release` call is what drops them, and nothing else can.
    var state = alloc[_CArrayState](1).unsafe_origin_cast[MutUntrackedOrigin]()
    state.unsafe_write(_CArrayState(shared^))
    root.private_data = state.bitcast[NoneType]()
    _set_array_release(root)
    return root^


# =============================================================================
# Import: CArrowArray child + ArrowType -> Column (copies buffer bytes).
# =============================================================================
#
# ⚠ A NULL BUFFER POINTER IS NOT "SKIP THE MEMCPY". A buffer read of the shape
#
#     var buf = OwnedAlignedBuffer(max(n_bytes, 1))
#     if _non_null(bufs) and _non_null((bufs + i)[]):
#         memcpy(dest=..., src=..., count=n_bytes)
#     buf.set_length(n_bytes)
#
# — i.e. an absent buffer means "don't copy", and then `set_length` publishes
# `n_bytes` anyway. `OwnedAlignedBuffer.__init__` zeroes only its SIMD
# tail-pad (`bytes.resize(unsafe_uninit_length=raw_size)`), so those bytes are
# WHATEVER THE ALLOCATOR LAST LEFT THERE: on a length-0 string column
# `offsets[0]` is allocator residue, and `concat.mojo` copies offsets[0] into
# the merged column verbatim.
#
# The spec is narrow about when NULL is permitted, and neither situation is
# implied by the pointer being NULL:
#
#     "The buffer pointers MAY be null only in two situations: (1) for the null
#      bitmap buffer, if ArrowArray.null_count is 0; (2) for any buffer
#      (including variadic buffers), if the size in bytes of the corresponding
#      buffer would be 0."
#
# So there are exactly two correct responses, and `_require_c_buffer` /
# `OwnedAlignedBuffer.zero()` below are them: REFUSE when the producer omitted
# a buffer the spec obliged it to supply, and ZERO when it legitimately omitted
# an empty one. Falsifier:
# `tests/test_arrow_c_data_null_buffer_semantics.mojo`.


def _require_c_buffer(
    p: OpaquePtr, needed_bytes: Int, which: String, arrow_t: ArrowType
) raises:
    """Refuse a NULL `buffers[i]` that the Arrow C Data Interface does not
    permit — spec situation (2), the size-would-be-zero allowance.

    `needed_bytes` is the size the buffer WOULD have, computed from the array's
    own declared length. Callers pass 0 for the cases the spec does permit, so
    this only fires on a genuine violation. Situation (1) — the validity bitmap
    against `null_count` — is checked separately, where `null_count` is in
    scope.

    This is the same check arrow-cpp performs in `ValidateArray`; a producer
    that trips it would be rejected by pyarrow too.
    """
    if needed_bytes > 0 and _is_null(p):
        raise Error(
            "from_arrow_c_stream: array of type '"
            + String(arrow_t)
            + "' has a NULL "
            + which
            + " buffer, but that buffer's size would be "
            + String(needed_bytes)
            + " bytes — the Arrow C Data Interface permits a NULL buffer"
            + " pointer only when the buffer's size would be 0 (or, for the"
            + " validity bitmap, when null_count is 0)"
        )


@always_inline
def _c_buffer_at(
    bufs: UnsafePointer[OpaquePtr, MutUntrackedOrigin], i: Int
) -> OpaquePtr:
    """`buffers[i]`, or NULL when the buffers array itself is NULL.

    Collapses the two-step `_non_null(bufs) and _non_null((bufs + i)[])` guard
    into one value so a caller can hand the result to `_require_c_buffer` and
    get the spec's answer instead of writing the test again.

    # SAFETY: FFI boundary. `bufs` is the producer's `void**`; the read is
    # guarded by the NULL test on the array itself, and `i < n_buffers` is
    # established by the `n_buffers` equality check at the top of
    # `_import_column`.
    """
    if _is_null(bufs):
        return _null_ptr[NoneType, MutUntrackedOrigin]()
    return (bufs + i)[]


def _import_column(
    ref carray: CArrowArray,
    arrow_t: ArrowType,
    precision: Int = 0,
    scale: Int = 0,
    sch_ptr: _SchemaPtr = _null_ptr[CArrowSchema, MutUntrackedOrigin](),
    keys_sorted: Bool = False,
    union_type_ids: List[Int] = List[Int](),
) raises -> Column[HeapRegion]:
    """Reconstruct a Mojo Column[HeapRegion] from a child CArrowArray. Copies all
    buffer bytes (we do not retain pointers into foreign memory). Raises
    `UnsupportedArrowCABIType` for types outside the supported subset.

    For DECIMAL128, `(precision, scale)` come from the schema's `d:P,S`
    format string and are stamped onto the resulting Column.

    When `sch_ptr` is non-NULL AND `arrow_t`
    is LIST/STRUCT/MAP, the function recursively imports child Columns
    using the matching child CArrowSchemas from `sch_ptr[].children`.
    `keys_sorted` is honored for MAP (mirrors
    ARROW_FLAG_MAP_KEYS_SORTED on the parent CArrowSchema).
    """
    var nb = _arrow_type_n_buffers(arrow_t)
    if Int(carray.n_buffers) != nb:
        raise Error(
            "from_arrow_c_stream: child array for type '" + String(arrow_t)
            + "' has " + String(Int(carray.n_buffers)) + " buffers, expected "
            + String(nb)
        )
    if carray.offset != 0:
        raise Error(
            "from_arrow_c_stream: child array with non-zero offset ("
            + String(Int(carray.offset)) + ") — not supported"
        )
    var length = Int(carray.length)
    var declared_null_count = Int(carray.null_count)
    var null_count = declared_null_count
    if null_count < 0:
        # -1 == "not yet computed". PROVISIONAL ONLY: if a validity bitmap
        # turns up below, this is REPLACED by the bitmap's own popcount.
        # ⚠ DO NOT SHORT-CIRCUIT THIS TO 0 — see the block at `validity =`.
        null_count = 0

    # buffers array as void**.
    var bufs = carray.buffers

    # --- validity bitmap (buffers[0]) ---
    # Unions have NO validity bitmap (Arrow
    # spec) — `bufs[0]` is the TYPES buffer for unions, not validity.
    # Skip the validity-read in that case.
    var is_union_t = (
        arrow_t == ArrowType.UNION_SPARSE
        or arrow_t == ArrowType.UNION_DENSE
    )
    var validity_p = _c_buffer_at(bufs, 0)
    # Spec situation (1): `buffers[0]` MAY be NULL only if `null_count` is 0.
    # `declared_null_count` and not `null_count`, because -1 means "not yet
    # computed" — an honest absence of information, not a claim of N nulls —
    # and a producer using it is entitled to omit the bitmap.
    #
    # ⚠ WITHOUT THIS THE COUNT AND THE BITMAP DISAGREE AND NOTHING SAYS SO.
    # `null_count` is copied from the struct verbatim a few lines up, so a
    # producer declaring 2 nulls with no bitmap yielded a Column asserting
    # `null_count == 2` while every row read back valid — the nulls existed in
    # the count and nowhere else. Silent, and wrong in the direction that turns
    # missing data into data.
    if (not is_union_t) and declared_null_count > 0 and _is_null(validity_p):
        raise Error(
            "from_arrow_c_stream: array of type '"
            + String(arrow_t)
            + "' declares null_count="
            + String(declared_null_count)
            + " but its validity bitmap buffer is NULL — the Arrow C Data"
            + " Interface permits a NULL validity buffer only when null_count"
            + " is 0"
        )
    var validity = Optional[Bitmap[HeapRegion]](None)
    if (not is_union_t) and _non_null(validity_p):
        var bm_src = validity_p.bitcast[UInt8]()
        var bm_bytes = (length + 7) >> 3
        var bm = Bitmap.create(length)
        if bm_bytes > 0:
            # Migrate memcpy DEST off
            # `_unsafe_data_ptr()` wildcard-shim onto `view_mut() +
            # view._unsafe_ptr()`. `view_mut()` returns a
            # `ByteView[origin]` whose origin is mut + tied to the
            # buffer's lifetime; `_unsafe_ptr()` extracts the typed
            # UInt8 pointer. memcpy resolves on independent origin
            # parameters for dest vs src, so the dest does NOT require
            # the wildcard widening that the FFI-supplied src does.
            var bm_view = bm.buffer.view_mut()
            unsafe_memcpy(
                dest=bm_view._unsafe_ptr(),
                src=bm_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=bm_bytes,
            )
            bm.buffer.set_length(bm_bytes)

            # --- CANONICALISE THE PADDING BITS OF THE LAST BYTE ---
            # The Arrow columnar spec leaves the bits past `length` in the
            # final validity byte UNDEFINED, and the memcpy above copied the
            # producer's verbatim. Every counter in this repo — `popcount`,
            # `null_count`, `all_valid` — counts whole BYTES, so a producer
            # that left `0xFF` padding on a 3-row column makes `popcount()`
            # report 8 valid out of 3. `Bitmap.create` zeroed these bytes and
            # our own kernels (`and_` / `and_not`) promise canonical 0 past
            # `length`; the memcpy is the one place that promise is broken, so
            # it is restored here, at the boundary, once. At most 7 bits.
            for pad in range(length, bm_bytes << 3):
                bm.clear(pad)

        # =====================================================================
        # ⛔ THE BITMAP IS GROUND TRUTH. `null_count` IS A CACHE, AND AN
        #    IMPORTED CACHE IS A CLAIM BY A STRANGER.
        # =====================================================================
        #
        # THE INVARIANT THIS ONE LINE ESTABLISHES, and the reason it is
        # unconditional rather than special-cased: *after this block, whenever
        # a Column carries a validity bitmap, its `null_count` IS that
        # bitmap's popcount.* That is checkable by reading two lines. The
        # alternative — recompute only in the case we happen to have a bug
        # report for — leaves the field a maybe-lie, and every downstream
        # reader then has to know WHICH producers it can believe.
        #
        # THE REPORTED DEFECT (the `-1` direction). `declared_null_count < 0`
        # is the spec's legal "not yet computed" — a common value, not an
        # exotic one; pyarrow computes lazily and exports -1. The provisional
        # coercion to 0 at the top of this function published a Column
        # asserting `null_count == 0` over a bitmap with real NULLs in it.
        # The sibling check above already refuses the OPPOSITE lie
        # (`declared > 0` with NO bitmap); this is its missing mirror. A
        # producer declaring `0` while its bitmap holds NULLs is the same
        # falsehood a third way, and the same line covers it.
        #
        # ⚠ WHY A CACHED NUMBER DISAGREEING WITH ITS BITMAP IS A WRONG ANSWER
        # AND NOT A COSMETIC FIELD. `Column.null_count` is a plain mutable Int
        # with no invariant tying it to `validity`, and many sites in the
        # engine gate on `null_count != 0` to decide whether to consult
        # validity AT ALL — including the NULL-join-key guards across the
        # join kernel families. A zero here disarms ALL of them at once for
        # any column arriving through this import: the kernel reads the value
        # under the cleared bit — DType zero in practice — and matches it
        # against a real key `0`. No exception, no crash, a plausible answer.
        # The join key extractor states the same asymmetry from the CONSUMER
        # side ("the bitmap is ground truth ... the lax gate reinstates a
        # wrong answer") and chose the same way; fixing it at the producer
        # boundary is what stops every other site needing to.
        #
        # COST: one SIMD popcount over `(length+7)/8` bytes — the bytes the
        # memcpy 20 lines up just touched, so they are in L1. Paid once per
        # imported column that HAS a bitmap; a column without one skips this
        # branch entirely and keeps `null_count == 0`, which is then true.
        null_count = bm.null_count()

        validity = bm^

    if (
        arrow_t == ArrowType.STRING
        or arrow_t == ArrowType.BINARY
        or arrow_t == ArrowType.LARGE_STRING
        or arrow_t == ArrowType.LARGE_BINARY
    ):
        # buffers[1] = offsets (i32 for STRING/BINARY, i64 for LARGE_*),
        # buffers[2] = utf8/raw bytes.
        var is_large = (
            arrow_t == ArrowType.LARGE_STRING
            or arrow_t == ArrowType.LARGE_BINARY
        )
        var off_elem_bytes = 8 if is_large else 4
        var n_off = length + 1
        var off_bytes = n_off * off_elem_bytes
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        var data_len = 0
        var off_p = _c_buffer_at(bufs, 1)
        # A non-empty var-len array's offsets buffer has (length+1) entries, so
        # its size is never 0 and the spec's NULL allowance never applies.
        # Passing `0` for the empty case is the whole point: an empty column IS
        # entitled to omit it.
        _require_c_buffer(off_p, off_bytes if length > 0 else 0, "offsets", arrow_t)
        if _non_null(off_p):
            var off_src = off_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr; see
            # FFI-CARVE-OUT block in `_build_column_array`.
            var off_view_mut = off_buf.view_mut()
            unsafe_memcpy(
                dest=off_view_mut._unsafe_ptr(),
                src=off_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=off_bytes,
            )
            off_buf.set_length(Int64(off_bytes))

            # last offset == total data length.  Read the correct width.
            # Read via view_ro + _unsafe_ptr.bitcast[T].
            if length > 0:
                if is_large:
                    var off_view_ro = off_buf.view_ro()
                    var last_off_ptr = off_view_ro._unsafe_ptr().bitcast[Int64]()
                    data_len = Int((last_off_ptr + length)[])
                else:
                    var off_view_ro = off_buf.view_ro()
                    var last_off_ptr = off_view_ro._unsafe_ptr().bitcast[Int32]()
                    data_len = Int((last_off_ptr + length)[])
        else:
            # Legitimately absent (length == 0 — `_require_c_buffer` refused
            # every other case). ZERO, don't merely `set_length`: the canonical
            # offsets of an empty var-len array are `[0]`, and OAB's bytes are
            # uninitialised until written, so publishing them unzeroed hands the
            # next consumer allocator residue as offsets[0].
            off_buf.zero()
            off_buf.set_length(Int64(off_bytes))

        var data_buf = OwnedAlignedBuffer(max(data_len, 1))
        var data_p = _c_buffer_at(bufs, 2)
        _require_c_buffer(data_p, data_len, "data", arrow_t)
        if data_len > 0 and _non_null(data_p):
            var data_src = data_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var data_view_mut = data_buf.view_mut()
            unsafe_memcpy(
                dest=data_view_mut._unsafe_ptr(),
                src=data_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=data_len,
            )
        data_buf.set_length(Int64(data_len))

        return Column[HeapRegion](
            arrow_type=arrow_t,
            data=data_buf^,
            offsets=Optional[OwnedAlignedBuffer](off_buf^),
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    if arrow_t == ArrowType.DICTIONARY:
        # Dictionary import.
        # Parent CArrowArray: 2 buffers (validity [done above], i32 indices).
        # Dictionary CArrowArray hangs off carray.dictionary: STRING array
        # with 3 buffers (validity, offsets, utf8 data) — those become the
        # value table.
        if _is_null(carray.dictionary):
            raise Error("from_arrow_c_stream: dictionary column missing dictionary slot")
        # Indices buffer (parent buffers[1]).  Supports INT32 indices.
        var idx_bytes = length * 4
        var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        var idx_p = _c_buffer_at(bufs, 1)
        _require_c_buffer(idx_p, idx_bytes, "dictionary indices", arrow_t)
        if idx_bytes > 0 and _non_null(idx_p):
            var idx_src = idx_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var idx_view_mut = idx_buf.view_mut()
            unsafe_memcpy(
                dest=idx_view_mut._unsafe_ptr(),
                src=idx_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=idx_bytes,
            )
        idx_buf.set_length(Int64(idx_bytes))

        # Dictionary value-type child array.
        ref dict_carray = carray.dictionary[]
        var dict_len = Int(dict_carray.length)
        var dict_bufs = dict_carray.buffers
        if _is_null(dict_bufs):
            raise Error("from_arrow_c_stream: dictionary value-array missing buffers")
        # dict_bufs[1] = i32 offsets (dict_len + 1 entries).
        var d_off_bytes = (dict_len + 1) * 4
        var d_off_buf = OwnedAlignedBuffer(max(d_off_bytes, 1))
        var d_data_len = 0
        var d_off_p = _c_buffer_at(dict_bufs, 1)
        _require_c_buffer(
            d_off_p, d_off_bytes if dict_len > 0 else 0,
            "dictionary value offsets", arrow_t,
        )
        if _non_null(d_off_p):
            var d_off_src = d_off_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var d_off_view_mut = d_off_buf.view_mut()
            unsafe_memcpy(
                dest=d_off_view_mut._unsafe_ptr(),
                src=d_off_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=d_off_bytes,
            )
            d_off_buf.set_length(Int64(d_off_bytes))

            # Last_off read via view_ro + _unsafe_ptr.
            if dict_len > 0:
                var d_off_view_ro = d_off_buf.view_ro()
                var last_off_ptr = d_off_view_ro._unsafe_ptr().bitcast[Int32]()
                d_data_len = Int((last_off_ptr + dict_len)[])
        else:
            # Empty value table: canonical offsets are `[0]`. See the STRING
            # arm for why `zero()` and not just `set_length`.
            d_off_buf.zero()
            d_off_buf.set_length(Int64(d_off_bytes))

        # dict_bufs[2] = utf8 data.
        var d_data_buf = OwnedAlignedBuffer(max(d_data_len, 1))
        var d_data_p = _c_buffer_at(dict_bufs, 2)
        _require_c_buffer(d_data_p, d_data_len, "dictionary value data", arrow_t)
        if d_data_len > 0 and _non_null(d_data_p):
            var d_data_src = d_data_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var d_data_view_mut = d_data_buf.view_mut()
            unsafe_memcpy(
                dest=d_data_view_mut._unsafe_ptr(),
                src=d_data_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=d_data_len,
            )
        d_data_buf.set_length(Int64(d_data_len))

        var dict_col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^,
            offsets=Optional[OwnedAlignedBuffer](d_off_buf^),
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        dict_col._set_dict_data_from_oab(d_data_buf^)
        dict_col._dict_size = dict_len
        return dict_col^

    # --- Nested types (LIST/STRUCT/MAP). ---

    if arrow_t == ArrowType.LIST:
        # 2 buffers (validity [done above], i32 offsets); 1 child.
        if _is_null(sch_ptr):
            raise Error(
                "from_arrow_c_stream: LIST column requires a matching"
                " CArrowSchema for child-type recursion"
            )
        if Int(carray.n_children) != 1:
            raise Error(
                "from_arrow_c_stream: LIST array must have 1 child, got "
                + String(Int(carray.n_children))
            )
        comptime int32_size = size_of[Int32]()
        var off_bytes = (length + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        var off_p = _c_buffer_at(bufs, 1)
        _require_c_buffer(off_p, off_bytes if length > 0 else 0, "offsets", arrow_t)
        if _non_null(off_p):
            var off_src = off_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var off_view_mut = off_buf.view_mut()
            unsafe_memcpy(
                dest=off_view_mut._unsafe_ptr(),
                src=off_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=off_bytes,
            )
        else:
            # Empty list: canonical offsets are `[0]`. See the STRING arm.
            off_buf.zero()
        off_buf.set_length(Int64(off_bytes))

        # Recurse on the single child.
        if _is_null(carray.children):
            raise Error("from_arrow_c_stream: LIST array has NULL children array")
        var child_ca_arr = carray.children.bitcast[_ArrayPtr]()
        var child_ca = (child_ca_arr + 0)[]
        if _is_null(child_ca):
            raise Error("from_arrow_c_stream: LIST child array is NULL")
        # Walk the schema's children for the child format string.
        ref pschema = sch_ptr[]
        if _is_null(pschema.children):
            raise Error("from_arrow_c_stream: LIST schema has NULL children array")
        var child_cs_arr = pschema.children.bitcast[_SchemaPtr]()
        var child_cs_ptr = (child_cs_arr + 0)[]
        if _is_null(child_cs_ptr):
            raise Error("from_arrow_c_stream: LIST child schema is NULL")
        ref child_cs = child_cs_ptr[]
        var child_fmt = _c_str_to_mojo(child_cs.format) if _non_null(child_cs.format) else String("")
        var child_t = _format_string_to_arrow_type(child_fmt)
        var child_p = 0
        var child_s = 0
        if child_t == ArrowType.DECIMAL128 or child_t == ArrowType.DECIMAL256:
            var ps = _parse_decimal_format(child_fmt)
            child_p = ps[0]
            child_s = ps[1]
        var child_col = _import_column(child_ca[], child_t, child_p, child_s, child_cs_ptr, False)
        # zero-length data buffer for LIST.
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)

        var col = Column[HeapRegion](
            arrow_type=ArrowType.LIST,
            data=data_buf^,
            offsets=Optional[OwnedAlignedBuffer](off_buf^),
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        # Use a child-name from the schema, if any.
        var child_name = _c_str_to_mojo(child_cs.name) if _non_null(child_cs.name) else String("item")
        col._field_names.append(child_name)
        col._children.append(child_col^)
        return col^

    if arrow_t == ArrowType.STRUCT:
        # 1 buffer (validity [done above]); N children.
        if _is_null(sch_ptr):
            raise Error(
                "from_arrow_c_stream: STRUCT column requires a matching"
                " CArrowSchema for child-type recursion"
            )
        var nchild = Int(carray.n_children)
        ref pschema = sch_ptr[]
        if Int(pschema.n_children) != nchild:
            raise Error(
                "from_arrow_c_stream: STRUCT schema/array children mismatch: "
                + String(Int(pschema.n_children)) + " vs " + String(nchild)
            )
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)

        var col = Column[HeapRegion](
            arrow_type=ArrowType.STRUCT,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        if nchild > 0:
            if _is_null(carray.children):
                raise Error("from_arrow_c_stream: STRUCT array has NULL children array")
            if _is_null(pschema.children):
                raise Error("from_arrow_c_stream: STRUCT schema has NULL children array")
            var child_ca_arr = carray.children.bitcast[_ArrayPtr]()
            var child_cs_arr = pschema.children.bitcast[_SchemaPtr]()
            for i in range(nchild):
                var child_ca = (child_ca_arr + i)[]
                var child_cs_ptr = (child_cs_arr + i)[]
                if _is_null(child_ca) or _is_null(child_cs_ptr):
                    raise Error(
                        "from_arrow_c_stream: STRUCT child #" + String(i)
                        + " has NULL schema or array"
                    )
                ref child_cs = child_cs_ptr[]
                var child_fmt = _c_str_to_mojo(child_cs.format) if _non_null(child_cs.format) else String("")
                var child_t = _format_string_to_arrow_type(child_fmt)
                var child_p = 0
                var child_s = 0
                if child_t == ArrowType.DECIMAL128 or child_t == ArrowType.DECIMAL256:
                    var ps = _parse_decimal_format(child_fmt)
                    child_p = ps[0]
                    child_s = ps[1]
                var child_col = _import_column(child_ca[], child_t, child_p, child_s, child_cs_ptr, False)
                col._children.append(child_col^)
                var cname = _c_str_to_mojo(child_cs.name) if _non_null(child_cs.name) else String("f") + String(i)
                col._field_names.append(cname)
        return col^

    if arrow_t == ArrowType.MAP:
        # 2 buffers (validity [done above], i32 offsets); 1 child (entries struct).
        if _is_null(sch_ptr):
            raise Error(
                "from_arrow_c_stream: MAP column requires a matching"
                " CArrowSchema for child-type recursion"
            )
        if Int(carray.n_children) != 1:
            raise Error(
                "from_arrow_c_stream: MAP array must have 1 entries child,"
                " got " + String(Int(carray.n_children))
            )
        comptime int32_size = size_of[Int32]()
        var off_bytes = (length + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        var off_p = _c_buffer_at(bufs, 1)
        _require_c_buffer(off_p, off_bytes if length > 0 else 0, "offsets", arrow_t)
        if _non_null(off_p):
            var off_src = off_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var off_view_mut = off_buf.view_mut()
            unsafe_memcpy(
                dest=off_view_mut._unsafe_ptr(),
                src=off_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=off_bytes,
            )
        else:
            # Empty map: canonical offsets are `[0]`. See the STRING arm.
            off_buf.zero()
        off_buf.set_length(Int64(off_bytes))

        if _is_null(carray.children):
            raise Error("from_arrow_c_stream: MAP array has NULL children array")
        var child_ca_arr = carray.children.bitcast[_ArrayPtr]()
        var child_ca = (child_ca_arr + 0)[]
        ref pschema = sch_ptr[]
        if _is_null(pschema.children):
            raise Error("from_arrow_c_stream: MAP schema has NULL children array")
        var child_cs_arr = pschema.children.bitcast[_SchemaPtr]()
        var child_cs_ptr = (child_cs_arr + 0)[]
        if _is_null(child_ca) or _is_null(child_cs_ptr):
            raise Error("from_arrow_c_stream: MAP entries child is NULL")
        ref child_cs = child_cs_ptr[]
        var child_fmt = _c_str_to_mojo(child_cs.format) if _non_null(child_cs.format) else String("")
        var child_t = _format_string_to_arrow_type(child_fmt)
        if child_t != ArrowType.STRUCT:
            raise Error(
                "from_arrow_c_stream: MAP entries child must be STRUCT, got"
                " format '" + child_fmt + "'"
            )
        var entries_col = _import_column(child_ca[], ArrowType.STRUCT, 0, 0, child_cs_ptr, False)
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)

        var col = Column[HeapRegion](
            arrow_type=ArrowType.MAP,
            data=data_buf^,
            offsets=Optional[OwnedAlignedBuffer](off_buf^),
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )
        col._children.append(entries_col^)
        col._field_names.append(String("entries"))
        col._keys_sorted = keys_sorted
        return col^

    # --- Union types (sparse + dense). ---

    if (
        arrow_t == ArrowType.UNION_SPARSE
        or arrow_t == ArrowType.UNION_DENSE
    ):
        if _is_null(sch_ptr):
            raise Error(
                "from_arrow_c_stream: UNION column requires a matching"
                " CArrowSchema for child-type recursion"
            )
        var is_dense = arrow_t == ArrowType.UNION_DENSE
        # buffers[0] = Int8 types buffer (always).
        comptime int8_size = size_of[Int8]()
        var types_bytes = length * int8_size
        var types_buf_local = OwnedAlignedBuffer(max(types_bytes, 1))
        # A union's buffers[0] is the TYPE-IDS buffer, not a validity bitmap —
        # spec situation (1) does not apply to it, only situation (2).
        var types_p = _c_buffer_at(bufs, 0)
        _require_c_buffer(types_p, types_bytes, "union type ids", arrow_t)
        if types_bytes > 0 and _non_null(types_p):
            var types_src = types_p.bitcast[UInt8]()
            # Memcpy dest via view_mut + _unsafe_ptr.
            var types_view_mut = types_buf_local.view_mut()
            unsafe_memcpy(
                dest=types_view_mut._unsafe_ptr(),
                src=types_src.unsafe_origin_cast[MutUntrackedOrigin](),
                count=types_bytes,
            )
        types_buf_local.set_length(Int64(types_bytes))

        # Dense: buffers[1] = Int32 offsets buffer.
        var off_opt = Optional[OwnedAlignedBuffer](None)
        if is_dense:
            comptime int32_size = size_of[Int32]()
            var off_bytes = length * int32_size
            var off_buf_local = OwnedAlignedBuffer(max(off_bytes, 1))
            var dense_off_p = _c_buffer_at(bufs, 1)
            _require_c_buffer(
                dense_off_p, off_bytes, "dense union offsets", arrow_t
            )
            if off_bytes > 0 and _non_null(dense_off_p):
                var off_src = dense_off_p.bitcast[UInt8]()
                # Memcpy dest via view_mut + _unsafe_ptr.
                var off_view_mut = off_buf_local.view_mut()
                unsafe_memcpy(
                    dest=off_view_mut._unsafe_ptr(),
                    src=off_src.unsafe_origin_cast[MutUntrackedOrigin](),
                    count=off_bytes,
                )
            off_buf_local.set_length(Int64(off_bytes))

            off_opt = off_buf_local^
        # Walk children.  Schema must have parallel children.
        var nchild = Int(carray.n_children)
        ref pschema = sch_ptr[]
        if Int(pschema.n_children) != nchild:
            raise Error(
                "from_arrow_c_stream: UNION schema/array children mismatch: "
                + String(Int(pschema.n_children)) + " vs " + String(nchild)
            )
        var col = Column[HeapRegion](
            arrow_type=arrow_t,
            data=types_buf_local^,
            offsets=off_opt^,
            validity=None,  # unions carry no validity bitmap
            length=length,
            null_count=0,
            offset=0,
        )
        if nchild > 0:
            if _is_null(carray.children):
                raise Error("from_arrow_c_stream: UNION array has NULL children array")
            if _is_null(pschema.children):
                raise Error("from_arrow_c_stream: UNION schema has NULL children array")
            var child_ca_arr = carray.children.bitcast[_ArrayPtr]()
            var child_cs_arr = pschema.children.bitcast[_SchemaPtr]()
            for i in range(nchild):
                var child_ca = (child_ca_arr + i)[]
                var child_cs_ptr = (child_cs_arr + i)[]
                if _is_null(child_ca) or _is_null(child_cs_ptr):
                    raise Error(
                        "from_arrow_c_stream: UNION child #" + String(i)
                        + " has NULL schema or array"
                    )
                ref child_cs = child_cs_ptr[]
                var child_fmt = _c_str_to_mojo(child_cs.format) if _non_null(child_cs.format) else String("")
                var child_t = _format_string_to_arrow_type(child_fmt)
                var child_p = 0
                var child_s = 0
                if child_t == ArrowType.DECIMAL128 or child_t == ArrowType.DECIMAL256:
                    var ps = _parse_decimal_format(child_fmt)
                    child_p = ps[0]
                    child_s = ps[1]
                var child_col = _import_column(child_ca[], child_t, child_p, child_s, child_cs_ptr, False)
                col._children.append(child_col^)
                var cname = _c_str_to_mojo(child_cs.name) if _non_null(child_cs.name) else String("f") + String(i)
                col._field_names.append(cname)
        # Carry the declared type-ids (from the parent format string,
        # passed in by the caller).  Pad / truncate to match nchild for
        # safety; an empty `union_type_ids` falls back to 0..nchild-1.
        if len(union_type_ids) == nchild:
            for i in range(nchild):
                col._type_ids.append(union_type_ids[i])
        else:
            for i in range(nchild):
                col._type_ids.append(i)
        return col^

    # --- fixed-width / boolean ---
    var elem_bytes: Int
    if arrow_t == ArrowType.BOOL:
        elem_bytes = -1  # packed bits
    elif arrow_t == ArrowType.DECIMAL128:
        elem_bytes = 16
    elif arrow_t == ArrowType.DECIMAL256:
        # 32-byte LE 256-bit decimal.
        elem_bytes = 32
    else:
        elem_bytes = _arrow_fixed_width_bytes(arrow_t)
    var data_bytes: Int
    if elem_bytes == -1:
        data_bytes = (length + 7) >> 3
    else:
        data_bytes = length * elem_bytes
    var data_buf2 = OwnedAlignedBuffer(max(data_bytes, 1))
    # The values themselves. A NULL here is the worst case of all: read
    # blindly, a 3-row INT64 column with an omitted data buffer yields 24 bytes of
    # allocator residue AS THE VALUES, with a correct length and no error.
    var fixed_data_p = _c_buffer_at(bufs, 1)
    _require_c_buffer(fixed_data_p, data_bytes, "data", arrow_t)
    if data_bytes > 0 and _non_null(fixed_data_p):
        var data_src = fixed_data_p.bitcast[UInt8]()
        # Memcpy dest via view_mut + _unsafe_ptr.
        var data_view_mut = data_buf2.view_mut()
        unsafe_memcpy(
            dest=data_view_mut._unsafe_ptr(),
            src=data_src.unsafe_origin_cast[MutUntrackedOrigin](),
            count=data_bytes,
        )
    data_buf2.set_length(Int64(data_bytes))

    var col = Column[HeapRegion](
        arrow_type=arrow_t,
        data=data_buf2^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )
    if arrow_t == ArrowType.DECIMAL128:
        var p = precision if precision >= 1 else 38
        var s = scale if (scale >= 0 and scale <= p) else 0
        col._decimal_p = p
        col._decimal_s = s
    elif arrow_t == ArrowType.DECIMAL256:
        # Stamp 256-bit decimal (p, s).
        # The 256-bit precision bound is 76 (Arrow spec).
        var p = precision if precision >= 1 else 76
        var s = scale if (scale >= 0 and scale <= p) else 0
        col._decimal_p = p
        col._decimal_s = s
    return col^


def _arrow_fixed_width_bytes(arrow_t: ArrowType) raises -> Int:
    if arrow_t == ArrowType.INT8 or arrow_t == ArrowType.UINT8:
        return 1
    elif arrow_t == ArrowType.INT16 or arrow_t == ArrowType.UINT16:
        return 2
    # Float16 is 2 bytes per element.
    elif arrow_t == ArrowType.FLOAT16:
        return 2
    elif (
        arrow_t == ArrowType.INT32
        or arrow_t == ArrowType.UINT32
        or arrow_t == ArrowType.FLOAT32
        or arrow_t == ArrowType.DATE32
        #
        # Time32 (Int32 buffer); IntervalYearMonth (Int32 months).
        or arrow_t == ArrowType.TIME32_S
        or arrow_t == ArrowType.TIME32_MS
        or arrow_t == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return 4
    elif (
        arrow_t == ArrowType.INT64
        or arrow_t == ArrowType.UINT64
        or arrow_t == ArrowType.FLOAT64
        or arrow_t == ArrowType.DATE64
        or arrow_t.is_timestamp()
        # Time64 / Duration / IntervalDayTime
        # all use an Int64 storage buffer.
        or arrow_t == ArrowType.TIME64_US
        or arrow_t == ArrowType.TIME64_NS
        or arrow_t.is_duration()
        or arrow_t == ArrowType.INTERVAL_DAY_TIME
    ):
        return 8
    # IntervalMonthDayNano = 16 bytes
    # (Int32 months + Int32 days + Int64 nanos).
    elif arrow_t == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return 16
    # Decimal256 = 32 bytes per element (LE).
    elif arrow_t == ArrowType.DECIMAL256:
        return 32
    else:
        raise _unsupported(arrow_t, "drain")


# --- Parse a C ABI format string back to an ArrowType. ---

def _parse_small_uint(s: String) -> Int:
    """Parse a small non-negative decimal integer from a (possibly
    whitespace-padded) string; returns -1 if it contains a non-digit
    (after trimming) or is empty."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = 0
    # Trim leading whitespace.
    while i < n and (bytes[i] == 0x20 or bytes[i] == 0x09):
        i += 1
    var j = n
    # Trim trailing whitespace.
    while j > i and (bytes[j - 1] == 0x20 or bytes[j - 1] == 0x09):
        j -= 1
    if i >= j:
        return -1
    var v = 0
    while i < j:
        var c = Int(bytes[i])
        if c < 0x30 or c > 0x39:
            return -1
        v = v * 10 + (c - 0x30)
        i += 1
    return v


def _parse_decimal_format(fmt: String) raises -> Tuple[Int, Int]:
    """Parse `d:precision,scale[,bitwidth]` into (precision, scale).

    Delegates to the public
    `extract_decimal_params` in `arrow_types.mojo` for the parse work.
    Accepted bitwidths are 128 AND 256. The (p, s) bound depends on the bitwidth:
    Decimal128 allows precision up to 38; Decimal256 allows up to 76.
    """
    var ps_w = extract_decimal_params(fmt)
    var p = ps_w[0]
    var s = ps_w[1]
    var w = ps_w[2]
    if w != 0 and w != 128 and w != 256:
        raise Error(
            "UnsupportedArrowCABIType: decimal bitwidth '" + String(w)
            + "' (only 128 and 256 supported)"
        )
    # Per-bitwidth precision bound. 0 (no width specified) -> Decimal128.
    var max_prec = 76 if w == 256 else 38
    var default_p = 76 if w == 256 else 38
    var default_s = 0 if w == 256 else 18
    # Defensive defaults for (p, s) when the parser returned zeros.
    if p < 1 or p > max_prec:
        p = default_p
    if s < 0:
        s = default_s
    if s > p:
        s = p
    return (p, s)


def _format_string_to_arrow_type(fmt: String) raises -> ArrowType:
    """Parse a CArrowSchema format string into an ArrowType, restricted to
    the supported C-Data import subset.

    Delegates the discriminator parse to the
    public `parse_format_string` (the byte-equivalent shared with
    `Field.format_string()`), then enforces the import gate by raising
    `UnsupportedArrowCABIType` for any type not wired through the
    import codepath.
    """
    var t = parse_format_string(fmt)
    # `parse_format_string` returns NULL for unrecognized strings; preserve
    # `n` -> NULL only when the literal string asked for a Null array.
    if t == ArrowType.NULL and fmt != String("n"):
        raise Error(
            "UnsupportedArrowCABIType: Arrow C ABI format string '" + fmt
            + "' is not recognized."
        )
    # The import subset includes BINARY + LARGE_STRING + LARGE_BINARY (the
    # 3-buffer var-len family with i32 vs i64 offsets) and Decimal256,
    # Float16, Time*, Duration*, Interval* (the primitive-passthrough types).
    if (
        t == ArrowType.NULL
        or t == ArrowType.BOOL
        or t.is_integer()
        or t.is_floating()
        or t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
        or t == ArrowType.DATE32
        or t == ArrowType.DATE64
        or t.is_timestamp()
        or t == ArrowType.DECIMAL128
        # New primitive-passthrough + Decimal256.
        or t == ArrowType.DECIMAL256
        or t.is_time()
        or t.is_duration()
        or t.is_interval()
        # Nested types (round-trip only).
        or t == ArrowType.LIST
        or t == ArrowType.STRUCT
        or t == ArrowType.MAP
        # Union types (round-trip only).
        or t == ArrowType.UNION_SPARSE
        or t == ArrowType.UNION_DENSE
    ):
        return t
    raise Error(
        "UnsupportedArrowCABIType: Arrow C ABI format string '" + fmt
        + "' not in the supported drain subset. Extension types are passed"
        + " through as metadata; Run-End-Encoded (REE) is not supported."
    )


# =============================================================================
# Import: read the root CArrowSchema -> (column_names, arrow_types).
# =============================================================================

struct _ImportedSchemaInfo(Movable):
    var names: List[String]
    var arrow_types: List[ArrowType]
    var nullables: List[Bool]
    # Decimal (precision, scale) per column; (0, 0) for non-decimal columns.
    var dec_precisions: List[Int]
    var dec_scales: List[Int]
    # parameter slots, populated on import:
    var tzs: List[String]
    var dict_index_types: List[ArrowType]
    var union_type_ids_per_field: List[List[Int]]
    # Raw CArrowSchema.flags per field +
    # per-field metadata kv-lists (each entry is a List[String] of keys
    # parallel to a List[String] of values).
    var flags: List[Int64]
    var metadata_keys: List[List[String]]
    var metadata_values: List[List[String]]

    def __init__(out self):
        self.names = List[String]()
        self.arrow_types = List[ArrowType]()
        self.nullables = List[Bool]()
        self.dec_precisions = List[Int]()
        self.dec_scales = List[Int]()
        self.tzs = List[String]()
        self.dict_index_types = List[ArrowType]()
        self.union_type_ids_per_field = List[List[Int]]()
        self.flags = List[Int64]()
        self.metadata_keys = List[List[String]]()
        self.metadata_values = List[List[String]]()


def _read_root_schema(sch_ptr: _SchemaPtr) raises -> _ImportedSchemaInfo:
    """Read a root struct CArrowSchema (`+s`) into per-column metadata."""
    if _is_null(sch_ptr):
        raise Error("from_arrow_c_stream: get_schema returned a NULL ArrowSchema")
    ref root = sch_ptr[]
    if _is_null(root.format):
        raise Error("from_arrow_c_stream: ArrowSchema has a NULL format string")
    var root_fmt = _c_str_to_mojo(root.format)
    if root_fmt != "+s":
        raise Error(
            "from_arrow_c_stream: top-level ArrowSchema must be a struct ('+s'),"
            " got '" + root_fmt + "'"
        )
    var info = _ImportedSchemaInfo()
    var n = Int(root.n_children)
    if n > 0:
        if _is_null(root.children):
            raise Error("from_arrow_c_stream: struct schema has NULL children array")
        var child_arr = root.children.bitcast[_SchemaPtr]()
        for i in range(n):
            var c = (child_arr + i)[]
            if _is_null(c):
                raise Error("from_arrow_c_stream: child schema #" + String(i) + " is NULL")
            ref cs = c[]
            var fmt = _c_str_to_mojo(cs.format) if _non_null(cs.format) else String("")
            var name = _c_str_to_mojo(cs.name) if _non_null(cs.name) else (String("f") + String(i))
            var nullable = (cs.flags & ARROW_FLAG_NULLABLE) != 0
            # Dictionary detection.  A non-NULL
            # `dictionary` slot is the discriminator (per the Arrow C Data
            # spec — the parent format string is the INDEX type when this
            # is set).  We promote the parent type to DICTIONARY and pull
            # the index type from the parent format.
            var arrow_t: ArrowType
            var dict_idx_type = ArrowType.INT32
            if _non_null(cs.dictionary):
                # Parent format encodes the index type (INT8/16/32/64).
                arrow_t = ArrowType.DICTIONARY
                var parent_t = _format_string_to_arrow_type(fmt)
                if (
                    parent_t == ArrowType.INT8
                    or parent_t == ArrowType.INT16
                    or parent_t == ArrowType.INT32
                    or parent_t == ArrowType.INT64
                ):
                    dict_idx_type = parent_t
                else:
                    raise Error(
                        "from_arrow_c_stream: dictionary index type must be"
                        " signed int (INT8/16/32/64), got '" + fmt + "'"
                    )
                # Validate the child value-type format (STRING only).
                ref dict_cs = cs.dictionary[]
                var dict_fmt = _c_str_to_mojo(dict_cs.format) if _non_null(dict_cs.format) else String("")
                if dict_fmt != "u":
                    raise Error(
                        "from_arrow_c_stream: dictionary value type '" + dict_fmt
                        + "' — only STRING ('u') values are supported; other"
                        " value types are not"
                    )
            else:
                arrow_t = _format_string_to_arrow_type(fmt)
            info.names.append(name)
            info.arrow_types.append(arrow_t)
            info.nullables.append(nullable)
            info.dict_index_types.append(dict_idx_type)
            if arrow_t == ArrowType.DECIMAL128 or arrow_t == ArrowType.DECIMAL256:
                # Same `d:P,S[,W]` format string;
                # `_parse_decimal_format` discriminates the bitwidth bound.
                var ps = _parse_decimal_format(fmt)
                info.dec_precisions.append(ps[0])
                info.dec_scales.append(ps[1])
            else:
                info.dec_precisions.append(0)
                info.dec_scales.append(0)
            # parameter extraction.
            if arrow_t.is_timestamp():
                info.tzs.append(extract_timestamp_timezone(fmt))
            else:
                info.tzs.append(String(""))
            if arrow_t == ArrowType.UNION_SPARSE or arrow_t == ArrowType.UNION_DENSE:
                info.union_type_ids_per_field.append(extract_union_type_ids(fmt))
            else:
                info.union_type_ids_per_field.append(List[Int]())
            # Capture raw flags + metadata.
            info.flags.append(cs.flags)
            var kv_keys = List[String]()
            var kv_values = List[String]()
            if _non_null(cs.metadata):
                var kvs = decode_metadata(cs.metadata)
                # Tuple subscript can't be moved-out-of in Mojo 1.0.0b1; copy.
                kv_keys = kvs[0].copy()
                kv_values = kvs[1].copy()
            info.metadata_keys.append(kv_keys^)
            info.metadata_values.append(kv_values^)
    return info^


def _build_schema_from_info(info: _ImportedSchemaInfo) raises -> Schema:
    """Build a Mojo Schema from imported per-column metadata.

    Carries decimal (precision, scale) for Decimal128 columns, the parameter
    slots (tz, dict index, union type-ids), raw flags and the per-Field
    metadata kv-list. Uses the SchemaBuilder path (not the legacy ctor) so
    those slots are populated.
    """
    var sb = SchemaBuilder()
    var n = len(info.names)
    var have_dec_info = (
        len(info.dec_precisions) == n and len(info.dec_scales) == n
    )
    var have_tz_info = len(info.tzs) == n
    var have_dict_info = len(info.dict_index_types) == n
    var have_union_info = len(info.union_type_ids_per_field) == n
    var have_flag_info = len(info.flags) == n
    var have_meta_info = (
        len(info.metadata_keys) == n and len(info.metadata_values) == n
    )
    for i in range(n):
        var arrow_t = info.arrow_types[i]
        var name = info.names[i]
        var nullable = info.nullables[i]
        var field: Field
        if arrow_t == ArrowType.DICTIONARY and have_dict_info:
            field = Field.dictionary(name, info.dict_index_types[i], nullable)
        elif arrow_t.is_timestamp() and have_tz_info:
            field = Field.timestamp(name, arrow_t, info.tzs[i], nullable)
        elif (arrow_t == ArrowType.UNION_SPARSE or arrow_t == ArrowType.UNION_DENSE) and have_union_info:
            field = Field.union(name, arrow_t, info.union_type_ids_per_field[i], nullable)
        else:
            field = Field(name, arrow_t, nullable)
        if have_dec_info and (
            arrow_t == ArrowType.DECIMAL128 or arrow_t == ArrowType.DECIMAL256
        ):
            # Decimal256 carries (p, s) like
            # Decimal128 — the Field slot is the same; the bitwidth bound
            # differs (76 vs 38) but is validated in `Field.decimal256`.
            field.decimal_precision = info.dec_precisions[i]
            field.decimal_scale = info.dec_scales[i]
        # Stamp the raw flag bitfield + metadata.
        if have_flag_info:
            field._flags = info.flags[i]
        if have_meta_info:
            for j in range(len(info.metadata_keys[i])):
                field.set_metadata(info.metadata_keys[i][j], info.metadata_values[i][j])
        sb.add_field(field^)
    return sb.build()


def _arrow_type_to_dtype(t: ArrowType) -> DType:
    if t == ArrowType.BOOL:
        return DType.bool
    elif t == ArrowType.INT8:
        return DType.int8
    elif t == ArrowType.INT16:
        return DType.int16
    elif (
        t == ArrowType.INT32
        or t == ArrowType.DATE32
        # Time32 / IntervalYearMonth = Int32.
        or t == ArrowType.TIME32_S
        or t == ArrowType.TIME32_MS
        or t == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return DType.int32
    elif (
        t == ArrowType.INT64
        or t == ArrowType.DATE64
        or t.is_timestamp()
        # Time64 / Duration / IntervalDayTime = Int64.
        or t == ArrowType.TIME64_US
        or t == ArrowType.TIME64_NS
        or t.is_duration()
        or t == ArrowType.INTERVAL_DAY_TIME
    ):
        return DType.int64
    elif t == ArrowType.UINT8:
        return DType.uint8
    elif t == ArrowType.UINT16:
        return DType.uint16
    elif t == ArrowType.UINT32:
        return DType.uint32
    elif t == ArrowType.UINT64:
        return DType.uint64
    elif t == ArrowType.FLOAT16:
        # Float16 first-class storage.
        return DType.float16
    elif t == ArrowType.FLOAT32:
        return DType.float32
    elif t == ArrowType.FLOAT64:
        return DType.float64
    else:
        # STRING / DECIMAL128 / DECIMAL256 / INTERVAL_MONTH_DAY_NANO / NULL —
        # Column carries the ArrowType tag; the DType field is only meaningful
        # for fixed-width numerics that map to a Mojo DType.
        return DType.int64


# =============================================================================
# Import: root CArrowArray + schema info -> RecordBatch.
# =============================================================================

def _import_record_batch(
    arr_ptr: _ArrayPtr, info: _ImportedSchemaInfo, var schema: Schema,
    sch_ptr: _SchemaPtr = _null_ptr[CArrowSchema, MutUntrackedOrigin](),
) raises -> RecordBatch:
    """Import a CArrowArray + previously-read schema info into a Mojo
    RecordBatch.  Also accepts the original
    root CArrowSchema pointer so nested-type columns can recurse into
    child schemas (Field's flat `_child_types` loses parameterization)."""
    if _is_null(arr_ptr):
        raise Error("from_arrow_c_stream: get_next returned a NULL ArrowArray")
    ref root = arr_ptr[]
    var ncols = len(info.arrow_types)
    if Int(root.n_children) != ncols:
        raise Error(
            "from_arrow_c_stream: ArrowArray has " + String(Int(root.n_children))
            + " children, schema has " + String(ncols)
        )
    var num_rows = Int(root.length)
    var columns = Slab[Column[HeapRegion]].create(ncols)
    if ncols > 0:
        if _is_null(root.children):
            raise Error("from_arrow_c_stream: struct array has NULL children array")
        var child_arr = root.children.bitcast[_ArrayPtr]()
        # Also access the schema children for nested-type recursion.
        var schema_child_arr = _null_ptr[_SchemaPtr, MutUntrackedOrigin]()
        if _non_null(sch_ptr):
            ref proot = sch_ptr[]
            if _non_null(proot.children):
                schema_child_arr = proot.children.bitcast[_SchemaPtr]()
        for i in range(ncols):
            var c = (child_arr + i)[]
            if _is_null(c):
                raise Error("from_arrow_c_stream: child array #" + String(i) + " is NULL")
            ref cref = c[]
            var col_p = 0
            var col_s = 0
            if (
                len(info.dec_precisions) == ncols
                and len(info.dec_scales) == ncols
            ):
                col_p = info.dec_precisions[i]
                col_s = info.dec_scales[i]
            # Pass the matching child CArrowSchema for nested
            # types (NULL otherwise — non-nested arms ignore it).
            var child_sch_ptr = _null_ptr[CArrowSchema, MutUntrackedOrigin]()
            if _non_null(schema_child_arr):
                child_sch_ptr = (schema_child_arr + i)[]
            # Read MAP keys_sorted from the child schema's flags.
            var child_keys_sorted = False
            if (
                info.arrow_types[i] == ArrowType.MAP
                and _non_null(child_sch_ptr)
            ):
                ref ccs = child_sch_ptr[]
                child_keys_sorted = (ccs.flags & ARROW_FLAG_MAP_KEYS_SORTED) != 0
            # Thread the union type-ids from the format-string
            # parse done in `_read_root_schema`.  Empty for non-union.
            var col_union_ids = List[Int]()
            if (
                info.arrow_types[i] == ArrowType.UNION_SPARSE
                or info.arrow_types[i] == ArrowType.UNION_DENSE
            ):
                if len(info.union_type_ids_per_field) == ncols:
                    col_union_ids = info.union_type_ids_per_field[i].copy()
            columns.append(
                _import_column(
                    cref, info.arrow_types[i], col_p, col_s,
                    child_sch_ptr, child_keys_sorted, col_union_ids^,
                )
            )
    var batch = RecordBatch()
    batch.schema = schema^
    batch._columns = columns^
    batch._num_rows = num_rows
    return batch^


# =============================================================================
# Exported-stream callbacks (Mojo-side; bound onto the CArrowArrayStream).
# =============================================================================

def _exported_get_schema(stream: OpaquePtr, out_schema: _SchemaPtr) abi("C") -> Int32:
    """get_schema: fill `out_schema` with the (constant) stream schema."""
    if _is_null(stream) or _is_null(out_schema):
        return Int32(22)  # EINVAL
    var sp = stream.bitcast[CArrowArrayStream]()
    ref st = sp[]
    if _is_null(st.private_data):
        return Int32(22)
    var state_ptr = st.private_data.bitcast[_CStreamState]()
    ref state = state_ptr[]
    try:
        # Schema build needs a RecordBatch to
        # drive nested-type child format strings from the Column's actual
        # child arrow_types.  Use the first batch in the stream as the
        # sample; if the stream is empty AND the schema contains no nested
        # columns, fall back to the Field-only path (no Column needed).
        if len(state.batches) > 0:
            ref sample = state.batches[0]
            var built = _build_record_batch_schema(state.schema, sample)
            out_schema.unsafe_write(built^)
        else:
            # Empty stream — verify no nested columns (we can't synthesize a
            # nested Column's child types from Field alone).  Raise
            # rather than emit a schema with
            # missing child types.
            for i in range(state.schema.num_columns()):
                var t = state.schema.field_arrow_type(i)
                if (
                    t == ArrowType.LIST
                    or t == ArrowType.STRUCT
                    or t == ArrowType.MAP
                    or t == ArrowType.UNION_SPARSE
                    or t == ArrowType.UNION_DENSE
                ):
                    raise Error(
                        "ArrowCStream: empty stream with nested column '"
                        + state.schema.field_name(i)
                        + "' — cannot synthesize child schema without a"
                        " sample RecordBatch (child types are not derived"
                        " from Field._child_types)."
                    )
            var built = _build_record_batch_schema_no_data(state.schema)
            out_schema.unsafe_write(built^)
    except e:
        state.set_error(String(e))
        return Int32(5)  # EIO
    return Int32(0)


def _exported_get_next(stream: OpaquePtr, out_array: _ArrayPtr) abi("C") -> Int32:
    """get_next: fill `out_array` with the next chunk, or leave it released
    (`out_array.release == NULL`) on end-of-stream."""
    if _is_null(stream) or _is_null(out_array):
        return Int32(22)
    var sp = stream.bitcast[CArrowArrayStream]()
    ref st = sp[]
    if _is_null(st.private_data):
        return Int32(22)
    var state_ptr = st.private_data.bitcast[_CStreamState]()
    ref state = state_ptr[]
    if state.next_idx >= len(state.batches):
        # End of stream: leave `out_array` in the released state.
        out_array.unsafe_write(CArrowArray())  # zeroed -> release == NULL
        return Int32(0)
    try:
        ref batch = state.batches[state.next_idx]
        var built = _build_record_batch_array(batch)
        out_array.unsafe_write(built^)
        state.next_idx += 1
    except e:
        state.set_error(String(e))
        return Int32(5)
    return Int32(0)


def _exported_get_last_error(stream: OpaquePtr) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    if _is_null(stream):
        return _null_ptr[Int8, MutUntrackedOrigin]()
    var sp = stream.bitcast[CArrowArrayStream]()
    ref st = sp[]
    if _is_null(st.private_data):
        return _null_ptr[Int8, MutUntrackedOrigin]()
    var state_ptr = st.private_data.bitcast[_CStreamState]()
    ref state = state_ptr[]
    if len(state.last_error_bytes) == 0:
        # No error yet — return NULL per the Arrow C Stream Interface.
        return _null_ptr[Int8, MutUntrackedOrigin]()
    # Pointer INTO `last_error_bytes`'s storage; valid until the next stream
    # call (the next set_error may replace it, release destroys it).
    return state.last_error_bytes.unsafe_ptr().bitcast[Int8]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()


# =============================================================================
# PUBLIC ENTRY POINTS
# =============================================================================

def build_record_batch_stream(
    var batches: Slab[RecordBatch],
    var schema: Schema,
    out_stream: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin],
) raises:
    """Populate the caller-allocated `out_stream` so a consumer can pull the
    `batches` out via the Arrow C Stream Interface. Takes ownership of
    `batches` + `schema` (moved into the heap-allocated `_CStreamState`).

    The consumer owns `out_stream` after this call returns; it MUST invoke
    `out_stream.release(&out_stream)` (Mojo-side: `release_c_stream(ptr)`)
    exactly once to free the `_CStreamState` (which owns the batches' heap).

    Validates the schema's column types eagerly (raises
    `UnsupportedArrowCABIType` if any column is outside the supported subset) so
    a malformed export fails fast rather than at `get_next` time.
    """
    if _is_null(out_stream):
        raise Error("build_record_batch_stream: out_stream is NULL")
    # Eager type-coverage validation.
    for i in range(schema.num_columns()):
        _ = _arrow_type_n_buffers(schema.field_arrow_type(i))
    # Heap-allocate the producer-private state (FFI carve-out: raw alloc).
    var state = alloc[_CStreamState](1).unsafe_origin_cast[MutUntrackedOrigin]()
    state.unsafe_write(_CStreamState(batches^, schema^))
    var s = CArrowArrayStream()
    s.get_schema = _exported_get_schema
    s.get_next = _exported_get_next
    s.get_last_error = _exported_get_last_error
    _set_stream_release(s)
    s.private_data = state.bitcast[NoneType]()
    out_stream.unsafe_write(s^)


def drain_record_batch_stream(
    stream: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin],
) raises -> Slab[RecordBatch]:
    """Drain `stream`: call `get_schema`, then `get_next` until end-of-stream,
    importing each chunk into a Mojo `RecordBatch` (buffers are COPIED — we
    retain no pointers into foreign memory). Releases the stream (invokes its
    `release` callback) before returning. The returned `Slab` is owned by the
    caller.

    Raises if any callback returns non-zero (with the stream's
    `get_last_error` text appended) or if any inbound column type is outside
    the supported drain subset.
    """
    if _is_null(stream):
        raise Error("from_arrow_c_stream: stream pointer is NULL")
    ref st = stream[]
    if st.is_released():
        raise Error("from_arrow_c_stream: stream is already released")

    # NB: the per-call CArrowSchema / CArrowArray scratch structs are
    # HEAP-allocated rather than stack `var`s. Stack `var c = CArrowSchema();
    # var p = UnsafePointer(to=c)` is unsound here — Mojo does not extend
    # `c`'s lifetime through the UnsafePointer, so the compiler is free to
    # reuse the stack slot once `p` is taken, before the FFI callback writes
    # through `p` and before we read it back. Heap-allocating keeps the
    # storage live for the whole drain; we free it at the end. (FFI carve-out:
    # raw alloc is module-internal.)

    # --- get_schema ---
    var sch_box = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sch_box.unsafe_write(CArrowSchema())
    var rc = st.get_schema(stream.bitcast[NoneType](), sch_box)
    if rc != 0:
        var msg = _stream_error_text(stream)
        consumer_release_c_schema(sch_box)
        sch_box.free()
        consumer_release_c_stream(stream)
        raise Error("from_arrow_c_stream: get_schema failed (rc=" + String(Int(rc)) + "): " + msg)
    var info: _ImportedSchemaInfo
    try:
        info = _read_root_schema(sch_box)
    except e:
        consumer_release_c_schema(sch_box)
        sch_box.free()
        consumer_release_c_stream(stream)
        raise e^
    # Keep `sch_box` LIVE through the
    # get_next loop so nested-type imports can recurse into child
    # CArrowSchemas.  The schema struct is constant-for-the-stream per
    # the Arrow C Data Interface spec, so retaining it is correct.
    # Released after the get_next loop (below).

    # --- get_next loop ---
    var out = Slab[RecordBatch].with_capacity(4)
    while True:
        var arr_box = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
        arr_box.unsafe_write(CArrowArray())
        var rc2 = st.get_next(stream.bitcast[NoneType](), arr_box)
        if rc2 != 0:
            var msg = _stream_error_text(stream)
            consumer_release_c_array(arr_box)
            arr_box.free()
            consumer_release_c_schema(sch_box)
            sch_box.free()
            consumer_release_c_stream(stream)
            raise Error("from_arrow_c_stream: get_next failed (rc=" + String(Int(rc2)) + "): " + msg)
        if arr_box[].is_released():
            # End of stream.
            arr_box.free()
            break
        # Build a fresh Schema for this batch (Schema is Movable, copy per
        # batch so RecordBatch can own it).
        var batch_schema = _build_schema_from_info(info)
        var batch: RecordBatch
        try:
            batch = _import_record_batch(arr_box, info, batch_schema^, sch_box)
        except e:
            consumer_release_c_array(arr_box)
            arr_box.free()
            consumer_release_c_schema(sch_box)
            sch_box.free()
            consumer_release_c_stream(stream)
            raise e^
        out.append(batch^)
        # Release the consumed array struct (consumer obligation) then free
        # the box.
        consumer_release_c_array(arr_box)
        arr_box.free()

    # --- release the schema + stream ---
    consumer_release_c_schema(sch_box)
    sch_box.free()
    consumer_release_c_stream(stream)
    return out^


def _stream_error_text(stream: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]) -> String:
    if _is_null(stream):
        return String("(no stream)")
    ref st = stream[]
    var p = st.get_last_error(stream.bitcast[NoneType]())
    if _is_null(p):
        return String("(no error text)")
    return _c_str_to_mojo(p)


# =============================================================================
# ⭐⭐ THE C-ABI DRAIN — the same protocol, callable by a FOREIGN C PRODUCER.
# =============================================================================
#
# WHAT THIS IS. `drain_record_batch_stream` reads the four callbacks out of a
# `CArrowArrayStream`; this function takes them as four separate C function
# pointers plus the producer's `self`, for a connector that has a cursor and
# callbacks but no `ArrowArrayStream` struct. Both call the callbacks through
# `abi("C")` function types.
#
# WHY THE TYPES ARE `abi("C")`. The C Stream Interface declares these
# callbacks as C function pointers, and the Mojo manual requires `abi("C")` on
# a function that crosses the FFI boundary; Mojo documents no guarantee that
# its default convention matches C. What was MEASURED to break is the
# `raises` convention. Four arms in one process:
#
#     POSITIVE CONTROL  a MOJO `raises thin` fn through a `raises thin` alias -> rc = 42 ✓
#     SUBJECT           a plain C fn through the SAME alias                   -> rc = 128385032 ✗
#     CONTROL 2         the SAME C fn through `abi("C") thin`                 -> rc = 42 ✓
#     RELEASE           a C `void (*)(void*)` through `thin -> None`          -> OK ✓
#
# The out-params landed correctly in every arm, so this is a RETURN-convention
# skew, not an argument one; the garbage value is pointer-derived and differs
# between builds. SUBJECT and CONTROL 2 differ in two things at once (`raises`
# and `abi("C")`), so these arms alone do not say which one matters. A
# separate measurement on linux-x86_64 settles it for the `Int32` returns:
# with every stream slot, stub and exported callback on the Mojo default
# convention but non-raising, the dlopen gate of `:arrow_c_abi_probe` passed
# in both directions. That gate called `get_schema` and `get_next`, not
# `get_last_error` (its error-path driver came later), so the pointer return
# was not measured without `abi("C")`. The skew is the `raises`
# convention's. The fourth arm is why the release callbacks
# (`_ArrayReleaseFn = def (_ArrayPtr) thin -> None`) work across the seam. The
# Mojo stdlib states the rule at `std/ffi/__init__.mojo:get_function`: *"Using
# a plain Mojo function type causes silent ABI corruption for struct arguments
# and return values."* The `CArrowArrayStream` slots were once typed
# `raises thin`, and `drain_record_batch_stream` then read a garbage return
# code from every C producer; the dlopen gate of `:arrow_c_abi_probe`
# (`tests/c_abi/arrow_c_abi_driver.mojo`) drains a C-convention stream through
# it and fails if that comes back, and `tests/c_abi/arrow_c_abi_error_driver.mojo`
# makes the C producer fail and checks that its `get_last_error` text arrives.
#
# ⚠ WHAT IS UNCHANGED, AND IT IS THE WHOLE POINT: the DATA still crosses as
# plain Arrow C Data Interface `ArrowSchema` / `ArrowArray` — `_read_root_schema`
# and `_import_record_batch` below are the SAME two functions
# `drain_record_batch_stream` calls. Only the four callback slots are re-typed.
# A connector therefore has to know exactly one Komira-specific thing (a
# five-pointer table) and is otherwise a stock Arrow producer.
# =============================================================================

comptime CAbiGetSchemaFn = def (OpaquePtr, _SchemaPtr) abi("C") thin -> Int32
"""`int32_t (*)(void *self, struct ArrowSchema *out)` — 0 == OK."""

comptime CAbiGetNextFn = def (OpaquePtr, _ArrayPtr) abi("C") thin -> Int32
"""`int32_t (*)(void *self, struct ArrowArray *out)` — 0 == OK. End-of-stream
is signalled by leaving `out` in the RELEASED state (`out->release == NULL`),
per the Arrow C Stream Interface, NOT by a distinguished return code."""

comptime CAbiLastErrorFn = def (
    OpaquePtr
) abi("C") thin -> UnsafePointer[Int8, MutUntrackedOrigin]
"""`const char *(*)(void *self)` — NUL-terminated, or NULL if no error."""

comptime CAbiReleaseFn = def (OpaquePtr) abi("C") thin -> None
"""`void (*)(void *self)` — release the producer's per-stream state. Called
EXACTLY ONCE by this drain, on every exit path including the raising ones."""


def _c_abi_error_text(self_ptr: OpaquePtr, get_last_error: CAbiLastErrorFn) -> String:
    var p = get_last_error(self_ptr)
    if _is_null(p):
        return String("(no error text)")
    return _c_str_to_mojo(p)


def drain_c_abi_record_batch_stream(
    self_ptr: OpaquePtr,
    get_schema: CAbiGetSchemaFn,
    get_next: CAbiGetNextFn,
    get_last_error: CAbiLastErrorFn,
    release: CAbiReleaseFn,
) raises -> Slab[RecordBatch]:
    """Drain a FOREIGN C producer's stream into owned Mojo `RecordBatch`es.

    Byte-for-byte the same protocol as `drain_record_batch_stream` — call
    `get_schema` once, then `get_next` until the out-array comes back released
    — with the four callbacks taken as separate C-ABI function pointers instead
    of read out of a `CArrowArrayStream`.

    ⚠ BUFFERS ARE COPIED on import (`_import_record_batch`), so the returned
    `Slab` retains NO pointer into the producer's memory and stays valid after
    `release` — which is what makes it safe to hand to a plan that outlives the
    connector's cursor.

    ⛔ `release(self_ptr)` RUNS ON EVERY EXIT PATH, including each raise. A
    producer whose cursor leaks because the consumer failed mid-drain is a leak
    the producer cannot see and cannot fix.
    """
    # --- get_schema -----------------------------------------------------
    var sch_box = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sch_box.unsafe_write(CArrowSchema())
    var rc = get_schema(self_ptr, sch_box)
    if rc != 0:
        var msg = _c_abi_error_text(self_ptr, get_last_error)
        consumer_release_c_schema(sch_box)
        sch_box.free()
        release(self_ptr)
        raise Error(
            "c_abi_scan_stream: get_schema failed (rc="
            + String(Int(rc))
            + "): "
            + msg
        )
    var info: _ImportedSchemaInfo
    try:
        info = _read_root_schema(sch_box)
    except e:
        consumer_release_c_schema(sch_box)
        sch_box.free()
        release(self_ptr)
        raise e^

    # --- get_next loop --------------------------------------------------
    var out = Slab[RecordBatch].with_capacity(4)
    while True:
        var arr_box = alloc[CArrowArray](1).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        arr_box.unsafe_write(CArrowArray())
        var rc2 = get_next(self_ptr, arr_box)
        if rc2 != 0:
            var msg2 = _c_abi_error_text(self_ptr, get_last_error)
            consumer_release_c_array(arr_box)
            arr_box.free()
            consumer_release_c_schema(sch_box)
            sch_box.free()
            release(self_ptr)
            raise Error(
                "c_abi_scan_stream: get_next failed (rc="
                + String(Int(rc2))
                + "): "
                + msg2
            )
        if arr_box[].is_released():
            arr_box.free()
            break
        var batch_schema = _build_schema_from_info(info)
        var batch: RecordBatch
        try:
            batch = _import_record_batch(arr_box, info, batch_schema^, sch_box)
        except e:
            consumer_release_c_array(arr_box)
            arr_box.free()
            consumer_release_c_schema(sch_box)
            sch_box.free()
            release(self_ptr)
            raise e^
        out.append(batch^)
        consumer_release_c_array(arr_box)
        arr_box.free()

    consumer_release_c_schema(sch_box)
    sch_box.free()
    release(self_ptr)
    return out^


def c_abi_stream_schema(
    self_ptr: OpaquePtr,
    get_schema: CAbiGetSchemaFn,
    get_last_error: CAbiLastErrorFn,
) raises -> Schema:
    """The producer's DECLARED schema, without draining a single batch.

    ⭐ THE ZERO-ROW PATH. `drain_...` above returns an EMPTY `Slab` for a
    producer that legitimately has nothing right now — an empty queue, a
    partition with no messages — and an empty Slab carries no schema, so a plan
    rooted on it would have no columns to type-check against. This reads the
    schema through the SAME callback and lets the caller build a zero-row
    batch with the right columns.

    ⛔ IT DOES NOT `release` — the caller is mid-drain and still owns the
    cursor. Pairing this with `drain_c_abi_record_batch_stream` on the same
    `self_ptr` would release twice.
    """
    var sch_box = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sch_box.unsafe_write(CArrowSchema())
    var rc = get_schema(self_ptr, sch_box)
    if rc != 0:
        var msg = _c_abi_error_text(self_ptr, get_last_error)
        consumer_release_c_schema(sch_box)
        sch_box.free()
        raise Error(
            "c_abi_scan_stream: get_schema failed (rc="
            + String(Int(rc))
            + "): "
            + msg
        )
    var info: _ImportedSchemaInfo
    try:
        info = _read_root_schema(sch_box)
    except e:
        consumer_release_c_schema(sch_box)
        sch_box.free()
        raise e^
    var s = _build_schema_from_info(info)
    consumer_release_c_schema(sch_box)
    sch_box.free()
    return s^
