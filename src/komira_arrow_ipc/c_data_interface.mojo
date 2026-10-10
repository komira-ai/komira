# =============================================================================
# FFI-BOUNDARY: Arrow C Data Interface (zero-copy producer/consumer ABI)
# =============================================================================
# Library: Apache Arrow C Data Interface spec. No dlopen — the ABI is
#   defined by struct layout, not a library symbol table. Consumers are
#   PyArrow / Pandas / Polars / Rust Arrow.
# Contract:
#   - Mojo owns the CArrowSchema / CArrowArray allocation and the
#     buffer pointers it exports. The release callback (when filled)
#     is responsible for freeing both the struct and the underlying
#     Mojo heap. The consumer MUST call release before dropping the
#     struct.
#   - All pointer fields in the structs (name, format, buffers, children)
#     are `UnsafePointer[UInt8, MutExternalOrigin]` because (a) the C
#     ABI does not speak Mojo origins; (b) the ABI's own lifetime
#     contract (release callback) replaces Mojo's compile-time tracking.
#   - Caller promises the Mojo-owned backing buffers outlive the
#     consumer's reads. The release callback frees only what the producer
#     allocated (format/name/metadata strings, the buffers/children arrays),
#     never the borrowed buffer BYTES.
# SAFETY: every MutExternalOrigin here is correct because the struct's
#   lifetime is mediated by the C Data Interface release callback
#   protocol (or, in the stub-level case, by caller-scope aliasing).
#   See the Arrow spec for the complete ownership rules.
# This file is an FFI carve-out: raw pointers appear only at the C ABI.
# =============================================================================
# Arrow C Data Interface — struct definitions, format string helpers, and
# export/import stubs
# =============================================================================
#
# The Arrow C Data Interface defines two C structs (ArrowSchema and ArrowArray)
# that enable zero-copy data sharing between different Arrow implementations.
# This is the standard mechanism for exporting Arrow data to Python libraries
# like Pandas, Polars, and PyArrow.
#
# Reference: https://arrow.apache.org/docs/format/CDataInterface.html
#
# This module provides:
#   1. CArrowSchema / CArrowArray struct definitions matching the C ABI layout
#   2. ArrowType.format_string() for C Data Interface format strings
#      (implemented in arrow_types.mojo)
#   3. export_schema() / export_primitive() stubs for Field/PrimitiveArray export
#
# The `release` slot holds a REAL function pointer (Mojo 1.0.0b2 spells the
# type `def (T) thin -> None`); `export_schema` / `export_primitive` install
# `_release_schema` / `_release_array` so a conforming consumer can do what the
# ABI says and CALL it. See §"Release-callback discipline" below for the
# heap-byte defect this replaced.
# =============================================================================

from std.memory import alloc, bitcast, unsafe_memcpy
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field
from komira_arrow.primitive_array import PrimitiveArray


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer (replaces the b2-removed `UnsafePointer[T, o]()`
    null ctor).

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
# NULL TESTS AT THE C ABI BOUNDARY — and why they are not `Bool(ptr)`
# =============================================================================
#
# `Bool(UnsafePointer)` is deprecated: "UnsafePointer is non-null by design, so
# Bool(ptr) is no longer meaningful. To model a null pointer, use
# `Optional[UnsafePointer[...]]`."
#
# ⚠ THE SUGGESTED MIGRATION IS INAPPLICABLE HERE, AND SILENTLY SO. `Optional`
# models OUR optionality. Every pointer in a CArrowSchema / CArrowArray is a
# field of a C struct whose bytes a FOREIGN producer wrote — pyarrow, polars,
# arrow-rs, any C caller — and NULL is a value the spec REQUIRES them to be able
# to write there. We do not control the writer, so we cannot make the field an
# `Optional`; we can only read the word and ask whether it is zero.
#
# `Int(p) == 0` is the established idiom for exactly this, it is
# semantics-preserving today, and it survives the non-nullable redefinition.
# The two named wrappers below exist so each call site says WHICH of the spec's
# several NULL meanings it is testing rather than leaving `not p` to stand for
# all of them; the meaning table is in `c_data_stream.mojo`.


@always_inline
def _is_null[T: AnyType, o: Origin](p: UnsafePointer[T, o]) -> Bool:
    """True iff `p` is the C NULL pointer.

    # SAFETY: FFI boundary. The address is only COMPARED, never dereferenced;
    # this is the read half of a contract whose write half is a foreign C
    # producer storing a literal NULL in a struct field the spec says may be
    # NULL. Comparing an address to zero requires no valid origin.
    """
    return Int(p) == 0


@always_inline
def _non_null[T: AnyType, o: Origin](p: UnsafePointer[T, o]) -> Bool:
    """True iff `p` is a non-NULL pointer. See `_is_null`."""
    return Int(p) != 0


# --- Flag constants (from the Arrow C Data Interface spec) ---

comptime ARROW_FLAG_DICTIONARY_ORDERED: Int64 = 1
"""If set, the dictionary is ordered (relevant for dictionary-encoded arrays)."""

comptime ARROW_FLAG_NULLABLE: Int64 = 2
"""If set, the field/array may contain null values."""

comptime ARROW_FLAG_MAP_KEYS_SORTED: Int64 = 4
"""If set, the map keys within each value are sorted."""


# =============================================================================
# CArrowSchema — C ABI struct for type/schema metadata
# =============================================================================

struct CArrowSchema(Movable):
    """Arrow C Data Interface schema struct.

    This matches the ArrowSchema C struct layout exactly. Each field
    corresponds to the spec:

        struct ArrowSchema {
            const char* format;
            const char* name;
            const char* metadata;
            int64_t flags;
            int64_t n_children;
            struct ArrowSchema** children;
            struct ArrowSchema* dictionary;
            void (*release)(struct ArrowSchema*);
            void* private_data;
        };

    Ownership: the CONSUMER calls `release` exactly once, and the callback
    must free everything the producer allocated and set `release = NULL`
    ("released structure"). `release` is declared `void*` here rather than as
    a typed fn-ptr field because the C ABI slot is one word either way and the
    `void*` spelling keeps `is_released()` a plain null check; what is STORED
    in it is the address of `_release_schema`.
    """

    # SAFETY: ALL UnsafePointer fields in CArrowSchema and CArrowArray are
    # REQUIRED by the Arrow C Data Interface spec. The struct layout must
    # match the C ABI exactly (raw pointers, not smart pointers). These
    # cannot use OwnedPointer/ArcPointer because:
    # 1. The C ABI mandates specific pointer types and null semantics.
    # 2. The release callback (function pointer) manages ownership.
    # 3. Cross-language interop (Python/PyArrow) requires exact C layout.

    var format: UnsafePointer[Int8, MutUntrackedOrigin]
    """Mandatory. A null-terminated, UTF8-encoded string describing the
    data type. Must not be null."""

    var name: UnsafePointer[Int8, MutUntrackedOrigin]
    """Optional. A null-terminated, UTF8-encoded string giving the field
    name. May be null."""

    var metadata: UnsafePointer[Int8, MutUntrackedOrigin]
    """Optional. Binary-encoded key-value metadata in Arrow's metadata
    format. May be null."""

    var flags: Int64
    """A bitfield of ARROW_FLAG_* constants."""

    var n_children: Int64
    """The number of child schemas (for nested types)."""

    var children: UnsafePointer[
        UnsafePointer[CArrowSchema, MutUntrackedOrigin], MutUntrackedOrigin
    ]
    """Pointer to an array of n_children pointers to child CArrowSchema."""

    var dictionary: UnsafePointer[CArrowSchema, MutUntrackedOrigin]
    """Optional. Points to the dictionary value type schema for
    dictionary-encoded arrays. Null if not dictionary-encoded."""

    var release: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Release callback: `void (*release)(struct ArrowSchema*)`. Holds the
    address of a real function (`_release_schema`), stored in a `void*`-typed
    slot — same one machine word the C ABI expects. NULL means released."""

    var private_data: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Optional opaque pointer for the producer's private use."""

    def __init__(out self):
        """Create a zeroed-out (released) CArrowSchema.

        All pointer fields are null and counts are zero. This represents
        a schema that has been released or is not yet initialized.
        """
        self.format = _null_ptr[Int8, MutUntrackedOrigin]()
        self.name = _null_ptr[Int8, MutUntrackedOrigin]()
        self.metadata = _null_ptr[Int8, MutUntrackedOrigin]()
        self.flags = 0
        self.n_children = 0
        self.children = _null_ptr[UnsafePointer[CArrowSchema, MutUntrackedOrigin], MutUntrackedOrigin]()
        self.dictionary = _null_ptr[CArrowSchema, MutUntrackedOrigin]()
        self.release = _null_ptr[NoneType, MutUntrackedOrigin]()
        self.private_data = _null_ptr[NoneType, MutUntrackedOrigin]()

    def is_released(self) -> Bool:
        """Check if this schema has been released (release callback is null).

        Per the Arrow spec, a null release callback indicates that the
        struct has been released and should not be used.
        """
        return _is_null(self.release)


# =============================================================================
# CArrowArray — C ABI struct for columnar data
# =============================================================================

struct CArrowArray(Movable):
    """Arrow C Data Interface array struct.

    This matches the ArrowArray C struct layout exactly. Each field
    corresponds to the spec:

        struct ArrowArray {
            int64_t length;
            int64_t null_count;
            int64_t offset;
            int64_t n_buffers;
            int64_t n_children;
            const void** buffers;
            struct ArrowArray** children;
            struct ArrowArray* dictionary;
            void (*release)(struct ArrowArray*);
            void* private_data;
        };

    Ownership: Same as CArrowSchema — the release callback is the
    ownership mechanism, and it holds a real function address.
    """

    var length: Int64
    """The logical length of the array (number of elements)."""

    var null_count: Int64
    """The number of null values. May be -1 if not yet computed."""

    var offset: Int64
    """The logical offset into the buffers (for sliced arrays)."""

    var n_buffers: Int64
    """The number of physical buffers backing this array.
    Includes the validity bitmap if present."""

    var n_children: Int64
    """The number of child arrays (for nested types)."""

    # SAFETY: All pointer fields mandated by Arrow C Data Interface spec.
    # See CArrowSchema SAFETY comment for rationale.

    var buffers: UnsafePointer[
        UnsafePointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin
    ]
    """Pointer to an array of n_buffers pointers. Each points to
    a contiguous memory region. The meaning depends on the data type."""

    var children: UnsafePointer[
        UnsafePointer[CArrowArray, MutUntrackedOrigin], MutUntrackedOrigin
    ]
    """Pointer to an array of n_children pointers to child CArrowArrays."""

    var dictionary: UnsafePointer[CArrowArray, MutUntrackedOrigin]
    """Optional. Points to the dictionary values array for
    dictionary-encoded arrays. Null if not dictionary-encoded."""

    var release: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Release callback: `void (*release)(struct ArrowArray*)`. Holds the
    address of a real function (`_release_array`) — see CArrowSchema."""

    var private_data: UnsafePointer[NoneType, MutUntrackedOrigin]
    """Optional opaque pointer for the producer's private use."""

    def __init__(out self):
        """Create a zeroed-out (released) CArrowArray.

        All pointer fields are null, counts are zero, null_count is 0.
        """
        self.length = 0
        self.null_count = 0
        self.offset = 0
        self.n_buffers = 0
        self.n_children = 0
        self.buffers = _null_ptr[UnsafePointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin]()
        self.children = _null_ptr[UnsafePointer[CArrowArray, MutUntrackedOrigin], MutUntrackedOrigin]()
        self.dictionary = _null_ptr[CArrowArray, MutUntrackedOrigin]()
        self.release = _null_ptr[NoneType, MutUntrackedOrigin]()
        self.private_data = _null_ptr[NoneType, MutUntrackedOrigin]()

    def is_released(self) -> Bool:
        """Check if this array has been released (release callback is null)."""
        return _is_null(self.release)


# =============================================================================
# Export functions — stubs for Arrow C Data Interface export
# =============================================================================


@always_inline
def _copy_string_to_c(s: String) -> UnsafePointer[Int8, MutUntrackedOrigin]:
    """Copy a Mojo String to a heap-allocated null-terminated C string.

    The caller is responsible for freeing the returned pointer.

    Args:
        s: The Mojo String to copy.

    Returns:
        A pointer to a null-terminated C string on the heap.
    """
    var n = s.byte_length()
    var buf = alloc[Int8](n + 1)
    # memcpy from the String's underlying storage instead of byte-by-byte loop
    var s_ref = s
    var src = s_ref.as_c_string_slice().unsafe_ptr()
    if n > 0:
        unsafe_memcpy(dest=buf, src=src, count=n)
    (buf + n).unsafe_write(Int8(0))
    return buf


# =============================================================================
# Release-callback discipline + per-struct release callbacks
# =============================================================================
#
# Arrow C Data Interface release-callback protocol (see spec §"Released
# structure"): every live `CArrowSchema` / `CArrowArray` MUST have a non-NULL
# `release` member; after the consumer invokes the release callback, the
# struct's `release` member MUST be NULL and all heap-owned resources must
# be freed.
#
# The slot holds a REAL FUNCTION POINTER. The in-tree struct still declares
# `release` as `void*` because it predates Mojo fn-ptr fields, but what we
# store in it is the address of `_release_schema` / `_release_array` — the
# same 8-byte word a C producer writes, so `((void(*)(ArrowArray*))a->release)(a)`
# on the consumer side lands in real code.
#
# ⛔ NOT A "LIVE MARKER". A non-NULL placeholder (e.g. a pointer to a one-byte
# heap allocation) satisfies every Mojo-side test — `release` is non-NULL, so
# `is_released()` says False — while guaranteeing that any conforming consumer
# that does what the ABI says, and CALLS it, jumps the program counter into a
# heap data byte: SIGBUS, PC at an unmapped heap address. Mojo spells the type
# `def (T) thin -> None` (this file's sibling `c_data_stream.mojo` stores three
# such pointers in the ArrowArrayStream callback fields). Arrow's own C helpers
# additionally `abort()` when a release callback fails to null itself out,
# which a heap byte can never do. The release-callback-is-a-function-pointer
# unit test guards this.
#
# `export_schema` and `export_primitive` heap-allocate `format` / `name` /
# `buffers`; this block of helpers + the wiring in the two export functions
# frees them through the release callback, which keeps the file
# spec-compliant on the release-callback contract and leak-free.

# Type aliases for the by-pointer release helpers.
comptime _SchemaPtrRel = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _ArrayPtrRel = UnsafePointer[CArrowArray, MutUntrackedOrigin]

# The spec's callback types, verbatim:
#     void (*release)(struct ArrowSchema*);
#     void (*release)(struct ArrowArray*);
# `thin` = non-capturing (no context word). VERIFIED against a real C caller,
# not assumed: a `cc`-compiled C function that casts the `void*` slot to
# `void (*)(struct*)` and calls it reaches the Mojo callback with the correct
# argument, and observes `release == NULL` on return — i.e. exactly the
# sequence pyarrow's C++ importer performs.
comptime SchemaReleaseFn = def (_SchemaPtrRel) thin -> None
comptime ArrayReleaseFn = def (_ArrayPtrRel) thin -> None


# ⚠ CONSUMER-SIDE DISPATCH DOES NOT LIVE HERE, AND THAT IS NOT A STYLE CHOICE.
# The obvious tidier shape — have `release_c_schema` read the slot back into a
# fn-ptr and call THROUGH it, so our own tests exercise the same indirection a
# C consumer does — SEGFAULTS THE MOJO 1.0.0b2 COMPILER. Not the built binary:
# the compiler, during `MojoCompileExecutable` of any test that imports this
# module from the precompiled the core packages (`(Segmentation fault)`, no diagnostic).
# It is specifically an indirect call through a bitcast `def (T) thin -> None`
# made from a function elaborated OUT OF A precompiled package; the identical call
# compiles fine in test-local source. So `release_c_*` below calls the release
# function directly, and the falsifying test does the reinterpret-and-call
# itself. Do not "simplify" this back.

def _release_schema(sch_ptr: _SchemaPtrRel) -> None:
    """Internal: walk a CArrowSchema, free the heap THIS module allocated
    (format/name/metadata strings; for nested types, children array + child
    structs + recursive children; dictionary), and NULL `release` per the
    Arrow spec.

    Idempotent (safe on an already-released / zeroed struct).

    Does NOT free borrowed buffer bytes — those belong to the producer
    upstream of the export call. For `export_primitive`, those buffer bytes
    are the input PrimitiveArray's internal storage; that lifetime is the
    caller's responsibility per the existing `export_primitive` docstring.
    """
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
        var child_arr = s.children.bitcast[_SchemaPtrRel]()
        for i in range(Int(s.n_children)):
            var c = (child_arr + i)[]
            if _non_null(c):
                _release_schema(c)
                c.free()
        s.children.free()
        s.children = _null_ptr[UnsafePointer[CArrowSchema, MutUntrackedOrigin], MutUntrackedOrigin]()
    if _non_null(s.dictionary):
        _release_schema(s.dictionary)
        s.dictionary.free()
        s.dictionary = _null_ptr[CArrowSchema, MutUntrackedOrigin]()
    s.n_children = 0
    # "Released structure": the spec REQUIRES the callback to null its own
    # `release` member. Arrow's C helpers abort() if it does not.
    s.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _release_array(arr_ptr: _ArrayPtrRel) -> None:
    """Internal: walk a CArrowArray, free the heap THIS module allocated
    (buffers array; for nested types, children array + child structs +
    recursive children; dictionary), and NULL `release` per the Arrow spec.

    Idempotent (safe on an already-released / zeroed struct).

    Does NOT free borrowed buffer bytes — those belong to the producer
    upstream of the export call.
    """
    if _is_null(arr_ptr):
        return
    ref a = arr_ptr[]
    if a.is_released():
        return
    if a.n_children > 0 and _non_null(a.children):
        var child_arr = a.children.bitcast[_ArrayPtrRel]()
        for i in range(Int(a.n_children)):
            var c = (child_arr + i)[]
            if _non_null(c):
                _release_array(c)
                c.free()
        a.children.free()
        a.children = _null_ptr[UnsafePointer[CArrowArray, MutUntrackedOrigin], MutUntrackedOrigin]()
    if _non_null(a.dictionary):
        _release_array(a.dictionary)
        a.dictionary.free()
        a.dictionary = _null_ptr[CArrowArray, MutUntrackedOrigin]()
    if _non_null(a.buffers):
        a.buffers.free()
        a.buffers = _null_ptr[UnsafePointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin]()
    a.n_children = 0
    a.n_buffers = 0
    # "Released structure": the spec REQUIRES the callback to null its own
    # `release` member. Arrow's C helpers abort() if it does not.
    a.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _release_schema_entry(sch_ptr: _SchemaPtrRel) -> None:
    """Non-recursive entry trampoline whose ADDRESS goes in the `release` slot.

    `_release_schema` is SELF-RECURSIVE (it walks children). Taking a recursive
    function's address here segfaults the Mojo compiler — not the binary,
    the compiler — while elaborating a consumer TU that lets an exported
    struct drop as a local (deterministic, no diagnostic; `@no_inline` does
    not help). The one-hop
    trampoline is not decoration.
    """
    _release_schema(sch_ptr)


def _release_array_entry(arr_ptr: _ArrayPtrRel) -> None:
    """Non-recursive entry trampoline — see `_release_schema_entry`."""
    _release_array(arr_ptr)


def _set_schema_release(mut s: CArrowSchema):
    """Install the real release callback on `s.release`. Call from every
    public `export_*` that produces a CArrowSchema, so the resulting struct
    satisfies the Arrow 'live struct' contract AND is callable by a
    conforming consumer.

    # SAFETY: a `thin` fn-ptr and a `void*` are both one machine word; the C
    # Data Interface's `release` member IS a code pointer whose in-tree
    # declaration is `void*` only because the struct predates Mojo fn-ptr
    # fields. This reinterpret is the producer half of the ABI; the only
    # reader is the consumer, through the C ABI.
    """
    var f: SchemaReleaseFn = _release_schema_entry
    s.release = UnsafePointer(to=f).bitcast[
        UnsafePointer[NoneType, MutUntrackedOrigin]
    ]()[]


def _set_array_release(mut a: CArrowArray):
    """Install the real release callback on `a.release`. Call from every
    public `export_*` that produces a CArrowArray, so the resulting struct
    satisfies the Arrow 'live struct' contract AND is callable by a
    conforming consumer.

    # SAFETY: see `_set_schema_release`.
    """
    var f: ArrayReleaseFn = _release_array_entry
    a.release = UnsafePointer(to=f).bitcast[
        UnsafePointer[NoneType, MutUntrackedOrigin]
    ]()[]


def release_c_schema(sch_ptr: _SchemaPtrRel) -> None:
    """Invoke the release callback of a CArrowSchema exported by this
    module (Mojo-side equivalent of C's `schema.release(&schema)`).
    Recursive into children + dictionary. NULLs `sch_ptr[].release`
    afterwards. Idempotent on an already-released / zeroed struct.

    This is the MOJO-side entry point and it calls `_release_schema`
    directly. A foreign consumer instead calls the `release` slot, which
    holds that same function's address. See the compiler-segfault note in
    §"Release-callback discipline" for why the two paths are not unified.

    Caller MUST invoke this on any CArrowSchema returned by
    `export_schema` (or any other `export_*` function in this module
    that produces a CArrowSchema) before the struct goes out of scope,
    or the heap-allocated `format` / `name` / `metadata` strings will
    leak.
    """
    _release_schema(sch_ptr)


def release_c_array(arr_ptr: _ArrayPtrRel) -> None:
    """Invoke the release callback of a CArrowArray exported by this
    module (Mojo-side equivalent of C's `array.release(&array)`).
    Recursive into children + dictionary. NULLs `arr_ptr[].release`
    afterwards. Idempotent on an already-released / zeroed struct.

    Mojo-side entry point; calls `_release_array` directly — see
    `release_c_schema`.

    Caller MUST invoke this on any CArrowArray returned by
    `export_primitive` (or any other `export_*` function in this
    module that produces a CArrowArray) before the struct goes out
    of scope, or the heap-allocated `buffers` array will leak.

    Does NOT free borrowed buffer BYTES — those belong to the source
    PrimitiveArray / Column / etc. that was passed to the export
    function. The caller must keep the source alive separately for as
    long as any consumer is reading via the exported CArrowArray.
    """
    _release_array(arr_ptr)


# =============================================================================
# Metadata kv-list <-> Arrow C Data Interface packed bytes
# =============================================================================
# Per the Arrow C Data Interface spec (§"Metadata"), `CArrowSchema.metadata`
# holds a *packed* sequence of length-prefixed UTF-8 key/value byte strings
# with the wire format:
#
#     int32 num_keys (host byte order, signed)
#     for each entry:
#         int32 key_len   (host byte order, signed)
#         char  key_bytes[key_len]    (UTF-8, NOT null-terminated)
#         int32 value_len (host byte order, signed)
#         char  value_bytes[value_len] (UTF-8, NOT null-terminated)
#
# The spec uses platform-endian int32s (i.e. memcpy'd) because the metadata
# is consumed in-process by another library that shares the same native ABI.
# A 0-entry payload is `[0, 0, 0, 0]` (4 bytes). NULL means "no metadata".
#
# These helpers carry the Field's `_metadata_keys` / `_metadata_values`
# across `CArrowSchema.metadata` on export and import, so Extension types
# (ARROW:extension:name) survive the C-Data round-trip.


@always_inline
def _i32_to_bytes(value: Int32, mut out: UnsafePointer[Int8, MutUntrackedOrigin]):
    """Write a 32-bit signed integer to `out` in little-endian order, 4 bytes.

    ⛔ DO NOT "SIMPLIFY" THIS TO A memcpy FROM `UnsafePointer(to=<local>)`.
    That is SILENTLY WRONG ON MOJO 1.1:
    a local used ONLY as a memcpy SOURCE is never materialised, so the copy
    reads ZEROS. Measured on both compilers, isolated repro:

        var w = Int32(1234567)
        unsafe_memcpy(dest=buf, src=UnsafePointer(to=w).unsafe_bitcast[Int8](), count=4)
        buf as i32  ->  1.0.0: 1234567    1.1.0: 0

    ⚠ The opposite direction (a local as the memcpy DESTINATION, then reading
    the local) is FINE on both — which is why `_bytes_to_i32` below is unchanged.
    There is no diagnostic on either compiler; the only witness is a test,
    where it presents as `decode_metadata: implausible key count ...`.

    Explicit byte stores also make the encoding ENDIAN-DEFINED rather than
    native, and are alignment-safe, which matters because Arrow packs these
    i32s at unaligned offsets."""
    var u = UInt32(Int(value) & 0xFFFFFFFF)
    out.unsafe_write(Int8(Int(u & 0xFF)))
    (out + 1).unsafe_write(Int8(Int((u >> 8) & 0xFF)))
    (out + 2).unsafe_write(Int8(Int((u >> 16) & 0xFF)))
    (out + 3).unsafe_write(Int8(Int((u >> 24) & 0xFF)))


@always_inline
def _bytes_to_i32(p: UnsafePointer[Int8, MutUntrackedOrigin]) -> Int32:
    """Read a 32-bit signed integer from `p` in little-endian order, 4 bytes.

    ⚠ THE PAIR MUST AGREE. `_i32_to_bytes` above is byte-wise little-endian
    (it had to stop using a memcpy -- see its docstring), so this reader is
    byte-wise too. The memcpy form it replaced was NATIVE-endian; that agreed
    with the writer only because every platform this repo targets
    (osx-arm64, linux-x86_64, linux-aarch64) is little-endian. Keeping one
    half native and the other explicit would leave a latent disagreement that
    no test on any supported host could catch."""
    var b0 = UInt32(Int(p[]) & 0xFF)
    var b1 = UInt32(Int((p + 1)[]) & 0xFF)
    var b2 = UInt32(Int((p + 2)[]) & 0xFF)
    var b3 = UInt32(Int((p + 3)[]) & 0xFF)
    # Reinterpret the 32 bits as two's complement. `Int32(Int(u))` widens
    # the UInt32 first and then narrows an Int above Int32's range, which
    # is not a defined wrap: FF FF FF FF came out as 4294967295, not -1,
    # and the callers' `< 0` checks never fired.
    return bitcast[DType.int32](b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))


def encode_metadata(
    keys: List[String], values: List[String]
) -> UnsafePointer[Int8, MutUntrackedOrigin]:
    """Encode a kv-list into Arrow C Data Interface packed metadata bytes.

    Returns a heap-allocated, *not* null-terminated buffer suitable for
    assigning to `CArrowSchema.metadata`. Returns NULL when there are zero
    entries (Arrow spec: NULL == "no metadata", which is the canonical
    representation; an empty kv-list is encoded the same way to keep
    round-trip behavior with no-metadata producers stable).

    Caller owns the returned pointer; the matching release callback should
    free it via `.free()` when releasing the schema.


    """
    var n = len(keys)
    if n == 0 or n != len(values):
        return _null_ptr[Int8, MutUntrackedOrigin]()
    # Compute total size: i32 count + per-entry (i32 klen + bytes + i32 vlen + bytes).
    var total = 4
    for i in range(n):
        total += 4 + keys[i].byte_length()
        total += 4 + values[i].byte_length()
    var buf = alloc[Int8](total).unsafe_origin_cast[MutUntrackedOrigin]()
    var cursor = buf
    _i32_to_bytes(Int32(n), cursor)
    cursor = cursor + 4
    for i in range(n):
        var k = keys[i]
        var v = values[i]
        var klen = k.byte_length()
        var vlen = v.byte_length()
        _i32_to_bytes(Int32(klen), cursor)
        cursor = cursor + 4
        if klen > 0:
            var k_ref = k
            var k_src = k_ref.as_c_string_slice().unsafe_ptr()
            unsafe_memcpy(dest=cursor, src=k_src, count=klen)
            cursor = cursor + klen
        _i32_to_bytes(Int32(vlen), cursor)
        cursor = cursor + 4
        if vlen > 0:
            var v_ref = v
            var v_src = v_ref.as_c_string_slice().unsafe_ptr()
            unsafe_memcpy(dest=cursor, src=v_src, count=vlen)
            cursor = cursor + vlen
    return buf


def decode_metadata(
    p: UnsafePointer[Int8, MutUntrackedOrigin]
) raises -> Tuple[List[String], List[String]]:
    """Decode an Arrow C Data Interface packed metadata buffer into a
    (keys, values) kv-pair.  Returns empty lists when `p` is NULL.

    Raises if the buffer self-describes a negative count, negative key/value
    length, or implausibly large length (>= 2^28 bytes per token guards
    against corrupted input). The implementation walks the bytes
    sequentially using little-endian i32 reads (matches `encode_metadata`).


    """
    var keys = List[String]()
    var values = List[String]()
    if _is_null(p):
        return (keys^, values^)
    var cursor = p
    var n = Int(_bytes_to_i32(cursor))
    cursor = cursor + 4
    if n < 0 or n > (1 << 20):
        raise Error(
            "decode_metadata: implausible key count " + String(n)
        )
    for _ in range(n):
        var klen = Int(_bytes_to_i32(cursor))
        cursor = cursor + 4
        if klen < 0 or klen > (1 << 28):
            raise Error(
                "decode_metadata: implausible key length " + String(klen)
            )
        # Build a null-terminated scratch buffer and feed to the String ctor.
        var k_scratch = List[UInt8](capacity=klen + 1)
        for i in range(klen):
            k_scratch.append(UInt8((cursor + i)[]))
        k_scratch.append(UInt8(0))
        var k = String(unsafe_from_utf8_ptr=k_scratch.unsafe_ptr())
        cursor = cursor + klen
        var vlen = Int(_bytes_to_i32(cursor))
        cursor = cursor + 4
        if vlen < 0 or vlen > (1 << 28):
            raise Error(
                "decode_metadata: implausible value length " + String(vlen)
            )
        var v_scratch = List[UInt8](capacity=vlen + 1)
        for i in range(vlen):
            v_scratch.append(UInt8((cursor + i)[]))
        v_scratch.append(UInt8(0))
        var v = String(unsafe_from_utf8_ptr=v_scratch.unsafe_ptr())
        cursor = cursor + vlen
        keys.append(k)
        values.append(v)
    return (keys^, values^)


def export_schema(field: Field) -> CArrowSchema:
    """Export a Field as an Arrow C Schema struct.

    Fills in the format string from the Field's ArrowType, the name, and
    the nullable flag. Children are not populated (empty for primitive types).
    The release callback is installed (see `_set_schema_release`).

    The heap-allocated `format` and `name` strings ARE freed by the release callback machinery.
    Callers MUST invoke `release_c_schema(UnsafePointer(to=returned_schema))`
    before the returned struct goes out of scope, per the Arrow C Data
    Interface release-callback protocol. Without that call, the strings leak.
    See module §"Release-callback discipline" for the full protocol.

    Args:
        field: The Field to export.

    Returns:
        A CArrowSchema struct with format, name, flags, and the real
        `_release_schema` callback installed on `release`. Caller MUST
        eventually invoke `release_c_schema` on it (or, as a foreign
        consumer, call the `release` slot directly).
    """
    var schema = CArrowSchema()

    # Format string — heap-allocated null-terminated copy
    var fmt = field.arrow_type.format_string()
    schema.format = _copy_string_to_c(fmt)

    # Name — heap-allocated null-terminated copy
    schema.name = _copy_string_to_c(field.name)

    # Flags
    if field.nullable:
        schema.flags = ARROW_FLAG_NULLABLE
    else:
        schema.flags = 0

    # Children — leave empty for primitive types
    schema.n_children = Int64(field.num_children())

    # Install the release callback so the struct satisfies the Arrow 'live
    # struct' contract and any consumer — ours via `release_c_schema`, or a foreign one calling the slot — can
    # free the heap-allocated format/name strings. Without this, they leak.
    _set_schema_release(schema)

    # metadata, dictionary, private_data remain null (from __init__).
    return schema^


def export_primitive[dtype: DType](array: PrimitiveArray[dtype]) -> CArrowArray:
    """Export a PrimitiveArray as an Arrow C Array struct.

    Populates length, null_count, offset, n_buffers, the buffer pointers
    (validity bitmap pointer + data pointer), and the real `release`
    callback.

    The heap-allocated `buffers` array IS freed by the release callback machinery. Callers MUST
    invoke `release_c_array(UnsafePointer(to=returned_array))` before the
    returned struct goes out of scope, per the Arrow C Data Interface
    release-callback protocol. Without that call, the buffers array leaks.
    The BORROWED buffer BYTES (`array.data` / `array.validity`) are NOT
    freed by the release callback — those belong to the source PrimitiveArray
    and the caller MUST keep `array` alive separately for as long as any
    consumer is reading via the exported CArrowArray.

    The buffer layout for primitive types per the Arrow spec:
        buffers[0] = validity bitmap pointer (null if non-nullable)
        buffers[1] = data pointer

    Args:
        array: The PrimitiveArray to export.

    Returns:
        A CArrowArray struct with length, null_count, offset, buffer
        pointers populated, and the real `_release_array` callback installed
        on `release`. Caller MUST eventually invoke `release_c_array` on it
        (or, as a foreign consumer, call the `release` slot directly).
    """
    var result = CArrowArray()

    result.length = Int64(array.length)
    result.null_count = Int64(array.null_count)
    result.offset = Int64(array.offset)

    # Primitive arrays always have 2 buffers: validity + data
    result.n_buffers = 2

    # Allocate the buffers array (2 pointers)
    var bufs = alloc[UnsafePointer[NoneType, MutUntrackedOrigin]](2)

    # Buffer 0: validity bitmap (null pointer if non-nullable)
    # FFI-CARVE-OUT: FFI boundary — `bufs` is the Arrow C
    # Data Interface buffers array, consumed by external C/Python
    # processes. We MUST hand out raw bytes here; no view-based API
    # can SUBSTITUTE for the receiver type (the C ABI requires
    # `UnsafePointer[NoneType, MutExternalOrigin]`). This file is an FFI
    # boundary.
    #
    # Uses the `view_ro() + view._unsafe_ptr()` pattern (never a
    # wildcard-shim accessor), as `PrimitiveArray._unsafe_data_ptr` does
    # internally (SharedAlignedBuffer exposes view_ro/view_mut
    # with the same ByteView[origin] shape).
    #
    # SAFETY: `view_ro()` produces a `ByteView[origin]` whose origin
    # ties to the bitmap's buffer (i.e. to the validity bitmap object's
    # lifetime). Within this expression scope, the buffer is alive
    # (`array.validity.value()` borrows it). `_unsafe_ptr()` returns
    # the raw `UnsafePointer[UInt8, origin]`; the `bitcast[NoneType]`
    # preserves origin, `unsafe_mut_cast[True]` flips immut→mut to
    # match the C ABI receiver, and `unsafe_origin_cast[MutExternalOrigin]`
    # widens origin to satisfy the FFI receiver — the C consumer's
    # lifetime contract (release callback or caller-scope aliasing)
    # replaces Mojo's compile-time origin tracking for the FFI boundary.
    if array.validity:
        # Point to the bitmap's raw data
        var bm_view = array.validity.value().buffer.view_ro()
        var bm_ptr = bm_view._unsafe_ptr().bitcast[
            NoneType
        ]().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin]()
        (bufs + 0).unsafe_write(bm_ptr)
    else:
        (bufs + 0).unsafe_write(
            _null_ptr[NoneType, MutUntrackedOrigin]()
        )

    # Buffer 1: data pointer (offset-adjusted is NOT applied here — the
    # offset field in CArrowArray tells the consumer where to start reading)
    # FFI-CARVE-OUT: same rationale as Buffer 0 above. This
    # file is an FFI boundary.
    #
    # Same pattern as Buffer 0: `view_ro() + view._unsafe_ptr()`.
    #
    # SAFETY: see Buffer 0 above. `array.data` (PrimitiveArray's
    # `MmapAlignedBuffer[64, K]` field) is alive for the duration of
    # `export_primitive` since `array` is passed by borrow; the
    # ByteView's origin ties to it. The FFI receiver's lifetime is
    # mediated by the C Data Interface contract (release callback
    # or caller-scope aliasing per file header), which is why the
    # widening to MutExternalOrigin is correct here.
    var data_view = array.data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[
        NoneType
    ]().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin]()
    (bufs + 1).unsafe_write(data_ptr)

    result.buffers = bufs

    # No children for primitive types
    result.n_children = 0

    # Install the release callback so the struct satisfies the Arrow 'live
    # struct' contract and any consumer — ours via `release_c_array`, or a foreign one calling the slot — can
    # free the heap-allocated buffers array. Without this, it leaks.
    _set_array_release(result)

    return result^
